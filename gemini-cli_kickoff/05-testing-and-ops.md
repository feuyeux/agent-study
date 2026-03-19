# 测试与运维：`integration-tests/` 为什么能直接反映产品表面

主向导对应章节：`测试与运维`

`gemini-cli` 的 `integration-tests/` 很值得读，因为它不是抽象单元测试集合，而是直接沿着产品表面命名。比如 `policy-headless.test.ts` 会从真实 headless 场景出发，验证工具调用日志、审批策略和策略落地后的行为差异（`gemini-cli/integration-tests/policy-headless.test.ts:19-205`）。你从文件名和断言内容里看到的，基本就是 CLI 对外承诺的功能面。

`hooks-system.test.ts` 则把 hooks 当成正式扩展面来测，而不是“顺带验证”。它覆盖 `BeforeTool` 阻断、stderr deny 和 allow 决策等路径，说明 hooks 在系统里具有真实的执行控制权（`gemini-cli/integration-tests/hooks-system.test.ts:25-220`）。这和入口层 `gemini.tsx` 在 `config.initialize()` 之后触发 `SessionStart` hook 的设计是对应的（`gemini-cli/packages/cli/src/gemini.tsx:614-640`）。

`checkpointing.test.ts` 证明会话恢复不是薄功能。它会通过 `GitService` 和 `Storage` 验证 snapshot/restore 流程，并确认隔离 git identity 的行为（`gemini-cli/integration-tests/checkpointing.test.ts:50-154`）。这与入口层的 `--resume` 逻辑、SDK 的 `resumeSession()`、以及 `GeminiChat` 的历史初始化一起，构成“会话可恢复”这一产品承诺的完整证据链（`gemini-cli/packages/cli/src/gemini.tsx:553-585`; `gemini-cli/packages/sdk/src/agent.ts:30-84`; `gemini-cli/packages/core/src/core/geminiChat.ts:256-271`）。

`browser-agent.test.ts` 更能看出测试面和产品面的贴合程度。文件开头就声明它在跑真实 Chrome，后续覆盖导航、快照、截图、交互以及工具确认路径（`gemini-cli/integration-tests/browser-agent.test.ts:8-234`）。这说明浏览器能力在仓库里不是实验性 demo，而是被视为需要端到端回归的正式表面。

运维侧的线索则藏在入口和外围宿主里。`gemini.tsx` 启动时会清理 checkpoint、tool output file、background logs，并把 startup profiler 的阶段信息记录下来（`gemini-cli/packages/cli/src/gemini.tsx:209-230`; `gemini-cli/packages/cli/src/gemini.tsx:601-603`）；A2A server 的 `main()` 会在启动后更新 agent card URL 并输出监听地址（`gemini-cli/packages/a2a-server/src/http/app.ts:372-389`）；VS Code companion 的 `IDEServer.start()` 会写端口文件供外部发现（`gemini-cli/packages/vscode-ide-companion/src/ide-server.ts:340-351`）。
