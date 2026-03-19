# app-server 与状态模型：`Thread*Params`、`Thread`、`Turn`、`ThreadItem` 为什么暴露了真正的协议面

主向导对应章节：`app-server 与状态模型`

`app-server/src/lib.rs` 的 `run_main_with_transport()` 是理解 app-server 的最佳起点。这个函数先为 transport event、outgoing envelope、outbound control 建立 channel，然后根据 `AppServerTransport` 选择 stdio 或 websocket 宿主（`codex/codex-rs/app-server/src/lib.rs:343-377`）。这说明 app-server 不是“另一套业务逻辑”，而是把同一套线程运行时挂在可替换传输层上。

真正值得细读的是协议定义。`app-server-protocol/src/protocol/v2.rs` 的 `ThreadStartParams` 把一个线程的创建条件写得非常清楚：模型、provider、service tier、cwd、approval policy、sandbox、base/developer instructions、personality、dynamic tools、persist_extended_history 都是线程级配置（`codex/codex-rs/app-server-protocol/src/protocol/v2.rs:2452-2506`）。`ThreadResumeParams` 和 `ThreadForkParams` 则把恢复与分叉视为同一类“基于已有历史重建线程”的操作，只是来源不同：history、path 或 thread id（`codex/codex-rs/app-server-protocol/src/protocol/v2.rs:2556-2609`; `codex/codex-rs/app-server-protocol/src/protocol/v2.rs:2640-2685`）。

响应结构也对应这种设计。`ThreadStartResponse`、`ThreadResumeResponse`、`ThreadForkResponse` 都返回 `thread`、`model`、`model_provider`、`cwd`、`approval_policy`、`sandbox`、`reasoning_effort` 等线程快照（`codex/codex-rs/app-server-protocol/src/protocol/v2.rs:2528-2540`; `codex/codex-rs/app-server-protocol/src/protocol/v2.rs:2614-2626`; `codex/codex-rs/app-server-protocol/src/protocol/v2.rs:2691-2703`）。这意味着对外协议的中心单元不是“单轮回答”，而是“某个具备配置和历史的线程实例”。

`Thread`、`Turn`、`ThreadItem` 则给出了状态模型的三层分解。`Thread` 保存线程级元信息，如 `id`、`preview`、`ephemeral`、`model_provider`、`status`、`path`、`cwd`、`source`（`codex/codex-rs/app-server-protocol/src/protocol/v2.rs:3456-3479`）；`Turn` 描述一次回合的状态与错误边界（`codex/codex-rs/app-server-protocol/src/protocol/v2.rs:3564-3573`）；`ThreadItem` 则把回合内部的内容实体化成 `UserMessage`、`AgentMessage`、`Plan`、`Reasoning`、`CommandExecution`、`FileChange` 等对象（`codex/codex-rs/app-server-protocol/src/protocol/v2.rs:4102-4155`）。

这套模型和 `ThreadManager` 是严丝合缝的。`start_thread*()`、`resume_thread*()`、`fork_thread()` 都统一回到 `spawn_thread()`，所以 app-server 的协议对象并不是平行设计出来的 DTO，而是对底层线程生命周期的直接外化（`codex/codex-rs/core/src/thread_manager.rs:344-430`; `codex/codex-rs/core/src/thread_manager.rs:536-557`）。
