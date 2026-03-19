# 入口与宿主：OpenClaw 的 agent 实际跑在哪里

OpenClaw 的宿主关系不是“CLI 调模型”，而是两层。第一层是把请求送进控制面的外壳，第二层是把请求推进 embedded runner 的执行核。这个分层在源码里非常明确。

## CLI 只负责生成一次合格的控制面请求

`agentViaGatewayCommand()` 先做参数卫生，再用 `resolveSessionKeyForRequest()` 解析目标会话，最后通过 `callGateway()` 调 `method: "agent"`。它不持有会话状态，也不装配模型，只是把一次命令行输入翻译成 Gateway 可执行请求（`openclaw/src/commands/agent-via-gateway.ts:88-155`）。

## 真正的宿主是 Gateway runtime state

`server.impl.ts` 在启动阶段先构造 `channelManager`、`createReadinessChecker()`、`createGatewayRuntimeState()`，随后再挂 `NodeRegistry`、订阅管理、voice wake 广播、cron 服务、discovery、skills 刷新和健康轮询。也就是说，OpenClaw 的“主机”不是某个单函数，而是这批常驻对象组成的 runtime state（`openclaw/src/gateway/server.impl.ts:627-760`）。

`createGatewayRuntimeState()` 返回的也不是单个 server handle，而是一组控制面资源：HTTP/WSS server、`clients`、`broadcast`、`chatRunState`、`chatRunBuffers`、`chatAbortControllers`、`toolEventRecipients` 等。这些对象共同决定消息如何被接收、广播、取消和收尾（`openclaw/src/gateway/server.impl.ts:637-683`）。

## Gateway 不执行 prompt，它把执行委托给 embedded runner

Gateway 的 `agent` method 先做 `validateAgentParams()`，再根据调用方权限决定是否允许 `provider/model` override，并校验 `agentId` 与 `sessionKey` 是否一致；这里做的是控制面准入，而不是模型执行（`openclaw/src/gateway/server-methods/agent.ts:155-217`; `openclaw/src/gateway/server-methods/agent.ts:312-326`）。

真正的执行从 `runEmbeddedPiAgent()` 开始。这个函数先做 session/global lane 排队，再解析 workspace、加载 runtime plugins、跑 `before_model_resolve`/`before_agent_start` hook，然后才进入一次次 `runEmbeddedAttempt()`。因此 Gateway 是宿主，embedded runner 是执行内核（`openclaw/src/agents/pi-embedded-runner/run.ts:269-360`; `openclaw/src/agents/pi-embedded-runner/run.ts:879-980`）。

## 宿主分层的直接结果

- 会话和并发都归 Gateway 控制，因为 `runEmbeddedPiAgent()` 依赖 `sessionKey` 进入 session lane，而 `sessionKey` 正是控制面分配的地址（`openclaw/src/agents/pi-embedded-runner/run.ts:269-285`; `openclaw/src/routing/resolve-route.ts:91-112`）。
- 插件能力优先挂到宿主上，因为 `createPluginRuntime()` 暴露的是 `agent`、`subagent`、`tools`、`channel`、`events`、`logging`、`modelAuth` 等宿主级接口，而不是单一 prompt hook（`openclaw/src/plugins/runtime/index.ts:138-189`）。
- 渠道和节点都不是旁路；它们直接被放进 Gateway runtime state，所以控制面天然负责长连接、消息分发、工具事件和恢复逻辑（`openclaw/src/gateway/server.impl.ts:685-760`）。

## 关键源码锚点

- `agentViaGatewayCommand()`：`openclaw/src/commands/agent-via-gateway.ts:88-179`
- Gateway 宿主装配：`openclaw/src/gateway/server.impl.ts:627-760`
- `agent` method 准入与一致性校验：`openclaw/src/gateway/server-methods/agent.ts:155-217`; `openclaw/src/gateway/server-methods/agent.ts:312-326`
- embedded runner 外层协调：`openclaw/src/agents/pi-embedded-runner/run.ts:266-360`; `openclaw/src/agents/pi-embedded-runner/run.ts:879-980`

## 阅读问题

- 如果把 Gateway 拿掉，只保留 `runEmbeddedPiAgent()`，你会失去哪些长期运行能力？
- 为什么 `sessionKey` 的分配必须发生在控制面，而不是 runner 内部现算？
