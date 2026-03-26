# OpenCode 深度专题 B03：高级编排，Subagent、Command、Compaction 怎样落回同一条主线

> 本文基于 `opencode` `v1.3.2`（tag `v1.3.2`，commit `0dcdf5f529dced23d8452c9aa5f166abb24d8f7c`）源码校对

在 `v1.3.2` 中，OpenCode 并没有引入独立的 workflow engine，但它也绝不只是“模型自己决定下一步用哪个工具”。高级编排主要靠三套机制完成：`task` 子任务、`command` 模板、`compaction` 压缩恢复。它们的共同点是都回写到同一条 session/message/part 历史里。

---

## 1. 编排层的真正核心还是 `loop()`

先明确一点：高级编排没有绕开 `SessionPrompt.loop()`。

当前三类编排能力最终都表现为：

1. 向 session history 写入特定的 user part
2. 下一轮 `loop()` 扫到这些 part
3. 进入相应分支继续执行

因此 OpenCode 的 orchestration 不是“另起一套任务图”，而是“让 loop 消费更丰富的 durable state”。

---

## 2. Subagent 的本体不是线程，而是 child session

`task` 工具的实现位于 `packages/opencode/src/tool/task.ts:28-167`。

### 2.1 先过滤可访问 subagent

`29-43` 会：

1. 列出所有 `mode !== "primary"` 的 agents
2. 若当前 caller agent 存在，则用 `Permission.evaluate("task", ...)` 过滤掉被 deny 的 subagent

也就是说，subagent 选择本身受 agent permission 约束。

### 2.2 真正执行前会新建 child session

`68-104` 的关键逻辑是：

1. 若传了 `task_id` 且对应 session 存在，则恢复旧 child session
2. 否则 `Session.create({ parentID: ctx.sessionID, ... })`

并且新 session 会自带一组受限 permission：

1. 默认禁掉 todo 读写
2. 若 subagent 本身不允许 task，则再禁掉 task
3. 可额外允许 `experimental.primary_tools`

因此 subagent 的并发单位是 session，不是 Promise 或线程。

### 2.3 child session 最终还是走 `SessionPrompt.prompt()`

`128-145` 会把 subtask prompt 先过 `resolvePromptParts()`，再调用：

```ts
SessionPrompt.prompt({
  sessionID: session.id,
  model,
  agent: agent.name,
  parts: promptParts,
  tools: { ... }
})
```

所以 subagent 没有自己的执行器，它只是复用同一个 runtime，换了一份 session、agent 和 permission 边界。

---

## 3. 父 session 如何感知 subagent 结果

`TaskTool.execute()` 不会把 child session 全量历史复制回父 session，而是返回一段工具结果：

1. `task_id: ...`
2. `<task_result> ... </task_result>`

父 session 侧的 `loop()` 再把这次执行记录成：

1. 一条 assistant message
2. 一个 `tool: "task"` part

也就是说，父 session 感知的是“调用 subagent 这个工具的结果”，不是把 child session 历史直接内联回来。

这也是为什么 `Session.children(parentID)` 可以单独列子会话，见 `session/index.ts:652-662`。

---

## 4. `command` 是编排糖衣，不是另一条执行通道

`packages/opencode/src/session/prompt.ts:1823-1973` 的 `command()` 经常被当成独立执行器，其实它本质上只是：

1. 读取命令模板
2. 展开参数和 shell 占位符
3. 选择是“直接 prompt”还是“转成 subtask”
4. 最后仍然调用 `prompt()`

### 4.1 模板编译能力

`1790-1879` 支持：

1. `$1`、`$2` 这类位置占位符
2. `$ARGUMENTS`
3. `!` 反引号包裹的 shell 执行替换

### 4.2 决定是否转 subtask

`1920-1945` 的规则是：

1. 如果目标 agent 是 `subagent` 且 `command.subtask !== false`，默认转 subtask
2. 或 `command.subtask === true` 时强制转 subtask
3. 否则把模板展开后的 parts 当普通 prompt 输入

这说明 command 不是独立编排系统，而是一个把“文本模板”编译成 `PromptInput` / `SubtaskPart` 的桥接层。

---

## 5. Compaction 也是显式编排任务，而不是偷偷裁历史

`SessionCompaction` 位于 `packages/opencode/src/session/compaction.ts`。

### 5.1 创建 compaction 任务

`create()` 在 `299-329` 里会插入：

1. 一条 user message
2. 一个 `compaction` part

这一步不直接生成 summary，只是把“需要压缩”编码进 durable history。

### 5.2 处理 compaction 任务

真正执行在 `process()`，`102-297`：

1. 找出当前 user message
2. 必要时构造 replay message
3. 启动隐藏的 `compaction` agent
4. 通过 `SessionProcessor.process()` 生成一条 `summary` assistant message
5. 若 `auto === true`，再决定是 replay 原请求还是补一条 synthetic continue message

因此 compaction 不是“后台清理上下文缓存”，而是一段完整的 session 编排流程。

### 5.3 `prune()` 是另一条更轻的编排线

`54-100` 的 `prune()` 会在会话结束后回头标记旧 `tool` part 的 `state.time.compacted`，只清空老旧 tool output，不动 message 结构。

这又进一步说明 OpenCode 的“压缩”其实分两层：

1. **summary compaction**：插入摘要轮次
2. **tool output prune**：标记旧工具输出已压缩

---

## 6. 隐藏 agent 是 orchestration 的内部角色

当前有三个典型的隐藏 agent：

1. `compaction`
2. `title`
3. `summary`

它们的特点是：

1. `hidden: true`
2. 权限通常全部 deny
3. 只服务 runtime 内部步骤

这说明 OpenCode 的编排层并不依赖“额外脚本服务”，而是用同一个 agent/runtime 体系承载内部 side job。

---

## 7. 为什么这些能力都能共存而不把状态机搞炸

答案不在于它们简单，而在于它们都遵守了同一条约束：

1. 不新建第二套状态存储
2. 不新建第二套事件总线
3. 不绕开 `prompt -> loop -> processor`
4. 不绕开 `MessageV2` / `Part`

Subagent、command、compaction 看起来是高级能力，但在实现上都被压成了：

1. 特定 part
2. 特定 session 关系
3. 特定 loop 分支

这就是 OpenCode 当前编排层的核心风格：**扩展能力很多，但骨架只有一条。**
