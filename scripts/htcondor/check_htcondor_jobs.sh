#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONDOR_DIR="${POST_TRAIN_BENCH_PERSONAL_CONDOR_DIR:-$REPO_ROOT/.htcondor-local/condor}"

usage() {
    cat <<'EOF'
Usage:
  bash scripts/htcondor/check_htcondor_jobs.sh [cluster_id]
  bash scripts/htcondor/check_htcondor_jobs.sh --status
  bash scripts/htcondor/check_htcondor_jobs.sh --history [cluster_id]
  bash scripts/htcondor/check_htcondor_jobs.sh --all [cluster_id]
  bash scripts/htcondor/check_htcondor_jobs.sh --watch [seconds] [cluster_id]

Examples:
  bash scripts/htcondor/check_htcondor_jobs.sh
  bash scripts/htcondor/check_htcondor_jobs.sh <cluster_id>
  bash scripts/htcondor/check_htcondor_jobs.sh --history <cluster_id>
  bash scripts/htcondor/check_htcondor_jobs.sh --all <cluster_id>
  bash scripts/htcondor/check_htcondor_jobs.sh --watch 5 <cluster_id>
EOF
}

if [ ! -f "$CONDOR_DIR/condor.sh" ]; then
    echo "Personal HTCondor is not set up yet."
    echo "Run: bash scripts/setup_personal_htcondor.sh"
    exit 1
fi

# shellcheck source=/dev/null
source "$CONDOR_DIR/condor.sh"

if ! condor_status -compact >/dev/null 2>&1; then
    echo "Personal HTCondor is not running."
    echo "Run: bash scripts/start_personal_htcondor.sh"
    exit 1
fi

mode="queue"
cluster_id=""
watch_interval=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --status)
            mode="status"
            shift
            ;;
        --history)
            mode="history"
            shift
            ;;
        --all)
            mode="all"
            shift
            ;;
        --watch)
            mode="watch"
            if [ "$#" -gt 1 ] && [[ "${2:-}" =~ ^[0-9]+$ ]]; then
                watch_interval="$2"
                shift 2
            else
                watch_interval="5"
                shift
            fi
            ;;
        *)
            if [ -n "$cluster_id" ]; then
                echo "Unexpected extra argument: $1"
                usage
                exit 1
            fi
            cluster_id="$1"
            shift
            ;;
    esac
done

queue_cmd=(condor_q -nobatch)
history_cmd=(condor_history -limit 20)

if [ -n "$cluster_id" ]; then
    queue_cmd=(condor_q "$cluster_id" -nobatch)
    history_cmd=(condor_history "$cluster_id" -limit 20)
fi

show_queue() {
    echo "=== condor_q ==="
    "${queue_cmd[@]}"
}

show_history() {
    echo "=== condor_history ==="
    "${history_cmd[@]}"
}

show_status() {
    echo "=== condor_status -compact ==="
    condor_status -compact
}

show_all() {
    show_status
    echo
    show_queue
    echo
    show_history
}

case "$mode" in
    queue)
        show_queue
        ;;
    history)
        show_history
        ;;
    status)
        show_status
        ;;
    all)
        show_all
        ;;
    watch)
        while true; do
            clear
            date
            echo
            show_all
            sleep "$watch_interval"
        done
        ;;
    *)
        echo "Unknown mode: $mode"
        exit 1
        ;;
esac
