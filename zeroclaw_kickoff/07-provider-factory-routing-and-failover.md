# provider 工厂与路由：`create_routed_provider()`、`RouterProvider`、`Provider` trait 的职责分层

ZeroClaw 的 provider 层分成三层：统一契约、工厂装配、运行时路由。

## `Provider` trait 先统一了交互协议

`Provider` trait 定义了 `chat_with_system()`、`chat_with_history()`、结构化 `chat()`，并把工具协商抽成 `convert_tools()` 与 `ToolsPayload`。默认实现甚至会在 provider 不支持 native tools 时把工具说明注入 system prompt，这说明 provider 抽象本身就包含了 tool fallback 语义（`zeroclaw/src/providers/traits.rs:323-449`）。

## `create_routed_provider()` 决定要不要进入路由模式

`create_routed_provider()` 在 `model_routes` 为空时直接退回 `create_resilient_provider_with_options()`；只有在存在 route 时，才继续走 routed provider 初始化。这说明“是否启用 provider 路由”是工厂层决策，不是调用时临时分支（`zeroclaw/src/providers/mod.rs:1715-1755`）。

## `create_routed_provider_with_options()` 真正做的是多 provider 装配

这个函数会先尝试构建 primary provider；如果 default model 是 hint，primary 初始化失败时仍可继续走 hint-based route。随后它再为每条 route 单独建 provider 实例，把 route-specific API key、transport 和运行时选项隔离开，避免不同 route 的配置互相污染（`zeroclaw/src/providers/mod.rs:1737-1820`）。

## `RouterProvider` 负责把 hint 解析成真正的 provider/model

`RouterProvider` 内部维护 `routes`、`providers`、`default_index`、`default_model` 和 vision override。`resolve()` 会把 `hint:<name>` 解析成具体 provider index 和 model；`chat_with_system()`、`chat_with_history()`、`chat()`、`chat_with_tools()` 都只是在 runtime 把请求转发到解析后的 provider 实例上（`zeroclaw/src/providers/router.rs:21-199`）。

## 关键源码锚点

- provider 契约：`zeroclaw/src/providers/traits.rs:323-449`
- routed provider 工厂：`zeroclaw/src/providers/mod.rs:1715-1820`
- runtime 路由器：`zeroclaw/src/providers/router.rs:21-199`

## 阅读问题

- 为什么路由逻辑要放在 `RouterProvider`，而不是让调用方自己先解析 hint？
- route-specific credential 隔离解决的根本问题是什么？
