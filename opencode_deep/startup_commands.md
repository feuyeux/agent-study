# OpenCode 核心构建物启动与调试指南

在 `opencode` 项目中采用了极具现代化的 Monorepo 和多端（Headless API、TUI、Web、Desktop）混合架构。通过一套底层的 Server 与 Event Bus，支撑起了多形态的应用。

> **核心前提与常见依赖问题避坑**：
> 1. **根目录执行**：请确保你的终端当前工作路径位于整个项目的根目录 `/opencode`。虽然部分框架支持切换目录执行，但大部分脚本的预设挂载均基于项目根部。
> 2. **包管理器使用**：全工程**仅且强依赖 [Bun](https://bun.sh) (`v1.3.10+`)**。切勿在该目录使用 `npmi`/`pnpm`/`yarn`。
> 3. **首次环境依赖处理**：必须**完整执行一次 `bun install`**，以此触发 Bun 的 catalog workspace 自动关联过程，否则部分包（如 `@opencode-ai/sdk`）与互相依赖关系无法生效。
> 4. **macOS 权限避坑**：在启动基于 Tauri 的应用程序时，偶尔可能出现缓存/执行临时目录缺乏写权限导致的 `PermissionDenied`。临时可利用覆盖环境变量重定向的方式解决（例如：`TMPDIR=/tmp bun run dev:desktop`）。

---

## 1. 核心底座引擎 (Core Services)

### API Server (无头服务端)
这是支持 CLI、Web 端、桌面端客户端均能以正常工作流流转的底层基座，用于接管大模型网络收发和事件广播流。
```bash
# 默认开启 headless Server。bun dev 是跑根部的 script
bun dev serve               

# 也可以直接针对特定路径
bun run --cwd packages/opencode src/index.ts serve --port 8080
```

---

## 2. 交互终端与命令行 (CLI & TUI)

作为原生的 Agent 互动手段，CLI 可以直接在你的目前 Shell 工作区拉起一个极速的 Solid.js + opentui 组件化的终端界面。

### 启动完整的本端终端应用 (自动拉起 Worker Server)
默认命令在启动本端终端界面（TUI）的同时，还会在后台自动构建并挂起支持 RPC 的 API 服务：
```bash
bun dev          # 默认拉起交互终端 TUI 模式，接管默认项目路径
bun dev .        # 指定以操作该项目根目录的形式启动 TUI
bun dev <PATH>   # 指明一个特定的工作区以启动
```

### 接入已启动服务器模式 (Attach)
脱离内置环境，将本地的终端直接接管到远端或预启动的 Server 上：
```bash
bun dev attach <HTTP_SERVER_URL>
```

---

## 3. 面向原生桌面客户端 (Desktop Clients)

借由完全独立的前后端架构拆分，同样的 Agent 能力也可以被内嵌到系统原生窗口（Tauri 或 Electron）中。

### 3.1 基于 Tauri 架构 (当前主线态)
采用底层 Rust 捆绑侧伴（Sidecar），资源利用率高且启动快，必须要在宿主机拥有 Rust 工具链：
```bash
# 本地原生桌面调试进程拉起 (同时拉起内嵌包的 localhost 端口页面)
bun run dev:desktop
# 也可以显式：bun run --cwd packages/desktop tauri dev
```

### 3.2 基于 Electron 架构 (传统的备选兼容分支)
采用传统的全量 Chromium + NodeJS Main 进程托管，主要走一套与 Tauri 全然不同的发布包管理规范。
```bash
bun run --cwd packages/desktop-electron dev
```

---

## 4. 前端应用界面展现层 (Web Applications)

通过 Vite 强力打包呈现的交互界面层（这同时也是桌面版本背后的那套前端 UI 展示引擎）。

### Core Web APP (`packages/app`)
这个包承载着最复杂的 UI 交互业务，能通过独立端口在普通的现代浏览器打开。
**注意：单独启动前端通常不可脱离 API Server。**
```bash
bun run dev:web
# 在浏览器端开启服务，通常监听 http://localhost:5173 
```

---

## 5. 云管控与生态集成周边 (Ecosystem & Tooling)

### 控制台前台 (Web Console)
面对云端和多账户环境管理的入口（涉及部署态时的登录身份映射）：
```bash
bun run dev:console
# 注意内置指令已经针对类 unix 平台包含了 ulimit 拓频防爆逻辑
```

### Storybook (核心组件沙盒)
专门供前端开发独立演进和调试无业务侧杂项干扰的可视化 UI 库测试平台。
```bash
bun run dev:storybook
```

---

## 🌟 高级开发：后端运行时调优介入 (Inspector Debugger)

作为大量的异步、`yield` 事件流与 Agent State 混杂的系统工程，纯靠 `console.log` 会非常吃力，并且常规的 `bun dev` 在拉起 Worker 时会干扰到默认断点的捕捉。

**最佳服务进程联调方式**：以显式挂放 Inspector 及端口的方式剥离启动 Core Server。

```bash
bun run --inspect=ws://localhost:6499/ --cwd packages/opencode src/index.ts serve --port 4096
```
> 完成绑定后，就可以任意地接管或向 HTTP 端口发动 Session Post 接口，并确保你在诸如特定工具的 SandBox API (如 `TaskTool.execute`) 或 LLM SDK Adapter `transform.ts` 之处设下的每一处断住。
