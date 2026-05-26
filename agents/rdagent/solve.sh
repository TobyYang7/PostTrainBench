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

RD_AGENT_DIR="/home/ben/rd-agent"
if [ ! -d "$RD_AGENT_DIR/rdagent" ]; then
    echo "ERROR: expected rd-agent checkout at ${RD_AGENT_DIR}" >&2
    exit 1
fi

RD_AGENT_MODE="${RD_AGENT_MODE:-sft}"
RD_AGENT_VENV="${RD_AGENT_DIR}/.venv"
RD_AGENT_TIMEOUT="${RD_AGENT_TIMEOUT:-${NUM_HOURS:-10}h}"
RD_AGENT_LOOP_N="${RD_AGENT_LOOP_N:-3}"
RD_AGENT_STEP_N="${RD_AGENT_STEP_N:-}"
RD_AGENT_EMBEDDING_MODEL="${RD_AGENT_EMBEDDING_MODEL:-text-embedding-3-small}"

setup_rdagent_env() {
    cd "$RD_AGENT_DIR"

    if [ ! -x "${RD_AGENT_VENV}/bin/python" ]; then
        uv venv --seed "$RD_AGENT_VENV"
        "${RD_AGENT_VENV}/bin/python" -m pip install --upgrade pip
        "${RD_AGENT_VENV}/bin/python" -m pip install -e .
        "${RD_AGENT_VENV}/bin/python" -m pip install pyyaml
        "${RD_AGENT_VENV}/bin/python" -m pip install "llamafactory==0.9.3"
        "${RD_AGENT_VENV}/bin/python" -m pip install "opencompass @ git+https://github.com/Jensen246/opencompass.git"
    fi

    cat > "${RD_AGENT_DIR}/.env" <<EOF
BACKEND=rdagent.oai.backend.LiteLLMAPIBackend
OPENAI_API_KEY=${OPENAI_API_KEY:-}
OPENAI_API_BASE=${OPENAI_API_BASE:-}
CHAT_MODEL=${AGENT_CONFIG:-${OPENAI_MODEL_NAME:-gpt-5.5}}
EMBEDDING_MODEL=${RD_AGENT_EMBEDDING_MODEL}
FT_Coder_CoSTEER_env_type=local
FT_LOCAL_BIN_PATH=${RD_AGENT_VENV}/bin
BENCHMARK_LOCAL_BIN_PATH=${RD_AGENT_VENV}/bin
FT_FILE_PATH=/home/ben/task/rdagent_ft_files
RL_FILE_PATH=/home/ben/task/rdagent_rl_files
RDAGENT_ALLOW_FAKE_EMBEDDING=1
EOF
}

benchmark_description_for_sft() {
    case "$1" in
        gsm8k)
            printf '%s' 'GSM8K grade-school math word problems. Solve each problem correctly and return the final answer clearly.'
            ;;
        aime2025)
            printf '%s' 'AIME 2025 math competition problems. Each answer is an integer from 0 to 999. Put the final answer within \boxed{}, for example \boxed{42}.'
            ;;
        *)
            return 1
            ;;
    esac
}

prepare_rl_assets() {
    mkdir -p /home/ben/task/rdagent_rl_workspace /home/ben/task/final_model

    cat > /home/ben/task/rdagent_rl_workspace/description.md <<EOF
PostTrainBench RL post-training task

Benchmark: ${EVALUATION_TASK}
Base model: ${MODEL_TO_TRAIN}

Goal: improve the model through RL post-training and save the best resulting model under /home/ben/task/final_model.
External evaluation is handled by PostTrainBench after the run finishes.
EOF

    "${RD_AGENT_VENV}/bin/python" - <<'PY'
from pathlib import Path
from rdagent.scenarios.rl.autorl_bench.core.utils import download_data, download_model
import os

base_model = os.environ["MODEL_TO_TRAIN"]
task = os.environ["EVALUATION_TASK"]
root = Path("/home/ben/task/rdagent_rl_files")
(root / "models").mkdir(parents=True, exist_ok=True)
(root / "datasets").mkdir(parents=True, exist_ok=True)
download_model(base_model, str(root / "models"))
download_data(task, str(root / "datasets"))
PY
}

run_sft_mode() {
    local benchmark="${EVALUATION_TASK}"
    local dataset="deepscaler"
    local benchmark_description

    benchmark_description="$(benchmark_description_for_sft "$benchmark")" || {
        echo "ERROR: rdagent SFT mode currently supports only gsm8k and aime2025; got ${benchmark}" >&2
        exit 1
    }

    cd "$RD_AGENT_DIR"
    local cmd=(
        "${RD_AGENT_VENV}/bin/python" -m rdagent.app.finetune.llm.loop
        --benchmark "$benchmark"
        --benchmark-description "$benchmark_description"
        --dataset "$dataset"
        --base-model "$MODEL_TO_TRAIN"
        --loop-n "$RD_AGENT_LOOP_N"
        --timeout "$RD_AGENT_TIMEOUT"
    )
    if [ -n "$RD_AGENT_STEP_N" ]; then
        cmd+=(--step_n "$RD_AGENT_STEP_N")
    fi
    "${cmd[@]}"
}

run_rl_mode() {
    case "${EVALUATION_TASK}" in
        gsm8k|humaneval)
            ;;
        *)
            echo "ERROR: rdagent RL mode currently supports only gsm8k and humaneval; got ${EVALUATION_TASK}" >&2
            exit 1
            ;;
    esac

    prepare_rl_assets

    export TASK="${EVALUATION_TASK}"
    export BASE_MODEL="${MODEL_TO_TRAIN}"
    export WORKSPACE="/home/ben/task/rdagent_rl_workspace"
    export MODEL_PATH="/home/ben/task/rdagent_rl_files/models/${MODEL_TO_TRAIN}"
    export DATA_PATH="/home/ben/task/rdagent_rl_files/datasets/${EVALUATION_TASK}"
    export OUTPUT_DIR="/home/ben/task/final_model"
    export GRADING_SERVER_URL=""

    cd "$RD_AGENT_DIR"
    local cmd=(
        "${RD_AGENT_VENV}/bin/python" -m rdagent.app.rl.loop
        --base-model "$MODEL_TO_TRAIN"
        --benchmark "$EVALUATION_TASK"
        --loop-n "$RD_AGENT_LOOP_N"
        --timeout "$RD_AGENT_TIMEOUT"
    )
    if [ -n "$RD_AGENT_STEP_N" ]; then
        cmd+=(--step-n "$RD_AGENT_STEP_N")
    fi
    "${cmd[@]}"
}

setup_rdagent_env

case "$RD_AGENT_MODE" in
    sft)
        run_sft_mode
        ;;
    rl)
        run_rl_mode
        ;;
    *)
        echo "ERROR: unknown RD_AGENT_MODE=${RD_AGENT_MODE}; expected sft or rl" >&2
        exit 1
        ;;
esac
