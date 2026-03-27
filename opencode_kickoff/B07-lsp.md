# OpenCode 深度专题 B07：LSP，代码理解、符号定位与诊断反馈是怎样接进主链路的

> 本文基于 `opencode` `v1.3.2`（tag `v1.3.2`，commit `0dcdf5f529dced23d8452c9aa5f166abb24d8f7c`）源码校对

很多 agent 项目把 LSP 讲成“编辑器增强”或“一个可选工具”。OpenCode 当前实现更接近另一种思路：LSP 是一层**按文件类型懒启动、按工程根分片、为 runtime 提供代码理解与诊断回路的基础设施**。它既不是主执行器，也不是纯 UI 附件，但会直接影响 read、prompt 编译、编辑后纠错和状态面板。

---

## 1. 当前 LSP 架构不是一个点，而是五层

| 层 | 代码坐标 | 角色 |
| --- | --- | --- |
| 配置层 | `packages/opencode/src/config/config.ts:1152-1187` | 定义 `lsp` 配置 schema，允许关闭、覆写内建 server、注册自定义 server。 |
| server 注册层 | `packages/opencode/src/lsp/server.ts:35-53`、`95+` | 声明每种语言 server 的扩展名匹配、root 发现和 spawn 方式。 |
| runtime 调度层 | `packages/opencode/src/lsp/index.ts:80-300` | 维护 `servers/clients/broken/spawning` 状态，按文件懒启动 client。 |
| JSON-RPC client 层 | `packages/opencode/src/lsp/client.ts:43-245` | 跟具体 LSP 进程做 stdio 通信，接收 diagnostics，推送 didOpen/didChange。 |
| 消费层 | `tool/read.ts:215-217`、`tool/write.ts:54-82`、`tool/edit.ts:146-160`、`tool/apply_patch.ts:234-269`、`session/prompt.ts:1148-1167` | 把 LSP 能力接回主链路。 |

所以 OpenCode 的 LSP 不是“给模型多开了个查询接口”，而是“在文件读写循环旁边挂了一层代码语义反馈”。

---

## 2. 启动时只初始化能力，不急着起所有语言服务器

`InstanceBootstrap()` 很早就会调用 `LSP.init()`，见 `packages/opencode/src/project/bootstrap.ts:15-22`。但这里做的不是把所有 LSP server 全部拉起，而只是把状态容器准备好。

`packages/opencode/src/lsp/index.ts:80-140` 当前初始化逻辑是：

1. 先读 `Config.get()`。
2. 若 `cfg.lsp === false`，直接全局禁用。
3. 把 `LSPServer` 里的内建 server 注册进 `servers`。
4. 应用实验 flag 和用户配置覆写。
5. 建立 `broken`、`clients`、`spawning` 三组运行态。

这里最关键的结论是：**LSP 是 eager init、lazy spawn。**

也就是说，runtime 会先知道“有哪些 server 可用”，但真正启动某个 LSP 进程，要等某个文件真的触发了它。

---

## 3. 配置模型不是只支持开关，还支持覆写和自定义

`packages/opencode/src/config/config.ts:1152-1187` 里的 `lsp` 配置支持三种模式：

1. `false`：全局禁用全部 LSP。
2. 内建 server 覆写：例如改 `command`、`env`、`initialization`，或设 `disabled: true`。
3. 自定义 server：只要提供 `command`，并给非内建 server 补 `extensions`。

这一段 schema 还显式做了校验：

1. 如果名字命中内建 `LSPServer`，可以不写 `extensions`。
2. 如果是自定义 server，`extensions` 必填。

说明 OpenCode 把 LSP 看成“可配置 runtime 组件”，不是写死在代码里的硬编码列表。

另外还有两组很关键的运行时开关，定义在 `packages/opencode/src/flag/flag.ts:26`、`63-64`：

1. `OPENCODE_DISABLE_LSP_DOWNLOAD`：禁止自动下载缺失的语言服务器。
2. `OPENCODE_EXPERIMENTAL_LSP_TY`：启用 `ty`，并在 `packages/opencode/src/lsp/index.ts:65-77` 里把 `pyright` 挤掉。

这说明 Python LSP 在当前版本里其实是一个可切换的实现位，而不是固定死绑到 `pyright`。

---

## 4. 一份文件不一定只对应一个 LSP server

这点非常关键，也是最容易被忽略的一点。

`packages/opencode/src/lsp/index.ts:178-261` 的 `getClients(file)` 并不是“找到一个最匹配 server 就结束”，而是：

1. 遍历当前启用的全部 servers。
2. 用扩展名过滤。
3. 调每个 server 自己的 `root(file)` 判断当前文件是否落在它负责的工程根里。
4. 对每个 `(root + serverID)` 去重、复用或懒启动。
5. 把所有匹配 client 全部收集起来。

这意味着对一个前端工程文件，OpenCode 可能同时挂上：

1. `typescript`
2. `eslint`
3. `oxlint`
4. `biome`
5. `vue`（若是 `.vue`）

也就是说，这里不是“一个语言一个 server”，而是“一个文件可以叠多层代码智能与诊断来源”。

`diagnostics()` 也印证了这一点。`packages/opencode/src/lsp/index.ts:291-300` 会把所有已连接 client 的诊断结果聚合到同一个 `Record<string, Diagnostic[]>` 里，而不是只取单一来源。

---

## 5. root 发现是 LSP 能不能工作好的前提

`packages/opencode/src/lsp/server.ts:35-53` 的 `NearestRoot(...)` 是当前 root 发现的公共骨架：从当前文件目录向上找标记文件，必要时支持排除条件，找不到时再退回 `Instance.directory`。

各语言 server 再在这个骨架上编码各自的“工程边界”：

1. `typescript` 用锁文件找 JS/TS 工程根，并显式排除 `deno.json`，见 `lsp/server.ts:95-122`。
2. `gopls` 优先 `go.work`，再退回 `go.mod` / `go.sum`，见 `366-386`。
3. `ty` / `pyright` 围绕 `pyproject.toml`、`requirements.txt`、`pyrightconfig.json` 等 Python 项目标记工作，见 `447-509`、`511-558`。
4. `bash`、`dockerfile` 这种弱工程边界语言，则直接退到 `Instance.directory`，见 `1643-1680`、`1855-1892`。

所以 LSP 在 OpenCode 里不是“按整个 workspace 起一份大进程”，而更像“按文件命中的项目根分仓启动”。

同时，各 server 的 `spawn()` 策略也不完全一样：

1. 有些要求本机已有工具链，例如 `deno`、`gopls`、`dart`、`ocaml-lsp`。
2. 有些会优先找本地 binary，找不到再自动下载或安装，例如 `vue-language-server`、`pyright`、`bash-language-server`、`terraform-ls`。
3. 有些还会把 server-specific `initialization` 一并传给 LSP client。

所以 OpenCode 宣称的“LSP 开箱即用”，本质上是“能本地复用就复用，必要时在运行期补安装”，而不是所有语言都内嵌在二进制里。

---

## 6. 懒启动过程里，OpenCode 还做了失败隔离和并发去重

`packages/opencode/src/lsp/index.ts:183-258` 的调度逻辑有三个很实用的保护：

### 6.1 `broken`

某个 `(root + serverID)` 一旦 spawn 或 initialize 失败，就会进 `broken` 集合，后续不再反复重试。

### 6.2 `spawning`

若同一时刻多个请求都命中了同一个 LSP server/root，对应 promise 会被放进 `spawning` map，其余调用直接等这一个 in-flight 结果，避免重复拉进程。

### 6.3 复用已连接 client

一旦 `s.clients` 里已有同一个 `(root, serverID)`，后续直接复用，而不是重新建连接。

这三点组合起来，说明它不是“每次调用工具就临时起个语言服务器”，而是有明确复用策略的长期运行部件。

---

## 7. `LSPClient` 真正做的是“把文件系统变化翻译成 LSP 事件”

`packages/opencode/src/lsp/client.ts:43-245` 这一层很值得细看。

### 7.1 连接协议就是标准 stdio JSON-RPC

`47-50` 用 `createMessageConnection(...)` 把 child process 的 stdin/stdout 接成 LSP 连接。

### 7.2 初始化会同时发 `initialize` 和配置

`82-134` 会：

1. 发送 `initialize`
2. 带上 `rootUri`、`workspaceFolders`
3. 注入 `initializationOptions`
4. 声明 `didOpen` / `didChange` / `publishDiagnostics` 等能力
5. 初始化后再补一个 `workspace/didChangeConfiguration`

所以 OpenCode 并不是“起个 server 就直接发 query”，而是把自己当作一个相对完整的 LSP client。

### 7.3 `touchFile()` 最终会走 `didOpen` 或 `didChange`

`149-205` 的 `notify.open()` 会先读文件内容，再：

1. 若这个文件第一次进入当前 client，发 `workspace/didChangeWatchedFiles` + `textDocument/didOpen`
2. 若之前已打开过，则发 `workspace/didChangeWatchedFiles` + `textDocument/didChange`

换句话说，OpenCode 的 LSP 视图不是“假定 server 自己监控磁盘”，而是 runtime 主动把文件内容同步给它。

---

## 8. diagnostics 是 OpenCode 接 LSP 的第一公民

从源码看，当前 LSP 接入最核心的产物不是 definition，也不是 hover，而是 diagnostics。

`packages/opencode/src/lsp/client.ts:53-63` 收到 `textDocument/publishDiagnostics` 后会：

1. 把结果写进本地 `Map<path, Diagnostic[]>`
2. 通过 `Bus.publish(Event.Diagnostics, ...)` 广播

`210-237` 的 `waitForDiagnostics()` 又做了两件事：

1. 订阅同路径、同 server 的 diagnostics 事件
2. 做一个 `150ms` debounce，给语义诊断等 follow-up 留窗口

然后 `packages/opencode/src/lsp/index.ts:277-289` 的 `touchFile(file, true)` 会把 `notify.open()` 和 `waitForDiagnostics()` 绑在一起，形成“通知 server + 等诊断回来”的最小闭环。

这条闭环后面直接喂给了编辑类工具。

---

## 9. LSP 真正嵌进主链路的地方，是读写循环

### 9.1 `read` 只预热，不阻塞主流程

`packages/opencode/src/tool/read.ts:215-217` 在读完文件后只做一件事：

```ts
LSP.touchFile(filepath, false)
```

注释也写得很直白：`just warms the lsp client`。

也就是说，OpenCode 当前不会为了“读文件”同步等待 LSP 结果，但会趁机把相关语言 server 热起来，为后续符号查询和诊断做准备。

### 9.2 `write` / `edit` / `apply_patch` 会把 diagnostics 直接反馈给模型

这三类编辑工具在写盘后都会：

1. `LSP.touchFile(..., true)`
2. `LSP.diagnostics()`
3. 把 severity=1 的错误格式化进 tool output

对应位置分别是：

1. `packages/opencode/src/tool/write.ts:54-82`
2. `packages/opencode/src/tool/edit.ts:146-160`
3. `packages/opencode/src/tool/apply_patch.ts:234-269`

这说明 LSP 在 OpenCode 当前最重要的 runtime 价值是：

1. 不是帮模型“理解一切”
2. 而是让模型在编辑后立即看到编译/静态分析报错

也就是把“修改代码”闭成“修改 -> 诊断 -> 再修正”的反馈回路。

---

## 10. 符号能力已经接进 prompt 编译，但用得很克制

LSP 并不是只在 edit 后校验。

`packages/opencode/src/session/prompt.ts:1148-1167` 当前有一个非常典型的用法：当 `file:` part 带了 `start/end` 查询参数，而且某些 server 的 `workspace/symbol` 只返回了退化 range 时，会再调用一次 `LSP.documentSymbol()` 去修正 symbol 的完整区间。

这段代码的含义是：

1. OpenCode 已经承认 `workspace/symbol` 的结果不总是够用。
2. 真正要把“符号附件”稳定地转成文件片段时，还得回到 document 级 symbol 树补精度。

`packages/opencode/src/session/message-v2.ts:153-160` 里也能看到对应的数据结构，`SymbolSource` 会把 `path`、`range`、`name`、`kind` 一并存下来。

因此，LSP 在主链路里的第二个价值是：**帮 prompt 编译阶段把“符号引用”变成更可靠的文件片段。**

---

## 11. 对外暴露面分成“稳定面”和“实验面”

### 11.1 稳定面：状态查询和 UI 刷新

`packages/opencode/src/server/server.ts:458-475` 暴露了 `GET /lsp`，返回 `LSP.status()`。

这里有个很重要的细节：`status()` 只枚举已经连接成功的 client，见 `packages/opencode/src/lsp/index.ts:163-175`。也就是说，它展示的是**当前已激活的 LSP 状态**，不是“配置里声明过的所有 server”。

TUI 侧在 `packages/opencode/src/cli/cmd/tui/context/sync.tsx:343-345` 监听 `lsp.updated` 后，会重新请求一次 `sdk.client.lsp.status()` 刷新状态面板。

### 11.2 实验面：显式 `lsp` 工具

`packages/opencode/src/tool/registry.ts:124-132` 里，`LspTool` 只有在 `OPENCODE_EXPERIMENTAL_LSP_TOOL` 打开时才会注册。

`packages/opencode/src/tool/lsp.ts:23-84` 又说明这个工具是一个独立 permission 面：

1. 调用前必须过 `permission: "lsp"`
2. 要先 `hasClients(file)`
3. 再 `touchFile(file, true)`
4. 然后才允许 definition / references / hover / call hierarchy 等操作

所以 OpenCode 当前的态度很明确：LSP 作为 runtime 底座已经在用，但把它完整开放成模型主动可调用工具，仍然算实验能力。

### 11.3 半开放面：API 已留口，但还没真正放量

`packages/opencode/src/server/routes/file.ts:86-115` 里有个 `/find/symbol` 路由，OpenAPI 描述和 schema 都写好了，但真正逻辑被注释掉，当前直接 `return c.json([])`。

这说明工程已经预留了“把 workspace symbol 搜索纳入公共 API”的位置，但在 `v1.3.2`，这条能力还没有正式对外稳定开放。

---

## 12. B07 的核心结论

OpenCode 当前对 LSP 的使用方式，可以压成四句话：

1. **它是懒启动、按 root 分片、允许多 server 叠加的代码智能层。**
2. **它最重要的现实用途不是 query，而是 diagnostics 反馈回路。**
3. **它已经参与 prompt 编译中的符号定位修正，但仍然是辅助层，不取代 `read` / `grep` / durable history。**
4. **工程内部已经把 LSP 当基础设施来组织，但对模型直接暴露这层能力依然保持克制，只开放了实验面和状态面。**

所以如果要一句话概括 B07：

> 在 OpenCode 里，LSP 不是“外挂工具”，而是围绕文件读写主链路搭起来的一层语义校验与符号补偿基础设施。
