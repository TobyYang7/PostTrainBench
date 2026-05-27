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

unset ANTHROPIC_API_KEY
unset GEMINI_API_KEY

GEPA_AGENT_DIR="${GEPA_AGENT_DIR:-/home/ben/gepa-agent}"
GEPA_REPO_DIR="${GEPA_REPO_DIR:-/home/ben/gepa}"
GEPA_VENV_DIR="${GEPA_VENV_DIR:-/opt/posttrain_gepa_venv}"
GEPA_INSTALL_SOURCE="${GEPA_INSTALL_SOURCE:-git+https://github.com/gepa-ai/gepa.git}"

ensure_gepa_env() {
    if [ ! -x "${GEPA_VENV_DIR}/bin/python" ]; then
        uv venv --seed "${GEPA_VENV_DIR}"
        "${GEPA_VENV_DIR}/bin/python" -m pip install --upgrade pip
    fi

    if "${GEPA_VENV_DIR}/bin/python" - <<'PY' >/dev/null 2>&1
import importlib.util
import sys

modules = [
    "gepa",
    "litellm",
    "cloudpickle",
    "tqdm",
]

missing = [name for name in modules if importlib.util.find_spec(name) is None]
sys.exit(1 if missing else 0)
PY
    then
        return 0
    fi

    if [ -f "${GEPA_REPO_DIR}/pyproject.toml" ]; then
        "${GEPA_VENV_DIR}/bin/python" -m pip install -e "${GEPA_REPO_DIR}"
    else
        "${GEPA_VENV_DIR}/bin/python" -m pip install "${GEPA_INSTALL_SOURCE}"
    fi

    "${GEPA_VENV_DIR}/bin/python" -m pip install \
        "litellm>=1.83.0" \
        "tqdm>=4.66.1" \
        "cloudpickle>=3.0.0"
}

if [ ! -x "${GEPA_AGENT_DIR}/gepa_driver.py" ]; then
    chmod 0755 "${GEPA_AGENT_DIR}/gepa_driver.py" 2>/dev/null || true
fi

if [ ! -f "${GEPA_AGENT_DIR}/gepa_driver.py" ]; then
    echo "ERROR: expected GEPA driver at ${GEPA_AGENT_DIR}/gepa_driver.py" >&2
    exit 1
fi

if ! command -v codex >/dev/null 2>&1; then
    echo "ERROR: codex CLI is required for the GEPA agent but was not found in PATH." >&2
    exit 1
fi

mkdir -p /home/ben/.codex
if [ ! -f /home/ben/.codex/auth.json ]; then
    echo "ERROR: GEPA requires local Codex auth at /home/ben/.codex/auth.json for the inner executor." >&2
    exit 1
fi
if ! grep -q "forced_login_method" /home/ben/.codex/config.toml 2>/dev/null; then
    printf '\nforced_login_method = "chatgpt"\n' >> /home/ben/.codex/config.toml
fi

if [ -z "${OPENAI_API_KEY:-}" ]; then
    echo "ERROR: GEPA requires OPENAI_API_KEY or CODEX_API_KEY to drive the inner Codex executor." >&2
    exit 1
fi

ensure_gepa_env

exec "${GEPA_VENV_DIR}/bin/python" "${GEPA_AGENT_DIR}/gepa_driver.py"
