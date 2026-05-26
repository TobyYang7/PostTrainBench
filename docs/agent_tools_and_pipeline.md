# Agent 工具与 Pipeline 说明

本文档说明当前 PostTrainBench 中 agent 在任务运行时能使用哪些工具、有哪些权限边界，以及从提交任务到产出最终 `metrics.json` 的完整流程。

## 运行环境

每个任务都在 Apptainer 容器中运行，默认容器是：

```text
containers/standard.sif
```

容器内 agent 的工作目录是：

```text
/home/ben/task
```

宿主机上的单次运行临时目录格式是：

```text
/tmp/posttrain_container_<task>_<model>_<uuid>/
```

宿主机上的结果目录格式是：

```text
results/<agent>_<agent_config>_<hours>h<experiment>/<task>_<model>_<run_id>/
```

任务开始前，pipeline 会把下面这些文件复制到 `/home/ben/task`：

- `evaluate.py`
- `templates/`
- 可选的 `evaluation_code/`
- 可选的 `task_context/`
- `timer.sh`
- `agent_solve.sh`

agent 最终必须把提交模型写到：

```text
/home/ben/task/final_model
```

## Agent 可用工具

容器里包含常见开发工具：

- `bash`
- `python`
- `git`
- `curl`
- `wget`
- build tools
- `nvidia-smi`
- `uv`
- Node.js
- npm 安装的 AI CLI 工具

主要 Python / ML 包包括：

- `torch`，通过 `vllm` 依赖提供
- `vllm`
- `transformers`
- `datasets`
- `accelerate`
- `peft`
- `trl`
- `bitsandbytes`
- `tokenizers`
- `evaluate`
- `inspect-ai`
- `lm-eval`
- `pandas`
- `scikit-learn`
- `openai`
- `tiktoken`
- `matplotlib`
- `flash_attn`

agent 可以读写当前任务目录 `/home/ben/task` 下的文件，也可以使用 `/tmp` 作为临时 scratch 空间。

Hugging Face cache 通过下面这个环境变量访问：

```text
$HF_HOME
```

容器内 `$HF_HOME` 会挂载到：

```text
/home/ben/hf_cache
```

它实际是一个 `fuse-overlayfs` overlay：

- lowerdir：宿主机用户的 Hugging Face cache
- upperdir：本次 run 的 `/tmp/posttrain_container_.../upper_huggingface`
- merged dir：本次 run 的 `/tmp/posttrain_container_.../merged_huggingface`

这样 agent 可以使用 HF cache，但不会直接污染宿主机原始 cache。

## Skill / Plugin 情况

当前 benchmark task 不会额外挂载 Codex skills、MCP tools 或 plugin manifests。

agent 能用的能力来自：

- 对应 CLI 自带能力
- shell
- Python 环境
- `/home/ben/task` 中的文件
- 容器内已安装的系统工具和 Python 包

例如：

- Codex agent 使用 Codex CLI 的原生工具能力
- Claude agent 使用 Claude Code 的原生工具能力
- Gemini agent 使用 Gemini CLI 的原生工具能力
- OpenCode agent 使用 OpenCode 的原生工具能力

repo 里没有给 benchmark task 注入额外的 skill 系统。

## Agent 类型

agent 由 `AGENT` 参数选择，对应启动脚本位于：

```text
agents/<agent>/solve.sh
```

常见 agent 如下：

| Agent | 后端 CLI | 认证方式 | 说明 |
| --- | --- | --- | --- |
| `codex` | `codex` | API key | 使用 `codex --search exec --json --yolo`。 |
| `codexlow` | `codex` | API key | 设置 `model_reasoning_effort = "low"`。 |
| `codexhigh` | `codex` | API key | 设置 `model_reasoning_effort = "high"`。 |
| `codex_non_api` | `codex` | ChatGPT auth | 清空 API key，强制 `forced_login_method = "chatgpt"`。 |
| `codex_non_api_high` | `codex` | ChatGPT auth | 非 API Codex，高 reasoning effort。 |
| `codex_non_api_xhigh` | `codex` | ChatGPT auth | 非 API Codex，xhigh reasoning effort。 |
| `codex_non_api_*_reprompt` | `codex` | ChatGPT auth | 如果 agent 提前结束且剩余时间超过 30 分钟，会 resume 继续跑。 |
| `claude` | `claude` | API key | 使用 Claude Code，带 `--dangerously-skip-permissions`。 |
| `claude_non_api` | `claude` | OAuth token | 使用 `/home/ben/oauth_token`，effort high。 |
| `claude_non_api_max` | `claude` | OAuth token | 使用 max effort。 |
| `gemini` | `gemini` | Gemini key | 使用 Gemini CLI，`--yolo`，`GEMINI_SANDBOX=false`。 |
| `opencode` | `opencode` | provider config | 写入 `opencode.json`，权限设为 allow。 |
| `qwen3max` | `claude` | DashScope key | Claude Code 连接 Qwen Anthropic-compatible endpoint。 |
| `glm5` | `claude` | Z.AI key | Claude Code 连接 Z.AI Anthropic-compatible endpoint。 |
| `ml_intern` | `ml-intern` | `.env` / API key | 使用干净 upstream `huggingface/ml-intern` loop，读取 `.env` 中的 API key，并执行当前 PostTrainBench prompt。 |
| `rdagent` | `rdagent` | `.env` / API key | 本地化的 RD-Agent post-training wrapper，支持 `RD_AGENT_MODE=sft|rl`，默认 `sft`。 |
| `ml_master` | `ML-Master` | `.env` / API key | 使用适配后的 upstream `sjtu-sai-agents/ML-Master` 搜索 loop，在隔离 workspace 中运行 PostTrainBench 任务，并把最佳 `final_model` 回拷到基准目录。 |

`ml_intern` 的接入细节见 `docs/ml_intern_agent.md`。

大多数 agent 都关闭了 CLI 层面的交互确认，例如：

- `--yolo`
- `--dangerously-skip-permissions`
- OpenCode 的 `"permission": "allow"`

这只是不再询问 CLI 操作确认，不代表绕过 OS / 容器权限。

## Task Prompt 约束

task prompt 由下面脚本生成：

```text
src/eval/general/get_prompt.py
```

模板文件由 `POST_TRAIN_BENCH_PROMPT` 选择：

```text
src/eval/general/<POST_TRAIN_BENCH_PROMPT>.txt
```

当前可用模板：

- `prompt1` / `src/eval/general/prompt1.txt`：默认模板，保留原有自动研究指令。
- `prompt2` / `src/eval/general/prompt2.txt`：假设驱动模板，要求 agent 先提出具体假设，再设计实验验证或证伪方法。

默认值是：

```text
POST_TRAIN_BENCH_PROMPT=prompt1
```

当前 prompt 明确要求 agent：

- 不使用 `sudo`
- 不使用 `apt`、`apt-get`、`dnf`、`yum` 等系统包管理器
- 避免安装额外 Python 包
- 如果实验确实需要额外包，只能安装到当前工作目录下的本地目录
- `final_model` 不能依赖新增包
- 不修改 `CUDA_VISIBLE_DEVICES`
- 使用容器内可见的 CUDA id，例如 `cuda:0`
- 不根据 `nvidia-smi` 里看到的宿主机 GPU id 自行切换 GPU
- 代码、数据、checkpoint、日志都写在当前目录下
- `/tmp` 只用于临时 scratch 文件
- 使用 `$HF_HOME` 访问 Hugging Face cache
- 不写 `/usr`、`/opt`、`/var` 或 global site-packages
- 不修改 `evaluate.py` 或 `templates/`
- 不使用 benchmark test data 训练
- 只能 fine-tune 指定 base model，或从该 base model 训练出来的 student-created derivative

这些限制是为了减少无权限错误、不可复现依赖、错误 GPU 选择和数据污染。

## GPU 处理

local run 中：

```text
run1.sh -> CUDA_DEVICE_IDX=6
run2.sh -> CUDA_DEVICE_IDX=7
```

`src/run_task.sh` 会把 GPU 相关环境变量传进容器：

- `CUDA_DEVICE_IDX`
- `CUDA_VISIBLE_DEVICES`
- `CUDA_DEVICE_ORDER=PCI_BUS_ID`
- `NVIDIA_VISIBLE_DEVICES`
- `POST_TRAIN_BENCH_ASSIGNED_CUDA_VISIBLE_DEVICES`

在容器内，指定的物理 GPU 会作为 Python 可见的 `cuda:0` 出现。

例如 `CUDA_DEVICE_IDX=6` 时，agent 应使用：

```python
device = "cuda:0"
```

而不是：

```python
device = "cuda:6"
```

### `nvidia-smi` wrapper

为了防止 agent 先运行 `nvidia-smi`，看到宿主机所有 GPU 后自行选择错误 GPU，pipeline 会创建一个 `nvidia-smi` wrapper，并 bind 覆盖容器内：

```text
/usr/bin/nvidia-smi
```

wrapper 的效果：

- 默认 `nvidia-smi` 只显示被分配的 GPU
- `nvidia-smi --id=0` 会映射到真实分配的物理 GPU
- 例如 `CUDA_DEVICE_IDX=6` 时，`--id=0` 会映射到 host GPU 6

这是 local 模式下的实用防护。真正强隔离 GPU 仍应由 scheduler、cgroup、Docker GPU device 或集群资源系统提供。

## 提交流程

local 常用入口：

```bash
./run1.sh
./run2.sh
```

这两个脚本会设置：

- `POST_TRAIN_BENCH_JOB_SCHEDULER=local`
- `CUDA_DEVICE_IDX`
- `POST_TRAIN_BENCH_REQUIRED_GPU_NAME=H20`
- `POST_TRAIN_BENCH_EXPERIMENT_NAME`
- `POST_TRAIN_BENCH_PROMPT`
- `POST_TRAIN_BENCH_JUDGE_PROMPT`
- `POST_TRAIN_BENCH_JUDGE_MODEL=gpt-5.5`

其中：

- `run1.sh` 使用 `POST_TRAIN_BENCH_PROMPT=prompt1` 和 GPU 6。
- `run2.sh` 使用 `POST_TRAIN_BENCH_PROMPT=prompt2` 和 GPU 7。
- `run.sh` 是兼容入口，等价于执行 `run1.sh`。

然后调用：

```text
src/commit_utils/commit_codex.sh
```

当前 `commit_codex.sh` 默认选择：

- model：`Qwen/Qwen3-1.7B-Base`
- benchmark：`aime2025`
- agent：`codex_non_api_high`
- agent config：`gpt-5.5`
- 默认运行时间：`10` 小时

local 模式下最终调用：

```text
src/run_task.sh <eval> <agent> <model> <run_id> <num_hours> <agent_config> <num_gpus> <cuda_device_idx>
```

HTCondor 模式使用：

```text
src/commit_utils/single_task.sub
```

它会请求 GPU、CPU、内存、磁盘，并传入同样的 `run_task.sh` 参数。

## 主 Pipeline

主调度脚本是：

```text
src/run_task.sh
```

### 1. 初始化路径

脚本会创建：

- `EVAL_DIR`
- `TMP_SUBDIR`
- `JOB_DIR`
- `JOB_TMP`
- `HF_MERGED`

stdout 和 stderr 分别重定向到：

```text
output.log
error.log
```

### 2. 准备任务目录

pipeline 会把 benchmark 相关文件复制到：

```text
$JOB_DIR/task
```

还会复制或创建：

- `containers/other_home_data/.codex`
- local Codex auth
- local Codex binary
- Python compatibility shim
- `check_cuda.py`
- `check_cuda_writing.py`
- `system_monitor.sh`
- `timestamp_lines.py`
- `agents/<agent>/solve.sh`，复制为 `agent_solve.sh`

### 3. 生成 task prompt

benchmark 名称来自：

```text
src/eval/tasks/<task>/benchmark.txt
```

然后通过 `get_prompt.py` 生成完整 prompt。

prompt 会写入：

```text
$EVAL_DIR/prompt.txt
```

### 4. 启动 Hugging Face overlay

agent 运行前会启动 `fuse-overlayfs`：

```text
lowerdir = $HF_HOME
upperdir = $TMP_SUBDIR/upper_huggingface
workdir  = $TMP_SUBDIR/fuse_workdir
mount    = $TMP_SUBDIR/merged_huggingface
```

merged cache 会挂载到容器内：

```text
/home/ben/hf_cache
```

清理时会先卸载 overlay，再用 `rm -rf` 删除：

- `merged_huggingface`
- `upper_huggingface`
- `fuse_workdir`

### 5. 运行 agent

agent 通过下面形式启动：

```text
apptainer exec --nv -c --writable-tmpfs
```

容器挂载：

- home：`$JOB_DIR:/home/ben`
- 工作目录：`/home/ben/task`
- tmp：`$JOB_TMP:/tmp`
- HF cache：`$HF_MERGED:/home/ben/hf_cache`

执行顺序：

```bash
python /home/ben/check_cuda.py &&
python /home/ben/check_cuda_writing.py ||
exit 1
bash /home/ben/system_monitor.sh &
bash /home/ben/agent_solve.sh
```

agent 输出会 timestamp 后写入：

```text
$EVAL_DIR/solve_out.txt
```

solve 阶段总超时为：

```text
NUM_HOURS * 60 + 5 minutes
```

### 6. 检查 solve 结果

agent 退出后会记录：

- exit code
- `final_model` 文件数量
- hostname
- 是否还有 `fuse-overlayfs`
- task 目录磁盘使用量
- `/tmp` 使用量
- 内存情况

如果出现下面任意情况，pipeline 会在 judge/evaluation 前失败：

- solve exit code 非 0
- `final_model/` 不存在
- `final_model/` 为空

### 7. 解析 agent trace

如果存在：

```text
agents/<agent>/human_readable_trace.py
```

pipeline 会生成：

```text
$EVAL_DIR/solve_parsed.txt
```

如果没有 parser，则复制 raw output。

### 8. 运行 judge

judge prompt 由下面脚本生成：

```text
src/disallowed_usage_judge/get_judge_prompt.py
```

prompt 选择由环境变量控制：

```text
POST_TRAIN_BENCH_JUDGE_PROMPT
```

支持：

- `prompt` / `prompt.txt`：默认 judge prompt，原始简短版本。
- 直接路径

默认是：

```text
prompt
```

judge model 由环境变量控制：

```text
POST_TRAIN_BENCH_JUDGE_MODEL
```

默认是：

```text
gpt-5.5
```

judge 在同一个 task 目录中运行，必须输出：

```text
contamination_judgement.txt
disallowed_model_judgement.txt
```

当前默认 judge prompt 保持原始简短版本，不额外加入安装包、训练时长等执行约束。

### 9. 复制 artifacts

judge 完成后，pipeline 会复制：

- `final_model/` 到 `$EVAL_DIR/final_model`
- `system_monitor.log`
- 清理后的 task 目录到 `$EVAL_DIR/task`

复制 task 目录前会执行：

```text
containers/delete_hf_models.py
```

用于删除 task 目录里的大型 Hugging Face 模型缓存，避免结果目录过大。

### 10. 最终 evaluation

最终评估使用：

```text
$EVAL_DIR/final_model
```

评估容器优先使用：

```text
POST_TRAIN_BENCH_EVAL_CONTAINER_NAME
```

否则使用：

```text
vllm_debug.sif
```

如果 eval container 不存在，会 fallback 到主容器。

评估脚本是：

```text
src/eval/tasks/<task>/evaluate.py
```

调用参数包括：

```text
--model-path $EVAL_DIR/final_model
--templates-dir ../../../../src/eval/templates
--limit -1
--json-output-file $EVAL_DIR/metrics.json
```

evaluation 分阶段重试：

1. 默认生成参数，最多 4 次
2. task-specific 调整 token limit，最多 3 次
3. 进一步 fallback token limit，最多 2 次

如果最终仍没有生成：

```text
metrics.json
```

则 run 失败。

## 输出文件

每个结果目录中常见文件：

| 文件 | 含义 |
| --- | --- |
| `prompt.txt` | 发给 agent 的任务 prompt |
| `solve_out.txt` | 原始 timestamped agent 输出 |
| `solve_parsed.txt` | 解析后的 human-readable trace |
| `time_taken.txt` | solve 阶段耗时 |
| `judge_output.json` | judge 原始 trace |
| `judge_output.txt` | judge human-readable trace |
| `contamination_judgement.txt` | 数据污染判定 |
| `disallowed_model_judgement.txt` | 非允许模型使用判定 |
| `final_model/` | 从 task 目录复制出的最终模型 |
| `task/` | 清理后的任务工作目录归档 |
| `system_monitor.log` | GPU / CPU / 内存 / 磁盘监控 |
| `final_eval_<n>.txt` | evaluation 文本输出 |
| `metrics.json` | 最终评估指标 |
| `output.log` | pipeline stdout |
| `error.log` | pipeline stderr |

## 运维注意事项

- local 模式下的 `nvidia-smi` wrapper 是为了防止 agent 误选未分配 GPU。
- 真正强隔离 GPU 应由 scheduler、cgroup、Docker GPU device 或集群资源系统保证。
- 如果 run 被中断，`/tmp/posttrain_container_*` 可能残留。
- 删除 overlay 目录前，应先卸载 `merged_huggingface`。
- `upper_huggingface` 里可能出现 OverlayFS whiteout character device，这是正常现象。
- 清理 overlay upperdir 时应使用 `rm -rf`，不要用交互式 `rm -r`。
- HTCondor 的 `single_task.sub` 默认还是 H100-oriented。
- local H20 运行通过 `run1.sh` / `run2.sh` 设置 `POST_TRAIN_BENCH_REQUIRED_GPU_NAME=H20`。
- CLI 的 `--yolo` / `--dangerously-skip-permissions` 只关闭 agent CLI 交互确认，不代表可以绕过容器或系统权限。
