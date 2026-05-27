#!/bin/bash
container="${1}"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${REPO_ROOT}"
source src/commit_utils/set_env_vars.sh

mkdir -p "${POST_TRAIN_BENCH_CONTAINERS_DIR}" "${APPTAINER_CACHEDIR}" "${APPTAINER_TMPDIR}"
export APPTAINER_BIND=""

apptainer build "${POST_TRAIN_BENCH_CONTAINERS_DIR}/${container}.sif" "containers/${container}.def"
