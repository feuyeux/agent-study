# 一次请求的完整生命周期：消息怎样从 Gateway `agent` method 走到 `runEmbeddedAttempt()`

最值得打通的主链不是某个 UI，而是这一条：

`agentViaGatewayCommand()` -> Gateway `agent` method -> `runEmbeddedPiAgent()` -> `runEmbeddedAttempt()` -> payload/delivery

## 第一步：外部请求被翻译成 Gateway `agent` RPC

`agentViaGatewayCommand()` 先读取消息体、解析 `agentId`、计算 timeout，再用 `resolveSessionKeyForRequest()` 生成目标 `sessionKey`，最后把所有字段塞进 `callGateway({ method: "agent" })`。所以“发起一次请求”的入口对象其实是 Gateway params，而不是 prompt 本身（`openclaw/src/commands/agent-via-gateway.ts:88-155`）。

## 第二步：Gateway 把请求变成合法的执行单元

Gateway 的 `agent` handler 先跑 `validateAgentParams()`，然后根据 `resolveAllowModelOverrideFromClient()` 判定是否允许 `provider/model` override。接着它还会检查显式 `sessionKey` 是否 malformed，以及 `agentId` 是否和 `sessionKey` 中解析出的 agent 一致。这一层在做控制面准入与身份守卫（`openclaw/src/gateway/server-methods/agent.ts:155-217`; `openclaw/src/gateway/server-methods/agent.ts:307-326`）。

同文件里的 `agent.identity.get` 也重复做了 `agentId/sessionKey` 一致性校验，说明“session key 即 agent 身份”的规则不是某个分支偶然使用，而是 Gateway method 级别的系统约束（`openclaw/src/gateway/server-methods/agent.ts:680-692`）。

## 第三步：runner 外层决定并发、workspace、模型与 hook

`runEmbeddedPiAgent()` 一进来先根据 `sessionKey/sessionId` 和 `lane` 计算 session/global lane，再把真正执行包进两层队列。随后它解析 workspace，必要时记录 fallback，确保 runtime plugins 已加载，并在模型解析之前调用 `before_model_resolve` 与兼容性的 `before_agent_start` hook（`openclaw/src/agents/pi-embedded-runner/run.ts:269-360`）。

## 第四步：一次次 attempt 在 retry 循环里推进

`runEmbeddedPiAgent()` 不直接完成全部执行，它先初始化 context engine，再在循环里反复调用 `runEmbeddedAttempt()`；循环负责 retry 上限、auth retry、workspace 准备、Anthropic refusal scrub、usage 累积以及错误出参整形。也就是说，attempt 只是单次试跑，真正的 turn 生命周期由外层循环收束（`openclaw/src/agents/pi-embedded-runner/run.ts:879-980`）。

## 第五步：`runEmbeddedAttempt()` 组 prompt、修 session、再真正执行

`runEmbeddedAttempt()` 在 prompt 阶段先 `prependBootstrapPromptWarning()`，再调用 `resolvePromptBuildHookResult()`。如果 hook 返回 `prependContext`、`systemPrompt`、`prependSystemContext` 或 `appendSystemContext`，函数会通过 `applySystemPromptOverrideToSession()` 改写 session 中的 system message。随后它会检查 `sessionManager.getLeafEntry()`，若发现 orphaned trailing user message，就 `branch()` 或 `resetLeaf()` 后重建 session context，避免连续 user turn 破坏角色顺序（`openclaw/src/agents/pi-embedded-runner/run/attempt.ts:2415-2495`）。

## 第六步：结果回到 Gateway，再由外层决定怎么交付

CLI 侧最后只是读取 `GatewayAgentResponse.result.payloads` 并逐条格式化输出；这和第一步对应，说明入口与出口都停在控制面边界，执行细节完全留在 runner 内部（`openclaw/src/commands/agent-via-gateway.ts:163-179`）。

## 关键源码锚点

- CLI 入口：`openclaw/src/commands/agent-via-gateway.ts:88-179`
- Gateway `agent` method：`openclaw/src/gateway/server-methods/agent.ts:155-217`; `openclaw/src/gateway/server-methods/agent.ts:307-326`
- runner 外层循环：`openclaw/src/agents/pi-embedded-runner/run.ts:266-360`; `openclaw/src/agents/pi-embedded-runner/run.ts:879-980`
- 单次 attempt：`openclaw/src/agents/pi-embedded-runner/run/attempt.ts:2415-2495`

## 阅读问题

- 为什么 `runEmbeddedPiAgent()` 要负责 retry，而不是把 retry 都塞进 `runEmbeddedAttempt()`？
- 如果没有 orphan user 修复，会在哪些 provider/history 语义上出问题？
