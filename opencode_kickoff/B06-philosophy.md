# OpenCode 深度专题 B06：设计哲学，固定骨架与晚绑定策略

读完整个工程后，可以把 OpenCode 当前实现的设计哲学概括成一句话：**核心骨架非常固定，扩展点尽量后置。** 这也是为什么它既不像死板的单一 prompt 脚本，也不像一个完全开放的 workflow engine。

---

## 1. 固定骨架到底固定在哪

当前代码里真正“很难被改形”的骨架主要有这几段：

1. `prompt()` 先把输入编译成 durable user message
2. `loop()` 每轮从 durable history 重新求状态
3. normal round 先落 assistant skeleton，再调用 `processor`
4. `processor` 只消费单轮模型流并写回 part/message
5. `MessageV2.toModelMessages()` 负责把 durable history 投成模型上下文
6. 所有扩展能力最终都回到 session/message/part/Bus 这组基础对象

这条骨架在以下文件里都能看到：

1. `session/prompt.ts`
2. `session/processor.ts`
3. `session/llm.ts`
4. `session/index.ts`
5. `session/message-v2.ts`

也就是说，OpenCode 当前不是通过可配置图编排执行流程，而是通过一条固定 runtime pipeline 运行。

---

## 2. 晚绑定主要发生在哪些点

虽然骨架固定，但大量策略都被推迟到很晚才决定。

### 2.1 model/provider 晚绑定

直到 `LLM.stream()` 才会真正做：

1. `Provider.getProvider()`
2. `Provider.getModel()`
3. `Provider.getLanguage()`
4. provider-specific options/header/prompt transform

### 2.2 system prompt 晚绑定

直到普通推理分支执行前，才会把：

1. provider prompt
2. agent prompt
3. 环境信息
4. 技能说明
5. AGENTS/CLAUDE 指令
6. user.system

真正拼成最终 system。

### 2.3 tool set 晚绑定

直到本轮开始前，才会从：

1. 内建工具
2. 插件工具
3. MCP 工具
4. session permission
5. agent permission
6. user tools 开关

生成最终 active tools。

### 2.4 transport 晚绑定

入口层可以是：

1. in-process `Server.Default().fetch()`
2. worker RPC
3. 远端 HTTP attach
4. sidecar
5. ACP

但 runtime 完全不需要知道自己此刻被谁调用。

---

## 3. 为什么它不是一个“高度可配的工作流引擎”

当前实现里，有几个设计选择明确说明它不想变成通用 workflow engine。

### 3.1 分支种类是写死的

`loop()` 当前只识别：

1. `subtask`
2. `compaction`
3. overflow
4. normal round

这些不是用户在配置里拼出来的节点，而是 runtime 硬编码分支。

### 3.2 durable 数据模型是固定的

所有扩展能力都必须回到：

1. `Session.Info`
2. `MessageV2.Info`
3. `MessageV2.Part`
4. `Bus` 事件

不能随意定义新型状态容器。

### 3.3 扩展点在边缘，不在骨架中央

插件、技能、MCP、provider transform 都很强，但它们介入的方式是：

1. 修改 system/messages/headers/params
2. 提供额外工具
3. 提供额外 provider

而不是改写 `prompt -> loop -> processor` 的主骨架。

因此 OpenCode 当前的哲学不是“让用户自定义整个执行图”，而是“在一条稳定执行图上开放尽可能多的边缘插槽”。

---

## 4. 这种设计换来了什么

### 4.1 可恢复性

固定骨架意味着所有能力都被压到统一 durable state 模型里，恢复时只需要回放 history，而不用恢复一堆插件自定义中间态。

### 4.2 多宿主一致性

CLI、TUI、桌面、Web、ACP 都复用同一套 runtime，因为骨架与 transport 分离。

### 4.3 扩展成本可控

新 provider、新工具、新技能、新插件可以加，但不用重写 loop/processor/message model。

### 4.4 可观测性更强

因为所有东西都必须回到 message/part/Bus，前端、日志、SSE 和历史回放天然对齐。

---

## 5. 这种设计的代价是什么

也要看到它的边界：

1. 想做完全自定义的编排图并不容易，因为分支类型固定。
2. 想引入一种“不落到 message/part 的新执行对象”会比较别扭。
3. provider/tool 兼容逻辑会集中堆在 `LLM.stream()` 和 `toModelMessages()` 这种关键节点上。

但这恰恰说明当前团队的取舍非常明确：

> 优先要稳定、可恢复、可多端复用的 agent runtime；不是优先做一个可任意拼图的 workflow 平台。

---

## 6. 读完整个工程后的总判断

如果只看表面，OpenCode 很像“支持多模型、多工具、多入口的 AI coding agent”。如果把源码真正串起来看，会发现它更本质的定位是：

1. 一套 **durable session runtime**
2. 一条 **固定的执行骨架**
3. 一组 **尽量后置的 provider/tool/instruction/transport 绑定点**

也正因为如此，这个工程最应该被理解成“可恢复的 agent 操作系统内核”，而不是“一个写了很多 prompt 和工具的聊天应用”。
