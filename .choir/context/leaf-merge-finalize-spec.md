# Spec: leaf-merge-finalize

## Context

When the per-HEAD automerge sweep (shipped in PR #343) fires `merge_pr` for an
iterative-review Dev leaf and merge succeeds on GitHub, the leaf's lifecycle
does NOT transition out of `ReviewOwned`. Observed live on PR #346
(2026-05-16):

- `gh` reports the PR as MERGED (HEAD `793a3e1`).
- `wave_state` shows the leaf still `agent_state: active`, workflow
  `Dev / ReviewOwned / OpenUnreviewed-346`.
- The TL never received `[PR MERGED]`.
- `kill_agent` REFUSED with `target is supervisor` via
  `is_supervisor_role(agent.role)` (`src/tools/shutdown.mbt:141-146`), even
  though the leaf is `Role::Dev`.
- `send_message [PARENT RELEASE]` was accepted; lifecycle moved
  `ReviewOwned → ExitRequestedDeferred`, but the
  `ExitRequestedDeferred → Exited` transition is gated on PR not being
  `OpenUnreviewed` — so it deadlocks on the same stale state.
- Only `pkill -f main.server-audit-gh-fallback-0` worked.

Initial recon (2026-05-16) confirmed the sweep DOES route through
`handle_with_runner_and_capture` → `plan_post_tool_actions`
(`src/server/handler_automerge.mbt:293`,
`src/server/handler.mbt:170`). So the finalize chain is wired; something
inside the chain isn't identifying the LEAF for finalize. Suspect: the
synthetic merge_pr's `caller_id` is the TL/parent (from
`automerge_parent_caller_id_for_tracked_pr`), and `plan_post_tool_actions`
may key the finalize on the caller rather than `tracked.agent_id`. The first
implementation step is investigating this and fixing the actual bug.

Observable outcome: after the sweep merges a Dev leaf's PR, within one
poller tick the TL receives `[PR MERGED]`, the leaf's workflow advances to
a terminal state (`Done(Merged)` / equivalent), its bridge process exits
cleanly, and its zellij pane closes. `kill_agent` against a `Role::Dev` /
`Role::Worker` agent never refuses with `target is supervisor`. A
`Role::Dev` leaf that calls `notify_parent` / receives `[PARENT RELEASE]`
exits cleanly even if its tracked-PR snapshot is briefly stale.

## Clarifications
> Q&A from the crystallize step. Durable; leaves read this.

**Q: How should the sweep's `merge_pr` success route to the
leaf-finalize / `[PR MERGED]` path?**
A: Investigate first — `maybe_trigger_automerge_for_pending_event` already
calls `state.handle_with_runner_and_capture`, which calls
`plan_post_tool_actions` (initial recon confirmed). Either
`plan_post_tool_actions` doesn't identify the LEAF agent in the
synthetic-caller case, or the finalize effects fire but don't reach the
leaf for some other reason. **Step 1 of the implementation is tracing
`maybe_trigger_automerge_for_pending_event` → `handle_with_runner_and_capture`
→ `plan_post_tool_actions(merge_pr, ...)`** and pinpointing why
`plan_finalize(leaf_agent, ..., ExitReason::Merged)` doesn't fire (or
fires but targets the wrong agent). Step 2 is the focused fix grounded in
what the trace finds — likely either pass `tracked.agent_id` through the
post-tool-actions path so it finalizes the leaf (not the caller), or
centralize a sweep-aware finalize that reuses the existing
`plan_finalize(agent, lifecycle, ExitReason::Merged)` machinery.

**Q: Scope: just the root cause, or root cause + defensive widening of
the downstream consumers?**
A: Both — root cause + defenses on `kill_agent` and
`ExitRequestedDeferred`. (i) `kill_agent`'s `is_supervisor_role` check
should only refuse `Role::Root` / `Role::TL` targets; `Role::Dev` /
`Role::Worker` leaves must always be killable regardless of lifecycle.
Investigate why the check fired for a `Role::Dev` leaf — there's either
stale role data in the registry for ReviewOwned-holding agents, or the
check is consulting something other than `agent.role`. (ii)
`ExitRequestedDeferred → Exited` must not deadlock on a stale
`OpenUnreviewed` snapshot: if the leaf is genuinely requesting exit AND
the PR is actually merged on GitHub (or the tracked PR state has been
updated to Merged via the root-cause fix), the transition succeeds.
Belt-and-suspenders: any future stale-state surprises don't strand
leaves.

**Q: How should the leaf-finalize handle the case where the sweep's
`merge_pr` fails (transient `gh` hiccup)?**
A: No finalize on failure; retry next HEAD. If the sweep's `merge_pr`
returns an error, DO NOT emit `[PR MERGED]` and DO NOT finalize the
leaf. The existing per-HEAD-sweep guard (`last_automerge_attempt_sha`)
already prevents retry-spam; the leaf stays in `ReviewOwned` until the
next HEAD push OR a successful sweep on a later tick. Matches today's
behavior for transient failures; never finalizes a leaf whose PR isn't
actually merged.

## Goals

### Root cause — sweep success transitions the leaf

- **Step 1 (investigation)**: trace
  `maybe_trigger_automerge_for_pending_event` →
  `state.handle_with_runner_and_capture(automerge_merge_pr_request(...))` →
  `plan_post_tool_actions(merge_pr_req, ..., resp)`. Pinpoint why the merge
  success path does not result in `plan_finalize(leaf_agent, ...,
  ExitReason::Merged)` firing for the LEAF agent (`tracked.agent_id`).
  Document the finding in the PR body. Concrete suspects:
  - The synthetic merge_pr's `caller_id` is the TL/parent (from
    `automerge_parent_caller_id_for_tracked_pr` at
    `src/server/handler_automerge.mbt:~160`), so
    `plan_post_tool_actions` may key finalize on the caller instead of
    `tracked.agent_id`.
  - The `plan_post_tool_actions` merge_pr case at `src/server/post_tool.mbt:283-296`
    (`@types.ExitReason::Merged` path) may require an `agent` lookup that
    doesn't find the leaf when the caller is the TL.
  - The internal-request dispatch in `handle_with_runner_and_capture` may
    skip post-tool actions for non-MCP-originated calls.

- **Step 2 (fix grounded in the trace)**: the focused change to ensure
  `plan_finalize(leaf, ExitReason::Merged)` fires on sweep success. Likely
  either:
  - thread `tracked.agent_id` (the leaf) into the post-tool-actions chain
    for synthetic-caller merge_pr so the finalize keys on the leaf, OR
  - if post-tool-actions cannot be made caller-aware here, have the sweep
    explicitly invoke `plan_finalize(leaf_agent, lifecycle,
    ExitReason::Merged)` + emit `[PR MERGED]` after a successful
    `handle_with_runner_and_capture` response, reusing the same effect
    interpreters (`interpret_teardown_effects`).
  - Whatever path is chosen, the result must match what the event-path
    merge ([MERGE READY]-driven) already does today for leaves: emit
    `[PR MERGED]` to the leaf's parent, run `plan_finalize` for the leaf
    with `ExitReason::Merged`, which produces `CloseTerminal +
    ClearRuntimeTracking + ...` effects.

- **No finalize on failure**: if the sweep's merge_pr returns non-Ok, log
  via the existing delivery-log line (`automerge result pr=N status=...`)
  and leave the leaf in `ReviewOwned`. The existing
  `last_automerge_attempt_sha` guard prevents retry-spam on the same HEAD;
  next HEAD push (or other transition) gets another attempt.

### Defense — `kill_agent` and `ExitRequestedDeferred`

- **`kill_agent` role guard** (`src/tools/shutdown.mbt:141-146`):
  investigate why `is_supervisor_role(agent.role)` fired for a `Role::Dev`
  leaf. Either the registry has bad role data for ReviewOwned-holding
  agents, or the check looks at something other than `agent.role`. Fix
  the root cause if it's stale-role; otherwise tighten the check so
  ONLY `Role::Root` and `Role::TL` can produce the refusal. `Role::Dev`
  and `Role::Worker` must always be killable. Update the existing comment
  block at `shutdown.mbt:~137` to reflect the invariant.

- **`ExitRequestedDeferred → Exited`**: identify the transition (look in
  `src/phase/lifecycle.mbt:431` and `src/phase/service.mbt:79-103` where
  `ExitRequestedDeferred` is handled). Ensure that when the leaf has
  requested exit AND the tracked PR state is Merged OR the leaf's
  PR-not-OpenUnreviewed predicate evaluates true, the transition succeeds.
  The root-cause fix above makes this correct via the state update; this
  goal documents that the transition machinery should also be robust to
  the "PR just merged but state hasn't quite caught up" race window.

### Cross-cutting

- Tests must cover all three failure-mode cases:
  - Sweep merge succeeds ⇒ `[PR MERGED]` event observed at the leaf's
    parent, leaf workflow transitions to a terminal state (`Done(Merged)`
    or equivalent), `ClearRuntimeTracking` and `CloseTerminal` effects
    fire.
  - `kill_agent` on a `Role::Dev` leaf in `ReviewOwned` state ⇒ succeeds
    (no `target is supervisor` refusal); same for `Role::Worker`. `kill_agent`
    on `Role::Root` / `Role::TL` ⇒ still refused as today.
  - `ExitRequestedDeferred → Exited`: leaf requests exit + tracked PR is
    Merged ⇒ transition succeeds.

## Non-Goals

- Re-running gh-side merge cleanup (branch delete, etc.) — those go
  through `merge_pr`'s existing post-success path which the sweep's
  internal dispatch already invokes. We are not duplicating that work.
- Changing `merge_pr`'s preflight or gate logic. The sweep's invocation
  already passes gate evaluation; the bug is purely in the post-success
  / finalize path.
- Refactoring `plan_post_tool_actions`'s general structure. We're
  ensuring the finalize fires for the LEAF in the synthetic-caller case;
  not redesigning how post-tool actions resolve agents in general.
- Touching the event-path merge ([MERGE READY] event-driven) — it
  already works correctly; we're bringing the sweep up to parity.
- Server-side merge of a PR that isn't tracked by the poller — out of
  scope here; sweep only acts on tracked PRs.
- A new `request_kill` MCP tool or alternate kill path — `kill_agent`
  stays the canonical entrypoint; we widen its role guard, not replace
  it.

## Design

### Investigation step (mandatory first)

Trace from
`src/server/handler_poll_delivery.mbt::sweep_tracked_prs_for_automerge`
(~L1545-1604):

```
sweep_tracked_prs_for_automerge
  → maybe_trigger_automerge_for_pending_event (handler_automerge.mbt:206)
    → state.handle_with_runner_and_capture (handler.mbt:93)
      → ... → plan_post_tool_actions (post_tool.mbt:416)
        → plan_finalize (post_tool.mbt:79)  [if ExitReason::Merged]
```

Concrete question to answer: in `plan_post_tool_actions` for `req.name ==
"merge_pr"` (the success branch around `post_tool.mbt:283-296`), which
agent does it look up for `plan_finalize`? The caller (`caller_id`) or
the merged PR's owning agent (the leaf, via `tracked.agent_id` or some
lookup from the PR number)? If the caller — that's the bug: the sweep's
synthetic caller is the TL/parent, so finalize keys on the wrong agent.

Verify and document the answer in the PR body's "Root cause" section
before writing the fix.

### Root-cause fix

Based on the investigation. Two likely shapes:

**Shape A**: thread `tracked.agent_id` through the post-tool-actions
chain for synthetic merge_pr. E.g. add a `target_agent_id : String?`
field to the `merge_pr` request args (or to a server-internal companion
struct that flows alongside the request) so `plan_post_tool_actions` can
finalize the named target, not just the caller. The event-path merge
would set `target_agent_id` to the leaf's agent_id (resolved from the
event's pr_number → tracked.agent_id); the sweep already has
`tracked.agent_id` in scope at the sweep loop. Defaults to `None`, in
which case the current caller-based finalize behavior is preserved
for non-merge_pr post-tool actions.

**Shape B**: have the sweep explicitly invoke finalize after a successful
`handle_with_runner_and_capture` response. After
`resp.is_ok()`, the sweep looks up the leaf agent via
`state.registry.get(tracked.agent_id)`, retrieves its lifecycle, calls
`plan_finalize(leaf, lifecycle, ExitReason::Merged, notify_parent=true)`,
and applies the resulting effects via `interpret_teardown_effects`.
Reuses the existing finalize machinery; doesn't touch
`plan_post_tool_actions`.

Pick whichever the investigation step shows is correct (or both, if the
event-path already does Shape A but the sweep skipped it for unrelated
reasons). Document the choice in the PR body.

### Defense — `kill_agent` role guard

`src/tools/shutdown.mbt:141-146` — `is_supervisor_role(agent.role)`.
Investigate by running the existing failing scenario (Dev leaf in
ReviewOwned, attempt kill_agent), instrumenting the role read with a
TRACE log. If `agent.role` reads as `Root` / `TL` for a leaf we registered
as `Dev`, there's stale role data — find where the role gets mutated
(possibly during `ExitRequestedDeferred` transition? the spawn_worker
elevation path? the synthetic Root caller from PR #346?). Fix the
mutation site.

If the role data is actually correct as `Dev` and the check is
mis-firing, then `is_supervisor_role` may be referenced through some
other path. Confirm definitively, then ensure the refusal only fires
for `Role::Root` / `Role::TL` targets. `Role::Dev` and `Role::Worker`
must always pass the check.

### Defense — `ExitRequestedDeferred → Exited`

`src/phase/service.mbt:79-103` + `src/phase/lifecycle.mbt:431` — the
`ExitRequestedDeferred` handler. The transition should succeed when the
leaf has requested exit AND (the tracked PR is Merged OR the
PR-not-OpenUnreviewed predicate evaluates true). If the root-cause fix
above makes the tracked PR state update to Merged on sweep success, this
defense becomes mostly redundant — but keep it as a belt-and-suspenders
for the brief race window between "merge_pr returns Ok on GitHub" and
"tracked PR state is updated to Merged in choir's view."

### Tests

- `src/server/handler_poll_delivery_test.mbt` or
  `src/server/handler_test.mbt`: a Dev leaf in `ReviewOwned`, tracked PR
  with `merge_gate_ready=true`, sweep tick, mocked merge_pr success
  response. Assert: `[PR MERGED]` delivered to the leaf's parent via the
  mocked delivery seam; leaf's workflow transitions to terminal state;
  ClearRuntimeTracking effect fires for the leaf's agent_id.
- `src/tools/shutdown_test.mbt`: `kill_agent` on Dev leaf in
  `ReviewOwned` succeeds (no `target is supervisor` refusal). Same for
  Worker. Root and TL still refused.
- `src/phase/*_test.mbt`: `ExitRequestedDeferred → Exited` transition
  succeeds when tracked PR is Merged.
- Negative: sweep's merge_pr returns Err ⇒ no `[PR MERGED]` emitted, no
  finalize, leaf stays in `ReviewOwned`, `last_automerge_attempt_sha`
  updated.

Boundary: tests hermetic — mock the gh capture seam, the runner, and the
parent-delivery seam. No real-checkout / repo-git / network mutation.

## Verify

- `moon test --target native`: all new + existing tests pass. Test count
  should grow by ≥4 covering the cases above.
- Observable (PR body, smoke): on the next `fork_wave(automerge,
  iterative)` Dev leaf wave — after the sweep merges the PR,
  `wave_state` shows the leaf at a terminal workflow state (NOT
  `ReviewOwned`, NOT `ExitRequestedDeferred`); `choir logs --grep "PR
  MERGED"` shows the parent-delivered event for that PR; `ps -ef | grep
  "choir mcp-stdio.*<agent_id>"` returns nothing within seconds of the
  merge.
- `grep -c "is_supervisor_role" src/tools/shutdown.mbt` ⇒ unchanged
  count, but the refusal-message context comment makes the
  Dev/Worker-always-killable invariant explicit.

## Boundary (do not)

- The leaf-finalize path on sweep success must NOT fire for a non-Ok
  merge_pr response (transient gh failure). The leaf stays in
  `ReviewOwned` and the `last_automerge_attempt_sha` guard prevents
  retry-spam on the same HEAD.
- The `kill_agent` widening must not weaken the Root/TL guard (the
  choir-eek protection). Those roles still refuse. Only `Role::Dev` and
  `Role::Worker` move from "refused" to "always killable."
- No `@sys.*` / `@process.*` direct calls in `src/server` / `src/tools` /
  `src/phase` beyond existing adapter seams.
- Use the `Role`, `ExitReason`, `FinalizeReason` enums (not strings);
  `ChoirError` for new error paths.
- All tests hermetic — mock the runner, capture, parent delivery,
  registry seams. No real process mutation, no real-checkout edits.
- Do not change `merge_pr`'s gate logic, preflight, or success-path
  cleanup (branch delete etc). The bug is in finalize, not merge.
- Do not touch the event-path merge — it works correctly and is the
  reference behavior the sweep should match.

## Follow-Ups

- If the investigation reveals a class of post-tool-actions bugs (not
  just merge_pr), file separately. This bead is the specific leaf-merge
  case.
- `choir-cfw` (completion-chime) — the UX-layer notification that
  composes with this fix; once `[PR MERGED]` reliably fires, a user-side
  `notify-send` hook is straightforward.
- A separate bead if the `is_supervisor_role` investigation reveals a
  systemic role-mutation bug (e.g. ReviewOwned silently mutates role).
- Consider whether the sweep should also handle non-Merged terminal
  outcomes (e.g. PR closed without merging) — out of scope; sweep only
  acts on `MergeNow` gate decisions.
