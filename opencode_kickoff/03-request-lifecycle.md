# 从 SessionRoutes 到 SessionPrompt.loop：02 之后应该继续看的代码入口

> **总纲** [00-opencode_ko](./00-opencode_ko.md) · **分层定位** 第二层主线入口  
> **前置阅读** [02-server-and-routing](./02-server-and-routing.md)  
> **后续阅读** [10-loop-and-processor](./10-loop-and-processor.md) · [11-loop-source-walkthrough](./11-loop-source-walkthrough.md)

这一篇不再重复“四层怎样协作”的宏观概括。那些内容现在应该放在 [00](./00-opencode_ko.md) 里解决。  
`02` 已经把请求追到 `SessionRoutes` 了，所以 `03` 要做的事应该更直接：

> **从 `SessionRoutes` 往里追，直到真正进入 `SessionPrompt.loop()`。**

也就是说，这一篇只回答三个代码问题：

1. `SessionRoutes` 里哪几条路由会把请求送进 runtime 主循环？
2. `SessionPrompt.prompt()` 在进入 loop 之前到底先做了什么？
3. `SessionPrompt.loop()` 开头几百行怎样从 durable history 恢复现场，并决定“下一步跑什么”？

---

## 一、先把入口收窄：02 之后主线只看 prompt family

`SessionRoutes` 里和 runtime 最相关的端点不止一个，但 **02 之后的主线** 应该先盯住 prompt family：

| 路由 | 直接下游 | 为什么先看它 |
|------|----------|--------------|
| `POST /session/:sessionID/message` | `SessionPrompt.prompt()` | 同步等到 prompt 主链返回 assistant message |
| `POST /session/:sessionID/prompt_async` | `SessionPrompt.prompt()` | 异步启动同一条 prompt 主链 |
| `POST /session/:sessionID/command` | `SessionPrompt.command()` | 先做命令解释，再回落到 `prompt()` |
| `POST /session/:sessionID/shell` | `SessionPrompt.shell()` | 直接执行 shell，不走 `prompt() -> loop()` 主链 |

代码定位：

- `packages/opencode/src/server/routes/session.ts:782-920`

如果目标是承接 `02` 去看 **loop 的代码主线**，最稳的读法是：

```text
先看 /message 和 /prompt_async
  -> 它们都会进入 SessionPrompt.prompt()
  -> 然后进入 SessionPrompt.loop()

/command 和 /shell 先放在旁边
  -> /command 是 prompt 前面的解释层
  -> /shell 是另一条直接写消息的旁路
```

所以这一篇后面默认说的“入口”，指的都是：

```text
SessionRoutes.message / SessionRoutes.prompt_async
  -> SessionPrompt.prompt()
  -> SessionPrompt.loop()
```

---

## 二、先进入 `prompt()`：它不是调度器，而是“落盘 + 起跑”入口

`SessionPrompt.prompt()` 本身很短，但它的职责边界非常清楚。它不负责跑完整个主循环，它负责把一次外部输入编译成 durable state，然后把 session 交给 loop。

代码定位：

- `packages/opencode/src/session/prompt.ts:162-189`

把源码压成调用链，是这样：

```text
SessionPrompt.prompt(input)
  -> Session.get(input.sessionID)
  -> SessionRevert.cleanup(session)
  -> createUserMessage(input)
  -> Session.touch(input.sessionID)
  -> 兼容旧 tools 参数，必要时写回 Session.setPermission(...)
  -> 如果 input.noReply === true
       -> 只返回刚创建的 user message
     否则
       -> SessionPrompt.loop({ sessionID })
```

### 1. `prompt()` 真正做的是“把请求变成 durable 起点”

这里最重要的不是某一个 API 调用，而是它的顺序：

1. 先取 session，确认这次输入属于哪个执行边界。
2. 再清理 `revert` 残留状态，避免 loop 看到脏现场。
3. 然后通过 `createUserMessage()` 先把用户输入写成 durable message / parts。
4. 最后才把 session 丢给 `loop()`。

这说明 OpenCode 的主线不是“收到请求就进 loop”，而是：

```text
先落 durable 输入
  -> 再进 session 调度
```

这一点决定了后面的 loop 可以每轮都从 durable history 重新建局面，而不是依赖某个仅存在于内存里的“当前输入对象”。

### 2. `createUserMessage()` 是 `prompt()` 前半段真正的重活

`prompt()` 看起来短，是因为真正的输入编译逻辑都压进了 `createUserMessage()`。

代码定位：

- `packages/opencode/src/session/prompt.ts:966-1496`
- `packages/opencode/src/session/index.ts:686-789`
- `packages/opencode/src/session/session.sql.ts:46-76`

这一段的意义不是“把文本存一下”，而是把外部输入翻译成 runtime 能继续消费的 durable parts。  
它会处理：

- 文本 part
- 文件/目录引用
- agent mention
- MCP / 资源展开
- synthetic part 注入

但如果只说“翻译成 parts”，还是太粗。这里要把 **写入链** 拆开看。

#### 先在内存里组装 `MessageV2.Info` 和 `MessageV2.Part[]`

`createUserMessage()` 开头先做两件事：

1. 解析这次输入最终使用的 `agent` / `model` / `variant`
2. 构造一条 user message 的 `info`

对应代码：

- `packages/opencode/src/session/prompt.ts:967-989`

这时还没有落库。真正落库前，它会先把 `input.parts` 展开成一批最终要写入的 `MessageV2.Part`：

- file part 会按协议分流：
  - MCP resource：先读资源内容，再生成 synthetic text part + 原 file part
  - `data:text/plain`：直接解码成 synthetic text part
  - `file:text/plain`：调用 `ReadTool`，把读出的文本先写成 synthetic text part
  - `application/x-directory`：同样通过 `ReadTool` 生成目录内容摘要
- agent part 会补一段 synthetic text，提示后续调用 task tool

对应代码：

- MCP resource 分支：`packages/opencode/src/session/prompt.ts:1000-1067`
- `data:` / `file:` / 目录读取分支：`packages/opencode/src/session/prompt.ts:1068-1269`
- agent part 分支：`packages/opencode/src/session/prompt.ts:1272-1295`
- 所有 part 展平并分配最终 `PartID`：`packages/opencode/src/session/prompt.ts:1297-1305`

#### 再统一写入 `message` 表和 `part` 表

内存里组装完成后，`createUserMessage()` 不会把对象交给某个“事务对象”缓存着，而是立刻走统一写路径：

```text
createUserMessage()
  -> Session.updateMessage(info)
  -> for (const part of parts)
       -> Session.updatePart(part)
```

对应代码：

- `packages/opencode/src/session/prompt.ts:1347-1349`

这两条写路径分别做什么：

```text
Session.updateMessage(msg)
  -> INSERT INTO MessageTable(id, session_id, time_created, data)
  -> onConflictDoUpdate(...)
  -> Bus.publish("message.updated", { info: msg })

Session.updatePart(part)
  -> INSERT INTO PartTable(id, message_id, session_id, time_created, data)
  -> onConflictDoUpdate(...)
  -> Bus.publish("message.part.updated", { part })
```

对应代码：

- `Session.updateMessage()`：`packages/opencode/src/session/index.ts:686-706`
- `Session.updatePart()`：`packages/opencode/src/session/index.ts:755-776`
- `Session.updatePartDelta()` 只发增量事件、不落库：`packages/opencode/src/session/index.ts:778-789`

表结构也很直接：

- `MessageTable` 把 message 元信息放在 `data` JSON 列：`packages/opencode/src/session/session.sql.ts:46-58`
- `PartTable` 把 part 内容放在 `data` JSON 列，并通过 `message_id` 归属到某条 message：`packages/opencode/src/session/session.sql.ts:60-76`

所以 `loop()` 看到的已经不是原始 HTTP body，而是：

```text
已经写进 session history 的 user message + parts
```

更准确地说，是：

```text
session 表里已有 session 边界
message 表里已有 user message
part 表里已有本次输入展开后的 parts
bus 上也已经发出了 message.updated / message.part.updated
```

---

## 三、然后进入 `loop()`：先解决并发与恢复，再谈普通轮次

如果说 `prompt()` 是“落盘 + 起跑”，那 `loop()` 才是 session 级调度器。

代码定位：

- `packages/opencode/src/session/prompt.ts:242-357`
- `packages/opencode/src/session/prompt.ts:561-667`

但读 `loop()` 时，不要一上来就盯 `SessionProcessor.process()`。  
`loop()` 的前半段先解决的是两个更底层的问题：

1. **同一 session 当前能不能开始新一轮执行**
2. **如果能开始，当前最应该处理的到底是什么**

### 1. 入口先看 `start()` / `resume()` / callback 队列

`loop()` 的第一段不是业务分支，而是 session 并发控制。

代码定位：

- `start()`：`packages/opencode/src/session/prompt.ts:242-250`
- `resume()`：`packages/opencode/src/session/prompt.ts:253-257`
- `cancel()`：`packages/opencode/src/session/prompt.ts:260-272`
- `loop()` 入口：`packages/opencode/src/session/prompt.ts:274-289`

对应调用链：

```text
SessionPrompt.loop({ sessionID, resume_existing? })
  -> 如果 resume_existing
       -> resume(sessionID)
     否则
       -> start(sessionID)
  -> 如果没有拿到新的 abort signal
       -> 说明已有活跃执行者
       -> 当前调用挂到 callbacks 队列上等待结果
  -> 否则
       -> 通过 defer(() => cancel(sessionID)) 注册收尾
       -> 进入 while(true)
```

这一步说明 `loop()` 的第一职责不是“跑模型”，而是：

> **保证同一 session 在任意时刻只有一个真正的执行者。**

别的调用者即使也打到了 `loop()`，也只是挂到 callback 队列上等结果，不会并发推进同一条 session history。

### 2. 每轮都先从 durable history 恢复现场

进入 `while (true)` 后，`loop()` 第一件事是重新读取历史，而不是沿用某个内存态指针。

代码定位：

- `packages/opencode/src/session/prompt.ts:296-318`
- `packages/opencode/src/session/message-v2.ts:533-557`
- `packages/opencode/src/session/message-v2.ts:794-850`
- `packages/opencode/src/session/message-v2.ts:882-898`
- `packages/opencode/src/session/index.ts:524-537`

核心逻辑是：

```text
while (true)
  -> SessionStatus.set(sessionID, { type: "busy" })
  -> MessageV2.filterCompacted(MessageV2.stream(sessionID))
  -> 倒序扫描历史
       -> lastUser
       -> lastAssistant
       -> lastFinished
       -> pending subtask / compaction
```

这里最需要展开的是：**这份 history 具体从哪里读出来？**

#### `loop()` 直接读的是 `MessageV2.stream(sessionID)`，不是某个缓存

`loop()` 里用的是：

```ts
let msgs = await MessageV2.filterCompacted(MessageV2.stream(sessionID))
```

对应代码：

- `packages/opencode/src/session/prompt.ts:302`

这里没有经过 `Session.messages()`。  
`Session.messages()` 只是一个更高层的便捷包装，它内部同样是 `for await (const msg of MessageV2.stream(...))` 再 reverse：

- `packages/opencode/src/session/index.ts:524-537`

而 `loop()` 为了做自己的恢复和 compaction 过滤，直接走了更底层的 `MessageV2.stream()`。

#### `MessageV2.stream()` 的读取链

这条读取链按函数展开，是：

```text
MessageV2.stream(sessionID)
  -> 反复调用 MessageV2.page({ sessionID, limit, before })
  -> page() 先从 MessageTable 分页取 message rows
  -> hydrate(rows) 再去 PartTable 批量取这些 message 对应的 parts
  -> 组装成 MessageV2.WithParts[]
  -> stream() 按时间正序 yield 给 loop
```

对应代码：

- `page()`：`packages/opencode/src/session/message-v2.ts:794-836`
- `stream()`：`packages/opencode/src/session/message-v2.ts:838-850`
- `hydrate()`：`packages/opencode/src/session/message-v2.ts:533-557`

也就是说，`loop()` 每轮恢复现场时，真正读的是：

1. `MessageTable` 里的 message rows
2. `PartTable` 里这些 message 对应的全部 parts
3. 然后拼成 `MessageV2.WithParts`

不是：

- 某个内存消息数组
- 某个“当前 session 指针”
- 某个 processor 临时上下文

#### `filterCompacted()` 不是“读取历史”，而是“裁剪可见历史”

`MessageV2.stream()` 把完整 history 读出来后，`filterCompacted()` 才会在此基础上裁掉被 compaction summary 覆盖的旧段落。

对应代码：

- `packages/opencode/src/session/message-v2.ts:882-898`

它的做法是：

1. 顺着 stream 收集 message
2. 如果看到“已经完成 summary 的 assistant”
3. 再遇到对应 parent user 的 compaction user message
4. 就在这里截断，保留 summary 之后还需要参与推理的可见历史

所以这一步不是“从数据库少读”，而是：

```text
先读完整的 durable history 片段
  -> 再按 compaction 语义裁成当前可见 history
```

这一步是 OpenCode 主循环最关键的设计点之一：

- 它不从“上一次 loop 留下的内存变量”恢复
- 它从 durable history 重新推导现场

所以它天然支持：

- 进程重启后的恢复
- 多入口接管
- pending task 重放
- summary / compaction 之后的继续运行

### 3. `loop()` 的第一个业务判断是“这条 session 现在该干什么”

恢复完历史后，`loop()` 才开始决定当前分支。

代码定位：

- 历史恢复与退出判断：`packages/opencode/src/session/prompt.ts:302-328`
- model 解析与 pending task 分支入口：`packages/opencode/src/session/prompt.ts:340-358`
- normal processing 入口：`packages/opencode/src/session/prompt.ts:561-667`

这段逻辑可以压成一张图：

```text
loop()
  -> 恢复 durable history
  -> 找到 lastUser / lastAssistant / lastFinished / tasks
  -> 如果已经满足退出条件
       -> break
  -> 如果有 pending subtask
       -> 先跑 subtask 分支
  -> 否则如果有 pending compaction
       -> 先跑 compaction 分支
  -> 否则如果 context overflow
       -> 创建 compaction 请求
  -> 否则
       -> 进入 normal processing
```

把“恢复 + 判定”这一步再展开成更具体的扫描过程，会更接近源码：

```text
msgs = filterCompacted(stream(sessionID))

for (let i = msgs.length - 1; i >= 0; i--) {
  const msg = msgs[i]
  -> 第一次遇到 user      => lastUser
  -> 第一次遇到 assistant => lastAssistant
  -> 第一次遇到 finish 的 assistant => lastFinished
  -> 如果 assistant 还没 finish
       -> 把它的 subtask / compaction part 收集到 tasks
}
```

对应代码：

- `packages/opencode/src/session/prompt.ts:304-318`

注意这里有一个很具体的因果关系：

1. `createUserMessage()` 先把 user message 和 part 写进 `MessageTable` / `PartTable`
2. `loop()` 随后从 `MessageV2.stream()` 把这些刚写进去的数据重新读回来
3. 然后在这批 durable 数据上判断 `lastUser`、`lastAssistant`、`tasks`

所以“恢复现场”并不抽象，它实际就是：

> **先读 `message` / `part` 两张表，再把它们重新组合成 `MessageV2.WithParts[]`，然后在这个数组上做 session 级判定。**

这一段的重点是：

> **`loop()` 不是“每次来消息就调一次 LLM”，而是在 durable history 上做 session 级任务选择。**

---

## 四、03 到这里先停：只停在 `loop()` 把本轮交给 processor 之前

如果继续往后读，马上就会进入 `normal processing`：

```text
normal processing
  -> Agent.get(...)
  -> insertReminders(...)
  -> SessionProcessor.create(...)
  -> resolveTools(...)
  -> system 组装
  -> processor.process(...)
```

代码定位：

- `packages/opencode/src/session/prompt.ts:561-667`

但这里正是 `03` 应该收住的地方。因为到这一步，叙事边界已经从：

- “请求怎样进入 runtime”

切到了：

- “loop 为什么要和 processor 拆成两层”

这应该交给下一篇 [10-loop-and-processor](./10-loop-and-processor.md)。

所以 `03` 的真正收束点是：

```text
SessionRoutes
  -> SessionPrompt.prompt()
  -> createUserMessage()
  -> SessionPrompt.loop()
  -> 恢复现场
  -> 任务选择
  -> normal processing 入口
```

---

## 五、这篇结束后，你脑子里应该留下什么

1. **`02` 讲完 `SessionRoutes` 后，主线应该直接进 `prompt()` 和 `loop()`，而不是先跳回四层概括。**
2. **`prompt()` 的职责是“把输入先写成 durable 起点，再启动 loop”，不是自己承担调度。**
3. **`loop()` 的前半段重点不是模型调用，而是 session 并发控制、history 恢复和任务选择。**
4. **OpenCode 的 session 主循环建立在 durable history 上，不建立在某个内存中的“当前请求对象”上。**
5. **到 `normal processing` 为止，03 的任务就完成了；下一步应该进入 loop/processor 的分层分析，而不是回头做宏观总结。**
