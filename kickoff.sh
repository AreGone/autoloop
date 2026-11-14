#!/usr/bin/env bash
#
# Autonomous development loop: plan -> one task -> verify, repeated, with
# PROGRESS.md as the state the runs share and git commits as checkpoints.
# A blocked loop first asks the judge run (a strong model) to answer the open
# questions from the project's documents; what it cannot answer goes to the
# owner over Telegram. Dependabot's pull requests on the base branch are looked
# at between runs: a green one is merged and brought into the milestone branch,
# a red one is triaged by the judge (flaky: its failed jobs run again once;
# broken or unclear: told to the owner with the judge's reason). With
# STAGING_UP set, the project's services run next to the loop on free ports
# (a staging), started with the loop and brought up to date after every
# commit, so that the owner can open what it builds.
#
# This file is the shared core (https://github.com/AreGone/autoloop), checked
# out as a submodule under the project's autoloop directory, by default
# tools/autoloop/core. The project directory (the parent of this checkout)
# holds the prompts, autoloop.env, log/ and archive/; nothing is written here.
#
# Usage: core/kickoff.sh [--once] [--dry-run] [--print-stage]
#   --once         run a single stage and exit (for testing the wrapper)
#   --dry-run      print the stage and the claude command, run nothing
#   --print-stage  print the next stage (plan, task, verify, blocked, bad_progress, ...) and exit
#
# Configuration: <project autoloop dir>/autoloop.env (copy autoloop.env.example;
# git-ignored). Exit codes: 0 milestone done or iteration cap reached,
# 2 blocked with no answer path (question in QUESTIONS.md, Telegram not
# configured or no answer within ANSWER_WAIT_S), 3 setup error,
# 4 usage limit wait longer than LIMIT_NOTIFY_HOURS.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly HERE
readonly AUTOLOOP_DIR="${AUTOLOOP_DIR:-$(cd "${HERE}/.." && pwd)}"
readonly REPO_ROOT="${AUTOLOOP_REPO:-$(git -C "${AUTOLOOP_DIR}" rev-parse --show-toplevel)}"
readonly AUTOLOOP_REL="${AUTOLOOP_DIR#"${REPO_ROOT}"/}"
readonly ENV_FILE="${AUTOLOOP_DIR}/autoloop.env"
readonly LOG_DIR="${AUTOLOOP_DIR}/log"
readonly PROGRESS="${REPO_ROOT}/PROGRESS.md"
readonly QUESTIONS="${REPO_ROOT}/QUESTIONS.md"
readonly ARCHIVE_ROOT="${AUTOLOOP_DIR}/archive"

if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
fi

readonly PLAN_MODEL="${PLAN_MODEL:-opus}"
readonly TASK_MODEL="${TASK_MODEL:-sonnet}"
readonly VERIFY_MODEL="${VERIFY_MODEL:-opus}"
readonly JUDGE_MODEL="${JUDGE_MODEL:-opus}"
readonly PLAN_MAX_TURNS="${PLAN_MAX_TURNS:-60}"
readonly TASK_MAX_TURNS="${TASK_MAX_TURNS:-80}"
readonly VERIFY_MAX_TURNS="${VERIFY_MAX_TURNS:-40}"
readonly JUDGE_MAX_TURNS="${JUDGE_MAX_TURNS:-40}"
readonly STAGE_TIMEOUT_S="${STAGE_TIMEOUT_S:-5400}"
readonly MAX_ITERATIONS="${MAX_ITERATIONS:-200}"
readonly NO_PROGRESS_LIMIT="${NO_PROGRESS_LIMIT:-3}"
readonly NO_COMMIT_LIMIT="${NO_COMMIT_LIMIT:-$(( NO_PROGRESS_LIMIT * 2 ))}"
# Runs in a row that may break PROGRESS.md (a task field outside a task) and have it restored and retried.
readonly PROGRESS_REPAIR_LIMIT="${PROGRESS_REPAIR_LIMIT:-2}"
readonly LIMIT_SLEEP_DEFAULT_S="${LIMIT_SLEEP_DEFAULT_S:-1800}"
readonly LIMIT_SLEEP_MAX_S="${LIMIT_SLEEP_MAX_S:-10800}"
readonly LIMIT_NOTIFY_HOURS="${LIMIT_NOTIFY_HOURS:-6}"
readonly ANSWER_WAIT_S="${ANSWER_WAIT_S:-604800}"
readonly MERGE_POLL_S="${MERGE_POLL_S:-600}"
readonly CHECK_POLL_S="${CHECK_POLL_S:-120}"
readonly CI_REOPEN_LIMIT="${CI_REOPEN_LIMIT:-3}"
readonly CI_FIX_ACCEPTANCE="${CI_FIX_ACCEPTANCE:-tools/lint/lint.sh}"
# Run in place of CI when GitHub refuses to start the jobs for billing (bash -c, from the repository root).
readonly LOCAL_GATE="${LOCAL_GATE:-${CI_FIX_ACCEPTANCE}}"
readonly LOCAL_GATE_TIMEOUT_S="${LOCAL_GATE_TIMEOUT_S:-7200}"
readonly DEPENDABOT_MERGE="${DEPENDABOT_MERGE:-squash}"
# Who looks at a red Dependabot pull request first: judge (a judge run triages it) or off (the owner is told).
readonly DEPENDABOT_TRIAGE="${DEPENDABOT_TRIAGE:-judge}"
# The project's services while the loop runs (a staging the owner can open): STAGING_UP starts them
# or brings them up to date with STAGING_PORT_<NAME> set to a free port for every name in
# STAGING_SERVICES; empty means no staging. STAGING_DOWN stops them when the loop exits.
readonly STAGING_UP="${STAGING_UP:-}"
readonly STAGING_DOWN="${STAGING_DOWN:-}"
readonly STAGING_SERVICES="${STAGING_SERVICES:-}"
readonly STAGING_PORT_BASE="${STAGING_PORT_BASE:-42000}"
readonly STAGING_HOST="${STAGING_HOST:-$(hostname 2>/dev/null || echo localhost)}"
readonly STAGING_READY_S="${STAGING_READY_S:-120}"
readonly PR_BODY_MAX_CHARS="${PR_BODY_MAX_CHARS:-60000}"
readonly GIT_REMOTE="${GIT_REMOTE:-origin}"
readonly BASE_BRANCH="${BASE_BRANCH:-main}"
readonly PERMISSION_MODE="${PERMISSION_MODE:-acceptEdits}"
readonly CLAUDE_BIN="${CLAUDE_BIN:-claude}"

once=0
dry_run=0
print_stage=0
for arg in "$@"; do
  case "${arg}" in
    --once) once=1 ;;
    --dry-run) dry_run=1 ;;
    --print-stage) print_stage=1 ;;
    *) echo "unknown argument: ${arg}" >&2; exit 3 ;;
  esac
done

mkdir -p "${LOG_DIR}"
readonly RUN_LOG="${LOG_DIR}/kickoff.log"
readonly JUDGE_LOG="${LOG_DIR}/judge.log"
# The staging's ports ("<name> <port>" lines), the output of STAGING_UP and STAGING_DOWN, and the
# pid (with its start time) of a STAGING_UP that keeps running.
readonly STAGING_PORTS="${LOG_DIR}/staging.ports"
readonly STAGING_LOG="${LOG_DIR}/staging.log"
readonly STAGING_PID="${LOG_DIR}/staging.pid"

#######################################
# Log a line with a UTC timestamp to stdout and the run log.
# Arguments:
#   The message.
#######################################
log() {
  local line
  line="$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"
  echo "${line}"
  echo "${line}" >> "${RUN_LOG}"
}

#######################################
# Send a Telegram message if the token is configured; never fails the loop.
# Arguments:
#   The message text.
#######################################
notify() {
  "${HERE}/telegram.sh" send "$*" || log "telegram: send failed (ignored)"
}

#######################################
# The prompt file of a run: the project's prompts/<name>.md when it exists, else the core's.
# Arguments:
#   The run name (plan, task, verify, judge, dependabot).
#######################################
prompt_file() {
  if [[ -f "${AUTOLOOP_DIR}/prompts/$1.md" ]]; then
    echo "${AUTOLOOP_DIR}/prompts/$1.md"
  elif [[ -f "${HERE}/prompts/$1.md" ]]; then
    echo "${HERE}/prompts/$1.md"
  else
    echo "no prompt for the $1 run: write ${AUTOLOOP_REL}/prompts/$1.md" >&2
    exit 3
  fi
}

#######################################
# Read a header field of PROGRESS.md (STATUS, MILESTONE).
# Arguments:
#   The field name.
#######################################
progress_field() {
  sed -n "s/^$1: *//p" "${PROGRESS}" | head -1 | tr -d '[:space:]'
}

#######################################
# Why a run ended, in one line: the "result" text of its JSON result file with whitespace joined,
# cut to RUN_REASON_CHARS characters. Says so when the file is missing or carries no result.
# Arguments:
#   The result file (may be empty).
#######################################
run_reason() {
  python3 -I - "$1" "${RUN_REASON_CHARS:-700}" <<'PY'
import json, sys
path, limit = sys.argv[1], int(sys.argv[2])
try:
    with open(path, encoding="utf-8") as f:
        text = str(json.load(f).get("result") or "")
except (OSError, ValueError, AttributeError):
    text = ""
text = " ".join(text.split())
if not text:
    print("(no result text in the run's result file)")
elif len(text) > limit:
    print(text[: limit - 1].rstrip() + "…")
else:
    print(text)
PY
}

#######################################
# The id of the next question in QUESTIONS.md: one above the highest "## Q<n>" heading outside a
# code fence (the format example in the file's header is inside one).
#######################################
next_question_id() {
  awk '/^```/ {fence = !fence; next} !fence && /^## Q[0-9]+/ {sub(/^## Q/, ""); sub(/[^0-9].*/, ""); if ($0 + 0 > max) max = $0 + 0} END {print max + 1}' "${QUESTIONS}"
}

#######################################
# Count task lines in a given checkbox state.
# Arguments:
#   The state character inside the brackets: ' ', '~', 'x', '!'.
#######################################
count_tasks() {
  grep -cE "^- \[$1\] T" "${PROGRESS}" || true
}

#######################################
# Find a task field outside a task: before any task, or repeated within one (a lost task heading).
# Only lines of exactly two spaces and "- field:" count; continuation lines and the Log never match.
# Outputs:
#   The first orphan's line number and first 60 characters; nothing when there is none.
#######################################
orphan_field() {
  awk '
    /^## Log/ { exit }
    /^- \[.\] T/ { intask = 1; split("", seen); next }
    /^  - (files|reads|design|acceptance|model|notes|verified):/ {
      name = $0
      sub(/^  - /, "", name)
      sub(/:.*/, "", name)
      if (!intask || (name in seen)) { print NR ": " substr($0, 1, 60); exit }
      seen[name] = 1
    }
  ' "${PROGRESS}"
}

#######################################
# Undo a run's damage to PROGRESS.md: put back the version of the commit before the run and commit it,
# so the same stage runs again. The run's other commits (code, tests) stay; history is not rewritten.
# Arguments:
#   The stage that ran, the commit before it.
# Returns:
#   0 when PROGRESS.md was restored, 1 when it could not be.
#######################################
repair_progress() {
  local stage="$1" before="$2" found
  found="$(orphan_field)"
  git show "${before}:PROGRESS.md" > "${PROGRESS}.restore" 2>/dev/null || { rm -f "${PROGRESS}.restore"; return 1; }
  mv "${PROGRESS}.restore" "${PROGRESS}"
  if ! git diff --quiet -- PROGRESS.md; then
    git add PROGRESS.md \
      && git commit -q -m "autoloop: restore PROGRESS.md, the ${stage} run left a task field outside a task" \
      || return 1
  fi
  log "the ${stage} run left a task field outside a task (${found}); PROGRESS.md restored from ${before:0:7}, ${stage} runs again"
  notify "autoloop: the ${stage} run broke PROGRESS.md (line ${found}); restored it and running ${stage} again."
}

#######################################
# Decide the next stage from PROGRESS.md: plan, task, verify, or a terminal state.
# Outputs:
#   One word on stdout.
#######################################
next_stage() {
  local state open prog done_ reopened
  state="$(progress_field STATUS)"
  case "${state}" in
    BLOCKED) echo "blocked"; return ;;
    MILESTONE_DONE) echo "milestone_done"; return ;;
    RUNNING) ;;
    *) echo "bad_status"; return ;;
  esac
  if [[ -n "$(orphan_field)" ]]; then
    echo "bad_progress"
    return
  fi
  open="$(count_tasks ' ')"
  prog="$(count_tasks '~')"
  done_="$(count_tasks 'x')"
  reopened="$(count_tasks '!')"
  if (( open + prog + done_ + reopened == 0 )); then
    echo "plan"
  elif grep -qE '^- \[x\] T' "${PROGRESS}" && awk '/^- \[x\] T/{t=1; v=0} /^- \[/{if(!/^- \[x\]/){t=0}} t && /^  - verified: *[^ ]/{v=1} t && /^  - verified: *$/{print "unverified"; exit}' "${PROGRESS}" | grep -q unverified; then
    echo "verify"
  elif (( open + prog + reopened > 0 )); then
    echo "task"
  else
    echo "plan"   # everything done and verified: the planning run runs the milestone acceptance
  fi
}

#######################################
# The model for the next task run: the task the implementer will pick (first [~], else first [!],
# else first [ ]) may carry a "model:" line set by the planner (MILESTONES.md "Task format");
# otherwise TASK_MODEL.
# Outputs:
#   The model alias on stdout.
#######################################
task_model() {
  local picked
  picked="$(python3 -I - "${PROGRESS}" <<'PY'
import re
import sys

lines = open(sys.argv[1], encoding="utf-8").read().splitlines()


def first(mark: str):
    for i, line in enumerate(lines):
        if line.startswith(f"- [{mark}] T"):
            return i
    return None


start = next((j for j in (first("~"), first("!"), first(" ")) if j is not None), None)
model = ""
if start is not None:
    for line in lines[start + 1:]:
        if line.startswith("- ["):
            break
        m = re.match(r"\s+- model:\s*(\S+)\s*$", line)
        if m:
            model = m.group(1)
print(model)
PY
)"
  echo "${picked:-${TASK_MODEL}}"
}

#######################################
# Run one claude invocation and classify its outcome.
# Arguments:
#   stage name, model, prompt file, max turns.
# Returns:
#   0 ok, 75 usage limit (sets LIMIT_RESET_EPOCH when known), 1 other error.
#######################################
invoke() {
  local stage="$1" model="$2" prompt_file="$3" max_turns="$4"
  local stamp out_file prompt
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  out_file="${LOG_DIR}/${stamp}-${stage}.json"
  prompt="$(cat "${prompt_file}")"
  # No subagents: they run in the background, and a run that ends its turn to wait for one never hears back.
  local -a cmd=("${CLAUDE_BIN}" -p "${prompt}" --model "${model}" --max-turns "${max_turns}"
    --disallowedTools "Agent,Workflow" --output-format json --permission-mode "${PERMISSION_MODE}")
  if (( dry_run )); then
    log "dry-run ${stage}: ${cmd[*]:0:1} -p <${prompt_file}> --model ${model} --max-turns ${max_turns}"
    return 0
  fi
  log "stage ${stage} (${model}, max ${max_turns} turns) -> ${out_file}"
  local rc=0
  if command -v timeout >/dev/null 2>&1; then
    (cd "${REPO_ROOT}" && timeout "${STAGE_TIMEOUT_S}" "${cmd[@]}" > "${out_file}" 2>> "${RUN_LOG}") || rc=$?
  else
    (cd "${REPO_ROOT}" && "${cmd[@]}" > "${out_file}" 2>> "${RUN_LOG}") || rc=$?
  fi
  if (( rc == 124 )); then
    log "stage ${stage} hit the ${STAGE_TIMEOUT_S}s timeout"
    return 1
  fi
  # Classify from the JSON result (is_error, result text); fall back to rc.
  local verdict
  verdict="$(python3 -I - "${out_file}" <<'PY'
import json, re, sys, pathlib
raw = pathlib.Path(sys.argv[1]).read_text(errors="replace")
try:
    data = json.loads(raw)
    if isinstance(data, list):
        data = next((d for d in reversed(data) if d.get("type") == "result"), data[-1])
    text = str(data.get("result", "")) + " " + str(data.get("error", ""))
    is_error = bool(data.get("is_error"))
except Exception:
    text, is_error = raw, True
low = text.lower()
# Only an error result is classified; a normal summary may mention limits or authentication as its topic.
if not is_error:
    print("OK")
elif re.search(r"(usage limit|hit your \S*\s*limit|rate limit|limit reached|too many requests|overloaded)", low):
    # The reset time: an epoch after "|" (older wording) or "resets 5:20pm (UTC)" (current wording, a clock
    # time within the next 24 h). Anything else is 0: the wait falls back to the doubling default.
    import datetime as dt
    epoch = "0"
    m = re.search(r"\|(\d{10})", text)
    if m:
        epoch = m.group(1)
    else:
        m = re.search(r"resets\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)\s*\(utc\)", low)
        if m:
            hour = int(m.group(1)) % 12 + (12 if m.group(3) == "pm" else 0)
            now = dt.datetime.now(dt.timezone.utc)
            reset = now.replace(hour=hour, minute=int(m.group(2) or 0), second=0, microsecond=0)
            if reset <= now:
                reset += dt.timedelta(days=1)
            epoch = str(int(reset.timestamp()))
    print("LIMIT " + epoch)
elif re.search(r"(not logged in|invalid api key|authentication_error|please run /login|run claude login|401 unauthorized)", low):
    print("AUTH")
else:
    print("ERROR " + text[:200].replace("\n", " "))
PY
)"
  case "${verdict}" in
    OK) return 0 ;;
    LIMIT*) LIMIT_RESET_EPOCH="${verdict#LIMIT }"; return 75 ;;
    AUTH) log "claude is not authenticated on this machine; run 'claude' once and log in"; notify "autoloop: claude not authenticated, stopped"; exit 3 ;;
    *) log "stage ${stage} error (rc=${rc}): ${verdict}"; return 1 ;;
  esac
}

#######################################
# Sleep until the usage limit resets (or a default, doubling), notify when long.
#######################################
wait_for_limit() {
  local now sleep_s
  now="$(date -u +%s)"
  if [[ "${LIMIT_RESET_EPOCH:-0}" =~ ^[0-9]{10}$ ]] && (( LIMIT_RESET_EPOCH > now )); then
    sleep_s=$(( LIMIT_RESET_EPOCH - now + 60 ))
  else
    sleep_s="${limit_backoff_s}"
    limit_backoff_s=$(( limit_backoff_s * 2 ))
    (( limit_backoff_s > LIMIT_SLEEP_MAX_S )) && limit_backoff_s="${LIMIT_SLEEP_MAX_S}"
  fi
  log "usage limit: sleeping ${sleep_s}s"
  if (( sleep_s > LIMIT_NOTIFY_HOURS * 3600 )); then
    notify "autoloop: usage limit, reset in $(( sleep_s / 3600 )) h; exiting (weekly cap?). Restart kickoff.sh later."
    exit 4
  fi
  sleep "${sleep_s}"
}

#######################################
# The judge run: a strong model answers the open questions that the project's documents settle and
# passes the rest to the owner (a "Judge:" line under the question). Runs once per set of unjudged
# questions; the answers and the passes are appended to log/judge.log (qa.py judged), which the
# hourly status report reads.
# Returns:
#   0 every question answered (STATUS RUNNING), 1 questions remain for the owner, 2 usage limit
#   (waited; the caller loops), 3 nothing for the judge.
#######################################
judge_questions() {
  local before_open before_unjudged rc=0 summary
  before_open="$(python3 -I "${HERE}/qa.py" list --ids)"
  before_unjudged="$(python3 -I "${HERE}/qa.py" list --ids --unjudged)"
  if [[ -z "${before_unjudged}" ]]; then
    return 3
  fi
  log "judge run on Q${before_unjudged// /, Q}"
  invoke judge "${JUDGE_MODEL}" "$(prompt_file judge)" "${JUDGE_MAX_TURNS}" || rc=$?
  iteration=$(( iteration + 1 ))
  if (( rc == 75 )); then
    wait_for_limit
    return 2
  fi
  if (( dry_run )); then
    return 1
  fi
  summary="$(python3 -I "${HERE}/qa.py" judged --before-open "${before_open}" --before-unjudged "${before_unjudged}" --log "${JUDGE_LOG}")" || {
    log "judge run changed nothing; the owner is asked"
    return 1
  }
  log "judge: ${summary//$'\n'/; }"
  notify "autoloop: judge on $(progress_field MILESTONE): ${summary}"
  if [[ "$(progress_field STATUS)" == "RUNNING" ]]; then
    return 0
  fi
  return 1
}

#######################################
# The heading text of a milestone in MILESTONES.md ("M0: dev stack and bootstrap").
# Arguments:
#   The milestone id (M0).
#######################################
milestone_title() {
  sed -n "s/^## $1: *//p" "${REPO_ROOT}/MILESTONES.md" | head -1
}

#######################################
# The milestone after the given one, by the order of MILESTONES.md; empty when none.
# Arguments:
#   The milestone id.
#######################################
next_milestone() {
  grep -oE '^## M[0-9]+:' "${REPO_ROOT}/MILESTONES.md" | grep -oE 'M[0-9]+' | awk -v cur="$1" 'found {print; exit} $0 == cur {found = 1}'
}

#######################################
# Write the pull request body for the current milestone to the file given: the tasks done and the log.
# GitHub takes at most 65536 characters in a body, so the log is cut to fit when a budget is given
# (the archive keeps the whole PROGRESS.md).
# Arguments:
#   The output path, then the character budget (optional; no cut when absent).
#######################################
write_pr_body() {
  local milestone budget="${2:-0}"
  milestone="$(progress_field MILESTONE)"
  write_pr_body_full "$1"
  if (( budget > 0 )) && (( $(wc -c < "$1") > budget )); then
    python3 -I - "$1" "${budget}" "${AUTOLOOP_REL}/archive/${milestone}/PROGRESS.md" <<'PY'
import pathlib
import sys

path, budget, archive = pathlib.Path(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
note = f"\n\n(The log is cut here to fit the pull request; the whole of it is in {archive}.)\n"
text = path.read_text(encoding="utf-8")
keep = text[: budget - len(note)]
keep = keep[: keep.rfind("\n")] if "\n" in keep else keep
path.write_text(keep + note, encoding="utf-8")
PY
  fi
}

#######################################
# The whole pull request body: the tasks done and the log, no cut.
# Arguments:
#   The output path.
#######################################
write_pr_body_full() {
  local milestone
  milestone="$(progress_field MILESTONE)"
  {
    echo "Milestone ${milestone}: $(milestone_title "${milestone}")"
    echo
    echo "Built by the autonomous loop (${AUTOLOOP_REL}); every task was implemented by one run and verified by another."
    echo "Done when: see MILESTONES.md \"${milestone}\"; the acceptance ran in the last planning run (log below)."
    echo
    echo "## Tasks"
    grep -E '^- \[x\] T' "${PROGRESS}" | sed 's/^- \[x\] /- /'
    echo
    echo "## Log"
    sed -n '/^## Log/,$p' "${PROGRESS}" | tail -n +2
    echo
    echo "🤖 Generated with [Claude Code](https://claude.com/claude-code)"
  } > "$1"
}

#######################################
# The HISTORY.md entry of a finished milestone, wrapped at 80 columns with a two-space continuation indent.
# The bold prefix stays whole on the first line, and no continuation line starts with a word that Markdown
# would read as markup (a list marker, heading, quote or table): the previous word moves down with it.
# Arguments:
#   The date, the milestone id, the title and the archive path.
#######################################
history_line() {
  python3 -I - "$@" <<'PY'
import re
import sys

date, milestone, title, path = sys.argv[1:5]
prefix = f"- **{date}, milestone {milestone} done.**"
words = [prefix] + f"{title} ({path}).".split()
markup = re.compile(r"^([-+*#>|<=~`]|\d+[.)])")
lines = [[words[0]]]
for word in words[1:]:
    if len(("  " if len(lines) > 1 else "") + " ".join(lines[-1] + [word])) <= 80:
        lines[-1].append(word)
        continue
    new = [word]
    moved = []
    while markup.match(new[0]) and len(lines[-1]) > 1:
        moved.append(lines[-1].pop())
        new.insert(0, moved[-1])
    if len("  " + " ".join(new)) > 80 or markup.match(new[0]):
        lines[-1].extend(reversed(moved))
        new = [word]
    lines.append(new)
out = []
for number, line in enumerate(lines):
    out.append(("  " if number else "") + " ".join(line))
print("\n".join(out))
PY
}

#######################################
# Archive the working files of the finished milestone under archive/<milestone>/ of the project's
# autoloop directory, add the milestone's line to HISTORY.md, and commit on the milestone branch
# (so it is in its pull request). Idempotent: a second call with nothing new to archive commits nothing.
#######################################
archive_milestone() {
  local milestone dir latest_plan
  milestone="$(progress_field MILESTONE)"
  dir="${ARCHIVE_ROOT}/${milestone}"
  mkdir -p "${dir}"
  cp "${PROGRESS}" "${dir}/PROGRESS.md"
  cp "${QUESTIONS}" "${dir}/QUESTIONS.md"
  write_pr_body "${dir}/PULL_REQUEST.md"
  latest_plan="$(ls -t "${LOG_DIR}"/*-plan.json 2>/dev/null | head -1)"
  if [[ -n "${latest_plan}" ]]; then
    python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("result",""))' "${latest_plan}" \
      > "${dir}/ACCEPTANCE.md" 2>/dev/null || true
  fi
  if ! grep -q "milestone ${milestone} done" "${REPO_ROOT}/HISTORY.md"; then
    if [[ -s "${REPO_ROOT}/HISTORY.md" && -n "$(tail -c 1 "${REPO_ROOT}/HISTORY.md")" ]]; then
      echo >> "${REPO_ROOT}/HISTORY.md"
    fi
    history_line "$(date -u +%F)" "${milestone}" "$(milestone_title "${milestone}")" \
      "${AUTOLOOP_REL}/archive/${milestone}" >> "${REPO_ROOT}/HISTORY.md"
  fi
  git add "${AUTOLOOP_REL}/archive/${milestone}" HISTORY.md
  git diff --cached --quiet || git commit -q -m "Archive ${milestone}: working files, pull request body, acceptance"
}

#######################################
# Write a fresh PROGRESS.md for a milestone (header, format note, empty task list, one log line).
# Arguments:
#   The milestone id.
#######################################
write_fresh_progress() {
  {
    echo "STATUS: RUNNING"
    echo "MILESTONE: $1"
    echo "UPDATED: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo
    echo "Format and states: MILESTONES.md \"Task format in PROGRESS.md\". The first"
    echo "three lines are read by \`${AUTOLOOP_REL}/kickoff.sh\`; keep them exactly in"
    echo "this shape. The planning run fills \"Tasks\"; the implementer and the"
    echo "verifier edit only the entry they work on and append to \"Log\". Earlier"
    echo "milestones are under ${AUTOLOOP_REL}/archive/."
    echo
    echo "## Tasks ($1)"
    echo
    echo "(none yet: the planning run writes them)"
    echo
    echo "## Log"
    echo
    echo "- $(date -u +%F) $1 started on branch autoloop/$1 after the previous milestone's pull request was merged."
  } > "${PROGRESS}"
}

#######################################
# Write a fresh QUESTIONS.md: the header and format, no questions.
#######################################
write_fresh_questions() {
  # Everything before the first question heading outside a code fence is the file's header and format
  # (the format example inside the fence stays); the header ends with "(no open questions)".
  awk '/^```/ {fence = !fence} !fence && /^## Q/ {exit} {print}' "${QUESTIONS}" > "${QUESTIONS}.tmp"
  grep -q '^(no open questions)' "${QUESTIONS}.tmp" || echo "(no open questions)" >> "${QUESTIONS}.tmp"
  mv "${QUESTIONS}.tmp" "${QUESTIONS}"
}

#######################################
# Push the milestone branch and open (or reuse) its pull request; print the PR URL.
#######################################
open_pr() {
  local branch milestone body url
  branch="$(git rev-parse --abbrev-ref HEAD)"
  milestone="$(progress_field MILESTONE)"
  git push -u "${GIT_REMOTE}" "${branch}" >> "${RUN_LOG}" 2>&1 || { log "push of ${branch} failed"; return 1; }
  url="$(gh pr view "${branch}" --json url --jq .url 2>/dev/null || true)"
  if [[ -z "${url}" ]]; then
    body="${LOG_DIR}/pr-${milestone}.md"
    write_pr_body "${body}" "${PR_BODY_MAX_CHARS}"
    url="$(gh pr create --base "${BASE_BRANCH}" --head "${branch}" \
      --title "${milestone}: $(milestone_title "${milestone}")" --body-file "${body}" 2>> "${RUN_LOG}")" || { log "gh pr create failed"; return 1; }
  fi
  echo "${url}"
}

#######################################
# The warning and failure annotations of a workflow run's jobs, one per line; notices are left out.
# Arguments:
#   The run id.
#######################################
run_annotations() {
  local job
  for job in $(gh api "repos/{owner}/{repo}/actions/runs/$1/jobs" --jq '.jobs[].id' 2>/dev/null); do
    gh api --paginate "repos/{owner}/{repo}/check-runs/${job}/annotations" \
      --jq '.[] | select(.annotation_level != "notice") | "\(.annotation_level): \(.path):\(.start_line) \(.message)"' \
      2>/dev/null || true
  done
}

#######################################
# A green run with warning annotations is considered, not waved through. The first time a set of
# annotations is seen in a milestone it is saved under log/ci-annotations-<sha>.txt, STATUS goes
# back to RUNNING with a Log line naming the file, and PROGRESS.md is committed: the planning run
# reads the file and writes a task for each warning it can resolve within the documents, a question
# in QUESTIONS.md for one it cannot, and a Log line for one that needs nothing. The same set seen
# again in the milestone passes.
# Arguments:
#   Where the run was seen ("the branch" or "the pull request"), then the run ids.
# Returns:
#   0 nothing new, 1 MILESTONE_DONE withdrawn.
#######################################
consider_annotations() {
  local where="$1" sha milestone lines digest seen file stamp count id
  shift
  sha="$(git rev-parse HEAD)"
  milestone="$(progress_field MILESTONE)"
  lines="$(for id in "$@"; do run_annotations "${id}"; done | sort -u)"
  if [[ -z "${lines}" ]]; then
    return 0
  fi
  digest="$(printf '%s\n' "${lines}" | sha256sum | cut -c1-16)"
  seen="${LOG_DIR}/ci-annotations-seen"
  if [[ -f "${seen}" ]] && grep -qx "${milestone} ${digest}" "${seen}"; then
    log "CI annotations on ${sha:0:7} were already considered in ${milestone} (${digest})"
    return 0
  fi
  file="${LOG_DIR}/ci-annotations-${sha:0:7}.txt"
  printf '%s\n' "${lines}" > "${file}"
  echo "${milestone} ${digest}" >> "${seen}"
  count="$(wc -l < "${file}")"
  stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  sed -i.bak -e '1s/^STATUS: .*/STATUS: RUNNING/' -e "s/^UPDATED: .*/UPDATED: ${stamp}/" "${PROGRESS}" && rm -f "${PROGRESS}.bak"
  printf -- '- %s wrapper: CI green on %s (%s, runs %s) with %s warning annotation(s), listed in %s/log/ci-annotations-%s.txt; MILESTONE_DONE withdrawn so the planning run considers them: a task for each it can resolve within the documents, a question in QUESTIONS.md for one it cannot, a Log line for one that needs nothing. First: %s\n' \
    "${stamp}" "${where}" "${sha:0:7}" "$*" "${count}" "${AUTOLOOP_REL}" "${sha:0:7}" "$(head -1 "${file}" | cut -c1-200)" >> "${PROGRESS}"
  git add PROGRESS.md
  git commit -q -m "Reopen ${milestone}: ${count} CI annotation(s) on ${sha:0:7} to consider"
  log "CI green on ${where} at ${sha:0:7} with ${count} annotation(s); ${milestone} reopened to consider them (${file})"
  return 1
}

#######################################
# True when every failing check is a job GitHub refused to start for billing (a failed payment or
# the spending limit): no step ran, so the check says nothing about the code.
# Arguments:
#   The failing check lines from gh, "<bucket> <name> <link>".
#######################################
billing_refused() {
  local ids id
  ids="$(grep -oE 'runs/[0-9]+' <<< "$1" | cut -d/ -f2 | sort -u)"
  [[ -n "${ids}" ]] || return 1
  for id in ${ids}; do
    run_annotations "${id}" | grep -qiE 'account payments have failed|spending limit' || return 1
  done
}

#######################################
# Merge the base branch into the current (milestone) branch after something landed on it, so the
# runs build against it and the milestone's pull request stays mergeable. The caller pushes when
# the branch has a pull request. A conflict is the owner's: the merge is aborted and told.
# Arguments:
#   What landed on the base branch, for the merge commit's message.
# Returns:
#   0 merged or nothing to merge, 1 the fetch or the merge failed.
#######################################
merge_base_branch() {
  local branch
  branch="$(git rev-parse --abbrev-ref HEAD)"
  git fetch -q "${GIT_REMOTE}" "${BASE_BRANCH}" >> "${RUN_LOG}" 2>&1 || { log "fetch of ${BASE_BRANCH} failed"; return 1; }
  if git merge-base --is-ancestor "${GIT_REMOTE}/${BASE_BRANCH}" HEAD; then
    return 0
  fi
  if git merge -q --no-edit -m "Merge ${BASE_BRANCH} into ${branch}: $1" "${GIT_REMOTE}/${BASE_BRANCH}" >> "${RUN_LOG}" 2>&1; then
    log "merged ${BASE_BRANCH} into ${branch} ($1)"
    return 0
  fi
  git merge --abort >> "${RUN_LOG}" 2>&1 || true
  log "merge of ${BASE_BRANCH} into ${branch} failed after $1; left for the owner"
  notify "autoloop: ${BASE_BRANCH} does not merge cleanly into ${branch} after $1; merge it by hand before the milestone's pull request."
  return 1
}

#######################################
# Tell the owner about a Dependabot pull request once per head commit and state; the pairs told
# are kept in log/dependabot-seen.
# Arguments:
#   The pull request number, its head sha, the state (red, billing, rerun, green, unmerged), the message.
#######################################
dependabot_tell() {
  local seen="${LOG_DIR}/dependabot-seen" key="$1 $2 $3"
  if ! grep -qxF "${key}" "${seen}" 2>/dev/null; then
    echo "${key}" >> "${seen}"
    log "Dependabot #$1 at ${2:0:7} is $3"
    notify "autoloop: $4"
  fi
}

#######################################
# The judge's triage of a red Dependabot pull request. The wrapper saves the failed jobs' log and
# the pull request's diff under log/ (dependabot-<number>-<sha>.log and .diff); the judge run
# (JUDGE_MODEL, prompts/dependabot.md with the pull request's facts appended) reads them, changes
# nothing and ends with a "VERDICT:" and a "REASON:" line, which are read from its result file.
# Arguments:
#   The pull request number, its head sha, its title, its url, the failing check lines.
# Outputs:
#   "<verdict> <reason>" on stdout: the verdict is flaky, break or unsure, the reason one line.
# Returns:
#   0 a verdict, 1 none (the run failed or named no verdict), 2 usage limit (ask again later).
#######################################
dependabot_triage() {
  local number="$1" sha="$2" title="$3" url="$4" failing="$5"
  local base="${LOG_DIR}/dependabot-${number}-${sha:0:7}" prompt ids id rc=0 result
  prompt="$(prompt_file dependabot)" || return 1
  : > "${base}.log"
  ids="$(grep -oE 'runs/[0-9]+' <<< "${failing}" | cut -d/ -f2 | sort -u)"
  for id in ${ids}; do
    { echo "# run ${id}"; gh run view "${id}" --log-failed 2>&1 || true; } >> "${base}.log"
  done
  gh pr diff "${number}" > "${base}.diff" 2>> "${RUN_LOG}" || true
  {
    cat "${prompt}"
    printf '\nThe pull request: #%s, "%s", %s, head commit %s, against %s.\nIts failed checks, one per line as "<state> <name> <link>":\n%s\nThe log of the failed jobs: %s\nThe diff: %s\n' \
      "${number}" "${title}" "${url}" "${sha}" "${BASE_BRANCH}" "${failing}" "${base}.log" "${base}.diff"
  } > "${base}.prompt.md"
  # In a subshell: a claude that is not logged in ends this triage, not the wait this may be called from.
  ( invoke dependabot "${JUDGE_MODEL}" "${base}.prompt.md" "${JUDGE_MAX_TURNS}" ) >&2 || rc=$?
  if (( rc == 75 )); then
    return 2
  fi
  (( rc == 0 )) || return 1
  # The newest result file; the names are timestamps.
  # shellcheck disable=SC2012
  result="$(ls -t "${LOG_DIR}"/*-dependabot.json 2>/dev/null | head -1)"
  python3 -I - "${result}" <<'PY'
import json, re, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        data = json.load(f)
    if isinstance(data, list):
        data = next((d for d in reversed(data) if d.get("type") == "result"), data[-1])
    text = str(data.get("result") or "")
except (OSError, ValueError, AttributeError, IndexError):
    text = ""
verdicts = re.findall(r"(?mi)^\W*VERDICT:\W*(flaky|break|unsure)\b", text)
if not verdicts:
    sys.exit(1)
reasons = re.findall(r"(?mi)^\W*REASON:\W*(.+)$", text)
reason = " ".join(reasons[-1].split()) if reasons else ""
if len(reason) > 300:
    reason = reason[:299].rstrip() + "…"
print(verdicts[-1].lower(), reason or "(no reason given)")
PY
}

#######################################
# A red Dependabot pull request, looked at once per head commit. Checks GitHub refused to start
# for billing say nothing about the update and are told as such. Otherwise the judge triages it
# (DEPENDABOT_TRIAGE=judge): "flaky" runs the failed jobs again, once per head commit, and the next
# looks merge it when green or tell the owner when red again; "break" and "unsure" are told to the
# owner with the judge's reason. Without a verdict (DEPENDABOT_TRIAGE=off, a failed run) the owner
# is told the check failed. Never merged while red. Verdicts are appended to log/judge.log for the
# hourly status report.
# Arguments:
#   The pull request number, its head sha, its title, its url, the failing check lines.
#######################################
dependabot_red() {
  local number="$1" sha="$2" title="$3" url="$4" failing="$5"
  local seen="${LOG_DIR}/dependabot-seen" what names line="" verdict="" reason="" ids id rc=0 reran=1
  what="Dependabot pull request #${number} (${title})"
  names="$(awk '{print $2}' <<< "${failing}" | paste -sd, -)"
  if grep -qxF -e "${number} ${sha} red" -e "${number} ${sha} billing" "${seen}" 2>/dev/null; then
    return 0
  fi
  if grep -qxF "${number} ${sha} rerun" "${seen}" 2>/dev/null; then
    dependabot_tell "${number}" "${sha}" red \
      "${what} is RED again after its failed jobs ran a second time: check ${names} failed on ${sha:0:7}. The judge had called the first failure flaky; it is left to you. ${url}"
    return 0
  fi
  if billing_refused "${failing}"; then
    dependabot_tell "${number}" "${sha}" billing \
      "GitHub did not start check ${names} on ${what} (billing or spending limit), so nothing is known about ${sha:0:7}; it is left to you. ${url}"
    return 0
  fi
  if [[ "${DEPENDABOT_TRIAGE}" == "judge" ]]; then
    log "judge run on the red Dependabot #${number} at ${sha:0:7} (${names})"
    line="$(dependabot_triage "${number}" "${sha}" "${title}" "${url}" "${failing}")" || rc=$?
    if (( rc == 2 )); then
      log "usage limit: the triage of Dependabot #${number} waits for the next look"
      return 0
    fi
    if (( rc == 0 )); then
      verdict="${line%% *}"
      reason="${line#* }"
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) Dependabot #${number} at ${sha:0:7} judged ${verdict}: ${reason}" >> "${JUDGE_LOG}"
    fi
  fi
  case "${verdict}" in
    flaky)
      ids="$(grep -oE 'runs/[0-9]+' <<< "${failing}" | cut -d/ -f2 | sort -u)"
      for id in ${ids}; do
        gh run rerun "${id}" --failed >> "${RUN_LOG}" 2>&1 || reran=0
      done
      if (( reran )); then
        dependabot_tell "${number}" "${sha}" rerun \
          "${what} is red on ${sha:0:7} (check ${names}) and the judge calls it flaky: ${reason} Its failed jobs run again once: green is merged, red again is told to you. ${url}"
      else
        dependabot_tell "${number}" "${sha}" red \
          "${what} is RED: check ${names} failed on ${sha:0:7}. The judge calls it flaky: ${reason} The failed jobs could not be started again (see kickoff.log); it is left to you. ${url}"
      fi ;;
    break)
      dependabot_tell "${number}" "${sha}" red \
        "${what} is RED: check ${names} failed on ${sha:0:7}. The judge: the update breaks the build: ${reason} It is left to you. ${url}" ;;
    unsure)
      dependabot_tell "${number}" "${sha}" red \
        "${what} is RED: check ${names} failed on ${sha:0:7}. The judge could not tell a flaky check from a broken update: ${reason} It is left to you. ${url}" ;;
    *)
      if [[ "${DEPENDABOT_TRIAGE}" == "judge" ]]; then
        reason=" the judge run gave no verdict;"
      fi
      dependabot_tell "${number}" "${sha}" red \
        "${what} is RED: check ${names} failed on ${sha:0:7};${reason} it is left to you. ${url}" ;;
  esac
}

#######################################
# Look at the open Dependabot pull requests against the base branch. A green, mergeable one is
# merged with the DEPENDABOT_MERGE method (only while its head is still the commit whose checks
# were read) and the base branch is then merged into the milestone branch; a red one is triaged
# once per head commit (dependabot_red) and never merged; one still being checked, one that conflicts
# (Dependabot rebases it itself) and one with a review asking for changes wait for the next look.
# DEPENDABOT_MERGE=report tells the owner about a green one instead of merging it; ignore looks
# at nothing. Never fails the loop; gh missing or failing means nothing to look at.
#######################################
check_dependabot_prs() {
  local -a prs
  local line number sha mergeable review draft url title checks failing
  [[ "${DEPENDABOT_MERGE}" != "ignore" ]] || return 0
  command -v gh >/dev/null 2>&1 || return 0
  mapfile -t prs < <(gh pr list --app dependabot --state open --base "${BASE_BRANCH}" --limit 50 \
    --json number,headRefOid,mergeable,reviewDecision,isDraft,url,title \
    --jq '.[] | [.number, .headRefOid, .mergeable, .reviewDecision, .isDraft, .url, .title] | map(tostring) | join("|")' \
    2>/dev/null)
  (( ${#prs[@]} )) || return 0
  for line in "${prs[@]}"; do
    IFS='|' read -r number sha mergeable review draft url title <<< "${line}"
    [[ "${number}" =~ ^[0-9]+$ && "${draft}" != "true" ]] || continue
    checks="$(gh pr checks "${number}" --json name,bucket,link --jq '.[] | "\(.bucket) \(.name) \(.link)"' 2>/dev/null || true)"
    failing="$(grep -E '^(fail|cancel) ' <<< "${checks}" || true)"
    if [[ -n "${failing}" ]]; then
      dependabot_red "${number}" "${sha}" "${title}" "${url}" "${failing}"
      continue
    fi
    if [[ -z "${checks}" ]] || grep -qE '^pending ' <<< "${checks}"; then
      continue
    fi
    if [[ "${mergeable}" != "MERGEABLE" || "${review}" == "CHANGES_REQUESTED" ]]; then
      continue
    fi
    if [[ "${DEPENDABOT_MERGE}" == "report" ]]; then
      dependabot_tell "${number}" "${sha}" green \
        "Dependabot pull request #${number} (${title}) is green and mergeable; DEPENDABOT_MERGE=report, so the merge is yours. ${url}"
      continue
    fi
    if gh pr merge "${number}" "--${DEPENDABOT_MERGE}" --delete-branch --match-head-commit "${sha}" >> "${RUN_LOG}" 2>&1; then
      log "merged Dependabot #${number} (${title}) into ${BASE_BRANCH}"
      notify "autoloop: merged Dependabot pull request #${number} (${title}) into ${BASE_BRANCH}: its checks were green. ${url}"
      merge_base_branch "Dependabot #${number} ${title}" || true
    else
      dependabot_tell "${number}" "${sha}" unmerged \
        "could not merge the green Dependabot pull request #${number} (${title}): gh pr merge failed (a required review, the merge method, or a new commit); see kickoff.log. The merge is yours. ${url}"
    fi
  done
}

#######################################
# The local stand-in for CI: runs LOCAL_GATE from the repository root, its output saved under log/.
# Outputs:
#   The log file.
# Returns:
#   The gate's exit status.
#######################################
run_local_gate() {
  local file rc=0
  file="${LOG_DIR}/local-gate-$(git rev-parse --short HEAD).log"
  { echo "# local gate: ${LOCAL_GATE}"; timeout "${LOCAL_GATE_TIMEOUT_S:-7200}" bash -c "${LOCAL_GATE}"; } > "${file}" 2>&1 || rc=$?
  echo "${file}"
  return "${rc}"
}

#######################################
# The staging: the project's services, up next to the loop so that the owner can open what it
# builds. STAGING_UP (autoloop.env) starts them or brings them up to date; it runs when the loop
# starts and again after every commit, with STAGING_PORT_<NAME> set for every name in
# STAGING_SERVICES.
#######################################

#######################################
# The environment variable that carries a service's port: STAGING_PORT_<NAME>, the name in upper
# case with every character that is not a letter or a digit as "_" (my-api: STAGING_PORT_MY_API).
# Arguments:
#   The service name.
#######################################
staging_var() {
  local name="${1^^}"
  echo "STAGING_PORT_${name//[^A-Z0-9]/_}"
}

#######################################
# Give every service a free port and export it as STAGING_PORT_<NAME>: the port recorded in
# log/staging.ports when it is still free, else the first free one at or above STAGING_PORT_BASE
# that no other service got. The file is written again, so the ports stay the same across runs
# and restarts of the loop while nothing else takes them. No free port is a setup error.
#######################################
staging_allocate() {
  local name port
  # shellcheck disable=SC2086
  python3 -I - "${STAGING_PORTS}" "${STAGING_PORT_BASE}" ${STAGING_SERVICES} > "${STAGING_PORTS}.tmp" <<'PY' \
    || { log "staging: no free port for every service at or above ${STAGING_PORT_BASE}"; exit 3; }
import socket
import sys

path, base, names = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
recorded = {}
try:
    with open(path, encoding="utf-8") as f:
        for line in f:
            parts = line.split()
            if len(parts) == 2 and parts[1].isdigit():
                recorded[parts[0]] = int(parts[1])
except OSError:
    pass


def free(port: int) -> bool:
    # Taken when something listens on it; a connection of an earlier service still closing does not count.
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            s.bind(("", port))
        except OSError:
            return False
    return True


taken = set()
candidate = base
for name in names:
    port = recorded.get(name)
    if port is None or port in taken or not free(port):
        while candidate in taken or not free(candidate):
            candidate += 1
            if candidate > 65535:
                sys.exit(f"no free port at or above {base}")
        port = candidate
    taken.add(port)
    print(name, port)
PY
  mv "${STAGING_PORTS}.tmp" "${STAGING_PORTS}"
  while read -r name port; do
    export "$(staging_var "${name}")=${port}"
  done < "${STAGING_PORTS}"
}

#######################################
# The services that do not accept a TCP connection on loopback within a second, one name per line.
#######################################
staging_unready() {
  python3 -I - "${STAGING_PORTS}" <<'PY'
import socket
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    for line in f:
        name, port = line.split()
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.settimeout(1)
            try:
                s.connect(("127.0.0.1", int(port)))
            except OSError:
                print(name)
PY
}

#######################################
# The services as told to the owner: "<name> http://<STAGING_HOST>:<port>" each, joined by ", ",
# with "(not answering)" after the ones named in the argument.
# Arguments:
#   The names that do not answer, one per line (may be empty).
#######################################
staging_urls() {
  local name port mark out=""
  while read -r name port; do
    mark=""
    grep -qx "${name}" <<< "$1" && mark=" (not answering)"
    out+="${out:+, }${name} http://${STAGING_HOST}:${port}${mark}"
  done < "${STAGING_PORTS}"
  echo "${out:-no service declared}"
}

#######################################
# When a process started, as /proc or ps report it; empty for one that is gone. With the pid it
# tells the process the wrapper started from another one that got the same pid after it ended.
# Arguments:
#   The pid.
#######################################
process_start() {
  { sed 's/^[^)]*) //' "/proc/$1/stat" 2>/dev/null | awk '{print $20}'; } || ps -o lstart= -p "$1" 2>/dev/null || true
}

#######################################
# Stop the STAGING_UP of the last call when it still runs (it is the service, a dev server): TERM
# to its process group, KILL after ten seconds. The pid file names the process and when it
# started; a pid that now belongs to another process is only forgotten.
#######################################
staging_kill_up() {
  local pid started i
  read -r pid started < "${STAGING_PID}" 2>/dev/null || return 0
  rm -f "${STAGING_PID}"
  [[ "${pid}" =~ ^[0-9]+$ ]] && kill -0 "${pid}" 2>/dev/null || return 0
  [[ "$(process_start "${pid}")" == "${started:-}" ]] || return 0
  kill -TERM -- "-${pid}" 2>/dev/null || kill -TERM "${pid}" 2>/dev/null || true
  for i in {1..10}; do
    kill -0 "${pid}" 2>/dev/null || return 0
    sleep 1
  done
  kill -KILL -- "-${pid}" 2>/dev/null || kill -KILL "${pid}" 2>/dev/null || true
}

#######################################
# Start the services, or bring them up to date with HEAD. A STAGING_UP of the last call that still
# runs is stopped first. STAGING_UP runs in the background from the repository root, in a session
# of its own so that it can be stopped with everything it started, with the ports in its
# environment and its output appended to log/staging.log; the wrapper then waits until every
# service answers on its port, STAGING_UP fails, or STAGING_READY_S seconds have passed. A
# STAGING_UP that returns (docker compose up -d) has detached the services; one that keeps
# running (a dev server) is left running until the next call or the exit.
# Globals:
#   staging_head: the commit staged. staging_state: the services with their URLs, the ones that
#   do not answer marked, after what went wrong when STAGING_UP failed.
# Returns:
#   0 every service answers, 1 some do not or STAGING_UP failed.
#######################################
staging_up() {
  local pid rc=0 waited=0 unready="" setsid=""
  staging_kill_up
  staging_head="$(git rev-parse HEAD)"
  echo "# $(date -u +%Y-%m-%dT%H:%M:%SZ) up at ${staging_head:0:7}: ${STAGING_UP}" >> "${STAGING_LOG}"
  command -v setsid >/dev/null 2>&1 && setsid=setsid
  # shellcheck disable=SC2086
  (cd "${REPO_ROOT}" && exec ${setsid} bash -c "${STAGING_UP}") >> "${STAGING_LOG}" 2>&1 < /dev/null &
  pid=$!
  echo "${pid} $(process_start "${pid}")" > "${STAGING_PID}"
  while true; do
    if [[ -n "${pid}" ]] && ! kill -0 "${pid}" 2>/dev/null; then
      wait "${pid}" || rc=$?
      pid=""
      rm -f "${STAGING_PID}"
      (( rc == 0 )) || break
    fi
    unready="$(staging_unready)"
    [[ -n "${unready}" ]] || break
    (( waited < STAGING_READY_S )) || break
    sleep 1
    waited=$(( waited + 1 ))
  done
  (( rc == 0 )) || unready="$(staging_unready)"
  staging_state="$(staging_urls "${unready}")"
  if (( rc != 0 )); then
    staging_state="STAGING_UP exited ${rc} ($(tail -1 "${STAGING_LOG}" | cut -c1-200)); ${staging_state}"
    return 1
  fi
  [[ -z "${unready}" ]]
}

#######################################
# Bring the staging up when the loop starts, for a project with STAGING_UP: STAGING_DOWN first,
# when set, so that services of an earlier loop are gone and their ports free; then the ports,
# STAGING_UP, and the owner gets the URLs. The staging is stopped when the loop exits.
#######################################
staging_start() {
  [[ -n "${STAGING_UP}" ]] || return 0
  if (( dry_run )); then
    log "dry-run: would start the staging (${STAGING_UP}) for ${STAGING_SERVICES:-no declared service}"
    return 0
  fi
  trap staging_stop EXIT
  staging_down
  staging_allocate
  staging_up || true
  staging_told="${staging_state}"
  log "staging at ${staging_head:0:7}: ${staging_state}"
  notify "autoloop: staging for $(progress_field MILESTONE) at ${staging_head:0:7}: ${staging_state}. It follows every commit; the services' output is in ${AUTOLOOP_REL}/log/staging.log."
}

#######################################
# After a commit: STAGING_UP again, so that the staging shows HEAD. The owner hears of it when the
# state changed since the last message (a service stopped answering or answers again, STAGING_UP
# failed), not on every commit; every refresh is a line in kickoff.log.
#######################################
staging_sync() {
  [[ -n "${staging_head:-}" && "$(git rev-parse HEAD)" != "${staging_head}" ]] || return 0
  staging_up || true
  log "staging refreshed at ${staging_head:0:7}: ${staging_state}"
  if [[ "${staging_state}" != "${staging_told}" ]]; then
    staging_told="${staging_state}"
    notify "autoloop: staging at ${staging_head:0:7}: ${staging_state}."
  fi
}

#######################################
# STAGING_DOWN, when set, from the repository root with its output in log/staging.log; a failure
# is logged, never fatal.
#######################################
staging_down() {
  [[ -n "${STAGING_DOWN}" ]] || return 0
  local -a limit=()
  command -v timeout >/dev/null 2>&1 && limit=(timeout 300)
  echo "# $(date -u +%Y-%m-%dT%H:%M:%SZ) down: ${STAGING_DOWN}" >> "${STAGING_LOG}"
  (cd "${REPO_ROOT}" && ${limit[@]+"${limit[@]}"} bash -c "${STAGING_DOWN}") >> "${STAGING_LOG}" 2>&1 \
    || log "staging: STAGING_DOWN failed; see ${STAGING_LOG}"
}

#######################################
# At exit: stop a STAGING_UP that still runs, then STAGING_DOWN. Detached services of a project
# without STAGING_DOWN stay up; the next start brings them up to date.
#######################################
staging_stop() {
  staging_kill_up
  staging_down
  log "staging stopped with the loop"
}

#######################################
# Block until the branch's pull request is merged, closed, or a check fails on its head commit.
# Checks are read with gh (buckets pass, fail, pending, skipping, cancel) and only when the pull
# request's head is the local HEAD, so a stale rollup from the previous push is never judged.
# The head is read again on every pass: a commit pushed after the checks went green (a merge of
# the base branch, a fix pushed by hand) is judged like the loop's own push. When the pull
# request's head is ahead of the local HEAD, the branch is fast-forwarded to it first; a head that
# cannot be fast-forwarded to is left alone and only the merge is waited on.
# A pull request without any check is only waited on for the merge. When every failing check is a
# job GitHub refused to start for billing, CI is not relied on: LOCAL_GATE runs once on that head,
# green waits for the merge, red is reported as the check "local-gate" whose link is the gate's log.
# Dependabot's pull requests are looked at on every poll; when a merge of the base branch moved
# the head, the branch is pushed and its checks are watched from the start again. The staging
# follows the head too.
# Outputs:
#   On a failed check: one line per failing check, "<bucket> <name> <link>".
# Returns:
#   0 merged, 1 closed unmerged, 2 a check failed or was cancelled, 3 withdrawn to consider annotations.
#######################################
wait_for_pr() {
  local branch head judged="" state pr_head checks failing green_told=0 empty_polls=0 local_green=""
  branch="$(git rev-parse --abbrev-ref HEAD)"
  while true; do
    state="$(gh pr view "${branch}" --json state --jq .state 2>/dev/null || echo UNKNOWN)"
    case "${state}" in
      MERGED) return 0 ;;
      CLOSED) return 1 ;;
    esac
    head="$(git rev-parse HEAD)"
    check_dependabot_prs
    if [[ "$(git rev-parse HEAD)" != "${head}" ]]; then
      # The base branch was merged in: the new head is judged afresh on the next pass.
      head="$(git rev-parse HEAD)"
      git push -q "${GIT_REMOTE}" "${branch}" >> "${RUN_LOG}" 2>&1 || log "push of ${branch} failed"
      log "pushed ${branch} at ${head:0:7} with ${BASE_BRANCH} merged in; watching its checks again"
      continue
    fi
    pr_head="$(gh pr view "${branch}" --json headRefOid --jq .headRefOid 2>/dev/null || true)"
    head="$(git rev-parse HEAD)"
    if [[ -n "${pr_head}" && "${pr_head}" != "${head}" ]] \
      && git fetch -q "${GIT_REMOTE:-origin}" "${branch}" 2>/dev/null \
      && [[ "$(git rev-parse FETCH_HEAD)" == "${pr_head}" ]] \
      && git merge-base --is-ancestor HEAD FETCH_HEAD \
      && git merge -q --ff-only FETCH_HEAD >/dev/null 2>&1; then
      log "pull request head moved to ${pr_head}; fast-forwarded ${branch} to it" >&2
      head="${pr_head}"
    fi
    staging_sync >&2
    if [[ "${head}" != "${judged}" ]]; then
      # A new head: its checks are judged afresh and green is told again.
      judged="${head}"
      green_told=0
      empty_polls=0
    fi
    checks=""
    if [[ "${pr_head}" == "${head}" ]]; then
      # gh exits 1 on a failing check and 8 on a pending one; the output is what matters here.
      checks="$(gh pr checks "${branch}" --json name,bucket,link --jq '.[] | "\(.bucket) \(.name) \(.link)"' 2>/dev/null || true)"
    fi
    failing="$(grep -E '^(fail|cancel) ' <<< "${checks}" || true)"
    if [[ -n "${failing}" ]] && billing_refused "${failing}"; then
      # GitHub did not start the jobs (billing): the local gate stands in for CI on this head.
      if [[ "${local_green}" != "${head}" ]]; then
        local gate_log
        log "GitHub refused to start CI on ${head} for billing; running the local gate: ${LOCAL_GATE}" >&2
        if gate_log="$(run_local_gate)"; then
          local_green="${head}"
          log "local gate green on ${branch} at ${head} (${gate_log}); waiting for the merge" >&2
          notify "autoloop: GitHub did not start CI on the pull request for $(progress_field MILESTONE) (billing or spending limit); the local gate is green on ${head:0:7} instead. Waiting for the merge." >&2
        else
          echo "fail local-gate ${gate_log}"
          return 2
        fi
      fi
      sleep "${MERGE_POLL_S}"
      continue
    fi
    if [[ -n "${failing}" ]]; then
      echo "${failing}"
      return 2
    fi
    if [[ -z "${checks}" ]]; then
      empty_polls=$(( empty_polls + 1 ))
      # No check reported yet (the workflow has not started) or none configured: poll fast for a
      # while, then at the merge rate.
      if (( empty_polls < 10 )); then sleep "${CHECK_POLL_S}"; else sleep "${MERGE_POLL_S}"; fi
      continue
    fi
    if grep -qE '^pending ' <<< "${checks}"; then
      sleep "${CHECK_POLL_S}"
      continue
    fi
    if (( ! green_told )); then
      local ids
      ids="$(grep -oE 'runs/[0-9]+' <<< "${checks}" | cut -d/ -f2 | sort -u | paste -sd' ' -)"
      # shellcheck disable=SC2086
      if ! consider_annotations "the pull request" ${ids}; then
        return 3
      fi
      green_told=1
      log "checks green on ${branch} at ${head}; waiting for the merge" >&2
      notify "autoloop: CI is green on the pull request for $(progress_field MILESTONE); waiting for the merge." >&2
    fi
    sleep "${MERGE_POLL_S}"
  done
}

#######################################
# A check failed on the milestone's pull request, so the milestone is not done: save the failed
# job logs under log/, add a task that makes CI green (the implementer and the verifier handle it
# like any task; the next planning run re-runs the acceptance), set STATUS RUNNING, commit
# PROGRESS.md and notify. After CI_REOPEN_LIMIT such tasks in one milestone the loop blocks with
# a question instead.
# Arguments:
#   The failing check lines from wait_for_pr.
#######################################
reopen_for_ci() {
  local failing="$1" milestone branch sha pr_url logfile run_id count task_id names
  milestone="$(progress_field MILESTONE)"
  branch="$(git rev-parse --abbrev-ref HEAD)"
  sha="$(git rev-parse --short HEAD)"
  pr_url="$(gh pr view "${branch}" --json url --jq .url 2>/dev/null || echo "(unknown)")"
  names="$(awk '{print $2}' <<< "${failing}" | paste -sd, -)"
  logfile="${LOG_DIR}/ci-${milestone}-${sha}.log"
  : > "${logfile}"
  while read -r _bucket _name link; do
    run_id="$(grep -oE 'runs/[0-9]+' <<< "${link}" | head -1 | cut -d/ -f2)"
    if [[ -f "${link}" ]]; then
      # The local gate's own log (CI refused for billing).
      cat "${link}" >> "${logfile}"
    elif [[ -n "${run_id}" ]]; then
      { echo "# ${link}"; gh run view "${run_id}" --log-failed 2>&1 || true; } >> "${logfile}"
    fi
  done <<< "${failing}"

  count="$(grep -cE '^- \[.\] T[^ ]+ Make CI green' "${PROGRESS}" || true)"
  if (( count >= CI_REOPEN_LIMIT )); then
    local next_q
    sed -i.bak '1s/^STATUS: .*/STATUS: BLOCKED/' "${PROGRESS}" && rm -f "${PROGRESS}.bak"
    next_q="$(next_question_id)"
    printf '\n## Q%s (%s): CI is still red on the %s pull request after %d fix tasks; what should the loop do?\nContext: checks %s failed on %s (%s); the failed log is %s.\nProposed: read that log, decide whether the workflow or the code is wrong, answer with the instruction for the next task.\nAnswer:\n' \
      "${next_q}" "$(date -u +%F)" "${milestone}" "${count}" "${names}" "${sha}" "${pr_url}" "${logfile}" >> "${QUESTIONS}"
    git add PROGRESS.md QUESTIONS.md && git commit -q -m "autoloop: blocked, CI red on ${milestone} after ${count} fix tasks" || true
    notify "autoloop: CI still red on ${milestone} after ${count} fix tasks; BLOCKED, question Q${next_q}."
    return 0
  fi

  task_id="$(python3 -I "${HERE}/ci_task.py" "${PROGRESS}" "${milestone}" "${sha}" "${names}" "${pr_url}" "${logfile}" "${CI_FIX_ACCEPTANCE}")"
  git add PROGRESS.md && git commit -q -m "Reopen ${milestone}: CI red on the pull request, ${task_id} makes it green"
  log "CI red on ${milestone} (${names} on ${sha}); reopened with ${task_id}, log ${logfile}"
  notify "autoloop: CI is RED on the pull request for ${milestone} (check ${names}, commit ${sha}); the milestone is not done. Reopened with ${task_id}; the loop fixes it and pushes again. ${pr_url}"
}

#######################################
# After a merge: update the base branch, reset PROGRESS.md for the next milestone on its own branch.
# Arguments:
#   The next milestone id.
#######################################
start_next_milestone() {
  local next="$1" done_ms
  done_ms="$(progress_field MILESTONE)"
  git checkout -q "${BASE_BRANCH}" && git pull -q --ff-only "${GIT_REMOTE}" "${BASE_BRANCH}" || { log "cannot update ${BASE_BRANCH}"; return 1; }
  if ! git rev-parse -q --verify "refs/tags/milestone/${done_ms}" >/dev/null; then
    git tag -a "milestone/${done_ms}" -m "${done_ms} merged: $(milestone_title "${done_ms}")" \
      && git push -q "${GIT_REMOTE}" "refs/tags/milestone/${done_ms}" >> "${RUN_LOG}" 2>&1 || log "tag milestone/${done_ms} not pushed"
  fi
  git checkout -q -b "autoloop/${next}" || git checkout -q "autoloop/${next}"
  write_fresh_questions
  write_fresh_progress "${next}"
  git add PROGRESS.md QUESTIONS.md && git commit -q -m "Start ${next}: $(milestone_title "${next}")"
  log "started ${next} on autoloop/${next} with fresh PROGRESS.md and QUESTIONS.md"
}

#######################################
# Ensure the work happens on the autoloop branch of the current milestone.
#######################################
ensure_branch() {
  local milestone branch current
  milestone="$(progress_field MILESTONE)"
  branch="${AUTOLOOP_BRANCH:-autoloop/${milestone}}"
  current="$(git -C "${REPO_ROOT}" rev-parse --abbrev-ref HEAD)"
  if [[ "${current}" != "${branch}" ]]; then
    if (( dry_run )); then
      log "dry-run: would switch to branch ${branch} (now ${current})"
      return
    fi
    if git -C "${REPO_ROOT}" show-ref --verify --quiet "refs/heads/${branch}"; then
      git -C "${REPO_ROOT}" checkout -q "${branch}"
    else
      git -C "${REPO_ROOT}" checkout -q -b "${branch}"
    fi
    log "on branch ${branch}"
  fi
}

#######################################
# The runs that judge (plan, verify, judge) need the strong model: a cheaper alias here is a setup
# error, as is a DEPENDABOT_MERGE or a DEPENDABOT_TRIAGE the loop does not know, or a staging
# setting that cannot work.
#######################################
check_settings() {
  local m
  for m in "${PLAN_MODEL}" "${VERIFY_MODEL}" "${JUDGE_MODEL}"; do
    if [[ ! "${m,,}" =~ (opus|fable) ]]; then
      echo "PLAN_MODEL, VERIFY_MODEL and JUDGE_MODEL must be a Fable or Opus model, got '${m}'" >&2
      exit 3
    fi
  done
  case "${DEPENDABOT_MERGE}" in
    squash|merge|rebase|report|ignore) ;;
    *) echo "DEPENDABOT_MERGE must be squash, merge, rebase, report or ignore, got '${DEPENDABOT_MERGE}'" >&2; exit 3 ;;
  esac
  case "${DEPENDABOT_TRIAGE}" in
    judge|off) ;;
    *) echo "DEPENDABOT_TRIAGE must be judge or off, got '${DEPENDABOT_TRIAGE}'" >&2; exit 3 ;;
  esac
  local name
  # shellcheck disable=SC2086
  for name in ${STAGING_SERVICES}; do
    [[ "${name}" =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]] \
      || { echo "a name in STAGING_SERVICES is letters, digits, _ and -, starting with a letter, got '${name}'" >&2; exit 3; }
  done
  if [[ -n "${STAGING_SERVICES}" && -z "${STAGING_UP}" ]]; then
    echo "STAGING_SERVICES names ${STAGING_SERVICES} but STAGING_UP is empty: set the command that starts them, or empty STAGING_SERVICES" >&2
    exit 3
  fi
  if [[ ! "${STAGING_PORT_BASE}" =~ ^[0-9]+$ ]] || (( STAGING_PORT_BASE < 1 || STAGING_PORT_BASE > 65535 )); then
    echo "STAGING_PORT_BASE must be a port number, got '${STAGING_PORT_BASE}'" >&2
    exit 3
  fi
  if [[ ! "${STAGING_READY_S}" =~ ^[0-9]+$ ]]; then
    echo "STAGING_READY_S must be a number of seconds, got '${STAGING_READY_S}'" >&2
    exit 3
  fi
}

main() {
  cd "${REPO_ROOT}"
  [[ -f "${PROGRESS}" ]] || { echo "missing ${PROGRESS}" >&2; exit 3; }
  check_settings
  if (( print_stage )); then
    next_stage
    exit 0
  fi
  if ! (( dry_run )) && ! command -v "${CLAUDE_BIN}" >/dev/null 2>&1; then
    echo "claude CLI not found (CLAUDE_BIN=${CLAUDE_BIN})" >&2
    exit 3
  fi
  ensure_branch
  staging_start

  local iteration=0 no_progress=0 no_commit=0 no_progress_blocks=0 judge_allowed=1 progress_repairs=0 limit_backoff_s="${LIMIT_SLEEP_DEFAULT_S}"
  local stage head_before progress_before rc=0
  while (( iteration < MAX_ITERATIONS )); do
    (( dry_run )) || check_dependabot_prs
    staging_sync
    stage="$(next_stage)"
    case "${stage}" in
      blocked)
        log "STATUS BLOCKED: see QUESTIONS.md"
        rc=3
        if (( judge_allowed )); then
          rc=0
          judge_questions || rc=$?
        fi
        if (( rc == 2 )); then
          continue   # usage limit: the judge runs again
        fi
        if (( dry_run || once )); then
          log "stopping after one stage (--once/--dry-run)"
          exit 0
        fi
        if (( rc == 0 )); then
          log "every question answered by the judge; resuming"
          continue
        fi
        notify "autoloop: BLOCKED on $(progress_field MILESTONE). $(python3 -I "${HERE}/qa.py" list --ids | wc -w) question(s) for you in QUESTIONS.md; they follow. Reply \"Q<n> <answer>\" to each."
        python3 -I "${HERE}/qa.py" send || true
        if python3 -I "${HERE}/qa.py" wait --timeout "${ANSWER_WAIT_S}" && [[ "$(progress_field STATUS)" == "RUNNING" ]]; then
          log "questions answered over Telegram; resuming"
          notify "autoloop: answers recorded in DECISIONS.md, resuming $(progress_field MILESTONE)"
          continue
        fi
        log "blocked with no answer path (Telegram not configured, no open question, or timeout): fix the files and restart"
        notify "autoloop: still BLOCKED and cannot wait for an answer; see QUESTIONS.md and kickoff.log"
        exit 2 ;;
      milestone_done)
        local done_ms next_ms pr_url failing
        done_ms="$(progress_field MILESTONE)"
        log "milestone ${done_ms} done"
        if ! command -v gh >/dev/null 2>&1; then
          notify "autoloop: milestone ${done_ms} DONE on branch $(git rev-parse --abbrev-ref HEAD); gh is not installed, so open the pull request, merge it, set the next MILESTONE and STATUS: RUNNING by hand."
          exit 0
        fi
        archive_milestone
        pr_url="$(open_pr)" || { notify "autoloop: milestone ${done_ms} DONE but the push or pull request failed; see kickoff.log"; exit 3; }
        notify "autoloop: milestone ${done_ms} DONE. Pull request: ${pr_url}. The loop watches its checks and waits for the merge, then starts the next milestone."
        rc=0
        failing="$(wait_for_pr)" || rc=$?
        case "${rc}" in
          1)
            notify "autoloop: the pull request for ${done_ms} was closed without merging; stopped. Reopen or merge it and restart."
            exit 2 ;;
          2)
            log "check failed on the ${done_ms} pull request: ${failing}"
            reopen_for_ci "${failing}"
            continue ;;
          3)
            notify "autoloop: CI is green on the pull request for ${done_ms} but carries warning annotations; the milestone is reopened so the planning run considers them. $(tail -1 "${PROGRESS}" | cut -c1-300)"
            continue ;;
        esac
        next_ms="$(next_milestone "${done_ms}")"
        if [[ -z "${next_ms}" ]]; then
          notify "autoloop: ${done_ms} merged and it was the last milestone in MILESTONES.md. Done."
          exit 0
        fi
        start_next_milestone "${next_ms}" || exit 3
        notify "autoloop: ${done_ms} merged; starting ${next_ms} ($(milestone_title "${next_ms}"))."
        continue ;;
      bad_status)
        log "PROGRESS.md STATUS line is not RUNNING/BLOCKED/MILESTONE_DONE"
        exit 3 ;;
      bad_progress)
        log "PROGRESS.md has a task field outside a task: $(orphan_field)"
        notify "autoloop: PROGRESS.md has a task field outside a task (line $(orphan_field)); fix it and restart."
        exit 3 ;;
    esac

    head_before="$(git rev-parse HEAD)"
    progress_before="$(md5sum "${PROGRESS}" 2>/dev/null || md5 -q "${PROGRESS}")"
    rc=0
    case "${stage}" in
      plan)   invoke plan   "${PLAN_MODEL}"   "$(prompt_file plan)"   "${PLAN_MAX_TURNS}"   || rc=$? ;;
      task)   invoke task   "$(task_model)"   "$(prompt_file task)"   "${TASK_MAX_TURNS}"   || rc=$? ;;
      verify) invoke verify "${VERIFY_MODEL}" "$(prompt_file verify)" "${VERIFY_MAX_TURNS}" || rc=$? ;;
    esac
    iteration=$(( iteration + 1 ))

    if (( rc == 75 )); then
      wait_for_limit
      continue   # same stage again
    fi
    limit_backoff_s="${LIMIT_SLEEP_DEFAULT_S}"

    # A run that left a task field outside a task (it overwrote a task heading) is undone and retried;
    # after PROGRESS_REPAIR_LIMIT such runs in a row the damage stays and the next pass stops (bad_progress).
    if [[ -n "$(orphan_field)" ]]; then
      if (( progress_repairs < PROGRESS_REPAIR_LIMIT )) && repair_progress "${stage}" "${head_before}"; then
        progress_repairs=$(( progress_repairs + 1 ))
        (( dry_run || once )) && exit 0
        continue
      fi
    else
      progress_repairs=0
    fi

    if (( dry_run || once )); then
      log "stopping after one stage (--once/--dry-run)"
      exit 0
    fi

    local progress_after blocked_after=0 detail=""
    progress_after="$(md5sum "${PROGRESS}" 2>/dev/null || md5 -q "${PROGRESS}")"
    if [[ "$(git rev-parse HEAD)" != "${head_before}" ]]; then
      no_progress=0
      no_commit=0
    else
      no_commit=$(( no_commit + 1 ))
      if [[ "${progress_after}" == "${progress_before}" ]]; then
        no_progress=$(( no_progress + 1 ))
        log "no commit and no PROGRESS.md change after ${stage} (${no_progress}/${NO_PROGRESS_LIMIT})"
      else
        log "no commit after ${stage}, PROGRESS.md changed but not committed (${no_commit}/${NO_COMMIT_LIMIT})"
        detail=" (PROGRESS.md was changed but never committed)"
      fi
      if (( no_progress >= NO_PROGRESS_LIMIT )); then
        blocked_after="${no_progress}"
      elif (( no_commit >= NO_COMMIT_LIMIT )); then
        blocked_after="${no_commit}"
      fi
      if (( blocked_after )); then
        sed -i.bak '1s/^STATUS: .*/STATUS: BLOCKED/' "${PROGRESS}" && rm -f "${PROGRESS}.bak"
        local next_q last_result reason
        next_q="$(next_question_id)"
        last_result="$(ls -t "${LOG_DIR}"/*-"${stage}".json 2>/dev/null | head -1)"
        reason="$(run_reason "${last_result}")"
        printf '\n## Q%s (%s): no progress after %d %s runs; what should the loop do?\nContext: %d %s runs ended with no commit%s. Last result: %s\nThe last run said: %s\nProposed: read that file, fix the cause (a refused command, too few turns, a failing acceptance), answer with the instruction for the next run.\nAnswer:\n' \
          "${next_q}" "$(date -u +%F)" "${blocked_after}" "${stage}" "${blocked_after}" "${stage}" "${detail}" "${last_result:-none}" "${reason}" >> "${QUESTIONS}"
        git add PROGRESS.md QUESTIONS.md && git commit -q -m "autoloop: blocked after ${blocked_after} runs without progress" || true
        no_progress_blocks=$(( no_progress_blocks + 1 ))
        if (( no_progress_blocks >= 2 )); then
          # The judge already answered one such block in this run and the runs still make no progress:
          # the owner is asked directly.
          judge_allowed=0
        fi
        no_progress=0
        no_commit=0
        notify "autoloop: BLOCKED, no progress after ${blocked_after} ${stage} runs on $(progress_field MILESTONE). The last run said: ${reason} The judge reads it next."
        continue   # the blocked branch: the judge, then the owner
      fi
    fi
    if ! git diff --quiet || ! git diff --cached --quiet; then
      log "warning: uncommitted changes left after ${stage}; the next run must commit or revert them"
    fi
  done
  log "iteration cap ${MAX_ITERATIONS} reached"
  notify "autoloop: iteration cap reached on $(progress_field MILESTONE); restart to continue"
}

main "$@"
