#!/bin/bash
set -euo pipefail

source src/commit_utils/set_env_vars.sh

ensure_condor_submit() {
    if ! command -v condor_submit_bid >/dev/null 2>&1; then
        if command -v condor_submit >/dev/null 2>&1; then
            condor_submit_bid() {
                if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
                    echo "ERROR: condor_submit_bid fallback cannot apply bid '$1'. Use the cluster-provided condor_submit_bid helper for htcondor_mpi-is." >&2
                    return 127
                fi
                condor_submit "$@"
            }
        else
            echo "ERROR: neither condor_submit_bid nor condor_submit is available in PATH." >&2
            echo "Run this from an HTCondor submit environment, or set POST_TRAIN_BENCH_JOB_SCHEDULER=local on a GPU node." >&2
            exit 127
        fi
    fi
}

if [ "${POST_TRAIN_BENCH_JOB_SCHEDULER}" = "htcondor" ] || [ "${POST_TRAIN_BENCH_JOB_SCHEDULER}" = "htcondor_mpi-is" ]; then
    ensure_condor_submit
fi

models=(
    # "google/gemma-3-4b-pt"
    # "Qwen/Qwen3-4B-Base"
    "Qwen/Qwen3-1.7B-Base"
    # "HuggingFaceTB/SmolLM3-3B-Base"
)

evals=(
    # "aime2025"
    "gsm8k"
)

submit_codex_mpi_is() {
    local bid="$1"
    local agent="$2"
    local agent_config="$3"
    local eval="$4"
    local model="$5"
    local num_hours="${6:-10}"
    local cuda_device_idx="${7:-${CUDA_DEVICE_IDX:-}}"
    local condor_log_dir="${CONDOR_LOG_DIR:-.}"
    local submit_args=(
        "$bid"
        -a "agent=$agent"
        -a "agent_config=$agent_config"
        -a "eval=$eval"
        -a "model_to_train=$model"
        -a "num_hours=$num_hours"
        -a "cuda_device_idx=$cuda_device_idx"
        -a "condor_log_dir=$condor_log_dir"
    )
    if [ -n "${CONDOR_GPU_REQUIREMENTS:-}" ]; then
        submit_args+=(-a "gpu_requirements=${CONDOR_GPU_REQUIREMENTS}")
    fi

    condor_submit_bid "${submit_args[@]}" src/commit_utils/single_task.sub
}

submit_codex_htcondor() {
    local agent="$1"
    local agent_config="$2"
    local eval="$3"
    local model="$4"
    local num_hours="${5:-10}"
    local cuda_device_idx="${6:-${CUDA_DEVICE_IDX:-}}"
    local condor_log_dir="${CONDOR_LOG_DIR:-.}"
    local submit_args=(
        -a "agent=$agent"
        -a "agent_config=$agent_config"
        -a "eval=$eval"
        -a "model_to_train=$model"
        -a "num_hours=$num_hours"
        -a "cuda_device_idx=$cuda_device_idx"
        -a "condor_log_dir=$condor_log_dir"
    )
    if [ -n "${CONDOR_GPU_REQUIREMENTS:-}" ]; then
        submit_args+=(-a "gpu_requirements=${CONDOR_GPU_REQUIREMENTS}")
    fi

    condor_submit_bid "${submit_args[@]}" src/commit_utils/single_task.sub
}

submit_codex_local() {
    local agent="$1"
    local agent_config="$2"
    local eval="$3"
    local model="$4"
    local num_hours="${5:-10}"
    local cuda_device_idx="${6:-${CUDA_DEVICE_IDX:-0}}"
    local num_gpus="${7:-${NUM_GPUS:-1}}"
    local local_run_id="${POST_TRAIN_BENCH_LOCAL_RUN_ID:-local_$(date +%Y%m%d%H%M%S)_${RANDOM}}"

    echo "Running locally with id ${local_run_id}"
    bash src/run_task.sh "$eval" "$agent" "$model" "$local_run_id" "$num_hours" "$agent_config" "$num_gpus" "$cuda_device_idx"
}

for model in "${models[@]}"; do
    for eval in "${evals[@]}"; do
        echo ""
        echo "$model on $eval"

        if [ "${POST_TRAIN_BENCH_JOB_SCHEDULER}" = "htcondor_mpi-is" ]; then
            # Codex ChatGPT subscription run
            submit_codex_mpi_is 100 codex_non_api_high "gpt-5.5" "$eval" "$model"
            sleep 10
        elif [ "${POST_TRAIN_BENCH_JOB_SCHEDULER}" = "htcondor" ]; then
            submit_codex_htcondor codex_non_api_high "gpt-5.5" "$eval" "$model"
            sleep 20
        elif [ "${POST_TRAIN_BENCH_JOB_SCHEDULER}" = "local" ]; then
            submit_codex_local codex_non_api_high "gpt-5.5" "$eval" "$model"
        else
            echo ERROR: job scheduler "${POST_TRAIN_BENCH_JOB_SCHEDULER}" is not supported.
        fi
    done
done
