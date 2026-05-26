#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 2 ]; then
    echo "Usage: $0 <cluster_id> <output_log> [interval_seconds]" >&2
    exit 2
fi

CLUSTER_ID="$1"
OUTPUT_LOG="$2"
INTERVAL="${3:-60}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONDOR_SH="${REPO_ROOT}/.htcondor-local/condor/condor.sh"
TEST_LOG="${REPO_ROOT}/.htcondor-local/logs/test_${CLUSTER_ID}.log"

if [ ! -f "$CONDOR_SH" ]; then
    echo "Missing condor env: $CONDOR_SH" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$CONDOR_SH"

find_run_dir() {
    find "${REPO_ROOT}/results" -maxdepth 2 -type d -name "*_${CLUSTER_ID}" | sort | tail -n 1
}

RUN_DIR="$(find_run_dir || true)"
SOLVE_OUT=""
if [ -n "${RUN_DIR:-}" ] && [ -f "${RUN_DIR}/solve_out.txt" ]; then
    SOLVE_OUT="${RUN_DIR}/solve_out.txt"
fi

mkdir -p "$(dirname "$OUTPUT_LOG")"

{
    echo "=== monitor start $(date --iso-8601=seconds) cluster=${CLUSTER_ID} ==="
    echo "repo_root=${REPO_ROOT}"
    echo "run_dir=${RUN_DIR:-missing}"
    echo "solve_out=${SOLVE_OUT:-missing}"
    echo "test_log=${TEST_LOG}"
} >> "$OUTPUT_LOG"

while true; do
    NOW="$(date --iso-8601=seconds)"
    {
        echo
        echo "=== snapshot ${NOW} ==="
        if condor_q "$CLUSTER_ID" -af ClusterId ProcId JobStatus EnteredCurrentStatus RemoteHost CumulativeSlotTime Args; then
            :
        else
            echo "condor_q: cluster ${CLUSTER_ID} no longer in queue"
        fi
        if condor_q "$CLUSTER_ID" -af RemoteHost 2>/dev/null | grep -q .; then
            REMOTE_HOST="$(condor_q "$CLUSTER_ID" -af RemoteHost | head -n 1)"
            if [ -n "$REMOTE_HOST" ] && [ "$REMOTE_HOST" != "undefined" ]; then
                SLOT_NAME="$(echo "$REMOTE_HOST" | sed 's/.*\///')"
                if [ -n "$SLOT_NAME" ]; then
                    condor_status "$SLOT_NAME" -af Name State Activity JobId RemoteUser MemoryUsage ResidentSetSize ImageSize CPUsUsage LastHeardFrom || true
                fi
            fi
        fi
        if [ -f "$TEST_LOG" ]; then
            echo "--- test log tail ---"
            tail -n 12 "$TEST_LOG"
        fi
        if [ -n "$SOLVE_OUT" ] && [ -f "$SOLVE_OUT" ]; then
            echo "--- solve_out stat ---"
            stat -c '%y %s' "$SOLVE_OUT"
            echo "--- solve_out tail ---"
            tail -n 20 "$SOLVE_OUT"
        fi
    } >> "$OUTPUT_LOG"

    if ! condor_q "$CLUSTER_ID" -af ClusterId >/dev/null 2>&1; then
        {
            echo
            echo "=== monitor end $(date --iso-8601=seconds) cluster=${CLUSTER_ID} left queue ==="
        } >> "$OUTPUT_LOG"
        exit 0
    fi

    sleep "$INTERVAL"
done
