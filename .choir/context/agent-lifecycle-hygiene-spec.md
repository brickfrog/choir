# Spec: agent-lifecycle-hygiene

## Context

Two related agent-lifecycle bugs that both bit us on 2026-05-15, batched into
one PR because they share `src/server/handler_disconnect.mbt` /
`src/server/worker_handoff.mbt` and a single conceptual theme (cleaning up
after dead/idle agents):

- **`choir-8c2` (P2)**: a `fork_wave(automerge, iterative)` dev leaf, after
  pushing fixes addressing Copilot review, entered an infinite `sleep 180`
  loop instead of calling `notify_parent`. `[FIXES PUSHED]` (unresolved=0)
  and then `[REVIEW]` (CI green on new head) had both arrived — but the
  leaf interpreted these as "still waiting" and idled for hours until the
  user killed it. The `choir-q4y` no-handoff watchdog catches this for
  *workers* (`Role::Worker`) but not for *dev leaves* (`Role::Dev`).
- **`choir-8is` (P3)**: when a leaf's outer process dies (manual kill, codex
  crash, terminal close) or the choir server dies, the per-agent
  `choir mcp-stdio` bridge subprocess survives as an orphan (parent PID
  reparented to init/PID 1, child still alive). `choir init --recreate`
  does not reap them; 4 orphans had accumulated by today.

Observable outcome: (1) a leaf that pushed fixes and is sitting on a
merge-gate-ready PR is prodded once at ~2 min idle; if still silent, the
parent gets a `[LEAF STALLED AFTER FIX-PUSH]` event with the leaf's pane tail
— the TL is never left hanging for hours. (2) `ps -ef | grep "choir mcp-stdio"`
after a clean session exit shows zero orphans; killing a bridge's parent
takes the bridge with it.

## Clarifications
> Q&A from the crystallize step. Durable; leaves read this.

**Q: choir-8c2 — how should the no-handoff watchdog widen to cover ReviewOwned
dev leaves?**
A: Add a sibling pure function `leaf_no_handoff_decision(role, lifecycle,
gate_ready, idle_sec, handoff_delivered, prodded, stalled_emitted, prod_sec,
escalate_sec) -> WorkerNoHandoffDecision` in `src/server/worker_handoff.mbt`,
mirroring the existing `worker_no_handoff_decision` but with the leaf-specific
predicate (role == Dev AND lifecycle is ReviewOwned AND gate_ready == true).
`check_idle_agents` iterates and calls the right one per agent role. Keep
`worker_no_handoff_decision` untouched (workers still firing as today).

**Q: choir-8c2 — should the server PROD the leaf's pane before escalating to
the parent, the same way choir-q4y does for workers?**
A: Yes, prod first then escalate. At idle ≥ `prod_sec` (default ~120s)
without `notify_parent`, send a one-shot message into the leaf's pane
(`"You pushed fixes and the merge gate is ready — call notify_parent --status
success with a short summary, then stand down. Do not idle waiting for more
events."`). At idle ≥ `prod_sec + escalate_sec` still no `notify_parent`,
emit `[LEAF STALLED AFTER FIX-PUSH]` to the parent with the leaf's pane tail.
Reuses `worker_no_handoff_prodded_at` + `worker_no_handoff_stalled_emitted`
maps + `worker_no_handoff_pane_tail` helper.

**Q: choir-8is — how should orphan `choir mcp-stdio` bridges be cleaned up?**
A: Both — PR_SET_PDEATHSIG + init-time reaper. (b) On Linux, the bridge
calls `prctl(PR_SET_PDEATHSIG, SIGTERM)` at startup so it gets a SIGTERM
when its parent dies — handles parent-dies-first the moment it happens. (c)
`choir init --recreate` sweeps `choir mcp-stdio` processes whose `PPID == 1`
(reparented to init) and SIGTERMs them — safety net for any past orphans +
the server-dies-first case.

## Goals

### choir-8c2 — leaf post-fix-push handoff enforcement

- **Prompt**: `.choir/prompts/profiles/leaf.md` gains an explicit
  "post-fix-push terminal step" subsection right after the existing
  "Do not exit voluntarily after file_pr" / review-cycle area. New text
  (paraphrase): *After you address Copilot comments and `git push`, the
  moment the next poller snapshot shows `Unresolved inline review threads
  (GraphQL): 0` AND CI green for your fix-push HEAD, your job is DONE —
  call `notify_parent --status success` ONCE with a short summary, then
  idle until `[PR MERGED]` or `[PARENT RELEASE]`. Do NOT enter `sleep`
  loops waiting for additional events. Do NOT pull review state with `gh`
  (the poller pushes events). A leaf that idles for minutes after a
  successful fix-push has failed its task.* Keep all existing review-cycle
  instructions intact (no leaf-side `gh reviewThreads` query, gh timeout
  ≠ blocker, server resolves outdated threads on FixesPushed).
  `src/prompts/loader.mbt` loads this; no loader logic change required.
- **Pure decision function**: `src/server/worker_handoff.mbt` gains
  `pub fn leaf_no_handoff_decision(role, lifecycle, gate_ready, idle_sec,
  handoff_delivered, prodded, stalled_emitted, prod_sec, escalate_sec) ->
  WorkerNoHandoffDecision`. Fires `Prod` when role==Dev AND lifecycle
  matches ReviewOwned AND gate_ready AND idle_sec >= prod_sec AND NOT
  handoff_delivered AND NOT prodded; fires `EmitStalled` when prodded AND
  idle_sec >= prod_sec + escalate_sec AND NOT stalled_emitted AND NOT
  handoff_delivered; else `DoNothing`. Worker function untouched.
- **Watchdog wiring**: `src/server/handler_disconnect.mbt::check_idle_agents`
  (around L1056) — for each agent, if `agent.role == @types.Role::Dev`,
  look up its current lifecycle and whether the tracked PR's
  `merge_gate_ready` evaluates true, call `leaf_no_handoff_decision`, and
  dispatch the result through the same prod-pane / parent-deliver paths
  the worker decision already uses (`durable_deliver_to_agent` for prod,
  `durable_deliver_to_parent` for the parent event). The existing
  ReviewOwned-exempt rule for the KILL watchdog (around L1081) stays —
  the no-handoff check is independent and additive (it does not kill).
- **Message constructors**: `src/server/worker_handoff.mbt` gains
  `leaf_stalled_no_handoff_prod_message(slug) -> String` and
  `leaf_stalled_no_handoff_parent_message(slug, idle_sec, pane_tail) ->
  String` alongside the existing worker_* helpers. Format mirrors workers
  (`[LEAF STALLED AFTER FIX-PUSH] <slug> ...`).
- **Config**: reuse `worker_no_handoff_prod_sec` /
  `worker_no_handoff_escalate_sec` for v1 (don't introduce separate leaf
  knobs unless we observe needing them). Defaults stay ~120s/~120s; `0`
  disables.
- **`handoff_delivered` map** at `handler_disconnect.mbt`: already populated
  on `notify_parent` for any agent regardless of role; no change needed.

### choir-8is — `choir mcp-stdio` bridge orphan cleanup

- **`prctl(PR_SET_PDEATHSIG, SIGTERM)` on bridge startup (Linux-only)**:
  - New C FFI helper alongside the existing native helpers in
    `src/sys/stub.c` (or wherever `kill_pid_best_effort` / `pid_is_alive`
    live): `int choir_set_parent_death_signal_term()` returning `0` on
    success, `-1` on failure. Calls `prctl(PR_SET_PDEATHSIG, SIGTERM)` on
    Linux; non-Linux variant (if present) returns `0` as a no-op.
  - Expose in `src/sys/io.mbt` as
    `pub fn set_parent_death_signal_term() -> Bool`. Wasm/JS stub in
    `src/sys/io_stub.mbt` returns `false`.
  - `src/bin/choir/mcp_mode.mbt`'s `mcp-stdio` entrypoint calls
    `ignore(@sys.set_parent_death_signal_term())` at the very start of
    its run loop, before any I/O. Log TRACE on failure; continue.
- **Init-time reaper sweep**:
  - New helper in `src/sys/` (native): `pub fn
    list_orphan_choir_mcp_stdio_pids() -> Array[Int]` that walks
    `/proc/*/stat` + `/proc/*/cmdline` on Linux, filters to processes
    whose cmdline contains `choir` AND `mcp-stdio` AND whose `stat`'s
    PPID field is `1`, returns the PIDs. Stub returns `[]`.
  - `src/bin/choir/init.mbt`: add `init_reap_orphan_mcp_stdio_bridges()`
    invoked from `init_cleanup_recreate_artifacts` (~L126). Body: list
    the orphans, `@sys.kill_pid_best_effort(pid)` each, log one
    moontrace INFO line `"reaped N orphan mcp-stdio bridge(s)"` only when
    `N > 0`.
  - Run unconditionally on `--recreate`; also run on the normal `choir
    init` startup path (orphans shouldn't survive any init).

## Non-Goals

- macOS / non-Linux PR_SET_PDEATHSIG equivalents (kqueue NOTE_EXIT). Stub
  returns success on non-Linux; the init-reaper still handles those platforms
  via the PPID sweep at startup.
- A bridge "self-terminate when UDS unrecoverable" path (option (a) from the
  `choir-8is` bead). The two paths chosen — PR_SET_PDEATHSIG + init reaper —
  cover the observed cases; the server-dies-with-live-parent case is rare
  enough to defer.
- Separate config knobs for the leaf no-handoff watchdog (reuse `worker_*`
  values for v1).
- Reworking the existing kill-watchdog timeout, Root/TL skip, or its
  ReviewOwned-exempt rule. The new no-handoff check runs alongside; it's
  additive and never kills.
- Changing `notify_parent`'s side effects on the `handoff_delivered` map
  (already correct for any agent).
- Touching worker `worker_no_handoff_decision` logic (workers untouched).
- Leaf prompt changes outside the post-fix-push terminal step (no
  rewriting unrelated review-cycle guidance).

## Design

### choir-8c2

`.choir/prompts/profiles/leaf.md` — append a `### Post-fix-push terminal
handoff` subsection right after the existing "Do not exit voluntarily after
file_pr" block. Wording per Goals above. Add a `loader_test.mbt` line
asserting the new key phrases are present (grep-style — e.g. the phrases
"the moment the next poller snapshot shows", "notify_parent --status success
ONCE", "do not enter sleep loops").

`src/server/worker_handoff.mbt`:
- Add `pub fn leaf_no_handoff_decision(role : @types.Role, lifecycle :
  @phase.WorkflowState, gate_ready : Bool, idle_sec : Int64,
  handoff_delivered : Bool, prodded : Bool, stalled_emitted : Bool,
  prod_sec : Int64, escalate_sec : Int64) -> WorkerNoHandoffDecision`.
  Truth-table:
  ```
  if role != Role::Dev:                                 DoNothing
  if !lifecycle_is_review_owned(lifecycle):             DoNothing
  if !gate_ready:                                       DoNothing
  if handoff_delivered:                                 DoNothing
  if prod_sec == 0:                                     DoNothing   # disabled
  if idle_sec < prod_sec:                               DoNothing
  if !prodded && idle_sec >= prod_sec:                  Prod
  if  prodded && !stalled_emitted
              && idle_sec >= prod_sec + escalate_sec:   EmitStalled
  else:                                                 DoNothing
  ```
- Add `pub fn leaf_stalled_no_handoff_prod_message(slug : String) ->
  String` and `pub fn leaf_stalled_no_handoff_parent_message(slug : String,
  idle_sec : Int64, pane_tail : String) -> String`. Reuse the existing
  `worker_no_handoff_pane_tail(screen)` truncator.

`src/server/handler_disconnect.mbt::check_idle_agents` (~L1056): after the
existing Root/TL skip + the `lifecycle_idle_watchdog_exempt` check at ~L1081
(which protects ReviewOwned from KILL), add a parallel no-handoff dispatch
block per agent role:
```
let dec = match agent.role {
  @types.Role::Worker  => worker_no_handoff_decision(...)
  @types.Role::Dev     => {
    let gate_ready = match self.tracked_pr_for_agent(agent_id) {
      Some(tracked) => @poller.tl_tracked_pr_merge_gate_snapshot_ready(
        tracked,
        tracked_unresolved_thread_count_for_gate(tracked),
        review_mode=tracked.review_mode,
      )
      None => false
    }
    leaf_no_handoff_decision(agent.role, current_lifecycle, gate_ready,
      idle_sec, handoff_delivered, prodded, stalled_emitted,
      prod_sec, escalate_sec)
  }
  _ => WorkerNoHandoffDecision::DoNothing
}
match dec {
  Prod        => deliver_prod_into_pane(...)
  EmitStalled => deliver_parent_event(...)
  DoNothing   => ()
}
```
Keep all existing prod / parent-event dispatch code — just point it at the
right message constructor based on role. The Dev branch reuses
`worker_no_handoff_prodded_at` + `worker_no_handoff_stalled_emitted` maps
(they're agent-id-keyed; role is the discriminator in the decision fn, not
the map).

Tests in `src/server/worker_handoff_test.mbt` and/or
`handler_disconnect_test.mbt` / `handler_test.mbt`:
- Pure decision truth table for `leaf_no_handoff_decision` (all branches:
  non-Dev role ⇒ DoNothing; Dev + not-ReviewOwned ⇒ DoNothing; Dev +
  ReviewOwned + !gate_ready ⇒ DoNothing; Dev + ReviewOwned + gate_ready +
  idle<prod_sec ⇒ DoNothing; ... ⇒ Prod ⇒ EmitStalled progression;
  delivered ⇒ DoNothing; prod_sec==0 ⇒ disabled).
- Wiring test: `check_idle_agents` with a ReviewOwned Dev leaf that's
  pane-idle for `prod_sec+escalate_sec` and has `merge_gate_ready=true`
  fires the `[LEAF STALLED AFTER FIX-PUSH]` parent message (mock the runner
  and assert via the delivery-log / pane-watcher seams — no test tautologies;
  assert the actual parent-event message goes out, not just a counter).

### choir-8is

C FFI alongside the existing native helpers (mirror the
`kill_pid_best_effort` / `pid_is_alive` pattern in `src/sys/stub.c` or
equivalent):
```c
#include <sys/prctl.h>
#include <signal.h>
int choir_set_parent_death_signal_term(void) {
  return prctl(PR_SET_PDEATHSIG, SIGTERM, 0, 0, 0);
}
```

`src/sys/io.mbt` (native):
`pub fn set_parent_death_signal_term() -> Bool` — FFI call, returns true
on success.
`src/sys/io_stub.mbt` (wasm/js): returns `false`.

`src/sys/io.mbt` (native):
`pub fn list_orphan_choir_mcp_stdio_pids() -> Array[Int]` — walks
`/proc/<pid>/stat` + `/proc/<pid>/cmdline`, filters to processes whose
cmdline matches both `choir` and `mcp-stdio` AND whose PPID is `1`. Returns
the PIDs. Implement via straightforward `readdir`/`read` (no shelling out
to `ps`). Stub returns `[]`.

`src/bin/choir/mcp_mode.mbt` (the `mcp-stdio` entrypoint): at the very top
of the run loop, call `ignore(@sys.set_parent_death_signal_term())` before
any I/O. Log TRACE on failure (use `@moontrace.trace`); continue.

`src/bin/choir/init.mbt`: add a private fn
`init_reap_orphan_mcp_stdio_bridges()` invoked from
`init_cleanup_recreate_artifacts` (~L126):
```
fn init_reap_orphan_mcp_stdio_bridges() -> Unit {
  let orphans = @sys.list_orphan_choir_mcp_stdio_pids()
  for pid in orphans {
    @sys.kill_pid_best_effort(pid)
  }
  if orphans.length() > 0 {
    @moontrace.info("reaped orphan mcp-stdio bridges",
      fields=[@moontrace.field("count", orphans.length())])
  }
}
```
Invoke it unconditionally on both `--recreate` and the normal `init` path.

Tests:
- Pure-function test for the orphan-detection logic. Inject a mock
  process-table capability if the native impl resists mocking (follow the
  existing dispatch-injection pattern with an optional `list_pids?` param
  + default).
- Wiring test asserts `init_cleanup_recreate_artifacts` invokes the reaper
  exactly once and SIGTERMs each returned PID. Mock the kill so no real
  processes die in tests.

No `@sys.*`/`@process.*` direct calls in `src/server`/`src/tools`/`src/poller`
beyond existing adapter seams; the new sys helpers are exposed via
`@sys.*` but called only from `src/bin/choir/` (the I/O boundary) and
through injected capabilities elsewhere.

## Verify

- `moon test --target native`: `leaf_no_handoff_decision` truth table;
  `check_idle_agents` fires the parent stall event for ReviewOwned +
  gate_ready Dev leaves at the right thresholds (and does NOT fire for
  non-ReviewOwned Dev leaves, workers, or Root/TL — those still use their
  own paths); the reaper is invoked from init and SIGTERMs each orphan;
  orphan detection returns the right PID set given a mocked process table.
  Worker tests unchanged.
- Observable: `grep -A8 "Post-fix-push terminal handoff"
  .choir/prompts/profiles/leaf.md` shows the new section with the three
  key phrases ("the moment the next poller snapshot shows",
  "notify_parent --status success", "do not enter sleep loops");
  `loader_test.mbt` grep coverage stays green.
- Manual smoke (post-merge, optional, document in PR): start a process
  under `choir mcp-stdio --name test-bridge`, kill its parent shell — the
  bridge dies within seconds (Linux PDEATHSIG). Start 3 bridges, kill all
  parents, run `choir init --recreate` — all 3 are reaped, log shows
  `reaped 3 orphan mcp-stdio bridges`. Also: any future
  `fork_wave(automerge, iterative)` wave with a Copilot fix-push cycle
  produces a `notify_parent` from the leaf within seconds of fix-push
  (not minutes), via the prompt change.

## Boundary (do not)

- The no-handoff prod/parent-event for leaves fires ONLY for `Role::Dev`
  AND `lifecycle is ReviewOwned` AND `merge_gate_ready == true`. Never for
  non-ReviewOwned Dev leaves (still implementing — the regular watchdog
  territory). Never for Root/TL (already skipped). Never for Workers
  (handled by `worker_no_handoff_decision`).
- The existing kill-watchdog's ReviewOwned-exempt rule stays — no kill.
  The no-handoff path NEVER calls `fail_agent_with_runner` or anything
  that terminates the leaf; it only prods + emits parent events.
- `worker_no_handoff_decision` and worker prod/parent paths are NOT
  modified; worker behavior is identical to today.
- The PR_SET_PDEATHSIG call is fire-and-forget; failure is logged TRACE
  and does not block the bridge from running. Non-Linux platforms get a
  no-op stub.
- The init reaper targets ONLY processes whose cmdline matches BOTH
  `choir` AND `mcp-stdio` AND whose PPID is exactly `1`. Never broader,
  never by name alone. Verify both predicates before issuing SIGTERM.
- The reaper uses SIGTERM (not SIGKILL); the bridge's PR_SET_PDEATHSIG
  delivers SIGTERM too — give the bridge a chance to clean up.
- Use the `Role` and `WorkerNoHandoffDecision` enums (not strings);
  `ChoirError` for new error paths.
- All tests hermetic — mock the process-table, the kill, the runner, the
  delivery seams. No real-checkout/repo-git/process mutation.

## Follow-Ups

- macOS (and other non-Linux) PR_SET_PDEATHSIG equivalent (kqueue
  NOTE_EXIT) — needed if/when Choir starts to support macOS as a
  first-class platform.
- The "bridge self-terminates when UDS connection to a now-dead server is
  unrecoverable" path (option (a) from `choir-8is`'s three options) —
  handles the server-dies-with-live-parent edge case that the reaper +
  PDEATHSIG don't cover. Defer until observed.
- Per-leaf no-handoff config knobs distinct from worker's — defer until
  observed needing different timing for leaves vs workers.
- A typed MCP `[LEAF STALLED AFTER FIX-PUSH]` event — a structured-data
  follow-up so the TL gets a typed signal, not just prose. Mirrors the
  same follow-up filed against the worker equivalent.
