# OpenCode 深度专题 B04：韧性机制：重试、溢出自愈与回滚清理

OpenCode 的韧性来自三条互相咬合的路径：processor 的错误分类、SessionRetry 的退避规则、SessionRevert 的清理与恢复。

## 一、代码坐标

| 主题 | 文件与代码行 | 细节 |
| --- | --- | --- |
| 错误分类入口 | `packages/opencode/src/session/processor.ts:354-424` | context overflow、retryable API error、fatal error 三路分流。 |
| retry 规则 | `packages/opencode/src/session/retry.ts:5-100` | `retry-after-ms`/`retry-after` 优先，其次指数退避。 |
| status 发布 | `packages/opencode/src/session/status.ts:71-80` | `busy`、`retry`、`idle` 都通过 bus 对外可见。 |
| overflow 判定 | `packages/opencode/src/session/compaction.ts:33-49` | token 超限后转入 compaction。 |
| compaction 错误兜底 | `packages/opencode/src/session/compaction.ts:227-236` | 连 compaction 都放不下时，把错误写回 assistant。 |
| revert 入口 | `packages/opencode/src/session/revert.ts:24-79` | 计算回滚目标、快照、diff。 |
| revert cleanup | `packages/opencode/src/session/revert.ts:91-137` | 在新 prompt 开始前清掉被回滚的 message/part。 |

## 二、重试不是盲目的指数退避

`packages/opencode/src/session/retry.ts:28-59` 的优先级是：

1. 如果 provider 响应里有 `retry-after-ms`，直接用它。
2. 否则看 `retry-after`，先尝试秒数，再尝试 HTTP date。
3. 再不行才用 `RETRY_INITIAL_DELAY * 2^(attempt-1)`。
4. 没有 header 时还会被 `RETRY_MAX_DELAY_NO_HEADERS = 30000` 限制住。

processor 在 `packages/opencode/src/session/processor.ts:367-378` 调这套逻辑，并在 `371-376` 把重试倒计时写成 `SessionStatus.set(... type: "retry" ...)`。

## 三、上下文溢出不是“报错结束”，而是“切编排分支”

`packages/opencode/src/session/processor.ts:359-365` 把 `ContextOverflowError` 单独识别出来，直接设 `needsCompaction = true` 并发 `session.error`。

一轮结束后：

- `packages/opencode/src/session/processor.ts:421` 返回 `"compact"`。
- `packages/opencode/src/session/prompt.ts:715-723` 立刻创建 compaction user message。
- 下一轮 `loop()` 在 `532-543` 优先消费 compaction part。

所以 overflow 是 runtime 内部的显式状态迁移，不是外围补丁。

## 四、回滚不是 UI 层删除，而是 durable history + 文件快照双清理

`packages/opencode/src/session/revert.ts:24-79` 会：

- 找出要从哪条 message/part 开始回滚。
- 收集 patch parts。
- 调 `Snapshot.revert(patches)` 回滚文件系统。
- 写 `session.revert`、`session.diff` 和汇总 summary。

真正删除被回滚 message/part 的动作在下一次 `prompt()` 前执行：

- `packages/opencode/src/session/prompt.ts:163-164` 一进 `prompt()` 就 `SessionRevert.cleanup(session)`。
- `packages/opencode/src/session/revert.ts:91-137` 决定删哪些 messages、删哪些 parts，并同步发 `message.removed`/`message.part.removed` 事件。

## 五、结论

1. 重试、overflow、revert 都不是 UI 层策略，而是 runtime 内部的 durable 状态迁移。
2. SessionStatus 是用户可见性的基础，坐标在 `packages/opencode/src/session/status.ts:71-80`。
3. OpenCode 的容错不是“隐藏失败”，而是把失败显式写成 message error、retry status 或 revert state。
