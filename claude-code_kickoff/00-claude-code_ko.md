# Claude Code 源码 Kickoff

- [先划清边界：这个仓库公开出来的不是 Claude Code 内核，而是插件协议与治理层](./01-repo-role-and-boundary.md)
- [插件市场与插件骨架：`marketplace.json`、`plugin.json`、`commands/`、`agents/` 在源码里怎样拼装成一个可分发单元](./02-plugin-marketplace-and-shape.md)
- [自动化与治理：生命周期脚本、settings 示例、GitHub workflow 如何共享同一份规则源](./03-automation-and-governance.md)
- [建议的阅读路径：先读协议清单，再读样板插件，最后读治理脚本](./04-reading-path.md)
- [最终心智模型：把 `claude-code` 看成“插件分发协议 + 治理自动化仓”](./05-final-mental-model.md)

## 先抓住三个源码判断

- 这个仓库最靠近“主入口”的对象不是某个 agent runtime，而是 `.claude-plugin/marketplace.json` 的 `plugins` 列表；它把仓库组织成一个市场索引，每一项都只负责把安装源指向 `plugins/*` 子目录（`claude-code/.claude-plugin/marketplace.json:1-149`）。
- 插件的稳定接口是目录协议而不是类层级。`plugins/README.md` 把 `.claude-plugin/plugin.json`、`commands/`、`agents/`、`skills/`、`hooks/` 定义成标准骨架，所以这里真正被维护的是“Claude Code 能消费什么扩展形状”（`claude-code/plugins/README.md:47-70`）。
- 仓库另一条硬主线是治理自动化。`scripts/issue-lifecycle.ts` 的 `lifecycle` 常量和 `LifecycleLabel` 类型被 `scripts/sweep.ts` 与 `scripts/lifecycle-comment.ts` 复用，再由 `.github/workflows/sweep.yml` 和 `issue-lifecycle-comment.yml` 触发，这说明 issue 运维是代码化的，不是人工约定（`claude-code/scripts/issue-lifecycle.ts:3-38`; `claude-code/scripts/sweep.ts:45-168`; `claude-code/scripts/lifecycle-comment.ts:19-53`; `claude-code/.github/workflows/sweep.yml:14-30`）。

## 真正值得盯住的对象

- `feature-dev` 插件是最适合读的样板。它的 `plugin.json` 只保存最薄的 manifest，而真正的行为分布在 `commands/feature-dev.md` 的七阶段流程和 `agents/code-explorer.md` 的分析契约里（`claude-code/plugins/feature-dev/.claude-plugin/plugin.json:1-9`; `claude-code/plugins/feature-dev/commands/feature-dev.md:20-124`; `claude-code/plugins/feature-dev/agents/code-explorer.md:11-51`）。
- `code-explorer` 代理的输出约束本身就暴露了 Anthropic 想要的工程阅读方式：必须回到 entry point、执行流、依赖、架构层，并强制带 `file:line` 引用。这和普通“会聊天的 prompt”不同，它已经是一个很具体的代码分析协议（`claude-code/plugins/feature-dev/agents/code-explorer.md:21-51`）。
- `examples/settings/README.md` 则给出另一类接口面：不是 prompt，而是组织级控制面。这里明确列出哪些能力只能在 enterprise settings 生效，例如 `strictKnownMarketplaces`、`allowManagedHooksOnly`、`allowManagedPermissionRulesOnly`，说明 Claude Code 生态不是只有插件安装面，还有集中治理面（`claude-code/examples/settings/README.md:3-27`）。

## 最短阅读路线

如果你只想用最短路径读懂这个仓库，先看 `.claude-plugin/marketplace.json`（`claude-code/.claude-plugin/marketplace.json:1-149`）确认分发单元，再看 `plugins/README.md`（`claude-code/plugins/README.md:47-70`）确认插件协议，随后用 `feature-dev` 贯穿一次 `plugin.json -> command markdown -> agent markdown` 的装配链（`claude-code/plugins/feature-dev/.claude-plugin/plugin.json:1-9`; `claude-code/plugins/feature-dev/commands/feature-dev.md:20-124`; `claude-code/plugins/feature-dev/agents/code-explorer.md:16-51`），最后回到 `issue-lifecycle.ts`、`sweep.ts` 与 `lifecycle-comment.ts` 看治理代码怎样复用同一份规则源（`claude-code/scripts/issue-lifecycle.ts:3-38`; `claude-code/scripts/sweep.ts:45-168`; `claude-code/scripts/lifecycle-comment.ts:19-53`）。
