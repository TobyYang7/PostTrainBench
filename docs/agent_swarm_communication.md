# Agent Swarm 通信机制

本文档说明 Claude Code 在本仓库下做多 agent 协作（"swarm"）时，agent 之间究竟如何通信、context 怎么隔离、何时该触发。

> 这里的 "swarm" 指 Claude Code **`Agent` 工具**派出的子 agent 集合，不是 `claude-flow` CLI 的 daemon 模式。后者另见 `~/.claude/settings.json` 的 `ruflo-swarm` 插件配置。

## 一、三种通信通道

整个 swarm 只有三条数据通道，没有别的。理解清楚这三条，整个系统就透明了。

### 通道 1：派发时的 prompt（lead → child）

主对话（lead）调用 `Agent(prompt=..., subagent_type=..., name=..., run_in_background=true)` 时，`prompt` 字段是**单向、一次性**的"任务交付物"。子 agent 启动后看不到 lead 后续的消息，也看不到 lead 此前的对话历史——只有 prompt 里写进去的东西。

这意味着：

- prompt 必须**自包含**：把 agent 需要的所有上下文（要看的目录、限制、输出格式）一次性写齐
- 不要写 "根据我们刚才聊的"——子 agent 没有"刚才"
- prompt 里要写明**它要 SendMessage 给谁、消息怎么组织**（见通道 3）

### 通道 2：完成时的 result（child → lead）

子 agent 跑完之后，它的**最后一条文本消息**会作为 tool result 回到 lead 的 context。这是唯一从 child 返回 lead 的数据。

关键点：

- 中间过程（工具调用、思考、读了哪些文件）**不进入** lead 的 context，只有最后那条总结进入
- 这就是 swarm 节省主 context 的本质——子 agent 读 30 个文件，主 context 只看几百字总结
- prompt 里应明确要求 "在 X 字以内总结"，否则子 agent 可能返回过长导致浪费

### 通道 3：SendMessage（child ↔ child，可选）

如果 lead 在派发时给子 agent 起了 `name`，agent 之间可以通过 `SendMessage(to="other-name", summary="...", message="...")` **直接给彼此发消息**，不经过 lead。

适用场景：

- Pipeline 串联：A 跑完把产物推给 B，B 跑完推给 C
- Supervisor 协调：lead 让 worker 之间互相协调，自己只看最终结果

不需要的场景：

- 纯 fan-out（多个 agent 独立做不重叠的事）——直接 return 给 lead 就够了，不要画蛇添足

## 二、三种典型拓扑

### Fan-out（最常用）

```
        lead
       / | \
      A  B  C        ← 三个 agent 并行，不互相通信
       \ | /
        lead         ← 各自把 result 返回，lead 汇总
```

派发代码（lead 视角，一条消息里发 3 个 Agent 调用）：

```javascript
Agent({ prompt: "扫 X，<250 字总结",  subagent_type: "Explore", run_in_background: true })
Agent({ prompt: "扫 Y，<250 字总结",  subagent_type: "Explore", run_in_background: true })
Agent({ prompt: "扫 Z，<250 字总结",  subagent_type: "Explore", run_in_background: true })
```

适合：**独立可并行**的工作。本仓库的典型例子：调研多个 baseline agent 集成、并行扫多个 eval task 目录、给 N 个文件并行生成 README。

### Pipeline（串行接力，需要 SendMessage）

```
lead → researcher → architect → coder → tester → reviewer → lead
                  ↑           ↑       ↑        ↑
                  通过 SendMessage 接力
```

派发代码：

```javascript
// 一条消息里全部 spawn 好（agent 已就位等待）
Agent({ name: "researcher",
  prompt: "调研 X。完成后 SendMessage 给 'architect'，附 findings",
  run_in_background: true })
Agent({ name: "architect",
  prompt: "等 'researcher' 的消息。设计方案，SendMessage 给 'coder'",
  run_in_background: true })
Agent({ name: "coder",
  prompt: "等 'architect' 的方案。实现，SendMessage 给 'tester'",
  run_in_background: true })
// ...

// 单独一条 SendMessage 启动整条流水线
SendMessage({ to: "researcher", summary: "kick off", message: "任务描述..." })
```

适合：**有顺序依赖**的功能开发、跨模块重构。

### Supervisor（中心协调）

```
        lead (supervisor)
        ↕   ↕   ↕
       A    B   C    ← 各 worker 与 lead 双向通信
                       worker 之间不直接对话
```

适合：复杂调研需要 lead 看到中间产物后**动态分派**新任务。本仓库目前没有典型例子，一般不需要。

## 三、context 隔离 —— swarm 的核心收益

| 资源 | 主 context 消耗 |
|---|---|
| 子 agent 读了多少文件 | **不消耗** |
| 子 agent 跑了多少工具调用 | **不消耗** |
| 子 agent 的中间推理 | **不消耗** |
| 子 agent 的最终 result | 消耗（仅这一条）|

实测：[`docs/agent_tools_and_pipeline.md`](agent_tools_and_pipeline.md) 那个量级的调研，主对话直接做要吃 50k+ token；让 3 个子 agent fan-out 做，主对话只吃 ~2k。差 25 倍。

**反过来理解**：如果一个任务用主对话直接做 token 也不会超 5k，就**别用 swarm**——派发开销大于收益。

## 四、何时触发 swarm

按 `~/.claude/settings.json` 启用的 `ruflo-swarm` 插件，和 `/mnt/cpfs-01cde2b08bc90ffb/yzyang/ruflo-workspace/CLAUDE.md` 的路由表，标准是：

| 用 swarm | 不用 swarm |
|---|---|
| 3+ 文件改动 | 单文件 edit |
| 跨模块重构 | 1-2 行 fix |
| 新功能 / 架构调研 | 改文档、改配置 |
| 安全 / 性能审计 | 一次性问答 |

实际项目里，本仓库适合 swarm 的场景：

- 同时跑多个 baseline agent 的 dry-run / smoke test
- 并行调研 `src/eval/tasks/` 下多个 benchmark 的指标差异
- 审计 `scripts/htcondor/` 全部脚本的错误处理一致性
- 给四个 agent 集成（codex / ml_master / rdagent / gepa）同时生成对照表

## 五、触发方式

三种入口，门槛递增：

### 1. 自然语言（默认）

直接对 Claude Code 说"用 swarm 调研 X"或"并行让几个 agent 看一下 Y"。Claude 会按本节"何时触发"的标准自己判断要不要派 swarm、用哪种拓扑。

### 2. Slash command（半精确）

```text
/ruflo-swarm:swarm           初始化 + 监控 + 管理（一站式）
/ruflo-swarm:swarm-init      只初始化拓扑
/ruflo-swarm:watch           实时观察事件流
/ruflo-swarm:monitor-stream  Monitor 工具流式
```

后接任务描述，例：

```text
/ruflo-swarm:swarm 调研 src/eval/tasks/ 下七个 benchmark 的评测指标差异
```

### 3. claude-flow CLI（重，需 daemon）

需先 `cd` 到 [`/mnt/cpfs-01cde2b08bc90ffb/yzyang/ruflo-workspace`](/mnt/cpfs-01cde2b08bc90ffb/yzyang/ruflo-workspace)，因为 daemon 状态、`.claude-flow/sessions/` 都在那个目录。

```bash
npx @claude-flow/cli@latest daemon start          # 首次
npx @claude-flow/cli@latest swarm init \
    --topology hierarchical --max-agents 8 \
    --strategy specialized
```

带 memory / hooks / metrics 跨 session 持久化。**对一次性任务过重，平时别用**。

## 六、写 prompt 的注意事项

派给子 agent 的 prompt 应当：

1. **自包含**：交代清楚仓库路径、要看的目录、要避开的目录
2. **限定输出长度**：例如 "<250 字总结"、"列出条目即可，不要分析"
3. **指定格式**：要 markdown 表 / ASCII 图 / `file:line` 引用 / JSON
4. **告知它在 swarm 里的角色**：让它知道自己是 N 个并行 agent 之一，不要重复别人的工作
5. **写明下一步**：如果是 pipeline，明确写 "完成后 SendMessage 给 'X'"

反例（不要这样写）：

> "根据我们之前讨论的，看一下相关代码并给出建议"

正例：

> "你是 swarm 中的 researcher-A，扫 `agents/` 下四个 baseline agent 的 entrypoint。仓库根目录 /mnt/cpfs-01cde2b08bc90ffb/yzyang/PostTrainBench。报告 ≤250 字。格式：每个 agent 一段，包含 entrypoint `file:line`、调用方、third-party submodule。不要分析、只要 map。这是三个并行 agent 之一，别去碰 `src/eval/` 和 `scripts/htcondor/`。"

## 七、调试与排查

| 现象 | 可能原因 |
|---|---|
| 子 agent 报告 "找不到文件" | prompt 里给的路径是相对路径而非绝对路径 |
| 子 agent 返回的报告过长，主 context 暴涨 | prompt 没写字数限制 |
| 两个 agent 做了重复工作 | prompt 没写明各自范围、没说自己是 swarm 之一 |
| 子 agent 工作完一直不返回 | 让它跑了交互式命令；`Explore` subagent 类型只读，不会卡 |
| Pipeline 卡死 | 上游 agent 没正确 SendMessage 给下游；检查 prompt 里的 `to: "name"` 拼写 |

调试时优先用 `Explore` 子类型（只读、快），不会改文件。

## 相关资料

- 本仓库 swarm 演示出处：调研 `agents/`、`scripts/htcondor/`、`src/eval/` 三层架构
- 项目级 agent 协作规范：[`/mnt/cpfs-01cde2b08bc90ffb/yzyang/ruflo-workspace/CLAUDE.md`](/mnt/cpfs-01cde2b08bc90ffb/yzyang/ruflo-workspace/CLAUDE.md)
- 全局插件配置：`~/.claude/settings.json` 中 `enabledPlugins.ruflo-swarm@ruflo`
- Claude Code Agent 工具官方文档：https://docs.anthropic.com/en/docs/claude-code/sub-agents
