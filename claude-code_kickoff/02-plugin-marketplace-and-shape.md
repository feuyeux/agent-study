# 插件市场与插件骨架：`marketplace.json`、`plugin.json`、`commands/`、`agents/` 在源码里怎样拼装成一个可分发单元

主向导对应章节：`插件市场与插件骨架`

一条插件装配链可以从 `.claude-plugin/marketplace.json` 开始读。这个文件的 `plugins[]` 条目把 `feature-dev`、`code-review`、`plugin-dev` 等官方插件全部声明成市场条目，并用 `source` 把它们映射到 `./plugins/<name>` 子目录（`claude-code/.claude-plugin/marketplace.json:10-149`）。这里最关键的设计不是字段多少，而是“市场索引”和“插件内容”被显式拆成两层：先由市场文件发布可发现性，再由子目录承载具体实现。

插件子目录的骨架由 `plugins/README.md` 统一规定。它明确要求 `.claude-plugin/plugin.json`、`commands/`、`agents/`、`skills/`、`hooks/`、`.mcp.json` 这些槽位，并在贡献要求里再次强调新增插件必须补 metadata、文档和命令/agent 说明（`claude-code/plugins/README.md:47-70`）。这说明 Claude Code 的插件接口本质上是“约定目录 + 若干契约文件”，而不是某个需要继承的 SDK 抽象类。

`feature-dev` 是看清这条装配链的最好样板。`.claude-plugin/plugin.json` 只保存插件标识、版本和作者信息，没有任何业务逻辑（`claude-code/plugins/feature-dev/.claude-plugin/plugin.json:1-9`）。真正的行为入口在 `commands/feature-dev.md`：它把 `/feature-dev` 写成一个七阶段状态机，要求先 discovery，再 codebase exploration，再 clarifying questions，最后才允许 implementation 和 review（`claude-code/plugins/feature-dev/commands/feature-dev.md:20-124`）。也就是说，命令文件不是文档附件，而是工作流本体。

再往下一层，`agents/code-explorer.md` 把“代码探索子代理”写成另一个更细的执行契约。它规定 `Core Mission` 是从入口追到数据落点，`Analysis Approach` 要覆盖 feature discovery、code flow tracing、architecture analysis、implementation details，而 `Output Guidance` 明确要求“entry points with file:line references”“step-by-step execution flow”“essential files list”（`claude-code/plugins/feature-dev/agents/code-explorer.md:11-51`）。这相当于把团队希望代理遵守的代码审读方法学直接固化成可复用工件。

这条链最值得注意的地方在于分层非常干净：

- 市场层只负责发现与分发：`.claude-plugin/marketplace.json`（`claude-code/.claude-plugin/marketplace.json:10-149`）。
- manifest 层只负责声明插件身份：`plugin.json`（`claude-code/plugins/feature-dev/.claude-plugin/plugin.json:1-9`）。
- 工作流层负责定义主任务推进方式：`commands/feature-dev.md`（`claude-code/plugins/feature-dev/commands/feature-dev.md:20-124`）。
- 角色层负责定义子代理职责与输出格式：`agents/code-explorer.md`（`claude-code/plugins/feature-dev/agents/code-explorer.md:16-51`）。

因此，这个仓库里最像“源码设计”的并不是某个运行时类，而是这套分层协议本身。它让插件既能被市场发现，又能被 Claude Code 解析成可执行工作流，还能把代理职责拆成更小的提示契约单元。
