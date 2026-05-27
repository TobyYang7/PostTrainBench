#!/bin/bash
# Inside-container fan-out:
#   - 1 COORDINATOR (Opus): no GPU, reads worker outboxes, writes ./swarm/coordinator/plan.md
#   - N WORKERS (Sonnet): one per GPU, train on their pinned GPU, read coordinator plan + peer outboxes
# All processes share $TASK_ROOT/swarm/ for filesystem-based comms.
set -u
set -o pipefail

unset GEMINI_API_KEY
unset CODEX_API_KEY
export ANTHROPIC_API_KEY=""

if [ -f /home/ben/oauth_token ]; then
    export CLAUDE_CODE_OAUTH_TOKEN="$(cat /home/ben/oauth_token)"
else
    echo "ERROR: No oauth_token file found at /home/ben/oauth_token" >&2
    exit 1
fi

export BASH_MAX_TIMEOUT_MS="36000000"

TASK_ROOT="$PWD"
TIMER_PATH="${TASK_ROOT}/timer.sh"
SWARM_ROOT="${TASK_ROOT}/swarm"
COORDINATOR_DIR="${SWARM_ROOT}/coordinator"
SHARED_DIR="${SWARM_ROOT}/shared"
mkdir -p "$SWARM_ROOT" "$COORDINATOR_DIR" "$SHARED_DIR"

MIN_REMAINING_MINUTES=30

# Model assignments — coordinator inherits AGENT_CONFIG (Opus by default).
# Workers can be overridden by POST_TRAIN_BENCH_SWARM_WORKER_MODEL.
COORDINATOR_MODEL="${AGENT_CONFIG}"
WORKER_MODEL="${POST_TRAIN_BENCH_SWARM_WORKER_MODEL:-claude-sonnet-4-6}"

IFS=',' read -ra GPU_LIST <<< "${CUDA_VISIBLE_DEVICES:-}"
NUM_WORKERS=${#GPU_LIST[@]}
if [ "$NUM_WORKERS" -lt 1 ] || [ -z "${GPU_LIST[0]}" ]; then
    echo "ERROR: CUDA_VISIBLE_DEVICES empty; cannot spawn swarm workers" >&2
    exit 1
fi

WORKER_NAMES=()
for i in "${!GPU_LIST[@]}"; do
    WORKER_NAMES+=("subagent${i}")
done

echo "[swarm] coordinator model: ${COORDINATOR_MODEL}"
echo "[swarm] worker model:      ${WORKER_MODEL}"
echo "[swarm] launching 1 coordinator + ${NUM_WORKERS} workers on GPUs: ${GPU_LIST[*]}"
echo "[swarm] worker names: ${WORKER_NAMES[*]}"
echo "[swarm] root:  ${SWARM_ROOT}"

worker_peer_snapshot_for() {
    local self="$1"
    local out=""
    local peer
    for peer in "${WORKER_NAMES[@]}"; do
        if [ "$peer" = "$self" ]; then continue; fi
        local outbox="${SWARM_ROOT}/${peer}/outbox.md"
        if [ -f "$outbox" ]; then
            out+=$'\n--- '"${peer}"$' outbox (last 60 lines) ---\n'
            out+="$(tail -n 60 "$outbox" 2>/dev/null || true)"
            out+=$'\n'
        fi
    done
    printf '%s' "$out"
}

coordinator_worker_snapshot() {
    local out=""
    local worker
    for worker in "${WORKER_NAMES[@]}"; do
        local outbox="${SWARM_ROOT}/${worker}/outbox.md"
        if [ -f "$outbox" ]; then
            out+=$'\n--- '"${worker}"$' outbox (last 80 lines) ---\n'
            out+="$(tail -n 80 "$outbox" 2>/dev/null || true)"
            out+=$'\n'
        else
            out+=$'\n--- '"${worker}"$' outbox (empty) ---\n'
        fi
    done
    printf '%s' "$out"
}

build_worker_initial_prompt() {
    local name="$1"
    local gpu="$2"
    cat <<PROMPT
You are **${name}**, one of ${NUM_WORKERS} parallel WORKER subagents in a swarm.

You are pinned to GPU ${gpu} (CUDA_VISIBLE_DEVICES is restricted to this device in your shell environment). Do NOT attempt to use any other GPU.

There is also a COORDINATOR agent overseeing the swarm. The coordinator does NOT execute code — it only synthesizes strategy. Read its guidance at ../coordinator/plan.md whenever you make a planning decision. If the file does not exist yet on your first turn, proceed with your best judgment and check again later.

Your peer workers (running concurrently): $(printf '%s ' "${WORKER_NAMES[@]}" | sed "s/${name} //; s/ ${name} / /; s/ ${name}\$//")

Swarm filesystem layout (paths relative to your current working directory):
  ./outbox.md                — append your progress, decisions, findings here (coordinator + peers read this)
  ../coordinator/plan.md     — coordinator's strategic plan (READ at every planning step)
  ../<peer>/outbox.md        — peer progress (read-only convention)
  ../shared/                 — drop genuinely shared artifacts here (datasets, checkpoints peers may reuse)

Coordination rules:
  1. After each significant action (data prep, training step, eval, hypothesis change), append a short note to ./outbox.md with a UTC timestamp.
  2. Before starting a new experiment direction, scan ../coordinator/plan.md AND all ../<peer>/outbox.md. If a peer is already exploring the same direction, pick a different one or specialize.
  3. Treat ../shared/ as cooperative storage. Don't write there unless you intend peers to consume the artifact.
  4. You may NOT communicate with peers any other way — no network, no signals, no shared stdin.

Original task prompt follows. Solve it from your own GPU, but coordinate with the swarm via the rules above.
========== ORIGINAL TASK ==========
${PROMPT}
========== END ORIGINAL TASK ==========
PROMPT
}

build_worker_continuation_prompt() {
    local name="$1"
    local gpu="$2"
    local remaining_h="$3"
    local remaining_m="$4"
    local snapshot plan
    snapshot="$(worker_peer_snapshot_for "$name")"
    if [ -z "$snapshot" ]; then snapshot=$'\n(no peer updates yet)\n'; fi
    if [ -f "${COORDINATOR_DIR}/plan.md" ]; then
        plan="$(tail -n 100 "${COORDINATOR_DIR}/plan.md" 2>/dev/null || true)"
    else
        plan="(no coordinator plan yet)"
    fi
    cat <<PROMPT
You still have ${remaining_h}h ${remaining_m}m remaining. Continue improving your result on GPU ${gpu}.

Coordinator plan (../coordinator/plan.md, last 100 lines):
${plan}

Peer progress snapshot:${snapshot}

Reminders:
  - Append your own progress to ./outbox.md before you finish this turn.
  - If peers are duplicating your direction, pivot or specialize.
  - Don't touch other GPUs.
PROMPT
}

build_coordinator_initial_prompt() {
    cat <<PROMPT
You are the **COORDINATOR** of a swarm of ${NUM_WORKERS} worker subagents (${WORKER_NAMES[*]}).

Each worker is pinned to a different GPU and is solving the same original task independently. Your job is NOT to solve the task yourself — it is to read worker progress and steer them.

You do NOT have any GPU. CUDA_VISIBLE_DEVICES is empty in your shell. Do NOT attempt to run training code, model inference, or nvidia-smi.

Your only output channel is ./plan.md. Workers read this file at every planning step.

Swarm filesystem layout (paths relative to your current working directory):
  ./plan.md                   — write your latest coordination plan here (workers read this)
  ../subagent*/outbox.md      — worker progress (read-only convention)
  ../shared/                  — shared artifacts that workers exchange

Rules:
  1. After each turn, overwrite ./plan.md with: (a) overall strategy, (b) per-worker direction recommendation, (c) what to avoid.
  2. Be terse — workers have limited context budget. Aim for under 200 lines.
  3. Identify duplicated work between workers and propose specialization.
  4. Never assume a worker is "stuck" before reading its outbox.

The original task workers are solving:
========== ORIGINAL TASK ==========
${PROMPT}
========== END ORIGINAL TASK ==========

Begin by writing an initial ./plan.md proposing how to split this task across ${NUM_WORKERS} workers (different model sizes, prompt variants, hyperparameter regions, ablation directions, etc.). The workers will read it before starting.
PROMPT
}

build_coordinator_continuation_prompt() {
    local remaining_h="$1"
    local remaining_m="$2"
    local snapshot
    snapshot="$(coordinator_worker_snapshot)"
    cat <<PROMPT
You still have ${remaining_h}h ${remaining_m}m remaining. Continue coordinating.

Worker outboxes:${snapshot}

Update ./plan.md with the current strategy. Workflow:
  1. Read each worker's latest outbox above.
  2. Identify what's working, what's stalled, and where workers are duplicating effort.
  3. Overwrite ./plan.md with concise (≤200 lines) updated guidance — overall strategy + per-worker direction + things to avoid.
  4. Do NOT execute code. Do NOT touch GPUs.
PROMPT
}

run_worker() {
    local name="$1"
    local gpu="$2"
    local work_dir="${SWARM_ROOT}/${name}"
    mkdir -p "$work_dir"
    : > "${work_dir}/outbox.md"

    (
        # Detach subshell stdout/stderr from any $() capture in the caller
        # so command substitution returns immediately after `echo $!`.
        exec >>"${work_dir}/spawn.log" 2>&1
        cd "$work_dir" || exit 1
        export CUDA_VISIBLE_DEVICES="$gpu"

        local initial_prompt
        initial_prompt="$(build_worker_initial_prompt "$name" "$gpu")"

        echo "[${name}] initial run on GPU ${gpu} (model=${WORKER_MODEL})"
        claude --print --verbose --model "$WORKER_MODEL" \
            --output-format stream-json \
            --effort high \
            --dangerously-skip-permissions "$initial_prompt" \
            >> "${work_dir}/transcript.jsonl" 2>>"${work_dir}/stderr.log"
        local initial_exit=$?
        if [ "$initial_exit" -ne 0 ]; then
            echo "[${name}] initial run exited ${initial_exit}" >&2
            exit "$initial_exit"
        fi

        while true; do
            local timer_output remaining_line
            timer_output="$(bash "$TIMER_PATH" 2>/dev/null)" || {
                echo "[${name}] timer.sh failed; exiting reprompt loop" >&2
                break
            }
            if printf '%s\n' "$timer_output" | grep -q "expired"; then
                break
            fi
            remaining_line="$(printf '%s\n' "$timer_output" | tail -n 1)"
            if [[ ! "$remaining_line" =~ ^([0-9]+):([0-9]{2})$ ]]; then
                echo "[${name}] unexpected timer output: ${timer_output}" >&2
                break
            fi
            local rh="${BASH_REMATCH[1]}"
            local rm="${BASH_REMATCH[2]}"
            local total=$((10#$rh * 60 + 10#$rm))
            if [ "$total" -lt "$MIN_REMAINING_MINUTES" ]; then
                break
            fi

            local cont_prompt
            cont_prompt="$(build_worker_continuation_prompt "$name" "$gpu" "$rh" "$rm")"

            claude --print --continue --verbose --model "$WORKER_MODEL" \
                --output-format stream-json \
                --effort high \
                --dangerously-skip-permissions "$cont_prompt" \
                >> "${work_dir}/transcript.jsonl" 2>>"${work_dir}/stderr.log"
            local cont_exit=$?
            if [ "$cont_exit" -ne 0 ]; then
                echo "[${name}] continue exited ${cont_exit}; ending loop" >&2
                exit "$cont_exit"
            fi
        done
        exit 0
    ) &
    echo "$!"
}

run_coordinator() {
    local work_dir="$COORDINATOR_DIR"
    : > "${work_dir}/plan.md"

    (
        # Detach subshell stdout/stderr from any $() capture in the caller.
        exec >>"${work_dir}/spawn.log" 2>&1
        cd "$work_dir" || exit 1
        # Coordinator gets no GPU. Empty CUDA_VISIBLE_DEVICES hides the device.
        export CUDA_VISIBLE_DEVICES=""

        local initial_prompt
        initial_prompt="$(build_coordinator_initial_prompt)"

        echo "[coordinator] initial run (model=${COORDINATOR_MODEL})"
        claude --print --verbose --model "$COORDINATOR_MODEL" \
            --output-format stream-json \
            --effort high \
            --dangerously-skip-permissions "$initial_prompt" \
            >> "${work_dir}/transcript.jsonl" 2>>"${work_dir}/stderr.log"
        local initial_exit=$?
        if [ "$initial_exit" -ne 0 ]; then
            echo "[coordinator] initial run exited ${initial_exit}" >&2
            exit "$initial_exit"
        fi

        while true; do
            local timer_output remaining_line
            timer_output="$(bash "$TIMER_PATH" 2>/dev/null)" || {
                echo "[coordinator] timer.sh failed; exiting reprompt loop" >&2
                break
            }
            if printf '%s\n' "$timer_output" | grep -q "expired"; then
                break
            fi
            remaining_line="$(printf '%s\n' "$timer_output" | tail -n 1)"
            if [[ ! "$remaining_line" =~ ^([0-9]+):([0-9]{2})$ ]]; then
                echo "[coordinator] unexpected timer output: ${timer_output}" >&2
                break
            fi
            local rh="${BASH_REMATCH[1]}"
            local rm="${BASH_REMATCH[2]}"
            local total=$((10#$rh * 60 + 10#$rm))
            if [ "$total" -lt "$MIN_REMAINING_MINUTES" ]; then
                break
            fi

            local cont_prompt
            cont_prompt="$(build_coordinator_continuation_prompt "$rh" "$rm")"

            claude --print --continue --verbose --model "$COORDINATOR_MODEL" \
                --output-format stream-json \
                --effort high \
                --dangerously-skip-permissions "$cont_prompt" \
                >> "${work_dir}/transcript.jsonl" 2>>"${work_dir}/stderr.log"
            local cont_exit=$?
            if [ "$cont_exit" -ne 0 ]; then
                echo "[coordinator] continue exited ${cont_exit}; ending loop" >&2
                exit "$cont_exit"
            fi
        done
        exit 0
    ) &
    echo "$!"
}

PIDS=()
NAMES_BY_PID=()

COORDINATOR_PID="$(run_coordinator)"
PIDS+=("$COORDINATOR_PID")
NAMES_BY_PID+=("${COORDINATOR_PID}:coordinator:none")
echo "[swarm] coordinator (pid ${COORDINATOR_PID}) spawned"

for i in "${!GPU_LIST[@]}"; do
    name="${WORKER_NAMES[$i]}"
    gpu="${GPU_LIST[$i]}"
    pid="$(run_worker "$name" "$gpu")"
    PIDS+=("$pid")
    NAMES_BY_PID+=("${pid}:${name}:${gpu}")
    echo "[swarm] ${name} (pid ${pid}, gpu ${gpu}) spawned"
done

echo "[swarm] all ${#PIDS[@]} processes launched; waiting"

EXIT_CODE=0
FAILED=()
for entry in "${NAMES_BY_PID[@]}"; do
    pid="${entry%%:*}"
    rest="${entry#*:}"
    name="${rest%%:*}"
    gpu="${rest##*:}"
    if wait "$pid"; then
        echo "[swarm] ${name} (gpu ${gpu}) finished OK"
    else
        rc=$?
        EXIT_CODE=1
        FAILED+=("${name}(gpu${gpu})=${rc}")
        echo "[swarm] ${name} (gpu ${gpu}) FAILED rc=${rc}" >&2
    fi
done

{
    echo "# Swarm Summary"
    echo ""
    echo "- coordinator model: ${COORDINATOR_MODEL}"
    echo "- worker model:      ${WORKER_MODEL}"
    echo "- workers: ${NUM_WORKERS}"
    echo "- gpus: ${GPU_LIST[*]}"
    echo "- failed: ${FAILED[*]:-none}"
    echo ""
    echo "## coordinator (final plan)"
    if [ -f "${COORDINATOR_DIR}/plan.md" ]; then
        cat "${COORDINATOR_DIR}/plan.md"
    else
        echo "(no plan written)"
    fi
    echo ""
    for name in "${WORKER_NAMES[@]}"; do
        echo "## ${name}"
        if [ -f "${SWARM_ROOT}/${name}/outbox.md" ]; then
            cat "${SWARM_ROOT}/${name}/outbox.md"
        else
            echo "(no outbox written)"
        fi
        echo ""
    done
} > "${TASK_ROOT}/swarm_summary.md"

if [ "${#FAILED[@]}" -gt 0 ]; then
    echo "[swarm] ${#FAILED[@]} process(es) failed: ${FAILED[*]}" >&2
fi

exit "$EXIT_CODE"
