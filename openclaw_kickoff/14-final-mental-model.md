# 最终心智模型：把 OpenClaw 看成“以 Gateway 控制面和 `sessionKey` 地址模型为中心的嵌入式 agent 平台”

最稳的抓法是四句话：

- Gateway 是宿主，不是薄 API，因为 channels、nodes、cron、health 和 restart 都在它这层组装（`openclaw/src/gateway/server.impl.ts:627-760`; `openclaw/src/gateway/server-methods/update.ts:95-110`）。
- `sessionKey` 是真实身份边界，不是聊天 ID，因为 route、并发 lane、workspace 继承和 session file 都围着它转（`openclaw/src/routing/resolve-route.ts:39-112`; `openclaw/src/routing/session-key.ts:118-174`; `openclaw/src/agents/pi-embedded-runner/run.ts:269-300`）。
- embedded runner 是执行核，不是整个系统，因为 `runEmbeddedPiAgent()` 和 `runEmbeddedAttempt()` 只负责 turn 执行，控制面和扩展面都在它们之外（`openclaw/src/agents/pi-embedded-runner/run.ts:266-360`; `openclaw/src/agents/pi-embedded-runner/run/attempt.ts:2415-2495`）。
- Plugin Runtime 是平台接口，不是边缘能力，因为它暴露的是 agent、subagent、tools、channel、events、modelAuth 等宿主投影（`openclaw/src/plugins/runtime/index.ts:138-189`）。

把这四句拼起来，你看到的就不是“支持很多渠道的聊天机器人”，而是一台能长期运行、能路由多会话、能扩展宿主能力的 agent 控制平台。
