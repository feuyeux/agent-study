# 模型、认证与 failover：OpenClaw 怎样把“选模型”做成运行时决策

OpenClaw 在这条线上有三个层次：catalog 负责发现可用模型，auth 负责决定凭据来源，fallback 负责在运行期跨 provider/model 试跑。

## `loadModelCatalog()` 先把“有哪些模型”做成可恢复的动态发现

`readConfiguredOptInProviderModels()` 允许配置显式补充 opt-in provider models；`mergeConfiguredOptInProviderModels()` 再把它们并入 catalog。也就是说，模型表不只来自内建发现，还接受配置显式扩容（`openclaw/src/agents/model-catalog.ts:61-132`）。

`loadModelCatalog()` 自身还会 `ensureOpenClawModelsJson()`、动态导入 PI SDK、读取 `ModelRegistry`、应用 built-in suppression，并通过 `augmentModelCatalogWithProviderPlugins()` 让 provider 插件继续补充目录。更关键的是它在失败时会清空 `modelCatalogPromise`，避免把一次瞬时加载失败毒化成永久坏缓存（`openclaw/src/agents/model-catalog.ts:145-259`）。

## `resolveApiKeyForProvider()` 决定凭据来源顺序

`resolveApiKeyForProvider()` 先看显式 `profileId`，再看 provider auth override，再按 profile order 尝试存储中的 profile，随后再退到环境变量、自定义 provider key、synthetic local auth，最后才报错。认证在这里不是单点字段，而是一条分层回退链（`openclaw/src/agents/model-auth.ts:282-394`）。

## fallback 不是异常处理，而是运行时主链

`createModelCandidateCollector()` 负责去重和 allowlist 过滤，`runFallbackCandidate()` 负责把 provider/model 单次运行包装成统一结果，而 `runWithModelFallback()` 才是主循环：它按候选列表尝试，结合 cooldown、profile 可用性和 probe 节流来决定跳过、探测还是执行下一个候选（`openclaw/src/agents/model-fallback.ts:66-97`; `openclaw/src/agents/model-fallback.ts:128-180`; `openclaw/src/agents/model-fallback.ts:511-580`）。

## Gateway 自己也有一层认证决议

`resolveGatewayAuth()` 会把 config、override、环境变量和 Tailscale 模式折叠成 `ResolvedGatewayAuth`，`assertGatewayAuthConfigured()` 再确保 token/password/trusted-proxy 配置完整。也就是说，OpenClaw 把“模型认证”和“控制面认证”拆成了两套不同但并行的解析链（`openclaw/src/gateway/auth.ts:208-320`）。

## 关键源码锚点

- catalog 补充与缓存：`openclaw/src/agents/model-catalog.ts:61-132`; `openclaw/src/agents/model-catalog.ts:145-259`
- provider auth 解析：`openclaw/src/agents/model-auth.ts:282-394`
- failover 主链：`openclaw/src/agents/model-fallback.ts:66-97`; `openclaw/src/agents/model-fallback.ts:128-180`; `openclaw/src/agents/model-fallback.ts:511-580`
- Gateway auth：`openclaw/src/gateway/auth.ts:208-320`

## 阅读问题

- 为什么 model catalog 要允许 provider plugin 增补，而不是只读 `models.json`？
- Gateway auth 和 provider auth 为什么不能共用同一套解析器？
