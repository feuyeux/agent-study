# 先看系统形态：为什么 ZeroClaw 是 trait 驱动的多宿主 Rust runtime

ZeroClaw 最值得先建立的判断是：它不是“一个 agent 程序，顺手带个 gateway”。从源码看，它的中心是 runtime contract 和装配工厂。

## 命令很多，但真正稳定的是命令后面的宿主模式

`Commands` 枚举里既有 `Agent`、`Gateway`、`Daemon`，也有 `Service`、`Doctor`、`Status`、`Peripheral`。`main()` 先统一处理 config、logging、OTP 初始化，再把不同命令导向 `agent::run()`、`gateway::run_gateway()`、`daemon::run()` 等分支。这表明 CLI 只是总调度器（`zeroclaw/src/main.rs:231-430`; `zeroclaw/src/main.rs:920-1210`）。

## `RuntimeAdapter` 才是稳定骨架

`RuntimeAdapter` trait 定义了 `has_shell_access()`、`has_filesystem_access()`、`storage_path()`、`supports_long_running()`、`memory_budget()`、`build_shell_command()`。也就是说，ZeroClaw 先问“当前 runtime 能做什么”，再问“当前命令想做什么”（`zeroclaw/src/runtime/traits.rs:15-75`）。

`create_runtime()` 的角色也很纯粹，只按 `runtime.kind` 选择 `native`、`docker`、`wasm` 实现。运行环境的可变性被压进工厂，而上层始终只看 trait（`zeroclaw/src/runtime/mod.rs:13-29`）。

## `Agent` 是组合体，不是巨型过程函数

`Agent` 结构体把 provider、tools、memory、observer、prompt_builder、tool_dispatcher、memory_loader、history、turn_buffer、classification、research 等全部拉成显式字段。`AgentBuilder` 则把这些部件的装配顺序变成可组合过程（`zeroclaw/src/agent/agent.rs:24-120`）。

## 总装发生在 `Agent::from_config()`

`Agent::from_config()` 里能清楚看到几条工厂链：`create_memory_with_storage_and_routes()` 负责 memory，`tools::all_tools_with_runtime()` 负责工具面，`create_routed_provider()` 负责 provider，tool dispatcher 再根据 config 和 provider native-tools 能力决定选 `NativeToolDispatcher` 还是 `XmlToolDispatcher`（`zeroclaw/src/agent/agent.rs:285-390`）。

## 关键源码锚点

- 命令面：`zeroclaw/src/main.rs:231-430`
- 主分发：`zeroclaw/src/main.rs:920-1210`
- runtime contract：`zeroclaw/src/runtime/traits.rs:15-75`
- runtime factory：`zeroclaw/src/runtime/mod.rs:13-29`
- agent 结构与 builder：`zeroclaw/src/agent/agent.rs:24-120`
- agent 总装：`zeroclaw/src/agent/agent.rs:285-390`

## 阅读问题

- 如果拿掉 `RuntimeAdapter`，哪些工具和宿主分支会立刻耦死在一起？
- `AgentBuilder` 在这里解决的是测试问题，还是架构组合问题？
