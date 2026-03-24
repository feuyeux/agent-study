# A 系列索引：OpenCode 执行主线深度解析

本文档按执行顺序逐段解析 OpenCode 的核心主线：**用户输入 → 路由 → prompt 编译 → loop 调度 → processor 单轮执行 → LLM 请求 → durable 写回 → 重新投影**。

共 7 篇，完整覆盖一次模型推理从发起到落盘的完整生命周期。

## 快速导航

| 篇 | 标题 | 核心坐标 | 解决的问题 |
|---|---|---|---|
| [A01](./A01-entry.md) | 多端入口与传输适配 | `run.ts:306-675`、`tui/thread.ts:65-225` | CLI/TUI/Web/Attach/Desktop/ACP 各端怎样统一汇到 session 协议 |
| [A02](./A02-server.md) | Server 与路由 | `server.ts:53-128`、`session.ts:781-919` | Hono app 怎样装配认证/CORS/日志中间件，请求怎样分发给 runtime |
| [A03](./A03-prompt.md) | 第 1 步：prompt 编译成 durable user message | `prompt.ts:162-188`、`createUserMessage()` | 用户输入怎样被编译成落盘的 message/part，file/agent/resource parts 怎样展开 |
| [A04](./A04-orchestrator.md) | 第 2 步：loop 决定下一轮，processor 负责单轮 | `prompt.ts:278-736`、`processor.ts:46-425` | loop 和 processor 的职责边界在哪里，subtask/compaction 由谁决策 |
| [A05](./A05-loop.md) | 第 3 步：loop 分支展开 | `prompt.ts:354-559` | subtask、compaction、overflow 三个分支各做什么操作 |
| [A06](./A06-llm.md) | 第 4 步：LLM.stream() 组装 provider 请求 | `llm.ts:48-290`、`provider.ts:1343-1368` | streamText 之前有哪四层铺垫，system/tools/params 怎样合并，tool call 修复逻辑 |
| [A07](./A07-state.md) | 第 5 步：消息写回 durable state 并重新投影 | `processor.ts:56-425`、`db.ts:126-162`、`bus/index.ts:41-64` | 流事件怎样分类处理，Database.effect 与 Bus.publish 的顺序，doom loop 检测 |

## 执行主线速览

```
用户输入 (CLI / TUI / Web / Attach / Desktop / ACP)
    │
    ▼
A01  多端传输适配
    └─ 本地: Server.Default().fetch()
    └─ 远端: HTTP POST /session/:id/message
    │
    ▼
A02  Hono Server 中间件 + /session 路由
    └─ Auth / CORS / 日志
    └─ → SessionPrompt.prompt()
    │
    ▼
A03  prompt() 编译用户输入
    ├─ SessionRevert.cleanup()
    ├─ createUserMessage() [file / agent / resource parts 展开]
    └─ loop()
    │
    ▼
A04  loop() = session 级状态机
    ├─ 找 lastUser / lastAssistant / lastFinished / tasks
    ├─ subtask / compaction / overflow 分支
    └─ → SessionProcessor.process()
    │
    ▼
A06  LLM.stream() 发起模型请求
    ├─ Provider.getLanguage() → LanguageModelV2
    ├─ system / tools / params 四层合并
    ├─ wrapLanguageModel() middleware
    └─ streamText() → HTTP 请求发出
    │
    ▼
A07  processor 消费流事件并写回
    ├─ reasoning / text → updatePart() + updatePartDelta()
    ├─ tool-call / tool-result / tool-error → 幂等状态机
    ├─ finish-step → usage / cost / snapshot / compaction 判断
    ├─ Database.effect() → Bus.publish()
    ├─ doom loop 检测
    └─ return "continue" | "compact" | "stop"
    │
    ▼
回到 A04 下一轮 loop
    或 CLI / TUI / Web 实时订阅 Bus 事件
    或前端分页回放 MessageV2.page() / stream()
```

## 各篇之间的真实关系

```
A01 ──► A02 ──► A03 ──► A04 ──► A05 ──► A06 ──► P ──► A07
                          ↑                        │
                          └────── loop 重启 ◄───────┘
```

- **A01 → A02**：传输层差异（本地 fetch vs HTTP），不影响 runtime 逻辑
- **A02 → A03**：请求路由边界，`prompt()` 是 runtime 的真正起点
- **A03 → A04**：同一进程中，`loop()` 接收 `prompt()` 的输出并开始调度
- **A04 ↔ A05**：A05 是 A04 的分支展开，`loop()` 是外壳，A05 是内芯
- **A04 → A06**：`SessionProcessor.process()` 在 A04 的 `571-688` 创建后，在 A06 的 `processor.ts:54` 被调用
- **A06 → A07**：同一次 `process()` 执行中，发起请求（`LLM.stream()`）和写回（`Session.update*()`）是前后两段，A06 讲前半段，A07 讲后半段

## 补充阅读

- **B05**（基础设施）与 **A07** 一起看 Durable State 层的完整实现
- **B03**（高级编排）与 **A04/A05** 一起看 loop 的编排能力
- **B01**（对象模型）定义 A03-A07 中流转的所有数据结构
