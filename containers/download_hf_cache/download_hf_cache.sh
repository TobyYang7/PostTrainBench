#!/bin/bash
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

cd "${REPO_ROOT}"
source src/commit_utils/set_env_vars.sh

container_path="${POST_TRAIN_BENCH_CONTAINERS_DIR}/${POST_TRAIN_BENCH_CONTAINER_NAME}.sif"

if [ ! -f "${container_path}" ]; then
    echo "ERROR: container not found: ${container_path}" >&2
    exit 1
fi

mkdir -p "${HF_HOME}"

apptainer run \
    --nv \
    --bind "${HF_HOME}:${HF_HOME}" \
    --env HF_HOME="${HF_HOME}" \
    "${container_path}" \
    containers/download_hf_cache/download_resources.py "$@"

echo "Downloads complete! Cache at: ${HF_HOME}"
