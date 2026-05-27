#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    echo "Usage: $0 <trace.txt> [lines]" >&2
    exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INPUT_PATH="$1"
LINES="${2:-200}"
PARSER="${SCRIPT_DIR}/agents/codex/human_readable_trace.py"
POLL_SECS="${CHECK_POLL_SECS:-2}"

if [[ ! "$LINES" =~ ^[0-9]+$ ]]; then
    echo "ERROR: lines must be an integer, got: $LINES" >&2
    exit 2
fi

if [[ ! "$POLL_SECS" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    echo "ERROR: CHECK_POLL_SECS must be numeric, got: $POLL_SECS" >&2
    exit 2
fi

if [ ! -f "$PARSER" ]; then
    echo "ERROR: parser not found: $PARSER" >&2
    exit 1
fi

TMP_DIR="$(mktemp -d)"
PARSED_PATH="${TMP_DIR}/parsed.txt"
LAST_SIZE=-1
LAST_LINES=0

cleanup() {
    rm -rf "$TMP_DIR"
}

trap cleanup EXIT INT TERM

parse_file() {
    python "$PARSER" "$INPUT_PATH" --stdout >"$PARSED_PATH" 2>/dev/null
}

print_initial_header() {
    echo "Watching: $INPUT_PATH"
    echo "Lines: $LINES"
    echo "Poll: ${POLL_SECS}s"
    echo "Press Ctrl-C to stop"
    echo
}

while [ ! -e "$INPUT_PATH" ]; do
    printf 'Waiting for file: %s\n' "$INPUT_PATH"
    sleep "$POLL_SECS"
done

print_initial_header

parse_file
tail -n "$LINES" "$PARSED_PATH" || true
LAST_LINES="$(wc -l <"$PARSED_PATH" | tr -d ' ')"
LAST_SIZE="$(wc -c <"$INPUT_PATH" | tr -d ' ')"

while true; do
    if [ ! -e "$INPUT_PATH" ]; then
        echo
        echo "[check.sh] file disappeared, waiting: $INPUT_PATH"
        LAST_SIZE=-1
        LAST_LINES=0
        while [ ! -e "$INPUT_PATH" ]; do
            sleep "$POLL_SECS"
        done
        echo "[check.sh] file reappeared: $INPUT_PATH"
        parse_file
        tail -n "$LINES" "$PARSED_PATH" || true
        LAST_LINES="$(wc -l <"$PARSED_PATH" | tr -d ' ')"
        LAST_SIZE="$(wc -c <"$INPUT_PATH" | tr -d ' ')"
        continue
    fi

    CURRENT_SIZE="$(wc -c <"$INPUT_PATH" | tr -d ' ')"
    if [ "$CURRENT_SIZE" -eq "$LAST_SIZE" ]; then
        sleep "$POLL_SECS"
        continue
    fi

    parse_file
    CURRENT_LINES="$(wc -l <"$PARSED_PATH" | tr -d ' ')"

    if [ "$CURRENT_SIZE" -lt "$LAST_SIZE" ] || [ "$CURRENT_LINES" -lt "$LAST_LINES" ]; then
        echo
        echo "[check.sh] file truncated or restarted"
        tail -n "$LINES" "$PARSED_PATH" || true
    else
        START_LINE=$((LAST_LINES + 1))
        if [ "$START_LINE" -le "$CURRENT_LINES" ]; then
            sed -n "${START_LINE},${CURRENT_LINES}p" "$PARSED_PATH"
        fi
    fi

    LAST_SIZE="$CURRENT_SIZE"
    LAST_LINES="$CURRENT_LINES"
    sleep "$POLL_SECS"
done
