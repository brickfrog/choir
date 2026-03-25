# Choir Roadmap

## Current State (2026-03-25)

Choir's local UDS workflow is usable and releaseable. The north-star loop (spawn -> edit -> commit -> PR -> review -> fix -> merge) works end-to-end with Claude, Gemini, and Moon Pilot as leaf agents. moontrace provides structured colored logging and OTLP span export.

## Near-Term: Zellij Integration Depth

### Watchdog: `zellij subscribe` replaces `dump-screen` polling

**Problem:** The current watchdog polls `dump-screen` every 30s and hashes the output to detect idle agents. This is slow (30s granularity), can be fooled by retry spam that changes screen content without meaningful progress (Moon Pilot 429 loop), and shells out to zellij on every tick.

**Solution:** `zellij subscribe` streams pane viewport updates as JSON. Choir can subscribe to each agent's pane and get notified immediately when output changes or stops. Filter out noise like retry lines by tracking meaningful content changes rather than raw screen hashes.

**Scope:** Replace `check_idle_agents` in `src/server/handler.mbt`. The subscribe process runs as a background task per agent, parsing JSON update events from zellij's stdout.

### Message Delivery: Bracketed paste is a workaround, not a fix

**Problem:** Review feedback and other messages are injected via `write-chars` with bracketed paste escape sequences. This works but it's still terminal injection — fragile, depends on the agent's CLI supporting paste mode, and there's no acknowledgment that the message was received.

**Current state:** Bracketed paste (`ESC[200~...ESC[201~`) was just added to fix Moon Pilot treating newlines as Enter. Claude Code and Gemini already handle paste. This is good enough for now.

**Future:** A zellij plugin or the pipe system could provide structured message delivery with acknowledgment. See "Zellij Plugin" below.

## Medium-Term: Operational Hardening

### `kill_agent` was just added — but reactive, not proactive

The TL can now kill stuck agents. But ideally agents that hit terminal states (rate limit death spirals, context exhaustion) would be detected and killed automatically. The `zellij subscribe` watchdog improvement would help here — pattern-match on known failure signatures in the pane output (e.g., repeated "429" lines, "context window exceeded").

### Spawn verification with `--block-until-exit-success`

`zellij run --block-until-exit-success` could replace the current fire-and-hope spawn flow for verification steps. Run `moon test` in the worktree, block until it exits, check the code. If it fails, the spawn can be retried or the TL notified before the agent starts working on broken code.

### Multi-leaf merge conflicts

When multiple leaves edit overlapping files and file PRs against main, merge conflicts happen. Currently the TL handles these manually. Choir could detect conflicts at `merge_pr` time (the `gh pr merge` will fail) and either rebase automatically or notify the TL with the conflict details.

## Longer-Term: Zellij Plugin

A small WASM plugin (Rust, compiled for wasmi — zellij's WASM runtime) that acts as choir's in-process agent monitor:

**Subscribes to:**
- `PaneUpdate` — pane state changes
- `PaneClosed` — immediate notification when an agent crashes or exits
- `PaneRenderReport` — real-time pane output for smart idle detection

**Receives messages via `zellij pipe`:**
- Choir server sends structured messages (review feedback, parent notifications) through the pipe system instead of `write-chars`
- The plugin delivers them to the target pane's stdin with proper framing
- Acknowledgment flows back via `cli_pipe_output`

**Reports back to choir:**
- Agent activity status (active / idle / stuck pattern detected)
- Pane close events with exit codes
- Could replace the entire watchdog + `dump-screen` + `list-panes` polling layer

**Build:** Rust → WASM (wasmi target). This is a separate build from choir's MoonBit native binary and the extism hooks WASM plugin. Three artifacts: `choir` (native), `hook.wasm` (extism/moonbit), `choir-monitor.wasm` (wasmi/rust).

**Why not now:** It's a nontrivial amount of work, requires Rust tooling for the plugin, and the current approach (shell out to zellij CLI) works. The plugin is the right architecture for v2 but not blocking for the current release.

## Transport & Remote

### TCP transport hardening

TCP transport is implemented but less proven than UDS. Needs live smoke coverage and testing under real concurrent multi-client use.

### Remote agents via zellij HTTPS

Zellij 0.44 added remote session attach over HTTPS. This could replace or complement the current TCP transport for remote agents — instead of choir running its own TCP server, remote agents could attach to the zellij session over HTTPS and communicate through the same pane-based delivery path as local agents.

## Not Planned

- **tmux support** — dropped, zellij-only (completed 2026-03-24)
- **Embedding extism in the choir binary via C FFI** — wrong architecture, extism CLI is the host runtime
- **Intelligence in the server** — choir is a tool executor, all decisions come from agents
