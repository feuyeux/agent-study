# OpenCode 提示词三文件对比分析

## 概述

OpenCode 为不同模型配置了三个独立的提示词文件，分别用于不同的模型提供商：

| 文件 | 目标模型 | 定位 |
|:------|:---------|:------|
| `packages/opencode/src/session/prompt/default.txt` | 未指定时的默认 fallback | 轻量、极简、被动响应 |
| `packages/opencode/src/session/prompt/anthropic.txt` | Anthropic Claude 系列 | 自信主动、深度工作、详细格式 |
| `packages/opencode/src/session/prompt/codex.txt` | OpenAI Codex 系列 | 结构化任务管理、介于两者之间 |

---

## 一、回复风格与长度

### 1.1 回复长度约束（最显著差异）

| 文件 | 约束强度 | 具体要求 |
|------|---------|---------|
| **default.txt** | **最强** | 必须少于 4 行（不含工具调用和代码生成），强制极简 |
| anthropic.txt | 中等 | 简洁但不严格限制行数 |
| codex.txt | 中等 | 简短但不严格限制行数 |

**default.txt 的强制极简示例**：

```sh
user: 2 + 2
assistant: 4

user: is 11 a prime number?
assistant: Yes

user: what command should I run to list files?
assistant: ls
```

**default.txt 的解释**（第18-19行）：

```sh
IMPORTANT: You should minimize output tokens as much as possible while maintaining helpfulness.
Answer the user's question directly, without elaboration, explanation, or details.
```

### 1.2 主动性与被动性

| 文件 | 风格 | 关键引述 |
|------|------|---------|
| **default.txt** | **被动优先** | "You are allowed to be proactive, but only when the user asks you to do something." |
| **anthropic.txt** | **主动执行** | "Default: do the work without asking questions." |
| codex.txt | 适度主动 | 无明确被动约束 |

**分析**：default 刻意限制主动性，要求先回答问题而非直接跳入行动；anthropic 则鼓励直接执行、边做边说。

### 1.3 前置/后置解释

**default.txt 明确禁止**（第18-19行）：

```sh
IMPORTANT: You should NOT answer with unnecessary preamble or postamble
(such as explaining your code or summarizing your action), unless the user asks you to.
Do not say "Here is what I will do next..." or "Based on the information provided..."
```

**anthropic.txt 允许合理说明**（第50行）：

```sh
For substantial work, summarize clearly; follow final‑answer formatting.
```

**codex.txt 无明确约束**。

---

## 二、代码相关政策

### 2.1 注释政策

| 文件 | 政策 |
|------|------|
| **default.txt** | **完全禁止添加任何注释**："DO NOT ADD ***ANY*** COMMENTS unless asked" |
| anthropic.txt | 允许必要注释："Only add comments if they are necessary to make a non-obvious block easier to understand." |
| codex.txt | 无明确约束 |

**设计意图**：default 作为通用默认模板，采用最保守策略；注释问题留给用户自行决定。

### 2.2 apply_patch 工具

| 文件 | 是否提及 |
|------|---------|
| **anthropic.txt** | **是**，明确推荐："Try to use apply_patch for single file edits" |
| default.txt | 否 |
| codex.txt | 否 |

**原因**：apply_patch 是 Anthropic 官方工具，与 Claude 模型集成最佳，因此只在对 Anthropic 模型的提示中推荐。

### 2.3 代码引用格式

| 文件 | 规范 |
|------|------|
| anthropic.txt | **最详细**：支持 `file:line[:col]`、`#Lline[Ccol]`、`a/` `b/` diff 前缀等（第74-79行） |
| default.txt | 仅 `file_path:line_number`（第100行） |
| codex.txt | 仅 `file_path:line_number`（第100行） |

---

## 三、任务管理

### 3.1 TodoWrite 工具使用

| 文件 | 态度 |
|------|------|
| **codex.txt** | **强烈推荐**："Use these tools VERY frequently" + 多个完整 examples（第24-49行） |
| default.txt | 提及但无强调（第82行） |
| anthropic.txt | **完全不提及** |

**原因推断**：Codex 模型可能不如 Claude 那样自然地进行任务规划和拆解，需要通过详细的 examples 和强调来引导。Claude 经过 RLHF 后已内建任务分解能力，无需显式强调。

### 3.2 Task 工具（探索代码库）

| 文件 | 规范 |
|------|------|
| **codex.txt** | **最强调**："When exploring the codebase to gather context... it is CRITICAL that you use the Task tool"（第86行） |
| default.txt | 推荐使用："When doing file search, prefer to use the Task tool"（第91行） |
| anthropic.txt | 无明确要求 |

---

## 四、前端设计能力

### 4.1 详细设计指南

| 文件 | 是否有独立设计章节 |
|------|------------------|
| **anthropic.txt** | **是**（第26-36行） |
| default.txt | 无 |
| codex.txt | 无 |

**anthropic.txt 的前端设计指南包含**：

- 字体：避免 Inter/Roboto/Arial/system 默认堆栈，使用有表现力的字体
- 颜色：避免紫色/白色默认，选择明确的视觉方向，定义 CSS 变量
- 动效：使用有意义的动画而非通用微动效
- 背景：避免纯色，使用渐变、形状、图案构建氛围
- 整体：避免模板布局和可互换 UI 模式
- 响应式：确保桌面和移动端都正常加载

**原因**：Claude 经过风格对齐训练，审美能力更强，能可靠地执行这些设计要求。

### 4.2 Git/工作区约束

| 文件 | 特殊约束 |
|------|---------|
| **anthropic.txt** | **最详细**（第17-24行）：包括不 revert 用户变更、不 amend commits、禁止 destructive 命令 |
| default.txt | 提及但不详细（第86行） |
| codex.txt | 无 |

---

## 五、外部知识与通信

### 5.1 WebFetch 获取 OpenCode 文档

| 文件 | 规范 |
|------|------|
| **codex.txt** | 有明确指示（第12行）：当用户询问 OpenCode 功能时使用 WebFetch |
| **default.txt** | 有明确指示（第9行）：当用户询问 OpenCode 功能时使用 WebFetch |
| anthropic.txt | **无** |

**原因**：Anthropic 模型可能已通过训练包含了足够的 OpenCode 知识；Codex 和 default 模型需要通过 WebFetch 实时获取项目文档。

### 5.2 OpenCode 身份描述差异

| 文件 | 品牌名称大小写 |
|------|--------------|
| **default.txt** | `opencode`（小写） |
| anthropic.txt | `OpenCode`（大写） |
| codex.txt | `OpenCode`（大写） |

---

## 六、格式与输出规范

### 6.1 详细格式手册

| 文件 | 是否有完整格式手册 |
|------|------------------|
| **anthropic.txt** | **是**（第61-79行）详细的 headers/bullets/monospace/code blocks 规范 |
| default.txt | 无 |
| codex.txt | 无 |

**anthropic.txt 格式规范要点**：

- Headers：短标题用 **…** 包裹，不用空行分隔
- Bullets：用 `-`；合并相关点；每列表 4-6 条
- Monospace：命令/路径/代码用 backticks
- 多行代码： fenced code blocks + info string
- 文件引用：`file:line[:col]`，不使用 range

### 6.2 emoji 使用

| 文件 | 政策 |
|------|------|
| **default.txt** | **明确允许**："Only use emojis if the user explicitly requests it"（第16行） |
| anthropic.txt | 同样限制："Only use emojis if the user explicitly requests it"（第16行 codex 版本） |
| codex.txt | 同样限制（第15行） |

三个文件一致：默认禁用 emoji，除非用户明确要求。

---

## 七、专业性与客观性

### 7.1 专业客观性声明

| 文件 | 是否有专门章节 |
|------|--------------|
| **codex.txt** | **有**（第20-21行）：强调技术准确性优先于验证用户信念 |
| default.txt | 无 |
| anthropic.txt | 无 |

**codex.txt 的声明**：

```sh
Prioritize technical accuracy and truthfulness over validating the user's beliefs.
Focus on facts and problem-solving, providing direct, objective technical info
without any unnecessary superlatives, praise, or emotional validation.
```

**原因**：非 Anthropic 模型可能更倾向于讨好用户或过度确认用户观点，需要显式强调保持技术客观性。

---

## 八、安全与约束

### 8.1 URL 生成约束

| 文件 | 表述 |
|------|------|
| **default.txt** | "You must NEVER generate or guess URLs"（第3行） |
| **codex.txt** | "You must NEVER generate or guess URLs"（第5行） |
| **anthropic.txt** | 无此明确约束 |

### 8.2 Bash 通信限制

| 文件 | 规范 |
|------|------|
| **default.txt** | **明确**："Never use tools like Bash or code comments as means to communicate with the user"（第14行） |
| **codex.txt** | **明确**："Never use tools like Bash or code comments as means to communicate with the user"（第17行） |
| anthropic.txt | 无此明确约束 |

---

## 九、工具使用哲学

### 9.1 通用工具推荐对比

| 文件 | 工具使用哲学 |
|------|------------|
| **default.txt** | 强调搜索工具和 lint/typecheck："Verify the solution with tests... run lint and typecheck" |
| **anthropic.txt** | 强调并行工具调用："Run tool calls in parallel when neither call needs the other's output" |
| **codex.txt** | 强调任务分解和搜索工具 |

### 9.2 文件操作工具偏好

| 文件 | 推荐 |
|------|------|
| **anthropic.txt** | 明确推荐 Read/Edit/Write/Glob/Grep |
| **codex.txt** | 明确推荐 Read/Edit/Write/Glob/Grep |
| **default.txt** | 同样推荐（第13行） |

---

## 十、总结：设计意图与适用场景

### 10.1 default.txt —— 轻量快速查询

**设计哲学**：最小化 token 消耗，强制简洁，避免过度解释。

**适用场景**：

- 简单的一次性问答
- 需要快速响应的场景
- 资源受限的环境

**核心特点**：

- 4 行以内强制回复
- 禁止主动行动
- 禁止任何注释
- 无任务分解强调

### 10.2 anthropic.txt —— 深度复杂工作

**设计哲学**：充分发挥 Claude 的自主决策能力，提供详细格式规范，适合需要多步骤的复杂任务。

**适用场景**：

- 复杂的多文件修改
- 需要前端设计的任务
- 需要主动规划和执行的工作

**核心特点**：

- 主动执行，不问问题
- 详细的前端设计指南
- 完整的输出格式手册
- apply_patch 工具推荐

### 10.3 codex.txt —— 结构化任务管理

**设计哲学**：介于两者之间，但强调结构化任务管理，通过 TodoWrite 和 Task 工具保持任务可见性。

**适用场景**：

- 中等复杂度的多步骤任务
- 需要明确任务追踪的工作
- Codex 模型（对工具使用需要更多引导）

**核心特点**：

- 强调 TodoWrite 频繁使用
- 强调使用 Task 工具探索代码库
- 强调技术客观性
- WebFetch 获取 OpenCode 文档

---

## 十一、背后的核心原因

### 11.1 模型能力差异

不同模型经过不同的 RLHF 训练，具有不同的内在能力：

| 能力 | Claude (anthropic) | Codex | 默认模型 |
|------|---------------------|-------|---------|
| 自主决策 | 强 → 减少约束 | 中 → 需要引导 | 弱 → 强制简洁 |
| 任务分解 | 强 → 不需强调 | 中 → 需强调 | 弱 → 无 |
| 格式遵循 | 强 → 详细规范 | 中 → 简单规范 | 弱 → 无 |
| 设计审美 | 强 → 专项指南 | 弱 → 无 | 弱 → 无 |

### 11.2 Token 成本考量

- **default**：为降低 API 成本设计，强制极短回复
- **anthropic/codex**：为高质量输出设计，允许更长回复

### 11.3 品牌一致性

三个文件都服务于 OpenCode 品牌，但在：

- 品牌名称大小写（OpenCode vs opencode）
- emoji 政策（一致禁用）
- 核心身份定位（一致：best coding agent）

保持了一致性。

---

*分析基于 packages/opencode/src/session/prompt/ 目录下的三个提示词文件*
