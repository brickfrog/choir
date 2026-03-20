# Choir

MoonBit reimplementation of [exomonad](https://github.com/tidepool-heavy-industries/exomonad) — type-safe agent orchestration without the Haskell WASM toolchain pain.

## What This Is

A persistent server that orchestrates heterogeneous coding agent teams. Agents (Claude, Gemini, future: Moon Pilot) run in isolated workspaces (git worktrees + tmux). The server manages spawning, messaging, PR workflow, and lifecycle — it makes no decisions, generates no code.

See `SPEC.md` for the full service specification.

## Architecture

Option B from the exomonad design: persistent server, pure MoonBit native binary.

```
choir serve                        # persistent server on UDS (.exo/server.sock)
  ├── Agent Registry               # in-memory
  ├── Message Router               # Teams inbox → tmux STDIN fallback
  ├── GitHub Poller                # background task
  └── Tool Dispatch                # role-gated MCP tool handlers

choir mcp-stdio                    # stateless JSON-RPC ↔ server bridge (one per agent)
```

Transport: UDS (default, local), TCP (opt-in, for future SSH/remote agents).

## Building

```bash
moon check            # typecheck
moon build            # compile
moon test             # run all tests
moon fmt              # format
```

## Project Layout

```
SPEC.md                # service specification (source of truth)
CLAUDE.md              # you are here
AGENTS.md              # instructions for Gemini/Moon Pilot leaf agents
src/
  server/              # persistent server, transport listeners
  mcp/                 # MCP JSON-RPC translation
  tools/               # tool handlers (fork_wave, spawn_gemini, etc.)
  registry/            # agent registry, mutex registry
  workspace/           # git worktree + tmux management
  message/             # message routing (Teams inbox, tmux STDIN)
  poller/              # GitHub PR/CI status polling
  config/              # TOML config parsing
moon.mod.json
moon.pkg.json
```

## Key Design Decisions

1. **Pure MoonBit native** — no WASM split, no Rust runtime, no protobuf boundary. Tool logic runs in-process. Compiles in <2s.
2. **Persistent server** — shared in-memory state (agent registry, mutex, poller state). Single log stream. Operationally simple for users.
3. **Transport-agnostic** — UDS for local, TCP for remote. Adding SSH agents is a config change, not an architecture change.
4. **Agent-type agnostic** — drives Claude, Gemini, Moon Pilot, or anything that speaks MCP or can be poked via tmux.
5. **No intelligence** — the server is a tool executor. All decisions come from the TL agent (Claude).

## North Star Workflow

This is the workflow Choir is supposed to make routine. Treat this as the product target, not the current maturity claim.

1. User runs `choir init` from a normal terminal or outer multiplexer session.
2. Choir brings up one persistent server and one TL client session.
3. User asks Claude/TL for a feature or fix.
4. TL decomposes the work and uses `fork_wave`, `spawn_gemini`, `spawn_moon_pilot`, or `spawn_worker`.
5. Each child runs in its own isolated worktree/branch/pane with a structured spawn contract, not just a raw prompt.
6. Each leaf implements, verifies, commits, and calls `file_pr`.
7. `file_pr` pushes the branch, resolves or creates the PR, and starts PR tracking automatically.
8. GitHub/Copilot reviews the PR.
9. The server poller detects review state changes and routes them back into the owning child session.
10. The child pushes fixes after `ChangesRequested`, and the parent is notified when fixes land.
11. When a PR is approved, the parent Claude/TL is notified and decides whether to merge.
12. TL calls `merge_pr`, the branch fold completes, and the tree collapses back toward `main`.
13. If the server restarts mid-flight, Choir reconstructs agent and PR tracking state and continues.

If Choir cannot do that loop cleanly, it is not done.

## Development Rules

- `moon fmt` before committing. No exceptions.
- `moon test` must pass. Do not skip, ignore, or weaken tests.
- Immutable by default. Explicit `mut` only where needed.
- Pattern matching over conditionals.
- Pipe operator (`|>`) for chaining.
- Error handling via `Result[T, E]` — no panics except for genuine invariant violations.
- Log before and after subprocess calls (`git`, `gh`, `tmux`). Log exit codes. Log stderr on failure.
- Do not call the system production-ready unless the full north-star loop above has been proven end to end against real tools.

## Current Reality

Choir has substantial pieces of the workflow, but it is not production-ready yet.

Working or mostly working:
- `choir init`, persistent server, MCP bridge, task/KV/mutex tools
- worktree/tmux spawning for Claude, Gemini, Moon Pilot, and inline workers
- canonical child identity and per-child config propagation
- `file_pr`, `track_pr`, `merge_pr`, GitHub poller, and restart recovery
- review event routing back into agent sessions

Still needs hard proof or more hardening:
- repeated end-to-end runs of the full child PR review loop with real GitHub/Copilot feedback
- stronger guarantees around child completion/reporting discipline
- continued hardening of multi-client bridge/server behavior under real concurrent use
- richer parity with ExoMonad session/routing semantics

## Implementation Phasing

### Phase 1: Foundation
Server + UDS, mcp-stdio translator, core tools, agent registry, workspace manager, config parsing, hooks, logging.

### Phase 2: Workflow Closure
Reliable PR lifecycle, review feedback routing, restart recovery, shutdown protection, and end-to-end proof of the north-star loop.

### Phase 3: Extensions
TCP transport, SSH remote agents, and the remaining ExoMonad parity work.

## References

- `SPEC.md` — full service specification
- `AGENTS.md` — instructions for leaf agents (Gemini, Moon Pilot)
- [exomonad](https://github.com/tidepool-heavy-industries/exomonad) — the Haskell+Rust original
- [MoonBit docs](https://docs.moonbitlang.com)
- [moonbitlang/async](https://github.com/moonbitlang/async) — native async I/O library
