# OpenCode 深度专题 B05：基础设施：SQLite、Drizzle、Schema 与事件总线

OpenCode 的基础设施由 SQLite、事务副作用、历史回放和事件投影共同构成。

## 一、代码坐标

| 主题 | 文件与代码行 | 细节 |
| --- | --- | --- |
| DB 文件路径 | `packages/opencode/src/storage/db.ts:29-40` | 默认 `Global.Path.data/opencode.db`，channel 可分库。 |
| SQLite 初始化 | `packages/opencode/src/storage/db.ts:81-109` | WAL、`synchronous = NORMAL`、`busy_timeout = 5000`、迁移执行。 |
| DB 上下文与副作用 | `packages/opencode/src/storage/db.ts:121-162` | `Context` 持有 `tx + effects`。 |
| session/message/part schema | `packages/opencode/src/session/session.sql.ts:14-103` | 三张核心表 + todo/permission。 |
| JSON 迁移 | `packages/opencode/src/storage/json-migration.ts:26-52`, `149-150`, `403-410` | 老存储迁入 SQLite 的批处理流程。 |
| bus 事件发布 | `packages/opencode/src/bus/index.ts:41-64` | instance 订阅 + `GlobalBus.emit("event", ...)`。 |
| 历史 hydrate | `packages/opencode/src/session/message-v2.ts:533-557`, `794-850` | schema 与 runtime 读取路径的接缝。 |

## 二、表结构里真正决定系统行为的列

`packages/opencode/src/session/session.sql.ts:14-103` 里最关键的不是表名，而是列设计：

- `SessionTable` 在 `14-44` 保存 `project_id`、`workspace_id`、`parent_id`、`directory`、`permission`、`revert`、`summary_*`。
- `MessageTable` 在 `46-58` 只把 `id`、`session_id`、时间和 `data JSON` 分开存。
- `PartTable` 在 `60-76` 同样把主键/外键/时间和 `data JSON` 分开。

这意味着 query 能靠索引跑，异构内容能靠 JSON 保持 schema 弹性，两者兼得。

## 三、`Database.use()` 和 `Database.transaction()` 才是 OpenCode 一致性的基石

`packages/opencode/src/storage/db.ts:126-162` 的行为非常具体：

- 没有上下文时，`use()` 会创建一个新的 `effects` 队列。
- `effect(fn)` 只把副作用推入队列。
- `transaction()` 结束后统一执行队列。

因此上层写路径可以放心把 `Bus.publish()` 包在 `Database.effect()` 里，而不会出现“事件先发了，数据库最后没提交”的幽灵状态。

## 四、Bus 不是单纯的事件发射器

`packages/opencode/src/bus/index.ts:41-64` 做了两件事：

1. 给 instance 内所有本地订阅者发 payload。
2. 再把同一 payload 发给 `GlobalBus.emit("event", { directory, payload })`。

所以 CLI/TUI/Web 可以共享同一套事件语义，但仍能按 instance/worktree 维度隔离。

## 五、为什么这套基础设施天然支持“恢复现场”

`packages/opencode/src/session/message-v2.ts:533-557` 的 `hydrate()` 和 `794-850` 的 `page()/stream()` 说明：

- 历史回放只依赖 `MessageTable + PartTable`。
- loop、CLI、分页 API 都复用同一套 hydrate 逻辑。
- 数据写入与事件投影共用同一条 durable 写路径。

这就是 OpenCode 不需要额外 event-store、cache 层或内存镜像，也能做到恢复、分页、审计和实时更新的原因。
