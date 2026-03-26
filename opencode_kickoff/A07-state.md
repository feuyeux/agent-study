# OpenCode 源码深度解析 A07：模型流返回后，message/part 怎样写回 Durable State 并被重新读出

> 本文基于 `opencode` `v1.3.2`（tag `v1.3.2`，commit `0dcdf5f529dced23d8452c9aa5f166abb24d8f7c`）源码校对

A06 解决了“请求怎样发出去”，A07 解决的是更关键的问题：模型流回来以后，OpenCode 怎样把它拆成 durable parts，怎样保证“先写库、再发事件”，以及前端/下一轮 loop 又怎样把这些历史重新投影回去。

---

## 1. Durable 写回真正只有三组 API

写回核心不在 `processor.ts`，而在 `packages/opencode/src/session/index.ts`：

| API | 代码坐标 | 做什么 |
| --- | --- | --- |
| `Session.updateMessage()` | `session/index.ts:686-706` | upsert 一条 message 头，并发布 `message.updated`。 |
| `Session.updatePart()` | `session/index.ts:755-776` | upsert 一条完整 part，并发布 `message.part.updated`。 |
| `Session.updatePartDelta()` | `session/index.ts:778-789` | **不落库**，只发布增量事件。 |

再往下一层，是 `Database.use()` / `Database.effect()`：

1. `Database.use()` 在当前 DB 上下文里执行写操作，见 `storage/db.ts:126-138`
2. `Database.effect()` 把事件推迟到 DB 写操作之后再执行，见 `140-146`

这条顺序非常关键：**先写 durable state，再通过 Bus 对外广播。**

---

## 2. `processor` 如何把模型流拆成 part

`packages/opencode/src/session/processor.ts:56-351` 是真正的事件分发器。在 `v1.3.2` 中，最重要的事件分类如下。

### 2.1 reasoning 事件

1. `reasoning-start`：创建空的 `reasoning` part，见 `63-80`
2. `reasoning-delta`：更新内存对象并发 `updatePartDelta(text)`，见 `82-95`
3. `reasoning-end`：补 `time.end`，再 `updatePart()`，见 `97-110`

因此 reasoning 既有实时增量，也有最终落盘快照。

### 2.2 text 事件

1. `text-start`：创建空 `text` part，见 `291-304`
2. `text-delta`：只发 delta 事件，见 `306-318`
3. `text-end`：跑 `experimental.text.complete` plugin hook，补齐最终文本和时间，再 `updatePart()`，见 `320-341`

OpenCode 的文本输出不是按 token 永久存库，而是“delta 只走事件，最终文本走 part snapshot”。

### 2.3 tool 事件

1. `tool-input-start`：创建 `pending` tool part，见 `112-127`
2. `tool-call`：把 tool part 切到 `running`，写入结构化输入，见 `135-180`
3. `tool-result`：切到 `completed`，写 output/title/metadata/attachments，见 `181-203`
4. `tool-error`：切到 `error`，见 `205-230`

也就是说，tool 在 durable history 里是显式状态机，不是一段文本描述。

### 2.4 step 事件

1. `start-step`：`Snapshot.track()`，并写 `step-start` part，见 `234-243`
2. `finish-step`：计算 usage/cost，更新 assistant message，写 `step-finish` 和可能的 `patch` part，见 `245-289`

step 事件是 OpenCode 把“每轮推理边界”和“文件系统快照边界”连接起来的地方。

---

## 3. `doom loop` 检测是怎么做的

`tool-call` 分支里，`152-177` 会读取当前 assistant message 已有的 parts，取最后三个。如果连续三次出现：

1. 同一个 tool
2. 相同输入
3. 状态都已经不是 pending

就触发 `Permission.ask({ permission: "doom_loop", ... })`。

这说明 doom loop 不是靠模型自觉停止，而是 runtime 对 tool-call 序列做模式检测，然后把“是否继续”升级成权限问题。

---

## 4. `finish-step` 才是 assistant message 真正定型的时刻

`finish-step` 事件处理里，`245-289` 做了五件事：

1. `Session.getUsage(...)` 计算 tokens 和 cost
2. 写回 `assistantMessage.finish`
3. 写回 `assistantMessage.cost` / `tokens`
4. 写一条 `step-finish` part
5. 若 `Snapshot.patch(snapshot)` 发现文件变化，再写一条 `patch` part

然后才触发：

1. `SessionSummary.summarize(...)`
2. overflow 检测，必要时置 `needsCompaction = true`

因此 assistant message 的“完成态”不是 text-end，而是 finish-step。

---

## 5. 错误、重试与状态迁移

### 5.1 错误先被统一映射成 `MessageV2` 错误对象

`processor.ts:354-386` 捕获异常后，会用 `MessageV2.fromError(...)` 转换成：

1. `AbortedError`
2. `AuthError`
3. `ContextOverflowError`
4. `APIError`
5. `StructuredOutputError`
6. `NamedError.Unknown`

### 5.2 可重试错误会进入 `SessionStatus.retry`

如果 `SessionRetry.retryable(error)` 有结果：

1. `attempt++`
2. `SessionRetry.delay(...)` 算出下一次重试时间
3. `SessionStatus.set(sessionID, { type: "retry", ... })`
4. `SessionRetry.sleep(delay, abort)`

不满足重试条件时，才把错误写进 assistant message 并停机。

### 5.3 `idle` / `busy` / `retry` 是独立于消息历史的临时状态

`packages/opencode/src/session/status.ts:9-99` 维护的是 instance-local 状态：

1. `busy`
2. `retry`
3. `idle`

它们通过 `session.status` 事件广播，但不写进 message/part history。这是 OpenCode 少数明确不 durable 的 runtime 状态。

---

## 6. `updatePartDelta()` 为什么不落库

这是一个经常会被误解的设计点。

`session/index.ts:778-789` 的 `updatePartDelta()` 只调用：

```ts
Bus.publish(MessageV2.Event.PartDelta, input)
```

没有任何数据库写操作。

它的语义是：

1. 给正在订阅的 CLI/TUI/Web 一个实时增量流
2. 最终一致性依赖后续 `updatePart()` 的完整 part snapshot

所以 OpenCode 当前的 durable 模型并不是“token 级落库”，而是“token 级事件 + part 级快照”。

---

## 7. 写完以后，历史怎样被重新读出来

`packages/opencode/src/session/message-v2.ts` 负责 replay/projection。

### 7.1 数据库回放

1. `page()`：`794-836`，按 cursor 分页读取 message
2. `hydrate()`：`533-557`，把 message rows 和 part rows 组装成 `WithParts`
3. `stream()`：`838-850`，不断翻页并按“最新到最旧”顺序回放

### 7.2 compacted history 过滤

`filterCompacted()` 在 `882-898` 会在遇到 summary assistant 后折叠更老的一段历史，保证 loop 和 UI 不会无限带着旧上下文。

### 7.3 模型投影

`toModelMessages()` 在 `559-792` 会把 durable `MessageV2.WithParts[]` 转成 AI SDK `ModelMessage[]`：

1. user text/file/compaction/subtask -> user message
2. assistant text/reasoning/tool result/tool error -> assistant message
3. 对不支持 media-in-tool-result 的 provider，额外注入 user file message

这意味着同一份 durable history 同时支撑了：

1. 下一轮 loop 的推理上下文
2. HTTP `/session/:id/message` 的历史查询
3. CLI/TUI/Web 的历史回放

---

## 8. 事件如何从 DB 写回传播到前端

事件链路是：

1. `Session.updateMessage()` / `updatePart()` 在 `Database.effect()` 里触发 `Bus.publish(...)`
2. `Bus.publish()` 会：
   - 通知当前 `Instance` 的本地订阅者
   - 同时转发到 `GlobalBus`
3. `/event` 把 `Bus.subscribeAll()` 转成 SSE，见 `server/routes/event.ts:13-84`
4. `/global/event` 把 `GlobalBus` 转成 SSE，见 `server/routes/global.ts:43-124`

因此前端实时看到的不是“processor 直接推 token”，而是“durable write 完成后的事件投影”。

---

## 9. 为什么 A07 是整条主线最关键的一环

如果没有这一层，OpenCode 就会退化成“模型流 + UI 临时状态”。而当前实现之所以能支持：

1. session 恢复
2. fork
3. revert
4. compaction
5. 多端订阅
6. diff/summary

靠的都是同一个原则：

> 先把执行过程写成 durable message/part history，再让 UI、下一轮 loop 和外部 API 去消费这份 history。

A07 讲清楚之后，A 线主流程就闭合了。接下来再看 B 线，才能把这条主线背后的对象模型、基础设施和设计哲学补齐。
