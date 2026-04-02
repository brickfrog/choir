# Choir Roadmap

## Current State (2026-04-02)

Choir's local UDS workflow is stable. The north-star loop (spawn -> edit -> commit -> PR -> review -> fix -> merge) works end-to-end with Claude, Gemini, Codex, Cursor Agent, Moon Pilot, and **Pi** as leaf agents. moontrace provides structured colored logging and OTLP span export. brickfrog/tempo handles datetime parsing.

**Choir × Pi (product/runtime)** — The integration described in `PI_NORTH_STAR.md` is **substantially achieved and live-validated**: `choir tool` is the non-MCP control plane; `choir init --tl pi`, Pi TL/dev/worker paths, and restart recovery (including offline PR-owning leaves) are validated. Further work is mostly persistence policy, delivery tradeoffs, and **architecture** (below), not first-pass viability.

**Effect architecture (exomonad-style hard boundary)** — **In progress.** Orchestration is still fused with I/O in parts of `dispatch`, server `handler`, recovery, and lifecycle persistence—but several areas now follow a clearer pure-data direction (`fork_wave` via `Eff`, canonical TL workflow classification and re-check copy in `src/poller/tl_decision.mbt`, and related poller plumbing). The densest remaining hotspots are often **server post-tool orchestration**, **poller↔registry integration and TL-facing notifications**, **lifecycle/service convergence**, and **recovery seams**, not only raw dispatch line count. The audit and phased plan live in `PI_NORTH_STAR.md` (Architecture boundary audit). This is ongoing refactor work, not a future wishlist.

**Shell/process edges** — Broad ambient-shell orchestration debt is largely **closed**; remaining production shell uses are **intentional and localized** (TL init tab trailer, plugin capture fallback, remote SSH semantics, smoke scripts). See `PI_NORTH_STAR.md` (Remaining intentional production shell boundaries).

Recent workflow hardening (post-#174, landed as **#175–#178**):
- **Actionable CI / re-check TL summaries** — poller-driven parent notifications include an honest gate paragraph (approved, CI, threads, Copilot issue comment state) so the TL can re-check before `merge_pr`.
- **Canonical TL decision planner** — `tl_decision.mbt` centralizes workflow categories and stable sentences for `TLDecision:` lines (no duplicated ad hoc copy in tools).
- **Copilot issue-comment signal** — Choir tracks whether a Copilot **issue** comment was observed (REST), separate from review rollups alone.
- **Copilot-silent timeout escalation** — if review wait times out and Choir’s snapshot still shows no PR review, the TL is warned about comment-trigger flakiness and manual follow-up (for example Request review).

Recent additions (still accurate):
- **Disconnect recovery** — agents that bypass `file_pr` get retroactively recovered via GitHub PR detection instead of being falsely failed
- **WASM hook system** — extism/moonbit-pdk plugins for PII rewriting and tool guards (BeforeModel/AfterModel/PreToolUse)
- **Typed lifecycle state machine** — labeled enum fields, AgentId newtype, LocalTarget type, ChildTracker
- **Idle watchdog** — dump-screen hash comparison with overflow-safe hashing and empty snapshot guards
- **Claude Code statusline** — `choir statusline` subcommand shows weekly rate limit bar + agent state counts
- **Task decomposition protocol** — TL MCP instructions include 4-step reasoning before spawning

## Near-Term: Operational Hardening

### Disconnect / reconnect resilience

The disconnect recovery fix catches agents that bypassed `file_pr`, but the broader problem remains: transient MCP disconnects (shell command connections closing) trigger `schedule_disconnect` which can cascade into false failures. The 60-second grace period helps but isn't sufficient for all cases.

**Next steps:** Consider a heartbeat or liveness check before declaring an agent failed — query the zellij pane for activity before firing the fail path.

### Multi-leaf merge conflicts

When multiple leaves edit overlapping files and file PRs against main, merge conflicts happen. Currently the TL handles these manually. Choir could detect conflicts at `merge_pr` time and either rebase automatically or notify the TL with conflict details.

### Message delivery beyond bracketed paste

Review feedback and messages are injected via `write-chars` with bracketed paste escape sequences. This works but it's terminal injection — fragile, depends on the agent's CLI supporting paste mode, no acknowledgment. A zellij plugin or pipe system could provide structured delivery.

## Medium-Term: WASM Targets

MoonBit compiles to both native and WASM. Choir currently only targets native for the main binary and WASM for the extism hook plugin. There's untapped potential here.

### Portable leaf tooling

`file_pr`, `notify_parent`, `shutdown` as a single WASM binary that any agent runtime can call without needing the full native choir binary on PATH. Ship one `.wasm`, run it anywhere with wasmtime/wasmer. Removes the hard dependency on having choir's native binary installed for leaf agents.

### In-repo web dashboard

**Not pursued.** There is no Choir webapp in the repo; status and orchestration remain CLI, `choir tool`, MCP, and on-disk state under `.choir/`. A hypothetical WASM-hosted UI remains speculative and is not on the active roadmap.

### Plugin system without extism

Instead of shelling out to `extism call`, load WASM plugins directly using the WASM component model. Cut the extism CLI dependency (which has version-specific issues — v1.6.3 segfaults).

### Cross-platform statusline

The statusline subcommand uses C FFI (`read_stdin`, `system`, etc.) which locks it to native. A WASM build with WASI would work on any platform without recompilation.

## Longer-Term: Zellij Plugin

A WASM plugin (Rust, compiled for wasmi — zellij's runtime) that acts as choir's in-process agent monitor:

- **Subscribes to:** `PaneUpdate`, `PaneClosed`, `PaneRenderReport` for real-time pane monitoring
- **Receives messages via `zellij pipe`:** structured delivery with acknowledgment, replacing `write-chars`
- **Reports back:** agent activity status, pane close events with exit codes
- Could replace the entire watchdog + `dump-screen` + `list-panes` polling layer

**Why not now:** Requires Rust tooling for the plugin, and the current approach works. Right architecture for v2.

## Transport & Remote

### TCP transport hardening

TCP transport is implemented but less proven than UDS. Needs live smoke coverage under real concurrent multi-client use.

### Remote agents via zellij HTTPS

Zellij 0.44 added remote session attach over HTTPS. Could replace or complement TCP transport — remote agents attach to the zellij session over HTTPS and communicate through the same pane-based delivery path as local agents.

## Not Planned

- **tmux support** — dropped, zellij-only (completed 2026-03-24)
- **Embedding extism in choir binary via C FFI** — extism CLI is the host runtime
- **Intelligence in the server** — choir is a tool executor, all decisions come from agents
