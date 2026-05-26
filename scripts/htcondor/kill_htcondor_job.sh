#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONDOR_DIR="${POST_TRAIN_BENCH_PERSONAL_CONDOR_DIR:-$REPO_ROOT/.htcondor-local/condor}"
WAIT_SECONDS=10
GRACE_ONLY=0
USE_ALL=0

usage() {
    cat <<'EOF'
Usage:
  bash scripts/htcondor/kill_htcondor_job.sh <cluster_id> [more_cluster_ids...]
  bash scripts/htcondor/kill_htcondor_job.sh --all
  bash scripts/htcondor/kill_htcondor_job.sh --grace-only <cluster_id>
  bash scripts/htcondor/kill_htcondor_job.sh --wait 20 <cluster_id>

Behavior:
  1. Try condor_rm first.
  2. Wait briefly for the job to enter Removed / leave the queue.
  3. If wrappers are still alive, kill the matching run_task/starter/shadow processes.

Options:
  --all         Cancel every job currently visible in condor_q.
  --grace-only  Only do condor_rm; skip host-side process cleanup.
  --wait N      Seconds to wait after condor_rm before force cleanup. Default: 10.
  -h, --help    Show this help.

Examples:
  bash scripts/htcondor/kill_htcondor_job.sh <cluster_id>
  bash scripts/htcondor/kill_htcondor_job.sh <cluster_id_1> <cluster_id_2>
  bash scripts/htcondor/kill_htcondor_job.sh --wait 5 <cluster_id>
  bash scripts/htcondor/kill_htcondor_job.sh --grace-only <cluster_id>
  bash scripts/htcondor/kill_htcondor_job.sh --all
EOF
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

is_integer() {
    [[ "${1:-}" =~ ^[0-9]+$ ]]
}

CONDOR_READY=0

if [ -f "$CONDOR_DIR/condor.sh" ]; then
    # shellcheck source=/dev/null
    source "$CONDOR_DIR/condor.sh"
    if condor_status -compact >/dev/null 2>&1; then
        CONDOR_READY=1
    fi
fi

cluster_ids=()

while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --all)
            USE_ALL=1
            shift
            ;;
        --grace-only)
            GRACE_ONLY=1
            shift
            ;;
        --wait)
            [ "$#" -ge 2 ] || die "--wait requires an integer argument"
            is_integer "$2" || die "--wait requires an integer argument"
            WAIT_SECONDS="$2"
            shift 2
            ;;
        *)
            is_integer "$1" || die "Cluster IDs must be integers: $1"
            cluster_ids+=("$1")
            shift
            ;;
    esac
done

if [ "$USE_ALL" -eq 1 ] && [ "${#cluster_ids[@]}" -gt 0 ]; then
    die "--all cannot be combined with explicit cluster IDs"
fi

if [ "$USE_ALL" -eq 0 ] && [ "${#cluster_ids[@]}" -eq 0 ]; then
    usage
    exit 1
fi

if [ "$USE_ALL" -eq 1 ]; then
    [ "$CONDOR_READY" -eq 1 ] || die "--all requires Personal HTCondor to be running"
    mapfile -t cluster_ids < <(condor_q -af ClusterId 2>/dev/null | awk 'NF' | sort -n | uniq)
    if [ "${#cluster_ids[@]}" -eq 0 ]; then
        echo "No jobs are currently visible in condor_q."
        exit 0
    fi
fi

if [ "$CONDOR_READY" -eq 0 ]; then
    echo "Warning: Personal HTCondor is not running or condor.sh is unavailable."
    echo "Skipping condor_rm and using host-side cleanup only."
    if [ "$GRACE_ONLY" -eq 1 ]; then
        die "--grace-only cannot work when Personal HTCondor is unavailable"
    fi
fi

find_run_task_rows() {
    local cluster_id="$1"
    ps -eo pid=,ppid=,pgid=,cmd= | awk -v cluster_id="$cluster_id" '
        $4 ~ /bash$/ && $5 == "src/run_task.sh" && $9 == cluster_id {
            print $1, $2, $3
        }
    '
}

find_shadow_pids() {
    local cluster_id="$1"
    ps -eo pid=,cmd= | awk -v cluster_id="$cluster_id" '
        $2 == "condor_shadow" && $3 == cluster_id ".0" {
            print $1
        }
    '
}

find_matching_pids() {
    local cluster_id="$1"
    ps -eo pid=,ppid=,pgid=,cmd= | awk -v cluster_id="$cluster_id" '
        ($4 ~ /bash$/ && $5 == "src/run_task.sh" && $9 == cluster_id) ||
        ($4 == "condor_shadow" && $5 == cluster_id ".0") {
            print $1
        }
    '
}

queue_state_is_removed_or_gone() {
    local cluster_id="$1"
    local statuses

    statuses="$(condor_q "$cluster_id" -af JobStatus 2>/dev/null || true)"
    if [ -z "$statuses" ]; then
        return 0
    fi

    if printf '%s\n' "$statuses" | awk 'NF && $1 != 3 { exit 1 }'; then
        return 0
    fi

    return 1
}

show_queue_snapshot() {
    local cluster_id="$1"
    if [ "$CONDOR_READY" -eq 1 ]; then
        condor_q "$cluster_id" -nobatch 2>&1 || true
    else
        echo "condor_q unavailable"
    fi
}

request_remove() {
    local cluster_id="$1"
    echo "==> condor_rm $cluster_id"
    if [ "$CONDOR_READY" -eq 1 ]; then
        condor_rm "$cluster_id" 2>&1 || true
    else
        echo "Skipped: Personal HTCondor unavailable"
    fi
}

wait_for_remove() {
    local cluster_id="$1"
    local deadline

    if [ "$CONDOR_READY" -eq 0 ]; then
        return 0
    fi

    deadline=$((SECONDS + WAIT_SECONDS))
    while [ "$SECONDS" -lt "$deadline" ]; do
        if queue_state_is_removed_or_gone "$cluster_id"; then
            return 0
        fi
        sleep 1
    done
    return 1
}

kill_residuals() {
    local cluster_id="$1"
    local row pid ppid pgid
    local -a rows=()
    local -a shadow_pids=()
    local -a pgids=()
    local -a pids=()
    local -a unique_pgids=()
    local -a unique_pids=()

    mapfile -t rows < <(find_run_task_rows "$cluster_id")
    mapfile -t shadow_pids < <(find_shadow_pids "$cluster_id")

    if [ "${#rows[@]}" -eq 0 ] && [ "${#shadow_pids[@]}" -eq 0 ]; then
        echo "No residual host processes matched cluster $cluster_id."
        return 0
    fi

    for row in "${rows[@]}"; do
        read -r pid ppid pgid <<<"$row"
        pids+=("$pid" "$ppid")
        pgids+=("$pgid")
    done

    if [ "${#shadow_pids[@]}" -gt 0 ]; then
        pids+=("${shadow_pids[@]}")
    fi

    mapfile -t unique_pgids < <(printf '%s\n' "${pgids[@]}" | awk 'NF' | sort -n | uniq)
    mapfile -t unique_pids < <(printf '%s\n' "${pids[@]}" | awk 'NF' | sort -n | uniq)

    echo "Residual processes still matched cluster $cluster_id."
    echo "Sending SIGTERM to process groups: ${unique_pgids[*]:-<none>}"
    echo "Sending SIGTERM to pids: ${unique_pids[*]:-<none>}"

    for pgid in "${unique_pgids[@]}"; do
        kill -TERM "-$pgid" 2>/dev/null || true
    done
    for pid in "${unique_pids[@]}"; do
        kill -TERM "$pid" 2>/dev/null || true
    done

    sleep 3

    if find_matching_pids "$cluster_id" | awk 'NF { found = 1 } END { exit !found }'; then
        echo "Residual wrappers still alive; escalating to SIGKILL."
        for pgid in "${unique_pgids[@]}"; do
            kill -KILL "-$pgid" 2>/dev/null || true
        done
        for pid in "${unique_pids[@]}"; do
            kill -KILL "$pid" 2>/dev/null || true
        done
        sleep 1
    fi
}

for cluster_id in "${cluster_ids[@]}"; do
    echo
    echo "===== Cluster $cluster_id ====="
    echo "-- Before --"
    show_queue_snapshot "$cluster_id"
    echo

    request_remove "$cluster_id"

    if [ "$CONDOR_READY" -eq 1 ]; then
        if wait_for_remove "$cluster_id"; then
            echo "Job $cluster_id is removed or no longer in queue."
        else
            echo "Job $cluster_id did not leave the queue within ${WAIT_SECONDS}s."
        fi
    fi

    if [ "$GRACE_ONLY" -eq 0 ]; then
        kill_residuals "$cluster_id"
    fi

    echo
    echo "-- After --"
    show_queue_snapshot "$cluster_id"
    echo "-- Matching host pids --"
    if ! find_matching_pids "$cluster_id"; then
        :
    fi
done
