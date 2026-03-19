# ZeroClaw 源码 Kickoff

- [先看系统形态：`Commands`、`create_runtime()`、`RuntimeAdapter` 为什么定义了 ZeroClaw 的基本骨架](./01-runtime-shape.md)
- [架构总图：为什么 ZeroClaw 的主干是 `Config -> Factories -> Runtime Contracts -> Agent/Gateway/Daemon`](./02-architecture-diagram.md)
- [入口与运行模式：`agent`、`gateway`、`daemon` 怎样共用同一套内核](./03-entry-command-and-runtime-modes.md)
- [agent loop：`Agent::from_config()` 和主循环怎样把 provider、tools、memory、history 串成一个 turn](./04-agent-loop-and-tool-dispatch.md)
- [安全优先 runtime：`SecurityPolicy`、sandbox、pairing、estop 怎样直接塑造行为边界](./05-security-first-runtime.md)
- [工具面与 runtime adapter：为什么 Runtime 决定 ZeroClaw 能暴露哪些工具](./06-tool-registry-and-runtime-adapters.md)
- [provider 工厂与路由：`create_routed_provider()`、`RouterProvider`、`Provider` trait 的职责分层](./07-provider-factory-routing-and-failover.md)
- [memory 与 session：memory backend 工厂和 channel session manager 怎样分层](./08-memory-and-session-layer.md)
- [gateway 与 OpenClaw 兼容层：Web 宿主怎样接回同一套 agent 内核](./09-gateway-dashboard-and-openclaw-compat.md)
- [daemon 与 channels：长期运行 supervisor 怎样把 gateway、channels、heartbeat、scheduler 编成一台宿主](./10-daemon-and-channel-supervision.md)
- [subagents 与 coordination：协作协议、上下文快照和负载选择怎样落地](./11-subagents-teams-and-coordination.md)
- [plugins 与 WASM：ZeroClaw 怎样开出受控扩展面](./12-plugins-and-wasm-extension.md)
- [peripherals：硬件能力怎样并进主工具面](./13-peripherals-and-hardware.md)
- [建议阅读路径](./14-reading-path.md)
- [最终心智模型](./15-final-mental-model.md)

## 先抓住五个源码判断

- `main.rs` 的 `Commands` 枚举把 `Onboard`、`Agent`、`Gateway`、`Daemon`、`Service`、`Doctor`、`Status`、`Peripheral` 等入口统一收进一个 CLI 外壳，而 `main()` 再把它们导向不同宿主模式，说明 ZeroClaw 从入口上就是一台多模式 runtime，而不是单一 agent 命令（`zeroclaw/src/main.rs:231-430`; `zeroclaw/src/main.rs:920-1210`）。
- `RuntimeAdapter` trait 把 shell、filesystem、long-running、storage path、memory budget 和 shell command 构造抽成统一契约，`create_runtime()` 只负责根据 `runtime.kind` 选 `NativeRuntime`、`DockerRuntime`、`WasmRuntime`。真正稳定的边界因此不是命令名，而是 runtime contract（`zeroclaw/src/runtime/traits.rs:15-75`; `zeroclaw/src/runtime/mod.rs:13-29`）。
- `Agent` 结构体和 `AgentBuilder` 汇总了 provider、tools、memory、observer、prompt builder、tool dispatcher、history、turn buffer、research/config 等状态；`Agent::from_config()` 再通过 memory factory、tool registry 和 routed provider 完成总装，说明 agent 核心是组合装配而不是单体函数（`zeroclaw/src/agent/agent.rs:24-120`; `zeroclaw/src/agent/agent.rs:285-390`）。
- 真正的一轮执行在 `Agent` 主循环里：`provider.chat()`、`parse_response()`、`execute_tools()`、`LoopDetector`、history trim、fact extraction 和 autosave 全都编进同一个 turn 里，所以 provider 调用只是中段而不是起点（`zeroclaw/src/agent/agent.rs:617-745`）。
- `run_gateway()`、`start_channels()`、`daemon::run()` 都在复用同样的 provider/memory/runtime/security/tool 装配链，因此 Gateway、Channels、Daemon 只是不同宿主壳，不是不同系统（`zeroclaw/src/gateway/mod.rs:403-492`; `zeroclaw/src/channels/mod.rs:5698-5825`; `zeroclaw/src/daemon/mod.rs:61-174`）。

## 最短源码路线

先读 `main.rs` 的 `Commands` 和 `main()` 分发，理解有哪些宿主模式（`zeroclaw/src/main.rs:231-430`; `zeroclaw/src/main.rs:1090-1194`）；再读 `RuntimeAdapter` 与 `create_runtime()`，理解运行环境如何约束能力（`zeroclaw/src/runtime/traits.rs:15-75`; `zeroclaw/src/runtime/mod.rs:13-29`）；随后进入 `Agent::from_config()` 与主循环，把内核打通（`zeroclaw/src/agent/agent.rs:285-390`; `zeroclaw/src/agent/agent.rs:617-745`）；最后再补 `run_gateway()`、`start_channels()` 和 `daemon::run()` 看宿主层怎样复用内核（`zeroclaw/src/gateway/mod.rs:403-492`; `zeroclaw/src/channels/mod.rs:5698-5825`; `zeroclaw/src/daemon/mod.rs:61-174`）。
