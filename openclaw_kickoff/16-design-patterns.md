# OpenClaw 的设计模式：从源码里能读出的五个稳定范式

## 1. 控制面与执行核分离

Gateway 负责宿主状态、节点、渠道、cron、health、restart；embedded runner 负责 turn 执行。这种分层让长期运行复杂度不会污染单次 attempt 逻辑（`openclaw/src/gateway/server.impl.ts:627-760`; `openclaw/src/agents/pi-embedded-runner/run.ts:266-360`）。

## 2. 地址优先，而不是对象优先

`sessionKey/mainSessionKey/lastRoutePolicy` 把身份、回写和并发边界编码成稳定地址；后续 route、spawn、usage、session store 都围着它工作。这是一种典型的 address-first 设计（`openclaw/src/routing/resolve-route.ts:39-112`; `openclaw/src/routing/session-key.ts:118-174`; `openclaw/src/gateway/server-methods/usage.ts:62-93`）。

## 3. Lazy Runtime + Strict Loader

`plugins/loader.ts` 先用 Proxy 惰性暴露 runtime，再做 manifest registry、boundary check、module load 和 `register/activate`。扩展面很宽，但加载协议很严，这是平台型系统常见的“宽接口、窄入口”模式（`openclaw/src/plugins/loader.ts:69-84`; `openclaw/src/plugins/loader.ts:894-964`; `openclaw/src/plugins/loader.ts:1196-1385`）。

## 4. Retry 外提，attempt 内聚

`runEmbeddedPiAgent()` 持有 retry/context engine/auth retry，`runEmbeddedAttempt()` 持有 prompt/session/attempt 级执行。把重试和单次试跑拆开，可以让错误、usage 和 prompt 修复各归其位（`openclaw/src/agents/pi-embedded-runner/run.ts:879-980`; `openclaw/src/agents/pi-embedded-runner/run/attempt.ts:2415-2495`）。

## 5. 失败不毒化长期状态

`loadModelCatalog()` 在失败时主动清空缓存 promise，`update.run` 只在成功更新后重启 Gateway。这两个点分别处理“目录发现失败”和“进程更新失败”，但背后都是同一模式：临时失败不能污染长期宿主状态（`openclaw/src/agents/model-catalog.ts:166-173`; `openclaw/src/agents/model-catalog.ts:244-250`; `openclaw/src/gateway/server-methods/update.ts:95-110`）。

## 结论

OpenClaw 最值得学的不是某个单一算法，而是它怎样把控制面、地址模型、执行核和扩展协议拆开，同时又让这几层用同一套源码约束彼此对齐。
