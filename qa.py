"""Questions: the judge's bookkeeping, then Telegram for what the judge passes to the owner.

Usage:
  qa.py list [--ids] [--unjudged]  print the open questions (or only their ids; or only those without a Judge: line)
  qa.py send                       send every unanswered question in QUESTIONS.md to the chat
  qa.py wait [--timeout S]         long-poll the chat until every open question has an answer; record each one
  qa.py wait --from-file F         same, but read answers from a text file (tests; one "Q1 answer" per line)
  qa.py judged --before-open "1 2" --before-unjudged "1 2" --log F
                                   after a judge run: append what changed to the judge log, reconcile STATUS,
                                   print a summary; exit 1 when nothing changed
  qa.py judge-log [--since EPOCH] [--log F]
                                   print the judge log lines newer than EPOCH (the status report)

An answer is a Telegram message from the configured chat that starts with the question id:
"Q1 use the mirror at ..." (also "Q1:" or "Q1 -"). Multi-line messages are kept whole.
Recording an answer: the question's "Answer:" line in QUESTIONS.md, a row in DECISIONS.md section 2
(so the next run reads it where every run looks), and when no question is left open,
"STATUS: RUNNING" in PROGRESS.md; the three files are committed. Only messages from TELEGRAM_CHAT_ID count.
The judge run (prompts/judge.md) records its answers in the same two places itself, with "(judge, <date>)"
on the Answer: line, and marks a question it passes to the owner with a "Judge: cannot answer: ..." line.
Settings come from <project autoloop dir>/autoloop.env; without a token "send" prints and "wait" exits 2.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import pathlib
import re
import subprocess
import sys
import time
import urllib.parse
import urllib.request

HERE = pathlib.Path(__file__).resolve().parent
AUTOLOOP_DIR = pathlib.Path(os.environ.get("AUTOLOOP_DIR") or HERE.parent)
REPO = pathlib.Path(
    os.environ.get("AUTOLOOP_REPO")
    or subprocess.run(
        ["git", "-C", str(AUTOLOOP_DIR), "rev-parse", "--show-toplevel"], check=True, capture_output=True, text=True
    ).stdout.strip()
)
QUESTIONS = REPO / "QUESTIONS.md"
DECISIONS = REPO / "DECISIONS.md"
PROGRESS = REPO / "PROGRESS.md"
LOG_DIR = AUTOLOOP_DIR / "log"
OFFSET_FILE = LOG_DIR / "telegram.offset"
JUDGE_LOG = LOG_DIR / "judge.log"
ANSWER_RE = re.compile(r"^\s*Q[-_ ]?(\d+)\s*[:\-]?\s*(.+)$", re.DOTALL | re.IGNORECASE)
# What counts as "no answer yet" on an Answer: line: empty, one bracketed placeholder such as "(human)"
# or "[owner]", dashes, or the words tbd / todo / pending / open. One bracket pair only, so an answer
# that starts with an option such as "(a)" and ends with "(judge, <date>)" is an answer; and a bracketed
# option letter or number alone, "(a)" or "(2)", is an answer too.
PLACEHOLDER_RE = re.compile(
    r"^(\((?![a-z0-9]\))[^()]*\)|\[(?![a-z0-9]\])[^\[\]]*\]|-+|tbd|todo|pending|open|\?+)?$", re.IGNORECASE
)
POLL_S = 30
FIELD_RE = re.compile(r"^(context|proposed|answer|judge|options?|cost|impact)\s*:", re.IGNORECASE)


def load_env() -> dict[str, str]:
    """Read <project autoloop dir>/autoloop.env (KEY=value lines) on top of the process environment."""
    env = dict(os.environ)
    env_file = AUTOLOOP_DIR / "autoloop.env"
    if env_file.exists():
        for line in env_file.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, value = line.split("=", 1)
                env.setdefault(key.strip(), value.strip().strip('"').strip("'"))
    return env


class Question:
    """One "## Q<id> ..." section of QUESTIONS.md."""

    def __init__(self, qid: str, heading: str, body_lines: list[str], start: int, end: int) -> None:
        """Keep the id, the heading line, the body and the line span in the file."""
        self.qid = qid
        self.heading = heading
        self.body_lines = body_lines
        self.start = start
        self.end = end

    @property
    def answered(self) -> bool:
        """True when the Answer: line has content."""
        return self.answer is not None

    @property
    def answer(self) -> str | None:
        """The content of the Answer: line, or None when it is empty or a placeholder."""
        for line in self.body_lines:
            if line.lower().startswith("answer:"):
                text = line.split(":", 1)[1].strip()
                return None if PLACEHOLDER_RE.match(text) else text
        return None

    @property
    def judge_line(self) -> str | None:
        """The content of the Judge: line (the judge passed the question to the owner), or None."""
        for line in self.body_lines:
            if line.lower().startswith("judge:"):
                return line.split(":", 1)[1].strip()
        return None

    @property
    def judged(self) -> bool:
        """True when the judge answered it or passed it to the owner."""
        return self.judge_line is not None or (self.answer is not None and "(judge" in self.answer)

    def text(self) -> str:
        """The question as sent to the chat: the heading, then one line per field or paragraph.

        QUESTIONS.md is hard-wrapped at about 76 columns; a line break inside a sentence misleads in a
        chat, so wrapped lines are joined and a break appears only before a field (Context:, Proposed:,
        Judge:, Answer:), a list item, or after a blank line.
        """
        paragraphs: list[str] = [self.heading.lstrip("# ").strip()]
        open_paragraph = False
        for raw in self.body_lines:
            line = raw.strip()
            if not line:
                open_paragraph = False
                continue
            starts_new = (
                bool(FIELD_RE.match(line)) or line.startswith(("- ", "* ")) or bool(re.match(r"^\d+[.)] ", line))
            )
            if open_paragraph and not starts_new:
                paragraphs[-1] += " " + line
            else:
                paragraphs.append(line)
                open_paragraph = True
        return "\n".join(paragraphs)


def parse_questions() -> list[Question]:
    """Return every Q section of QUESTIONS.md with its line span."""
    lines = QUESTIONS.read_text().splitlines()
    questions: list[Question] = []
    # Headings inside fenced code blocks (the format example in the file's header) are not questions.
    in_fence, starts = False, []
    for i, line in enumerate(lines):
        if line.startswith("```"):
            in_fence = not in_fence
        elif not in_fence and re.match(r"^## Q", line):
            starts.append(i)
    for n, start in enumerate(starts):
        end = starts[n + 1] if n + 1 < len(starts) else len(lines)
        # A section ends at the next question heading or at the next fence, so the example never leaks in.
        for k in range(start + 1, end):
            if lines[k].startswith("```"):
                end = k
                break
        match = re.match(r"^## Q[-_ ]?(\w+)", lines[start])
        qid = match.group(1) if match else str(n + 1)
        questions.append(Question(qid, lines[start], lines[start + 1 : end], start, end))
    return questions


def open_questions() -> list[Question]:
    """The unanswered ones."""
    return [q for q in parse_questions() if not q.answered]


def telegram(env: dict[str, str], method: str, **fields: str) -> dict:
    """Call one Bot API method; raise on HTTP or API failure."""
    token = env.get("TELEGRAM_BOT_TOKEN", "")
    url = f"https://api.telegram.org/bot{token}/{method}"
    data = urllib.parse.urlencode(fields).encode()
    with urllib.request.urlopen(urllib.request.Request(url, data=data), timeout=60) as resp:  # noqa: S310
        payload = json.loads(resp.read().decode())
    if not payload.get("ok"):
        raise RuntimeError(f"telegram {method}: {payload}")
    return payload["result"]


def configured(env: dict[str, str]) -> bool:
    """Token and chat id present."""
    return bool(env.get("TELEGRAM_BOT_TOKEN")) and bool(env.get("TELEGRAM_CHAT_ID"))


def send(env: dict[str, str]) -> int:
    """Send every open question; print them when Telegram is not configured."""
    opens = open_questions()
    if not opens:
        print("no open questions")
        return 0
    for q in opens:
        text = (
            f'autoloop question {q.qid} (reply with "Q{q.qid} <your answer>"; it is recorded in DECISIONS.md '
            f"and the loop resumes):\n\n{q.text()}"
        )
        if configured(env):
            telegram(env, "sendMessage", chat_id=env["TELEGRAM_CHAT_ID"], text=text[:4000])
        else:
            print(f"telegram (not configured):\n{text}\n")
    return 0


def set_status(status: str) -> bool:
    """Set the STATUS line of PROGRESS.md; return True when it changed."""
    progress = PROGRESS.read_text().splitlines()
    if progress and progress[0].startswith("STATUS:") and progress[0] != f"STATUS: {status}":
        progress[0] = f"STATUS: {status}"
        PROGRESS.write_text("\n".join(progress) + "\n")
        return True
    return False


def record(qid: str, answer: str, source: str) -> None:
    """Write the answer into QUESTIONS.md and DECISIONS.md; set RUNNING when nothing stays open; commit."""
    questions = parse_questions()
    target = next((q for q in questions if q.qid == qid), None)
    if target is None:
        raise KeyError(qid)
    lines = QUESTIONS.read_text().splitlines()
    answer_one_line = " ".join(answer.split())
    for i in range(target.start + 1, target.end):
        if lines[i].lower().startswith("answer:"):
            lines[i] = f"Answer: {answer_one_line} ({source}, {dt.date.today().isoformat()})"
            break
    else:
        lines.insert(target.end, f"Answer: {answer_one_line} ({source}, {dt.date.today().isoformat()})")
    QUESTIONS.write_text("\n".join(lines) + "\n")

    decisions = DECISIONS.read_text()
    marker = "\n## 3. Process"
    if marker not in decisions:
        raise RuntimeError("DECISIONS.md has no section 3 marker")
    head, tail = decisions.split(marker, 1)
    title = target.heading.lstrip("# ").strip()
    row = f"| {title} | {answer_one_line} |\n"  # DECISIONS.md carries no history; QUESTIONS.md does
    head = head.rstrip("\n") + "\n" + row
    DECISIONS.write_text(head + marker + tail)

    changed = [QUESTIONS, DECISIONS]
    if not open_questions() and set_status("RUNNING"):
        changed.append(PROGRESS)
    subprocess.run(["git", "add", *[str(p.relative_to(REPO)) for p in changed]], cwd=REPO, check=True)
    subprocess.run(
        ["git", "commit", "-q", "-m", f"Answer Q{qid} ({source}): {answer_one_line[:60]}"], cwd=REPO, check=True
    )


def answers_from_file(path: str) -> list[tuple[str, str]]:
    """Parse "Q1 answer" lines from a file (tests)."""
    out = []
    for line in pathlib.Path(path).read_text().splitlines():
        m = ANSWER_RE.match(line)
        if m:
            out.append((m.group(1), m.group(2).strip()))
    return out


def poll_once(env: dict[str, str]) -> list[tuple[str, str]]:
    """One getUpdates call; return (qid, answer) pairs from the configured chat; advance the offset."""
    offset = int(OFFSET_FILE.read_text().strip() or 0) if OFFSET_FILE.exists() else 0
    updates = telegram(env, "getUpdates", offset=str(offset), timeout="20")
    found = []
    for update in updates:
        offset = max(offset, update["update_id"] + 1)
        message = update.get("message") or update.get("edited_message") or {}
        if str(message.get("chat", {}).get("id")) != str(env["TELEGRAM_CHAT_ID"]):
            continue
        m = ANSWER_RE.match(message.get("text", ""))
        if m:
            found.append((m.group(1), m.group(2).strip()))
    OFFSET_FILE.parent.mkdir(parents=True, exist_ok=True)
    OFFSET_FILE.write_text(str(offset))
    return found


def wait(env: dict[str, str], timeout_s: int, from_file: str | None) -> int:
    """Block until every open question is answered (or the timeout); record each answer as it arrives."""
    if not open_questions():
        print("no open question in QUESTIONS.md, yet the loop is blocked: nothing to wait for", file=sys.stderr)
        return 3
    if from_file:
        for qid, answer in answers_from_file(from_file):
            if any(q.qid == qid for q in open_questions()):
                record(qid, answer, "file")
                print(f"recorded Q{qid}")
        return 0 if not open_questions() else 3
    if not configured(env):
        print("telegram not configured: answer in QUESTIONS.md and DECISIONS.md by hand, set STATUS: RUNNING")
        return 2
    deadline = time.monotonic() + timeout_s
    while open_questions():
        if time.monotonic() > deadline:
            print("timeout waiting for answers")
            return 3
        try:
            for qid, answer in poll_once(env):
                if any(q.qid == qid for q in open_questions()):
                    record(qid, answer, "telegram")
                    telegram(env, "sendMessage", chat_id=env["TELEGRAM_CHAT_ID"], text=f"Recorded Q{qid}. Thank you.")
                    print(f"recorded Q{qid}")
                else:
                    telegram(env, "sendMessage", chat_id=env["TELEGRAM_CHAT_ID"], text=f"Q{qid} is not open.")
        except (OSError, RuntimeError) as exc:
            print(f"telegram error, retrying: {exc}", file=sys.stderr)
        if open_questions():
            time.sleep(POLL_S)
    print("every question answered; STATUS: RUNNING")
    return 0


def judged(before_open: str, before_unjudged: str, log_path: pathlib.Path) -> int:
    """Bookkeeping after a judge run.

    Compares the questions that were open and unjudged before the run with QUESTIONS.md now: a question
    answered since is logged as "answered" with its answer, one that gained a Judge: line as "passed"
    with the judge's reason. STATUS is reconciled with the file (RUNNING only when nothing stays open;
    BLOCKED otherwise) and PROGRESS.md committed when that changed it. Prints one summary line per
    change; exit 1 when nothing changed, so the wrapper asks the owner instead of judging again.
    """
    was_open = set(before_open.split())
    was_unjudged = set(before_unjudged.split())
    now = {q.qid: q for q in parse_questions()}
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    lines: list[str] = []
    for qid in sorted(was_open, key=lambda s: (len(s), s)):
        q = now.get(qid)
        if q is None:
            continue
        if q.answered:
            lines.append(f"{stamp} Q{qid} answered: {' '.join(q.answer.split())}")
        elif qid in was_unjudged and q.judge_line is not None:
            lines.append(f"{stamp} Q{qid} passed to the owner: {' '.join(q.judge_line.split())}")
    still_open = open_questions()
    wanted = "BLOCKED" if still_open else "RUNNING"
    if set_status(wanted):
        subprocess.run(["git", "add", "PROGRESS.md"], cwd=REPO, check=True)
        subprocess.run(
            ["git", "commit", "-q", "-m", f"autoloop: STATUS {wanted} after the judge run"], cwd=REPO, check=True
        )
        lines.append(f"{stamp} STATUS set to {wanted} by the wrapper")
    if not lines:
        return 1
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("a") as handle:
        handle.write("\n".join(lines) + "\n")
    for line in lines:
        print(line.split(" ", 1)[1][:600])
    return 0


def judge_log(since_epoch: int, log_path: pathlib.Path) -> int:
    """Print the judge log lines whose timestamp is after the epoch given."""
    if not log_path.exists():
        return 0
    since = dt.datetime.fromtimestamp(since_epoch, dt.timezone.utc)
    for line in log_path.read_text().splitlines():
        stamp, _, rest = line.partition(" ")
        try:
            when = dt.datetime.strptime(stamp, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)
        except ValueError:
            continue
        if when > since:
            print(f"{stamp[11:16]} {rest}")
    return 0


def main() -> int:
    """Command line entry."""
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=["send", "wait", "list", "judged", "judge-log"])
    parser.add_argument("--timeout", type=int, default=7 * 24 * 3600)
    parser.add_argument("--from-file")
    parser.add_argument("--ids", action="store_true", help="list: ids only, space separated")
    parser.add_argument("--unjudged", action="store_true", help="list: only questions without a judge verdict")
    parser.add_argument("--before-open", default="", help="judged: the open ids before the judge run")
    parser.add_argument("--before-unjudged", default="", help="judged: the unjudged ids before the judge run")
    parser.add_argument("--log", default=str(JUDGE_LOG), help="judged, judge-log: the judge log file")
    parser.add_argument("--since", type=int, default=0, help="judge-log: epoch seconds")
    args = parser.parse_args()
    env = load_env()
    if args.command == "list":
        opens = [q for q in open_questions() if not (args.unjudged and q.judged)]
        if args.ids:
            print(" ".join(q.qid for q in opens))
        else:
            for q in opens:
                print(q.text(), "\n")
        return 0
    if args.command == "send":
        return send(env)
    if args.command == "judged":
        return judged(args.before_open, args.before_unjudged, pathlib.Path(args.log))
    if args.command == "judge-log":
        return judge_log(args.since, pathlib.Path(args.log))
    return wait(env, args.timeout, args.from_file)


if __name__ == "__main__":
    sys.exit(main())
