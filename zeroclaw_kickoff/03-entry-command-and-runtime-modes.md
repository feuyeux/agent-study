# 入口与运行模式：`agent`、`gateway`、`daemon` 怎样共用同一套内核

ZeroClaw 的三个主要运行模式不是三套系统，而是三种宿主壳。

## `main()` 先统一做环境准备

在命令分发前，`main()` 会处理 `--config-dir`、初始化 logging、运行 onboarding 特殊分支、加载 config、应用环境覆盖、初始化 runtime trace 和 OTP。这意味着宿主分支的共同前置都被收敛到入口（`zeroclaw/src/main.rs:920-1088`）。

## `agent` 模式：最直接的执行壳

`Commands::Agent` 分支会把 autonomy、tool iteration、history、compact_context、memory backend 等 CLI override 写回 config，然后调用 `agent::run()`。这里的壳最薄，因为它几乎直接通向 agent loop（`zeroclaw/src/main.rs:1093-1140`）。

## `gateway` 模式：把同一内核挂到 Web 宿主上

`Commands::Gateway` 分支处理 pairing token 重置、端口/host 决议和 dashboard 自动打开，然后调用 `gateway::run_gateway()`。它没有换掉内核，只是给内核套上 HTTP/WebSocket/API 外壳（`zeroclaw/src/main.rs:1142-1183`）。

## `daemon` 模式：把多个组件编进 supervisor

`Commands::Daemon` 只是解析 host/port 后进入 `daemon::run()`。真正的区别不在命令入口，而在 daemon 会继续拉起 gateway、channels、heartbeat 和 scheduler，并做重启退避与状态写盘（`zeroclaw/src/main.rs:1185-1194`; `zeroclaw/src/daemon/mod.rs:61-174`）。

## 关键源码锚点

- 入口准备：`zeroclaw/src/main.rs:920-1088`
- `agent` 分支：`zeroclaw/src/main.rs:1093-1140`
- `gateway` 分支：`zeroclaw/src/main.rs:1142-1183`
- `daemon` 分支：`zeroclaw/src/main.rs:1185-1194`
- daemon supervisor：`zeroclaw/src/daemon/mod.rs:61-174`

## 阅读问题

- 哪些 config override 只在 `agent` 模式下有意义？
- 为什么 `daemon` 分支在入口层看起来很薄，但系统层却最厚？
