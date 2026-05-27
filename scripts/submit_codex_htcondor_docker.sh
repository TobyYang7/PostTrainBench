#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
source src/commit_utils/set_env_vars.sh

IMAGE="${POST_TRAIN_BENCH_HTCONDOR_IMAGE:-posttrainbench-htcondor-submit}"
CONTAINER="${POST_TRAIN_BENCH_HTCONDOR_CONTAINER:-ptb-htcondor-submit}"
CUDA_DEVICE_IDX="${CUDA_DEVICE_IDX:-7}"
POST_TRAIN_BENCH_EXPERIMENT_NAME="${POST_TRAIN_BENCH_EXPERIMENT_NAME:-_gpu7}"
POST_TRAIN_BENCH_RESULTS_DIR="${POST_TRAIN_BENCH_RESULTS_DIR:-$REPO_ROOT/results}"
CONDOR_LOG_DIR="${CONDOR_LOG_DIR:-$REPO_ROOT/.htcondor-submit/logs}"
POST_TRAIN_BENCH_HTCONDOR_HOME="${POST_TRAIN_BENCH_HTCONDOR_HOME:-$REPO_ROOT/.htcondor-submit/home}"

HF_HOME_IS_DEFAULT=0
if [[ -z "${HF_HOME:-}" ]]; then
    HF_HOME="$POST_TRAIN_BENCH_HTCONDOR_HOME/.cache/huggingface"
    HF_HOME_IS_DEFAULT=1
fi

if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: docker is not available in PATH." >&2
    exit 127
fi

if ! docker info >/dev/null 2>&1; then
    echo "ERROR: cannot access the Docker daemon." >&2
    echo "Make sure this host allows your user to run docker, or run this from a Docker-capable submit host." >&2
    exit 126
fi

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    docker build \
        --build-arg "HTCONDOR_SUBMIT_IMAGE=${HTCONDOR_SUBMIT_IMAGE:-htcondor/submit:lts}" \
        -t "$IMAGE" \
        "$REPO_ROOT/docker/htcondor-submit"
fi

mkdir -p \
    "$REPO_ROOT/.htcondor-submit/tokens" \
    "$REPO_ROOT/.htcondor-submit/passwords" \
    "$REPO_ROOT/.htcondor-submit/config" \
    "$CONDOR_LOG_DIR" \
    "$POST_TRAIN_BENCH_RESULTS_DIR" \
    "$POST_TRAIN_BENCH_HTCONDOR_HOME" \
    "$HF_HOME"
chmod 1777 "$CONDOR_LOG_DIR" "$POST_TRAIN_BENCH_RESULTS_DIR" "$POST_TRAIN_BENCH_HTCONDOR_HOME"
if [[ "$HF_HOME_IS_DEFAULT" -eq 1 ]]; then
    chmod 1777 "$HF_HOME"
fi

if docker ps -a --format '{{.Names}}' | grep -Fxq "$CONTAINER"; then
    if ! docker ps --format '{{.Names}}' | grep -Fxq "$CONTAINER"; then
        docker start "$CONTAINER" >/dev/null
    fi
else
    if [[ -z "${CONDOR_HOST:-${CONDOR_SERVICE_HOST:-}}" ]]; then
        echo "ERROR: set CONDOR_HOST or CONDOR_SERVICE_HOST for the HTCondor pool before starting the submit container." >&2
        exit 2
    fi

    docker run -d --name "$CONTAINER" \
        --network host \
        -e CONDOR_HOST="${CONDOR_HOST:-}" \
        -e CONDOR_SERVICE_HOST="${CONDOR_SERVICE_HOST:-}" \
        -e USE_POOL_PASSWORD="${USE_POOL_PASSWORD:-no}" \
        -e CONDOR_SUBMIT_BID_APPEND="${CONDOR_SUBMIT_BID_APPEND:-}" \
        -v "$REPO_ROOT:$REPO_ROOT" \
        -v "$REPO_ROOT/.htcondor-submit/tokens:/etc/condor/tokens-orig.d:ro" \
        -v "$REPO_ROOT/.htcondor-submit/passwords:/etc/condor/passwords-orig.d:ro" \
        -v "$REPO_ROOT/.htcondor-submit/config:/root/config:ro" \
        "$IMAGE"
fi

docker exec \
    -u submituser \
    -w "$REPO_ROOT" \
    -e OPENAI_API_KEY="${OPENAI_API_KEY:-}" \
    -e ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}" \
    -e GEMINI_API_KEY="${GEMINI_API_KEY:-}" \
    -e OPENCODE_API_KEY="${OPENCODE_API_KEY:-}" \
    -e DASHSCOPE_API_KEY="${DASHSCOPE_API_KEY:-}" \
    -e ZAI_API_KEY="${ZAI_API_KEY:-}" \
    -e HF_TOKEN="${HF_TOKEN:-}" \
    -e GITHUB_TOKEN="${GITHUB_TOKEN:-}" \
    -e ML_INTERN_MODEL="${ML_INTERN_MODEL:-}" \
    -e ML_INTERN_MAX_ITERATIONS="${ML_INTERN_MAX_ITERATIONS:-}" \
    -e ML_MASTER_CODE_MODEL="${ML_MASTER_CODE_MODEL:-}" \
    -e ML_MASTER_CODE_BASE_URL="${ML_MASTER_CODE_BASE_URL:-}" \
    -e ML_MASTER_CODE_API_KEY="${ML_MASTER_CODE_API_KEY:-}" \
    -e ML_MASTER_FEEDBACK_MODEL="${ML_MASTER_FEEDBACK_MODEL:-}" \
    -e ML_MASTER_FEEDBACK_BASE_URL="${ML_MASTER_FEEDBACK_BASE_URL:-}" \
    -e ML_MASTER_FEEDBACK_API_KEY="${ML_MASTER_FEEDBACK_API_KEY:-}" \
    -e ML_MASTER_STEPS="${ML_MASTER_STEPS:-}" \
    -e ML_MASTER_TIME_LIMIT_SECS="${ML_MASTER_TIME_LIMIT_SECS:-}" \
    -e ML_MASTER_EXEC_TIMEOUT_SECS="${ML_MASTER_EXEC_TIMEOUT_SECS:-}" \
    -e ML_MASTER_PARALLEL_SEARCH_NUM="${ML_MASTER_PARALLEL_SEARCH_NUM:-}" \
    -e ML_MASTER_CPU_NUMBER="${ML_MASTER_CPU_NUMBER:-}" \
    -e ML_MASTER_NUM_DRAFTS="${ML_MASTER_NUM_DRAFTS:-}" \
    -e ML_MASTER_NUM_IMPROVES="${ML_MASTER_NUM_IMPROVES:-}" \
    -e ML_MASTER_NUM_BUGS="${ML_MASTER_NUM_BUGS:-}" \
    -e POST_TRAIN_BENCH_AGENT="${POST_TRAIN_BENCH_AGENT:-}" \
    -e POST_TRAIN_BENCH_AGENT_CONFIG="${POST_TRAIN_BENCH_AGENT_CONFIG:-}" \
    -e HOME="$POST_TRAIN_BENCH_HTCONDOR_HOME" \
    -e HF_HOME="$HF_HOME" \
    -e APPTAINER_CACHEDIR="${APPTAINER_CACHEDIR:-}" \
    -e APPTAINER_TMPDIR="${APPTAINER_TMPDIR:-}" \
    -e POST_TRAIN_BENCH_RESULTS_DIR="$POST_TRAIN_BENCH_RESULTS_DIR" \
    -e POST_TRAIN_BENCH_CONTAINERS_DIR="${POST_TRAIN_BENCH_CONTAINERS_DIR:-}" \
    -e POST_TRAIN_BENCH_CONTAINER_NAME="${POST_TRAIN_BENCH_CONTAINER_NAME:-}" \
    -e POST_TRAIN_BENCH_PROMPT="${POST_TRAIN_BENCH_PROMPT:-}" \
    -e POST_TRAIN_BENCH_JOB_SCHEDULER="${POST_TRAIN_BENCH_JOB_SCHEDULER:-htcondor}" \
    -e POST_TRAIN_BENCH_WORKSPACE_ROOT="${POST_TRAIN_BENCH_WORKSPACE_ROOT:-}" \
    -e CUDA_DEVICE_IDX="$CUDA_DEVICE_IDX" \
    -e POST_TRAIN_BENCH_EXPERIMENT_NAME="$POST_TRAIN_BENCH_EXPERIMENT_NAME" \
    -e CONDOR_LOG_DIR="$CONDOR_LOG_DIR" \
    "$CONTAINER" \
    bash src/commit_utils/commit_codex.sh
