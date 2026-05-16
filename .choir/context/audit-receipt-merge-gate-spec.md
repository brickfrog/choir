# Spec: audit-receipt-merge-gate

## Context
Today's audit-receipt gate (PR #346 / choir-cbm) runs only inside `file_pr`.
A leaf that bypasses `file_pr` and calls `gh pr create` directly (observed
live 2026-05-16 on PR #349 with the codex `spark` model after `file_pr`
appeared to time out) ships a PR with no audit receipt and no choir-side
record that an audit ever ran. The merge path currently has no equivalent
check, so the bypassed PR flows straight through `merge_pr` and (with
automerge) lands on `main` without ever passing the cbm gate. We want a
structural lock at `merge_pr` so the bypass is closed even when a leaf is
non-compliant or out-of-band.

## Clarifications

**Q: Where should the audit-receipt gate enforce — i.e. at what point does choir refuse a PR that has no valid audit receipt for its HEAD?**
A: `merge_pr` only. Block at merge time. Let PRs be filed/tracked without a
receipt, but they cannot merge. Composes naturally with the existing
`merge_pr_preflight_block_message` policy block path.

**Q: When a tracked PR has no valid audit receipt for its current HEAD, what should choir do?**
A: Auto-spawn an audit worker, then block until the receipt lands. The
server reacts to the gh-fallback case by running the same audit it would
have run inside `file_pr`, writes the receipt, and the gate clears once the
receipt is present. Self-healing — no manual TL step required for the
common case. Same shape as `file_pr_auto_audit_for_missing_receipt`.

**Q: What counts as a 'valid' receipt for a PR HEAD that has been amended/force-pushed since the receipt was written?**
A: Receipt sha must match current PR HEAD exactly. Same rule as
`file_pr_audit_receipt_validation` today (stale_audit_receipt_error).
Receipt must be re-issued after any push.

**Q: How should the gate treat PRs already open (or already merged) before this feature lands?**
A: Grandfather. Stamp a `gate_enabled_at` unix timestamp the first time the
server starts with this code; PRs whose `created_at` is older than that
timestamp pass automatically. Avoids retroactively merge-blocking in-flight
work at deploy time.

## Goals
- `merge_pr` refuses to merge a PR whose merge-HEAD has no valid audit
  receipt under `.choir/audit/` (validity == exact sha match), unless the
  PR is grandfathered.
- When a receipt is missing/stale, the server auto-spawns an audit worker
  scoped to the PR's merge-HEAD, waits within an audit budget for the
  worker to report, writes the receipt via the existing
  `write_audit_receipt` path, and then re-evaluates the gate.
- The gate composes with the existing `merge_pr_preflight_block_message`
  policy block surface — same return shape, same TL-facing language.
- A `gate_enabled_at` timestamp persisted at
  `.choir/audit-gate.json` grandfathers PRs created before the gate
  shipped.
- Test coverage: validation pure function, grandfather predicate, and an
  integration-style test that exercises the auto-audit spawn path with
  injected adapters (mirrors `file_pr_require_audit_receipt` tests).

## Non-Goals
- No `track_pr` / poller-side enforcement. The bypass closes at merge,
  not at PR discovery. (Considered and rejected.)
- No tolerant-validity rules (any-ancestor, merge-base reachable). Exact
  sha match only.
- No retroactive enforcement on already-open PRs at deploy time —
  grandfather flag, no backfill task.
- No `gh` wrapper / worktree-level interception of `gh pr create`.
  Out of scope (and noted as too restrictive in the bead).
- No async `file_pr` protocol change (choir-mje follow-up; tracked
  separately).
- No per-model prompt tuning to discourage gh fallback. Prompt-side
  change is orthogonal and lives outside this feature.

## Design

Two cohesive modules under `src/tools/merge_pr.mbt` plus a tiny new
persistence helper. Strongly mirrors the file_pr receipt code path so
the validation logic and audit-spawn orchestration are not duplicated.

### Module 1 — merge-side receipt validation (pure)
Files:
- `src/tools/merge_pr.mbt` — add `merge_pr_audit_receipt_validation`
  that wraps `file_pr_audit_receipt_validation` (already exported from
  `src/tools/file_pr.mbt`). Reuse the same receipt path helper
  (`file_pr_audit_receipt_path_for_head`) and the same `AuditReceipt`
  parser. New code is glue, not duplicated rules.
- `src/tools/merge_pr.mbt` — extend
  `merge_pr_preflight_block_message` with a new case before the
  unresolved-threads branch: when the gate is required for this PR and
  the receipt is missing/stale/invalid, return a typed policy block
  message instructing the TL that the auto-audit is running (or, if
  spawn failed, that a manual `/audit` is required).

### Module 2 — grandfather timestamp persistence
File: `src/tools/merge_pr_gate.mbt` (new, narrow).
- `pub struct MergeGateState { enabled_at_unix : Int64 }`
- `pub fn load_or_initialize_gate_state(project_dir : String, now_fn : () -> Int64, read : ..., write : ...) -> MergeGateState`
  - Reads `.choir/audit-gate.json`. If absent, writes `{enabled_at_unix: now}` and returns it.
  - Read/write go through injected adapters (file-IO is the
    capability per the effect rules in CLAUDE.md).
- `pub fn merge_pr_audit_gate_required(state : MergeGateState, pr_created_at_unix : Int64) -> Bool`
  - Pure predicate: required iff `pr_created_at_unix >= enabled_at_unix`.

### Module 3 — auto-audit on missing receipt at merge time
File: `src/tools/merge_pr.mbt`.
- `async fn merge_pr_require_audit_receipt(...) -> Result[Unit, ChoirError]`
  modeled on `file_pr_require_audit_receipt` and reusing
  `file_pr_auto_audit_for_missing_receipt` directly (extract it to a
  shared helper if currently private — keep the existing tests passing).
- Wired into `merge_pr` after the existing policy-block computation,
  before invoking `gh pr merge`. If the gate blocks (and auto-audit was
  attempted but didn't land a receipt within budget), surface the block
  through the same `Err(ChoirError::validation_error(...))` path the
  policy block uses — so `wave_state` / TL prose sees one consistent
  shape.

### Reused patterns
- `.choir/context/patterns/thread-enum-through-wire.md` for any new
  typed status we surface (prefer a `MergeGateResult` enum over
  stringly status).
- The `file_pr_require_audit_receipt` adapter-injection style is the
  exact analog — same `spawn_audit_worker?`, `wait_for_audit_report?`,
  `cleanup_audit_report?`, `write_audit_receipt?` shape.

### Wiring at the merge_pr call site
- `dispatch.mbt` passes the real adapters (server-bound) through.
- Tests pass mock adapters and a fake `now_fn` to exercise the
  grandfather predicate and the auto-audit happy/sad paths.

## Verify
- `moon test --target native` — full suite (this is the CI gate per
  CLAUDE.md Leaf Agent Rules).
- New unit tests in `src/tools/merge_pr_test.mbt`:
  1. `merge_pr_audit_gate_required` is false for PRs created before
     `enabled_at_unix`, true after.
  2. `merge_pr_audit_receipt_validation` returns Valid when the
     on-disk receipt sha matches the supplied HEAD; Stale when sha
     differs; Missing when no file; Invalid when JSON is malformed.
  3. Auto-audit success path: missing-receipt + spawn + report +
     write-receipt → gate clears.
  4. Auto-audit timeout path: missing-receipt + spawn ok + no report
     within budget → returns typed block error mentioning the audit
     budget.
  5. Auto-audit spawn failure path: returns typed block error
     directing the TL to run `/audit` manually.
- Observable check (per feedback_spec_hygiene):
  - Stage a tracked PR with no receipt under
    `.choir/audit/` and run `merge_pr` against it (mock gh layer).
    `serve.log` must contain a `merge_pr ... outcome=audit_block`
    line and the response must include the typed policy block
    message — grep the log and the response JSON.

## Boundary (do not)
- Do NOT change `file_pr_audit_receipt_validation`'s signature or
  semantics. Reuse it as-is. Same for
  `file_pr_audit_receipt_path_for_head` and the
  `AuditReceipt`/`AuditReceiptWritePlan` types.
- Do NOT introduce a parallel receipt directory. Receipts live where
  `file_pr` writes them (`.choir/audit/`).
- Do NOT add a `--no-audit` override flag, env var, or config knob.
  Force-merge needs no new shortcut — TL can already use
  `gh pr merge --admin <N>` per the MCP server instructions.
- Do NOT add stringly status fields. New gate status is an enum and
  threads through the policy-block message channel.
- Do NOT call `@sys.*` or `@process.*` directly from
  `src/tools/merge_pr.mbt` or the new gate module — go through
  injected adapters per the effect rules.
- Do NOT widen merge_pr's `merge_policy_decision_for_tracked_pr`
  surface. The gate is a separate preflight check, not a new
  `MergeDecision` variant.
- Do NOT leave behind any `legacy_*` / `compat_*` wrapper to keep the
  old "no gate at merge" behavior reachable.

## Follow-Ups
- choir-c4h — observability layer (responsiveness watchdog) so the
  TL has a signal when a leaf goes unresponsive after a cap. Composes
  with this gate (this gate stops the *artifact*; c4h stops the
  *cascade*).
- choir-jop — audit-worker reaped-at-0s bug; the trigger that pushed
  spark into gh-fallback in the first place. Fixing it reduces how
  often this gate actually fires.
- choir-3bj — delta-only audit on retry. Auto-audit at merge time
  re-scans the full diff; once 3bj lands, the spawn invoked here can
  reuse the delta-scan path for cheaper retries.
- choir-mje — async `file_pr` protocol change. If file_pr stops
  having a 120s wall-clock for the leaf to time out against, the
  gh-fallback temptation drops; the gate stays as defense-in-depth.
