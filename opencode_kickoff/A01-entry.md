# OpenCode 源码深度解析 A01：多端入口与传输适配

OpenCode 不只有 `run` 这一个入口。真正的入口分布在 CLI 命令注册、TUI 宿主、Web 页面、ACP 适配层，以及 Electron/Tauri 桌面壳里；这些入口最后都汇到同一套 `session`/`server` 协议。

## 一、统一入口注册

顶层命令注册在 `packages/opencode/src/index.ts:126-150`：

- `AcpCommand`：`packages/opencode/src/cli/cmd/acp.ts:12-69`
- `TuiThreadCommand`：`packages/opencode/src/cli/cmd/tui/thread.ts:65-225`
- `AttachCommand`：`packages/opencode/src/cli/cmd/tui/attach.ts:9-88`
- `RunCommand`：`packages/opencode/src/cli/cmd/run.ts:306-675`
- `ServeCommand`：`packages/opencode/src/cli/cmd/serve.ts:9-24`
- `WebCommand`：`packages/opencode/src/cli/cmd/web.ts:31-80`
- `WorkspaceServeCommand`：只在本地安装形态下追加，判断点在 `packages/opencode/src/index.ts:149-150`

这意味着“入口”首先是命令级分流，而不是只有 `run.ts` 一条主线。

## 二、入口总览

| 入口 | 代码坐标 | 宿主形态 | 最终传输 |
| --- | --- | --- | --- |
| CLI `run` | `packages/opencode/src/cli/cmd/run.ts:306-675` | 一次性命令 | 远端 attach 走 HTTP；本地模式走 `Server.Default().fetch()` |
| TUI | `packages/opencode/src/cli/cmd/tui/thread.ts:65-225` | 常驻交互线程 | 外部网络模式走 `Server.listen()`；本地模式走 worker RPC 包装的 `fetch`/`events` |
| TUI attach | `packages/opencode/src/cli/cmd/tui/attach.ts:9-88` | 连接已启动 server | 直接连远端 URL，可带 Basic Auth |
| Headless server | `packages/opencode/src/cli/cmd/serve.ts:9-24` | 纯服务端 | `Server.listen(opts)` |
| Web | `packages/opencode/src/cli/cmd/web.ts:31-80` | 启 server 并打开浏览器 | 浏览器通过 SDK 调 HTTP server |
| ACP | `packages/opencode/src/cli/cmd/acp.ts:12-69` | Agent Client Protocol | stdin/stdout NDJSON + 内部 SDK |
| Electron 桌面 | `packages/desktop-electron/src/main/index.ts:56-58,123-188,259-277` | 本地 sidecar + 桌面窗口 | 先拉起 loopback sidecar，再让前端连本地 HTTP |
| Tauri 桌面 | `packages/desktop/src-tauri/src/main.rs:42-77` | 原生桌面壳 | 启动前修正代理环境，再进入 `opencode_lib::run()` |

## 三、CLI `run`：一次性请求入口

`RunCommand.handler()` 在 `packages/opencode/src/cli/cmd/run.ts:306-675` 负责一次性 CLI 调用的完整闭环：

- `311-343` 处理 `--dir` 和 `--file`，把文件参数编译成 file parts。
- `345-355` 拼接 stdin，并校验“prompt/command 至少要有一个”。
- `357-394` 建默认权限规则，并在 `session()` 里处理 `--continue`、`--session`、`--fork`。
- `411-557` 订阅 `sdk.event.subscribe()`，用 bus 事件而不是 HTTP 响应体驱动输出。
- `634-651` 真正分流请求：`args.command` 走 `sdk.session.command()`，否则走 `sdk.session.prompt()`。
- `655-664` attach 模式直接 `createOpencodeClient({ baseUrl: args.attach, headers })`。
- `667-673` 本地模式不启动端口，而是把 SDK 的 `fetch` 直接接到 `Server.Default().fetch()`。

所以 `run` 是“直接发一轮请求”的入口，不是所有宿主的总入口。

## 四、TUI：长驻宿主 + 本地 worker 适配层

TUI 主入口在 `packages/opencode/src/cli/cmd/tui/thread.ts:65-225`。这一层做的不是直接发送 prompt，而是先决定宿主和 transport：

- `101-129` 解析 `project` 路径并切换 `cwd`。
- `131-168` 启动 worker，并建立关闭、重载、异常处理逻辑。
- `185-195` 决定 transport：
  - 外部模式通过 `client.call("server", network)` 让 worker 启动真实 HTTP server。
  - 内嵌模式用 `createWorkerFetch()` 与 `createEventSource()`，把 RPC 包装成 SDK 可用的 `fetch/events`。
- `202-216` 调用 `tui()`，把 `url`、`fetch`、`events` 和会话参数一起注入 UI。

TUI 的两个关键适配器在同一文件：

- `packages/opencode/src/cli/cmd/tui/thread.ts:24-40` 的 `createWorkerFetch()` 把浏览器式 `Request` 转成 RPC `fetch` 调用。
- `packages/opencode/src/cli/cmd/tui/thread.ts:42-49` 的 `createEventSource()` 把 worker 推送的 `event` 和 `setWorkspace()` 包成前端事件源接口。

真正落到 server 的地方在 worker：

- `packages/opencode/src/cli/cmd/tui/worker.ts:46-96` 的 `startEventStream()` 创建本地 SDK，调用 `sdk.event.subscribe()` 持续拉事件，再通过 `Rpc.emit("event", ...)` 推回 TUI。
- `packages/opencode/src/cli/cmd/tui/worker.ts:52-64` 给 SDK 注入 `fetchFn`，底层直接走 `Server.Default().fetch()`。
- `packages/opencode/src/cli/cmd/tui/worker.ts:100-119` 暴露 `rpc.fetch()`，把 RPC 请求继续转发到 `Server.Default().fetch()`。
- `packages/opencode/src/cli/cmd/tui/worker.ts:120-123` 的 `rpc.server()` 才会真正 `Server.listen(input)`，用于外部网络模式。
- `packages/opencode/src/cli/cmd/tui/worker.ts:138-146` 的 `setWorkspace()` 会重建事件流，让 workspace 维度切换后仍订阅同一套 bus。

TUI 输入组件本身也有三路分流，坐标在 `packages/opencode/src/cli/cmd/tui/component/prompt/index.tsx:591-650`：

- `591-601` shell 模式调用 `sdk.client.session.shell()`。
- `617-631` slash command 调用 `sdk.client.session.command()`。
- `633-649` 普通输入调用 `sdk.client.session.prompt()`。

也就是说，`shell` 入口现在主要体现在 TUI，而不是 `run.ts`。

## 五、Attach：连接已有 Server

`AttachCommand` 在 `packages/opencode/src/cli/cmd/tui/attach.ts:9-88`，它不是本地 server 的别名，而是“跳过 worker 和 bootstrap，直接接入已有 server”的入口：

- `53-62` 处理 `--dir`，本地存在就 `chdir`，不存在就把路径原样透传给远端。
- `63-68` 组装 Basic Auth 头。
- `69-72` 只用本地目录读取 `TuiConfig`。
- `73-83` 把 `url`、`headers`、`directory` 和 `continue/session/fork` 一起交给 `tui()`。

这条路径解释了为什么 TUI 既能本地内嵌运行，也能 attach 到独立 server。

## 六、Web 与 Headless Server：浏览器入口不等于 CLI

服务端入口分两种：

- `packages/opencode/src/cli/cmd/serve.ts:9-24` 是纯 headless server，只做 `Server.listen(opts)` 并常驻等待。
- `packages/opencode/src/cli/cmd/web.ts:31-80` 同样启动 `Server.listen(opts)`，但会打印访问地址，并在 `70-75` 自动打开浏览器。

浏览器侧 SDK 工厂在 `packages/app/src/utils/server.ts:4-22`：

- `10-15` 根据保存的用户名和密码生成 Basic Auth。
- `17-21` 用 `createOpencodeClient({ baseUrl: server.url, headers })` 创建浏览器侧 SDK。

Web 输入提交在 `packages/app/src/components/prompt-input/submit.ts`：

- `74-104` 先判断首词是不是 slash command；如果是，`84-99` 调 `input.client.session.command()`。
- `106-165` 普通消息会先构造 optimistic message，再在 `152-159` 调 `input.client.session.promptAsync()`。

当前 Web 代码里没有与 TUI 对应的 `session.shell()` 调用；Web 入口现阶段主要覆盖 `command` 与 `promptAsync` 两种发送方式。

## 七、ACP：把内部 SDK 暴露成 Agent 协议

`packages/opencode/src/cli/cmd/acp.ts:12-69` 不是简单启动 server，而是在 server 之上再包一层 ACP：

- `24-30` 先 `Server.listen(opts)`，再创建指向该 server 的 SDK。
- `32-53` 把 `stdout`/`stdin` 包成 `WritableStream` 与 `ReadableStream`。
- `55-60` 用 `ndJsonStream()` 和 `AgentSideConnection()` 把内部 agent 暴露成 ACP 协议端点。

因此 ACP 是“协议适配入口”，不是普通用户直接交互的 UI 入口。

## 八、桌面壳：为什么同时有 Electron 和 Tauri

这里不是两套独立产品，而是“同一套前端与 sidecar 模型，对接两种桌面宿主”。

共享层可以直接从前端入口看出来：

- Electron 渲染进程在 `packages/desktop-electron/src/renderer/index.tsx:3-13,252-274,311-323` 引入同一个 `@opencode-ai/app`，等待 `window.api.awaitInitialization()` 拿到 sidecar 凭据，再组装 `ServerConnection.Sidecar` 交给 `AppInterface`。
- Tauri 渲染进程在 `packages/desktop/src/index.tsx:3-13,418-442,467-477` 做的是同一件事，只是把宿主桥接从 `window.api` 换成了 `commands.awaitInitialization(...)` 和 Tauri plugin API。

也就是说，两套壳共享的是应用层和 sidecar 协议，差异主要在“宿主如何暴露系统能力”。

### 1. Tauri：当前默认开发主线

仓库根脚本把桌面开发入口直接指向 Tauri：`package.json:8-10` 的 `dev:desktop` 运行 `bun --cwd packages/desktop tauri dev`。

Tauri 包本身也说明它是完整的原生壳：

- `packages/desktop/package.json:7-13` 暴露 `tauri` 命令和独立构建脚本。
- `packages/desktop/package.json:20-32` 依赖 `@tauri-apps/api` 及一整套 Tauri plugins，包括 `dialog`、`deep-link`、`notification`、`process`、`shell`、`store`、`updater`、`http`。
- `packages/desktop/src/bindings.ts:7-22` 通过 Specta 生成 Rust 命令绑定，前端直接调用 `awaitInitialization`、`killSidecar`、`openPath` 等原生命令。
- `packages/desktop/src-tauri/src/lib.rs:421-523` 在 Rust 侧拉起 sidecar、驱动初始化事件、处理 loading window 与 health check，再把能力回灌给前端。

从仓库形态看，Tauri 是现在的原生桌面主线，适合回答“当前桌面版怎么开发、怎么调 sidecar、怎么接原生能力”这类问题。

### 2. Electron：并行维护的另一套发布宿主

Electron 有独立的构建与发布链路：

- `packages/desktop-electron/package.json:12-23` 提供 `electron-vite dev`、`electron-vite build`、`electron-builder` 的打包脚本。
- `packages/desktop-electron/package.json:34-49` 依赖 `electron`、`electron-updater`、`electron-store`、`electron-builder`。
- `packages/desktop-electron/src/main/index.ts:56-58,123-188,259-277` 由 Electron main process 负责 sidecar 生命周期、健康检查、窗口创建和代理绕过。
- `packages/desktop-electron/src/main/server.ts:32-84` 的 `spawnLocalServer()` 用 Node 侧轮询 `/global/health` 来判定 sidecar 可用。
- `packages/desktop-electron/src/renderer/index.tsx:45-46,70-95,252-274` 则通过 preload 暴露的 `window.api` 访问 deep link、存储、文件选择、sidecar 初始化等宿主能力。

从代码结构看，Electron 适合回答“Electron 打包产物怎么来的、主进程怎样托管 sidecar、preload API 如何桥接前端”这类问题。

### 3. 两套为什么会并存

仓库里的直接证据有两条：

- 开发默认走 Tauri：`package.json:8-10`。
- 发布流水线同时构建两种桌面包：`.github/workflows/publish.yml:105-234` 是 `build-tauri`，用 `tauri-action` 构建 `packages/desktop`；`.github/workflows/publish.yml:249-356` 是 `build-electron`，用 `electron-builder` 构建 `packages/desktop-electron`。

因此，更准确的描述不是“旧的 Electron 和新的 Tauri 二选一”，而是“当前仓库同时维护两种桌面宿主”：

- Tauri 是默认开发入口，也是当前桌面主线代码阅读的第一站。
- Electron 仍在正式发布流水线里，属于并行交付的桌面宿主。
- 两者都不是业务逻辑主干；业务主干仍然是共享的 `@opencode-ai/app` 前端和本地 sidecar server。

### 4. 读者应该在什么场景看哪一套

- 想理解“OpenCode 桌面版怎么接系统 API、怎么走原生命令、当前本地开发怎么跑”，先看 Tauri：`package.json:8-10`、`packages/desktop/src/index.tsx:418-442`、`packages/desktop/src-tauri/src/lib.rs:421-523`。
- 想理解“Electron main/preload/renderer 三段式怎么托管 sidecar、怎么打包发版”，看 Electron：`packages/desktop-electron/src/main/index.ts:123-188`、`packages/desktop-electron/src/main/server.ts:32-84`、`packages/desktop-electron/package.json:12-23`。
- 想理解产品功能本身，而不是宿主差异，两套都不是起点；应该回到共享前端 `@opencode-ai/app` 和 sidecar server 协议。
