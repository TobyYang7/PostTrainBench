#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONDOR_DIR="${POST_TRAIN_BENCH_PERSONAL_CONDOR_DIR:-$REPO_ROOT/.htcondor-local/condor}"

bash "$REPO_ROOT/scripts/setup_personal_htcondor.sh"

# shellcheck source=/dev/null
source "$CONDOR_DIR/condor.sh"

wait_for_pool_ready() {
    local timeout="$1"
    local deadline=$((SECONDS + timeout))

    while [ "$SECONDS" -lt "$deadline" ]; do
        if condor_status -compact >/dev/null 2>&1 && condor_q -nobatch >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done

    return 1
}

show_diagnostics() {
    condor_status -compact 2>&1 || true
    condor_q -nobatch 2>&1 || true
}

count_user_condor_masters() {
    local current_user

    current_user="$(id -un)"
    ps -eo user=,comm= | awk -v current_user="$current_user" '
        $1 == current_user && $2 == "condor_master" { count += 1 }
        END { print count + 0 }
    '
}

master_count="$(count_user_condor_masters)"

if [ "$master_count" -gt 1 ]; then
    echo "Detected multiple Personal HTCondor masters for user $(id -un); restarting the local pool."
    bash "$REPO_ROOT/scripts/stop_personal_htcondor.sh"
elif condor_config_val -master MASTER_PID >/dev/null 2>&1; then
    if wait_for_pool_ready 30; then
        echo "Personal HTCondor is already running."
        condor_status -compact
        exit 0
    fi

    echo "Personal HTCondor is running but not ready for submissions; restarting it."
    bash "$REPO_ROOT/scripts/stop_personal_htcondor.sh"
elif ! wait_for_pool_ready 1; then
    # If the address files are stale but the master is already gone, clear them
    # before starting a fresh local pool.
    bash "$REPO_ROOT/scripts/stop_personal_htcondor.sh" >/dev/null 2>&1 || true
fi

condor_master

echo "Waiting for local HTCondor collector/startd/schedd..."
if ! wait_for_pool_ready 60; then
    echo "ERROR: Personal HTCondor did not become ready for queue submissions." >&2
    show_diagnostics >&2
    exit 1
fi

condor_status -compact
