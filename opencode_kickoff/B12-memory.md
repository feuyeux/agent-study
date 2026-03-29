# OpenCode 深度专题 B12：Memory，Session 级别文件变更追踪与摘要管理

> 本文基于 `opencode` `v1.3.2`（tag `v1.3.2`，commit `0dcdf5f529dced23d8452c9aa5f166abb24d8f7c`）源码校对

在 B 系列的前面章节里，compaction 和 summary 被当作编排机制提过，但负责具体 diff 计算和 session 摘要持久化的代码始终没有单独拆出来讲。B12 就把这个模块单独钉住：`SessionSummary` 命名空间是 OpenCode 当前实现里"agent 记忆"的核心载体——它跟踪 session 期间的文件变更，计算 diff，并把这些信息写回 durable state。

---

## 1. 为什么需要"记忆"模块

如果只看 B01 的对象模型，`Session.Info.summary` 只是一个包含 `additions/deletions/files` 计数的聚合字段。但实际内容来自哪里？

答案是 `SessionSummary.computeDiff()`——它通过 `Snapshot.diffFull()` 把 session 开始到当前的所有文件变更算成 `FileDiff[]`，再分别写进：

1. `Session.setSummary()`（session 级聚合数字）
2. `Storage.write(["session_diff", sessionID])`（逐条 diff 列表）
3. `Bus.publish(Session.Event.Diff, ...)`（让前端实时感知变化）

这意味着 OpenCode 的"记忆"不是模糊的"模型自己记住上下文"，而是有具体数据结构支撑的 durable diff 历史。

---

## 2. SessionSummary 的三个导出函数

`packages/opencode/src/session/summary.ts` 当前导出三个函数：

| 函数 | 代码位置 | 做什么 |
| --- | --- | --- |
| `summarize` | `71-89` | 对指定 message 触发 session 摘要和 message 摘要两条计算 |
| `diff` | `123-142` | 读取/规范化 session_diff，返回 `FileDiff[]` |
| `computeDiff` | `144-169` | 从 message history 的 step-start/step-finish 快照中计算 diff |

---

## 3. `summarize` 的完整流程

`71-89` 的 `summarize` 实际上调用两条并行计算路径：

```ts
await Promise.all([
  summarizeSession({ sessionID, messages: all }),
  summarizeMessage({ sessionID, messages: all }),
])
```

### 3.1 `summarizeSession`：写 session 级聚合

`summarizeSession()`（`91-106`）做三件事：

1. `computeDiff(messages)` 得到 `FileDiff[]`
2. 把 `additions/deletions/files` 总计数写回 `Session.setSummary()`
3. 把完整 `FileDiff[]` 写入 `Storage` 的 `session_diff` 路径
4. 通过 `Bus` 发布 `Session.Event.Diff`

所以一次 session 结束后的 `session diff` 面板数据，就来自这里。

### 3.2 `summarizeMessage`：写 message 级细粒度 diff

`summarizeMessage()`（`108-121`）的逻辑更精细：

1. 找到指定 `messageID` 对应的 user message 及其后续 assistant 兄弟节点
2. 只对这个子区间调用 `computeDiff()`
3. 把结果合并进 `userMsg.summary.diffs`

这意味着每个 compaction summary message 携带的 diff，都是"到这个 message 为止的增量"，而不是全量 session diff。

---

## 4. Diff 的计算起点与终点

`computeDiff()`（`144-169`）的核心逻辑是**从 message history 中找最早和最晚的 step 快照**：

1. **找起点**：遍历所有 part，第一个遇到 `step-start.snapshot` 就记下
2. **找终点**：遍历所有 part，所有 `step-finish.snapshot` 都更新，最后一个就是终点
3. 如果起点和终点都找到，调用 `Snapshot.diffFull(from, to)`

这说明：
- diff 不来自"编辑器保存"或"git diff"，而来自 `step-start/step-finish` 快照边界
- 如果一轮 session 内没有任何 step（纯对话），`computeDiff` 返回空数组
- 快照本身是 `Snapshot.diffFull(from, to)` 的产物，存放在 `Snapshot` 服务里

---

## 5. `diff` 函数：读取端

`diff()`（`123-142`）是读取侧：

1. 先从 `Storage.read(["session_diff", sessionID])` 拿缓存的 diff
2. 对每个条目的 `file` 字段做 Git 路径规范化（处理 `"..."` 这种 octal-escaped 格式）
3. 如果规范化后发现有变化（文件名变了），回写更新后的列表
4. 返回最终 `FileDiff[]`

这一步的意义在于：Git 内部存储路径时会做 octal escape，读取时需要规范化才能给用户看可读的路径。

---

## 6. 为什么说这是"记忆"而不是"摘要"

一般的"摘要"只指"压缩后的文本描述"。OpenCode 的实现要具体得多：

1. **文件级**：每轮 step 的开始/结束快照构成一个可差分的版本链
2. **变更级**：`FileDiff` 包含 `additions/deletions/changes`，不是模糊文字
3. **持久化级**：diff 数据存在 `Storage`（JSON 文件）里，不是内存态
4. **传播级**：通过 `Bus.publish` 实时推给前端，不是轮询

所以 `SessionSummary` 更准确的定位是：**session 级别的文件变更追踪系统**，而"摘要"只是这个追踪系统的一个聚合投影。

---

## 7. 和 Compaction 的关系

[B03](./B03-orchestration.md) 讲过 compaction 会触发 `summary` agent 生成 summary message。触发链路是：

```
CompactionTask → summary agent → SessionProcessor.process() → 生成 summary assistant message
                  → SessionSummary.summarize() 被调用 → 写 session_diff + Session.setSummary()
```

也就是说，`SessionSummary` 既是 compaction 的消费者（compaction 调用它），也是 summary 数据的持久化层（它把计算结果写回 durable state）。

---

## 8. 把 B12 压成一句代码级结论

> `SessionSummary` 是 OpenCode 当前实现里的"agent 记忆"引擎：它从 step-start/step-finish 快照边界中提取文件 diff，写成 session 级和 message 级两份 durable 记录，并通过 Bus 实时广播给前端。
