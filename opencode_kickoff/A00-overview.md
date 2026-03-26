# A 系列索引：OpenCode 执行主线深度解析

> 本文基于 `opencode` `v1.3.2`（tag `v1.3.2`，commit `0dcdf5f529dced23d8452c9aa5f166abb24d8f7c`）源码校对

本系列基于 `packages/opencode` 当前实现，按**真实调用顺序**解开一次请求的生命周期：入口如何进入 Server，Server 如何进入 session runtime，runtime 怎样把用户输入编译成 durable message，再怎样循环驱动模型、工具和写回。

---

## 1. A 系列到底覆盖什么

| 篇 | 标题 | 主文件 | 真正要回答的问题 |
| --- | --- | --- | --- |
| [A01](./A01-entry.md) | 多端入口与传输适配 | `src/index.ts`、`cli/cmd/run.ts`、`cli/cmd/tui/*`、桌面壳 | CLI/TUI/Web/Attach/ACP/Desktop 最后怎样统一成同一个 session 协议 |
| [A02](./A02-server.md) | Server 与路由边界 | `server/server.ts`、`server/routes/session.ts` | Hono app 如何挂载中间件、绑定 `Instance`/`Workspace`，以及 `/session` 路由怎样进入 runtime |
| [A03](./A03-prompt.md) | `prompt()` 如何编译 durable user message | `session/prompt.ts` | text/file/agent/subtask parts 怎样被展开、补写 synthetic part、最终落库 |
| [A04](./A04-orchestrator.md) | `prompt`、`loop`、`processor` 的职责边界 | `session/prompt.ts`、`session/processor.ts` | 谁负责读历史，谁负责分支决策，谁负责消费模型流 |
| [A05](./A05-loop.md) | `loop()` 内部分支怎样展开 | `session/prompt.ts` | subtask、compaction、overflow、normal round 各自怎样修改 durable state |
| [A06](./A06-llm.md) | `LLM.stream()` 怎样把 runtime 状态绑定成 provider 请求 | `session/llm.ts`、`session/system.ts`、`provider/provider.ts` | system prompt、tool set、provider params、兼容层和 `streamText()` 调用如何拼起来 |
| [A07](./A07-state.md) | 流事件怎样写回 durable state 并重新投影 | `session/processor.ts`、`session/index.ts`、`session/message-v2.ts` | reasoning/text/tool/step 事件如何写回 part/message，前端怎样再把它们读出来 |

---

## 2. 一次请求的真实调用链

把关键函数压成一条链，就是：

1. 入口层解析用户动作。
   - `src/index.ts` 注册命令。
   - `run`、`$0`(TUI)、`attach`、`web`、`serve`、`acp`、桌面 sidecar 分别决定传输方式。
2. 请求进入 `Server.createApp()`。
   - 认证、日志、CORS、`WorkspaceContext`、`Instance.provide()` 都在这里挂上。
3. `/session/:sessionID/message` 或相关 API 进入 `SessionPrompt.prompt()`。
   - 先清理 revert 状态，再调用 `createUserMessage()` 写入 durable user message/parts。
4. `prompt()` 进入 `SessionPrompt.loop()`。
   - 每轮从 `MessageV2.stream()`/`filterCompacted()` 回放当前 session 历史。
   - 决定这轮是 subtask、compaction，还是正常模型推理。
5. 正常推理分支创建 `SessionProcessor`。
   - 先插入 assistant 骨架 message，再组 system/messages/tools，最后调用 `processor.process()`。
6. `SessionProcessor.process()` 调 `LLM.stream()`。
   - `LLM.stream()` 负责 provider/model/tool/system 的晚绑定，并最终调用 `streamText()`。
7. `SessionProcessor` 消费模型流并写回。
   - 把 reasoning/text/tool/step/patch 逐个写成 durable part。
   - 更新 assistant message 的 `finish`、`tokens`、`cost`、`error`。
8. `loop()` 根据结果继续下一轮或停止。
   - 停止后返回最新 assistant message。
   - 前端和 CLI 通过 SSE/Bus 订阅同一批 durable 事件。

---

## 3. 把这条链按时序画出来

```mermaid
sequenceDiagram
    participant Entry as CLI/TUI/Web/Desktop/ACP
    participant Server as Hono Server
    participant Prompt as SessionPrompt.prompt
    participant Loop as SessionPrompt.loop
    participant Proc as SessionProcessor
    participant LLM as LLM.stream
    participant DB as SQLite/Storage
    participant Bus as Bus/SSE

    Entry->>Server: HTTP or in-process fetch
    Server->>Prompt: session.prompt / session.command / session.shell
    Prompt->>DB: updateMessage(user) + updatePart(parts)
    Prompt->>Loop: loop(sessionID)
    Loop->>DB: MessageV2.stream() / filterCompacted()
    Loop->>DB: updateMessage(assistant skeleton)
    Loop->>Proc: process(...)
    Proc->>LLM: LLM.stream(...)
    LLM-->>Proc: fullStream events
    Proc->>DB: updatePart / updateMessage / summary / patch
    DB-->>Bus: Database.effect -> publish
    Bus-->>Entry: SSE / event subscription
    Proc-->>Loop: continue / compact / stop
```

---

## 4. A 线刻意不展开什么

A 系列关心的是主线，不会在每一篇里展开以下主题：

1. **Agent/Session/Message/Part 的 schema 设计**：放到 [B01](./B01-model.md)。
2. **系统指令、AGENTS.md、技能、投影到 ModelMessage 的全过程**：放到 [B02](./B02-context.md)。
3. **Subagent、Command、Compaction 的编排抽象**：放到 [B03](./B03-orchestration.md)。
4. **Retry、Overflow、自愈、Revert、Permission/Question**：放到 [B04](./B04-resilience.md)。
5. **SQLite、Drizzle、Bus、GlobalBus、Storage**：放到 [B05](./B05-infra.md)。
6. **为什么它既固定骨架又大量晚绑定**：放到 [B06](./B06-philosophy.md)。

也就是说，A 系列先回答“系统是怎么跑起来的”，B 系列再回答“为什么要这样设计”。

---

## 5. 读 A 线时要抓住的三个事实

### 5.1 真相源是数据库历史，不是内存对象

`loop()` 的输入来自 `MessageV2.stream()`，而不是一个长驻 conversation 实例。每一轮都在 durable history 上重新求 `lastUser`、`lastAssistant`、`tasks`。

### 5.2 assistant 骨架会先落盘

不论是普通推理、subtask，还是 compaction，OpenCode 都会先插入 assistant message，再开始消费模型流或工具结果。这让崩溃恢复、UI 订阅和 fork/revert 都有稳定锚点。

### 5.3 所有“特殊能力”都回写成普通 history

subtask 会变成 `subtask` part + child session，compaction 会变成 `compaction` user part + `summary` assistant，shell/command 也会写成普通 user/assistant/tool history。系统没有第二条隐式执行通道。

---

## 6. 推荐阅读方式

1. 先读 [A01](./A01-entry.md) 和 [A02](./A02-server.md)，明确 transport 与 runtime 的边界。
2. 再读 [A03](./A03-prompt.md) 到 [A05](./A05-loop.md)，把 `prompt -> loop -> processor` 吃透。
3. 接着看 [A06](./A06-llm.md) 和 [A07](./A07-state.md)，理解“请求如何发出去、结果如何落回来”。
4. 最后回看 [B01](./B01-model.md) 到 [B06](./B06-philosophy.md)，把对象模型和设计哲学补齐。
