#!/usr/bin/env bash
#
# Telegram notifications for the autoloop.
#
# Usage: core/telegram.sh send "<text>"             send one message
#        core/telegram.sh status                    send the progress summary (the hourly timer)
#        core/telegram.sh status-text               print the summary without sending it
#        core/telegram.sh photo <file> ["caption"]  send a screenshot (png/jpg)
#        core/telegram.sh video <file> ["caption"]  send a screen recording (mp4/webm)
#        core/telegram.sh file <file> ["caption"]   send any file as a document
#
# Needs TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID in <project autoloop dir>/autoloop.env
# (git-ignored). Without them it prints the message and exits 0, so the loop
# never depends on Telegram being configured. The project's tools/autoloop/telegram.sh
# execs this file, so the prompts keep naming that path.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly HERE
readonly AUTOLOOP_DIR="${AUTOLOOP_DIR:-$(cd "${HERE}/.." && pwd)}"
readonly REPO_ROOT="${AUTOLOOP_REPO:-$(git -C "${AUTOLOOP_DIR}" rev-parse --show-toplevel)}"
readonly ENV_FILE="${AUTOLOOP_DIR}/autoloop.env"
readonly LOG_DIR="${AUTOLOOP_DIR}/log"
# The epoch of the last status report: the next one covers everything since.
readonly STATUS_STAMP="${LOG_DIR}/status.last"
readonly TELEGRAM_MAX_CHARS=4000

if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
fi

#######################################
# Send a text to the configured chat.
# Arguments:
#   The text.
#######################################
send() {
  local text="$1"
  # Telegram refuses a message over 4096 characters (and an empty one): cut it short with a mark.
  if (( ${#text} > TELEGRAM_MAX_CHARS )); then
    text="${text:0:$(( TELEGRAM_MAX_CHARS - 16 ))}
(... cut short)"
  fi
  if [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then
    printf 'telegram (not configured): %s\n' "${text}"
    return 0
  fi
  curl -fsS -m 20 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${text}" \
    --data-urlencode "disable_web_page_preview=true" > /dev/null
}

#######################################
# Send a file with the Bot API method given (sendPhoto, sendVideo, sendDocument).
# Arguments:
#   method, file path, caption (optional).
#######################################
send_file() {
  local method="$1" path="$2" caption="${3:-}" field
  [[ -f "${path}" ]] || { echo "no such file: ${path}" >&2; return 1; }
  case "${method}" in
    sendPhoto) field=photo ;;
    sendVideo) field=video ;;
    *) field=document ;;
  esac
  if [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then
    printf 'telegram (not configured): %s %s %s\n' "${method}" "${path}" "${caption}"
    return 0
  fi
  curl -fsS -m 120 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/${method}" \
    -F "chat_id=${TELEGRAM_CHAT_ID}" \
    -F "${field}=@${path}" \
    -F "caption=${caption}" > /dev/null
}

#######################################
# Build the progress summary from PROGRESS.md, git log and the judge log: everything since the
# last report (at most the last hour when there was none), and the open Dependabot pull requests
# when gh can list them.
#######################################
status_text() {
  cd "${REPO_ROOT}"
  local status milestone open prog done_ verifying reopened branch commits since judge dependabot=""
  status="$(sed -n 's/^STATUS: *//p' PROGRESS.md | head -1)"
  milestone="$(sed -n 's/^MILESTONE: *//p' PROGRESS.md | head -1)"
  open="$(grep -cE '^- \[ \] T' PROGRESS.md || true)"
  prog="$(grep -cE '^- \[~\] T' PROGRESS.md || true)"
  done_="$(grep -cE '^- \[x\] T' PROGRESS.md || true)"
  reopened="$(grep -cE '^- \[!\] T' PROGRESS.md || true)"
  # Done tasks whose verified: field is still empty: the verify run is pending or running on them.
  verifying="$(awk '/^- \[x\] T/{t=1} /^- \[/{if(!/^- \[x\]/){t=0}} t && /^  - verified: *$/{n++} END{print n+0}' PROGRESS.md)"
  branch="$(git rev-parse --abbrev-ref HEAD)"
  since="$(cat "${STATUS_STAMP}" 2>/dev/null || true)"
  [[ "${since}" =~ ^[0-9]+$ ]] || since=$(( $(date -u +%s) - 3600 ))
  # head stops reading early; the writer's broken pipe must not fail the report under pipefail.
  commits="$(git log --since="@${since}" --format='- %s' 2>/dev/null | head -8 || true)"
  judge="$(python3 -I "${HERE}/qa.py" judge-log --since "${since}" 2>/dev/null | head -8 || true)"
  if command -v gh >/dev/null 2>&1; then
    dependabot="$(gh pr list --app dependabot --state open --base "${BASE_BRANCH:-main}" --json number --jq length 2>/dev/null || true)"
  fi
  printf 'autoloop %s | %s | %s\nopen %s, in progress %s, reopened %s, done %s (verifying %s)%s\ncommits since the last report:\n%s\njudge:\n%s\n' \
    "${milestone}" "${status}" "${branch}" "${open}" "${prog}" "${reopened}" "${done_}" "${verifying}" \
    "${dependabot:+; Dependabot PRs open: ${dependabot}}" "${commits:-- none}" "${judge:-- nothing answered or passed}"
}

#######################################
# Remember when the report was sent, so the next one starts there.
#######################################
mark_status_sent() {
  mkdir -p "${LOG_DIR}"
  date -u +%s > "${STATUS_STAMP}"
}

main() {
  case "${1:-}" in
    send) shift; send "$*" ;;
    status) send "$(status_text)"; mark_status_sent ;;
    status-text) status_text ;;
    photo) send_file sendPhoto "${2:-}" "${3:-}" ;;
    video) send_file sendVideo "${2:-}" "${3:-}" ;;
    file) send_file sendDocument "${2:-}" "${3:-}" ;;
    *) echo "usage: $0 send <text> | status | status-text | photo <file> [caption] | video <file> [caption] | file <file> [caption]" >&2; exit 2 ;;
  esac
}

main "$@"
