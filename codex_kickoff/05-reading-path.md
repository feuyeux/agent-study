# 建议的阅读路径：先打通线程模型，再看 app-server，最后看 JS 封装

主向导对应章节：`建议的阅读路径`

读 `codex` 最容易迷路的地方，是 crate 太多、表面太多。最省时间的路线是先抓线程模型，再回到各个宿主。

第一步看 `cli/src/main.rs`，但只看两处：`Subcommand` 和 `cli_main()`（`codex/codex-rs/cli/src/main.rs:88-152`; `codex/codex-rs/cli/src/main.rs:590-715`）。目标不是记所有命令，而是确认产品表面到底有哪些，以及这些表面是怎样被折叠到少数入口上的。

第二步立刻转到 `core/src/thread_manager.rs`（`codex/codex-rs/core/src/thread_manager.rs:239-430`; `codex/codex-rs/core/src/thread_manager.rs:536-557`）。这里是全仓最重要的调用汇合点，因为 start、resume、fork 都会回到统一 spawn 路径。这个文件没看懂，后面 app-server 和 SDK 都会被误读成“另一套东西”。

第三步用 `app-server-protocol/src/protocol/v2.rs` 给线程模型补协议外壳（`codex/codex-rs/app-server-protocol/src/protocol/v2.rs:2452-2703`; `codex/codex-rs/app-server-protocol/src/protocol/v2.rs:3456-3479`; `codex/codex-rs/app-server-protocol/src/protocol/v2.rs:3564-3573`; `codex/codex-rs/app-server-protocol/src/protocol/v2.rs:4102-4155`）。重点只看三类对象：线程生命周期参数、线程与回合、回合内容。

第四步再读 `app-server/src/lib.rs` 的 `run_main_with_transport()`（`codex/codex-rs/app-server/src/lib.rs:343-377`）。这一步的目的只是确认 app-server 如何把线程 runtime 挂到 stdio/websocket 传输层上，不需要一开始就陷进去看所有 transport 细节。

第五步最后看 JS 层：`codex-cli/bin/codex.js`、`sdk/typescript/src/exec.ts`、`sdk/typescript/src/thread.ts`（`codex/codex-cli/bin/codex.js:15-220`; `codex/sdk/typescript/src/exec.ts:72-226`; `codex/sdk/typescript/src/thread.ts:70-138`）。等你已经理解线程协议后，再看这些文件就会很轻松，因为它们几乎都在做参数翻译和事件转发。
