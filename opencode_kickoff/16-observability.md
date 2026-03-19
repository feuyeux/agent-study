# 观测性为什么这么强：因为主状态本来就是事件化的

主向导对应章节：`观测性为什么这么强`

&nbsp;

```mermaid
flowchart TB
    subgraph 写路径 = 事件源
        UM[updateMessage] --> BusPub1[message.updated]
        UP[updatePart] --> BusPub2[message.part.updated]
        UPD[updatePartDelta] --> BusPub3[message.part.delta]
    end

    BusPub1 --> Bus[Bus.publish]
    BusPub2 --> Bus
    BusPub3 --> Bus

    Bus --> SSE[/event SSE路由]
    Bus --> Subscribe[Bus.subscribeAll]
    Subscribe --> CLI[CLI渲染]
    Subscribe --> TUI[TUI组件]
```

&nbsp;

OpenCode 的可观测性不是后加的 log viewer，而是 `Bus.publish()`（`packages/opencode/src/bus/index.ts:41-64`）贯穿整个持久化写路径的副产物。`Session.updateMessage()`（`packages/opencode/src/session/index.ts:686-706`）在写 message 后发布 `message.updated`，`Session.updatePart()`（`packages/opencode/src/session/index.ts:755-776`）在写 part 后发布 `message.part.updated`，`Session.updatePartDelta()`（`packages/opencode/src/session/index.ts:778-789`）则单独把流式文本和推理增量发布为 `message.part.delta`。`MessageV2.Event`（`packages/opencode/src/session/message-v2.ts:451-489`）把这些事件类型集中定义出来，所以“会话状态”和“可观察事件”从一开始就是同一套模型的两个投影。

这也是为什么 `SessionProcessor.process()`（`packages/opencode/src/session/processor.ts:63-340`）可以边消费模型流边持续更新 UI。它遇到 `reasoning-start`、`reasoning-delta`、`tool-call`、`tool-result`、`text-delta` 时，不是攒在内存里最后一次性提交，而是每个阶段都调用 `Session.updatePart()`（`packages/opencode/src/session/index.ts:755-776`）或 `Session.updatePartDelta()`（`packages/opencode/src/session/index.ts:778-789`）。因此前端看到的不是“最终答案 + 日志”，而是状态机当前正停在哪个 part 上。

服务端事件出口也很薄。`Server.createApp()`（`packages/opencode/src/server/server.ts:502-556`）里的 `/event` SSE 路由只是订阅 `Bus.subscribeAll()`（`packages/opencode/src/bus/index.ts:85-104`），然后把事件原样写出去。CLI 的 `RunCommand.execute()`（`packages/opencode/src/cli/cmd/run.ts:411-553`）直接消费这些事件，按 `message.part.updated` 渲染工具输出、文本和 reasoning；TUI 的 `Session()` 组件在事件订阅逻辑里也直接监听相同事件（`packages/opencode/src/cli/cmd/tui/routes/session/index.tsx:218-232`）。因为事件粒度足够细，客户端几乎不需要重新发明状态模型。

权限、问题和外部能力也延续同样的路线。`PermissionNext.Event`（`packages/opencode/src/permission/index.ts:70-80`）和 `Question.Event`（`packages/opencode/src/question/index.ts:59-76`）把用户介入显式事件化；`PermissionRoutes`（`packages/opencode/src/server/routes/permission.ts:9-69`）和 `QuestionRoutes`（`packages/opencode/src/server/routes/question.ts:10-99`）只是把回复写回服务；`MCP.registerNotificationHandlers()`（`packages/opencode/src/mcp/index.ts:111-117`）收到工具列表变化后也会抛出 `mcp.tools.changed`。所以 OpenCode 的“可观测性强”，本质上是因为运行时的每一步都已经被拆成稳定事件。
