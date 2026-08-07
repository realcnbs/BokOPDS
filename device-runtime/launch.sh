#!/bin/sh
set -u

APP_DIR="${BOKOPDS_APP_DIR:-/mnt/onboard/.adds/bokopds}"
LOCK_DIR="${BOKOPDS_LOCK_DIR:-/tmp/bokopds-running}"
LOG_FILE="${APP_DIR}/launch.log"

acquired=false
for _attempt in 1 2; do
    if mkdir "${LOCK_DIR}" 2>/dev/null; then
        printf '%s\n' "$$" > "${LOCK_DIR}/pid"
        acquired=true
        break
    fi
    previous_pid=$(cat "${LOCK_DIR}/pid" 2>/dev/null || true)
    if [ -n "${previous_pid}" ] && kill -0 "${previous_pid}" 2>/dev/null; then
        logger -t BokOPDS "launch ignored because another instance is running"
        exit 0
    fi
    rm -f "${LOCK_DIR}/pid" 2>/dev/null || true
    rmdir "${LOCK_DIR}" 2>/dev/null || true
done
if [ "${acquired}" != "true" ]; then
    logger -t BokOPDS "launch failed because the application lock could not be acquired"
    exit 1
fi

cleanup() {
    status=$?
    trap - EXIT INT TERM HUP
    rm -f "${LOCK_DIR}/pid" 2>/dev/null || true
    rmdir "${LOCK_DIR}" 2>/dev/null || true
    exit "${status}"
}
runtime_pid=""
collect_descendants() {
    root_pid=$1
    frontier=${root_pid}
    seen=" ${root_pid} "
    descendants=""
    while [ -n "${frontier}" ]; do
        next_frontier=""
        for stat_path in /proc/[0-9]*/stat; do
            [ -r "${stat_path}" ] || continue
            pid=${stat_path#/proc/}
            pid=${pid%/stat}
            stat_line=$(cat "${stat_path}" 2>/dev/null || true)
            [ -n "${stat_line}" ] || continue
            stat_fields=${stat_line##*) }
            set -- ${stat_fields}
            parent_pid=${2:-}
            case " ${frontier} " in
                *" ${parent_pid} "*)
                    case "${seen}" in
                        *" ${pid} "*) ;;
                        *)
                            seen="${seen}${pid} "
                            descendants="${descendants} ${pid}"
                            next_frontier="${next_frontier} ${pid}"
                            ;;
                    esac
                    ;;
            esac
        done
        frontier=${next_frontier}
    done
    printf '%s\n' "${descendants}"
}

terminate_runtime() {
    trap '' INT TERM HUP
    descendant_pids=""
    if [ -n "${runtime_pid}" ] && kill -0 "${runtime_pid}" 2>/dev/null; then
        # KOReader's Trapper workers put themselves in separate process groups.
        # Capture the complete process tree before terminating the UI so those
        # workers cannot be reparented and continue writing after lock cleanup.
        descendant_pids=$(collect_descendants "${runtime_pid}")
        for pid in ${descendant_pids}; do
            kill -TERM "-${pid}" 2>/dev/null || kill -TERM "${pid}" 2>/dev/null || true
        done
    fi
    if kill -0 "-$$" 2>/dev/null; then
        # QProcess::startDetached creates a session for this launcher. This
        # group contains koreader.sh and LuaJIT, but not Trapper workers.
        kill -TERM "-$$" 2>/dev/null || true
    elif [ -n "${runtime_pid}" ] && kill -0 "${runtime_pid}" 2>/dev/null; then
        kill -TERM "${runtime_pid}" 2>/dev/null || true
    fi
    if [ -n "${runtime_pid}" ]; then
        for _attempt in 1 2 3; do
            kill -0 "${runtime_pid}" 2>/dev/null || break
            sleep 1
        done
        if kill -0 "${runtime_pid}" 2>/dev/null; then
            kill -KILL "${runtime_pid}" 2>/dev/null || true
        fi
        for pid in ${descendant_pids}; do
            if [ -r "/proc/${pid}/stat" ]; then
                stat_line=$(cat "/proc/${pid}/stat" 2>/dev/null || true)
                stat_fields=${stat_line##*) }
                set -- ${stat_fields}
                process_group=${3:-}
                if [ "${process_group}" = "${pid}" ]; then
                    kill -KILL "-${pid}" 2>/dev/null || true
                fi
            fi
        done
        wait "${runtime_pid}" 2>/dev/null || true
    fi
}
trap cleanup EXIT
trap 'terminate_runtime; exit 130' INT
trap 'terminate_runtime; exit 143' TERM HUP

: > "${LOG_FILE}"
exec >> "${LOG_FILE}" 2>&1
echo "BokOPDS launch started: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

export KOREADER_DIR="${APP_DIR}"
export KO_HOME="${APP_DIR}/state"
export BOKOPDS_SHELL=1
export BOKOPDS_LIBRARY_REFRESH_MARKER="${APP_DIR}/library-refresh.pending"
export BOKOPDS_DOWNLOAD_DIR="${BOKOPDS_DOWNLOAD_DIR:-/mnt/onboard/BokOPDS}"
export BOKOPDS_LIBRARY_ROOT="${BOKOPDS_LIBRARY_ROOT:-/mnt/onboard}"
export SSL_CERT_FILE="${APP_DIR}/data/ca-bundle.crt"

mkdir -p "${KO_HOME}" "${BOKOPDS_DOWNLOAD_DIR}"
"${APP_DIR}/koreader.sh" &
runtime_pid=$!
# The lock tracks the runtime, not this supervisor. If the supervisor is
# killed, another launch still sees the live UI and cannot start a duplicate.
printf '%s\n' "${runtime_pid}" > "${LOCK_DIR}/pid"
set +e
wait "${runtime_pid}"
application_status=$?
set -e
runtime_pid=""
echo "BokOPDS exited with status ${application_status}"
exit "${application_status}"
