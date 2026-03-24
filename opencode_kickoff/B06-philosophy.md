# OpenCode 深度专题 B06：设计哲学：固定骨架与晚绑定策略

本篇把 “Skeleton & Strategy” 直接落到代码上。OpenCode 的设计哲学体现在 `prompt.ts`、`processor.ts`、`llm.ts`、`tool/registry.ts` 这些固定接缝里。

## 一、固定骨架在哪些行

| 骨架节点 | 文件与代码行 | 为什么说它是固定骨架 |
| --- | --- | --- |
| `prompt()` | `packages/opencode/src/session/prompt.ts:162-188` | 先 cleanup，再写 user message，再进 loop。 |
| `loop()` | `packages/opencode/src/session/prompt.ts:278-736` | 所有 session 级分支都必须从这里过。 |
| `process()` | `packages/opencode/src/session/processor.ts:46-425` | 所有单轮流事件都必须在这里落成 parts。 |
| durable 写路径 | `packages/opencode/src/session/index.ts:686-788` | message/part 只有这一套正式写入口。 |
| runtime 回放 | `packages/opencode/src/session/message-v2.ts:838-898` | 下一轮永远从 durable history 重建现场。 |

只要这条骨架不变，OpenCode 的可恢复性和可审计性就不会塌。

## 二、晚绑定策略在哪些行

| 策略点 | 文件与代码行 | 晚绑定发生在什么地方 |
| --- | --- | --- |
| provider prompt 选择 | `packages/opencode/src/session/system.ts:17-26` | 按模型家族切 `PROMPT_CODEX`/`PROMPT_GEMINI`/`PROMPT_ANTHROPIC`。 |
| 环境与技能注入 | `packages/opencode/src/session/system.ts:28-67` | cwd、平台、日期、skills 都在请求前最后拼上。 |
| 指令文件解析 | `packages/opencode/src/session/instruction.ts:72-141` | AGENTS/CLAUDE/config.instructions 在请求前动态装载。 |
| 参数合并 | `packages/opencode/src/session/llm.ts:97-145` | model/agent/variant/options 到最后一刻才 merge。 |
| headers/tool 修补 | `packages/opencode/src/session/llm.ts:147-186`, `222-265` | headers、LiteLLM `_noop`、tool repair 都在 request-time 生效。 |
| 工具定义装配 | `packages/opencode/src/tool/registry.ts:155-195` | 按 provider、model、flag 选择 edit/write 还是 apply_patch。 |
| 插件钩子 | `packages/opencode/src/plugin/index.ts:159-174` | system、message、tool definition、headers 都可在固定插槽被改写。 |

这就是“骨架固定，策略晚绑定”的真实落点。

## 三、为什么 OpenCode 不是“高度可配的工作流引擎”

因为它明确拒绝把骨架也做成配置：

- 没有让插件改写 `prompt -> loop -> process` 顺序。
- 没有让 agent 自定义 durable 写路径。
- 没有让工具绕过 `Session.updatePart()` 直接产生 UI 状态。

相反，插件和配置只能在 system、headers、tools、messages transform 这些固定插槽里介入。对应坐标分别是 `packages/opencode/src/plugin/index.ts:159-174`、`packages/opencode/src/session/prompt.ts:653`、`packages/opencode/src/session/llm.ts:85-159`、`packages/opencode/src/tool/registry.ts:155-195`。

## 四、这套哲学换来了什么

1. 可恢复：下一轮永远从 `MessageV2.stream()` 回放，而不是从调用栈恢复。
2. 可扩展：provider、tool、plugin、skill 都能接进来，但接缝固定。
3. 可调试：任意阶段出问题，都能回到具体 message/part、具体 bus event、具体 DB 写路径去看。

这也是为什么 OpenCode 代码看上去“硬”，但长期演进反而更稳。
