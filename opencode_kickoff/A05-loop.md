# OpenCode 源码深度解析 A05：沿着 `loop()` 看 session 级分支怎样展开

> 本文基于 `opencode` `v1.3.2`（tag `v1.3.2`，commit `0dcdf5f529dced23d8452c9aa5f166abb24d8f7c`）源码校对

A04 讲清了 `loop()` 的职责边界，这一篇继续往里钻：OpenCode 当前的 session 调度器到底怎样从 durable history 里推导出下一轮动作，又怎样把 subtask、compaction、overflow 和普通推理串在同一条循环里。

---

## 1. `loop()` 的总框架

`packages/opencode/src/session/prompt.ts:278-756` 可以粗分成 6 段：

1. 占用/恢复 session 运行态，见 `281-289`。
2. 每轮回放历史、求 `lastUser` / `lastAssistant` / `lastFinished` / `tasks`，见 `296-319`。
3. subtask 分支，见 `356-539`。
4. compaction 分支，见 `542-553`。
5. overflow 检测与普通推理分支，见 `556-744`。
6. 收尾：prune、返回最新 assistant、唤醒排队调用者，见 `746-755`。

这说明 `loop()` 不是大一统 if/else 杂糅，而是稳定的“扫描历史 -> 选择分支 -> 执行 -> 再扫描历史”结构。

---

## 2. 每轮开始时，`loop()` 真正关心的是哪些状态

`302-319` 会先读取：

1. `msgs = await MessageV2.filterCompacted(MessageV2.stream(sessionID))`
2. 从最新往前找：
   - 最近一条 user message：`lastUser`
   - 最近一条 assistant message：`lastAssistant`
   - 最近一条已完成 assistant：`lastFinished`
   - 未完成尾段里的 `subtask`/`compaction` part：`tasks`

这里有两个关键事实：

### 2.1 `loop()` 的状态来源是当前 durable history

不是某个内存 conversation，也不是某个“上轮返回对象”。

### 2.2 `tasks` 不是单独建表管理的队列

subtask 和 compaction 都是 message parts，本轮是否有待处理任务，是从 history 尾段扫出来的。

这也是为什么 OpenCode 可以在崩溃恢复后继续处理未完成编排任务。

---

## 3. 退出条件其实很严格

`321-329` 会先做两类退出判断：

1. 没有 `lastUser` 直接报错，这说明 session history 非法。
2. 如果最近 assistant 已完成，且 finish reason 不是 `"tool-calls"` 或 `"unknown"`，并且它在最近 user 之后，那么 loop 直接结束。

翻译成运行语义就是：

1. 如果最新一轮已经是一个真正完成的 assistant answer，就不要再继续跑。
2. 只有工具调用未闭合、状态未知、或者中途插入了新的 user message，才需要继续 loop。

---

## 4. 第一个 side job：标题生成不会阻塞主线

`331-339` 在第一轮会调用 `ensureTitle(...)`，但这里没有 `await`。

这代表标题生成是一个**异步旁路任务**：

1. 只在 root session 且标题还是默认标题时才尝试。
2. 使用隐藏的 `title` agent 和小模型。
3. 不影响主 loop 的继续执行。

这是个很典型的实现细节：OpenCode 会把“跟主任务有关但不应阻塞主线”的工作做成 side job，而不是塞回模型主轮次。

---

## 5. 分支一：pending subtask 不是“模型下一轮自己处理”，而是先执行 `TaskTool`

如果 `task?.type === "subtask"`，`356-539` 会进入专门分支。

### 5.1 先落一个 assistant message + running tool part

代码会：

1. 插入 assistant message，`359-383`
2. 插入 `tool: "task"` 的 running part，`384-403`

这一步很重要，因为 subtask 执行不是 invisible side effect，而是被编码成父 session 中一条可订阅、可回放的 tool history。

### 5.2 再真正执行 `TaskTool.execute()`

`404-467` 组出 task 工具参数和 `Tool.Context`：

1. `metadata()` 可回写 tool part 的标题/元数据。
2. `ask()` 会合并 subagent 权限与 session 权限。
3. `messages` 带着当前历史给工具。

然后真正调 `taskTool.execute(taskArgs, taskCtx)`。

### 5.3 执行结果会写回 completed/error tool state

执行成功时：

1. assistant message `finish = "tool-calls"`，见 `468-470`
2. tool part 更新为 `completed`，带 `title` / `metadata` / `output` / `attachments`，见 `471-487`

执行失败时：

1. tool part 更新为 `error`，见 `488-501`

### 5.4 command 触发的 subtask 还会补一条 synthetic user turn

如果这个 subtask 来自 command，`504-527` 会额外写一条 synthetic user message：

> “Summarize the task tool output above and continue with your task.”

这不是多余包装，而是为了给某些推理模型补齐用户轮次边界，避免中途 reasoning/tool 状态不匹配。

所以 subtask 分支的真实语义是：**先把 pending subtask 清空，再让 session 回到正常 loop。**

---

## 6. 分支二：compaction 任务会被优先消费

如果 `task?.type === "compaction"`，`542-553` 会直接调用：

```ts
SessionCompaction.process({
  messages: msgs,
  parentID: lastUser.id,
  abort,
  sessionID,
  auto: task.auto,
  overflow: task.overflow,
})
```

返回值如果是 `"stop"`，整个 loop 停止；否则继续下一轮。

这说明 compaction 不是“普通模型工具调用的一部分”，而是 loop 级别的专门分支。只有把 compaction 先跑完，正常推理才会恢复。

---

## 7. 分支三：overflow 自愈不是立刻报错，而是插入 compaction 任务

`556-568` 会在最近一条已完成 assistant 上做 overflow 检测：

1. 最近 assistant 不是 summary。
2. `SessionCompaction.isOverflow({ tokens, model })` 返回 true。

满足后，它不会立即终止，而是：

1. `SessionCompaction.create(...)` 插入一条新的 user message。
2. 这条 user message 只有一个 `compaction` part。
3. 下一轮 loop 就会命中上面的 compaction 分支。

换句话说，overflow 在 OpenCode 里是一种**编排状态迁移**，不是简单的错误返回。

---

## 8. 普通推理分支真正做了什么

当没有 pending subtask/compaction，且没有触发 overflow 时，才进入 `571-744` 的 normal processing。

### 8.1 先决定 agent 和步数边界

1. `Agent.get(lastUser.agent)` 拿到这轮 agent。
2. `agent.steps ?? Infinity` 变成 `maxSteps`。
3. `step >= maxSteps` 时，后面会附加 `MAX_STEPS` 提示。

### 8.2 再插入 reminder 和 assistant skeleton

`585-589` 的 `insertReminders()` 会根据 plan/build 模式补 synthetic reminder；之后 `591-620` 会先落 assistant skeleton message。

这意味着普通推理轮次的 assistant 头信息始终先 durable，再开始流式生成。

### 8.3 tool set 是每轮重新解析的

`627-635` 调 `resolveTools(...)`，它会根据：

1. 当前 agent
2. 当前 session permission
3. 当前 model
4. 历史消息

重新生成 AI SDK 的 tool set，而不是重用上轮实例。

### 8.4 结构化输出是通过注入额外工具实现的

若 `lastUser.format.type === "json_schema"`，`637-645` 会临时注入 `StructuredOutput` 工具，并把 `toolChoice` 设成 `"required"`。

所以 OpenCode 的结构化输出不是特判一个 provider API，而是把“最终答案必须走工具”编译成统一工具流。

### 8.5 queued user message 会被临时包上 system-reminder

`655-668` 会把上一条已完成 assistant 之后、尚未处理的 user text 包成：

```text
<system-reminder>
The user sent the following message:
...
</system-reminder>
```

这个修改只发生在本轮内存里的 `msgs` 上，不会回写数据库。它的作用是提醒模型不要忘记处理中途插入的新用户消息。

### 8.6 最后才真正调用 `processor.process(...)`

`687-708` 组出：

1. `user`
2. `agent`
3. `permission`
4. `system`
5. `messages`
6. `tools`
7. `model`
8. `toolChoice`

然后交给 `SessionProcessor.process(...)`。

---

## 9. `processor` 返回后，`loop()` 还要再做一次状态迁移

`710-744` 在普通推理分支里还要处理三类结果：

### 9.1 Structured output 成功，直接结束

如果 `structuredOutput !== undefined`：

1. 把结果写到 `processor.message.structured`
2. 若没有 finish reason，则补成 `"stop"`
3. 更新 assistant message，随后 `break`

### 9.2 模型停下来了，但没按 JSON schema 产出工具结果

如果 `format.type === "json_schema"` 且模型没有调用 `StructuredOutput`，就构造 `StructuredOutputError`，更新 message 后停止。

### 9.3 `processor` 请求 compaction

如果返回 `"compact"`，则插入 compaction user message，`overflow` 标记取 `!processor.message.finish`。这表示：

1. 若模型压根没正常 finish 就爆了，是“硬溢出”。
2. 若有 finish 但上下文已逼近上限，则是“软溢出”。

---

## 10. `loop()` 的收尾同样是 durable 导向

循环结束后，`746-755` 还会做两件事：

1. 调 `SessionCompaction.prune({ sessionID })`，尝试压缩旧 tool result。
2. 重新 `MessageV2.stream(sessionID)`，取最新 assistant 作为最终返回值，并把等待中的 callbacks 一并 resolve。

注意这里的返回值不是某个局部变量，而是**重新从 durable history 中读出的最新 assistant message**。这再次说明 OpenCode 的主线并不信任内存中那份执行对象，而是信任已经落盘的历史。
