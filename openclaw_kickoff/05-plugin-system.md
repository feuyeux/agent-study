# 插件系统：`createPluginRuntime()` 和 `plugins/loader.ts` 怎样把扩展面做成正式运行时

OpenClaw 的插件系统不是“加载几段外部脚本”。它的关键设计是先定义稳定 runtime 面，再让 loader 围绕这个 runtime 做 discovery、治理和激活。

## `createPluginRuntime()` 暴露的是宿主能力总面

`createPluginRuntime()` 一次性导出 `config`、`agent`、`subagent`、`system`、`media`、`tts`、`mediaUnderstanding`、`imageGeneration`、`webSearch`、`stt`、`tools`、`channel`、`events`、`logging`、`state`、`modelAuth`。这意味着插件拿到的不是 prompt callback，而是一整台 OpenClaw 宿主的受控投影（`openclaw/src/plugins/runtime/index.ts:138-189`）。

其中 `modelAuth.getApiKeyForModel()` 和 `modelAuth.resolveApiKeyForProvider()` 还主动剥掉了 profile steering 等能力，只允许插件基于 provider/model 发起查询，真正的凭据选择仍由核心 auth pipeline 决定。这是一个很明显的边界收束（`openclaw/src/plugins/runtime/index.ts:171-188`）。

## loader 先定义可反射的 runtime 面，再做惰性装配

`LAZY_RUNTIME_REFLECTION_KEYS` 明确列出了插件能反射到的 runtime 键；`plugins/loader.ts` 再通过 `resolveCreatePluginRuntime()`、`resolveRuntime()` 和 `Proxy` 把 runtime 做成惰性对象。这样即使 discovery 先跑，依赖树也不会被过早全部拉起（`openclaw/src/plugins/loader.ts:69-84`; `openclaw/src/plugins/loader.ts:894-964`）。

## 真正的 loader 主链是治理，而不是 import

`createPluginRegistry()` 之后，loader 依次执行 `discoverOpenClawPlugins()`、`loadPluginManifestRegistry()`、duplicate ordering、allowlist warning、provenance index 构造和 memory slot 决策。也就是说，插件主链的前半段基本都在做治理和选择，而不是运行用户代码（`openclaw/src/plugins/loader.ts:966-1050`; `openclaw/src/plugins/loader.ts:1196-1209`）。

## 边界检查和模块加载是硬约束

loader 在真正导入模块前会用 `openBoundaryFileSync()` 检查 entry 是否逃逸 plugin root，再用 `getJiti()` 加载模块。这里的约束不是约定式的；一旦 entry path 越界或 setup 导出的 plugin id 和 manifest 不一致，插件会被直接拒绝（`openclaw/src/plugins/loader.ts:1217-1265`）。

## `register/activate` 是扩展协议，不是自由代码执行

loader 后段要求模块满足运行时约定，缺 `register/activate` 或 setup 语义不对都会触发错误。它甚至会对 async `register()` 发出告警，说明插件注册阶段被有意设计成“同步声明能力”，而不是任意副作用脚本（`openclaw/src/plugins/loader.ts:1350-1385`）。

## 关键源码锚点

- runtime 面：`openclaw/src/plugins/runtime/index.ts:138-189`
- lazy reflection keys：`openclaw/src/plugins/loader.ts:69-84`
- lazy runtime proxy：`openclaw/src/plugins/loader.ts:894-964`
- discovery 与 registry：`openclaw/src/plugins/loader.ts:966-1187`
- boundary check 与 module load：`openclaw/src/plugins/loader.ts:1196-1329`
- `register/activate` 协议：`openclaw/src/plugins/loader.ts:1350-1385`

## 阅读问题

- 为什么 loader 要先做 lazy runtime，而不是一开始就实例化完整 runtime？
- `modelAuth` 为什么要暴露查询能力，却故意不让插件控制 profile 选择？
