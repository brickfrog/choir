# Spec: leaf-finalize-handshake

## Context

Two related "leaf-finish handshake has gaps" bugs from today's PR #348
incident, batched into one PR because they share files and the conceptual
theme of cleaning up a leaf cleanly:

- **`choir-9ke` (P2)**: the per-HEAD automerge sweep (shipped in PR #343
  via `choir-cps`) runs inside `deliver_pending_poll_events` after the
  per-event loop. The sweep depends on the poller TICKING. Today's poller
  is event-driven (ticks fire when GitHub changes deliver an event). When
  a leaf clears its gate (e.g. TL resolves the last review thread, leaf
  cleanly notifies + shuts down), no new GitHub event happens, so no tick
  fires, so the sweep never runs — and the gate-ready PR sits indefinitely.
  Observed live 2026-05-16 on PR #348: gate cleared at 10:53, last tick
  was 10:53, no tick or sweep activity for the next ~14 min until the TL
  manually invoked `merge_pr`.

- **`choir-0a7` (P2)**: the `shutdown` tool's adapter host-steps ordering
  (`src/tools/shutdown.mbt::shutdown_adapter_host_steps`) is
  `PollerCriticalPhaseRead`, `RegistryRoleLookup`, `LifecycleRead`,
  `PaneClose`, `DevExitEventApply`, `WorktreeCleanupAttempt`,
  `BeadsLifecycleMirror`. `PaneClose` is deliberately after the lifecycle
  read: the interpreter computes `shutdown_exit_plan` first, then closes
  the pane only when `attempt_worktree_cleanup` is true. Deferred
  PR-owning shutdowns leave the agent process running so it can keep
  processing messages.

Observable target: a `fork_wave(automerge, iterative)` leaf clears its gate
(TL resolves last thread, leaf notifies + shuts down). Within ~60 seconds
the automerge sweep fires and merges the PR — without TL intervention. When
the shutdown exit plan grants or releases exit, the leaf's `shutdown` call
closes its pane and exits its bridge process; when the plan defers exit, the
pane remains open and the leaf must keep processing messages.

## Clarifications
> Q&A from the crystallize step. Durable; leaves read this.

**Q: How should we wake up the automerge sweep when GitHub is quiet?**
A: Periodic poller tick + on-thread-resolve trigger. (i) The poller gains
a heartbeat tick: at minimum every N seconds, regardless of GitHub events,
the poller runs its normal tick loop (which already includes the sweep).
Cheap (no extra `gh` calls if nothing changed); catches the dead-zone we
hit today within N seconds. (ii) When the TL or leaf successfully resolves
the last review thread (via the `resolve_review_thread` MCP tool OR the
server's auto-resolve path), synthesize an immediate poller tick for that
PR. Targeted; makes "thread cleared → gate ready → merge" feel instant.

**Q: Periodic poller-tick cadence?**
A: 60s default, configurable, `0` disables. New config knob (alongside
`audit_heartbeat_sec` from yesterday's pattern). 60s matches existing
heartbeat cadence; worst-case automerge latency after gate-clear is ~60s
(or near-instant via the on-thread-resolve trigger).

**Q: Shutdown tool's pane-close behavior?**
A: `PaneClose` belongs in `shutdown_adapter_host_steps` after
`LifecycleRead`, not before the plan is known. The interpreter computes
`shutdown_exit_plan` first, then closes the pane only when
`attempt_worktree_cleanup` is true and the caller is not a supervisor. A
deferred shutdown leaves the pane and process alive so the leaf can keep
processing parent messages.

## Goals

### choir-9ke — periodic + targeted poller-tick wakeups

- **Periodic heartbeat tick**: the server runs
  `ServerState::process_poller_tick` on a periodic schedule (default every
  60s, configurable via a new `poller_heartbeat_tick_sec : Int` config
  field; `0` disables). The heartbeat task lives wherever other server
  background tasks live (alongside the existing watchdog tick). It runs
  `process_poller_tick` even when no external event has arrived — the
  existing sweep logic handles the rest.
- **On-thread-resolve trigger**: when `interpret_resolve_review_thread`
  (`src/tools/dispatch.mbt:1549` / its implementation) succeeds AND the
  underlying PR's unresolved-thread-count drops to 0 (or even just
  decreases), the server enqueues an immediate synthesized poller tick for
  that PR. The leaf or TL clearing the last thread no longer waits for the
  periodic timer; the sweep fires within seconds.
- **The sweep itself is unchanged**: it already iterates
  `self.poller.tracked.values()`, checks `pr_needs_automerge_sweep_attempt`,
  invokes `maybe_trigger_automerge_for_pending_event`. We just give it
  more chances to run.
- **End-to-end**: a leaf clears its gate. Within either the periodic
  heartbeat (≤60s) OR the on-thread-resolve trigger (seconds), the sweep
  fires, `merge_pr` runs server-side, the PR merges, `plan_finalize`
  fires, the leaf transitions to Done(Merged) — no TL `merge_pr` call
  required.

### choir-0a7 — `shutdown` closes the pane only when exit is granted

- **Gate `PaneClose` in `shutdown_adapter_host_steps`**: keep
  `src/tools/shutdown.mbt::shutdown_adapter_host_steps` in this order:
  `PollerCriticalPhaseRead`, `RegistryRoleLookup`, `LifecycleRead`,
  `PaneClose`, `DevExitEventApply`, `WorktreeCleanupAttempt`,
  `BeadsLifecycleMirror`. The `interpret_shutdown` host-side interpreter
  computes `shutdown_exit_plan` after `LifecycleRead`; only when
  `plan.attempt_worktree_cleanup` is true does it invoke the
  `kill_agent_pane_close_command` builder + runner sequence.
- **Role guard**: `Role::Root` and `Role::TL` are never pane-closed via
  `shutdown` (same `is_supervisor_role` invariant `kill_agent` enforces).
  This preserves the choir-eek protection (don't kill the TL).
- **Failure mode**: if the pane-close runner returns non-zero, log a
  TRACE, continue with the rest of the shutdown host steps — pane-close
  failure doesn't block the rest of cleanup.
- **End-to-end**: a leaf calls `notify_parent` then `shutdown`. If the exit
  plan grants or releases exit, the pane closes within seconds and the
  bridge process exits cleanly. If the exit plan defers exit, the pane is
  untouched and the leaf continues processing messages.

### Cross-cutting

- Both fixes are server-side. No leaf prompt changes. No MCP tool surface
  changes. No new poller event types.
- Tests cover the truth table for each fix: periodic-tick-fires-sweep,
  on-thread-resolve-fires-tick, shutdown-closes-pane-for-granted-exits,
  shutdown-leaves-deferred-pane-alive, and shutdown-doesn't-close-pane-for
  Root/TL.

## Non-Goals

- Reactive-only fallback for environments where 60s ambient ticks are too
  costly. The `poller_heartbeat_tick_sec=0` knob handles disable. Tuning
  the default isn't in scope.
- Unconditional PaneClose for `shutdown`. The lifecycle exit plan is the
  authority: deferred PR-owning shutdowns stay alive; granted and releasable
  exits close the pane. Rename/delayed-close behavior is out of scope.
- Touching the existing kill_agent path or the kill-watchdog timeout.
- Changing the sweep logic itself (`pr_needs_automerge_sweep_attempt`,
  `last_automerge_attempt_sha`); the sweep is already correct, we just
  trigger it more.
- A new `[AUTOMERGE TICK]` poller event or pane-side notification. The
  sweep firing is server-internal; outcome (`[PR MERGED]`) already
  arrives via the existing path.
- Heartbeat ticks for OTHER tracked state (e.g. lifecycle staleness, idle
  agents). Scope is the automerge sweep.
- A unified "leaf finalize" framework. We're patching two specific
  observed gaps; future ones get filed.

## Design

### choir-9ke

**`src/types/config.mbt`** (or wherever the config struct lives —
alongside `audit_heartbeat_sec`): add
```moonbit
pub(all) struct Config {
  ...
  poller_heartbeat_tick_sec : Int  // 0 disables; default 60
}
```

**Server task wiring**: locate where the existing watchdog tick task is
spawned (likely `src/server/handler_disconnect.mbt::check_idle_agents` or
a server-startup spawn site). Add a sibling heartbeat-tick task that,
while the server is alive, runs:
```
while alive {
  @async.sleep(poller_heartbeat_tick_sec * 1000)
  if poller_heartbeat_tick_sec == 0: continue   // disabled
  state.process_poller_tick(...)
}
```
Use the existing async/sleep seam; mock for tests.

**On-thread-resolve trigger**: `src/tools/dispatch.mbt:1549` — the
`ToolRequest::ResolveReviewThread` arm calls
`interpret_resolve_review_thread`. After a successful response, look up
the affected PR's tracked entry, check if `unresolved_thread_ids.length()`
dropped vs the prior tracked count, and if so call
`state.process_poller_tick(...)` for that PR (or a more targeted "sweep
this PR now" path that re-enters the per-event sweep loop with
`MergeReady(pr_number)` synthesis). Factor the "should we synthesize a
tick now?" decision as a pure function for testing.

**Tests**:
- Periodic heartbeat: mock the async-sleep seam; assert
  `process_poller_tick` runs at the configured cadence; assert
  `poller_heartbeat_tick_sec=0` disables (no tick from the heartbeat
  path, event-driven still works).
- On-thread-resolve: dispatch a `ResolveReviewThread` request that takes
  unresolved-count 1→0; assert an immediate sweep runs for that PR (mock
  the sweep entrypoint and assert it's called with the right PR number).
- Negative: thread resolve that takes count 5→4 (still unresolved): no
  synthesized tick (the sweep would no-op anyway; don't waste cycles).
  OR fire it anyway and let the sweep's existing `merge_gate_ready` check
  handle it — implementer's call; either is correct, but match the
  existing event-driven path's behavior.
- End-to-end (hermetic): tracked PR with `merge_gate_ready=true` +
  `automerge enabled` + `last_automerge_attempt_sha != last_sha` sits;
  periodic tick fires; sweep runs; merge_pr invoked.

### choir-0a7

**`src/tools/shutdown.mbt::shutdown_adapter_host_steps`** (~L367):
```moonbit
pub fn shutdown_adapter_host_steps() -> Array[ShutdownAdapterHostStep] {
  [
    PollerCriticalPhaseRead,
    RegistryRoleLookup,
    LifecycleRead,
    PaneClose,                  // gated by shutdown_exit_plan
    DevExitEventApply,
    WorktreeCleanupAttempt,
    BeadsLifecycleMirror,
  ]
}
```
Keep `PaneClose` after `LifecycleRead` so the interpreter can compute the
exit plan before side effects that may destroy the pane.

**`interpret_shutdown`** (the host-side step interpreter): when handling
`PaneClose`, first require `shutdown_exit_plan(...).attempt_worktree_cleanup`.
Then look up the agent in the registry and check
`is_supervisor_role(agent.role)`:
- If supervisor: SKIP — `Role::Root`/`Role::TL` panes are never closed
  via shutdown (choir-eek invariant).
- If `Role::Dev` or `Role::Worker` AND `agent.terminal_target` is `Some`:
  invoke `kill_agent_pane_close_command(agent)` → runner. Log success +
  failure with TRACE.

**Tests**:
- Truth table: Dev or Worker granted exit with terminal_target ⇒ PaneClose
  command runner is invoked; deferred Dev exit ⇒ pane close is not invoked;
  Dev without terminal_target ⇒ no-op; Root/TL with terminal_target ⇒ no-op
  (skipped by is_supervisor_role guard); Pane-close runner failure ⇒ logged
  but shutdown continues to subsequent steps.
- Negative: kill_agent's PaneClose behavior unchanged (regression
  protection — choir-eek's Root/TL guard still refuses kill_agent on
  supervisors).

## Verify

- `moon test --target native`: all new + existing tests pass; new tests
  cover heartbeat periodic + on-thread-resolve trigger + PaneClose truth
  table + role-guard regression.
- Observable: on the next `fork_wave(automerge, iterative)` Dev leaf wave
  that requires Copilot fixes:
  - After the TL or leaf resolves the last thread, the merge happens
    within ~60s (periodic tick) or seconds (on-thread-resolve trigger).
    Check via `choir logs --grep "automerge"` and the `[PR MERGED]` event
    timing.
  - When the exit plan grants exit (Allowed or releasable deferred), the
    leaf's pane disappears within seconds. `ps -ef | grep
    "choir mcp-stdio.*<leaf-id>"` returns nothing within seconds of the
    shutdown call.
  - When shutdown is deferred because the leaf still owns an open PR, the
    pane and `choir mcp-stdio` process MUST remain alive, and the leaf must
    continue processing TL messages.
- `grep -c "poller_heartbeat_tick_sec" src/types/config.mbt` ⇒ ≥1.
- `grep -c "PaneClose" src/tools/shutdown.mbt` ⇒ ≥2 (definition +
  adapter step list).

## Boundary (do not)

- The periodic heartbeat tick must respect `poller_heartbeat_tick_sec == 0`
  as a true disable (no ticks fire from the heartbeat path).
- The on-thread-resolve trigger fires ONLY when the resolve actually
  decreased the unresolved count (or took it to 0). Don't fire on no-op
  resolves of already-resolved threads.
- `PaneClose` for shutdown fires ONLY when `shutdown_exit_plan` grants or
  releases exit (`attempt_worktree_cleanup=true`) for non-supervisor agents.
  It NEVER fires for deferred PR-owning shutdowns, `Role::Root`, or
  `Role::TL` — the `is_supervisor_role` guard is mandatory (choir-eek
  invariant).
- PaneClose failure (runner exit ≠ 0) MUST NOT block the rest of
  shutdown's host steps. Log TRACE, continue with worktree cleanup +
  lifecycle event + beads mirror.
- No new MCP tool surface, no new poller event types, no pane-side
  `[AUTOMERGE TICK]` event.
- No `@sys.*` / `@process.*` direct calls in `src/server` / `src/tools`
  beyond existing adapter seams.
- Use the `Role`, `ShutdownAdapterHostStep` enums (not strings);
  `ChoirError` for new error paths.
- All tests hermetic — mock the async/sleep, runner, pane-close, sweep
  entrypoints. No real sleeping / process spawning / pane interaction.

## Follow-Ups

- Heartbeat ticks for other server-internal state (idle agent staleness,
  registry consistency checks, etc.) — extension of the pattern. File
  separately if observed needing.
- `choir-cfw` (completion-chime) — orthogonal UX layer; this fix
  eliminates the "leaf finished, pane stuck" friction that motivates it
  but doesn't replace user-facing notification.
- `choir-3bj` (delta-audit on retry) — composes with this fix (faster
  audits + cleaner finalize handshake).
- Rename/delayed PaneClose variants for `shutdown` if the granted-exit close
  behavior turns out to remove value (post-mortem visibility) in practice.
  File separately.
