# Choir

Choir is a MoonBit native orchestration server for coding-agent teams.

## Working Model

- The server owns lifecycle, PR tracking, review routing, and workspace isolation.
- Agents make implementation decisions, but they do not invent new orchestration flows.
- Prefer Choir tools over ad hoc shell work when a Choir tool exists.
- Treat `.choir/` as Choir-owned runtime and guidance state.
- The Choir × Pi product/runtime path is substantially validated; non-MCP control is `choir tool` plus Pi extension/runtime under `.choir/pi/`. The exomonad-style **hard effect boundary** (pure orchestration vs host I/O) is **still in progress**—see `PI_NORTH_STAR.md` if you touch dispatch, server handlers, or recovery.

## Repository Rules

- `moon fmt` before commit.
- Use `./scripts/verify-fast.sh` for normal iteration.
- Use `./scripts/verify-strict.sh` when full confidence is required.
- Do not weaken tests to make a change pass.
- Keep MoonBit code idiomatic: pattern matching, immutable-by-default, `Result[T, E]`.

## Runtime Rules

- Do not push to `main`.
- Do not merge your own PR unless the parent explicitly directs it.
- Do not create extra branches outside the branch/worktree Choir assigned.
- If Choir provides a helper command on PATH, prefer it over reimplementing the flow.
