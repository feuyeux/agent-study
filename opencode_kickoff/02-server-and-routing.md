# Server 启动与请求路由：请求怎样进入 Hono 应用、穿过中间件、打到 SessionRoutes

> **总纲** [00-opencode_ko](./00-opencode_ko.md) · **分层定位** 第一层：宿主与入口层 → Server 内部
> **前置阅读** [01-user-entry](./01-user-entry.md)
> **后续阅读** [03-request-lifecycle](./03-request-lifecycle.md)

这一篇不再把 `Server.listen(opts)` 和 `Server.Default().fetch(request)` 笼统地叫成“两种启动方式”，而是先把名字定准，再按代码里的真实角色来讲：

- `Server.listen(opts)` 推荐命名为 **网络入口启动器**。
- `Server.Default()` 推荐命名为 **默认单例 Hono app**。
- `Server.Default().fetch(request)` 推荐命名为 **进程内请求派发入口**。

所以这篇真正要回答的是两个问题：

1. **请求从哪里进来**：来自 `Bun.serve()` 的网络 socket，还是来自进程内的 `fetch` 调用。
2. **请求进去之后发生什么**：经过哪些中间件、在哪一步绑定 `WorkspaceContext` / `Instance`、何时分流到 `SessionRoutes`、事件又如何回流给上游调用者。

---

## 一、两种请求入口

| 符号 | 真正角色 | 是否新建 app | 是否监听端口 | 典型上游 |
|------|----------|--------------|--------------|----------|
| `Server.listen(opts)` | 网络入口启动器 | 会，`createApp(opts)` 每次新建 | 会 | `serve`、`web`、`acp`、TUI worker 的 `rpc.server()`、本地 e2e |
| `Server.Default()` | 默认单例 Hono app | 只初始化一次，之后复用 | 否 | `run`、TUI worker、插件内部 fetch 的 app 宿主 |
| `Server.Default().fetch(request)` | 进程内请求派发入口 | 不会新建 app，只复用 `Server.Default()` | 不会 | `run` 本地模式、TUI worker 的 `event`/`rpc.fetch`、插件内部 SDK |

这两条路径在 **transport 层** 不同，但进入 `app.fetch` 之后，会走同一套 Hono 中间件和同一套路由。

后文会统一使用下面这组简称：

- **网络入口** = `Server.listen(opts)`
- **默认 app** = `Server.Default()`
- **进程内派发** = `Server.Default().fetch(request)`

### 1. 网络入口：`Server.listen(opts)`

`packages/opencode/src/server/server.ts` 里的 `listen(opts)` 做的不是一句“起服务”，而是下面这一整段装配：

```text
上游调用者
  -> Server.listen(opts)
      -> 设置共享的 Server.url（代码里已标注 deprecated）
      -> createApp(opts)           // 每次 listen 都新建一棵 Hono app
      -> 组装 Bun.serve 参数
           hostname
           idleTimeout: 0
           fetch: app.fetch
           websocket: websocket
      -> 选端口
           opts.port !== 0: 直接尝试该端口
           opts.port === 0: 先试 4096，失败再试随机端口 0
      -> 如满足条件则 MDNS.publish(server.port, opts.mdnsDomain)
      -> 包装 server.stop()，停止时先 unpublish mDNS
      -> 返回 Bun server 实例
```

这里有三个容易被文档说粗的点：

1. **`listen()` 不是复用 `Server.Default()`**  
   它会 `createApp(opts)` 新建一棵 app，因此能带上 `opts.cors` 这样的 per-server 配置。

2. **端口策略不是“默认 4096，否则随机”这么简单**  
   只有 `opts.port === 0` 时，才会先试 `4096`，失败再回退到随机端口；如果明确传了固定端口，就只试那个端口。

3. **返回值不是抽象 server 描述，而是真正的 Bun server**  
   上游可以直接读 `server.port`、`server.hostname`、`server.url`，也可以 `await server.stop(true)`。

#### `Server.listen(opts)` 的上游

当前仓库里，明确的调用点有：

| 上游 | 作用 |
|------|------|
| `cli/cmd/serve.ts` | 启动 headless server，纯粹暴露 HTTP 接口 |
| `cli/cmd/web.ts` | 启动 server 后打开浏览器，供 web UI 访问 |
| `cli/cmd/acp.ts` | 启动 HTTP server，再把 SDK 接到 ACP 流式连接上 |
| `cli/cmd/tui/worker.ts` 的 `rpc.server()` | TUI 需要对外暴露服务时，按需启动 Bun server |
| `packages/app/script/e2e-local.ts` | 本地 e2e 测试环境先拉起 server，再跑测试 |

#### `Server.listen(opts)` 的下游

`listen()` 自己不处理业务，它只负责把外部 HTTP 请求送进 `app.fetch`：

```text
外部客户端 / 浏览器 / SDK / ACP
  -> TCP socket
  -> Bun.serve(..., fetch: app.fetch)
  -> Hono app.fetch(request)
  -> 中间件链
  -> 路由分发
  -> SessionRoutes / FileRoutes / EventRoutes / ...
  -> SessionPrompt / Session / Bus / File / Provider / ...
```

也就是说，`listen()` 的直接下游是 **Hono app 的 `fetch`**；真正的业务下游要到路由层之后才开始。

### 2. 进程内派发：`Server.Default().fetch(request)`

`Server.Default` 的定义是：

```ts
export const Default = lazy(() => createApp({}))
```

这里要拆成两个名字看：

- `Server.Default()` 不是 “default server”，而是 **默认配置下的单例 app factory**
- `Server.Default().fetch(request)` 才是 **进程内派发入口**

第一次调用 `Server.Default()` 时才真正执行 `createApp({})`，后续复用同一个 Hono app。

所以 `Server.Default().fetch(request)` 的真实语义是：

```text
我已经在当前进程里有一棵默认配置的 Hono app
现在不给它绑定端口
也不经过 Bun 的监听 socket
而是把一个 Request 直接交给 app.fetch(request)
```

#### `Server.Default().fetch(request)` 的上游

当前仓库里，明确的调用点有：

| 上游 | 作用 |
|------|------|
| `cli/cmd/run.ts` | `run` 命令在未 `--attach` 到外部 server 时，给 SDK 注入自定义 `fetch`，直接打到本进程 app |
| `cli/cmd/tui/worker.ts` 的 `startEventStream()` | TUI worker 用进程内 `fetch` 订阅 `/event` SSE |
| `cli/cmd/tui/worker.ts` 的 `rpc.fetch()` | TUI 主进程通过 RPC 把 HTTP 请求交给 worker，再由 worker 进程内派发 |
| `plugin/index.ts` | 内部插件拿到一个 SDK client，底层 `fetch` 直接指向 `Server.Default().fetch` |

注意，这里说“CLI 本地模式”太粗。准确说法应该是：**`run` 命令本地模式、TUI worker 的内嵌 SDK 调用、以及插件层内部 SDK 调用**。

#### `Server.Default().fetch(request)` 的下游

这条链比 `listen()` 少了一层网络 transport，但从 `app.fetch` 开始完全一致：

```text
run / tui worker / plugin
  -> 构造 Request
  -> Server.Default()           // lazy 单例 app
  -> app.fetch(request)
  -> 同一套中间件链
  -> 同一套路由
  -> 同一批业务模块
```

这意味着它和 `listen()` 的差异只在：

- **有无网络监听**
- **是否有独立 server 生命周期**
- **是否能携带 `listen(opts)` 级别的 CORS 配置**

而不在 Session、File、Event 这些业务处理逻辑上。

---

## 二、`createApp(opts)`：真正的 Server 组装中心

无论入口是 `listen()` 还是 `Default().fetch()`，真正决定请求如何被处理的，都是 `createApp(opts)`。

它不是简单“创建一个 Hono 实例然后挂路由”，而是按下面顺序装配：

```text
onError
  -> Basic Auth middleware
  -> request logging middleware
  -> CORS middleware
  -> /global routes
  -> /auth/:providerID (PUT/DELETE)
  -> WorkspaceContext + Instance middleware
  -> WorkspaceRouterMiddleware
  -> /doc
  -> 通用 query validator(directory/workspace)
  -> 业务 routes
  -> fallback proxy to https://app.opencode.ai/*
```

### 1. 错误边界：`onError`

这是整个 app 的全局错误出口：

- `NamedError` 会按类型映射成 `404 / 400 / 500`
- `HTTPException` 直接返回 Hono 自带响应
- 其他异常被包装成 `NamedError.Unknown`

所以从路由往下抛出的异常，最终都会回到这里统一转成 HTTP 响应。

### 2. Basic Auth 中间件：先于日志、先于 CORS

代码顺序上，认证中间件在最前面：

- `OPTIONS` 预检请求直接放过
- 如果没有 `OPENCODE_SERVER_PASSWORD`，则整个中间件形同空操作
- 否则按 `OPENCODE_SERVER_USERNAME` / `OPENCODE_SERVER_PASSWORD` 校验 Basic Auth

这和旧文档把 “CORS 在前、Auth 在后” 的描述是相反的。真实执行顺序应以代码为准。

### 3. 请求日志中间件

这里会记录：

- `method`
- `path`
- request timer

`/log` 会跳过普通请求日志，以免日志上报本身制造噪音。

### 4. CORS 中间件

这一层才开始做跨域 origin 白名单判断。允许的来源主要有：

- `http://localhost:*`
- `http://127.0.0.1:*`
- tauri 相关 origin
- `https://*.opencode.ai`
- `listen(opts)` 传入的 `opts.cors`

因此只有 **网络入口** `Server.listen(opts)` 能注入自定义 CORS；**默认 app** `Server.Default()` 走的是 `createApp({})`，没有额外的 cors 白名单。

### 5. 先挂全局路由，再做实例绑定

接着 `createApp()` 先挂的是：

- `.route("/global", GlobalRoutes())`
- `PUT /auth/:providerID`
- `DELETE /auth/:providerID`

这些端点在代码位置上 **早于** `WorkspaceContext` / `Instance` 绑定中间件。

### 6. `WorkspaceContext` + `Instance` 绑定：这是本地请求最关键的一跳

真正把请求绑定到具体项目目录的是这一段中间件：

1. 从 query/header 读取：
   - `workspace` 或 `x-opencode-workspace`
   - `directory` 或 `x-opencode-directory`
   - 如果都没有，目录回退到 `process.cwd()`
2. 对目录做 `decodeURIComponent` 和 `Filesystem.resolve`
3. `WorkspaceContext.provide({ workspaceID, fn })`
4. 在 `fn` 内层再执行 `Instance.provide({ directory, init: InstanceBootstrap, fn: next })`

到这里为止，请求已经拿到了：

- 当前 workspace 维度上下文
- 当前 project `Instance`
- `Instance.directory`
- `Instance.worktree`
- 后续会复用的实例级缓存与服务

所以旧文档里那句“中间件链最后一环是 Instance 绑定”也不够准。更准确的说法是：**在进入大部分业务路由前，请求会先完成 workspace 和 instance 的双重绑定。**

### 7. `WorkspaceRouterMiddleware`：不是“按目录选 Instance”，而是“必要时转发到远端 workspace”

这是旧文档里另一个关键误差。

`WorkspaceRouterMiddleware` 的职责不是在本地挑选 `Instance`。本地 `Instance` 在前一个中间件里已经通过 `Instance.provide(...)` 绑定好了。

它真正做的是：

- 只有 `OPENCODE_EXPERIMENTAL_WORKSPACES` 打开时才生效
- 如果当前请求带有 `WorkspaceContext.workspaceID`
- 就去查这个 workspace 的类型与配置
- 再调用对应 adaptor 的 `fetch(...)`
- 一旦 adaptor 返回了响应，本地后续路由链就被短路

例如 `worktree` adaptor 会：

```text
收到控制面请求
  -> 给请求补上 x-opencode-directory
  -> WorkspaceServer.App().fetch(request)
  -> 由 workspace server 里的 SessionRoutes / WorkspaceServerRoutes 继续处理
```

所以这一步的真实语义是 **“跨 workspace 转发”**，不是 **“本地多目录路由”**。

### 8. 路由挂载与真实 URL 前缀

旧文档把一些挂载前缀写成了“概念分组”，但代码里并不都是那个 URL。按 `createApp()` 的真实挂载顺序：

| 挂载方式 | 实际 URL 形态 | 主要下游 |
|----------|---------------|----------|
| `.route("/project", ProjectRoutes())` | `/project/*` | 项目元信息 |
| `.route("/pty", PtyRoutes())` | `/pty/*` | PTY 生命周期 |
| `.route("/config", ConfigRoutes())` | `/config/*` | 配置读写 |
| `.route("/experimental", ExperimentalRoutes())` | `/experimental/*` | 实验功能 |
| `.route("/session", SessionRoutes())` | `/session/*` | session、prompt、command、shell |
| `.route("/permission", PermissionRoutes())` | `/permission/*` | 权限确认 |
| `.route("/question", QuestionRoutes())` | `/question/*` | 问题答复 |
| `.route("/provider", ProviderRoutes())` | `/provider/*` | provider / model |
| `.route("/", FileRoutes())` | `/find`、`/find/file`、`/find/symbol`、`/file` 等 | 文件/搜索 |
| `.route("/", EventRoutes())` | `/event` | SSE 事件订阅 |
| `.route("/mcp", McpRoutes())` | `/mcp/*` | MCP 管理 |
| `.route("/tui", TuiRoutes())` | `/tui/*` | TUI 专用端点 |
| 直接定义 | `/instance/dispose`、`/path`、`/vcs`、`/command`、`/log`、`/agent`、`/skill`、`/lsp`、`/formatter` | 各类全局/实例接口 |
| `.all("/*")` | 其余未命中的路径 | 反代到 `https://app.opencode.ai/*` |

尤其要注意两点：

1. **`EventRoutes` 不是挂在 `/event` 前缀下，而是挂在根路径，再由内部 route 定义出 `/event`。**
2. **`FileRoutes` 也不是 `/file/*` 整体前缀，而是根路径下的一组搜索/文件端点。**

---

## 三、先看汇合点：所有入口都先汇合到 `app.fetch`

第三节开始不要直接跳进 `SessionPrompt`。更稳的读法是先看 **所有入口在 Server 内部的共同汇合点**，再看汇合之后怎样分流。

```text
网络入口
  外部客户端
    -> Server.listen(opts)
    -> Bun.serve({ fetch: app.fetch })
    -> app.fetch(request)

进程内入口
  run / tui worker / plugin
    -> Server.Default().fetch(request)
    -> app.fetch(request)
```

这一步之后，两条链就已经没有差别了。后面的执行顺序统一都是：

```text
app.fetch(request)
  -> createApp(...) 中间件链
  -> 路由匹配
  -> SessionRoutes / FileRoutes / EventRoutes / ...
```

代码定位：

- `packages/opencode/src/server/server.ts:45-46`
- `packages/opencode/src/server/server.ts:535-572`
- `packages/opencode/src/cli/cmd/run.ts:664-671`
- `packages/opencode/src/cli/cmd/tui/worker.ts:52-57`
- `packages/opencode/src/plugin/index.ts:58-69`

所以第三节最该记住的不是“listen 和 fetch 都能进来”，而是：

> **无论从网络进，还是从进程内进，只要走到 `app.fetch(request)`，后面的 Server 处理链就是同一条。**

---

## 四、再看分流点：`SessionRoutes` 把请求分成三类

如果请求目标是 agent/runtime，真正的 HTTP 分流点在 `SessionRoutes`，不是在 `SessionPrompt`。

先把这几个端点按“下游形态”分组：

| 路由 | 直接下游 | 运行语义 |
|------|----------|----------|
| `POST /session/:sessionID/message` | `SessionPrompt.prompt()` | 同步等待 prompt 主链完成，并把最终 message 写回响应体 |
| `POST /session/:sessionID/prompt_async` | `SessionPrompt.prompt()` | 只启动 prompt 主链，立刻返回 `204` |
| `POST /session/:sessionID/command` | `SessionPrompt.command()` | 先展开 slash command，再回落到 `prompt()` |
| `POST /session/:sessionID/shell` | `SessionPrompt.shell()` | 直接执行 shell，并把结果写成 session message |

代码定位：

- `packages/opencode/src/server/routes/session.ts:782-920`

也就是说，这里不是“一条 message 路由 + 两个变体”，而是 **三种运行路径**：

```text
SessionRoutes
  -> prompt family
       /message
       /prompt_async
  -> command family
       /command
  -> shell family
       /shell
```

### 1. prompt family：`/message` 和 `/prompt_async` 共享同一条核心主链

这两条路由最容易写乱，因为它们的差异发生在 **HTTP 响应策略**，而不是 runtime 主链。

#### 入口差异

```text
/session/:sessionID/message
  -> validator(...)
  -> await SessionPrompt.prompt(...)
  -> stream.write(JSON.stringify(msg))
  -> HTTP 200

/session/:sessionID/prompt_async
  -> validator(...)
  -> SessionPrompt.prompt(...)
  -> 不等待结果
  -> HTTP 204
```

代码定位：

- `/session/:sessionID/message`：`packages/opencode/src/server/routes/session.ts:782-820`
- `/session/:sessionID/prompt_async`：`packages/opencode/src/server/routes/session.ts:823-851`

#### 共享主链

这两条路由进入 `SessionPrompt.prompt()` 之后，才真正并到同一条 runtime 主链：

```text
SessionRoutes.message / SessionRoutes.prompt_async
  -> SessionPrompt.prompt(input)
       -> Session.get(...)
       -> SessionRevert.cleanup(...)
       -> createUserMessage(...)
       -> Session.touch(...)
       -> 可选：旧 tools 参数转 permission
       -> SessionPrompt.loop(...)
  -> SessionPrompt.loop(input)
       -> start/resume session abort state
       -> SessionStatus.set(..., busy)
       -> 扫描消息流，确定 lastUser / lastAssistant / pending task
       -> 分支：
            subtask
            compaction
            normal processing
       -> normal processing 时创建 SessionProcessor
       -> resolveTools(...)
       -> SessionSummary.summarize(...)
       -> processor.process(...)
```

代码定位：

- `prompt()`：`packages/opencode/src/session/prompt.ts:162-189`
- `createUserMessage()`：`packages/opencode/src/session/prompt.ts:966-1496`
- `loop()` 入口、busy 状态、历史扫描：`packages/opencode/src/session/prompt.ts:274-357`
- `loop()` 正常处理分支、`SessionProcessor.create(...)`、`resolveTools(...)`、`SessionSummary.summarize(...)`：`packages/opencode/src/session/prompt.ts:561-667`

这里叙事上最容易混淆的点是：

- **`/message` 和 `/prompt_async` 的区别不在 runtime 核心逻辑，而在“HTTP 这一跳是否等待结果”。**
- **真正的 runtime 主链是 `prompt() -> loop()`，不是 `route -> loop()`。**

### 2. command family：`/command` 先做模板展开，再回落到 prompt 主链

`/session/:sessionID/command` 不是直接进入 `loop()`，也不是单独的一套 runtime。它先把 slash command 解释成一次普通 prompt，再回到上面的 prompt family 主链。

```text
POST /session/:sessionID/command
  -> SessionPrompt.command(input)
       -> Command.get(input.command)
       -> 展开 $1 / $2 / $ARGUMENTS
       -> 解析模板里的 !`...` shell 内联片段
       -> 推导 agent / model
       -> Plugin.trigger("command.execute.before", ...)
       -> prompt(...)
       -> loop(...)
```

代码定位：

- 路由入口：`packages/opencode/src/server/routes/session.ts:854-887`
- `CommandInput` 与 `command()`：`packages/opencode/src/session/prompt.ts:1749-1924`

所以正确叙事不是“command 路由和 message 路由差不多”，而是：

> **`/command` 是 prompt 主链前面的一个解释层。**

### 3. shell family：`/shell` 不回落到 prompt 主链

`/session/:sessionID/shell` 的语义和上面两类都不同。它不是把输入交给 LLM 继续推理，而是直接在 server 侧执行一次 shell，再把结果写成 session message / part。

```text
POST /session/:sessionID/shell
  -> SessionPrompt.shell(input)
       -> start(sessionID)
       -> Session.get(...)
       -> 写入 user message
       -> 写入 assistant message
       -> 写入 tool part(status=running)
       -> spawn(shell, args, ...)
       -> 持续更新 tool part metadata/output
       -> 结束后把 tool part 标记 completed/error
       -> 返回 { info, parts }
```

代码定位：

- 路由入口：`packages/opencode/src/server/routes/session.ts:891-919`
- `ShellInput` 与 `shell()`：`packages/opencode/src/session/prompt.ts:1498-1746`

所以从调用关系上看：

```text
/message, /prompt_async
  -> prompt()
  -> loop()

/command
  -> command()
  -> prompt()
  -> loop()

/shell
  -> shell()
  -> 直接写消息与 tool part
```

---

## 五、最后看回流：运行态不是主要靠 HTTP body 返回，而是靠 `/event`

前面是“请求怎么进去”，这一节才是“状态怎么出来”。

`EventRoutes` 的职责很简单，但在叙事上必须放在最后讲，因为它依赖前面的 runtime 已经开始发布事件。

```text
客户端订阅 /event
  -> 先收到 server.connected
  -> 每 10s 收到 server.heartbeat
  -> EventRoutes 订阅 Bus.subscribeAll(...)
  -> 任何 runtime 事件都被转成 SSE data
  -> 客户端持续消费这些事件
```

代码定位：

- `/event` 路由实现：`packages/opencode/src/server/routes/event.ts:13-85`

把完整调用链画成一张图，会比文字更稳：

```text
请求入口
  -> app.fetch(request)
  -> SessionRoutes
     -> /message -----------\
     -> /prompt_async ------+-> SessionPrompt.prompt -> SessionPrompt.loop -> SessionProcessor -> Bus.publish(...)
     -> /command -----------/         ^
           -> SessionPrompt.command --|
                                      |
     -> /shell -> SessionPrompt.shell -+-> Session.updateMessage / Session.updatePart -> Bus.publish(...)

事件出口
  Bus.subscribeAll(...)
    -> EventRoutes(/event)
    -> SSE
    -> run / tui worker / web
```

下游消费者代码定位：

- `run.ts` 订阅事件流：`packages/opencode/src/cli/cmd/run.ts:441-447`
- `tui/worker.ts` 用进程内 `fetch` 订阅 `/event`：`packages/opencode/src/cli/cmd/tui/worker.ts:52-85`

因此应该这样理解返回路径：

- `/session/:sessionID/message` 会回一个最终 message JSON，但**运行中的增量状态**仍主要走 `/event`
- `/session/:sessionID/prompt_async` 不回结果体，**全部运行状态**都靠 `/event`
- `/session/:sessionID/command` 由于最后回落到 `prompt() -> loop()`，它的增量状态也主要靠 `/event`
- `/session/:sessionID/shell` 虽然直接返回 `{ info, parts }`，但 tool part 的更新同样会进入事件流

---

## 六、最该记住的五句话

1. **先看汇合点，再看分流点，再看回流点。第三节之后的主线应该是 `app.fetch -> SessionRoutes -> SessionPrompt/Session -> Bus/EventRoutes`。**
2. **`/message` 和 `/prompt_async` 共享同一条 `prompt() -> loop()` 主链，区别只在 HTTP 响应策略。**
3. **`/command` 不是并列 runtime，它只是 prompt 主链前面的一个解释层。**
4. **`/shell` 不回落到 `prompt() -> loop()`，而是直接执行 shell 并写入 message / tool part。**
5. **真正的实时回流出口是 `/event`；HTTP body 只负责返回一次性的受理结果或最终结果。**
