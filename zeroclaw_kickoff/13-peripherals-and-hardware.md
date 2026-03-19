# peripherals：硬件能力怎样并进主工具面

ZeroClaw 和多数 agent 项目最大的差异之一，是它把硬件外设当一等运行时能力。

## `Peripheral` trait 先把硬件抽象成稳定契约

`Peripheral` trait 定义了 `name()`、`board_type()`、`connect()`、`disconnect()`、`health_check()` 和 `tools()`。硬件在这里不是特例分支，而是另一种可暴露工具的能力源（`zeroclaw/src/peripherals/traits.rs:24-68`）。

## `create_peripheral_tools()` 把硬件并进主工具注册表

`create_peripheral_tools()` 会根据配置选择 RPi GPIO 或 serial peripheral，实现连接后再把 `peripheral.tools()` 扩展进返回的工具向量。这说明外设并不是“agent 调一个专门硬件服务”，而是直接回流到主工具面（`zeroclaw/src/peripherals/mod.rs:137-232`）。

## agent loop 已经把 peripherals 视作常规工具来源

`agent/loop_.rs` 在构造工具注册表时会调用 `crate::peripherals::create_peripheral_tools(&config.peripherals)`，然后把返回结果扩展进 `tools_registry`。对主循环来说，硬件工具和普通工具没有第二层特殊总线（`zeroclaw/src/agent/loop_.rs:2706-2710`; `zeroclaw/src/agent/loop_.rs:3423-3425`).

## CLI 也把 peripherals 当正式子系统

`PeripheralCommands` 单独定义了 `List`、`Add`、`Flash`、`SetupUnoQ`、`FlashNucleo`，说明硬件支持不仅存在于运行时，还进入了配置和运维命令面（`zeroclaw/src/lib.rs:487-536`; `zeroclaw/src/main.rs:611-627`; `zeroclaw/src/peripherals/mod.rs:43-92`）。

## 关键源码锚点

- 外设契约：`zeroclaw/src/peripherals/traits.rs:24-68`
- 外设工具工厂：`zeroclaw/src/peripherals/mod.rs:137-232`
- agent loop 并入外设工具：`zeroclaw/src/agent/loop_.rs:2706-2710`; `zeroclaw/src/agent/loop_.rs:3423-3425`
- CLI 子系统：`zeroclaw/src/lib.rs:487-536`; `zeroclaw/src/main.rs:611-627`; `zeroclaw/src/peripherals/mod.rs:43-92`

## 阅读问题

- 为什么外设工具要直接并进主注册表，而不是单独开一条设备 RPC？
- 硬件 support 进入 CLI 子系统，对长期运维意味着什么？
