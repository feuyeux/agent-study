# 先看仓库形态：为什么 `codex-rs` 才是系统中心，而不是 npm 外壳

主向导对应章节：`先看仓库形态`

判断仓库重心最简单的方法，是看谁在组织真正的依赖图。`codex-rs/Cargo.toml` 的 workspace 一口气收进 `cli`、`core`、`app-server`、`app-server-protocol`、`mcp-server`、`exec`、`tui`、`cloud-tasks` 以及大量 utils crate（`codex/codex-rs/Cargo.toml:1-140`）。这不是“一个 CLI 带若干子模块”的规模，而是“一个运行时平台被拆成多个宿主与服务”的规模。

`core/src/lib.rs` 则进一步证明谁是中心。这个文件不是简短 re-export，而是把 `auth`、`config`、`mcp`、`plugins`、`sandboxing`、`shell`、`skills`、`state_db`、`rollout`、`thread_manager` 等核心模块全都暴露出来（`codex/codex-rs/core/src/lib.rs:8-126`），同时继续 re-export `ThreadManager`、`CodexThread`、`ModelClient`、`ResponseStream` 等运行时关键类型（`codex/codex-rs/core/src/lib.rs:101-182`）。从这里看，`core` 更像产品内核，而 `cli`/`app-server` 更像不同入口壳。

反过来看 JS 层，角色就薄很多。`codex-cli/bin/codex.js` 只解决三件事：根据 `process.platform` / `process.arch` 计算 target triple，定位平台包里的二进制路径，再用 `spawn()` 把 argv 和信号转发给真正的 `codex` 可执行文件（`codex/codex-cli/bin/codex.js:15-21`; `codex/codex-cli/bin/codex.js:27-118`; `codex/codex-cli/bin/codex.js:175-220`）。这意味着 npm 包本身并不是实现层，只是二进制分发层。

TypeScript SDK 也验证了这种分工。`sdk/typescript/src/codex.ts` 的 `Codex` 类只持有一个 `CodexExec`，并把 `startThread()` / `resumeThread()` 映射成 `Thread` 对象创建（`codex/sdk/typescript/src/codex.ts:11-37`）。`sdk/typescript/src/exec.ts` 的 `CodexExec.run()` 则直接拼出 `exec --experimental-json` 命令行，向子进程写入输入并把 stdout 当 JSON 事件流读回来（`codex/sdk/typescript/src/exec.ts:57-226`）。也就是说，SDK 并没有“重写 Codex”，只是消费已经存在的 CLI 协议。

因此，仓库形态可以概括成两层：

- Rust workspace 负责运行时与协议：`codex-rs/*`（`codex/codex-rs/Cargo.toml:1-140`; `codex/codex-rs/core/src/lib.rs:8-182`）。
- JS/TS 层负责分发、封装和生态接入：`codex-cli`、`sdk/typescript`、`shell-tool-mcp`（`codex/codex-cli/bin/codex.js:15-220`; `codex/sdk/typescript/src/codex.ts:11-37`; `codex/shell-tool-mcp/src/index.ts:9-25`）。

把这个边界先看清，后面读 CLI、app-server、SDK 才不会误以为它们各自有独立引擎；它们共享的是同一个 Rust 线程运行时。
