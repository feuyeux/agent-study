# agent loop：`Agent::from_config()` 和主循环怎样把 provider、tools、memory 串成一个 turn

ZeroClaw 的 agent loop 有两个重点：总装链，以及 turn 级执行闭环。

## `Agent::from_config()` 是总装厂

这个函数先调用 `create_memory_with_storage_and_routes()` 建 memory，再通过 `tools::all_tools_with_runtime()` 和 `filter_primary_agent_tools()` 构造工具面，随后用 `create_routed_provider()` 建 provider，最后根据配置和 provider 能力选择 `NativeToolDispatcher` 或 `XmlToolDispatcher`。也就是说，provider、tools、memory 和 dispatcher 都是启动时确定的装配结果（`zeroclaw/src/agent/agent.rs:285-390`）。

## `Agent` 结构体把 turn 所需状态全显式化

`Agent` 本身持有 provider、tools、memory、observer、prompt_builder、tool_dispatcher、history、turn_buffer、classification、research config 等字段。主循环不是在全局单例上跑，而是在一个完整状态对象上推进（`zeroclaw/src/agent/agent.rs:24-48`）。

## 主循环按固定顺序闭环

每轮 turn 都先把 user message 压进 `history`，然后决定 `effective_model`，初始化 `LoopDetector`，再反复执行：

- `tool_dispatcher.to_provider_messages(&self.history)`
- `provider.chat(...)`
- `tool_dispatcher.parse_response(&response)`
- 如果无 tool call，写 assistant 文本、autosave memory、做 fact extraction
- 如果有 tool call，记录 `AssistantToolCalls`、执行 `execute_tools()`、格式化结果、更新 loop detector、必要时注入 warning 或 hard stop

这条顺序在 `for iteration in 0..max_tool_iterations` 里是完全显式的（`zeroclaw/src/agent/agent.rs:617-745`）。

## Tool dispatch 不是后处理，而是 provider 协议的一部分

`Provider` trait 的 `chat()` 默认实现会在 provider 不支持 native tools 时把 `ToolSpec` 转成 `ToolsPayload::PromptGuided` 并注入 system prompt；而支持 native tools 的 provider 可以返回 Gemini、Anthropic、OpenAI 风格 payload。也就是说，tool dispatch 既依赖 `ToolDispatcher`，也依赖 provider 能力协商（`zeroclaw/src/providers/traits.rs:323-449`）。

## 关键源码锚点

- agent 状态对象：`zeroclaw/src/agent/agent.rs:24-48`
- agent 总装：`zeroclaw/src/agent/agent.rs:285-390`
- 主循环：`zeroclaw/src/agent/agent.rs:617-745`
- provider/tool 协议：`zeroclaw/src/providers/traits.rs:323-449`

## 阅读问题

- `ToolDispatcher` 和 `Provider::convert_tools()` 的职责边界为什么要拆两层？
- 如果把 `LoopDetector` 移到工具实现内部，会损失什么全局语义？
