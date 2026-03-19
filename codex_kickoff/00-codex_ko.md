# Codex 源码 Kickoff

- [先看仓库形态：为什么 `codex-rs` 才是系统中心，而不是 npm 外壳](./01-repo-shape.md)
- [CLI 与运行时：`Subcommand`、`cli_main()`、`ThreadManager` 怎样把多种表面压到同一条 Rust 主干上](./02-rust-runtime-and-cli.md)
- [app-server 与状态模型：`Thread*Params`、`Thread`、`Turn`、`ThreadItem` 为什么暴露了真正的协议面](./03-app-server-and-state-model.md)
- [分发、SDK 与 shell 层：`codex.js`、TypeScript SDK、`shell-tool-mcp` 怎样把 Rust runtime 包出去](./04-packaging-sdk-and-shell-layer.md)
- [建议的阅读路径：先打通线程模型，再看 app-server，最后看 JS 封装](./05-reading-path.md)
- [最终心智模型：把 Codex 看成“以线程协议为中心的多宿主 Rust runtime”](./06-final-mental-model.md)

## 先抓住四个源码判断

- `codex-rs/Cargo.toml` 把 `cli`、`core`、`app-server`、`mcp-server`、`tui`、`exec`、`cloud-tasks` 等几十个 crate 收进同一个 workspace，说明 Codex 一开始就不是单体 CLI，而是围绕统一内核拆出的多表面系统（`codex/codex-rs/Cargo.toml:1-140`）。
- `cli/src/main.rs` 的 `Subcommand` 枚举直接暴露了产品面：`Exec`、`Review`、`McpServer`、`AppServer`、`Sandbox`、`Resume`、`Fork`、`Cloud` 都走同一个入口，而 `cli_main()` 只负责把参数导向不同 runtime（`codex/codex-rs/cli/src/main.rs:88-152`; `codex/codex-rs/cli/src/main.rs:590-715`）。
- 真正共享的内核集中在 `core/src/lib.rs` 和 `core/src/thread_manager.rs`。前者一次性公开 config、auth、MCP、plugins、skills、sandbox、shell、state、rollout 等模块，后者则把 `start_thread*()`、`resume_thread*()`、`fork_thread()` 收敛到统一的 spawn 路径（`codex/codex-rs/core/src/lib.rs:8-126`; `codex/codex-rs/core/src/thread_manager.rs:344-430`; `codex/codex-rs/core/src/thread_manager.rs:536-557`）。
- `app-server-protocol/src/protocol/v2.rs` 说明 Codex 的核心对象不是“当前 prompt”，而是线程协议。`ThreadStartParams`、`ThreadResumeParams`、`ThreadForkParams` 描述了线程如何创建/恢复/分叉，`Thread`、`Turn`、`ThreadItem` 描述了运行时状态如何被序列化成对外接口（`codex/codex-rs/app-server-protocol/src/protocol/v2.rs:2452-2703`; `codex/codex-rs/app-server-protocol/src/protocol/v2.rs:3456-3479`; `codex/codex-rs/app-server-protocol/src/protocol/v2.rs:3564-3573`; `codex/codex-rs/app-server-protocol/src/protocol/v2.rs:4102-4155`）。

## 最短源码路线

先读 `cli/src/main.rs` 看所有可见运行模式（`codex/codex-rs/cli/src/main.rs:88-152`; `codex/codex-rs/cli/src/main.rs:590-715`），再读 `thread_manager.rs` 看线程生命周期（`codex/codex-rs/core/src/thread_manager.rs:344-430`; `codex/codex-rs/core/src/thread_manager.rs:536-557`），随后用 `app-server-protocol` 理解线程协议（`codex/codex-rs/app-server-protocol/src/protocol/v2.rs:2452-2703`; `codex/codex-rs/app-server-protocol/src/protocol/v2.rs:3456-3479`; `codex/codex-rs/app-server-protocol/src/protocol/v2.rs:4102-4155`），最后再看 `codex.js`、`sdk/typescript` 与 `shell-tool-mcp` 怎么把这套 runtime 向外包装（`codex/codex-cli/bin/codex.js:15-220`; `codex/sdk/typescript/src/codex.ts:11-37`; `codex/sdk/typescript/src/thread.ts:41-138`; `codex/shell-tool-mcp/src/index.ts:9-25`）。
