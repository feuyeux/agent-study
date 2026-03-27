# OpenCode 启动加载全过程深度拆解

> 基于 `opencode` `v1.3.2`（tag `v1.3.2`，commit `0dcdf5f529dced23d8452c9aa5f166abb24d8f7c`）源码校对。
> 重点分析默认命令 `opencode` / `bun dev` 对应的启动路径，也就是 `packages/opencode/src/cli/cmd/tui/thread.ts` 这条 TUI 链路。

---

## 1. 先记住结论

默认 `opencode` 启动，不是“一个 CLI 进程直接把 TUI 画出来”，而是分成五层：

1. `bin/opencode` 负责选择正确的平台二进制。
2. `src/index.ts` 完成 CLI 注册、日志初始化、数据库迁移检查。
3. 默认命令 `$0 [project]` 进入 `TuiThreadCommand`，主线程负责 TUI 壳、参数和 RPC 桥接。
4. 主线程再拉起一个 `Worker`，真正的 runtime、HTTP API、事件流都在 worker 内。
5. worker 第一次请求 `Server.Default().fetch()` 时，才会通过 `Instance.provide(..., init: InstanceBootstrap)` 把项目 runtime 真正拉起来。

整条链里最容易搞混的只有三点：

- 主线程负责 UI 壳，不负责完整 runtime。
- 默认模式下 server 往往不监听真实端口，而是“内存内 fetch”。
- 真正的项目启动点不在 `tui()`，而在 worker 第一次命中 server 中间件时。

---

## 2. 启动总览

```text
Shell / npm / bun
  -> packages/opencode/bin/opencode
  -> 平台二进制 opencode-{platform}-{arch}/bin/opencode
  -> src/index.ts
     -> yargs 全局 middleware
        -> Log.init()
        -> 设置 OPENCODE / AGENT / PID
        -> 数据库迁移检查
     -> 默认命令 $0 [project]
        -> cli/cmd/tui/thread.ts
           -> 主线程处理 cwd / 参数 / 终端
           -> spawn Worker(worker.ts)
           -> 主线程读取 TuiConfig
           -> 选择 transport（内嵌 RPC 或真实端口）
           -> tui() render
              -> SDKProvider / SyncProvider 拉首屏数据

Worker 并行启动：
  -> cli/cmd/tui/worker.ts
     -> Log.init()
     -> startEventStream(process.cwd())
        -> createOpencodeClient(fetch => Server.Default().fetch)
        -> sdk.event.subscribe() 发 GET /event
        -> Server.Default() 首次 lazy createApp()
        -> middleware 解析 directory / workspace
        -> Instance.provide(directory, init: InstanceBootstrap)
           -> Project.fromDirectory()
           -> Plugin.init()
           -> ShareNext.init()
           -> Format.init()
           -> LSP.init()
           -> File.init()
           -> FileWatcher.init()
           -> Vcs.init()
           -> Snapshot.init()
        -> EventRoutes 把 bus event 转成 SSE
```

一句话概括：主线程负责把 TUI 跑起来，worker 负责把 runtime 点着，而点火器正是 worker 启动后最早发出的 `/event` 请求。

---

## 3. 分发层：`bin/opencode` 只是二进制 shim

`packages/opencode/package.json` 把可执行入口声明为：

```json
"bin": {
  "opencode": "./bin/opencode"
}
```

这个 `bin/opencode` 很薄，只做分发：

1. 如果设置了 `OPENCODE_BIN_PATH`，直接执行该路径。
2. 如果脚本同目录存在 `.opencode`，直接执行这个缓存二进制。
3. 根据 `os.platform()` 和 `os.arch()` 生成平台包名。
4. 对 `x64` 机器补做 `AVX2` 检测。
5. Linux 下继续区分 `glibc` 和 `musl`。
6. 从当前目录向上查找 `node_modules/<platform-package>/bin/opencode[.exe]`。
7. 找到后用 `spawnSync(target, process.argv.slice(2), { stdio: "inherit" })` 转交控制权。

因此 npm 暴露给用户的其实只是一个 Node 包装层。真正执行的是平台原生二进制，而且参数在 shim 层不会做业务解析。

### 3.1 发布版和源码版的入口其实是同一套

`packages/opencode/script/build.ts` 明确把 `src/index.ts` 和 TUI worker 一起打包：

```ts
entrypoints: ["./src/index.ts", parserWorker, workerPath]
```

构建时还会注入：

- `OPENCODE_VERSION`
- `OPENCODE_CHANNEL`
- `OPENCODE_MIGRATIONS`
- `OPENCODE_WORKER_PATH`
- `OPENCODE_LIBC`

所以发布版和开发版的区别，主要只是“怎么启动代码”，不是“走不同的启动链”：

- 发布版走原生二进制。
- 开发态通常直接 `bun run src/index.ts`。
- 核心链路仍然是 `src/index.ts -> TuiThreadCommand -> worker.ts -> server -> instance`。

---

## 4. 真实入口：`src/index.ts`

`src/index.ts` 做三件事：

1. 构建 yargs CLI。
2. 在全局 middleware 里初始化日志和数据库。
3. 注册命令并 parse。

不过在 parse 之前，模块图本身已经带来了一些顶层副作用。

### 4.1 import 阶段的隐式初始化

`global/index.ts` 会：

1. 计算 XDG 路径：`data`、`cache`、`config`、`state`、`log`、`bin`。
2. 创建这些目录。
3. 读取 `cache/version`。
4. 如果缓存版本不是代码里的 `"21"`，清空 cache 并写回新版本号。

`flag/flag.ts` 会把多组环境变量映射为 `Flag.*`。其中一部分是静态读取，一部分是动态 getter，例如：

- `OPENCODE_DISABLE_PROJECT_CONFIG`
- `OPENCODE_TUI_CONFIG`
- `OPENCODE_CONFIG_DIR`
- `OPENCODE_CLIENT`

`src/index.ts` 自己还会提前注册：

- `process.on("unhandledRejection", ...)`
- `process.on("uncaughtException", ...)`

它们的策略是优先记日志，而不是立刻退出。

### 4.2 全局 middleware：日志和数据库都在这里被点亮

每个命令 handler 前，middleware 都会执行以下动作：

1. `Log.init(...)`
2. 写环境变量：`AGENT=1`、`OPENCODE=1`、`OPENCODE_PID=<pid>`
3. 记录版本和 argv
4. 检查 `Global.Path.data/opencode.db`
5. 如果数据库不存在，则执行数据库迁移和 JSON -> SQLite 迁移

这里有两个要点：

- 第一次启动时，数据库连接是在 CLI middleware 里打开的，不是更晚的业务层。
- JSON -> SQLite 的迁移触发条件直接看 `Global.Path.data/opencode.db`，不是按更细的业务路径判断。

### 4.3 `Database.Client()` 的副作用

数据库 lazy 初始化时会一次性做完这些准备：

1. 计算最终 DB 路径：
   - 默认 `Global.Path.data/opencode.db`
   - 非 `latest` / `beta` channel 会变成 `opencode-<channel>.db`
   - 也可以被 `OPENCODE_DB` 覆盖
2. 用 `bun:sqlite` 打开数据库
3. 执行 PRAGMA：
   - `journal_mode = WAL`
   - `synchronous = NORMAL`
   - `busy_timeout = 5000`
   - `cache_size = -64000`
   - `foreign_keys = ON`
   - `wal_checkpoint(PASSIVE)`
4. 应用 Drizzle migrations

所以从 CLI 视角看，持久化层在“命令真正开始做事之前”就已经可用了。

### 4.4 为什么默认会直接进 TUI

默认命令是：

```ts
command: "$0 [project]"
```

也就是 `TuiThreadCommand`。因此：

- `opencode`
- `opencode .`
- `bun dev`

都会进入默认 TUI 启动链。`run`、`serve`、`attach`、`web`、`mcp`、`acp` 都只是分支。

### 4.5 parse 收尾

`src/index.ts` 最后无论成功失败都会走到：

```ts
finally { process.exit() }
```

源码注释写得很直接：某些子进程不响应 `SIGTERM`，所以这里显式退出，避免 CLI 挂死。

---

## 5. 主线程：`TuiThreadCommand` 负责 TUI 壳

默认 TUI 启动发生在 `src/cli/cmd/tui/thread.ts`。主线程的职责很单纯：

1. 处理终端兼容。
2. 解析目录。
3. 拉起 worker。
4. 准备 transport。
5. 渲染 TUI。

### 5.1 早期动作：终端和 cwd 先定下来

进入 handler 后，主线程先做：

1. `win32InstallCtrlCGuard()`
2. `win32DisableProcessedInput()`
3. 校验 `--fork` 必须和 `--continue` 或 `--session` 搭配

然后解析目录：

- 优先使用 `process.env.PWD`
- 否则退回 `process.cwd()`
- 把 `args.project` 解析成绝对路径
- 最终 `process.chdir(next)`

这一步很关键，因为 worker 会继承这个 cwd，后面的 `startEventStream({ directory: process.cwd() })` 也靠它判断当前项目。

### 5.2 worker 路径怎么定

worker 文件路径优先级如下：

1. 编译期注入的 `OPENCODE_WORKER_PATH`
2. `./cli/cmd/tui/worker.js`
3. 开发态源码 `./worker.ts`

所以发布版通常直接走打包后的 worker，开发态才会执行源码。

### 5.3 主线程和 worker 是并行启动的

主线程会依次做：

1. `new Worker(file, { env: ...process.env })`
2. 建立 RPC client
3. 读取 `args.prompt` 和可能存在的管道输入
4. 用 `Instance.provide({ directory: cwd, fn: () => TuiConfig.get() })` 读取 TUI 配置

这说明：

- worker 一出生就开始准备 server 和 event stream。
- 主线程同时在做 TUI 配置解析和 UI 初始化。

### 5.4 为什么主线程读配置时也会碰到项目实例

这里虽然没有传 `init: InstanceBootstrap`，但 `Instance.provide()` 仍然会：

1. `Filesystem.resolve(directory)`
2. `Project.fromDirectory(directory)`
3. 建立 `{ directory, worktree, project }` 上下文
4. 在这个上下文里执行 `TuiConfig.get()`

因此主线程仅仅读取 TUI 配置，也会顺手触发：

- git worktree / sandbox 识别
- project id 计算
- 项目记录的数据库 upsert

但不会启动插件、LSP、文件索引、watcher 等完整 runtime 服务。

---

## 6. TUI 配置：`TuiConfig.get()` 在默认启动时一定会跑

主线程读取 `TuiConfig` 时，会按下面顺序处理：

1. 计算项目级 `tui.json{,c}` 路径集合
2. 计算 `.opencode` 目录集合
3. 执行 `migrateTuiConfig(...)`
4. 重新计算项目级 `tui.json{,c}`
5. 按优先级合并配置
6. 对 `keybinds` 做 schema parse 并补默认值

合并优先级从低到高大致是：

1. `Global.Path.config/tui.jsonc`
2. `Global.Path.config/tui.json`
3. `OPENCODE_TUI_CONFIG`
4. 项目 `tui.jsonc/json`
5. 各级 `.opencode/tui.jsonc/json`
6. managed config dir 下的 `tui.jsonc/json`

### 6.1 `migrateTuiConfig()` 的副作用

这一步会扫描 `opencode.json{,c}`，把旧版 TUI 字段剥出来：

- `theme`
- `keybinds`
- `tui`

然后执行迁移：

1. 如果同目录还没有 `tui.json`，就新建一个
2. 写入 `$schema: "https://opencode.ai/tui.json"`
3. 把原文件备份成 `*.tui-migration.bak`
4. 从原 `opencode.json` 中删除旧的 TUI 字段

也就是说，默认启动时“只是读 TUI 配置”这件事，本身就可能改写磁盘文件。

---

## 7. transport：默认走内嵌模式，不是真端口

主线程随后会执行 `resolveNetworkOptions(args)`。这里读取的是 `Config.global()`，也就是全局用户配置，而不是当前项目的完整配置。

以下条件任意命中时，会切到外部 server 模式：

- CLI 显式传了 `--port`
- CLI 显式传了 `--hostname`
- CLI 显式传了 `--mdns`
- 配置里 `server.mdns = true`
- 端口不为 `0`
- host 不是 `127.0.0.1`

### 7.1 默认内嵌模式

默认情况下使用：

- `url = "http://opencode.internal"`
- `fetch = createWorkerFetch(client)`
- `events = createEventSource(client)`

这意味着：

1. TUI 发出的“HTTP 请求”不会真的走网络。
2. 请求会先经由 RPC 转发给 worker。
3. worker 在内部调用 `Server.Default().fetch(request)`。
4. 实时事件也不是浏览器直连 SSE，而是 worker 经由 RPC 再推回主线程。

### 7.2 显式开端口时

如果显式要求开端口，主线程会调用：

```ts
client.call("server", network)
```

worker 随后执行 `Server.listen(...)`，启动真正的 `Bun.serve()`。主线程拿到真实 URL 后，后续 TUI 才会直接请求这个地址。

---

## 8. worker：真正的 runtime 点火点

`src/cli/cmd/tui/worker.ts` 才是默认 TUI runtime 的核心，而且它的顶层代码会在 worker 启动时立刻执行。

### 8.1 worker 启动后立刻做什么

worker 一启动就会：

1. `Log.init(...)`
2. 注册 `unhandledRejection` / `uncaughtException`
3. 订阅 `GlobalBus.on("event", ...)`，把全局事件转成 `Rpc.emit("global.event", event)`
4. 立刻调用 `startEventStream({ directory: process.cwd() })`

第四步最关键，因为它会主动把 server 和 instance 点着。

### 8.2 `startEventStream()` 的真实工作

这一步会：

1. 创建新的 `AbortController`
2. 构造 `fetchFn`，内部直接调用 `Server.Default().fetch(request)`
3. 创建 `createOpencodeClient({ baseUrl: "http://opencode.internal", directory, experimental_workspaceID, fetch, signal })`
4. 循环调用 `sdk.event.subscribe()`
5. 把事件流里的每一条 `Event` 转成 `Rpc.emit("event", event)`

所以默认 TUI 模式下，worker 不是“先监听 server，再自己连 localhost”，而是直接把 Hono app 当成内存内函数调用。

### 8.3 第一个 `/event` 请求如何点着 runtime

把调用链展开，默认 TUI 下大致是：

```text
worker.ts:startEventStream({ directory: process.cwd() })
  -> createOpencodeClient({
       baseUrl: "http://opencode.internal",
       directory,
       experimental_workspaceID,
       fetch: (req) => Server.Default().fetch(req)
     })
  -> sdk.event.subscribe()
     -> 发 GET /event
     -> 自动带上 x-opencode-directory / x-opencode-workspace
     -> Server.Default().fetch(request)
        -> lazy(createApp({}))
        -> auth middleware
        -> request log middleware
        -> cors middleware
        -> 解析 directory / workspace
        -> WorkspaceContext.provide(...)
        -> Instance.provide({ directory, init: InstanceBootstrap, fn: next })
           -> 首次命中该目录时：
              -> Project.fromDirectory(directory)
              -> 建立 instance context
              -> 执行 InstanceBootstrap()
        -> WorkspaceRouterMiddleware
        -> EventRoutes().get("/event")
           -> streamSSE()
           -> 先发 server.connected
           -> 每 10s 发 server.heartbeat
           -> Bus.subscribeAll() 把 bus event 写入 SSE
  -> SDK 解析 SSE
  -> for await (const event of events.stream)
     -> Rpc.emit("event", event)
```

这里最关键的是：

1. 真正触发 `InstanceBootstrap()` 的，是 `/event` 请求经过 server 中间件时命中的 `Instance.provide(..., init: InstanceBootstrap)`。
2. `/event` 只是 worker 启动后最早发起的请求，所以顺手成了 runtime 点火器；后续 `/project`、`/session`、`/config` 等请求都会复用同一套实例上下文。
3. `InstanceBootstrap()` 不是每次请求都跑，只会在当前进程里某个目录第一次 miss `Instance` cache 时执行。

---

## 9. `Instance.provide()` 和 `Project.fromDirectory()`

`Instance.provide()` 以解析后的绝对目录为缓存 key。首次命中某个目录时，会执行一次 boot：

1. `Project.fromDirectory(input.directory)`
2. 得到 `directory`、`worktree`、`project`
3. 用 async local context 暴露这三个值
4. 在这个上下文里执行 `input.init?.()`

### 9.1 `Project.fromDirectory()` 不只是找仓库根目录

它做的是完整的项目识别流程：

1. 向上查找 `.git`
2. 如果没有 `.git`
   - `project.id = global`
   - `worktree = "/"`
   - `sandbox = "/"`
3. 如果有 git
   - `git rev-parse --git-common-dir` 判断是否 worktree
   - 先读 `.git/opencode` 中缓存的 project id
   - 没缓存时，用 `git rev-list --max-parents=0 HEAD` 的最早根提交 hash 作为 project id
   - 再把这个 id 回写到 `.git/opencode`
   - 用 `git rev-parse --show-toplevel` 计算 sandbox
4. 把结果 upsert 到 `ProjectTable`
5. 如有历史 session 仍挂在 `global` project 下，还会批量迁移到当前 project id

因此默认启动不仅是在“识别仓库”，还会顺手：

- 规范化项目身份
- 更新数据库记录
- 维护 worktree / sandbox 信息

---

## 10. `InstanceBootstrap()`：完整 runtime 服务图

当 worker 首次命中某个目录实例时，`InstanceBootstrap()` 会按固定顺序运行：

1. `Plugin.init()`
2. `ShareNext.init()`
3. `Format.init()`
4. `LSP.init()`
5. `File.init()`
6. `FileWatcher.init()`
7. `Vcs.init()`
8. `Snapshot.init()`
9. 订阅 `Command.Event.Executed`，在默认 `init` 命令执行后写入项目的 `initialized` 时间戳

### 10.1 `Plugin.init()`：完整 `Config.get()` 的真正入口

worker runtime 第一次真正触发 `Config.get()` 的地方，就是 `Plugin.init()`。它会：

1. 创建内嵌 SDK client，`fetch` 仍然指向 `Server.Default().fetch(...)`
2. 读取完整配置 `Config.get()`
3. 先加载内建插件，如 `CodexAuthPlugin`、`CopilotAuthPlugin`、`GitlabAuthPlugin`、`PoeAuthPlugin`
4. 如果配置里声明了外部插件
   - 先 `Config.waitForDependencies()`
   - 必要时给配置目录写 `package.json`
   - 执行 `bun install`
   - 再 `import(plugin)` 动态加载
5. 调用插件的 `config` hook
6. 订阅总线事件，把 bus event 交给插件的 `event` hook

因此插件初始化本身也是完整配置系统、依赖安装、动态模块加载的入口。

### 10.2 `Config.get()` 的优先级

从低到高大致是：

1. 远程 `.well-known/opencode`
2. 全局 config
3. `OPENCODE_CONFIG`
4. 项目 `opencode.json/jsonc`
5. `.opencode` 目录配置、agents、commands、plugins
6. `OPENCODE_CONFIG_CONTENT`
7. 当前账号所属组织下发的远程 config
8. managed config dir

还要补几个实现细节：

- `Auth.all()` 中如果有 `type = "wellknown"` 的认证项，会先拉远程配置。
- 项目级 `opencode.json` 是按“上层到下层”覆盖。
- `.opencode` 目录不只读配置文件，也会加载 `commands/**/*.md`、`agents/**/*.md`、`modes/*.md`、`plugins/*.{ts,js}`。
- `ConfigPaths.parseText()` 支持 `{env:VAR}` 和 `{file:path}`。
- 如果配置文件缺少 `$schema`，实现里还会尝试自动回写。
- 解析结束后还会做 `mode -> agent`、`tools -> permission`、`autoshare -> share` 等兼容迁移，并叠加部分环境变量覆盖。

### 10.3 其他 runtime 服务分别做什么

- `Format.init()`
  读取 `Config.get().formatter`，建立 formatter 表，并监听 `File.Event.Edited`。真正格式化不是启动时执行，而是在后续文件编辑时按扩展名触发。

- `LSP.init()`
  启动阶段只负责读取配置、建立可用 LSP 列表、记录禁用项和扩展名映射。LSP 子进程是按文件访问懒启动的。

- `File.init()`
  建立文件搜索缓存。git 项目下会通过 `Ripgrep.files({ cwd: Instance.directory })` 扫描文件，并顺手缓存目录层级。

- `FileWatcher.init()`
  如果 watcher 没被禁用，就加载 `@parcel/watcher` 平台绑定，订阅项目目录变化；git 项目还会额外订阅 `.git` 中的关键项。

- `Vcs.init()`
  读取当前 branch，并监听 `HEAD` 变化；分支变化时发布 `vcs.branch.updated`。

- `Snapshot.init()`
  为当前 project 维护独立 snapshot gitdir：

  ```text
  <Global.Path.data>/snapshot/<project.id>
  ```

  启动时主要准备状态对象，并建立每小时一次的 `git gc --prune=7.days` 清理循环。真正写当前工作区快照是在后续 `Snapshot.track()` 时发生。

---

## 11. TUI 首屏：不是一次性全量加载

主线程执行 `tui()` 后，还要经历两层启动：先装配 Provider 树，再做分阶段同步。

### 11.1 render 前还有一次终端背景探测

主线程会先发一个 OSC 11 查询，用来判断当前主题更接近 `dark` 还是 `light`：

1. 临时把 `stdin` 设成 raw mode
2. 发送 `\x1b]11;?\x07`
3. 等待终端回传颜色
4. 计算亮度
5. 超时则默认 `dark`

### 11.2 Provider 树的大致分层

`render()` 时挂上的 Provider 可以粗略分成四层：

1. 基础运行层：`ArgsProvider`、`ExitProvider`、`KVProvider`、`ToastProvider`、`RouteProvider`
2. 通信与同步层：`TuiConfigProvider`、`SDKProvider`、`SyncProvider`
3. 本地 UI 状态层：`ThemeProvider`、`LocalProvider`、`KeybindProvider`、`DialogProvider`
4. 命令与历史层：`CommandProvider`、`FrecencyProvider`、`PromptHistoryProvider`、`PromptRefProvider`

`App` 放在最底部，说明 UI 组件本身不是启动起点，而是消费这些上层上下文的结果。

### 11.3 `SDKProvider`：UI 侧的通信入口

`SDKProvider` 负责创建 `createOpencodeClient(...)` 并维持事件流。关键行为包括：

- 默认 `baseUrl` 是 `http://opencode.internal`
- 会把当前 `directory` 一并传给 SDK
- 没有 `props.events` 时自己走 SSE
- 已有 `props.events` 时直接消费 worker RPC 回来的事件
- 事件先进入 16ms 批处理队列，再批量写入 UI
- 当前 session 切换 workspace 时，`setWorkspace()` 会重建 client，并让 worker 重启 event stream

### 11.4 `SyncProvider.bootstrap()`：分两段把首屏数据灌进来

首屏同步分两阶段。

阻塞阶段会并发请求：

1. `config.providers`
2. `provider.list`
3. `app.agents`
4. `config.get`
5. 如果带了 `--continue`，还会阻塞等待 `session.list({ start: 30 days ago })`

只有这些返回后，状态才会从 `loading` 切到 `partial`。

随后是后台的非阻塞阶段，会继续拉：

1. `session.list(...)`
2. `command.list()`
3. `lsp.status()`
4. `mcp.status()`
5. `experimental.resource.list()`
6. `formatter.status()`
7. `session.status()`
8. `provider.auth()`
9. `vcs.get()`
10. `path.get()`
11. `workspace.list()`

全部完成后，状态才会进入 `complete`。这也是首页能较快可交互的原因。

---

## 12. 路由与启动参数

默认路由是：

```ts
{ type: "home" }
```

但启动参数会继续推动首页和会话路由的行为。

### 12.1 `App` 层会先处理什么

`App` 在 `onMount()` 里先处理：

1. `--agent`：写入本地 agent store
2. `--model`：解析 provider / model 后写入本地 model store
3. `--session` 且没有 `--fork`：立即跳到指定 session

随后两个 `createEffect()` 会继续处理：

- `--continue`
  等 `session list` 至少到 `partial`，找到最近更新的根 session；如果同时带了 `--fork`，则先 fork 再跳转。

- `--session --fork`
  必须等到 `sync.status === "complete"` 才会 fork 指定 session。

### 12.2 `Home` 何时自动提交 `--prompt`

首页还会做一层输入框相关逻辑：

1. 读取提示文案和 tips 状态
2. 根据 MCP 连接状态渲染提示
3. 如果有 `route.initialPrompt` 或 `args.prompt`，先把 prompt 填进输入框
4. 只有等到 `sync.ready && local.model.ready`，才会真正自动提交 `--prompt`

所以 `opencode --prompt "..."` 不是一进程就立刻发请求，而是会先等 provider、model、route 状态就位。

## 13. 进入 Session 后的深同步

首页拿到的 session list 只能支撑列表展示，真正切到某个 session 后，还会再执行一次深同步。

`sync.session.sync(sessionID)` 会并发拉取：

1. `session.get({ sessionID })`
2. `session.messages({ sessionID, limit: 100 })`
3. `session.todo({ sessionID })`
4. `session.diff({ sessionID })`

随后把这些结果一起写进 store：

- `session`
- `message[sessionID]`
- `part[messageID]`
- `todo[sessionID]`
- `session_diff[sessionID]`

如果该 session 绑定了 `workspaceID`，还会调用 `sdk.setWorkspace(...)`，让 worker 侧重启 event stream 并切到对应 workspace。

---

## 14. 退出与清理

默认 TUI 退出时，主线程和 worker 各自收尾。

### 14.1 主线程

`TuiThreadCommand.stop()` 会：

1. 移除异常和 reload 监听
2. 通过 RPC 调用 `shutdown`
3. 最多等待 5 秒
4. 即使超时，也继续 `worker.terminate()`

### 14.2 worker

`rpc.shutdown()` 会：

1. 记录 `worker shutting down`
2. abort 当前 event stream
3. `Instance.disposeAll()`
4. 如果之前启动过真实 server，则执行 `server.stop(true)`

### 14.3 `Instance.disposeAll()`

它会遍历当前进程里的目录实例：

1. `State.dispose(directory)`
2. `disposeInstance(directory)`
3. 清理 cache
4. `GlobalBus.emit("server.instance.disposed", ...)`

如果 UI 还活着，这个事件又会被 `SyncProvider` 捕获，并触发一次重新 bootstrap。

---

## 15. 和其他命令分支的差异

### 15.1 `opencode run ...`

这条路径不会起 TUI worker，而是直接：

1. `bootstrap(process.cwd(), ...)`
2. `Instance.provide(..., init: InstanceBootstrap)`
3. 用内嵌 `Server.Default().fetch` 构造 SDK client
4. 执行 session prompt / command

### 15.2 `opencode attach <url>`

这条路径也不会起本地 worker runtime，只会：

1. 本地读取 `TuiConfig`
2. 让 TUI 直接连接远端 URL

### 15.3 `opencode serve` / `opencode web`

这两类命令会走显式监听端口的 server 分支，而不是默认 TUI 的内嵌 transport。

---

## 16. 一句话总结

默认 `opencode` 启动不是“一个 CLI 直接显示 UI”，而是：

**平台 shim 选中原生二进制 -> `src/index.ts` 完成日志和数据库准备 -> 默认 TUI 命令拉起主线程壳 -> 主线程 spawn worker -> worker 通过第一次 `/event` 请求触发 `InstanceBootstrap()` -> 配置、插件、文件索引、watcher、VCS、snapshot 等 runtime 服务完成初始化 -> `SyncProvider` 分阶段把首屏数据灌进 UI -> 首页或指定 session 最终进入可交互状态。**

如果只保留两个最重要的认识，那就是：

1. 默认 TUI 至少包含主线程和 worker 两个执行上下文。
2. 真正的项目 runtime 启动，不发生在 `tui()`，而发生在 worker 第一次命中 server 中间件时。
