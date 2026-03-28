# OpenCode 源码深度解析 A04：`prompt`、`loop`、`processor` 的职责边界

> 本文基于 `opencode` `v1.3.2`（tag `v1.3.2`，commit `0dcdf5f529dced23d8452c9aa5f166abb24d8f7c`）源码校对

如果只看功能名，`prompt`、`loop`、`processor` 很容易被讲成“三层职责分离”。但源码里真正重要的不是抽象名词，而是它们之间交接的产物完全不同：

1. `prompt()` 只接收外部输入，并把它编译成 durable user message。
2. `loop()` 不接收原始输入，它只回放 session 历史并判断下一轮该做什么。
3. `processor` 不管 session 全局状态，它只消费这一轮 `LLM.stream()` 的事件流。

也就是说，三层不是“都在 orchestrate”，而是在处理三种不同粒度的数据。

---

## 1. 先把三层骨架按代码顺序摊开

如果把 `packages/opencode/src/session/prompt.ts` 和 `session/processor.ts` 压成伪代码，骨架其实非常直白：

```ts
prompt(input) {
  cleanupRevert()
  message = createUserMessage(input)
  Session.touch(sessionID)
  maybePatchLegacyPermissions()
  if (input.noReply) return message
  return loop({ sessionID })
}

loop({ sessionID }) {
  abort = startOrResume(sessionID)
  while (true) {
    msgs = filterCompacted(stream(sessionID))
    { lastUser, lastAssistant, lastFinished, tasks } = deriveState(msgs)
    if (canExit(lastUser, lastAssistant)) break
    if (pendingSubtask(tasks)) executeTaskBranch()
    else if (pendingCompaction(tasks)) executeCompactionBranch()
    else if (isOverflow(lastFinished)) createCompactionTask()
    else executeNormalRound()
  }
  return latestAssistantMessage()
}

processor.process(streamInput) {
  stream = LLM.stream(streamInput)
  for await (event of stream.fullStream) {
    writeReasoningTextToolStepParts(event)
    updateAssistantMessageFinishUsageError(event)
  }
  return "continue" | "compact" | "stop"
}
```

所以这三层的边界不是“都和模型交互”，而是：

1. `prompt()` 处理输入编译。
2. `loop()` 处理轮次调度。
3. `processor` 处理单轮事件写回。

---

## 2. `prompt()` 的边界其实很硬

### 2.1 `prompt()` 真正只做四件事

`packages/opencode/src/session/prompt.ts:162-188` 的 `prompt()` 很短，但每一步都有硬边界：

1. `Session.get(input.sessionID)` 先把 session 取出来。
2. `SessionRevert.cleanup(session)` 先清理可能残留的 revert 状态。
3. `createUserMessage(input)` 把这次输入编译成 durable user message / parts。
4. `Session.touch(input.sessionID)` 更新时间戳。

后面 `169-182` 那段看起来像是业务逻辑，其实只是兼容旧 `tools` 参数，把它转成 session permission。

最后 `184-188` 才决定：

1. `noReply === true` 就直接返回刚写进去的 user message。
2. 否则进入 `loop({ sessionID })`。

### 2.2 `prompt()` 不负责的事

这一层明确不做三件事：

1. 不决定这轮要不要 subtask、compaction 或 normal round。
2. 不组 model messages，不碰 provider。
3. 不消费任何模型流事件。

所以 `prompt()` 的职责不是“开始一轮推理”，而是“把外部输入变成 runtime 能消费的 durable 状态”。

---

## 3. `loop()` 才是 session 级调度器

### 3.1 进入 `loop()` 的第一步不是读历史，而是占住 session

`274-289` 的入口先做并发控制：

1. `start(sessionID)` 会给这个 session 建一个 `AbortController` 和 callbacks 队列。
2. 如果同一个 session 已经在跑，新的调用不会重复执行，而是挂进 `callbacks`，等已有执行结束后拿结果。
3. `defer(() => cancel(sessionID))` 保证无论成功、失败还是中断，最终都会把 `SessionStatus` 释放回 `idle`。

这意味着 OpenCode 处理“同一 session 被重复 prompt”靠的不是数据库锁，而是 `SessionPrompt` 的 instance-local 状态。

### 3.2 `loop()` 的输入是 durable history，不是内存 conversation

`298-319` 是这层最关键的代码：

1. `MessageV2.filterCompacted(MessageV2.stream(sessionID))` 先把当前可见历史回放出来。
2. 然后从尾到头扫描，求出：
   - `lastUser`
   - `lastAssistant`
   - `lastFinished`
   - `tasks`

这一步非常重要，因为后续所有分支判断都建立在这批 durable 历史上，而不是建立在“刚才函数里发生了什么”上。

### 3.3 `loop()` 的退出条件是代码写死的

`321-329` 的退出判断并不模糊：

1. 必须先找到 `lastUser`，否则直接报错。
2. 如果 `lastAssistant.finish` 已经存在，且 finish reason 不是 `"tool-calls"` / `"unknown"`，并且 `lastUser.id < lastAssistant.id`，说明上一轮已经完整结束，可以退出。

也就是说，`loop()` 不是“跑到模型不想说为止”，而是只在满足明确 durable 条件时退出。

---

## 4. `loop()` 里有哪些硬编码分支

### 4.1 pending subtask 分支先写一条 assistant tool 轮次

`354-540` 不是一句“执行 task 工具”就能概括的。它的顺序是：

1. `Session.updateMessage(...)` 先插一条 assistant message，作为这轮 subtask tool call 的宿主。
2. `Session.updatePart(...)` 再插一个 `tool` part，状态直接是 `running`。
3. `Plugin.trigger("tool.execute.before", ...)` 先给 plugin 一个切面。
4. 真正执行 `taskTool.execute(taskArgs, taskCtx)`。
5. 执行结束后，把 `tool` part 改成 `completed` 或 `error`。
6. 若这次 subtask 来自 command，还会额外补一条 synthetic user message，提醒主 agent 继续总结和推进。

所以 pending subtask 不是“模型自己下一轮顺便处理一下”，而是 `loop()` 主动改写 durable history，再执行一条显式工具分支。

### 4.2 pending compaction 分支直接交给 `SessionCompaction.process()`

`542-554` 的逻辑更克制：

1. 只要 `task?.type === "compaction"`，就把当前 `msgs`、`parentID`、`abort`、`auto/overflow` 交给 `SessionCompaction.process(...)`。
2. 返回 `"stop"` 就直接退出，否则继续下一轮。

这说明 compaction 不是 `processor` 的子逻辑，而是 `loop()` 识别到特定 durable part 后切去另一条 session 级分支。

### 4.3 overflow 自愈也发生在 `loop()`，不发生在 `processor`

`556-569` 会检查：

1. `lastFinished` 必须存在。
2. 当前轮次还不是 `summary`。
3. `SessionCompaction.isOverflow({ tokens: lastFinished.tokens, model })` 返回 true。

满足后不会直接报错，而是先 `SessionCompaction.create(...)`，把“需要压缩”再次编码成 durable compaction task，然后继续下一轮。

所以 overflow 的 session 级策略仍然掌握在 `loop()` 手里。

---

## 5. normal round 真正从哪里开始

### 5.1 normal round 的开始标志是 assistant skeleton

`571-620` 的 normal processing 分支先做了三件事：

1. `Agent.get(lastUser.agent)` 取出本轮 agent。
2. `insertReminders(...)` 给当前历史补运行时提醒。
3. `Session.updateMessage(...)` 先插一条 assistant skeleton message。

这条 skeleton 很关键，因为 `SessionProcessor.create(...)` 拿到的第一个输入就是它。也就是说，processor 从来不是“先有流，再决定往哪写”，而是“先有 durable assistant 宿主，再往里面写流事件”。

### 5.2 `loop()` 在进入 `processor` 前就把本轮上下文准备好了

`623-707` 又完成了五件事：

1. 通过 user message 里的 `agent` part 判断是否要 `bypassAgentCheck`。
2. `resolveTools(...)` 先把本轮 active tools 算出来。
3. 若当前是 `json_schema` 模式，就临时注入 `StructuredOutput` 工具。
4. 把 queued user message 包成 `<system-reminder>`，只影响本轮模型感知，不回写 DB。
5. 组好：
   - `system`
   - `messages`
   - `tools`
   - `toolChoice`

最后才把这些全部交给 `processor.process(...)`。

这一步很能说明边界：`loop()` 负责准备“这一轮应该怎么打给模型”，但真正处理模型流的是 `processor`。

### 5.3 `processor` 返回后，最后决定权还在 `loop()`

`710-744` 会再做一轮 session 级判断：

1. 如果 `StructuredOutput` 已经成功捕获，就把结果写回 `assistant.structured` 并直接结束。
2. 如果模型正常停下了，但在 `json_schema` 模式下没调用 `StructuredOutput`，就写入 `StructuredOutputError` 并结束。
3. 如果 `processor` 返回 `"stop"`，结束。
4. 如果返回 `"compact"`，由 `loop()` 负责创建新的 compaction task。
5. 其他情况继续下一轮。

因此 `processor` 只是把单轮结果交回来；是否再开下一轮，仍然是 `loop()` 的决定。

---

## 6. `processor` 的边界同样非常硬

### 6.1 `create()` 只保存单轮局部状态

`packages/opencode/src/session/processor.ts:27-45` 初始化的只有：

1. `toolcalls`
2. `snapshot`
3. `blocked`
4. `attempt`
5. `needsCompaction`

这说明 processor 自己不维护 session 全局历史，也不缓存上一轮上下文。它只关心“这条模型流里还悬着哪些 tool call、是否需要重试、是否需要 compaction”。

### 6.2 `process()` 只解释 `LLM.stream()` 这一轮事件流

`46-353` 的主体逻辑就是：

1. `const stream = await LLM.stream(streamInput)`。
2. `for await (const value of stream.fullStream)` 按事件类型逐个处理。
3. 不同事件会被翻译成不同 durable writes：
   - `reasoning-start/delta/end` -> reasoning parts
   - `text-start/delta/end` -> text parts
   - `tool-input-start` / `tool-call` / `tool-result` / `tool-error` -> tool parts 状态机
   - `start-step` / `finish-step` -> step parts、snapshot patch、usage/cost/finish

这里没有任何“重新扫描 session 历史”“重新决定 agent”“挑选下一个任务”的逻辑。

### 6.3 `processor` 的返回值不是文本，而是调度信号

`421-424` 最后只会返回三种结果：

1. `"compact"`
2. `"stop"`
3. `"continue"`

它返回的不是 assistant 文本，不是 tool 结果，也不是下一轮 prompt。那些东西都已经通过 `Session.updateMessage()` / `updatePart()` 写回 durable state 了；这里仅仅告诉 `loop()` 下一步应该怎么调度。

---

## 7. 为什么这三层不能合成一层

把代码串起来就能看到，不合并是因为三层操作的是三种完全不同的输入输出：

| 层 | 输入 | 输出 |
| --- | --- | --- |
| `prompt()` | 外部请求体：text/file/agent/subtask/format/model/tools | durable user message / parts |
| `loop()` | durable session history | 本轮分支决策 + assistant skeleton + `processor` 调用 |
| `processor` | 单轮 `LLM.stream()` 事件流 | durable reasoning/text/tool/step/patch 写回 + `"continue" / "compact" / "stop"` |

一旦看清这张表，很多误解就会自动消失：

1. `prompt()` 不是模型入口，它是输入编译器。
2. `loop()` 不是 token 消费器，它是 session 调度器。
3. `processor` 不是 orchestrator，它是单轮事件写回器。

---

## 8. 下一篇该带着什么问题去看 A05

A04 把三层边界切开后，A05 就可以只盯一个问题：

1. `loop()` 每轮到底按什么顺序判分支。
2. subtask、compaction、overflow、normal round 为什么是现在这个顺序。
3. 哪些写回发生在进入 `processor` 之前，哪些写回只能在 `processor` 内部发生。

也就是说，A05 不再解释“谁负责什么”，而是解释“`loop()` 这台调度器内部到底怎样展开”。
