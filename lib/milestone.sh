#!/usr/bin/env bash
#
# The milestone's files, branch and pull request: its title and successor in MILESTONES.md, the
# question ids of QUESTIONS.md, the pull request body, the HISTORY.md line, the archive of a finished
# milestone, fresh PROGRESS.md and QUESTIONS.md for the next one, pushing the branch and opening the
# pull request.
#
# Part of the autoloop core: kickoff.sh sources this file from its own checkout (lib/milestone.sh) after
# the settings; log, notify, progress_field, prompt_file and invoke are kickoff.sh's. Not a program
# of its own.

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
# The id of the next question in QUESTIONS.md: one above the highest "## Q<n>" heading outside a
# code fence (the format example in the file's header is inside one).
#######################################
next_question_id() {
  awk '/^```/ {fence = !fence; next} !fence && /^## Q[0-9]+/ {sub(/^## Q/, ""); sub(/[^0-9].*/, ""); if ($0 + 0 > max) max = $0 + 0} END {print max + 1}' "${QUESTIONS}"
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
    python3 -I "${HERE}/result.py" text "${latest_plan}" > "${dir}/ACCEPTANCE.md" 2>/dev/null || true
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
