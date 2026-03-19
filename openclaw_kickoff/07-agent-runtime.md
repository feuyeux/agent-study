# agent 内核：`runEmbeddedPiAgent()` 与 `runEmbeddedAttempt()` 各自负责什么

OpenClaw 的执行核拆得很刻意。`runEmbeddedPiAgent()` 负责把一次请求放进正确的并发和运行环境里，`runEmbeddedAttempt()` 则负责单次 attempt 的 prompt 和 session 操作。两者不是大小函数关系，而是“外层运行时协调器”和“内层执行器”的关系。

## `runEmbeddedPiAgent()` 先决定运行环境

函数入口先根据 `sessionKey/sessionId` 计算 session lane，再根据显式 `lane` 计算 global lane，并把整个执行包进两层队列。随后它会解析 workspace、记录 fallback、调用 `ensureRuntimePluginsLoaded()`，再开始 provider/model 解析前的 hook 协调（`openclaw/src/agents/pi-embedded-runner/run.ts:269-307`; `openclaw/src/agents/pi-embedded-runner/run.ts:320-360`）。

## 外层循环负责 retry、auth retry 和 context engine 生命周期

`runEmbeddedPiAgent()` 在进入 attempt 前会 `ensureContextEnginesInitialized()`，然后复用 `resolveContextEngine()` 的结果穿过整个 retry 循环。循环内部管理 retry limit、auth retry、workspace 创建、prompt scrub、usage 累积，并不断调用 `runEmbeddedAttempt()`。这说明 context engine 和重试语义属于 turn 级，不属于单次 attempt（`openclaw/src/agents/pi-embedded-runner/run.ts:879-980`）。

## `runEmbeddedAttempt()` 才真正操作 session 与 prompt

`runEmbeddedAttempt()` 会构造 `effectivePrompt`，跑 `resolvePromptBuildHookResult()`，根据 hook 结果 prepend context 或改写 system prompt，并在必要时通过 `applySystemPromptOverrideToSession()` 回写到 session 内部。它操作的是 session message tree，而不只是生成一段待发字符串（`openclaw/src/agents/pi-embedded-runner/run/attempt.ts:2415-2467`; `openclaw/src/agents/pi-embedded-runner/system-prompt.ts:87-105`）。

## 它还显式修复 session 拓扑

在真正发送给模型之前，`runEmbeddedAttempt()` 会检查 `sessionManager.getLeafEntry()`；如果 leaf 是 trailing user message，就通过 `branch()` 或 `resetLeaf()` 重建叶子上下文，再把 `activeSession.agent.replaceMessages()` 同步回去。也就是说，它不仅组 prompt，还维护对话树的结构合法性（`openclaw/src/agents/pi-embedded-runner/run/attempt.ts:2476-2489`）。

## system prompt 不是常量，而是函数式构造物

`buildEmbeddedSystemPrompt()` 接收 runtimeInfo、tools、sandboxInfo、skillsPrompt、contextFiles、memoryCitationsMode 等大量参数，再转给 `buildAgentSystemPrompt()`。这意味着 embedded runner 看到的 system prompt 本质上是执行环境投影，而不是静态模板（`openclaw/src/agents/pi-embedded-runner/system-prompt.ts:11-85`）。

## 关键源码锚点

- 外层协调：`openclaw/src/agents/pi-embedded-runner/run.ts:266-360`
- retry/context engine：`openclaw/src/agents/pi-embedded-runner/run.ts:879-980`
- 单次 attempt：`openclaw/src/agents/pi-embedded-runner/run/attempt.ts:2415-2495`
- system prompt 构造与 override：`openclaw/src/agents/pi-embedded-runner/system-prompt.ts:11-105`

## 阅读问题

- 为什么 context engine 要在 `runEmbeddedPiAgent()` 层解析一次，而不是每次 attempt 各自 new？
- `applySystemPromptOverrideToSession()` 为什么不只是返回新字符串，而要直接改 session？
