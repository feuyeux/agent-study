# OpenCode A01：多端入口与传输适配

> 本文基于 `opencode` `v1.3.2`（tag `v1.3.2`，commit `0dcdf5f529dced23d8452c9aa5f166abb24d8f7c`）源码校对

OpenCode 的入口层覆盖默认 TUI、一次性 `run`、`attach`、`serve`、`web`、`acp`、桌面 sidecar 等多种形态。阅读这一层时，重点在于 transport 与宿主怎样收束到同一个 HTTP/session 协议上。

---

## 1. 入口总览

| 入口 | 代码坐标 | 传输方式 | 最后进入哪里 |
| --- | --- | --- | --- |
| 默认 TUI (`opencode`) | `packages/opencode/src/index.ts:126-151`、`cli/cmd/tui/thread.ts:66-231` | 本地 worker RPC，必要时也可起外部 HTTP server | 同一套 `Server.fetch()` / `/event` 协议 |
| 一次性 `run` | `cli/cmd/run.ts:221-675` | 本地 in-process fetch 或远端 HTTP attach | `session.prompt` / `session.command` |
| `attach <url>` | `cli/cmd/tui/attach.ts:9-88` | 远端 HTTP + SSE | 远端 server 的 `/session`、`/event` |
| `serve` | `cli/cmd/serve.ts:9-23` | 纯 HTTP server | `Server.listen()` |
| `web` | `cli/cmd/web.ts:31-80` | 本地 HTTP server，再打开浏览器 | `Server.listen()`，未知路径代理到 `app.opencode.ai` |
| `acp` | `cli/cmd/acp.ts:12-69`、`acp/agent.ts` | stdin/stdout NDJSON + 本地 HTTP SDK | 同一套 `/session`、`/permission`、`/event` |
| 桌面端 | `packages/desktop/src/index.tsx:432-458`、`packages/desktop-electron/src/main/server.ts:32-57` | sidecar server + `@opencode-ai/app` | 同一套 HTTP/SSE server 连接 |

结论先说在前面：**OpenCode 没有多套 runtime，只有多套 transport 和宿主。**

---

## 2. CLI 主进程先完成运行环境准备

入口注册位于 `packages/opencode/src/index.ts`：

1. `yargs` 注册所有命令，见 `50-151`。
2. 中间件里初始化日志、设置 `AGENT=1` / `OPENCODE=1` / `OPENCODE_PID`，见 `67-86`。
3. 首次启动时检查数据库并执行 JSON -> SQLite 迁移，见 `87-122`。

这一步的意义是：

1. 任何入口都共享同一个全局数据库和日志系统。
2. runtime 之前先完成安装态准备，后面的命令处理逻辑不需要再关心迁移问题。

`index.ts` 负责 CLI 壳层与全局初始化，各个子命令负责进入 agent runtime。

---

## 3. `run` 命令：两条 transport 路径的结构化解析

`RunCommand` `packages/opencode/src/cli/cmd/run.ts:221-675` 的核心结构是**输入整理 → transport 选择 → SDK 请求 → 事件消费**四步。其中 transport 选择最值得细读。

### 3.1 `run` 命令完整流程

```
输入整理 (306-394)
  → transport 选择：local fetchFn 或 remote baseUrl (655-673)
  → SDK 请求：session.prompt / session.command / session.shell
  → 事件消费：sdk.event.subscribe() → 终端渲染
```

### 3.2 两条 transport 路径

`run.ts:655-673` 根据 `--attach` 参数决定走哪条路径：

| | 本地模式（默认） | 远端模式（`--attach <url>`） |
|---|---|---|
| 代码位置 | `667-673` | `655-664` |
| transport 构造 | `fetchFn = req => Server.Default().fetch(req)` | `createOpencodeClient({ baseUrl, headers })` |
| HTTP 栈 | 无 — 直接调 Hono `app.fetch()` | 真实 TCP，发往远端 |
| basic auth | 无 | 有，带上 `Authorization` header |
| 目录参数 | 用 `process.cwd()`，无需传 | 必须通过 header/query 传 |
| 场景 | 本地一次性执行 | 连已有 server 做交互 |

#### 1. 本地模式：内存 fetch，绕过 socket 层

本地模式的 transport 构造是：

```ts
// run.ts:667-673
const fetchFn = async (input, init) =>
  Server.Default().fetch(new Request(input, init))
```

这里 `Server.Default()` 是 `lazy(() => createApp({}))` 的单例，`fetchFn` 把 SDK 发出的标准 `Request` 直接交给 Hono app 的 `fetch` handler。整个过程没有任何网络 IO，SDK 的 HTTP 语义在内存层就闭合了。

#### 2 远端模式：构造带 auth 的 SDK client

远端模式的 transport 构造是：

```ts
// run.ts:655-664
createOpencodeClient({ baseUrl: args.attach, headers: { Authorization: `Basic ${credentials}` } })
```

连到远端 server 时，SDK 请求经过真实 TCP 栈，directory 必须显式通过 `x-opencode-directory` header 传给 server（因为远端 server 的 `process.cwd()` 是 server 进程所在目录，不是客户端当前目录）。

### 3.3 事件消费：两条路径共用同一套 SSE 逻辑

`run.ts:411-558` 在**两条 transport 路径下执行完全相同的逻辑**：

```ts
await sdk.event.subscribe()   // 订阅 SSE
// 收到 message.part.updated  → 渲染到终端
// 收到 session.status        → 更新状态
// 收到 permission.asked    → 自动 deny
// 收到 session.error        → 打印错误
```

**关键事实**：`run` 的终端输出不来自 `prompt()` 的返回值，而来自 SSE 事件流。无论本地还是远端模式，`session.prompt()` 本身只返回最终 assistant message JSON，token 流和中间状态都通过 `/event` SSE 推回。

---

## 4. 默认 TUI 入口：transport 抽象比 `run` 更厚一层

`TuiThreadCommand`，位于 `packages/opencode/src/cli/cmd/tui/thread.ts:66-231`。

这一层把"本地 worker 模式"和"外部 server 模式"统一成同一套前端依赖：

### 4.1 TUI 主线程不直接碰 runtime

`132-169` 会先启动 `Worker`，通过 `Rpc.client()` 与 worker 通信。

### 4.2 worker 暴露三类能力

`packages/opencode/src/cli/cmd/tui/worker.ts:101-151` 暴露了：

1. `fetch`：把任意 HTTP 请求转发给 `Server.Default().fetch()`。
2. `event`：把本地 `/event` 订阅转成 RPC 事件。
3. `server`：按需起真实 `Server.listen()`。

所以 TUI 前端既可以：

1. 在默认场景下直接通过 worker 调本地 `Server.Default()`。
2. 在传了 `--port` / `--hostname` / `--mdns` 等参数时切换成外部 HTTP server。

### 4.3 UI 自己并不知道后面是本地还是远端

`thread.ts:186-223` 最终只把 `{ url, fetch, events }` 交给 `tui()`。`tui()` 消费的是抽象后的 SDK provider，而不是某个 runtime 单例。

这就是 OpenCode TUI 的一个核心设计：**UI 永远只面对 session 协议，不面对 session 实现。**

### 4.4 TUI 首屏加载：不是一次性全量渲染

TUI 主线程执行 `render()` 时，还要经历两层启动：先装配 Provider 树，再做分阶段同步。

#### 4.4.1 render 前有一次终端背景探测

主线程会先发一个 OSC 11 查询，用来判断当前终端主题更接近 `dark` 还是 `light`：

1. 临时把 `stdin` 设成 raw mode
2. 发送 `\x1b]11;?\x07`
3. 等待终端回传颜色并计算亮度
4. 超时则默认 `dark`

#### 4.4.2 Provider 树分四层

`render()` 时挂上的 Provider 可以粗略分成四层：

1. 基础运行层：`ArgsProvider`、`ExitProvider`、`KVProvider`、`ToastProvider`、`RouteProvider`
2. 通信与同步层：`TuiConfigProvider`、`SDKProvider`、`SyncProvider`
3. 本地 UI 状态层：`ThemeProvider`、`LocalProvider`、`KeybindProvider`、`DialogProvider`
4. 命令与历史层：`CommandProvider`、`FrecencyProvider`、`PromptHistoryProvider`、`PromptRefProvider`

#### 4.4.3 `SDKProvider`：UI 侧的通信入口

`SDKProvider` 负责创建 `createOpencodeClient(...)` 并维持事件流。关键行为包括：

- 默认 `baseUrl` 是 `http://opencode.internal`
- 会把当前 `directory` 一并传给 SDK
- 没有 `props.events` 时自己走 SSE；已有时直接消费 worker RPC 事件
- 事件先进入 16ms 批处理队列，再批量写入 UI
- 当前 session 切换 workspace 时，`setWorkspace()` 会重建 client，并让 worker 重启 event stream

#### 4.4.4 `SyncProvider.bootstrap()`：分两段把首屏数据灌进来

首屏同步分两阶段：

**阻塞阶段**会并发请求：

1. `config.providers`
2. `provider.list`
3. `app.agents`
4. `config.get`
5. 如果带了 `--continue`，还会阻塞等待 `session.list({ start: 30 days ago })`

只有这些返回后，状态才会从 `loading` 切到 `partial`。

**后台非阻塞阶段**继续拉：
`session.list` / `command.list` / `lsp.status` / `mcp.status` / `experimental.resource.list` / `formatter.status` / `session.status` / `provider.auth` / `vcs.get` / `path.get` / `workspace.list`

全部完成后才进入 `complete`。这也是首页能较快可交互的原因。

---

## 5. `attach`：远端 TUI 不是另一套产品，只是 transport 换成 HTTP

`packages/opencode/src/cli/cmd/tui/attach.ts:9-88` 做的事很克制：

1. 解析 URL、目录、continue/session/fork。
2. 读取本地 TUI 配置。
3. 组出远端 basic auth 头。
4. 把这些信息交给同一个 `tui()`。

它没有自己的 runtime，也不直接处理 session 数据。它只是在告诉 TUI：

1. SDK base URL 是远端地址。
2. 目录参数不一定本地存在，可能是远端路径。

`attach` 通过远端 HTTP transport 复用同一套 TUI 逻辑。

---

## 6. `serve` 与 `web`：一个是 headless server，一个是浏览器壳

### 6.1 `serve` 只负责把 server 起起来

`packages/opencode/src/cli/cmd/serve.ts:9-23` 基本等于：

1. 解析网络选项。
2. `Server.listen(opts)`。
3. 常驻不退出。

它没有 UI，也不会主动连接 session。

### 6.2 `web` 也只是先起 server，再打开浏览器

`packages/opencode/src/cli/cmd/web.ts:31-80`：

1. 一样调用 `Server.listen(opts)`。
2. 打印本地/局域网访问地址。
3. 调 `open()` 打开浏览器。

浏览器访问的是本地 server 暴露的 API 与被代理的远端 app shell；`packages/web` 负责官网与文档站点。

### 6.3 在 `v1.3.2` 中，未知路径会代理到 `https://app.opencode.ai`

`packages/opencode/src/server/server.ts:499-514` 的兜底路由会把任意未命中的路径代理到 `app.opencode.ai`，并重写 CSP。

因此：

1. `web` 命令启动的是本地 agent server。
2. 浏览器访问的是"本地 server 暴露的 API + 被代理过来的远端 app shell"。
3. `packages/web` 实际上是 Astro 文档/官网站点。
4. 交互前端代码位于 `packages/app`，桌面壳复用这一层。

这四点一定要分开。

---

## 7. ACP：把同一套 session 协议再包一层 Agent Client Protocol

`packages/opencode/src/cli/cmd/acp.ts:12-69` 做的事情是：

1. 本地 `bootstrap()`。
2. `Server.listen()` 起一个内部 server。
3. 用 `createOpencodeClient()` 连回这个 server。
4. 再把 stdin/stdout 包装成 ACP 的 NDJSON stream。

随后 `packages/opencode/src/acp/agent.ts` 里的 `ACP.Agent`：

1. 持续订阅 `sdk.global.event()`，把全局事件投给 ACP connection，见 `167-181`。
2. 把 permission request、session load/resume、新建会话、工具调用等 ACP 动作翻译回 SDK 请求。

ACP 通过协议适配器复用同一套 runtime。

---

## 8. 桌面端：Tauri 和 Electron 都是 sidecar 壳，不是第二个 runtime

这一节需要重点区分 UI 壳层与 agent runtime。

### 8.1 Tauri 版

Tauri 前端在 `packages/desktop/src/index.tsx:432-458` 通过 `commands.awaitInitialization()` 获取 sidecar server 地址和凭证，然后构造 `ServerConnection.Sidecar` 交给 `@opencode-ai/app`。

Rust 侧在 `packages/desktop/src-tauri/src/server.rs:87-127` 通过 `cli::serve(...)` 拉起本地 sidecar，并轮询 `/global/health` 等待就绪。

### 8.2 Electron 版

Electron 主进程在 `packages/desktop-electron/src/main/server.ts:32-57` 调 `spawnLocalServer()`，它内部会走 `packages/desktop-electron/src/main/cli.ts:123-195` 启一个 `serve` 子进程，再做健康检查。

Renderer 端再在 `packages/desktop-electron/src/renderer/index.tsx:252-290` 把 sidecar 连接组装成 `ServerConnection.Sidecar`。

### 8.3 两个桌面壳的共同点

1. UI 通过 server URL 连接 runtime。
2. agent 执行链仍由 `packages/opencode` 里的 sidecar 提供。
3. `@opencode-ai/app` 是复用的 UI 层，不是新的编排引擎。

桌面端把同一套 server 封装进桌面宿主，并继续复用已有的 UI 与 runtime。

---

## 9. 入口层统一了三件事

看完这些入口，可以把统一点归纳成三件事：

1. **统一协议**：最终都落到 `/session`、`/permission`、`/question`、`/event` 这些 server 路由。
2. **统一状态**：都读写同一个 SQLite/Storage durable state。
3. **统一 runtime**：agent 执行链集中在 `packages/opencode` 的 `SessionPrompt` / `SessionProcessor` / `LLM`。

入口层的差异，只是：

1. 谁来采集用户输入。
2. transport 是本地 fetch、worker RPC、远端 HTTP，还是 ACP NDJSON。
3. 宿主是终端、浏览器、桌面壳还是协议适配器。
