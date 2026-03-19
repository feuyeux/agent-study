# 分发、SDK 与 shell 层：`codex.js`、TypeScript SDK、`shell-tool-mcp` 怎样把 Rust runtime 包出去

主向导对应章节：`分发、SDK 与 shell 层`

npm 层最核心的文件是 `codex-cli/bin/codex.js`。它用 `PLATFORM_PACKAGE_BY_TARGET` 把 target triple 映射到平台包名，再根据 `process.platform` / `process.arch` 选出当前二进制，必要时从已安装的平台包或本地 `vendor` 目录定位 `codex` 可执行文件（`codex/codex-cli/bin/codex.js:15-21`; `codex/codex-cli/bin/codex.js:27-118`）。后续 `spawn(binaryPath, process.argv.slice(2), { stdio: "inherit", env })` 和 `forwardSignal()` 只是把 Node 包装层变成一个忠实的过程代理（`codex/codex-cli/bin/codex.js:168-220`）。换句话说，这一层做的是分发与进程桥接，不做业务决策。

TypeScript SDK 也是类似思路。`sdk/typescript/src/codex.ts` 的 `Codex` 类只在构造时创建 `CodexExec`，然后让 `startThread()` / `resumeThread()` 返回 `Thread` 包装对象（`codex/sdk/typescript/src/codex.ts:11-37`）。真正的调用细节在 `sdk/typescript/src/exec.ts` 的 `CodexExec.run()`：它把 JS 侧参数翻译成 `exec --experimental-json` 命令行，写 stdin，逐行读取 stdout，并在子进程非零退出时抛出错误（`codex/sdk/typescript/src/exec.ts:72-226`）。

`sdk/typescript/src/thread.ts` 再在此基础上把“线程”暴露成更顺手的对象接口。`Thread.runStreamedInternal()` 先整理输入，再把 thread id、working directory、sandbox、approval policy、web search 等选项传给 `CodexExec.run()`；当收到 `thread.started` 事件时，它会把 `_id` 更新成真正的线程 id（`codex/sdk/typescript/src/thread.ts:70-112`）。`Thread.run()` 则继续把事件流折叠成 `items`、`finalResponse` 和 `usage` 三元组（`codex/sdk/typescript/src/thread.ts:115-138`）。所以 SDK 其实是在消费 app/CLI 已经存在的线程事件协议。

`shell-tool-mcp` 展示的是另一种包装方式。`src/index.ts` 的 `main()` 先解析平台，再调用 `resolveBashPath()` 输出当前应使用的 Bash 路径（`codex/shell-tool-mcp/src/index.ts:9-25`）。`src/bashSelection.ts` 里的 `selectLinuxBash()`、`selectDarwinBash()`、`resolveBashPath()` 则把 OS 识别、版本偏好和 fallback 路径明确编码出来（`codex/shell-tool-mcp/src/bashSelection.ts:10-115`）。它和主 CLI 一样，也是把运行时能力打包成可分发、可在外部系统消费的接口，而不是再造一套执行引擎。

把这三层连起来看，Codex 的外部表面有一个很统一的哲学：核心逻辑留在 Rust；Node/TypeScript 只做宿主对接、参数编译和事件解码。这样做的好处是所有宿主都共享同一条线程协议与行为语义，不会因为包装层不同而分叉实现。
