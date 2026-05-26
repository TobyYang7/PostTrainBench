#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONDOR_DIR="${POST_TRAIN_BENCH_PERSONAL_CONDOR_DIR:-$REPO_ROOT/.htcondor-local/condor}"

if [ ! -f "$CONDOR_DIR/condor.sh" ]; then
    bash "$REPO_ROOT/scripts/setup_personal_htcondor.sh"
fi

# shellcheck source=/dev/null
source "$CONDOR_DIR/condor.sh"

if condor_config_val -master MASTER_PID >/dev/null 2>&1; then
    echo "Personal HTCondor is already running."
else
    condor_master
fi

echo "Waiting for local HTCondor collector/startd..."
for _ in $(seq 1 30); do
    if condor_status -compact >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

condor_status -compact
