"""Write the task that makes CI green into PROGRESS.md and set STATUS RUNNING.

Called by kickoff.sh when a check failed on the milestone's pull request.
Arguments: PROGRESS.md path, milestone id, short sha, failing check names,
pull request url, the saved failed-log path, the acceptance command.
The task's acceptance is that command followed by each make target that failed
in the log, so the verifier re-runs what CI ran, not only the lint gate.
Prints the new task id.
"""

import datetime
import pathlib
import re
import subprocess
import sys

_MAKE_FAIL = re.compile(r"\bmake(?:\[(\d+)\])?: \*\*\* \[(?:[^\]]*?:\d+: )?([^\]\s]+)\] Error \d+")
_MAKE_DIR = re.compile(r"\bmake\[(\d+)\]: Entering directory '([^']+)'")


def _local_dir(remote: str, root: pathlib.Path) -> str | None:
    """The directory of the repository that a runner's absolute path names, relative to the root ("" for the root).

    The runner checks the repository out elsewhere, so the longest tail of the path that is a directory of this
    checkout with a Makefile is taken; None when no tail is.
    """
    parts = pathlib.PurePosixPath(remote).parts
    for start in range(1, len(parts) + 1):
        tail = pathlib.Path(*parts[start:]) if parts[start:] else pathlib.Path()
        if (root / tail / "Makefile").is_file():
            return tail.as_posix() if parts[start:] else ""
    return None


def failed_make_commands(log_text: list[str], root: pathlib.Path) -> list[str]:
    """The `make` command of the innermost failed target of each failed job in the log, in log order, unique.

    make reports a failure from the innermost level outwards, so the first `*** [...] Error` line after a job's
    `# http` header is the target that failed; its directory comes from that level's last `Entering directory`
    line (none at level 0: the step's own directory, taken as the root).
    """
    commands: list[str] = []
    dirs: dict[int, str] = {}
    found = False
    for raw in log_text:
        if raw.startswith("# http"):
            dirs, found = {}, False
            continue
        if found:
            continue
        if m := _MAKE_DIR.search(raw):
            dirs[int(m.group(1))] = m.group(2)
            continue
        if m := _MAKE_FAIL.search(raw):
            found = True
            level = int(m.group(1) or 0)
            where = _local_dir(dirs[level], root) if level in dirs else ""
            if where is None:
                continue
            command = f"make -C {where} {m.group(2)}" if where else f"make {m.group(2)}"
            if command not in commands:
                commands.append(command)
    return commands


def _repo_root(progress: pathlib.Path) -> pathlib.Path:
    """The top of the git checkout that holds PROGRESS.md, or its directory outside git."""
    result = subprocess.run(
        ["git", "-C", str(progress.parent), "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=False
    )
    return pathlib.Path(result.stdout.strip()) if result.returncode == 0 else progress.parent.resolve()


def main() -> None:
    """Insert the task before the Log section, set STATUS RUNNING and UPDATED, append a Log line."""
    path, milestone, sha, names, pr_url, logfile, acceptance = sys.argv[1:8]
    lines = pathlib.Path(path).read_text(encoding="utf-8").splitlines()
    major = re.sub(r"\D", "", milestone) or "0"
    task_re = re.compile(r"- \[.\] T" + major + r"\.(\d+)\b")
    minors = [int(m.group(1)) for line in lines if (m := task_re.match(line))]
    task_id = f"T{major}.{max(minors, default=0) + 1}"

    log_text = pathlib.Path(logfile).read_text(encoding="utf-8", errors="replace").splitlines()
    links = [raw[2:] for raw in log_text if raw.startswith("# http")]
    errors = [raw.split("##[error]", 1)[1].strip()[:300] for raw in log_text if "##[error]" in raw][:5]
    error_text = (
        "; ".join(errors) if errors else "no ##[error] line in the log; read it from the start of the failed step"
    )
    reruns = [c for c in failed_make_commands(log_text, _repo_root(pathlib.Path(path))) if c != acceptance]
    acceptance = " && ".join([acceptance, *reruns])

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
