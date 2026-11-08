"""Tests of the shared wrapper in a temporary repository laid out like a project (tools/autoloop/core).

Run from a project: python3 -I -m unittest discover -s tools/autoloop/core/tests
Needs git, bash, python3 and the `timeout` binary; claude is a fake script, Telegram is not configured.
"""

from __future__ import annotations

import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
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
# failed, run 42 has one failed job and a two-line log.
case "$*" in
  *"pr view"*"state"*) echo OPEN ;;
  *"pr view"*"headRefOid"*) echo "${FAKE_HEAD:-$(git rev-parse HEAD)}" ;;
  *"pr view"*"url"*) echo "https://example.invalid/pr/1" ;;
  *"pr checks"*) echo "fail gate https://example.invalid/actions/runs/42/job/7" ;;
  *"run view 42 --log-failed"*) printf 'gate\\tTest\\t##[error]Process completed with exit code 1.\\n' ;;
  *"run view 42 --json jobs"*) echo gate ;;
  *"actions/runs/42/jobs"*) echo 7 ;;
  *"check-runs/7/annotations"*) echo "warning: .github:2 Node.js 20 is deprecated; action x targets it" ;;
  *) exit 1 ;;
esac
"""
PR_FUNCTIONS = ";".join(
    f"/^{name}()/,/^}}/p"
    for name in (
        "wait_for_pr",
        "reopen_for_ci",
        "run_annotations",
        "consider_annotations",
        "next_question_id",
        "write_pr_body",
        "write_pr_body_full",
        "milestone_title",
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
        shutil.copy(CORE / "prompts" / "judge.md", core / "prompts" / "judge.md")
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

    def stage(self, progress: str) -> str:
        """The stage kickoff.sh prints for the given PROGRESS.md text."""
        self.write_progress(progress)
        result = self.run_loop(None, "--print-stage")
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def call(self, function: str, *args: str, timeout: int = 20, **env: str) -> subprocess.CompletedProcess:
        """Runs one pull-request function of kickoff.sh with the fake gh on the PATH, log and notify stubbed."""
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir(exist_ok=True)
        (bin_dir / "gh").write_text(FAKE_GH)
        (bin_dir / "gh").chmod(0o755)
        log_dir = self.tmp / "log"
        log_dir.mkdir(exist_ok=True)
        script = f"""set -uo pipefail
HERE={self.loop}/core; AUTOLOOP_REL=tools/autoloop; REPO_ROOT={self.repo}
LOG_DIR={log_dir}; RUN_LOG={log_dir}/kickoff.log
PROGRESS={self.repo}/PROGRESS.md; QUESTIONS={self.repo}/QUESTIONS.md
MERGE_POLL_S=1; CHECK_POLL_S=1; CI_REOPEN_LIMIT=${{CI_REOPEN_LIMIT:-3}}; CI_FIX_ACCEPTANCE=tools/lint/lint.sh
log() {{ echo "LOG: $*"; }}
notify() {{ echo "NOTIFY: $*"; }}
progress_field() {{ sed -n "s/^$1: *//p" "$PROGRESS" | head -1 | tr -d '[:space:]'; }}
source <(sed -n '{PR_FUNCTIONS}' tools/autoloop/core/kickoff.sh)
{function} "$@"
"""
        environ = {**os.environ, **IDENTITY, **env, "PATH": f"{bin_dir}:{os.environ['PATH']}"}
        return subprocess.run(
            ["timeout", str(timeout), "bash", "-c", script, "bash", *args],
            cwd=self.repo,
            env=environ,
            capture_output=True,
            text=True,
            timeout=timeout + 5,
            check=False,
        )

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
        self.assertIn("no progress after 2 task runs on M1. The last run said: ok The judge reads it next.", result.stdout)
        self.assertIn("blocked after 2 runs", git(self.repo, "log", "--format=%s"))
        self.assertIn("judge run changed nothing", result.stdout)
        self.assertIn("telegram (not configured):\nautoloop question 1", result.stdout)
        self.assertFalse((self.loop / "log" / "judge.log").exists())
        self.assertEqual(git(self.repo, "status", "--porcelain", "PROGRESS.md", "QUESTIONS.md"), "")

    def test_no_progress_reason_is_one_line_and_cut(self):
        fake = "#!/usr/bin/env bash\necho x >> \"$FAKE_COUNT\"\n" + (
            "echo '{\"is_error\": false, \"result\": \"waiting for\\n\\nthe release " + "x" * 50 + "\"}'\n"
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
        environ = {k: v for k, v in os.environ.items() if not k.startswith("TELEGRAM_")}
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
        environ = {k: v for k, v in os.environ.items() if not k.startswith("TELEGRAM_")}
        result = subprocess.run(
            [str(self.loop / "core" / "telegram.sh"), "status-text"],
            cwd=self.repo,
            env=environ,
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("autoloop M1 | RUNNING | autoloop/M1", result.stdout)
        self.assertIn("open 1, in progress 0, reopened 0, done 0 (verifying 0)", result.stdout)
        self.assertIn("commits since the last report:\n- Judge: answered Q1", result.stdout)
        self.assertRegex(result.stdout, r"judge:\n\d\d:\d\d Q1 answered: 8080")
        # Sending (not configured: printed) remembers the time; the next report starts there.
        sent = subprocess.run(
            [str(self.loop / "core" / "telegram.sh"), "status"],
            cwd=self.repo,
            env=environ,
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
        self.assertIn("telegram (not configured): autoloop M1", sent.stdout)
        self.assertTrue((self.loop / "log" / "status.last").read_text().strip().isdigit())
        again = subprocess.run(
            [str(self.loop / "core" / "telegram.sh"), "status-text"],
            cwd=self.repo,
            env=environ,
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
        self.assertIn("judge:\n- nothing answered or passed", again.stdout)

    def test_status_report_counts_done_tasks_awaiting_verification(self):
        # Two done tasks, one verified and one not, and an open one: done 2, verifying 1.
        verified = (
            TASK.replace("T1.1 First", "T1.0 Zero").replace("- [ ]", "- [x]").replace("verified:", "verified: abc ok")
        )
        unverified = TASK.replace("T1.1 First", "T1.2 Second").replace("- [ ]", "- [x]")
        self.write_progress(HEADER + verified + unverified + TASK + LOG)
        environ = {k: v for k, v in os.environ.items() if not k.startswith("TELEGRAM_")}
        result = subprocess.run(
            [str(self.loop / "core" / "telegram.sh"), "status-text"],
            cwd=self.repo,
            env=environ,
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("open 1, in progress 0, reopened 0, done 2 (verifying 1)", result.stdout)

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

    def test_checks_are_judged_only_on_the_pull_request_head(self):
        self.write_progress(DONE_HEADER + TASK + LOG)
        result = self.call("wait_for_pr", timeout=3, FAKE_HEAD="f" * 40)
        self.assertEqual(result.returncode, 124, result.stderr)
        self.assertEqual(result.stdout, "")

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
        self.assertEqual(
            git(self.repo, "log", "-1", "--format=%s"), "Reopen M1: CI red on the pull request, T1.2 makes it green\n"
        )
        self.assertEqual(git(self.repo, "status", "--porcelain", "PROGRESS.md"), "")

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


if __name__ == "__main__":
    unittest.main()
