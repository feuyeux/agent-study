# OpenCode 源码深度解析 A05：第 3 步：沿着 `loop()` 看 session 级分支怎样展开

本篇承接 A04，只展开 `packages/opencode/src/session/prompt.ts:278-736` 这一层，回答 `loop()` 怎样在 durable history 上决定“下一步走 subtask、compaction，还是正常模型轮次”。

## 一、逐段坐标

| 段落 | 文件与代码行 | 代码在判断什么 |
| --- | --- | --- |
| 入口与复用 | `packages/opencode/src/session/prompt.ts:278-289` | 新开 loop 还是挂到已有 loop 的 callback 列表。 |
| 历史重建 | `packages/opencode/src/session/prompt.ts:297-329` | 从 durable history 找 `lastUser`、`lastAssistant`、`lastFinished`、`tasks`。 |
| 首轮标题生成 | `packages/opencode/src/session/prompt.ts:331-338` | 第一步异步触发 `ensureTitle()`。 |
| 模型解析 | `packages/opencode/src/session/prompt.ts:340-351` | `Provider.getModel()`，模型不存在时主动发 `session.error`。 |
| subtask 分支 | `packages/opencode/src/session/prompt.ts:354-529` | 把 `subtask` durable part 消耗成真正的 task tool 执行。 |
| compaction 分支 | `packages/opencode/src/session/prompt.ts:532-543` | 消费 pending compaction part。 |
| overflow 分支 | `packages/opencode/src/session/prompt.ts:546-559` | 检测上轮 token 是否已经逼近上下文上限。 |
| 正常模型轮次 | `packages/opencode/src/session/prompt.ts:561-724` | 插 reminder、建 assistant、resolve tools、调用 processor。 |
| 收尾与回调 | `packages/opencode/src/session/prompt.ts:726-735` | prune 历史、resolve 等待中的调用者。 |

## 二、关键源码细节

### 1. “已有 loop 正在跑”不会抛错，而是复用结果

`packages/opencode/src/session/prompt.ts:281-286` 如果拿不到新的 abort signal，会返回一个 Promise，并把当前调用的 `resolve/reject` 压进 `state()[sessionID].callbacks`。这保证 CLI、Web 同时观察同一 session 时不会起两条 loop。

### 2. `tasks` 不是从数据库单独查出来的

`packages/opencode/src/session/prompt.ts:307-318` 在逆序扫描消息时，把还没被 `lastFinished` 吞掉的 `compaction` 和 `subtask` parts 收集进 `tasks`。这意味着“是否有待处理任务”本身就是 durable history 的一个派生视图。

### 3. subtask 分支会创建独立 assistant message

`packages/opencode/src/session/prompt.ts:359-403` 先插一条 assistant message，再写一个 `type: "tool"` 且 `tool = task` 的 running part。随后 `447-501` 真正调用 `taskTool.execute()`，完成后把 tool part 更新成 `completed` 或 `error`。

### 4. command 触发的 subtask 会补 synthetic user turn

`packages/opencode/src/session/prompt.ts:504-527` 如果 subtask 来自 command，loop 会补一条 user message，内容是 `Summarize the task tool output above and continue with your task.`，用来避免某些 reasoning model 在 assistant 连续发言时出错。

### 5. 正常轮次里还有一次“对未完成 user 消息的提醒包装”

`packages/opencode/src/session/prompt.ts:634-650` 会把上一个 `lastFinished` 之后新插入的真实 user text 包在 `<system-reminder>` 里，提醒模型“先处理这条新消息再继续原任务”。这是多轮追问能不丢主线的关键小机制。

## 三、`loop()` 输出的不是 token，而是下一个 durable 状态

在 `packages/opencode/src/session/prompt.ts:714-723`：

- processor 返回 `stop` 就退出。
- 返回 `compact` 就创建新的 compaction user message。
- 返回 `continue` 就下一轮重新从数据库读历史。

因此 loop 的真正输出不是文本，而是“session 下一步要进入哪个 durable 分支”。

## 四、收尾阶段也不是纯尾声

`packages/opencode/src/session/prompt.ts:726-735` 做了两件经常被省略的事：

1. `SessionCompaction.prune({ sessionID })` 会把很旧的 tool 输出标记为 compacted，减轻后续上下文负担。
2. 它从 `MessageV2.stream(sessionID)` 里找到最新的 assistant message，并把它 resolve 给所有挂起的 callback。

也就是说，loop 的返回值本质上也是从 durable history 重新取出来的，而不是某个局部变量直接返回。
