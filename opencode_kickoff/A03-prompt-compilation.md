# OpenCode 源码深度解析 A03：`SessionPrompt.prompt()` 如何把用户输入编译成 durable user message

> 本文基于 `opencode` `v1.3.2`（tag `v1.3.2`，commit `0dcdf5f529dced23d8452c9aa5f166abb24d8f7c`）源码校对
> 核心代码：`packages/opencode/src/session/prompt.ts`

A03 说明 `POST /session/:id/message` 如何进入 session runtime，并在 `prompt()` 层被编译成 durable user message。阅读这一层时，重点在于 user message 头、part 编译路径，以及 durable 写盘顺序。

---

## 1. `PromptInput` 定义了 prompt 阶段的中间表示

`packages/opencode/src/session/prompt.ts:95-159`

这一段先用 `zod` 定义 `PromptInput`。它的结构已经直接暴露出 OpenCode 对“用户输入”的理解方式：

1. `95-114` 是 message 级字段，包括 `sessionID`、`messageID`、`model`、`agent`、`noReply`、`tools`、`format`、`system`、`variant`。
2. `115-158` 的 `parts` 由 `text`、`file`、`agent`、`subtask` 四种 part 组成。
3. `106-111` 的 `tools` 明确被标成 `@deprecated`，说明旧时代“按 prompt 指定工具权限”的做法已经退位，权限应当归入 session 自身。

`prompt()` 的输入同时包含 message 级字段和结构化 parts，这套结构共同构成 prompt 阶段的中间表示。`prompt()` 的任务是把它编译成 durable history。

---

## 2. `prompt()` 主流程很短，但执行顺序是硬编码出来的

`packages/opencode/src/session/prompt.ts:162-188`

这一段只有 27 行，但顺序非常重要：

1. `163` 先 `Session.get(input.sessionID)` 取 session。
2. `164` 再 `SessionRevert.cleanup(session)`，把可能遗留的 revert 临时状态清理掉。
3. `166` 调 `createUserMessage(input)`，把这次输入编译并写进 durable history。
4. `167` 调 `Session.touch(input.sessionID)` 更新时间戳。
5. `169-182` 把旧的 `tools` 输入翻译成 `Permission.Ruleset`，再回写到 session。
6. `184-188` 判断 `noReply`。如果只想落 user message，不想继续推理，就直接返回；否则才进入 `loop({ sessionID })`。

这里至少有三个关键点：

1. `revert cleanup` 一定发生在新输入之前。否则后面读取历史时，会读到“逻辑上应当已经回滚，但物理上还没清掉”的中间态。
2. `createUserMessage()` 一定发生在 `loop()` 之前，loop 随后读取的是 durable history。
3. `tools` 兼容逻辑发生在写完 user message 之后，所以它补的是 session 权限，不是改写刚刚生成的 user message 本体。

`prompt()` 的职责边界因此很清楚：它负责“把外部请求变成 durable 状态”，而不是“亲自完成一轮模型推理”。

---

## 3. `resolvePromptParts()` 会先把模板里的引用预编译成 part

`packages/opencode/src/session/prompt.ts:191-240`

这段函数经常被忽略，但它很关键，因为 command 模板和普通 prompt 最终都要汇总到同一种 part 体系。

### 3.1 默认先放一条原始文本

`192-197` 先把整个 `template` 放成一个 `text` part。这保证了即使后面的文件引用一个都没解析出来，原始文本仍然会进入消息。

### 3.2 `ConfigMarkdown.files()` 负责抽出 `@file` / `@dir` 风格引用

`198-204` 会扫描模板里的引用，并用 `seen` 去重。同一个名字被写了多次时，只会补一次 file/agent part。

### 3.3 路径解析规则是写死的

`205-209` 有两条路径规则：

1. `~/` 开头按用户 home 目录展开。
2. 其他相对路径都以 `Instance.worktree` 为根做 `path.resolve()`。

模板里的文件引用统一相对项目 worktree 解析。

### 3.4 路径不存在时，代码会退化成“把名字当 agent 名”

`210-218` 先 `fs.stat(filepath)`。如果文件不存在，不会立刻报错，而是尝试 `Agent.get(name)`：

1. 能找到 agent，就生成 `agent` part。
2. 找不到，就什么都不加。

这就是为什么 `@plan`、`@build` 一类写法能在同一套 markdown 语法里工作。

### 3.5 目录和文件会变成不同 mime 的 `file` part

`221-236`：

1. 目录会生成 `mime: "application/x-directory"` 的 `file` part。
2. 普通文件会生成 `mime: "text/plain"` 的 `file` part。

这一步负责声明文件类型。具体展开逻辑在 `createUserMessage()` 中完成。

### 3.6 一个容易漏掉的实现细节

从 `200-237` 的写法看，`files.map(async ...)` 内部直接对共享 `parts` 数组做 `push`。因此附加 part 的实际插入顺序取决于各个异步 `stat()` / `Agent.get()` 何时完成，而不是严格按原始引用出现顺序稳定排序。这是从实现方式推出来的行为特征，不是接口文档里写出来的承诺。

---

## 4. `createUserMessage()` 先决定“这条 user message 由谁解释”

`packages/opencode/src/session/prompt.ts:986-1027`

`prompt()` 的重心其实在 `createUserMessage()`。这段开头先把 user message 的“头信息”定死。

### 4.1 先解析 agent，不存在就立刻报错

`987-998`：

1. `input.agent` 优先。
2. 否则退回 `Agent.defaultAgent()`。
3. 如果最终拿不到 agent，就列出可用 agent 名并抛错，同时通过 `Bus.publish(Session.Event.Error, ...)` 发事件。

agent 有效性在 user message 落盘前完成校验。

### 4.2 model 的选取顺序是三段式

`1000`：

1. `input.model`
2. `agent.model`
3. `lastModel(input.sessionID)`

这意味着如果用户这轮没显式指定 model，也没有 agent 预设，那么会沿用 session 最近一次 user message 的 model。

### 4.3 variant 不是无脑继承

`1001-1005` 先在“没有显式 `input.variant`，但 agent 有默认 `variant`”时，额外拉一次 model 信息。

`1005` 的逻辑非常严格：

1. 显式传入 `input.variant` 时直接用它。
2. 否则只有在 `agent.variant` 存在且当前 model 的 `variants` 里真有这个名字时，才继承 agent 默认 variant。

variant 只有在当前 model 支持时才会写入 user message。

### 4.4 user message 头信息在这里就已经 durable 化

`1007-1020` 组出 `info`：

1. `role` 固定是 `"user"`。
2. `agent`、`model`、`system`、`format`、`variant` 都直接写在消息头上。
3. `tools` 这个兼容字段也照样写入。

后面的 `loop()` 读取到的是完整 durable 的 user message 头。

### 4.5 `assign()` 的作用是给所有编译结果补稳定 part ID

`1023-1027` 定义了一个很小但很关键的辅助函数：

1. 如果 part 自带 `id`，就用 `PartID.make(part.id)` 规范化。
2. 否则生成新的 `PartID.ascending()`。

后面所有编译出的 parts，最终都会走这一步，保证落盘前就有稳定 ID。

---

## 5. 编译主体位于 `1029-1336`

`packages/opencode/src/session/prompt.ts:1029-1336`

这里的总框架是：

1. `1029-1030` 对 `input.parts` 做 `Promise.all(map(...))`。
2. 每个输入 part 都可能被扩展成“多个输出 part”。
3. `1336` 再把二维数组 `flat()`，最后统一 `assign()` 补 ID。

和前面的 `resolvePromptParts()` 不同，这里是“先按输入顺序 map，再统一 flatten”，所以顶层 `input.parts` 的展开顺序是稳定的。一个输入 part 自己展开出的多个 piece，也会保持它在当前分支里 `return` 的数组顺序。

---

## 6. `file` part 会被编译成模型可读上下文

`packages/opencode/src/session/prompt.ts:1031-1299`

这是整篇里最值得细读的一段，因为它决定了“附件”在 durable history 中究竟长什么样。

### 6.1 MCP resource：先写 synthetic 文本，再保留原 file part

`1031-1098`

如果 `part.source?.type === "resource"`，代码会走 MCP 资源分支：

1. `1037-1045` 先生成一条 synthetic text，说明正在读取哪个 MCP resource。
2. `1047-1051` 调 `MCP.readResource(clientName, uri)` 读取资源。
3. `1053-1078` 遍历返回内容：
   - 有 `text`，就转成 synthetic text part。
   - 有 `blob`，就写成 `[Binary content: ...]` 这种 synthetic text。
4. `1080-1084` 最后再把原始 `file` part 保留下来。
5. 如果读取失败，`1085-1094` 不会终止整个 prompt，而是补一条失败说明的 synthetic text。

MCP 资源会被编译成“说明文本 + 真实文本内容 + 原始附件元数据”的组合。

### 6.2 `data:text/plain`：直接把 data URL 解码进上下文

`1099-1125`

`url.protocol === "data:"` 且 `part.mime === "text/plain"` 时，代码返回三段内容：

1. 一条 synthetic text，模拟“调用了 Read tool，参数是哪个文件”，见 `1104-1110`。
2. 一条 synthetic text，正文是 `decodeDataUrl(part.url)` 解码出来的纯文本，见 `1111-1117`。
3. 最后一条仍然保留原始 `file` part，见 `1118-1123`。

所以文本 data URL 并不是让模型稍后自己解析；prompt 阶段就已经把文本内容内联进 history 了。

### 6.3 本地文本文件：`prompt()` 阶段真的会执行一次 `ReadTool`

`1126-1242`

这是最重的一条路径。

#### 6.3.1 先把 URL 还原成本地路径

`1127-1135`：

1. `fileURLToPath(part.url)` 得到真实文件路径。
2. `Filesystem.stat(filepath)` 看看它是不是目录。
3. 如果是目录，直接把 `part.mime` 改成 `application/x-directory`，后面就走目录分支。

#### 6.3.2 如果文件 URL 带了 `start/end`，会先计算读取窗口

`1137-1172`：

1. `1140-1143` 从 query string 读 `start/end`。
2. `1145-1170` 把它转成 `ReadTool` 所需的 `offset/limit`。
3. `1148-1166` 还有一层 LSP 补偿逻辑：如果 `start === end`，会尝试跑 `LSP.documentSymbol(filePathURI)`，补出更完整的 symbol range。

这说明 file part 里携带的行号范围，最终会被翻译成真实的 ReadTool 参数，而不是原封不动交给模型。

#### 6.3.3 再构造一条 synthetic 的“Read tool 调用记录”

`1172-1182` 先生成：

1. `filePath`
2. `offset`
3. `limit`

对应的 JSON 输入说明会写成一条 synthetic text，history 中会留下一条“runtime 读过这个文件片段”的痕迹。

#### 6.3.4 `ReadTool.execute()` 的输出会被直接写回当前 user message

`1184-1239`：

1. `1184` 先 `ReadTool.init()`。
2. `1186-1196` 人工构造一个只用于 prompt 编译阶段的 `Tool.Context`。
3. `1197` 执行 `t.execute(args, readCtx)`。
4. `1198-1204` 把 `result.output` 写成 synthetic text。
5. `1205-1214` 如果 `ReadTool` 顺便产出了附件，也一并作为 synthetic attachments 写入。
6. `1215-1221` 如果没有额外附件，才保留原始 `file` part。
7. `1223-1238` 若读取失败，不抛中断，而是发错误事件并补一条 synthetic text 说明失败原因。

文本文件会在 `prompt()` 阶段主动展开进 durable history。

### 6.4 目录也会走 `ReadTool`，但落盘形式不同

`1244-1278`

目录分支会：

1. 构造 `args = { filePath: filepath }`。
2. 直接调用 `ReadTool.execute()` 获取目录 listing。
3. 依次落三条 part：
   - synthetic text：记录 ReadTool 调用参数。
   - synthetic text：记录 listing 输出。
   - 原始目录 `file` part。

目录会连同展开后的 listing 一并进入 history。

### 6.5 二进制文件会被改写成 data URL，再落回新的 `file` part

`1280-1299`

如果既不是文本文件，也不是目录，这里会：

1. `1280` 先 `FileTime.read(...)` 记一次读取时间。
2. `1281-1288` 先补一条 synthetic text，仍然模拟“Read tool 被调用”。
3. `1289-1298` 不保留原来的 `file:` URL，而是把文件字节读出来，转成 `data:${part.mime};base64,...` 的新 `file` part。

这一步非常关键，因为 durable history 不能依赖一条将来可能失效的本地路径。把二进制读成 data URL，就是为了让后续回放仍然有稳定输入。

---

## 7. `agent` part 不会立即起子任务，它只会把“调用 task 工具”的意图编译进消息

`packages/opencode/src/session/prompt.ts:1303-1334`

这一段决定了 `@agent` 在 prompt 阶段到底意味着什么。

### 7.1 先根据当前 agent 权限做一次 `task` 权限评估

`1304-1306` 用的是：

1. 权限名：`"task"`
2. pattern：`part.name`
3. ruleset：当前会话 agent 的 `agent.permission`

如果评估结果是 `deny`，就会在后面附上一句 hint，强调“这是用户显式调用的 agent”。

### 7.2 最终落盘是“两段式结构”

`1307-1325` 返回的是两个 part：

1. 原始 `agent` part 本身。
2. 一条 synthetic text，正文是：
   - 使用上面的 message 和 context 生成 prompt；
   - 然后调用 `task` 工具；
   - 目标 subagent 是 `part.name`。

`agent` part 的语义是把用户的 agent 指令编译成下一轮模型必须看到的 durable 提示。

### 7.3 `subtask` / `text` 等其它 part 在这里基本直通

`1328-1334` 是默认分支。只要不是 `file` 或 `agent`，就原样补上 `messageID/sessionID` 返回。

这意味着：

1. `text` part 不会在这里被二次改写。
2. `subtask` part 也不会在这里执行，它只是被原样落成 user message 的一个 durable part，等 `loop()` 识别后再处理。

---

## 8. 编译结果还要经过插件、校验和 durable 写盘

`packages/opencode/src/session/prompt.ts:1338-1386`

### 8.1 先触发 `chat.message` 插件钩子

`1338-1351` 会调用：

1. 事件名：`"chat.message"`
2. 输入：`sessionID / agent / model / messageID / variant`
3. 输出对象：`{ message: info, parts }`

这里一个很细的实现特征是：代码没有接住 `Plugin.trigger()` 的返回值，而是直接继续往下走。因此从当前调用方式看，这个 hook 更像“原地观察/原地修改”切面，而不是显式接收一份新的返回对象。

### 8.2 再做一次 schema 校验，但校验失败只记日志，不会阻止保存

`1353-1376`：

1. `MessageV2.Info.safeParse(info)` 失败时，只写 error log。
2. 每个 `part` 也会单独 `safeParse`；失败同样只是记日志。

这里的校验承担落盘前哨兵角色，失败时记录日志并继续保存。

### 8.3 最终写盘顺序是先 message，后 parts

`1378-1380`：

1. 先 `Session.updateMessage(info)`。
2. 再逐个 `Session.updatePart(part)`。

这个顺序很重要，因为后续任何读取方都可以先 hydrate 到 message，再按 `messageID` 补 parts。

### 8.4 `createUserMessage()` 的返回值已经不是“原始输入”

`1383-1386` 返回的是：

1. `info`
2. `parts`

也就是已经过编译、补 ID、可能插入 synthetic text、可能内联文件内容、可能改写成 data URL 的 durable 产物。

---

## 9. 从代码行回头看，`prompt()` 完成了什么

把 `162-188` 和 `986-1386` 合起来看，`prompt()` 这一层至少实现了 5 件事：

1. 选定这轮 user message 的 `agent / model / variant / system / format`。
2. 把原始 `parts` 编译成 durable parts，而不是把原始输入原样存档。
3. 主动展开文件和目录，把模型需要看到的文本在 prompt 阶段就写进 history。
4. 把 `@agent` / `subtask` 这样的高级输入也变成 durable 编排信号。
5. 在 `noReply !== true` 时，把已经写好的 durable history 交给 `loop()` 继续调度。

`prompt()` 交给后续 runtime 的是一条能够被回放、被恢复、被分支、被压缩的 durable user message。A04 接着说明 `loop()` 如何根据这条 durable history 决定下一轮动作。
