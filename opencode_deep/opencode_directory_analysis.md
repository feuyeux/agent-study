# OpenCode 工作区目录结构深度分析

> 本文基于 `opencode` `v1.3.2`（tag `v1.3.2`，commit `0dcdf5f529dced23d8452c9aa5f166abb24d8f7c`）源码校对

---

## 1. 根目录扮演什么角色

`opencode` 在 `v1.3.2` 里是一个以 **Bun** 为运行时和包管理器、以 **Turborepo** 为工作区编排器的 monorepo。

从根目录 `package.json` 可以直接确认三件事：

1. `packageManager` 是 `bun@1.3.11`。
2. workspaces 覆盖 `packages/*`、`packages/console/*`、`packages/sdk/js`、`packages/slack`。
3. 根脚本只做“分发入口”，真正的运行时代码主要在 `packages/opencode`，其他脚本则把不同客户端拉起来。

根目录最值得优先认识的文件是：

| 路径 | 作用 |
| --- | --- |
| `package.json` | 工作区声明、根入口脚本、依赖 catalog、patchedDependencies。 |
| `bun.lock` / `bunfig.toml` | Bun 锁文件与运行配置。 |
| `turbo.json` | 跨包任务编排。 |
| `sst.config.ts` | SST 基础设施入口。 |
| `flake.nix` / `flake.lock` | Nix 环境声明。 |

---

## 2. 根目录有哪些重要顶层目录

`v1.3.2` 根目录的顶层目录主要是：

| 目录 | 角色 |
| --- | --- |
| `packages/` | 绝大多数业务代码与工作区包。 |
| `infra/` | SST 相关基础设施代码。 |
| `script/` | 根级脚本与发布辅助。 |
| `patches/` | 对第三方依赖的补丁。 |
| `sdks/` | 编辑器或外部集成相关资源。 |
| `specs/` | 规格或协议相关内容。 |
| `nix/` | Nix 生态支持文件。 |
| `.opencode/` | 本地运行生成或工作目录相关内容。 |
| `.github/` / `github/` | GitHub Actions 与仓库自动化相关资源。 |

这也说明一个边界：根目录不是单一应用，而是“运行时 + 多端壳 + 控制台 + 官网/文档 + 共享库”的集合。

---

## 3. `packages/` 里的真实分层

`packages/` 是理解整个仓库的关键。按职责看，`v1.3.2` 大致可以分成 5 组。

### 3.1 核心运行时

| 目录 | 作用 |
| --- | --- |
| `packages/opencode/` | 主运行时。包含 CLI、TUI、HTTP Server、Session、Provider、Tool、SQLite、事件总线等核心能力。 |
| `packages/plugin/` | 插件能力与相关构建脚本。 |
| `packages/sdk/js/` | 面向外部或其他宿主的 JS SDK。 |
| `packages/util/` | 共享工具库。 |

如果你的目标是理解“agent 真正如何运行”，优先看 `packages/opencode/`。

### 3.2 用户可见客户端

| 目录 | 作用 |
| --- | --- |
| `packages/app/` | 通用前端应用，桌面壳与部分 Web 体验会复用它。 |
| `packages/desktop/` | Tauri 桌面壳。 |
| `packages/desktop-electron/` | Electron 桌面壳。 |
| `packages/web/` | 公开网站/文档站点的 Web 壳与页面路由。 |
| `packages/enterprise/` | 企业端前端应用。 |
| `packages/storybook/` | 组件开发与展示沙盒。 |

需要特别区分：

1. `packages/app` 是本地 agent UI 会复用的前端应用。
2. `packages/web` 是公开网站/文档站点，不等于 `opencode web` 命令背后的本地 runtime。

### 3.3 控制台与云侧代码

| 目录 | 作用 |
| --- | --- |
| `packages/console/app/` | 控制台前端。 |
| `packages/console/core/` | 控制台共享核心逻辑。 |
| `packages/console/function/` | 控制台相关函数代码。 |
| `packages/console/mail/` | 控制台邮件相关模块。 |
| `packages/console/resource/` | 控制台资源层。 |
| `packages/function/` | 通用函数或服务端代码。 |
| `packages/identity/` | 身份相关模块。 |
| `packages/slack/` | Slack 集成。 |

### 3.4 共享 UI、脚本与扩展

| 目录 | 作用 |
| --- | --- |
| `packages/ui/` | 共享 UI 组件与样式资源。 |
| `packages/script/` | 工作区内部可复用脚本。 |
| `packages/extensions/zed/` | Zed 扩展相关内容。 |
| `packages/containers/` | 各类构建/发布容器定义。 |

### 3.5 文档内容

| 目录 | 作用 |
| --- | --- |
| `packages/docs/` | 文档正文、图片、snippets 等内容源。 |
| `packages/web/` | 消费这些内容并提供站点壳与页面渲染。 |

这两者在 `v1.3.2` 是分离的，所以“文档内容仓”与“文档站点壳”不要混为一谈。

---

## 4. 对源码阅读最有价值的主路径

如果你的目标是读懂 `opencode` 运行链路，建议按下面顺序看目录：

1. `packages/opencode/`
2. `packages/app/`
3. `packages/desktop/` 与 `packages/desktop-electron/`
4. `packages/sdk/js/`
5. `packages/plugin/`

这条路径对应的是：

1. 核心 runtime 在哪。
2. 前端如何消费同一套 HTTP/SSE 协议。
3. 桌面壳如何拉起本地 sidecar。
4. SDK 如何把外部调用也收束到同一套 server contract。

---

## 5. 目录结构透露出的架构结论

`v1.3.2` 的目录布局传达了一个非常明确的设计取向：

1. `packages/opencode` 是唯一真正的 agent runtime 内核。
2. `packages/app`、`packages/desktop`、`packages/desktop-electron` 只是不同宿主和表现层。
3. `packages/web` 与 `packages/docs` 面向公开站点和文档体系，不是本地 agent runtime 本体。
4. monorepo 的目的不是“堆在一起”，而是让一套 durable runtime 被多个客户端、控制台和集成层复用。
