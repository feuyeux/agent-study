# OpenCode 工作区目录结构深度分析

本文档基于真实的 `opencode` 代码仓库（基于 **Bun** 运行时 + **Turborepo** 构建栈）的物理组织结构，解析其作为一个独立子仓的 Monorepo 工程骨架。

---

## 1. 整体架构范式与基础设施栈

`opencode` 本身不仅是一个 CLI 项目，而是一个包含多主端应用的前端/全栈 Monorepo。
- **运行时与包管理**: [Bun](https://bun.sh) (`v1.3.10+`)。采用极其新锐的前端栈（`esbuild`, `effect.ts`, `solid-js`）。
- **工作区编排**: `workspaces` 配置在了 `package.json` 中，包含 `packages/*`, `packages/console/*`, `packages/sdk/js`, `packages/slack` 等，并用 [Turborepo](https://turbo.build/) 做任务流与增量缓存（`turbo.json`）。
- **云基础设施编排**: 集成了 **SST (Serverless Stack)** (`sst.config.ts`, `infra/`)。通过直接用 TS 编写的 CDK 映射到云组件上部署 Web 与后台应用环境。

---

## 2. 根目录核心控制文件

项目的根路径包含了控制全局编译时（Compile-time）与运行时（Runtime）的策略：

- **`package.json`** 
  - **工作区映射**：指明了所有子 npm 包的位置。它开启了 Bun 的 `catalog` 管理特性，统一全局依赖版本（如 `drizzle-orm`, `hono`, `tailwindcss` 等）。
  - **核心命令簇**：`dev` 指向了基于 `packages/opencode` 下源码的 TUI 与 Server 启动；另外提供了诸如 `dev:desktop`, `dev:web`, `dev:console`, `dev:storybook` 针对特定客户端的启动通道。
  - **依赖补丁**：下设 `patchedDependencies`，通过本地 `patches/` 对固化问题第三方包进行强力入侵修补（例如修复官方 `@ai-sdk/xai` 或 `@openrouter` SDK）。
- **`turbo.json` / `sst.config.ts`**
  - 控制构建管线的高级拓扑。结合 SST 定义 AWS 等服务部署流。
- **配置底座支持文件**
  - 使用 `bunfig.toml` / `bun.lock`。
  - 全局 Typescript 支持（`tsconfig.json`），并且还混合集成了 Nix 环境声明（`flake.nix`）从而实现在 NixOS 生态下的绝对环境隔离与复现。

---

## 3. 按业务域划分的核心代码空间 (`packages/`)

工作区内的每一个目录，都是边界明晰的独立模块领域。

### 3.1 核心大底座与运行时
- **`packages/opencode/`**
  这是整个底层 AI 运行时能力与服务的承载者（约占系统 70% 逻辑复杂度）。包含了由 yargs 驱动的 CLI、本地 Hono Server、核心基于 SQLite 的 Durable State Machine 引擎，以及与所有大模型通信和调用工具的沙箱体系（详见 `opencode_src_analysis.md`）。

### 3.2 图形界面与终端呈现
为了适应多端（Web, App, 终端），展现出极其清晰的前端与展现层解耦：
- **`packages/app/`**
  核心的纯 Web 应用程序态（采用 Solid.js 栈构建的高性能界面），能够直接在浏览器运行或被宿主窗口嵌套加载。
- **桌面端双保险外壳**
  - **`packages/desktop/`**：最新的主流桌面客户端解决方案，直接通过 `.rs` 调用使用 Rust 编写的 [Tauri](https://tauri.app/) 系统，构建体积小且性能优异。
  - **`packages/desktop-electron/`**：另一套平行保留的遗留宿主方案，通过 Node (Main) + Browser (Renderer) 托管前端界面。
- **`packages/console/`**
  后台云控制台的前端应用入口，通常用于面向多账户管理和审计配置等控制面（Control Plane）相关功能。

### 3.3 生态、服务扩展与基础 UI 库
- **`packages/slack/`**
  业务外联服务（第三方办公协同通讯平台接入的 Bot 后台服务端）。
- **`packages/func/` / `packages/function/`** (视具体构建而定)
  对应于 SST AWS Lambda 或相似 Serverless 环境分离出的零碎函数片端代码。
- **`packages/sdk/js`** 等
  专门抽离出的、用于与 OpenCode 标准化模型/Session 协议交互的 API 客户端 SDK，它是多端界面与 CLI 无缝通信的基础。
- **公共 UI 资源**
  比如针对 Storybook 的独立沙盒工作区包。

---

## 4. 其余顶层功能性目录
除了庞大的业务堆栈 `packages/`，根目录下还存在如下基建：
- **`script/`**：一套内建的非常严格和现代的发版、检查脚本集合（如自动处理发版和 changelog 合并）。
- **`infra/`**：以基础设施即代码（IaC）方式定义的云资源结构，跟据不同的 `sst` stage (如 prod/dev) 自动化执行云资源的开通与挂载。
- **`install/` / `nix/`**：面向用户侧部署和安装依赖（如针对类 Unix 系统和 macOS 的专用一键拉起与引导环境脚本等）。
- **`patches/`**：存储 `package.json` 设置打入的特殊依赖源修复代码的差异补丁。
- **`sdks/`**：与特定 IDE 编辑器（通常为 `vscode` / `zed`）集成的配置及特供集成工具包。

## 5. 结论

`opencode` 的多包 Monorepo 体系并非简单的“把库放到一起”，而是服务于**单一运行时内核支撑多样性 UI 显示层**这一产品的终极形态：一套底层核心逻辑 (`packages/opencode`) 可无缝被运行时的内置 HTTP Server 包裹，供跨端的 Web UI (`packages/app`) 或原生平台壳 (`packages/desktop`) 分发调用。并且底层使用了统一且暴力的工具链如 Bun 与 Turbo 保障复杂构建体验不下降。
