# OpenCode `src/` 源码架构全景解析

> 本文基于 `opencode` `v1.3.2`（tag `v1.3.2`，commit `0dcdf5f529dced23d8452c9aa5f166abb24d8f7c`）源码校对
> 本文讨论的目录范围是 `packages/opencode/src`。

---

## 1. 先看清 `src/` 的真实边界

在 `v1.3.2` 中，`packages/opencode/src` 下有 **39 个一级目录**，外加一个根入口文件 `index.ts`。这说明 `packages/opencode` 不是“一个 CLI 命令脚本”，而是一套完整的本地 agent runtime。

39 个一级目录如下：

```text
account
acp
agent
auth
bun
bus
cli
command
config
control-plane
effect
env
file
filesystem
flag
format
global
id
ide
installation
lsp
mcp
patch
permission
plugin
project
provider
pty
question
server
session
share
shell
skill
snapshot
storage
tool
util
worktree
```

如果只记一个结论，那就是：**真正驱动 agent 的核心只有 `session`，其他目录要么在给它喂上下文，要么给它提供宿主、工具、存储和对外接口。**

---

## 2. 入口与宿主适配层

这层解决“谁来调用 runtime”。

| 目录/文件 | 作用 |
| --- | --- |
| `index.ts` | 进程级入口。注册 `run`、`serve`、`web`、`attach`、`mcp`、`acp`、`debug` 等命令，并在启动前做日志初始化与 JSON -> SQLite 迁移。 |
| `cli/` | 所有命令实现与 TUI 宿主。默认 `$0 [project]` 是 TUI；`run` 是一次性 CLI；`serve`/`web` 启动 HTTP server；`attach` 接远端 server。 |
| `acp/` | Agent Client Protocol 适配层。把内部 session/runtime 变成 ACP 语义。 |
| `server/` | Hono HTTP 网关。负责认证、CORS、实例绑定、SSE 与 API 路由。 |
| `control-plane/` | workspace 级别的请求路由与隔离。 |
| `installation/` | 版本、安装方式、升级等环境信息。 |

这里最重要的边界是：

1. `cli/` 和桌面壳只是入口。
2. `server/` 是 transport 边界。
3. 真正的 agent 执行仍然要下沉到 `session/`。

---

## 3. Session Runtime 核心层

这层解决“消息怎样变成 durable history，并被 loop 一轮轮消费”。

| 目录 | 作用 |
| --- | --- |
| `session/` | 绝对核心。包含 `prompt.ts`、`processor.ts`、`llm.ts`、`message-v2.ts`、`compaction.ts`、`retry.ts`、`revert.ts`、`summary.ts` 等。 |
| `agent/` | agent 定义与默认权限模板。`build`、`plan`、`general`、`explore`、`compaction`、`title`、`summary` 都在这里定义。 |
| `project/` | 当前目录、worktree、project 识别与实例化。 |
| `snapshot/` | 文件系统快照、patch 与 diff。 |
| `worktree/` | 工作树与 git 相关视图控制。 |
| `bus/` | runtime 事件总线，既服务 session，也服务 SSE 投影。 |

从执行链路看，真正的主干是：

1. `SessionPrompt.prompt()` 先把 user input durable 化。
2. `SessionPrompt.loop()` 每轮从 history 回放状态并决定分支。
3. `SessionProcessor.process()` 消费单轮模型流。
4. `MessageV2.toModelMessages()` 负责把 durable history 投影成模型消息。

所以 `session/` 不是普通的聊天记录封装，而是整个 runtime 的状态机。

---

## 4. 工具、文件与执行层

这层解决“模型能做什么事，以及如何安全地做”。

| 目录 | 作用 |
| --- | --- |
| `tool/` | 模型可见的工具总表。包括 `bash`、`read`、`edit`、`write`、`glob`、`grep`、`codesearch`、`task`、`todo`、`webfetch`、`websearch` 等。 |
| `skill/` | 技能发现与加载。 |
| `shell/` | 命令执行包装。 |
| `pty/` | 伪终端能力。 |
| `file/` | 文件读取、截断、ripgrep 等更贴近“内容读取”的封装。 |
| `filesystem/` | 更底层的文件系统能力，如 ignore、watcher、保护规则等。 |
| `lsp/` | 语言服务器集成。 |
| `mcp/` | MCP client/server、资源、工具与 OAuth 支持。 |

这一层的关键设计有两个：

1. `tool/` 是模型能力边界，不是 UI 功能按钮集合。
2. `task` 工具并不会新起一套执行器，而是新建 child session 后再次进入 `SessionPrompt.prompt()`。

---

## 5. 模型与外部协议层

这层解决“向哪个模型发请求，以及怎样把 provider 差异抹平”。

| 目录 | 作用 |
| --- | --- |
| `provider/` | provider 注册、鉴权、模型发现、默认模型、language model 适配。 |
| `auth/` | provider 凭据与 OAuth 信息。 |
| `plugin/` | system prompt、headers、messages、tool execution 等环节的 hook。 |
| `permission/` | 工具和敏感动作的规则评估。 |
| `question/` | 需要澄清时的人机交互阻塞点。 |
| `share/` | session 分享相关能力。 |
| `account/` | 账户相关状态。 |

`v1.3.2` 的一个鲜明特征是：provider 差异不会在上层乱飞，而是尽量收敛到 `provider/`、`provider/transform`、`session/llm.ts` 这几个点里。

---

## 6. 存储与基础设施层

这层解决“状态存在哪、如何发布事件、怎样跨实例隔离”。

| 目录 | 作用 |
| --- | --- |
| `storage/` | SQLite/Drizzle 与 JSON storage。`Database.use()`、`Database.effect()` 是一致性关键点。 |
| `server/` | 对外 API 与 SSE 投影。 |
| `global/` | 应用级路径、全局状态目录等。 |
| `config/` | 配置读取、合并与 schema。 |
| `env/` | 运行时环境变量接入。 |
| `flag/` | feature flag 与环境开关。 |
| `format/` | 格式化器状态与展示。 |
| `id/` | 各类 ID 生成。 |

这一层最值得记住的是：**OpenCode 不是“先在内存里跑，再顺手写库”，而是从一开始就把 durable storage 和 event bus 当成 runtime 组成部分。**

---

## 7. 平台与通用支撑层

剩余目录更多是在提供“运行时地基”。

| 目录 | 作用 |
| --- | --- |
| `util/` | 大量通用函数与运行时辅助。 |
| `effect/` | Effect 相关封装。 |
| `bun/` | Bun 特有行为适配。 |
| `patch/` | 补丁相关能力。 |
| `ide/` | IDE/编辑器侧集成辅助。 |
| `command/` | 命令模板与命令元信息。 |

这些目录不是主执行链，但很多“看似分散”的能力最终都会回到这里复用底层组件。

---

## 8. 读 `src/` 时应抓住的 4 个判断

1. `session/` 才是 runtime 本体，`server/` 和 `cli/` 都只是宿主边界。
2. `tool/` 是模型动作表，`permission/` 和 `question/` 是动作闸门。
3. `provider/` 负责晚绑定，`session/llm.ts` 负责真正发起模型流。
4. `storage/` + `bus/` 不是配角，它们决定了 session 为什么能 durable、可恢复、可投影。
