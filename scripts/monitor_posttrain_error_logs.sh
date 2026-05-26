#!/bin/bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$REPO_DIR" || exit 1

INTERVAL_SECONDS="${POST_TRAIN_BENCH_MONITOR_INTERVAL:-60}"
RESTART_GRACE_SECONDS="${POST_TRAIN_BENCH_MONITOR_RESTART_GRACE:-90}"

latest_run_dir() {
    local experiment_dir="$1"
    find "results/${experiment_dir}" -mindepth 1 -maxdepth 1 -type d \
        -name 'gsm8k_Qwen_Qwen3-1.7B-Base_*' \
        -printf '%T@ %p\n' 2>/dev/null \
        | sort -nr \
        | while read -r _ path; do
            printf '%s\n' "$path"
            break
        done
}

restart_run() {
    local session_name="$1"
    local run_script="$2"

    if tmux has-session -t "$session_name" 2>/dev/null; then
        tmux kill-session -t "$session_name"
    fi
    tmux new-session -d -s "$session_name" -c "$REPO_DIR" "bash ${run_script}"
}

check_error_log() {
    local label="$1"
    local experiment_dir="$2"
    local session_name="$3"
    local run_script="$4"

    local run_dir
    run_dir="$(latest_run_dir "$experiment_dir")"
    if [ -z "$run_dir" ]; then
        return 0
    fi

    local error_log="${run_dir}/error.log"
    if [ ! -f "$error_log" ]; then
        return 0
    fi

    if [ -s "$error_log" ]; then
        printf '%s %s error.log is non-empty; restarting %s from %s\n' \
            "$(date --iso-8601=seconds)" "$label" "$run_script" "$error_log"
        restart_run "$session_name" "$run_script"
        sleep "$RESTART_GRACE_SECONDS"
    fi
}

printf '%s monitoring run1/run2 error.log only\n' "$(date --iso-8601=seconds)"
while true; do
    check_error_log \
        "run1" \
        "codex_non_api_high_gpt-5.5_10h_prompt1_gpu6" \
        "ptb_run1" \
        "run1.sh"
    check_error_log \
        "run2" \
        "codex_non_api_high_gpt-5.5_10h_prompt2_gpu7" \
        "ptb_run2" \
        "run2.sh"
    sleep "$INTERVAL_SECONDS"
done
