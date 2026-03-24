# OpenCode 源码深度解析 A06：第 4 步：沿着 `processor()` 进入 `LLM.stream()`，看模型请求怎样发出去

本篇继续承接 A04，但焦点从 `loop()` 切到 `processor()` 的下一跳：`packages/opencode/src/session/processor.ts:54` 在这里进入 `LLM.stream(streamInput)`，而 `packages/opencode/src/session/llm.ts` 决定了这轮请求如何被组装成 provider 可接受的格式。

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

## 五、A06 和 A04/A05 的接缝

这一层的调用点不在 llm 文件里，而在：

- `packages/opencode/src/session/prompt.ts:667-688`：loop 组好 `system/messages/tools/model` 后调用 processor。
- `packages/opencode/src/session/processor.ts:54`：processor 进入 `LLM.stream(streamInput)`。

所以 A04/A05 负责“何时发起一轮模型调用”，A06 负责“这轮请求以什么 provider 兼容格式发出去”。
