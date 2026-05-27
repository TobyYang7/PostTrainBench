if [ "${POST_TRAIN_BENCH_JOB_SCHEDULER:-}" = "htcondor_mpi-is" ]; then
    source /etc/profile.d/modules.sh
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

export POST_TRAIN_BENCH_REPO_ROOT="$REPO_ROOT"
export HF_HOME_NEW="/home/ben/hf_cache"

# Helper function: sets variable to default if unset or "UNDEFINED"
set_default() {
    local var_name="${1:-}"
    local default_value="${2:-}"
    local current_value
    eval "current_value=\"\${$var_name:-}\""

    if [ -z "$current_value" ] || [ "$current_value" = "UNDEFINED" ]; then
        export "$var_name"="$default_value"
    fi
}

sanitize_experiment_component() {
    local value="${1:-}"
    value="$(printf '%s' "$value" | tr '/:[] ,=' '_' | tr -s '_')"
    value="${value##_}"
    value="${value%%_}"
    printf '%s' "$value"
}

auto_set_post_train_bench_experiment_name() {
    local current_value="${POST_TRAIN_BENCH_EXPERIMENT_NAME:-}"
    local prompt_name=""
    local gpu_name=""
    local scheduler_name=""
    local parts=()
    local joined=""

    if [ -n "$current_value" ] && [ "$current_value" != "UNDEFINED" ]; then
        return 0
    fi

    prompt_name="$(sanitize_experiment_component "${POST_TRAIN_BENCH_PROMPT:-}")"
    if [ -n "$prompt_name" ]; then
        parts+=("$prompt_name")
    fi

    if [ -n "${CUDA_DEVICE_IDX:-}" ] && [ "${CUDA_DEVICE_IDX:-}" != "UNDEFINED" ]; then
        gpu_name="$(sanitize_experiment_component "gpu${CUDA_DEVICE_IDX}")"
        if [ -n "$gpu_name" ]; then
            parts+=("$gpu_name")
        fi
    fi

    scheduler_name="$(sanitize_experiment_component "${POST_TRAIN_BENCH_JOB_SCHEDULER:-}")"
    if [ -n "$scheduler_name" ]; then
        parts+=("$scheduler_name")
    fi

    if [ "${#parts[@]}" -eq 0 ]; then
        export POST_TRAIN_BENCH_EXPERIMENT_NAME=""
        return 0
    fi

    printf -v joined '%s_' "${parts[@]}"
    joined="${joined%_}"
    export POST_TRAIN_BENCH_EXPERIMENT_NAME="_${joined}"
}

load_env_defaults_file() {
    local env_file="${1:-}"
    local raw_line
    local line
    local var_name

    if [ -z "$env_file" ] || [ ! -f "$env_file" ]; then
        return 0
    fi

    while IFS= read -r raw_line || [ -n "$raw_line" ]; do
        line="${raw_line#"${raw_line%%[![:space:]]*}"}"

        if [ -z "$line" ] || [[ "$line" == \#* ]]; then
            continue
        fi

        if [[ "$line" == export[[:space:]]* ]]; then
            line="${line#export }"
            line="${line#"${line%%[![:space:]]*}"}"
        fi

        if [[ ! "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
            continue
        fi

        var_name="${line%%=*}"
        if [ -z "${!var_name+x}" ] || [ "${!var_name}" = "UNDEFINED" ]; then
            eval "export $line"
        fi
    done < "$env_file"
}

load_env_defaults_file "$REPO_ROOT/.env.local"
load_env_defaults_file "$REPO_ROOT/.env"

set_default HF_HOME "$HOME/.cache/huggingface"
set_default POST_TRAIN_BENCH_RESULTS_DIR "results"
set_default POST_TRAIN_BENCH_CONTAINERS_DIR "containers"
set_default POST_TRAIN_BENCH_CONTAINER_NAME "standard"
set_default POST_TRAIN_BENCH_PROMPT "prompt1"
set_default POST_TRAIN_BENCH_JOB_SCHEDULER "htcondor"
set_default POST_TRAIN_BENCH_EXPERIMENT_NAME ""
set_default POST_TRAIN_BENCH_WORKSPACE_ROOT "/tmp"
set_default POST_TRAIN_BENCH_GEPA_VENV_DIR "$REPO_ROOT/.runtime/gepa-venv"
set_default POST_TRAIN_BENCH_RDAGENT_VENV_DIR "$REPO_ROOT/.runtime/rdagent-venv"
set_default POST_TRAIN_BENCH_RDAGENT_BENCHMARK_VENV_DIR "$REPO_ROOT/.runtime/rdagent-benchmark-venv"
set_default POST_TRAIN_BENCH_ML_MASTER_VENDOR_DIR "$REPO_ROOT/.runtime/mlmaster-vendor"
set_default POST_TRAIN_BENCH_ML_MASTER_SHIM_DIR "$REPO_ROOT/.runtime/mlmaster-shims"
set_default APPTAINER_CACHEDIR "$HOME/.apptainer/cache"
set_default APPTAINER_TMPDIR "${TMPDIR:-/tmp}"

export PYTHONNOUSERSITE=1

if [ "${POST_TRAIN_BENCH_JOB_SCHEDULER:-}" = "htcondor_mpi-is" ]; then
    SAVE_PATH="$PATH"
    module load cuda/12.1
    export PATH="$PATH:$SAVE_PATH"
    hash -r
fi
