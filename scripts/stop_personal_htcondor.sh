#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONDOR_DIR="${POST_TRAIN_BENCH_PERSONAL_CONDOR_DIR:-$REPO_ROOT/.htcondor-local/condor}"

if [ ! -f "$CONDOR_DIR/condor.sh" ]; then
    echo "Personal HTCondor is not configured at $CONDOR_DIR"
    exit 0
fi

# shellcheck source=/dev/null
source "$CONDOR_DIR/condor.sh"
condor_off -master
