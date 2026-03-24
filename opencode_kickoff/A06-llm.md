# OpenCode 源码深度解析 A06：第 4 步：沿着 `processor()` 进入 `LLM.stream()`，看模型请求怎样发出去

本篇继续承接 A04，但焦点从 `loop()` 切到 `processor()` 的下一跳：`packages/opencode/src/session/processor.ts:54` 在这里进入 `LLM.stream(streamInput)`，而 `packages/opencode/src/session/llm.ts` 决定了这轮请求如何被组装成 provider 可接受的格式。

> **TL;DR**：`streamText`（来自 Vercel `ai` SDK）确实是真正发起 HTTP 请求到 LLM API 的方法，但它前面有四层铺垫：`Provider.getLanguage()` → `wrapLanguageModel()` 包装 middleware → `streamText()` 接收参数 → 内部通过 `fetch` 真正发请求。

## 一、代码坐标

| 主题 | 文件与代码行 | 细节 |
| --- | --- | --- |
| `LLM.stream()` 入口 | `packages/opencode/src/session/llm.ts:48-290` | 统一 provider 请求装配。 |
| system prompt 合并 | `packages/opencode/src/session/llm.ts:70-95` | agent prompt、input.system、user.system 先拼，再给插件变换。 |
| 参数级联合并 | `packages/opencode/src/session/llm.ts:97-145` | `base -> model.options -> agent.options -> variant`。 |
| 自定义 headers | `packages/opencode/src/session/llm.ts:147-159`, `252-265` | 插件 headers + opencode 自有 headers。 |
| 工具裁剪 | `packages/opencode/src/session/llm.ts:166-167`, `292-303` | 根据 permission 和 user.tools 删除禁用工具。 |
| LiteLLM 兼容 | `packages/opencode/src/session/llm.ts:168-186` | 历史里有 tool-call 但本轮无工具时，注入 `_noop`。 |
| tool call 自动修复 | `packages/opencode/src/session/llm.ts:222-241` | 大小写修正，不可修复则降级到 `invalid`。 |
| provider prompt 选择 | `packages/opencode/src/session/system.ts:17-67` | 按模型家族选择 `PROMPT_CODEX` / `PROMPT_GEMINI` / `PROMPT_ANTHROPIC` 等。 |
| 指令文件装载 | `packages/opencode/src/session/instruction.ts:72-141` | 读取 AGENTS/CLAUDE/外部 instructions。 |

## 二、system prompt 并不是一坨字符串

`packages/opencode/src/session/llm.ts:70-95` 的处理顺序很明确：

1. `74-78` 先取 agent prompt 或 provider prompt。
2. 拼上 `input.system`。
3. 再拼上最后一条 user message 自带的 `system` 字段。
4. `85-89` 调 `Plugin.trigger("experimental.chat.system.transform", ...)` 允许插件改写。
5. `90-95` 如果 header 没变，会把 system 保持为“两段式结构”，专门给 provider cache 命中用。

这里的晚绑定体现在明确的数组拼接和二段式重组上。

## 三、模型参数的优先级也写死在代码里

`packages/opencode/src/session/llm.ts:97-145` 的合并顺序不能说反：

- `base` 来自 `ProviderTransform.options(...)` 或 `smallOptions(...)`。
- 然后 `mergeDeep(input.model.options)`。
- 再叠 `mergeDeep(input.agent.options)`。
- 最后叠 `mergeDeep(variant)`。

温度等参数则在 `128-145` 通过 `chat.params` 钩子再给插件最后一次覆写机会。

## 四、真正发请求前还有三层兼容补丁

### 1. 工具集会按权限再裁一次

`packages/opencode/src/session/llm.ts:292-303` 会把 agent permission、session permission、user.tools 三者合并后禁用对应工具。上游 `loop()` 已经 resolve 好工具定义，这里做的是最后一层 request-time 过滤。

### 2. LiteLLM/Anthropic 代理兼容不是文档说说而已

`packages/opencode/src/session/llm.ts:168-186` 明确检查：

- provider 是否显式标记 `litellmProxy`
- providerID/api.id 是否包含 `litellm`
- 历史消息是否还有 tool-call/tool-result

满足条件但本轮工具集为空时，会注入一个永不调用的 `_noop`。

### 3. tool call 修复在协议层，不在 processor

`packages/opencode/src/session/llm.ts:222-241` 的 `experimental_repairToolCall` 会先尝试把工具名转小写命中；修不好才改写成 `toolName: "invalid"` 并把错误原因塞进 input。processor 之后只需要按普通 tool-error 路径处理。

### 4. 工具执行结果是谁负责发回给模型的

这里有一个关键分工：**`streamText` 只负责发起请求和解析事件，工具的实际执行（execute）并不在 `streamText` 内部**。

当模型输出一个 tool-call 时，AI SDK 会：
1. 在 `fullStream` 上 yield 一个 `tool-call` 事件（携带 `toolName`/`input`/`toolCallId`）。
2. **暂停**流式输出，等待外部注入 `tool-result` 事件。
3. opencode 在 `processor.ts:181-202` 捕获 `tool-result`，由 Session/SessionLoop 执行完工具后，将结果通过某种机制（看 AI SDK 的 `toolResult` API）注回去，模型才能继续输出。

也就是说，`streamText` 返回的 `StreamTextResult` 上，工具调用是**半自动**的——SDK 负责解析事件，但工具执行和结果注入由 opencode 控制。

## 五、`streamText` 是真正的大模型调用入口——但它前面有四层铺垫

### 调用链路全貌

```
processor.ts:54  LLM.stream(streamInput)
  └── llm.ts:48  LLM.stream(input)         ← opencode 的入口，负责"组装请求"
        │
        ├── 61-66  并行拉取 language / config / provider / auth
        │           Provider.getLanguage(model) → provider.ts:1343
        │              └── 调用 provider chain 的 modelLoaders[]
        │                 最终拿到 LanguageModelV2 实例（真正的模型对象）
        │
        ├── 216-289  streamText({...})     ← 来自 ai SDK (Vercel)
        │              model: wrapLanguageModel({ model: language, middleware })
        │                 └── middleware[0].transformParams 把 prompt 格式再转一次
        │           返回 StreamTextResult<ToolSet>
        │
        └── processor.ts:56  for await (const value of stream.fullStream)
                               ← 消费 ai SDK 的流式事件
```

### 第一层：`Provider.getLanguage()` 是如何拿到真正的模型对象的

`llm.ts:61` 并行执行 `Provider.getLanguage(input.model)`。这个函数在 `provider.ts:1343-1368`：

1. 先查 `state.models` 缓存（key = `"${providerID}/${modelID}"`）。
2. 未命中则走 `getSDK(model)`（`provider.ts:1186-1317`）：根据 `model.api.npm` 找到对应的 AI SDK provider（如 `createAnthropic`、`createOpenAI` 等），调用其 `createXxx()` 并缓存 SDK 实例。
3. 再调 `modelLoaders[providerID](sdk, model.api.id, options)` 或 `sdk.languageModel(model.api.id)` —— 这一步才拿到 `LanguageModelV2`（真正的模型对象）。

也就是说，`LLM.stream()` 自己并不直接持有任何 provider 的 API key，它通过 `Provider` 命名空间按需加载。

### 第二层：`wrapLanguageModel` 的 middleware 是请求发出前的最后一次拦截

`llm.ts:268-281` 用 `wrapLanguageModel` 包了一层 `middleware`，其中 `transformParams` 只在 `type === "stream"` 时生效，把 `args.params.prompt` 再通过 `ProviderTransform.message()` 统一做消息格式转换。这是 `ProviderTransform` 最后一次介入的机会。

### 第三层：`streamText` 内部发生什么

`streamText` 是 Vercel `ai` SDK 的核心函数（`import { streamText } from "ai"`）。它：

1. 接收 opencode 组装好的 `messages`/`tools`/`temperature` 等参数。
2. 用 `model`（即经过 `wrapLanguageModel` 包装后的 `LanguageModelV2`）调用对应 provider 的 SDK。
3. 底层通过 `Provider.getLanguage` 中注册的 `fetch`（`provider.ts:1243-1284`）发出 HTTP 请求——请求体格式由 AI SDK 的 provider 实现决定（Anthropic 用 BC235 协议，OpenAI 用 TCG/ Responses API 等）。
4. 返回 `StreamTextResult<ToolSet>`，其 `fullStream` 是一个 `AsyncIterable<CoreStreamEvent>`，每 yield 一个事件都携带着 `type`（`start`/`text-delta`/`tool-call`/`finish-step` 等）。

**所以 `streamText` 是真正触发网络 I/O 的时刻。** 在此之前的所有代码（70-215 行）都是在构造传递给它的参数。

### 第四层：processor 消费流事件

`processor.ts:56` 开始 `for await (const value of stream.fullStream)`，对每一个 `CoreStreamEvent` 分类处理：
- `text-delta` → 增量写文本 part
- `tool-call` → 创建 tool part & 检查 doom loop
- `tool-result` → 更新 tool part 状态
- `finish-step` → 记录 usage / cost / 调用 compaction 判断

## 六、A06 和 A04/A05 的接缝

这一层的调用点不在 llm 文件里，而在：

- `packages/opencode/src/session/prompt.ts:667-688`：loop 组好 `system/messages/tools/model` 后调用 processor。
- `packages/opencode/src/session/processor.ts:54`：processor 进入 `LLM.stream(streamInput)`。

所以 A04/A05 负责“何时发起一轮模型调用”，A06 负责“这轮请求以什么 provider 兼容格式发出去”。
