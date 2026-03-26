# OpenCode 深度专题 B04：韧性机制，重试、溢出自愈、回滚清理与交互式阻塞

> 本文基于 `opencode` `v1.3.2`（tag `v1.3.2`，commit `0dcdf5f529dced23d8452c9aa5f166abb24d8f7c`）源码校对

在 `v1.3.2` 中，OpenCode 的“韧性”不是单指重试。它至少包括四类机制：错误分类与重试、上下文溢出后的自愈、revert/unrevert 回滚、以及 permission/question/cancel 这些把执行挂起或终止的交互式阻塞。

---

## 1. 错误先被归一成 `MessageV2` 错误类型

`packages/opencode/src/session/message-v2.ts:900-987` 的 `fromError()` 会把底层异常映射成 runtime 能处理的错误对象：

1. `AbortedError`
2. `AuthError`
3. `APIError`
4. `ContextOverflowError`
5. `StructuredOutputError`
6. `NamedError.Unknown`

这一步的价值在于：

1. provider、网络、系统调用错误先被规约进统一语义
2. `processor` 后续只需要按错误类别做策略分支

因此 OpenCode 的重试和自愈不是靠字符串匹配 everywhere，而是先靠错误模型归一化。

---

## 2. 重试不是盲目指数退避，而是看错误头和 provider 语义

`packages/opencode/src/session/retry.ts:28-100` 里有两套核心逻辑。

### 2.1 `delay(attempt, error)`

优先级是：

1. `retry-after-ms`
2. `retry-after`
3. HTTP 日期格式的 `retry-after`
4. 否则退回指数退避

所以 `v1.3.2` 不是固定 `2s -> 4s -> 8s`，而是尊重 provider 头信息。

### 2.2 `retryable(error)`

它会：

1. 明确排除 `ContextOverflowError`
2. 只对 `APIError.isRetryable === true` 的错误重试
3. 特判 `FreeUsageLimitError`、`Overloaded`、`too_many_requests`、`rate_limit`

`SessionProcessor.process()` 里命中可重试错误时，会把 session 状态切到 `retry`，并通过 `SessionStatus` 广播剩余等待时间。

---

## 3. 上下文溢出后的第一反应不是终止，而是转 compaction

在 `v1.3.2` 中，overflow 有两条触发路径。

### 3.1 软溢出：正常 finish 之后判断 token 接近上限

`SessionCompaction.isOverflow()` 根据：

1. model 上下文上限
2. reserved token 配置
3. 本轮 usage

判断是否需要压缩。若需要，`loop()` 会插入一条 `compaction` task，而不是直接报错。

### 3.2 硬溢出：provider 直接返回 context overflow

`SessionProcessor.process()` catch 到 `ContextOverflowError` 时，会：

1. `needsCompaction = true`
2. 先通过 `Bus.publish(Session.Event.Error, ...)` 广播错误
3. 最终返回 `"compact"`

随后 `loop()` 仍会创建 compaction 任务并继续自愈。

也就是说，OpenCode 当前把 overflow 视为“需要切换编排分支”，而不是“整个 session 终止”。

---

## 4. Compaction 自愈还有 replay 逻辑

`SessionCompaction.process()` 在 `112-130` 会尝试找到 overflow 之前最近一条未 compaction 的 user message 作为 `replay`。

成功后，压缩完成时会：

1. 重新写一条 user message，复制原 `agent/model/format/tools/system/variant`
2. 把旧 replay parts 复制回来
3. 对 media 附件则降级成文本提示

如果找不到可 replay 的历史，则写一条 synthetic continue message，提示模型继续或解释附件过大。

因此 overflow 自愈不是“总结一下就完”，而是尽量把任务重新带回主线。

---

## 5. Revert 不是 UI 层删除，而是文件快照 + history 清理双轨并行

`packages/opencode/src/session/revert.ts` 里的 `revert()` / `cleanup()` / `unrevert()` 组成了另一套韧性机制。

### 5.1 `revert()`

`24-80` 会：

1. 找到目标 message 或 part
2. 从目标之后收集所有 `patch` part
3. 用 `Snapshot.revert(patches)` 回滚文件系统
4. 记录 `session.revert = { messageID, partID?, snapshot, diff }`
5. 计算并写入 `session_diff`

注意：`revert()` 本身不会立即删除 message/part 历史，只是把 session 标记成“待清理回滚态”。

### 5.2 `cleanup()`

真正删除历史发生在下一次 `prompt()` 前，见 `revert.ts:91-137`：

1. 若回滚的是整条 message，就删掉该 message 及其后的所有消息
2. 若回滚的是 part，就只删目标 part 及之后的 parts
3. 删除完成后清空 `session.revert`

这解释了为什么 A03 一开始必须先 `SessionRevert.cleanup(session)`。

### 5.3 `unrevert()`

如果用户取消回滚，则 `82-89` 会用 `Snapshot.restore(snapshot)` 恢复文件现场，再清掉 `session.revert`。

所以 revert 机制不是“软隐藏消息”，而是真正把 durable history 与文件系统状态同时拉回去。

---

## 6. Permission/Question 是把执行挂起到用户交互上的机制

### 6.1 Permission

`packages/opencode/src/permission/index.ts:166-267` 当前逻辑是：

1. 先用 ruleset 求 `allow/deny/ask`
2. `deny` 直接抛 `PermissionDeniedError`
3. `ask` 就创建 pending request，发布 `permission.asked`
4. 等待 UI/CLI 通过 `/permission/:requestID/reply` 回答

`reply === "always"` 还会把批准规则写进 `PermissionTable`，对同项目后续请求生效。

### 6.2 Question

`packages/opencode/src/question/index.ts:131-220` 会：

1. 创建 pending question request
2. 发布 `question.asked`
3. 阻塞等待回答
4. 回答后生成“用户已回答你的问题”形式的工具输出

当前 `question` 工具和 `plan_exit` 都用这套机制。

### 6.3 被拒绝时 loop 是否停止，取决于配置

`SessionProcessor.process()` 里 `shouldBreak = experimental?.continue_loop_on_deny !== true`。默认情况下 permission/question 被拒绝会让本轮 stop；只有显式打开实验开关才允许继续 loop。

---

## 7. cancel / busy / doom_loop 也属于韧性的一部分

### 7.1 busy

`SessionPrompt.assertNotBusy(sessionID)` 会在新操作撞上正在运行的 session 时抛 `Session.BusyError`，避免同一 session 重入。

### 7.2 cancel

`SessionPrompt.cancel()` 会：

1. abort 当前 controller
2. 删除 session 占位
3. 把状态切回 `idle`

shell、loop、task tool 都会监听这个 abort signal。

### 7.3 doom loop

连续三次同工具同输入时，processor 会触发 `Permission.ask({ permission: "doom_loop" })`。这相当于 runtime 主动怀疑自己陷入死循环，并把是否继续执行交给用户。

---

## 8. B04 的核心结论

`v1.3.2` 的韧性不是某个 retry helper，而是一整套“把失败变成可调度状态”的机制：

1. 错误先归一化
2. 可重试的进入 retry 状态
3. overflow 切到 compaction 分支
4. revert 把文件和历史一起回滚
5. permission/question/busy/cancel 让执行进入可交互挂起

所以 OpenCode 的 resilience 不是简单兜底，而是把异常路径也纳入同一条 durable orchestration 主线。
