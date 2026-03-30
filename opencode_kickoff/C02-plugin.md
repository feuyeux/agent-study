# OpenCode 深度专题 C02：Plugin 系统，runtime 内部受信扩展层的全部节点

> 本文基于 `opencode` `v1.3.2`（tag `v1.3.2`，commit `0dcdf5f529dced23d8452c9aa5f166abb24d8f7c`）源码校对

C 系列是 B 系列的补充专题：本文是 plugin 系统深挖，适合在读完 [B09 扩展面](./B09-extension.md) 之后继续深究。

如果不单独把 plugin 系统拎出来，很容易把 OpenCode 理解成“核心 runtime 固定，插件只是顺手挂几个工具”。当前实现不是这个结构。plugin 更像是 **runtime 内部的受信扩展层**：它不在外围做代理，而是直接插进 provider 装配、认证、tool 定义、session prompt 编译、LLM 请求、compaction 和 shell 环境构造这些核心节点里。

---

## 1. 先给结论：OpenCode 的 plugin 不是外围适配层，而是内嵌改写层

当前 plugin 系统至少有 4 个特征：

1. **按 instance 作用域加载。** 每个 `Instance.directory` 都会有自己的 plugin hook 缓存，不是全局单例。
2. **按真实调用点改写 output。** 大部分 hook 形态都是 `(input, output) => Promise<void>`，插件直接改写 runtime 已经构造出来的对象。
3. **内建插件和用户插件走同一条总线。** `CodexAuthPlugin`、`CopilotAuthPlugin` 与用户 `.opencode/plugin/*.ts` 最终都变成同一个 `Hooks[]` 数组。
4. **这是受信扩展，不是沙箱扩展。** plugin 运行在主进程内，可以拿到 SDK client、项目路径、`Bun.$`，也能影响 provider header、tool schema、shell 环境，权限非常高。

所以 OpenCode 的 plugin 系统更接近：

- “runtime 内部可编排的钩子层”
- 而不是“给外部插件开个边车接口”

---

## 2. 先认清源码坐标

| 代码位置 | 角色 |
| --- | --- |
| `packages/opencode/src/plugin/index.ts` | plugin runtime：加载、缓存、触发 hook |
| `packages/opencode/src/plugin/codex.ts` | 内建 OpenAI/Codex 认证插件 |
| `packages/opencode/src/plugin/copilot.ts` | 内建 GitHub Copilot 认证插件 |
| `packages/plugin/src/index.ts` | 对外暴露的 plugin API：`Plugin`、`Hooks`、`PluginInput` |
| `packages/plugin/src/tool.ts` | plugin 自定义 tool 的 helper 和 schema API |
| `packages/opencode/src/config/config.ts` | plugin 发现、依赖安装、去重 |
| `packages/opencode/src/provider/auth.ts` | 消费 plugin `auth` hook |
| `packages/opencode/src/provider/provider.ts` | 消费 plugin `auth.loader` 产出的 provider options |
| `packages/opencode/src/tool/registry.ts` | 消费 plugin `tool` 和 `tool.definition` |
| `packages/opencode/src/session/prompt.ts` | 消费 `chat.message`、`command.execute.before`、`tool.execute.before/after`、`shell.env` |
| `packages/opencode/src/session/llm.ts` | 消费 `experimental.chat.system.transform`、`chat.params`、`chat.headers` |
| `packages/opencode/src/session/processor.ts` | 消费 `experimental.text.complete` |
| `packages/opencode/src/session/compaction.ts` | 消费 `experimental.session.compacting`、`experimental.chat.messages.transform` |
| `packages/opencode/test/plugin/*.test.ts` | plugin 行为与覆盖语义测试 |

从结构上看，plugin 并没有独立成一个“插件子系统”。它是散射在 config、provider、session、tool、pty 等多个路径里的横切关注点。

---

## 3. plugin 从哪里来：发现、安装、去重

### 3.1 来源不是一个，而是两类

`Config.get()` 最终得到的 `config.plugin` 既可能来自显式配置，也可能来自目录扫描。

#### 第一类：显式 `plugin` 数组

用户可以在 `opencode.json/jsonc` 里写：

1. npm 包名，例如 `my-plugin`
2. 带版本的包名，例如 `my-plugin@1.2.3`
3. file URL

#### 第二类：`.opencode/plugin/*.ts` 或 `.opencode/plugins/*.ts`

`config.ts` 里的 `loadPlugin(dir)` 会扫描：

```text
{plugin,plugins}/*.{ts,js}
```

并把命中的本地文件转成 `file://` URL，再推入 `result.plugin`。

所以本地目录插件不需要在 `plugin` 数组里手写声明，只要放到约定目录就会自动装入。

### 3.2 plugin 发现和 config 解析是同一阶段完成的

`Config.state(...)` 在汇总配置时，会顺带处理 plugin：

1. 读取全局/项目/`.opencode`/远程/managed config
2. 每扫到一个 config dir，就继续扫 `plugin/*.ts`
3. 把 plugin specifier 推入 `result.plugin`
4. 最后做 `deduplicatePlugins(result.plugin ?? [])`

这说明 plugin 不是后处理附加项，而是配置系统的一部分。

### 3.3 为什么会有 `waitForDependencies()`

目录型扩展不仅可能有 plugin，还可能有自定义 tool、command、agent。为了让这些目录里的 `import` 可用，OpenCode 会在 config dir 上自动准备运行时依赖。

`Config.installDependencies(dir)` 会：

1. 生成或更新该目录下的 `package.json`
2. 自动写入 `@opencode-ai/plugin: <当前版本>`
3. 如无 `.gitignore`，自动写入：
   - `node_modules`
   - `package.json`
   - `bun.lock`
   - `.gitignore`
4. 之后执行 `bun install`

如果 `OPENCODE_STRICT_CONFIG_DEPS=true`，安装失败会直接抛错；否则只记录 warning。

### 3.4 plugin 去重语义不是按完整 specifier，而是按“规范名”

`Config.getPluginName()` 的规则是：

1. `file://.../foo.js` -> `foo`
2. `pkg@1.2.3` -> `pkg`
3. `@scope/pkg@1.2.3` -> `@scope/pkg`

`deduplicatePlugins()` 再按这个规范名去重，并且让**后出现的条目获胜**。

这意味着：

1. 同名 npm plugin 的不同版本不会共存。
2. 本地 file plugin 可以覆盖同名包插件。
3. 覆盖是配置层完成的，runtime 不会再做二次仲裁。

---

## 4. runtime 是怎么把 plugin 变成 `Hooks[]` 的

真正把 plugin 实例化的地方不在 config，而在 `Plugin.init()`。

### 4.1 触发时机：`InstanceBootstrap()` 的第一步

`project/bootstrap.ts` 里 `InstanceBootstrap()` 的第一行就是：

```ts
await Plugin.init()
```

因此 plugin 会早于：

- `Format.init()`
- `LSP.init()`
- `File.init()`
- `FileWatcher.init()`
- `Vcs.init()`
- `Snapshot.init()`

这非常关键，因为 provider auth、tool 定义、chat headers 等后续行为都可能依赖 plugin。

### 4.2 `PluginInput` 提供了哪些能力

每个 plugin factory 都会收到同一个 `PluginInput`：

| 字段 | 含义 |
| --- | --- |
| `client` | 内嵌 SDK client，`fetch` 直接走 `Server.Default().fetch()` |
| `project` | 当前实例绑定的 project 信息 |
| `directory` | 当前工作目录 |
| `worktree` | worktree 根 |
| `serverUrl` | 当前 server URL，若未 listen 则退回 `http://localhost:4096` |
| `$` | `Bun.$` shell 能力 |

这套输入已经说明 plugin 不是“轻量脚本”。它拿到的是一套完整宿主能力。

### 4.3 运行时装配顺序

`Plugin.init()` 的加载顺序是：

1. 先加载内建插件 `INTERNAL_PLUGINS`
   - `CodexAuthPlugin`
   - `CopilotAuthPlugin`
   - `GitlabAuthPlugin`
   - `PoeAuthPlugin`
2. 再读取 `cfg.plugin`
3. 如存在外部 plugin，先 `Config.waitForDependencies()`
4. 对非 `file://` specifier，先 `BunProc.install(pkg, version)`
5. `import(plugin)` 动态加载模块
6. 遍历模块导出，把每个导出都当作 plugin factory 调用

这里还有两个很重要的细节：

#### 细节 1：同一模块可以导出多个 plugin factory

runtime 会遍历 `Object.entries(mod)`，所以一个模块理论上可以导出多个 plugin factory，而不是只能导出 `default`。

#### 细节 2：仅按函数引用去重，不按导出名去重

代码专门处理了这种场景：

```ts
export const X = async () => ({ ... })
export default X
```

此时 default 和 named export 指向同一函数，只初始化一次。

但如果你导出的是多个不同函数，它们都会被执行。

### 4.4 失败隔离策略并不完全一致

plugin runtime 对不同阶段的失败处理是不一样的：

| 阶段 | 处理方式 |
| --- | --- |
| 内建 plugin factory 加载失败 | 记录 error，继续 |
| npm plugin 安装失败 | 发布 `Session.Event.Error`，继续 |
| plugin 模块 `import()` 失败 | 发布 `Session.Event.Error`，继续 |
| `config` hook 执行失败 | 单独 `try/catch`，记录 `plugin config hook failed`，继续 |
| `Plugin.trigger(...)` 期间 hook 抛错 | **不隔离**，错误直接冒泡给调用方 |

所以当前系统只对“装载期”和“config hook”做容错；对多数业务 hook 不做隔离。

---

## 5. `Plugin.trigger()` 的语义：串行、共享 output、无事务隔离

这是理解 plugin 行为最重要的一点。

`Plugin.trigger(name, input, output)` 的实现是：

1. 取出当前 instance 的 `hooks[]`
2. 逐个取 `hook[name]`
3. 若存在则 `await fn(input, output)`
4. 最后把同一个 `output` 对象返回

这意味着：

1. **调用顺序严格串行。** 后一个 plugin 一定能看到前一个 plugin 改过的 output。
2. **冲突策略是“后写覆盖前写”。** 没有 merge 协议，也没有优先级仲裁。
3. **一旦某个 hook 抛错，整条调用链就会报错。**

这套语义很强，但也很硬：它适合“可信插件协作”，不适合“不可信第三方脚本生态”。

---

## 6. Hook 全景：哪些声明真的接进了 runtime

下面这张表只写“当前代码里有真实调用点的 hook”。

| Hook | 主要调用点 | 作用 |
| --- | --- | --- |
| `config` | `Plugin.init()` 装载完成后 | 让 plugin 读取最终配置 |
| `event` | `Plugin.init()` 里 `Bus.subscribeAll(...)` | 旁路观察 instance 级 bus event |
| `auth` | `ProviderAuth.methods/authorize/callback`、`Provider.list()` | 自定义 provider 登录方式与认证后 provider patch |
| `tool` | `ToolRegistry.state()` | 向 runtime 注入自定义 tool |
| `tool.definition` | `ToolRegistry.tools()` | 在 tool 暴露给模型前改 description/schema |
| `chat.message` | `SessionPrompt.createUserMessage()` | 在 user message/parts 落库前改写 |
| `experimental.chat.messages.transform` | `session/prompt.ts`、`session/compaction.ts` | 在 durable history 转 model messages 前做整体变换 |
| `experimental.chat.system.transform` | `session/llm.ts`、`agent/agent.ts` | 在 system prompt 最终拼装后再变换 |
| `chat.params` | `session/llm.ts` | 改 temperature/topP/topK/provider options |
| `chat.headers` | `session/llm.ts` | 改 provider 请求头 |
| `command.execute.before` | `SessionPrompt.command()` | 改 command 模板展开后的 parts |
| `tool.execute.before` | `SessionPrompt.loop()` 多个 tool 执行点 | 改 tool args |
| `tool.execute.after` | `SessionPrompt.loop()` 多个 tool 执行点 | 改 tool title/output/metadata |
| `shell.env` | `tool/bash.ts`、`pty/index.ts`、`session/prompt.ts` | 给 shell / PTY 注入环境变量 |
| `experimental.session.compacting` | `session/compaction.ts` | 扩充或替换 compaction prompt |
| `experimental.text.complete` | `session/processor.ts` | 在 text part 完成时做最后改写 |

### 6.1 有声明但当前没接线的 hook

`@opencode-ai/plugin` 的 `Hooks` 里还声明了 `permission.ask`，但当前 `packages/opencode/src` 中没有 `Plugin.trigger("permission.ask", ...)` 的调用点。

也就是说：

- API 已经预留了这个 hook
- 但当前 runtime 还没有真正消费它

这类细节很重要，因为“类型里存在”不等于“运行时已接线”。

### 6.2 `event` hook 是 fire-and-forget，不参与主链路回压

`Plugin.init()` 里给 `Bus.subscribeAll(...)` 传的是一个 `async` 回调，但内部并没有 `await hook.event?.(...)`，而是直接 fire-and-forget 调用。

因此：

1. event hook 不会阻塞 bus 主链路。
2. event hook 的 reject 也不会像 `Plugin.trigger(...)` 那样被显式接住。

换句话说，`event` hook 更像旁路观察器，而不是事务内 hook。

---

## 7. 内建插件到底做了什么

当前 repo 内最重要的内建 plugin 是两个认证插件：Codex 和 Copilot。

### 7.1 `CodexAuthPlugin`

它挂在 provider `openai` 上，但不是普通 API key 适配，而是把 ChatGPT/Codex OAuth 账户接入 OpenCode。

它做了 3 层事：

#### 第一层：自定义认证入口

提供三种 method：

1. `ChatGPT Pro/Plus (browser)`
2. `ChatGPT Pro/Plus (headless)`
3. `Manually enter API Key`

也就是说同一个 provider 的认证策略，本身就是插件定义的，不是 provider 核心写死的。

#### 第二层：认证后重写 provider 行为

`auth.loader()` 在检测到 OAuth 后会：

1. 只保留 Codex / GPT-5.x 允许模型
2. 若缺失则补一个 `gpt-5.3-codex` 模型定义
3. 把模型 cost 全部改成 0
4. 返回自定义 `fetch()`
5. 用 dummy API key 占位，真正请求时改走 OAuth access token
6. 需要时自动 refresh token
7. 把 `/v1/responses` 或 `/chat/completions` 重写到 `https://chatgpt.com/backend-api/codex/responses`

也就是说 Codex 插件并不是“多一个登录按钮”，而是整个 provider transport 的重写器。

#### 第三层：额外 header 注入

它还通过 `chat.headers` 给 openai 请求加：

- `originator`
- `User-Agent`
- `session_id`

这说明认证 plugin 也能跨到 LLM 请求层继续施加影响。

### 7.2 `CopilotAuthPlugin`

它挂在 `github-copilot` 上，重点是把 GitHub device flow 和 Copilot 特定 header 规则封装成 hook。

`auth.loader()` 会：

1. 识别 enterprise URL
2. 把 provider `baseURL` 指向企业域名
3. 把模型 `api.npm` 改成 `@ai-sdk/github-copilot`
4. 把模型成本清零
5. 提供自定义 `fetch()`：
   - 注入 `Authorization: Bearer <refresh token>`
   - 注入 `x-initiator`
   - 注入 `Openai-Intent`
   - 视情况注入 `Copilot-Vision-Request`

`chat.headers` 还会：

1. 给 Copilot 上的 Anthropic 模型加 `anthropic-beta`
2. 通过读取当前 session/message 判断这次调用是不是 compaction 或 subagent 派生请求
3. 决定是否把 `x-initiator` 标成 `agent`

这说明 plugin 可以跨多个 runtime 层面协同：

- provider auth
- request fetch
- message-aware header patch

### 7.3 另外两个内建 plugin

`GitlabAuthPlugin` 和 `PoeAuthPlugin` 不在本仓库源码里展开实现，但在 runtime 中和上述两个插件地位完全相同：都是 `INTERNAL_PLUGINS` 的一员，和用户插件共享同一加载链。

---

## 8. plugin 如何影响 provider、tool 和 session 三条主线

### 8.1 provider 主线

plugin 对 provider 的影响分两层：

1. `auth` hook 决定“怎么登录”
2. `auth.loader()` 决定“登录后如何 patch provider options/models/fetch”

`Provider.list()` 会在加载 env/api/custom/config provider 之后，再遍历 `Plugin.list()`：

1. 找到带 `auth` 的 plugin
2. 如果对应 provider 已有 auth
3. 再调 `plugin.auth.loader(...)`
4. 把 loader 产出的 `options` merge 回 provider

所以 plugin auth 不是独立于 provider list 的，它就是 provider 组装过程的一部分。

### 8.2 tool 主线

plugin 有两条扩 tool 的路：

#### 路径 A：`plugin.tool`

plugin factory 返回：

```ts
{
  tool: {
    mytool: tool({ ... })
  }
}
```

`ToolRegistry` 会把它转成 runtime `Tool.Info`。

#### 路径 B：独立 `tools/*.ts`

这不是 plugin hook，但也属于同一扩展生态。`ToolRegistry.state()` 会从 config directories 下额外扫描：

```text
{tool,tools}/*.{js,ts}
```

然后一起注册进 tool registry。

这两条路的差异是：

1. `plugin.tool` 能和其它 hooks 共用同一个 plugin 生命周期。
2. 独立 `tools/*.ts` 更像轻量工具扩展，不需要返回 `Hooks`。

### 8.3 session / prompt 主线

plugin 在 session 主线的切入点很深：

1. `chat.message`：用户消息入库前最后一道改写口
2. `command.execute.before`：命令模板展开后、真正 prompt 前
3. `tool.execute.before/after`：tool 调用前后
4. `experimental.chat.messages.transform`：durable history -> model message 前
5. `experimental.chat.system.transform`：system prompt 拼装后
6. `chat.params` / `chat.headers`：进入 `streamText()` 前
7. `experimental.text.complete`：text part 结束时
8. `experimental.session.compacting`：compaction 总结 prompt 生成前

也就是说，plugin 不只是在“调用模型之前”插一个 middleware，而是把一次 session round 的多个阶段都开放出来了。

---

## 9. auth 覆盖语义：为什么用户插件能覆盖内建认证插件

这个行为不是猜的，repo 里有专门测试：`test/plugin/auth-override.test.ts`。

测试做的事是：

1. 在临时目录下创建 `.opencode/plugin/custom-copilot-auth.ts`
2. 为 `github-copilot` 提供一个新的 `auth.methods`
3. 再通过 `ProviderAuth.methods()` 读取 provider auth methods
4. 断言返回的是用户插件定义的 label，而不是内建 Copilot 插件的 label

它之所以成立，原因是：

1. `Plugin.init()` 先 push 内建 hooks，再 push 用户 hooks
2. `ProviderAuth.state()` 用 `Record.fromEntries(...)` 把 `provider -> auth hook` 建成映射
3. 同一个 provider key 后写覆盖前写
4. CLI 的 `providers` 命令在选择认证 plugin 时也是 `findLast(...)`

所以在 auth 这个维度上，OpenCode 的真实优先级就是：

**用户 plugin > 内建 plugin**

这也是它能被当成“认证 override 层”的原因。

---

## 10. 写 plugin 时真正该遵守的约束

从 runtime 实现反推，写 plugin 时至少要遵守下面这些约束。

### 10.1 导出内容最好只放 plugin factory

runtime 会遍历模块所有导出并假设它们都是 `Plugin` 函数。

所以如果你额外导出：

- 常量
- 配置对象
- 帮助函数

就可能在 `fn(input)` 这里直接炸掉，导致整个模块被当成加载失败。

更稳妥的写法是：

1. 只导出 plugin factory
2. 帮助函数放模块内部，不做 export

### 10.2 不要指望 hook 自动隔离异常

除了 `config` hook 以外，大多数 hook 出错都会直接把异常抛回主链路。

例如：

- `chat.params` 抛错，整个 LLM round 会失败
- `tool.definition` 抛错，tool registry 构造会失败
- `chat.message` 抛错，user message 创建会失败

### 10.3 plugin 是受信代码，不要把它当脚本片段

plugin 拿到的是：

- 当前 project / directory / worktree
- 内嵌 SDK client
- `Bun.$`
- shell/tool header/provider 改写能力

所以它天然拥有高权限。这个接口适合团队内扩展，不适合直接运行来源不明的第三方插件。

---

## 11. 一个最小可工作的 plugin 骨架

`packages/plugin/src/example.ts` 给了最小骨架：

```ts
import { Plugin } from "@opencode-ai/plugin"
import { tool } from "@opencode-ai/plugin"

export const ExamplePlugin: Plugin = async (ctx) => {
  return {
    tool: {
      mytool: tool({
        description: "This is a custom tool",
        args: {
          foo: tool.schema.string().describe("foo"),
        },
        async execute(args) {
          return `Hello ${args.foo}!`
        },
      }),
    },
  }
}
```

这个例子虽然小，但已经说明了 3 件事：

1. plugin factory 本身是 `async`
2. 返回值是 `Hooks`
3. 自定义 tool 和其它 hooks 是同级成员

如果要做 header 改写或 provider auth，本质也是在这个对象上继续加字段，而不是注册额外 class/service。

---

## 12. 最后总结：OpenCode plugin 体系的本质是什么

OpenCode 的 plugin 体系本质上不是“可插拔附件”，而是 **runtime 内部的高权限 hook 编排层**。

它的真实设计取向是：

1. 让认证 provider 可以通过 plugin 被完整改写
2. 让 tool/schema/header/message/system 都能在临门一脚被重写
3. 让用户目录里的本地扩展和官方内建插件走同一条生命周期
4. 用 instance 作用域缓存保证插件行为和当前 project/config 一致

它的代价也同样明显：

1. 安全边界弱，默认就是 trusted code execution
2. 多数 hook 没有隔离，坏插件可以直接打断主链路
3. 导出约束隐式而脆弱，plugin 模块作者必须非常自觉

但从 OpenCode 当前目标看，这其实是一个非常一致的选择：

**它要的不是“插件市场”，而是“把 runtime 做成可在内部深度改写的 agent 平台”。**

如果把本文放回主线里理解，可以把它看成 [B08-startup-config](./B08-startup-config.md) 的启动时机补充，以及 [B09](./B09-extension.md) 的 plugin 细化稿。
