# 工具与策略：OpenClaw 怎样把执行能力包进受控协议

OpenClaw 的工具面不只是“有哪些 tool”。更关键的是它把宿主执行策略显式编码成 approval、binding 和 runtime surfaces。

## `exec-approvals.ts` 把执行策略做成结构化协议

`ExecHost`、`ExecSecurity`、`ExecAsk` 先把执行宿主、安全级别和询问策略枚举化；`SystemRunApprovalBinding`、`SystemRunApprovalPlan` 则进一步把命令 argv、cwd、agentId、sessionKey、环境哈希和可变文件操作数编进审批载荷。这里的核心设计不是弹一个确认框，而是把“为什么允许这次执行”记录成可复核对象（`openclaw/src/infra/exec-approvals.ts:10-120`）。

## plugin runtime 直接暴露工具面，但不是无边界暴露

`createPluginRuntime()` 把 `tools`、`channel`、`events`、`logging`、`state` 和 `modelAuth` 都暴露给插件，说明工具不是独立子系统，而是宿主能力的一部分（`openclaw/src/plugins/runtime/index.ts:138-189`）。

但同一实现里，`modelAuth` 会主动裁掉 profile steering，避免插件横向读取不该接触的认证配置；这说明 runtime surface 本身就承担策略收束职责（`openclaw/src/plugins/runtime/index.ts:171-188`）。

## 渠道侧也遵循工具化的中间协议

`ChannelGatewayContext.channelRuntime` 不是直接给外部渠道插件一个 “send text” 函数，而是给 reply、routing、session、media、commands、groups、pairing 这些高阶运行时能力。渠道插件要做的不是绕过系统，而是调用系统已经定义好的工具化能力面（`openclaw/src/channels/plugins/types.adapters.ts:234-305`）。

## 关键源码锚点

- approval 协议：`openclaw/src/infra/exec-approvals.ts:10-120`
- plugin tools/runtime 面：`openclaw/src/plugins/runtime/index.ts:138-189`
- 渠道运行时能力面：`openclaw/src/channels/plugins/types.adapters.ts:234-305`

## 阅读问题

- 为什么 `SystemRunApprovalPlan` 要记录 `mutableFileOperand`，而不是只记录命令文本？
- `tools` 面和 `modelAuth` 面为什么要在同一个 runtime 对象里暴露？
