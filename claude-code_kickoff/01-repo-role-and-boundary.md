# 先划清边界：这个仓库公开出来的不是 Claude Code 内核，而是插件协议与治理层

主向导对应章节：`先划清边界`

这篇最重要的结论是：当前 checkout 里没有一条可以和 `opencode`、`codex`、`gemini-cli` 对应的 agent runtime 主链；可持续维护的中心对象是插件市场、插件骨架和治理脚本。

第一层证据来自市场清单。`.claude-plugin/marketplace.json` 把仓库命名成 `claude-code-plugins`，核心字段是 `plugins[]`，每个条目只声明 `name`、`description`、`source`、`category`，把真实内容交给 `./plugins/<name>` 子树（`claude-code/.claude-plugin/marketplace.json:1-149`）。这说明仓库中心不是单个产品二进制，而是“可安装插件集合”。

第二层证据来自插件协议。`plugins/README.md` 没有描述任何 runtime 类，而是直接定义插件目录结构：`.claude-plugin/plugin.json` 承载元数据，`commands/` 承载 slash command，`agents/` 承载专门代理，`skills/` 与 `hooks/` 提供额外能力，`.mcp.json` 负责外部工具配置（`claude-code/plugins/README.md:47-61`）。如果一个仓库的“核心架构图”本质上是目录约定，那它的角色就已经更接近协议仓，而不是执行内核。

第三层证据来自样板插件。`plugins/feature-dev/.claude-plugin/plugin.json` 极薄，只保留名字、版本和作者信息（`claude-code/plugins/feature-dev/.claude-plugin/plugin.json:1-9`）；真正的行为在 `commands/feature-dev.md` 中展开为七个 phase，从 discovery 到 summary 一路写成 prompt contract（`claude-code/plugins/feature-dev/commands/feature-dev.md:20-124`）。`agents/code-explorer.md` 又把一个分析子代理压成另一份 contract，明确要求输出 entry point、执行流、架构层和 `file:line` 引用（`claude-code/plugins/feature-dev/agents/code-explorer.md:16-51`）。换句话说，这个仓库发布的是“工作流与角色定义”，不是“执行器实现”。

第四层证据来自治理面。`examples/settings/README.md` 说明 settings 示例主要服务于组织级部署，并点名若干只能在 enterprise settings 生效的字段（`claude-code/examples/settings/README.md:3-27`）。`scripts/issue-lifecycle.ts` 定义了 `lifecycle` 和 `LifecycleLabel`，随后被 `scripts/sweep.ts` 的 `markStale()` / `closeExpired()` 以及 `scripts/lifecycle-comment.ts` 的评论逻辑复用（`claude-code/scripts/issue-lifecycle.ts:3-38`; `claude-code/scripts/sweep.ts:45-168`; `claude-code/scripts/lifecycle-comment.ts:19-53`）。这说明仓库另一半职责是“官方生态治理工具箱”。

所以读这个仓库时要主动收缩问题域：不要追问“Claude Code 如何调度模型回合”，因为这份公开仓并没有把那条链放出来；应该追问的是“Claude Code 官方允许什么扩展被装进去”“这些扩展用什么清单与目录协议分发”“组织和社区治理规则怎样被代码化”。
