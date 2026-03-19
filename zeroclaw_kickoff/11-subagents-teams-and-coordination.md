# subagents 与 coordination：协作协议、上下文快照和负载选择怎样落地

ZeroClaw 的协作层已经不是抽象草图，而是由 subagent runtime、注册表和 coordination bus 组成的可执行结构。

## `subagent_spawn` 是正式工具入口

`subagent_spawn` 的 schema 要求 `task`，可选 `agent` 和 `context`；执行时先检查 subagent 开关和 `SecurityPolicy::enforce_tool_operation(ToolOperation::Act, "subagent_spawn")`，再按负载快照和选择策略挑选 agent，最后创建 provider、构造 prompt、生成 `session_id` 并注册后台任务。这说明“派发给子代理”已经是一等工具操作（`zeroclaw/src/tools/subagent_spawn.rs:153-330`）。

## `SubAgentRegistry` 负责真实生命周期

`SubAgentRegistry` 维护 `SubAgentSession`，支持并发上限检查、handle 绑定、complete/fail/kill、状态查询和列表清理。这里保存的不是抽象计划，而是后台任务的真实运行态（`zeroclaw/src/tools/subagent_registry.rs:16-180`）。

## coordination bus 把共享上下文做成版本化协议

`delegate_context_entries_recent_with_offset()` 和相关 API 允许按写入顺序、按 correlation ID 抽取 `delegate/` 命名空间下的共享上下文；`apply_context_patch_locked()` 则在写入时检查 delegate key/correlation 对齐、版本号匹配、容量淘汰和顺序维护。协作上下文在这里是版本化数据结构，而不是随手拼接的上下文字符串（`zeroclaw/src/coordination/mod.rs:812-904`; `zeroclaw/src/coordination/mod.rs:1094-1268`）。

## 默认配置已经把协作当成常规能力

`config/schema.rs` 里 coordination、agent teams、subagents 都有默认开启与负载平衡策略默认值。这说明协作不是实验特性，而是被预期会进入正常运行时配置的能力（`zeroclaw/src/config/schema.rs:801-899`）。

## 关键源码锚点

- `subagent_spawn`：`zeroclaw/src/tools/subagent_spawn.rs:153-330`
- `SubAgentRegistry`：`zeroclaw/src/tools/subagent_registry.rs:16-180`
- delegate context snapshot：`zeroclaw/src/coordination/mod.rs:812-904`
- context patch 应用：`zeroclaw/src/coordination/mod.rs:1094-1268`
- 协作默认配置：`zeroclaw/src/config/schema.rs:801-899`

## 阅读问题

- 为什么 delegate context 要单独有 correlation-aware 顺序索引？
- `SubAgentRegistry` 和 coordination bus 分别解决的是“执行”还是“协议”问题？
