#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONDOR_DIR="${POST_TRAIN_BENCH_PERSONAL_CONDOR_DIR:-$REPO_ROOT/.htcondor-local/condor}"

bash "$REPO_ROOT/scripts/start_personal_htcondor.sh"

# shellcheck source=/dev/null
source "$CONDOR_DIR/condor.sh"

export POST_TRAIN_BENCH_JOB_SCHEDULER=htcondor
export POST_TRAIN_BENCH_RESULTS_DIR="${POST_TRAIN_BENCH_RESULTS_DIR:-$REPO_ROOT/results}"
export CONDOR_LOG_DIR="${CONDOR_LOG_DIR:-$REPO_ROOT/.htcondor-local/logs}"
export CONDOR_GPU_REQUIREMENTS="${CONDOR_GPU_REQUIREMENTS:-true}"
export POST_TRAIN_BENCH_COPY_HOST_CODEX_AUTH="${POST_TRAIN_BENCH_COPY_HOST_CODEX_AUTH:-1}"
export POST_TRAIN_BENCH_INSTALL_HOST_CODEX_BINARY="${POST_TRAIN_BENCH_INSTALL_HOST_CODEX_BINARY:-1}"
export POST_TRAIN_BENCH_COPY_HOST_CLAUDE_OAUTH="${POST_TRAIN_BENCH_COPY_HOST_CLAUDE_OAUTH:-0}"
export POST_TRAIN_BENCH_INSTALL_HOST_CLAUDE_BINARY="${POST_TRAIN_BENCH_INSTALL_HOST_CLAUDE_BINARY:-0}"
if [ -z "${POST_TRAIN_BENCH_CLAUDE_BIN:-}" ] && command -v claude >/dev/null 2>&1; then
    POST_TRAIN_BENCH_CLAUDE_BIN="$(readlink -f "$(command -v claude)")"
fi
export POST_TRAIN_BENCH_CLAUDE_BIN="${POST_TRAIN_BENCH_CLAUDE_BIN:-}"
if [ -z "${POST_TRAIN_BENCH_CODEX_BIN:-}" ] && command -v codex >/dev/null 2>&1; then
    POST_TRAIN_BENCH_CODEX_BIN="$(readlink -f "$(command -v codex)")"
fi
export POST_TRAIN_BENCH_CODEX_BIN="${POST_TRAIN_BENCH_CODEX_BIN:-}"

if [ -z "${POST_TRAIN_BENCH_REQUIRED_GPU_NAME:-}" ] && command -v nvidia-smi >/dev/null 2>&1; then
    POST_TRAIN_BENCH_REQUIRED_GPU_NAME="$(nvidia-smi --query-gpu=name --format=csv,noheader | head -n 1 || true)"
fi
export POST_TRAIN_BENCH_REQUIRED_GPU_NAME="${POST_TRAIN_BENCH_REQUIRED_GPU_NAME:-H20}"

mkdir -p "$POST_TRAIN_BENCH_RESULTS_DIR" "$CONDOR_LOG_DIR"
chmod 1777 "$POST_TRAIN_BENCH_RESULTS_DIR" "$CONDOR_LOG_DIR"

maybe_preinstall_agent_envs() {
    if [ "${POST_TRAIN_BENCH_AUTO_PREINSTALL:-1}" != "1" ]; then
        return 0
    fi
    if ! command -v apptainer >/dev/null 2>&1; then
        return 0
    fi
    case "${POST_TRAIN_BENCH_AGENT:-}" in
        ml_master|rdagent)
            echo "Ensuring preinstalled agent environments are ready for ${POST_TRAIN_BENCH_AGENT}"
            (
                cd "$REPO_ROOT"
                bash scripts/preinstall_posttrain_agent_envs.sh
            )
            ;;
    esac
}

maybe_preinstall_agent_envs

(
    cd "$REPO_ROOT"
    bash src/commit_utils/commit_codex.sh
)
