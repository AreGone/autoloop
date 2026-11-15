#!/usr/bin/env bash
#
# The staging: the project's services, up next to the loop so that the owner can open what it
# builds. STAGING_UP (autoloop.env) starts them or brings them up to date; it runs when the loop
# starts and again after every commit, with STAGING_PORT_<NAME> set for every name in
# STAGING_SERVICES. STAGING_CHECK, when set, runs against them after each STAGING_UP that brought
# them up, in the background, and is let finish before the next STAGING_UP.
#
# Part of the autoloop core: kickoff.sh sources this file from its own checkout (lib/staging.sh) after
# the settings; log, notify, progress_field, prompt_file and invoke are kickoff.sh's. Not a program
# of its own.

#######################################
# The environment variable that carries a service's port: STAGING_PORT_<NAME>, the name in upper
# case with every character that is not a letter or a digit as "_" (my-api: STAGING_PORT_MY_API).
# Arguments:
#   The service name.
#######################################
staging_var() {
  local name="${1^^}"
  echo "STAGING_PORT_${name//[^A-Z0-9]/_}"
}

#######################################
# Give every service a free port and export it as STAGING_PORT_<NAME>: the port recorded in
# log/staging.ports when it is still free, else the first free one at or above STAGING_PORT_BASE
# that no other service got. The file is written again, so the ports stay the same across runs
# and restarts of the loop while nothing else takes them. No free port is a setup error.
#######################################
staging_allocate() {
  local name port
  # shellcheck disable=SC2086
  python3 -I - "${STAGING_PORTS}" "${STAGING_PORT_BASE}" ${STAGING_SERVICES} > "${STAGING_PORTS}.tmp" <<'PY' \
    || { log "staging: no free port for every service at or above ${STAGING_PORT_BASE}"; exit 3; }
import socket
import sys

path, base, names = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
recorded = {}
try:
    with open(path, encoding="utf-8") as f:
        for line in f:
            parts = line.split()
            if len(parts) == 2 and parts[1].isdigit():
                recorded[parts[0]] = int(parts[1])
except OSError:
    pass


def free(port: int) -> bool:
    # Taken when something listens on it; a connection of an earlier service still closing does not count.
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            s.bind(("", port))
        except OSError:
            return False
    return True


taken = set()
candidate = base
for name in names:
    port = recorded.get(name)
    if port is None or port in taken or not free(port):
        while candidate in taken or not free(candidate):
            candidate += 1
            if candidate > 65535:
                sys.exit(f"no free port at or above {base}")
        port = candidate
    taken.add(port)
    print(name, port)
PY
  mv "${STAGING_PORTS}.tmp" "${STAGING_PORTS}"
  while read -r name port; do
    export "$(staging_var "${name}")=${port}"
  done < "${STAGING_PORTS}"
}

#######################################
# The services that do not accept a TCP connection on loopback within a second, one name per line.
#######################################
staging_unready() {
  python3 -I - "${STAGING_PORTS}" <<'PY'
import socket
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    for line in f:
        name, port = line.split()
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.settimeout(1)
            try:
                s.connect(("127.0.0.1", int(port)))
            except OSError:
                print(name)
PY
}

#######################################
# The services as told to the owner: "<name> http://<STAGING_HOST>:<port>" each, joined by ", ",
# with "(not answering)" after the ones named in the argument.
# Arguments:
#   The names that do not answer, one per line (may be empty).
#######################################
staging_urls() {
  local name port mark out=""
  while read -r name port; do
    mark=""
    grep -qx "${name}" <<< "$1" && mark=" (not answering)"
    out+="${out:+, }${name} http://${STAGING_HOST}:${port}${mark}"
  done < "${STAGING_PORTS}"
  echo "${out:-no service declared}"
}

#######################################
# When a process started, as /proc or ps report it; empty for one that is gone. With the pid it
# tells the process the wrapper started from another one that got the same pid after it ended.
# Arguments:
#   The pid.
#######################################
process_start() {
  { sed 's/^[^)]*) //' "/proc/$1/stat" 2>/dev/null | awk '{print $20}'; } || ps -o lstart= -p "$1" 2>/dev/null || true
}

#######################################
# Stop the process a pid file names, when it still runs: TERM to its process group, KILL after ten
# seconds. The pid file names the process and when it started; a pid that now belongs to another
# process is only forgotten.
# Arguments:
#   The pid file.
#######################################
staging_kill_group() {
  local pid started
  [[ -f "$1" ]] || return 0
  read -r pid started < "$1" || return 0
  rm -f "$1"
  [[ "${pid}" =~ ^[0-9]+$ ]] && kill -0 "${pid}" 2>/dev/null || return 0
  [[ "$(process_start "${pid}")" == "${started:-}" ]] || return 0
  kill -TERM -- "-${pid}" 2>/dev/null || kill -TERM "${pid}" 2>/dev/null || true
  for _ in {1..10}; do
    kill -0 "${pid}" 2>/dev/null || return 0
    sleep 1
  done
  kill -KILL -- "-${pid}" 2>/dev/null || kill -KILL "${pid}" 2>/dev/null || true
}

#######################################
# Stop the STAGING_UP of the last call when it still runs (it is the service, a dev server).
#######################################
staging_kill_up() {
  staging_kill_group "${STAGING_PID}"
}

#######################################
# Start STAGING_CHECK in the background, against the services STAGING_UP just brought up: from the
# repository root, in a session of its own, with the ports in its environment and its output
# appended to log/staging.log. Its pid and start time go to log/staging-check.pid.
# Globals:
#   staging_check_head: the commit the check runs against.
#######################################
staging_check_start() {
  local setsid="" pid
  staging_check_head="${staging_head}"
  echo "# $(date -u +%Y-%m-%dT%H:%M:%SZ) check at ${staging_head:0:7}: ${STAGING_CHECK}" >> "${STAGING_LOG}"
  command -v setsid >/dev/null 2>&1 && setsid=setsid
  # shellcheck disable=SC2086
  (cd "${REPO_ROOT}" && exec ${setsid} bash -c "${STAGING_CHECK}") >> "${STAGING_LOG}" 2>&1 < /dev/null &
  pid=$!
  echo "${pid} $(process_start "${pid}")" > "${STAGING_CHECK_PID}"
  log "staging check started at ${staging_head:0:7}"
}

#######################################
# When the STAGING_CHECK this loop started has finished: its result as a line in kickoff.log, and the
# pid file removed. A check of an earlier loop (not this shell's child) is left to staging_kill_group.
# Returns:
#   0 no check runs any more, 1 the check still runs.
#######################################
staging_check_reap() {
  local pid started rc=0
  [[ -f "${STAGING_CHECK_PID}" ]] || return 0
  read -r pid started < "${STAGING_CHECK_PID}" || { rm -f "${STAGING_CHECK_PID}"; return 0; }
  if [[ "${pid}" =~ ^[0-9]+$ ]] && kill -0 "${pid}" 2>/dev/null \
    && [[ "$(process_start "${pid}")" == "${started:-}" ]]; then
    return 1
  fi
  rm -f "${STAGING_CHECK_PID}"
  [[ "${pid}" =~ ^[0-9]+$ ]] || return 0
  wait "${pid}" 2>/dev/null || rc=$?
  if (( rc == 0 )); then
    log "staging check at ${staging_check_head:0:7} passed"
  else
    log "staging check at ${staging_check_head:0:7} failed (exit ${rc}); see ${STAGING_LOG}"
  fi
  return 0
}

#######################################
# Before the next STAGING_UP: wait up to STAGING_CHECK_S seconds for a running STAGING_CHECK to
# finish, so that a refresh never cuts it short; one that runs longer is stopped, and the log says so.
#######################################
staging_check_finish() {
  local waited=0
  until staging_check_reap; do
    if (( waited >= STAGING_CHECK_S )); then
      log "staging check at ${staging_check_head:0:7} still ran after ${STAGING_CHECK_S}s; stopped"
      staging_kill_group "${STAGING_CHECK_PID}"
      return 0
    fi
    sleep 1
    waited=$(( waited + 1 ))
  done
}

#######################################
# Start the services, or bring them up to date with HEAD. A STAGING_UP of the last call that still
# runs is stopped first. STAGING_UP runs in the background from the repository root, in a session
# of its own so that it can be stopped with everything it started, with the ports in its
# environment and its output appended to log/staging.log; the wrapper then waits until every
# service answers on its port, STAGING_UP fails, or STAGING_READY_S seconds have passed. A
# STAGING_UP that returns (docker compose up -d) has detached the services; one that keeps
# running (a dev server) is left running until the next call or the exit. A STAGING_CHECK of the
# last call is let finish first. With STAGING_CHECK set, services that answer are not enough while
# STAGING_UP still runs (the old ones may answer during a rebuild): the wait goes on until it
# returns or STAGING_READY_S has passed, and then the check starts when every service answers.
# Globals:
#   staging_head: the commit staged. staging_state: the services with their URLs, the ones that
#   do not answer marked, after what went wrong when STAGING_UP failed.
# Returns:
#   0 every service answers, 1 some do not or STAGING_UP failed.
#######################################
staging_up() {
  local pid rc=0 waited=0 unready="" setsid=""
  staging_check_finish
  staging_kill_up
  staging_head="$(git rev-parse HEAD)"
  echo "# $(date -u +%Y-%m-%dT%H:%M:%SZ) up at ${staging_head:0:7}: ${STAGING_UP}" >> "${STAGING_LOG}"
  command -v setsid >/dev/null 2>&1 && setsid=setsid
  # shellcheck disable=SC2086
  (cd "${REPO_ROOT}" && exec ${setsid} bash -c "${STAGING_UP}") >> "${STAGING_LOG}" 2>&1 < /dev/null &
  pid=$!
  echo "${pid} $(process_start "${pid}")" > "${STAGING_PID}"
  while true; do
    if [[ -n "${pid}" ]] && ! kill -0 "${pid}" 2>/dev/null; then
      wait "${pid}" || rc=$?
      pid=""
      rm -f "${STAGING_PID}"
      (( rc == 0 )) || break
    fi
    unready="$(staging_unready)"
    [[ -n "${unready}" || ( -n "${STAGING_CHECK}" && -n "${pid}" ) ]] || break
    (( waited < STAGING_READY_S )) || break
    sleep 1
    waited=$(( waited + 1 ))
  done
  (( rc == 0 )) || unready="$(staging_unready)"
  staging_state="$(staging_urls "${unready}")"
  if (( rc != 0 )); then
    staging_state="STAGING_UP exited ${rc} ($(tail -1 "${STAGING_LOG}" | cut -c1-200)); ${staging_state}"
    return 1
  fi
  [[ -z "${unready}" ]] || return 1
  [[ -z "${STAGING_CHECK}" ]] || staging_check_start
}

#######################################
# Bring the staging up when the loop starts, for a project with STAGING_UP: STAGING_DOWN first,
# when set, so that services of an earlier loop are gone and their ports free; then the ports,
# STAGING_UP, and the owner gets the URLs. The staging is stopped when the loop exits.
#######################################
staging_start() {
  [[ -n "${STAGING_UP}" ]] || return 0
  # dry_run is set by kickoff.sh from its arguments.
  # shellcheck disable=SC2154
  if (( dry_run )); then
    log "dry-run: would start the staging (${STAGING_UP}) for ${STAGING_SERVICES:-no declared service}"
    return 0
  fi
  trap staging_stop EXIT
  staging_kill_group "${STAGING_CHECK_PID}"
  staging_down
  staging_allocate
  staging_up || true
  staging_told="${staging_state}"
  log "staging at ${staging_head:0:7}: ${staging_state}"
  notify "autoloop: staging for $(progress_field MILESTONE) at ${staging_head:0:7}: ${staging_state}. It follows every commit; the services' output is in ${AUTOLOOP_REL}/log/staging.log."
}

#######################################
# After a commit: STAGING_UP again, so that the staging shows HEAD. The owner hears of it when the
# state changed since the last message (a service stopped answering or answers again, STAGING_UP
# failed), not on every commit; every refresh is a line in kickoff.log.
#######################################
staging_sync() {
  [[ -z "${STAGING_CHECK}" ]] || staging_check_reap || true
  [[ -n "${staging_head:-}" && "$(git rev-parse HEAD)" != "${staging_head}" ]] || return 0
  staging_up || true
  log "staging refreshed at ${staging_head:0:7}: ${staging_state}"
  if [[ "${staging_state}" != "${staging_told}" ]]; then
    staging_told="${staging_state}"
    notify "autoloop: staging at ${staging_head:0:7}: ${staging_state}."
  fi
}

#######################################
# STAGING_DOWN, when set, from the repository root with its output in log/staging.log; a failure
# is logged, never fatal.
#######################################
staging_down() {
  [[ -n "${STAGING_DOWN}" ]] || return 0
  local -a limit=()
  command -v timeout >/dev/null 2>&1 && limit=(timeout 300)
  echo "# $(date -u +%Y-%m-%dT%H:%M:%SZ) down: ${STAGING_DOWN}" >> "${STAGING_LOG}"
  (cd "${REPO_ROOT}" && ${limit[@]+"${limit[@]}"} bash -c "${STAGING_DOWN}") >> "${STAGING_LOG}" 2>&1 \
    || log "staging: STAGING_DOWN failed; see ${STAGING_LOG}"
}

#######################################
# At exit: stop a STAGING_CHECK and a STAGING_UP that still run, then STAGING_DOWN. Detached services of a project
# without STAGING_DOWN stay up; the next start brings them up to date.
#######################################
staging_stop() {
  staging_kill_group "${STAGING_CHECK_PID}"
  staging_kill_up
  staging_down
  log "staging stopped with the loop"
}
