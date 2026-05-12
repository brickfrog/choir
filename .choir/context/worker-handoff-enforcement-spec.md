# Spec: worker-handoff-enforcement

## Context

A `spawn_worker` research/review worker can finish its task, print its full
report to stdout, and then *idle* — never calling `notify_parent` or `shutdown`.
The parent (TL) cannot read worker stdout; the worker's `notify_parent` IS the
handoff (the `/audit` skill literally says "Wait for the worker to return"), so
the TL waits forever — until the 5-minute idle-kill watchdog eventually reaps the
worker, which gives the TL nothing useful. Observed repeatedly with codex
Sarcasmotron review workers (this session and the dere-project PR-146 case). The
worker treats the printed report as the handoff. We want: (1) worker prompts that
make `notify_parent` → `shutdown` an unmissable terminal sequence, and (2) a
server-side safety net so a worker that produces output but never notifies gets
prodded, and — failing that — the TL gets a `[WORKER STALLED — no handoff]` (or
`[WORKER EXITED WITHOUT NOTIFY]`) event with the worker's pane tail, well before
the kill-watchdog fires. Observable outcome: a worker that finishes and idles is
either nudged into notifying within ~2 min, or the TL is told about it (with the
report text from the pane) instead of hanging.

## Clarifications
> Q&A from the crystallize step. Durable; leaves read this.

**Q: How far should the enforcement go beyond prompt-hardening?**
A: Prompt + parent-event + worker-prod. Harden the worker prompts and the
`/audit` skill template; AND server-side: when a watched worker has been pane-idle
for the no-handoff timeout without having recorded a `notify_parent` call, the
server (a) sends a prod into the worker's pane ("you produced output but never
called notify_parent — do it now, then shutdown"), and if it's still idle after a
grace window, (b) emits a `[WORKER STALLED — no handoff]` event to the worker's
parent with the worker's pane tail. The same parent-event (as `[WORKER EXITED
WITHOUT NOTIFY]`) also fires if the worker's connection closes or the kill-
watchdog reaps it while it has never notified.

**Q: Should this also cover dev (leaf) agents, or just spawn_worker workers?**
A: Workers only (`Role::Worker`). Dev leaves have `file_pr` auto-notify and the
existing disconnect/PR-recovery path; a stronger leaf terminal-sequence
enforcement is a follow-up (it overlaps the `choir-8z1` follow-up about leaves
emitting a structured verify signal).

**Q: What idle timeout triggers the no-handoff path, relative to the existing
5-min kill-watchdog?**
A: A separate, shorter "no-handoff" timeout (~2 min / 120s of pane-idle with no
`notify_parent` recorded), configurable, that fires well before the 5-min idle-
kill watchdog — so the worker gets prodded and/or the TL hears about it while
there's still time to recover, not after the worker is already dead.

## Goals

- **Prompt hardening.** `.choir/prompts/profiles/worker-research.md` and
  `.choir/prompts/profiles/worker-review.md` are rewritten so the terminal
  sequence is the *first* thing the "When you are done" section says and is
  framed as mandatory and failure-defining: e.g. *"Your printed report is NOT the
  handoff — the parent cannot read your stdout. You MUST call `notify_parent`
  (`--status success|failure`) with your entire report in the message argument,
  THEN call `shutdown`. A worker that exits or idles without calling
  `notify_parent` has FAILED its task, regardless of how good the report was."*
  `.choir/prompts/skills/audit.md` (and, if the live `/audit` skill text is
  sourced elsewhere — check `.choir/plugin/skills/audit/SKILL.md`) gets the same
  hard sentence in the `spawn_worker` task template. (`src/prompts/loader.mbt`
  loads these markdown files — no `loader.mbt` logic change needed unless a new
  profile/section is introduced; keep `loader_test.mbt` green.)
- **Server tracks "has this agent notified its parent".** When a `notify_parent`
  tool call is handled for an agent, the server records that agent as
  "handoff-delivered" (a `Set[AgentId]` in `ServerState`, or equivalent — do not
  require an `Agent` struct field / registry-schema change if a server-side set
  works). Cleared/irrelevant once the agent is gone.
- **No-handoff prod (workers only).** On the existing watchdog tick, for each
  watched agent with `role == Role::Worker` that is NOT in the handoff-delivered
  set: if it has been pane-idle ≥ `worker_no_handoff_prod_sec` (default ~120s)
  and has not yet been prodded, send a one-shot message into its pane: *"You
  appear finished but have not called `notify_parent` — your printed output is
  not the handoff. Call `notify_parent --status success|failure '<your full
  report>'` now, then `shutdown`."* Record that it was prodded (so it's not
  re-prodded every tick).
- **`[WORKER STALLED — no handoff]` to the parent.** If a prodded worker is still
  pane-idle and still not in the handoff-delivered set after a further grace
  window (`worker_no_handoff_escalate_sec`, default ~120s after the prod), emit
  one `[WORKER STALLED — no handoff]` event to the worker's parent via the
  existing parent-delivery path (`durable_deliver_to_parent` /
  `durable_deliver_to_agent`), including the worker's slug, the elapsed idle
  time, and a tail of the worker's pane screen (the same `dump-screen` content
  the idle check already captures). Emit at most once per worker.
- **`[WORKER EXITED WITHOUT NOTIFY]` to the parent.** When a worker's connection
  closes (disconnect handler) or the 5-min kill-watchdog reaps a worker, and that
  worker is not in the handoff-delivered set, emit one `[WORKER EXITED WITHOUT
  NOTIFY]` event to the worker's parent with the worker's pane tail (best effort —
  if the pane is already gone, send without it). This must not fire for a worker
  that *did* notify (clean handoff then exit is normal).
- **Config knobs.** `worker_no_handoff_prod_sec` and
  `worker_no_handoff_escalate_sec` live alongside the existing watchdog timeout
  config (wherever `idle_timeout` / the 5-min watchdog value is configured), with
  the ~120s/~120s defaults; `0` disables that step. The existing 5-min kill-
  watchdog behavior is unchanged.

## Non-Goals

- Dev (`Role::Dev`) leaves — no new stall-detection or parent-event for leaves
  (they have `file_pr` auto-notify + disconnect/PR-recovery). Follow-up.
- Changing the 5-min idle-kill watchdog timeout, its Root/TL skip, or its
  ReviewOwned-exempt rule. We *add* a shorter worker-only no-handoff check; we
  don't touch the kill path's existing logic (beyond the exit-without-notify
  parent-event hook).
- Making `notify_parent` itself blocking/mandatory at the protocol level for
  workers (we prod + tell the parent; we don't, say, refuse `shutdown` until
  `notify_parent` has been called — a worker that *fails* still needs to be able
  to bail).
- The `worker-notify-missing-config` gap (workers failing `notify_parent` because
  `spawn_worker` didn't write `.choir/config.local.toml`) — that's a separate
  config-write bead; this spec assumes `notify_parent` *works* when called.
- Re-running anything / verify signals — unrelated.

## Design

**Prompt markdown (no MoonBit logic):**
- `.choir/prompts/profiles/worker-research.md`, `.choir/prompts/profiles/worker-review.md`:
  move the terminal sequence to the top of "When you are done", reword per Goals.
- `.choir/prompts/skills/audit.md` and (if it's the live source)
  `.choir/plugin/skills/audit/SKILL.md`: add the hard "report ≠ handoff; you MUST
  notify_parent then shutdown; exiting/idling without notify_parent = FAILED"
  sentence into the `spawn_worker` task template (step 2) AND keep step 3 ("Wait
  for the worker to return") as-is.

**Server (the safety net) — likely files:**
- `src/server/handler_disconnect.mbt` — `ServerState::check_idle_agents` already
  iterates `pane_watcher.watched_agents()` on the tick. Add, before/after the
  existing kill check, a worker-only no-handoff branch: skip unless `role ==
  Role::Worker`; consult the handoff-delivered set; compare idle time against
  `worker_no_handoff_prod_sec` then `…_escalate_sec`; track per-worker "prodded"
  and "stalled-event-emitted" state in `ServerState` (sets keyed by `AgentId`).
  Also: in the disconnect path (`handle_disconnect_*` / wherever a worker's
  connection-close is finalized) and at the watchdog-kill point, if the worker is
  not handoff-delivered, fire `[WORKER EXITED WITHOUT NOTIFY]` to the parent.
- The `notify_parent` handler path — `src/tools/dispatch.mbt`
  (`ToolRequest::NotifyParent` arm) and/or `src/tools/messaging.mbt` /
  `src/tools/notify_parent_*` — needs a hook so the server marks the caller as
  handoff-delivered. If the dispatch arm doesn't have a clean seam to
  `ServerState`, add one (the existing pattern of injecting capabilities into
  dispatch applies). Mark on a *successful* `notify_parent` (or even an attempted
  one — a worker that called `notify_parent` and then `shutdown` is the happy
  path; we only care that it tried to hand off).
- Parent delivery: reuse `ServerState::durable_deliver_to_parent` /
  `durable_deliver_to_agent` (the same mechanism `[NOTIFY BLOCKED]` / poller
  events use) for both new events. Message format: `[WORKER STALLED — no
  handoff] <worker_slug> idle <N>s after producing output and never called
  notify_parent. Pane tail:\n<screen tail>` and `[WORKER EXITED WITHOUT NOTIFY]
  <worker_slug> exited/killed without calling notify_parent. Last pane:\n<tail>`.
- Pane tail: the idle check already does a `dump-screen` (hash compare); surface
  the screen text it captured (or do a `zellij action dump-screen` against the
  worker's `terminal_target` at event time). Truncate to a sane size (e.g. last
  ~2KB / ~40 lines).
- Pure-extractable bits to test without a live server: the decision function
  ("given role, idle_sec, handoff_delivered?, prodded?, stalled_emitted?,
  prod_sec, escalate_sec → {DoNothing | Prod | EmitStalled | (kill as before)}"),
  the message formatting, and the pane-tail truncation. Mirror the existing
  `check_idle_agents` test style.

**Config:** add `worker_no_handoff_prod_sec` / `worker_no_handoff_escalate_sec`
to the config struct next to the watchdog timeout (`src/config/*` /
`src/types/*`), with defaults ~120/~120 and `0 ⇒ disabled`; thread into
`check_idle_agents`'s call site.

No `@sys.*` / `@process.*` direct calls in `src/server` / `src/tools` beyond the
adapters already in use there (the `dump-screen` / pane-send already go through
the existing zellij-action seam).

## Verify

- `moon test --target native` — unit tests for: the no-handoff decision function
  (Worker + idle≥prod_sec + not-delivered + not-prodded ⇒ Prod; +already-prodded
  + idle≥escalate_sec + no stalled-event-yet ⇒ EmitStalled; delivered ⇒
  DoNothing; non-Worker role ⇒ DoNothing for this path; prod_sec==0 ⇒ disabled);
  the parent-event message formatting; pane-tail truncation; the handoff-delivered
  set is populated on a `notify_parent` call and consulted by the decision; the
  disconnect/kill path emits `[WORKER EXITED WITHOUT NOTIFY]` only when not
  delivered. Keep `loader_test.mbt` and the audit-skill / prompt tests green
  after the markdown edits.
- Observable: `grep -A3 "When you are done" .choir/prompts/profiles/worker-review.md`
  shows the hard "report is NOT the handoff … FAILED" sentence as the lead line;
  `grep "report.*not.*handoff\|MUST.*notify_parent" .choir/prompts/skills/audit.md`
  matches. (A live end-to-end "spawn a worker that doesn't notify and watch the
  prod arrive" smoke is reasonable to *describe* in the PR but not required as an
  automated test — keep tests hermetic.)
- Manual smoke (post-merge, document in PR, optional): `spawn_worker` a trivial
  research task whose prompt is overridden to "print 'done' and do nothing else";
  within ~2 min a prod message appears in the worker pane; if still ignored,
  `choir logs --grep "WORKER STALLED"` shows the parent event.

## Boundary (do not)

- Do not change the 5-min idle-kill watchdog's timeout, its Root/TL skip, or its
  ReviewOwned-exempt rule. The new no-handoff check is additive and worker-only.
- The no-handoff prod / `[WORKER STALLED]` / `[WORKER EXITED WITHOUT NOTIFY]`
  paths must apply ONLY to `role == Role::Worker`. Never prod or emit these for
  Root/TL/Dev agents.
- Never fire `[WORKER EXITED WITHOUT NOTIFY]` for a worker that did call
  `notify_parent` (handoff-then-exit is the normal happy path).
- Emit the prod at most once per worker; emit `[WORKER STALLED]` at most once per
  worker; emit `[WORKER EXITED WITHOUT NOTIFY]` at most once per worker.
- Do not make `shutdown` (or anything else) refuse to proceed because
  `notify_parent` wasn't called — a failed worker must still be able to exit.
- `worker_no_handoff_prod_sec == 0` (or `…_escalate_sec == 0`) must fully disable
  that step — no prod / no stalled-event — leaving today's behavior.
- No `@sys.*` / `@process.*` direct calls in `src/server` / `src/tools` outside
  the existing adapter seams.
- Don't touch `Role::Dev` leaf prompts or the `file_pr` auto-notify flow.

## Follow-Ups

- Apply an analogous "produced work but no terminal handoff" safety net to dev
  leaves (a leaf that fails before `file_pr`, or finishes and idles) — overlaps
  the `choir-8z1` follow-up about leaves emitting a structured verify signal.
- `worker-notify-missing-config` — `spawn_worker` should write the worker's
  `.choir/config.local.toml` so `notify_parent`/`shutdown` work cleanly (separate
  config-write gap; this spec assumes they work when called).
- Consider an `mcp__choir__*` typed event for `[WORKER STALLED]` / `[WORKER
  EXITED WITHOUT NOTIFY]` so the TL gets structured data, not just prose (mirrors
  the `wave_state` direction).
- Promote the "report ≠ handoff" rule from prose into a harder mechanism if
  workers keep skipping it even with the strengthened prompt (e.g. the worker's
  `shutdown` handler refusing-with-a-warning the first time if `notify_parent`
  was never called — bounded, one nudge, then allow).
