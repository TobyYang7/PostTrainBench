#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONDOR_DIR="${POST_TRAIN_BENCH_PERSONAL_CONDOR_DIR:-$REPO_ROOT/.htcondor-local/condor}"

if [ ! -f "$CONDOR_DIR/condor.sh" ]; then
    echo "Personal HTCondor is not configured at $CONDOR_DIR"
    exit 0
fi

# shellcheck source=/dev/null
source "$CONDOR_DIR/condor.sh"

find_local_daemon_pids() {
    local current_user

    current_user="$(id -un)"
    ps -eo pid=,user=,comm= | awk -v current_user="$current_user" '
        $2 == current_user &&
        $3 ~ /^condor_(master|collector|negotiator|schedd|startd|shared_port|procd)$/ {
            print $1
        }
    '
}

wait_for_local_daemons_to_exit() {
    local timeout="$1"
    local deadline=$((SECONDS + timeout))
    local -a pids=()

    while [ "$SECONDS" -lt "$deadline" ]; do
        mapfile -t pids < <(find_local_daemon_pids)
        if [ "${#pids[@]}" -eq 0 ]; then
            return 0
        fi
        sleep 1
    done

    return 1
}

kill_local_daemons() {
    local signal="$1"
    local -a pids=()

    mapfile -t pids < <(find_local_daemon_pids)
    if [ "${#pids[@]}" -eq 0 ]; then
        return 0
    fi

    echo "Sending SIG${signal} to Personal HTCondor daemons: ${pids[*]}"
    kill "-${signal}" "${pids[@]}" 2>/dev/null || true
}

cleanup_local_state() {
    local local_dir lock_dir path legacy_lock_dir
    local -a legacy_lock_dirs=()

    local_dir="$(condor_config_val LOCAL_DIR 2>/dev/null || printf '%s/local\n' "$CONDOR_DIR")"
    lock_dir="$(condor_config_val LOCK 2>/dev/null || true)"

    shopt -s nullglob
    for path in \
        "$local_dir"/log/.master_address* \
        "$local_dir"/log/.collector_address* \
        "$local_dir"/log/.startd_address* \
        "$local_dir"/spool/.schedd_address*; do
        rm -f "$path"
    done
    shopt -u nullglob

    if [ -n "$lock_dir" ] && [ -d "$lock_dir" ]; then
        rm -f \
            "$lock_dir/InstanceLock" \
            "$lock_dir/shared_port_ad" \
            "$lock_dir/procd_pipe" \
            "$lock_dir/procd_pipe.watchdog"
    fi

    mapfile -t legacy_lock_dirs < <(find /tmp -maxdepth 1 -type d -name 'condor-lock-*' -user "$(id -u)" 2>/dev/null | sort)
    for legacy_lock_dir in "${legacy_lock_dirs[@]}"; do
        rm -f \
            "$legacy_lock_dir/InstanceLock" \
            "$legacy_lock_dir/shared_port_ad" \
            "$legacy_lock_dir/procd_pipe" \
            "$legacy_lock_dir/procd_pipe.watchdog"
    done
}

echo "Stopping Personal HTCondor..."
condor_off -master >/dev/null 2>&1 || true

if ! wait_for_local_daemons_to_exit 15; then
    kill_local_daemons TERM
fi

if ! wait_for_local_daemons_to_exit 10; then
    kill_local_daemons KILL
fi

if ! wait_for_local_daemons_to_exit 5; then
    echo "Warning: some Personal HTCondor daemons are still present after SIGKILL." >&2
fi

cleanup_local_state
