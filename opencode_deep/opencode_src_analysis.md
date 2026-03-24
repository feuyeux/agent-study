# OpenCode `src/` 源码架构全景解析

本文档是对 `opencode/packages/opencode/src` 目录（共 39 个核心模块）的深度架构解析。有别于只列出目录名称的宽泛描述，本文从 OpenCode 的真实执行时（Runtime）视角出发，将这 39 个离散目录划分为 6 大核心子系统。

这 6 大子系统构成了一个**持久化驱动（Durable State**）、**多端适配（Multi-host API）**、**带复杂沙箱与回滚能力（Sandbox & Revert）**的大型智能代理运行时。

---

## 1. 核心底座与多端入口层 (Core Entry & CLI)
OpenCode 并不只是一个简单的 CLI 命令脚本。它的入口层负责了多形态（CLI单次执行、长驻TUI线程、Web/桌面端接入、ACP协议端点）的统一路由与基础环境装载。

- **`index.ts`**
  应用的真正启动大门。通过 `yargs` 注册了多达 20 余个子命令，并在启动前统一拦截了 SQLite 数据库的一次性 JSON 迁移（`JsonMigration.run`）和全局未捕获异常处理。
- **`cli/`**
  分发所有的命令实现逻辑。其内部的 `cmd/` 目录不光有基础的 `run.ts`，还有复杂的宿主挂载：
  - `tui/thread.ts`：将 TUI 前端跑在 Worker 线程，用 RPC 透明代理底层的 HTTP Server。
  - `acp.ts`：把内部会话 SDK 重新包装成标准化的 Agent Client Protocol，通过 stdio `ndjson` 暴露能力。
  - `ui.ts` / `error.ts`：对终端呈现效果、报错链路进行美化封装。
- **`command/`**
  抽象通用命令结构接口，解耦具体子命令业务逻辑。
- **`installation/`**
  运行环境自检机制（如判断是否处于 `isLocal()` 本地源码调试态、提取版本号等）。
- **`config/`** 与 **`env/`** 与 **`global/`** 与 **`flag/`**
  一套完整的设计：`config/` 处理基于文件的持久化配置 Schema，`env/` 解析 `.env` 等运行时环境，`global/` 掌控应用级全生命周期的系统目录定义（如 `Global.Path.data`），而 `flag/` 用于特征实验开关管理。

---

## 2. 核心大模型运行时与编排层 (Orchestration & Session)
这是 OpenCode 作为 AI Agent 框架的心脏。它**放弃了内存对话树**，转而采用以 SQLite 为真相源的持久化状态机模型（Durable State Machine）。

- **`session/`** (最高复杂度的核心引擎)
  负责推进大模型流与状态边界。
  - **调度机制**：不仅有 `prompt.ts` 将输入转成 durable message，更包含了由 `loop()` 循环主导的任务流；内部包括 `processor.ts` 处理每一次 LLM Stream。
  - **韧性与状态维护**：`retry.ts` (指数退避), `revert.ts` (历史及文件版本回退), `compaction.ts` (上下文 token 爆炸时的主动摘要压缩)。
  - **模型**：`message-v2.ts`（强大的异构 Part 系统：文本 / reason / tool / diff），`session.sql.ts`。
- **`agent/`**
  Agent 并不是一个活着的进程，而是一组静态的**能力约束策略集**。它定义了当前处于什么模式（`build`、`explore`、`plan`）、最大执行轮次以及授权使用哪些工具（`prompt`/`steps`/`permission`）。
- **`project/`**
  工作区概念基石（`project.ts`, `vcs.ts`）。在命令发起时，它通过自动发现最近的 `.git` 或 package 等锚点确定环境上下文，提供给大模型当前的代码地貌认知。
- **`worktree/`** 与 **`snapshot/`**
  防御性编程的极致体现：Agent 修改代码前开启快照追踪（Snapshot），随时准备依据大模型误操作直接丢弃改动；`worktree` 控制 Git 视图与防呆处理策略。

---

## 3. 工具沙箱与执行能力层 (Tools & Execution)
大模型要干活，需要具体的“手和脚”。此部分抽象出了模型能调用的底层能力栈，并通过严格的协议包装它们。

- **`tool/`**
  Agent 可动用的动作集合：
  - **核心命令系**：`bash.ts`（开启受控 pty 跑脚本）、`grep.ts`/`ls.ts`（文件检索）。
  - **代码修缮系**：`edit.ts`, `apply_patch.ts`, `multiedit.ts`（核心护城河：支持批量原子性修改的差异应用工具）。
  - **文件数据系**：`read.ts`, `codesearch.ts`, `lsp.ts`（代码级搜索与文件读取）。
  - **外联能力**：`webfetch.ts`, `websearch.ts`。
  - **自递归任务**：`task.ts`（允许开启子代理 Subagent，建立 Child Session），`todo.ts`。
  值得注意的是：这些 TypeScript 文件紧跟着一个个配套的 `.txt` Prompt，专用于教授大模型如何高质量地生成正确的 Tool Call JSON。
- **`skill/`**
  高级扩展能力发现总线，系统能通过 `discovery.ts` 获取工作区额外定制的场景专用技能（Skills）。
- **`shell/`** & **`pty/`**
  构建了一个能在模型和宿主间挂载的虚拟终端沙盒，而非简单的 `child_process.exec()`。它能收集输出并按指定长度截断，防阻塞。
- **`file/`** & **`filesystem/`**
  深度文件系统接口层：并非只是 `fs`，它内置了 `.gitignore` 感知（`ignore.ts`），保护性文件列表屏蔽（`protected.ts`），高性能全局查找（`ripgrep.ts`）和文件变动监控（`watcher.ts`）。

---

## 4. 大模型通信与生态集成协议 (Providers & Integrations)
为了让业务层调用做到“模型和扩展无关”，该层负责拉齐所有外部服务提供商和集成生态的通信数据标准。

- **`provider/`**
  提供与外部大脑对话的基础设施。统一桥接各大供应商（Anthropic、OpenAI、Ollama等），内部完成了授权（`auth.ts`）、特定模型的 Token 计算规则、System Prompt 差异抹平，甚至是某些模型（如 LiteLLM）无法支持工具调用时的“退化兜底补丁”。
- **`mcp/`** (Model Context Protocol)
  全面支持新一代的模型上下文协议（Model Context Protocol）。内部实现了连接和暴露 MCP Servers，允许将外部工具与资源原生喂给 OpenCode。
- **`lsp/`**
  Language Server Protocol 支持层。当普通正则找不到关键代码在哪时，这层能让 Agent 建立一个 `client.ts`，像 IDE 一样唤醒后台对应的语言服务（如 `tsserver`、`rust-analyzer`），查询符号（Symbol）、引用（References）并精准跳转。
- **`plugin/`**
  在固定插槽点进行钩子注入的扩展机制系统（例如在生成 system prompt 前允许特定的 `plugin` 修改上下文），以及针对特殊辅助工具如 `copilot.ts` 的接口联络。
- **`acp/`**
  Agent Control Protocol 定义代理层抽象标准。

---

## 5. 持久化、服务基础设施与鉴权系统 (Infrastructure & Security)
这部分解决了应用如何在背后静默提供持久化服务，甚至暴露给局域网其他客户端、进行状态落盘的复杂设计。

- **`storage/`**
  底层为高可用而做的 SQLite Drizzle 封装（`db.ts`、`json-migration.ts`）。它创造了 `Database.effect()` 队列模式，确保只在数据库事务确认提交后，系统才会把相关的 WebSocket 状态变更事件抛出去。
- **`server/`**
  内置了一个使用 **Hono** 构建的极低开销 HTTP REST 服务网关。不仅承担本地 UI (TUI) 的后端轮询，还通过 `mdns.ts` 处理局域网互相发现，把本地工具直接变为了服务能力提供者。
- **`control-plane/`**
  控制平面：代理不同 workspace 之间的请求调度与路由转发（如 `workspace-router-middleware.ts` 明确写明需要做转发代理逻辑）。
- **`permission/`** 与 **`auth/`** 与 **`question/`**
  企业级的防崩溃管控矩阵：
  - `permission/`：以 glob pattern 粒度拦截所有大模型打算调用的危险命令。
  - `question/`：在工具即将实行毁灭性动作前卡住任务流，向人类弹出发问事件等用户确认。
  - `auth/`：对接共享凭证与 Oauth 逻辑。
- **`account/`** 与 **`share/`**
  支持未来企业端版本共享当前会话内容上下文到云端的结构体封装。

---

## 6. 底层工具箱体系 (Platform Utilities)
整个工程大量引入前沿技术规范以统一格式控制：

- **`util/`**
  非常庞大的全局工具方法群包，甚至引入了 Effect.TS 处理复杂状态（如 `effect-http-client.ts`），此外还有 `rpc.ts`, `signal.ts`, `process.ts`, `color.ts` 等约 30 多项基础设施。
- **`effect/`**
  独立的效果与中间件高阶抽象封装层，帮助更好的控制异常副作用流。
- **`bun/`** 与 **`patch/`**
  对运行时底层环境（Bun Runtime 特有 API 的向下兼容）的管理及打补丁系统。
- **`id/`** 与 **`format/`** 与 **`bus/`**
  雪花算法 UUID 自动生成，跨应用的终端高亮格式工具，以及作为局部（Instance内）与全局（`GlobalBus` 桌面端通讯层）同步消息事件总线（Event Bus）。
