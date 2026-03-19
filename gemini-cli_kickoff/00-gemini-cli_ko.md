# Gemini CLI 源码 Kickoff

- [先看 monorepo 形态：为什么 `packages/core` 是真正的系统中心](./01-monorepo-shape.md)
- [CLI 启动链与运行模式：`gemini.tsx` 和 `nonInteractiveCli.ts` 怎样把 settings、auth、sandbox、resume、hooks 串成入口主链](./02-cli-startup-and-modes.md)
- [core engine、tools 与 policy：`GeminiChat`、`Turn`、`Scheduler`、`PolicyEngine` 在哪里闭环](./03-core-engine-tools-and-policy.md)
- [扩展与其他表面：SDK、A2A server、VS Code companion 怎样复用 core，而不是各写一套引擎](./04-extensions-and-other-surfaces.md)
- [测试与运维：`integration-tests/` 为什么能直接反映产品表面](./05-testing-and-ops.md)
- [建议的阅读路径：先入口，再主循环，再外围宿主](./06-reading-path.md)
- [最终心智模型：把 Gemini CLI 看成“TypeScript agent engine + 多宿主薄壳”](./07-final-mental-model.md)

## 先抓住四个源码判断

- 根目录 `package.json` 的 workspaces 只是告诉你这是个 monorepo；真正的系统中心从 `packages/core/src/index.ts` 开始，因为这里把 config、policy、turn、scheduler、tools、hooks、skills、IDE、telemetry 全部 re-export 出去（`gemini-cli/package.json:8-67`; `gemini-cli/packages/core/src/index.ts:7-243`）。
- `packages/cli/src/gemini.tsx` 是产品入口链，不是简单 UI 壳。它负责加载 settings、trusted folders、auth、sandbox、resume、hooks，再决定走 interactive UI 还是 non-interactive loop（`gemini-cli/packages/cli/src/gemini.tsx:187-233`; `gemini-cli/packages/cli/src/gemini.tsx:303-418`; `gemini-cli/packages/cli/src/gemini.tsx:553-682`）。
- 真正的 agent 主循环分布在 `GeminiChat.sendMessageStream()`、`Turn.run()`、`Scheduler.schedule()` 三层：前者序列化发往模型的消息，第二层把流式响应拆成内容/思考/工具调用事件，第三层把工具调用推进到执行与确认系统（`gemini-cli/packages/core/src/core/geminiChat.ts:249-330`; `gemini-cli/packages/core/src/core/turn.ts:238-447`; `gemini-cli/packages/core/src/scheduler/scheduler.ts:93-210`）。
- `packages/sdk`、`packages/a2a-server`、`packages/vscode-ide-companion` 都在消费 core，而不是平行重写。`GeminiCliSession` 直接创建 `Config`、注册技能与工具、调用 `GeminiClient.sendMessageStream()`；A2A server 与 VS Code companion 则分别把 core 包到 HTTP 和 IDE/MCP 边界上（`gemini-cli/packages/sdk/src/session.ts:38-270`; `gemini-cli/packages/a2a-server/src/http/app.ts:127-313`; `gemini-cli/packages/vscode-ide-companion/src/extension.ts:122-210`; `gemini-cli/packages/vscode-ide-companion/src/ide-server.ts:438-478`）。
