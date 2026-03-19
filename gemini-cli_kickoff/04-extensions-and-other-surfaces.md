# 扩展与其他表面：SDK、A2A server、VS Code companion 怎样复用 core，而不是各写一套引擎

主向导对应章节：`扩展与其他表面`

最直接的外围宿主是 SDK。`packages/sdk/src/agent.ts` 的 `GeminiCliAgent` 只提供两件事：`session()` 创建新会话，`resumeSession()` 用 `Storage` 找回已有会话并构造 `GeminiCliSession`（`gemini-cli/packages/sdk/src/agent.ts:18-84`）。真正的工作在 `GeminiCliSession` 里：构造函数直接 new `Config`，把 `skillsSupport`、`adminSkillsEnabled`、`policyEngineConfig` 等最小运行参数写进去（`gemini-cli/packages/sdk/src/session.ts:47-87`）；`initialize()` 再负责 refreshAuth、initialize config、动态装载 skill、重注册 `ActivateSkillTool` 并把 SDK 自带工具包装成 `SdkTool` 挂进 registry（`gemini-cli/packages/sdk/src/session.ts:93-169`）。

`GeminiCliSession.sendStream()` 进一步说明 SDK 并没有私有 loop。它先在需要时动态生成 instructions，然后调用 `client.sendMessageStream()`；如果模型返回工具请求，就复制一份 scoped `ToolRegistry`，用 `scheduleAgentTools()` 执行，再把 `responseParts` 拼回下一轮请求（`gemini-cli/packages/sdk/src/session.ts:171-270`）。这和 CLI 的非交互模式是同一套 loop 语义，只是宿主换成了 SDK。

`packages/a2a-server` 则把这套能力包进 HTTP。`src/http/app.ts` 里 `handleExecuteCommand()` 会根据 `commandRegistry` 找命令，若命令声明 `streaming` 就建立 `DefaultExecutionEventBus` 并以 SSE 形式把事件写给响应（`gemini-cli/packages/a2a-server/src/http/app.ts:127-178`）。创建任务的路径则通过 `agentExecutor.createTask()` 把 agent settings 和 context id 变成可持久化任务对象（`gemini-cli/packages/a2a-server/src/http/app.ts:254-313`）。`main()` 最终只负责启动 Express app 并写出实际端口（`gemini-cli/packages/a2a-server/src/http/app.ts:372-389`）。

VS Code companion 走的是 IDE + MCP 双桥路线。`src/extension.ts` 先创建 `DiffContentProvider` 与 `DiffManager`，注册 `gemini.diff.accept` / `gemini.diff.cancel` 命令，再启动 `IDEServer` 并同步工作区环境变量（`gemini-cli/packages/vscode-ide-companion/src/extension.ts:122-210`）。`src/ide-server.ts` 在 HTTP 层监听随机端口，写出端口文件供其他进程发现（`gemini-cli/packages/vscode-ide-companion/src/ide-server.ts:340-351`），同时构造 `McpServer` 并注册 `openDiff`、`closeDiff` 等工具，把 IDE diff 能力投射成 MCP 可调用接口（`gemini-cli/packages/vscode-ide-companion/src/ide-server.ts:438-478`）。

把这些外围表面放在一起看，Gemini CLI 的扩展策略很统一：保持 `packages/core` 的 loop、policy、tool、session 语义不变，只在外层替换宿主协议。SDK 替换成程序化 API，A2A server 替换成 HTTP 任务接口，VS Code companion 则替换成 IDE/MCP 桥。
