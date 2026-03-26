# OpenCode 源码深度解析 A02：Server 与路由边界

> 本文基于 `opencode` `v1.3.2`（tag `v1.3.2`，commit `0dcdf5f529dced23d8452c9aa5f166abb24d8f7c`）源码校对

入口层之后，所有请求都会遇到同一个问题：怎样从一个 CLI/TUI/桌面/Web 入口，进入到当前工作目录、当前 workspace、当前 project 对应的 session runtime。这个边界就落在 `packages/opencode/src/server/server.ts` 和 `server/routes/*` 上。

---

## 1. Server 层的真实职责

`Server.createApp()` 做的并不是“处理 AI 对话”，而是五件更基础的事：

| 职责 | 代码坐标 | 说明 |
| --- | --- | --- |
| 错误归一化 | `server.ts:58-76` | 把 `NamedError`、`HTTPException`、未知异常统一成 HTTP JSON 响应。 |
| 认证与日志 | `server.ts:77-102` | Basic auth、请求日志、耗时统计。 |
| CORS | `server.ts:103-128` | 允许 localhost、Tauri、本域 `*.opencode.ai` 及显式传入白名单。 |
| 绑定 `WorkspaceContext` 与 `Instance` | `server.ts:192-218` | 从 query/header 解析 `workspace` 与 `directory`，进入正确的 project/runtime 作用域。 |
| 路由装配与兜底代理 | `server.ts:242-253`、`499-514` | 挂载业务路由；未知路径代理到 `app.opencode.ai`。 |

所以 Server 是 runtime 边界，不是 runtime 本体。

---

## 2. 中间件顺序不是随便排的

`createApp()` 当前中间件顺序有明确含义。

### 2.1 先统一错误出口

`58-76` 的 `onError` 先把错误语义收敛掉，后续路由可以直接抛错，不必每处都自己格式化 HTTP 响应。

### 2.2 再做 basic auth

`77-85` 会在非 `OPTIONS` 请求上执行 basic auth。也就是说，浏览器跨域预检不会被认证挡住，但真正业务请求会被挡住。

### 2.3 然后才是日志和 CORS

日志中间件 `86-102` 负责记录 path/method 和耗时；CORS `103-128` 决定哪些宿主可以直接在浏览器里连本地 server。

这一步之后，请求还没有进入任何 session/runtime 作用域。

### 2.4 最关键的一步：把请求绑定到正确的目录和 workspace

`192-218` 会从：

1. query `workspace` / header `x-opencode-workspace`
2. query `directory` / header `x-opencode-directory`

解析运行作用域，然后进入：

1. `WorkspaceContext.provide(...)`
2. `Instance.provide({ directory, init: InstanceBootstrap, fn })`

这意味着从这一层开始，后面的代码拿到的 `Instance.directory`、`Instance.worktree`、`Instance.project` 都已经是“当前请求对应的那份工程上下文”。

因此，workspace 隔离和多工程切换并不是靠 session id 猜出来的，而是靠 Server 中间件提前注入上下文。

---

## 3. 路由层的分工

`server.ts:242-253` 当前挂载的核心路由有：

1. `/global`：全局 health、全局配置、全局事件流。
2. `/project`：project 级信息。
3. `/session`：创建/更新/fork/message/prompt/command/revert 等核心 runtime 接口。
4. `/permission`：权限请求回复。
5. `/question`：问题澄清回复。
6. `/provider`：provider/model 配置。
7. `/event`：当前 `Instance` 作用域下的 SSE 事件流。
8. `/mcp`、`/pty`、`/config`、`/tui` 等外围能力。

当前工程里，真正把请求带入 agent runtime 的主入口仍然是 `/session`。

---

## 4. `/session` 路由不只是 “send message”

`packages/opencode/src/server/routes/session.ts:27-1031` 比一般聊天服务要厚很多，它至少覆盖了：

### 4.1 session 生命周期

1. `GET /session`：列 session。
2. `POST /session`：创建 session。
3. `PATCH /session/:id`：改标题、归档。
4. `POST /session/:id/fork`：fork session。
5. `DELETE /session/:id`：删 session。

### 4.2 message/part 生命周期

1. `GET /session/:id/message`：列 message，支持 cursor 分页，见 `547-631`。
2. `GET /session/:id/message/:messageID`：取单条 message，见 `634-670`。
3. `DELETE /session/:id/message/:messageID`：删 message，见 `672-706`。
4. `PATCH /session/:id/message/:messageID/part/:partID`：直接改某个 part，见 `743-779`。

### 4.3 runtime 动作

1. `POST /session/:id/message`：同步 prompt，见 `781-820`。
2. `POST /session/:id/prompt_async`：异步 prompt，见 `823-850`。
3. `POST /session/:id/command`：执行 command 模板，见 `854-888`。
4. `POST /session/:id/shell`：执行 shell 并写回 session，见 `891-920`。
5. `POST /session/:id/summarize`：主动创建 compaction 任务，见 `488-543`。
6. `POST /session/:id/revert` / `unrevert`：回滚与恢复，见 `923-985`。

所以 `/session` 不只是“聊天接口”，而是 runtime 级 API 面。

---

## 5. `POST /session/:id/message` 不是 token 流

这是当前文档里必须纠正的一点。

`session.ts:781-820` 的实现是：

1. 校验参数和 body。
2. 调 `SessionPrompt.prompt({ ...body, sessionID })`。
3. 把最终返回的 assistant message JSON 写回响应。

它用了 `hono/streaming` 的 `stream()`，但只是为了手动写 JSON，并没有把 token/reasoning/tool 事件直接通过这个响应体流出去。

真正的实时通道是：

1. `GET /event`，见 `server/routes/event.ts:13-84`
2. `GET /global/event`，见 `server/routes/global.ts:43-124`

这两个接口会把 `Bus` / `GlobalBus` 里的事件转成 SSE，CLI/TUI/桌面都是订阅这条流来刷新 UI 的。

---

## 6. `v1.3.2` 的事件作用域有两层

### 6.1 `GET /event`

`server/routes/event.ts` 订阅的是当前 `Instance` 里的 `Bus.subscribeAll()`，因此它只看当前 directory/workspace 作用域里的事件。

### 6.2 `GET /global/event`

`server/routes/global.ts` 订阅的是 `GlobalBus`，收到的是 `{ directory, payload }` 结构，适合桌面壳或控制平面监听多个 workspace/instance 的事件。

这也是为什么 `Bus.publish()` 里除了通知本地订阅者，还会额外 `GlobalBus.emit("event", { directory, payload })`。

---

## 7. `web` 命令背后的浏览器入口发生了什么

`Server.createApp()` 的最后一个 `.all("/*")`，见 `server.ts:499-514`，会把所有未命中的路径代理到 `https://app.opencode.ai${path}`。

这意味着：

1. server 路由优先处理 API。
2. 浏览器页面路径由远端 app shell 提供。
3. 浏览器里脚本再回头调当前本地 server 的 API。

所以这里的 Server 既是 API server，也是 web 壳的反向代理入口。

---

## 8. `Server.listen()` 只是把 Hono app 暴露出去

`server.ts:535-579` 的 `listen()` 逻辑相对直接：

1. 先 `createApp(opts)`。
2. 用 `Bun.serve({ fetch: app.fetch, websocket })` 起服务。
3. 支持端口回退策略：`port=0` 时先尝试 `4096`，失败再随机端口。
4. 可选发布 mDNS。

这说明 Server 层并没有把 session runtime 和网络 IO 耦死；无论是内存模式还是真实端口模式，本质上都是同一份 `app.fetch`。

---

## 9. 这一层对后续章节的意义

理解 A02 之后，后面几篇要带着两个前提继续读：

1. runtime 代码默认运行在已经绑定好的 `Instance`/`Workspace` 作用域里。
2. UI 更新主要靠 SSE 事件，而不是 prompt HTTP 响应体。

有了这两个坐标，再看 A03-A07 的 `prompt -> loop -> processor -> llm -> writeback`，就不会把 transport 和 runtime 混在一起。
