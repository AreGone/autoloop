#!/usr/bin/env bash
#
# PreToolUse hook for Bash: blocks commands that could reach a host outside
# the dev stack, put a secret on the command line, or damage the repository
# history. Exit 2 blocks the call and returns the message to Claude; exit 0
# lets it through.
#
# Wired in .claude/settings.json through the project's tools/autoloop/hooks/guard.sh,
# which execs this file. Reads the tool call as JSON on stdin. A project adds
# its own rules in tools/autoloop/hooks/rules.sh, sourced after the shared
# rules with `cmd` and `block` defined: one `grep -qE '<pattern>' <<<"${cmd}" &&
# block "<reason>"` per line.

set -euo pipefail

readonly HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly RULES="${AUTOLOOP_GUARD_RULES:-${HERE}/../../hooks/rules.sh}"

cmd="$(python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("tool_input",{}).get("command",""))' 2>/dev/null || true)"
[[ -z "${cmd}" ]] && exit 0

block() {
  echo "blocked by tools/autoloop/hooks/guard.sh: $1 (CLAUDE.md hard rules)" >&2
  exit 2
}

# Outbound network from dev, except loopback, Docker-internal names, Telegram, GitHub and the registries.
if grep -qE '(^|[^a-z])(curl|wget|ssh|scp|rsync|nc|ncat|telnet|nmap)([^a-z]|$)' <<<"${cmd}"; then
  grep -qE '127\.0\.0\.1|localhost|\[::1\]|api\.telegram\.org|pypi\.org|files\.pythonhosted\.org|registry\.npmjs\.org|github\.com|ghcr\.io|docker\.io' <<<"${cmd}" \
    || block "network command to a non-loopback host"
fi
# Secrets on the command line.
grep -qiE '(ANTHROPIC|OPENAI|CLAUDE)_API_KEY=|sk-ant-|sk-[A-Za-z0-9]{20,}' <<<"${cmd}" && block "a provider key on the command line: keys live in the ignored env file"
# Repository history and the machine.
grep -qE 'git +push +.*(--force|-f\b|\+)' <<<"${cmd}" && block "force push"
grep -qE 'git +(reset +--hard|clean +-[a-z]*f|checkout +--? *\.|filter-branch|rebase)' <<<"${cmd}" && block "history or working tree rewrite"
grep -qE 'git +add +(-A|--all|\.)( |$)' <<<"${cmd}" && block "git add -A: add named files"
grep -qE '(^|[;&| ])sudo( |$)' <<<"${cmd}" && block "sudo"
grep -qE 'rm +-[a-zA-Z]*r[a-zA-Z]* +(/|~|\$HOME|\.\.)( |$)' <<<"${cmd}" && block "recursive delete outside the work tree"

# The project's own rules (tools/autoloop/hooks/rules.sh), when it has any.
if [[ -f "${RULES}" ]]; then
  # shellcheck disable=SC1090
  source "${RULES}"
fi
exit 0
