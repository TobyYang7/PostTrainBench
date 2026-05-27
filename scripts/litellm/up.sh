#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env"
COMPOSE_FILE="${REPO_ROOT}/docker/litellm/compose.yaml"
RUNTIME_DIR="${REPO_ROOT}/.runtime/litellm"
VENV_DIR="${RUNTIME_DIR}/venv"
LOG_FILE="${RUNTIME_DIR}/proxy.log"
PID_FILE="${RUNTIME_DIR}/proxy.pid"
LITELLM_SPEC="litellm[proxy]==1.86.0"

if [ ! -f "${ENV_FILE}" ]; then
    echo "ERROR: missing ${ENV_FILE}" >&2
    exit 1
fi

set -a
# shellcheck source=/dev/null
source "${ENV_FILE}"
set +a

mkdir -p "${RUNTIME_DIR}"

docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" up -d --remove-orphans postgres

for _ in $(seq 1 60); do
    if docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" exec -T postgres \
        pg_isready -U litellm -d litellm >/dev/null 2>&1; then
        break
    fi
    sleep 2
done

if [ ! -x "${VENV_DIR}/bin/litellm" ]; then
    python3 -m venv "${VENV_DIR}"
    "${VENV_DIR}/bin/pip" install --upgrade pip
    "${VENV_DIR}/bin/pip" install "${LITELLM_SPEC}"
fi

if [ -f "${PID_FILE}" ]; then
    OLD_PID="$(cat "${PID_FILE}")"
    if [ -n "${OLD_PID}" ] && kill -0 "${OLD_PID}" >/dev/null 2>&1; then
        kill "${OLD_PID}" >/dev/null 2>&1 || true
        sleep 1
    fi
    rm -f "${PID_FILE}"
fi

nohup "${VENV_DIR}/bin/litellm" \
    --config "${REPO_ROOT}/docker/litellm/config.yaml" \
    --host 127.0.0.1 \
    --port 4000 \
    >"${LOG_FILE}" 2>&1 < /dev/null &

echo $! > "${PID_FILE}"

for _ in $(seq 1 60); do
    if curl -fsS \
        -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
        "http://127.0.0.1:4000/v1/models" >/dev/null 2>&1; then
        cat <<EOF
LiteLLM proxy is ready.
API base: http://127.0.0.1:4000/v1
UI: http://127.0.0.1:4000/ui
Username: ${UI_USERNAME}
Password: read UI_PASSWORD from ${ENV_FILE}
EOF
        exit 0
    fi
    sleep 2
done

echo "LiteLLM did not become ready in time." >&2
tail -n 100 "${LOG_FILE}" >&2 || true
exit 1
