# CLI 与运行时：`Subcommand`、`cli_main()`、`ThreadManager` 怎样把多种表面压到同一条 Rust 主干上

主向导对应章节：`CLI 与运行时`

`codex-rs/cli/src/main.rs` 最值得先看的类型是 `Subcommand`。这里把用户能看到的所有运行形态一次性摊开：`Exec`、`Review`、`Login`、`Mcp`、`McpServer`、`AppServer`、`Sandbox`、`Apply`、`Resume`、`Fork`、`Cloud` 等都被声明成同一个 enum 变体（`codex/codex-rs/cli/src/main.rs:88-152`）。这个设计很重要，因为它说明 Codex 没有为不同表面复制入口程序，而是先在命令层做统一分流。

真正的分流发生在 `cli_main()`。它先解析 root 级 config override 与 feature toggle，再按 `match subcommand` 把请求导向 `run_interactive_tui()`、`codex_exec::run_main()`、`codex_mcp_server::run_main()`、`codex_app_server::run_main_with_transport()`，或者把 `Resume` / `Fork` 重新折叠回交互式 TUI 启动路径（`codex/codex-rs/cli/src/main.rs:590-715`）。换句话说，CLI 层只负责宿主选择，不负责线程执行。

线程执行的共享枢纽在 `core/src/thread_manager.rs`。`ThreadManager::new()` 组装出 `PluginsManager`、`McpManager`、`SkillsManager`、`ModelsManager`、`file_watcher` 与 auth manager，把这些全挂进 `ThreadManagerState`（`codex/codex-rs/core/src/thread_manager.rs:239-264`）。后面的 `start_thread()`、`start_thread_with_tools()`、`start_thread_with_tools_and_service_name()` 都只是不同参数封装，最终统一调用 `state.spawn_thread()`（`codex/codex-rs/core/src/thread_manager.rs:344-390`）。`resume_thread_from_rollout()` 与 `resume_thread_with_history()` 先准备历史，再回到同一个 spawn 路径（`codex/codex-rs/core/src/thread_manager.rs:393-430`）；`fork_thread()` 也只是多做了一次截断，然后仍然回到 `spawn_thread()`（`codex/codex-rs/core/src/thread_manager.rs:536-557`）。

这条调用链揭示了 Codex 的一个关键设计：CLI 子命令很多，但线程生命周期入口极少。你无论是新建、恢复、分叉，还是通过 app-server 创建线程，本质上都在复用 `ThreadManager` 的同一套装配逻辑。

`core/src/lib.rs` 进一步解释了为什么这种集中化成立。它把 `plugins`、`mcp`、`shell`、`skills`、`sandboxing`、`models_manager`、`state_db`、`rollout` 等模块都公开在同一个 crate 里（`codex/codex-rs/core/src/lib.rs:8-126`），并把 `ThreadManager`、`RolloutRecorder`、`ModelClient` 等线程执行需要的核心类型一起对外暴露（`codex/codex-rs/core/src/lib.rs:128-182`）。这就是为什么 CLI 层可以保持很薄：运行时能力已经被收敛在 core。
