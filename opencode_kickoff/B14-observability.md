# OpenCode 深度专题 B14：可观测性，日志、Bus 事件与运行时状态追踪

> 本文基于 `opencode` `v1.3.2`（tag `v1.3.2`，commit `0dcdf5f529dced23d8452c9aa5f166abb24d8f7c`）源码校对

可观测性不是"加几个 console.log"那么简单。在 OpenCode 当前实现里，可观测性依赖三条正交的系统：结构化日志（`Log`）、实例内事件总线（`Bus`）、和进程级全局事件广播（`GlobalBus`）。这三条线各自独立又相互配合，构成运行时状态追踪的完整底座。B14 就把这三条线全部拆开。

---

## 1. 可观测性在 OpenCode 里有三个独立支柱

| 支柱 | 代码坐标 | 职责 |
| --- | --- | --- |
| 结构化日志 | `util/log.ts` | 带 service tag、level 过滤、timing 度量的持久化日志 |
| 实例内事件总线 | `bus/index.ts` | 按 instance scope 划分的 typed pub/sub |
| 进程级全局广播 | `bus/global.ts` | Node `EventEmitter`，跨 instance 传递事件 |

这三条线的共同特点是：**它们都不是业务逻辑的一部分，但支撑着所有业务逻辑的可追踪性。**

---

## 2. Log：结构化日志不只是打印字符串

### 2.1 日志五要素

`util/log.ts` 的 `Logger` 接口（`25-39`）暴露的实际上是五个能力：

```ts
debug(message?, extra?)  // DEBUG 级别
info(message?, extra?)   // INFO 级别
warn(message?, extra?)   // WARN 级别
error(message?, extra?)  // ERROR 级别
tag(key, value)          // 链式打标签
time(message, extra?)    // 自动计时作用域
```

每条日志输出格式是：

```
{timestamp} +{diff_ms} {tags...} {message}
```

其中 `diff_ms` 是相对于上一次日志的时间差。这意味着读日志时不仅能看到事件内容，还能还原事件发生的时序关系。

### 2.2 Service tag 缓存

`create()`（`100-181`）用 service name 做缓存 key（`106-109`）：

```ts
const cached = loggers.get(service)
if (cached) return cached
```

同一个 service 的 logger 只创建一次，之后复用。这意味着 `Log.create({ service: "bus" })` 在同一个进程里永远返回同一个 logger 实例。

### 2.3 自动文件轮转

`init()`（`60-78`）在初始化时：

1. 日志文件路径 = `Global.Path.log` + `{dev ? "dev.log" : "YYYY-MM-DDTHHMMSS.log"}`
2. 每次启动时 `fs.truncate(logpath)` 清空旧内容
3. `cleanup()`（`80-90`）在启动时保留最近 10 个日志文件，多于 5 个时删旧

所以本地开发日志会不断追加到 `dev.log`，生产模式每次启动新文件。

### 2.4 `time()` 是最实用的Scoped 计时器

`time()`（`157-173`）利用 `Symbol.dispose` 实现自动计时：

```ts
using timer = logger.time("build", { step: 1 })
// ... 做事情 ...
// 离开作用域时自动 stop()，输出 "build status=completed duration=123ms step=1"
```

这比手动记录开始/结束时间要安全得多，异常路径下也不会漏记录。

---

## 3. Bus：实例内的 typed pub/sub

### 3.1 核心设计：instance-scoped 单例

`bus/index.ts` 的 `state` 用 `Instance.state()` 管理订阅表（`18-39`）：

```ts
const state = Instance.state(
  () => { subscriptions: new Map() },
  teardown // instance 销毁时清理
)
```

这意味着：
- 每个 workspace/project 实例有独立的订阅表
- 订阅关系跟着 instance 生命周期走，不会跨实例泄漏
- instance 销毁时会向 `*` wildcard 订阅者广播 `server.instance.disposed`

### 3.2 wildcard 订阅

`subscribeAll(callback)` 注册到 `"*"` key，`publish()` 时对 `type` 和 `"*"` 都触发（`53-57`）。这让某些 consumer（典型是 plugin）可以监听所有事件而不需要逐个声明。

### 3.3 GlobalBus 桥接

`publish()` 最后总是调用 `GlobalBus.emit("event", { directory, payload })`（`59-62`），把事件从 instance scope 广播到进程层。这实现了：

- worker 内多个 instance 的事件可以被外部 UI 通过 SSE 感知
- 同一进程内的跨 instance 通信（虽然不常用）

---

## 4. BusEvent：所有事件类型的集中注册表

`bus-event.ts` 的 `define()` 函数（`12-18`）做两件事：

1. 返回一个 typed `BusEvent.Definition`
2. 把定义注册到全局 `registry`

`payloads()`（`21-42`）把所有注册的事件聚合成一个 discriminated union schema，供 SDK 层做 event 类型校验。

这意味着事件类型不是散在代码各处的字符串字面量，而是集中管理、可以枚举的。

---

## 5. 实际定义了哪些事件

当前定义的事件分散在各个模块里：

| 事件 | 定义位置 | 触发时机 |
| --- | --- | --- |
| `session.status` | `session/status.ts:31` | session 状态变为 idle/busy/retry |
| `session.idle` | `session/status.ts:39` | session 回到 idle（已废弃，用 session.status 代替） |
| `session.updated` | `session/index.ts` | session 元信息更新 |
| `message.updated` | `session/index.ts` | message 写入 |
| `message.part.updated` | `session/index.ts` | part 写入 |
| `session.diff` | `session/summary.ts` | diff 计算完成 |
| `tool.started` | `session/processor.ts` | 工具调用开始 |
| `tool.completed` | `session/processor.ts` | 工具调用完成 |
| `permission.asked` | `permission/index.ts` | 等待用户授权 |
| `question.asked` | `question/index.ts` | 等待用户澄清 |
| `mcp.tools.changed` | `mcp/index.ts:43` | MCP server 动态更新了 tool list |
| `lsp.updated` | `lsp/index.ts` | LSP 诊断结果更新 |
| `pty.created/exited/updated` | `pty/index.ts` | PTY 生命周期 |
| `project.updated` | `project/index.ts` | 项目配置变更 |
| `worktree.ready/failed` | `worktree/index.ts` | sandbox 创建结果 |
| `server.instance.disposed` | `bus/index.ts:11` | instance 关闭 |
| `server.connected` | `server/index.ts` | 客户端连接 |

---

## 6. SessionStatus：session 级别的运行时状态

`session/status.ts` 用 Effect + InstanceState 实现了一个带类型的 session 状态服务：

- `idle`：等待输入
- `busy`：正在处理
- `retry`：可重试错误后的等待状态（带 `next` 毫秒数）

`set()` 不仅更新内存状态，还会 `Bus.publish(Event.Status, { sessionID, status })`，让订阅者感知状态变化。

---

## 7. effect 系统：实例作用域的状态缓存

`effect/instance-state.ts` 的 `InstanceState` 封装（`7-46`）是基于 `effect`库的 `ScopedCache`，按 `Instance.directory` 做缓存分区：

- `get()` 时用 `Instance.directory` 做 key 查缓存
- instance 销毁时通过 `registerDisposer` 自动失效
- 同一 instance 内的多个 consumer 共享同一份缓存状态

这是 OpenCode 实现"每个 workspace 有独立运行时状态"而不是"全局单例"的核心机制。

---

## 8. 日志与 Bus 的协作模式

实践中，日志和 Bus 通常配合使用。以一个工具调用为例：

```
用户触发 tool_call
  → processor 开始执行
    → logger.info("tool started", { tool, args })          // 日志：详细参数
    → Bus.publish(ToolStart, { tool, sessionID })           // 事件：通知 UI
    → 工具执行...
    → logger.time("tool " + tool)(auto-stop on dispose)     // 日志：自动计时
    → Bus.publish(ToolComplete, { tool, result })           // 事件：通知 UI
    → logger.info("tool completed", { tool, duration })     // 日志：完成状态
```

日志负责**事后分析**（写文件、可查历史），Bus 负责**实时通知**（推 UI、触发回调）。

---

## 9. 可观测性为什么没有独立成"SDK"

很多系统会把日志/Bus/状态抽象成独立 SDK 包。OpenCode 没有这么做，原因有两个：

1. **直接依赖主模块**：Bus 定义依赖 `BusEvent`，`BusEvent` 依赖 `Log`，形成自然内聚
2. **instance scope 是第一公民**：如果抽成独立包，反而要在包内重新实现 instance scope 绑定

所以可观测性始终是 runtime 的内置能力，而不是外部依赖。

---

## 10. 把 B14 压成一句代码级结论

> OpenCode 的可观测性依赖三条正交线：结构化日志提供持久化历史，typed Bus 提供实例内实时事件流，GlobalBus 把事件跨实例广播到 UI；这三条线都围绕 instance scope 做隔离，而不是全局单例。
