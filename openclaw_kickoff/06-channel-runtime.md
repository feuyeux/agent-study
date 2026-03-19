# 渠道运行时：渠道为什么能接进同一套控制面

OpenClaw 的渠道层不是若干独立 adapter。它能统一起来，是因为“渠道元数据”“渠道草稿流”“渠道插件上下文”和“Gateway 宿主状态”被做成了四个相互咬合的层。

## `channels/registry.ts` 先把渠道做成正式目录

`CHAT_CHANNEL_META` 把 Telegram、WhatsApp、Discord、IRC、Google Chat、Slack、Signal、iMessage、LINE 等渠道声明成结构化元数据；`CHAT_CHANNEL_ALIASES` 则把别名标准化回正式 channel id。这说明渠道在 OpenClaw 里先是产品注册表，再是运行时实现（`openclaw/src/channels/registry.ts:26-130`）。

## Gateway 宿主里有专门的 `channelManager`

`server.impl.ts` 启动时立刻创建 `channelManager`，然后从它取出 `getRuntimeSnapshot()`、`startChannels()`、`startChannel()`、`stopChannel()`、`markChannelLoggedOut()`。渠道生命周期因此被放进 Gateway runtime state，而不是散落在命令入口或单个 plugin 内（`openclaw/src/gateway/server.impl.ts:627-713`）。

## 草稿流本身就是渠道运行时协议

`createFinalizableDraftStreamControls()` 和 `createFinalizableDraftLifecycle()` 把增量更新、停止、最终 flush、删除草稿消息这些行为做成标准控制对象。OpenClaw 不是简单地把 token stream 发给渠道，而是显式处理“流式草稿消息”这个中间态（`openclaw/src/channels/draft-stream-controls.ts:31-120`）。

## 外部渠道插件拿到的是 Gateway 级上下文

`ChannelGatewayContext` 不只给 `cfg`、`account` 和 `runtime`，还给 `getStatus()/setStatus()` 和可选的 `channelRuntime`。`channelRuntime` 又进一步暴露 reply、routing、text、session、media、commands、groups、pairing 等高级能力，所以外部渠道插件不是自己重造消息管线，而是挂在既有控制面上（`openclaw/src/channels/plugins/types.adapters.ts:234-305`）。

## 渠道运行时和 agent 运行时是互相咬合的

`channelRuntime` 实际来自 `createPluginRuntime().channel`，而 `createPluginRuntime()` 本身又暴露 agent、tools、events、modelAuth 等宿主能力。这意味着渠道插件向下可以进入路由、回复和会话管理，向上又共享整台 OpenClaw runtime（`openclaw/src/plugins/runtime/index.ts:138-189`）。

## 关键源码锚点

- 渠道注册表：`openclaw/src/channels/registry.ts:26-130`
- 渠道宿主装配：`openclaw/src/gateway/server.impl.ts:627-713`
- 草稿流控制：`openclaw/src/channels/draft-stream-controls.ts:31-120`
- 外部渠道上下文：`openclaw/src/channels/plugins/types.adapters.ts:234-305`
- 共享 runtime 面：`openclaw/src/plugins/runtime/index.ts:138-189`

## 阅读问题

- 为什么草稿流要单独抽成 `draft-stream-controls.ts`，而不是塞进某个具体渠道实现？
- `ChannelGatewayContext.channelRuntime` 为什么是可选字段而不是必选字段？
