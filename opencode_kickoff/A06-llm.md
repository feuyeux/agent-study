# OpenCode 源码深度解析 A06：沿着 `processor()` 进入 `LLM.stream()`，看模型请求怎样发出去

> 本文基于 `opencode` `v1.3.2`（tag `v1.3.2`，commit `0dcdf5f529dced23d8452c9aa5f166abb24d8f7c`）源码校对

到了 A06，真正的模型调用才开始出现。在 `v1.3.2` 中，大模型请求不是 `processor` 里随手拼个 payload 发出去，而是经过了 system prompt 选择、环境注入、指令文件加载、tool set 包装、provider 参数合并、兼容补丁和 AI SDK middleware 多层处理。

---

## 1. 入口坐标

这条调用链的关键代码有四组：

| 环节 | 代码坐标 | 作用 |
| --- | --- | --- |
| `processor -> llm` 交接 | `packages/opencode/src/session/processor.ts:46-56` | 单轮执行开始，调用 `LLM.stream()`。 |
| system prompt 组装 | `packages/opencode/src/session/prompt.ts:675-685`、`session/system.ts:17-67`、`session/instruction.ts:72-191` | provider prompt、环境信息、技能、AGENTS/CLAUDE 指令等被合并。 |
| provider/tool/params 绑定 | `packages/opencode/src/session/llm.ts:48-285` | 选择 language model、参数、headers、tools，并最终调用 `streamText()`。 |
| provider 适配 | `packages/opencode/src/provider/provider.ts:1319-1487` | `getProvider`、`getModel`、`getLanguage`、`defaultModel`、`parseModel`。 |

---

## 2. system prompt 不是一坨字符串，而是四层来源的叠加

在 `v1.3.2` 中，system prompt 分两段生成。

### 2.1 `prompt.ts` 先准备“运行时上下文层”

普通推理分支里，`675-685` 会先拼出：

1. `SystemPrompt.environment(model)`：环境信息，见 `session/system.ts:28-53`
2. `SystemPrompt.skills(agent)`：技能目录和说明，见 `55-67`
3. `InstructionPrompt.system()`：AGENTS.md / CLAUDE.md / config instructions / URL instructions，见 `instruction.ts:117-142`

如果本轮是 JSON schema 输出，还会额外追加结构化输出强制指令。

### 2.2 `llm.ts` 再决定 provider/agent/user 级覆盖顺序

`session/llm.ts:70-82` 的最终顺序是：

1. 若 agent 自带 `prompt`，优先它；否则退回 `SystemPrompt.provider(model)`
2. 再接上 `input.system`，也就是上一层准备好的环境/技能/指令
3. 最后再接 `input.user.system`

这个顺序非常重要，因为它说明：

1. provider prompt 是最底层基座。
2. 环境和指令文件在它上面叠。
3. 用户显式传进来的 `system` 才是最后一层补丁。

所以 OpenCode 的 system prompt 不是固定模板，而是一套按层级拼接的编译产物。

---

## 3. provider prompt 的选择是硬编码策略，不是配置文件规则

`packages/opencode/src/session/system.ts:18-26` 当前内置的 provider prompt 选择逻辑很直接：

1. `gpt-4` / `o1` / `o3` 走 `PROMPT_BEAST`
2. 其他 `gpt*` 走 `PROMPT_CODEX`
3. `gemini-*` 走 `PROMPT_GEMINI`
4. `claude*` 走 `PROMPT_ANTHROPIC`
5. `trinity` 走 `PROMPT_TRINITY`
6. 否则走 `PROMPT_DEFAULT`

这说明 provider prompt 不是“从 config 里任意挑一份模版”，而是 runtime 里写死的模型家族策略。

---

## 4. 环境层和指令层各自提供了什么

### 4.1 环境层

`SystemPrompt.environment()` 会把以下信息注入 system：

1. 当前精确模型 ID
2. `Instance.directory`
3. `Instance.worktree`
4. 当前目录是否是 git repo
5. 平台
6. 当天日期

这些信息都不是 UI 侧补的，而是服务端 runtime 在发请求前最后一刻插进去的。

### 4.2 指令层

`InstructionPrompt.systemPaths()` / `system()` 会依次搜集：

1. 项目内自下而上的 `AGENTS.md` / `CLAUDE.md` / `CONTEXT.md`
2. 全局 `~/.config/opencode/AGENTS.md` 或 `~/.claude/CLAUDE.md`
3. `config.instructions` 里声明的额外文件或 URL

因此，OpenCode 当前的“项目级 agent 指令”并不是在 CLI 入口读取，而是在 LLM 调用前统一拉取并塞进 system prompt。

---

## 5. model 参数的优先级也在代码里写死了

`session/llm.ts:97-111` 先拿到：

1. `base`：small model 选项或普通 provider transform 选项
2. `input.model.options`
3. `input.agent.options`
4. `variant`

然后按顺序 `mergeDeep`。

这意味着参数优先级是：

1. provider transform 的默认值
2. model 自带选项
3. agent 自带选项
4. 当前 user message 选择的 variant

这不是“每层随便覆盖一点”，而是一条稳定的 precedence chain。

---

## 6. 进入 `streamText()` 之前，工具系统已经被包了两层

### 6.1 第一层：`prompt.ts` 把本地工具、插件工具、MCP 工具都包装成 AI SDK Tool

`SessionPrompt.resolveTools()` 在 `766-953` 里会：

1. 从 `ToolRegistry.tools(...)` 取到可用工具定义。
2. 用 `ProviderTransform.schema()` 做 schema 适配。
3. 给每个工具包上统一的 `Tool.Context`：
   - `metadata()`
   - `ask()`
   - 当前 session/message/callID/messages
4. 统一插入 plugin `tool.execute.before/after` 钩子。
5. 把 MCP tool 结果整理成文本输出和附件。

所以在 `LLM.stream()` 看到的 `input.tools`，已经不是裸工具，而是被 runtime 包装过的一套 AI SDK Tool。

### 6.2 第二层：`llm.ts` 再按权限裁一次

`session/llm.ts:296-307` 会根据：

1. agent permission
2. session permission
3. user message 级的 `tools` 开关

再删掉被禁用的工具。

因此工具可用性不是一处决定，而是：

1. 先生成所有候选工具。
2. 再在发请求前做一次 late pruning。

---

## 7. `LLM.stream()` 里真正的 provider 兼容层有四块

### 7.1 OpenAI OAuth 走 `instructions` 字段，不拼 system messages

`67-69` 检测 `provider.id === "openai"` 且 auth 类型是 oauth；命中后：

1. `options.instructions = system.join("\n")`
2. `messages` 不再手动 prepend `system` message，而是直接用 `input.messages`

这不是风格差异，而是兼容 provider 协议差异。

### 7.2 LiteLLM/Anthropic 代理兼容：必要时补一个 `_noop` 工具

`168-186` 会在“历史里含 tool calls，但当前没有 active tools”时注入一个永远不会被调用的 `_noop`。这是为某些 LiteLLM/Anthropic proxy 必须要求 `tools` 字段存在而准备的兼容补丁。

### 7.3 GitLab Workflow model：把远端 workflow tool call 接回本地工具系统

`188-214` 如果 language model 是 `GitLabWorkflowLanguageModel`，会挂一个 `toolExecutor`：

1. 解析远端请求里的 `toolName` / `argsJson`
2. 调本地 `tools[toolName].execute(...)`
3. 再把 result/output/title/metadata 返回给 workflow 服务

也就是说，GitLab workflow 不是另一套工具执行系统，而是把 workflow tool call 反向桥接回 OpenCode 的工具系统。

### 7.4 tool call repair：大小写修复或打回 `invalid`

`222-242` 的 `experimental_repairToolCall` 会：

1. 若只是大小写不对且小写版工具存在，则修成小写工具名。
2. 否则把它改成 `invalid` 工具，并把错误放进 input JSON。

这一步做在协议层，而不是做在 processor 里。

---

## 8. 最后一步：`streamText()` 之前还有 middleware

`272-285` 用 `wrapLanguageModel()` 包了一层 middleware。唯一的 middleware 会在 stream 请求时：

1. 取到 `args.params.prompt`
2. 再用 `ProviderTransform.message(...)` 做 provider-specific prompt 转换

所以真正发给 provider 的 prompt，最后一刻还会再过一遍 provider transform。

这也是 OpenCode 当前“固定骨架 + 最晚绑定”的一个典型例子。

---

## 9. `streamText()` 调用时最终带上了什么

`220-293` 里最终传给 `streamText()` 的关键字段有：

1. `temperature/topP/topK`
2. `providerOptions`
3. `activeTools` / `tools` / `toolChoice`
4. `maxOutputTokens`
5. `abortSignal`
6. provider/model headers
7. `messages`
8. telemetry metadata

其中 headers 还会自动带上：

1. `x-opencode-project`
2. `x-opencode-session`
3. `x-opencode-request`
4. `x-opencode-client`

前提是 providerID 以 `opencode` 开头。

所以 A06 的终点，不是“把字符串发给模型”，而是把整份 session runtime 上下文压缩成一次 provider-aware 的 `streamText()` 调用。

---

## 10. A06 和 A07 的边界

A06 讲的是请求怎样被拼出来、怎样发出去；A07 才讲返回流怎样被解释成 durable part/message。

两者之间的边界非常清楚：

1. `LLM.stream()` 负责生成 `fullStream`
2. `SessionProcessor.process()` 负责消费 `fullStream`

所以如果你要找“为什么这个请求这样发”，看 A06；如果你要找“为什么前端能看到 reasoning/tool/patch 这些 part”，看 A07。
