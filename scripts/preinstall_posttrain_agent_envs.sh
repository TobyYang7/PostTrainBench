#!/usr/bin/env bash
set -euo pipefail
unset VIRTUAL_ENV PYTHONHOME

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

source src/commit_utils/set_env_vars.sh

CONTAINER_PATH="${POST_TRAIN_BENCH_CONTAINERS_DIR}/${POST_TRAIN_BENCH_CONTAINER_NAME}.sif"
if [ ! -f "$CONTAINER_PATH" ]; then
    echo "ERROR: container not found: $CONTAINER_PATH" >&2
    exit 1
fi

mkdir -p \
    "$POST_TRAIN_BENCH_RDAGENT_VENV_DIR" \
    "$POST_TRAIN_BENCH_RDAGENT_BENCHMARK_VENV_DIR" \
    "$POST_TRAIN_BENCH_ML_MASTER_VENDOR_DIR" \
    "$POST_TRAIN_BENCH_ML_MASTER_SHIM_DIR" \
    "$POST_TRAIN_BENCH_WORKSPACE_ROOT/preinstall-home" \
    "$POST_TRAIN_BENCH_WORKSPACE_ROOT/preinstall-tmp"

apptainer exec \
    -c \
    --bind "$REPO_ROOT:/repo" \
    --bind "$POST_TRAIN_BENCH_RDAGENT_VENV_DIR:/opt/posttrain_rdagent_venv" \
    --bind "$POST_TRAIN_BENCH_RDAGENT_BENCHMARK_VENV_DIR:/opt/posttrain_rdagent_benchmark_venv" \
    --bind "$POST_TRAIN_BENCH_ML_MASTER_VENDOR_DIR:/opt/posttrain_mlmaster_vendor" \
    --bind "$POST_TRAIN_BENCH_ML_MASTER_SHIM_DIR:/opt/posttrain_mlmaster_shims" \
    --bind "$POST_TRAIN_BENCH_WORKSPACE_ROOT/preinstall-tmp:/opt/posttrain_preinstall_tmp" \
    --home "$POST_TRAIN_BENCH_WORKSPACE_ROOT/preinstall-home:/home/ben" \
    --env TMPDIR="/opt/posttrain_preinstall_tmp" \
    --env TEMP="/opt/posttrain_preinstall_tmp" \
    --env TMP="/opt/posttrain_preinstall_tmp" \
    "$CONTAINER_PATH" \
    bash -lc '
set -euo pipefail
unset VIRTUAL_ENV PYTHONHOME
export TMPDIR=/opt/posttrain_preinstall_tmp
export TEMP=/opt/posttrain_preinstall_tmp
export TMP=/opt/posttrain_preinstall_tmp

rdagent_core_ready() {
    [ -x /opt/posttrain_rdagent_venv/bin/python ] || return 1
    /opt/posttrain_rdagent_venv/bin/python - <<'"'"'PY'"'"' >/dev/null 2>&1
import importlib.util
import sys
sys.exit(0 if importlib.util.find_spec("rdagent") else 1)
PY
}

rdagent_bench_ready() {
    [ -x /opt/posttrain_rdagent_benchmark_venv/bin/python ] || return 1
    /opt/posttrain_rdagent_benchmark_venv/bin/python - <<'"'"'PY'"'"' >/dev/null 2>&1
import importlib.util
import sys
sys.exit(0 if importlib.util.find_spec("opencompass") else 1)
PY
}

mlmaster_vendor_ready() {
    PYTHONPATH=/opt/posttrain_mlmaster_vendor python - <<'"'"'PY'"'"' >/dev/null 2>&1
import importlib.util
import sys
mods = ["backoff","coolname","dataclasses_json","funcy","genson","humanize","jsonschema","omegaconf","requests","rich","shutup"]
missing = [m for m in mods if importlib.util.find_spec(m) is None]
sys.exit(1 if missing else 0)
PY
}

if ! rdagent_core_ready; then
    cd /repo/third_party/rd-agent
    if [ -d /opt/posttrain_rdagent_venv ]; then
        find /opt/posttrain_rdagent_venv -mindepth 1 -maxdepth 1 -exec rm -rf {} +
        uv venv --seed /opt/posttrain_rdagent_venv
    else
        uv venv --seed /opt/posttrain_rdagent_venv
    fi
    /opt/posttrain_rdagent_venv/bin/python -m pip install --upgrade pip
    SETUPTOOLS_SCM_PRETEND_VERSION=0.0.0 /opt/posttrain_rdagent_venv/bin/python -m pip install -e .
    /opt/posttrain_rdagent_venv/bin/python -m pip install pyyaml "llamafactory==0.9.3"
fi

if ! rdagent_bench_ready; then
    if [ -d /opt/posttrain_rdagent_benchmark_venv ]; then
        find /opt/posttrain_rdagent_benchmark_venv -mindepth 1 -maxdepth 1 -exec rm -rf {} +
        uv venv --seed /opt/posttrain_rdagent_benchmark_venv
    else
        uv venv --seed /opt/posttrain_rdagent_benchmark_venv
    fi
    /opt/posttrain_rdagent_benchmark_venv/bin/python -m pip install --upgrade pip
    /opt/posttrain_rdagent_benchmark_venv/bin/python -m pip install "opencompass @ git+https://github.com/Jensen246/opencompass.git"
fi

if ! mlmaster_vendor_ready; then
    uv pip install --quiet --target /opt/posttrain_mlmaster_vendor -r /repo/third_party/ML-Master/requirements-posttrainbench.txt
fi

cat > /opt/posttrain_mlmaster_shims/sitecustomize.py <<'"'"'PY'"'"'
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

echo "Preinstall complete."
echo "  RD-Agent core venv: /opt/posttrain_rdagent_venv"
echo "  RD-Agent benchmark venv: /opt/posttrain_rdagent_benchmark_venv"
echo "  ML-Master vendor dir: /opt/posttrain_mlmaster_vendor"
echo "  ML-Master shim dir: /opt/posttrain_mlmaster_shims"
'
