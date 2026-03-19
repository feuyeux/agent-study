# 架构总图：OpenClaw 的稳定骨架是 `Gateway -> Route -> SessionKey -> Embedded Runner -> Plugin Runtime`

不要按目录把 OpenClaw 看成“channels 一块、agents 一块、plugins 一块”。真正稳定的结构是五段串接，而每一段都在源码里有明确对象。

## 第一段：入口把请求送到 Gateway

`entry.ts` 负责把轻量命令和真正的 CLI 运行时拆开；`agentViaGatewayCommand()` 再把一条外部输入转成 Gateway `agent` 请求。入口层只做导流，不保存系统状态（`openclaw/src/entry.ts:151-220`; `openclaw/src/commands/agent-via-gateway.ts:88-155`）。

## 第二段：Gateway 决定谁来接这次执行

Gateway 的 `agent` method 校验参数、校验 `agentId/sessionKey` 一致性、校验 provider/model override 权限，这一层把“请求是否合法、属于谁”变成显式控制面逻辑（`openclaw/src/gateway/server-methods/agent.ts:155-217`; `openclaw/src/gateway/server-methods/agent.ts:312-326`）。

## 第三段：Route 和 SessionKey 决定真实身份

`ResolvedAgentRoute` 同时带 `sessionKey`、`mainSessionKey` 和 `lastRoutePolicy`，说明 OpenClaw 的路由结果不是“挑一个 agent”这么简单，而是同时定义了状态写回策略。`buildAgentSessionKey()` 再调用 `buildAgentPeerSessionKey()`，把 direct/group、channel/account、peer scope 编进可持久化地址（`openclaw/src/routing/resolve-route.ts:39-112`; `openclaw/src/routing/session-key.ts:118-174`）。

## 第四段：Embedded Runner 执行一次 turn

`runEmbeddedPiAgent()` 管 session/global lane、workspace 和模型外层协调；`runEmbeddedAttempt()` 管 prompt 构建、hook 注入、system prompt override、orphan user 修复和真正的 attempt 执行。执行核被拆成“两层循环 + 一层 prompt 管道”，不是一个大而全的 chat 函数（`openclaw/src/agents/pi-embedded-runner/run.ts:266-360`; `openclaw/src/agents/pi-embedded-runner/run.ts:879-980`; `openclaw/src/agents/pi-embedded-runner/run/attempt.ts:2415-2495`）。

## 第五段：Plugin Runtime 把整台宿主暴露为扩展面

`createPluginRuntime()` 暴露的不是几个 helper，而是 `agent`、`subagent`、`system`、`media`、`tts`、`webSearch`、`tools`、`channel`、`events`、`logging`、`state`、`modelAuth`。`plugins/loader.ts` 再在 discovery、manifest registry、duplicate resolution、boundary check、module load、register/activate 调用之间把扩展真正接进主系统（`openclaw/src/plugins/runtime/index.ts:138-189`; `openclaw/src/plugins/loader.ts:966-1187`; `openclaw/src/plugins/loader.ts:1196-1385`）。

## 这张图里最重要的横切面

- `sessionKey` 是并发和持久化边界，因为 runner 的 lane、workspace 和会话文件都围着它转（`openclaw/src/agents/pi-embedded-runner/run.ts:269-300`; `openclaw/src/routing/session-key.ts:73-174`）。
- Gateway 是长期运行宿主，因为 channels、nodes、cron、skills refresh、health monitor 都在它这层组装（`openclaw/src/gateway/server.impl.ts:627-760`）。
- Plugin Runtime 是平台化接口，因为渠道、工具、认证和子代理都通过同一 runtime 面进入系统（`openclaw/src/plugins/runtime/index.ts:138-189`）。

## 关键源码锚点

- 入口：`openclaw/src/entry.ts:151-220`
- 控制面请求：`openclaw/src/commands/agent-via-gateway.ts:88-179`
- 路由与 session：`openclaw/src/routing/resolve-route.ts:39-112`; `openclaw/src/routing/session-key.ts:118-174`
- 执行核：`openclaw/src/agents/pi-embedded-runner/run.ts:266-360`; `openclaw/src/agents/pi-embedded-runner/run/attempt.ts:2415-2495`
- 插件骨架：`openclaw/src/plugins/runtime/index.ts:138-189`; `openclaw/src/plugins/loader.ts:966-1385`

## 阅读问题

- 为什么 `ResolvedAgentRoute.lastRoutePolicy` 必须和 `mainSessionKey` 一起看？
- 如果把 Plugin Runtime 缩成只有 tools，会失去哪些平台级扩展点？
