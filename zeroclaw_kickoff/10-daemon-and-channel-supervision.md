# daemon 与 channels：长期运行 supervisor 怎样把 gateway、channels、heartbeat、scheduler 编成一台宿主

ZeroClaw 的长期运行形态不在 `gateway`，而在 `daemon + channels` 这层。

## `daemon::run()` 本质上是组件 supervisor

函数入口先做端口占用预检，再根据配置拉起 state writer、gateway supervisor、channels supervisor、heartbeat supervisor 和 scheduler supervisor，最后等待关机信号并执行 graceful drain。它关注的是组件生命周期，而不是单次对话（`zeroclaw/src/daemon/mod.rs:61-174`）。

`spawn_component_supervisor()` 还给每个组件加上 health 标记、restart 计数和指数退避，说明 daemon 的设计目标是把 ZeroClaw 当常驻服务养起来（`zeroclaw/src/daemon/mod.rs:226-260`）。

## Channel trait 定义了统一消息宿主接口

`ChannelMessage`、`SendMessage` 和 `Channel` trait 把 listen/send、draft update、approval prompt、reaction 等能力统一抽象出来。渠道差异被压进 trait 实现，而上层统一处理消息流水线（`zeroclaw/src/channels/traits.rs:5-174`）。

## `process_message()` 才是入站消息的真实管线

`process_message()` 会记录 runtime trace、跑 `on_message_received` hook、处理 runtime command、应用 prompt/perplexity guard，然后再继续进入后续执行链。它不是简单转发到 provider，而是包含了一整套 ingress 治理（`zeroclaw/src/channels/mod.rs:3536-3660`）。

## `start_channels()` 负责把渠道接到统一运行时上下文

`start_channels()` 先清理旧句柄，再装配 provider、observer bridge、runtime、security、memory、工具注册表和 system prompt，然后构造 `ChannelRuntimeContext`，把 `session_manager`、`conversation_histories`、`provider_cache`、`route_overrides`、hooks 等都放进去。渠道不是薄 adapter，而是接到一台完整运行时（`zeroclaw/src/channels/mod.rs:5698-5825`; `zeroclaw/src/channels/mod.rs:6075-6105`）。

## 关键源码锚点

- daemon supervisor：`zeroclaw/src/daemon/mod.rs:61-174`; `zeroclaw/src/daemon/mod.rs:226-260`
- channel 抽象：`zeroclaw/src/channels/traits.rs:5-174`
- 入站消息管线：`zeroclaw/src/channels/mod.rs:3536-3660`
- channels 宿主装配：`zeroclaw/src/channels/mod.rs:5698-5825`; `zeroclaw/src/channels/mod.rs:6075-6105`

## 阅读问题

- 为什么 ZeroClaw 要在 daemon 层而不是 systemd 层实现组件 supervisor？
- `process_message()` 里哪些步骤说明 channel ingress 不是 provider 调用前的小前菜？
