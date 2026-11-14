"""The result file of a run (claude -p --output-format json), read in one place for the wrapper.

Usage:
  result.py text <file>             the run's result text as the run wrote it; nothing when there is none
  result.py reason <file> <chars>   the result text on one line, cut to <chars> characters with "…", for the
                                    no-progress question and the Telegram message; says so when there is none
  result.py classify <file>         the run's outcome, one line: OK; LIMIT <epoch> (the usage limit, with the
                                    reset time as an epoch, 0 when unknown); AUTH (not logged in); or
                                    ERROR <the first 200 characters>
  result.py verdict <file>          "<flaky|break|unsure> <reason>" from the last VERDICT: and REASON: lines
                                    of a triage run's answer; exit 1 when it named no verdict

The file holds one JSON object, or a list of events whose last "result" event counts. A file that is
missing or not JSON has no text (text, reason, verdict) and, for classify, is an error whose text is the
raw content, so a limit message the CLI wrote without JSON is still recognised.
"""

from __future__ import annotations

import datetime as dt
import json
import pathlib
import re
import sys

LIMIT_RE = re.compile(r"(usage limit|hit your \S*\s*limit|rate limit|limit reached|too many requests|overloaded)")
AUTH_RE = re.compile(
    r"(not logged in|invalid api key|authentication_error|please run /login|run claude login|401 unauthorized)"
)
VERDICT_RE = re.compile(r"(?mi)^\W*VERDICT:\W*(flaky|break|unsure)\b")
REASON_RE = re.compile(r"(?mi)^\W*REASON:\W*(.+)$")


def read(path: str) -> str:
    """The file's content; empty when it cannot be read."""
    try:
        return pathlib.Path(path).read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def parse(raw: str) -> tuple[str, str, bool] | None:
    """The result text, the error text and whether the run reported an error; None when raw is not a result."""
    try:
        data = json.loads(raw)
    except ValueError:
        return None
    if isinstance(data, list):
        results = [d for d in data if isinstance(d, dict) and d.get("type") == "result"]
        data = results[-1] if results else (data[-1] if data else None)
    if not isinstance(data, dict):
        return None
    return str(data.get("result") or ""), str(data.get("error") or ""), bool(data.get("is_error"))


def text(path: str) -> str:
    parsed = parse(read(path))
    return parsed[0] if parsed else ""


def reason(path: str, limit: int) -> str:
    """The result text joined to one line and cut to the limit."""
    joined = " ".join(text(path).split())
    if not joined:
        return "(no result text in the run's result file)"
    if len(joined) > limit:
        return joined[: limit - 1].rstrip() + "…"
    return joined


def reset_epoch(full: str, low: str) -> str:
    """The reset time of a usage limit: an epoch after "|" (older wording) or "resets 5:20pm (UTC)" (current
    wording, a clock time within the next 24 h). "0" for anything else: the wait falls back to its default."""
    match = re.search(r"\|(\d{10})", full)
    if match:
        return match.group(1)
    match = re.search(r"resets\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)\s*\(utc\)", low)
    if not match:
        return "0"
    hour = int(match.group(1)) % 12 + (12 if match.group(3) == "pm" else 0)
    now = dt.datetime.now(dt.timezone.utc)
    reset = now.replace(hour=hour, minute=int(match.group(2) or 0), second=0, microsecond=0)
    if reset <= now:
        reset += dt.timedelta(days=1)
    return str(int(reset.timestamp()))


def classify(path: str) -> str:
    """OK, LIMIT <epoch>, AUTH or ERROR <text>. Only an error result is classified: a normal summary may
    mention limits or authentication as its topic."""
    raw = read(path)
    parsed = parse(raw)
    if parsed is None:
        full, is_error = raw, True
    else:
        full, is_error = parsed[0] + " " + parsed[1], parsed[2]
    low = full.lower()
    if not is_error:
        return "OK"
    if LIMIT_RE.search(low):
        return "LIMIT " + reset_epoch(full, low)
    if AUTH_RE.search(low):
        return "AUTH"
    return "ERROR " + full[:200].replace("\n", " ")


def verdict(path: str) -> str | None:
    """The last verdict and reason of a triage run, the reason on one line and cut to 300 characters."""
    answer = text(path)
    verdicts = VERDICT_RE.findall(answer)
    if not verdicts:
        return None
    reasons = REASON_RE.findall(answer)
    why = " ".join(reasons[-1].split()) if reasons else ""
    if len(why) > 300:
        why = why[:299].rstrip() + "…"
    return f"{verdicts[-1].lower()} {why or '(no reason given)'}"


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    command, path = argv[1], argv[2]
    if command == "text":
        print(text(path))
    elif command == "reason":
        print(reason(path, int(argv[3]) if len(argv) > 3 else 700))
    elif command == "classify":
        print(classify(path))
    elif command == "verdict":
        line = verdict(path)
        if line is None:
            return 1
        print(line)
    else:
        print(__doc__, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
