#!/bin/bash
set -o pipefail

export EVALUATION_TASK="$1"
AGENT="$2"
MODEL_TO_TRAIN="$3"
CLUSTER_ID="$4"
NUM_HOURS="$5"
AGENT_CONFIG="$6"
NUM_GPUS="${7:-1}"
CUDA_DEVICE_IDX="${8:-}"

APPTAINER_CUDA_ENV=()
if [ -n "$CUDA_DEVICE_IDX" ]; then
    export CUDA_DEVICE_IDX
    export CUDA_VISIBLE_DEVICES="$CUDA_DEVICE_IDX"
    export CUDA_DEVICE_ORDER="PCI_BUS_ID"
    export NVIDIA_VISIBLE_DEVICES="$CUDA_VISIBLE_DEVICES"
    export POST_TRAIN_BENCH_ASSIGNED_CUDA_VISIBLE_DEVICES="$CUDA_VISIBLE_DEVICES"
    APPTAINER_CUDA_ENV=(
        --env CUDA_DEVICE_IDX="${CUDA_DEVICE_IDX}"
        --env CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES}"
        --env CUDA_DEVICE_ORDER="${CUDA_DEVICE_ORDER}"
        --env NVIDIA_VISIBLE_DEVICES="${NVIDIA_VISIBLE_DEVICES}"
        --env POST_TRAIN_BENCH_ASSIGNED_CUDA_VISIBLE_DEVICES="${POST_TRAIN_BENCH_ASSIGNED_CUDA_VISIBLE_DEVICES}"
    )
fi

source src/commit_utils/set_env_vars.sh

RESULT_PREFIX_SAFE=$(echo "$MODEL_TO_TRAIN" | tr '/:[]' '____')

AGENT_CONFIG_SAFE=$(echo "$AGENT_CONFIG" | tr '/:[]' '____')

RANDOM_UUID=$(uuidgen)

GPU_SUFFIX=""
if [ "$NUM_GPUS" -gt 1 ] 2>/dev/null; then
    GPU_SUFFIX="_${NUM_GPUS}gpu"
fi

export EVAL_DIR="${POST_TRAIN_BENCH_RESULTS_DIR}/${AGENT}_${AGENT_CONFIG_SAFE}_${NUM_HOURS}h${GPU_SUFFIX}${POST_TRAIN_BENCH_EXPERIMENT_NAME}/${EVALUATION_TASK}_${RESULT_PREFIX_SAFE}_${CLUSTER_ID}"

mkdir -p ${EVAL_DIR}

exec 1>${EVAL_DIR}/output.log
exec 2>${EVAL_DIR}/error.log

echo "$@"

export TMP_SUBDIR="/tmp/posttrain_container_${EVALUATION_TASK}_${RESULT_PREFIX_SAFE}_${RANDOM_UUID}"

JOB_DIR="${TMP_SUBDIR}/job_dir"
JOB_TMP="${TMP_SUBDIR}/tmp"
export HF_MERGED="${TMP_SUBDIR}/merged_huggingface"

mkdir -p "${JOB_DIR}"
mkdir -p "${JOB_TMP}"
export PYTHON_SHIM_DIR="${JOB_DIR}/python_shims"
CONTAINER_PYTHON_SHIM_DIR="/home/ben/python_shims"
NVIDIA_SMI_WRAPPER="${JOB_DIR}/nvidia-smi"
HOST_NVIDIA_SMI="$(command -v nvidia-smi 2>/dev/null || true)"
NVIDIA_SMI_BIND_ARGS=()

echo "Preparing job directory..." 
mkdir -p "${JOB_DIR}"

mkdir "${JOB_DIR}/task"
mkdir -p "${PYTHON_SHIM_DIR}"
cat > "${PYTHON_SHIM_DIR}/sitecustomize.py" <<'PY'
try:
    import transformers.tokenization_utils_base as _tokenization_base

    for _class_name in ("SpecialTokensMixin", "PreTrainedTokenizerBase"):
        _cls = getattr(_tokenization_base, _class_name, None)
        if _cls is None or not hasattr(_cls, "__getattr__"):
            continue
        _orig_getattr = _cls.__getattr__

        def _posttrain_getattr(self, key, _orig_getattr=_orig_getattr):
            if key == "all_special_tokens_extended":
                return self.all_special_tokens
            return _orig_getattr(self, key)

        _cls.__getattr__ = _posttrain_getattr
except Exception:
    pass
PY

cp "src/eval/tasks/${EVALUATION_TASK}/evaluate.py" "${JOB_DIR}/task"
if [ -d "src/eval/tasks/${EVALUATION_TASK}/evaluation_code" ]; then
    cp -r "src/eval/tasks/${EVALUATION_TASK}/evaluation_code" "${JOB_DIR}/task"
fi
cp -r src/eval/templates "${JOB_DIR}/task/"

if [ -d "src/eval/tasks/${EVALUATION_TASK}/task_context" ]; then
    cp -r src/eval/tasks/${EVALUATION_TASK}/task_context/* "${JOB_DIR}/task"
fi
cp -r "containers/other_home_data/.codex" "${JOB_DIR}/"

refresh_workspace_symlink() {
    local target="$1"
    local workspace_link="${EVAL_DIR}/proj/workspace"
    mkdir -p "${EVAL_DIR}/proj"
    rm -rf "${workspace_link}"
    ln -s "${target}" "${workspace_link}"
}

refresh_workspace_symlink "${JOB_DIR}/task"

copy_host_codex_auth() {
    if { [ "${POST_TRAIN_BENCH_JOB_SCHEDULER:-}" = "local" ] || [ "${POST_TRAIN_BENCH_COPY_HOST_CODEX_AUTH:-}" = "1" ]; } && [ -f "${HOME}/.codex/auth.json" ]; then
        mkdir -p "${JOB_DIR}/.codex"
        cp "${HOME}/.codex/auth.json" "${JOB_DIR}/.codex/auth.json"
    fi
}

force_codex_chatgpt_auth() {
    mkdir -p "${JOB_DIR}/.codex"
    if ! grep -q "forced_login_method" "${JOB_DIR}/.codex/config.toml" 2>/dev/null; then
        printf '\nforced_login_method = "chatgpt"\n' >> "${JOB_DIR}/.codex/config.toml"
    fi
}

install_host_codex_binary() {
    if [ "${POST_TRAIN_BENCH_JOB_SCHEDULER:-}" != "local" ] && [ "${POST_TRAIN_BENCH_INSTALL_HOST_CODEX_BINARY:-}" != "1" ]; then
        return 0
    fi

    local host_codex_bin="${POST_TRAIN_BENCH_CODEX_BIN:-}"
    if [ -z "$host_codex_bin" ] && command -v codex >/dev/null 2>&1; then
        host_codex_bin="$(readlink -f "$(command -v codex)")"
    fi

    if [ -n "$host_codex_bin" ] && [ -x "$host_codex_bin" ]; then
        mkdir -p "${JOB_DIR}/.local/bin"
        cp "$host_codex_bin" "${JOB_DIR}/.local/bin/codex"
        chmod 0755 "${JOB_DIR}/.local/bin/codex"
    fi
}

install_nvidia_smi_wrapper() {
    if [ -z "${CUDA_VISIBLE_DEVICES:-}" ] || [ -z "$HOST_NVIDIA_SMI" ]; then
        return 0
    fi

    cat > "$NVIDIA_SMI_WRAPPER" <<'SH'
#!/bin/bash
set -euo pipefail

real_nvidia_smi="${POST_TRAIN_BENCH_REAL_NVIDIA_SMI:-/usr/bin/nvidia-smi}"
assigned_devices="${POST_TRAIN_BENCH_ASSIGNED_CUDA_VISIBLE_DEVICES:-${CUDA_VISIBLE_DEVICES:-}}"

if [ -z "$assigned_devices" ]; then
    exec "$real_nvidia_smi" "$@"
fi

map_id_one() {
    local requested="$1"
    IFS=',' read -r -a assigned <<< "$assigned_devices"
    if [[ "$requested" =~ ^[0-9]+$ ]] && [ "$requested" -lt "${#assigned[@]}" ]; then
        printf '%s' "${assigned[$requested]}"
    else
        printf '%s' "$requested"
    fi
}

map_id_list() {
    local requested_list="$1"
    local mapped=()
    IFS=',' read -r -a requested <<< "$requested_list"
    for id in "${requested[@]}"; do
        mapped+=("$(map_id_one "$id")")
    done
    local IFS=,
    printf '%s' "${mapped[*]}"
}

args=()
has_id=0
list_gpus=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        -L|--list-gpus)
            args+=("$1")
            list_gpus=1
            ;;
        --id=*)
            args+=("--id=$(map_id_list "${1#--id=}")")
            has_id=1
            ;;
        -i|--id)
            if [ "$#" -gt 1 ]; then
                shift
                args+=("--id=$(map_id_list "$1")")
                has_id=1
            else
                args+=("$1")
            fi
            ;;
        *)
            args+=("$1")
            ;;
    esac
    shift
done

if [ "$list_gpus" -eq 1 ]; then
    exec "$real_nvidia_smi" "${args[@]}"
fi

if [ "$has_id" -eq 0 ]; then
    exec "$real_nvidia_smi" --id="$assigned_devices" "${args[@]}"
fi

exec "$real_nvidia_smi" "${args[@]}"
SH
    chmod 0755 "$NVIDIA_SMI_WRAPPER"
    mkdir -p "${JOB_DIR}/.local/bin"
    cp "$NVIDIA_SMI_WRAPPER" "${JOB_DIR}/.local/bin/nvidia-smi"
    NVIDIA_SMI_BIND_ARGS=(
        --bind "${NVIDIA_SMI_WRAPPER}:/usr/bin/nvidia-smi:ro"
        --bind "${HOST_NVIDIA_SMI}:/opt/posttrain_real_nvidia_smi:ro"
        --env POST_TRAIN_BENCH_REAL_NVIDIA_SMI="/opt/posttrain_real_nvidia_smi"
    )
}

copy_host_codex_auth
install_host_codex_binary
install_nvidia_smi_wrapper

BENCHMARK=$(cat src/eval/tasks/${EVALUATION_TASK}/benchmark.txt)
PROMPT=$(python src/eval/general/get_prompt.py --model-to-train "$MODEL_TO_TRAIN" --benchmark-id "$EVALUATION_TASK" --num-hours "$NUM_HOURS" --num-gpus "$NUM_GPUS" --agent "${AGENT}")
echo "$PROMPT" > "${EVAL_DIR}/prompt.txt"
echo "$PROMPT" > "${JOB_DIR}/prompt.txt"

bash src/utils/create_timer.sh $NUM_HOURS $JOB_DIR/task/timer.sh

# set openai api keys appropriately
export CODEX_API_KEY="${OPENAI_API_KEY}"
unset OPENAI_API_KEY
if [ "$EVALUATION_TASK" == "arenahardwriting" ] || [ "$EVALUATION_TASK" == "healthbench" ]; then
    export OPENAI_API_KEY="${CODEX_API_KEY}"
fi

# Copy scripts needed inside the container
cp src/utils/check_cuda.py "${JOB_DIR}/check_cuda.py"
cp src/utils/check_cuda_writing.py "${JOB_DIR}/check_cuda_writing.py"
cp src/utils/system_monitor.sh "${JOB_DIR}/system_monitor.sh"
cp src/utils/timestamp_lines.py "${JOB_DIR}/timestamp_lines.py"
cp "agents/${AGENT}/solve.sh" "${JOB_DIR}/agent_solve.sh"

if [ "$AGENT" = "ml_intern" ] && [ -d "third_party/ml-intern" ]; then
    cp -r "third_party/ml-intern" "${JOB_DIR}/ml-intern"
    if [ -f ".env" ]; then
        cp ".env" "${JOB_DIR}/.env"
        chmod 0600 "${JOB_DIR}/.env"
    fi
fi

if [ "$AGENT" = "ml_master" ] && [ -d "third_party/ML-Master" ]; then
    cp -r "third_party/ML-Master" "${JOB_DIR}/ML-Master"
    if [ -f ".env" ]; then
        cp ".env" "${JOB_DIR}/.env"
        chmod 0600 "${JOB_DIR}/.env"
    fi
fi

if [ "$AGENT" = "rdagent" ] && [ -d "third_party/rd-agent" ]; then
    cp -r "third_party/rd-agent" "${JOB_DIR}/rd-agent"
    if [ -f ".env" ]; then
        cp ".env" "${JOB_DIR}/.env"
        chmod 0600 "${JOB_DIR}/.env"
    fi
fi

# Copy agent-specific auth if present (e.g. for non-API agents)
if [ -f "agents/${AGENT}/auth.json" ]; then
    cp "agents/${AGENT}/auth.json" "${JOB_DIR}/.codex/auth.json"
fi
if [ -f "agents/${AGENT}/oauth_token" ]; then
    cp "agents/${AGENT}/oauth_token" "${JOB_DIR}/oauth_token"
fi

# Utils
with_huggingface_overlay() {
    local merged="$TMP_SUBDIR/merged_huggingface"
    local upper="$TMP_SUBDIR/upper_huggingface"
    local workdir="$TMP_SUBDIR/fuse_workdir"

    cleanup_huggingface_overlay() {
        local cleanup_status="${1:-$?}"
        trap - EXIT INT TERM
        fusermount -u "$merged" 2>/dev/null || fusermount3 -u "$merged" 2>/dev/null || true
        rm -rf "$merged" "$upper" "$workdir"
        return "$cleanup_status"
    }

    mkdir -p "$merged" "$upper" "$workdir"
    fuse-overlayfs -o "lowerdir=$HF_HOME,upperdir=$upper,workdir=$workdir" "$merged"

    trap 'cleanup_huggingface_overlay 130; exit 130' INT
    trap 'cleanup_huggingface_overlay 143; exit 143' TERM
    trap 'cleanup_huggingface_overlay $?' EXIT

    "$@"
    local exit_code=$?

    trap - EXIT INT TERM
    cleanup_huggingface_overlay "$exit_code"
    return $exit_code
}

with_record_the_time() {
    local begin=$(date --iso-8601=seconds)
    "$@"
    local exit_code=$?
    local end=$(date --iso-8601=seconds)
    
    local time_taken=$(( $(date --date="$end" +%s) - $(date --date="$begin" +%s) ))
    printf '%02d:%02d:%02d\n' \
        $(( time_taken / 3600 )) \
        $(( (time_taken % 3600) / 60 )) \
        $(( time_taken % 60 )) > "${EVAL_DIR}/time_taken.txt"
    
    return $exit_code
}

SOLVE_OUT="${EVAL_DIR}/solve_out.txt"

solve_task() {
    timeout --signal=TERM --kill-after=30s "$((NUM_HOURS * 60 + 5))m" \
    apptainer exec \
        --nv \
        -c \
        "${APPTAINER_CUDA_ENV[@]}" \
        "${NVIDIA_SMI_BIND_ARGS[@]}" \
        --env PATH="/root/.local/bin:/home/ben/.local/bin:$PATH" \
        --env HF_HOME="${HF_HOME_NEW}" \
        --env OPENAI_API_KEY="${OPENAI_API_KEY:-}" \
        --env OPENAI_BASE_URL="${OPENAI_BASE_URL:-}" \
        --env OPENAI_API_BASE="${OPENAI_API_BASE:-}" \
        --env ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY}" \
        --env CODEX_API_KEY="${CODEX_API_KEY}" \
        --env GEMINI_API_KEY="${GEMINI_API_KEY}" \
        --env OPENCODE_API_KEY="${OPENCODE_API_KEY}" \
        --env DASHSCOPE_API_KEY="${DASHSCOPE_API_KEY}" \
        --env ZAI_API_KEY="${ZAI_API_KEY}" \
        --env HF_TOKEN="${HF_TOKEN:-}" \
        --env GITHUB_TOKEN="${GITHUB_TOKEN:-}" \
        --env ML_INTERN_MODEL="${ML_INTERN_MODEL:-}" \
        --env ML_INTERN_MAX_ITERATIONS="${ML_INTERN_MAX_ITERATIONS:-}" \
        --env ML_MASTER_CODE_MODEL="${ML_MASTER_CODE_MODEL:-}" \
        --env ML_MASTER_CODE_BASE_URL="${ML_MASTER_CODE_BASE_URL:-}" \
        --env ML_MASTER_CODE_API_KEY="${ML_MASTER_CODE_API_KEY:-}" \
        --env ML_MASTER_FEEDBACK_MODEL="${ML_MASTER_FEEDBACK_MODEL:-}" \
        --env ML_MASTER_FEEDBACK_BASE_URL="${ML_MASTER_FEEDBACK_BASE_URL:-}" \
        --env ML_MASTER_FEEDBACK_API_KEY="${ML_MASTER_FEEDBACK_API_KEY:-}" \
        --env ML_MASTER_STEPS="${ML_MASTER_STEPS:-}" \
        --env ML_MASTER_TIME_LIMIT_SECS="${ML_MASTER_TIME_LIMIT_SECS:-}" \
        --env ML_MASTER_EXEC_TIMEOUT_SECS="${ML_MASTER_EXEC_TIMEOUT_SECS:-}" \
        --env ML_MASTER_PARALLEL_SEARCH_NUM="${ML_MASTER_PARALLEL_SEARCH_NUM:-}" \
        --env ML_MASTER_CPU_NUMBER="${ML_MASTER_CPU_NUMBER:-}" \
        --env ML_MASTER_NUM_DRAFTS="${ML_MASTER_NUM_DRAFTS:-}" \
        --env ML_MASTER_NUM_IMPROVES="${ML_MASTER_NUM_IMPROVES:-}" \
        --env ML_MASTER_NUM_BUGS="${ML_MASTER_NUM_BUGS:-}" \
        --env RD_AGENT_MODE="${RD_AGENT_MODE:-}" \
        --env RD_AGENT_TIMEOUT="${RD_AGENT_TIMEOUT:-}" \
        --env RD_AGENT_LOOP_N="${RD_AGENT_LOOP_N:-}" \
        --env RD_AGENT_STEP_N="${RD_AGENT_STEP_N:-}" \
        --env RD_AGENT_EMBEDDING_MODEL="${RD_AGENT_EMBEDDING_MODEL:-}" \
        --env VLLM_API_KEY="inspectai" \
        --env PYTHONNOUSERSITE="1" \
        --env TMPDIR="/tmp" \
        --env PYTHONPATH="${CONTAINER_PYTHON_SHIM_DIR}:${PYTHONPATH:-}" \
        --env NUM_GPUS="${NUM_GPUS}" \
        --env POST_TRAIN_BENCH_REQUIRED_GPU_NAME="${POST_TRAIN_BENCH_REQUIRED_GPU_NAME:-H100}" \
        --env AGENT_CONFIG="${AGENT_CONFIG}" \
        --env EVALUATION_TASK="${EVALUATION_TASK}" \
        --env MODEL_TO_TRAIN="${MODEL_TO_TRAIN}" \
        --env NUM_HOURS="${NUM_HOURS}" \
        --bind "${JOB_TMP}:/tmp" \
        --bind "${HF_MERGED}:${HF_HOME_NEW}" \
        --home "${JOB_DIR}:/home/ben" \
        --pwd "/home/ben/task" \
        --writable-tmpfs \
        "${POST_TRAIN_BENCH_CONTAINERS_DIR}/${POST_TRAIN_BENCH_CONTAINER_NAME}.sif" \
        bash -c "{ export PROMPT=\"\$(cat /home/ben/prompt.txt)\"; python /home/ben/check_cuda.py && python /home/ben/check_cuda_writing.py || exit 1; bash /home/ben/system_monitor.sh & MONITOR_PID=\$!; bash /home/ben/agent_solve.sh; kill \$MONITOR_PID 2>/dev/null; } 2>&1 | python /home/ben/timestamp_lines.py" > "${SOLVE_OUT}" 2>&1
}

echo "================================"
echo "========= RUNNING TASK ========="
echo "================================"

with_huggingface_overlay with_record_the_time solve_task
SOLVE_EXIT=$?

echo "--- SOLVE DIAGNOSTICS ---"
echo "exit_code: $SOLVE_EXIT"
if [ $SOLVE_EXIT -eq 0 ]; then
    echo "status: exited normally"
elif [ $SOLVE_EXIT -eq 124 ]; then
    echo "status: killed by timeout (reached ${NUM_HOURS}h limit)"
elif [ $SOLVE_EXIT -gt 128 ]; then
    echo "status: killed by signal $((SOLVE_EXIT - 128)) ($(kill -l $((SOLVE_EXIT - 128)) 2>/dev/null || echo unknown))"
else
    echo "status: exited with error code $SOLVE_EXIT"
fi
echo "final_model_files: $(ls "${JOB_DIR}/task/final_model/" 2>/dev/null | wc -l)"
echo "hostname: $(hostname)"
echo "fuse_overlayfs_alive: $(ps aux 2>/dev/null | grep fuse-overlay | grep -v grep | wc -l)"
echo "disk_job_dir: $(du -sh "${JOB_DIR}" 2>/dev/null | cut -f1)"
echo "disk_tmp: $(du -sh "${JOB_TMP}" 2>/dev/null | cut -f1)"
echo "memory: $(free -m 2>/dev/null | grep Mem | awk '{print "total=" $2 "MB used=" $3 "MB free=" $4 "MB"}')"
echo "--- END SOLVE DIAGNOSTICS ---"

if [ "$SOLVE_EXIT" -ne 0 ]; then
    echo "ERROR: solve step failed; stopping before judge/evaluation."
    exit "$SOLVE_EXIT"
fi

if [ ! -d "${JOB_DIR}/task/final_model" ] || [ "$(find "${JOB_DIR}/task/final_model" -mindepth 1 -print -quit 2>/dev/null | wc -l)" -eq 0 ]; then
    echo "ERROR: solve step did not produce final_model; stopping before judge/evaluation."
    exit 1
fi

echo "============================================"
echo "=== TASK COMPLETE, PARSING AGENT TRACE ==="
echo "============================================"

# Parse agent trace into human-readable format
TRACE_PARSER="agents/${AGENT}/human_readable_trace.py"
if [ -f "$TRACE_PARSER" ]; then
    python "$TRACE_PARSER" "${SOLVE_OUT}" -o "${EVAL_DIR}/solve_parsed.txt"
    cp "${EVAL_DIR}/solve_parsed.txt" "${JOB_DIR}/solve_parsed.txt"
else
    echo "Warning: No trace parser found at $TRACE_PARSER, using raw output"
    cp "${SOLVE_OUT}" "${JOB_DIR}/solve_parsed.txt"
fi

echo "========================================="
echo "=== RUNNING CONTAMINATION JUDGE ==="
echo "========================================="

JUDGE_PROMPT="${POST_TRAIN_BENCH_JUDGE_PROMPT:-prompt}"
echo "Judge prompt: ${JUDGE_PROMPT}"
JUDGE_TASK=$(python src/disallowed_usage_judge/get_judge_prompt.py --benchmark "${BENCHMARK}" --model "${MODEL_TO_TRAIN}" --prompt "${JUDGE_PROMPT}")
JUDGE_MODEL="${POST_TRAIN_BENCH_JUDGE_MODEL:-gpt-5.5}"
echo "Judge model: ${JUDGE_MODEL}"

# Reset codex config to prevent agent-specific settings (e.g. model_reasoning_effort)
# from leaking into the judge, which uses a different model
cp -r "containers/other_home_data/.codex" "${JOB_DIR}/"
copy_host_codex_auth
force_codex_chatgpt_auth

with_huggingface_overlay apptainer exec \
    --nv \
    -c \
    "${APPTAINER_CUDA_ENV[@]}" \
    "${NVIDIA_SMI_BIND_ARGS[@]}" \
    --env PATH="/root/.local/bin:/home/ben/.local/bin:$PATH" \
    --env HF_HOME="${HF_HOME_NEW}" \
    --env CODEX_API_KEY="" \
    --env OPENAI_API_KEY="" \
    --env VLLM_API_KEY="inspectai" \
    --env PYTHONNOUSERSITE="1" \
    --env TMPDIR="/tmp" \
    --env PYTHONPATH="${CONTAINER_PYTHON_SHIM_DIR}:${PYTHONPATH:-}" \
    --bind "${JOB_TMP}:/tmp" \
    --bind "${HF_MERGED}:${HF_HOME_NEW}" \
    --home "${JOB_DIR}:/home/ben" \
    --pwd "/home/ben/task" \
    --writable-tmpfs \
    ${POST_TRAIN_BENCH_CONTAINERS_DIR}/${POST_TRAIN_BENCH_CONTAINER_NAME}.sif codex --search -a never exec --json -c model_reasoning_summary=detailed --skip-git-repo-check --yolo --model "${JUDGE_MODEL}" "$JUDGE_TASK" 2>&1 | tee "${EVAL_DIR}/judge_output.json"

# Convert judge JSON output to human-readable format
python agents/codex/human_readable_trace.py "${EVAL_DIR}/judge_output.json" -o "${EVAL_DIR}/judge_output.txt"

if [ ! -f "${JOB_DIR}/task/contamination_judgement.txt" ] || [ ! -f "${JOB_DIR}/task/disallowed_model_judgement.txt" ]; then
    echo "ERROR: contamination judge did not produce required judgement files."
    exit 1
fi

cp "${JOB_DIR}/task/contamination_judgement.txt" "${EVAL_DIR}/contamination_judgement.txt"
cp "${JOB_DIR}/task/disallowed_model_judgement.txt" "${EVAL_DIR}/disallowed_model_judgement.txt"

echo "============================="
echo "======== CLEANING UP ========"
echo "============================="

echo "Task directory contents:"
if command -v tree >/dev/null 2>&1; then
    tree "${JOB_DIR}/task"
else
    find "${JOB_DIR}/task" -maxdepth 3 -print
fi
echo "================================"

if [ -d "${JOB_DIR}/task/final_model" ]; then
    cp -r "${JOB_DIR}/task/final_model" "$EVAL_DIR/final_model"
fi

if [ -f "${JOB_DIR}/task/system_monitor.log" ]; then
    cp "${JOB_DIR}/task/system_monitor.log" "$EVAL_DIR/system_monitor.log"
fi

python containers/delete_hf_models.py "${JOB_DIR}/task"

cp -r "${JOB_DIR}/task" "$EVAL_DIR/task"
refresh_workspace_symlink "../task"

rm -rf /tmp/posttrain_container

echo "================================"
echo "========= EVALUATING ==========="
echo "================================"

export REPO_ROOT="$(pwd)"

export TMP_HF_CACHE="/tmp/hf_cache_90afd0"
EVAL_CONTAINER_PATH="${POST_TRAIN_BENCH_CONTAINERS_DIR}/${POST_TRAIN_BENCH_EVAL_CONTAINER_NAME:-vllm_debug}.sif"
if [ ! -f "$EVAL_CONTAINER_PATH" ]; then
    echo "WARNING: evaluation container $EVAL_CONTAINER_PATH not found; using ${POST_TRAIN_BENCH_CONTAINER_NAME}.sif"
    EVAL_CONTAINER_PATH="${POST_TRAIN_BENCH_CONTAINERS_DIR}/${POST_TRAIN_BENCH_CONTAINER_NAME}.sif"
fi
export EVAL_CONTAINER_PATH

export EVAL_COUNTER=0

run_evaluation() {
    local max_tokens_arg="$1"
    local eval_num="$2"
    local apptainer_cuda_env=()
    if [ -n "${CUDA_DEVICE_IDX:-}" ]; then
        apptainer_cuda_env=(
            --env CUDA_DEVICE_IDX="${CUDA_DEVICE_IDX}"
            --env CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-$CUDA_DEVICE_IDX}"
            --env CUDA_DEVICE_ORDER="${CUDA_DEVICE_ORDER:-PCI_BUS_ID}"
            --env NVIDIA_VISIBLE_DEVICES="${NVIDIA_VISIBLE_DEVICES:-${CUDA_VISIBLE_DEVICES:-$CUDA_DEVICE_IDX}}"
            --env POST_TRAIN_BENCH_ASSIGNED_CUDA_VISIBLE_DEVICES="${POST_TRAIN_BENCH_ASSIGNED_CUDA_VISIBLE_DEVICES:-${CUDA_VISIBLE_DEVICES:-$CUDA_DEVICE_IDX}}"
        )
    fi

    local nvidia_smi_id="${CUDA_VISIBLE_DEVICES:-${CUDA_DEVICE_IDX:-}}"
    if [ -n "$nvidia_smi_id" ]; then
        nvidia-smi --id="$nvidia_smi_id" --query-compute-apps=pid --format=csv,noheader |
            while read -r pid; do
                [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null || true
            done
    fi
    sleep 5
    with_huggingface_overlay apptainer exec \
        --nv \
        "${apptainer_cuda_env[@]}" \
        --env "HF_HOME=${TMP_HF_CACHE}" \
        --env OPENAI_API_KEY="${OPENAI_API_KEY}" \
        --env VLLM_API_KEY="inspectai" \
        --env PYTHONNOUSERSITE="1" \
        --env TMPDIR="/tmp" \
        --env PYTHONPATH="/opt/posttrain_python_shims:${PYTHONPATH:-}" \
        --writable-tmpfs \
        --bind "${PYTHON_SHIM_DIR}:/opt/posttrain_python_shims:ro" \
        --bind "${REPO_ROOT}:${REPO_ROOT}" \
        --bind "${HF_MERGED}:${TMP_HF_CACHE}" \
        --pwd "$(pwd)/src/eval/tasks/${EVALUATION_TASK}" \
        "$EVAL_CONTAINER_PATH" python "evaluate.py" \
            --model-path "$EVAL_DIR/final_model" \
            --templates-dir ../../../../src/eval/templates \
            --limit -1 \
            ${max_tokens_arg} \
            --json-output-file "${EVAL_DIR}/metrics.json" > "$EVAL_DIR/final_eval_${eval_num}.txt"
}

run_evaluation_with_retry() {
    local max_retries="$1"
    local max_tokens_arg="$2"

    for ((attempt=1; attempt<=max_retries; attempt++)); do
        sleep 5
        if [ -f "${EVAL_DIR}/metrics.json" ]; then
            return 0
        fi

        EVAL_COUNTER=$((EVAL_COUNTER + 1))
        export EVAL_COUNTER
        echo "Evaluation attempt $EVAL_COUNTER (phase attempt $attempt of $max_retries)"

        timeout --signal=TERM --kill-after=60s 28800s bash -c "$(declare -f run_evaluation with_huggingface_overlay); run_evaluation \"$max_tokens_arg\" \"$EVAL_COUNTER\""

        if [ -f "${EVAL_DIR}/metrics.json" ]; then
            return 0
        fi
    done

    return 1
}

# First evaluation: up to 4 attempts
run_evaluation_with_retry 4 ""

# Second evaluation with adjusted max tokens: up to 2 attempts
case "${EVALUATION_TASK}" in
    aime2025)
        MAX_TOKENS_ARG="--max-tokens 12000"
        ;;
    arenahardwriting)
        MAX_TOKENS_ARG="--max-new-tokens 12288"
        ;;
    bfcl)
        MAX_TOKENS_ARG="--max-tokens 12000"
        ;;
    gpqamain)
        MAX_TOKENS_ARG="--max-tokens 12000"
        ;;
    gsm8k)
        MAX_TOKENS_ARG="--max-tokens 3000"
        ;;
    healthbench)
        MAX_TOKENS_ARG="--max-new-tokens 12288"
        ;;
    humaneval)
        MAX_TOKENS_ARG="--max-tokens 3000"
        ;;
    *)
        MAX_TOKENS_ARG=""
        ;;
esac

run_evaluation_with_retry 3 "$MAX_TOKENS_ARG"

# Third evaluation with further adjusted max tokens: up to 2 attempts
case "${EVALUATION_TASK}" in
    aime2025)
        MAX_TOKENS_ARG="--max-tokens 8000"
        ;;
    arenahardwriting)
        MAX_TOKENS_ARG="--max-new-tokens 8192"
        ;;
    bfcl)
        MAX_TOKENS_ARG="--max-tokens 8000"
        ;;
    gpqamain)
        MAX_TOKENS_ARG="--max-tokens 8000"
        ;;
    gsm8k)
        MAX_TOKENS_ARG="--max-tokens 2000"
        ;;
    healthbench)
        MAX_TOKENS_ARG="--max-new-tokens 8192"
        ;;
    humaneval)
        MAX_TOKENS_ARG="--max-tokens 2000"
        ;;
    *)
        MAX_TOKENS_ARG=""
        ;;
esac

run_evaluation_with_retry 2 "$MAX_TOKENS_ARG"

if [ ! -f "${EVAL_DIR}/metrics.json" ]; then
    echo "ERROR: evaluation failed to produce metrics.json after all retries."
    exit 1
fi

echo $(cat "$EVAL_DIR/final_eval_${EVAL_COUNTER}.txt")

echo "================================"
echo "======= EVALUATION DONE ========"
echo "================================"
