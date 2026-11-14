#!/usr/bin/env bash
#
# The checks of the milestone's pull request: waiting for the merge, judging the checks on the
# pull request's head, the local gate when GitHub refuses the jobs for billing, the warning
# annotations of a green run, merging the base branch in, and reopening the milestone with a task
# that makes CI green.
#
# Part of the autoloop core: kickoff.sh sources this file from its own checkout (lib/pr.sh) after
# the settings; log, notify, progress_field, prompt_file and invoke are kickoff.sh's. Not a program
# of its own.

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
# Globals:
#   pr_failing: on a failed check, one line per failing check, "<bucket> <name> <link>".
# Returns:
#   0 merged, 1 closed unmerged, 2 a check failed or was cancelled, 3 withdrawn to consider annotations.
#######################################
wait_for_pr() {
  local branch head judged="" state pr_head checks failing green_told=0 empty_polls=0 local_green=""
  pr_failing=""
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
      log "pull request head moved to ${pr_head}; fast-forwarded ${branch} to it"
      head="${pr_head}"
    fi
    staging_sync
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
        log "GitHub refused to start CI on ${head} for billing; running the local gate: ${LOCAL_GATE}"
        if gate_log="$(run_local_gate)"; then
          local_green="${head}"
          log "local gate green on ${branch} at ${head} (${gate_log}); waiting for the merge"
          notify "autoloop: GitHub did not start CI on the pull request for $(progress_field MILESTONE) (billing or spending limit); the local gate is green on ${head:0:7} instead. Waiting for the merge."
        else
          pr_failing="fail local-gate ${gate_log}"
          return 2
        fi
      fi
      sleep "${MERGE_POLL_S}"
      continue
    fi
    if [[ -n "${failing}" ]]; then
      pr_failing="${failing}"
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
