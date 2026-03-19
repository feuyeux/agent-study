# 多会话协作：OpenClaw 怎样把 subagent 和 session 工具链接进主系统

OpenClaw 的多会话协作不是“当前对话里再打个标签”。它的实现一直围着三个对象转：`sessionKey`、spawn metadata 和 late-binding subagent runtime。

## subagent 先被做成 Plugin Runtime 的正式表面

`createPluginRuntime()` 直接导出 `subagent`，而且这个表面是通过 `createLateBindingSubagent()` 创建的；`allowGatewaySubagentBinding` 还能决定它是否允许绑定到 Gateway 宿主。这说明 subagent 从设计上就不是内部私有功能，而是宿主能力的一部分（`openclaw/src/plugins/runtime/index.ts:138-146`）。

## spawned metadata 决定新会话继承什么执行视角

`normalizeSpawnedRunMetadata()` 规范化 `spawnedBy/groupId/groupChannel/groupSpace/workspaceDir`，`mapToolContextToSpawnedRunMetadata()` 把工具上下文映射到 spawned metadata，而 `resolveSpawnedWorkspaceInheritance()` 再根据显式 workspace、target agent 或 requester `sessionKey` 推导出子会话 workspace。这意味着一次 spawn 本质上是在已有 agent/session 地址空间里开出新的执行分支（`openclaw/src/agents/spawned-context.ts:36-76`）。

## `sessionKey` 仍然是协作的底层地址

`buildAgentMainSessionKey()` 和 `buildAgentPeerSessionKey()` 负责把 main session、peer session 和 channel/account scope 编码进地址；因此多会话协作不是靠额外数据库维系，而是继续复用同一套 session-key 语法（`openclaw/src/routing/session-key.ts:118-174`）。

## runner 外层明确允许 Gateway 参与 subagent 绑定

`runEmbeddedPiAgent()` 在加载 runtime plugins 时显式接收 `allowGatewaySubagentBinding`，说明“是否让子代理与 Gateway 生命周期联动”是 runner 外层的正式开关，而不是插件作者自己猜测的隐含行为（`openclaw/src/agents/pi-embedded-runner/run.ts:303-307`; `openclaw/src/agents/pi-embedded-runner/run.ts:953-958`）。

## 关键源码锚点

- Plugin Runtime 的 `subagent` 面：`openclaw/src/plugins/runtime/index.ts:138-146`
- spawned metadata：`openclaw/src/agents/spawned-context.ts:36-76`
- session 地址语法：`openclaw/src/routing/session-key.ts:118-174`
- runner 的 Gateway 绑定开关：`openclaw/src/agents/pi-embedded-runner/run.ts:303-307`; `openclaw/src/agents/pi-embedded-runner/run.ts:953-958`

## 阅读问题

- 为什么 subagent 要做成 late-binding runtime，而不是固定实现？
- `workspaceDir` 继承策略为什么必须读 `requesterSessionKey`？
