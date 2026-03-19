# 最终心智模型：把 Codex 看成“以线程协议为中心的多宿主 Rust runtime”

如果只用一句话概括 `codex`，最贴切的说法不是“OpenAI 的 CLI”，而是“一个以线程协议为中心、可以被 CLI、app-server、SDK 和其他宿主复用的 Rust runtime”。

这句话背后有四个直接源码支点：

- 宿主很多，但入口统一由 `Subcommand` 与 `cli_main()` 暴露和分流（`codex/codex-rs/cli/src/main.rs:88-152`; `codex/codex-rs/cli/src/main.rs:590-715`）。
- 运行时能力集中在 `codex-core`，尤其是 `ThreadManager` 对 start/resume/fork 的统一装配（`codex/codex-rs/core/src/lib.rs:8-182`; `codex/codex-rs/core/src/thread_manager.rs:344-430`; `codex/codex-rs/core/src/thread_manager.rs:536-557`）。
- app-server 把线程生命周期和内容模型公开成稳定协议：`Thread*Params`、`Thread`、`Turn`、`ThreadItem`（`codex/codex-rs/app-server-protocol/src/protocol/v2.rs:2452-2703`; `codex/codex-rs/app-server-protocol/src/protocol/v2.rs:3456-3479`; `codex/codex-rs/app-server-protocol/src/protocol/v2.rs:3564-3573`; `codex/codex-rs/app-server-protocol/src/protocol/v2.rs:4102-4155`）。
- JS/TS 层不复制实现，只桥接二进制和协议：`codex.js` 负责启动平台二进制，`CodexExec` 负责参数编译与 JSON 事件流解码，`Thread` 负责把事件流包装成更易用的线程接口（`codex/codex-cli/bin/codex.js:15-220`; `codex/sdk/typescript/src/exec.ts:72-226`; `codex/sdk/typescript/src/thread.ts:70-138`）。

所以读 Codex 时，最稳的脑内模型应该是：`cli` / `app-server` / `sdk` 是宿主，`thread` 是状态边界，`ThreadManager` 是装配与生命周期枢纽，`app-server-protocol` 是外部世界理解这套 runtime 的正式语法。
