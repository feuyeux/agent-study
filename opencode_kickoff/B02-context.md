# OpenCode 深度专题 B02：上下文工程，从输入重写到模型消息投影

OpenCode 当前实现里，“上下文工程”不是在 prompt 前拼几段字符串，而是贯穿输入编译、指令发现、工具权限裁剪、历史投影和 provider 兼容的一整条链。B02 的任务就是把这条链拆清楚。

---

## 1. 上下文源头不是一层，而是多层叠加

当前代码里，送进模型的上下文主要来自 6 个来源：

| 来源 | 代码坐标 | 在哪一层进入 |
| --- | --- | --- |
| 用户原始输入 | `session/prompt.ts:998-1305` | `createUserMessage()` 编译 part |
| 文件/MCP/agent 附件展开 | `prompt.ts:1000-1294` | 仍属于 user message 编译阶段 |
| provider/agent 基础提示 | `session/system.ts:18-26`、`session/llm.ts:70-82` | `LLM.stream()` 组 system |
| 环境/技能/指令文件 | `system.ts:28-67`、`instruction.ts:72-142` | `prompt.ts:655-665` |
| 运行时提醒 | `prompt.ts:1358-1496`、`634-650` | `insertReminders()` 与 queued user reminder |
| durable history 投影 | `message-v2.ts:559-792` | `toModelMessages()` |

因此 OpenCode 的上下文不是“message string + system string”，而是一份 runtime 编译产物。

---

## 2. 输入侧：用户输入会先被改写成可持久化上下文

### 2.1 文件不会原样保留，通常会被展开成 synthetic text

`createUserMessage()` 对 file part 的处理已经在 A03 讲过，这里只强调它对上下文工程的意义：

1. 文本文件会主动跑 `ReadTool`，把内容或片段变成 synthetic text。
2. 目录会被列出条目再写成 synthetic text。
3. MCP resource 会先被读取再写成 synthetic text。
4. 二进制文件和图片/PDF 会保留为 file attachment。

所以 durable history 里记录的不是“用户附了个路径”，而是“系统如何理解这个附件”。

### 2.2 `@agent` 也会被改写成上下文提示

`1272-1294` 不直接执行子任务，而是写入一条 synthetic text，明确告诉模型：

1. 上面那段上下文要被拿去生成 subtask prompt
2. 应调用 `task` 工具
3. subagent 类型是什么

这本质上是把 orchestration hint 编译进上下文。

---

## 3. 指令系统不是只有根目录 `AGENTS.md`

`InstructionPrompt` 当前分成三种读取方式。

### 3.1 system 级指令

`instruction.ts:72-142` 的 `systemPaths()` / `system()` 会搜集：

1. 工程内向上查找的 `AGENTS.md` / `CLAUDE.md` / `CONTEXT.md`
2. 全局配置目录里的 `AGENTS.md`
3. `~/.claude/CLAUDE.md`
4. `config.instructions` 里声明的额外本地文件和 URL

这些内容会在每轮 `prompt.ts:655-665` 拼进 system prompt。

### 3.2 read tool 触发的局部指令发现

`InstructionPrompt.resolve()` 在 `168-190` 会围绕某个被读取的文件路径，向上查找尚未加载、也未被当前 message claim 过的 instruction 文件。

它的调用点在 `tool/read.ts:118`。因此当 agent 读取一个深层文件时，OpenCode 还能补发现该子目录局部的 `AGENTS.md`/`CLAUDE.md`。

### 3.3 loaded/claim 机制避免重复灌上下文

`InstructionPrompt.loaded(messages)` 会从历史里的 `read` 工具结果 metadata 中提取已经加载过的 instruction 路径；`claim/clear` 用于避免同一 message 内重复注入。

这说明当前实现不是“发现一个 instruction 就无脑重复塞”，而是维护了一套轻量去重策略。

---

## 4. system prompt 的真实组装顺序

普通推理分支里，`prompt.ts:655-665` 先准备好：

1. 环境 prompt
2. 技能说明
3. 指令文件内容

随后 `llm.ts:70-82` 再做最后组合：

1. `agent.prompt` 或 provider prompt
2. 上面这批运行时 system 片段
3. `user.system`

这个顺序意味着：

1. provider/agent 提示是底座
2. 环境和工程规则是中层
3. 用户显式 system 是顶层补丁

所以如果看到某条 system prompt 很长，不要以为它来自单个模板文件；很可能是 runtime 多层合并的结果。

---

## 5. 运行时提醒会在进入模型前再改写一次历史

`insertReminders()` 和普通推理分支的 queued message 包装，是当前上下文工程里非常容易漏掉的两块。

### 5.1 plan/build reminder

`prompt.ts:1358-1496` 会根据当前 agent、上轮 agent 和实验 flag：

1. 给 `plan` agent 注入 plan mode 限制说明
2. 从 `plan` 切回 `build` 时插入 build-switch 提醒
3. 在实验 plan mode 下把计划文件路径和工作流规则写进 synthetic text

这意味着 plan/build 切换并不是 UI 状态，而是被 durable/synthetic context 明确告知模型。

### 5.2 queued user message reminder

`634-650` 会把上轮 assistant 之后插入的新 user 文本临时包成 `<system-reminder>`，提醒模型优先处理后来的消息。

这一步不回写数据库，但会影响本轮模型感知到的对话顺序和优先级。

---

## 6. Durable history 投影成模型消息时还会再“翻译一遍”

`MessageV2.toModelMessages()` 是上下文工程的另一半，负责把 durable history 转成 AI SDK `ModelMessage[]`。

### 6.1 user 侧投影

当前规则是：

1. `text` -> user text part
2. 非文本 file -> user file part
3. `compaction` -> `"What did we do so far?"`
4. `subtask` -> `"The following tool was executed by the user"`

因此模型看到的 user history，不是原始 `MessageV2.Part` 字段，而是被语义翻译过的投影。

### 6.2 assistant 侧投影

assistant part 会被翻译成：

1. `text`
2. `reasoning`
3. `tool-call` / `tool-result` / `tool-error`
4. `step-start`

未完成的 tool call 还会被补成 `"Tool execution was interrupted"` 的 error result，避免 provider 看到悬挂的 tool_use 块。

### 6.3 media-in-tool-result 兼容

若 provider 不支持 tool result 里带 media，`703-778` 会把图片/PDF 附件抽出来，再额外注入一条 user file message。

这不是 UI 行为，而是模型上下文兼容层。

---

## 7. 工具集合也是上下文的一部分

OpenCode 当前的工具上下文有两层裁剪：

1. `SessionPrompt.resolveTools()` 先构造本地工具、插件工具、MCP 工具，并挂上 metadata/permission/plugin hooks。
2. `LLM.resolveTools()` 再根据 agent/session/user 的 permission 规则删掉禁用工具。

因此模型看到的 tool set，不是静态注册表快照，而是“当前轮次 + 当前 agent + 当前权限上下文”下的最终结果。

这也是为什么 OpenCode 的上下文工程不能只看 message；tool set 本身就是上下文。

---

## 8. B02 的核心结论

当前实现里，“上下文工程”至少包含三层编译：

1. **输入编译**：把原始输入、附件、agent 指令写成 durable user message/parts。
2. **system 编译**：把 provider prompt、环境、技能、AGENTS/CLAUDE、运行时提醒拼成最终 system。
3. **历史投影**：把 durable history 再翻译成 provider 能接受的 `ModelMessage[]` 和 tool set。

所以 OpenCode 的 prompt engineering 不是“写一份 system prompt”，而是“设计一整条上下文编译管线”。
