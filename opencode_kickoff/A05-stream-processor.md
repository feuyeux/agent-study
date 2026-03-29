# OpenCode 源码深度解析 A05：`SessionProcessor.process()` 如何把单轮流事件写回 durable history

> 本文基于 `opencode` `v1.3.2`（tag `v1.3.2`，commit `0dcdf5f529dced23d8452c9aa5f166abb24d8f7c`）源码校对
> 核心代码：`packages/opencode/src/session/processor.ts`

如果说 `prompt()` 负责把外部输入编译进 history，`loop()` 负责决定“这轮该走哪条分支”，那 `processor` 干的就是第三件事：接住单轮 `LLM.stream()` 的事件流，并把 reasoning、text、tool、step、patch、finish、error 一类流式事件，一条条翻译成 durable writes。

它不决定下一个 agent，也不重新回放整个 session；它只处理“这一轮 assistant skeleton 已经建好之后，流进来的事件该怎么落盘”。

---

## 1. `create()` 只初始化单轮局部状态，不维护 session 全局历史

`packages/opencode/src/session/processor.ts:27-45`

`SessionProcessor.create(...)` 接收的输入只有 4 个：

1. `assistantMessage`
2. `sessionID`
3. `model`
4. `abort`

然后在 `33-37` 初始化 5 个局部变量：

1. `toolcalls`：当前轮里，`toolCallId -> MessageV2.ToolPart` 的映射表。
2. `snapshot`：当前 step 开始时的文件系统快照 ID。
3. `blocked`：是否因为权限拒绝或问题拒绝而要求外层停机。
4. `attempt`：当前轮的重试次数。
5. `needsCompaction`：是否因为上下文溢出而请求外层转去 compaction。

这已经说明 processor 的边界非常硬：

1. 它不持有整段 session 历史。
2. 它不关心上一轮 assistant 是谁。
3. 它只关心“这条 assistant skeleton 的这一轮流执行状态”。

---

## 2. `process()` 的主体其实是“带重试的单轮流解释器”

`packages/opencode/src/session/processor.ts:46-55`

### 2.1 每次 `process()` 开头先重置 compaction 标志

`47-49`

1. `log.info("process")`
2. `needsCompaction = false`
3. 读取配置项 `experimental?.continue_loop_on_deny`

其中 `49` 的 `shouldBreak` 很关键：如果配置没有显式打开 `continue_loop_on_deny === true`，那么后面一旦出现权限拒绝或问题拒绝，processor 就会把本轮标记成 `blocked`，要求 loop 停下来。

### 2.2 外层 `while (true)` 表示同一轮内的重试循环

`50-55`

这一层 while 的作用有三点：

1. 调一次 `LLM.stream(streamInput)`。
2. 如果中途命中可重试错误，就 sleep 后重来。
3. 否则结束当前 `process()`。

所以 processor 自己内部有 retry 机制，但这个 retry 只发生在同一轮 assistant skeleton 之内。

---

## 3. `56-353` 的核心就是：按事件类型把流翻译成 durable part 更新

`packages/opencode/src/session/processor.ts:56-353`

`const stream = await LLM.stream(streamInput)` 之后，整个 processor 的主体就是：

1. `for await (const value of stream.fullStream)`
2. `switch (value.type)`
3. 按事件类型执行 `Session.updateMessage()` / `Session.updatePart()` / `Session.updatePartDelta()`

processor 充当“流事件到 durable writes 的翻译器”。

---

## 4. `start` 和 `reasoning-*` 事件：先把推理痕迹落成 reasoning parts

`packages/opencode/src/session/processor.ts:59-110`

### 4.1 `start` 事件只做一件事：把 session 状态重新设成 busy

`59-61`

这说明 processor 也会在开始消费流时再次声明 session 正在运行。

### 4.2 `reasoning-start`：创建 reasoning part

`63-80`

如果当前 `value.id` 还不在 `reasoningMap` 里：

1. 生成新的 `PartID.ascending()`。
2. 创建 `type: "reasoning"` 的 part。
3. `text` 初始为空字符串。
4. `time.start` 记当前时间。
5. `metadata` 记 provider 附带元信息。
6. 立刻 `Session.updatePart(reasoningPart)` 落盘。

reasoning part 会在开始事件到来时先写一个 durable 占位 part，随后接收 delta，并在结束时写回完整快照。

### 4.3 `reasoning-delta`：用 `updatePartDelta()` 追加文本

`82-95`

如果 `value.id` 对应的 reasoning part 已存在：

1. 先在内存里的 `part.text` 上拼接。
2. 再用 `Session.updatePartDelta(...)` 把 delta 写进存储。
3. 如果 provider metadata 有更新，也会覆盖 `part.metadata`。

这里能看出 processor 对流式输出的设计取向：对于大文本 delta，它偏向增量写入，而不是每次都整段 `updatePart()`。

### 4.4 `reasoning-end`：补齐结束时间，再做一次整段 update

`97-110`

结束时会：

1. `trimEnd()` 去掉尾部空白。
2. 补 `time.end`。
3. 如果 metadata 有更新，再覆盖一次。
4. 用 `Session.updatePart(part)` 写回最终版。
5. `delete reasoningMap[value.id]` 清掉这段 reasoning 的运行态。

所以 reasoning part 的完整生命周期是：`start -> delta* -> end`。

---

## 5. `tool-*` 事件：processor 在本轮 assistant 内维护一套 tool part 状态机

`packages/opencode/src/session/processor.ts:112-230`

这是 processor 最重的一组分支，因为工具调用既有 pending/running/completed/error 状态，又要防止 doom loop。

### 5.1 `tool-input-start`：先创建一个 pending tool part

`112-127`

这里会写下：

1. `type: "tool"`
2. `tool: value.toolName`
3. `callID: value.id`
4. `state.status: "pending"`
5. `state.input: {}`
6. `state.raw: ""`

然后把这个 part 放进 `toolcalls[value.id]`。

这说明 processor 在拿到 `tool-call` 之前，就已经为这次工具调用创建了 durable 占位。

### 5.2 `tool-input-delta` 和 `tool-input-end` 当前实现里被完全忽略

`129-133`

这两种事件都直接 `break`。结合前面的 `raw: ""` 可以看出，当前实现并不会把流式工具输入正文逐字持久化下来；tool input 的持久化主要依赖后面的 `tool-call` 事件一次性写入 `value.input`。

### 5.3 `tool-call`：把 pending 状态切成 running，并顺手做 doom loop 检测

`135-180`

先看状态迁移：

1. `136` 按 `value.toolCallId` 找到之前的 pending part。
2. `138-149` 用 `Session.updatePart(...)` 把它更新成：
   - `status: "running"`
   - `input: value.input`
   - `time.start = Date.now()`
   - `metadata = value.providerMetadata`
3. 再把新 part 回填进 `toolcalls` 映射。

然后看 doom loop 检测：

1. `152` 取当前 assistant message 的所有 parts。
2. `153` 只看最后 `DOOM_LOOP_THRESHOLD = 3` 个。
3. `155-164` 要求这 3 个 part 同时满足：
   - 都是 `tool`
   - 工具名相同
   - 状态不是 `pending`
   - `state.input` 完全一致
4. 满足后，`165-176` 会对 `"doom_loop"` 权限发起一次 `Permission.ask(...)`。

这段逻辑很细：

1. 它只检查“当前 assistant message 的最近 3 次相同工具调用”，而不是整个 session。
2. 该检测会触发一次权限询问，由上层策略或用户决定是否继续。

### 5.4 `tool-result`：把 running tool part 补成 completed

`181-203`

只要 `match.state.status === "running"`，就会更新为：

1. `status: "completed"`
2. `input` 沿用 `value.input` 或旧 `match.state.input`
3. `output / metadata / title / attachments` 全部取自工具返回值
4. `time.start` 沿用原来的开始时间
5. `time.end` 记当前时间

然后 `delete toolcalls[value.toolCallId]`，表示这次工具调用的运行态已经闭合。

### 5.5 `tool-error`：把 running tool part 补成 error，并决定是否 block

`205-230`

错误路径和成功路径对应：

1. `208-219` 把 tool part 更新成 `status: "error"`，并记录错误文本。
2. `221-226` 如果错误是 `Permission.RejectedError` 或 `Question.RejectedError`，就把 `blocked = shouldBreak`。
3. 最后同样 `delete toolcalls[value.toolCallId]`。

这里的关键点是：processor 不直接决定“权限被拒绝后一定停机”。它先看配置 `shouldBreak`，再决定是否把这一轮标成 block。

---

## 6. `start-step` / `finish-step`：step part、usage、patch、summary、overflow 检测都在这里落盘

`packages/opencode/src/session/processor.ts:234-289`

### 6.1 `start-step`：记录快照并落一个 `step-start` part

`234-243`

代码会：

1. `snapshot = await Snapshot.track()`
2. 立刻写一个 `type: "step-start"` 的 part
3. 把这次快照 ID 也挂在 part 上

这说明“本 step 开始时工作区是什么状态”是 processor 主动记录的，而不是事后反推。

### 6.2 `finish-step`：更新 assistant 主消息的 finish/cost/tokens

`245-264`

结束一个 step 时，processor 会：

1. `246-250` 用 `Session.getUsage(...)` 统一算 usage/cost。
2. `251` 把 `assistantMessage.finish = value.finishReason`。
3. `252` 用 `+=` 累加 cost。
4. `253` 直接把 `assistantMessage.tokens = usage.tokens`。
5. `254-263` 再写一条 `type: "step-finish"` part，里面带 `reason / snapshot / tokens / cost`。
6. `264` 用 `Session.updateMessage(input.assistantMessage)` 更新 assistant 主消息。

这里有一个容易忽略的代码级事实：

1. `cost` 是累加。
2. `tokens` 是直接覆盖。

至于这是不是“累计 token”，要看 `Session.getUsage(...)` 返回的 `usage.tokens` 本身是不是累计值；从这一段代码字面上看，processor 自己并不做 token 累加。

### 6.3 如果快照对应的 patch 非空，还会补一个 `patch` part

`265-278`

1. `266` 计算 `Snapshot.patch(snapshot)`。
2. `267-276` 如果 `patch.files.length` 非零，就补一条 `type: "patch"` 的 part。
3. `277` 再把 `snapshot = undefined`，表示这个 step 的快照闭合了。

因此 patch part 由 processor 在 step 结束时统一对比工作区差异后生成。

### 6.4 step 结束时还会旁路触发 session summary，并检查 overflow

`279-289`

1. `279-282` 调 `SessionSummary.summarize(...)`，总结的是当前 assistant 的父 user message。
2. `283-288` 如果当前 assistant 不是 summary，且 `SessionCompaction.isOverflow(...)` 为真，就把 `needsCompaction = true`。

当前轮只设置 `needsCompaction` 标志，后续分支切换由 loop 决定。

---

## 7. `text-*` 事件：assistant 正文同样是增量落成 text parts

`packages/opencode/src/session/processor.ts:291-341`

### 7.1 `text-start`：先建一个空文本 part

`291-304`

这里会：

1. 生成新的 `PartID`
2. 创建 `type: "text"`
3. `text` 初始为空字符串
4. `time.start` 记当前时间
5. 附上 provider metadata
6. 立刻 `Session.updatePart(currentText)`

和 reasoning part 一样，正文文本也是先创建 durable 占位，再吃 delta。

### 7.2 `text-delta`：用 `updatePartDelta()` 追加正文

`306-318`

1. 先把 `value.text` 追加到 `currentText.text`
2. 再用 `Session.updatePartDelta(...)` 把增量写进去
3. 若 metadata 有更新，覆盖本地对象

这使得前端或订阅方可以实时看到 assistant 文本增长。

### 7.3 `text-end`：先走插件，再写最终文本

`320-341`

结束时 processor 会：

1. `322` 先 `trimEnd()`。
2. `323-331` 触发 `experimental.text.complete`，让插件有机会改写最终文本。
3. `332` 把插件返回的文本重新塞回 `currentText.text`。
4. `333-338` 更新 `time`、`metadata`，再 `Session.updatePart(currentText)`。
5. `340` 把 `currentText = undefined`。

这里有一个很细的实现特征：

`333-336` 把 `currentText.time` 重设成新的 `{ start: Date.now(), end: Date.now() }`。从代码字面看，最终 text part 保存的是收尾时间，而非完整的流式开始到结束时长。

---

## 8. 还有三种看起来小、但决定控制流的事件

`packages/opencode/src/session/processor.ts:343-353`

### 8.1 `finish` 事件当前不直接做任何写盘

`343-344`

这里直接 `break`。对 processor 来说，携带 finish reason、usage、cost 的关键事件是 `finish-step`，`finish` 事件本身不承担这部分写回。

### 8.2 未识别事件会记日志，但不会中断

`346-350`

processor 会把未知事件打到日志里，然后继续吃流。

### 8.3 只要 `needsCompaction` 被置真，就会提前跳出事件循环

`352`

一旦 step 结束时发现上下文已经接近极限，processor 会尽快把控制权交回 loop，由 loop 决定是否创建 compaction task。

---

## 9. `catch` 分支处理 retry、overflow 与 fatal error

`packages/opencode/src/session/processor.ts:354-387`

### 9.1 所有异常都会先转成 `MessageV2` 错误对象

`354-360`

processor 遇到异常后，会先统一走：

`const error = MessageV2.fromError(e, { providerID: input.model.providerID })`

这样后面无论是 API 错误、鉴权错误还是上下文溢出，都能统一进同一套消息 schema。

### 9.2 上下文溢出不会直接把 assistant 标成 fatal，而是请求 compaction

`360-366`

如果错误是 `ContextOverflowError`：

1. `needsCompaction = true`
2. 通过 `Bus.publish(Session.Event.Error, ...)` 广播错误事件

这里不会直接 `input.assistantMessage.error = ...` 然后返回 stop，因为 overflow 还有机会通过 compaction 自愈。

### 9.3 其它可重试错误会进入 retry 状态并 sleep

`367-379`

1. `SessionRetry.retryable(error)` 判断要不要重试。
2. `attempt++`
3. `SessionRetry.delay(...)` 算退避时间。
4. `SessionStatus.set(... type: "retry" ...)` 把状态切成 retry。
5. `SessionRetry.sleep(delay, input.abort)` 等待。
6. `continue` 回到外层 while，再重开一次 `LLM.stream(...)`。

这说明 retry 完全封装在 processor 内部，外层 loop 看不到这些中间尝试。

### 9.4 非重试错误会写进 assistant 主消息

`380-386`

当错误既不是 overflow，也不是 retryable 时，processor 会：

1. `input.assistantMessage.error = error`
2. 广播 `Session.Event.Error`
3. `SessionStatus.set(input.sessionID, { type: "idle" })`

fatal error 会直接写进当前 assistant skeleton。

---

## 10. 无论成功还是失败，processor 退出前都会做一轮统一清理

`packages/opencode/src/session/processor.ts:388-420`

### 10.1 如果还有挂着的快照，会在退出前补一次 patch

`388-401`

这段和 `finish-step` 里的 patch 逻辑类似，但它承担的是兜底责任：即便中途异常了，只要 `snapshot` 还没被清掉，也要尽量把 patch 写出来。

### 10.2 所有未完成的 tool part 都会被强制改成 error

`402-418`

processor 会重新把当前 assistant 的 parts 全读一遍：

1. 找出所有 `type === "tool"` 且状态既不是 `completed` 也不是 `error` 的 part。
2. 统一改成：
   - `status: "error"`
   - `error: "Tool execution aborted"`
   - `time.start/end` 记当前时间

这一步保证了 durable history 里不会留下悬空的 `pending/running` tool part。

### 10.3 assistant 主消息一定会被补完成时间并写回

`419-420`

无论前面发生了什么，退出前都会：

1. `input.assistantMessage.time.completed = Date.now()`
2. `Session.updateMessage(input.assistantMessage)`

所以 assistant skeleton 最终一定会收口成一条完整 durable message，只是它可能带 error，或者 finish reason 还没有成功值。

---

## 11. `421-424` 返回的是给 loop 的调度信号

`packages/opencode/src/session/processor.ts:421-424`

processor 最后只会返回三种值：

1. `needsCompaction` 为真，返回 `"compact"`
2. `blocked` 为真，或者 `assistantMessage.error` 已存在，返回 `"stop"`
3. 否则返回 `"continue"`

这里最关键的一点是：

1. assistant 文本、reasoning、tool output、patch、finish、error 都已经在前面落盘了。
2. 返回值本身只负责告诉外层 loop：“这一轮写完之后，session 下一步应该停、继续，还是转去 compaction。”

processor 的返回值承担控制信号角色。

---

## 12. 回到代码行，`SessionProcessor.process()` 实现了什么

把整段 `46-424` 串起来，processor 实现的是下面这套单轮运行时：

1. 调用 `LLM.stream()`，消费一轮模型事件流。
2. 把 reasoning、text、tool、step、patch 全部翻译成 durable parts。
3. 在工具调用层维护 pending/running/completed/error 状态机。
4. 对连续重复工具调用做 doom loop 检测。
5. 在 step 结束时记录 usage、cost、snapshot patch，并检查 overflow。
6. 对可重试错误做退避重试，对致命错误写回 assistant.error。
7. 退出前清掉未闭合工具状态，补齐 assistant 完成时间。
8. 最终只返回 `"continue" / "compact" / "stop"` 给 loop。

因此，processor 承担“单轮流事件 durable writer”的职责。`loop()` 与 `processor` 分层后，session 级调度和单轮事件写回各自独立。
