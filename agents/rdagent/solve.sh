#!/bin/bash
set -euo pipefail
unset VIRTUAL_ENV PYTHONHOME

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

normalize_optional_env() {
    local value="${1:-}"
    if [ -z "$value" ] || [ "$value" = "UNDEFINED" ]; then
        printf '%s' ""
    else
        printf '%s' "$value"
    fi
}

normalize_int_env() {
    local value="${1:-}"
    local fallback="${2:-}"
    if [ -z "$value" ] || [ "$value" = "UNDEFINED" ] || [[ ! "$value" =~ ^[0-9]+$ ]]; then
        printf '%s' "$fallback"
    else
        printf '%s' "$value"
    fi
}

normalize_timeout_env() {
    local value="${1:-}"
    local fallback="${2:-}"
    if [ -z "$value" ] || [ "$value" = "UNDEFINED" ]; then
        printf '%s' "$fallback"
    else
        printf '%s' "$value"
    fi
}

RD_AGENT_DIR="/home/ben/rd-agent"
if [ ! -d "$RD_AGENT_DIR/rdagent" ]; then
    echo "ERROR: expected rd-agent checkout at ${RD_AGENT_DIR}" >&2
    exit 1
fi

RD_AGENT_MODE="${RD_AGENT_MODE:-sft}"
RD_AGENT_VENV="${RD_AGENT_VENV:-/opt/posttrain_rdagent_venv}"
RD_AGENT_BENCHMARK_VENV="${RD_AGENT_BENCHMARK_VENV:-/opt/posttrain_rdagent_benchmark_venv}"
RD_AGENT_TIMEOUT="$(normalize_timeout_env "${RD_AGENT_TIMEOUT:-}" "${NUM_HOURS:-10}h")"
RD_AGENT_LOOP_N="$(normalize_int_env "${RD_AGENT_LOOP_N:-}" 3)"
RD_AGENT_STEP_N="$(normalize_optional_env "${RD_AGENT_STEP_N:-}")"
RD_AGENT_TIMEOUT_HOURS="$(normalize_int_env "${NUM_HOURS:-}" 10)"
RD_AGENT_DATA_PROCESSING_TIMEOUT_DEFAULT="$((RD_AGENT_TIMEOUT_HOURS * 3600))"
RD_AGENT_EMBEDDING_MODEL="$(normalize_optional_env "${RD_AGENT_EMBEDDING_MODEL:-text-embedding-3-small}")"
if [ -z "$RD_AGENT_EMBEDDING_MODEL" ]; then
    RD_AGENT_EMBEDDING_MODEL="text-embedding-3-small"
fi
RD_AGENT_OPENAI_API_BASE="$(normalize_optional_env "${OPENAI_BASE_URL:-${OPENAI_API_BASE:-https://api.openai.com/v1}}")"
RD_AGENT_OPENAI_API_KEY="$(normalize_optional_env "${OPENAI_API_KEY:-}")"
RD_AGENT_TASK_ROOT="/home/ben/task"
RD_AGENT_FT_ROOT="${RD_AGENT_TASK_ROOT}/rdagent_ft_files"
RD_AGENT_RL_ROOT="${RD_AGENT_TASK_ROOT}/rdagent_rl_files"
RD_AGENT_WORKSPACE_ROOT="${RD_AGENT_TASK_ROOT}/rdagent_workspace"
RD_AGENT_CACHE_ROOT="${RD_AGENT_TASK_ROOT}/rdagent_cache"

if [ -z "$RD_AGENT_OPENAI_API_BASE" ]; then
    RD_AGENT_OPENAI_API_BASE="https://api.openai.com/v1"
fi
if [ -z "$RD_AGENT_OPENAI_API_KEY" ]; then
    echo "ERROR: rd-agent OpenAI API key is empty" >&2
    exit 1
fi

export OPENAI_API_KEY="$RD_AGENT_OPENAI_API_KEY"
export OPENAI_API_BASE="$RD_AGENT_OPENAI_API_BASE"
export OPENAI_BASE_URL="$RD_AGENT_OPENAI_API_BASE"
export BACKEND="rdagent.oai.backend.LiteLLMAPIBackend"
export CHAT_MODEL="${AGENT_CONFIG:-${OPENAI_MODEL_NAME:-gpt-5.5}}"
export EMBEDDING_MODEL="${RD_AGENT_EMBEDDING_MODEL}"
export RDAGENT_ALLOW_FAKE_EMBEDDING="${RDAGENT_ALLOW_FAKE_EMBEDDING:-1}"
export FT_STRONG_MODELS="${FT_STRONG_MODELS:-[\"gpt-5.5\",\"gpt-5.4\",\"gpt-5.2\"]}"
export FT_WEAK_MODELS="${FT_WEAK_MODELS:-[\"gpt-5.4-mini\",\"gpt-5.5\"]}"
export FT_DATA_PROCESSING_TIMEOUT="${FT_DATA_PROCESSING_TIMEOUT:-${RD_AGENT_DATA_PROCESSING_TIMEOUT_DEFAULT}}"
export OC_JUDGE_API_KEY="$(normalize_optional_env "${OC_JUDGE_API_KEY:-$RD_AGENT_OPENAI_API_KEY}")"
if [ -z "${OC_JUDGE_API_KEY:-}" ]; then
    export OC_JUDGE_API_KEY="$RD_AGENT_OPENAI_API_KEY"
fi
export OC_JUDGE_API_BASE="$(normalize_optional_env "${OC_JUDGE_API_BASE:-$RD_AGENT_OPENAI_API_BASE}")"
if [ -z "${OC_JUDGE_API_BASE:-}" ]; then
    export OC_JUDGE_API_BASE="$RD_AGENT_OPENAI_API_BASE"
fi
export OC_JUDGE_MODEL="$(normalize_optional_env "${OC_JUDGE_MODEL:-${POST_TRAIN_BENCH_JUDGE_MODEL:-gpt-5.5}}")"
if [ -z "${OC_JUDGE_MODEL:-}" ]; then
    export OC_JUDGE_MODEL="gpt-5.5"
fi
export FT_JUDGE_API_KEY="${OC_JUDGE_API_KEY}"
export FT_JUDGE_API_BASE="${OC_JUDGE_API_BASE}"
export FT_JUDGE_MODEL="${OC_JUDGE_MODEL}"
export FT_Coder_CoSTEER_env_type="local"
export FT_LOCAL_BIN_PATH="${RD_AGENT_VENV}/bin"
export BENCHMARK_LOCAL_BIN_PATH="${RD_AGENT_BENCHMARK_VENV}/bin"
export FT_FILE_PATH="${RD_AGENT_FT_ROOT}"
export RL_FILE_PATH="${RD_AGENT_RL_ROOT}"
export WORKSPACE_PATH="${RD_AGENT_WORKSPACE_ROOT}"
export PICKLE_CACHE_FOLDER_PATH_STR="${RD_AGENT_CACHE_ROOT}/pickle"

mkdir -p \
    "${RD_AGENT_FT_ROOT}" \
    "${RD_AGENT_RL_ROOT}" \
    "${RD_AGENT_WORKSPACE_ROOT}" \
    "${RD_AGENT_CACHE_ROOT}" \
    "${RD_AGENT_TASK_ROOT}/final_model"

rdagent_import_ready() {
    [ -x "${RD_AGENT_VENV}/bin/python" ] || return 1
    "${RD_AGENT_VENV}/bin/python" - <<'PY' >/dev/null 2>&1
import importlib.util
import sys
sys.exit(0 if importlib.util.find_spec("rdagent") else 1)
PY
}

rdagent_benchmark_import_ready() {
    [ -x "${RD_AGENT_BENCHMARK_VENV}/bin/python" ] || return 1
    "${RD_AGENT_BENCHMARK_VENV}/bin/python" - <<'PY' >/dev/null 2>&1
import importlib.util
import sys
sys.exit(0 if importlib.util.find_spec("opencompass") else 1)
PY
}

setup_rdagent_env() {
    cd "$RD_AGENT_DIR"

    if ! rdagent_import_ready; then
        uv venv --seed "$RD_AGENT_VENV"
        "${RD_AGENT_VENV}/bin/python" -m pip install --upgrade pip
        # The copied rd-agent checkout inside the benchmark container does not
        # carry usable VCS metadata, so setuptools-scm needs a fallback version.
        SETUPTOOLS_SCM_PRETEND_VERSION=0.0.0 \
            "${RD_AGENT_VENV}/bin/python" -m pip install -e .
        "${RD_AGENT_VENV}/bin/python" -m pip install pyyaml
        "${RD_AGENT_VENV}/bin/python" -m pip install "llamafactory==0.9.3"
    fi

    if ! rdagent_benchmark_import_ready; then
        uv venv --seed "$RD_AGENT_BENCHMARK_VENV"
        "${RD_AGENT_BENCHMARK_VENV}/bin/python" -m pip install --upgrade pip
        "${RD_AGENT_BENCHMARK_VENV}/bin/python" -m pip install "opencompass @ git+https://github.com/Jensen246/opencompass.git"
    fi

    cat > "${RD_AGENT_DIR}/.env" <<EOF
BACKEND=rdagent.oai.backend.LiteLLMAPIBackend
OPENAI_API_KEY=${RD_AGENT_OPENAI_API_KEY}
OPENAI_API_BASE=${RD_AGENT_OPENAI_API_BASE}
CHAT_MODEL=${CHAT_MODEL}
EMBEDDING_MODEL=${RD_AGENT_EMBEDDING_MODEL}
FT_STRONG_MODELS=${FT_STRONG_MODELS}
FT_WEAK_MODELS=${FT_WEAK_MODELS}
FT_DATA_PROCESSING_TIMEOUT=${FT_DATA_PROCESSING_TIMEOUT}
FT_JUDGE_API_KEY=${FT_JUDGE_API_KEY}
FT_JUDGE_API_BASE=${FT_JUDGE_API_BASE}
FT_JUDGE_MODEL=${FT_JUDGE_MODEL}
FT_Coder_CoSTEER_env_type=local
FT_LOCAL_BIN_PATH=${RD_AGENT_VENV}/bin
BENCHMARK_LOCAL_BIN_PATH=${RD_AGENT_BENCHMARK_VENV}/bin
FT_FILE_PATH=${RD_AGENT_FT_ROOT}
RL_FILE_PATH=${RD_AGENT_RL_ROOT}
WORKSPACE_PATH=${RD_AGENT_WORKSPACE_ROOT}
PICKLE_CACHE_FOLDER_PATH_STR=${RD_AGENT_CACHE_ROOT}/pickle
RDAGENT_ALLOW_FAKE_EMBEDDING=${RDAGENT_ALLOW_FAKE_EMBEDDING}
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
    mkdir -p "${RD_AGENT_TASK_ROOT}/rdagent_rl_workspace" "${RD_AGENT_TASK_ROOT}/final_model"

    cat > "${RD_AGENT_TASK_ROOT}/rdagent_rl_workspace/description.md" <<EOF
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

collect_best_sft_model() {
    local final_model_dir="${RD_AGENT_TASK_ROOT}/final_model"
    rm -rf "${final_model_dir}"
    mkdir -p "${final_model_dir}"

    "${RD_AGENT_VENV}/bin/python" - <<'PY'
import csv
import os
import shutil
import sys
from pathlib import Path

from rdagent.app.finetune.llm.ui.benchmarks import get_core_metric_score

workspace_root = Path(os.environ["WORKSPACE_PATH"])
benchmark_name = os.environ["EVALUATION_TASK"]
final_model_dir = Path("/home/ben/task/final_model")


def build_accuracy_summary(csv_path: Path) -> dict:
    with csv_path.open(newline="", encoding="utf-8") as fh:
        reader = csv.DictReader(fh)
        rows = list(reader)

    score_cols = [c for c in reader.fieldnames or [] if c not in {"dataset", "version", "metric", "mode"}]
    if not score_cols:
        return {}

    score_col = score_cols[0]
    accuracy_summary: dict[str, dict[str, float]] = {}
    for row in rows:
        try:
            score = float(row[score_col])
        except (TypeError, ValueError):
            continue
        accuracy_summary.setdefault(row["dataset"], {})[row["metric"]] = score
    return accuracy_summary


def has_model_artifacts(output_dir: Path) -> bool:
    required = [
        "adapter_config.json",
        "adapter_model.bin",
        "adapter_model.safetensors",
        "model.safetensors",
        "pytorch_model.bin",
    ]
    if any((output_dir / name).exists() for name in required):
        return True
    return any(output_dir.glob("*.safetensors")) or any(output_dir.glob("*.bin"))


best = None
for workspace in sorted(workspace_root.glob("*")):
    if not workspace.is_dir():
        continue

    output_dir = workspace / "output"
    if not output_dir.is_dir() or not has_model_artifacts(output_dir):
        continue

    score = None
    higher_is_better = True
    metric_name = None
    summary_dirs = sorted((workspace / "benchmark_results" / "validation").glob("*/summary"))
    if summary_dirs:
        csv_files = sorted(summary_dirs[-1].glob("*.csv"))
        if csv_files:
            accuracy_summary = build_accuracy_summary(csv_files[-1])
            metric = get_core_metric_score(benchmark_name, accuracy_summary)
            if metric is not None:
                metric_name, score, higher_is_better = metric

    mtime = max((p.stat().st_mtime for p in output_dir.rglob("*")), default=output_dir.stat().st_mtime)
    candidate = {
        "workspace": workspace,
        "output_dir": output_dir,
        "score": score,
        "higher_is_better": higher_is_better,
        "metric_name": metric_name,
        "mtime": mtime,
    }

    if best is None:
        best = candidate
        continue

    if candidate["score"] is not None and best["score"] is not None:
        better = candidate["score"] > best["score"] if candidate["higher_is_better"] else candidate["score"] < best["score"]
        if better or (candidate["score"] == best["score"] and candidate["mtime"] > best["mtime"]):
            best = candidate
        continue

    if candidate["score"] is not None and best["score"] is None:
        best = candidate
        continue

    if candidate["score"] is None and best["score"] is None and candidate["mtime"] > best["mtime"]:
        best = candidate

if best is None:
    print(f"ERROR: no SFT output directory with model artifacts found under {workspace_root}", file=sys.stderr)
    sys.exit(1)

shutil.copytree(best["output_dir"], final_model_dir, dirs_exist_ok=True)
metric_desc = "no validation score found"
if best["score"] is not None and best["metric_name"] is not None:
    metric_desc = f"{best['metric_name']}={best['score']}"

print(
    f"Selected SFT final_model from {best['workspace'].name} ({metric_desc}) -> {final_model_dir}",
    flush=True,
)
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
    collect_best_sft_model
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
    export WORKSPACE="${RD_AGENT_TASK_ROOT}/rdagent_rl_workspace"
    export MODEL_PATH="${RD_AGENT_RL_ROOT}/models/${MODEL_TO_TRAIN}"
    export DATA_PATH="${RD_AGENT_RL_ROOT}/datasets/${EVALUATION_TASK}"
    export OUTPUT_DIR="${RD_AGENT_TASK_ROOT}/final_model"
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
