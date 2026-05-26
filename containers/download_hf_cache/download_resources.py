"""Download every cached Hugging Face model and dataset if missing."""

import argparse
import json
import os
import re
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from threading import Lock
from typing import List, Tuple

from datasets import load_dataset
from huggingface_hub import snapshot_download

SCRIPT_DIR = Path(__file__).parent
RESOURCES_FILE = SCRIPT_DIR / 'resources.json'

CACHE_ROOT = Path(os.environ.get('HF_HOME') or Path.home() / '.cache' / 'huggingface')
HUB_ROOT = CACHE_ROOT / 'hub'
MODEL_CACHE_DIRS = tuple(dict.fromkeys([
    HUB_ROOT,
    CACHE_ROOT,
    Path(os.environ.get('TRANSFORMERS_CACHE') or (CACHE_ROOT / 'models'))
]))
DATASET_CACHE_DIR = Path(os.environ.get('HF_DATASETS_CACHE') or (CACHE_ROOT / 'datasets'))
SNAPSHOT_ONLY_DATASET_PREFIXES = ('camel-ai/',)

# Thread-safe printing
_print_lock = Lock()


def _safe_print(msg: str) -> None:
    """Thread-safe print."""
    with _print_lock:
        print(msg)


def _repo_folder(prefix: str, repo_id: str) -> str:
    """Build the cache folder name for a HuggingFace repo."""
    return f"{prefix}--{repo_id.replace('/', '--')}"


def _to_cache_key(dataset_name: str) -> str:
    """Convert dataset name to the cache key format used by datasets library."""
    if '/' not in dataset_name:
        return dataset_name

    owner, name = dataset_name.split('/', 1)
    # Convert CamelCase to snake_case and lowercase
    name = re.sub(r'([a-z])([A-Z])', r'\1_\2', name).lower()
    owner = re.sub(r'([a-z])([A-Z])', r'\1_\2', owner)
    return f"{owner}___{name}"


def _any_exists(paths: List[Path]) -> bool:
    """Check if any of the given paths exist."""
    return any(p and p.exists() for p in paths)


def load_resources() -> dict:
    """Load models and datasets from resources.json."""
    with open(RESOURCES_FILE) as f:
        return json.load(f)


def _download_model(model_name: str, index: int, total: int, dry_run: bool) -> Tuple[str, bool]:
    """Download a single model. Returns (model_name, success)."""
    repo_folder = _repo_folder('models', model_name)
    candidates = [base / repo_folder for base in MODEL_CACHE_DIRS]

    if dry_run:
        action = "verify cached model" if _any_exists(candidates) else "download model"
        _safe_print(f"[{index}/{total}] Would {action}: {model_name}")
        return model_name, True

    action = "Verifying cached model" if _any_exists(candidates) else "Downloading model"
    _safe_print(f"[{index}/{total}] {action}: {model_name}...")
    try:
        snapshot_download(model_name)
    except Exception as exc:
        _safe_print(
            f"[{index}/{total}] WARNING: could not download model {model_name}: "
            f"{type(exc).__name__}: {exc}"
        )
        return model_name, False
    _safe_print(f"[{index}/{total}] Model {model_name} downloaded successfully")
    return model_name, True


def _download_dataset(entry: dict, index: int, total: int, dry_run: bool) -> Tuple[str, bool]:
    """Download a single dataset. Returns (dataset_name, success)."""
    dataset_name = entry['dataset']
    configs = entry.get('configs', [entry.get('config', 'default')])
    splits = entry.get('splits', [])

    # Check if already cached
    repo_folder = _repo_folder('datasets', dataset_name)
    cache_key = _to_cache_key(dataset_name)
    cached = _any_exists([
        HUB_ROOT / repo_folder,
        CACHE_ROOT / repo_folder,
        DATASET_CACHE_DIR / cache_key
    ])

    if cached:
        _safe_print(f"[{index}/{total}] Skipping dataset: {dataset_name} (already cached)")
        return dataset_name, True

    snapshot_only = dataset_name.startswith(SNAPSHOT_ONLY_DATASET_PREFIXES)
    if snapshot_only:
        if dry_run:
            _safe_print(f"[{index}/{total}] Would snapshot dataset repo: {dataset_name}")
            return dataset_name, True

        _safe_print(f"[{index}/{total}] Snapshotting dataset repo: {dataset_name}...")
        try:
            snapshot_download(dataset_name, repo_type='dataset')
        except Exception as snapshot_exc:
            _safe_print(
                f"[{index}/{total}] WARNING: could not snapshot dataset {dataset_name}: "
                f"{type(snapshot_exc).__name__}: {snapshot_exc}"
            )
            return dataset_name, False
        _safe_print(f"[{index}/{total}] Dataset {dataset_name} snapshotted successfully")
        return dataset_name, True

    try:
        # Download each config
        for config in configs:
            label = f"{dataset_name} ({config})" if config else dataset_name

            if dry_run:
                if splits:
                    _safe_print(f"[{index}/{total}] Would download dataset: {label} [splits={splits}]")
                else:
                    _safe_print(f"[{index}/{total}] Would download dataset: {label}")
                continue

            if splits:
                for split in splits:
                    _safe_print(f"[{index}/{total}] Downloading dataset: {label} [split={split}]...")
                    kwargs = {'split': split}
                    if config and config != 'default':
                        kwargs['name'] = config
                    load_dataset(dataset_name, **kwargs)
            else:
                _safe_print(f"[{index}/{total}] Downloading dataset: {label}...")
                kwargs = {}
                if config and config != 'default':
                    kwargs['name'] = config
                load_dataset(dataset_name, **kwargs)
    except Exception as exc:
        if dry_run:
            raise
        _safe_print(
            f"[{index}/{total}] load_dataset failed for {dataset_name}: "
            f"{type(exc).__name__}: {exc}. Falling back to dataset snapshot..."
        )
        try:
            snapshot_download(dataset_name, repo_type='dataset')
        except Exception as snapshot_exc:
            _safe_print(
                f"[{index}/{total}] WARNING: could not snapshot dataset {dataset_name}: "
                f"{type(snapshot_exc).__name__}: {snapshot_exc}"
            )
            return dataset_name, False
        _safe_print(f"[{index}/{total}] Dataset {dataset_name} snapshotted successfully")
        return dataset_name, True

    if not dry_run:
        _safe_print(f"[{index}/{total}] Dataset {dataset_name} downloaded successfully")
    return dataset_name, True


def download_models(models: List[str], dry_run: bool = False, workers: int = 1) -> None:
    """Download all models that aren't already cached."""
    total = len(models)
    failures = []
    with ThreadPoolExecutor(max_workers=workers) as executor:
        futures = {
            executor.submit(_download_model, model, i, total, dry_run): model
            for i, model in enumerate(models, 1)
        }
        for future in as_completed(futures):
            submitted_model_name = futures[future]
            try:
                model_name, success = future.result()
            except Exception as exc:
                _safe_print(
                    f"WARNING: unexpected failure for model {submitted_model_name}: "
                    f"{type(exc).__name__}: {exc}"
                )
                failures.append(submitted_model_name)
                continue
            if not success:
                failures.append(model_name)

    if failures:
        print("\nModels skipped or failed:")
        for model_name in failures:
            print(f"- {model_name}")


def download_datasets(datasets: List[dict], dry_run: bool = False, workers: int = 4) -> None:
    """Download all datasets that aren't already cached."""
    total = len(datasets)
    failures = []
    with ThreadPoolExecutor(max_workers=workers) as executor:
        futures = {
            executor.submit(_download_dataset, entry, i, total, dry_run): entry['dataset']
            for i, entry in enumerate(datasets, 1)
        }
        for future in as_completed(futures):
            submitted_dataset_name = futures[future]
            try:
                dataset_name, success = future.result()
            except Exception as exc:
                _safe_print(
                    f"WARNING: unexpected failure for dataset {submitted_dataset_name}: "
                    f"{type(exc).__name__}: {exc}"
                )
                failures.append(submitted_dataset_name)
                continue
            if not success:
                failures.append(dataset_name)

    if failures:
        print("\nDatasets skipped or failed:")
        for dataset_name in failures:
            print(f"- {dataset_name}")


def _shard(items: List, shard_index: int, num_shards: int) -> List:
    """Return one deterministic shard of a list."""
    return [item for i, item in enumerate(items) if i % num_shards == shard_index]


def main(
    dry_run: bool = False,
    workers: int = 4,
    model_workers: int = 1,
    only: str = 'all',
    shard_index: int = 0,
    num_shards: int = 1,
) -> None:
    """Main entry point."""
    resources = load_resources()

    if not 0 <= shard_index < num_shards:
        raise ValueError(f"shard_index must satisfy 0 <= shard_index < num_shards ({num_shards})")

    models = resources['models'] if only in ('all', 'models') else []
    datasets = resources['datasets'] if only in ('all', 'datasets') else []
    models = _shard(models, shard_index, num_shards)
    datasets = _shard(datasets, shard_index, num_shards)

    print(f"Mode: {only}")
    print(f"Shard: {shard_index + 1}/{num_shards}")
    print(f"Models: {len(models)}")
    print(f"Datasets: {len(datasets)}")
    print(f"Dataset workers: {workers}")
    print(f"Model workers: {model_workers}")
    if dry_run:
        print("DRY RUN - no downloads will be performed")
    print()

    if models:
        download_models(models, dry_run=dry_run, workers=model_workers)
        print()
    if datasets:
        download_datasets(datasets, dry_run=dry_run, workers=workers)

    print(f"\nCache location: {CACHE_ROOT}")


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Download HuggingFace models and datasets')
    parser.add_argument('--dry-run', action='store_true',
                        help='Show what would be downloaded without actually downloading')
    parser.add_argument('--workers', type=int, default=4,
                        help='Number of parallel dataset download workers (default: 4)')
    parser.add_argument('--model-workers', type=int, default=1,
                        help='Number of parallel model download workers (default: 1)')
    parser.add_argument('--only', choices=['all', 'models', 'datasets'], default='all',
                        help='Download only models, only datasets, or both (default: all)')
    parser.add_argument('--shard-index', type=int, default=0,
                        help='Zero-based shard index to download (default: 0)')
    parser.add_argument('--num-shards', type=int, default=1,
                        help='Total number of shards (default: 1)')
    args = parser.parse_args()

    main(
        dry_run=args.dry_run,
        workers=args.workers,
        model_workers=args.model_workers,
        only=args.only,
        shard_index=args.shard_index,
        num_shards=args.num_shards,
    )
