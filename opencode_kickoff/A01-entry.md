# OpenCode 源码深度解析 A01：多端入口与传输适配

讨论 OpenCode 的入口层，不能只盯着 `run` 命令。当前代码里至少有 7 类入口：默认 TUI、一次性 `run`、`attach`、`serve`、`web`、`acp`、桌面 sidecar。它们的 UI 形态不同，但真正重要的是它们怎样收束到同一个 HTTP/session 协议上。

---

## 1. 入口总览

| 入口 | 代码坐标 | 传输方式 | 最后进入哪里 |
| --- | --- | --- | --- |
| 默认 TUI (`opencode`) | `packages/opencode/src/index.ts:126-151`、`cli/cmd/tui/thread.ts:65-225` | 本地 worker RPC，必要时也可起外部 HTTP server | 同一套 `Server.fetch()` / `/event` 协议 |
| 一次性 `run` | `cli/cmd/run.ts:221-675` | 本地 in-process fetch 或远端 HTTP attach | `session.prompt` / `session.command` |
| `attach <url>` | `cli/cmd/tui/attach.ts:9-88` | 远端 HTTP + SSE | 远端 server 的 `/session`、`/event` |
| `serve` | `cli/cmd/serve.ts:9-23` | 纯 HTTP server | `Server.listen()` |
| `web` | `cli/cmd/web.ts:31-80` | 本地 HTTP server，再打开浏览器 | `Server.listen()`，未知路径代理到 `app.opencode.ai` |
| `acp` | `cli/cmd/acp.ts:12-69`、`acp/agent.ts` | stdin/stdout NDJSON + 本地 HTTP SDK | 同一套 `/session`、`/permission`、`/event` |
| 桌面端 | `packages/desktop/src/index.tsx:419-442`、`packages/desktop-electron/src/main/server.ts:32-58` | sidecar server + `@opencode-ai/app` | 同一套 HTTP/SSE server 连接 |

结论先说在前面：**OpenCode 没有多套 runtime，只有多套 transport 和宿主。**

---

## 2. CLI 主进程先做的不是“跑 agent”，而是准备运行环境

真正的入口注册在 `packages/opencode/src/index.ts`：

1. `yargs` 注册所有命令，见 `50-151`。
2. 中间件里初始化日志、设置 `AGENT=1` / `OPENCODE=1` / `OPENCODE_PID`，见 `67-86`。
3. 首次启动时检查数据库并执行 JSON -> SQLite 迁移，见 `87-122`。

这一步的意义是：

1. 任何入口都共享同一个全局数据库和日志系统。
2. runtime 之前先完成安装态准备，后面的命令处理逻辑不需要再关心迁移问题。

也就是说，`index.ts` 是 CLI 壳；真正跟 agent runtime 直接交互的是各个子命令。

---

## 3. `run` 命令：一次性执行入口其实有两条传输路径

`packages/opencode/src/cli/cmd/run.ts:221-675` 是最容易误读的一段代码。它做了四件事：

### 3.1 把外部输入整理成 session 请求

`306-350` 会把：

1. 位置参数和 `--` 后参数拼成 message。
2. `--file` 附件转成 file part 输入。
3. `stdin` 管道内容拼接进 message。
4. `--fork`、`--continue`、`--session` 做会话选择。

随后 `381-394` 通过 SDK 决定是复用 session、fork session，还是创建新 session。

### 3.2 先订阅事件，再发请求

`411-558` 会先 `sdk.event.subscribe()`，再根据事件类型把 tool/text/reasoning/error/status 渲染到终端。

这里有个关键事实：`run` 的终端输出并不是直接消费 `prompt()` 返回值，而是消费 SSE 事件流里的 `message.part.updated` / `session.error` / `session.status`。

### 3.3 本地模式不是走 socket，而是直接把 SDK `fetch` 指向 `Server.Default().fetch()`

`667-673` 通过：

```ts
const fetchFn = async (input, init) => Server.Default().fetch(new Request(input, init))
```

把 SDK 客户端直接接到内存里的 Hono app 上。它仍然走 HTTP 语义，只是没经过真正网络栈。

### 3.4 attach 模式才走真实远端 HTTP

`655-665` 会用 `createOpencodeClient({ baseUrl, headers })` 连到远端 server，并带上 basic auth。

因此 `run` 的核心不是“直接调用 runtime 函数”，而是“用 SDK 发 session 协议请求”，只是这个协议既可以指向内存里的 server，也可以指向远端 server。

---

## 4. 默认 TUI 入口：transport 抽象比 `run` 更厚一层

默认命令其实不是 `run`，而是 `TuiThreadCommand`，位于 `packages/opencode/src/cli/cmd/tui/thread.ts:65-225`。

这一层的关键不是 UI，而是它把“本地 worker 模式”和“外部 server 模式”统一成同一套前端依赖：

### 4.1 TUI 主线程不直接碰 runtime

`131-167` 会先启动 `Worker`，通过 `Rpc.client()` 与 worker 通信。

### 4.2 worker 暴露两类能力

`packages/opencode/src/cli/cmd/tui/worker.ts:100-149` 暴露了：

1. `fetch`：把任意 HTTP 请求转发给 `Server.Default().fetch()`。
2. `event`：把本地 `/event` 订阅转成 RPC 事件。
3. `server`：按需起真实 `Server.listen()`。

所以 TUI 前端既可以：

1. 在默认场景下直接通过 worker 调本地 `Server.Default()`。
2. 在传了 `--port` / `--hostname` / `--mdns` 等参数时切换成外部 HTTP server。

### 4.3 UI 自己并不知道后面是本地还是远端

`thread.ts:185-215` 最终只把 `{ url, fetch, events }` 交给 `tui()`。`tui()` 消费的是抽象后的 SDK provider，而不是某个 runtime 单例。

这就是 OpenCode TUI 的一个核心设计：**UI 永远只面对 session 协议，不面对 session 实现。**

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

所以 `attach` 不是“远端模式的另一个实现”，只是把 transport 从 worker fetch 换成了远端 HTTP。

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

真正容易被误写的是后半句：浏览器里看到的 UI **不是本地 `packages/web`**。

### 6.3 当前代码里，未知路径会代理到 `https://app.opencode.ai`

`packages/opencode/src/server/server.ts:499-514` 的兜底路由会把任意未命中的路径代理到 `app.opencode.ai`，并重写 CSP。

因此：

1. `web` 命令启动的是本地 agent server。
2. 浏览器访问的是“本地 server 暴露的 API + 被代理过来的远端 app shell”。
3. `packages/web` 实际上是 Astro 文档/官网站点。
4. 真正可复用的交互前端是 `packages/app`，它被桌面壳复用。

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

所以 ACP 不是旁路接口，而是**把同一套 runtime 重新包装成 ACP 协议适配器**。

---

## 8. 桌面端：Tauri 和 Electron 都是 sidecar 壳，不是第二个 runtime

这一点是当前文档最容易写虚的地方。

### 8.1 Tauri 版

Tauri 前端在 `packages/desktop/src/index.tsx:419-442` 通过 `commands.awaitInitialization()` 获取 sidecar server 地址和凭证，然后构造 `ServerConnection.Sidecar` 交给 `@opencode-ai/app`。

Rust 侧在 `packages/desktop/src-tauri/src/server.rs:87-127` 通过 `cli::serve(...)` 拉起本地 sidecar，并轮询 `/global/health` 等待就绪。

### 8.2 Electron 版

Electron 主进程在 `packages/desktop-electron/src/main/server.ts:32-58` 调 `spawnLocalServer()`，它内部会走 `packages/desktop-electron/src/main/cli.ts:122-195` 启一个 `serve` 子进程，再做健康检查。

Renderer 端再在 `packages/desktop-electron/src/renderer/index.tsx:252-275` 把 sidecar 连接组装成 `ServerConnection.Sidecar`。

### 8.3 两个桌面壳的共同点

1. UI 都不是直接嵌入 runtime，而是消费 server URL。
2. 真正跑 agent 的依旧是 `packages/opencode` 里的 sidecar。
3. `@opencode-ai/app` 是复用的 UI 层，不是新的编排引擎。

所以桌面端并不是 “CLI 版 OpenCode 的另一个实现”，而只是 “把同一套 server 包进桌面宿主”。

---

## 9. 入口层真正统一的是什么

看完这些入口，可以把统一点归纳成三件事：

1. **统一协议**：最终都落到 `/session`、`/permission`、`/question`、`/event` 这些 server 路由。
2. **统一状态**：都读写同一个 SQLite/Storage durable state。
3. **统一 runtime**：真正执行 agent 的始终是 `packages/opencode` 里的 `SessionPrompt` / `SessionProcessor` / `LLM`。

入口层的差异，只是：

1. 谁来采集用户输入。
2. transport 是本地 fetch、worker RPC、远端 HTTP，还是 ACP NDJSON。
3. 宿主是终端、浏览器、桌面壳还是协议适配器。
