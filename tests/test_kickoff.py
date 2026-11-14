"""Tests of the shared wrapper in a temporary repository laid out like a project (tools/autoloop/core).

Run from a project: python3 -I -m unittest discover -s tools/autoloop/core/tests
Needs git, bash, python3 and the `timeout` binary; claude is a fake script, Telegram is not configured.
"""

from __future__ import annotations

import contextlib
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import tempfile
import time
import unittest

CORE = Path(__file__).resolve().parents[1]
CORE_FILES = ("kickoff.sh", "telegram.sh", "qa.py", "ci_task.py")
# The PROGRESS.md of the project this core is checked out in, when there is one.
REAL_PROGRESS = CORE.parent.parent.parent / "PROGRESS.md"

IDENTITY = {
    "GIT_AUTHOR_NAME": "Test",
    "GIT_AUTHOR_EMAIL": "test@example.invalid",
    "GIT_COMMITTER_NAME": "Test",
    "GIT_COMMITTER_EMAIL": "test@example.invalid",
}

TASK = """- [ ] T1.1 First
  - files: a.py
  - reads: b.md
  - design: do it
    - files: not a field, a continuation line
  - acceptance: make test
  - notes:
  - verified:
"""
HEADER = "STATUS: RUNNING\nMILESTONE: M1\nUPDATED: 2026-11-01T00:00:00Z\n\n## Tasks (M1)\n\n"
BLOCKED_HEADER = HEADER.replace("STATUS: RUNNING", "STATUS: BLOCKED")
DONE_HEADER = HEADER.replace("STATUS: RUNNING", "STATUS: MILESTONE_DONE")
LOG = "\n## Log\n\n- 2026-11-01 started.\n  - files: a Log line that looks like a field\n"
QUESTIONS_HEADER = "# Questions\n\nFormat:\n\n```markdown\n## Q1 (date, task): one line\nContext: ...\nAnswer:\n```\n\n"
Q1_TITLE = "Q1 (2026-11-01, task T1.1): which port does the API listen on?"
OPEN_Q = f"## {Q1_TITLE}\nContext: two options.\nProposed: 8080.\nAnswer:\n"
PASSED_Q = OPEN_Q.replace("Answer:", "Judge: cannot answer: the owner's call (2026-11-01)\nAnswer:")
DECISIONS = (
    "# Decisions\n\n## 1. Fixed\n\n| Item | Value |\n|---|---|\n| a | b |\n\n"
    "## 2. Open items\n\n| Open item | Proceed like this |\n|---|---|\n\n## 3. Process\n\ntext\n"
)

FAKE_OK = """#!/usr/bin/env bash
echo x >> "$FAKE_COUNT"
echo '{"is_error": false, "result": "ok"}'
"""
FAKE_APPEND = """#!/usr/bin/env bash
echo x >> "$FAKE_COUNT"
echo "- appended" >> PROGRESS.md
echo '{"is_error": false, "result": "ok"}'
"""
FAKE_COMMIT = """#!/usr/bin/env bash
echo x >> "$FAKE_COUNT"
git commit -q --allow-empty -m "fake work"
echo '{"is_error": false, "result": "ok"}'
"""
FAKE_COMMIT_SECOND = """#!/usr/bin/env bash
echo x >> "$FAKE_COUNT"
if [ "$(wc -l < "$FAKE_COUNT")" -eq 2 ]; then git commit -q --allow-empty -m "fake work"; fi
echo '{"is_error": false, "result": "ok"}'
"""
# A run that overwrites the task heading (as an edit of the task above it can) and commits PROGRESS.md.
FAKE_BREAK_ALWAYS = """#!/usr/bin/env bash
echo x >> "$FAKE_COUNT"
sed -i '/^- \\[.\\] T1.1 First$/d' PROGRESS.md
git commit -q -am "broke the heading"
echo '{"is_error": false, "result": "ok"}'
"""
FAKE_BREAK_FIRST = """#!/usr/bin/env bash
echo x >> "$FAKE_COUNT"
if [ "$(wc -l < "$FAKE_COUNT")" -eq 1 ]; then sed -i '/^- \\[.\\] T1.1 First$/d' PROGRESS.md; fi
git commit -q --allow-empty -am "work"
echo '{"is_error": false, "result": "ok"}'
"""
# The first call hits the usage limit (the CLI's wording, with a reset the wrapper cannot parse), the second commits.
FAKE_LIMIT_ONCE = """#!/usr/bin/env bash
echo x >> "$FAKE_COUNT"
if [ "$(wc -l < "$FAKE_COUNT")" -eq 1 ]; then
  echo '{"is_error": true, "result": "You\u2019ve hit your 5-hour limit \u00b7 resets soon"}'
  exit 1
fi
git commit -q --allow-empty -m "fake work"
echo '{"is_error": false, "result": "ok"}'
"""
# The judge answers Q1 as prompts/judge.md asks: Answer line, DECISIONS row, STATUS RUNNING, one commit.
FAKE_JUDGE_ANSWERS = """#!/usr/bin/env bash
echo x >> "$FAKE_COUNT"
python3 - <<'PY'
import pathlib
q = pathlib.Path("QUESTIONS.md")
q.write_text(q.read_text().replace("Answer:\\n", "Answer: 8080, TECH_STACK.md section 2 (judge, 2026-11-01)\\n"))
d = pathlib.Path("DECISIONS.md")
row = "| Q1 (2026-11-01, task T1.1): which port does the API listen on? | 8080 (judge) |\\n\\n## 3. Process"
d.write_text(d.read_text().replace("\\n## 3. Process", row))
PY
if [ -z "$FAKE_FORGET_STATUS" ]; then sed -i '1s/.*/STATUS: RUNNING/' PROGRESS.md; fi
git add QUESTIONS.md DECISIONS.md PROGRESS.md && git commit -q -m "Judge: answered Q1"
echo '{"is_error": false, "result": "ok"}'
"""
# The judge answers with an option letter first and its "(judge, <date>)" mark last: the line begins
# and ends with a bracket, which must not read as a placeholder such as "(human)".
FAKE_JUDGE_ANSWERS_OPTION = FAKE_JUDGE_ANSWERS.replace(
    "Answer: 8080, TECH_STACK.md section 2 (judge, 2026-11-01)",
    "Answer: (a). TECH_STACK.md section 2 (judge, 2026-11-01)",
)
# The judge passes Q1 to the owner.
FAKE_JUDGE_PASSES = """#!/usr/bin/env bash
echo x >> "$FAKE_COUNT"
python3 - <<'PY'
import pathlib
q = pathlib.Path("QUESTIONS.md")
q.write_text(q.read_text().replace("Answer:\\n", "Judge: cannot answer: the owner's call (2026-11-01)\\nAnswer:\\n"))
PY
git add QUESTIONS.md && git commit -q -m "Judge: passed Q1"
echo '{"is_error": false, "result": "ok"}'
"""
FAKE_GH = """#!/usr/bin/env bash
# Scripted gh: the pull request is open at FAKE_HEAD (default: the local HEAD), its one check
# failed, run 42 has one failed job and a two-line log. With FAKE_GREEN_AT the check passed on that
# commit (run 43, no annotations); with FAKE_THEN_COMMIT too, a commit lands on the branch right after
# that green is read, as a push from outside the loop would. With FAKE_BILLING the failed job carries
# GitHub's billing refusal instead of the warning. Dependabot's open pull requests are the lines of FAKE_PRS (number|sha|mergeable|review|draft|url|title; FAKE_PRS_COUNT of them for the
# status report); #12 has the checks FAKE_PR_CHECKS (default: one passed) and its merge, recorded
# in FAKE_MERGED, exits FAKE_MERGE_RC. Run 43 (the checks of #12) has a one-line failed log; a re-run
# of its failed jobs is recorded in FAKE_RERUN and exits FAKE_RERUN_RC.
case "$*" in
  *"pr list --app dependabot"*"--jq length"*) echo "${FAKE_PRS_COUNT:-0}" ;;
  *"pr list --app dependabot"*) printf '%s' "${FAKE_PRS:-}" ;;
  *"pr checks 12 "*) printf '%s\\n' "${FAKE_PR_CHECKS-pass gate https://example.invalid/actions/runs/43/job/8}" ;;
  *"pr merge 12 "*) echo "$*" >> "${FAKE_MERGED:-/dev/null}"; exit "${FAKE_MERGE_RC:-0}" ;;
  *"pr diff 12"*) printf -- '-x==1\n+x==2\n' ;;
  *"run view 43 --log-failed"*) printf 'gate\tInstall\tnpm ERR! 503 Service Unavailable\n' ;;
  *"run rerun "*) echo "$*" >> "${FAKE_RERUN:-/dev/null}"; exit "${FAKE_RERUN_RC:-0}" ;;
  *"pr view"*"state"*) echo OPEN ;;
  *"pr view"*"headRefOid"*) echo "${FAKE_HEAD:-$(git rev-parse HEAD)}" ;;
  *"pr view"*"url"*) echo "https://example.invalid/pr/1" ;;
  *"pr checks"*)
    if [ -n "${FAKE_GREEN_AT:-}" ] && [ "$(git rev-parse HEAD)" = "$FAKE_GREEN_AT" ]; then
      echo "pass gate https://example.invalid/actions/runs/43/job/8"
      if [ -n "${FAKE_THEN_COMMIT:-}" ]; then git commit -q --allow-empty -m "pushed after green"; fi
    else
      echo "fail gate https://example.invalid/actions/runs/42/job/7"
    fi ;;
  *"run view 42 --log-failed"*) printf 'gate\\tTest\\t##[error]Process completed with exit code 1.\\n' ;;
  *"run view 42 --json jobs"*) echo gate ;;
  *"actions/runs/42/jobs"*) echo 7 ;;
  *"check-runs/7/annotations"*)
    if [ -n "${FAKE_BILLING:-}" ]; then
      echo "failure: .github:1 The job was not started because recent account payments have failed" \
        "or your spending limit needs to be increased."
    else
      echo "warning: .github:2 Node.js 20 is deprecated; action x targets it"
    fi ;;
  *) exit 1 ;;
esac
"""
# The triage run ends with a verdict (its prompt ends with the pull request's facts); any other run commits.
FAKE_TRIAGE_FLAKY = """#!/usr/bin/env bash
echo x >> "$FAKE_COUNT"
case "$*" in
  *"The pull request: #12"*)
    echo '{"is_error": false, "result": "Read both.\\n\\nVERDICT: flaky\\nREASON: the registry answered 503."}' ;;
  *)
    git commit -q --allow-empty -m "fake work"
    echo '{"is_error": false, "result": "ok"}' ;;
esac
"""
RED_CHECK = "fail gate https://example.invalid/actions/runs/43/job/8"
# The staging's STAGING_UP commands: one that keeps running (two servers in its session; stopped by the
# wrapper), one that returns after starting a server once (stopped by STAGING_DOWN), and one that fails
# on its second call.
STAGING_SERVE = (
    'echo "up $STAGING_PORT_WEB $STAGING_PORT_API" >> "$FAKE_STAGING"; '
    'python3 -m http.server "$STAGING_PORT_WEB" --bind 127.0.0.1 & '
    'python3 -m http.server "$STAGING_PORT_API" --bind 127.0.0.1 & wait'
)
STAGING_DETACH = (
    'if ! { [ -s "$FAKE_SERVER_PID" ] && kill -0 "$(cat "$FAKE_SERVER_PID")" 2>/dev/null; }; then '
    'python3 -m http.server "$STAGING_PORT_WEB" --bind 127.0.0.1 >/dev/null 2>&1 & echo $! > "$FAKE_SERVER_PID"; fi; '
    'echo up >> "$FAKE_STAGING"'
)
STAGING_FAIL_SECOND = (
    'echo up >> "$FAKE_STAGING"; if [ "$(wc -l < "$FAKE_STAGING")" -ge 2 ]; then echo "compose: boom"; exit 7; fi; '
    'exec python3 -m http.server "$STAGING_PORT_WEB" --bind 127.0.0.1'
)


def verdict(text: str) -> str:
    """The result file of a triage run whose answer is the text."""
    return json.dumps({"is_error": False, "result": text})


FLAKY = verdict("I read the log.\n\nVERDICT: flaky\nREASON: npm answered 503 in step Install;\n")
BREAK = verdict("**VERDICT:** break\n**REASON:** tests/test_x.py fails on the removed x.old() call.")
UNSURE = verdict("VERDICT: unsure\nREASON: the log is empty.")
DEPENDABOT_SHA = "a" * 40
# One open Dependabot pull request, #12, as the scripted gh lists it.
DEPENDABOT_PR = f"12|{DEPENDABOT_SHA}|MERGEABLE||false|https://example.invalid/pr/12|Bump x from 1 to 2\n"
PR_FUNCTIONS = ";".join(
    f"/^{name}()/,/^}}/p"
    for name in (
        "wait_for_pr",
        "staging_sync",
        "check_dependabot_prs",
        "dependabot_red",
        "dependabot_triage",
        "dependabot_tell",
        "merge_base_branch",
        "reopen_for_ci",
        "run_annotations",
        "billing_refused",
        "run_local_gate",
        "consider_annotations",
        "next_question_id",
        "write_pr_body",
        "write_pr_body_full",
        "milestone_title",
        "history_line",
        "archive_milestone",
    )
)


def git(repo: Path, *args: str) -> str:
    """Runs git in the repository and returns stdout."""
    return subprocess.run(
        ["git", *args], cwd=repo, check=True, capture_output=True, text=True, timeout=60, env={**os.environ, **IDENTITY}
    ).stdout


class WrapperTest(unittest.TestCase):
    """A temporary repository on branch autoloop/M1 with the core under tools/autoloop/core."""

    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="autoloop-test-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.repo = self.tmp / "repo"
        self.loop = self.repo / "tools" / "autoloop"
        core = self.loop / "core"
        (core / "prompts").mkdir(parents=True)
        for name in CORE_FILES:
            shutil.copy(CORE / name, core / name)
        for name in ("judge", "dependabot"):
            shutil.copy(CORE / "prompts" / f"{name}.md", core / "prompts" / f"{name}.md")
        (self.loop / "prompts").mkdir()
        for name in ("plan", "task", "verify"):
            (self.loop / "prompts" / f"{name}.md").write_text(f"{name} prompt\n")
        self.write_progress(HEADER + TASK + LOG)
        (self.repo / "QUESTIONS.md").write_text(QUESTIONS_HEADER + "(no open questions)\n")
        (self.repo / "DECISIONS.md").write_text(DECISIONS)
        (self.repo / "MILESTONES.md").write_text("# Milestones\n\n## M1: first\n\n## M2: second\n")
        (self.repo / "HISTORY.md").write_text("# History\n")
        (self.repo / ".gitignore").write_text("tools/autoloop/log/\ntools/autoloop/autoloop.env\n")
        git(self.repo, "init", "-q", "-b", "autoloop/M1")
        git(self.repo, "add", ".")
        git(self.repo, "commit", "-q", "-m", "initial")
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        (self.bin / "gh").write_text(FAKE_GH)
        (self.bin / "gh").chmod(0o755)
        self.merged = self.tmp / "merged"
        self.rerun = self.tmp / "rerun"

    def add_remote(self) -> Path:
        """Gives the repository a bare origin holding main, at the initial commit, and the milestone branch."""
        remote = self.tmp / "remote.git"
        git(self.tmp, "init", "-q", "--bare", "-b", "main", str(remote))
        git(self.repo, "remote", "add", "origin", str(remote))
        git(self.repo, "branch", "main")
        git(self.repo, "push", "-q", "origin", "main", "autoloop/M1")
        return remote

    def land_on_main(self, name: str, content: str) -> str:
        """Commits a file on origin's main, as a merged Dependabot pull request would; returns the sha."""
        work = self.tmp / "work"
        git(self.tmp, "clone", "-q", "-b", "main", str(self.tmp / "remote.git"), str(work))
        (work / name).write_text(content)
        git(work, "add", name)
        git(work, "commit", "-q", "-m", f"Bump x from 1 to 2 ({name})")
        git(work, "push", "-q", "origin", "main")
        sha = git(work, "rev-parse", "HEAD").strip()
        shutil.rmtree(work)
        return sha

    def write_progress(self, text: str) -> None:
        (self.repo / "PROGRESS.md").write_text(text)

    def read(self, name: str) -> str:
        return (self.repo / name).read_text()

    def run_loop(self, fake: str | None = None, *args: str, **env: str) -> subprocess.CompletedProcess:
        """Runs the project's wrapper path with a fake claude; returns the completed process."""
        claude = self.tmp / "fake_claude"
        claude.write_text(fake or FAKE_COMMIT)
        claude.chmod(0o755)
        environ = {k: v for k, v in os.environ.items() if not k.startswith("TELEGRAM_")}
        environ.update(IDENTITY)
        environ.update({"FAKE_FORGET_STATUS": "", **env}, CLAUDE_BIN=str(claude), FAKE_COUNT=str(self.tmp / "count"))
        environ.update(PATH=f"{self.bin}:{environ['PATH']}", FAKE_MERGED=str(self.merged), FAKE_RERUN=str(self.rerun))
        return subprocess.run(
            [str(self.loop / "core" / "kickoff.sh"), *args],
            cwd=self.repo,
            env=environ,
            capture_output=True,
            text=True,
            timeout=120,
            check=False,
        )

    def calls(self) -> int:
        """The number of times the fake claude ran."""
        count = self.tmp / "count"
        return len(count.read_text().splitlines()) if count.exists() else 0

    def staging_env(self, base: int, **env: str) -> dict[str, str]:
        """The staging settings of a test: ports from the base given (above the ephemeral range), a fixed host."""
        return {
            "STAGING_HOST": "stage.invalid",
            "STAGING_PORT_BASE": str(base),
            "STAGING_READY_S": "5",
            "FAKE_STAGING": str(self.tmp / "staging"),
            "FAKE_SERVER_PID": str(self.tmp / "server.pid"),
            **env,
        }

    def staging_lines(self) -> list[str]:
        """What the test's STAGING_UP and STAGING_DOWN recorded, in order."""
        path = self.tmp / "staging"
        return path.read_text().splitlines() if path.exists() else []

    def ports(self) -> dict[str, int]:
        """The staging's ports as log/staging.ports records them."""
        lines = (self.loop / "log" / "staging.ports").read_text().splitlines()
        return {name: int(port) for name, port in (line.split() for line in lines)}

    @staticmethod
    def port_free(port: int) -> bool:
        """True when nothing listens on the port (within two seconds, for a server just told to stop)."""
        for _ in range(20):
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
                s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                try:
                    s.bind(("", port))
                    return True
                except OSError:
                    time.sleep(0.1)
        return False

    @staticmethod
    @contextlib.contextmanager
    def listening(port: int):
        """Holds the port with a listening socket."""
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            s.bind(("", port))
            s.listen()
            yield s

    def telegram(self, *args: str, **env: str) -> subprocess.CompletedProcess:
        """Runs telegram.sh with the fake gh on the PATH and Telegram not configured."""
        environ = {k: v for k, v in os.environ.items() if not k.startswith("TELEGRAM_")}
        environ.update(env, PATH=f"{self.bin}:{environ['PATH']}")
        return subprocess.run(
            [str(self.loop / "core" / "telegram.sh"), *args],
            cwd=self.repo,
            env=environ,
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )

    def stage(self, progress: str) -> str:
        """The stage kickoff.sh prints for the given PROGRESS.md text."""
        self.write_progress(progress)
        result = self.run_loop(None, "--print-stage")
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def call(self, function: str, *args: str, timeout: int = 20, **env: str) -> subprocess.CompletedProcess:
        """Runs one pull-request function of kickoff.sh with the fake gh on the PATH, log and notify stubbed.

        The judge's triage run is stubbed too: it leaves FAKE_RESULT as its result file, or fails with
        FAKE_INVOKE_RC, and keeps the prompt it was given as log/prompt.
        """
        log_dir = self.tmp / "log"
        log_dir.mkdir(exist_ok=True)
        script = f"""set -uo pipefail
HERE={self.loop}/core; AUTOLOOP_REL=tools/autoloop; REPO_ROOT={self.repo}
LOG_DIR={log_dir}; RUN_LOG={log_dir}/kickoff.log
PROGRESS={self.repo}/PROGRESS.md; QUESTIONS={self.repo}/QUESTIONS.md
MERGE_POLL_S=1; CHECK_POLL_S=1; CI_REOPEN_LIMIT=${{CI_REOPEN_LIMIT:-3}}; CI_FIX_ACCEPTANCE=tools/lint/lint.sh
LOCAL_GATE="${{LOCAL_GATE:-true}}"; LOCAL_GATE_TIMEOUT_S=60
GIT_REMOTE=origin; BASE_BRANCH=main; DEPENDABOT_MERGE=${{DEPENDABOT_MERGE:-squash}}
DEPENDABOT_TRIAGE=${{DEPENDABOT_TRIAGE:-judge}}; JUDGE_MODEL=opus; JUDGE_MAX_TURNS=40; JUDGE_LOG={log_dir}/judge.log
log() {{ echo "LOG: $*"; }}
notify() {{ echo "NOTIFY: $*"; }}
prompt_file() {{ echo "$HERE/prompts/$1.md"; }}
invoke() {{
  echo "INVOKE: $1 $2 $4"
  cp "$3" "$LOG_DIR/prompt"
  [[ -z "${{FAKE_INVOKE_RC:-}}" ]] || return "$FAKE_INVOKE_RC"
  printf '%s' "${{FAKE_RESULT:-}}" > "$LOG_DIR/20261101T000000Z-$1.json"
}}
progress_field() {{ sed -n "s/^$1: *//p" "$PROGRESS" | head -1 | tr -d '[:space:]'; }}
source <(sed -n '{PR_FUNCTIONS}' tools/autoloop/core/kickoff.sh)
{function} "$@"
"""
        environ = {**os.environ, **IDENTITY, "FAKE_MERGED": str(self.merged), "FAKE_RERUN": str(self.rerun), **env}
        environ["PATH"] = f"{self.bin}:{os.environ['PATH']}"
        return subprocess.run(
            ["timeout", str(timeout), "bash", "-c", script, "bash", *args],
            cwd=self.repo,
            env=environ,
            capture_output=True,
            text=True,
            timeout=timeout + 5,
            check=False,
        )

    # History line

    def history(self, title: str, milestone: str = "M14", date: str = "2026-11-08") -> list[str]:
        """The lines history_line prints for a title."""
        result = self.call("history_line", date, milestone, title, f"tools/autoloop/archive/{milestone}")
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.splitlines()

    def test_history_line_wraps_the_m14_entry(self):
        self.assertEqual(
            self.history("auth and admin app"),
            ["- **2026-11-08, milestone M14 done.** auth and admin app", "  (tools/autoloop/archive/M14)."],
        )

    def test_history_line_short_title_is_one_line(self):
        self.assertEqual(
            self.history("first", "M1"), ["- **2026-11-08, milestone M1 done.** first (tools/autoloop/archive/M1)."]
        )

    def test_history_line_long_title_wraps_at_80(self):
        title = " ".join(f"word{i:02d}" for i in range(30))[:200]
        lines = self.history(title)
        self.assertGreater(len(lines), 2)
        self.assertTrue(all(len(line) <= 80 for line in lines), lines)
        self.assertTrue(all(line.startswith("  ") and not line.startswith("   ") for line in lines[1:]))
        self.assertTrue(lines[0].startswith("- **2026-11-08, milestone M14 done.** "))
        self.assertEqual(
            " ".join(" ".join(lines).split()),
            f"- **2026-11-08, milestone M14 done.** {title} (tools/autoloop/archive/M14).",
        )

    def test_history_line_continuation_never_starts_with_markup(self):
        carried = 0
        for marker in ("-", "#", ">", "1."):
            for pad in range(40, 43):
                lines = self.history("x" * pad + f" {marker} tail words")
                for line in lines[1:]:
                    self.assertNotRegex(line.lstrip(), r"^([-+*#>|<=~`]|\d+[.)])", (marker, pad, lines))
                    self.assertLessEqual(len(line), 80, lines)
                # The marker crossed column 80, so the word before it moved down with it.
                if lines[1].startswith("  " + "x" * pad + f" {marker}"):
                    carried += 1
        self.assertGreaterEqual(carried, 4)

    def test_history_line_markup_carry_never_exceeds_80_columns(self):
        lines = self.history(" ".join(["-"] * 40))
        self.assertGreater(len(lines), 1)
        self.assertTrue(all(len(line) <= 80 for line in lines), lines)

    def test_history_line_carry_that_would_overflow_is_undone(self):
        lines = self.history("- " * 20 + "-" + "x" * 40 + " tail")
        self.assertTrue(all(len(line) <= 80 for line in lines), lines)

    def test_history_line_carry_stopped_by_a_plain_word_is_undone_by_length(self):
        # The carry stops on the plain word, so only the length check undoes it.
        lines = self.history("p" * 41 + " b " + "y" * 60 + " - - -" + "x" * 20)
        self.assertTrue(all(len(line) <= 80 for line in lines), lines)
        self.assertEqual(lines[1], "  b " + "y" * 60 + " - -")

    def test_history_line_long_markup_run_does_not_degrade_to_one_word_per_line(self):
        lines = self.history("aa " + "- " * 60)
        self.assertTrue(all(len(line) <= 80 for line in lines), lines)
        self.assertTrue(all(len(line) >= 10 for line in lines[:-1]), lines)

    def test_history_line_empty_title_has_no_double_space(self):
        lines = self.history("")
        self.assertEqual(lines, ["- **2026-11-08, milestone M14 done.** (tools/autoloop/archive/M14)."])
        self.assertNotIn("  ", lines[0])

    def test_archive_milestone_repairs_a_missing_final_newline_and_is_idempotent(self):
        history = self.repo / "HISTORY.md"
        history.write_text("# History\n\n- last line")
        env = {"ARCHIVE_ROOT": str(self.loop / "archive")}
        self.assertEqual(self.call("archive_milestone", **env).returncode, 0)
        text = history.read_text()
        self.assertEqual(text.splitlines()[:3], ["# History", "", "- last line"])
        self.assertRegex(
            text.splitlines()[3], r"^- \*\*\d{4}-\d\d-\d\d, milestone M1 done\.\*\* first \(\S+/archive/M1\)\.$"
        )
        self.assertEqual(len(text.splitlines()), 4)
        self.assertTrue(text.endswith("\n"))
        self.assertEqual(self.call("archive_milestone", **env).returncode, 0)
        self.assertEqual(history.read_text(), text)

    # Stage choice

    def test_open_task_is_task(self):
        self.assertEqual(self.stage(HEADER + TASK + LOG), "task")

    def test_done_unverified_is_verify(self):
        self.assertEqual(self.stage(HEADER + TASK.replace("[ ]", "[x]") + LOG), "verify")

    def test_all_verified_is_plan(self):
        text = HEADER + TASK.replace("[ ]", "[x]").replace("verified:\n", "verified: ok\n") + LOG
        self.assertEqual(self.stage(text), "plan")

    def test_no_tasks_is_plan(self):
        self.assertEqual(self.stage(HEADER + "(none yet)\n" + LOG), "plan")

    def test_blocked(self):
        self.assertEqual(self.stage(BLOCKED_HEADER + TASK + LOG), "blocked")

    def test_repeated_field_is_bad_progress(self):
        self.assertEqual(self.stage(HEADER + TASK + "  - files: again\n" + LOG), "bad_progress")

    def test_field_before_any_task_is_bad_progress(self):
        self.assertEqual(self.stage(HEADER + "  - files: lost\n" + TASK + LOG), "bad_progress")

    def test_orphan_under_blocked_still_blocked(self):
        self.assertEqual(self.stage(BLOCKED_HEADER + TASK + "  - files: again\n" + LOG), "blocked")

    def test_real_progress_has_no_orphan(self):
        if not REAL_PROGRESS.exists():
            self.skipTest("no project PROGRESS.md around this core")
        text = re.sub(r"^STATUS: .*", "STATUS: RUNNING", REAL_PROGRESS.read_text(), count=1, flags=re.M)
        self.assertNotEqual(self.stage(text), "bad_progress")

    def test_orphan_in_running_loop_exits_3_without_a_call(self):
        self.write_progress(HEADER + TASK + "  - files: again\n" + LOG)
        result = self.run_loop(FAKE_COMMIT)
        self.assertEqual(result.returncode, 3)
        self.assertEqual(self.calls(), 0)

    def test_run_that_breaks_progress_is_restored_and_retried(self):
        result = self.run_loop(FAKE_BREAK_FIRST, MAX_ITERATIONS="2")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), 2)
        self.assertIn("- [ ] T1.1 First\n", self.read("PROGRESS.md"))
        self.assertIn("autoloop: restore PROGRESS.md, the task run left", git(self.repo, "log", "--format=%s"))
        self.assertIn("restored it and running task again", result.stdout)
        self.assertEqual(git(self.repo, "status", "--porcelain", "PROGRESS.md"), "")

    def test_uncommitted_break_is_restored_too(self):
        fake = FAKE_BREAK_ALWAYS.replace('git commit -q -am "broke the heading"', "true")
        result = self.run_loop(fake, "--once")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("- [ ] T1.1 First\n", self.read("PROGRESS.md"))
        self.assertEqual(git(self.repo, "status", "--porcelain", "PROGRESS.md"), "")

    def test_runs_that_keep_breaking_progress_stop_after_the_limit(self):
        result = self.run_loop(FAKE_BREAK_ALWAYS)
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertEqual(self.calls(), 3)
        self.assertEqual(git(self.repo, "log", "--format=%s").count("autoloop: restore PROGRESS.md"), 2)
        self.assertIn("task field outside a task", result.stdout)

    def test_weak_model_for_a_judging_run_is_a_setup_error(self):
        for var in ("PLAN_MODEL", "VERIFY_MODEL", "JUDGE_MODEL"):
            result = self.run_loop(FAKE_COMMIT, **{var: "sonnet"})
            self.assertEqual(result.returncode, 3, var)
            self.assertIn("Fable or Opus", result.stderr)
        self.assertEqual(self.calls(), 0)

    def test_unknown_dependabot_setting_is_a_setup_error(self):
        result = self.run_loop(FAKE_COMMIT, DEPENDABOT_MERGE="auto")
        self.assertEqual(result.returncode, 3)
        self.assertIn("DEPENDABOT_MERGE must be squash, merge, rebase, report or ignore, got 'auto'", result.stderr)
        result = self.run_loop(FAKE_COMMIT, DEPENDABOT_TRIAGE="sonnet")
        self.assertEqual(result.returncode, 3)
        self.assertIn("DEPENDABOT_TRIAGE must be judge or off, got 'sonnet'", result.stderr)
        self.assertEqual(self.calls(), 0)

    def test_task_model_line_picks_the_model(self):
        fake = f'#!/usr/bin/env bash\nprintf "%s\\n" "$@" > "{self.tmp}/args"\n' + FAKE_COMMIT.split("\n", 1)[1]
        self.write_progress(HEADER + TASK.replace("  - notes:\n", "  - model: opus\n  - notes:\n") + LOG)
        git(self.repo, "commit", "-q", "-am", "model line")
        self.run_loop(fake, "--once")
        args = (self.tmp / "args").read_text().splitlines()
        self.assertEqual(args[args.index("--model") + 1], "opus")

    # Progress guard

    def test_runs_without_commit_block_and_ask(self):
        # Two task runs without a commit or a PROGRESS.md change: STATUS BLOCKED with a question; the fake,
        # as the judge, changes nothing, so the owner is asked (Telegram not configured: exit 2).
        result = self.run_loop(FAKE_OK, NO_PROGRESS_LIMIT="2")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(self.calls(), 3)
        progress = self.read("PROGRESS.md")
        self.assertTrue(progress.startswith("STATUS: BLOCKED"))
        questions = self.read("QUESTIONS.md")
        self.assertIn("\n## Q1 (2026-", questions)
        self.assertIn("2 task runs ended with no commit. Last result:", questions)
        self.assertIn("\nThe last run said: ok\n", questions)
        self.assertIn(
            "no progress after 2 task runs on M1. The last run said: ok The judge reads it next.", result.stdout
        )
        self.assertIn("blocked after 2 runs", git(self.repo, "log", "--format=%s"))
        self.assertIn("judge run changed nothing", result.stdout)
        self.assertIn("telegram (not configured):\nautoloop question 1", result.stdout)
        self.assertFalse((self.loop / "log" / "judge.log").exists())
        self.assertEqual(git(self.repo, "status", "--porcelain", "PROGRESS.md", "QUESTIONS.md"), "")

    def test_no_progress_reason_is_one_line_and_cut(self):
        fake = '#!/usr/bin/env bash\necho x >> "$FAKE_COUNT"\n' + (
            'echo \'{"is_error": false, "result": "waiting for\\n\\nthe release ' + "x" * 50 + "\"}'\n"
        )
        self.run_loop(fake, NO_PROGRESS_LIMIT="1", RUN_REASON_CHARS="30")
        self.assertIn("\nThe last run said: waiting for the release xxxxx…\n", self.read("QUESTIONS.md"))

    def test_runs_that_only_touch_progress_block_after_twice_the_limit(self):
        result = self.run_loop(FAKE_APPEND, NO_PROGRESS_LIMIT="2")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(self.calls(), 5)
        self.assertIn(
            "4 task runs ended with no commit (PROGRESS.md was changed but never committed)", self.read("QUESTIONS.md")
        )
        self.assertEqual(self.read("PROGRESS.md").count("- appended"), 5)

    def test_next_question_number_follows_the_last(self):
        (self.repo / "QUESTIONS.md").write_text("# Questions\n\n## Q19 (2026-11-01): old\nAnswer: x\n")
        git(self.repo, "commit", "-q", "-am", "q19")
        self.run_loop(FAKE_OK, NO_PROGRESS_LIMIT="2")
        self.assertIn("## Q20 ", self.read("QUESTIONS.md"))

    def test_commits_every_time_run_to_the_cap(self):
        result = self.run_loop(FAKE_COMMIT, MAX_ITERATIONS="3")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), 3)
        self.assertTrue(self.read("PROGRESS.md").startswith("STATUS: RUNNING"))

    def test_runs_cannot_start_subagents(self):
        fake = f'#!/usr/bin/env bash\nprintf "%s\\n" "$@" > "{self.tmp}/args"\n' + FAKE_COMMIT.split("\n", 1)[1]
        self.run_loop(fake, "--once")
        args = (self.tmp / "args").read_text().splitlines()
        self.assertEqual(args[args.index("--disallowedTools") + 1], "Agent,Workflow")
        self.assertTrue(args[args.index("--disallowedTools") + 2].startswith("--"))

    def test_a_commit_resets_the_counter(self):
        result = self.run_loop(FAKE_COMMIT_SECOND, NO_PROGRESS_LIMIT="2", MAX_ITERATIONS="3")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), 3)
        self.assertTrue(self.read("PROGRESS.md").startswith("STATUS: RUNNING"))

    def test_usage_limit_waits_and_is_not_counted_as_no_progress(self):
        # The first run reports the 5-hour limit: the wrapper sleeps (the default, as the reset is not parsable)
        # and runs the same stage again; the run is not a strike against NO_PROGRESS_LIMIT.
        result = self.run_loop(FAKE_LIMIT_ONCE, NO_PROGRESS_LIMIT="1", MAX_ITERATIONS="2", LIMIT_SLEEP_DEFAULT_S="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), 2)
        self.assertIn("usage limit: sleeping 1s", result.stdout)
        self.assertNotIn("no commit and no PROGRESS.md change", result.stdout)
        self.assertTrue(self.read("PROGRESS.md").startswith("STATUS: RUNNING"))
        self.assertNotIn("\n## Q1 (2026-", self.read("QUESTIONS.md"))

    def test_limit_reset_clock_time_becomes_an_epoch(self):
        # The classifier reads "resets 5:20pm (UTC)" as the next 17:20 UTC, within the coming 24 h.
        script = CORE / "kickoff.sh"
        lines = script.read_text().splitlines()
        start = next(i for i, line in enumerate(lines) if "<<'PY'" in line and "out_file" in line) + 1
        end = next(i for i in range(start, len(lines)) if lines[i] == "PY")
        out = self.tmp / "limit.json"
        out.write_text('{"is_error": true, "result": "You\u2019ve hit your 5-hour limit \u00b7 resets 5:20pm (UTC)"}')
        verdict = subprocess.run(
            ["python3", "-I", "-", str(out)],
            input="\n".join(lines[start:end]),
            capture_output=True,
            text=True,
            check=True,
            timeout=20,
        ).stdout.strip()
        self.assertRegex(verdict, r"^LIMIT \d{10}$")
        import datetime as dt

        reset = dt.datetime.fromtimestamp(int(verdict.split()[1]), dt.timezone.utc)
        now = dt.datetime.now(dt.timezone.utc)
        self.assertEqual((reset.hour, reset.minute), (17, 20))
        self.assertTrue(now < reset <= now + dt.timedelta(days=1))

    # The judge

    def block_with_question(self, question: str = OPEN_Q) -> None:
        self.write_progress(BLOCKED_HEADER + TASK + LOG)
        (self.repo / "QUESTIONS.md").write_text(QUESTIONS_HEADER + question)
        git(self.repo, "commit", "-q", "-am", "blocked with Q1")

    def test_judge_answers_and_the_loop_resumes(self):
        self.block_with_question()
        result = self.run_loop(FAKE_JUDGE_ANSWERS, MAX_ITERATIONS="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), 1)
        self.assertTrue(self.read("PROGRESS.md").startswith("STATUS: RUNNING"))
        self.assertIn("(judge, 2026-11-01)", self.read("QUESTIONS.md"))
        self.assertIn("| 8080 (judge) |", self.read("DECISIONS.md"))
        judge_log = (self.loop / "log" / "judge.log").read_text()
        self.assertRegex(
            judge_log,
            r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ Q1 answered: 8080, TECH_STACK.md section 2 \(judge, 2026-11-01\)\n$",
        )
        self.assertIn("every question answered by the judge; resuming", result.stdout)
        self.assertIn("telegram (not configured): autoloop: judge on M1: Q1 answered: 8080", result.stdout)
        self.assertEqual(git(self.repo, "status", "--porcelain"), "")

    def test_judge_answer_in_brackets_is_an_answer(self):
        self.block_with_question()
        result = self.run_loop(FAKE_JUDGE_ANSWERS_OPTION, MAX_ITERATIONS="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.read("PROGRESS.md").startswith("STATUS: RUNNING"))
        self.assertIn("Q1 answered: (a). TECH_STACK.md section 2 (judge, 2026-11-01)", result.stdout)
        self.assertEqual(self.qa("list", "--ids").stdout.strip(), "")

    def test_placeholder_answers_stay_open(self):
        for placeholder in ("", "(human)", "[owner]", "(tbd)", "---", "pending", "?"):
            with self.subTest(placeholder=placeholder):
                (self.repo / "QUESTIONS.md").write_text(
                    QUESTIONS_HEADER + OPEN_Q.replace("Answer:", f"Answer: {placeholder}")
                )
                self.assertEqual(self.qa("list", "--ids").stdout.strip(), "1")
        for answer in ("(a)", "(2)", "(a) (telegram, 2026-11-01)", "8080 (telegram, 2026-11-01)"):
            with self.subTest(answer=answer):
                (self.repo / "QUESTIONS.md").write_text(
                    QUESTIONS_HEADER + OPEN_Q.replace("Answer:", f"Answer: {answer}")
                )
                self.assertEqual(self.qa("list", "--ids").stdout.strip(), "")

    def test_answer_to_a_reused_id_goes_to_the_open_question(self):
        """A run reused Q1 for a second question; the owner's reply lands on the open one, not the judged one."""
        judged = OPEN_Q.replace("Answer:", "Answer: 8080, TECH_STACK.md section 2 (judge, 2026-11-01)")
        second = "## Q1 (2026-11-02, task T1.2): which port does the broker listen on?\nContext: one option.\nAnswer:\n"
        self.block_with_question(judged + "\n" + second)
        answers = self.tmp / "answers.txt"
        answers.write_text("Q1 1883\n")
        self.qa("wait", "--from-file", str(answers))
        questions = self.read("QUESTIONS.md")
        self.assertIn("Answer: 8080, TECH_STACK.md section 2 (judge, 2026-11-01)\n", questions)
        self.assertRegex(
            questions, r"broker listen on\?\nContext: one option\.\nAnswer: 1883 \(file, \d{4}-\d\d-\d\d\)\n"
        )
        self.assertIn(
            "| Q1 (2026-11-02, task T1.2): which port does the broker listen on? | 1883 |\n", self.read("DECISIONS.md")
        )
        self.assertTrue(self.read("PROGRESS.md").startswith("STATUS: RUNNING"))
        self.assertEqual(self.qa("list", "--ids").stdout.strip(), "")
        self.assertEqual(git(self.repo, "status", "--porcelain"), "")

    def qa(self, *args: str) -> subprocess.CompletedProcess:
        """Runs qa.py in the repository without Telegram configured."""
        environ = {**{k: v for k, v in os.environ.items() if not k.startswith("TELEGRAM_")}, **IDENTITY}
        return subprocess.run(
            ["python3", "-I", str(self.loop / "core" / "qa.py"), *args],
            cwd=self.repo,
            env=environ,
            capture_output=True,
            text=True,
            timeout=60,
            check=True,
        )

    def test_judge_forgot_status_and_the_wrapper_reconciles(self):
        self.block_with_question()
        result = self.run_loop(FAKE_JUDGE_ANSWERS, MAX_ITERATIONS="1", FAKE_FORGET_STATUS="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.read("PROGRESS.md").startswith("STATUS: RUNNING"))
        self.assertEqual(git(self.repo, "log", "-1", "--format=%s"), "autoloop: STATUS RUNNING after the judge run\n")
        self.assertIn("STATUS set to RUNNING by the wrapper", (self.loop / "log" / "judge.log").read_text())

    def test_judge_passes_and_the_owner_is_asked_with_the_reason(self):
        self.block_with_question()
        result = self.run_loop(FAKE_JUDGE_PASSES)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(self.calls(), 1)
        self.assertTrue(self.read("PROGRESS.md").startswith("STATUS: BLOCKED"))
        judge_log = (self.loop / "log" / "judge.log").read_text()
        self.assertIn("Q1 passed to the owner: cannot answer: the owner's call (2026-11-01)", judge_log)
        self.assertIn("Judge: cannot answer: the owner's call", result.stdout)
        self.assertIn("1 question(s) for you in QUESTIONS.md", result.stdout)

    def test_judge_that_changes_nothing_hands_over_to_the_owner(self):
        self.block_with_question()
        result = self.run_loop(FAKE_OK)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(self.calls(), 1)
        self.assertIn("judge run changed nothing; the owner is asked", result.stdout)
        self.assertFalse((self.loop / "log" / "judge.log").exists())

    def test_already_passed_question_is_not_judged_again(self):
        self.block_with_question(PASSED_Q)
        result = self.run_loop(FAKE_JUDGE_ANSWERS)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(self.calls(), 0)
        self.assertNotIn("judge run on", result.stdout)

    def test_empty_judge_line_is_still_judged(self):
        """A run copied a judged question's layout and left "Judge:" empty: the judge still runs on it."""
        self.block_with_question(OPEN_Q.replace("Answer:", "Judge:\nAnswer:"))
        self.assertEqual(self.qa("list", "--ids", "--unjudged").stdout.strip(), "1")
        result = self.run_loop(FAKE_JUDGE_ANSWERS, MAX_ITERATIONS="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), 1)
        self.assertIn("judge run on Q1", result.stdout)
        self.assertTrue(self.read("PROGRESS.md").startswith("STATUS: RUNNING"))

    def test_judge_once_stops_after_the_judge_run(self):
        self.block_with_question()
        result = self.run_loop(FAKE_JUDGE_ANSWERS, "--once")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), 1)
        self.assertIn("stopping after one stage", result.stdout)

    def test_status_report_carries_the_judge_lines(self):
        self.block_with_question()
        self.run_loop(FAKE_JUDGE_ANSWERS, MAX_ITERATIONS="1")
        result = self.telegram("status-text")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("autoloop M1 | RUNNING | autoloop/M1", result.stdout)
        self.assertIn("open 1, in progress 0, reopened 0, done 0 (verifying 0)", result.stdout)
        self.assertIn("commits since the last report:\n- Judge: answered Q1", result.stdout)
        self.assertRegex(result.stdout, r"judge:\n\d\d:\d\d Q1 answered: 8080")
        # Sending (not configured: printed) remembers the time; the next report starts there.
        sent = self.telegram("status")
        self.assertIn("telegram (not configured): autoloop M1", sent.stdout)
        self.assertTrue((self.loop / "log" / "status.last").read_text().strip().isdigit())
        again = self.telegram("status-text")
        self.assertIn("judge:\n- nothing answered or passed", again.stdout)

    def test_status_report_survives_a_long_backlog_and_is_cut_to_the_limit(self):
        # A day of failed sends leaves an old stamp and more judge lines than the report shows: the
        # writer's broken pipe must not empty the report, and the message stays under Telegram's limit.
        log_dir = self.loop / "log"
        log_dir.mkdir(exist_ok=True)
        (log_dir / "status.last").write_text("1000000000\n")
        (log_dir / "judge.log").write_text(
            "".join(f"2026-11-08T10:{i % 60:02d}:00Z Q{i} answered: " + "x" * 600 + "\n" for i in range(400))
        )
        environ = {k: v for k, v in os.environ.items() if not k.startswith("TELEGRAM_")}
        text = subprocess.run(
            [str(self.loop / "core" / "telegram.sh"), "status-text"],
            cwd=self.repo,
            env=environ,
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
        self.assertEqual(text.returncode, 0, text.stderr)
        self.assertIn("autoloop M1 | RUNNING", text.stdout)
        self.assertEqual(text.stdout.count(" answered: "), 8)
        sent = subprocess.run(
            [str(self.loop / "core" / "telegram.sh"), "status"],
            cwd=self.repo,
            env=environ,
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
        self.assertEqual(sent.returncode, 0, sent.stderr)
        message = sent.stdout.removeprefix("telegram (not configured): ").rstrip("\n")
        self.assertLessEqual(len(message), 4000)
        self.assertTrue(message.endswith("(... cut short)"))

    def test_status_report_counts_done_tasks_awaiting_verification(self):
        # Two done tasks, one verified and one not, and an open one: done 2, verifying 1.
        verified = (
            TASK.replace("T1.1 First", "T1.0 Zero").replace("- [ ]", "- [x]").replace("verified:", "verified: abc ok")
        )
        unverified = TASK.replace("T1.1 First", "T1.2 Second").replace("- [ ]", "- [x]")
        self.write_progress(HEADER + verified + unverified + TASK + LOG)
        result = self.telegram("status-text")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("open 1, in progress 0, reopened 0, done 2 (verifying 1)", result.stdout)

    def test_status_report_counts_the_open_dependabot_pull_requests(self):
        result = self.telegram("status-text", FAKE_PRS_COUNT="2")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("done 0 (verifying 0); Dependabot PRs open: 2\n", result.stdout)

    # Pull request body and checks

    def test_pull_request_body_is_cut_to_the_budget(self):
        long_log = LOG + "".join(f"- 2026-11-02 line {i} " + "x" * 80 + "\n" for i in range(200))
        self.write_progress(DONE_HEADER + TASK.replace("[ ]", "[x]") + long_log)
        body = self.tmp / "body.md"
        result = self.call("write_pr_body", str(body), "4000")
        self.assertEqual(result.returncode, 0, result.stderr)
        text = body.read_text()
        self.assertLessEqual(len(text), 4000)
        self.assertTrue(text.startswith("Milestone M1: first\n"))
        self.assertIn("- T1.1 First", text)
        self.assertTrue(text.endswith("the whole of it is in tools/autoloop/archive/M1/PROGRESS.md.)\n"))
        whole = self.call("write_pr_body", str(body))
        self.assertEqual(whole.returncode, 0, whole.stderr)
        self.assertIn("line 199", body.read_text())

    def test_red_check_on_the_pull_request_is_reported(self):
        self.write_progress(DONE_HEADER + TASK + LOG)
        result = self.call("wait_for_pr")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(result.stdout.strip(), "fail gate https://example.invalid/actions/runs/42/job/7")

    def test_billing_refusal_runs_the_local_gate_and_waits_for_the_merge_when_green(self):
        self.write_progress(DONE_HEADER + TASK + LOG)
        marker = self.tmp / "gate-ran"
        result = self.call("wait_for_pr", timeout=4, FAKE_BILLING="1", LOCAL_GATE=f"echo x >> {marker}")
        self.assertEqual(result.returncode, 124, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr.count("NOTIFY:"), 1, result.stderr)
        self.assertIn("the local gate is green", result.stderr)
        self.assertIn("refused to start CI", result.stderr)
        # Once per head, not on every poll.
        self.assertEqual(marker.read_text(), "x\n")

    def test_billing_refusal_with_a_red_local_gate_reports_the_gate(self):
        self.write_progress(DONE_HEADER + TASK + LOG)
        git(self.repo, "commit", "-q", "-am", "done")
        sha = git(self.repo, "rev-parse", "--short", "HEAD").strip()
        result = self.call(
            "wait_for_pr", FAKE_BILLING="1", LOCAL_GATE="echo 'make: *** [Makefile:4: test-fast] Error 2'; exit 2"
        )
        self.assertEqual(result.returncode, 2, result.stderr)
        gate_log = self.tmp / "log" / f"local-gate-{sha}.log"
        self.assertEqual(result.stdout.strip(), f"fail local-gate {gate_log}")
        reopened = self.call("reopen_for_ci", result.stdout.strip())
        self.assertEqual(reopened.returncode, 0, reopened.stderr)
        progress = self.read("PROGRESS.md")
        self.assertIn(f"- [ ] T1.2 Make CI green on the pull request: check local-gate failed on {sha}", progress)
        self.assertIn("  - acceptance: `tools/lint/lint.sh && make test-fast`\n", progress)
        self.assertIn("test-fast] Error 2", (self.tmp / "log" / f"ci-M1-{sha}.log").read_text())

    def test_a_failure_that_is_not_billing_is_not_covered_by_the_local_gate(self):
        self.write_progress(DONE_HEADER + TASK + LOG)
        marker = self.tmp / "gate-ran"
        result = self.call("wait_for_pr", LOCAL_GATE=f"echo x >> {marker}")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertFalse(marker.exists())

    def test_checks_are_judged_only_on_the_pull_request_head(self):
        self.write_progress(DONE_HEADER + TASK + LOG)
        result = self.call("wait_for_pr", timeout=3, FAKE_HEAD="f" * 40)
        self.assertEqual(result.returncode, 124, result.stderr)
        self.assertEqual(result.stdout, "")

    def test_commit_after_green_is_judged_again(self):
        self.write_progress(DONE_HEADER + TASK + LOG)
        green = git(self.repo, "rev-parse", "HEAD").strip()
        result = self.call("wait_for_pr", FAKE_GREEN_AT=green, FAKE_THEN_COMMIT="1")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(result.stdout.strip(), "fail gate https://example.invalid/actions/runs/42/job/7")
        self.assertIn(f"checks green on autoloop/M1 at {green}", result.stderr)
        self.assertNotEqual(git(self.repo, "rev-parse", "HEAD").strip(), green)

    def test_push_from_outside_is_fast_forwarded_and_judged(self):
        self.write_progress(DONE_HEADER + TASK + LOG)
        remote = self.tmp / "remote.git"
        git(self.tmp, "init", "-q", "--bare", str(remote))
        git(self.repo, "remote", "add", "origin", str(remote))
        git(self.repo, "push", "-q", "origin", "autoloop/M1")
        other = self.tmp / "other"
        git(self.tmp, "clone", "-q", "-b", "autoloop/M1", str(remote), str(other))
        git(other, "commit", "-q", "--allow-empty", "-m", "merge main")
        git(other, "push", "-q", "origin", "autoloop/M1")
        pushed = git(other, "rev-parse", "HEAD").strip()
        result = self.call("wait_for_pr", FAKE_HEAD=pushed)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(result.stdout.strip(), "fail gate https://example.invalid/actions/runs/42/job/7")
        self.assertIn(f"pull request head moved to {pushed}", result.stderr)
        self.assertEqual(git(self.repo, "rev-parse", "HEAD").strip(), pushed)

    def test_red_check_reopens_the_milestone_with_a_fix_task(self):
        self.write_progress(DONE_HEADER + TASK + LOG)
        git(self.repo, "commit", "-q", "-am", "done")
        sha = git(self.repo, "rev-parse", "--short", "HEAD").strip()
        result = self.call("reopen_for_ci", "fail gate https://example.invalid/actions/runs/42/job/7")
        self.assertEqual(result.returncode, 0, result.stderr)
        progress = self.read("PROGRESS.md")
        self.assertTrue(progress.startswith("STATUS: RUNNING"))
        self.assertIn(f"- [ ] T1.2 Make CI green on the pull request: check gate failed on {sha}", progress)
        self.assertIn("Process completed with exit code 1", progress)
        self.assertIn("##[error]", (self.tmp / "log" / f"ci-M1-{sha}.log").read_text())
        self.assertIn("  - acceptance: `tools/lint/lint.sh`\n", progress)
        self.assertEqual(
            git(self.repo, "log", "-1", "--format=%s"), "Reopen M1: CI red on the pull request, T1.2 makes it green\n"
        )
        self.assertEqual(git(self.repo, "status", "--porcelain", "PROGRESS.md"), "")

    def ci_task(self, log: str) -> str:
        """Runs ci_task.py on a saved log in the repository and returns the new task's acceptance line."""
        logfile = self.tmp / "ci.log"
        logfile.write_text(log)
        subprocess.run(
            [
                "python3",
                "-I",
                str(self.loop / "core" / "ci_task.py"),
                str(self.repo / "PROGRESS.md"),
                "M1",
                "abc1234",
                "tests",
                "https://example.invalid/pull/1",
                str(logfile),
                "tools/lint/lint.sh",
            ],
            cwd=self.repo,
            check=True,
            capture_output=True,
            text=True,
            timeout=60,
        )
        return next(line for line in self.read("PROGRESS.md").splitlines() if line.startswith("  - acceptance: `tools"))

    def test_fix_task_acceptance_reruns_the_innermost_failed_make_target_of_each_job(self):
        (self.repo / "Makefile").write_text("all:\n")
        (self.repo / "svc" / "sim").mkdir(parents=True)
        (self.repo / "svc" / "sim" / "Makefile").write_text("test:\n")
        runner = "/home/runner/work/proj/proj"
        prefix = "tests\tRun the suites\t2026-11-08T12:00:00.0000000Z "
        log = "".join(
            prefix + line + "\n"
            for line in (
                f"make[1]: Entering directory '{runner}'",
                f"make[2]: Entering directory '{runner}/svc/sim'",
                "E   AssertionError: make[9]: *** [Makefile:1: not-a-failure-line]",
                "make[2]: *** [Makefile:3: test] Error 1",
                f"make[2]: Leaving directory '{runner}/svc/sim'",
                "make[1]: *** [Makefile:12: test-all] Error 2",
                "make: *** [Makefile:4: test-fast] Error 2",
                "##[error]Process completed with exit code 2.",
            )
        )
        log = "# https://example.invalid/actions/runs/42/job/7\n" + log
        log += "# https://example.invalid/actions/runs/42/job/8\n"
        log += "lint\tLint\t2026-11-08T12:00:00.0000000Z make: *** [lint] Error 1\n"
        self.assertEqual(self.ci_task(log), "  - acceptance: `tools/lint/lint.sh && make -C svc/sim test && make lint`")

    def test_fix_task_acceptance_is_the_configured_command_without_a_failed_make_target(self):
        log = "# https://example.invalid/actions/runs/42/job/7\n"
        log += "gate\tTest\t##[error]Process completed with exit code 1.\n"
        self.assertEqual(self.ci_task(log), "  - acceptance: `tools/lint/lint.sh`")

    def test_fix_tasks_are_capped_with_a_question(self):
        fix = (
            "- [x] T1.2 Make CI green on the pull request: check gate failed on 0000000\n"
            "  - notes: tried\n  - verified: ok\n"
        )
        self.write_progress(DONE_HEADER + TASK + fix + LOG)
        git(self.repo, "commit", "-q", "-am", "done again")
        result = self.call(
            "reopen_for_ci", "fail gate https://example.invalid/actions/runs/42/job/7", CI_REOPEN_LIMIT="1"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.read("PROGRESS.md").startswith("STATUS: BLOCKED"))
        questions = self.read("QUESTIONS.md")
        self.assertIn("\n## Q1 (2026-", questions)
        self.assertIn("still red on the M1 pull request after 1 fix tasks", questions)
        self.assertIn("blocked, CI red on M1 after 1 fix tasks", git(self.repo, "log", "-1", "--format=%s"))

    def test_green_run_with_warnings_is_withdrawn_once(self):
        self.write_progress(DONE_HEADER + TASK + LOG)
        git(self.repo, "commit", "-q", "-am", "done")
        sha = git(self.repo, "rev-parse", "HEAD").strip()
        result = self.call("consider_annotations", "the branch", "42")
        self.assertEqual(result.returncode, 1, result.stderr)
        progress = self.read("PROGRESS.md")
        self.assertTrue(progress.startswith("STATUS: RUNNING"))
        last = progress.splitlines()[-1]
        self.assertIn("wrapper: CI green on the branch", last)
        self.assertIn("1 warning annotation(s)", last)
        self.assertIn("tools/autoloop/log/ci-annotations-", last)
        self.assertIn("Node.js 20 is deprecated", last)
        self.assertTrue(
            (self.tmp / "log" / f"ci-annotations-{sha[:7]}.txt").read_text().startswith("warning: .github:2")
        )
        self.assertEqual(
            git(self.repo, "log", "-1", "--format=%s"), f"Reopen M1: 1 CI annotation(s) on {sha[:7]} to consider\n"
        )
        # The same set again in the milestone passes without a change.
        self.write_progress(DONE_HEADER + TASK + LOG)
        git(self.repo, "commit", "-q", "-am", "done again")
        again = self.call("consider_annotations", "the pull request", "42")
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertTrue(self.read("PROGRESS.md").startswith("STATUS: MILESTONE_DONE"))

    # Dependabot's pull requests

    def merges(self) -> list[str]:
        """The gh pr merge calls the scripted gh recorded."""
        return self.merged.read_text().splitlines() if self.merged.exists() else []

    def test_green_dependabot_pull_request_is_merged_and_the_base_brought_in(self):
        self.add_remote()
        git(self.repo, "commit", "-q", "--allow-empty", "-m", "branch work")
        landed = self.land_on_main("lock.txt", "2\n")
        result = self.call("check_dependabot_prs", FAKE_PRS=DEPENDABOT_PR)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.merges(), [f"pr merge 12 --squash --delete-branch --match-head-commit {DEPENDABOT_SHA}"])
        self.assertIn(
            "NOTIFY: autoloop: merged Dependabot pull request #12 (Bump x from 1 to 2) into main: its checks were "
            "green. https://example.invalid/pr/12",
            result.stdout,
        )
        self.assertIn("LOG: merged main into autoloop/M1 (Dependabot #12 Bump x from 1 to 2)", result.stdout)
        self.assertEqual(
            git(self.repo, "log", "-1", "--format=%s"),
            "Merge main into autoloop/M1: Dependabot #12 Bump x from 1 to 2\n",
        )
        self.assertIn(landed, git(self.repo, "log", "--format=%H"))
        self.assertEqual(self.read("lock.txt"), "2\n")
        self.assertEqual(git(self.repo, "status", "--porcelain"), "")
        # Nothing new on main: the next look merges nothing into the branch.
        again = self.call("check_dependabot_prs", FAKE_PRS=DEPENDABOT_PR)
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertNotIn("LOG: merged main", again.stdout)

    def reruns(self) -> list[str]:
        """The gh run rerun calls the scripted gh recorded."""
        return self.rerun.read_text().splitlines() if self.rerun.exists() else []

    def red(self, **env: str) -> subprocess.CompletedProcess:
        """One look at the Dependabot pull request #12 with a failed check."""
        result = self.call("check_dependabot_prs", **{"FAKE_PRS": DEPENDABOT_PR, "FAKE_PR_CHECKS": RED_CHECK, **env})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.merges(), [])
        return result

    def seen(self) -> str:
        return (self.tmp / "log" / "dependabot-seen").read_text()

    def test_red_dependabot_pull_request_without_triage_is_told_once_and_left(self):
        head = git(self.repo, "rev-parse", "HEAD")
        result = self.red(DEPENDABOT_TRIAGE="off")
        self.assertIn(
            "NOTIFY: autoloop: Dependabot pull request #12 (Bump x from 1 to 2) is RED: check gate failed on aaaaaaa; "
            "it is left to you. https://example.invalid/pr/12",
            result.stdout,
        )
        self.assertNotIn("INVOKE", result.stderr)
        self.assertEqual(git(self.repo, "rev-parse", "HEAD"), head)
        again = self.red(DEPENDABOT_TRIAGE="off")
        self.assertNotIn("NOTIFY", again.stdout)
        self.assertEqual(self.seen(), f"12 {DEPENDABOT_SHA} red\n")
        # A new head of the same pull request is looked at afresh.
        moved = DEPENDABOT_PR.replace(DEPENDABOT_SHA, "b" * 40)
        third = self.red(DEPENDABOT_TRIAGE="off", FAKE_PRS=moved)
        self.assertIn("is RED: check gate failed on bbbbbbb", third.stdout)

    def test_red_dependabot_pull_request_judged_flaky_runs_again_once(self):
        result = self.red(FAKE_RESULT=FLAKY)
        self.assertIn("LOG: judge run on the red Dependabot #12 at aaaaaaa (gate)", result.stdout)
        self.assertIn("INVOKE: dependabot opus 40", result.stderr)
        self.assertEqual(self.reruns(), ["run rerun 43 --failed"])
        self.assertIn(
            "NOTIFY: autoloop: Dependabot pull request #12 (Bump x from 1 to 2) is red on aaaaaaa (check gate) and the "
            "judge calls it flaky: npm answered 503 in step Install; Its failed jobs run again once: green is merged, "
            "red again is told to you. https://example.invalid/pr/12",
            result.stdout,
        )
        self.assertEqual(self.seen(), f"12 {DEPENDABOT_SHA} rerun\n")
        # The judge was given the pull request's facts and the files the wrapper saved for it.
        log_dir = self.tmp / "log"
        prompt = (log_dir / "prompt").read_text()
        self.assertTrue(prompt.startswith((CORE / "prompts" / "dependabot.md").read_text()))
        self.assertIn(
            f'The pull request: #12, "Bump x from 1 to 2", https://example.invalid/pr/12, head commit {DEPENDABOT_SHA}',
            prompt,
        )
        self.assertIn(f"{RED_CHECK}\nThe log of the failed jobs: {log_dir}/dependabot-12-aaaaaaa.log\n", prompt)
        self.assertEqual(
            (log_dir / "dependabot-12-aaaaaaa.log").read_text(),
            "# run 43\ngate\tInstall\tnpm ERR! 503 Service Unavailable\n",
        )
        self.assertEqual((log_dir / "dependabot-12-aaaaaaa.diff").read_text(), "-x==1\n+x==2\n")
        # The verdict is in the judge log, in the form the status report reads.
        self.assertRegex(
            (log_dir / "judge.log").read_text(),
            r"^\d{4}-\d\d-\d\dT[\d:]{8}Z Dependabot #12 at aaaaaaa judged flaky: npm answered 503 in step Install;\n$",
        )
        # Still being checked after the re-run: nothing. Green: merged like any other.
        pending = self.red(FAKE_PR_CHECKS="pending gate https://example.invalid/actions/runs/43/job/8")
        self.assertEqual(pending.stdout, "")
        # Red again on the same head: the owner is told, with no second judge run and no second re-run.
        again = self.red(FAKE_RESULT=FLAKY)
        self.assertIn(
            "NOTIFY: autoloop: Dependabot pull request #12 (Bump x from 1 to 2) is RED again after its failed jobs ran "
            "a second time: check gate failed on aaaaaaa. The judge had called the first failure flaky; it is left to "
            "you. https://example.invalid/pr/12",
            again.stdout,
        )
        self.assertNotIn("INVOKE", again.stderr)
        self.assertEqual(self.reruns(), ["run rerun 43 --failed"])
        third = self.red(FAKE_RESULT=FLAKY)
        self.assertEqual(third.stdout, "")
        self.assertEqual(self.seen(), f"12 {DEPENDABOT_SHA} rerun\n12 {DEPENDABOT_SHA} red\n")

    def test_green_after_the_rerun_is_merged(self):
        self.add_remote()
        self.red(FAKE_RESULT=FLAKY)
        result = self.call("check_dependabot_prs", FAKE_PRS=DEPENDABOT_PR)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.merges()), 1)

    def test_flaky_verdict_whose_rerun_fails_is_left_to_the_owner(self):
        result = self.red(FAKE_RESULT=FLAKY, FAKE_RERUN_RC="1")
        self.assertIn(
            "is RED: check gate failed on aaaaaaa. The judge calls it flaky: npm answered 503 in step Install; The "
            "failed jobs could not be started again (see kickoff.log); it is left to you.",
            result.stdout,
        )
        self.assertEqual(self.seen(), f"12 {DEPENDABOT_SHA} red\n")

    def test_red_dependabot_pull_request_judged_broken_is_told_with_the_reason(self):
        result = self.red(FAKE_RESULT=BREAK)
        self.assertIn(
            "NOTIFY: autoloop: Dependabot pull request #12 (Bump x from 1 to 2) is RED: check gate failed on aaaaaaa. "
            "The judge: the update breaks the build: tests/test_x.py fails on the removed x.old() call. It is left to "
            "you. https://example.invalid/pr/12",
            result.stdout,
        )
        self.assertEqual(self.reruns(), [])
        self.assertEqual(self.seen(), f"12 {DEPENDABOT_SHA} red\n")
        again = self.red(FAKE_RESULT=BREAK)
        self.assertEqual(again.stdout, "")
        self.assertNotIn("INVOKE", again.stderr)

    def test_red_dependabot_pull_request_the_judge_is_unsure_about_is_told(self):
        result = self.red(FAKE_RESULT=UNSURE)
        self.assertIn(
            "is RED: check gate failed on aaaaaaa. The judge could not tell a flaky check from a broken update: the "
            "log is empty. It is left to you.",
            result.stdout,
        )
        self.assertEqual(self.reruns(), [])

    def test_triage_without_a_verdict_tells_the_owner(self):
        for env in (
            {"FAKE_RESULT": verdict("It looks flaky to me.")},
            {"FAKE_RESULT": verdict("VERDICT: merge it\nREASON: none")},
            {"FAKE_RESULT": "not json"},
            {"FAKE_INVOKE_RC": "1"},
        ):
            with self.subTest(env=env):
                (self.tmp / "log" / "dependabot-seen").unlink(missing_ok=True)
                result = self.red(**env)
                self.assertIn(
                    "is RED: check gate failed on aaaaaaa; the judge run gave no verdict; it is left to you.",
                    result.stdout,
                )
                self.assertEqual(self.reruns(), [])
                self.assertFalse((self.tmp / "log" / "judge.log").exists())

    def test_verdict_reason_is_one_line_and_cut(self):
        result = self.red(FAKE_RESULT=verdict("VERDICT: break\nREASON: " + "long  words " * 60))
        line = next(x for x in result.stdout.splitlines() if x.startswith("NOTIFY"))
        reason = line.split("breaks the build: ")[1].split(" It is left")[0]
        self.assertEqual(len(reason), 300)
        self.assertTrue(reason.startswith("long words long words"))
        self.assertTrue(reason.endswith("…"))

    def test_triage_at_the_usage_limit_waits_for_the_next_look(self):
        result = self.red(FAKE_INVOKE_RC="75")
        self.assertNotIn("NOTIFY", result.stdout)
        self.assertIn("LOG: usage limit: the triage of Dependabot #12 waits for the next look", result.stdout)
        self.assertFalse((self.tmp / "log" / "dependabot-seen").exists())
        again = self.red(FAKE_RESULT=BREAK)
        self.assertIn("The judge: the update breaks the build", again.stdout)

    def test_checks_refused_for_billing_are_not_given_to_the_judge(self):
        checks = "fail gate https://example.invalid/actions/runs/42/job/7"
        result = self.red(FAKE_PR_CHECKS=checks, FAKE_BILLING="1", FAKE_RESULT=FLAKY)
        self.assertIn(
            "NOTIFY: autoloop: GitHub did not start check gate on Dependabot pull request #12 (Bump x from 1 to 2) "
            "(billing or spending limit), so nothing is known about aaaaaaa; it is left to you.",
            result.stdout,
        )
        self.assertNotIn("INVOKE", result.stderr)
        self.assertEqual(self.reruns(), [])
        again = self.red(FAKE_PR_CHECKS=checks, FAKE_BILLING="1", FAKE_RESULT=FLAKY)
        self.assertEqual(again.stdout, "")

    def test_loop_has_the_judge_triage_a_red_dependabot_pull_request(self):
        result = self.run_loop(FAKE_TRIAGE_FLAKY, "--once", FAKE_PRS=DEPENDABOT_PR, FAKE_PR_CHECKS=RED_CHECK)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("judge run on the red Dependabot #12 at aaaaaaa (gate)", result.stdout)
        self.assertIn(
            "telegram (not configured): autoloop: Dependabot pull request #12 (Bump x from 1 to 2) is red on aaaaaaa "
            "(check gate) and the judge calls it flaky: the registry answered 503.",
            result.stdout,
        )
        self.assertEqual(self.reruns(), ["run rerun 43 --failed"])
        self.assertEqual(self.merges(), [])
        # The triage run and the task run that follows it; the triage is no stage of the loop.
        self.assertEqual(self.calls(), 2)
        self.assertEqual(git(self.repo, "log", "-1", "--format=%s"), "fake work\n")
        self.assertEqual(git(self.repo, "status", "--porcelain"), "")
        status = self.telegram("status-text")
        self.assertRegex(
            status.stdout, r"judge:\n\d\d:\d\d Dependabot #12 at aaaaaaa judged flaky: the registry answered 503\."
        )

    def test_dependabot_pull_request_not_ready_waits_for_the_next_look(self):
        pending = "pending gate https://example.invalid/actions/runs/43/job/8"
        for prs, checks in (
            (DEPENDABOT_PR, pending),
            (DEPENDABOT_PR, ""),
            (DEPENDABOT_PR.replace("MERGEABLE", "CONFLICTING"), None),
            (DEPENDABOT_PR.replace("MERGEABLE||", "MERGEABLE|CHANGES_REQUESTED|"), None),
            (DEPENDABOT_PR.replace("|false|", "|true|"), None),
        ):
            env = {"FAKE_PRS": prs}
            if checks is not None:
                env["FAKE_PR_CHECKS"] = checks
            result = self.call("check_dependabot_prs", **env)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "", prs)
        self.assertEqual(self.merges(), [])
        self.assertFalse((self.tmp / "log" / "dependabot-seen").exists())

    def test_report_mode_tells_about_a_green_dependabot_pull_request_once(self):
        result = self.call("check_dependabot_prs", FAKE_PRS=DEPENDABOT_PR, DEPENDABOT_MERGE="report")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            "NOTIFY: autoloop: Dependabot pull request #12 (Bump x from 1 to 2) is green and mergeable; "
            "DEPENDABOT_MERGE=report, so the merge is yours.",
            result.stdout,
        )
        self.assertEqual(self.merges(), [])
        again = self.call("check_dependabot_prs", FAKE_PRS=DEPENDABOT_PR, DEPENDABOT_MERGE="report")
        self.assertNotIn("NOTIFY", again.stdout)
        ignored = self.call("check_dependabot_prs", FAKE_PRS=DEPENDABOT_PR, DEPENDABOT_MERGE="ignore")
        self.assertEqual(ignored.stdout, "")

    def test_failed_dependabot_merge_is_told_once(self):
        head = git(self.repo, "rev-parse", "HEAD")
        result = self.call("check_dependabot_prs", FAKE_PRS=DEPENDABOT_PR, FAKE_MERGE_RC="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            "NOTIFY: autoloop: could not merge the green Dependabot pull request #12 (Bump x from 1 to 2): gh pr merge "
            "failed",
            result.stdout,
        )
        self.assertEqual(len(self.merges()), 1)
        self.assertEqual(git(self.repo, "rev-parse", "HEAD"), head)
        again = self.call("check_dependabot_prs", FAKE_PRS=DEPENDABOT_PR, FAKE_MERGE_RC="1")
        self.assertNotIn("NOTIFY", again.stdout)

    def test_base_branch_that_conflicts_is_left_to_the_owner(self):
        self.add_remote()
        self.land_on_main("HISTORY.md", "# History\n- main's line\n")
        (self.repo / "HISTORY.md").write_text("# History\n- the branch's line\n")
        git(self.repo, "commit", "-q", "-am", "branch history")
        head = git(self.repo, "rev-parse", "HEAD")
        result = self.call("check_dependabot_prs", FAKE_PRS=DEPENDABOT_PR)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("NOTIFY: autoloop: merged Dependabot pull request #12", result.stdout)
        self.assertIn(
            "NOTIFY: autoloop: main does not merge cleanly into autoloop/M1 after Dependabot #12 Bump x from 1 to 2; "
            "merge it by hand before the milestone's pull request.",
            result.stdout,
        )
        self.assertEqual(git(self.repo, "rev-parse", "HEAD"), head)
        self.assertEqual(git(self.repo, "status", "--porcelain"), "")
        self.assertFalse((self.repo / ".git" / "MERGE_HEAD").exists())
        self.assertEqual(self.read("HISTORY.md"), "# History\n- the branch's line\n")

    def test_waiting_pull_request_is_pushed_after_a_dependabot_merge(self):
        remote = self.add_remote()
        self.write_progress(DONE_HEADER + TASK + LOG)
        git(self.repo, "commit", "-q", "-am", "done")
        git(self.repo, "push", "-q", "origin", "autoloop/M1")
        old_head = git(self.repo, "rev-parse", "HEAD").strip()
        self.land_on_main("lock.txt", "2\n")
        # The pull request's head stays the old commit for gh, so no check is ever read: the wait times out.
        result = self.call("wait_for_pr", timeout=4, FAKE_HEAD=old_head, FAKE_PRS=DEPENDABOT_PR)
        self.assertEqual(result.returncode, 124, result.stderr)
        new_head = git(self.repo, "rev-parse", "HEAD").strip()
        self.assertNotEqual(new_head, old_head)
        self.assertIn(
            f"LOG: pushed autoloop/M1 at {new_head[:7]} with main merged in; watching its checks again", result.stdout
        )
        self.assertEqual(git(remote, "rev-parse", "autoloop/M1").strip(), new_head)
        self.assertEqual(result.stdout.count("LOG: pushed"), 1)

    def test_loop_looks_at_dependabot_before_each_run_but_not_in_a_dry_run(self):
        self.add_remote()
        git(self.repo, "commit", "-q", "--allow-empty", "-m", "branch work")
        self.land_on_main("lock.txt", "2\n")
        dry = self.run_loop(FAKE_COMMIT, "--dry-run", FAKE_PRS=DEPENDABOT_PR)
        self.assertEqual(dry.returncode, 0, dry.stderr)
        self.assertEqual(self.merges(), [])
        self.assertFalse((self.repo / "lock.txt").exists())
        result = self.run_loop(FAKE_COMMIT, "--once", FAKE_PRS=DEPENDABOT_PR)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.merges()), 1)
        self.assertIn("merged Dependabot #12 (Bump x from 1 to 2) into main", result.stdout)
        self.assertIn("telegram (not configured): autoloop: merged Dependabot pull request #12", result.stdout)
        self.assertEqual(self.read("lock.txt"), "2\n")
        subjects = git(self.repo, "log", "--format=%s").splitlines()
        self.assertEqual(subjects[:2], ["fake work", "Merge main into autoloop/M1: Dependabot #12 Bump x from 1 to 2"])
        self.assertEqual(self.calls(), 1)

    # Staging

    def test_staging_runs_on_free_ports_follows_commits_and_stops_with_the_loop(self):
        # A STAGING_UP that keeps running (two dev servers): started with the loop, started again after each
        # of the first two commits (the third ends the loop), told once, stopped with the loop.
        fake = FAKE_COMMIT.replace('echo x >> "$FAKE_COUNT"\n', 'echo x >> "$FAKE_COUNT"\necho "$STAGING_PORT_WEB" > "$FAKE_SEEN"\n')
        env = self.staging_env(61100, FAKE_SEEN=str(self.tmp / "seen"))
        result = self.run_loop(fake, MAX_ITERATIONS="3", STAGING_UP=STAGING_SERVE, STAGING_SERVICES="web api", **env)
        self.assertEqual(result.returncode, 0, result.stderr)
        ports = self.ports()
        self.assertEqual(sorted(ports), ["api", "web"])
        self.assertGreaterEqual(min(ports.values()), 61100)
        self.assertNotEqual(ports["web"], ports["api"])
        start = git(self.repo, "rev-parse", "HEAD~3").strip()[:7]
        self.assertIn(
            f"telegram (not configured): autoloop: staging for M1 at {start}: web http://stage.invalid:{ports['web']}, "
            f"api http://stage.invalid:{ports['api']}. It follows every commit; the services' output is in "
            "tools/autoloop/log/staging.log.",
            result.stdout,
        )
        # Every STAGING_UP got the same ports, and so did the runs.
        self.assertEqual(self.staging_lines(), [f"up {ports['web']} {ports['api']}"] * 3)
        self.assertEqual((self.tmp / "seen").read_text().strip(), str(ports["web"]))
        self.assertEqual(result.stdout.count("staging refreshed at "), 2)
        self.assertEqual(result.stdout.count("autoloop: staging"), 1)
        self.assertNotIn("not answering", result.stdout)
        self.assertEqual(self.read("tools/autoloop/log/staging.log").count(" up at "), 3)
        self.assertIn("staging stopped with the loop", result.stdout)
        self.assertFalse((self.loop / "log" / "staging.pid").exists())
        for port in ports.values():
            self.assertTrue(self.port_free(port), port)

    def test_staging_tells_when_up_fails_and_a_service_stops_answering(self):
        env = self.staging_env(61200)
        result = self.run_loop(FAKE_COMMIT, MAX_ITERATIONS="2", STAGING_UP=STAGING_FAIL_SECOND, STAGING_SERVICES="web", **env)
        self.assertEqual(result.returncode, 0, result.stderr)
        port = self.ports()["web"]
        start = git(self.repo, "rev-parse", "HEAD~2").strip()[:7]
        after = git(self.repo, "rev-parse", "HEAD~1").strip()[:7]
        self.assertIn(f"autoloop: staging for M1 at {start}: web http://stage.invalid:{port}. It follows", result.stdout)
        self.assertIn(
            f"telegram (not configured): autoloop: staging at {after}: STAGING_UP exited 7 (compose: boom); "
            f"web http://stage.invalid:{port} (not answering).",
            result.stdout,
        )
        self.assertEqual(self.staging_lines(), ["up", "up"])
        self.assertTrue(self.port_free(port))

    def test_staging_skips_a_port_in_use_and_keeps_recorded_ports(self):
        env = self.staging_env(61300, STAGING_READY_S="0")
        with self.listening(61300):
            result = self.run_loop(FAKE_COMMIT, "--once", STAGING_UP="true", STAGING_SERVICES="web api", **env)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.ports(), {"web": 61301, "api": 61302})
            self.assertIn(
                "web http://stage.invalid:61301 (not answering), api http://stage.invalid:61302 (not answering).",
                result.stdout,
            )
            # The same ports again while they are free.
            result = self.run_loop(FAKE_COMMIT, "--once", STAGING_UP="true", STAGING_SERVICES="web api", **env)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.ports(), {"web": 61301, "api": 61302})
            # A recorded port that is taken, by another service or by the host, is replaced by the next free one.
            (self.loop / "log" / "staging.ports").write_text("web 61302\napi 61302\n")
            result = self.run_loop(FAKE_COMMIT, "--once", STAGING_UP="true", STAGING_SERVICES="web api", **env)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.ports(), {"web": 61302, "api": 61301})

    def test_staging_down_runs_before_the_first_up_and_at_exit_and_the_exit_code_stays(self):
        self.write_progress(HEADER + "  - files: x\n" + TASK + LOG)
        env = self.staging_env(61400, STAGING_READY_S="0")
        result = self.run_loop(
            FAKE_COMMIT, STAGING_UP='echo up >> "$FAKE_STAGING"', STAGING_DOWN='echo down >> "$FAKE_STAGING"', **env
        )
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertEqual(self.staging_lines(), ["down", "up", "down"])
        self.assertIn("autoloop: staging for M1 at ", result.stdout)
        self.assertIn(": no service declared. It follows every commit", result.stdout)
        self.assertEqual(self.calls(), 0)

    def test_staging_detached_services_stay_until_down(self):
        # A STAGING_UP that returns is not stopped between commits; STAGING_DOWN stops its server at exit.
        env = self.staging_env(61500)
        result = self.run_loop(
            FAKE_COMMIT,
            MAX_ITERATIONS="2",
            STAGING_UP=STAGING_DETACH,
            STAGING_DOWN='kill "$(cat "$FAKE_SERVER_PID")"',
            STAGING_SERVICES="web",
            **env,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        port = self.ports()["web"]
        start = git(self.repo, "rev-parse", "HEAD~2").strip()[:7]
        self.assertIn(f"autoloop: staging for M1 at {start}: web http://stage.invalid:{port}. It follows", result.stdout)
        self.assertNotIn("not answering", result.stdout)
        self.assertEqual(self.staging_lines(), ["up", "up"])
        self.assertEqual(result.stdout.count("staging refreshed at "), 1)
        self.assertTrue(self.port_free(port))

    def test_dry_run_starts_no_staging(self):
        env = self.staging_env(61600)
        result = self.run_loop(FAKE_COMMIT, "--dry-run", STAGING_UP='echo up >> "$FAKE_STAGING"', STAGING_SERVICES="web", **env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('dry-run: would start the staging (echo up >> "$FAKE_STAGING") for web', result.stdout)
        self.assertEqual(self.staging_lines(), [])
        self.assertFalse((self.loop / "log" / "staging.ports").exists())

    def test_staging_settings_are_checked(self):
        for env, message in (
            ({"STAGING_SERVICES": "web api"}, "STAGING_SERVICES names web api but STAGING_UP is empty"),
            ({"STAGING_UP": "true", "STAGING_SERVICES": "web 1api"}, "got '1api'"),
            ({"STAGING_UP": "true", "STAGING_PORT_BASE": "70000"}, "STAGING_PORT_BASE must be a port number"),
            ({"STAGING_UP": "true", "STAGING_READY_S": "soon"}, "STAGING_READY_S must be a number of seconds"),
        ):
            result = self.run_loop(None, "--print-stage", **env)
            self.assertEqual(result.returncode, 3, env)
            self.assertIn(message, result.stderr)

    def test_status_report_carries_the_staging_urls(self):
        log_dir = self.loop / "log"
        log_dir.mkdir(exist_ok=True)
        (log_dir / "staging.ports").write_text("web 61700\napi 61701\n")
        with self.listening(61700):
            result = self.telegram("status-text", STAGING_HOST="stage.invalid")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(
            result.stdout.endswith("staging: web http://stage.invalid:61700 (up), api http://stage.invalid:61701 (down)\n"),
            result.stdout,
        )


if __name__ == "__main__":
    unittest.main()
