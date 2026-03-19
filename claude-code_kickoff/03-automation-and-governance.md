# 自动化与治理：生命周期脚本、settings 示例、GitHub workflow 如何共享同一份规则源

主向导对应章节：`自动化与治理`

`claude-code` 的治理链不是零散脚本，而是围绕 `scripts/issue-lifecycle.ts` 这份规则源展开的。这个文件把所有生命周期状态压进 `lifecycle` 常量：`invalid`、`needs-repro`、`needs-info`、`stale`、`autoclose` 各自携带 `days`、`reason`、`nudge`，并导出 `LifecycleLabel` 类型与 `STALE_UPVOTE_THRESHOLD` 常量（`claude-code/scripts/issue-lifecycle.ts:3-38`）。它的作用相当于“社区治理枚举表 + 过期策略表 + 用户沟通文案表”的合体。

`scripts/lifecycle-comment.ts` 直接消费这份表。它读取环境变量里的 `LABEL` 和 `ISSUE_NUMBER`，用 `lifecycle.find()` 取出对应条目，再把 `entry.nudge` 和 `entry.days` 拼成评论正文发到 GitHub issue（`claude-code/scripts/lifecycle-comment.ts:8-53`）。也就是说，贴标签后的自动提醒并不是另一份硬编码文案，而是和生命周期定义共享同一个数据源。

`scripts/sweep.ts` 则把同一份规则源推进到批处理治理。`markStale()` 用 `lifecycle.find((l) => l.label === "stale")!.days` 计算 stale 截止日期，并结合 `STALE_UPVOTE_THRESHOLD` 决定是否跳过高票问题（`claude-code/scripts/sweep.ts:45-90`）。`closeExpired()` 再遍历整个 `lifecycle` 数组，按每个 label 的 `days`、`reason` 去拉 issue 事件、检查评论、决定是否自动关闭（`claude-code/scripts/sweep.ts:92-168`）。这里的关键设计是：关闭策略不是写死在 workflow 里，而是写死在 TypeScript 数据模型里。

workflow 只是调度层。`.github/workflows/sweep.yml` 负责定时触发 `bun run scripts/sweep.ts`，把 GitHub token 和仓库元数据注入进去（`claude-code/.github/workflows/sweep.yml:14-30`）；`issue-lifecycle-comment.yml` 则负责在标签事件发生时运行 `bun run scripts/lifecycle-comment.ts`（调用关系已通过仓库内引用验证，workflow 文件位于 `claude-code/.github/workflows/issue-lifecycle-comment.yml:1-23`）。所以真正的制度不在 YAML，而在脚本和数据结构里。

settings 示例提供的是另一种治理面。`examples/settings/README.md` 先声明这些 JSON 主要用于组织级部署，再明确指出 `strictKnownMarketplaces`、`allowManagedHooksOnly`、`allowManagedPermissionRulesOnly` 这类开关只有 enterprise settings 才会生效（`claude-code/examples/settings/README.md:3-6`）。随后它用表格说明 lax、strict、bash-sandbox 三种策略模板分别约束什么，例如禁止 `--dangerously-skip-permissions`、阻断插件市场、禁止自定义 hooks、要求 Bash 进沙箱（`claude-code/examples/settings/README.md:13-27`）。这说明 Claude Code 的治理并不局限于 GitHub issue 运维，还覆盖运行时权限与扩展来源控制。

把这些代码放在一起看，仓库的治理面其实非常清楚：TypeScript 规则源定义制度，脚本把制度应用到平台事件，workflow 只做定时和触发，settings 示例则把同样的“集中控制”思想延伸到产品配置面。
