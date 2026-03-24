# OpenCode 深度专题 B01：Durable State 与对象模型

Agent 定义能力，Session 定义执行容器，MessageV2/Part 定义 durable history。三者分别对应明确的 Zod schema 与写路径函数。

## 一、代码坐标

| 对象 | 文件与代码行 | 作用 |
| --- | --- | --- |
| `Agent.Info` | `packages/opencode/src/agent/agent.ts:25-50` | agent 的静态能力定义：`mode`、`permission`、`model`、`steps`、`prompt`。 |
| 内建 agents | `packages/opencode/src/agent/agent.ts:77-203` | `build`、`plan`、`general`、`explore`、`compaction`、`title`、`summary`。 |
| 用户配置覆盖 | `packages/opencode/src/agent/agent.ts:206-248` | 把 `config.agent` 叠加到默认 agent 上。 |
| `Session.Info` | `packages/opencode/src/session/index.ts:54-109`, `122-164` | session 的持久化边界：project/workspace/directory/title/share/revert/permission/time。 |
| session 创建/fork | `packages/opencode/src/session/index.ts:219-279`, `297-338` | `create()`、`fork()`、`createNext()`。 |
| `MessageV2` 消息模型 | `packages/opencode/src/session/message-v2.ts:351-448` | user/assistant message 头。 |
| `MessageV2.Part` 联合类型 | `packages/opencode/src/session/message-v2.ts:81-344`, `377-395` | text/reasoning/file/tool/subtask/compaction/patch 等异构 part。 |
| `ToolPart` 状态机 | `packages/opencode/src/session/message-v2.ts:267-344` | `pending -> running -> completed/error`。 |

## 二、Agent 是静态规则集，不是执行实例

`packages/opencode/src/agent/agent.ts:25-50` 定义了 agent 的真正字段：

- `mode` 决定是 `primary`、`subagent` 还是 `all`。
- `permission` 规定工具权限边界。
- `model`/`variant`/`options` 决定默认模型与参数。
- `steps` 决定 `loop()` 的最大轮次数。

内建 agent 在 `77-203` 写得很死：例如 `build` 允许 `question` 与 `plan_enter`，`plan` 明确改写 edit 权限，`explore` 明确只开放 grep/glob/list/bash/read/web* 等工具。

## 三、Session 不是聊天框，而是 durable 执行容器

`packages/opencode/src/session/index.ts:122-164` 的 `Session.Info` 里真正决定执行边界的字段有：

- `projectID` / `workspaceID`
- `directory`
- `parentID`
- `permission`
- `summary`
- `revert`
- `share`
- `time`

创建逻辑也很直接：

- `create()` 在 `219-236` 把 `Instance.directory`、可选 `permission/workspaceID` 带进 `createNext()`。
- `createNext()` 在 `297-338` 生成 session id、slug、title、version，并写 `SessionTable`。
- `fork()` 在 `239-279` 按 message 顺序复制 message 和 part，同时重建 assistant `parentID` 映射，保证 fork 后的因果链不乱。

## 四、MessageV2/Part 才是 runtime 真相源

`packages/opencode/src/session/message-v2.ts` 里最重要的不是 message 本身，而是 part 的拆分粒度：

- `TextPart` 在 `104-119`
- `ReasoningPart` 在 `121-132`
- `FilePart` 在 `175-184`
- `SubtaskPart` 在 `210-225`
- `StepStartPart` / `StepFinishPart` 在 `239-265`
- `ToolPart` 及其状态机在 `267-344`

这意味着 assistant 一轮输出不是一个 blob，而是一串有类型、有时间、有生命周期的 durable nodes。

## 五、为什么这组模型支撑了“可恢复”

1. Session 级边界在 `Session.Info` 里是显式字段，不靠调用栈隐式保存。
2. assistant 的因果关系靠 `parentID`，坐标在 `packages/opencode/src/session/message-v2.ts:414-441`。
3. 工具调用的整个生命周期都写进 `ToolPart.state`，坐标在 `packages/opencode/src/session/message-v2.ts:267-344`。
4. `fork()` 复制的不是“最后一段文本”，而是完整的 message/part 轨迹，坐标在 `packages/opencode/src/session/index.ts:253-276`。

这就是 OpenCode 能够 resume、fork、revert、summarize 的基础。
