# CLI 启动链与运行模式：`gemini.tsx` 和 `nonInteractiveCli.ts` 怎样把 settings、auth、sandbox、resume、hooks 串成入口主链

主向导对应章节：`CLI 启动链与运行模式`

`packages/cli/src/gemini.tsx` 是 Gemini CLI 最适合作为入口读物的文件，因为它把“启动前要装配的所有现实约束”几乎全都收进来了。开头一段先挂上 admin controls listener、stdio patch、signal handler、slash command conflict handler，然后加载 settings 与 trusted folders，并在真正解析 argv 之前先清理 checkpoint、tool output 和 background log（`gemini-cli/packages/cli/src/gemini.tsx:187-233`）。这一步说明 CLI 启动并不是“拿到 prompt 直接跑模型”，而是先把会话宿主清理到可运行状态。

接下来是配置与认证阶段。`loadCliConfig()` 会把 settings、sessionId 和 argv 编译成 `partialConfig`，之后 `validateAuthMethod()` / `validateNonInteractiveAuth()` 与 `partialConfig.refreshAuth()` 负责在进入主运行模式之前把认证状态拉齐（`gemini-cli/packages/cli/src/gemini.tsx:303-335`）。如果当前进程还没有进入沙箱，`loadSandboxConfig()` 会决定是否需要 `start_sandbox()` 或重新拉起 child process，这一步把 stdin 注入 argv 的细节也一起处理掉了（`gemini-cli/packages/cli/src/gemini.tsx:363-418`）。这说明 sandbox 不是工具调用时才考虑的附加选项，而是入口阶段就决定的宿主切换。

`--resume` 的装配也在入口层完成。`SessionSelector.resolveSession()` 先把目标会话解析出来，再通过 `config.setSessionId()` 让后续记录继续写回同一 session（`gemini-cli/packages/cli/src/gemini.tsx:553-585`）。只有这些前置状态都准备好，CLI 才会决定进入 interactive UI 还是 non-interactive 模式：interactive 走 `startInteractiveUI()`，non-interactive 先 `config.initialize()`，再从 stdin 补齐输入、触发 `SessionStart` hook，并最终调用 `runNonInteractive()`（`gemini-cli/packages/cli/src/gemini.tsx:587-682`）。

`packages/cli/src/nonInteractiveCli.ts` 则把最清晰的执行主链暴露出来。它先创建 `Scheduler`，然后对输入做两类预处理：`handleSlashCommand()` 负责 slash 命令改写，`handleAtCommand()` 负责 `@` include 展开（`gemini-cli/packages/cli/src/nonInteractiveCli.ts:213-277`）。之后 `while (true)` 循环开始真正的回合推进：调用 `geminiClient.sendMessageStream()` 获取模型流事件，收集 `ToolCallRequest`，把文本输出增量写给终端或 JSON formatter，在回合结束后把工具请求交给 `scheduler.schedule()`，再把工具响应拼回 `currentMessages` 进入下一轮（`gemini-cli/packages/cli/src/nonInteractiveCli.ts:291-519`）。
