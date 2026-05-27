#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env"
COMPOSE_FILE="${REPO_ROOT}/docker/litellm/compose.yaml"
PID_FILE="${REPO_ROOT}/.runtime/litellm/proxy.pid"

ARGS=()
if [ "${1:-}" = "--volumes" ]; then
    ARGS+=(--volumes)
fi

if [ -f "${PID_FILE}" ]; then
    PID="$(cat "${PID_FILE}")"
    if [ -n "${PID}" ] && kill -0 "${PID}" >/dev/null 2>&1; then
        kill "${PID}" >/dev/null 2>&1 || true
    fi
    rm -f "${PID_FILE}"
fi

docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" down --remove-orphans "${ARGS[@]}"
