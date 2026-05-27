# LiteLLM 本地代理与用量监控

本文档说明当前仓库如何通过本地 `LiteLLM` 代理转发 `OpenAI-compatible` 请求，并在 `LiteLLM` UI 中查看 API 用量。

## 当前接入方式

- 根目录 `.env` 里的 `OPENAI_API_KEY`、`OPENAI_BASE_URL`、`OPENAI_API_BASE` 已切到本地代理：
  - `OPENAI_API_KEY` 指向 `LITELLM_MASTER_KEY`
  - `OPENAI_BASE_URL` / `OPENAI_API_BASE` 指向 `http://127.0.0.1:4000/v1`
- 你原来的上游 API 没有丢失，已经保留在：
  - `LITELLM_UPSTREAM_OPENAI_API_KEY`
  - `LITELLM_UPSTREAM_OPENAI_BASE_URL`
  - `LITELLM_UPSTREAM_OPENAI_MODEL_NAME`
- `LiteLLM` 配置文件在 [docker/litellm/config.yaml](/mnt/cpfs-01cde2b08bc90ffb/yzyang/PostTrainBench/docker/litellm/config.yaml)。
- `LiteLLM` 代理本体运行在宿主机本地 venv：`.runtime/litellm/venv`
- `Postgres` 通过 Docker 运行，并把数据库端口绑定到 `127.0.0.1:5433`

## 启动 LiteLLM

执行：

```bash
bash scripts/litellm/up.sh
```

这会启动两部分：

- 本地 `LiteLLM` 代理进程
- Docker 里的 `Postgres`

默认只监听本机：

- API: `http://127.0.0.1:4000/v1`
- UI: `http://127.0.0.1:4000/ui`

停止服务：

```bash
bash scripts/litellm/down.sh
```

如果你要连数据库卷一起清掉：

```bash
bash scripts/litellm/down.sh --volumes
```

`Postgres` 的监控数据保存在 Docker named volume 里；执行 `--volumes` 会把这些历史用量记录一起删除。

第一次执行 `bash scripts/litellm/up.sh` 时，脚本会自动在 `.runtime/litellm/venv` 安装固定版本的 `litellm[proxy]==1.86.0`。

## 如何开启监控

监控本身不需要单独开关。满足下面两个条件即可：

1. `LiteLLM` 服务已经启动。
2. 你的请求继续走根目录 `.env` 里的默认 `OPENAI_*` 配置，而不是手动覆盖成别的上游地址。

只要请求经过 `http://127.0.0.1:4000/v1`，`LiteLLM` 就会把请求、用量和花费写进它的数据库，UI 里就能看到。

## 登录监控 UI

1. 打开 `http://127.0.0.1:4000/ui`
2. 用户名读取 `.env` 中的 `UI_USERNAME`
3. 密码读取 `.env` 中的 `UI_PASSWORD`

`LiteLLM` 官方 UI 文档也说明了 UI 依赖主密钥和数据库: https://docs.litellm.com.cn/docs/proxy/ui

## 验证代理是否生效

先查看模型列表：

```bash
source .env
curl -sS \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  http://127.0.0.1:4000/v1/models
```

再发一个最小聊天请求：

```bash
source .env
curl -sS \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -H "Content-Type: application/json" \
  http://127.0.0.1:4000/v1/chat/completions \
  -d '{
    "model": "gpt-5.5",
    "messages": [
      {"role": "user", "content": "reply with the word ok"}
    ]
  }'
```

如果响应正常，再刷新 `http://127.0.0.1:4000/ui`，就能看到这次请求。

## 在 UI 里看什么

你主要看这几类页面：

- Spend / Usage：总花费、总 token、模型维度的使用量
- Request / Spend Logs：每次请求的时间、模型、状态、花费
- Models：当前代理暴露出的模型别名

## 改模型时的注意事项

当前配置文件默认暴露了：

- `gpt-5.5`
- `openai/gpt-5.5`
- `text-embedding-3-small`
- `openai/text-embedding-3-small`

如果你后续把 `.env` 里的 `OPENAI_MODEL_NAME` 改成别的模型，最好同步更新 [docker/litellm/config.yaml](/mnt/cpfs-01cde2b08bc90ffb/yzyang/PostTrainBench/docker/litellm/config.yaml)，避免客户端请求了一个 LiteLLM 没有映射的模型名。

## 相关官方文档

- LiteLLM 官方文档: https://docs.litellm.ai/
- LiteLLM Proxy / UI: https://docs.litellm.com.cn/docs/proxy/ui
- LiteLLM Logging / Observability: https://docs.litellm.com.cn/docs/proxy/logging
