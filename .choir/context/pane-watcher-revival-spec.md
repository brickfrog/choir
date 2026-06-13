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

**Q: Does `zellij action new-tab` return the created pane id so we can capture
it at spawn?**
A: No. `new-tab -- <cmd>` returns promptly (≈0.04s, does not block on the inner
command) but its stdout is **not** the pane id (printed `3` while the created
pane was `terminal_4`). Pane id must be resolved by diffing
`zellij action list-panes` (session-wide; columns `PANE_ID  TYPE  TITLE`)
immediately before vs. after the `new-tab`. Because a wave's tabs are created
sequentially through `run_sequence`, the single new `terminal_*` row in the
after-set is unambiguously this agent's pane.

**Q: Existing analog to mirror?**
A: The pgid pidfile: `agent_pid_file_path` (`src/workspace/launch.mbt:56`),
written at spawn under `.choir/pids/<sanitized-id>`, read by the kill path,
deleted on teardown, re-readable after server reload. The pane-id sidecar
mirrors it exactly. For the dump runner, mirror `@exec.capture_command_stdout`
(`src/exec/exec_native.mbt:1146`). For capability injection, the existing
`PaneWatchHost` struct (`src/runtime/pane_watch.mbt:9`) is already the seam.

## Goals

- `check_idle_agents` observes real pane content for every watched agent, so a
  worker/leaf that is idle-without-handoff past the threshold reliably escalates
  `[WORKER STALLED — no handoff]` + pane tail to its parent via
  `durable_deliver_to_parent`.
- Pane content is read with `zellij action dump-screen --pane-id <id> --full`
  on the existing ~30s poller tick — no long-running supervisor, no `/tmp`
  snapshot files.
- Each agent's real zellij pane id is captured at spawn (before/after
  `list-panes` diff around `new-tab`) and written to a
  `.choir/pane-ids/<sanitized-agent-id>` sidecar; read by the watcher; deleted
  on teardown alongside the pidfile.
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

Single vertical leaf. Producer (capture pane-id at spawn) and consumer
(dump-screen polling) share the sidecar interface and both touch the watch path
(`handler_disconnect.mbt`); splitting would conflict and leave a non-functional
half-state.

### Pane-id sidecar (mirror the pidfile)

- Add `agent_pane_id_file_path(project_dir, agent_id)` →
  `<project_dir>/.choir/pane-ids/<sanitize_agent_id(agent_id)>`, beside
  `agent_pid_file_path`.
- Write it at spawn; read it in `watch_pane`; delete it in the same teardown
  path that removes the pidfile (`clear_agent_runtime_tracking` /
  `forget_agent_pid` neighbourhood).

### Capture at spawn (producer)

- In the server's spawn flow (where the `new-tab` command for each agent is
  built and run — `fork_wave` / `spawn_worker` handling, around
  `multiplexer.zellij_new_tab_*`), wrap tab creation with a capture seam:
  1. capture `zellij --session S action list-panes` → parse the set of
     `terminal_*` PANE_IDs (before).
  2. run `new-tab` as today.
  3. capture `list-panes` again (after).
  4. new pane id = the single `terminal_*` id in `after \ before`. If exactly
     one, write it to the pane-id sidecar for that agent. If zero or more than
     one (race/parse failure), log and skip (degrade: agent simply unwatched).
- The set-diff/parse is a **pure function** `pane_id_from_list_panes_diff(before
  : String, after : String) -> String?` — unit-tested without zellij.
- Use an injected capture capability (mirror the `capture?`/`git_capture?`
  injected-runner pattern); do not call `@exec`/`@process` directly from
  `src/tools` or `src/server` orchestration. `@exec.capture_command_stdout` is
  the native default.

### Watcher rewrite (consumer)

- `PaneWatchHost` loses `spawn_zellij_pane_viewport_subscribe`, `read_file`,
  `delete_file_sync`; gains `dump_pane_screen : (session, pane_id) -> String`
  (native default runs `zellij --session S action dump-screen --pane-id <id>
  --full` via `capture_command_stdout`). `kill_pid_best_effort` is dropped (no
  supervisor to kill).
- `watch_pane(agent_id, target, pane_id, now)` records `{pane_id,
  observation}`; no subprocess, no snapshot file.
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

- On server reload / agent re-discovery, `watch_pane` re-reads the pane-id
  sidecar (zellij session + pane ids survive choir's exec-in-place reload). If
  the sidecar is absent (pre-feature agent, or lost), the agent is unwatched —
  no crash, no false kill.

## Verify

- `moon test --target native` — green.
- `! grep -rn "spawn_zellij_pane_viewport_subscribe\|pane_snapshot_path\|choir-viewport-" src/` — streaming-subscribe subsystem gone.
- `! grep -rn "subscribe.*pane-viewport\|worker_no_handoff_prod_text" src/` — broken zellij call and the prod nag gone.
- Pure-function unit test: `pane_id_from_list_panes_diff(before, after)` returns the single new `terminal_*` id; returns `None` on zero/ambiguous diff.
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
- Do not block spawn on the inner agent command; `new-tab` returns promptly and
  the two `list-panes` captures must be fast and best-effort (failure → unwatched
  agent, never a spawn failure).
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
