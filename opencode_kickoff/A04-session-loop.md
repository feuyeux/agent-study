# OpenCode 源码深度解析 A04：`loop()` 如何从 durable history 推导下一轮动作

> 本文基于 `opencode` `v1.3.2`（tag `v1.3.2`，commit `0dcdf5f529dced23d8452c9aa5f166abb24d8f7c`）源码校对
> 核心代码：`packages/opencode/src/session/prompt.ts:242-756`

`loop()` 负责在 durable history 上推进 session。它的输入来自 `MessageV2.stream()`，每一轮都通过回放历史判断当前分支，并安排 subtask、compaction、overflow 处理和普通推理轮次。

---

## 1. `loop()` 之前，先有一套 session 级并发闸门

`packages/opencode/src/session/prompt.ts:242-289`

`loop()` 依赖前面三段配套状态机。

### 1.1 `start(sessionID)`：第一次进入 loop 时占住运行权

`242-251`

这一段会：

1. 读 `state()` 里的当前 session 运行表。
2. 如果这个 session 已经在跑，直接返回，不新建 controller。
3. 如果没在跑，就创建一个新的 `AbortController`，同时为这个 session 建一个 `callbacks` 队列。

同一个 session 的运行权由 `Instance.state(...)` 中的进程内状态维护。

### 1.2 `resume(sessionID)`：shell 等旁路流程恢复原 loop 时重用原来的 abort signal

`253-258`

如果 session 已经被 `start()` 占住，`resume()` 会直接把已有的 `abort.signal` 取出来，而不是再开一套新的循环。

### 1.3 `cancel(sessionID)`：释放运行态并把状态切回 idle

`260-272`

`cancel()` 做三件事：

1. 如果这个 session 当前没人占用，仍然会把 `SessionStatus` 设回 `idle`。
2. 如果正在运行，就 `abort.abort()`。
3. 无论哪种情况，最终都会 `delete s[sessionID]` 并把状态置为 `idle`。

### 1.4 `loop()` 入口先抢占，否则直接挂到等待队列

`278-289`

进入 `loop()` 时：

1. `281` 根据 `resume_existing` 决定是 `resume()` 还是 `start()`。
2. `282-287` 如果没拿到 `abort`，说明已经有一条 loop 在跑，这次调用不会重复执行，而是返回一个 `Promise` 并把 `resolve/reject` 推进 `callbacks`。
3. `289` 用 `defer(() => cancel(sessionID))` 保证这次 loop 结束后一定释放 session。

`loop()` 的第一步是占住当前 session 的执行权。

---

## 2. 进入 while 之后，`loop()` 每一轮都先从 durable history 重新推导状态

`packages/opencode/src/session/prompt.ts:291-319`

### 2.1 `structuredOutput` 和 `step` 是 loop 自己唯一保留的局部状态

`291-297`

这一轮 loop 局部维护的只有两类东西：

1. `structuredOutput`，用来接住 `StructuredOutput` 工具的成功结果。
2. `step`，记录当前 loop 第几轮。

除此之外，它并不缓存上一轮的 conversation 视图。

### 2.2 每一轮都把 session 状态切成 `busy`

`298-301`

每次 while 重新开始，都会：

1. `SessionStatus.set(sessionID, { type: "busy" })`
2. `log.info("loop", { step, sessionID })`
3. 如果 `abort.aborted`，立刻退出

busy 状态会在每轮开始时重新声明。

### 2.3 `msgs` 来自 `filterCompacted(stream(sessionID))`

`302`

这一行是整段代码的轴心：

1. `MessageV2.stream(sessionID)` 从 durable 存储里把消息流出来。
2. `MessageV2.filterCompacted(...)` 再把已经被 summary 覆盖掉的旧上下文过滤掉。

loop 使用经过 `filterCompacted()` 处理后的可见历史。

### 2.4 `304-319` 从尾到头扫描，推导 4 个关键状态

这段循环会得到：

1. `lastUser`
2. `lastAssistant`
3. `lastFinished`
4. `tasks`

逐行看它的意图：

1. `308-314` 从 `msgs.length - 1` 往前扫，也就是从最新消息往旧消息回退。
2. `310` 第一次遇到 user message，就记为 `lastUser`。
3. `311` 第一次遇到 assistant message，就记为 `lastAssistant`。
4. `312-313` 第一次遇到 `finish` 已存在的 assistant，就记为 `lastFinished`。
5. `315-318` 只要当前还没看到 `lastFinished`，就把这段“未完成尾巴”里的 `compaction` / `subtask` parts 收进 `tasks`。

`tasks` 收集的是未完成历史尾部中的编排 part。

---

## 3. 退出条件由 durable 字段直接决定

`packages/opencode/src/session/prompt.ts:321-329`

### 3.1 没有 `lastUser` 直接视为非法状态

`321`

这说明 loop 假设自己的最小输入是一条 durable user message；如果连它都没有，session history 就已经损坏。

### 3.2 满足“最近 assistant 已完整结束”就退出

`322-329` 的条件可以拆成三层：

1. `lastAssistant?.finish` 必须存在。
2. `finish` 不能是 `"tool-calls"` 或 `"unknown"`，因为这两种都代表还没彻底收口。
3. `lastUser.id < lastAssistant.id`，说明这条 assistant 的确是响应最新 user 的。

只要满足这三条，loop 就会认定“当前 session 已经有一条完成的 assistant answer”，于是直接 `break`。

这也是为什么 loop 能在崩溃恢复后继续工作：退出标准完全建立在 durable history 上，而不是某个内存标志位。

---

## 4. 第一步 side job 和 model 解析都发生在分支判断之前

`packages/opencode/src/session/prompt.ts:331-352`

### 4.1 `step++` 后，第一轮会异步触发标题生成

`331-338`

`step === 1` 时会调用 `ensureTitle(...)`，但这里没有 `await`。结合 `packages/opencode/src/session/prompt.ts:1975-2048` 可以看出：

1. 它只给 root session 生成标题。
2. 只会在默认标题、且当前是第一条真实 user message 时工作。
3. 它是旁路 side job，不阻塞主 loop。

### 4.2 每轮都按 `lastUser.model` 重新解析 model

`340-351`

每轮都会：

1. 按 `lastUser.model.providerID/modelID` 去 `Provider.getModel(...)`。
2. 如果 model 不存在，会发一个 `Session.Event.Error` 事件。
3. 最终把解析出来的 `model` 传给后面所有分支。

这说明 loop 并不相信 session 里还有某份现成的 model 对象缓存；它始终从 durable user message 头里的 model 描述重建本轮运行环境。

### 4.3 `task = tasks.pop()` 决定了 pending task 的消费顺序

`352`

这里有一个实现细节：

1. 前面 `308-318` 是从“新到旧”扫描，并把找到的 task 依次 `push` 进数组。
2. 这里再用 `pop()` 取任务。

因此当前 unfinished tail 里如果挂了多个 task，实际被执行的是其中较早的一项，也就是更靠近旧消息的一项。换句话说，这里实现的是“pending task 先来先处理”，而不是最新的先抢跑。

---

## 5. 分支一：`subtask` part 一旦挂在 history 里，loop 会主动把它清成一次 task tool 调用

`packages/opencode/src/session/prompt.ts:354-539`

这一段由 loop 显式发起一次工具执行分支。

### 5.1 先创建一条 assistant 宿主消息

`356-383`

代码先写一条 assistant message：

1. `parentID` 绑定到 `lastUser.id`。
2. `mode/agent` 直接写成 `task.agent`。
3. `modelID/providerID` 用的是 subtask 自己指定的 model，否则退回当前 `model`。
4. `cost/tokens/time` 这些运行统计字段从零初始化。

这说明 subtask tool 的输出也必须有一条正规的 assistant message 宿主，不能当作 invisible side effect。

### 5.2 再写一个 `tool` part，并把状态直接标为 `running`

`384-403`

这里写下来的 `tool` part 包含：

1. `tool: TaskTool.id`
2. `callID: ulid()`
3. `state.status: "running"`
4. `input.prompt / description / subagent_type / command`

父 session history 会留下“一次 task 工具正在执行”的 durable 轨迹。

### 5.3 执行前先触发插件钩子，再检查子 agent 是否存在

`404-430`

这一小段顺序是：

1. `404-409` 组好 `taskArgs`。
2. `410-418` 触发 `tool.execute.before`。
3. `420-430` `Agent.get(task.agent)`，找不到就列出可用 agent 并抛错。

subtask 的有效性检查发生在执行 `TaskTool.execute()` 之前。

### 5.4 `taskCtx` 把“如何回写 durable 状态”也一起交给了 `TaskTool`

`431-456`

`taskCtx` 不只是传运行参数，它还包含两条关键回调：

1. `metadata(input)`：允许 `TaskTool` 在运行中补写当前 tool part 的标题和元数据，见 `439-448`。
2. `ask(req)`：权限检查时，把 subagent 权限和 session 权限合并后再发起 `Permission.ask(...)`，见 `449-455`。

再加上 `437` 的 `extra: { bypassAgentCheck: true }`，可以看出这里是明确告诉 `TaskTool`：这次 subtask 是 loop 自己调度出来的，不要再走一遍上层 agent 显式调用检查。

### 5.5 执行完成后，loop 会把 tool 状态补成 completed 或 error

`457-512`

成功路径：

1. `462-467` 先把 result 附件补齐新的 `PartID`、`messageID`、`sessionID`。
2. `468-477` 触发 `tool.execute.after`。
3. `478-480` 把 assistant message 的 `finish` 写成 `"tool-calls"`，并写完成时间。
4. `481-497` 如果 tool 仍处于 `running`，就把它更新成 `completed`，连同 `title / metadata / output / attachments / end time` 一起写回。

失败路径：

1. `457-461` 把异常吞下，留在 `executionError` 里。
2. `498-511` 把 tool part 更新成 `error`，正文写成 `Tool execution failed: ...`。

### 5.6 command 触发的 subtask 还会补一条 synthetic user turn

`514-537`

如果 `task.command` 存在，loop 还会再插一条新的 synthetic user message，正文固定是：

`Summarize the task tool output above and continue with your task.`

注释 `515-517` 已经说明原因：某些推理模型需要稳定的 user 边界，这一条 synthetic user turn 用来修正会话节奏。

---

## 6. 分支二：pending compaction 会被优先消费

`packages/opencode/src/session/prompt.ts:542-553`

如果 `task?.type === "compaction"`，这一轮不会进入普通推理，而是直接：

1. 把当前 `msgs`、`parentID`、`abort`、`sessionID`、`auto`、`overflow` 打包交给 `SessionCompaction.process(...)`。
2. 如果 compaction 返回 `"stop"`，整个 loop 结束。
3. 否则继续下一轮 while。

compaction 属于 loop 级别的特殊调度路径。

---

## 7. 分支三：overflow 自愈通过 compaction task 完成

`packages/opencode/src/session/prompt.ts:556-569`

这一段检查的是“最近一条已完成 assistant 是否已经逼近上下文极限”：

1. `lastFinished` 必须存在。
2. 这条 assistant 不能本身就是 `summary`。
3. `SessionCompaction.isOverflow({ tokens: lastFinished.tokens, model })` 返回 true。

一旦命中，不会立刻终止，也不会直接在当前分支里做压缩，而是：

1. `562-567` 调 `SessionCompaction.create(...)`。
2. 把“需要 compaction”再次编码成一条新的 durable user message。
3. `568` `continue`，让下一轮 loop 去命中上面的 compaction 分支。

overflow 在 OpenCode 中会触发 durable 状态迁移。

---

## 8. 分支四：普通推理开始前，loop 会先把这一轮模型调用的全部上下文准备好

`packages/opencode/src/session/prompt.ts:571-708`

### 8.1 先解析 agent，并计算这是不是最后一步

`572-584`

这里做了三件事：

1. `Agent.get(lastUser.agent)`，拿当前轮次的 agent。
2. 如果 agent 不存在，像前面一样发错误事件并抛错。
3. `agent.steps ?? Infinity` 变成 `maxSteps`，再用 `step >= maxSteps` 得到 `isLastStep`。

“最大步数”这类策略判断由 loop 在调用模型之前完成。

### 8.2 `insertReminders()` 会在消息尾部补 plan/build 模式提醒

`585-589`

这一行会把 `msgs` 交给 `insertReminders(...)`。结合 `packages/opencode/src/session/prompt.ts:1389-1527` 可以看出：

1. 在普通模式下，`plan` agent 会被补一段 `PROMPT_PLAN`。
2. 从 `plan` 切回 `build` 时，会补 `BUILD_SWITCH`。
3. 新实验计划模式下，还会直接把 plan 工作流规则写成 synthetic text 插到 user message 上。

reminder 以 durable/半 durable 的 message-level 注入方式进入本轮上下文。

### 8.3 先落一条 assistant skeleton，再创建 `SessionProcessor`

`591-620`

这一段是普通推理分支的起点：

1. `592-616` 先 `Session.updateMessage(...)` 创建一条 assistant skeleton。
2. `591-620` 再用这条 skeleton 创建 `SessionProcessor.create(...)`。

这说明 processor 从来不是“先拿到流，再决定往哪里写”。它永远是“先拿到一条 durable assistant 宿主，再把流事件持续写进去”。

### 8.4 `bypassAgentCheck` 只在本轮 user message 显式带了 `agent` part 时开启

`623-625`

这里会去最后一条 user message 里找 `part.type === "agent"`。如果用户这轮明确写了 `@some-agent`，那后面工具上下文里的 `bypassAgentCheck` 才会是 `true`。

### 8.5 `resolveTools()` 构造的是一套“可执行且可回写 durable 状态”的工具集

`627-635`

结合同文件 `766-953` 可知，这里构造的每个工具都已经内嵌了：

1. `Permission.ask(...)`
2. `tool.execute.before/after` 插件钩子
3. 把附件补上 `PartID/messageID/sessionID`
4. 通过 `processor.partFromToolCall(...)` 回写当前 tool part metadata

这里生成的是本轮可执行的工具运行时。

### 8.6 JSON schema 输出通过额外注入 `StructuredOutput` 工具实现

`637-645`

如果 `lastUser.format?.type === "json_schema"`：

1. 就往 `tools` 里插入 `StructuredOutput`。
2. 成功时把结果存进外层 `structuredOutput` 变量。

这使得结构化输出被统一进“工具调用”这一套通道，而不是另开一条 provider 专属分支。

### 8.7 第一轮还会旁路触发一次 session summary

`647-652`

`step === 1` 时会异步调用 `SessionSummary.summarize(...)`。和标题生成一样，这里也没有 `await`，说明 summary 是旁路 side job，而不是当前轮次必须等待的主链步骤。

### 8.8 如果中途有新的 user text 插进来，本轮会临时包一层 `<system-reminder>`

`654-671`

`step > 1 && lastFinished` 时，loop 会扫描：

1. 所有 `id > lastFinished.id` 的 user message。
2. 其中非 synthetic、非 ignored、且有非空文本的 `text` part。

然后把 `part.text` 原地改写成：

1. `<system-reminder>`
2. `The user sent the following message:`
3. 原始文本
4. `Please address this message and continue with your tasks.`
5. `</system-reminder>`

这一步只发生在当前内存里的 `msgs` 上，不会重新 `Session.updatePart(...)` 落回数据库。它的作用是给模型补一个更强的“别忘了处理中途新消息”的提示。

### 8.9 最后拼出这一轮的模型输入

`673-708`

顺序是：

1. `673` 触发 `experimental.chat.messages.transform`，允许插件对当前内存消息视图做最后一次改写。
2. `676-681` 拼 system prompt，包括环境、skills、instruction prompt。
3. `682-685` 如果是 `json_schema` 模式，再追加结构化输出的系统提醒。
4. `687-708` 调 `processor.process(...)`，把：
   - `user`
   - `agent`
   - `permission`
   - `abort`
   - `sessionID`
   - `system`
   - `messages`
   - `tools`
   - `model`
   - `toolChoice`
   一次性交给 processor。

这里还有一个细节：

1. `694-695` 会先把 durable history 转成 model messages。
2. `696-703` 如果已经到最后一步，会额外在末尾补一条 assistant 消息，正文是 `MAX_STEPS`。

达到最大步数后，loop 会把一段提示文本追加到模型上下文末尾，由模型据此收尾。

---

## 9. `processor` 返回后，是否继续下一轮仍然由 loop 决定

`packages/opencode/src/session/prompt.ts:710-744`

### 9.1 `StructuredOutput` 成功时，loop 立刻把结果写回 assistant 并退出

`712-717`

只要外层 `structuredOutput !== undefined`：

1. `processor.message.structured = structuredOutput`
2. 如果还没 finish，就补成 `"stop"`
3. `Session.updateMessage(processor.message)`
4. `break`

结构化输出的最终裁定权由 loop 持有。

### 9.2 模型停下来了，但没按要求调用 `StructuredOutput` 工具，也会在这里被判错

`719-731`

先判断：

1. `processor.message.finish` 存在。
2. finish 不是 `"tool-calls"` 或 `"unknown"`。

如果模型确实已经停下了，且当前格式是 `json_schema`，但又没有走 `StructuredOutput`，loop 会构造一个 `StructuredOutputError` 写回 assistant，然后停止。

### 9.3 其它返回值只是一种调度信号

`734-744`

1. `result === "stop"`，直接结束。
2. `result === "compact"`，创建一条新的 compaction user message。
3. 其他情况 `continue`，再跑下一轮。

这里很能体现边界：processor 负责消费单轮事件流，而 loop 负责把 processor 的返回值翻译成“session 下一步该怎么办”。

---

## 10. 收尾阶段，loop 会重新相信 durable history，而不是内存里的局部变量

`packages/opencode/src/session/prompt.ts:746-755`

### 10.1 先做一次 tool result prune

`746`

这一步调用 `SessionCompaction.prune({ sessionID })`，会尝试把较旧、较重的工具输出标记为 compacted，降低后续上下文负担。

### 10.2 再从 durable history 里重新取“最终 assistant”

`747-755`

loop 最后会重新扫描 durable history：

1. `for await (const item of MessageV2.stream(sessionID))`
2. 跳过 user message
3. 遇到第一条 assistant 就把所有排队 callbacks resolve 掉，并把这条 message 返回

结合 `packages/opencode/src/session/message-v2.ts:838-849` 可知，`MessageV2.stream()` 是按“新到旧”产出消息的，所以这里拿到的就是当前 session 最新那条 assistant message。

这一步非常关键，因为它说明 loop 的最终真相源仍然是 durable history，而不是内存里那份执行对象。

---

## 11. `loop()` 形成一台 session 级状态机

把 `242-756` 串起来看，`loop()` 形成了下面这套状态机：

1. 占住 session 运行权，保证同一 session 同时只有一条主循环在推进。
2. 每轮重新回放 durable history，而不是依赖上轮返回值。
3. 从历史尾部推导 `lastUser / lastAssistant / lastFinished / tasks`。
4. 优先处理 pending subtask 和 pending compaction。
5. 在普通推理前检查 overflow，并把 overflow 重新编码成 durable compaction task。
6. 为普通推理准备 assistant skeleton、tool runtime、system prompt 和临时提醒。
7. 把单轮事件流交给 processor。
8. 再根据 processor 的返回信号做 session 级状态迁移。
9. 结束时重新从 durable history 取回最新 assistant 作为最终结果。

`loop()` 可以视为基于 durable history 的 session orchestration kernel。A05 接着说明 `SessionProcessor.process()` 如何把单轮 `LLM.stream()` 事件翻译成 durable parts。
