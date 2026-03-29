# OpenCode 源码深度解析 A07：`LLM.stream()` 返回后，Durable State 如何写入、传播与再投影

> 本文基于 `opencode` `v1.3.2`（tag `v1.3.2`，commit `0dcdf5f529dced23d8452c9aa5f166abb24d8f7c`）源码校对
> 核心代码：`packages/opencode/src/session/processor.ts`、`session/index.ts`、`session/message-v2.ts`

A06 已经说明请求如何进入 `streamText()`。A07 接着说明返回流如何在 `SessionProcessor.process()` 中被消费，如何经由 `Session.updateMessage()`、`Session.updatePart()`、`Session.updatePartDelta()` 进入 durable state，如何通过 `Bus` 与 SSE 发给前端，以及如何通过 `MessageV2.*` 重新投影给 `loop()` 和下一轮模型调用。

---

## 1. A07 覆盖的主线范围

从代码链路看，A07 负责下面这条后半程：

```ts
const stream = await LLM.stream(streamInput)

for await (const event of stream.fullStream) {
  Session.updatePart(...)
  Session.updatePartDelta(...)
  Session.updateMessage(...)
}

Bus.publish(...)
SSE 推送
MessageV2.stream()
MessageV2.toModelMessages()
```

这条链回答四个问题：

1. `LLM.stream()` 返回的事件流怎样变成 message/part 写操作。
2. 哪些内容会进入 SQLite，哪些内容只作为实时事件广播。
3. durable 写入完成后，前端怎样收到更新。
4. 下一轮 `loop()` 怎样重新读取这份 history。

---

## 2. Durable 写入口集中在 `Session.update*`

`packages/opencode/src/session/index.ts:686-789`

这一层是整条后半程的核心，因为 processor 只是事件分发器，写 durable state 的入口只有三组 API。

| API | 代码坐标 | 语义 |
| --- | --- | --- |
| `Session.updateMessage()` | `session/index.ts:686-706` | upsert 一条 message 头信息 |
| `Session.updatePart()` | `session/index.ts:755-776` | upsert 一条完整 part 快照 |
| `Session.updatePartDelta()` | `session/index.ts:778-789` | 发布 part 增量事件 |

### 2.1 `updateMessage()` 写入 message 头

`686-706`

这里的执行顺序很清晰：

1. `687-688` 拆出 `id`、`sessionID` 和 `data`。
2. `689-698` 把 message upsert 到 `MessageTable`。
3. `699-703` 通过 `Database.effect()` 延迟发布 `MessageV2.Event.Updated`。

因此，message 级 durable 真相源位于 `MessageTable`。

### 2.2 `updatePart()` 写入 part 最终快照

`755-776`

这条路径与 `updateMessage()` 对称：

1. `756-757` 拆出 `id/messageID/sessionID/data`。
2. `758-768` 把 part upsert 到 `PartTable`。
3. `769-773` 延迟发布 `MessageV2.Event.PartUpdated`。

`PartTable` 保存的是 part 的最终快照。这也是 UI 与后续 replay 的稳定依据。

### 2.3 `updatePartDelta()` 负责实时增量广播

`778-789`

这一段没有数据库写操作，只有：

1. `787` 发布 `MessageV2.Event.PartDelta`

这意味着：

1. `reasoning-delta` 与 `text-delta` 主要承担实时渲染职责。
2. 最终 durable 状态仍由 `updatePart()` 写入的完整快照承担。

OpenCode 当前采用的是“增量事件 + 最终快照”的组合模型。

---

## 3. `Database.effect()` 保证了“先写库，再发事件”

`packages/opencode/src/storage/db.ts:126-146`

这条执行顺序需要单独说明，因为它决定了 Bus 事件与 durable state 的先后关系。

### 3.1 `Database.use()` 会收集副作用并延后执行

`126-138`

当当前调用栈没有 DB 上下文时：

1. `131` 新建 `effects` 数组。
2. `132` 执行业务回调。
3. `133` 在回调结束后依次执行收集到的 `effects`。

这意味着 `updateMessage()` 与 `updatePart()` 中登记的 `Database.effect(...)`，会在 insert/upsert 完成后运行。

### 3.2 `Database.effect()` 负责登记延迟执行的副作用

`140-146`

1. 有 DB 上下文时，把副作用函数压入 `effects`。
2. 没有 DB 上下文时，直接执行。

在 session 写路径中，`Database.effect()` 承担的语义非常稳定：

1. 先完成 durable write
2. 再发布 Bus 事件

因此，前端和其他订阅方收到的事件，始终对应一份已经写入数据库的状态。

---

## 4. `processor` 用这三组 API 把流事件翻译成 durable state

`packages/opencode/src/session/processor.ts:56-420`

A05 已经详细解释了 processor 内部的事件分类。A07 重点关注“这些事件怎样进入 durable write path”。

### 4.1 reasoning 与 text 采用“占位 part + delta + 最终快照”模式

对应代码：

1. `reasoning-start` -> `Session.updatePart(...)`，见 `63-80`
2. `reasoning-delta` -> `Session.updatePartDelta(...)`，见 `82-95`
3. `reasoning-end` -> `Session.updatePart(...)`，见 `97-110`
4. `text-start` -> `Session.updatePart(...)`，见 `291-304`
5. `text-delta` -> `Session.updatePartDelta(...)`，见 `306-318`
6. `text-end` -> `Session.updatePart(...)`，见 `320-341`

这组事件形成了固定模式：

1. 先创建一个 durable 占位 part。
2. 中间增量通过 `PartDelta` 事件持续广播。
3. 结束时写回完整快照。

### 4.2 tool part 形成显式状态机

对应代码：

1. `tool-input-start` -> `pending`，见 `112-127`
2. `tool-call` -> `running`，见 `135-180`
3. `tool-result` -> `completed`，见 `181-203`
4. `tool-error` -> `error`，见 `205-230`

因此，tool 执行轨迹会在 durable history 中表现为一条完整状态机。

### 4.3 `finish-step` 决定 assistant message 的完成态

`245-289`

这一段决定了 assistant 主消息何时定型：

1. `246-250` 计算 usage 与 cost。
2. `251-253` 更新 `assistantMessage.finish`、`cost`、`tokens`。
3. `254-263` 写入 `step-finish` part。
4. `265-278` 根据 snapshot patch 追加 `patch` part。
5. `264` 用 `Session.updateMessage(...)` 把主消息状态写回。

因此，assistant message 的 durable 完成态落在 `finish-step` 这一组写操作上。

### 4.4 退出前的清理会收口未完成状态

`388-420`

即便中途出现异常，processor 仍会：

1. 尝试补一次 `patch`，见 `388-401`
2. 把所有未完成 tool part 改成 `error: "Tool execution aborted"`，见 `402-418`
3. 给 assistant message 补 `time.completed`，见 `419-420`

这样可以确保 durable history 中不会留下悬空的 running tool part。

---

## 5. `SessionStatus` 属于运行态，不进入 durable history

`packages/opencode/src/session/status.ts:9-99`

message 与 part history 承担 durable 会话记录；`SessionStatus` 负责 instance-local 运行态。

### 5.1 `SessionStatus.Info` 只有三种值

`10-24`

1. `idle`
2. `retry`
3. `busy`

### 5.2 状态保存在内存 `Map` 中

`55-83`

`58-60` 使用 `InstanceState.make(...)` 构建的是 `Map<SessionID, Info>`。这张表不进入 `MessageTable` 与 `PartTable`。

### 5.3 `set()` 会广播事件，并在 `idle` 时删除内存项

`71-80`

1. `73` 发布 `session.status`
2. `74-77` 处理 `idle`，同时发布兼容事件 `session.idle`
3. 其余状态写入 `Map`

这套状态适合表达当前实例的运行情况，不承担会话历史恢复职责。

---

## 6. Durable 写入完成后，事件怎样传播到前端

这一段连接 durable write 与外部可见效果。

### 6.1 `Bus.publish()` 同时通知本地订阅者和全局总线

`packages/opencode/src/bus/index.ts:41-64`

执行过程分成三步：

1. `45-48` 组出统一的 `{ type, properties }` payload
2. `53-58` 通知当前实例的精确订阅者和 `*` 订阅者
3. `59-62` 用 `GlobalBus.emit("event", ...)` 把事件转发给全局总线

这条链保证了当前实例和全局视角都能收到更新。

### 6.2 `/event` 把当前实例的 Bus 暴露成 SSE

`packages/opencode/src/server/routes/event.ts:13-84`

关键路径是：

1. `35-36` 用 `streamSSE` 与 `AsyncQueue` 建立事件流
2. `56-61` 通过 `Bus.subscribeAll(...)` 订阅当前实例所有事件
3. `77` 把事件写成 SSE

CLI/TUI/Web 在当前实例里看到的 message/part 更新，来自这条 SSE 通道。

### 6.3 `/global/event` 暴露跨实例 SSE

`packages/opencode/src/server/routes/global.ts:43-124`

这一层改为监听 `GlobalBus`：

1. `98-101` 注册 `GlobalBus` 事件处理器
2. 事件负载额外携带 `directory`

全局视角可以据此同时观测多个实例。

---

## 7. durable rows 怎样重新读成 runtime 可消费对象

`packages/opencode/src/session/message-v2.ts:533-898`

写入完成后，系统还要把这些 rows 重新组织成 `WithParts`、历史流与模型上下文。

### 7.1 `hydrate()` 把 message rows 与 part rows 组装成 `WithParts`

`533-557`

这一段的步骤很稳定：

1. `534` 收集 message IDs
2. `537-544` 批量查询 part rows
3. `545-550` 依据 `message_id` 分组
4. `553-556` 组装成 `{ info, parts }`

运行时广泛使用的 `MessageV2.WithParts`，就是由这一步得到的投影对象。

### 7.2 `page()` 与 `stream()` 负责回放 history

`794-850`

1. `805-813` `page()` 按 `time_created desc, id desc` 读取最新消息
2. `827-828` 反转当前页顺序
3. `838-849` `stream()` 再按“新到旧”持续 `yield`

`MessageV2.stream(sessionID)` 因此会按“新到旧”产出消息。这也是 `loop()` 收尾时能直接取到最新 assistant message 的原因。

### 7.3 `filterCompacted()` 负责压缩历史视图

`882-898`

这一段会：

1. 跟踪已经被 summary 覆盖的 user turn
2. 遇到对应 compaction user message 后停止向更老历史继续扩展
3. 最后返回“旧到新”的活动历史数组

loop 与 UI 平常看到的是这份经过 compaction 处理后的活动历史。

---

## 8. 同一份 durable history 还要重新投影回模型上下文

`packages/opencode/src/session/message-v2.ts:559-792`

这一步把 A07 再次接回 A06。

### 8.1 `toModelMessages()` 把 durable `WithParts[]` 转成 AI SDK `ModelMessage[]`

用户消息部分：

1. `623-666` 把 `text`、非文本 `file`、`compaction`、`subtask` 重新翻译成 user message
2. 文本文件和目录在 prompt 阶段已经展开，这里只保留应当再次进入模型的内容

assistant 消息部分：

1. `681-759` 把 `text`、`reasoning`、`tool` 投影成 assistant message parts
2. `697-748` 根据 tool part 状态生成不同类型的 tool output
3. `760-778` 某些 provider 不支持 tool result 中的媒体内容时，会追加一条 synthetic user message 承接媒体附件

### 8.2 同一份 durable history 支撑三条消费链

1. loop 的下一轮推理上下文
2. SSE 历史与实时投影
3. HTTP 查询与分页回放

OpenCode 围绕这份 durable message/part history 组织运行时，不同消费侧再按各自需求生成投影。

---

## 9. A06 与 A07 在这里闭环

把 A06 与 A07 连起来看，主线非常完整：

1. A06 说明请求如何进入 `streamText()`
2. A07 说明返回流如何写入 durable state
3. 同一份 durable state 又会被 SSE、`loop()` 和 `toModelMessages()` 重新消费

这条闭环支撑了 OpenCode 的恢复、fork、compaction、多端订阅与历史重放。A 系列到这里完成了从入口、路由、输入编译、编排、模型请求到 durable state 投影的完整主线。
