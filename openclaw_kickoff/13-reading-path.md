# 建议阅读路径：顺着控制面、地址模型和执行核读

## 第一条主链：先打通“请求如何被执行”

先读 `agentViaGatewayCommand()` 看 CLI 如何生成控制面请求（`openclaw/src/commands/agent-via-gateway.ts:88-179`），再读 Gateway `agent` method 看请求如何被验参与鉴权（`openclaw/src/gateway/server-methods/agent.ts:155-217`; `openclaw/src/gateway/server-methods/agent.ts:307-326`），随后直接进入 `runEmbeddedPiAgent()` 和 `runEmbeddedAttempt()` 看真正执行怎样发生（`openclaw/src/agents/pi-embedded-runner/run.ts:266-360`; `openclaw/src/agents/pi-embedded-runner/run.ts:879-980`; `openclaw/src/agents/pi-embedded-runner/run/attempt.ts:2415-2495`）。

## 第二条主链：再读“请求到底属于谁”

把 `ResolvedAgentRoute`、`buildAgentSessionKey()`、`buildAgentMainSessionKey()`、`buildAgentPeerSessionKey()` 连起来读，理解 `sessionKey/mainSessionKey/lastRoutePolicy` 三件套怎样定义身份、回写和并发边界（`openclaw/src/routing/resolve-route.ts:39-112`; `openclaw/src/routing/session-key.ts:19-174`）。

## 第三条主链：最后读“系统怎样变成平台”

先看 `createPluginRuntime()` 定义的宿主扩展面（`openclaw/src/plugins/runtime/index.ts:138-189`），再看 `plugins/loader.ts` 怎样 discovery、筛选、边界检查和激活插件（`openclaw/src/plugins/loader.ts:894-964`; `openclaw/src/plugins/loader.ts:966-1385`），最后再把 `ChannelGatewayContext` 接回渠道运行时（`openclaw/src/channels/plugins/types.adapters.ts:234-305`）。

## 补线：运维与控制面

读完主链后，再补 `server.impl.ts`、`healthCommand()`、`usage.ts`、`update.ts`，你会看到 Gateway 为什么不是聊天 API 外壳，而是长期运行宿主（`openclaw/src/gateway/server.impl.ts:627-760`; `openclaw/src/commands/health.ts:597-700`; `openclaw/src/gateway/server-methods/usage.ts:62-197`; `openclaw/src/gateway/server-methods/update.ts:18-133`）。

## 不建议的读法

不要先平铺读 `channels/` 或 `plugins/` 整个目录，也不要先盯着 prompt 模板。OpenClaw 的真正骨架不在目录层级，而在控制面主链、session 地址模型和 runner 分层。
