# Repository Guidelines

## Project Structure & Module Organization
`D:\coding\agent` is a workspace of independent repositories, not a single buildable root project. Work inside the subproject you are changing: `codex/` (Rust + pnpm/Bazel), `openclaw/` (pnpm monorepo), `gemini-cli/` (npm workspaces), `opencode/` (Bun + Turbo), `zeroclaw/` (Rust workspace), and `claude-code/` (plugin/docs automation). Source, tests, and docs are local to each repo, for example `openclaw/src`, `openclaw/test`, `gemini-cli/packages`, `gemini-cli/integration-tests`, `codex/codex-rs`, and `zeroclaw/crates`.

## Build, Test, and Development Commands
There is no root `build` or `test` command. Run commands from the affected repo:

- `cd codex && just test` runs the preferred Rust test suite with `cargo nextest`.
- `cd codex && pnpm format` checks repo-wide formatting for docs and JS.
- `cd openclaw && pnpm check` runs format, lint, and type checks; `pnpm test:fast` is the quickest test pass.
- `cd gemini-cli && npm run build && npm run test` builds all workspaces and runs Vitest-based suites.
- `cd opencode && bun run dev` starts local development; `bun turbo typecheck` validates workspace types.
- `cd zeroclaw && cargo test` runs the Rust workspace tests.

## Coding Style & Naming Conventions
Use the formatter and linter already configured in each repo. In practice that means Prettier/ESLint/Vitest in the Node-based repos, `oxlint`/`oxfmt` in `openclaw`, Bun/Turbo conventions in `opencode`, and `cargo fmt`/`cargo clippy` in Rust repos such as `codex` and `zeroclaw`. Follow existing naming nearby: kebab-case for scripts and markdown docs, PascalCase for React or UI components, and snake_case only where Rust conventions require it.

## Testing Guidelines
Keep tests next to the project they cover and use the local runner. Examples: `openclaw/test`, `gemini-cli/integration-tests`, and `zeroclaw/tests`. Prefer the smallest relevant test target before broader suites, then rerun the repo’s main validation command before opening a PR.

## Commit & Pull Request Guidelines
Recent history uses Conventional Commit style: `fix(core): ...`, `test: ...`, `chore: ...`, `release: ...`. Keep commit subjects imperative and scoped to one repo. PRs should name the affected subproject, summarize behavior changes, include test evidence, link the issue when applicable, and attach screenshots or terminal captures for UI, TUI, or docs workflow changes.

## Workspace Tips
Do not add root-level tooling unless it serves multiple repos. Avoid editing vendored output such as `node_modules/`, `dist/`, or `target/` unless the change is intentionally generated and documented.
