#!/usr/bin/env bash
#
# Dependabot's pull requests on the base branch: a green, mergeable one is merged and the base
# branch brought into the milestone branch; a red one is triaged by the judge once per head commit
# (flaky: its failed jobs run again once; broken or unclear: told to the owner with the reason).
#
# Part of the autoloop core: kickoff.sh sources this file from its own checkout (lib/dependabot.sh) after
# the settings; log, notify, progress_field, prompt_file and invoke are kickoff.sh's. Not a program
# of its own.

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
# nothing and ends with a "VERDICT:" and a "REASON:" line, which are read from its result file (result.py).
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
  python3 -I "${HERE}/result.py" verdict "${result}"
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
