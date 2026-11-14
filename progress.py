"""PROGRESS.md, read in one place for the wrapper and the status report.

Usage:
  progress.py <file> field <NAME>   the header field (STATUS, MILESTONE, UPDATED): the first "NAME: value" line,
                                    without whitespace
  progress.py <file> counts         "open inprogress reopened done verifying": the tasks by state ([ ], [~],
                                    [!], [x]) and the done ones whose verified: line is still empty
  progress.py <file> stage          the next stage: blocked, milestone_done or bad_status from STATUS;
                                    bad_progress for a task field outside a task; else plan (no tasks, or all
                                    done and verified), verify (a done task not yet verified) or task
  progress.py <file> orphan         the first task field outside a task or repeated within one (a lost task
                                    heading): "<line>: <first 60 characters>"; nothing when there is none
  progress.py <file> task-model     the model: line of the task the implementer will pick (the first [~],
                                    else the first [!], else the first [ ]); nothing when it has none

The task format is MILESTONES.md "Task format in PROGRESS.md": a task is a "- [<state>] T<id> ..." line
followed by "  - <field>:" lines (files, reads, design, acceptance, model, notes, verified). A line indented
deeper is a continuation, never a field; the Log section is not searched for orphans.
"""

from __future__ import annotations

import pathlib
import re
import sys

TASK_RE = re.compile(r"^- \[(.)\] T")
FIELD_RE = re.compile(r"^  - (files|reads|design|acceptance|model|notes|verified):")
STATES = {" ": "open", "~": "inprogress", "!": "reopened", "x": "done"}


def field(lines: list[str], name: str) -> str:
    for line in lines:
        if line.startswith(name + ":"):
            return "".join(line[len(name) + 1 :].split())
    return ""


def tasks(lines: list[str]) -> list[tuple[str, list[str]]]:
    """Each task's state and its body: the lines up to the next "- [" line."""
    found: list[tuple[str, list[str]]] = []
    for line in lines:
        match = TASK_RE.match(line)
        if match:
            found.append((match.group(1), []))
        elif line.startswith("- ["):
            found.append(("", []))  # a checkbox line that is not a task ends the task before it
        elif found:
            found[-1][1].append(line)
    return [task for task in found if task[0]]


def counts(lines: list[str]) -> dict[str, int]:
    out = {name: 0 for name in STATES.values()}
    out["verifying"] = 0
    for state, body in tasks(lines):
        if state in STATES:
            out[STATES[state]] += 1
        if state == "x" and any(re.match(r"^  - verified: *$", line) for line in body):
            out["verifying"] += 1
    return out


def orphan(lines: list[str]) -> str:
    in_task, seen = False, set()
    for number, line in enumerate(lines, 1):
        if line.startswith("## Log"):
            break
        if TASK_RE.match(line):
            in_task, seen = True, set()
            continue
        match = FIELD_RE.match(line)
        if match:
            if not in_task or match.group(1) in seen:
                return f"{number}: {line[:60]}"
            seen.add(match.group(1))
    return ""


def stage(lines: list[str]) -> str:
    status = field(lines, "STATUS")
    if status == "BLOCKED":
        return "blocked"
    if status == "MILESTONE_DONE":
        return "milestone_done"
    if status != "RUNNING":
        return "bad_status"
    if orphan(lines):
        return "bad_progress"
    c = counts(lines)
    if c["open"] + c["inprogress"] + c["done"] + c["reopened"] == 0:
        return "plan"
    if c["verifying"]:
        return "verify"
    if c["open"] + c["inprogress"] + c["reopened"]:
        return "task"
    return "plan"  # everything done and verified: the planning run runs the milestone acceptance


def task_model(lines: list[str]) -> str:
    for mark in ("~", "!", " "):
        for state, body in tasks(lines):
            if state == mark:
                for line in body:
                    match = re.match(r"\s+- model:\s*(\S+)\s*$", line)
                    if match:
                        return match.group(1)
                return ""
    return ""


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    lines = pathlib.Path(argv[1]).read_text(encoding="utf-8").splitlines()
    command = argv[2]
    if command == "field" and len(argv) > 3:
        print(field(lines, argv[3]))
    elif command == "counts":
        c = counts(lines)
        print(c["open"], c["inprogress"], c["reopened"], c["done"], c["verifying"])
    elif command == "stage":
        print(stage(lines))
    elif command == "orphan":
        found = orphan(lines)
        if found:
            print(found)
    elif command == "task-model":
        print(task_model(lines))
    else:
        print(__doc__, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
