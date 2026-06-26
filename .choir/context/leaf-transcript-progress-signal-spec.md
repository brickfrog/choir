# Spec: leaf-transcript-progress-signal

## Context
The TL and the idle-watchdog are blind to a leaf's per-turn work. choir's own signals only move on choir-MCP tool calls (events), lifecycle transitions (`last_updated`), or terminal-screen changes (`screen-hash`); none of them advance while a leaf is reading, planning, or thinking across many turns, and the worktree stays empty until the first write. Result: a busy-but-quiet leaf reads as "stalled," and the watchdog (or the TL) reaps it prematurely — this session killed an actively-working leaf ~37s after its last visible signal, and repeatedly mis-waited. The agent's transcript jsonl, by contrast, gains a record on most model turns, so its growth is a strong best-effort per-turn activity signal (it does NOT advance during a single long-running tool call — see Non-Goals). This adds transcript-growth as a best-effort, provider-keyed signal that (a) suppresses the watchdog idle-reap for a leaf that is demonstrably still working, and (b) is surfaced to the TL so wait/kill calls stop being blind. (Bead choir-6a64; the heartbeat-hook alternative is choir-zxmc, deferred — user chose transcript-scrape.)

## Clarifications
> User chose the transcript-scrape approach over the heartbeat-hook (zxmc) via the design fork. Remaining forks are TL-decided defaults with rationale; redirect any.

**Q (which agent types): does this work for all leaves?**
A: Claude only in v1, keyed on `AgentType::Claude`. Only claude's transcript layout (`~/.claude/projects/<mangled-workspace>/<uuid>.jsonl`) is mapped here; codex/gemini/etc. store transcripts elsewhere (or not at all). For any non-Claude agent type the signal is simply absent → status quo for those leaves. The locator is provider-keyed so other types can be added later without touching the watchdog logic.

**Q (path derivation): how is a leaf's transcript located from server state?**
A: From `agent.workspace` (the worktree absolute path, already available in `check_idle_agents`). Mangle = replace every `/` and `.` in the absolute workspace path with `-` (verified: `/mnt/data/Code/choir/.choir/worktrees/X` → `-mnt-data-Code-choir--choir-worktrees-X`). The transcript dir is `<claude-home>/projects/<mangled>`. Within it, the leaf's transcript is the newest `*.jsonl` (claude generates a per-session uuid choir does not know; newest-mtime jsonl is the session). `<claude-home>` defaults to `~/.claude` but must honor `CLAUDE_CONFIG_DIR`/`$HOME` resolution rather than a hardcoded `/home/...`.

**Q (what counts as "progress"): mtime, size, or line-count?**
A: File mtime of the newest transcript jsonl, compared to a recency window. Growth = mtime within the window. Mtime is the cheapest signal (one stat, no read), needs no parsing, and a new turn always rewrites the file. Reading/counting lines is unnecessary and would violate the read-only-cheap intent. (If mtime proves too coarse, size-delta is the follow-up — not v1.)

**Q (how does it interact with the existing reap + nwaf pid-liveness?):** [REVISED per spec-audit HIGH #1]
A: It is a SUPPRESSOR of the IDLE-THRESHOLD reap ONLY, never of nwaf's dead-process reap. Precedence in `check_idle_agents` — `process_dead` is evaluated and reaped FIRST, before the suppressor: (1) nwaf's `process_dead` (owned-process pid-liveness, choir-managed worktree) → reap immediately; (2) else if transcript progressed within the window → treat as NOT idle, suppress the idle reap (continue) — even if screen-hash is stale; (3) else the existing `idle_sec >= threshold` reap; (4) else continue. RATIONALE for ordering dead-first: a dead process can have touched its transcript shortly before exiting (e.g. mtime 80s ago, window 90s), so a naive `if progressing { continue }` placed before the dead-process check would DELAY the nwaf fast-reap until the window expired — directly contradicting nwaf. The suppressor only proves "the transcript was written recently," which is necessary-not-sufficient for liveness; the owned-process check is authoritative for death. It does NOT override the progress-backstop or lifecycle exemptions (orthogonal; already gate entry). Required test: `agent_process_alive=false` + `transcript_idle_sec=80` + window 90 MUST still reap via the dead-process path.

**Q (TL visibility): how does the TL see this?**
A: Surface a per-leaf "workspace transcript activity" (seconds-since) in `wave_state` so the TL reads real progress instead of inferring from notification prose or screen. This is the half of choir-6a64 that actually bit the TL (blind kills/waits). v1: add the field to the existing `wave_state` per-child snapshot; do not build a new polling surface. NOTE it is labelled *workspace* transcript activity, not definitive per-agent liveness (see multi-session Q).

**Q (effect-arch seam — watchdog): where does the stat happen?**
A: Behind an injected closure on the same provider the watchdog already uses for `agent_process_alive` (`ServerState.recovery_provider`, `src/server/state.mbt:336-339`; reached from `check_idle_agents` at `handler_disconnect.mbt:1185-1192`) — e.g. `leaf_transcript_idle_sec(project_dir, workspace, agent_type) -> Int64?` returning seconds-since-last-transcript-write, or None when no transcript is found / type unsupported. The server stays free of direct `@sys.*`; the filesystem stat lives in the adapter. Pure watchdog logic consumes the Int64?.

**Q (effect-arch seam — wave_state): can wave_state reach that closure?** [ADDED per spec-audit HIGH #2]
A: NOT for free. `wave_state` is a pure planner + interpreter (`src/tools/wave_state.mbt`); `interpret_wave_state` (`:1031-1043`) and `plan_wave_state` (`:1170-1186`) take injected readers (`capture`, `heartbeat_reader`, `tdd_phase_reader`, `task_contract_reader`) but NO `RecoveryProvider`, and the dispatch call site (`src/tools/dispatch.mbt:2012-2024`) does not have one in scope. So: add a NEW injected reader param `transcript_idle_reader? : (@types.Agent) -> Int64?` (default `None` → hermetic tests + status quo) to both `interpret_wave_state` and `plan_wave_state`; add an optional `transcript_idle_sec : Int64?` field to the `WaveStateChild` struct (`:383-395`). Wire the concrete reader at the dispatch boundary that owns `ServerState` (bind from `recovery_provider`, or a cached observation stored on `ServerState` and passed as a plain reader). If the tool dispatch genuinely cannot see server state, prefer the cached-observation route over leaking the provider into the pure path. This is more than a one-line thread — budget for it.

**Q (multi-session safety — newest jsonl): is "newest *.jsonl" the right session?** [ADDED per spec-audit MED #3]
A: Trusted ONLY for choir-managed leaf worktrees, where choir launches exactly one claude session per worktree (the common case — sampled leaf worktree dirs hold a single jsonl). The root/project dir holds many concurrent+historical jsonls, so newest-jsonl is NOT generally a per-agent signal — hence gating the whole feature on `is_choir_managed_worktree_path` (same gate nwaf uses) and labelling the wave_state field "workspace transcript activity." Hardening: ignore jsonls with mtime older than the agent's spawn/registration time if that timestamp is reachable (prevents a stale resumed-session file from masquerading); v1 may skip this if the single-session-per-worktree invariant holds, but the gate on choir-managed worktree is mandatory.

**Q (early window — spawn to first transcript): what protects a just-spawned leaf?** [ADDED per spec-audit MED #4]
A: This feature only helps AFTER the first transcript write; before that the locator returns None → status quo. The pre-transcript interval is covered by the EXISTING signals: nwaf owned-process liveness (reaps a dead spawn fast) and the 300s idle threshold (a live spawn is not reaped for 300s). Do NOT fake progress on a missing transcript. A narrow spawn-grace keyed to registration time is an OPTIONAL follow-up, not v1 — v1 must not regress the early window, only add post-first-write protection.

**Q (claude-home resolution): how is `<claude-home>` found?** [ADDED per spec-audit MED #5]
A: `claude_home` is an INJECTED/configurable value resolved in ONE place in the adapter; tests inject it. Do NOT bake `CLAUDE_CONFIG_DIR` as fact (the native build's env-var contract is unverified — live transcripts are under `/home/justin/.claude/projects` but stale dirs also exist under `~/.config/claude`). Production default resolves `~/.claude` with env override applied at that single resolution point; the locator helper itself takes `claude_home` as a parameter (pure, env-free).

## Goals
- A provider-keyed transcript locator: `AgentType::Claude` + `agent.workspace` → newest `*.jsonl` under `<claude-home>/projects/<mangled-workspace>`; mangling = `/` and `.` → `-`; `<claude-home>` honors env, not hardcoded.
- An injected closure (recovery-provider style) returning seconds-since-newest-transcript-write (None when absent/unsupported), so the server emits no direct `@sys.*`.
- `check_idle_agents`: a recent transcript write SUPPRESSES the idle-reap (leaf treated as not-idle), with precedence above the existing idle-threshold reap and not below nwaf's dead-process reap. Non-Claude / no-transcript → None → exact status quo (no suppression, behaves as today).
- `wave_state` per-child snapshot gains a transcript-activity field (seconds-since / progressing) so the TL sees real per-turn progress.
- Graceful degradation everywhere: locator miss, missing dir, unreadable, unsupported type → None → today's behavior; never an error, never a false "progressing".

## Non-Goals
- No heartbeat/hook-emitted progress signal (that is choir-zxmc, deferred).
- No support for non-Claude transcript layouts in v1 (provider-keyed so they can be added later).
- No parsing of transcript CONTENTS (no turn-counting, no semantic progress) — mtime only.
- No new polling loop, daemon, or TL-facing surface beyond the existing `wave_state` field.
- Does not replace screen-hash or nwaf pid-liveness — it is an additional, conservative (anti-reap) signal layered on top, and never suppresses the dead-process reap.
- No change to lifecycle exemptions, the progress-backstop, or the idle threshold value (300s, `src/bin/choir/uds_server.mbt:3840-3844`).
- Does NOT protect a leaf stuck inside a single long-running tool call: transcript mtime advances on transcript writes, not while claude waits on a subprocess. A `moon test`/build exceeding the window (then 300s) with no transcript append will still reap. Protecting long tool calls is a different signal (the heartbeat-hook follow-up, choir-zxmc), out of scope here. [per spec-audit MED #6]

## Design
- **Locator (pure, testable):** a pure helper `claude_transcript_dir_for_workspace(claude_home, workspace) -> String` doing the `/`+`.`→`-` mangle and join. Unit-testable with no I/O. Keyed by `AgentType` at the call site (only `Claude` resolves a path; others → None).
- **Adapter (I/O):** the concrete recovery-provider impl gains `leaf_transcript_idle_sec(project_dir, workspace, agent_type)`: resolve `<claude-home>` at a single injected/configurable point (NOT a baked `CLAUDE_CONFIG_DIR`; default `~/.claude`, env override applied here only), build the dir via the pure helper, find newest `*.jsonl`, return `now - mtime` in seconds (None if not `AgentType::Claude`, dir/file absent, or not a choir-managed worktree). Gate on `is_choir_managed_worktree_path` so the multi-session root dir is never consulted. All `@sys.*` lives here, mirroring `agent_process_alive`.
- **Watchdog (`src/server/handler_disconnect.mbt`, `check_idle_agents`):** consult the injected closure, but order the reap decision so the dead-process check stays first. Let `progressing = transcript_idle_sec.map(s => s < transcript_progress_window_sec).or(false)`. Decision order (per spec-audit HIGH #1): (1) nwaf `process_dead` (already computed at `:1180-1196`) → reap; (2) else `if progressing { continue }` (suppress idle reap); (3) else existing `idle_sec >= threshold` reap; (4) else `continue`. Concretely: keep nwaf's `if !idle_expired && !process_dead { ...maybe continue... }` shape, but inside the "would reap on idle_expired" branch, gate it on `!progressing` — i.e. progress only cancels the IDLE-threshold reap, never the `process_dead` reap. Add a distinct log when a reap is SUPPRESSED by transcript progress (observability). `transcript_progress_window_sec` is a named constant (proposed default 90s — below the 300s idle threshold and below the 120s worker no-handoff notify; bikeshed in review).
- **wave_state (`src/tools/wave_state.mbt`):** add an injected reader param `transcript_idle_reader? : (@types.Agent) -> Int64?` (default `None`) to `interpret_wave_state` (`:1031-1043`) and `plan_wave_state` (`:1170-1186`); add optional `transcript_idle_sec : Int64?` to `WaveStateChild` (`:383-395`) — ADDITIVE, schema stays v1 (`:1-2`; `from_json` at `:626-633` only rejects non-1 versions, so a new optional/nullable child field is backward-compatible). Wire the concrete reader at the dispatch boundary (`src/tools/dispatch.mbt:2012-2024`) from `ServerState.recovery_provider` (or a cached observation on `ServerState`); do NOT leak `@sys.*`/the provider into the pure planner. Typed field, no stringly JSON.
- **Injection wiring:** bind the new closure at the same server seam where `recovery_provider.agent_process_alive` is constructed; tests inject a fake returning a chosen Int64?.

## Verify
- `moon test --target native`:
  - Pure locator: exact string assertions — `/mnt/data/Code/choir` → `-mnt-data-Code-choir`, and `/mnt/data/Code/choir/.choir/worktrees/X` → `-mnt-data-Code-choir--choir-worktrees-X` (the two live-verified shapes; uppercase preserved). Do NOT reuse `sanitize_agent_id`/branch sanitizers (different domain); do NOT assert space/underscore behavior (unobserved).
  - Watchdog (injected fake closure): progressing transcript (idle_sec < window) + STALE screen → NOT reaped (suppressed); no transcript (None) + stale screen past 300s → reaped exactly as today; None + live screen → not reaped; **REQUIRED (HIGH #1): `process_dead`/`agent_process_alive=false` + `transcript_idle_sec=80` + window 90 → STILL reaped via the dead-process path** (progress must not block dead-process reap); Claude type resolves a path, non-Claude type → None → status-quo.
  - wave_state: `plan_wave_state` with an injected `transcript_idle_reader` returning a value populates `WaveStateChild.transcript_idle_sec`; default (`None` reader) → field is `None`/absent and snapshot still parses at schema_version 1.
- `moon run src/bin/choir_lint --target native` — clean.
- Hermetic only: fake the closure; do NOT stat the real `~/.claude` or create real worktrees. The pure-locator test is a string assertion. No real-checkout mutation, no git-state fixtures.

## Boundary (do not)
- Do NOT call `@sys.*`/`@process.*` from `src/server/` or the `wave_state` pure planner — the stat lives in the adapter behind the injected closure (effect-arch).
- Do NOT hardcode `/home/...`; resolve claude-home at one injected/configurable point (default `~/.claude`), and do NOT bake `CLAUDE_CONFIG_DIR` as fact.
- Do NOT let a locator miss / missing transcript become an error or a false "progressing" — None → status quo (preserves the early-window behavior).
- Do NOT let transcript-progress suppress nwaf's dead-process reap (dead-process check runs FIRST), the progress-backstop, or lifecycle exemptions.
- Do NOT consult the multi-session root/project transcript dir — gate on `is_choir_managed_worktree_path`.
- Do NOT bump `wave_state` schema_version — the new child field is additive/optional at v1.
- Do NOT parse transcript contents or count turns; mtime only.
- Do NOT introduce a stringly agent-type or stringly snapshot field; key on `AgentType`, add a typed field.
- Do NOT build a new poller/daemon; reuse `check_idle_agents` and `wave_state`.
- Hermetic tests only; no real `~/.claude` or worktree I/O in fixtures.

## Follow-Ups
- Heartbeat-hook signal (choir-zxmc) as the durable, cross-provider, choir-owned alternative if transcript-scraping proves fragile.
- Map codex/gemini/cursor transcript layouts behind the same provider-keyed locator (extends coverage without touching the watchdog).
- Size-delta or last-line-timestamp signal if mtime proves too coarse (e.g. a turn that writes nothing).
- Optional: feed transcript-idle into the TL's notification cadence so [possibly-stalled] nudges are gated on real inactivity.
