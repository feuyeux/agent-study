# OpenCode 源码深度解析 A07：第 5 步：模型流返回后，message/part 怎样写回 Durable State 并被重新读出

A07 不是和 A06 并列的另一个话题，而是它的后半段。A06 讲的是 `processor()` 如何进入 `LLM.stream()` 发起模型调用；A07 讲的是模型流返回后，`processor()` 怎样通过 `Session.updatePart()`、`Session.updatePartDelta()`、`Session.updateMessage()` 把结果写回 durable history，并通过 bus 与分页读取重新投影出来。

## 一、代码坐标

| 主题 | 文件与代码行 | 细节 |
| --- | --- | --- |
| DB 路径与 PRAGMA | `packages/opencode/src/storage/db.ts:29-40`, `81-109` | `opencode.db` 路径、WAL、`busy_timeout`、`cache_size` 等都在这里。 |
| `Database.use/effect/transaction` | `packages/opencode/src/storage/db.ts:126-162` | effect 队列和事务提交后的副作用执行顺序。 |
| `Session.updateMessage()` | `packages/opencode/src/session/index.ts:686-706` | `MessageTable` upsert 后发布 `message.updated`。 |
| `Session.updatePart()` | `packages/opencode/src/session/index.ts:755-776` | `PartTable` upsert 后发布 `message.part.updated`。 |
| `Session.updatePartDelta()` | `packages/opencode/src/session/index.ts:778-788` | 纯 bus delta 事件，不回写数据库。 |
| `Bus.publish()` | `packages/opencode/src/bus/index.ts:41-64` | 触发 instance 内订阅者，并同步发到 `GlobalBus`。 |
| `MessageV2.page()/stream()` | `packages/opencode/src/session/message-v2.ts:794-850` | 从 `MessageTable` 分页 hydrate，逆序流式回放。 |
| `MessageV2.hydrate()` | `packages/opencode/src/session/message-v2.ts:533-557` | 把 message 行和 part 行重新组回 `WithParts[]`。 |

## 二、A06 和 A07 的承接点

承接点不在目录层，而在同一个 `processor()` 函数内部：

- `packages/opencode/src/session/processor.ts:54`：A06 的起点，`processor()` 调 `LLM.stream(streamInput)`。
- `packages/opencode/src/session/processor.ts:79-107`：reasoning part 从内存对象开始写入，再用 `updatePartDelta()` 做流式增量。
- `packages/opencode/src/session/processor.ts:113-208`：tool pending/running/completed/error 全都通过 `Session.updatePart()` 落盘。
- `packages/opencode/src/session/processor.ts:264`, `419-420`：step 完成和整轮结束时，通过 `Session.updateMessage()` 回写 assistant message 的 finish/cost/tokens/completed。
- `packages/opencode/src/session/processor.ts:303-338`：text part 先 `updatePart()` 建骨架，再 `updatePartDelta()` 推实时增量，最后 `updatePart()` 写入最终文本。

所以 A06 和 A07 不是“前一篇调用后一篇”这种文件间调用关系，而是同一条执行链上的前后两段：

1. A06 解释 `processor -> LLM.stream()` 这次请求是怎样发给 provider 的。
2. A07 解释 provider 流事件回来后，`processor -> Session.update* -> Database.effect -> Bus.publish -> MessageV2.stream()` 这条写回与回放链是怎样成立的。

## 三、真正的“落盘即发布”是怎么做出来的

`packages/opencode/src/storage/db.ts:126-162` 这套机制非常具体：

1. `Database.use()` 如果没有事务上下文，就创建一个 `{ tx, effects }` 上下文。
2. 所有 `Database.effect(fn)` 都只把副作用先推到 `effects` 数组里，坐标在 `140-145`。
3. 外层 `use()` 或 `transaction()` 执行完 callback 后，才顺序执行这些 effects，坐标在 `132-157`。

所以 `Session.updateMessage()` 和 `Session.updatePart()` 里把 `Bus.publish()` 包在 `Database.effect()` 里，不是风格问题，而是为了保证“数据库写成功了，事件才可见”。

## 四、message 与 part 的写路径不要混为一谈

### 1. message 级写入

`packages/opencode/src/session/index.ts:686-706`：

- 把 `msg.time.created` 提成独立列 `time_created`。
- `id` 和 `session_id` 单独存列。
- 其余字段进入 `data` JSON。
- 用 `onConflictDoUpdate({ target: MessageTable.id, set: { data } })` 做幂等 upsert。

### 2. part 级写入

`packages/opencode/src/session/index.ts:755-776`：

- `id`、`message_id`、`session_id`、`time_created` 独立列。
- 其余 part 字段进入 `data` JSON。
- 发布的是 `message.part.updated`，负载里直接带完整 `part` 快照。

### 3. delta 事件不是持久化

`packages/opencode/src/session/index.ts:778-788` 的 `updatePartDelta()` 只 `Bus.publish(MessageV2.Event.PartDelta, input)`。真正的 durable 文本内容是 processor 在本地对象上累加后，再通过 `updatePart()` 最终覆写回去。

## 五、历史回放怎样跟写路径对上

`packages/opencode/src/session/message-v2.ts:794-850` 的读取顺序是：

1. `page()` 先按 `MessageTable.time_created` 和 `id` 分页。
2. `533-557` 的 `hydrate()` 再批量查 `PartTable`，按 `message_id, part_id` 排序组回消息。
3. `stream()` 用 `page()` 做分页循环，最终按时间顺序 yield。

这就是为什么 loop 和 CLI 总是依赖 `MessageV2.stream()`/bus，而不是手写 SQL 拼历史。

## 六、processor 的完整事件分类体系

`processor.ts:56-353` 的 `for await (const value of stream.fullStream)` 覆盖了 AI SDK `StreamTextResult` 定义的完整事件谱系，按用途分五类：

### 推理类（reasoning-*）

| 事件 | processor 处理逻辑 |
|---|---|
| `reasoning-start` | 创建内存 `reasoningMap[id]` 对象，`updatePart()` 落 `type: "reasoning"` 骨架 |
| `reasoning-delta` | 本地累加 `part.text += value.text`，`updatePartDelta()` 推送增量到 bus |
| `reasoning-end` | 截断空白、记结束时间、`updatePart()` 最终落盘 |

reasoning 不走 `tool-input-start/delta/end` 这套工具链，而是走独立的 part 类型。`reasoning-delta` 事件量大，所以用 `updatePartDelta()` 纯推送到 bus，不落库。

### 文本类（text-*）

| 事件 | processor 处理逻辑 |
|---|---|
| `text-start` | 创建内存 `currentText` 对象，`updatePart()` 建 `type: "text"` 骨架 |
| `text-delta` | 本地累加 `currentText.text += value.text`，`updatePartDelta()` 推送增量 |
| `text-end` | 触发 `experimental.text.complete` 插件钩子、`updatePart()` 最终落盘 |

与 reasoning 的区别是：reasoning part 的 `providerMetadata` 可能包含 thinking tokens 计量，而 text part 的 metadata 通常为空。两者都支持增量推送。

### 工具类（tool-*）

| 事件 | processor 处理逻辑 |
|---|---|
| `tool-input-start` | 创建 `toolcalls[id]` 条目，`updatePart()` 建 `type: "tool", status: "pending"` |
| `tool-input-delta` | 当前版本未使用（保留接口） |
| `tool-input-end` | 当前版本未使用（保留接口） |
| `tool-call` | 更新 `toolcalls[id]` 为 `status: "running"`、`updatePart()`；触发 doom loop 检测 |
| `tool-result` | 更新为 `status: "completed"`、`updatePart()`；注入 `output`/`title`/`metadata` |
| `tool-error` | 更新为 `status: "error"`、`updatePart()`；判断是否 `RejectedError` 以决定是否 `blocked` |

注意：`tool-input-*` 和 `tool-call` 是两套不同事件。前者是 SDK 解析输入参数的中间状态，后者是输入解析完成、准备执行。两个事件之间的 delta 在当前版本里被忽略了。

### 步骤边界类

| 事件 | processor 处理逻辑 |
|---|---|
| `start-step` | `Snapshot.track()` 开启本轮文件快照跟踪 |
| `finish-step` | 汇总 usage/cost、更新 assistant message 的 finishReason/cost/tokens、`Snapshot.patch()` 计算文件变更；若 token 超限则标记 `needsCompaction = true` |
| `start` | 置 session 状态为 `busy` |
| `finish` | 当前版本无操作（留空） |

### 错误类

| 事件 | processor 处理逻辑 |
|---|---|
| `error` | 直接 throw，进入 processor 的 `catch` 块做重试/分类 |
| `tool-error` | 更新 part 状态后，判断是否 `Permission.RejectedError` 或 `Question.RejectedError`，是则设置 `blocked = true` |

## 七、doom loop 检测机制

`processor.ts:155-177` 有一个专门的对策：

```typescript
// 同一工具连续调用 DOOM_LOOP_THRESHOLD(3) 次，且输入完全相同
if (lastThree.length === DOOM_LOOP_THRESHOLD &&
    lastThree.every(p => p.tool === value.toolName &&
                        JSON.stringify(p.state.input) === JSON.stringify(value.input)))
```

触发后会调 `Permission.ask({ permission: "doom_loop", ... })`，让用户确认是否继续。这里的 `always` 参数会把该工具加入 `agent.permission` 的 `always` 集合，后续轮次不再触发此检测。

这个机制防止模型在同一个工具调用上陷入无限循环。

## 八、processor 返回值与 loop 的状态迁移

`processor.process()` 最终返回三种状态：

| 返回值 | 触发条件 | loop 行为 |
|---|---|---|
| `"continue"` | 正常结束、无错误、无需 compaction | 下一轮 `loop()` 重新 `MessageV2.stream()` 读历史 |
| `"compact"` | `finish-step` 时 `SessionCompaction.isOverflow()` 为 true | `loop()` 在 `lastFinished` 后插入 `compaction` user message |
| `"stop"` | `tool-error` 时 blocked，或 `assistantMessage.error` 不为空 | loop 退出；外部（CLI/Web）收到 error 事件 |

retry 循环（`354-387`）不在 process 返回值里体现——它发生在 process 内部，通过 `continue` 重新执行本轮，而非返回给 loop。

## 九、`Bus` 与 `GlobalBus` 的区别

`Session.updatePart()` 里 `Bus.publish()` 发的是**进程内总线**，只通知同一个进程内的订阅者（如 TUI 的实时渲染回调）。

`Bus.publish()` 内部还同时向 `GlobalBus` 同步（`bus/index.ts:41-64`），`GlobalBus` 是进程间/跨实例广播通道，用于桌面端 sidecar 与前端之间的通信。

所以写入路径是：`processor -> Session.update*() -> Database.effect() -> Bus.publish() -> Local subscribers + GlobalBus`。

## 十、结论

1. OpenCode 的一致性不是”先写库再发事件”的口头约定，而是 `Database.effect()` 明确实现出来的提交后副作用队列。
2. `updatePartDelta()` 只是实时投影通道，不是 durable text 存储。
3. 无论是 loop 恢复现场还是前端重放历史，最终都回到 `MessageV2.page()/hydrate()/stream()` 这组函数。
4. processor 的事件处理体系是严格分类的：reasoning/text 用增量推送，tool 用幂等状态机，步骤边界触发 snapshot/usage/compaction 判断，错误决定 retry/compact/stop 三种退出路径。
5. doom loop 检测和 GlobalBus 广播是两个容易被忽略的横切关注点：前者防止工具重放，后者打通桌面端的 sidecar 与前端渲染。
