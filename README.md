# Autoloop: unattended development runs

The shared core of the autonomous loop that Claude Code projects run
unattended. A project checks this repository out as a git submodule under
its autoloop directory (by default `tools/autoloop/core`) and keeps its own
prompts, settings, logs and archive next to it. Nothing project-specific
lives here; nothing is written here at run time.

Three kinds of Claude Code run share `PROGRESS.md` as their state and git
commits as their checkpoints; a fourth, the judge, answers the questions the
others raise. The wrapper decides which run comes next from the first three
lines of `PROGRESS.md` and the task checkboxes; no run is a continued
session, so each one starts from the project's `CLAUDE.md` and the task
entry. Runs have no `Agent` or `Workflow` tool: a subagent runs in the
background, and its report never reaches a run that ended its turn to wait
for it.

```text
kickoff.sh loop
  ├── STATUS BLOCKED         -> judge run (JUDGE_MODEL, prompts/judge.md): answers each open question
  │                             that the project's documents settle, with its source, in QUESTIONS.md
  │                             and DECISIONS.md; marks the rest "Judge: cannot answer: ..." for the
  │                             owner. All answered: STATUS RUNNING, continue. Otherwise the open
  │                             questions go to Telegram (qa.py); the loop waits for "Q<n> <answer>"
  │                             replies, records them, sets RUNNING, continues; exit 2 only without
  │                             Telegram or after ANSWER_WAIT_S. Answers and passes: log/judge.log
  ├── STATUS MILESTONE_DONE  -> archive PROGRESS.md, QUESTIONS.md, the pull request body and the
  │                             acceptance result under archive/<milestone>/ (+ a HISTORY.md line,
  │                             wrapped at 80 columns),
  │                             push the branch, open the pull request (gh), Telegram the URL, watch
  │                             its checks: a red check reopens the milestone (below); green waits
  │                             for the merge, tags it milestone/<id>, then starts the next milestone of
  │                             MILESTONES.md on autoloop/<next> from the merged base branch with fresh
  │                             PROGRESS.md and QUESTIONS.md; exit 0 after the last one
  │   red check on the PR     -> the failed job log is saved under log/ci-<milestone>-<sha>.log, a task
  │                             "Make CI green" (ci_task.py) is added with the first error lines and
  │                             an acceptance that re-runs the failed make targets, STATUS
  │                             RUNNING, Telegram; task and verify runs handle it, the planning run
  │                             re-runs the acceptance, the loop pushes and watches again; after
  │                             CI_REOPEN_LIMIT such tasks in one milestone: STATUS BLOCKED with a question
  │   CI refused (billing)   -> every failing check is a job GitHub would not start for a failed payment
  │                             or the spending limit (its annotation says so): the checks are not
  │                             relied on; LOCAL_GATE runs once per head (log/local-gate-<sha>.log);
  │                             green waits for the merge, red is the check "local-gate" and reopens
  │                             the milestone like a red check
  │   green with warnings    -> the run's warning annotations are saved under log/ci-annotations-<sha>.txt
  │                             and the milestone reopened once per set so the planning run considers
  │                             them: a task, a question, or a Log line saying why nothing is needed
  ├── no tasks               -> plan run    (PLAN_MODEL, prompts/plan.md)
  ├── a [x] task unverified  -> verify run  (VERIFY_MODEL, prompts/verify.md)
  ├── [!] or [ ] or [~] task -> task run    (TASK_MODEL or the task's model: line, prompts/task.md)
  └── all verified           -> plan run runs the milestone acceptance
usage limit  -> sleep until reset (or default, doubling); exit 4 when longer than LIMIT_NOTIFY_HOURS
no progress  -> after NO_PROGRESS_LIMIT runs without a commit: STATUS BLOCKED with a question that names
                the last result file and quotes what that run said (RUN_REASON_CHARS, 700); the
                Telegram message carries the same quote; the judge reads it first, then the owner;
                the second such block in one run goes to the owner directly
orphan field -> a task field outside a task or repeated within one. Left by the run that just ended:
                PROGRESS.md is restored from the commit before it (committed, Telegram) and the stage
                runs again, up to PROGRESS_REPAIR_LIMIT (2) runs in a row. Found at the start of a
                pass otherwise (a hand edit, or the limit reached): log, Telegram, exit 3
Dependabot   -> its pull requests on the base branch are looked at before every run and on every poll while
                a milestone's pull request waits: a green, mergeable one is merged (DEPENDABOT_MERGE: squash
                by default; report only tells the owner) and the base branch merged into the milestone branch,
                pushed when the milestone's pull request is open; a red one goes to the judge once per head
                commit (DEPENDABOT_TRIAGE=judge, prompts/dependabot.md): flaky has its failed jobs run again
                once, broken or unclear is told to the owner with the judge's reason, and it is never merged
                while red; one the merge failed on and a base branch that conflicts are told to the owner
                once and left; one still being checked waits
staging      -> with STAGING_UP: the project's services run next to the loop on free ports, one per name in
                STAGING_SERVICES (STAGING_PORT_<NAME>, the first free at or above STAGING_PORT_BASE, kept in
                log/staging.ports), started with the loop and brought up to date after every commit; the
                owner gets the URLs once and hears when a service stops answering or STAGING_UP fails;
                STAGING_DOWN runs when the loop exits
telegram.sh status (the hourly timer) reads PROGRESS.md, git log, log/judge.log since the last report, gh and
                log/staging.ports
```

## How a project uses it

```text
<project>/tools/autoloop/
  core/                 this repository, as a submodule
  kickoff.sh            exec "$(dirname "$0")/core/kickoff.sh" "$@"
  telegram.sh           exec "$(dirname "$0")/core/telegram.sh" "$@"   (the prompts name this path)
  hooks/guard.sh        exec "$(dirname "$0")/../core/hooks/guard.sh"  (named in .claude/settings.json)
  hooks/rules.sh        optional: the project's own guard rules, sourced by the shared guard
  prompts/plan.md, task.md, verify.md   the project's master prompts (judge.md and dependabot.md optional; core's are the default)
  autoloop.env.example  the settings the project changes; autoloop.env (git-ignored) holds the real values
  log/                  git-ignored: one JSON result per run, kickoff.log, judge.log, the CI logs, evidence,
                        the staging's log and ports
  archive/<milestone>/  committed: each finished milestone's PROGRESS.md, QUESTIONS.md, pull request body, acceptance
```

The wrapper finds the project directory as the parent of its own checkout
and the repository root with `git rev-parse --show-toplevel` from there;
`AUTOLOOP_DIR` and `AUTOLOOP_REPO` in the environment override both. The
three wrappers keep every documented path (`tools/autoloop/kickoff.sh`,
`tools/autoloop/telegram.sh photo ...`, the hook command in
`.claude/settings.json`) valid, so adopting the core changes no document and
no permission file.

To adopt it in a project:

```bash
git submodule add https://github.com/AreGone/autoloop.git tools/autoloop/core
printf '#!/usr/bin/env bash\nexec "$(dirname "$0")/core/kickoff.sh" "$@"\n' > tools/autoloop/kickoff.sh
printf '#!/usr/bin/env bash\nexec "$(dirname "$0")/core/telegram.sh" "$@"\n' > tools/autoloop/telegram.sh
printf '#!/usr/bin/env bash\nexec "$(dirname "$0")/../core/hooks/guard.sh"\n' > tools/autoloop/hooks/guard.sh
chmod +x tools/autoloop/kickoff.sh tools/autoloop/telegram.sh tools/autoloop/hooks/guard.sh
cp tools/autoloop/core/autoloop.env.example tools/autoloop/autoloop.env   # fill it; git-ignored
```

Clones need the submodule: `git clone --recurse-submodules`, or
`git submodule update --init` in an existing clone, and `submodules: true`
on the checkout step of CI. To take a newer core in a project:
`git -C tools/autoloop/core pull origin main`, then commit the submodule
pointer (`git add tools/autoloop/core`) like any file.

What the project must provide: `PROGRESS.md` with the `STATUS`, `MILESTONE`
and `UPDATED` header lines and the task format the prompts describe;
`MILESTONES.md` with one `## M<n>: title` heading per milestone;
`QUESTIONS.md` with `## Q<n>` sections that end in an `Answer:` line, each
id one above the highest in the file and never reused;
`DECISIONS.md` with a `## 3. Process` heading, before which answers are
recorded as table rows; `HISTORY.md`; a `CLAUDE.md` the runs start from; a
lint gate the task prompt names; `gh` logged in for pull requests.

## Models and runs

The planning, verification and judge runs use the strong model (Opus by
default; `PLAN_MODEL`, `VERIFY_MODEL` and `JUDGE_MODEL` must name a Fable or
Opus model, otherwise the wrapper exits 3), the implementation run uses
Sonnet unless the task's `model:` line names another alias; `kickoff.sh`
reads the line of the task the implementer will pick. The brief written by
the planner is what makes a task Sonnet-sized.

The judge run answers a question only when the project's documents settle
it or when it is an engineering choice inside what they allow, and every
answer names its source: the `Answer:` line reads
`... (judge, <date>)` and the DECISIONS.md row ends in `(judge)`, so the
owner can see what was decided for them and overrule it. A question that
would change a fixed fact, needs something only the owner has, asks a
preference, or leaves the judge unsure is passed with a
`Judge: cannot answer: <why>` line and sent to Telegram with that line in
it. The wrapper, not the model, keeps the books: `qa.py judged` compares
the questions before and after the run, appends each answer and each pass
to `log/judge.log`, reconciles `STATUS` with the file, and reports to
Telegram at once. A judge run that changes nothing sends the questions to
the owner; the judge is never asked twice about the same set in one run of
the wrapper.

The judge also triages a red pull request of Dependabot, once per head
commit (`DEPENDABOT_TRIAGE=judge`, the default; `off` only tells the owner).
The wrapper saves the failed jobs' log and the pull request's diff under
`log/` (`dependabot-<number>-<sha>.log` and `.diff`) and appends the pull
request's facts to `prompts/dependabot.md`; the run changes nothing and ends
with a `VERDICT:` line (`flaky`, `break` or `unsure`) and a `REASON:` line,
which the wrapper reads from the run's result file. `flaky` has the failed
jobs run again once (`gh run rerun --failed`): green is then merged like any
other, red again is told to the owner. `break` and `unsure` are told to the
owner with the reason, as is a run that names no verdict. The judge never
merges, fixes or closes anything, and the log and the diff, which come from
outside the repository, can move it to nothing more than that one re-run.
Checks GitHub refused to start for billing are told to the owner without a
judge run. Each verdict is a line in `log/judge.log`, so the hourly report
carries it.

The hourly status report (`telegram.sh status`, fired by the
`<name>-status.timer` unit) carries the milestone, the task counts (open,
in progress, reopened, done, and among the done ones how many still await
their verify run), the number of open Dependabot pull requests when `gh`
can list them, the commits since the last report, the judge's answers
and passes since the last report, and the staging's services with whether
each answers when the loop has one; `log/status.last` remembers when the
last one went out.

## The staging: the services while the loop runs

With `STAGING_UP` set in `autoloop.env`, the wrapper keeps the project's
services running next to the loop, so you can open what it is building
while it builds it. `STAGING_UP` is a command, run from the repository root
with `bash -c`, that starts the services or brings them up to date:
`docker compose -f compose.staging.yml up -d --build`, `make staging-up`,
or a dev server such as `PORT=$STAGING_PORT_WEB npm run dev` (in single
quotes in `autoloop.env`, so that the port is read when the command runs).
It runs when the loop starts and again after every run that made a commit,
and the staging follows the branch's head while a milestone's pull request
waits for its merge. Each name in `STAGING_SERVICES` (`web api`) gets a
free port, the first at or above `STAGING_PORT_BASE` (42000) that nothing on
the host listens on, which `STAGING_UP` finds in `STAGING_PORT_<NAME>`
(upper case, `-` as `_`): a compose file maps it with
`ports: ["${STAGING_PORT_WEB}:3000"]`. The ports are kept in
`log/staging.ports` and used again on every refresh and restart while they
stay free, so the URLs do not change under you; another loop on the host, or
your own stack on the usual ports, gets other ones.

A `STAGING_UP` that returns has detached the services (compose); one that
keeps running is the service itself and is stopped, with everything it
started, before the next `STAGING_UP` and when the loop exits. Its output
goes to `log/staging.log`. After each `STAGING_UP` the wrapper waits up to
`STAGING_READY_S` seconds (120) for every service to accept a connection on
its port, then tells you once, over Telegram, where they are:
`staging for M3 at 1a2b3c4: web http://<host>:42000, api http://<host>:42001`,
with `(not answering)` after a service that does not and
`STAGING_UP exited <n>` with the log's last line when the command failed.
Later refreshes are lines in `kickoff.log`; you hear of one only when
something changed: a service stopped answering or answers again, or
`STAGING_UP` failed. The hourly report carries the URLs with `(up)` or
`(down)` after each. `STAGING_HOST` is the host in the URLs (default: the
machine's hostname); the services must listen on all interfaces to be
reached from elsewhere, and who may reach the host is yours to decide.

`STAGING_DOWN` (`docker compose -f compose.staging.yml down`), when set, runs
when the loop exits and before the first `STAGING_UP` of a start, so that
the services of an earlier loop are gone and their ports free. Without it,
detached services outlive the loop and the next start brings them up to
date. The runs see `STAGING_PORT_<NAME>` and `STAGING_HOST` too, so a verify
prompt can send the verifier to `http://127.0.0.1:$STAGING_PORT_WEB` (the
guard lets loopback through); a dev server with hot reload shows the
implementer's edits before they are committed. `--dry-run` starts nothing.

## Setting up on a new machine or account

1. Clone the project with `--recurse-submodules`; install the project's
   tool chain, the Claude Code CLI and the GitHub CLI. Run `claude` once
   interactively and log in with the account that will pay; run
   `gh auth login` and `gh auth setup-git` so the loop can push branches and
   open pull requests.
2. The project's bootstrap (its README says).
3. `cp tools/autoloop/core/autoloop.env.example tools/autoloop/autoloop.env`
   (or the project's example) and fill the Telegram token and chat id. One
   bot per loop: two loops polling the same token consume each other's
   answers. `STAGING_UP` and `STAGING_SERVICES` keep the project's services
   reachable while the loop runs ("The staging" above).
4. Dry run: `tools/autoloop/kickoff.sh --dry-run`; one stage:
   `tools/autoloop/kickoff.sh --once`; the next stage without running it:
   `tools/autoloop/kickoff.sh --print-stage`.
5. Start it as a system service (Linux with systemd; the script takes root
   rights only for the unit files, through `sudo` unless already root):

```bash
tools/autoloop/core/service/install.sh install
```

   This renders `service/autoloop.service.in`,
   `service/autoloop-status.service.in` and `service/autoloop-status.timer.in`
   with the loop's name (`AUTOLOOP_NAME` in `autoloop.env`, default
   `autoloop-<repository directory>`), your user, home, the repository path,
   the core checkout and the `claude` and `node` directories, installs them as
   `<name>.service`, `<name>-status.service` and the hourly
   `<name>-status.timer`, enables both at boot and (re)starts them. Several
   loops on one host each take their own name and their own Telegram bot;
   the installer refuses a name whose unit already belongs to another
   checkout. The loop restarts on a crash after ten minutes, but not after
   the exits that need a human (milestone done, blocked without an answer
   path, setup error, usage cap): start it again with
   `systemctl start <name>` once you have acted. Follow it with
   `journalctl -u <name> -f` and `tools/autoloop/log/kickoff.log`.
   `install.sh disable` stops both units and keeps them; `install.sh
   uninstall` removes them. Without systemd, the detached form still works:
   `nohup tools/autoloop/kickoff.sh >> tools/autoloop/log/nohup.log 2>&1 &`
   plus the cron line `0 * * * * /path/to/repo/tools/autoloop/telegram.sh status`.

## Permissions

The project's `.claude/settings.json` allows its commands and denies force
pushes, history rewrites and keys on the command line. The wrapper passes
`--permission-mode acceptEdits`, so file edits inside the repository need no
prompt and any Bash command outside the allowlist is refused; the run sees
the refusal and blocks. `hooks/guard.sh` runs before every Bash call and
blocks non-loopback network tools (loopback, Docker names, Telegram, GitHub
and the package registries pass), provider keys on the command line, `sudo`,
`git add -A`, force pushes and tree rewrites regardless of the allowlist; a
project's `hooks/rules.sh` adds its own lines, with `cmd` and `block` already
defined.

## Files

| File | Role |
|---|---|
| `kickoff.sh` | the loop: settings, stage choice, invocation, the judge, usage-limit wait, no-progress guard, branch; sources `lib/` |
| `lib/milestone.sh`, `lib/pr.sh`, `lib/dependabot.sh`, `lib/staging.sh` | the milestone's files and pull request; the checks of the pull request and the fix task; Dependabot's pull requests; the staging |
| `telegram.sh` | `send <text>`, `status`, `status-text`, `photo`, `video`, `file`; silent no-op without a token |
| `qa.py` | `list` the open questions, `send` them, `wait` for answers over Telegram (or `--from-file` in tests), `judged` and `judge-log` for the judge's bookkeeping |
| `ci_task.py` | writes the "Make CI green" task into PROGRESS.md when a pull request check fails; its acceptance is `CI_FIX_ACCEPTANCE` and then the innermost failed make target of each failed job |
| `progress.py` | reads PROGRESS.md for the wrapper and the status report: a header field, the task counts, the next stage, a task field outside a task, the next task's model |
| `result.py` | reads a run's JSON result file for the wrapper: its text, the one-line reason, the outcome (ok, usage limit with the reset time, not logged in, error) and a triage run's verdict |
| `prompts/judge.md` | the judge's prompt; a project's `prompts/judge.md` replaces it |
| `prompts/dependabot.md` | the judge's prompt for a red pull request of Dependabot; a project's `prompts/dependabot.md` replaces it |
| `hooks/guard.sh` | PreToolUse guard for Bash; sources the project's `hooks/rules.sh` |
| `autoloop.env.example` | every setting with its default |
| `service/` | systemd unit templates, the hourly status timer and `install.sh` (install, disable, uninstall, status) |
| `tests/` | the wrapper's tests: `python3 -I -m unittest discover -s tools/autoloop/core/tests` (git, bash and a fake claude; no network) |

## What the human does

Answer the questions the judge passed on, in the chat, as `Q1 <answer>`;
the wrapper records them and resumes (answering in the files by hand still
works, with a restart). Read the judge's answers in the hourly report or in
`QUESTIONS.md` and overrule one by editing its `Answer:` line and the
DECISIONS.md row. Review and merge each milestone's pull request on GitHub:
the loop opens it when the milestone is done, watches its checks (a red
check means the milestone is not done: the loop reopens it with a fix task
and pushes again; it never asks for a merge while CI is red) and waits for
the merge, then starts the next milestone by itself; closing the pull
request unmerged stops the loop. Dependabot's pull requests are the loop's
too: one whose checks are green is merged for you (`DEPENDABOT_MERGE`,
squash by default; `report` leaves the merge to you, `ignore` leaves them
all alone) and the base branch is merged into the milestone branch; one
whose check is red goes to the judge first, which has a flaky check run
again once and tells you, with its reason, about an update that breaks the
build or that it cannot call; that one, one the loop could not merge (a
required review, a forbidden merge method) and a base branch that no longer
merges cleanly are told to you once and left alone. Open the staging's URLs
from the Telegram message or the hourly report to see what the loop has built
so far; they stay the same while it runs. Keep `MILESTONES.md` honest when the plan
changes. The loop's prompts do not push; the wrapper pushes the milestone
branch when the milestone is done, and again when the base branch was
merged into it while its pull request waits.
