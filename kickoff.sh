#!/usr/bin/env bash
#
# Autonomous development loop: plan -> one task -> verify, repeated, with
# PROGRESS.md as the state the runs share and git commits as checkpoints.
# A blocked loop first asks the judge run (a strong model) to answer the open
# questions from the project's documents; what it cannot answer goes to the
# owner over Telegram.
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
readonly LIMIT_SLEEP_DEFAULT_S="${LIMIT_SLEEP_DEFAULT_S:-1800}"
readonly LIMIT_SLEEP_MAX_S="${LIMIT_SLEEP_MAX_S:-10800}"
readonly LIMIT_NOTIFY_HOURS="${LIMIT_NOTIFY_HOURS:-6}"
readonly ANSWER_WAIT_S="${ANSWER_WAIT_S:-604800}"
readonly MERGE_POLL_S="${MERGE_POLL_S:-600}"
readonly CHECK_POLL_S="${CHECK_POLL_S:-120}"
readonly CI_REOPEN_LIMIT="${CI_REOPEN_LIMIT:-3}"
readonly CI_FIX_ACCEPTANCE="${CI_FIX_ACCEPTANCE:-tools/lint/lint.sh}"
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
#   The run name (plan, task, verify, judge).
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
    printf -- '- **%s, milestone %s done.** %s (%s/archive/%s).\n' \
      "$(date -u +%F)" "${milestone}" "$(milestone_title "${milestone}")" "${AUTOLOOP_REL}" "${milestone}" >> "${REPO_ROOT}/HISTORY.md"
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
# Block until the branch's pull request is merged, closed, or a check fails on its head commit.
# Checks are read with gh (buckets pass, fail, pending, skipping, cancel) and only when the pull
# request's head is the local HEAD, so a stale rollup from the previous push is never judged.
# A pull request without any check is only waited on for the merge.
# Outputs:
#   On a failed check: one line per failing check, "<bucket> <name> <link>".
# Returns:
#   0 merged, 1 closed unmerged, 2 a check failed or was cancelled, 3 withdrawn to consider annotations.
#######################################
wait_for_pr() {
  local branch head state pr_head checks failing green_told=0 empty_polls=0
  branch="$(git rev-parse --abbrev-ref HEAD)"
  head="$(git rev-parse HEAD)"
  while true; do
    state="$(gh pr view "${branch}" --json state --jq .state 2>/dev/null || echo UNKNOWN)"
    case "${state}" in
      MERGED) return 0 ;;
      CLOSED) return 1 ;;
    esac
    pr_head="$(gh pr view "${branch}" --json headRefOid --jq .headRefOid 2>/dev/null || true)"
    checks=""
    if [[ "${pr_head}" == "${head}" ]]; then
      # gh exits 1 on a failing check and 8 on a pending one; the output is what matters here.
      checks="$(gh pr checks "${branch}" --json name,bucket,link --jq '.[] | "\(.bucket) \(.name) \(.link)"' 2>/dev/null || true)"
    fi
    failing="$(grep -E '^(fail|cancel) ' <<< "${checks}" || true)"
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
      log "checks green on ${branch} at ${head}; waiting for the merge"
      notify "autoloop: CI is green on the pull request for $(progress_field MILESTONE); waiting for the merge."
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
    if [[ -n "${run_id}" ]]; then
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
# The runs that judge (plan, verify, judge) need the strong model: a cheaper alias here is a setup error.
#######################################
check_models() {
  local m
  for m in "${PLAN_MODEL}" "${VERIFY_MODEL}" "${JUDGE_MODEL}"; do
    if [[ ! "${m,,}" =~ (opus|fable) ]]; then
      echo "PLAN_MODEL, VERIFY_MODEL and JUDGE_MODEL must be a Fable or Opus model, got '${m}'" >&2
      exit 3
    fi
  done
}

main() {
  cd "${REPO_ROOT}"
  [[ -f "${PROGRESS}" ]] || { echo "missing ${PROGRESS}" >&2; exit 3; }
  check_models
  if (( print_stage )); then
    next_stage
    exit 0
  fi
  if ! (( dry_run )) && ! command -v "${CLAUDE_BIN}" >/dev/null 2>&1; then
    echo "claude CLI not found (CLAUDE_BIN=${CLAUDE_BIN})" >&2
    exit 3
  fi
  ensure_branch

  local iteration=0 no_progress=0 no_commit=0 no_progress_blocks=0 judge_allowed=1 limit_backoff_s="${LIMIT_SLEEP_DEFAULT_S}"
  local stage head_before progress_before rc=0
  while (( iteration < MAX_ITERATIONS )); do
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
        local next_q last_result
        next_q="$(next_question_id)"
        last_result="$(ls -t "${LOG_DIR}"/*-"${stage}".json 2>/dev/null | head -1)"
        printf '\n## Q%s (%s): no progress after %d %s runs; what should the loop do?\nContext: %d %s runs ended with no commit%s. Last result: %s\nProposed: read that file, fix the cause (a refused command, too few turns, a failing acceptance), answer with the instruction for the next run.\nAnswer:\n' \
          "${next_q}" "$(date -u +%F)" "${blocked_after}" "${stage}" "${blocked_after}" "${stage}" "${detail}" "${last_result:-none}" >> "${QUESTIONS}"
        git add PROGRESS.md QUESTIONS.md && git commit -q -m "autoloop: blocked after ${blocked_after} runs without progress" || true
        no_progress_blocks=$(( no_progress_blocks + 1 ))
        if (( no_progress_blocks >= 2 )); then
          # The judge already answered one such block in this run and the runs still make no progress:
          # the owner is asked directly.
          judge_allowed=0
        fi
        no_progress=0
        no_commit=0
        notify "autoloop: BLOCKED, no progress after ${blocked_after} ${stage} runs; the judge reads the last result first"
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
