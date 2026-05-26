# `ml_intern` Agent 说明

`ml_intern` 使用干净的 upstream `huggingface/ml-intern`，不再使用 `ml_intern_codex` 或任何 Codex backend patch。

运行方式：

```text
src/run_task.sh
  -> copy third_party/ml-intern to /home/ben/ml-intern
  -> copy repo .env to /home/ben/.env
  -> bash /home/ben/agent_solve.sh
  -> agents/ml_intern/solve.sh
  -> source /home/ben/.env
  -> uv run --project /home/ben/ml-intern python -m agent.main --model <model> "$PROMPT"
```

也就是说，agent loop 是 upstream ml-intern 原生 loop：

```text
ContextManager -> LiteLLM model call -> parse tool_calls -> ToolRouter -> append tool results -> repeat
```

## PostTrainBench 接入流程图

```mermaid
flowchart TD
    A["提交入口<br/>run_gpu3_ml_intern_htcondor.sh"] --> B["设置运行环境<br/>CUDA_DEVICE_IDX=3<br/>POST_TRAIN_BENCH_AGENT=ml_intern<br/>POST_TRAIN_BENCH_AGENT_CONFIG=gpt-5.5"]
    B --> C["src/commit_utils/commit_codex.sh"]
    C --> D["src/run_task.sh"]

    D --> E["准备 job 目录<br/>/tmp/posttrain_container_.../job_dir"]
    E --> F["复制 benchmark 文件<br/>evaluate.py / templates / task_context"]
    E --> G["复制 third_party/ml-intern<br/>到 /home/ben/ml-intern"]
    E --> H["复制 repo .env<br/>到 /home/ben/.env"]
    E --> I["生成 bench prompt<br/>src/eval/general/get_prompt.py"]

    F --> J["进入 Apptainer 容器<br/>工作目录 /home/ben/task"]
    G --> J
    H --> J
    I --> J

    J --> K["bash /home/ben/agent_solve.sh"]
    K --> L["agents/ml_intern/solve.sh"]
    L --> M["source /home/ben/.env<br/>映射 HF_TOKEN<br/>规范化模型名"]
    M --> N["uv run --project /home/ben/ml-intern<br/>python -m agent.main --model &lt;model&gt; $PROMPT"]

    N --> O["ContextManager<br/>构建上下文"]
    O --> P["LiteLLM model call"]
    P --> Q{"是否产生 tool_calls?"}
    Q -- "是" --> R["parse tool_calls"]
    R --> S["ToolRouter 执行工具"]
    S --> T["append tool results"]
    T --> O
    Q -- "否 / 完成任务" --> U["在 /home/ben/task/final_model<br/>写出最终模型"]

    U --> V["返回 PostTrainBench pipeline"]
    V --> W["解析 trace / judge / evaluation"]
    W --> X["写入 results/...<br/>metrics.json / logs / artifacts"]
```

## ml-intern 源码 Framework

下面这张图按 `third_party/ml-intern` 的源码结构整理：

- CLI / headless 入口：`agent/main.py`
- agent 主循环：`agent/core/agent_loop.py`
- session 状态：`agent/core/session.py`
- 上下文管理：`agent/context_manager/manager.py`
- 工具注册与路由：`agent/core/tools.py`
- 本地工具：`agent/tools/local_tools.py`

PostTrainBench 通过 `python -m agent.main --model <model> "$PROMPT"` 走的是 headless 路径，因此 `headless_main()` 会创建一次性 submission，等待 agent 完成后退出。

```mermaid
flowchart TD
    A["agent/main.py::cli()"] --> B{"是否传入 prompt?"}
    B -- "是：PostTrainBench 路径" --> C["headless_main(prompt, model, stream=True)"]
    B -- "否：交互式 CLI" --> D["main(model)<br/>PromptSession 读取用户输入"]

    C --> E["load_config(CLI_CONFIG_PATH)<br/>headless 设置 yolo_mode=True"]
    D --> E
    E --> F["resolve_hf_token()<br/>加载 HF_TOKEN / provider key"]
    F --> G["NotificationGateway.start()"]
    G --> H["创建 queues<br/>submission_queue<br/>event_queue"]
    H --> I["ToolRouter(config.mcpServers,<br/>hf_token, local_mode)"]

    I --> I1["create_builtin_tools(local_mode)"]
    I1 --> I2{"tool_runtime"}
    I2 -- "local / 默认 CLI 配置" --> I3["local_tools<br/>bash / read / write / edit"]
    I2 -- "sandbox" --> I4["sandbox_tools<br/>sandbox_create + sandbox bash/read/write/edit"]
    I1 --> I5["研究与平台工具<br/>research / docs / papers / web_search<br/>dataset / plan / notify / hf_jobs<br/>hf_repo_files / hf_repo_git / GitHub tools"]
    I --> I6["FastMCP Client<br/>注册 MCP tools"]
    I --> I7["register_openapi_tool()"]

    I --> J["asyncio.create_task(submission_loop(...))"]
    J --> K["Session(...)"]
    K --> K1["ContextManager(...)"]
    K1 --> K2["加载 system_prompt_v3.yaml<br/>注入 tool_specs / date / HF user"]
    K --> K3["保存运行态<br/>config / tool_router / event_queue<br/>pending_approval / sandbox / plan<br/>cancel flag / autosave"]

    J --> L["async with ToolRouter"]
    L --> M["send_event('ready')"]
    C --> N["put USER_INPUT(prompt)<br/>进入 submission_queue"]
    D --> N
    M --> O["process_submission()"]
    N --> O
    O --> P["Handlers.run_agent(session, text)"]

    P --> P1["ContextManager.add_message(user)"]
    P1 --> Q["agentic loop<br/>直到无 tool_calls / 达到 max_iterations / error"]
    Q --> Q1["compaction 检查<br/>ContextManager.needs_compaction"]
    Q1 --> Q2["doom-loop / malformed tool recovery"]
    Q2 --> Q3["ContextManager.get_messages()<br/>patch dangling tool_calls"]
    Q3 --> Q4["ToolRouter.get_tool_specs_for_llm()"]
    Q4 --> R["_resolve_llm_params()<br/>模型参数 / reasoning_effort"]
    R --> S{"stream?"}
    S -- "是" --> T["_call_llm_streaming()<br/>litellm.acompletion(stream=True)"]
    S -- "否" --> U["_call_llm_non_streaming()<br/>litellm.acompletion(stream=False)"]

    T --> V["LLMResult<br/>content / tool_calls_acc<br/>token_count / usage<br/>thinking state"]
    U --> V
    V --> W{"是否有 tool_calls?"}

    W -- "否" --> X["记录 assistant message<br/>send_event('turn_complete')"]
    X --> Y["headless_main 收到 turn_complete<br/>发送 SHUTDOWN"]

    W -- "是" --> Z["解析 tool_calls<br/>json.loads(arguments)"]
    Z --> AA["记录 assistant tool_call message<br/>ContextManager.add_message()"]
    AA --> AB{"是否需要 approval?"}

    AB -- "不需要" --> AC["并发执行工具<br/>asyncio.gather(_exec_tool...)"]
    AC --> AD["ToolRouter.call_tool(name,args,session)"]
    AD --> AE{"工具来源"}
    AE -- "built-in handler" --> AF["直接调用 handler<br/>local/sandbox/research/HF/GitHub/..."]
    AE -- "MCP tool" --> AG["FastMCP client.call_tool()"]
    AF --> AH["返回 output, success"]
    AG --> AH
    AH --> AI["写入 tool message<br/>send_event('tool_output')"]
    AI --> Q

    AB -- "需要" --> AJ["send_event('approval_required')<br/>session.pending_approval=tool_calls"]
    AJ --> AK["headless_main 自动审批<br/>scheduled HF jobs 除外"]
    AK --> AL["put EXEC_APPROVAL"]
    AL --> AM["Handlers.exec_approval()"]
    AM --> AN["执行 approved tools<br/>拒绝 rejected tools"]
    AN --> AI

    Y --> AO["Handlers.shutdown()"]
    AO --> AP["save session traces<br/>teardown sandbox if needed<br/>send_event('shutdown')"]
```

核心循环可以简化为：

```text
submission_queue
  -> process_submission
  -> Handlers.run_agent
  -> ContextManager.get_messages + ToolRouter.get_tool_specs_for_llm
  -> LiteLLM acompletion
  -> parse tool_calls
  -> ToolRouter.call_tool
  -> append tool result messages
  -> repeat until no tool_calls
```

PostTrainBench 的 bench prompt 仍然来自 `src/eval/general/get_prompt.py`，通过 `$PROMPT` 原样传给 ml-intern。agent 仍需在 `/home/ben/task/final_model` 产出最终模型。

## API Key

`solve.sh` 会读取：

```text
/home/ben/.env
```

该文件由 `src/run_task.sh` 从 repo 根目录的 `.env` 复制进 job home。脚本不会打印 `.env` 内容。

如果 `.env` 中没有 `HF_TOKEN`，但有下面任意变量，会自动映射为 `HF_TOKEN`：

```text
HUGGING_FACE_HUB_TOKEN
BEN_HF_TOKEN
HARDIK_HF_TOKEN
```

## 模型名

默认使用提交时的 `AGENT_CONFIG`。如果传入裸模型名，例如：

```text
gpt-5.5
```

会自动转成 upstream ml-intern README 中的格式：

```text
openai/gpt-5.5
```

也可以直接传：

```text
anthropic/claude-opus-4-7
openai/gpt-5.5
ollama/llama3.1:8b
vllm/meta-llama/Llama-3.1-8B-Instruct
```

## GPU3 提交

脚本：

```bash
bash run_gpu3_ml_intern_htcondor.sh
```

关键环境变量：

```text
CUDA_DEVICE_IDX=3
POST_TRAIN_BENCH_AGENT=ml_intern
POST_TRAIN_BENCH_AGENT_CONFIG=gpt-5.5
POST_TRAIN_BENCH_EXPERIMENT_NAME=_prompt1_gpu3_ml_intern_htcondor
```
