# OpenCode 源码深度解析 A04：第 2 步：`loop()` 决定下一轮，再把模型调用交给 `processor()`

接在 A03 之后，`loop()` 与 `processor()` 分别承担不同层级的状态转换：前者负责 session 级调度，后者负责单轮流事件处理。

## 一、分层坐标

| 主题 | 文件与代码行 | 职责 |
| --- | --- | --- |
| 并发状态表 | `packages/opencode/src/session/prompt.ts:69-92` | 用 `Instance.state()` 维护每个 session 的 `AbortController`。 |
| `start/resume/cancel` | `packages/opencode/src/session/prompt.ts:242-272` | 决定本次是抢占新 loop、复用已有 loop，还是显式取消。 |
| `loop()` 主体 | `packages/opencode/src/session/prompt.ts:278-736` | session 级状态机。 |
| `SessionProcessor.create()` | `packages/opencode/src/session/processor.ts:27-46` | 创建一次 assistant 执行器，封装 toolcalls/snapshot/retry 状态。 |
| `process()` 主体 | `packages/opencode/src/session/processor.ts:46-425` | 单轮 LLM 流消费器。 |
| Processor 调用点 | `packages/opencode/src/session/prompt.ts:571-688` | `loop()` 创建 assistant message、resolve tools、组装 messages 后调用 processor。 |

## 二、`loop()` 只做“下一步是什么”

`packages/opencode/src/session/prompt.ts:278-736` 的职责可以压成四个判断：

1. `281-289` 先决定是新建 loop 还是挂到已有 loop 上；如果已有 loop 在跑，就把回调挂到 `state()[sessionID].callbacks`，而不是开第二条执行链。
2. `302-329` 每轮从 `MessageV2.filterCompacted(MessageV2.stream(sessionID))` 重建现场，找 `lastUser`、`lastAssistant`、`lastFinished` 和待处理任务。
3. `356-543` 如果存在 `subtask` 或 `compaction`，优先消费这些 durable parts。
4. `561-724` 没有特殊任务时才进入正常模型推理，创建 `SessionProcessor` 并调用 `process()`。

因此 loop 是 session 级调度器，不处理 token 流，也不解析 provider 事件。

## 三、Processor 只做“这一轮流里发生了什么”

`packages/opencode/src/session/processor.ts:46-425` 的边界也很清晰：

- `54` 调 `LLM.stream(streamInput)` 获取 provider 统一流。
- `56-353` 遍历 `stream.fullStream`，把 `reasoning-*`、`text-*`、`tool-*`、`start-step`、`finish-step` 映射成 durable parts。
- `354-387` 做错误分类、重试、上下文溢出判定。
- `402-424` 在一轮结束时把未完成工具补成 error、落 assistant 完成时间，并向 loop 返回 `continue` / `compact` / `stop`。

Processor 不决定“要不要开 subtask”“要不要做 compaction user message”，这些都属于 loop 的职责。

## 四、两层之间的真实交接点

交接发生在 `packages/opencode/src/session/prompt.ts:571-688`：

1. `571-600` 先插入空 assistant message，固定 `parentID`、`agent`、`cwd/root`、`modelID/providerID`。
2. `607-615` 根据 agent、session、model、历史消息计算可用工具。
3. `617-625` 如果用户要求 `json_schema`，额外注入 `StructuredOutput` 工具。
4. `653-665` 组 system prompt。
5. `667-688` 把 `MessageV2.toModelMessages(msgs, model)` 的结果交给 processor。

这也是为什么 assistant 骨架能先落盘，而真正的 text/tool/reasoning parts 由 processor 逐步补齐。

## 五、别把 subtask 和 compaction 说成“特殊工具”

它们是 loop 里的显式分支，不只是 processor 里某个 tool result：

- `packages/opencode/src/session/prompt.ts:356-529`：`subtask` part 会先新建一条 assistant message，再用 `TaskTool.execute()` 跑子任务，最后必要时补一条 synthetic user message，防止模型在下一轮缺失 user turn。
- `packages/opencode/src/session/prompt.ts:533-543`：`compaction` part 直接交给 `SessionCompaction.process()`。
- `packages/opencode/src/session/prompt.ts:546-559`：如果上一轮 token 已经接近上限，loop 会先创建 compaction user message，再下一轮处理。

## 六、结论

1. loop 是 session 级状态机，processor 是单轮流事件处理器。
2. assistant message 骨架由 loop 创建，reasoning/text/tool/patch parts 由 processor 逐步补全。
3. subtask、compaction、structured output 都是 loop 层的编排决策，不是 processor 随手附带的行为。
