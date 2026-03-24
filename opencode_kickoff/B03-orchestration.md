# OpenCode 深度专题 B03：高级编排：Subagent、TaskTool 与 Compaction

本篇说明 subtask 与 compaction 如何被做成 durable 分支，并直接回到主 loop 中消费。

## 一、代码坐标

| 主题 | 文件与代码行 | 细节 |
| --- | --- | --- |
| subtask durable 分支 | `packages/opencode/src/session/prompt.ts:356-529` | loop 看到 `subtask` part 后，转成 task tool 执行。 |
| task 工具定义 | `packages/opencode/src/tool/task.ts:28-165` | 选择 subagent、创建 child session、转发 prompt。 |
| compaction overflow 判定 | `packages/opencode/src/session/compaction.ts:33-49` | 基于模型上下文上限和保留 token 计算。 |
| compaction 处理 | `packages/opencode/src/session/compaction.ts:102-297` | 生成 summary assistant、必要时 replay 用户上下文。 |
| compaction 创建 | `packages/opencode/src/session/compaction.ts:299-329` | 插入 `type: "compaction"` 的 user part。 |
| tool 装配入口 | `packages/opencode/src/tool/registry.ts:155-195` | task 工具是否可见、采用哪套 edit/apply_patch 策略都在这里。 |

## 二、Subagent 不是“开个线程”，而是“开一个 child session”

`packages/opencode/src/tool/task.ts:68-104` 的核心是：

- 如果带 `task_id`，先尝试恢复已有子 session。
- 否则 `Session.create({ parentID: ctx.sessionID, ... })` 新建 child session。
- 子 session 会默认 deny `todowrite`、`todoread`，并在必要时 deny 再次调用 `task`，防止无限递归。

随后 `packages/opencode/src/tool/task.ts:128-145` 会把子任务 prompt 再次走 `SessionPrompt.prompt()`，也就是说 subagent 用的是同一套 runtime，不是旁路实现。

## 三、主 loop 如何消费 subtask

`packages/opencode/src/session/prompt.ts:356-529` 的顺序不能省：

1. 新建 assistant message，表示“主 agent 正在发起 task 工具调用”，坐标 `359-383`。
2. 写一个 running 的 `tool` part，`tool = task`，坐标 `384-403`。
3. 调 `Plugin.trigger("tool.execute.before")`，坐标 `410-418`。
4. 真正执行 `taskTool.execute()`，坐标 `447-451`。
5. 根据结果把 part 更新成 `completed` 或 `error`，坐标 `471-501`。
6. 如果这是 command 触发的 subtask，再补一条 synthetic user message，坐标 `504-527`。

subtask 的整个编排过程本身就是 durable history，不需要额外调试通道。

## 四、Compaction 也不是“偷偷删历史”

### 1. 溢出检测

`packages/opencode/src/session/compaction.ts:33-49` 会根据：

- 模型 `limit.context`
- `ProviderTransform.maxOutputTokens(model)`
- `config.compaction.reserved`

算出可用输入窗口，超过就判定 overflow。

### 2. 真正压缩

`packages/opencode/src/session/compaction.ts:132-225` 会：

- 选 `compaction` agent 和模型。
- 新建一条 `summary: true` 的 assistant message。
- 用 `SessionProcessor` 再跑一轮“总结历史”的模型请求。

### 3. overflow replay

`packages/opencode/src/session/compaction.ts:114-130`、`238-292` 如果是 overflow 触发的压缩，会尽量保留最近的一条真实 user turn，并在压缩后 replay 回来，避免总结完成后丢失当前任务目标。

## 五、结论

OpenCode 的高级编排不是“多了两个特性”，而是：

1. subtask 写成 child session + task tool part；
2. compaction 写成 compaction user part + summary assistant；
3. 两者都回到 `loop()` 里被显式消费。

这就是它为什么复杂，但仍然可恢复、可审计。
