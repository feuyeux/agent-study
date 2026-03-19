# 最终心智模型：把 ZeroClaw 看成“以 runtime contract 和工厂链为中心的多宿主 agent runtime”

最稳的抓法是四句话：

- `RuntimeAdapter` 决定能力边界，因为 shell、filesystem、long-running 和 storage 都在 trait 里被先验定义（`zeroclaw/src/runtime/traits.rs:15-75`）。
- `Agent::from_config()` 是总装中心，因为 provider、tools、memory、dispatcher 都在这里成型（`zeroclaw/src/agent/agent.rs:285-390`）。
- Gateway、Channels、Daemon 只是不同宿主壳，因为它们复用同一套 provider/memory/runtime/security/tool 装配（`zeroclaw/src/gateway/mod.rs:403-492`; `zeroclaw/src/channels/mod.rs:5698-5825`; `zeroclaw/src/daemon/mod.rs:61-174`）。
- 安全、协作、插件、外设都是横切扩展面，因为它们会直接反作用到宿主与工具语义，而不是停留在边缘插件层（`zeroclaw/src/security/policy.rs:115-193`; `zeroclaw/src/tools/subagent_spawn.rs:153-330`; `zeroclaw/src/plugins/loader.rs:23-120`; `zeroclaw/src/peripherals/mod.rs:137-232`）。

所以 ZeroClaw 不是“又一个 CLI agent”，而是一台可在 native/docker/wasm runtime 上装配、可挂 Web 和实时渠道、可接协作协议与硬件外设的 Rust agent runtime。
