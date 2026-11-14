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
# The parts that do not choose stages live in lib/ next to this file and are
# sourced from it: the milestone's files and pull request (milestone.sh), the
# checks of a pull request (pr.sh), Dependabot's pull requests (dependabot.sh)
# and the staging (staging.sh); progress.py reads PROGRESS.md and result.py
# a run's result file for all of them.
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

# The parts of the loop that do not choose stages, sourced from this checkout: they use the settings
# above and the functions below (log, notify, progress_field, prompt_file, invoke).
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/milestone.sh
source "${HERE}/lib/milestone.sh"
# shellcheck source=lib/pr.sh
source "${HERE}/lib/pr.sh"
# shellcheck source=lib/dependabot.sh
source "${HERE}/lib/dependabot.sh"
# shellcheck source=lib/staging.sh
source "${HERE}/lib/staging.sh"

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
# Read a header field of PROGRESS.md (STATUS, MILESTONE), through progress.py like every other reading of it.
# Arguments:
#   The field name.
#######################################
progress_field() {
  python3 -I "${HERE}/progress.py" "${PROGRESS}" field "$1"
}

#######################################
# Why a run ended, in one line: the result text of its result file (result.py) with whitespace joined,
# cut to RUN_REASON_CHARS characters. Says so when the file is missing or carries no result.
# Arguments:
#   The result file (may be empty).
#######################################
run_reason() {
  python3 -I "${HERE}/result.py" reason "$1" "${RUN_REASON_CHARS:-700}"
}

#######################################
# Find a task field outside a task: before any task, or repeated within one (a lost task heading).
# Outputs:
#   The first orphan's line number and first 60 characters; nothing when there is none.
#######################################
orphan_field() {
  python3 -I "${HERE}/progress.py" "${PROGRESS}" orphan
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
# Decide the next stage from PROGRESS.md: plan, task, verify, or a terminal state (progress.py).
# Outputs:
#   One word on stdout.
#######################################
next_stage() {
  python3 -I "${HERE}/progress.py" "${PROGRESS}" stage
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
  picked="$(python3 -I "${HERE}/progress.py" "${PROGRESS}" task-model)"
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
  # Classify from the JSON result (is_error, result text; result.py); fall back to rc.
  local verdict
  verdict="$(python3 -I "${HERE}/result.py" classify "${out_file}")"
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
        local done_ms next_ms pr_url
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
        wait_for_pr || rc=$?
        case "${rc}" in
          1)
            notify "autoloop: the pull request for ${done_ms} was closed without merging; stopped. Reopen or merge it and restart."
            exit 2 ;;
          2)
            log "check failed on the ${done_ms} pull request: ${pr_failing}"
            reopen_for_ci "${pr_failing}"
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
