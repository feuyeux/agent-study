# 建议阅读路径：顺着工厂链、宿主层和扩展面读

## 第一条主链：先打通内核总装

先读 `main.rs` 的命令分发（`zeroclaw/src/main.rs:231-430`; `zeroclaw/src/main.rs:1090-1194`），再读 `RuntimeAdapter` 与 `create_runtime()`（`zeroclaw/src/runtime/traits.rs:15-75`; `zeroclaw/src/runtime/mod.rs:13-29`），随后进入 `Agent::from_config()` 与主循环（`zeroclaw/src/agent/agent.rs:285-390`; `zeroclaw/src/agent/agent.rs:617-745`）。

## 第二条主链：补 provider 和 memory 两条工厂

把 `Provider` trait、`create_routed_provider()`、`RouterProvider` 连起来读，再读 `Memory` trait 与 `create_memory_with_storage_and_routes()`。这两条线会解释 ZeroClaw 的“后端装配”是怎样成型的（`zeroclaw/src/providers/traits.rs:323-449`; `zeroclaw/src/providers/mod.rs:1715-1820`; `zeroclaw/src/providers/router.rs:21-199`; `zeroclaw/src/memory/traits.rs:54-108`; `zeroclaw/src/memory/mod.rs:203-319`）。

## 第三条主链：再看多宿主复用

读 `run_gateway()`、`start_channels()`、`daemon::run()`，理解 Gateway、Channels、Daemon 怎样复用同一套 provider/memory/runtime/security/tool 装配（`zeroclaw/src/gateway/mod.rs:403-492`; `zeroclaw/src/channels/mod.rs:5698-5825`; `zeroclaw/src/daemon/mod.rs:61-174`）。

## 第四条主链：最后补协作与扩展

协作线读 `subagent_spawn`、`SubAgentRegistry`、coordination bus（`zeroclaw/src/tools/subagent_spawn.rs:153-330`; `zeroclaw/src/tools/subagent_registry.rs:16-180`; `zeroclaw/src/coordination/mod.rs:812-904`; `zeroclaw/src/coordination/mod.rs:1094-1268`）；扩展线读 plugins/WASM/peripherals（`zeroclaw/src/plugins/loader.rs:23-120`; `zeroclaw/src/tools/wasm_tool.rs:315-492`; `zeroclaw/src/peripherals/mod.rs:137-232`）。

## 不建议的读法

不要先从 `gateway/openclaw_compat.rs` 或某个具体渠道文件开始。那样容易把 ZeroClaw 误读成接口适配层，而看不到它真正的工厂链和 runtime contract。
