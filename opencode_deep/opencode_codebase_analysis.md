# OpenCode 代码库架构全景解析

> 本文基于 `opencode` `v1.3.2`（tag `v1.3.2`，commit `0dcdf5f529dced23d8452c9aa5f166abb24d8f7c`）源码校对。
> 本文不按目录百科来讲，而是顺着默认 `bun dev` / `opencode` 主线解释：仓库根脚本怎样把你送进 `packages/opencode`，再由哪些目录真正驱动 agent runtime。

---

## 1. 先把默认启动链钉在代码上

如果只关心“默认启动时到底经过哪些文件”，链路其实已经被源码写死：

```text
opencode/package.json
  -> packages/opencode/src/index.ts
  -> cli/cmd/tui/thread.ts
  -> cli/cmd/tui/worker.ts
  -> server/server.ts
  -> server/routes/session.ts
  -> session/prompt.ts
  -> session/processor.ts
  -> session/llm.ts
  -> session/index.ts / message-v2.ts
```

也就是说，这篇真正要回答的不是“目录里有什么”，而是：

1. 哪些目录在默认启动时一定会命中。
2. 哪些目录只是宿主、外围产品面或共享支撑。
3. `packages/opencode/src` 里哪些子目录属于主链，哪些只是给主链提供条件。

---

## 2. 仓库根目录怎样把你送到 `packages/opencode`

### 2.1 `opencode/package.json` 已经写死了默认启动入口

`opencode/package.json:8-18` 直接说明：

1. `dev` 是 `bun run --cwd packages/opencode --conditions=browser src/index.ts`。
2. `dev:desktop` 进入 `packages/desktop`。
3. `dev:web` 进入 `packages/app`。
4. `dev:console` 进入 `packages/console/app`。
5. `typecheck` 走 `bun turbo typecheck`，服务整个 workspace。

这意味着根目录脚本层的职责非常明确：

1. 选择要启动哪个产品面或宿主。
2. 把默认本地 agent 启动送进 `packages/opencode`。
3. 自己不承担 session/runtime 逻辑。

### 2.2 根目录里的“工作区信息”和“运行时信息”要分开看

同一个 `package.json` 里同时存在两类信号：

1. 工作区信号：
   - `packageManager: bun@1.3.11`
   - `workspaces.packages`
   - `catalog` / `patchedDependencies`
2. 运行时入口信号：
   - `scripts.dev`
   - `scripts.dev:desktop`
   - `scripts.dev:web`
   - `scripts.dev:console`

前者回答“这个 monorepo 怎么组织”，后者回答“默认启动到底去哪”。分析默认 agent 主链时，第二类信息才是关键。

---

## 3. `packages/` 应该按“离默认主链多近”来分层

`opencode/packages` 当前一共 19 个一级目录：

```text
app
console
containers
desktop
desktop-electron
docs
enterprise
extensions
function
identity
opencode
plugin
script
sdk
slack
storybook
ui
util
web
```

如果只做静态枚举，很容易看不出 runtime 重心。更有效的分法是按“默认启动会不会直接命中”来分。

### 3.1 直接命中默认主链的包

| 目录 | 为什么重要 |
| --- | --- |
| `packages/opencode` | 默认 `dev` 直接进入这里；CLI、TUI、Server、Session、Tool、Provider、Storage 都在这里。 |
| `packages/util` | `packages/opencode` 大量底层辅助依赖这里，但它本身不是主入口。 |
| `packages/plugin` | plugin API 和 runtime hook 汇合点，虽然不是第一跳，但离主链非常近。 |
| `packages/sdk` | TUI/桌面/UI 消费 server contract 时会用到，但它是消费层，不是 runtime 本体。 |

这里最该记住的是：**真正执行 agent 的只有 `packages/opencode`；其余几个只是紧贴主链的配套层。**

### 3.2 默认不会直接命中，但会承载同一套 runtime 的宿主

| 目录 | 作用 |
| --- | --- |
| `packages/app` | 通用前端壳，消费同一套 SDK/server contract。 |
| `packages/desktop` | Tauri sidecar 宿主。 |
| `packages/desktop-electron` | Electron sidecar 宿主。 |
| `packages/web` | 公开网站/文档站点，不等于本地 `opencode web` 里真正跑的 runtime UI。 |
| `packages/storybook` | UI 沙盒。 |
| `packages/enterprise` | 另一条产品面前端。 |

这些目录离 runtime 很近，但它们做的是“承载”和“消费”，不是“执行 loop”。

### 3.3 控制台、云侧和外部集成

| 目录 | 作用 |
| --- | --- |
| `packages/console/*` | 控制台产品面及其共享逻辑。 |
| `packages/function` | 通用服务端/函数能力。 |
| `packages/identity` | 身份相关。 |
| `packages/slack` | Slack 集成。 |
| `packages/extensions` | 编辑器扩展等外部集成。 |

这批代码属于更大的产品生态，但不在默认本地 agent 主链上。

### 3.4 内容、脚本和工程支撑

| 目录 | 作用 |
| --- | --- |
| `packages/docs` | 文档内容。 |
| `packages/ui` | 共享 UI 组件。 |
| `packages/script` | 工作区脚本。 |
| `packages/containers` | 构建/发布容器定义。 |

所以整个 monorepo 真正的阅读重心非常集中：**默认启动先看 `packages/opencode`，再按需要辐射到宿主或扩展层。**

---

## 4. 从 `packages/opencode` 往下，默认启动到底怎样点火

### 4.1 `src/index.ts` 先点亮程序自身

`packages/opencode/src/index.ts:67-147` 在命令注册前先做了三件事：

1. `Log.init(...)` 初始化日志。
2. 写入 `AGENT`、`OPENCODE`、`OPENCODE_PID` 这些环境变量。
3. 若 SQLite 还没建好，就跑 `JsonMigration.run(...)`。

然后才注册命令；其中默认 `$0 [project]` 命中的就是 `TuiThreadCommand`。

所以 `src/index.ts` 的第一职责不是跑 agent，而是把“进程级运行条件”准备好。

### 4.2 `thread.ts` 决定默认宿主怎样访问 runtime

`cli/cmd/tui/thread.ts:102-225` 的 handler 顺序很稳定：

1. 解析 `project` 并 `chdir` 到目标目录。
2. 启动 `worker.ts`。
3. 根据是否开 `--port` / `--hostname` / `--mdns`，决定 transport 是：
   - worker 内嵌 `fetch + events`
   - 真实 HTTP server
4. 再把 transport 交给 TUI UI。

这一步最值得记住的是：默认 TUI 不是直接碰 `SessionPrompt.prompt()`，而是先把“如何调用 server contract”这件事做出来。

### 4.3 `worker.ts` 把同一套 Hono app 暴露给 UI

`cli/cmd/tui/worker.ts:47-154` 干的事情比名字更关键：

1. `startEventStream(...)` 用 SDK 订阅 `/event`。
2. SDK 的 `fetch` 被重定向到 `Server.Default().fetch(request)`。
3. RPC 暴露 `fetch()`、`server()`、`setWorkspace()`、`reload()`、`shutdown()`。

所以默认本地 TUI 访问 runtime 的方式，本质上还是统一的 HTTP/SSE contract，只是 transport 被本地化了。

### 4.4 `server.ts` 才把请求变成“某个项目里的 runtime 调用”

`server/server.ts:55-253` 把几个关键边界写死了：

1. `onError` 统一收口。
2. basic auth、logging、CORS 先走。
3. `/global` 和 `/auth/:providerID` 这类全局接口先挂上。
4. 然后通过 `WorkspaceContext.provide(...)` 和 `Instance.provide(...)` 绑定当前 `workspaceID`、`directory`、`project`。
5. 最后才挂 `/project`、`/session`、`/provider`、`/event`、`/mcp` 等业务路由。

这一步之后，请求才真正获得“当前工程上下文”。

### 4.5 `/session` 路由把请求送进 session runtime

`server/routes/session.ts:783-821` 的 `POST /:sessionID/message` 并不自己处理 AI 流，而是：

1. 校验 path param 和 body。
2. 调 `SessionPrompt.prompt({ ...body, sessionID })`。
3. 把最终 assistant message JSON 写回响应。

这就把默认启动链从“宿主/传输层”切进了真正的 runtime 主骨架。

---

## 5. `packages/opencode/src` 的 39 个一级目录，应该按执行时机来理解

`packages/opencode/src` 当前有 39 个一级目录。它们不该按字母看，而该按“在默认主链的哪一段被命中”来分。

### 5.1 进程启动和宿主适配层

| 目录 | 在主链里的位置 |
| --- | --- |
| `cli` | 默认命令、`run`、`attach`、`serve`、`web`、TUI 宿主。 |
| `server` | Hono app、API 路由、SSE 暴露面。 |
| `acp` | ACP 适配层。 |
| `control-plane` | workspace 路由和远端转发。 |
| `installation` | 版本和安装态判断。 |
| `global` | 全局目录和路径。 |

这层回答“谁在调用 runtime，以及通过什么协议调用”。

### 5.2 项目 runtime 装配层

| 目录 | 在主链里的位置 |
| --- | --- |
| `project` | `Instance`、`Project.fromDirectory()`、bootstrap。 |
| `config` | 配置叠加、`.opencode` 装载。 |
| `plugin` | runtime hook 初始化。 |
| `format` | 格式化器。 |
| `lsp` | LSP 状态与 client。 |
| `snapshot` | patch / diff / worktree 快照。 |
| `worktree` | sandbox / worktree 管理。 |

这层回答“当前目录怎样变成一份可运行的 project/runtime”。

### 5.3 session 主骨架层

| 目录 | 在主链里的位置 |
| --- | --- |
| `session` | `prompt`、`loop`、`processor`、`llm`、`compaction`、`retry`、`revert`、`summary`。 |
| `agent` | agent 模板、默认权限、内建隐藏 agent。 |
| `permission` | ask / deny / allow 规则评估。 |
| `question` | 交互式澄清阻塞。 |
| `bus` | session/runtime 事件发布。 |

这一层才是“谁在真正驱动 agent”。

### 5.4 工具和外部动作层

| 目录 | 在主链里的位置 |
| --- | --- |
| `tool` | 模型可调用工具总表。 |
| `file` | 文件读取、tree、ripgrep、truncate。 |
| `filesystem` | ignore、watch、路径处理。 |
| `shell` | shell 执行包装。 |
| `pty` | 交互式终端能力。 |
| `mcp` | MCP tools/resources/prompts/connectors。 |
| `skill` | 技能发现与可用性。 |
| `command` | slash command / prompt template。 |

这层回答“模型到底能对外部世界做哪些动作”。

### 5.5 provider 与兼容层

| 目录 | 在主链里的位置 |
| --- | --- |
| `provider` | provider/model 注册和兼容。 |
| `auth` | provider 鉴权。 |
| `share` | session 分享。 |
| `account` | 账户相关。 |

这层主要在 `LLM.stream()` 附近被真正命中。

### 5.6 durable storage 与公共支撑

| 目录 | 在主链里的位置 |
| --- | --- |
| `storage` | SQLite / JSON storage / effect 队列。 |
| `util` | 通用工具。 |
| `effect` | Effect 封装。 |
| `env` | 环境变量接入。 |
| `flag` | feature flag。 |
| `id` | ID 生成。 |
| `bun`、`patch`、`ide` | Bun 适配、补丁、IDE 支撑。 |

这层不直接“决定下一轮”，但为整个 runtime 提供地基。

---

## 6. 为什么说真正驱动 agent 的核心是 `session/`

只要把 `server -> session` 这段拉通，判断会很明确：

1. `server` 负责把请求绑定到正确的 `Instance`。
2. `session/prompt.ts` 负责把输入编译成 durable user message。
3. `session/prompt.ts` 里的 `loop()` 决定这轮是不是 subtask、compaction，还是 normal round。
4. `session/processor.ts` 负责消费一次 `LLM.stream()` 事件流。
5. `session/index.ts` / `message-v2.ts` 负责把状态写回并重放。

这说明：

1. `cli/` 不是执行器，它是入口和宿主适配层。
2. `server/` 不是执行器，它是 runtime 边界层。
3. 真正推进 agent 状态机的核心代码都在 `session/`。

所以如果目标是理解“agent 为什么会这么行为”，阅读重心一定要尽快从 `cli/` / `server/` 收束到 `session/`。

---

## 7. 最有效的阅读顺序

如果希望最快摸清代码库，推荐按下面顺序读，而不是在目录树里随机跳：

1. `opencode/package.json`
   先确认默认启动到底会命中哪个包。
2. `packages/opencode/src/index.ts`
   看进程启动和命令注册。
3. `packages/opencode/src/cli/cmd/tui/thread.ts`
   看默认宿主怎样启动 worker 和 transport。
4. `packages/opencode/src/cli/cmd/tui/worker.ts`
   看 server contract 怎样被本地化暴露给 UI。
5. `packages/opencode/src/server/server.ts`
   看请求怎样绑定到 `WorkspaceContext` / `Instance`。
6. `packages/opencode/src/session/`
   重点读 `prompt.ts`、`processor.ts`、`llm.ts`、`message-v2.ts`。
7. 再回看 `tool/`、`provider/`、`storage/`、`plugin/`、`config/`
   理解主骨架依赖的外部动作、兼容层和基础设施。

这条顺序的核心逻辑是：先抓执行骨架，再回头看配套系统。

---

## 8. 把整篇压成一句话

如果只保留一句结论，那应该是：

> OpenCode 代码库虽然是一个大 monorepo，但默认本地 agent 主线非常集中：根脚本把你送进 `packages/opencode`，`index.ts -> thread.ts -> worker.ts -> server.ts` 负责把宿主和请求边界搭起来，真正驱动 agent 状态推进的核心始终是 `session/`。
