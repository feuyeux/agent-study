# OpenCode 深度专题 B10：SKILL，技能是怎样被发现、授权、加载并重新注入主链路的

> 本文基于 `opencode` `v1.3.2`（tag `v1.3.2`，commit `0dcdf5f529dced23d8452c9aa5f166abb24d8f7c`）源码校对

在前面的章节里，Skill 经常被顺手提到：B02 里它会进上下文，B09 里它又是扩展入口之一。但如果只停在这两层，很容易把 Skill 误解成“仓库里几份 markdown 指南”。OpenCode 当前实现其实更强一些：Skill 是一套可以被发现、缓存、授权、投影成 system prompt、tool 和 command 的技能包系统。B10 就专门把这条链路拆开。

这里也先把边界说清楚：B02 关注的是 Skill 怎样进入 system/context；B09 关注的是 Skill 怎样作为扩展入口被并入 runtime 汇总面；B10 则只看 Skill 子系统自己从发现、筛选、加载到再投影的完整路径。

---

## 1. Skill 不是单个文件，而是五层结构

| 层 | 代码坐标 | 角色 |
| --- | --- | --- |
| 发现层 | `packages/opencode/src/skill/index.ts:15-166` | 从全局目录、项目目录、`.opencode`、显式路径和远端 URL 收集 `SKILL.md`。 |
| 远端拉取层 | `packages/opencode/src/skill/discovery.ts:11-100` | 从 `index.json` 下载 skill pack 到本地 cache。 |
| 运行时服务层 | `packages/opencode/src/skill/index.ts:168-226` | 暴露 `get/all/dirs/available`，并做 lazy ensure。 |
| 注入层 | `packages/opencode/src/session/system.ts:55-65`、`session/prompt.ts:676-679` | 把“可用技能列表”编进 system prompt。 |
| 交互层 | `tool/skill.ts:8-90`、`command/index.ts:142-153`、`tool/registry.ts:112-130` | 把 Skill 继续投影成 `skill` tool 和 slash command 来源。 |

所以 Skill 在 OpenCode 里不是“静态说明文档”，而是一种可运行时发现、筛选和再投影的扩展对象。

---

## 2. 技能发现不是一条路径，而是五条来源叠加

`packages/opencode/src/skill/index.ts:109-156` 当前会按顺序装载多种来源。

### 2.1 外部技能目录

默认会扫两组外部目录：

1. 全局 `~/.claude`、`~/.agents` 下的 `skills/**/SKILL.md`
2. 从当前目录向上到 worktree 之间命中的 `.claude`、`.agents`

这说明 Skill 首先兼容的是一套“外部 agent 生态目录”，而不只认 OpenCode 自己的配置仓。

### 2.2 OpenCode 配置目录

`Config.directories()` 返回的每个目录下，还会继续扫：

```txt
{skill,skills}/**/SKILL.md
```

也就是说，`.opencode` 这条配置目录链不只加载 command/agent/plugin，也可以顺带承载 skill pack。

### 2.3 显式路径追加

`cfg.skills.paths` 会被逐个展开；既支持 `~/...`，也支持相对当前 instance 目录的路径。

这让 Skill 可以脱离默认目录发现链，变成一份明确挂到 config 上的本地资源。

### 2.4 远端 URL 追加

`cfg.skills.urls` 会进入 `Discovery.pull(url)`。远端技能不是直接在线读取，而是先下载到本地 cache，再按普通本地目录继续装载。

所以 Skill 的运行方式其实是：

1. 本地发现
2. 配置追加
3. 远端拉取
4. 本地缓存复用

四步混合。

---

## 3. `Skill` service 的核心不是扫描，而是 lazy ensure

`packages/opencode/src/skill/index.ts:48-166` 定义了一个带 `task?: Promise<void>` 的 cache state。它真正关键的点不在“怎么扫目录”，而在“什么时候扫、扫几次”。

### 3.1 首次访问才触发装载

`ensure()` 会检查 `state.task`；如果已有 in-flight promise，就直接复用；如果没有，才真正开始 `load()`。

这意味着 `Skill.get()`、`Skill.all()`、`Skill.available()` 虽然看起来像普通查询接口，背后其实都共享同一次懒初始化。

### 3.2 重复 skill 名按名称覆盖

`add(...)` 里如果发现同名 skill，当前实现会打 warning，但仍然用后扫描到的定义覆盖前一个。

因此 Skill 的去重主键不是路径，也不是 URL，而是 `name`。真正被 runtime 使用的是“最后留在 `state.skills[name]` 里的那份定义”。

### 3.3 目录集合会单独保留

`state.dirs` 会记录所有已装载 skill 所在目录，后续 `Skill.dirs()` 可以把这些路径回吐出去。

这很重要，因为 skill 不只是内容字符串；运行时还需要知道它的基目录，才能解释相对路径资源。

---

## 4. Skill 的最小 schema 很薄，但约束很硬

`packages/opencode/src/skill/index.ts:21-27` 定义的 `Info` 只有四个核心字段：

1. `name`
2. `description`
3. `location`
4. `content`

看起来很轻，但 `add(...)` 并不是无条件接受任意 markdown。它会先经过 `ConfigMarkdown.parse(...)`，再用：

```ts
Info.pick({ name: true, description: true })
```

校验 frontmatter。

所以在当前实现里，一份 `SKILL.md` 至少要满足两件事：

1. frontmatter 里要有 `name`
2. frontmatter 里要有 `description`

否则它不会进入 skill 注册表。

这也解释了为什么 Skill 在 runtime 里能同时支撑：

1. tool description 里的技能列表
2. system prompt 里的 `<available_skills>`
3. command 列表里的 slash command 元信息

因为这三处都依赖稳定的 `name + description`。

---

## 5. 权限不是“加载以后再拦”，而是从可见性开始就生效

Skill 当前至少有两道权限门。

### 5.1 `available(agent)` 先做静态过滤

`packages/opencode/src/skill/index.ts:206-216` 里，`Skill.available(agent)` 会对每个 skill 调：

```ts
Permission.evaluate("skill", skill.name, agent.permission)
```

只有没被 deny 的 skill 才会出现在可用列表里。

### 5.2 `SystemPrompt.skills(agent)` 甚至可能完全不注入技能列表

`packages/opencode/src/session/system.ts:55-65` 一开始就检查：

```ts
Permission.disabled(["skill"], agent.permission).has("skill")
```

如果当前 agent 整体禁用了 `skill` 能力，那么 system prompt 连“有哪些技能可用”这层信息都不会带。

也就是说，权限在 Skill 这里不是“模型先看见，调用时再拒绝”，而是：

1. 先决定能不能看见技能集合
2. 再决定具体技能能不能出现在 available list
3. 真正加载时还会再问一次权限

---

## 6. Skill 有三个对外投影面，不是只有 `skill` tool

这是 B10 最关键的一点。

### 6.1 第一层投影：system prompt 里的技能目录

`packages/opencode/src/session/prompt.ts:676-679` 组 system prompt 时，会把：

1. `SystemPrompt.environment(model)`
2. `SystemPrompt.skills(agent)`
3. `InstructionPrompt.system()`

按顺序拼起来。

其中 `SystemPrompt.skills(agent)` 会输出三部分：

1. 一句解释“skills provide specialized instructions...”
2. 一句提示“use the skill tool...”
3. `Skill.fmt(list, { verbose: true })`

而 verbose 版本会生成 `<available_skills>` XML 块，并附带每个 skill 的：

1. `name`
2. `description`
3. `location`

所以模型在真正调用 `skill` tool 之前，已经能先看到“当前有哪些技能，以及它们各自解决什么问题”。

### 6.2 第二层投影：内建 `skill` tool

`packages/opencode/src/tool/registry.ts:112-130` 把 `SkillTool` 作为内建工具固定注册进 runtime。

`packages/opencode/src/tool/skill.ts:8-90` 的行为则更具体：

1. 先用 `Skill.available(ctx?.agent)` 生成 tool description
2. 参数只接收 `name`
3. 真正执行时 `Skill.get(name)`
4. 调 `ctx.ask(...)` 走一轮 `permission: "skill"`
5. 把 skill 正文包装进 `<skill_content name="...">`
6. 额外回传 skill 基目录和一份采样文件列表

这说明 `skill` tool 的职责不是“执行技能”，而是**把整份技能包连同它的目录上下文一起注入对话**。

尤其是：

1. `Base directory for this skill: ...`
2. `<skill_files>...</skill_files>`

这两段，让模型能继续引用 skill 目录里的脚本、模板或参考资料，而不是只拿到一段纯文本说明。

### 6.3 第三层投影：slash command 来源

`packages/opencode/src/command/index.ts:142-153` 会把 `Skill.all()` 继续折叠进 command registry。

只要命令名没有冲突，skill 就会自动生成一条：

1. `name = skill.name`
2. `description = skill.description`
3. `source = "skill"`
4. `template = skill.content`

这意味着 Skill 不只是一种“需要模型主动选择的 tool”，也可以直接表现成 slash command 模板来源。

换句话说，Skill 当前同时占了两种入口：

1. 由模型按需加载的 tool
2. 由用户或系统直接选择的 command

---

## 7. 远端 Skill pack 的设计，说明它被当成可分发资产

`packages/opencode/src/skill/discovery.ts:15-100` 的实现很能说明 OpenCode 对 Skill 的定位。

远端 skill pack 并不是“给一个 raw markdown URL 就完事”，而是要求一个目录型分发格式：

1. 根目录下有 `index.json`
2. `index.json` 里列出每个 skill 及其文件集合
3. 每个 skill 条目必须包含 `SKILL.md`

下载时，runtime 会把这些文件写进：

```txt
Global.Path.cache/skills/<skill-name>/*
```

然后再把缓存目录返回给主 `Skill` service 扫描。

这套设计透露出一个非常清楚的取向：**Skill 在 OpenCode 里是可缓存、可同步、可复用的分发单元。**

它不只是 prompt 片段，更像一个小型能力包。

---

## 8. 为什么要把 Skill 做成独立系统，而不是塞进普通 prompt 模板

把 B10 前面的几层放在一起看，会发现 Skill 比“普通 prompt 文本”多了四个关键性质：

1. 它有显式发现机制，而不是靠手工 copy。
2. 它有权限过滤，而不是任何 agent 都默认可见。
3. 它能被投影进 system prompt、tool 和 command 三个面。
4. 它可以带目录资源和远端分发能力，而不只是单段文本。

所以 Skill 在 OpenCode 当前实现里，更接近：

> 一种被 runtime 管理的、可发现的、可授权的 instruction package

而不是：

> 某份恰好叫 `SKILL.md` 的说明文档

---

## 9. B10 的核心结论

OpenCode 当前的 Skill 系统可以压成四句话：

1. **Skill 是一套多来源发现、本地缓存、懒初始化的技能包系统，不是几份散落的 markdown。**
2. **权限从“能否看见技能列表”开始生效，而不只是加载时做一次拒绝。**
3. **Skill 同时被投影成 system prompt 中的 `<available_skills>`、内建 `skill` tool，以及 command 模板来源。**
4. **远端 `index.json` + 本地 cache 的设计，说明 Skill 被当成可分发、可复用的 runtime 资产。**

如果用一句话概括 B10：

> 在 OpenCode 里，Skill 不是“提示词附件”，而是被发现、授权、注入并再次投影到主链路上的技能包系统。
