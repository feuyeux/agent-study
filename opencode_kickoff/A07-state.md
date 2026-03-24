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

## 六、结论

1. OpenCode 的一致性不是“先写库再发事件”的口头约定，而是 `Database.effect()` 明确实现出来的提交后副作用队列。
2. `updatePartDelta()` 只是实时投影通道，不是 durable text 存储。
3. 无论是 loop 恢复现场还是前端重放历史，最终都回到 `MessageV2.page()/hydrate()/stream()` 这组函数。
