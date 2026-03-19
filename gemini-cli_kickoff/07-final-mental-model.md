# 最终心智模型：把 Gemini CLI 看成“TypeScript agent engine + 多宿主薄壳”

如果只用一句话概括 `gemini-cli`，最准确的说法不是“一个命令行工具”，而是“一个写在 TypeScript 里的 agent engine，被 CLI、SDK、A2A server、VS Code companion 等多个宿主包起来”。

这句话背后的源码支点很直接：

- `packages/core/src/index.ts` 暴露了完整引擎面，所以 `core` 是系统中心，不是工具库（`gemini-cli/packages/core/src/index.ts:7-243`）。
- `packages/cli/src/gemini.tsx` 负责宿主启动与运行模式切换，`packages/cli/src/nonInteractiveCli.ts` 负责把一次请求推进成显式 loop（`gemini-cli/packages/cli/src/gemini.tsx:187-233`; `gemini-cli/packages/cli/src/gemini.tsx:303-418`; `gemini-cli/packages/cli/src/gemini.tsx:553-682`; `gemini-cli/packages/cli/src/nonInteractiveCli.ts:291-519`）。
- `GeminiChat`、`Turn`、`Scheduler`、`PolicyEngine` 共同构成真正的执行闭环：模型流、工具请求、工具调度、策略审批各占一层（`gemini-cli/packages/core/src/core/geminiChat.ts:249-330`; `gemini-cli/packages/core/src/core/turn.ts:253-426`; `gemini-cli/packages/core/src/scheduler/scheduler.ts:93-210`; `gemini-cli/packages/core/src/policy/policy-engine.ts:163-315`）。
- SDK、A2A server、VS Code companion 全都复用同一套 core 语义，只是换了宿主接口（`gemini-cli/packages/sdk/src/session.ts:38-270`; `gemini-cli/packages/a2a-server/src/http/app.ts:127-313`; `gemini-cli/packages/vscode-ide-companion/src/extension.ts:122-210`; `gemini-cli/packages/vscode-ide-companion/src/ide-server.ts:438-478`）。

所以最稳的脑内图其实很简单：`core` 是引擎，`cli` 是默认终端宿主，`sdk` / `a2a-server` / `vscode-ide-companion` 是其他宿主，`integration-tests` 是这些宿主对外承诺的回归面。
