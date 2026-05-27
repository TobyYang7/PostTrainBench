#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  bash scripts/htcondor/guard_single_task_resubmit.sh [options] \
    <cluster_id> <agent> <agent_config> <eval> <model_to_train> <num_hours> <cuda_device_idx> <result_root>

Options:
  --interval <seconds>       Poll interval. Default: 60
  --max-resubmits <count>    Maximum automatic resubmits. Default: 1
  --condor-log-dir <dir>     HTCondor log directory. Default: .htcondor-local/logs

Behavior:
  - Watches the active cluster until it leaves the queue.
  - If the run produced a non-empty result_dir/final_model, exits successfully.
  - Otherwise, automatically resubmits the same task parameters, updates the watched
    cluster id, and continues watching until success or the resubmit limit is hit.
EOF
}

INTERVAL=60
MAX_RESUBMITS=1
CONDOR_LOG_DIR=".htcondor-local/logs"

while [ "$#" -gt 0 ]; do
    case "${1:-}" in
        --interval)
            INTERVAL="$2"
            shift 2
            ;;
        --max-resubmits)
            MAX_RESUBMITS="$2"
            shift 2
            ;;
        --condor-log-dir)
            CONDOR_LOG_DIR="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            break
            ;;
    esac
done

if [ "$#" -ne 8 ]; then
    usage >&2
    exit 1
fi

CLUSTER_ID="$1"
AGENT="$2"
AGENT_CONFIG="$3"
EVAL_NAME="$4"
MODEL_TO_TRAIN="$5"
NUM_HOURS="$6"
CUDA_DEVICE_IDX="$7"
RESULT_ROOT="$8"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

source src/commit_utils/set_env_vars.sh

export POST_TRAIN_BENCH_JOB_SCHEDULER="${POST_TRAIN_BENCH_JOB_SCHEDULER:-htcondor}"

if [ "$AGENT" = "rdagent" ] && { [ -z "${RD_AGENT_MODE:-}" ] || [ "${RD_AGENT_MODE:-}" = "UNDEFINED" ]; }; then
    export RD_AGENT_MODE="sft"
fi

if [ -z "${POST_TRAIN_BENCH_REQUIRED_GPU_NAME:-}" ] || [ "${POST_TRAIN_BENCH_REQUIRED_GPU_NAME:-}" = "UNDEFINED" ]; then
    if command -v nvidia-smi >/dev/null 2>&1; then
        POST_TRAIN_BENCH_REQUIRED_GPU_NAME="$(nvidia-smi --query-gpu=name --format=csv,noheader | head -n 1 || true)"
    fi
fi
case "${POST_TRAIN_BENCH_REQUIRED_GPU_NAME:-}" in
    *H100*)
        POST_TRAIN_BENCH_REQUIRED_GPU_NAME="H100"
        ;;
    *H20*)
        POST_TRAIN_BENCH_REQUIRED_GPU_NAME="H20"
        ;;
    ""|UNDEFINED)
        POST_TRAIN_BENCH_REQUIRED_GPU_NAME="H20"
        ;;
esac
export POST_TRAIN_BENCH_REQUIRED_GPU_NAME

RESULT_ROOT_DIR="$(dirname "$RESULT_ROOT")"
RESULT_ROOT_BASENAME="$(basename "$RESULT_ROOT")"
RESULT_PREFIX="${AGENT}_${AGENT_CONFIG}_${NUM_HOURS}h"
if [[ "$RESULT_ROOT_BASENAME" == "${RESULT_PREFIX}"* ]]; then
    export POST_TRAIN_BENCH_RESULTS_DIR="${POST_TRAIN_BENCH_RESULTS_DIR:-$RESULT_ROOT_DIR}"
    export POST_TRAIN_BENCH_EXPERIMENT_NAME="${RESULT_ROOT_BASENAME#${RESULT_PREFIX}}"
fi

CONDOR_DIR="${POST_TRAIN_BENCH_PERSONAL_CONDOR_DIR:-$REPO_ROOT/.htcondor-local/condor}"
if [ ! -f "$CONDOR_DIR/condor.sh" ]; then
    echo "ERROR: missing $CONDOR_DIR/condor.sh" >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$CONDOR_DIR/condor.sh"

ensure_condor_submit() {
    if ! command -v condor_submit_bid >/dev/null 2>&1; then
        if command -v condor_submit >/dev/null 2>&1; then
            condor_submit_bid() {
                if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
                    echo "ERROR: condor_submit_bid fallback cannot apply bid '$1'." >&2
                    return 127
                fi
                condor_submit "$@"
            }
        else
            echo "ERROR: neither condor_submit_bid nor condor_submit is available in PATH." >&2
            exit 127
        fi
    fi
}

ensure_condor_submit

find_result_dir() {
    local cluster_id="$1"
    local target="$2"

    if [ -f "$target/output.log" ] || [ -f "$target/error.log" ]; then
        printf '%s\n' "$target"
        return 0
    fi

    if [ -d "$target" ]; then
        find "$target" -maxdepth 1 -mindepth 1 -type d -name "*_${cluster_id}" | sort | tail -n 1
        return 0
    fi

    printf '%s\n' ""
}

cluster_in_queue() {
    local cluster_id="$1"
    condor_q -af ClusterId 2>/dev/null | awk -v cluster_id="$cluster_id" 'NF && $1 == cluster_id { found = 1 } END { exit(found ? 0 : 1) }'
}

has_final_model() {
    local result_dir="$1"
    [ -d "$result_dir/final_model" ] || return 1
    find "$result_dir/final_model" -mindepth 1 -print -quit 2>/dev/null | grep -q .
}

has_success_artifacts() {
    local result_dir="$1"
    has_final_model "$result_dir" || return 1
    [ -f "$result_dir/metrics.json" ] || return 1
    [ -f "$result_dir/contamination_judgement.txt" ] || return 1
    [ -f "$result_dir/disallowed_model_judgement.txt" ] || return 1
}

cluster_exit_code() {
    local cluster_id="$1"
    condor_history "$cluster_id" -limit 1 -af ExitCode 2>/dev/null | awk 'NF { print $1; exit }'
}

run_succeeded() {
    local cluster_id="$1"
    local result_dir="$2"
    local exit_code=""

    [ -n "$result_dir" ] || return 1
    has_success_artifacts "$result_dir" || return 1

    exit_code="$(cluster_exit_code "$cluster_id")"
    [ "$exit_code" = "0" ]
}

show_failure_summary() {
    local result_dir="$1"
    local output_log="$result_dir/output.log"
    local error_log="$result_dir/error.log"

    echo "--- failure summary for $result_dir ---"
    if [ -f "$output_log" ]; then
        tail -n 80 "$output_log" || true
    else
        echo "MISSING: $output_log"
    fi
    if [ -f "$error_log" ]; then
        tail -n 40 "$error_log" || true
    else
        echo "MISSING: $error_log"
    fi
}

submit_replacement() {
    local submit_output
    submit_output="$(
        condor_submit_bid \
            -a "agent=$AGENT" \
            -a "agent_config=$AGENT_CONFIG" \
            -a "eval=$EVAL_NAME" \
            -a "model_to_train=$MODEL_TO_TRAIN" \
            -a "num_hours=$NUM_HOURS" \
            -a "gpu_requirements=true" \
            -a "cuda_device_idx=$CUDA_DEVICE_IDX" \
            -a "condor_log_dir=$CONDOR_LOG_DIR" \
            src/commit_utils/single_task.sub
    )"
    echo "$submit_output" >&2
    printf '%s\n' "$submit_output" | sed -n 's/.*cluster \([0-9]\+\).*/\1/p' | tail -n 1
}

RESUBMITS=0

while true; do
    ts="$(date '+%Y-%m-%d %H:%M:%S %Z')"
    result_dir="$(find_result_dir "$CLUSTER_ID" "$RESULT_ROOT")"

    echo "[$ts] watching cluster $CLUSTER_ID result_dir=${result_dir:-PENDING}"

    if cluster_in_queue "$CLUSTER_ID"; then
        sleep "$INTERVAL"
        continue
    fi

    if run_succeeded "$CLUSTER_ID" "$result_dir"; then
        echo "[$ts] cluster $CLUSTER_ID completed successfully with metrics.json; guard exiting successfully."
        exit 0
    fi

    if [ "$RESUBMITS" -ge "$MAX_RESUBMITS" ]; then
        echo "[$ts] cluster $CLUSTER_ID left queue without full success artifacts and resubmit limit was reached." >&2
        if [ -n "$result_dir" ]; then
            show_failure_summary "$result_dir"
        fi
        exit 1
    fi

    if [ -n "$result_dir" ]; then
        show_failure_summary "$result_dir"
    else
        echo "[$ts] no result directory found for cluster $CLUSTER_ID; resubmitting anyway." >&2
    fi

    new_cluster_id="$(submit_replacement)"
    if [ -z "$new_cluster_id" ]; then
        echo "[$ts] ERROR: failed to parse replacement cluster id from condor_submit output." >&2
        exit 1
    fi

    RESUBMITS=$((RESUBMITS + 1))
    echo "[$ts] resubmitted as cluster $new_cluster_id (attempt $RESUBMITS/$MAX_RESUBMITS)." >&2
    CLUSTER_ID="$new_cluster_id"
    sleep "$INTERVAL"
done
