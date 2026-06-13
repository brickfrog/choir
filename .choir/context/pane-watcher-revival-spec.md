# Spec: pane-watcher-revival

## Context

The no-handoff watchdog (`check_idle_agents` → `check_worker_no_handoff` /
`check_leaf_no_handoff`) is supposed to detect an agent that has gone silent
(finished but never called `notify_parent`, or stalled) and escalate its pane
tail to the parent with `[WORKER STALLED — no handoff]`. It **never fires**,
because the pane-content feed it depends on is dead: `PaneWatcher::watch_pane`
spawns a long-running supervisor (`choir_spawn_zellij_pane_viewport_subscribe`,
`src/sys/stub.c`) that execs `zellij --session S subscribe pane-viewport
--pane-id <TABNAME> --format json`. On the installed **zellij 0.45.0** that
invocation is doubly wrong: `subscribe` no longer takes a `pane-viewport`
positional (exit 2), and `--pane-id` wants a real pane id (`terminal_N`), not a
tab name. The supervisor dies immediately, the `/tmp/choir-viewport-<id>.json`
snapshot file is never written (confirmed: zero such files exist while agents
run), so `observe_idle` always reads empty → returns `None` → the watchdog
loops over nothing. That is why, in this session, two codex workers finished
their task without calling `notify_parent` and the TL got no escalation and had
to read panes by hand.

This feature revives the watcher using zellij 0.45's stable, focus-free
`zellij action dump-screen --pane-id <id> --full` (verified on this host: reads
any pane's content without moving focus), captures each agent's real pane id at
spawn, and deletes the broken streaming-subscribe subsystem.

## Clarifications

> Decisions from the user during crystallization, plus host-verified zellij facts.

**Q: Fix the watcher only, or also auto-synthesize a clean `notify_parent` from
the worker's final pane output?**
A: Watcher only. Reviving the watcher re-feeds the existing escalate path, so a
silent worker's pane tail reaches the parent — that restores the lost
observability, which is the whole pain. Auto-synthesizing a structured handoff
from pane text is a Follow-Up, not this pass.

**Q: The in-pane "prod" nag types text into the worker's pane to make it call
`notify_parent`. This session that text triggered a codex apology-loop ("I can't
complete the handoff from here"). Keep it, rework it, or drop it?**
A: Drop it. Do not type into agent panes to demand a handoff. When an agent is
idle-without-handoff past the threshold, deliver its pane tail straight to the
parent. This collapses the two-stage prod→escalate flow into a single
idle-threshold escalation.

**Q: Can a pane be read without stealing focus on zellij 0.45.0?**
A: Yes — `zellij --session S action dump-screen --pane-id terminal_N --full`
prints the pane viewport to stdout and does not change focus (host-verified).

**Q: How is the agent's pane id resolved — capture at spawn, or look it up?**
A: Look it up at watch time, reusing infra that already exists. The codebase
already runs `zellij --session S action list-panes --json --tab`
(`src/workspace/multiplexer.mbt:148`) — verified working on 0.45.0, it returns
per-pane JSON with integer `id` + `tab_name` — parses it into
`@tools.ZellijListPanesSnapshot`, and resolves a `ZellijTab` target →
`pane_id` with `@tools.resolve_zellij_pane_id(target, snapshot)`
(`src/tools/status_bar_state.mbt:661`). The `status_bar_state` tool uses this
successfully today. So there is **no spawn-time capture, no
`.choir/pane-ids` sidecar, and no new diff function** — reuse the existing
resolver. (`new-tab`'s stdout is not the pane id — printed `3` while the pane
was `terminal_4` — which is why the lookup, not stdout-capture, is the path.)

**Q: Existing analog / building blocks to mirror?**
A: `@tools.resolve_zellij_pane_id` + `@tools.ZellijListPanesSnapshot` for
resolution (reuse, do not reimplement). For the dump runner, mirror
`@exec.capture_command_stdout` (`src/exec/exec_native.mbt:1146`). For
capability injection, the existing `PaneWatchHost` struct
(`src/runtime/pane_watch.mbt:9`) is already the seam. Resolution lives in
`src/server` (which already imports `@tools`); `src/runtime` must not import
`@tools` (cycle).

## Goals

- `check_idle_agents` observes real pane content for every watched agent, so a
  worker/leaf that is idle-without-handoff past the threshold reliably escalates
  `[WORKER STALLED — no handoff]` + pane tail to its parent via
  `durable_deliver_to_parent`.
- Pane content is read with `zellij action dump-screen --pane-id <id> --full`
  on the existing ~30s poller tick — no long-running supervisor, no `/tmp`
  snapshot files.
- Each agent's real zellij pane id is resolved at watch time by reusing
  `@tools.resolve_zellij_pane_id` against a `list-panes --json --tab`
  snapshot — no spawn-flow changes, no sidecar, no reimplemented resolver.
  Resolution is lazy/self-healing: retry on later ticks until the tab is
  listed, and re-resolve naturally after a server reload.
- The in-pane prod nag is removed: no `LocalTerminalInput` is sent to demand a
  handoff. The no-handoff watchdog escalates directly to the parent at a single
  idle threshold.
- The broken streaming-subscribe subsystem is deleted:
  `spawn_zellij_pane_viewport_subscribe` (MoonBit binding + C body
  `choir_spawn_zellij_pane_viewport_subscribe`), the snapshot-file path/read,
  and the now-unused `PaneWatchHost` fields.
- `moon test --target native` green; the watchdog path stays fully unit-testable
  via injected capabilities (no real zellij in tests).

## Non-Goals

- No auto-synthesis of a structured `notify_parent` from pane text (Follow-Up).
- No change to the codex/claude handoff prompt instructions.
- No change to the hard idle-kill (`[WATCHDOG] killed after Ns idle`) semantics
  beyond feeding it real observations; its timeout stays 300s.
- No change to `new-tab`'s tab-per-agent model (not switching to `zellij run`).
- No PID/pane-id-reuse hardening across a full zellij restart (a zellij restart
  kills the agents too; out of scope).
- No Windows/macOS support; zellij + Linux only.
- No change to spawn for non-zellij/inline workers that have no
  `terminal_target` — they are simply not watched (status quo).

## Design

Single vertical leaf, all in the watch path — no spawn-flow changes. The
resolution and dump capabilities are injected and reuse existing code.

### Resolve pane-id at watch time (reuse the existing resolver)

- Do **not** add a sidecar, a spawn-time capture, or a new diff function.
  Reuse `@tools.resolve_zellij_pane_id(target, snapshot)` against a snapshot
  captured by the existing `list-panes --json --tab` command
  (`src/workspace/multiplexer.mbt:148` builds it; `src/tools/status_bar_state.mbt`
  parses it into `ZellijListPanesSnapshot`).
- Resolution happens in `src/server` (which already imports `@tools`):
  `ServerState::watch_pane` resolves the agent's `terminal_target` →
  `pane_id`; `check_idle_agents` re-resolves lazily on later ticks for any
  watch still missing a `pane_id` (covers the brief spawn→list-panes race and
  post-reload re-discovery). `src/runtime` must **not** import `@tools`.
- Inject the list-panes-snapshot capture as a capability with an
  `@exec.capture_command_stdout`-based native default (mirror the
  `capture?`/`git_capture?` injected-runner pattern); do not call
  `@exec`/`@process` directly from `src/server`/`src/tools` orchestration.

### Watcher rewrite (consumer)

- `PaneWatchHost` loses `spawn_zellij_pane_viewport_subscribe`, `read_file`,
  `delete_file_sync`; gains `dump_pane_screen : (session, pane_id) -> String`
  (native default runs `zellij --session S action dump-screen --pane-id <id>
  --full` via `capture_command_stdout`). `kill_pid_best_effort` is dropped (no
  supervisor to kill).
- `PaneWatcher` records `{session, Option[pane_id], observation}` per watched
  agent; no subprocess, no snapshot file. The pane_id is set by the server
  after resolution; observe_idle is a no-op until it is set.
- `observe_idle` calls `dump_pane_screen(session, pane_id)` for the watched
  pane, hashes the screen, and applies the existing change-vs-idle logic. Same
  `PaneIdleObservation { screen, idle_sec }` return.
- `pane_snapshot_path` and `read_viewport` are deleted.
- A watch with no resolved pane id is not created (no false idle).

### Drop the prod (single-threshold escalation)

- Remove `prod_worker_no_handoff` and the `worker_no_handoff_prod_text`
  `LocalTerminalInput` send. Remove the `Prod` branch from
  `worker_no_handoff_decision` (and the leaf post-fix no-handoff equivalent);
  the decision collapses to "idle ≥ threshold and not handed off → EmitStalled".
- Keep `emit_worker_stalled_no_handoff` / `emit_leaf_stalled_no_handoff` and the
  message builders in `worker_handoff.mbt` (the payload the parent receives is
  unchanged). Keep the dedupe (`worker_no_handoff_stalled_emitted`) and the
  `handoff_was_delivered` short-circuit.
- Collapse `worker_no_handoff_prod_sec` + `worker_no_handoff_escalate_sec` to a
  single `worker_no_handoff_idle_sec` (default 120s); update config schema and
  call sites. Remove the now-dead `prodded_at` tracking.

### Delete

- C: `choir_spawn_zellij_pane_viewport_subscribe` and its SIGTERM handler/helpers
  in `src/sys/stub.c`; the `c_spawn_zellij_pane_viewport_subscribe` extern and
  `spawn_zellij_pane_viewport_subscribe` wrapper in `src/sys/io.mbt` +
  `io_stub.mbt`. Keep `/proc/self/exe` and all unrelated FFI.

### Recovery

- On server reload / agent re-discovery, `watch_pane` re-resolves the pane-id
  from the live session (zellij session + pane ids survive choir's exec-in-place
  reload). If the tab is not found, the agent stays unwatched and is retried on
  later ticks — no crash, no false kill.

## Verify

- `moon test --target native` — green.
- `! grep -rn "spawn_zellij_pane_viewport_subscribe\|pane_snapshot_path\|choir-viewport-" src/` — streaming-subscribe subsystem gone.
- `! grep -rn "subscribe.*pane-viewport\|worker_no_handoff_prod_text" src/` — broken zellij call and the prod nag gone.
- `! grep -rn "pane_id_from_list_panes_diff\|agent_pane_id_file_path\|pane-ids/" src/` — no reinvented resolver / sidecar; resolution reuses `resolve_zellij_pane_id`.
- Unit test: `ServerState::watch_pane` resolves pane-id via a spy `list-panes` snapshot + `@tools.resolve_zellij_pane_id`; an unresolvable tab leaves the agent unwatched (lazy retry), never false-idle.
- Observable (host has zellij): a small native or scripted check that
  `zellij --session <s> action dump-screen --pane-id <id> --full` returns
  non-empty pane text for a live pane and does not change the focused tab
  (assert `query-tab-names`/focus unchanged before/after). Keep it hermetic and
  skip cleanly when no zellij/session is present (CI has none) — gate on a
  session-exists probe so CI stays green.
- Watcher unit test (injected `dump_pane_screen` spy): unchanged screen across
  ticks past threshold → `observe_idle` reports idle → `emit_worker_stalled`
  delivers to parent exactly once; changing screen resets idle; no
  `LocalTerminalInput`/prod is ever sent.

## Boundary (do not)

- Do not keep the streaming `subscribe` or the `/tmp/choir-viewport-*` snapshot
  files "as a fallback" — deletion is the point.
- Do not type into agent panes to demand a handoff (no `LocalTerminalInput`
  prod). Escalate to the parent only.
- Do not steal/move zellij focus on the poller tick. `dump-screen --pane-id` is
  focus-free; never `go-to-tab-name` from the watcher.
- Do not call `@sys.*`/`@exec.*`/`@process.*` directly from `src/server` or
  `src/tools` orchestration — inject the capture/dump capabilities with native
  defaults (read-only `@sys.read_file` of the sidecar at the dispatch seam is
  allowed).
- Do not reimplement pane-id resolution — reuse `@tools.resolve_zellij_pane_id`.
  Do not add a `.choir/pane-ids` sidecar or any spawn-flow change; resolution is
  a watch-time lookup. A failed/None resolution → unwatched agent + retry, never
  a spawn failure and never a false idle.
- Do not change the hard idle-kill timeout (300s) or the `[WATCHDOG]` kill
  behavior beyond feeding it real observations.
- Do not add shell-harness tests or tests that drive a real zellij session in
  CI; the diff/idle logic is pure/injected and unit-tested. The one live
  zellij check must self-skip when no session exists.
- Verify with `moon test --target native`, never bare `moon test`.
- Do not call `notify_parent` until review threads are resolved.

## Follow-Ups

- Auto-synthesize a structured `notify_parent` (status + summary) from the
  worker's final pane output on done-without-handoff, instead of only forwarding
  the raw pane tail.
- After `merge_pr`/automerge succeeds, auto-delete the merged leaf branch so the
  remote doesn't accumulate (today's 220-branch cleanup was manual).
- Make the codex worker handoff itself deterministic (the model still has to run
  `notify_parent`; the watcher is the backstop, not a cure).
- Cap/stagger dump-screen calls if an agent count ever makes per-tick dumping
  expensive.
- Update the TL prompt hint at `src/prompts/loader.mbt` ("check /proc/<pid>/cwd
  if leaf goes silent") now that pane content is observable server-side.
