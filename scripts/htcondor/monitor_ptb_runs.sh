#!/usr/bin/env bash
set -uo pipefail

usage() {
    cat <<'EOF'
Usage:
  bash scripts/htcondor/monitor_ptb_runs.sh [--interval seconds] <cluster_id> <result_root_or_dir> [<cluster_id> <result_root_or_dir> ...]

Examples:
  bash scripts/htcondor/monitor_ptb_runs.sh --interval 30 \
    101 results/ml_intern_gpt-5.5_10h_prompt1_gpu3_ml_intern_htcondor \
    102 results/codex_non_api_high_gpt-5.5_10h_prompt3_gpu5_htcondor
EOF
}

if [ "$#" -lt 2 ]; then
    usage
    exit 1
fi

INTERVAL=60

if [ "${1:-}" = "--interval" ]; then
    if [ "$#" -lt 4 ]; then
        usage
        exit 1
    fi
    INTERVAL="$2"
    shift 2
fi

if [ $(( $# % 2 )) -ne 0 ]; then
    echo "ERROR: cluster/result arguments must come in pairs." >&2
    usage
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONDOR_DIR="${POST_TRAIN_BENCH_PERSONAL_CONDOR_DIR:-$REPO_ROOT/.htcondor-local/condor}"

if [ ! -f "$CONDOR_DIR/condor.sh" ]; then
    echo "Missing $CONDOR_DIR/condor.sh" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$CONDOR_DIR/condor.sh"

declare -a CLUSTERS=()
declare -a TARGETS=()

while [ "$#" -gt 0 ]; do
    CLUSTERS+=("$1")
    TARGETS+=("$2")
    shift 2
done

find_result_dir() {
    local cluster_id="$1"
    local target="$2"
    local parent_dir
    local target_name

    if [ -f "$target/output.log" ] || [ -f "$target/error.log" ]; then
        printf '%s\n' "$target"
        return 0
    fi

    if [ -d "$target" ]; then
        find "$target" -maxdepth 1 -mindepth 1 -type d -name "*_${cluster_id}" | sort | tail -n 1
        return 0
    fi

    parent_dir="$(dirname "$target")"
    target_name="$(basename "$target")"

    if [ -d "$parent_dir" ]; then
        find "$parent_dir" -maxdepth 2 -mindepth 2 -type d \
            -path "$parent_dir/$target_name/*_${cluster_id}" | sort | tail -n 1
        return 0
    fi

    printf '%s\n' ""
}

cluster_in_queue() {
    local cluster_id="$1"
    condor_q -af ClusterId 2>/dev/null | awk -v cluster_id="$cluster_id" 'NF && $1 == cluster_id { found = 1 } END { exit(found ? 0 : 1) }'
}

show_error_signals() {
    local file="$1"

    if [ ! -f "$file" ]; then
        echo "MISSING"
        return 0
    fi

    if ! tail -n 200 "$file" | rg -n -i 'traceback|exception|error:|failed|fatal|cuda out of memory|segmentation fault|permission denied|no such file|runtimeerror|valueerror|keyerror|assertionerror'; then
        echo "no obvious error signatures in last 200 lines"
    fi
}

snapshot_cluster() {
    local cluster_id="$1"
    local target="$2"
    local result_dir
    local ts

    result_dir="$(find_result_dir "$cluster_id" "$target")"
    ts="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"

    echo
    echo "=== $ts | cluster $cluster_id ==="
    echo "target: $target"
    echo "result_dir: ${result_dir:-PENDING}"
    echo "--- condor_q ---"
    condor_q -constraint "ClusterId == $cluster_id" -nobatch 2>&1 || true
    echo "--- condor_history ---"
    condor_history "$cluster_id" -limit 3 2>&1 || true

    if [ -n "$result_dir" ]; then
        for f in \
            "$result_dir/output.log" \
            "$result_dir/error.log" \
            "$result_dir/solve_out.txt" \
            "$result_dir/proj/workspace/system_monitor.log"; do
            echo "--- tail: $f ---"
            if [ -f "$f" ]; then
                tail -n 40 "$f" || true
            else
                echo "MISSING"
            fi
        done

        echo "--- error signatures: output.log ---"
        show_error_signals "$result_dir/output.log"
        echo "--- error signatures: error.log ---"
        show_error_signals "$result_dir/error.log"
        echo "--- error signatures: solve_out.txt ---"
        show_error_signals "$result_dir/solve_out.txt"
    else
        echo "--- result directory has not appeared yet ---"
    fi
}

while true; do
    active_count=0

    echo
    echo "############################################################"
    echo "# snapshot $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo "############################################################"
    echo "--- condor_status -compact ---"
    condor_status -compact 2>&1 || true

    i=0
    while [ "$i" -lt "${#CLUSTERS[@]}" ]; do
        cluster_id="${CLUSTERS[$i]}"
        target="${TARGETS[$i]}"
        snapshot_cluster "$cluster_id" "$target"
        if cluster_in_queue "$cluster_id"; then
            active_count=$((active_count + 1))
        fi
        i=$((i + 1))
    done

    if [ "$active_count" -eq 0 ]; then
        echo
        echo "All watched clusters have left the queue."
        exit 0
    fi

    sleep "$INTERVAL"
done
