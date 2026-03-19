# 最终心智模型：把 `claude-code` 看成“插件分发协议 + 治理自动化仓”

如果只用一句话概括当前 checkout，最准确的说法不是“Claude Code 的 agent 内核”，而是“Claude Code 官方用来分发插件、固化插件骨架、演示组织级配置、维护社区治理脚本的协议仓”。

这个判断直接落在几处源码事实上：

- `.claude-plugin/marketplace.json` 以插件清单为仓库中心，条目按 `name`、`description`、`path`、`git.url`、`git.subdirectory` 组织，并把真正可安装的单元指向 `plugins/*` 子目录（`claude-code/.claude-plugin/marketplace.json:2-149`）。
- `plugins/README.md` 给出的标准骨架不是运行时类图，而是一个插件目录应该怎样摆放 `.claude-plugin/plugin.json`、`commands/`、`agents/`、`skills/`、`hooks/`，这说明仓库真正稳定维护的是扩展接口和发布形态（`claude-code/plugins/README.md:47-61`）。
- `plugins/feature-dev/.claude-plugin/plugin.json` 把一个插件压缩成 manifest，`commands/feature-dev.md` 和 `agents/code-explorer.md` 再把工作流与子代理职责展开，所以“产品能力”在这里主要以 prompt contract 的形式存在，而不是以可执行核心类存在（`claude-code/plugins/feature-dev/.claude-plugin/plugin.json:1-9`; `claude-code/plugins/feature-dev/commands/feature-dev.md:1-125`; `claude-code/plugins/feature-dev/agents/code-explorer.md:1-51`）。
- `scripts/issue-lifecycle.ts` 里的 `lifecycle()` 与 `LifecycleLabel` 则暴露出另一条主线：这个仓库还承担官方仓库治理职责，用代码直接驱动 stale、needs-reproduction、planned、postponed 等状态流转（`claude-code/scripts/issue-lifecycle.ts:3-38`）。

所以读 `claude-code` 的正确姿势，不是找 agent loop，而是抓三条发布链：

- 市场链：`marketplace.json` -> 插件目录 -> manifest。
- 工作流链：`plugin.json` -> `commands/*.md` -> `agents/*.md`。
- 治理链：示例 settings/hooks -> issue 生命周期脚本 -> GitHub workflow。

把这三条链抓住之后，这个仓库的定位就很稳定了：它描述的是 Claude Code 生态层怎样被组织、分发和治理，而不是 Claude Code 模型推理循环本身怎样实现。
