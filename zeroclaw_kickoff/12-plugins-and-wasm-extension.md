# plugins 与 WASM：ZeroClaw 怎样开出受控扩展面

ZeroClaw 的扩展面分成两层：Rust 侧插件注册表，以及 WASM 工具执行面。

## Rust 插件 loader 先做治理再做注册

`resolve_enable()` 统一处理 `plugins.enabled`、allowlist、denylist 和 per-entry enabled；`load_plugins()` 则按 builtin plugin 和磁盘发现插件两条来源建立 `PluginRegistry`。这条主链的重点是决定“谁有资格进入系统”，而不是直接执行外部代码（`zeroclaw/src/plugins/loader.rs:23-120`）。

## `run_register()` 把插件接入做成受控协议

`run_register()` 用 `catch_unwind` 包住 `plugin.register(&mut api)`，返回 `PluginApi` 或结构化错误。插件即使 panic，也会被隔离成注册失败，而不会把宿主直接炸穿（`zeroclaw/src/plugins/loader.rs:41-64`）。

## `PluginRuntime` 是另一层更轻的 manifest/runtime 面

`PluginRuntime::load_manifest()` 和 `load_registry_from_config()` 负责读取 `.plugin.toml/.plugin.json`，在 manifest 层做校验，再生成 registry。这一层承担的是描述文件发现和静态登记，不直接执行工具逻辑（`zeroclaw/src/plugins/runtime.rs:30-86`）。

## WASM 工具把执行能力再压进沙箱协议

`WasmManifest` 描述工具名、描述和参数 schema；`load_wasm_tools_from_skills()` 扫描 skills 目录，按 dev layout 或 installed layout 发现 `tool.wasm + manifest.json`；`load_single_tool()` 再验证 snake_case 名称并通过 `WasmTool::load()` 导入。ZeroClaw 在这里把“技能工具”做成受限格式，而不是任意脚本（`zeroclaw/src/tools/wasm_tool.rs:315-492`）。

## `WasmModuleTool` 让运行时按能力执行模块

`WasmModuleTool` 会从参数里解析 `read_workspace`、`write_workspace`、`allowed_hosts`、fuel/memory override，并把这些能力请求收敛成 `WasmCapabilities`。WASM 执行在这里不是二进制直跑，而是受 runtime policy 约束的能力申请（`zeroclaw/src/tools/wasm_module.rs:9-120`）。

## 关键源码锚点

- 插件 enable/load/register：`zeroclaw/src/plugins/loader.rs:23-120`
- manifest/runtime 层：`zeroclaw/src/plugins/runtime.rs:30-86`
- WASM manifest 与扫描：`zeroclaw/src/tools/wasm_tool.rs:315-492`
- WASM module tool：`zeroclaw/src/tools/wasm_module.rs:9-120`

## 阅读问题

- 为什么 ZeroClaw 既有 Rust plugin loader，又有独立的 WASM 工具面？
- `WasmCapabilities` 这种“能力申请”模式比直接暴露文件和网络权限强在哪里？
