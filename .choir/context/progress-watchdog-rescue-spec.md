# Spec: progress-watchdog-rescue

## Context
Today's idle watchdog (`src/server/handler_disconnect.mbt:check_idle_agents`)
fires on pane-screen-hash stagnation and kills agents. It exempts
`DevReview`, `DevDone`, `DevFailed`, `DevExitDeferred`, `Exitable`, and
`ChangesRequested` (`src/phase/lifecycle.mbt:lifecycle_idle_watchdog_exempt`).
On 2026-05-16 PR #350 the leaf hit `DevChangesRequested`, pushed one fix
commit, then went inert — almost certainly the codex spark per-model cap
documented in this bead. Process stayed alive, pane screen kept ticking
(status reports), TL parroted the stale poller count, PR sat open
overnight. We want a server-side signal that catches "alive but not
making progress" distinct from "process disconnected" and "pane screen
unchanged", and we want the response to be a market-shaped automatic
rescue with a different agent_type — not another TLDecision imperative
for the hub to dispatch.

## Clarifications

**Q: What primitive signal should the server treat as 'progress' for a leaf?**
A: A new commit pushed to the leaf's branch. Only signal that survives
cap-after-output and other inert-but-alive states. Observable via the
existing poller `last_sha` tracking and `git ls-remote`. Hard to fake.
Matches what the user actually cares about — work landing.

**Q: When progress has stalled past threshold, what should the server do?**
A: Auto-rescue with a different agent_type. Kill the stuck leaf, spawn
a replacement via the existing `interpret_rescue_leaf` path. No TL
involvement for the common case. Market-shaped diversity premium —
captures the retry value the architecture essay describes.

**Q: How should the server choose the agent_type for the rescue?**
A: Hardcoded fallback chain in code, skipping the current type. Order
`[codex, claude, moon_pilot, cursor_agent, gemini]` with current-type
skipped. Predictable, zero state to track, easy to test. Tune the order
based on observed reputation in a follow-up bead.

**Q: Which lifecycle states should the progress watchdog apply to?**
A: Non-exempt states (where the existing watchdog already operates) +
`Dev(ChangesRequested(..))` when fixes have been pushed (i.e. the
poller has seen `fixes_pushed_at > 0` since the most recent review).
Narrow extension; doesn't disturb the existing watchdog's well-tested
exemptions for `Dev(ReviewOwned(..))`, `Dev(Done(..))`,
`Dev(Failed(..))`, `Dev(ExitRequestedDeferred(..))`, `Dev(Exitable)`,
`Dev(WaitingForRedGate)`.

## Goals
- New pure predicate `progress_watchdog_applies(workflow, fixes_pushed_at) -> Bool` in `src/phase/lifecycle.mbt` returning true for non-exempt workflow states, and additionally true for `Dev(ChangesRequested(..))` when `fixes_pushed_at > 0L`.
- New per-agent `last_commit_observed_at_unix : Int64` tracked alongside the existing watchdog state — sourced from the poller's `last_sha` transitions for PR-tracked agents, or a `git ls-remote --heads origin <branch>` capture for pre-PR agents.
- New pure decision function `progress_watchdog_decision(applies, last_commit_at, now, threshold_sec) -> ProgressWatchdogDecision` returning `DoNothing | Rescue` — captures the trigger condition end-to-end as a unit-testable pure function.
- New pure function `pick_rescue_agent_type(current : AgentType) -> AgentType` returning the next type in the hardcoded fallback chain, skipping `current` and wrapping.
- New `ServerState::check_leaf_progress` async tick that runs alongside `check_leaf_no_handoff` / `check_idle_agents`; on `Rescue` decision it calls a wrapped `interpret_rescue_leaf` with the picked agent_type and an auto-generated `new_slug` (e.g. `<current_slug>-r1`, `-r2` on repeat rescues).
- Threshold value defaults to **15 minutes** (`PROGRESS_STALL_SEC = 900`), matching the order of magnitude of the audit budget and well above normal commit cadence. Constant in code; no knob.
- Tests cover: predicate matrix (all DevLifecycle variants × fixes_pushed_at presence), decision function (below/at/above threshold), agent_type chain (rotation, current-skip, wrap), integration test for `check_leaf_progress` with mock rescue invocation.
- Observable: when the watchdog fires, `.choir/delivery.log` contains `progress_watchdog outcome=rescued from=<old_id> to=<new_id> agent_type=<new_type>` and the original leaf is replaced via the standard rescue path.

## Non-Goals
- No change to the existing screen-hash idle watchdog (`check_idle_agents`). Both fire independently.
- No change to `check_leaf_no_handoff` / `check_worker_no_handoff`. New tick is a sibling, not a rewrite.
- No new lifecycle states. `Dev(ChangesRequested(..))` stays as-is; the watchdog uses `fixes_pushed_at` as the auxiliary signal.
- No reputation table. Hardcoded fallback chain only; reputation is a follow-up.
- No per-wave / per-leaf threshold knob. Single constant.
- No prod-then-escalate sequence. Stalled past threshold → rescue. The leaf already had its chance.
- No "warn the TL before rescue" mode. Auto-rescue is the point.
- No wrapper-level cap detection (option (a) in the bead). Server-side observable signal only; wrapper-level cap detection is a follow-up that composes.
- No prompt-side TL hardening (option (c) in the bead). Out of scope; this gate makes it unnecessary for the common case.

## Design

Single vertical-slice leaf. Touches four files; pure logic isolated from the I/O wiring.

### 1. Pure predicates + decision
- `src/phase/lifecycle.mbt`:
  - Add `pub fn progress_watchdog_applies(workflow : WorkflowState, fixes_pushed_at : Int64) -> Bool`:
    - `Dev(Working) | Worker(Working)` → true
    - `Dev(ChangesRequested(..))` → `fixes_pushed_at > 0L`
    - everything else → false (mirrors the inverse of `lifecycle_idle_watchdog_exempt` plus the `ChangesRequested` carve-out)
- New file `src/server/progress_watchdog.mbt`:
  - `pub enum ProgressWatchdogDecision { DoNothing; Rescue }`
  - `pub fn progress_watchdog_decision(applies : Bool, last_commit_at : Int64, now : Int64, threshold_sec : Int64) -> ProgressWatchdogDecision` — pure, returns `Rescue` iff `applies && last_commit_at > 0L && (now - last_commit_at) >= threshold_sec`.
  - `pub fn pick_rescue_agent_type(current : @types.AgentType) -> @types.AgentType` — hardcoded chain `[Codex, Claude, MoonPilot, CursorAgent, Gemini]`, skip `current`, wrap.
  - `pub const PROGRESS_STALL_SEC : Int64 = 900L`

### 2. Per-agent commit tracking
- Add `mut last_commit_observed_at_unix : Int64` field to the agent-watchdog-state struct that already holds `worker_no_handoff_prodded_at`. (If no such per-agent struct exists yet, add a new `Map[String, Int64]` on `ServerState` alongside the existing maps.)
- Poller path (PR-tracked agents): when `last_sha` transitions on a tick, stamp `last_commit_observed_at_unix = now` on the matching entry.
- Pre-PR path (DevWorking without a PR yet): on each watchdog tick, run `git ls-remote --heads origin <branch>` via the existing injected capture, compare to a stored last-observed sha, stamp `now` on transition.

### 3. Watchdog tick (`src/server/handler_disconnect.mbt`)
- Add `pub async fn ServerState::check_leaf_progress(self, agent, lifecycle, fixes_pushed_at, now, capture, rescue_invoker)`:
  1. Compute `applies = progress_watchdog_applies(lifecycle.workflow, fixes_pushed_at)`. Return early if false.
  2. Read `last_commit_at` for this agent from the map populated by Module 2.
  3. Compute `decision = progress_watchdog_decision(applies, last_commit_at, now, PROGRESS_STALL_SEC)`.
  4. On `Rescue`: pick `new_type = pick_rescue_agent_type(agent.agent_type)`, derive `new_slug = <slug>-r<rescue_count + 1>` (count from registry), call `rescue_invoker({ from_agent_id: agent.agent_id, new_slug, agent_type: new_type, task: agent.task })`. Log the outcome line; remove the agent from the watchdog state map so we don't rescue twice.
- Wire `check_leaf_progress` into the tick loop adjacent to `check_idle_agents` and `check_leaf_no_handoff`.

### 4. Rescue invocation adapter
- `rescue_invoker` is a closure passed in from `dispatch.mbt` that calls `interpret_rescue_leaf` with the standard parameters (project_dir, session, runner, capture, registry, etc.). Tests pass a mock invoker that records call args.

### Reused patterns
- `.choir/context/patterns/thread-enum-through-wire.md` — `ProgressWatchdogDecision` and `AgentType` are enums end-to-end; no stringly status.
- The existing `check_leaf_no_handoff` is the structural analog for tick wiring.
- `interpret_rescue_leaf` is reused as-is; we only add a new caller.

### Wiring at call sites
- The server tick loop (where `check_idle_agents` is called) gets one new call to `check_leaf_progress` per agent per tick.
- `dispatch.mbt` constructs the `rescue_invoker` closure with the same project_dir / session / runner / capture / registry the rescue MCP tool already uses.

## Verify
- `moon test --target native` — full suite, zero new warnings.
- New unit tests in `src/phase/phase_test.mbt`:
  1. `progress_watchdog_applies` returns true for `Dev(Working)` regardless of `fixes_pushed_at`.
  2. Returns true for `Dev(ChangesRequested(..))` iff `fixes_pushed_at > 0`.
  3. Returns false for `Dev(ReviewOwned(..))`, `Dev(Done(..))`, `Dev(Failed(..))`, `Dev(ExitRequestedDeferred(..))`, `Dev(Exitable)`, `Dev(WaitingForRedGate)`.
  4. Returns true for `Worker(Working)` and false for `Worker(Done(..))` / `Worker(Failed(..))` / `Worker(Exitable)`.
- New unit tests in `src/server/progress_watchdog_test.mbt`:
  5. `progress_watchdog_decision` returns `DoNothing` below threshold.
  6. Returns `Rescue` at/above threshold when applies=true.
  7. Returns `DoNothing` when applies=false regardless of elapsed.
  8. Returns `DoNothing` when `last_commit_at == 0` (never observed; fail closed to avoid rescuing a fresh leaf with no commit yet).
  9. `pick_rescue_agent_type` rotates: Codex→Claude, Claude→MoonPilot, MoonPilot→CursorAgent, CursorAgent→Gemini, Gemini→Codex (wraps).
- New integration test in `src/server/handler_disconnect_test.mbt`:
  10. End-to-end: stage an agent in `Dev(ChangesRequested(..))` with `fixes_pushed_at=1` and `last_commit_observed_at` past threshold; tick `check_leaf_progress` with a mock `rescue_invoker`; assert invoker was called with expected `new_slug`, `agent_type`, and `from_agent_id`.
  11. Same staging but `Dev(ReviewOwned(..))` (fresh review, no fixes pushed) — assert invoker is NOT called.
- Observable check (per `feedback_spec_hygiene`):
  - Stage two agents — one `Dev(Working)` with a recent commit, one `Dev(ChangesRequested(..))` with `fixes_pushed_at=1` and `last_commit_observed_at = now - 1000s`. Run the tick (via the dispatch handler test harness). `.choir/delivery.log` must contain a `progress_watchdog outcome=rescued from=<id1>` line for the stalled agent only.

## Boundary (do not)
- Do NOT modify `lifecycle_idle_watchdog_exempt`. The new predicate is a *sibling*, not a replacement; the screen-hash watchdog keeps its own exemption rules.
- Do NOT widen `progress_watchdog_applies` to states the user excluded (`DevReview` waiting fresh, `DevDone`, etc.). Author check is exact.
- Do NOT use pane screen hash, tool-call count, or notify_parent text as the progress signal. Commits only. The bead specifically calls this out — screen-hash is exactly the signal that failed last night.
- Do NOT add a config knob for `PROGRESS_STALL_SEC`. Single constant in code.
- Do NOT add a config knob for the rescue agent_type chain. Hardcoded in `pick_rescue_agent_type`.
- Do NOT prod-then-escalate. Decision is binary; rescue is the response.
- Do NOT call `@sys.*` / `@process.*` directly in `src/server/progress_watchdog.mbt` or the new watchdog handler. All git / rescue calls go through injected adapters.
- Do NOT introduce stringly status for the decision. `ProgressWatchdogDecision` is an enum.
- Do NOT leave behind `legacy_*` / `compat_*` shims.
- Do NOT call `rescue_leaf` MCP-style (round-trip through the MCP layer). Call `interpret_rescue_leaf` directly from the server tick via the injected `rescue_invoker`.
- Do NOT mutate the existing `worker_no_handoff_prodded_at` map. New state lives in its own map.
- Do NOT run `choir init` / `choir claude` / anything that spawns zellij from inside the leaf.
- Do NOT rescue the same `from_agent_id` more than once per tick. Clearing the watchdog state on rescue invocation enforces this; the spawned replacement starts with its own fresh entry.

## Follow-Ups
- choir-9z3 (resolve-threads-when-fixed) — after this rescue lands, most "stuck threads" cases resolve as a side effect of the replacement leaf doing the work. Re-evaluate whether 9z3 is still needed; it may become redundant.
- Reputation-driven `pick_rescue_agent_type` — track per-agent_type success/failure rate per task shape, use to order the fallback chain dynamically. Bigger lift; warrants its own bead. Aligns with the per-agent-type capability surface discussed in the architecture re-ponder.
- Wrapper-level cap detection (bead option (a)) — emit a typed `[AGENT CAPPED]` event from each agent's wrapper script. Cleaner than commit-age inference, but per-model. Composes with this watchdog (cap detection can trigger immediate rescue without waiting for the threshold).
- choir-u7v M3 — mirror `[PROGRESS RESCUE]` lifecycle transitions into `.choir/events/*.jsonl` so the dashboard / moontrace shows when the gate fires.
- Per-agent-type capability tracking surfaced in `wave_state` — first-class server state for which type does which task shape well. The architectural reframe discussed; worth its own bead.
