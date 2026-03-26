# OpenCode 核心构建物启动与调试指南

> 本文基于 `opencode` `v1.3.2`（tag `v1.3.2`，commit `0dcdf5f529dced23d8452c9aa5f166abb24d8f7c`）源码校对

## 1. 先确认运行前提

根目录 `package.json` 明确了当前工作区的基础前提：

1. 包管理器与运行时是 `bun@1.3.11`。
2. 根脚本负责把命令分发到各个包，不存在统一的根级 `test`。
3. 如果你刚切到 `v1.3.2`，应先在仓库根目录执行一次 `bun install`，避免 workspace 依赖和补丁包不匹配。

推荐先做：

```bash
cd /path/to/opencode
bun install
```

需要注意两点：

1. 根目录的 `test` 脚本故意直接失败，提示你不要从根目录跑测试。
2. 真正的类型检查、测试、开发命令要么走根分发脚本，要么进入具体 package 执行。

---

## 2. 根目录最常用的启动命令

根目录 `package.json` 里与开发最相关的脚本如下：

| 命令 | 实际作用 |
| --- | --- |
| `bun dev` | 进入 `packages/opencode/src/index.ts`，默认触发 `$0 [project]`，也就是 TUI 入口。 |
| `bun dev serve` | 走同一个 CLI 入口，但执行 `serve` 子命令。 |
| `bun dev web` | 走同一个 CLI 入口，但执行 `web` 子命令。 |
| `bun dev attach <url>` | 走同一个 CLI 入口，但执行 `attach` 子命令。 |
| `bun run dev:web` | 启动 `packages/app`。 |
| `bun run dev:desktop` | 启动 Tauri 桌面壳。 |
| `bun run dev:console` | 启动控制台前端。 |
| `bun run dev:storybook` | 启动 Storybook。 |
| `bun run typecheck` | 通过 `bun turbo typecheck` 做工作区级类型检查。 |

如果你只关心 agent runtime，本质上最重要的根脚本只有一个：

```bash
bun run --cwd packages/opencode --conditions=browser src/index.ts
```

根目录的 `bun dev ...` 只是把参数透传给它。

---

## 3. `packages/opencode` 运行时怎么启动

### 3.1 默认 TUI

默认命令对应 `cli/cmd/tui/thread.ts` 的 `$0 [project]`：

```bash
bun dev
bun dev .
bun dev /absolute/path/to/project
```

常见附加参数也都来自这个入口：

```bash
bun dev . --model openai/gpt-5
bun dev . --agent build
bun dev . --continue
bun dev . --session <session-id>
bun dev . --fork
```

### 3.2 一次性 CLI

`run` 子命令适合非交互式调用：

```bash
bun dev run "summarize this repository"
bun dev run "fix lint" --agent build
```

### 3.3 Headless Server

`serve` 子命令启动纯 HTTP server：

```bash
bun dev serve
bun dev serve --port 8080
bun dev serve --hostname 0.0.0.0 --port 4096
```

`v1.3.2` 的网络参数默认值来自 `src/cli/network.ts`：

1. `hostname` 默认是 `127.0.0.1`
2. `port` 默认是 `0`
3. `mdns` 默认是 `false`

而 `Server.listen()` 的实现会在 `port=0` 时优先尝试 `4096`，失败后再退回系统随机端口。

如果要暴露给其他机器访问，至少需要考虑两件事：

1. `--hostname 0.0.0.0`
2. 设置 `OPENCODE_SERVER_PASSWORD`

### 3.4 Web 模式

`web` 子命令会先起本地 server，再尝试打开浏览器：

```bash
bun dev web
bun dev web --port 4096
```

这里本地跑起来的是 `Server.listen()`；未知路径由 server 兜底代理到 `https://app.opencode.ai`。

### 3.5 Attach 模式

`attach <url>` 用于让本地 TUI 接远端或预启动 server：

```bash
bun dev attach http://localhost:4096
bun dev attach http://127.0.0.1:4096 --password <server-password>
```

它支持 `--continue`、`--session`、`--fork`，本质上还是在消费同一套 server API 和 SSE。

---

## 4. 直接在包目录执行的常用命令

如果你不想经过根分发脚本，可以直接进入包目录。

### 4.1 运行时包

```bash
cd packages/opencode
bun run dev
bun run typecheck
bun run test
```

对应关系是：

1. `dev` 直接执行 `./src/index.ts`
2. `typecheck` 是 `tsgo --noEmit`
3. `test` 是 `bun test --timeout 30000`

### 4.2 前端与桌面壳

```bash
cd packages/app
bun run dev

cd packages/desktop
bun run tauri dev

cd packages/desktop-electron
bun run dev
```

### 4.3 其他常用前端包

```bash
bun run dev:web
bun run dev:console
bun run dev:storybook

cd packages/web
bun run dev
```

其中：

1. `packages/app` 是本地 agent UI 会复用的前端应用。
2. `packages/web` 是公开站点/文档站点。
3. `packages/console/app` 是控制台前端。

---

## 5. 与启动相关的几个实用判断

1. 想看 agent 主链路，用 `bun dev` 或 `bun dev run ...`。
2. 想看纯 server 行为，用 `bun dev serve`。
3. 想看浏览器端连接本地 runtime，用 `bun dev web`。
4. 想看桌面 sidecar 与前端结合，用 `bun run dev:desktop` 或 Electron 包。
5. 想跑校验，不要在根目录跑 `test`，而是进入具体 package。
