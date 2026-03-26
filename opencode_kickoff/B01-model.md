# OpenCode 深度专题 B01：Durable State 与对象模型

> 本文基于 `opencode` `v1.3.2`（tag `v1.3.2`，commit `0dcdf5f529dced23d8452c9aa5f166abb24d8f7c`）源码校对

A 线讲的是执行过程，B01 先把这条执行过程里最核心的对象讲透。OpenCode 当前 runtime 真正依赖的不是“对话字符串”和“工具调用日志”，而是三层 durable 对象：`Agent`、`Session`、`MessageV2/Part`。

---

## 1. 对象模型总览

| 对象 | 代码坐标 | 在系统里的角色 |
| --- | --- | --- |
| `Agent.Info` | `packages/opencode/src/agent/agent.ts:27-50` | 定义 agent 的静态能力边界：模式、权限、默认模型、prompt、steps。 |
| 内建 agents | `agent.ts:105-233` | `build`、`plan`、`general`、`explore`、`compaction`、`title`、`summary`。 |
| `Session.Info` | `packages/opencode/src/session/index.ts:54-109`、`122-164` | durable 执行容器，决定 project/workspace/directory/permission/revert/share 等边界。 |
| `MessageV2.User/Assistant` | `packages/opencode/src/session/message-v2.ts:351-448` | 单条用户/助手消息的 message header。 |
| `MessageV2.Part` | `message-v2.ts:81-395` | text/reasoning/file/tool/subtask/compaction/patch 等异构 part。 |
| `ToolPart.state` | `message-v2.ts:267-344` | 工具调用的 durable 状态机：`pending -> running -> completed/error`。 |

---

## 2. Agent 是静态规则集，不是执行实例

`Agent.Info` 里最重要的字段不是名字，而是这几个约束：

1. `mode`：`primary`、`subagent`、`all`
2. `permission`：工具与特殊能力的规则集
3. `model` / `variant` / `options`
4. `prompt`
5. `steps`

这说明在 `v1.3.2` 中，agent 本质上是：

1. 一套默认模型和参数
2. 一套工具权限
3. 一套行为提示词

它并不保存会话态；真正的运行态在 session 和 message history 里。

### 2.1 内建 agent 体现了 runtime 的固定角色分工

`agent.ts:105-233` 里当前内建 agents 的角色很清楚：

1. `build`：默认主 agent，可编辑、可提问、可进入 plan。
2. `plan`：只允许非常受限的编辑，核心目标是写 plan 文件。
3. `general` / `explore`：subagent。
4. `compaction` / `title` / `summary`：隐藏 agent，服务 runtime 内部任务。

因此 agent 不是“用户随便定义的 workflow 节点”，而是被 runtime 明确分配过职责的能力模板。

### 2.2 用户配置只是覆写模板，不会改变对象模型

`235-262` 会把 `config.agent` 覆写到默认 agent 上。可以改的是字段值，不能改的是模型：

1. 仍然是 `Agent.Info`
2. 仍然通过 `permission`/`model`/`prompt`/`steps` 生效
3. 不会产生新的 runtime 对象种类

---

## 3. Session 才是 durable 执行容器

`Session.Info` 定义在 `session/index.ts:122-164`。真正决定执行边界的字段有：

1. `projectID`
2. `workspaceID`
3. `directory`
4. `parentID`
5. `permission`
6. `summary`
7. `revert`
8. `share`
9. `time`

这组字段回答的是：

1. 这次执行属于哪个工程、哪个 workspace。
2. 在哪个目录内运行。
3. 是否是某个父 session 的 fork/child。
4. 当前 session 的权限、回滚、摘要、分享状态是什么。

所以 Session 不是“聊天列表里的一行元数据”，而是 runtime 的 durable boundary object。

### 3.1 create/fork 都是显式的 durable 操作

`Session.createNext()` 在 `297-338` 里会生成：

1. `SessionID`
2. `slug`
3. `version`
4. `title`
5. `projectID/directory/workspaceID`

并立即写进 `SessionTable`。

`Session.fork()` 在 `239-279` 里则会：

1. 新建 session
2. 复制原 session 的 message/part 历史
3. 重新映射 assistant `parentID`

也就是说，fork 复制的是完整 durable history，而不是 UI 上当前可见的一段文本。

---

## 4. MessageV2 把“消息头”和“消息体部件”彻底拆开了

`MessageV2` 当前最重要的设计不是 schema 长，而是拆分方式明确。

### 4.1 User message 保存的是“本轮调度意图”

`User` 结构里不仅有 `role/time`，还有：

1. `agent`
2. `model`
3. `system`
4. `format`
5. `tools`
6. `variant`

这意味着 user message 头保存的是“后续 loop/llm 应如何解释这次输入”，而不是纯展示字段。

### 4.2 Assistant message 保存的是“本轮执行结果”

`Assistant` 结构里最关键的字段是：

1. `parentID`
2. `providerID/modelID`
3. `path.cwd/root`
4. `tokens`
5. `cost`
6. `finish`
7. `error`
8. `structured`
9. `summary`

也就是说 assistant message 头记录的是一次执行轮次的边界信息，而不是最终文本内容本身。

真正的文本、reasoning、tool、patch 都在 part 里。

---

## 5. Part 联合类型才是 runtime 真相源

当前 `MessageV2.Part` 联合体至少包含这些关键类型：

| part 类型 | 代码坐标 | 典型生产者 |
| --- | --- | --- |
| `text` | `message-v2.ts:104-119` | user 输入、assistant 文本输出、synthetic reminder |
| `reasoning` | `121-132` | `SessionProcessor` 消费 reasoning 流事件 |
| `file` | `175-184` | prompt 编译后的附件、tool 输出附件 |
| `agent` | `186-199` | 用户显式 `@agent` |
| `subtask` | `210-225` | command/subagent 编排 |
| `compaction` | `201-208` | overflow 或手动 summarize |
| `tool` | `335-344` | 所有工具调用 |
| `step-start` / `step-finish` | `239-265` | 每轮模型 step 边界 |
| `patch` | `95-102` | step 结束后检测到文件改动 |
| `retry` | `227-237` | 当前代码已建模，未来可持久化重试历史 |

这意味着 OpenCode 的 durable history 不是 message 粒度，而是 message + part 的分层粒度。

---

## 6. `ToolPart.state` 是一条显式状态机

`ToolState` 目前有 4 个状态：

1. `pending`
2. `running`
3. `completed`
4. `error`

每个状态携带的数据也不同：

1. `pending`：结构化输入和原始输入
2. `running`：输入、标题、metadata、开始时间
3. `completed`：输出、附件、metadata、起止时间
4. `error`：错误文本、起止时间

因此工具调用不是“一段 assistant 文本提到用过某个工具”，而是一条 durable state machine node。

这正是 OpenCode 能做 doom-loop 检测、tool replay、tool compaction、permission 关联的基础。

---

## 7. 持久化层如何存这些对象

`packages/opencode/src/session/session.sql.ts` 的表结构对应得非常直接：

1. `SessionTable` 存 session 头
2. `MessageTable` 存 message 头
3. `PartTable` 存 part 体
4. `TodoTable` 存 todo 列表
5. `PermissionTable` 存项目级批准规则

其中 message/part 的存法很值得注意：

1. `MessageTable.data` 只存 `InfoData = Omit<MessageV2.Info, "id" | "sessionID">`
2. `PartTable.data` 只存 `PartData = Omit<MessageV2.Part, "id" | "sessionID" | "messageID">`

也就是说，ID 和外键列走关系型列，内容走 JSON。这是当前对象模型和 SQLite 结构对齐的关键设计。

---

## 8. 为什么这组对象模型支撑了“可恢复”

把上面所有点合起来，OpenCode 当前之所以能支持恢复、fork、revert、compaction，靠的是四个性质：

1. **Agent 静态化**：能力模板和运行态分离。
2. **Session 显式边界化**：project/workspace/directory/permission 都是 durable 字段。
3. **Message 头和 Part 体拆分**：执行结果不是一段大文本，而是一串 typed nodes。
4. **Tool/Step 事件状态机化**：工具调用、快照边界、patch 边界都有稳定的 durable 形态。

因此 B01 的结论可以压成一句话：

> OpenCode 当前不是“把 LLM 对话存数据库”，而是“把 agent 执行过程建模成可持久化、可重放的对象系统”。
