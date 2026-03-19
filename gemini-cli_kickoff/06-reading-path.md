# 建议的阅读路径：先入口，再主循环，再外围宿主

主向导对应章节：`建议的阅读路径`

如果你第一次读 `gemini-cli`，最稳的顺序不是从 `packages/core` 深处直接开挖，而是先拿到一条端到端主链。

第一步读 `packages/cli/src/gemini.tsx`（`gemini-cli/packages/cli/src/gemini.tsx:187-233`; `gemini-cli/packages/cli/src/gemini.tsx:303-418`; `gemini-cli/packages/cli/src/gemini.tsx:553-682`）。这一步只做一件事：确认 CLI 在进入主循环之前到底装配了哪些状态，尤其是 settings、auth、sandbox、resume、hooks。

第二步立刻读 `packages/cli/src/nonInteractiveCli.ts`（`gemini-cli/packages/cli/src/nonInteractiveCli.ts:213-519`）。原因很简单：这里的 loop 最直白，模型事件、工具请求、scheduler、工具响应回注都摆在明面上，比一开始钻 interactive UI 更容易建立整体感。

第三步转到 core 三件套：

1. `GeminiChat.sendMessageStream()` 看模型会话序列化与录制（`gemini-cli/packages/core/src/core/geminiChat.ts:249-330`; `gemini-cli/packages/core/src/core/geminiChat.ts:1010-1028`）。
2. `Turn.run()` 看事件拆解与工具请求生成（`gemini-cli/packages/core/src/core/turn.ts:253-426`）。
3. `Scheduler.schedule()` 与 `PolicyEngine.checkShellCommand()` 看工具批处理和策略判断（`gemini-cli/packages/core/src/scheduler/scheduler.ts:93-210`; `gemini-cli/packages/core/src/policy/policy-engine.ts:163-315`）。

第四步再读 `packages/core/src/index.ts`（`gemini-cli/packages/core/src/index.ts:7-243`）。这时你已经知道引擎怎么跑，再回来看 barrel file，就能把 skills、hooks、IDE、telemetry、browser、storage 等模块自然放回图里。

第五步最后补外围宿主：SDK、A2A server、VS Code companion（`gemini-cli/packages/sdk/src/session.ts:38-270`; `gemini-cli/packages/a2a-server/src/http/app.ts:127-313`; `gemini-cli/packages/vscode-ide-companion/src/extension.ts:122-210`; `gemini-cli/packages/vscode-ide-companion/src/ide-server.ts:438-478`）。顺序放在后面，是为了避免把“怎么接入 core”误认为“core 怎么工作”。
