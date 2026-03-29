# OpenCode 深度专题 B08：启动与配置加载，从全局目录到 `.opencode` 覆写

> 本文基于 `opencode` `v1.3.2`（tag `v1.3.2`，commit `0dcdf5f529dced23d8452c9aa5f166abb24d8f7c`）源码校对

前面的 A/B 章节大多从“请求已经进入 runtime”开始讲。但在 OpenCode 当前实现里，很多关键行为其实发生在第一条 prompt 之前：全局目录准备、日志与数据库迁移、配置叠加、`.opencode` 目录装载、依赖安装，以及 `InstanceBootstrap()` 固定服务图初始化。B08 的任务，就是把这条“启动前半场”讲清楚。

---

## 1. 启动与配置不是一步，而是四段

| 阶段 | 代码坐标 | 真正在做什么 |
| --- | --- | --- |
| import 阶段 | `packages/opencode/src/global/index.ts:14-40` | 准备 XDG 目录、缓存目录和 cache version。 |
| CLI middleware 阶段 | `packages/opencode/src/index.ts:67-123` | 初始化日志、设置环境变量、做首次 SQLite/JSON migration。 |
| 配置编译阶段 | `packages/opencode/src/config/config.ts:79-260`、`config/paths.ts:10-144` | 按优先级叠加 config，并装载 `.opencode` 下的 commands/agents/modes/plugins。 |
| 实例 bootstrap 阶段 | `packages/opencode/src/project/bootstrap.ts:15-30` | 固定顺序初始化 Plugin、Format、LSP、File、Watcher、VCS、Snapshot 等服务。 |

所以 OpenCode 的“启动”不能只理解成“命令行 parse 完就开始跑 agent”。它更像是一个分层装配过程。

---

## 2. import 阶段已经有显式副作用

`packages/opencode/src/global/index.ts:14-40` 在模块加载时就做了两件事：

1. 计算 `Global.Path.data/cache/config/state/log/bin`。
2. 确保这些目录存在，并校验 `cache/version`。

这说明 OpenCode 不是等命令 handler 里才懒创建工作目录，而是在进程 import 阶段就先把：

1. 配置根目录
2. 日志目录
3. 缓存目录
4. 二进制缓存目录

全部准备好。

这里还有个容易忽略的细节：cache version 不匹配时，会主动清理整份 cache 再写入新版本。这意味着升级并不只是二进制替换，缓存布局也被显式版本化了。

---

## 3. `src/index.ts` 的 middleware 先准备运行环境，再谈命令分发

`packages/opencode/src/index.ts:50-123` 当前最重要的不是命令注册，而是全局 middleware。

这一层按顺序做：

1. `Log.init(...)`
2. 写入 `AGENT=1`、`OPENCODE=1`、`OPENCODE_PID`
3. 打启动日志
4. 检查 `Global.Path.data/opencode.db`
5. 若数据库不存在，则执行一次性迁移

迁移分支在 `87-121` 很明确：

1. 用 `Database.Client().$client` 打开 SQLite
2. 调 `JsonMigration.run(...)`
3. 把历史 JSON 存储迁进 SQLite

因此，OpenCode 当前不是“命令执行时如果要用数据库再顺便初始化”，而是把数据库就绪看成 CLI 入口的公共前置条件。

---

## 4. `Config.get()` 不是读一个文件，而是编译一棵配置树

`packages/opencode/src/config/config.ts:81-88` 已经把优先级写得很直白了。当前配置加载顺序是从低到高：

1. 远端 `.well-known/opencode`
2. 全局 config
3. `OPENCODE_CONFIG`
4. 项目 `opencode.json/jsonc`
5. `.opencode` 目录配置与附属内容
6. `OPENCODE_CONFIG_CONTENT`
7. 组织级远端 account config
8. managed config dir

`79-260` 的实现说明，`Config.get()` 的本质不是“读 JSON”，而是：

1. 拉远端配置
2. 合并本地多来源配置
3. 解析配置目录里的 commands/agents/modes/plugins
4. 做一轮兼容迁移与 flag 覆写
5. 再产出最终 runtime config

换句话说，配置系统在 OpenCode 里本身就是一层编译器。

---

## 5. 项目配置与 `.opencode` 目录是两条不同的发现机制

`packages/opencode/src/config/paths.ts:10-42` 把这两种发现方式明确分开了。

### 5.1 `projectFiles(...)`

`11-20` 会沿着 `directory -> worktree` 向上找 `opencode.jsonc/json`，然后按上层到下层的顺序返回。

这意味着普通项目配置是典型的“层层覆盖”。

### 5.2 `directories(...)`

`22-42` 返回的则是：

1. `Global.Path.config`
2. 当前工程向上所有 `.opencode`
3. `$HOME` 下的 `.opencode`
4. `OPENCODE_CONFIG_DIR`

也就是说，`.opencode` 目录不是普通 config file 的附庸，而是另一条独立的“配置目录发现链”。

---

## 6. `.opencode` 目录装载的不只是 JSON，还包括可执行扩展内容

这是 B08 最关键的一点。

`packages/opencode/src/config/config.ts:143-166` 在遍历 `directories` 时，不只是 merge `opencode.jsonc/json`，还会同步装载：

1. `loadCommand(dir)`，见 `384-420`
2. `loadAgent(dir)`，见 `422-459`
3. `loadMode(dir)`，见 `461-495`
4. `loadPlugin(dir)`，见 `497-509`

这说明 `.opencode` 在 OpenCode 当前实现里不是“一个额外配置目录”，而是**本地扩展仓**。

更进一步，`273-360` 还能看到：

1. `needsInstall(dir)` 会检查目录是否可写、`node_modules` 是否存在、`@opencode-ai/plugin` 是否过期。
2. `installDependencies(dir)` 会自动写 `package.json`、补 `@opencode-ai/plugin` 依赖，并执行 `bun install`。

所以当前启动链实际上允许配置目录在初始化阶段触发依赖安装。这已经远远超出了“读配置文件”的范围。

---

## 7. 配置文本本身还支持二次展开

`packages/opencode/src/config/paths.ts:84-144` 的 `parseText()` / `substitute()` 还定义了两种内联替换：

1. `{env:VAR}`：直接读取环境变量。
2. `{file:path}`：把其他文件内容内联进当前配置文本。

这意味着 OpenCode 配置不只是静态 JSONC，还支持：

1. 依赖环境变量注入
2. 依赖外部文件拼装

因此所谓“配置文件”在当前实现里，更像是一份可展开的模板。

---

## 8. `Config.get()` 最后还会做一轮兼容与归一化

`packages/opencode/src/config/config.ts:216-259` 的后处理也很重要：

1. 把旧 `mode` 字段迁成 `agent`
2. 把旧 `tools` 配置迁成 `permission`
3. 把 `autoshare` 迁成 `share`
4. 应用 `Flag.OPENCODE_PERMISSION`
5. 应用关闭 auto compact / prune 的 flag
6. 对 plugin 做去重

其中 plugin 去重实现在 `543+`，本质上是按 plugin 名称保留高优先级来源。

这说明最终 runtime 看到的 config，并不是磁盘原样，而是经过了一轮兼容归一化的结果。

---

## 9. `InstanceBootstrap()` 才是“完整项目 runtime”真正启动的地方

当前固定启动顺序写在 `packages/opencode/src/project/bootstrap.ts:15-24`：

1. `Plugin.init()`
2. `ShareNext.init()`
3. `Format.init()`
4. `LSP.init()`
5. `File.init()`
6. `FileWatcher.init()`
7. `Vcs.init()`
8. `Snapshot.init()`

它的意义不是“把所有服务都立刻做完”，而是把当前 project/instance 作用域里的服务图挂好。

例如：

1. `Format.init()` 会基于 `Config.get()` 建 formatter 集合，并订阅 `File.Event.Edited`，见 `format/index.ts:39-115`。
2. `LSP.init()` 会建可用 server 列表，但具体 language server 仍按文件懒启动，见 [B07](./B07-lsp.md)。
3. `Snapshot.init()` 只准备 snapshot state 和后台清理循环；真正 `git init`/`write-tree` 在 `track()` 时才发生，见 `snapshot/index.ts:68-175`。

所以 bootstrap 的风格是：**固定装配、延迟执行。**

### 9.1 `Plugin.init()`：完整 `Config.get()` 的真正入口

worker runtime 第一次真正触发 `Config.get()` 的地方，就是 `Plugin.init()`。它会：

1. 创建内嵌 SDK client，`fetch` 仍然指向 `Server.Default().fetch(...)`
2. 读取完整配置 `Config.get()`
3. 先加载内建插件，如 `CodexAuthPlugin`、`CopilotAuthPlugin`、`GitlabAuthPlugin`、`PoeAuthPlugin`
4. 如果配置里声明了外部插件
   - 先 `Config.waitForDependencies()`
   - 必要时给配置目录写 `package.json`
   - 执行 `bun install`
   - 再 `import(plugin)` 动态加载
5. 调用插件的 `config` hook
6. 订阅总线事件，把 bus event 交给插件的 `event` hook

因此插件初始化本身也是完整配置系统、依赖安装、动态模块加载的入口。

### 9.2 其他各步的延迟执行细节

| 步骤 | 启动时真正在做什么 | 延迟到何时 |
| --- | --- | --- |
| `Format.init()` | 读取 `Config.get().formatter`，建立 formatter 表，并订阅 `File.Event.Edited` | 真正格式化在文件编辑时按扩展名触发 |
| `LSP.init()` | 读取配置、建立可用 LSP 列表、记录禁用项和扩展名映射 | LSP 子进程按文件访问懒启动 |
| `File.init()` | 建立文件搜索缓存；git 项目下通过 `Ripgrep.files()` 扫描文件并缓存目录层级 | 文件内容读取在具体 tool call 时 |
| `FileWatcher.init()` | 加载 `@parcel/watcher` 平台绑定，订阅项目目录变化；git 项目额外订阅 `.git` | 文件变化事件触发后续处理 |
| `Vcs.init()` | 读取当前 branch，监听 `HEAD` 变化 | 分支变化时发布 `vcs.branch.updated` |
| `Snapshot.init()` | 为当前 project 维护独立 snapshot gitdir：`<Global.Path.data>/snapshot/<project.id>`，建立每小时一次 `git gc --prune=7.days` 清理循环 | 真正写快照在 `Snapshot.track()` 时 |
| `ShareNext.init()` | 订阅 `session.updated`、`message.updated`、`message.part.updated`、`session.diff` 事件 | 真正 share sync 在会话变化时触发 |

---

## 10. 启动与配置系统为什么是 OpenCode 骨架的一部分

把 B08 前面的点合起来，可以得到一个很稳定的结构：

1. import 阶段先保证目录与缓存布局
2. CLI middleware 再保证日志和数据库迁移
3. `Config.get()` 把多来源配置和扩展目录编译成 runtime config
4. `InstanceBootstrap()` 用固定顺序装配一组作用域化服务

因此 OpenCode 当前并不是：

> 先有一个 agent runtime，再去读配置和附加插件

而更接近：

> 先把目录、数据库、配置、扩展和服务图装好，agent runtime 才能成立

---

## 11. 把 B08 压成一句代码级结论

OpenCode 当前的启动/配置链可以压成四句话：

1. **启动不是一次 parse，而是 import、副作用、middleware、config 编译、instance bootstrap 的分层过程。**
2. **配置不是单文件读取，而是带优先级、多来源、可展开、可迁移的编译产物。**
3. **`.opencode` 目录不只是配置覆盖点，更是 commands/agents/plugins/custom tools 的本地扩展仓。**
4. **`InstanceBootstrap()` 通过固定服务顺序，把配置编译结果装配成真正可运行的项目 runtime。**

所以如果要一句话概括 B08：

> 在 OpenCode 里，“启动”真正启动的不是某个聊天循环，而是一整套带配置编译和作用域服务图的 runtime 装配过程。
