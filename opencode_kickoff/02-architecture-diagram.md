# 架构总图怎么读：把目录树翻译成调用骨架，而不是模块清单

主向导对应章节：`架构总图`

&nbsp;

```mermaid
graph TB
    subgraph 第一层：入口
        CLI[CLI RunCommand.handler] --> ServerApp[Server.createApp]
        ServerApp --> Routes[SessionRoutes]
    end

    subgraph 第二层：Runtime核心
        Routes --> Loop[SessionPrompt.loop]
        Loop --> Process[SessionProcessor.process]
        Loop --> Compact[SessionCompaction]
    end

    subgraph 第三层：状态层
        Process --> MsgV2[MessageV2.Part]
        Compact --> MsgV2
        MsgV2 --> Session[(Session.Info)]
    end

    subgraph 第四层：横切能力
        Process --> Tools[ToolRegistry.tools]
        Process --> Perm[PermissionNext.ask]
        Process --> Quest[Question.ask]
        Process --> Plugin[Plugin.trigger]
        Process --> Bus[Bus.publish]
    end
```

<br/><br/>

这套代码最适合画成四层，但这四层不是”项目目录的四个文件夹”，而是四段不同职责的调用骨架。

## 第一层：入口负责把请求绑定到实例上下文

CLI 入口 `RunCommand.handler()`（`packages/opencode/src/cli/cmd/run.ts:306-672`）负责组装消息、创建或选择 session、订阅事件；服务端入口 `Server.createApp()`（`packages/opencode/src/server/server.ts:58-575`）负责解析 `directory/workspace` 并通过 `Instance.provide()` 建立实例上下文（`packages/opencode/src/server/server.ts:195-221`）。两者都不直接实现 agent 主逻辑，它们做的是“把一次外部请求挂到哪条 session 上、在哪个目录里执行”。

## 第二层：runtime 核心负责推进 session

真正的主链从 `SessionRoutes`（`packages/opencode/src/server/routes/session.ts:25-1023`）进入 `SessionPrompt.prompt()`（`packages/opencode/src/session/prompt.ts:161-188`），再进入 `SessionPrompt.loop()`（`packages/opencode/src/session/prompt.ts:277-735`）和 `SessionProcessor.process()`（`packages/opencode/src/session/processor.ts:46-425`）。`SessionPrompt.loop()` 决定 session 该走 subtask、compaction 还是 normal step；`SessionProcessor.process()` 把 normal step 的 provider 流写成 durable parts；`LLM.stream()`（`packages/opencode/src/session/llm.ts:47-257`）和 `ToolRegistry.tools()`（`packages/opencode/src/tool/registry.ts:132-173`）只是这条主链上的资源提供者。

## 第三层：状态层负责让执行轨迹成为真相源

`Session.Info`（`packages/opencode/src/session/index.ts:122-164`）定义 session 边界，`MessageV2.Part`（`packages/opencode/src/session/message-v2.ts:377-395`）定义最小执行单元，`Session.updateMessage()`（`packages/opencode/src/session/index.ts:686-706`）和 `Session.updatePart()`（`packages/opencode/src/session/index.ts:755-776`）则把所有副作用写回数据库与事件流。`SessionSummary.summarize()`（`packages/opencode/src/session/summary.ts:70-82`）和 `SessionCompaction.prune()`（`packages/opencode/src/session/compaction.ts:59-100`）都建立在这条轨迹之上，而不是另起状态系统。

## 第四层：横切能力在固定插槽里介入

`PermissionNext.ask()`（`packages/opencode/src/permission/index.ts:148-182`）和 `Question.ask()`（`packages/opencode/src/question/index.ts:109-133`）把用户介入接进工具执行路径；`Plugin.trigger()`（`packages/opencode/src/plugin/index.ts:112-127`）把 system、messages、params、headers、tool definition 和 tool execution 的可变性集中在少数钩子上；`MCP.tools()`（`packages/opencode/src/mcp/index.ts:609-649`）把外部服务器暴露的工具折叠回统一能力面；`Bus.publish()`（`packages/opencode/src/bus/index.ts:41-64`）把所有状态写操作投影成事件。

所以这张“架构图”的真正读法是：入口只负责挂载上下文，runtime 核心负责推进状态，状态层负责持久化执行轨迹，横切能力则在固定插槽里介入。只要这四层分清楚，目录再大也不会散。
