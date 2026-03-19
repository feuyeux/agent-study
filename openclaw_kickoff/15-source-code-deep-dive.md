# OpenClaw 主链深挖：从 `agentViaGatewayCommand()` 到 `runEmbeddedAttempt()`

## 1. 入口对象其实是 Gateway params

`agentViaGatewayCommand()` 的真正工作不是“拿用户输入拼 prompt”，而是把一次外部命令整理成 Gateway 可执行参数：消息体、`agentId`、`sessionKey`、`thinking`、`deliver`、`channel`、`replyChannel`、`idempotencyKey`、timeout 和 lane 全都在这里被固定下来（`openclaw/src/commands/agent-via-gateway.ts:97-155`）。

这一步很关键，因为它决定后面所有层都围绕同一个控制面协议工作，而不是每个入口各自定义请求结构。

## 2. Gateway `agent` method 先把身份和权限压实

Gateway 侧 `agent` handler 先调用 `validateAgentParams()`，再用 `resolveAllowModelOverrideFromClient()` 判断调用方能否覆盖 provider/model。如果来路不被授权，请求会在控制面直接失败。随后显式 `sessionKey` 还要通过 `resolveAgentIdFromSessionKey()` 与 `agentId` 做一致性校验（`openclaw/src/gateway/server-methods/agent.ts:155-217`; `openclaw/src/gateway/server-methods/agent.ts:318-326`）。

这意味着 OpenClaw 把“谁能跑这个 agent、谁能切这个模型”放在 Gateway 层，而不是把这些判断埋进 runner。

## 3. `sessionKey` 不只是会话标识，它还是执行地址

`ResolvedAgentRoute` 同时生成 `sessionKey`、`mainSessionKey` 和 `lastRoutePolicy`；`buildAgentSessionKey()` 再调用 `buildAgentPeerSessionKey()` 编码 peer scope。这里实际上把三件事合并了：身份、持久化位置、状态回写策略（`openclaw/src/routing/resolve-route.ts:39-112`; `openclaw/src/routing/session-key.ts:118-174`）。

一旦 `sessionKey` 确定，runner 的 session lane、workspace fallback、spawn workspace 继承都会围着它转（`openclaw/src/agents/pi-embedded-runner/run.ts:269-300`; `openclaw/src/agents/spawned-context.ts:59-76`）。

## 4. `runEmbeddedPiAgent()` 是 turn 级协调器

`runEmbeddedPiAgent()` 先计算 session/global lane，再解析 workspace，并调用 `ensureRuntimePluginsLoaded()`。这一步说明执行核并不是裸模型调用，它必须先把插件、workspace、并发边界和 hook 环境装好（`openclaw/src/agents/pi-embedded-runner/run.ts:269-307`）。

随后它会在模型解析前触发 `before_model_resolve` 和兼容性的 `before_agent_start` hook，让插件有机会在进入模型层之前改变 provider/model 选择（`openclaw/src/agents/pi-embedded-runner/run.ts:320-360`）。

## 5. 真正的 retry 循环也在外层

`runEmbeddedPiAgent()` 初始化 context engine 后进入 `while (true)` 重试循环。这里处理 retry limit、auth retry、workspace 目录确保、Anthropic refusal scrub，以及每次 `runEmbeddedAttempt()` 所需的大量参数传递。外层循环的存在说明一次 turn 可以包含多个 attempt，而这些 attempt 共享 context engine、usage 累积和错误归因（`openclaw/src/agents/pi-embedded-runner/run.ts:879-980`）。

## 6. `runEmbeddedAttempt()` 先做 prompt 管道，再做执行

在 attempt 内部，OpenClaw 先 `prependBootstrapPromptWarning()`，再通过 `resolvePromptBuildHookResult()` 收集 hook 注入。`prependContext` 会写回 `effectivePrompt`，`systemPrompt`、`prependSystemContext`、`appendSystemContext` 则通过 `applySystemPromptOverrideToSession()` 修改 session 中的 system message（`openclaw/src/agents/pi-embedded-runner/run/attempt.ts:2415-2467`; `openclaw/src/agents/pi-embedded-runner/system-prompt.ts:87-105`）。

这一步最值得注意的是：OpenClaw 不把 prompt 视为临时字符串，而是把 session tree 当成真实状态载体。system prompt 被覆盖时，session 本身也被同步更新。

## 7. 会话树修复是执行前的必经步骤

如果 `sessionManager.getLeafEntry()` 发现叶子节点是 trailing user message，`runEmbeddedAttempt()` 会选择 `branch()` 或 `resetLeaf()`，再用 `buildSessionContext()` 重建消息列表，最后 `replaceMessages()` 回写到 active session。这个修复动作在 prompt 发送前发生，说明 OpenClaw 把对话树合法性看成执行语义的一部分（`openclaw/src/agents/pi-embedded-runner/run/attempt.ts:2476-2489`）。

## 8. 插件不是外围附加层，而是横切主链

`createPluginRuntime()` 暴露 `agent/subagent/tools/channel/events/modelAuth` 等面，而 loader 通过 lazy runtime proxy、manifest registry、boundary check 和 `register/activate` 协议把插件接到主系统。也就是说，插件既可以在控制面前段插手，也可以在执行核周围扩展宿主能力（`openclaw/src/plugins/runtime/index.ts:138-189`; `openclaw/src/plugins/loader.ts:894-964`; `openclaw/src/plugins/loader.ts:966-1385`）。

## 9. 控制面闭环也在同一条系统观里

`healthCommand()` 总是去查 Gateway，`usage.ts` 以 `sessionKey` 反解 session file，`update.run` 只在更新成功时写 sentinel 并安排 restart。它们看起来是运维角落代码，但其实都在证明同一个事实：OpenClaw 的中心始终是 Gateway 控制面，而不是某次模型交互（`openclaw/src/commands/health.ts:597-700`; `openclaw/src/gateway/server-methods/usage.ts:62-197`; `openclaw/src/gateway/server-methods/update.ts:18-133`）。

## 10. 一句话收束

OpenClaw 这条主链真正厉害的地方，不是能把消息送到模型，而是它把“入口协议、身份地址、执行循环、扩展面和运维控制面”都压进了一套相互一致的源码结构里。
