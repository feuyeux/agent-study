# memory 与 session：memory backend 工厂和 channel session manager 怎样分层

ZeroClaw 把“长期记忆”和“对话 session”拆成了两套机制，而且这两套机制分别服务于不同层。

## `Memory` trait 负责长期记忆契约

`Memory` trait 定义了 `store()`、`recall()`、`get()`、`list()`、`forget()`、`count()`、`health_check()` 与可选 `reindex()`。这个接口天然偏长期持久化，不关心渠道线程或即时对话锁（`zeroclaw/src/memory/traits.rs:54-108`）。

## `create_memory_with_storage_and_routes()` 是真正的 memory 总装点

memory 工厂会先决定 backend kind，再解析 embedding 配置，然后依次处理 hygiene、snapshot、auto-hydrate，最后才按 backend 选择具体实现。这意味着 ZeroClaw 的 memory 层不仅选后端，还顺带处理 retention、冷启动恢复和 embedding 初始化（`zeroclaw/src/memory/mod.rs:203-319`）。

## channels 侧的 session manager 是另一套轻量层

`start_channels()` 会通过 `shared_session_manager()` 构造可选 `SessionManager`，然后把它放进 `ChannelRuntimeContext.session_manager`。同一个上下文里还会有 `conversation_histories`、`conversation_locks` 和 `route_overrides`，说明渠道会话管理服务的是并发对话和短期上下文，而不是语义记忆检索（`zeroclaw/src/channels/mod.rs:6075-6105`）。

## 关键源码锚点

- memory 契约：`zeroclaw/src/memory/traits.rs:54-108`
- memory 工厂：`zeroclaw/src/memory/mod.rs:203-319`
- channels session manager：`zeroclaw/src/channels/mod.rs:6075-6105`

## 阅读问题

- 为什么 hygiene/snapshot/hydrate 要放进 memory factory，而不是独立维护命令？
- `conversation_histories` 和 `Memory` 的职责边界在哪条线上？
