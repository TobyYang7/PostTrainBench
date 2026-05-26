#!/usr/bin/env bash
set -uo pipefail

usage() {
    cat <<'EOF'
Usage:
  bash scripts/htcondor/monitor_ptb_cluster.sh <cluster_id> <result_dir> [interval_seconds]

Example:
  bash scripts/htcondor/monitor_ptb_cluster.sh <cluster_id> <result_dir> 30
EOF
}

if [ "$#" -lt 2 ]; then
    usage
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONDOR_DIR="${POST_TRAIN_BENCH_PERSONAL_CONDOR_DIR:-$REPO_ROOT/.htcondor-local/condor}"
CLUSTER_ID="$1"
RESULT_DIR="$2"
INTERVAL="${3:-30}"

if [ ! -f "$CONDOR_DIR/condor.sh" ]; then
    echo "Missing $CONDOR_DIR/condor.sh"
    exit 1
fi

# shellcheck source=/dev/null
source "$CONDOR_DIR/condor.sh"

snapshot_logs() {
    local ts
    ts="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo
    echo "=== $ts | cluster $CLUSTER_ID ==="
    echo "--- condor_q ---"
    q_out="$(condor_q "$CLUSTER_ID" -nobatch 2>&1 || true)"
    printf '%s\n' "$q_out"
    echo "--- condor_history ---"
    h_out="$(condor_history "$CLUSTER_ID" -limit 1 2>&1 || true)"
    printf '%s\n' "$h_out"

    for f in \
        "$RESULT_DIR/output.log" \
        "$RESULT_DIR/error.log" \
        "$RESULT_DIR/solve_out.txt" \
        "$RESULT_DIR/proj/workspace/system_monitor.log"
    do
        echo "--- tail: $f ---"
        if [ -f "$f" ]; then
            tail -n 40 "$f" || true
        else
            echo "MISSING"
        fi
    done
}

while true; do
    snapshot_logs
    q_check="$(condor_q "$CLUSTER_ID" -nobatch 2>/dev/null || true)"
    if ! printf '%s\n' "$q_check" | rg -q "^[[:space:]]*$CLUSTER_ID\\."; then
        echo
        echo "Cluster $CLUSTER_ID no longer in queue. Final history snapshot above."
        break
    fi
    sleep "$INTERVAL"
done
