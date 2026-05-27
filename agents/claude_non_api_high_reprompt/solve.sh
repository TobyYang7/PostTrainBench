#!/bin/bash
set -u
set -o pipefail

unset GEMINI_API_KEY
unset CODEX_API_KEY

# Clear API key so the CLI uses the OAuth token from subscription
export ANTHROPIC_API_KEY=""

# Load OAuth token from file (copied by run_task.sh)
if [ -f /home/ben/oauth_token ]; then
    export CLAUDE_CODE_OAUTH_TOKEN="$(cat /home/ben/oauth_token)"
else
    echo "ERROR: No oauth_token file found at /home/ben/oauth_token"
    exit 1
fi

export BASH_MAX_TIMEOUT_MS="36000000"

MIN_REMAINING_MINUTES=30

run_claude_initial() {
    claude --print --verbose --model "$AGENT_CONFIG" --output-format stream-json \
        --effort high \
        --dangerously-skip-permissions "$PROMPT"
}

run_claude_continue() {
    local continuation_prompt="$1"
    claude --print --continue --verbose --model "$AGENT_CONFIG" --output-format stream-json \
        --effort high \
        --dangerously-skip-permissions "$continuation_prompt"
}

get_remaining_time() {
    local timer_output
    local remaining_line

    timer_output="$(bash timer.sh 2>/dev/null)" || {
        echo "ERROR: timer.sh failed" >&2
        return 1
    }

    if printf '%s\n' "$timer_output" | grep -q "expired"; then
        return 10
    fi

    remaining_line="$(printf '%s\n' "$timer_output" | tail -n 1)"
    if [[ ! "$remaining_line" =~ ^([0-9]+):([0-9]{2})$ ]]; then
        echo "ERROR: Unexpected timer output: $timer_output" >&2
        return 1
    fi

    REMAINING_HOURS="${BASH_REMATCH[1]}"
    REMAINING_MINS="${BASH_REMATCH[2]}"
    TOTAL_REMAINING_MINS=$((10#$REMAINING_HOURS * 60 + 10#$REMAINING_MINS))
}

run_claude_initial
INITIAL_EXIT_CODE=$?
if [ "$INITIAL_EXIT_CODE" -ne 0 ]; then
    exit "$INITIAL_EXIT_CODE"
fi

# Re-prompt loop: if the agent finishes early, continue the session
while true; do
    get_remaining_time
    TIMER_STATUS=$?
    if [ "$TIMER_STATUS" -eq 10 ]; then
        break
    fi
    if [ "$TIMER_STATUS" -ne 0 ]; then
        exit "$TIMER_STATUS"
    fi

    if [ "$TOTAL_REMAINING_MINS" -lt "$MIN_REMAINING_MINUTES" ]; then
        break
    fi

    CONTINUATION_PROMPT="You still have ${REMAINING_HOURS}h ${REMAINING_MINS}m remaining. Please continue improving your result and maximize performance."

    run_claude_continue "$CONTINUATION_PROMPT"
    CONTINUE_EXIT_CODE=$?
    if [ "$CONTINUE_EXIT_CODE" -ne 0 ]; then
        exit "$CONTINUE_EXIT_CODE"
    fi
done
