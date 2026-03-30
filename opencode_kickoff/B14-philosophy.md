# OpenCode 深度专题 B14：设计哲学，固定骨架与晚绑定策略

> 本文基于 `opencode` `v1.3.2`（tag `v1.3.2`，commit `0dcdf5f529dced23d8452c9aa5f166abb24d8f7c`）源码校对

这篇不从抽象哲学开讲，而是直接看代码里哪些地方被写死了、哪些地方被故意留到最后一刻才决定。只有把这两类点分开，才看得清 OpenCode 的真实设计取舍。

---

## 1. “固定骨架”的 6 个硬编码交接点

在 `v1.3.2` 中，下面 6 个交接点基本构成了 runtime 的不可随意改形部分：

| 固定点 | 代码坐标 | 被写死的事情 |
| --- | --- | --- |
| 输入先落 durable history | `session/prompt.ts:162-188` | `prompt()` 总是先 `createUserMessage()`，然后才可能进入 `loop()`。 |
| 每轮都从历史重建状态 | `prompt.ts:298-319` | `loop()` 每轮都重新跑 `MessageV2.filterCompacted(MessageV2.stream(sessionID))`。 |
| 分支种类固定 | `prompt.ts:354-569` | `loop()` 只识别 pending subtask、pending compaction、overflow、自定义 normal round 这几类核心分支。 |
| normal round 必须先写 assistant skeleton | `prompt.ts:591-620` | `SessionProcessor` 的宿主 assistant message 一定先落库。 |
| 单轮执行只消费模型流 | `session/processor.ts:46-425` | `processor` 只围绕 `LLM.stream().fullStream` 写 reasoning/text/tool/step。 |
| durable history 到模型消息的投影方式固定 | `message-v2.ts`、`prompt.ts:694-705` | 模型看到的始终是 `MessageV2.toModelMessages(...)` 产物，而不是自定义对话对象。 |

这些点加在一起，就是当前 runtime 的“硬骨架”。

---

## 2. 先看哪些东西是明显写死的

### 2.1 输入路径被写死在 `prompt()`

`SessionPrompt.prompt()` 的执行顺序基本不可变：

1. `SessionRevert.cleanup(session)`
2. `createUserMessage(input)`
3. `Session.touch(sessionID)`
4. 必要时兼容旧 `tools` 参数，把它写成 session permission
5. `noReply ? return message : return loop({ sessionID })`

这意味着“外部输入 -> durable user message -> loop”不是一种默认实现，而是当前唯一主线。

### 2.2 调度路径被写死在 `loop()`

`loop()` 里最有代表性的硬编码不是 if/else 数量，而是判断顺序：

1. 先回放历史并找 `lastUser`、`lastAssistant`、`lastFinished`、`tasks`。
2. 先处理 pending subtask。
3. 再处理 pending compaction。
4. 再处理 overflow 自愈。
5. 最后才进入 normal round。

这说明 OpenCode 当前并不是让用户用配置拼一张执行图；它把 session 级分支顺序直接写在运行时里了。

### 2.3 normal round 的宿主对象也被写死了

`prompt.ts:591-620` 和 `processor.ts:27-45` 连起来看，能看到一个非常硬的约束：

1. `loop()` 先 `Session.updateMessage(...)` 写一条 assistant skeleton。
2. `SessionProcessor.create(...)` 拿到的就是这条已落库的 message。
3. `processor` 后续所有 part 写回，都挂在这条 message 上。

因此 assistant 轮次不是“流结束后再合成一个结果对象”，而是先有 durable 宿主，再往上附 reasoning/text/tool/step/patch。

### 2.4 执行结果最终只能回到统一对象模型

不管能力看起来多特殊，最后都还是回到：

1. `Session.Info`
2. `MessageV2.Info`
3. `MessageV2.Part`
4. `Bus` / SSE 事件

subtask 会变成 child session + `tool`/`subtask` 痕迹，compaction 会变成 `compaction` part + `summary` message，patch 会变成 `patch` part。代码里没有第二套“高级能力专用状态树”。

---

## 3. 再看哪些东西被故意晚绑定

### 3.1 transport 是最外层的晚绑定

入口层可以是：

1. `run.ts` 里的本地 in-process fetch
2. `thread.ts` 的 worker RPC transport
3. `attach.ts` 的远端 HTTP
4. `serve.ts` / `web.ts` 的显式 server
5. 桌面 sidecar

但这些差异都停在 `Server.fetch()` 边界之外。runtime 内部几乎不知道自己是被哪种宿主调起来的。

### 3.2 request scope 是进入 server 后才晚绑定

`server/server.ts:192-219` 里，`WorkspaceContext.provide(...)` 和 `Instance.provide(...)` 是在请求进入业务路由前才决定：

1. 当前 `workspaceID`
2. 当前 `directory`
3. 当前 `project`

所以很多看似“全局”的东西，例如 `Instance.directory`、`Bus`、`SessionStatus`，其实都是 request-scoped 或 instance-scoped 单例。

### 3.3 agent / model / variant 是 normal round 开始前才晚绑定

`loop()` 在真正进入 `processor` 前才做：

1. `Agent.get(lastUser.agent)`
2. `Provider.getModel(lastUser.model.providerID, lastUser.model.modelID)`
3. 结合 `agent.steps`、`user.variant`、`session.permission`、`user.tools` 计算本轮边界

这意味着 session 历史里保存的是“本轮该如何解释”的 durable hint，但真正生效的模型和 agent 策略仍然是每轮临近执行时才装配。

### 3.4 system prompt 是进入 `LLM.stream()` 前才晚绑定

`prompt.ts:675-685` 和 `llm.ts:70-95` 连起来可以看到完整顺序：

1. `SystemPrompt.environment(model)`
2. `SystemPrompt.skills(agent)`
3. `InstructionPrompt.system()`
4. `agent.prompt` 或 provider prompt
5. `input.system`
6. `lastUser.system`
7. plugin 的 `experimental.chat.system.transform`

所以 system prompt 不是某一个模板文件，而是 runtime 在最后一刻按当前 model/agent/project/skill/instruction/user 配置拼出来的。

### 3.5 tool set 也是每轮晚绑定

当前工具集至少经过两次裁剪：

1. `prompt.ts` 里的 `resolveTools(...)` 先把内建工具、插件工具、MCP 工具和 metadata 组起来。
2. `llm.ts:296-307` 的 `LLM.resolveTools()` 再按 agent permission、session permission 和 user 显式禁用规则删掉工具。

因此模型看到的工具列表不是静态注册表，而是“这一轮、这个 agent、这个 session 权限”下的最终产物。

### 3.6 provider 兼容层直到 `LLM.stream()` 才真正落地

`session/llm.ts:61-293` 把很多厂商差异都压到了最后一步：

1. `Provider.getLanguage()` / `getProvider()` / `Auth.get()`
2. OpenAI OAuth 走 `instructions` 字段，而不是 system messages
3. LiteLLM/Anthropic proxy 需要时补 `_noop` 工具
4. GitLab Workflow model 把远端 tool call 接回本地工具系统
5. `experimental_repairToolCall()` 负责修大小写或打回 `invalid`

所以 provider 差异不是分散在主链路四处，而是集中在“发请求前最后一次编译”这一层。

---

## 4. 代码里哪些地方明确说明它不是 workflow engine

### 4.1 分支不是用户自己拼出来的

`loop()` 的分支种类是 runtime 源码枚举出来的，不是 DSL，不是 JSON graph，也不是配置里的节点。

### 4.2 durable 状态容器不是开放模型

虽然 plugin、MCP、skill、command 很多，但它们最终仍要回写到既有的 session/message/part 模型里。代码没有提供“再注册一种新的 durable node family”的主骨架入口。

### 4.3 扩展点都在边缘，而不是中心调度器

最典型的扩展点都长在这些地方：

1. system transform
2. chat params / headers
3. tool execute before/after
4. plugin tool / MCP tool / custom tool 装配
5. provider auth / provider options

但很难看到谁能直接改写 `prompt -> loop -> processor` 这条主骨架本身。

所以当前设计不是“给你一个可自由拼装的执行图平台”，而是“给你一条固定执行图，再开放很多边缘插槽”。

---

## 5. 这种取舍在代码层面换来了什么

### 5.1 可恢复性不是附带收益，而是骨架天然支持

因为每个关键步骤都被压回 durable history，恢复时只需要重新回放 session/message/part，而不是恢复一棵插件自定义状态树。

### 5.2 多宿主复用成本很低

transport 虽然很多，但它们都只要接到 `Server.fetch()` / SSE contract，就能复用后面的全部 runtime。

### 5.3 复杂性被集中在少数边缘节点

这套设计没有消灭复杂性，而是把复杂性收束到了：

1. `session/llm.ts`
2. `message-v2.ts`
3. `tool/registry.ts`
4. `server/server.ts`

主骨架本身反而保持得很稳定。

---

## 6. 这套设计也带来了什么代价

从源码上看，代价同样很明确：

1. 想增加一种全新的 session 级分支，通常要直接改 `loop()`。
2. 想增加一种完全独立于 `MessageV2.Part` 的执行对象，会非常别扭。
3. provider 兼容、tool 兼容、消息投影兼容，都会往少数关键节点堆积。

也就是说，OpenCode 当前选择的是“中心骨架更硬，边缘兼容层更厚”。

---

## 7. 把 B06 压成一句代码级结论

如果只允许保留一句结论，那应该是：

> OpenCode 当前的设计哲学，不是抽象的“稳定优先”，而是把 `prompt -> loop -> processor -> durable history` 这条主骨架写死，再把 transport、workspace、agent、system、tools、provider 全部推迟到临近执行时晚绑定。

这句话同时解释了两件事：

1. 为什么它看起来扩展很多，但主链几乎不变形。
2. 为什么它更像 durable agent runtime，而不像可任意拼装的 workflow engine。
