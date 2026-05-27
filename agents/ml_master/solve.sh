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

first_nonempty_defined() {
    local candidate
    for candidate in "$@"; do
        if [ -n "$candidate" ] && [ "$candidate" != "UNDEFINED" ]; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    printf '%s' ""
}

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
    local vendor_dir="${ML_MASTER_VENDOR_DIR:-/opt/posttrain_mlmaster_vendor}"
    mkdir -p "$vendor_dir"
    export PYTHONPATH="$vendor_dir${PYTHONPATH:+:$PYTHONPATH}"

    if check_ml_master_imports >/dev/null 2>&1; then
        return 0
    fi

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

install_ml_master_dataset_shim() {
    local shim_dir="${ML_MASTER_SHIM_DIR:-/opt/posttrain_mlmaster_shims}"
    mkdir -p "$shim_dir"

    cat > "${shim_dir}/sitecustomize.py" <<'PY'
try:
    import multiprocessing as _mp

    try:
        _mp.set_start_method("spawn", force=True)
    except RuntimeError:
        pass
except Exception:
    pass

try:
    import datasets
    from datasets import load as _datasets_load

    _orig_load_dataset = datasets.load_dataset
    _orig_load_dataset_builder = datasets.load_dataset_builder
    _orig_module_load_dataset = _datasets_load.load_dataset
    _orig_module_load_dataset_builder = _datasets_load.load_dataset_builder

    def _normalize_dataset_path(path):
        if path == "gsm8k":
            return "openai/gsm8k"
        return path

    def _patched_load_dataset(path, *args, **kwargs):
        return _orig_load_dataset(_normalize_dataset_path(path), *args, **kwargs)

    def _patched_load_dataset_builder(path, *args, **kwargs):
        return _orig_load_dataset_builder(_normalize_dataset_path(path), *args, **kwargs)

    datasets.load_dataset = _patched_load_dataset
    datasets.load_dataset_builder = _patched_load_dataset_builder
    _datasets_load.load_dataset = _patched_load_dataset
    _datasets_load.load_dataset_builder = _patched_load_dataset_builder
except Exception:
    pass

try:
    import inspect
    from torch.utils.data import DataLoader as _DataLoader
    from transformers import Trainer as _Trainer
    from transformers import TrainingArguments as _TrainingArguments

    _orig_dataloader_init = _DataLoader.__init__
    _dataloader_params = inspect.signature(_orig_dataloader_init)
    _orig_trainer_init = _Trainer.__init__
    _trainer_params = set(inspect.signature(_orig_trainer_init).parameters)
    _orig_training_arguments_init = _TrainingArguments.__init__
    _training_arguments_params = set(inspect.signature(_orig_training_arguments_init).parameters)

    def _patched_dataloader_init(self, *args, **kwargs):
        bound = _dataloader_params.bind_partial(self, *args, **kwargs)
        num_workers = bound.arguments.get("num_workers")
        if num_workers not in (None, 0):
            bound.arguments["num_workers"] = 0
        if bound.arguments.get("num_workers", 0) == 0:
            if "prefetch_factor" in bound.arguments:
                bound.arguments["prefetch_factor"] = None
            if "persistent_workers" in bound.arguments:
                bound.arguments["persistent_workers"] = False
        return _orig_dataloader_init(*bound.args, **bound.kwargs)

    def _patched_training_arguments_init(self, *args, **kwargs):
        if "overwrite_output_dir" not in _training_arguments_params:
            kwargs.pop("overwrite_output_dir", None)

        if "evaluation_strategy" in _training_arguments_params and "eval_strategy" in kwargs:
            kwargs.setdefault("evaluation_strategy", kwargs.pop("eval_strategy"))
        elif "eval_strategy" not in _training_arguments_params:
            kwargs.pop("eval_strategy", None)

        if "save_strategy" not in _training_arguments_params:
            kwargs.pop("save_strategy", None)
        if "logging_strategy" not in _training_arguments_params:
            kwargs.pop("logging_strategy", None)
        if "dataloader_num_workers" in _training_arguments_params:
            kwargs["dataloader_num_workers"] = 0

        return _orig_training_arguments_init(self, *args, **kwargs)

    def _patched_trainer_init(self, *args, **kwargs):
        if "tokenizer" in kwargs:
            tokenizer = kwargs.pop("tokenizer")
            kwargs.setdefault("processing_class", tokenizer)
        return _orig_trainer_init(self, *args, **kwargs)

    def _trainer_get_tokenizer(self):
        return getattr(self, "processing_class", None)

    def _trainer_set_tokenizer(self, value):
        setattr(self, "processing_class", value)

    _DataLoader.__init__ = _patched_dataloader_init
    _Trainer.__init__ = _patched_trainer_init
    _Trainer.tokenizer = property(_trainer_get_tokenizer, _trainer_set_tokenizer)
    _TrainingArguments.__init__ = _patched_training_arguments_init
except Exception:
    pass

try:
    import torch

    _orig_is_bf16_supported = torch.cuda.is_bf16_supported

    def _patched_is_bf16_supported(*args, **kwargs):
        try:
            return _orig_is_bf16_supported(*args, **kwargs)
        except RuntimeError as exc:
            if "Cannot re-initialize CUDA in forked subprocess" in str(exc):
                return False
            raise

    torch.cuda.is_bf16_supported = _patched_is_bf16_supported
except Exception:
    pass
PY

    export PYTHONPATH="$shim_dir${PYTHONPATH:+:$PYTHONPATH}"
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

has_model_weights() {
    local dir="$1"
    find "$dir" -maxdepth 1 \( -name 'model*.safetensors' -o -name 'pytorch_model*.bin' -o -name 'model.safetensors.index.json' -o -name 'pytorch_model.bin.index.json' \) -print -quit 2>/dev/null | grep -q .
}

materialize_final_model() {
    local source_dir="$1"
    local target_dir="$2"
    local strategy="$3"

    SOURCE_DIR="$source_dir" TARGET_DIR="$target_dir" MODEL_NAME="$MODEL_TO_TRAIN" STRATEGY="$strategy" python - <<'PY'
import os
import shutil
from pathlib import Path

from transformers import AutoModelForCausalLM, AutoTokenizer

source_dir = Path(os.environ["SOURCE_DIR"])
target_dir = Path(os.environ["TARGET_DIR"])
model_name = os.environ["MODEL_NAME"]
strategy = os.environ["STRATEGY"]

target_dir.parent.mkdir(parents=True, exist_ok=True)
if target_dir.exists():
    shutil.rmtree(target_dir)

source_has_files = source_dir.is_dir() and any(source_dir.iterdir())
source_has_adapter = source_has_files and (source_dir / "adapter_config.json").is_file()
source_has_weights = False
if source_has_files:
    for pattern in (
        "model*.safetensors",
        "pytorch_model*.bin",
        "model.safetensors.index.json",
        "pytorch_model.bin.index.json",
    ):
        if any(source_dir.glob(pattern)):
            source_has_weights = True
            break

if strategy == "merge_adapter":
    from peft import PeftModel

    base_model = AutoModelForCausalLM.from_pretrained(
        model_name,
        torch_dtype="auto",
        trust_remote_code=True,
    )
    merged_model = PeftModel.from_pretrained(base_model, source_dir).merge_and_unload()
    target_dir.mkdir(parents=True, exist_ok=True)
    merged_model.save_pretrained(target_dir, safe_serialization=True)
elif strategy == "copy_existing":
    shutil.copytree(source_dir, target_dir)
elif strategy == "base_model_fallback":
    fallback_model = AutoModelForCausalLM.from_pretrained(
        model_name,
        torch_dtype="auto",
        trust_remote_code=True,
    )
    target_dir.mkdir(parents=True, exist_ok=True)
    fallback_model.save_pretrained(target_dir, safe_serialization=True)
else:
    raise ValueError(f"Unknown final_model materialization strategy: {strategy}")

if source_has_files:
    try:
        tokenizer = AutoTokenizer.from_pretrained(source_dir, trust_remote_code=True)
    except Exception:
        tokenizer = AutoTokenizer.from_pretrained(model_name, trust_remote_code=True)
else:
    tokenizer = AutoTokenizer.from_pretrained(model_name, trust_remote_code=True)
tokenizer.save_pretrained(target_dir)

metadata = {
    "strategy": strategy,
    "source_dir": str(source_dir),
    "source_has_files": source_has_files,
    "source_has_adapter": source_has_adapter,
    "source_has_weights": source_has_weights,
    "model_name": model_name,
}
(target_dir / "posttrainbench_ml_master_artifact.json").write_text(
    __import__("json").dumps(metadata, indent=2),
    encoding="utf-8",
)
PY
}

ensure_ml_master_dependencies
install_ml_master_dataset_shim

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
ML_MASTER_CODE_BASE_URL="$(first_nonempty_defined "${ML_MASTER_CODE_BASE_URL:-}" "${OPENAI_API_BASE:-}" "${OPENAI_BASE_URL:-}" "https://api.openai.com/v1")"
ML_MASTER_CODE_API_KEY="$(first_nonempty_defined "${ML_MASTER_CODE_API_KEY:-}" "${OPENAI_API_KEY:-}" "${CODEX_API_KEY:-}")"
ML_MASTER_FEEDBACK_BASE_URL="$(first_nonempty_defined "${ML_MASTER_FEEDBACK_BASE_URL:-}" "$ML_MASTER_CODE_BASE_URL")"
ML_MASTER_FEEDBACK_API_KEY="$(first_nonempty_defined "${ML_MASTER_FEEDBACK_API_KEY:-}" "$ML_MASTER_CODE_API_KEY")"
ML_MASTER_CODE_BASE_URL="$(normalize_optional_env "$ML_MASTER_CODE_BASE_URL")"
ML_MASTER_CODE_API_KEY="$(normalize_optional_env "$ML_MASTER_CODE_API_KEY")"
ML_MASTER_FEEDBACK_BASE_URL="$(normalize_optional_env "$ML_MASTER_FEEDBACK_BASE_URL")"
ML_MASTER_FEEDBACK_API_KEY="$(normalize_optional_env "$ML_MASTER_FEEDBACK_API_KEY")"

if [ -z "$ML_MASTER_CODE_BASE_URL" ]; then
    ML_MASTER_CODE_BASE_URL="https://api.openai.com/v1"
fi
if [ -z "$ML_MASTER_FEEDBACK_BASE_URL" ]; then
    ML_MASTER_FEEDBACK_BASE_URL="$ML_MASTER_CODE_BASE_URL"
fi

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
    echo "- The final artifact must be a full Hugging Face model directory that AutoTokenizer, AutoModelForCausalLM, and vLLM can load from ./submission/final_model."
    echo "- If you use LoRA, QLoRA, or any adapter method, merge the adapter into the base model and save merged weights into ./submission/final_model. Do not leave an adapter-only directory."
    echo "- Avoid multiprocessing and self-reexec patterns. Do not use torchrun, accelerate launch, deepspeed, os.fork, subprocess-based self-reexecution, or DataLoader workers."
    echo "- Keep every DataLoader and Trainer dataloader at num_workers=0."
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
TARGET_OUTPUT_DIR="/home/ben/task/final_model"
MATERIALIZE_STRATEGY=""

if [ -d "$BEST_OUTPUT_DIR" ] && [ "$(find "$BEST_OUTPUT_DIR" -mindepth 1 -print -quit 2>/dev/null | wc -l)" -gt 0 ]; then
    if [ -f "$BEST_OUTPUT_DIR/adapter_config.json" ] && ! has_model_weights "$BEST_OUTPUT_DIR"; then
        MATERIALIZE_STRATEGY="merge_adapter"
    else
        MATERIALIZE_STRATEGY="copy_existing"
    fi
else
    echo "WARNING: ML-Master did not produce best_submission/final_model; falling back to the base model so benchmark evaluation can proceed." >&2
    MATERIALIZE_STRATEGY="base_model_fallback"
fi

echo "ML-Master final_model materialization strategy: ${MATERIALIZE_STRATEGY}"
materialize_final_model "$BEST_OUTPUT_DIR" "$TARGET_OUTPUT_DIR" "$MATERIALIZE_STRATEGY"

if [ ! -d "$TARGET_OUTPUT_DIR" ] || [ "$(find "$TARGET_OUTPUT_DIR" -mindepth 1 -print -quit 2>/dev/null | wc -l)" -eq 0 ]; then
    echo "ERROR: failed to materialize /home/ben/task/final_model" >&2
    exit 1
fi
