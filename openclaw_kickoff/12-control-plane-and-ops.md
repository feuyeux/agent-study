# 控制面与运维：Gateway 为什么是长期运行宿主

如果只看 `agent` method，会误以为 OpenClaw 的 Gateway 只是 RPC server。真正决定它是控制面的，是 runtime state、health、usage、update 这些长期运行职责。

## 宿主厚度首先体现在 runtime state 装配

`server.impl.ts` 在 `createGatewayRuntimeState()` 之外还要装上 `channelManager`、`NodeRegistry`、订阅管理、cron、skills refresh、health interval、dedupe cleanup 等对象。这些对象都不属于单次请求，但它们共同决定系统是否能长期运行、恢复和广播（`openclaw/src/gateway/server.impl.ts:627-760`）。

## `healthCommand()` 的视角是“Gateway 是否活着”

`healthCommand()` 明确总是通过 `callGateway({ method: "health" })` 查询运行中的 Gateway，而不是自己直连渠道。随后它再把 agents、session summary、channel bindings 和 probe 结果格式化成运维视图。这说明健康检查的中心是控制面，而不是某个具体 provider 或 channel（`openclaw/src/commands/health.ts:597-700`）。

## usage 统计依赖 session 地址和时间解释规则

`resolveSessionUsageFileOrRespond()` 先从 `sessionKey` 反解 `agentId/sessionId/sessionFile`；`resolveDateInterpretation()` 和 `parseDateToMs()` 再把 gateway/local/UTC offset 三种日期解释模式正规化。使用量统计并不是拿日志 grep 一下，而是建立在 session 地址模型和统一时间语义之上（`openclaw/src/gateway/server-methods/usage.ts:62-197`）。

## update 流程会写 restart sentinel，并且只在成功时重启

`update.run` 会先执行 `runGatewayUpdate()`，再把结果写进 `RestartSentinelPayload`，并调用 `writeRestartSentinel()` 记录 restart 元信息。最关键的是它只在 `result.status === "ok"` 时才 `scheduleGatewaySigusr1Restart()`，明确避免失败更新造成 crash loop（`openclaw/src/gateway/server-methods/update.ts:18-133`）。

## 关键源码锚点

- Gateway 宿主装配：`openclaw/src/gateway/server.impl.ts:627-760`
- health 控制面查询：`openclaw/src/commands/health.ts:597-700`
- usage 会话与日期解析：`openclaw/src/gateway/server-methods/usage.ts:62-197`
- update 与 restart sentinel：`openclaw/src/gateway/server-methods/update.ts:18-133`

## 阅读问题

- 为什么 health 要以 Gateway 可达性为中心，而不是把单个 channel failure 视为整个命令失败？
- restart sentinel 解决的是更新问题，还是控制面恢复问题？
