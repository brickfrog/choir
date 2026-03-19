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

## Development Rules

- `moon fmt` before committing. No exceptions.
- `moon test` must pass. Do not skip, ignore, or weaken tests.
- Immutable by default. Explicit `mut` only where needed.
- Pattern matching over conditionals.
- Pipe operator (`|>`) for chaining.
- Error handling via `Result[T, E]` — no panics except for genuine invariant violations.
- Log before and after subprocess calls (`git`, `gh`, `tmux`). Log exit codes. Log stderr on failure.

## Implementation Phasing

### Phase 1: MVP (current)
Server + UDS, mcp-stdio translator, core tools (fork_wave, spawn_gemini, file_pr, notify_parent), agent registry, workspace manager, config parsing, hooks, logging.

### Phase 2: Production
GitHub poller, server restart recovery, OTel, shutdown with critical phase protection, task tools, mutex registry.

### Phase 3: Extensions
TCP transport, Moon Pilot agent type, SSH remote agents.

## References

- `SPEC.md` — full service specification
- `AGENTS.md` — instructions for leaf agents (Gemini, Moon Pilot)
- [exomonad](https://github.com/tidepool-heavy-industries/exomonad) — the Haskell+Rust original
- [MoonBit docs](https://docs.moonbitlang.com)
- [moonbitlang/async](https://github.com/moonbitlang/async) — native async I/O library
