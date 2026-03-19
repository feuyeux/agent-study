# 工具面与 runtime adapter：为什么 Runtime 决定 ZeroClaw 能暴露哪些工具

ZeroClaw 的工具系统不是先列一堆工具，再到处做 if-else。它先定义 runtime 能力，再让工具注册表围着这个能力面收缩。

## `RuntimeAdapter` 先决定能力上限

`RuntimeAdapter` trait 把 shell、filesystem、long-running、storage path、memory budget 和 shell command 构造都做成统一契约。运行时如果不支持 shell 或 filesystem，对应工具面天然就该收缩（`zeroclaw/src/runtime/traits.rs:15-75`）。

## `create_runtime()` 让能力差异停在工厂层

`create_runtime()` 只负责选择 `native`、`docker`、`wasm` runtime 实现，上层拿到的一直是 trait object。ZeroClaw 在这里把“平台差异”压进 runtime factory，而不是让工具层到处知道自己跑在哪（`zeroclaw/src/runtime/mod.rs:13-29`）。

## 工具注册表在 agent 总装时一次成型

`Agent::from_config()` 调 `tools::all_tools_with_runtime()` 构造完整工具面，再用 allow/deny 过滤器裁剪 primary agent 可见工具。这里的关键不是某个工具本身，而是工具集合在启动时就已经根据 runtime、安全策略和配置被裁好了（`zeroclaw/src/agent/agent.rs:304-347`）。

## channel 宿主会复用同一套工具装配，但还能继续外挂 MCP

`start_channels()` 也会调 `tools::all_tools_with_runtime()` 构造基础工具集，然后在 `config.mcp.enabled` 时把 `McpRegistry::connect_all()` 拉起，再把 `McpToolWrapper` 包进工具注册表。渠道宿主和 agent 宿主因此共享同一套基础工具语义，只是在宿主层可以继续扩展（`zeroclaw/src/channels/mod.rs:5792-5825`）。

## 关键源码锚点

- runtime 契约：`zeroclaw/src/runtime/traits.rs:15-75`
- runtime 工厂：`zeroclaw/src/runtime/mod.rs:13-29`
- agent 工具装配：`zeroclaw/src/agent/agent.rs:304-347`
- channel 工具扩展：`zeroclaw/src/channels/mod.rs:5792-5825`

## 阅读问题

- 为什么 ZeroClaw 把 runtime 差异压进 `build_shell_command()`，而不是让每个 shell 工具自己处理？
- agent 和 channels 共用工具注册逻辑，对行为一致性有什么价值？
