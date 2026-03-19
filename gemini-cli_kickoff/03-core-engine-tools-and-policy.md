# core engine、tools 与 policy：`GeminiChat`、`Turn`、`Scheduler`、`PolicyEngine` 在哪里闭环

主向导对应章节：`core engine、tools 与 policy`

真正的模型交互入口在 `GeminiChat.sendMessageStream()`。`GeminiChat` 构造时会初始化 `ChatRecordingService`、校验历史并估算 prompt token 数（`gemini-cli/packages/core/src/core/geminiChat.ts:249-271`），而 `sendMessageStream()` 则用 `sendPromise` 序列化并发发送，先把用户消息转成 `Content`，再通过 `context.config.modelConfigService` 解析模型配置并开始流式交互（`gemini-cli/packages/core/src/core/geminiChat.ts:303-330`）。后续 `recordCompletedToolCalls()` 还会在工具回合结束后把工具调用以完整元数据写回记录层（`gemini-cli/packages/core/src/core/geminiChat.ts:1010-1028`）。

`Turn.run()` 站在 `GeminiChat` 之上，把底层流事件重新编排成 agent loop 可消费的语义事件。它从 `sendMessageStream()` 读出 chunk 后，按顺序解析 `thought`、正文文本、函数调用、citation 和 `finishReason`，并把工具请求统一收敛为 `GeminiEventType.ToolCallRequest`（`gemini-cli/packages/core/src/core/turn.ts:253-359`）。如果流出错，它还会构造结构化错误、补 schema 深度上下文并上报（`gemini-cli/packages/core/src/core/turn.ts:361-404`）。`handlePendingFunctionCall()` 则专门把 function call 包装成 `ToolCallRequestInfo`，并塞进 `pendingToolCalls`（`gemini-cli/packages/core/src/core/turn.ts:406-426`）。

工具调度在 `Scheduler` 层完成。`Scheduler` 构造函数会把 `SchedulerStateManager`、`ToolExecutor`、`ToolModificationHandler`、`MessageBus` 和各种上下文引用装进一个状态对象，并通过 `setupMessageBusListener()` 预装确认消息桥（`gemini-cli/packages/core/src/scheduler/scheduler.ts:93-184`）。`schedule()` 是批处理入口：它根据当前是否已有活跃批次，决定直接 `_startBatch()` 还是先 `_enqueueRequest()`，从而把多个工具请求折叠成受控执行队列（`gemini-cli/packages/core/src/scheduler/scheduler.ts:186-210`）。

审批与风险判断则不在 Scheduler 内部硬编码，而落在 `PolicyEngine`。`PolicyEngine` 构造时会把 rules、checkers、hookCheckers 全部按 priority 排序，并维护 `approvalMode`、`defaultDecision`、`nonInteractive` 等策略状态（`gemini-cli/packages/core/src/policy/policy-engine.ts:163-188`）。`checkShellCommand()` 是最值得细读的方法：它会先初始化 shell parser，再把命令拆成子命令，处理重定向降级、解析失败时的回退、以及 YOLO/AUTO_EDIT 等审批模式分支（`gemini-cli/packages/core/src/policy/policy-engine.ts:223-315`）。

这四个对象分工很清楚：`GeminiChat` 负责和模型会话并做录制，`Turn` 负责把模型流转成 agent 语义事件，`Scheduler` 负责把工具调用变成受控执行批次，`PolicyEngine` 负责批准、降级或拒绝风险操作。把它们串起来看，Gemini CLI 的核心并不是“一个 while 循环”，而是一组边界非常清楚的引擎部件。
