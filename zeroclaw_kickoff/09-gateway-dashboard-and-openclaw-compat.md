# gateway 与 OpenClaw 兼容层：Web 宿主怎样接回同一套 agent 内核

ZeroClaw 的 Gateway 有两件事同时在做：把内核挂到 Web 宿主上，以及向 OpenClaw/OpenAI 兼容调用方提供迁移入口。

## `run_gateway()` 先装的是内核，不是 router

`run_gateway()` 在真正建路由前，先初始化 plugin runtime、public bind guard、hooks、provider、memory、runtime、`SecurityPolicy` 和工具注册表。Gateway 不是先有 HTTP，再临时去找内核；它先是内核宿主，再是 HTTP 外壳（`zeroclaw/src/gateway/mod.rs:403-492`）。

## `AppState` 和 router 暴露了 Gateway 的真实厚度

`AppState` 里挂着 config、provider、model、temperature、memory、pairing、rate limiter、observer、tools registry、multimodal、event_tx 等对象；随后 router 再把 `/api/chat`、`/v1/chat/completions`、dashboard API、SSE、WebSocket 和静态资源统一挂上。这说明 Gateway 本身就是一台 Web 控制宿主（`zeroclaw/src/gateway/mod.rs:780-824`; `zeroclaw/src/gateway/mod.rs:827-917`）。

## `/api/chat` 直接走完整 agent loop

`ApiChatBody` 允许 `message`、`session_id` 和 `context`；`handle_api_chat()` 会做 rate limit、auth/pairing 校验、JSON 解析、memory autosave、context 拼接，然后调用 `run_gateway_chat_with_tools()`。这个 endpoint 的语义不是简单 `provider.chat_with_history()`，而是完整工具化 agent 执行（`zeroclaw/src/gateway/openclaw_compat.rs:49-234`）。

## `/v1/chat/completions` 兼容层也走同一条内核

`handle_v1_chat_completions_with_tools()` 会解析 OpenAI 风格请求，抽出最后一条 user message 和前文上下文，然后同样进入 `run_gateway_chat_with_tools()`。兼容层的价值不只是协议适配，而是把外部调用重定向到 ZeroClaw 的完整内核语义（`zeroclaw/src/gateway/openclaw_compat.rs:359-510`）。

## 关键源码锚点

- Gateway 内核装配：`zeroclaw/src/gateway/mod.rs:403-492`
- `AppState` 与 router：`zeroclaw/src/gateway/mod.rs:780-824`; `zeroclaw/src/gateway/mod.rs:827-917`
- `/api/chat`：`zeroclaw/src/gateway/openclaw_compat.rs:49-234`
- `/v1/chat/completions` compat：`zeroclaw/src/gateway/openclaw_compat.rs:359-510`

## 阅读问题

- 为什么 ZeroClaw 兼容 OpenClaw/OpenAI 时，仍坚持走完整 agent loop？
- `AppState` 挂了这么多对象，说明 Gateway 更像 API 层还是控制宿主？
