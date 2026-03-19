# 架构总图：ZeroClaw 的主干是 `Config -> Factories -> Runtime Contracts -> Agent/Gateway/Daemon`

ZeroClaw 的架构图不要从目录画，而要从装配顺序画。源码里的稳定顺序很清楚。

## 第一段：配置与入口决定宿主模式

`main()` 先加载 config、应用环境覆盖、初始化 observability 和 OTP，然后才根据 `Commands` 进入 `agent`、`gateway` 或 `daemon`。入口不是系统中心，但它决定了哪种宿主壳会把同一套内核装起来（`zeroclaw/src/main.rs:920-1090`; `zeroclaw/src/main.rs:1090-1194`）。

## 第二段：runtime contract 决定能力上限

`RuntimeAdapter` 定义 shell、filesystem、long-running、storage path 和 shell command 构造；`create_runtime()` 负责实例化具体 runtime。ZeroClaw 的很多功能可不可用，不是 later if-else 决定，而是 runtime trait 从一开始就限定好的（`zeroclaw/src/runtime/traits.rs:15-75`; `zeroclaw/src/runtime/mod.rs:13-29`）。

## 第三段：核心工厂链负责总装

`Agent::from_config()` 同时调用 memory factory、tool factory 和 provider factory：`create_memory_with_storage_and_routes()`、`tools::all_tools_with_runtime()`、`create_routed_provider()`。这条链把 storage、tooling、provider routing 压进统一总装点（`zeroclaw/src/agent/agent.rs:285-390`; `zeroclaw/src/memory/mod.rs:203-319`; `zeroclaw/src/providers/mod.rs:1718-1820`）。

## 第四段：同一内核被多个宿主复用

`run_gateway()` 自己装 provider、memory、runtime、security 和 tools registry，然后挂 HTTP/WebSocket/API；`start_channels()` 也做类似装配，再把 channel runtime context 建起来；`daemon::run()` 只是把 gateway、channels、heartbeat 和 scheduler 作为 supervised component 拉起来。这三层是不同宿主，不是不同 agent 内核（`zeroclaw/src/gateway/mod.rs:403-492`; `zeroclaw/src/channels/mod.rs:5698-5825`; `zeroclaw/src/daemon/mod.rs:61-174`）。

## 第五段：安全和扩展是横切面

`SecurityPolicy`、sandbox 检测、pairing、estop 会直接改变工具和宿主行为；plugin/WASM/peripheral 也通过工厂与 trait 接回主系统。这些都不是边角模块，而是架构横切面（`zeroclaw/src/security/policy.rs:115-193`; `zeroclaw/src/security/detect.rs:7-113`; `zeroclaw/src/plugins/loader.rs:23-120`; `zeroclaw/src/peripherals/mod.rs:137-232`）。

## 关键源码锚点

- 入口分发：`zeroclaw/src/main.rs:920-1194`
- runtime 契约：`zeroclaw/src/runtime/traits.rs:15-75`
- 内核总装：`zeroclaw/src/agent/agent.rs:285-390`
- memory 工厂：`zeroclaw/src/memory/mod.rs:203-319`
- provider 工厂：`zeroclaw/src/providers/mod.rs:1718-1820`
- 多宿主复用：`zeroclaw/src/gateway/mod.rs:403-492`; `zeroclaw/src/channels/mod.rs:5698-5825`; `zeroclaw/src/daemon/mod.rs:61-174`

## 阅读问题

- 为什么 ZeroClaw 的“架构中心”更像工厂链，而不是某个核心模块？
- `daemon` 复用 `gateway` 和 `channels` 的方式，暴露了哪些系统边界？
