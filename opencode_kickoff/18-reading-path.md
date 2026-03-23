# 建议的源码阅读路径：先追主线代码流，再回头补侧面展开

> **总纲** [00-opencode_ko](./00-opencode_ko.md) · **分层定位** 元阅读文档  
> **前置阅读** [17-why-this-design-matters](./17-why-this-design-matters.md)  
> **后续阅读** [19-final-mental-model](./19-final-mental-model.md)

现在这套 kickoff 最容易让人迷路的点，是把“主线代码流”和“侧面概念文档”混在了一起。  
更稳的读法是：

1. 先追 **主线代码流**，一路从入口读到 `prompt() -> loop() -> processor()`
2. 再回头补 **侧面展开**，理解 durable state、对象模型、上下文工程和横切能力

```mermaid
flowchart LR
    P1["第一站<br/>入口与 Server"] --> P2["第二站<br/>prompt / loop / processor 主线"]
    P2 --> P3["第三站<br/>durable state / 对象模型 / 上下文工程"]
    P3 --> P4["第四站<br/>横切能力与恢复"]
    P4 --> P5["第五站<br/>设计价值与最终心智模型"]
```

## 第一站：先把入口与 Server 立住

先读：

1. [01-user-entry](./01-user-entry.md)
2. [02-server-and-routing](./02-server-and-routing.md)

这一站只解决两个问题：

1. 六种入口怎样到达 Server（内嵌 fetch / RPC worker / HTTP / sidecar）。
2. Server 内部怎样通过 Hono 中间件和路由把请求绑定到实例上下文，最终到达 SessionRoutes。

如果这一步没读清楚，后面很容易把 CLI 或 TUI 误认成宿主本体。

## 第二站：直接打通主线代码流

接着读：

1. [03-request-lifecycle](./03-request-lifecycle.md)
2. [10-loop-and-processor](./10-loop-and-processor.md)
3. [11-loop-source-walkthrough](./11-loop-source-walkthrough.md)
4. [12-processor-source-walkthrough](./12-processor-source-walkthrough.md)

读完这一站，你应该能自己画出 `prompt -> loop -> process` 的时钟，并说明上下文工程发生在哪些节点。

## 第三站：回头补侧面展开

这一站不再继续“推进主线”，而是解释主线背后依赖的状态与装配结构。

然后读：

1. [04-session-centric-runtime](./04-session-centric-runtime.md)
2. [05-object-model](./05-object-model.md)
3. [06-context-engineering](./06-context-engineering.md)
4. [07-context-system-and-instructions](./07-context-system-and-instructions.md)
5. [08-context-input-and-history-rewrite](./08-context-input-and-history-rewrite.md)
6. [09-context-injection-order](./09-context-injection-order.md)
7. [20-storage-and-persistence](./20-storage-and-persistence.md)

这一站的关键收获应该是：

1. session 承载执行边界。
2. part 是最小状态单元。
3. loop 普通轮次装配 system/messages/tools 时，上下文到底怎样被塑造。
4. resume、fork、share、summary、revert 都建立在 durable history 之上。

## 第四站：最后吸收横切能力与恢复语义

最后读：

1. [13-advanced-primitives](./13-advanced-primitives.md)
2. [14-hardcoded-vs-configurable](./14-hardcoded-vs-configurable.md)
3. [16-observability](./16-observability.md)
4. [21-error-recovery](./21-error-recovery.md)

这一站的目标是形成一个整体判断：OpenCode 的高级能力统一接在固定节点上，共享同一条 durable history。

## 第五站：最后再回看“为什么值得学”

最后收束：

1. [17-why-this-design-matters](./17-why-this-design-matters.md)
2. [19-final-mental-model](./19-final-mental-model.md)

到这一步，你再回头看源码，会更容易把每段实现放回四层中的具体位置。
