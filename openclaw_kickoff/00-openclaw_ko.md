# OpenClaw 源码 Kickoff

- [入口与宿主：`agentViaGatewayCommand()`、`createGatewayRuntimeState()`、`runEmbeddedPiAgent()` 怎样把 CLI、Gateway 和执行核串起来](./01-gateway-and-host.md)
- [架构总图：为什么 OpenClaw 的稳定骨架是 `Gateway -> Route -> SessionKey -> Embedded Runner -> Plugin Runtime`](./02-architecture-diagram.md)
- [请求生命周期：一次消息怎样从 `agent` RPC 推进到 `runEmbeddedAttempt()`](./03-request-lifecycle.md)
- [会话与路由：`buildAgentSessionKey()`、`buildAgentMainSessionKey()`、`buildAgentPeerSessionKey()` 为什么定义了真实身份边界](./04-session-routing-delivery.md)
- [插件骨架：`createPluginRuntime()` 与 `plugins/loader.ts` 怎样把扩展面做成正式运行时](./05-plugin-system.md)
- [渠道运行时：`channels/registry.ts`、`draft-stream-controls.ts`、`ChannelGatewayContext` 怎样接入统一控制面](./06-channel-runtime.md)
- [执行内核：`runEmbeddedPiAgent()` 与 `runEmbeddedAttempt()` 的外层协调和单次 attempt 分工](./07-agent-runtime.md)
- [上下文工程：prompt 构建、hook 注入、system prompt override 与会话修复链](./08-context-engineering.md)
- [工具与策略：`exec-approvals.ts` 和 plugin runtime 暴露的 tools 面怎样约束执行](./09-tools-and-policy.md)
- [多会话协作：spawn metadata、workspace 继承与 session 工具链](./10-subagents-and-session-tools.md)
- [模型、认证与 failover：`loadModelCatalog()`、`runWithModelFallback()`、`resolveApiKeyForProvider()`、`resolveGatewayAuth()` 的组合](./11-model-provider-auth-failover.md)
- [控制面与运维：health、usage、update 与 Gateway runtime state 怎样组成长期运行宿主](./12-control-plane-and-ops.md)
- [建议阅读路径](./13-reading-path.md)
- [最终心智模型](./14-final-mental-model.md)
- [主链深挖](./15-source-code-deep-dive.md)
- [设计模式](./16-design-patterns.md)

## 先抓住五个源码判断

- `openclaw/src/entry.ts` 的入口判断先处理帮助、版本、profile 环境等轻路径，真正的 CLI 主链再延迟导入，这说明 OpenClaw 从进程入口开始就在区分“薄入口”和“厚运行时”（`openclaw/src/entry.ts:151-220`）。
- `agentViaGatewayCommand()` 并不直接跑 agent。它先校验 `--to/--session-id/--agent`，再调用 `resolveSessionKeyForRequest()` 生成目标 `sessionKey`，最后把请求交给 Gateway 的 `agent` method，这说明 CLI 只是控制面客户端（`openclaw/src/commands/agent-via-gateway.ts:88-179`）。
- Gateway 真正的宿主厚度在 `createGatewayRuntimeState()` 外围那层装配代码里：`channelManager`、`NodeRegistry`、订阅管理、cron、readiness、技能刷新和健康轮询都在启动时被拉起，所以它不是“转发到模型”的薄服务器，而是常驻控制面（`openclaw/src/gateway/server.impl.ts:627-760`）。
- 会话边界不是普通聊天 ID，而是 `buildAgentSessionKey()`、`buildAgentMainSessionKey()`、`buildAgentPeerSessionKey()` 产出的 `agent:<agentId>:...` 地址；`ResolvedAgentRoute` 还会同时计算 `mainSessionKey` 与 `lastRoutePolicy`，决定状态写回哪里（`openclaw/src/routing/resolve-route.ts:39-112`; `openclaw/src/routing/session-key.ts:19-174`）。
- 真正执行发生在 `runEmbeddedPiAgent()` 和 `runEmbeddedAttempt()`：前者做 lane 排队、workspace 决议、模型与 hook 外层协调，后者才做 prompt 组装、hook 注入、system prompt 覆盖和会话修复，所以 embedded runner 才是执行核（`openclaw/src/agents/pi-embedded-runner/run.ts:266-360`; `openclaw/src/agents/pi-embedded-runner/run.ts:879-980`; `openclaw/src/agents/pi-embedded-runner/run/attempt.ts:2410-2495`）。

## 最短源码路线

先读 `agentViaGatewayCommand()` 看外部请求如何进入 Gateway（`openclaw/src/commands/agent-via-gateway.ts:88-179`），再读 `server.impl.ts` 看 Gateway 怎样把 channels、nodes、cron、health 组装成宿主（`openclaw/src/gateway/server.impl.ts:627-760`），随后读 `resolve-route.ts` 和 `session-key.ts` 理解会话地址模型（`openclaw/src/routing/resolve-route.ts:39-112`; `openclaw/src/routing/session-key.ts:118-174`），最后再用 `run.ts` 和 `run/attempt.ts` 打通一次真实执行（`openclaw/src/agents/pi-embedded-runner/run.ts:266-360`; `openclaw/src/agents/pi-embedded-runner/run/attempt.ts:2415-2495`）。插件这条线不要单独看目录，要顺着 `createPluginRuntime()` 和 `plugins/loader.ts` 回看它怎样插入主链（`openclaw/src/plugins/runtime/index.ts:138-191`; `openclaw/src/plugins/loader.ts:966-1187`; `openclaw/src/plugins/loader.ts:1196-1329`）。
