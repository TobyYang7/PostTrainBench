#!/bin/bash
set -euo pipefail

ENV_FILE="/home/ben/.env"
if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck source=/dev/null
    source "$ENV_FILE"
    set +a
fi

if [ -z "${OPENAI_API_KEY:-}" ] && [ -n "${CODEX_API_KEY:-}" ]; then
    export OPENAI_API_KEY="$CODEX_API_KEY"
fi
if [ -z "${OPENAI_API_BASE:-}" ] && [ -n "${OPENAI_BASE_URL:-}" ]; then
    export OPENAI_API_BASE="$OPENAI_BASE_URL"
fi

ML_MASTER_REPO_DIR="${ML_MASTER_REPO_DIR:-/home/ben/ML-Master}"
if [ ! -d "$ML_MASTER_REPO_DIR/agent" ]; then
    echo "ERROR: expected ML-Master checkout at ${ML_MASTER_REPO_DIR}" >&2
    exit 1
fi

check_ml_master_imports() {
    python - <<'PY'
import importlib.util
import sys

modules = [
    "backoff",
    "coolname",
    "dataclasses_json",
    "funcy",
    "genson",
    "humanize",
    "jsonschema",
    "omegaconf",
    "requests",
    "rich",
    "shutup",
]
missing = [name for name in modules if importlib.util.find_spec(name) is None]
if missing:
    print(",".join(missing))
    sys.exit(1)
PY
}

ensure_ml_master_dependencies() {
    if check_ml_master_imports >/dev/null 2>&1; then
        return 0
    fi

    local vendor_dir="${ML_MASTER_VENDOR_DIR:-/home/ben/ml-master-vendor}"
    mkdir -p "$vendor_dir"

    if command -v uv >/dev/null 2>&1; then
        uv pip install \
            --quiet \
            --target "$vendor_dir" \
            -r "$ML_MASTER_REPO_DIR/requirements-posttrainbench.txt"
    else
        if ! python -m pip --version >/dev/null 2>&1; then
            python -m ensurepip --upgrade >/dev/null 2>&1 || true
        fi
        if python -m pip --version >/dev/null 2>&1; then
            python -m pip install \
                --disable-pip-version-check \
                --quiet \
                --target "$vendor_dir" \
                -r "$ML_MASTER_REPO_DIR/requirements-posttrainbench.txt"
        elif command -v pip3 >/dev/null 2>&1; then
            pip3 install \
                --disable-pip-version-check \
                --quiet \
                --target "$vendor_dir" \
                -r "$ML_MASTER_REPO_DIR/requirements-posttrainbench.txt"
        else
            echo "ERROR: cannot bootstrap ML-Master dependencies: neither uv nor pip is available" >&2
            check_ml_master_imports || true
            exit 1
        fi
    fi

    export PYTHONPATH="$vendor_dir${PYTHONPATH:+:$PYTHONPATH}"
    check_ml_master_imports >/dev/null
}

resolve_remaining_seconds() {
    if [ -x "./timer.sh" ]; then
        local remaining_line
        remaining_line="$(bash ./timer.sh 2>/dev/null | tail -n 1 | tr -d '\r')"
        if [[ "$remaining_line" =~ ^([0-9]+):([0-9]{2})$ ]]; then
            echo $((10#${BASH_REMATCH[1]} * 3600 + 10#${BASH_REMATCH[2]} * 60))
            return 0
        fi
    fi
    echo 36000
}

normalize_int_setting() {
    local value="$1"
    local fallback="$2"
    if [[ -z "$value" || "$value" == "UNDEFINED" || ! "$value" =~ ^[0-9]+$ ]]; then
        echo "$fallback"
    else
        echo "$value"
    fi
}

normalize_string_setting() {
    local value="$1"
    local fallback="$2"
    if [[ -z "$value" || "$value" == "UNDEFINED" ]]; then
        echo "$fallback"
    else
        echo "$value"
    fi
}

ensure_ml_master_dependencies

ML_MASTER_CODE_MODEL="${ML_MASTER_CODE_MODEL:-${AGENT_CONFIG:-gpt-5.5}}"
ML_MASTER_FEEDBACK_MODEL="${ML_MASTER_FEEDBACK_MODEL:-${POST_TRAIN_BENCH_JUDGE_MODEL:-$ML_MASTER_CODE_MODEL}}"
ML_MASTER_CODE_MODEL="$(normalize_string_setting "$ML_MASTER_CODE_MODEL" "${AGENT_CONFIG:-gpt-5.5}")"
ML_MASTER_FEEDBACK_MODEL="$(normalize_string_setting "$ML_MASTER_FEEDBACK_MODEL" "$ML_MASTER_CODE_MODEL")"
if [[ "$ML_MASTER_CODE_MODEL" == openai/* ]]; then
    ML_MASTER_CODE_MODEL="${ML_MASTER_CODE_MODEL#openai/}"
fi
if [[ "$ML_MASTER_FEEDBACK_MODEL" == openai/* ]]; then
    ML_MASTER_FEEDBACK_MODEL="${ML_MASTER_FEEDBACK_MODEL#openai/}"
fi
ML_MASTER_CODE_BASE_URL="${ML_MASTER_CODE_BASE_URL:-${OPENAI_API_BASE:-${OPENAI_BASE_URL:-https://api.openai.com/v1}}}"
ML_MASTER_CODE_API_KEY="${ML_MASTER_CODE_API_KEY:-${OPENAI_API_KEY:-}}"
ML_MASTER_FEEDBACK_BASE_URL="${ML_MASTER_FEEDBACK_BASE_URL:-$ML_MASTER_CODE_BASE_URL}"
ML_MASTER_FEEDBACK_API_KEY="${ML_MASTER_FEEDBACK_API_KEY:-$ML_MASTER_CODE_API_KEY}"
ML_MASTER_CODE_BASE_URL="$(normalize_string_setting "$ML_MASTER_CODE_BASE_URL" "${OPENAI_API_BASE:-${OPENAI_BASE_URL:-https://api.openai.com/v1}}")"
ML_MASTER_CODE_API_KEY="$(normalize_string_setting "$ML_MASTER_CODE_API_KEY" "${OPENAI_API_KEY:-}")"
ML_MASTER_FEEDBACK_BASE_URL="$(normalize_string_setting "$ML_MASTER_FEEDBACK_BASE_URL" "$ML_MASTER_CODE_BASE_URL")"
ML_MASTER_FEEDBACK_API_KEY="$(normalize_string_setting "$ML_MASTER_FEEDBACK_API_KEY" "$ML_MASTER_CODE_API_KEY")"

if [ -z "$ML_MASTER_CODE_API_KEY" ]; then
    echo "ERROR: ML-Master code model API key is empty" >&2
    exit 1
fi
if [ -z "$ML_MASTER_FEEDBACK_API_KEY" ]; then
    echo "ERROR: ML-Master feedback model API key is empty" >&2
    exit 1
fi

REMAINING_SECS="$(resolve_remaining_seconds)"
ML_MASTER_TIME_LIMIT_SECS="${ML_MASTER_TIME_LIMIT_SECS:-$REMAINING_SECS}"
ML_MASTER_TIME_LIMIT_SECS="$(normalize_int_setting "$ML_MASTER_TIME_LIMIT_SECS" "$REMAINING_SECS")"
if [ "$ML_MASTER_TIME_LIMIT_SECS" -gt "$REMAINING_SECS" ]; then
    ML_MASTER_TIME_LIMIT_SECS="$REMAINING_SECS"
fi
if [ "$ML_MASTER_TIME_LIMIT_SECS" -lt 600 ]; then
    ML_MASTER_TIME_LIMIT_SECS=600
fi

DEFAULT_EXEC_TIMEOUT_SECS="$ML_MASTER_TIME_LIMIT_SECS"
if [ "$DEFAULT_EXEC_TIMEOUT_SECS" -gt 10800 ]; then
    DEFAULT_EXEC_TIMEOUT_SECS=10800
fi
ML_MASTER_EXEC_TIMEOUT_SECS="${ML_MASTER_EXEC_TIMEOUT_SECS:-$DEFAULT_EXEC_TIMEOUT_SECS}"
ML_MASTER_EXEC_TIMEOUT_SECS="$(normalize_int_setting "$ML_MASTER_EXEC_TIMEOUT_SECS" "$DEFAULT_EXEC_TIMEOUT_SECS")"
if [ "$ML_MASTER_EXEC_TIMEOUT_SECS" -gt "$ML_MASTER_TIME_LIMIT_SECS" ]; then
    ML_MASTER_EXEC_TIMEOUT_SECS="$ML_MASTER_TIME_LIMIT_SECS"
fi
if [ "$ML_MASTER_EXEC_TIMEOUT_SECS" -lt 300 ]; then
    ML_MASTER_EXEC_TIMEOUT_SECS=300
fi

ML_MASTER_STEPS="${ML_MASTER_STEPS:-24}"
ML_MASTER_PARALLEL_SEARCH_NUM="${ML_MASTER_PARALLEL_SEARCH_NUM:-1}"
ML_MASTER_NUM_DRAFTS="${ML_MASTER_NUM_DRAFTS:-2}"
ML_MASTER_NUM_IMPROVES="${ML_MASTER_NUM_IMPROVES:-2}"
ML_MASTER_NUM_BUGS="${ML_MASTER_NUM_BUGS:-1}"
ML_MASTER_CPU_NUMBER="${ML_MASTER_CPU_NUMBER:-$(nproc)}"
ML_MASTER_STEPS="$(normalize_int_setting "$ML_MASTER_STEPS" 24)"
ML_MASTER_PARALLEL_SEARCH_NUM="$(normalize_int_setting "$ML_MASTER_PARALLEL_SEARCH_NUM" 1)"
ML_MASTER_NUM_DRAFTS="$(normalize_int_setting "$ML_MASTER_NUM_DRAFTS" 2)"
ML_MASTER_NUM_IMPROVES="$(normalize_int_setting "$ML_MASTER_NUM_IMPROVES" 2)"
ML_MASTER_NUM_BUGS="$(normalize_int_setting "$ML_MASTER_NUM_BUGS" 1)"
ML_MASTER_CPU_NUMBER="$(normalize_int_setting "$ML_MASTER_CPU_NUMBER" "$(nproc)")"
if [ "$ML_MASTER_CPU_NUMBER" -lt "$ML_MASTER_PARALLEL_SEARCH_NUM" ]; then
    ML_MASTER_CPU_NUMBER="$ML_MASTER_PARALLEL_SEARCH_NUM"
fi

RUN_ID="posttrainbench_$(date +%Y%m%d_%H%M%S)"
ML_MASTER_WORKSPACE_DIR="/home/ben/ml-master-workspace/${RUN_ID}"
ML_MASTER_LOG_DIR="/home/ben/ml-master-logs/${RUN_ID}"
ML_MASTER_PROMPT_FILE="/tmp/ml_master_posttrain_prompt.md"

{
    echo "You are running inside PostTrainBench, not MLE-Bench."
    echo
    echo "Execution model:"
    echo "- The entire benchmark working directory has been copied into ./input inside your workspace."
    echo "- Treat ./input as the task root. Read and run files from there."
    echo "- Use ./working for scratch space."
    echo "- The required final artifact is a usable model directory at ./submission/final_model."
    echo "- This directory will be copied back to the original benchmark root as ./final_model after your run."
    echo
    echo "Extra rules for this meta-run:"
    echo "- Do not modify ./input/evaluate.py or any files under ./input/templates/."
    echo "- Print a numeric validation metric to stdout for each meaningful experiment."
    echo "- Leave the best checkpoint or adapter in ./submission/final_model before the script exits."
    echo "- If you need the benchmark timer, run: bash ./input/timer.sh"
    echo
    echo "===== PostTrainBench task prompt ====="
    printf '%s\n' "$PROMPT"
} > "$ML_MASTER_PROMPT_FILE"

cd "$ML_MASTER_REPO_DIR"
python main_mcts.py \
    data_dir="/home/ben/task" \
    dataset_dir="/home/ben/task" \
    desc_file="$ML_MASTER_PROMPT_FILE" \
    output_dir_name="submission" \
    required_output_name="final_model" \
    required_output_type="dir" \
    workspace_dir="$ML_MASTER_WORKSPACE_DIR" \
    log_dir="$ML_MASTER_LOG_DIR" \
    exp_name="$RUN_ID" \
    preprocess_data=False \
    copy_data=True \
    start_cpu_id="0" \
    cpu_number="$ML_MASTER_CPU_NUMBER" \
    exec.timeout="$ML_MASTER_EXEC_TIMEOUT_SECS" \
    agent.steps="$ML_MASTER_STEPS" \
    agent.time_limit="$ML_MASTER_TIME_LIMIT_SECS" \
    agent.obfuscate=true \
    agent.check_format=false \
    agent.save_all_submission=false \
    agent.steerable_reasoning=false \
    agent.search.parallel_search_num="$ML_MASTER_PARALLEL_SEARCH_NUM" \
    agent.search.num_drafts="$ML_MASTER_NUM_DRAFTS" \
    agent.search.num_improves="$ML_MASTER_NUM_IMPROVES" \
    agent.search.num_bugs="$ML_MASTER_NUM_BUGS" \
    agent.code.model="$ML_MASTER_CODE_MODEL" \
    agent.code.base_url="$ML_MASTER_CODE_BASE_URL" \
    agent.code.api_key="$ML_MASTER_CODE_API_KEY" \
    agent.feedback.model="$ML_MASTER_FEEDBACK_MODEL" \
    agent.feedback.base_url="$ML_MASTER_FEEDBACK_BASE_URL" \
    agent.feedback.api_key="$ML_MASTER_FEEDBACK_API_KEY"

BEST_OUTPUT_DIR="$ML_MASTER_WORKSPACE_DIR/best_submission/final_model"
if [ ! -d "$BEST_OUTPUT_DIR" ] || [ "$(find "$BEST_OUTPUT_DIR" -mindepth 1 -print -quit 2>/dev/null | wc -l)" -eq 0 ]; then
    echo "ERROR: ML-Master did not produce a usable best_submission/final_model" >&2
    exit 1
fi

cp -r "$BEST_OUTPUT_DIR" /home/ben/task/final_model
