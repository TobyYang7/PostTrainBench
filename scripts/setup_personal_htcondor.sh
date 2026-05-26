#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONDOR_DIR="${POST_TRAIN_BENCH_PERSONAL_CONDOR_DIR:-$REPO_ROOT/.htcondor-local/condor}"
SRC_DIR="$REPO_ROOT/.htcondor-local/src"
TARBALL="$SRC_DIR/condor.tar.gz"
TARBALL_URL="${HTCONDOR_TARBALL_URL:-https://htcss-downloads.chtc.wisc.edu/tarball/25.0/current/condor-x86_64_AlmaLinux8-stripped.tar.gz}"

mkdir -p "$SRC_DIR"

if [ ! -f "$CONDOR_DIR/condor.sh" ]; then
    if [ ! -f "$TARBALL" ]; then
        echo "Downloading HTCondor tarball..."
        curl -fL "$TARBALL_URL" -o "$TARBALL"
    fi

    extract_dir="$SRC_DIR/extract.$$"
    mkdir -p "$extract_dir"
    trap 'rm -rf "$extract_dir"' EXIT
    tar -xzf "$TARBALL" -C "$extract_dir"

    unpacked_dir="$(find "$extract_dir" -maxdepth 1 -type d -name 'condor-*stripped' -print -quit)"
    if [ -z "$unpacked_dir" ]; then
        echo "ERROR: could not find unpacked HTCondor directory in $extract_dir" >&2
        exit 1
    fi

    mv "$unpacked_dir" "$CONDOR_DIR"
    (
        cd "$CONDOR_DIR"
        ./bin/make-personal-from-tarball
    )
fi

mkdir -p "$CONDOR_DIR/local/config.d"
cat > "$CONDOR_DIR/local/config.d/10-posttrainbench-local-gpu.conf" <<'EOF'
# Local single-node PostTrainBench simulation pool.
DAEMON_LIST = MASTER, COLLECTOR, NEGOTIATOR, SCHEDD, STARTD

# Use one partitionable slot so jobs requesting 16 CPUs, 128 GiB RAM, and GPUs
# can match on a single large GPU node.
NUM_SLOTS = 1
NUM_SLOTS_TYPE_1 = 1
SLOT_TYPE_1 = cpus=100%, mem=100%, disk=100%, gpus=100%
SLOT_TYPE_1_PARTITIONABLE = TRUE

# Advertise NVIDIA GPUs and set CUDA_VISIBLE_DEVICES for claimed GPUs.
use feature : GPUs
GPU_DISCOVERY_EXTRA = -properties
ENVIRONMENT_FOR_AssignedGPUs = CUDA_VISIBLE_DEVICES
ENVIRONMENT_VALUE_FOR_UnAssignedGPUs = none

# This pool is for an interactive single-user GPU node.
START = TRUE
SUSPEND = FALSE
PREEMPT = FALSE
KILL = FALSE
WANT_SUSPEND = FALSE
WANT_VACATE = FALSE
EOF

echo "Personal HTCondor is configured at $CONDOR_DIR"
echo "Run: source $CONDOR_DIR/condor.sh"
