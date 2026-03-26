# OpenCode 断点调试指南

> 本文是面向 `packages/opencode` 的源码调试。当前仓库里真正的 CLI 入口是 `packages/opencode/src/index.ts`；根目录 `package.json` 里的 `dev` 脚本，本质上也是从这里启动。

## 调试前准备

1. 用 IDE 打开 `opencode` 仓库根目录。
2. 在仓库根目录执行一次：

    ```powershell
    bun install
    ```

3. VS Code 需要安装 Bun 扩展 `oven.bun-vscode`。
4. 第一次调试时，先把断点打在 `packages/opencode/src/index.ts` 顶部。

常用断点位置：

- `packages/opencode/src/index.ts`：CLI 入口、参数解析、命令注册
- `packages/opencode/src/cli/cmd/run.ts`：`run` 子命令
- `packages/opencode/src/cli/cmd/mcp.ts`：MCP 与 OAuth 相关流程
- `packages/opencode/src/cli/cmd/debug/index.ts`：`debug` 子命令入口

如果你是第一次连断点，最稳妥的顺序仍然是先确认 `index.ts` 能停住，再往具体命令文件里追。另一个容易踩坑的点是：不要从 `packages/opencode/bin/opencode` 开始调，那一层主要是发布分发时的包装入口。

## VS Code

### 第一步：配置 `launch.json`

当前工作区，复制`.vscode/launch.example.json`为 `.vscode/launch.json` ：

```json
{
  "version": "0.2.0",
  "configurations": [
    {
      "type": "bun",
      "request": "attach",
      "name": "opencode (attach 6499)",
      "url": "ws://localhost:6499/opencode"
    }
  ]
}
```

### 第二步：先下断点

第一次建议就下在：

- `packages/opencode/src/index.ts`

这样最容易判断附加到底有没有成功。

### 第三步：在终端启动等待调试的进程

在仓库根目录执行：

```powershell
bun run --inspect-brk=6499/opencode --cwd packages/opencode --conditions=browser src/index.ts
```

如果终端里看到 Inspector 横幅，并且地址是 `ws://localhost:6499/opencode`，就说明端口已经起来了，而且监听路径和 VS Code 的附加配置是对上的。

这里没有继续用 `bun run dev:debug` 的原因也很简单：当前仓库根目录并没有这个脚本，最稳的方式就是直接把 Bun 调试参数写全。

### 第四步：让 IDE 附加到 6499

在 VS Code 或 Cursor 里：

1. 按 `F5`
2. 选择 `opencode (attach 6499)`

附加成功后，IDE 会连到刚才那个已经暂停住的 Bun 进程。因为启动命令显式用了 `--inspect-brk`，所以它会先停在入口附近，适合抓启动阶段的问题。

### 第五步：继续执行并观察断点

附加成功后：

1. 如果当前先停在入口，按一次继续执行
2. 程序走到你的断点时就会停住
3. 这时重点看这几类信息：
   - 调用栈
   - 局部变量
   - `yargs(...)` 注册了哪些命令
   - `cli.parse()` 前后的执行流

### 只想调某个具体命令怎么办

IDE 配置不用改，只改终端里的启动参数即可。

例如调 `run` 子命令：

```powershell
bun run --inspect-brk=6499/opencode --cwd packages/opencode --conditions=browser src/index.ts run "hello"
```

例如调 MCP：

```powershell
bun run --inspect-brk=6499/opencode --cwd packages/opencode --conditions=browser src/index.ts mcp debug my-server
```

然后仍然在 IDE 里附加：

- `opencode (attach 6499)`

所以 VS Code 这一套里，真正需要记住的其实只有一句话：

- 进程跑在 `6499/opencode`，IDE 就附加 `opencode (attach 6499)`

## JetBrains

### 第一步：确认 JetBrains 已启用 Bun 支持

先检查这两处：

1. `Settings | Plugins` 里启用了 `Bun` 插件
2. `Settings | Languages & Frameworks | JavaScript Runtime` 里把运行时设成 `Bun`

### 第二步：创建 `Bun` 运行配置

在 JetBrains 里执行：

1. `Run | Edit Configurations`
2. 点 `+`
3. 选择 `Bun`

然后把入口文件指到：

- `packages/opencode/src/index.ts`

再把 `Bun parameters` 补上：

```text
--cwd packages/opencode --conditions=browser
```

### 第三步：直接点 Debug

无需手工先跑：

```powershell
bun run --inspect-brk=9229 --cwd packages/opencode --conditions=browser src/index.ts
```

## 最后

### 想一边断点一边看日志

VS Code / Cursor 可以直接在启动命令后面补日志参数：

```powershell
bun run --inspect-brk=6499/opencode --cwd packages/opencode --conditions=browser src/index.ts --print-logs --log-level DEBUG
```

JetBrains 如果要看同样的日志，把下面这段放到 `Arguments` / `Program arguments` 里即可：

```text
--print-logs --log-level DEBUG
```

### 总结

- VS Code：先跑 `bun run --inspect-brk=6499/opencode --cwd packages/opencode --conditions=browser src/index.ts`，再附加 `opencode (attach 6499)`
- JetBrains：直接建一个 `Bun` 运行配置，入口指向 `packages/opencode/src/index.ts`，`Bun parameters` 填 `--cwd packages/opencode --conditions=browser`，然后点 `Debug`
