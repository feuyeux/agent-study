# 建议的阅读路径：先读协议清单，再读样板插件，最后读治理脚本

主向导对应章节：`建议的阅读路径`

如果你把 `claude-code` 当成运行时仓库来读，会很快失焦；最省时间的路线是按“分发协议 -> 插件实例 -> 治理代码”三步走。

第一步先读 `.claude-plugin/marketplace.json`（`claude-code/.claude-plugin/marketplace.json:1-149`）。这里不是为了记住有哪些插件，而是为了确认仓库中心对象到底是什么。只要你看到 `plugins[]` 如何把每个插件映射到 `./plugins/*`，就会意识到这套代码的第一真相是“市场索引”，不是“agent main loop”。

第二步读 `plugins/README.md`（`claude-code/plugins/README.md:47-70`）。这一步的目标是看清插件协议：Claude Code 到底期待一个插件目录长什么样，哪些槽位可选，哪些是必须补齐的。它会把你从“文档感”带到“接口感”。

第三步选一个样板插件走到底，首选 `feature-dev`。阅读顺序建议是：

1. `plugins/feature-dev/.claude-plugin/plugin.json`，确认 manifest 有多薄（`claude-code/plugins/feature-dev/.claude-plugin/plugin.json:1-9`）。
2. `plugins/feature-dev/commands/feature-dev.md`，看主工作流怎样被拆成七个 phase（`claude-code/plugins/feature-dev/commands/feature-dev.md:20-124`）。
3. `plugins/feature-dev/agents/code-explorer.md`，看子代理职责怎样被约束成具体输出格式，特别是 `file:line`、执行链、关键文件清单这些硬要求（`claude-code/plugins/feature-dev/agents/code-explorer.md:39-51`）。

第四步回头读治理链。先看 `scripts/issue-lifecycle.ts` 的规则表，再看 `scripts/lifecycle-comment.ts` 如何消费它，最后看 `scripts/sweep.ts` 如何批量应用它（`claude-code/scripts/issue-lifecycle.ts:3-38`; `claude-code/scripts/lifecycle-comment.ts:19-53`; `claude-code/scripts/sweep.ts:45-168`）。最后再用 `.github/workflows/sweep.yml` 对照一遍，确认 workflow 只是调度壳（`claude-code/.github/workflows/sweep.yml:14-30`）。

第五步再补 `examples/settings/README.md`（`claude-code/examples/settings/README.md:3-27`）。放到最后读的原因很简单：只有先理解“插件可分发、治理可集中化”这两个前提，才能真正看懂这些 settings 示例为什么要限制市场、hooks 和 permission rules。

按这条顺序读，读到最后你拿到的是一张协议图和治理图，而不是一堆零散插件说明。
