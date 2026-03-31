# OpenCode A02：Server 与路由边界

> 本文基于 `opencode` `v1.3.2`（tag `v1.3.2`，commit `0dcdf5f529dced23d8452c9aa5f166abb24d8f7c`）源码校对

入口层之后，所有请求都会遇到同一个问题：怎样从一个 CLI/TUI/桌面/Web 入口，进入到当前工作目录、当前 workspace、当前 project 对应的 session runtime。这个边界就落在 `packages/opencode/src/server/server.ts` 和 `server/routes/*` 上。

---

## 概览：一条请求进入 runtime 要经历三个阶段

A01 解决了"多端入口如何收束到同一协议"，A02 要解决的是"请求进来之后，如何选中正确的工程上下文并分派到正确的处理函数"。

这条链可以划分为三个阶段：

```
HTTP 请求
  │
  ▼
第一阶段：基础设施层（与工程无关）
  onError → BasicAuth → RequestLogging → CORS
  此时请求还只是一个 HTTP 请求，不知道也不关心当前工程是谁。
  │
  ▼
第二阶段：上下文绑定层（划定工程边界）
  /global 路由（不依赖工程上下文的全局接口）
  → WorkspaceRouterMiddleware（workspace + directory 解析 + 绑定）
  → WorkspaceContext + Instance.provide（进入正确的 runtime 作用域）
  │
  ▼
第三阶段：业务路由层（依赖 Instance 的 API 面）
  /project → /session → /provider → /event → /mcp → /tui …
  从这里开始，请求进入某个 session 或 project 的业务域。
```

三层的核心区别在于：**第一层处理的是"HTTP 请求"，第二层处理的是"哪个工程"，第三层处理的才是"什么操作"**。

对应到代码文件：

- `server/server.ts:55-253` —— 前两个阶段的全部逻辑（中间件链 + 全局路由 + 上下文绑定）。
- `server/routes/session.ts` —— `/session` 路由，是 runtime 的 API 主入口。
- `server/routes/global.ts` —— `/global` 路由，全局事件和配置。
- `server/routes/event.ts` —— `/event` 路由，Instance 级 SSE。

---

## 第一阶段：基础设施层

`Server.createApp()` 最外层处理的是所有 HTTP 请求都要面对的通用问题，与"当前工程是谁"完全无关。

### 1.1 `onError` 是整条链的统一错误出口

`server.ts:58-76` 的 `onError` 是整条链的统一错误出口。后面的中间件和路由只管抛错，最后都由它收口成 HTTP 响应。

1. `NamedError` 会被转成稳定的 JSON 错误结构。
2. `NotFoundError` 返回 `404`，`Provider.ModelNotFoundError`、`ProviderAuthValidationFailed`、`Worktree*` 返回 `400`。
3. `HTTPException` 直接复用 Hono 已经准备好的响应。
4. 其他未知异常会被包成 `NamedError.Unknown`，并把 `stack` 或 `toString()` 写进 `message`。

所以这层解决的是"错误怎么出站"，不是"业务怎么处理"。

### 1.2 Basic auth 只挡业务请求

`server.ts:77-85` 这一层按三段式规则处理认证：

1. 如果是 `OPTIONS`，直接 `next()`，保证浏览器跨域预检先过。
2. 如果没配 `Flag.OPENCODE_SERVER_PASSWORD`，整层认证直接失效。
3. 只有真的配置了密码，才会用 `basicAuth()` 校验；用户名默认是 `opencode`，也可以被 `Flag.OPENCODE_SERVER_USERNAME` 覆盖。

这意味着浏览器里带 `Authorization` 的请求不会被 preflight 卡死，但正式请求仍然会被保护。

### 1.3 日志和 CORS 发生在任何工程上下文之前

`server.ts:86-128` 的日志和 CORS 都还不知道"当前工程是谁"。

1. 日志中间件先记录 `method/path`，`await next()` 之后再统计耗时；只有 `/log` 被显式跳过。
2. CORS 的 `origin()` 明确放行 `localhost`、`127.0.0.1`、Tauri 宿主、`https://*.opencode.ai`，以及 `createApp(opts)` 额外传入的白名单。

所以到这里为止，请求还只是"一个 HTTP 请求"，还没有进入 project/session 作用域。

---

## 第二阶段：上下文绑定层

基础设施就绪后，请求还缺少一个关键信息：**它指向哪个工程**。第二阶段的工作就是这件事。

### 2.1 先插入"全局接口"：与工程无关的边界

`server.ts:129-190` 先注册了 `/global`、`PUT /auth/:providerID`、`DELETE /auth/:providerID`，然后才去绑定 workspace 和 instance。

这个顺序本身就是语义：

1. `/global` 面向的是全局状态，不依赖某个具体目录。
2. `/auth/:providerID` 读写的是 provider 凭据，也不该绑定到某个 project。

`createApp()` 先挂"与工程无关"的接口，再挂"进入工程上下文后执行"的接口。

### 2.2 `WorkspaceContext + Instance` 才是 runtime 入口

`server.ts:192-218` 是整条链里的核心绑定层，请求会在这里进入某个 workspace 和目录。

1. 先从 query `workspace` 或 header `x-opencode-workspace` 取 `workspaceID`。
2. 再从 query `directory` 或 header `x-opencode-directory` 取目录；如果都没有，就退回 `process.cwd()`。
3. 目录值会先尝试 `decodeURIComponent()`，再经过 `Filesystem.resolve(...)` 规范化，避免后面拿到编码路径或相对路径。
4. 然后进入 `WorkspaceContext.provide(...)`。
5. 在这个上下文里，再进入 `Instance.provide({ directory, init: InstanceBootstrap, fn })`。

从这一层往后，路由里读到的 `Instance.directory`、`Instance.worktree`、`Instance.project` 对应的就是当前请求指向的工程。

多 workspace、多目录切换由 Server 在进入业务路由前完成上下文注入。

### 2.3 远端 workspace 会在这里被转发

紧接着的 `server.ts:219` 行 `WorkspaceRouterMiddleware` 还承担了一件额外的事：如果启用了 `Flag.OPENCODE_EXPERIMENTAL_WORKSPACES`，并且当前 workspace 是 remote，它会直接把请求转发给对应 adaptor。

`createApp()` 同时完成 workspace 选择与远端 workspace 转发决策。

---

## 第三阶段：业务路由层

上下文绑定完成后，请求进入"对某个工程做操作"的阶段。

### 3.1 路由总览与主入口

`server.ts:242-253` 当前挂载的核心路由有：

| 路由 | 职责 |
| --- | --- |
| `/global` | 全局 health、配置、事件流 |
| `/project` | project 级信息 |
| `/session` | 创建/更新/fork/message/prompt/command/revert 等核心 runtime 接口 |
| `/permission` | 权限请求回复 |
| `/question` | 问题澄清回复 |
| `/provider` | provider/model 配置 |
| `/event` | 当前 `Instance` 作用域下的 SSE 事件流 |
| `/mcp`、`/pty`、`/config`、`/tui` | 外围能力 |

当前工程里，把请求带入 agent runtime 的主入口是 `/session`。

### 3.2 `/session` 路由不只是 "send message"

`packages/opencode/src/server/routes/session.ts:27-1031` 比一般聊天服务要厚很多，它至少覆盖了：

#### 3.2.1 session 生命周期

1. `GET /session`：列 session。
2. `POST /session`：创建 session。
3. `PATCH /session/:id`：改标题、归档。
4. `POST /session/:id/fork`：fork session。
5. `DELETE /session/:id`：删 session。

#### 3.2.2 message/part 生命周期

1. `GET /session/:id/message`：列 message，支持 cursor 分页，见 `547-631`。
2. `GET /session/:id/message/:messageID`：取单条 message，见 `634-670`。
3. `DELETE /session/:id/message/:messageID`：删 message，见 `672-706`。
4. `PATCH /session/:id/message/:messageID/part/:partID`：直接改某个 part，见 `743-779`。

#### 3.2.3 runtime 动作

1. `POST /session/:id/message`：同步 prompt，见 `781-820`。
2. `POST /session/:id/prompt_async`：异步 prompt，见 `823-850`。
3. `POST /session/:id/command`：执行 command 模板，见 `854-888`。
4. `POST /session/:id/shell`：执行 shell 并写回 session，见 `891-920`。
5. `POST /session/:id/summarize`：主动创建 compaction 任务，见 `488-543`。
6. `POST /session/:id/revert` / `unrevert`：回滚与恢复，见 `923-985`。

所以 `/session` 不只是"聊天接口"，而是 runtime 级 API 面。

### 3.3 `POST /session/:id/message` 不是 token 流

这是当前文档里必须纠正的一点。

`session.ts:781-820` 的实现是：

1. 校验参数和 body。
2. 调 `SessionPrompt.prompt({ ...body, sessionID })`。
3. 把最终返回的 assistant message JSON 写回响应。

它用了 `hono/streaming` 的 `stream()`，但只是为了手动写 JSON，并没有把 token/reasoning/tool 事件直接通过这个响应体流出去。

实时通道位于：

1. `GET /event`，见 `server/routes/event.ts:13-84`
2. `GET /global/event`，见 `server/routes/global.ts:43-124`

这两个接口会把 `Bus` / `GlobalBus` 里的事件转成 SSE，CLI/TUI/桌面都是订阅这条流来刷新 UI 的。

### 3.4 `v1.3.2` 的事件作用域有两层

#### 3.4.1 `GET /event`

`server/routes/event.ts` 订阅的是当前 `Instance` 里的 `Bus.subscribeAll()`，因此它只看当前 directory/workspace 作用域里的事件。

#### 3.4.2 `GET /global/event`

`server/routes/global.ts` 订阅的是 `GlobalBus`，收到的是 `{ directory, payload }` 结构，适合桌面壳或控制平面监听多个 workspace/instance 的事件。

这也是为什么 `Bus.publish()` 里除了通知本地订阅者，还会额外 `GlobalBus.emit("event", { directory, payload })`。

### 3.5 `web` 命令背后的浏览器入口

`Server.createApp()` 的最后一个 `.all("/*")`，见 `server.ts:499-514`，会把所有未命中的路径代理到 `https://app.opencode.ai${path}`。

这意味着：

1. server 路由优先处理 API。
2. 浏览器页面路径由远端 app shell 提供。
3. 浏览器里脚本再回头调当前本地 server 的 API。

所以这里的 Server 既是 API server，也是 web 壳的反向代理入口。

---

## Server 层小结

`Server.createApp()` 定义了一条固定的进入顺序：

```
HTTP 请求
  → 兜底异常 → 认证 → 记录 → 放行跨域
  → 全局边界（与工程无关的接口）
  → 划定工程边界（workspace + directory → WorkspaceContext + Instance）
  → 业务路由（/session /project /provider /event …）
```

`Server.listen()` 相对直接：`createApp()` 后用 `Bun.serve({ fetch: app.fetch, websocket })` 暴露端口，支持端口回退（`port=0` 时先 `4096` 再随机），可选发布 mDNS。

理解 A02 之后，后续章节要带着两个前提继续读：

1. runtime 代码默认运行在已经绑定好的 `Instance`/`Workspace` 作用域里。
2. UI 更新主要靠 SSE 事件（`/event` / `/global/event`），而不是 prompt HTTP 响应体。

有了这两个坐标，再看 A03-A07 的 `prompt -> loop -> processor -> llm -> writeback`，就不会把 transport 和 runtime 混在一起。
