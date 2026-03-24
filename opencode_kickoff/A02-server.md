# OpenCode 源码深度解析 A02：Server 与路由：请求如何跨过 Hono 边界并进入 Session Runtime

`server.ts` 和 `routes/session.ts` 负责认证、CORS、workspace 代理、参数校验和 runtime 入口切换，但不负责任何 AI 调度决策。

## 一、代码坐标

| 主题 | 文件与代码行 | 细节 |
| --- | --- | --- |
| 默认 app 工厂 | `packages/opencode/src/server/server.ts:53-55` | `Server.Default = lazy(() => createApp({}))`。 |
| 错误处理与认证 | `packages/opencode/src/server/server.ts:58-85` | `NamedError -> HTTP` 映射，加 Basic Auth。 |
| 请求日志与 CORS | `packages/opencode/src/server/server.ts:86-128` | 统一日志、允许 localhost/tauri/opencode.ai 源。 |
| 路由挂载 | `packages/opencode/src/server/server.ts:129-253` | `/session`、`/permission`、`/question`、`/event` 等都在这里接入。 |
| workspace 路由代理 | `packages/opencode/src/control-plane/workspace-router-middleware.ts:38-49` | 实验开关打开时先尝试转发到远端 workspace。 |
| 实际远端转发 | `packages/opencode/src/control-plane/workspace-router-middleware.ts:9-35` | `adaptor.fetch(workspace, path, { method, body, headers })`。 |
| session 路由对象 | `packages/opencode/src/server/routes/session.ts:25-27` | `SessionRoutes = lazy(() => new Hono()...)`。 |
| prompt 入口 | `packages/opencode/src/server/routes/session.ts:781-820` | 校验 `PromptInput`，调用 `SessionPrompt.prompt()`。 |
| async prompt | `packages/opencode/src/server/routes/session.ts:823-850` | 204 立即返回，后台继续跑。 |
| command/shell 入口 | `packages/opencode/src/server/routes/session.ts:853-919` | 直接切到 `SessionPrompt.command()` / `shell()`。 |

## 二、`createApp()` 只负责“挂环境”，不负责“跑 agent”

`packages/opencode/src/server/server.ts:55-128` 的顺序很关键：

1. `58-76` 先把 `NamedError`、`NotFoundError`、`Provider.ModelNotFoundError` 等统一翻成 HTTP 响应。
2. `77-85` 再根据 `OPENCODE_SERVER_PASSWORD` 决定是否开启 Basic Auth。
3. `86-102` 包一层请求日志。
4. `103-128` 挂 CORS 策略。

这意味着后续的 `/session` 路由拿到的已经是“认证过、带日志、带跨域规则”的请求上下文。

## 三、workspace 隔离不是靠 session id 猜测，而是靠前置代理

workspace 相关请求处理的核心逻辑位于 `packages/opencode/src/control-plane/workspace-router-middleware.ts:38-49`：

- 只有 `Flag.OPENCODE_EXPERIMENTAL_WORKSPACES` 打开才启用。
- `routeRequest()` 会在 `9-35` 读取 `WorkspaceContext.workspaceID`，查出 workspace，再调用适配器的 `fetch()` 把请求整体转发出去。
- 目前注释明确写了“Right now, we need to forward all requests”，说明这里不是轻量 metadata 注入，而是 mutation 级请求代理。

## 四、`/session/:id/message` 只是 runtime 边界，不是流式渲染通道

`packages/opencode/src/server/routes/session.ts:781-820` 的真实逻辑是：

- `804-810` 校验 path param 和 JSON body。
- `814-819` 用 Hono `stream()` 包一层响应。
- `817` 真正调用 `SessionPrompt.prompt({ ...body, sessionID })`。
- `818` 只把最终 `msg` JSON 写回当前 HTTP 响应。

实时 UI 更新主要依赖 `/event` 路由订阅的 bus 事件，而不是这条 POST 持续输出 token。

## 五、SessionRoutes 里还有三个容易漏掉的入口

1. `packages/opencode/src/server/routes/session.ts:293-324` 的 `/:sessionID/init` 负责会话初始化。
2. `packages/opencode/src/server/routes/session.ts:487-544` 的 `/:sessionID/summarize` 会先 `SessionRevert.cleanup()`，再创建 compaction user message，最后显式调用 `SessionPrompt.loop()`。
3. `packages/opencode/src/server/routes/session.ts:698-778` 的 message/part 删除与 patch 更新，直接操作 durable history，而不是走模型。

## 六、结论

1. Server 负责中间件、路由和参数校验，runtime 仍从 `SessionPrompt.*` 开始。
2. workspace 隔离采用请求级代理，核心坐标在 `workspace-router-middleware.ts:9-49`。
3. `/session/:id/message` 只负责把请求交给 runtime 并返回最终 message；实时渲染依赖 bus 事件，不依赖这条 POST 的响应体。
