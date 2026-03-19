# 先看 monorepo 形态：为什么 `packages/core` 是真正的系统中心

主向导对应章节：`先看 monorepo 形态`

根目录 `package.json` 只告诉你这是一个 workspace 仓库，`workspaces` 指向 `packages/*` 与 `integration-tests/*`，脚本里也主要是 build、lint、test、format 的总控（`gemini-cli/package.json:8-67`）。这些信息有用，但还不足以告诉你谁是系统中心。

真正的中心从 `packages/core/src/index.ts` 一眼就能看出来。这个 barrel file 不只是导出几个公共工具，而是把 config、policy、confirmation bus、turn、geminiChat、scheduler、fallback、skills、hooks、IDE、sandbox、tool registry、telemetry、browser、storage 等大块系统能力统一导出（`gemini-cli/packages/core/src/index.ts:7-243`）。换句话说，`core` 已经不是“共享工具包”，而是完整 agent engine 的公共面。

`packages/cli` 则更像宿主壳。`packages/cli/src/gemini.tsx` 负责把 settings、trusted folders、auth、sandbox、resume、hooks、UI 模式组装进启动流程（`gemini-cli/packages/cli/src/gemini.tsx:187-233`; `gemini-cli/packages/cli/src/gemini.tsx:303-418`; `gemini-cli/packages/cli/src/gemini.tsx:553-682`）；`packages/cli/src/nonInteractiveCli.ts` 则把单次 headless 运行折叠成一条显式循环（`gemini-cli/packages/cli/src/nonInteractiveCli.ts:291-519`）。CLI 很重要，但它消费的是 core 能力，不是定义 core 能力。

外围包也验证了同样的分工。`packages/sdk/src/agent.ts` 的 `GeminiCliAgent.session()` / `resumeSession()` 创建的是 `GeminiCliSession`，后者直接 new `Config`、加载技能、注册工具，再调用 core 里的 `GeminiClient` 与调度器（`gemini-cli/packages/sdk/src/agent.ts:18-84`; `gemini-cli/packages/sdk/src/session.ts:38-270`）。`packages/a2a-server/src/http/app.ts` 把 core 包进 HTTP 服务与任务创建入口（`gemini-cli/packages/a2a-server/src/http/app.ts:127-313`），VS Code companion 则把 IDE diff 能力和 MCP tool 暴露给外部代理（`gemini-cli/packages/vscode-ide-companion/src/extension.ts:122-210`; `gemini-cli/packages/vscode-ide-companion/src/ide-server.ts:438-478`）。

因此，这个 monorepo 最该记住的不是包名列表，而是层次关系：`packages/core` 是 agent engine，`packages/cli` 是默认终端宿主，`packages/sdk`、`packages/a2a-server`、`packages/vscode-ide-companion` 是其他宿主与连接面，`integration-tests` 是对这些宿主表面的行为回归。
