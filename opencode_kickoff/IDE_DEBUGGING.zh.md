# opencode 工程 IDE 断点调试

这份文档面向仓库里的 `packages/opencode` 源码调试，而不是已发布的 CLI 二进制。

## 调试对象

- 根目录 `dev` 脚本实际执行的是 `packages/opencode` 的源码入口，见 `package.json`。
- 真正的 CLI 入口是 `packages/opencode/src/index.ts`。
- `packages/opencode/bin/opencode` 主要是发布时的二进制分发包装层。本地断点调试不要从这个文件进。

## 已提供的调试资产

- 根目录新增了两个启动脚本：
  - `bun run dev:debug`：使用 `6499` 端口，适合 VS Code 或 Cursor 配合 Bun 扩展附加。
  - `bun run dev:debug:jetbrains`：使用 `9229` 端口，适合 JetBrains 的 Node.js 调试附加。
- 本地 VS Code 配置：`.vscode/launch.json`
- JetBrains 项目运行配置：`.run/OpenCode_CLI_Debug.run.xml`

## 常用断点位置

- CLI 装配和参数解析：`packages/opencode/src/index.ts`
- `run` 子命令：`packages/opencode/src/cli/cmd/run.ts`
- `debug` 子命令入口：`packages/opencode/src/cli/cmd/debug/index.ts`
- MCP OAuth 调试：`packages/opencode/src/cli/cmd/mcp.ts`
- TUI 线程入口：`packages/opencode/src/cli/cmd/tui/thread.ts`

## VS Code / Cursor

### 前提

- 已在仓库根目录执行 `bun install`
- 已安装 Bun 扩展 `oven.bun-vscode`

### 用法

1. 在仓库根目录启动等待调试的进程：

```powershell
bun run dev:debug
```

2. 如果想直接调某个命令，也可以用原始命令：

```powershell
bun run --inspect-brk=6499 --cwd packages/opencode --conditions=browser src/index.ts --help
```

```powershell
bun run --inspect-brk=6499 --cwd packages/opencode --conditions=browser src/index.ts run "hello"
```

```powershell
bun run --inspect-brk=6499 --cwd packages/opencode --conditions=browser src/index.ts mcp debug my-server
```

3. 在 VS Code 或 Cursor 里按 `F5`，选择：
   - `opencode (attach 6499)`，对应 `bun run dev:debug`
   - `opencode (attach 9229)`，用于附加 JetBrains 风格的 9229 端口进程

### 说明

- `--inspect-brk` 会在第一行暂停，适合抓启动阶段的断点。
- Bun 启动后会打印类似 `ws://localhost:6499/<session>` 的 Inspector 地址，`launch.json` 里的基础 URL 会自动附加到当前会话。

## JetBrains

### 方案 A：直接使用项目里的共享运行配置

仓库根目录已新增 `.run/OpenCode_CLI_Debug.run.xml`。

使用方法：

1. 在 JetBrains 里打开项目根目录。
2. 在运行配置列表里选择 `OpenCode CLI Debug`。
3. 启动后，JetBrains 会运行根目录脚本 `dev:debug:jetbrains`，也就是：

```powershell
bun run --inspect-brk=9229 --cwd packages/opencode --conditions=browser src/index.ts
```

4. 在 `packages/opencode/src/index.ts` 或具体命令文件打断点后继续执行。

### 方案 B：手工配置

如果 JetBrains 没自动识别 `.run` 配置，手工创建一个 npm 或 Bun 运行配置即可：

- `package.json`: 项目根目录的 `package.json`
- Script: `dev:debug:jetbrains`
- Environment:
  - `RUST_BACKTRACE=1`

也可以先在终端里启动：

```powershell
bun run dev:debug:jetbrains
```

再用 `Run | Attach to Node.js/Chrome` 附加到 `localhost:9229`。

## 推荐的调试入口

### 只看 CLI 装配

```powershell
bun run --inspect-brk=6499 --cwd packages/opencode --conditions=browser src/index.ts --help
```

适合在 `packages/opencode/src/index.ts` 观察：

- `process.on(...)` 的异常处理
- `yargs(...)` 的命令注册
- `cli.parse()` 前后的执行流

### 调 `run` 子命令

```powershell
bun run --inspect-brk=6499 --cwd packages/opencode --conditions=browser src/index.ts run "hello"
```

### 调 MCP OAuth 问题

```powershell
bun run --inspect-brk=6499 --cwd packages/opencode --conditions=browser src/index.ts mcp debug my-server
```

### 调默认 TUI

```powershell
bun run --inspect-brk=6499 --cwd packages/opencode --conditions=browser src/index.ts
```

## 常见问题

### 断点是灰的

- 确认打开的是仓库根目录，不是 `dist` 或单独子目录。
- 确认断点打在 `packages/opencode/src/**/*.ts` 源码里。
- 启动参数要带 `--conditions=browser`，和仓库现有 `dev` 脚本保持一致。

### 已附加但没停住

- 优先用 `--inspect-brk`，不要只用 `--inspect`。
- 把断点下在 `packages/opencode/src/index.ts` 顶部，先确认 IDE 能截到入口。

### 想同时看日志

可以把参数补成：

```powershell
bun run --inspect-brk=6499 --cwd packages/opencode --conditions=browser src/index.ts --print-logs --log-level DEBUG
```

### Windows 下参数带空格

PowerShell 里建议把消息参数整体包在引号里，例如：

```powershell
bun run --inspect-brk=6499 --cwd packages/opencode --conditions=browser src/index.ts run "explain this repository"
```

## 结论

最省事的组合是：

- VS Code / Cursor：`bun run dev:debug` + `opencode (attach 6499)`
- JetBrains：`bun run dev:debug:jetbrains` + `Attach to Node.js/Chrome` 或直接使用 `OpenCode CLI Debug`
