# 安全优先 runtime：`SecurityPolicy`、sandbox、pairing、estop 怎样直接塑造行为边界

ZeroClaw 的安全层不是外围中间件，它从策略对象开始一直延伸到 channel 消息处理和 gateway 宿主。

## `SecurityPolicy` 是工具执行的总边界

`AutonomyLevel` 只定义三档：`ReadOnly`、`Supervised`、`Full`。真正重要的是 `SecurityPolicy`：它持有 `workspace_only`、`allowed_commands`、`command_context_rules`、`forbidden_paths`、`max_actions_per_hour`、`require_approval_for_medium_risk`、`block_high_risk_commands`、敏感文件读写开关和动作计数器。这不是配置映射，而是运行时行为边界对象（`zeroclaw/src/security/policy.rs:8-193`）。

## sandbox 选择是一条 runtime 工厂链

`create_sandbox()` 会根据 `SecurityConfig` 在 `Landlock`、`Firejail`、`Bubblewrap`、`Docker` 和 `Noop` 之间做显式选择；`detect_best_sandbox()` 再按平台优先级自动探测。ZeroClaw 把 OS 级隔离看成 runtime feature，而不是某个工具自己的附属选项（`zeroclaw/src/security/detect.rs:7-113`）。

## gateway pairing 是另一条宿主级安全面

`PairingGuard` 维护一次性 pairing code、已配对 bearer token 的哈希集、设备元数据和失败尝试状态；`new()` 会在需要 pairing 且还没有 token 时生成新 code，`try_pair_blocking()` 则在成功后消费 pairing code 并写入哈希 token。这里控制的是谁能进入 Gateway，而不是谁能调用单个 tool（`zeroclaw/src/security/pairing.rs:73-191`）。

## `estop` 说明安全状态是持久化的

`EstopManager` 会从状态文件加载 `EstopState`，读取/解析失败时直接进入 fail-closed；`engage()` 和 `resume()` 操作的是 `kill_all/network_kill/blocked_domains/frozen_tools` 这些持久状态，`resume()` 还可以强制要求 OTP。这不是一次性 panic 按钮，而是长期运行系统的安全闸门（`zeroclaw/src/security/estop.rs:10-245`）。

## channel 入口会在 provider 之前先挡一轮

`process_message()` 在进入执行主链前先跑 `PromptGuard` 和 statistical adversarial suffix filter；一旦命中，会直接记录 runtime trace 并向渠道回送阻断说明。安全策略因此不仅存在于工具执行层，也存在于外部消息 ingress 层（`zeroclaw/src/channels/mod.rs:3583-3659`）。

## 关键源码锚点

- autonomy 与安全策略：`zeroclaw/src/security/policy.rs:8-193`
- sandbox 工厂：`zeroclaw/src/security/detect.rs:7-113`
- pairing：`zeroclaw/src/security/pairing.rs:73-191`
- estop：`zeroclaw/src/security/estop.rs:10-245`
- channel ingress guard：`zeroclaw/src/channels/mod.rs:3583-3659`

## 阅读问题

- 为什么 pairing 和 tool policy 要拆成两条安全面？
- `estop` 的持久化语义和 daemon 长期运行之间是什么关系？
