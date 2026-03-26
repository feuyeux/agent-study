# OpenCode 源码深度解析 A03：`SessionPrompt.prompt()` 如何把用户输入编译成 durable user message

> 本文基于 `opencode` `v1.3.2`（tag `v1.3.2`，commit `0dcdf5f529dced23d8452c9aa5f166abb24d8f7c`）源码校对

从这一篇开始，正式进入 session runtime。OpenCode 的第一步并不是直接调模型，而是先把用户输入编译成一条 durable user message，再把各种输入附件和指令展开成若干 part。后续所有编排、回放、fork、revert 都建立在这一步产出的结构上。

---

## 1. `prompt()` 主流程很短，但顺序非常关键

`packages/opencode/src/session/prompt.ts:162-188` 的 `prompt()` 主流程很短，但中间还夹着一段兼容旧 `tools` 参数的补丁逻辑：

1. `Session.get()` 取 session。
2. `SessionRevert.cleanup(session)` 清理尚未提交的 revert 状态。
3. `createUserMessage(input)` 写 durable user message。
4. `Session.touch(sessionID)` 刷新 session 时间。
5. 如需兼容旧 `tools` 参数，则把它翻译成 session permission。
6. 若 `noReply !== true`，进入 `loop({ sessionID })`。

这个顺序的意义是：

1. **revert 清理一定发生在新输入之前**，否则历史会处于“逻辑上已回滚、物理上还没删”的中间态。
2. **用户输入先 durable，再开始推理**，后面的 loop 和前端订阅都能看到这条输入已经存在。

---

## 2. `PromptInput` 不是“文本 + 文件”的简化模型

`PromptInput` 定义在 `95-159`，支持的 part 输入有四种：

1. `text`
2. `file`
3. `agent`
4. `subtask`

再配合 message 级字段：

1. `model`
2. `agent`
3. `format`
4. `system`
5. `variant`
6. `noReply`

这说明从 runtime 视角看，用户这次输入不只是“一段文本”，而是一份待编译的中间表示。

---

## 3. 编译第一步：先选定这条 user message 的 agent/model/variant

`createUserMessage()` 在 `986-1021` 先组装 `MessageV2.User` 头信息：

1. agent：优先 `input.agent`，否则取默认 agent。
2. model：优先 `input.model`，否则 `agent.model`，再否则 `lastModel(sessionID)`。
3. variant：优先 `input.variant`，否则当 agent 预设 variant 且当前 model 确实支持时才继承。

这一步之后，user message 已经具备了后续 loop 所需的关键调度信息：

1. 这轮应由哪个 agent 解释。
2. 这轮应使用哪个 provider/model。
3. 是否有 `system` 覆盖或 `json_schema` 输出格式。

OpenCode 把这些信息放在 **user message 头** 上，而不是放在某个调用参数对象里临时传递，这就是 durable runtime 的第一个特征。

---

## 4. `resolvePromptParts()`：命令模板和 markdown 输入会先被预编译

`packages/opencode/src/session/prompt.ts:191-240` 的 `resolvePromptParts()` 会把一段模板文本里的引用预解析成 part：

1. 默认先生成一个 `text` part。
2. `ConfigMarkdown.files(template)` 找到 `@file` / `@dir` 风格引用。
3. 若路径存在：
   - 目录转成 `file` part，mime 为 `application/x-directory`
   - 文件转成 `file` part，mime 为 `text/plain`
4. 若路径不存在，则尝试把这个名字解释成 agent 名，生成 `agent` part。

这个函数最重要的价值不是“方便命令模板”，而是让 `command()` 和普通 `prompt()` 最终落到同一种 part 体系上。

---

## 5. `file` part 的处理不是透传，而是一次内容编译

`createUserMessage()` 里最重的一段就是 `1000-1269` 的 file part 分支。这里至少有 4 条子路径。

### 5.1 MCP resource：先读资源，再补 synthetic text

如果 `part.source.type === "resource"`，代码会：

1. 先插一条 synthetic text，说明正在读取哪个 MCP resource。
2. 调 `MCP.readResource(clientName, uri)`。
3. 把返回的文本内容或二进制说明再转成 synthetic text。
4. 最后再保留原始 `file` part。

也就是说，MCP 资源不是单纯附件，而是会被编译成“对模型可读的上下文文本 + 文件元数据”。

### 5.2 `data:text/plain`：直接解码进上下文

如果是 `data:` URL 且 mime 为 `text/plain`，代码会：

1. 写一条 synthetic text，模拟“调用了 Read tool，参数是哪个文件”。
2. 把 data URL 解码后的纯文本写成第二条 synthetic text。
3. 再保留原始 file part。

这解释了为什么很多文本附件虽然看起来是 file part，实际进入模型上下文时已经被编译成可读文本。

### 5.3 `file:` + `text/plain`：真的去跑一次 `ReadTool`

如果是本地文本文件，`1095-1210` 会：

1. 解析 URL 和可选行号范围。
2. 必要时调用 `LSP.documentSymbol()` 修正 symbol range。
3. 组出 `ReadTool` 参数 `{ filePath, offset, limit }`。
4. 先写 synthetic text，记录“调用了 Read tool”。
5. 真正执行 `ReadTool.execute(...)`。
6. 把 `ReadTool` 的输出写成 synthetic text；若有附件则一并写入。

因此，文本文件不是“等模型自己去读”，而是 prompt 阶段就被主动编译进 history 里。

### 5.4 目录和二进制文件也会被特殊处理

目录会走 `ReadTool` 的 listing 流程，见 `1213-1247`；二进制文件则会把真实内容读成 data URL 写回新的 file part，见 `1249-1268`。

这意味着 user message 里的 file part，到了 durable history 中已经是“可以稳定回放的展开结果”，而不是一条脆弱的本地路径引用。

---

## 6. `agent` part 不是立即起子任务，而是编译成“调用 task 工具”的提示

`1272-1294` 对 `agent` part 的处理非常关键：

1. 原始 `agent` part 会保留。
2. 额外插入一条 synthetic text，大意是：
   - “用上面的消息和上下文生成 prompt，并调用 task 工具，subagent 是 X。”

如果当前 agent 的 `task` 权限对这个 subagent 是 `deny`，还会追加一段 hint，说明这是用户显式调用的 agent。

这里要特别注意：

1. `@agent` 并不会在 `createUserMessage()` 里直接创建 child session。
2. 真正的 subtask 执行发生在后面的 `loop()` 分支和 `TaskTool.execute()`。

所以 `agent part` 的本质是**把用户的显式 agent 指令编译进 durable prompt**，而不是直接触发副作用。

---

## 7. 所有编译结果最终都被写成 durable part

在 part 编译完成后，`1307-1355` 会：

1. 触发 `Plugin.trigger("chat.message", ...)`，允许插件改写 message 和 parts。
2. 对 message/part 做 schema 校验日志。
3. 先 `Session.updateMessage(info)`。
4. 再逐个 `Session.updatePart(part)`。

写入顺序是先 message，后 parts。这样后续任何读取方都能以 `message -> parts` 的方式稳定 hydrate。

这一步非常关键，因为它把“编译产物”真正变成了 runtime 真相源。

---

## 8. 这一步之后，user message 已经不再是“原始输入”

经过 `createUserMessage()`，一条用户输入通常会被扩展成：

1. 原始 text part
2. 若干 synthetic text part
3. file part
4. agent part
5. subtask part

也就是说，数据库里的 user message 记录的不是“用户键入了什么”，而是“runtime 希望后续轮次如何理解这次输入”。

这是 OpenCode 与很多“收到文本后直接喂模型”的 agent 实现最不一样的地方。

---

## 9. `prompt()` 的真正输出是什么

从接口看，`prompt()` 最终返回的是 assistant message。但从 runtime 角度，它真正完成了两件事：

1. 生成了一条 durable user message。
2. 启动了下一阶段的 `loop()`。

因此 A03 的终点不是“拿到模型输出”，而是“把原始输入编译成 durable history 的一部分”。A04 开始，才轮到 session 级调度器根据这条 history 决定下一步做什么。
