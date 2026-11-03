#!/usr/bin/env bash
#
# Install, enable, disable or remove the autoloop as a systemd service.
#
# Usage (run as the user who logged the Claude CLI in; root rights are taken through ROOT_CMD,
# default sudo, for the system files only, and directly when already root):
#   tools/autoloop/core/service/install.sh install     render the units, enable and (re)start the loop and the status timer
#   tools/autoloop/core/service/install.sh disable     stop and disable both (units stay installed; `install` re-enables)
#   tools/autoloop/core/service/install.sh uninstall   stop, disable and delete the units
#   tools/autoloop/core/service/install.sh status      show both units
#
# The units are named per project so that several loops can live on one host without touching
# each other's units: AUTOLOOP_NAME from tools/autoloop/autoloop.env, default autoloop-<repository
# directory name>, gives <name>.service, <name>-status.service and <name>-status.timer.
# The rendered fields are that name, the current user and group, their home, the repository path,
# the project's autoloop directory, this core checkout, and the directories that hold the `claude`
# and `node` binaries (the service PATH is not the login shell's, so a Node under Volta, nvm or fnm
# is otherwise invisible; a project without Node renders /usr/bin). Nothing is written into the
# repository.

set -euo pipefail

readonly HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CORE="$(cd "${HERE}/.." && pwd)"
readonly AUTOLOOP_DIR="${AUTOLOOP_DIR:-$(cd "${CORE}/.." && pwd)}"
readonly REPO="${AUTOLOOP_REPO:-$(git -C "${AUTOLOOP_DIR}" rev-parse --show-toplevel)}"
readonly AUTOLOOP_REL="${AUTOLOOP_DIR#"${REPO}"/}"
readonly ENV_FILE="${AUTOLOOP_DIR}/autoloop.env"
readonly UNIT_DIR="/etc/systemd/system"

if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
fi
readonly NAME="${AUTOLOOP_NAME:-autoloop-$(basename "${REPO}")}"
readonly LOOP_UNIT="${NAME}.service"
readonly STATUS_UNIT="${NAME}-status.service"
readonly TIMER_UNIT="${NAME}-status.timer"
readonly UNITS=("${LOOP_UNIT}" "${STATUS_UNIT}" "${TIMER_UNIT}")

#######################################
# Run a command with root rights: directly when already root, else through ROOT_CMD.
#######################################
as_root() {
  if (( EUID == 0 )); then
    "$@"
  else
    "${ROOT_CMD:-sudo}" "$@"
  fi
}

#######################################
# Replace the @FIELD@ placeholders of a template on stdout.
# Arguments:
#   The template path.
#######################################
render() {
  local claude_dir node_dir
  claude_dir="$(dirname "$(command -v claude)")"
  node_dir="$(dirname "$(command -v node 2>/dev/null || echo /usr/bin/node)")"
  sed -e "s|@NAME@|${NAME}|g" \
      -e "s|@USER@|$(id -un)|g" \
      -e "s|@GROUP@|$(id -gn)|g" \
      -e "s|@HOME@|${HOME}|g" \
      -e "s|@REPO@|${REPO}|g" \
      -e "s|@AUTOLOOP_DIR@|${AUTOLOOP_DIR}|g" \
      -e "s|@AUTOLOOP_REL@|${AUTOLOOP_REL}|g" \
      -e "s|@CORE@|${CORE}|g" \
      -e "s|@CLAUDE_DIR@|${claude_dir}|g" \
      -e "s|@NODE_DIR@|${node_dir}|g" \
      "$1"
}

check_prerequisites() {
  command -v systemctl >/dev/null || { echo "systemd is not available on this machine" >&2; exit 3; }
  command -v claude >/dev/null || { echo "claude CLI not on PATH; install it and log in first" >&2; exit 3; }
  [[ "${NAME}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || { echo "AUTOLOOP_NAME '${NAME}' is not a valid unit name" >&2; exit 3; }
  [[ -f "${ENV_FILE}" ]] || echo "warning: ${AUTOLOOP_REL}/autoloop.env missing; Telegram will be silent" >&2
  [[ -f "${REPO}/PROGRESS.md" ]] || { echo "no PROGRESS.md in ${REPO}" >&2; exit 3; }
  # A unit of the same name that belongs to another checkout would be overwritten: refuse.
  local existing
  if [[ -f "${UNIT_DIR}/${LOOP_UNIT}" ]]; then
    existing="$(sed -n 's/^WorkingDirectory=//p' "${UNIT_DIR}/${LOOP_UNIT}" | head -1)"
    if [[ -n "${existing}" && "${existing}" != "${REPO}" ]]; then
      echo "${UNIT_DIR}/${LOOP_UNIT} already belongs to ${existing}; set AUTOLOOP_NAME in autoloop.env to a distinct name" >&2
      exit 3
    fi
  fi
}

install_units() {
  check_prerequisites
  local tmp
  tmp="$(mktemp -d)"
  render "${HERE}/autoloop.service.in" > "${tmp}/${LOOP_UNIT}"
  render "${HERE}/autoloop-status.service.in" > "${tmp}/${STATUS_UNIT}"
  render "${HERE}/autoloop-status.timer.in" > "${tmp}/${TIMER_UNIT}"
  if command -v systemd-analyze >/dev/null; then
    systemd-analyze verify "${tmp}/${LOOP_UNIT}" "${tmp}/${STATUS_UNIT}" || true
  fi
  as_root install -m 644 "${tmp}/${LOOP_UNIT}" "${tmp}/${STATUS_UNIT}" "${tmp}/${TIMER_UNIT}" "${UNIT_DIR}/"
  rm -rf "${tmp}"
  as_root systemctl daemon-reload
  as_root systemctl enable "${TIMER_UNIT}" "${LOOP_UNIT}"
  # A restart, so that an already running loop or timer takes the new unit file.
  as_root systemctl restart "${TIMER_UNIT}"
  as_root systemctl restart "${LOOP_UNIT}"
  echo "installed and started as ${NAME}. Follow with: journalctl -u ${NAME} -f   (and ${AUTOLOOP_REL}/log/kickoff.log)"
}

disable_units() {
  as_root systemctl disable --now "${LOOP_UNIT}" "${TIMER_UNIT}" || true
  echo "disabled: ${NAME} and its status timer are stopped and will not start at boot. 'install' re-enables them."
}

uninstall_units() {
  disable_units
  local unit
  for unit in "${UNITS[@]}"; do
    as_root rm -f "${UNIT_DIR}/${unit}"
  done
  as_root systemctl daemon-reload
  echo "removed ${UNITS[*]} from ${UNIT_DIR}"
}

main() {
  case "${1:-}" in
    install) install_units ;;
    disable) disable_units ;;
    uninstall) uninstall_units ;;
    status) systemctl status "${LOOP_UNIT}" "${TIMER_UNIT}" --no-pager || true ;;
    *) echo "usage: $0 install | disable | uninstall | status" >&2; exit 2 ;;
  esac
}

main "$@"
