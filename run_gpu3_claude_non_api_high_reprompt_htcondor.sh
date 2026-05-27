#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST_OAUTH_TOKEN_PATH="${HOME}/.claude/oauth_token"
AGENT_OAUTH_TOKEN_PATH="$REPO_ROOT/agents/claude_non_api_high_reprompt/oauth_token"

if [ ! -f "$HOST_OAUTH_TOKEN_PATH" ] && [ ! -f "$AGENT_OAUTH_TOKEN_PATH" ]; then
    echo "ERROR: Missing Claude OAuth token." >&2
    echo "  Run: claude setup-token, then save the sk-ant-oat01-... value to $HOST_OAUTH_TOKEN_PATH" >&2
    echo "  (Or drop a per-agent token at $AGENT_OAUTH_TOKEN_PATH)" >&2
    exit 1
fi

POST_TRAIN_BENCH_AGENT=claude_non_api_high_reprompt \
POST_TRAIN_BENCH_AGENT_CONFIG="${POST_TRAIN_BENCH_AGENT_CONFIG:-claude-opus-4-6}" \
CUDA_DEVICE_IDX=2 \
POST_TRAIN_BENCH_REQUIRED_GPU_NAME=H20 \
POST_TRAIN_BENCH_EXPERIMENT_NAME=_prompt1_gpu3_claude_non_api_high_reprompt_htcondor \
POST_TRAIN_BENCH_PROMPT=prompt1 \
POST_TRAIN_BENCH_JUDGE_PROMPT=prompt \
POST_TRAIN_BENCH_JUDGE_MODEL=gpt-5.5 \
CONDOR_GPU_REQUIREMENTS=true \
bash "$REPO_ROOT/scripts/submit_claude_personal_htcondor.sh"
