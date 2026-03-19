# 会话与路由：为什么 `sessionKey` 才是 OpenClaw 的真实身份边界

OpenClaw 里最容易被低估的不是 prompt，而是 `sessionKey`。这不是普通会话标签，而是 agent 身份、并发 lane、持久化位置和回写策略的共同地址。

## `session-key.ts` 定义了地址语法，而不是辅助字符串

`DEFAULT_AGENT_ID`、`DEFAULT_MAIN_KEY`、`classifySessionKeyShape()`、`resolveAgentIdFromSessionKey()` 这组函数把 `sessionKey` 视为正式语法对象。`normalizeAgentId()` 还把 agent id 约束到 path-safe、shell-friendly 形态，说明这一层从一开始就服务于持久化和执行环境，而不只是 UI 展示（`openclaw/src/routing/session-key.ts:19-116`）。

`buildAgentMainSessionKey()` 明确生成 `agent:<agentId>:<mainKey>`，`buildAgentPeerSessionKey()` 则把 `channel`、`accountId`、`peerKind`、`peerId` 和 `dmScope` 编入地址。对 direct chat，`dmScope` 还能决定是退回 main session，还是切成 per-peer、per-channel-peer、per-account-channel-peer 粒度（`openclaw/src/routing/session-key.ts:118-174`）。

## `ResolvedAgentRoute` 不是“选中哪个 agent”这么简单

`ResolvedAgentRoute` 同时返回 `sessionKey`、`mainSessionKey`、`lastRoutePolicy` 和 `matchedBy`。其中 `deriveLastRoutePolicy()` 与 `resolveInboundLastRouteSessionKey()` 明确表达了一个事实：OpenClaw 路由不仅要决定谁处理消息，还要决定“最后路由”写回主会话还是当前分叉会话（`openclaw/src/routing/resolve-route.ts:39-75`）。

`buildAgentSessionKey()` 只是 facade，真正的地址构造仍然落到 `buildAgentPeerSessionKey()`。这说明 route 解析和地址编码是分层的：前者负责策略，后者负责稳定表示（`openclaw/src/routing/resolve-route.ts:91-112`; `openclaw/src/routing/session-key.ts:127-174`）。

## Gateway 把 `sessionKey` 当硬身份来校验

Gateway `agent` method 在显式给出 `agentId` 和 `sessionKey` 时，会用 `resolveAgentIdFromSessionKey()` 反解 agent，再拒绝不一致组合。`agent.identity.get` 同样重复这条校验，说明 `sessionKey` 不是可被随手覆盖的上下文字段，而是控制面身份协议的一部分（`openclaw/src/gateway/server-methods/agent.ts:318-326`; `openclaw/src/gateway/server-methods/agent.ts:685-692`）。

## 这层还直接影响 runner 和子会话继承

`runEmbeddedPiAgent()` 一开始就从 `sessionKey/sessionId` 派生 session lane，所以同一个 `sessionKey` 就意味着同一条并发串行边界（`openclaw/src/agents/pi-embedded-runner/run.ts:269-285`）。

跨会话协作也围着这套地址体系展开。`resolveSpawnedWorkspaceInheritance()` 会优先读显式 workspace，否则从 `targetAgentId` 或 `requesterSessionKey` 反解 agent，再继承目标 agent 的 workspace；这说明分叉会话不是匿名线程，而是继续挂在 agent/session 地址空间里（`openclaw/src/agents/spawned-context.ts:59-76`）。

## 关键源码锚点

- 地址语法：`openclaw/src/routing/session-key.ts:19-174`
- 路由结果：`openclaw/src/routing/resolve-route.ts:39-112`
- Gateway 身份校验：`openclaw/src/gateway/server-methods/agent.ts:318-326`; `openclaw/src/gateway/server-methods/agent.ts:685-692`
- runner 并发边界：`openclaw/src/agents/pi-embedded-runner/run.ts:269-285`
- spawned workspace 继承：`openclaw/src/agents/spawned-context.ts:59-76`

## 阅读问题

- 为什么 `mainSessionKey` 和 `sessionKey` 必须并存，而不是统一成一个地址？
- `dmScope` 改变的其实是 UI 体验，还是存储与并发模型？
