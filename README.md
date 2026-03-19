# Agent Architecture Study

Kickoff notes and architecture comparison for six agent runtimes.

## Repositories

- `claude-code` - Plugin ecosystem (extension layer only, not full host runtime)
- `codex` - Security-first coding agent runtime
- `gemini-cli` - Layered terminal agent
- `openclaw` - Multi-channel gateway with embedded agent runtime
- `opencode` - Session-first local coding agent
- `zeroclaw` - Rust monolith agent platform

## Comparison Table

| Project | Agent Positioning | Main Runtime Loop | Tool / Permission Model | Extension Model | Architecture Keywords |
|---|---|---|---|---|---|
| Claude Code | Plugin ecosystem around a host runtime, not the full host core | The host interprets commands, agents, hooks, and skills; this repo mainly provides declarative components | Hooks can intercept and enforce local rules, e.g. `plugins/hookify/core/rule_engine.py` | Plugin directories package commands, agents, hooks, and skills | Host-driven runtime + Markdown/JSON-defined extensions |
| Codex | Security-first coding agent runtime | CLI entrypoints converge into a session-centric Rust core, e.g. `codex-rs/cli/src/main.rs` and `codex-rs/core/src/codex.rs` | Tools run through approval, sandbox selection, execution, and escalation retry, e.g. `codex-rs/core/src/tools/orchestrator.rs` | Plugins, skills, and MCP are integrated into the same runtime | Session-centric, strongly typed, sandboxed, enterprise-style orchestration |
| Gemini CLI | Layered terminal agent | CLI bootstraps settings/auth/UI and hands off to a reusable core runtime, e.g. `packages/cli/src/gemini.tsx` | Tool calls are managed by a scheduler state machine and a policy engine, e.g. `packages/core/src/core/coreToolScheduler.ts` and `packages/core/src/policy/policy-engine.ts` | Extensions can hot-load MCP, rules, skills, hooks, and agents | Core loop + policy engine + hot-reloadable extensions |
| OpenClaw | Multi-channel gateway with embedded agent runtime | Thin entrypoint; the real loop lives in the embedded PI runner, e.g. `src/agents/pi-embedded-runner/run.ts` | Tool policy is shaped by owner checks, allowlists, plugin grouping, and subagent rules, e.g. `src/agents/tool-policy.ts` | Large plugin SDK exposes channel, gateway, runtime, and subagent capabilities | Platform-style agent OS, gateway-centric, subagent-aware |
| OpenCode | Local coding agent with session-first design | Session storage and the session processor drive the turn loop, e.g. `packages/opencode/src/session/index.ts` and `packages/opencode/src/session/processor.ts` | Tool registry merges built-in, local, and plugin tools; agent permission rules are part of agent definitions | Plugins can modify prompts, params, headers, and install additional tooling | Session database, evented turn processing, plugin-programmable |
| ZeroClaw | Rust monolith agent platform | A large integrated loop coordinates provider calls, tools, memory, history, security, and cost, e.g. `src/agent/loop_.rs` | Huge tool surface registered inside one subsystem, with both XML and native tool dispatch | Separate plugin system modeled after OpenClaw | Strong monolith, all-in-one integration, large tool surface, multi-agent budgeting |

## Key Conclusions

- `Codex` and `Gemini CLI` are the closest to classic coding-agent runtimes.
- `Codex` is more session-core and safety-centric; `Gemini CLI` is more policy-engine and extension-centric.
- `OpenCode` is the most session-first design: turns, reasoning, tool calls, and outputs are structured around persistent session state.
- `OpenClaw` and `ZeroClaw` are closer to platform-style agent systems than single-purpose terminal coding agents.
- `OpenClaw` emphasizes gateway, channel, and plugin-sdk design.
- `ZeroClaw` emphasizes a Rust monolith with a very broad built-in capability surface.
- `Claude Code` in this workspace only shows the extension layer, so it should not be treated as the complete host implementation.

## Suggested Next Expansion

If this document is extended later, the most useful next section would be a per-project execution chain:

`user input -> model call -> tool scheduling -> permission check -> state persistence -> extension callbacks`
