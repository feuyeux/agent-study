# OpenCode 源码深度解析 A04：`prompt`、`loop`、`processor` 的职责边界

> 本文基于 `opencode` `v1.3.2`（tag `v1.3.2`，commit `0dcdf5f529dced23d8452c9aa5f166abb24d8f7c`）源码校对

很多介绍会把 OpenCode 说成“一个 loop + 一次模型调用”。这在概念上没错，但对源码分析是不够的。当前实现至少分成三层：`prompt()` 负责把输入编译成 durable user message，`loop()` 负责 session 级调度，`SessionProcessor.process()` 负责消费单轮模型流。

---

## 1. 这三层分别解决什么问题

| 层 | 代码坐标 | 真正职责 |
| --- | --- | --- |
| `SessionPrompt.prompt()` | `packages/opencode/src/session/prompt.ts:162-188` | 把本次输入编译进 durable history，并触发后续调度。 |
| `SessionPrompt.loop()` | `packages/opencode/src/session/prompt.ts:278-756` | 基于当前 session 历史判断下一轮该做什么：subtask、compaction，还是正常推理。 |
| `SessionProcessor.process()` | `packages/opencode/src/session/processor.ts:46-425` | 对单次 `LLM.stream()` 流做事件级消费，把 reasoning/text/tool/step 写回 durable state。 |

最重要的分界线是：

1. `loop()` 决定 **要不要** 调模型，以及这一轮之前要先处理什么。
2. `processor` 决定 **这一轮模型流里发生了什么**。

---

## 2. `prompt()` 和 `loop()` 之间还有一层并发控制

`packages/opencode/src/session/prompt.ts:69-93` 定义了 `SessionPrompt` 的实例内状态：

1. 每个 `sessionID` 对应一个 `AbortController`。
2. 还有一个 callbacks 队列，用来挂住并发调用者。

`start(sessionID)`、`resume(sessionID)`、`cancel(sessionID)` 在 `242-272`：

1. 新任务用 `start()` 占住 session。
2. 已有任务恢复时走 `resume_existing`。
3. 同时又来一个 `loop()` 调用时，不会重复执行，而是把 `resolve/reject` 挂到回调队列上。

因此，OpenCode 对“同一个 session 同时多次 prompt”不是靠数据库锁解决的，而是靠 `SessionPrompt` 的进程内占位状态解决的。

---

## 3. `loop()` 负责“下一轮做什么”

`loop()` 一进来就先做三件事：

1. 占住 session 或复用已有 abort signal，见 `281-287`。
2. 用 `defer(() => cancel(sessionID))` 保证最终释放忙碌状态，见 `289`。
3. 初始化本轮临时状态，如 `structuredOutput`、`step`。

之后每一轮的固定流程是：

1. `MessageV2.filterCompacted(MessageV2.stream(sessionID))` 取当前可见历史，见 `302`。
2. 从最新消息往前扫描，找出：
   - `lastUser`
   - `lastAssistant`
   - `lastFinished`
   - `tasks`
3. 判断是否可以直接退出。
4. 若不能退出，就根据 `tasks` 和 overflow 状态选择分支。

也就是说，`loop()` 是 session 级调度器，不是 token 消费器。

---

## 4. `processor` 负责“这一轮里发生了什么”

`SessionProcessor.create()` 在 `27-45` 只接收四个输入：

1. 已经落盘的 assistant 骨架 message
2. sessionID
3. 当前 model
4. abort signal

然后 `process(streamInput)` 做的事是：

1. 调 `LLM.stream(streamInput)`，见 `54`。
2. 按事件类型写 reasoning/text/tool/step/patch。
3. 把 usage、cost、finish、error 写回 assistant message。
4. 根据 retry/overflow/block/error 返回 `"continue" | "compact" | "stop"`。

因此 `processor` 不读取全局历史、不决定 subtask/compaction 分支，也不决定下轮是否换 agent；它只解释当前这条模型流。

---

## 5. 三层之间的真实交接点

当前主线的交接点非常明确：

### 5.1 `prompt()` -> `loop()`

`prompt()` 完成 durable user message 的写入后，直接 `return loop({ sessionID })`。这里的交接物不是原始输入字符串，而是**已经持久化的 message/parts**。

### 5.2 `loop()` -> `processor`

普通推理分支里，`loop()` 会先插入一条 assistant skeleton message，见 `571-600`，然后创建：

1. `SessionProcessor`
2. tool set
3. system prompt
4. model messages

最后调用 `processor.process(...)`，见 `667-688`。

### 5.3 `processor` -> `loop()`

`processor.process()` 返回的不是文本，而是状态信号：

1. `"continue"`：本轮正常完成，loop 再判断是否继续。
2. `"compact"`：上下文太大，需要先创建 compaction 任务。
3. `"stop"`：错误、拒绝、结构化输出失败等终止条件成立。

这就是 OpenCode 把“调度决策”和“单轮执行”拆开的关键。

---

## 6. 哪些能力不属于这三层

为了避免误把所有逻辑塞进 orchestrator，需要看清几个边界：

1. **provider 绑定** 不在 `loop()` / `processor`，而在 `session/llm.ts`。
2. **message -> model message 投影** 不在 `processor`，而在 `message-v2.ts`。
3. **subagent 的 child session 创建** 真正落在 `tool/task.ts`。
4. **compaction 的 summary 构造** 落在 `session/compaction.ts`。
5. **permission/question 的 ask/reply** 分别落在 `permission/index.ts` 和 `question/index.ts`。

所以 A04 的意义不是把所有逻辑装进“编排层”，而是明确编排层只负责**拼装和调度**。

---

## 7. 为什么这个分层很重要

这套分层带来三个直接效果：

1. `prompt()` 可以被 `message`、`command`、`task`、桌面端 UI 等不同入口复用。
2. `loop()` 每轮只依赖 durable history，因此 session 可以恢复、fork、revert、compaction。
3. `processor` 可以专注做事件级幂等写回，不需要知道入口来自 CLI、TUI 还是 ACP。

下一篇 A05 会继续把 `loop()` 内部真正的分支展开讲透，尤其是 subtask、compaction 和 normal round 三条路径到底怎样落在代码里。
