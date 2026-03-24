# OpenCode 深度专题 B02：上下文工程：从输入重写到模型消息投影

在 OpenCode 中，上下文工程跨了四个明确阶段：输入展开、指令文件装载、message 投影、provider 请求装配。

## 一、代码坐标

| 阶段 | 文件与代码行 | 细节 |
| --- | --- | --- |
| 输入 `@` 展开 | `packages/opencode/src/session/prompt.ts:191-240` | `resolvePromptParts()` 把文件、目录、agent mention 编译成 parts。 |
| 用户消息编译 | `packages/opencode/src/session/prompt.ts:966-1355` | `createUserMessage()` 把 file/resource/agent part 变成可持久化消息。 |
| 动态 reminder | `packages/opencode/src/session/prompt.ts:1358-1495` | plan/build 切换、计划文件约束。 |
| 指令文件发现 | `packages/opencode/src/session/instruction.ts:72-141` | 读取 `AGENTS.md`、`CLAUDE.md`、config.instructions。 |
| provider/system prompt | `packages/opencode/src/session/system.ts:17-67` | provider prompt、environment、skills 三段基础上下文。 |
| 模型消息投影 | `packages/opencode/src/session/message-v2.ts:559-792` | `toModelMessages()` 把 durable history 转成 provider 可吃的 `ModelMessage[]`。 |
| provider 请求装配 | `packages/opencode/src/session/llm.ts:70-167` | system、messages、options、headers、tools 最终在这里合流。 |

## 二、输入侧不是“把原文交给模型再说”

`packages/opencode/src/session/prompt.ts:191-240` 的 `resolvePromptParts()` 已经做了第一轮上下文工程：

- 匹配 Markdown 里的文件引用。
- 如果是本地路径，转成 `type: "file"` part。
- 如果磁盘上没有这个名字，但存在同名 agent，就转成 `type: "agent"` part。

到了 `createUserMessage()`，这些 parts 会进一步被实体化：

- MCP resource 直接读内容，坐标 `1000-1067`。
- 文本文件调用 `ReadTool` 提前注入读取结果，坐标 `1106-1210`。
- `@agent` 会被翻译成“后续应该调用 task tool”的 synthetic text，坐标 `1272-1294`。

## 三、系统指令不是一层，是三层半

### 1. 指令文件层

`packages/opencode/src/session/instruction.ts:72-141` 会找到项目和全局 instruction 文件，再把内容拼成 `Instructions from: <path>\n<content>`。

### 2. 环境层

`packages/opencode/src/session/system.ts:28-52` 把模型名、工作目录、workspace root、git repo 状态、平台和日期打包进 `<env>`。

### 3. 技能层

`packages/opencode/src/session/system.ts:55-67` 只有在 `skill` 工具没被禁用时才会注入 skill 列表。

### 4. 运行时补丁层

`packages/opencode/src/session/prompt.ts:1358-1495` 的 `insertReminders()` 会把 plan/build 切换提醒直接写进最后一条 user message。

## 四、真正喂给模型的不是原始 MessageV2

`packages/opencode/src/session/message-v2.ts:559-792` 的 `toModelMessages()` 做了几件特别关键的转换：

- user message 的纯文本 `file`/目录 part 会转成 text，不重复投给模型，坐标 `623-651`。
- `compaction` 和 `subtask` part 会被投影成特定提示文本，坐标 `653-664`。
- assistant `tool` part 会按 `completed/error/pending/running` 转成 tool output 或中断错误，坐标 `697-748`。
- 对不支持 tool-result media 的 provider，会把图片/PDF attachments 注入成后续 user message，坐标 `703-778`。

所以 durable truth 和 model view 从来不是同一个结构。

## 五、最后一跳才是 provider-specific late binding

`packages/opencode/src/session/llm.ts:70-167` 把这些上下文收束成最终请求：

- `70-95` 组 system prompt。
- `97-145` 合并模型参数。
- `147-159` 注入 headers。
- `166-167`/`292-303` 裁工具权限。

这也是为什么 OpenCode 能在不改 durable history 的前提下切 provider、切模型、切缓存策略。
