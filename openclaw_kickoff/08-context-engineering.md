# 上下文工程：OpenClaw 怎样塑造模型看到的世界

OpenClaw 的上下文工程不是“写好一段 system prompt”。从源码看，它至少有四层：system prompt 构造、hook 注入、session 树修复、spawn/workspace 继承。

## 第一层：system prompt 是环境投影函数

`buildEmbeddedSystemPrompt()` 接收 runtimeInfo、tool 列表、sandboxInfo、skillsPrompt、workspace notes、context files、memory citations mode 等参数，再调用 `buildAgentSystemPrompt()`。这个接口说明 system prompt 本身就是 runtime state 的序列化，而不是纯静态文案（`openclaw/src/agents/pi-embedded-runner/system-prompt.ts:11-85`）。

## 第二层：hook 可以同时改 prompt 和 system prompt

`runEmbeddedAttempt()` 会先跑 `resolvePromptBuildHookResult()`。如果 hook 返回 `prependContext`，它会把内容拼进 `effectivePrompt`；如果返回 `systemPrompt`、`prependSystemContext` 或 `appendSystemContext`，则通过 `applySystemPromptOverrideToSession()` 把 session 里的 system message 重写。这让插件既能加前缀上下文，也能重组系统指令层（`openclaw/src/agents/pi-embedded-runner/run/attempt.ts:2415-2467`; `openclaw/src/agents/pi-embedded-runner/system-prompt.ts:87-105`）。

## 第三层：session 树会在 prompt 前被修复

如果当前 leaf 是 orphaned trailing user message，`runEmbeddedAttempt()` 会 `branch()` 或 `resetLeaf()`，然后用 `buildSessionContext()` 重建 message 列表。这一步不是异常清理，而是 prompt 组装主链的一部分，因为它直接保证 role ordering 合法（`openclaw/src/agents/pi-embedded-runner/run/attempt.ts:2476-2489`）。

## 第四层：spawn 上下文会改变后续 workspace 视角

`normalizeSpawnedRunMetadata()` 统一清洗 `spawnedBy/groupId/groupChannel/groupSpace/workspaceDir`，`mapToolContextToSpawnedRunMetadata()` 把 tool context 映射成 spawned metadata，而 `resolveSpawnedWorkspaceInheritance()` 则根据显式 workspace、target agent 或 requester `sessionKey` 决定新会话继承哪个 workspace。OpenClaw 的上下文不仅是文字，还包括执行视角（`openclaw/src/agents/spawned-context.ts:36-76`）。

## 关键源码锚点

- system prompt 构造：`openclaw/src/agents/pi-embedded-runner/system-prompt.ts:11-85`
- system prompt override：`openclaw/src/agents/pi-embedded-runner/system-prompt.ts:87-105`
- prompt hook 与 session 修复：`openclaw/src/agents/pi-embedded-runner/run/attempt.ts:2415-2495`
- spawned metadata 与 workspace 继承：`openclaw/src/agents/spawned-context.ts:36-76`

## 阅读问题

- OpenClaw 为什么把很多“上下文”放进 session 和 workspace，而不是都变成 prompt 文本？
- 如果 hook 既能改 `effectivePrompt` 又能改 system prompt，哪个层面更稳定，为什么？
