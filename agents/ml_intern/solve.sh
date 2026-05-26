#!/bin/bash
set -euo pipefail

ENV_FILE="/home/ben/.env"
if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck source=/dev/null
    source "$ENV_FILE"
    set +a
else
    echo "ERROR: expected .env at ${ENV_FILE}" >&2
    exit 1
fi

if [ -z "${HF_TOKEN:-}" ] && [ -n "${HUGGING_FACE_HUB_TOKEN:-}" ]; then
    export HF_TOKEN="$HUGGING_FACE_HUB_TOKEN"
fi
if [ -z "${HF_TOKEN:-}" ] && [ -n "${BEN_HF_TOKEN:-}" ]; then
    export HF_TOKEN="$BEN_HF_TOKEN"
fi
if [ -z "${HF_TOKEN:-}" ] && [ -n "${HARDIK_HF_TOKEN:-}" ]; then
    export HF_TOKEN="$HARDIK_HF_TOKEN"
fi
if [ -z "${OPENAI_API_BASE:-}" ] && [ -n "${OPENAI_BASE_URL:-}" ]; then
    export OPENAI_API_BASE="$OPENAI_BASE_URL"
fi

ML_INTERN_REPO_DIR="${ML_INTERN_REPO_DIR:-/home/ben/ml-intern}"
if [ ! -d "$ML_INTERN_REPO_DIR/agent" ]; then
    echo "ERROR: expected ml-intern checkout at ${ML_INTERN_REPO_DIR}" >&2
    exit 1
fi

if [ -z "${ML_INTERN_MODEL:-}" ] || [ "${ML_INTERN_MODEL:-}" = "UNDEFINED" ]; then
    ML_INTERN_MODEL="${OPENAI_MODEL_NAME:-}"
fi
if [ -z "$ML_INTERN_MODEL" ]; then
    ML_INTERN_MODEL="$AGENT_CONFIG"
fi
if [[ "$ML_INTERN_MODEL" != */* ]]; then
    ML_INTERN_MODEL="openai/${ML_INTERN_MODEL}"
fi
if [ -z "${ML_INTERN_MAX_ITERATIONS:-}" ] || [ "${ML_INTERN_MAX_ITERATIONS:-}" = "UNDEFINED" ]; then
    ML_INTERN_MAX_ITERATIONS=300
fi

cat > "$ML_INTERN_REPO_DIR/configs/cli_agent_config.json" <<JSON
{
  "model_name": "${ML_INTERN_MODEL}",
  "save_sessions": true,
  "share_traces": false,
  "personal_trace_repo_template": "{hf_user}/ml-intern-sessions",
  "yolo_mode": true,
  "confirm_cpu_jobs": false,
  "auto_file_upload": true,
  "tool_runtime": "local",
  "messaging": {
    "enabled": false,
    "auto_event_types": ["approval_required", "error", "turn_complete"],
    "destinations": {}
  },
  "mcpServers": {}
}
JSON

ML_INTERN_PROMPT="/tmp/ml_intern_posttrain_prompt.md"
{
    echo "You are running inside PostTrainBench."
    echo "Use the original ml-intern agent loop and tools."
    echo "The benchmark output contract is mandatory: create a usable ./final_model directory before finishing."
    echo
    echo "===== PostTrainBench task prompt ====="
    printf '%s\n' "$PROMPT"
} > "$ML_INTERN_PROMPT"

cd "$ML_INTERN_REPO_DIR"
uv run --project "$ML_INTERN_REPO_DIR" \
    python -m agent.main \
    --model "$ML_INTERN_MODEL" \
    --no-stream \
    --max-iterations "$ML_INTERN_MAX_ITERATIONS" \
    "$(cat "$ML_INTERN_PROMPT")"
