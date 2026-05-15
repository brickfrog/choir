# Spec: leaf-poller-review-snapshot

## Context

Iterative-review leaves call `gh api graphql … reviewThreads` /
`gh api repos/…/pulls/N/reviews` / `…/comments` **directly** during their review
cycle to figure out PR review state and to find thread IDs to resolve. Those
calls hang regularly (exit 124 even under `timeout 30s`); when one does, the leaf
treats "I couldn't check" as "I'm blocked" and bails to `[BLOCKED]` /
`[NOTIFY BLOCKED]`, dragging the TL into resolving threads from its own pane —
even when nothing is actually wrong (Copilot hasn't reviewed yet, 0 threads).
Hit 3× in the choir-7uc wave (PRs #332/#333/#334), in the dere project, and again
this session on PR #341 (the leaf's `resolveReviewThread` mutations hung → the TL
resolved both threads). The poller already delivers a review snapshot into the
leaf's pane on every tick/event (`[CI LATEST HEAD]`/`[COPILOT ISSUE COMMENT]`/
`[FIXES PUSHED]`/`[MERGE READY]` all carry "GitHub review rollup",
"Unresolved inline review threads (GraphQL): N", "GitHub Copilot issue comment
(REST)", CI rollup) — the leaf is making redundant round-trips for state the
server already has. Observable outcome: a leaf in its review cycle never issues a
`gh api graphql reviewThreads` query; it pushes its fixes and the server resolves
the now-outdated Copilot threads on its behalf; a transient `gh` hiccup does not
escalate to the parent.

## Clarifications
> Q&A from the crystallize step. Durable; leaves read this.

**Q: What's the fix shape?**
A: Hybrid — (a) prompt: a timed-out `gh` call is NOT a blocker; the poller
snapshot's "Unresolved inline review threads (GraphQL): N" line (in events the
leaf already receives) is the source of truth; after addressing comments and
pushing, the leaf does NOT call `gh` for threads at all; only `[BLOCKED]` +
`notify_parent` if the snapshot itself shows unresolved threads the leaf cannot
resolve. (c) Server: on the `FixesPushed` poller tick for a `review_mode ==
Iterative` tracked PR, the poller resolves the now-outdated Copilot review
threads on the leaf's behalf (the same `resolveReviewThread` the TL does manually
from its pane). Belt-and-suspenders: even if the server's auto-resolve hiccups,
the leaf waits for the next tick rather than going `[BLOCKED]`.

**Q: How conservative should the server's auto-resolve be?**
A: `isOutdated` threads only — resolve only threads GitHub marks `isOutdated`
(the leaf's fix commit moved/changed that line, the strong signal it addressed
the comment). A still-current (not-outdated) unresolved thread is left for the
leaf (or for `[BLOCKED]` if it genuinely can't resolve it). Copilot never
re-reviews; the merge gate only blocks on the unresolved *count*; a wrongly-
outdated thread that hides a real issue is what the Sarcasmotron audit pass
catches.

**Q: When does the server's auto-resolve run?**
A: On the `FixesPushed` poller tick for `review_mode == Iterative` tracked PRs
only — the targeted moment (new commits after a Copilot review). Single-pass /
non-iterative PRs and PRs with no post-review push are untouched. (If
`review_mode` is not currently plumbed to the poller tick per-PR, plumb it — it's
in the wave/spawn task contract; thread it onto `TrackedPR` or look it up.)

## Goals

- **Poller fetches thread IDs + `isOutdated`, not just a count.** Wherever the
  poller currently obtains the "Unresolved inline review threads (GraphQL): N"
  value (the `unresolved_threads : Int?` plumbed into `tl_decision`), extend the
  GraphQL query / fetcher to return the unresolved threads as
  `[{id, isOutdated}]` and stash them on `TrackedPR` (new
  `mut unresolved_thread_ids : Array[ReviewThreadRef]` or similar; the existing
  count derives from `.length()`). The bounded/timeout/backoff handling stays
  exactly as today (this is the *same* query the poller already runs, just
  selecting two more fields) — a fetch failure leaves the prior snapshot, same as
  now.
- **`review_mode` is known to the poller per tracked PR.** Add `review_mode :
  ReviewMode` to `TrackedPR` (populated when the PR is tracked — `file_pr` /
  `fork_wave` already know the wave's review mode; thread it through), defaulting
  to `Iterative` for PRs tracked without an explicit mode.
- **Server auto-resolves outdated Copilot threads on FixesPushed (iterative
  only).** When the poller emits `PollEvent::FixesPushed(pr)` for a tracked PR
  with `review_mode == Iterative`: for each currently-unresolved thread with
  `isOutdated == true`, issue a `resolveReviewThread` GraphQL mutation
  (server-side, bounded the same way the poller's other `gh` calls are; failures
  are logged and retried on the next applicable tick, never fatal). Log one line
  per PR: `poller auto-resolved N outdated review thread(s) pr=<n>` (and a
  per-thread TRACE if useful). Do not touch not-outdated threads. Do not run for
  `SinglePass` PRs or on non-FixesPushed ticks.
- **Leaf prompt: poller snapshot is the source of truth; no `gh` for threads; a
  `gh` timeout is not a blocker.** Rewrite the `gh discipline` block in
  `.choir/prompts/profiles/leaf.md` (and any mirrored copy — check
  `.choir/prompts/skills/audit.md` is unaffected; the audit skill is a worker
  flow, not a leaf flow) so the review-cycle instructions are:
  - The poller pushes review snapshots into your pane (`[REVIEW]` /
    `[CI LATEST HEAD]` / `[COPILOT ISSUE COMMENT]` / `[FIXES PUSHED]` /
    `[MERGE READY]`) carrying "GitHub review rollup", "Unresolved inline review
    threads (GraphQL): N", "GitHub Copilot issue comment (REST)", and the CI
    rollup. **That snapshot is the source of truth.** Do NOT issue your own
    `gh api graphql … reviewThreads` / `gh api …/pulls/N/reviews` / `…/comments`
    calls to determine review state.
  - When Copilot's comments arrive: address every one, `git push`, then **stop**.
    The server resolves the now-outdated threads for you (the next poller snapshot
    will show "Unresolved … : 0"). You do NOT need to call `gh` to resolve
    threads — remove the old "resolve each thread yourself via `gh api graphql
    mutation resolveReviewThread`" instruction.
  - If, after your fix-push, the next poller snapshot still shows "Unresolved …:
    N > 0" and those threads are *not* getting cleared (e.g. they're not
    outdated because your fix lives in a different file/region), THEN: try the
    `resolve_review_thread` MCP tool (or, bounded, `timeout 30s gh api graphql -f
    query='mutation { resolveReviewThread(input:{threadId:"…"}){thread{isResolved}}}'`)
    using a thread ID from… (the leaf no longer has an easy way to get IDs — so:
    if the snapshot shows persistent N>0 you can't clear, THAT is when you
    `notify_parent --status …` and let the TL resolve from its pane). A `gh`
    call that times out is **not** a blocker — wait for the next poller snapshot;
    only `[BLOCKED]`/`notify_parent` when the snapshot *itself* shows unresolved
    threads that aren't clearing.
  - Keep the "bound every `gh` call with `timeout 30s` / prefer REST / don't
    poll-loop after `file_pr`" guidance for the cases the leaf still legitimately
    uses `gh` (it shouldn't for review state anymore).
- **End-to-end:** a leaf addresses Copilot comments → `git push` → idles. Next
  poller tick: `FixesPushed` → server resolves outdated threads → next snapshot
  shows "Unresolved … : 0" → merge gate clears (with choir-8z1's CI-verify) →
  server automerges. The leaf never runs a `reviewThreads` query; the TL is not
  pulled in unless a non-outdated thread genuinely persists.

## Non-Goals

- Removing the leaf's ability to call `gh` for *non-review-state* things (git
  status, etc.) or the `resolve_review_thread` MCP tool — those stay; we just
  stop the leaf from doing review-state *queries*.
- Auto-resolving **not-outdated** unresolved threads, or auto-resolving on
  non-FixesPushed ticks, or for `SinglePass` PRs. (Conservative by design.)
- Changing what the poller event snapshot text looks like (it already carries the
  count; we don't need to surface the thread IDs in the *text* — the leaf doesn't
  use them anymore. Stashing IDs on `TrackedPR` is server-internal.)
- The `choir-cx6` server-side `gh`-stall-fallback-to-`poller_state.json` work —
  related but separate; this spec assumes the poller's existing `gh` calls behave
  as they do today (bounded, backoff on failure).
- A new poller event type. Reuse `FixesPushed`.
- Touching the worker/audit flow (workers don't have a review cycle).

## Design

**`src/poller/poller.mbt`** — `TrackedPR`: add `mut review_mode : @types.ReviewMode`
(default `Iterative`) and `mut unresolved_thread_ids : Array[ReviewThreadRef]`
(or reuse a small struct `pub(all) struct ReviewThreadRef { id : String;
is_outdated : Bool }`). The existing `unresolved_threads : Int?` plumbing can stay
as the count, derived from the array (or keep both — the array is `[]` when "not
fetched" vs the `Int?` `None`; pick one representation, document it).

**Poller GraphQL fetch** (wherever the unresolved-thread count is fetched — likely
the server-side poll-delivery / poll-tick handler in `src/server/` or a
`src/poller/gh*.mbt` fetcher; trace from `handler_poll_delivery.mbt`'s
"Unresolved inline review threads (GraphQL):" formatting back to its source):
extend the `reviewThreads(first:…){ nodes{ … } }` selection to include `id` and
`isOutdated`; parse into `ReviewThreadRef[]`; write onto the `TrackedPR`. No
change to the bounding/timeout/error handling.

**`src/poller/detect.mbt` / `tl_decision.mbt` (or wherever `FixesPushed` is acted
on after detection)** — when a tick produces `PollEvent::FixesPushed(pr)` and the
tracked PR's `review_mode == Iterative`: collect `tracked.unresolved_thread_ids`
where `is_outdated`, and for each issue a `resolveReviewThread` mutation via the
same bounded `gh` capture seam the poller uses. Factor the *selection* ("given the
event, the tracked PR, and its thread refs → which thread IDs to resolve") as a
pure function for testing; the actual mutation call is the effectful adapter step.
Log `poller auto-resolved N outdated review thread(s) pr=<n>`.

**`src/poller/poller.mbt` / `src/tools/file_pr.mbt` / `src/tools/fork_wave.mbt`** —
when a PR is first tracked (`ensure_tracked` / the `TrackedPR` constructor in
`file_pr_plan`), set `review_mode` from the wave/spawn contract (the `review_mode`
arg `fork_wave`/`spawn` already accept; default `Iterative`). If that value isn't
currently reachable at the tracking call site, plumb it (it's in the task
contract / spawn args).

**`.choir/prompts/profiles/leaf.md`** — rewrite the `gh discipline` /
review-cycle steps per Goals: poller snapshot is truth; no `reviewThreads`
queries; after fix-push the server resolves outdated threads; `gh` timeout ≠
blocker; `[BLOCKED]`+`notify_parent` only when the snapshot shows persistent
unresolved threads. (`src/prompts/loader.mbt` loads it; no logic change; keep
`loader_test.mbt` green. Also update the inline leaf spawn-prompt text if any of
it is still string-literal in `src/tools/spawn_prompt.mbt` rather than sourced
from the markdown.)

**`src/server/reload.mbt`** — if `TrackedPR` gains fields that are persisted in
`poller_state.json`, make sure (de)serialization round-trips them with sane
defaults (`review_mode` ⇒ `Iterative`, thread refs ⇒ `[]`) so a reload doesn't
choke on an old state file.

No `@sys.*`/`@process.*` direct calls in `src/server`/`src/poller`/`src/tools`
beyond the existing `gh` capture adapter seam; use the `ReviewMode` enum,
`ChoirError` for new error paths.

## Verify

- `moon test --target native` — unit tests for: the "which thread IDs to resolve
  on FixesPushed" pure selector (Iterative + FixesPushed + N outdated ⇒ those N
  ids; SinglePass ⇒ none; not-FixesPushed ⇒ none; not-outdated threads excluded;
  empty thread list ⇒ none); GraphQL response parsing into `ReviewThreadRef[]`
  (incl. `isOutdated` true/false, empty); `TrackedPR` round-trips
  `review_mode`/thread-refs through `poller_state.json` (de)serialization with
  the right defaults for an old state file lacking the fields; `loader_test.mbt`
  stays green after the leaf.md rewrite. Hermetic — mock the `gh` capture seam,
  no real-checkout/repo-git/network.
- Observable: `grep -n "source of truth\|do NOT issue your own .*gh\|gh.*timeout.*not a blocker"
  .choir/prompts/profiles/leaf.md` shows the new review-cycle instructions; the
  old "resolve each thread yourself via `gh api graphql ... resolveReviewThread`"
  line is **gone** from `leaf.md` (`grep -c "resolveReviewThread" .choir/prompts/profiles/leaf.md`
  ⇒ 0, or only inside the "persistent-unresolved fallback" clause).
- Manual smoke (post-merge, document in PR, optional): next `fork_wave(automerge,
  iterative)` wave — when Copilot comments land and the leaf pushes a fix, watch
  `choir logs --grep "auto-resolved"` show the server resolving the outdated
  thread(s), and the leaf reach `notify_parent` (or just idle to automerge)
  without ever running a `reviewThreads` query.

## Boundary (do not)

- Server auto-resolve fires ONLY on `FixesPushed` for `review_mode == Iterative`
  tracked PRs, and ONLY for threads GitHub reports `isOutdated`. Never resolve a
  not-outdated thread; never on a `SinglePass` PR; never on a non-FixesPushed
  tick.
- A `gh` failure (timeout/error) anywhere in the poller's fetch or auto-resolve
  path is logged and retried next tick — never fatal, never changes the prior
  snapshot, never blocks anything. (Same as the poller's existing `gh` behavior.)
- The leaf prompt must NOT instruct leaves to run `gh api graphql … reviewThreads`
  / `gh api …/pulls/N/reviews` / `…/comments` for review state. The only `gh`
  the leaf may run in its review cycle is a bounded `resolveReviewThread` mutation
  (or the `resolve_review_thread` MCP tool) in the rare persistent-not-outdated
  case — and a timeout there is not a blocker.
- Do not change the poller event *text* / add a new event type — reuse
  `FixesPushed`; stashing thread IDs on `TrackedPR` is server-internal.
- Do not weaken the merge gate, the `gh` bounding discipline, or the worker/audit
  flow. Keep `loader_test.mbt` and existing poller/file_pr tests green.
- No `@sys.*`/`@process.*` direct calls outside the existing adapter seams.

## Follow-Ups

- `choir-cx6` — server-side `gh`-stall fallback to `poller_state.json` (so even
  the poller's own `gh` queries degrade gracefully); composes with this.
- If the not-outdated-persistent-thread case turns out to be common, give the
  leaf a way to enumerate unresolved thread IDs *without* a `gh` query (e.g.
  surface them in the `[REVIEW]`/`[FIXES PUSHED]` event payload after all) so it
  can resolve them via the MCP tool without ever shelling `gh`.
- Have the leaf consume the poller's CI-rollup line as the verify signal too
  (overlaps choir-8z1's CI-satisfies-verify — already shipped on the gate side).
- `choir-kqv.8` — retire Choir-side merge override flags. If `merge_pr` returns a
  policy block, address it or use `gh pr merge --admin <N>` for human-judgment
  overrides.
