# OpenCode 源码深度解析 A03：第 1 步：`SessionPrompt.prompt()` 先把用户输入编译成 Durable User Message

`prompt()` 本身并不直接进行模型推理。它的职责是把用户输入标准化成一条已经落盘的 user message，并把后续 `loop()` 所需的上下文约束提前写进去。这是整条执行链的起点。

## 一、代码坐标

| 主题 | 文件与代码行 | 细节 |
| --- | --- | --- |
| `PromptInput` schema | `packages/opencode/src/session/prompt.ts:95-160` | 定义 session、model、agent、format、parts 等输入契约。 |
| `prompt()` 主入口 | `packages/opencode/src/session/prompt.ts:162-188` | cleanup、createUserMessage、touch、兼容旧 `tools` 参数、进入 loop。 |
| `resolvePromptParts()` | `packages/opencode/src/session/prompt.ts:191-240` | 把 `@file` / `@dir` / `@agent` 展开成标准 parts。 |
| `createUserMessage()` | `packages/opencode/src/session/prompt.ts:966-1355` | 生成 user message info，展开 file/agent/resource parts，最后落盘。 |
| MCP resource 分支 | `packages/opencode/src/session/prompt.ts:1000-1067` | `part.source.type === "resource"` 时直接调用 `MCP.readResource()`。 |
| 本地 file/data URL 分支 | `packages/opencode/src/session/prompt.ts:1068-1269` | 文本文件走 ReadTool，目录走 list/read，二进制走 base64 file part。 |
| `@agent` 转译 | `packages/opencode/src/session/prompt.ts:1272-1294` | 追加 agent part，再补一段 synthetic text 引导 task tool。 |
| `insertReminders()` | `packages/opencode/src/session/prompt.ts:1358-1495` | build/plan 切换、计划文件路径提示、系统 reminder 注入。 |

## 二、`prompt()` 的真实顺序

`packages/opencode/src/session/prompt.ts:162-188` 的执行顺序非常固定：

1. `163-164` 先 `Session.get()` 再 `SessionRevert.cleanup(session)`，把上一次 revert 残留清干净。
2. `166` 调 `createUserMessage(input)`，这里已经会把 user message 和全部 parts 写进数据库。
3. `167` 调 `Session.touch(sessionID)` 更新 session 活跃时间。
4. `171-182` 把 `tools` 布尔配置兼容成 permission rules，并写回 session。
5. `184-186` 如果 `noReply === true`，直接返回刚写好的 user message。
6. `188` 否则进入 `loop({ sessionID })`。

所以 `prompt()` 的职责不是“发请求给模型”，而是“把一轮输入编译成 durable state，再启动调度器”。

## 三、`createUserMessage()` 真正做了哪些编译

### 1. 先确定 message info，再展开 parts

`packages/opencode/src/session/prompt.ts:966-989` 先生成 user message info，包括：

- `id`
- `sessionID`
- `agent`
- `model`
- `system`
- `format`
- `variant`

这一步先固定消息头，后面的 part 扩展都要挂到这个 `messageID` 上。

### 2. `file` part 不是简单透传

`packages/opencode/src/session/prompt.ts:998-1269` 对 `file` part 有三条完全不同的路径：

- `1000-1067`：MCP resource，先读取资源内容，再塞入 synthetic text 和记账 file part。
- `1068-1210`：`file:` + `text/plain`，会调用 `ReadTool` 真读文件，必要时根据 URL range 和 LSP symbol 扩展行范围，核心在 `1113-1167`。
- `1213-1247`：目录路径会转成目录读取结果。
- `1249-1268`：非文本文件会读字节并改写成 `data:${mime};base64,...` 的 file part。

这也是为什么 OpenCode 的“附件”不是裸引用，而是会在消息写入前主动补齐可供模型消费的上下文。

### 3. `@agent` 不是立即启动子任务

`packages/opencode/src/session/prompt.ts:1272-1294` 遇到 `agent` part 时，并不会直接执行 subagent。它会：

- 保留一个 `type: "agent"` part。
- 再追加一段 synthetic text，明确要求“基于上面的消息和上下文，生成 prompt 并调用 task tool”。

真正的 subtask 调度发生在 A04 的 `loop()` 里，不在 `createUserMessage()`。

## 四、`insertReminders()` 是写到消息里的，不是只在内存里拼接

`packages/opencode/src/session/prompt.ts:1358-1495` 有两套逻辑：

- `1362-1385`：实验 plan mode 关闭时，只在最后一个 user message 上追加 `PROMPT_PLAN` 或 `BUILD_SWITCH` synthetic text part。
- `1391-1407`：从 `plan -> build` 切换时，如果计划文件存在，会直接 `Session.updatePart()` 把 reminder 写进当前 user message。
- `1411-1493`：进入 plan mode 时，会把整段 `<system-reminder>...</system-reminder>` 写成一个 durable text part，其中明确写死 plan 文件路径、只允许编辑 plan 文件、以及 agent 工作流。

也就是说，plan/build 切换不是一次“临时 prompt 拼接”，而是对 durable history 的显式修改。

## 五、结论

1. `prompt()` 先把 user message 写进数据库，再进入 `loop()`；核心坐标在 `packages/opencode/src/session/prompt.ts:162-188`。
2. `createUserMessage()` 会主动读取文本文件、目录和 MCP resource，而不是把路径原样交给模型；核心坐标在 `packages/opencode/src/session/prompt.ts:998-1269`。
3. plan/build reminder 很多情况下会直接通过 `Session.updatePart()` 落成 synthetic text part，因此它们是 durable state，不是临时内存注入。
