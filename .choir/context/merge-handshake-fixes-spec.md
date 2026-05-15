# Spec: merge-handshake-fixes

## Context

Three related TL↔leaf↔server handshake bugs that all bit us in the last few
sessions. They share files (`src/tools/file_pr.mbt`, `src/tools/merge_pr.mbt`,
`src/server/handler_poll_delivery.mbt`, `src/poller/poller.mbt`) and a
conceptual theme (the merge handshake is leaky), so they ship as one batched
leaf:

- **`choir-cps`**: on `automerge=iterative` PRs the server only fires automerge
  on the per-event `MergeReady` path, but a normal Copilot-fix-push cycle keeps
  the PR at `review_state == commented` throughout (`commented → fixes_pushed →
  commented` is not a review-state *transition*), so `MergeReady` never re-fires,
  no automerge runs, and the PR sits with `merge_gate_ready=true` indefinitely.
  Observed concretely on PR #342 (choir-5fv) — the TL had to manually call
  `merge_pr`.
- **`choir-lq4`**: `file_pr_require_audit_receipt` reads the receipt from the
  leaf's worktree (`workdir=file_pr_dir`) but `write_audit_receipt` writes to the
  project root. TL-written receipts are invisible to leaf retries; the loop
  never closes. Observed on moontrace 2026-05-13.
- **`choir-kqv.8`**: the `choir tl-parent-override on` → `merge_pr force=true` →
  `choir tl-parent-override off` three-command dance is obsolete now that
  `choir-8z1` (PR #340) made the happy path no longer need a force-merge. Time
  to retire it.

Observable outcome: a normal `fork_wave(automerge, iterative)` leaf addresses
Copilot comments, pushes, and is auto-merged by the server **with zero TL
intervention** (no manual `merge_pr`, no override dance, no leaf hand-copying
receipts). The TL only steps in for genuinely human-judgment cases.

## Clarifications
> Q&A from the crystallize step. Durable; leaves read this.

**Q: choir-kqv.8 — what shape should retiring `tl-parent-override` take?**
A: Eliminate the override entirely. After `choir-8z1` the happy path doesn't
need a force-merge — if `merge_gate_ready=true` the policy gate just passes.
Drop the `tl-parent-override` KV, the `choir tl-parent-override <on|off>` CLI,
the `merge_pr force=true` arg, and the preflight bypass. For the rare
genuinely-human-judgment override (CI red but ship anyway, etc.) the operator
uses `gh pr merge --admin <N>` directly — that's the correct escape hatch and
it's not choir's job to provide a parallel one.

**Q: choir-cps — when the per-tick sweep attempts `merge_pr` and it fails
(transient `gh` hiccup), how does it retry?**
A: Conservative — one attempt per HEAD. Persist `mut last_automerge_attempt_sha
: String` on `TrackedPR`. The per-tick sweep attempts `merge_pr` only when
`merge_gate_ready && automerge enabled && last_automerge_attempt_sha !=
tracked.last_sha`. A transient `gh` failure on tick N means waiting for HEAD
to move (next push) before retrying. Trades slow-recovery-after-transient-fail
for zero risk of `merge_pr`-spam against GitHub rate limits.

**Q: choir-lq4 — fix shape for the audit-receipt path resolution?**
A: Smaller — pass `project_dir` into `file_pr_require_audit_receipt` and run
the `cat` capture with `workdir=project_dir`. Keep the relative
`.choir/audit-receipts/<short>.json` path; just fix the workdir. The receipt
lookup is a strict project-root concern; no reason it should ever read from a
worktree's `.choir/`.

## Goals

- **choir-cps — per-tick automerge sweep, idempotent across ticks via per-HEAD guard.**
  - Add `mut last_automerge_attempt_sha : String` to `TrackedPR` (default `""`).
  - In `deliver_pending_poll_events` (`src/server/handler_poll_delivery.mbt`,
    around the existing `automerge_attempted_prs : Map[Int, Bool]` per-tick
    dedupe at ~L1290–1404), after the existing per-event automerge gate runs,
    sweep tracked PRs: for each `pr` with `pr.review_mode == Iterative`
    (re-use `tracked.review_mode`), `merge_gate_ready == true` per the policy
    evaluation, automerge enabled for this wave, AND
    `pr.last_automerge_attempt_sha != pr.last_sha` — invoke
    `maybe_trigger_automerge_for_pending_event` (or the equivalent
    `merge_pr` entry the existing event path uses) and set
    `pr.last_automerge_attempt_sha = pr.last_sha` regardless of outcome.
  - On a successful merge (the existing untrack path) the PR leaves the tracked
    map anyway — no extra cleanup needed.
  - Factor the SELECTION ("given a tracked PR + tick, should we attempt
    automerge?") as a PURE function for testing; the actual `merge_pr` call is
    the effectful adapter step. Persist `last_automerge_attempt_sha` through
    `poller_state.json` (de)serialization with a `""` default for old state
    files lacking the field (so a reload doesn't choke).

- **choir-lq4 — audit-receipt lookup uses `project_dir`, not `file_pr_dir`.**
  - Add a `project_dir : String` parameter to `file_pr_require_audit_receipt`
    (`src/tools/file_pr.mbt:696`).
  - Change the `cat` capture call at `file_pr.mbt:713–718` to use
    `workdir=Some(project_dir)` instead of `workdir=Some(file_pr_dir)`. The
    relative `file_pr_audit_receipt_path_for_head(sha)` helper stays unchanged.
  - Update every call site (probably one or two in the dispatch path) to pass
    the project root.
  - Add a regression test that drives `file_pr_require_audit_receipt` with
    `project_dir != file_pr_dir` and a receipt at
    `<project_dir>/.choir/audit-receipts/<short>.json`; preflight must succeed.
    Add the inverse test: receipt at `<file_pr_dir>/.choir/audit-receipts/...`
    is NOT consulted.

- **choir-kqv.8 — eliminate `tl-parent-override` and `merge_pr force=true`.**
  - Remove the `force : Bool` parameter from `interpret_merge_pr_preflight` /
    `merge_pr` tool entry (`src/tools/merge_pr.mbt`), the MCP tool schema
    (`src/mcp/translate.mbt`'s `merge_pr` declaration), the parser
    (`src/tools/parse.mbt`'s `parse_merge_pr_args` / `force` field), the
    `MergePrArgs` struct, and every test that asserts `force=true` behavior.
  - Delete the `override_check` helper and the `tl-parent-override--<caller>`
    KV path read at `merge_pr.mbt:291–305`.
  - Delete the `choir tl-parent-override <on|off>` CLI subcommand
    (`src/bin/choir/main.mbt`'s usage string + dispatch + the subcommand file).
  - Delete the audit/log line `"force-merge: override active, bypassing
    poller/threads/policy preflight"` (`merge_pr.mbt:366`) and the post-tool
    messaging that surfaces `force_override` provenance
    (`src/server/post_tool.mbt` ~L216/L236/L250) — server-automerge stays as
    `server_automerge` provenance; the `force_override` variant goes away.
  - Verify the evidence event `UserOverrideObserved(scope="merge_pr.force",
    reason="merge_pr invoked with force=true")` at
    `src/server/handler_evidence.mbt:130-131`: delete it (along with any
    enum variants of `MergeExecutionMode::ForceOverride` in
    `src/evidence/evidence.mbt`, since they only exist to record this).
  - When the policy gate genuinely blocks, `merge_pr` returns a structured
    error explaining why (it already does — preserve those messages, just
    strip the "or pass force=true to override" hints from them).
  - Update `.choir/prompts/profiles/tl.md` / `.choir/context/tl.md` / memory
    references to the override dance: rewrite to "if `merge_pr` returns a
    policy block, address the block (resolve threads, wait for CI, etc.) or
    use `gh pr merge --admin <N>` for human-judgment overrides — there is no
    choir-side force flag." `.choir/prompts/profiles/leaf.md` doesn't need
    changes (leaves never had access to `force=true` / the override).

- **End-to-end:** a leaf in a `fork_wave(automerge, iterative)` wave addresses
  Copilot comments → `git push` → idles. On the next poller tick after
  threads-clear/CI-green: the per-HEAD sweep finds
  `merge_gate_ready=true && last_automerge_attempt_sha != last_sha`, fires
  `merge_pr` (no force, no override) — merges. `choir tl-parent-override` and
  `merge_pr force=true` are gone; trying to use them surfaces "unknown
  subcommand" / "unknown argument" errors at parse time.

## Non-Goals

- The `choir-cx6` server-side `gh`-stall fallback to `poller_state.json` — that
  composes with this work but ships separately.
- Reworking the per-event `MergeReady` path itself. The existing per-event
  trigger keeps working; the per-tick sweep is purely additive (and idempotent
  via `last_automerge_attempt_sha`).
- A *new* parallel "override" mechanism. If `gh pr merge --admin` proves
  insufficient in practice we'll reconsider — but not in this bead.
- Changing what `merge_gate_ready` actually checks (that's the evaluation
  cascade in `src/types/domain.mbt`, untouched here).
- Touching leaf prompts beyond removing the obsolete override-dance references
  if any exist (leaves don't have `force`).

## Design

### choir-cps — per-HEAD automerge sweep

`src/poller/poller.mbt` (`TrackedPR`): add `mut last_automerge_attempt_sha :
String` (default `""`).

`src/server/reload.mbt` / wherever `poller_state.json` (de)serialization lives:
round-trip the new field with default `""` for old state files lacking it.

`src/server/handler_poll_delivery.mbt` (`deliver_pending_poll_events`, around
the existing per-tick automerge dedupe at ~L1290–1404): after the per-event
automerge loop runs, walk the tracked PR list. For each `pr` where
`pr.review_mode == Iterative`, `merge_gate_ready_for_tracked(pr) == true` (use
the same evaluation function the snapshot uses), and
`pr.last_automerge_attempt_sha != pr.last_sha`: invoke the same automerge
entrypoint the event path uses (`maybe_trigger_automerge_for_pending_event` or
its equivalent), then set `pr.last_automerge_attempt_sha = pr.last_sha` whether
the attempt succeeded or failed.

Factor the selection as a pure function:
```
pub fn pr_needs_automerge_sweep_attempt(
  pr : @poller.TrackedPR,
  gate_ready : Bool,
  automerge_enabled : Bool,
) -> Bool {
  pr.review_mode == @types.ReviewMode::Iterative
  && gate_ready
  && automerge_enabled
  && pr.last_automerge_attempt_sha != pr.last_sha
}
```
Unit-test the full truth table.

### choir-lq4 — receipt lookup workdir

`src/tools/file_pr.mbt:696` (`file_pr_require_audit_receipt`): add `project_dir
: String` parameter. Change the cat capture (lines 713–718) from
`workdir=Some(file_pr_dir)` to `workdir=Some(project_dir)`. The
`file_pr_audit_receipt_path_for_head(sha)` helper at line 586 keeps its
signature (relative path).

Caller (the dispatch site that invokes file_pr's preflight): pass
`project_dir` alongside the existing `file_pr_dir`.

Regression test: drive `file_pr_require_audit_receipt` with
`project_dir = "/tmp/test-receipt-root"` and `file_pr_dir =
"/tmp/test-receipt-root/.choir/worktrees/some-leaf"`. Write a valid receipt at
`/tmp/test-receipt-root/.choir/audit-receipts/<short>.json`; the preflight
must return `Ok`. The inverse: write the receipt only at
`<file_pr_dir>/.choir/audit-receipts/...`; the preflight must fail.

### choir-kqv.8 — eliminate the override

Files to gut (grep first to make sure nothing's missed):

- `src/tools/merge_pr.mbt`:
  - Drop the `force : Bool` arg from `MergePrArgs` and every function that
    threads it (`interpret_merge_pr_preflight`, `interpret_merge_pr`, etc.).
  - Delete `override_check` and the `.choir/kv/tl-parent-override--<caller>`
    KV path at L291–305.
  - Delete the force-path branch in the preflight (the `if force { ... }` at
    ~L352–366) including its moontrace warn line.
  - Strip "or pass force=true to override" suffixes from the policy-block
    error messages at L445/455/461.
- `src/tools/parse.mbt`: drop `force` from `parse_merge_pr_args`; the parser
  should error on `force` being supplied (unknown key) so old callers get a
  clear signal.
- `src/mcp/translate.mbt`: drop the `force` field from the `merge_pr` MCP tool
  schema.
- `src/bin/choir/main.mbt`: remove `tl-parent-override` from the usage string,
  the dispatch switch, and its subcommand handler file (`src/bin/choir/*.mbt`
  — grep `tl_parent_override` / `tl-parent-override`).
- `src/server/post_tool.mbt`: drop the `force_override` provenance branch
  (~L216/L236/L250); server-automerge stays as `server_automerge` provenance.
- `src/server/handler_evidence.mbt`: drop the
  `UserOverrideObserved(scope="merge_pr.force", ...)` recorder at L130–131.
- `src/evidence/evidence.mbt`: if `MergeExecutionMode::ForceOverride` exists
  only to record this override, drop the variant. Otherwise leave it (other
  callers may exist).
- `.choir/context/tl.md` and any other TL-facing prompt / doc that says
  "tl-parent-override on → merge_pr force=true → tl-parent-override off":
  rewrite to "if `merge_pr` returns a policy block, address the block or use
  `gh pr merge --admin <N>`." Memory files (`MEMORY.md` entries) describing
  the old dance can stay — they're historical.
- Every test asserting `force=true` behavior (`merge_pr_test.mbt`,
  `notify_parent_preflight_test.mbt`, etc.): delete or rewrite to the
  no-force path.

The merge gate itself doesn't change. Server-side automerge already calls
`merge_pr` without `force`, so its happy path is untouched.

## Verify

- `moon test --target native` — unit tests for: `pr_needs_automerge_sweep_attempt`
  truth table (Iterative + gate_ready + automerge + last_attempt!=last_sha ⇒
  true; any of those false ⇒ false; SinglePass ⇒ false); the sweep correctly
  updates `last_automerge_attempt_sha` on both success and failure paths;
  `TrackedPR` round-trips `last_automerge_attempt_sha` through
  `poller_state.json` (de)serialization with `""` default for old files;
  `file_pr_require_audit_receipt` with `project_dir != file_pr_dir`
  succeeds/fails per receipt placement; merge_pr (now without `force`)
  policy-block errors no longer suggest `force=true`. Hermetic — mock the gh
  capture seam.
- Observable: `grep -c "force_override" src/server/post_tool.mbt` ⇒ 0;
  `grep -c "tl-parent-override" src/bin/choir/main.mbt` ⇒ 0;
  `grep -c "force\s*:\s*Bool" src/tools/merge_pr.mbt` ⇒ 0;
  `grep -A2 "or pass force=true" src/tools/merge_pr.mbt` ⇒ no matches.
- Manual smoke (optional, document in PR): on the next
  `fork_wave(automerge, iterative)` wave — a fix-push cycle ends with the
  server automerging without TL intervention (check `choir logs --grep
  "automerge sweep"` for the sweep firing on the post-fix-push tick); trying
  `choir tl-parent-override on` fails with "unknown subcommand"; trying
  `merge_pr force=true` fails at parse with "unknown argument".

## Boundary (do not)

- The per-HEAD sweep fires ONLY for `review_mode == Iterative` tracked PRs
  with `automerge enabled` and `last_automerge_attempt_sha != last_sha`. Never
  for SinglePass, never on a PR that's already been attempted on this HEAD,
  never on PRs not in the tracked set.
- The sweep call uses the SAME `merge_pr` entrypoint the per-event path uses —
  do not introduce a parallel merge path with different gating.
- The audit-receipt fix only changes the `workdir` on the cat capture in
  `file_pr_require_audit_receipt`. Do not change the on-disk receipt format,
  the `write_audit_receipt` tool, the receipt-required predicate
  (`file_pr_audit_receipt_required`), or any other receipt-related behavior.
- Eliminating the override must not weaken the policy gate. When the gate
  blocks, `merge_pr` still errors with the specific reason (just without
  "or pass force=true"). The escape hatch is the human's `gh pr merge
  --admin`, not a choir tool.
- No new poller event type. The sweep runs inside the existing
  `deliver_pending_poll_events` after the existing event loop.
- No `@sys.*`/`@process.*` direct calls in `src/server`/`src/tools`/`src/poller`
  beyond the existing adapter seams.
- Use the `ReviewMode` enum (not strings); `ChoirError` for new error paths.
- Keep all tests hermetic — fixture dirs only, no real-checkout/repo-git
  mutation, mock the gh capture seam.

## Follow-Ups

- `choir-cx6` — server-side `gh`-stall fallback to `poller_state.json` (so the
  poller's own `gh` queries degrade gracefully); composes with the sweep.
- If `gh pr merge --admin` proves insufficient in practice (a recurring
  legitimate need for a typed choir-side override), reconsider — file a fresh
  bead with the use case data, don't re-resurrect `tl-parent-override`.
- Consider widening the per-HEAD sweep to SinglePass PRs after observing
  Iterative for a session or two — left out of v1 to keep the change scoped.
