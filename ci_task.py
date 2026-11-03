"""Write the task that makes CI green into PROGRESS.md and set STATUS RUNNING.

Called by kickoff.sh when a check failed on the milestone's pull request.
Arguments: PROGRESS.md path, milestone id, short sha, failing check names,
pull request url, the saved failed-log path, the acceptance command.
Prints the new task id.
"""

import datetime
import pathlib
import re
import sys


def main() -> None:
    path, milestone, sha, names, pr_url, logfile, acceptance = sys.argv[1:8]
    lines = pathlib.Path(path).read_text(encoding="utf-8").splitlines()
    major = re.sub(r"\D", "", milestone) or "0"
    task_re = re.compile(r"- \[.\] T" + major + r"\.(\d+)\b")
    minors = [int(m.group(1)) for line in lines if (m := task_re.match(line))]
    task_id = f"T{major}.{max(minors, default=0) + 1}"

    log_text = pathlib.Path(logfile).read_text(encoding="utf-8", errors="replace").splitlines()
    links = [raw[2:] for raw in log_text if raw.startswith("# http")]
    errors = [raw.split("##[error]", 1)[1].strip()[:300] for raw in log_text if "##[error]" in raw][:5]
    error_text = "; ".join(errors) if errors else "no ##[error] line in the log; read it from the start of the failed step"

    entry = [
        f"- [ ] {task_id} Make CI green on the pull request: check {names} failed on {sha}",
        "  - files: the workflow under .github/workflows/, or the code the failing step ran; the log names it",
        f"  - reads: the failed job log {logfile}; the check: {' '.join(links) or pr_url}",
        f"  - design: The milestone's pull request {pr_url} has a failing check on its head commit {sha}, "
        "so the milestone is not done. Read the saved log, find the first error, and fix its cause in the "
        "workflow or in the code the step ran. Do not remove, skip or weaken a step of the gate: a step that "
        "cannot run in CI needs a decision in QUESTIONS.md, not a deletion. Run the same step locally where it "
        "can run (the lint gate and the suites the change touches) and state the result in notes. The loop "
        "pushes the branch when the milestone is done again and watches the check; the verifier re-reads the "
        f"diff. First error lines: {error_text}",
        f"  - acceptance: `{acceptance}`",
        "  - model:",
        "  - notes:",
        "  - verified:",
    ]

    log_idx = next(i for i, line in enumerate(lines) if line.startswith("## Log"))
    insert_at = log_idx
    while insert_at > 0 and lines[insert_at - 1].strip() == "":
        insert_at -= 1
    if lines[insert_at - 1].strip() == "(none yet: the planning run writes them)":
        del lines[insert_at - 1]
        insert_at -= 1
    lines[insert_at:insert_at] = entry

    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    lines[0] = "STATUS: RUNNING"
    for i, line in enumerate(lines[:3]):
        if line.startswith("UPDATED:"):
            lines[i] = f"UPDATED: {now}"
    lines.append(
        f"- {now[:10]} wrapper: CI red on the {milestone} pull request (check {names} on {sha}); "
        f"milestone reopened with {task_id}."
    )
    pathlib.Path(path).write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(task_id)


if __name__ == "__main__":
    main()
