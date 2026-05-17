# Spec: audit-worker-id-collision

## Context
`audit_on_file_pr_worker_slug(head_sha)` in
`src/tools/file_pr.mbt:1067` derives the audit worker's slug
deterministically from `audit-on-file-pr-<short_sha>`. The resulting
`agent_id` (`<parent>.audit-on-file-pr-<short_sha>`) collides on any
retry against the same HEAD — observed live on 2026-05-16 PR #349:
the second audit worker was reaped at 0s with
`reason=worker_shutdown`, file_pr returned
`"no finding summary provided"`, and the codex spark leaf fell back to
`gh pr create` (the choir-mu1 bypass). Also missing: even when a valid
audit receipt already exists on disk for this exact HEAD, the
auto-audit path still spawns a fresh worker and waits 15 minutes. We
want collisions to be impossible by construction, the receipt path to
short-circuit, and an in-flight audit on the same branch to be
piggy-backed on rather than duplicated.

## Clarifications

**Q: The audit worker's slug is `audit-on-file-pr-<short_sha>` (file_pr.mbt:1067), making the agent_id deterministic per HEAD sha. A second file_pr call on the same sha tries to spawn an identical agent_id and the new pane shuts down at 0s. What's the fix?**
A: Make the slug unique per spawn — append a unix-ms timestamp (or
monotonic counter). Format: `audit-on-file-pr-<short_sha>-<unix_ms>`.
Eliminates collision by construction; no coupling to prior-worker
state. Worktree / pane cleanup falls to the standard worker-finalize
path.

**Q: Should the fix also short-circuit when a valid audit receipt already exists on disk for the exact HEAD sha?**
A: Yes — if `.choir/audit/<sha>.json` exists and parses cleanly via
`file_pr_audit_receipt_validation`, skip the auto-audit spawn entirely
and return success. Validation logic already exists; cheap to wire.

**Q: If a prior audit worker for this branch is still in flight (registry shows it alive), what should the new file_pr call do?**
A: Wait on the existing worker's report instead of spawning a new one.
The work is already happening; piggy-back. Composes with the
unique-slug strategy — uniqueness is per *new* spawn, not per pending
spawn. Detection: look up registry entries whose slug starts with
`audit-on-file-pr-<short_sha>-` and whose lifecycle is not
finalized; if any exist, await their report rather than spawning.

## Goals
- `audit_on_file_pr_worker_slug(head_sha, now_ms)` accepts a current-time argument and returns `audit-on-file-pr-<short_sha>-<unix_ms>` so successive calls produce distinct ids deterministically by clock advance.
- New pure helper `audit_on_file_pr_slug_prefix(head_sha) -> String` returns the `audit-on-file-pr-<short_sha>-` prefix used for collision detection (does NOT include the timestamp).
- New pure helper `find_in_flight_audit_worker(registry_entries, prefix)` (or equivalent on the registry surface) returns the first registry entry whose slug starts with `prefix` and whose lifecycle is *not* terminal — Done/Failed/Exitable/Finalized are not in-flight.
- `file_pr_auto_audit_for_missing_receipt` short-circuits when `file_pr_audit_receipt_validation(parent_branch, head_sha, on_disk_receipt)` returns `AuditReceiptValid` *before* any worker spawn — return `Ok(())` immediately.
- If validation is missing/stale/invalid AND `find_in_flight_audit_worker` finds an existing alive worker for this sha, await its report via `wait_for_audit_report_with_heartbeats` rather than spawning a new worker. The waited worker_id is the in-flight one.
- Otherwise, spawn a fresh worker with the new unique slug, exactly as today.
- Tests cover: pure slug generation with two distinct timestamps, prefix helper, in-flight detection (terminal vs non-terminal lifecycle), short-circuit on valid receipt, await-existing on in-flight detection, spawn-fresh on no prior worker.
- Observable: when a retry hits a still-running prior worker, `.choir/delivery.log` contains a `file_pr_auto_audit outcome=awaiting_in_flight worker=<existing_id>` line and the new file_pr call returns success after the existing worker reports.

## Non-Goals
- No change to the audit-worker prompt, report format, or budget. The worker itself is unchanged.
- No new MCP tool. All changes are internal to `src/tools/file_pr.mbt` and adjacent helpers.
- No retry/backoff loop inside file_pr. Single spawn or single wait; the caller retries if needed.
- No cleanup of orphan worktrees from prior spawns. Standard worker-finalize handles those. (If pollution becomes a problem, a follow-up watchdog can sweep.)
- No change to the `merge_pr` audit-receipt gate (choir-mu1). This bead operates on the file_pr side only; the merge gate already short-circuits when the receipt is valid.
- No persistent caching of audit *reports* (only *receipts*). Receipts are the validated form; reports are intermediate. Keep the receipt as the cache key.
- No change to `wait_for_audit_report_with_heartbeats`'s budget when awaiting an in-flight worker. The caller already gets `audit_budget_ms`; the in-flight wait uses the same budget against whatever time remains.

## Design

Single vertical-slice leaf. Touches one source file and one test file.

### 1. Unique slug + prefix helper (`src/tools/file_pr.mbt`)
- Modify `audit_on_file_pr_worker_slug` signature to `(head_sha : String, now_ms : Int64) -> String`. Return `audit_on_file_pr_internal_caller_id + "-" + file_pr_short_sha(head_sha) + "-" + now_ms.to_string()`.
- Add `pub fn audit_on_file_pr_slug_prefix(head_sha : String) -> String` returning `audit_on_file_pr_internal_caller_id + "-" + file_pr_short_sha(head_sha) + "-"`.
- `audit_on_file_pr_worker_args` now takes `now_ms` and passes it through to the slug helper.

### 2. In-flight detection (`src/tools/file_pr.mbt` + registry-friendly helper)
- Add `pub fn find_in_flight_audit_worker(entries : Array[RegistryEntry], slug_prefix : String) -> RegistryEntry?` — pure, takes a snapshot of registry entries. Returns the first non-finalized entry whose slug starts with `slug_prefix`. "Non-finalized" means lifecycle is `Working` / `ReviewOwned` / `ChangesRequested` / `WaitingForRedGate` — not `Done` / `Failed` / `Exitable`.
- The function takes the snapshot as input to keep it pure; the caller injects the snapshot via the existing `audit_worker_alive`-style adapter or a new sibling adapter `list_audit_workers : () -> Array[RegistryEntry]`.

### 3. Short-circuit on valid receipt before spawn (`file_pr_auto_audit_for_missing_receipt`)
- At the top of the function, after the branch detection, read the receipt at `file_pr_audit_receipt_path_for_head(head_sha)` via the existing capture and run `file_pr_audit_receipt_validation(parent_branch, head_sha, receipt_body)`. If `AuditReceiptValid`, return `Ok(())` immediately. Skip the spawn and the wait.
  - **Note**: this duplicates the check the caller (`file_pr_require_audit_receipt`) already did at file_pr.mbt:1303. That's intentional — between that check and entry to this function, the receipt could have appeared (concurrent file_pr or manual /audit). The double-check makes auto-audit idempotent.
- If invalid/missing/stale, proceed.

### 4. Await in-flight or spawn fresh (same function, after short-circuit)
- Call `find_in_flight_audit_worker(list_audit_workers(), audit_on_file_pr_slug_prefix(head_sha))`.
- If `Some(existing)`: bind `worker_id = existing.agent_id`. Log `file_pr_auto_audit outcome=awaiting_in_flight worker=<id>`. Skip `spawn_audit_worker(...)`. Proceed to `wait_for_audit_report_with_heartbeats` with this worker_id.
- If `None`: spawn fresh via `spawn_audit_worker(audit_on_file_pr_worker_args(project_dir, branch, head_sha, now_ms_fn()))`. Existing path.
- Everything from `wait_for_audit_report_with_heartbeats` onward stays as-is.

### 5. Adapter wiring
- `dispatch.mbt` (and any other caller of `file_pr_auto_audit_for_missing_receipt`) injects the new `list_audit_workers` adapter — bound to `registry.entries()` or equivalent. Default for tests returns `[]`.
- `now_ms_fn` is already passed in for heartbeat timing; reuse for slug generation.

### Reused patterns
- `.choir/context/patterns/thread-enum-through-wire.md` — no new stringly status; the existing `AuditReportWaitResult` enum carries the outcome.
- The existing `audit_worker_alive` adapter is the structural analog for `list_audit_workers`; mirror its injection shape.
- `file_pr_audit_receipt_validation` is reused as-is for the short-circuit.

### Wiring at call sites
- `dispatch.mbt` builds `list_audit_workers = fn() { registry.entries() }`. Tests pass a captured snapshot.
- All existing tests continue to compile by passing a default `now_ms_fn` and a default `list_audit_workers = fn() { [] }`.

## Verify
- `moon test --target native` — full suite, zero new warnings.
- New unit tests in `src/tools/file_pr_test.mbt`:
  1. `audit_on_file_pr_worker_slug(head, 1L)` and `audit_on_file_pr_worker_slug(head, 2L)` produce distinct slugs differing only by suffix.
  2. `audit_on_file_pr_slug_prefix("abc123...")` returns the expected prefix string.
  3. `find_in_flight_audit_worker` returns `Some(entry)` for a non-terminal entry whose slug starts with the prefix.
  4. Returns `None` when the only matching entry is `Done`, `Failed`, or `Exitable`.
  5. Returns `None` when no entry's slug starts with the prefix.
- New async tests for `file_pr_auto_audit_for_missing_receipt`:
  6. With a valid receipt on disk for `head_sha`, returns `Ok(())` *without* invoking `spawn_audit_worker` or `wait_for_audit_report` (assert via mock counters).
  7. With no receipt and an in-flight entry matching the prefix, calls `wait_for_audit_report` with the in-flight worker_id and does NOT call `spawn_audit_worker`.
  8. With no receipt and no in-flight entry, calls `spawn_audit_worker` with a slug ending in the supplied `now_ms` and then waits.
- Observable check (per `feedback_spec_hygiene`):
  - Stage a registry with one alive audit worker for sha `abc123` and a fresh project with no receipt; invoke the auto-audit path via the test harness. `.choir/delivery.log` contains `file_pr_auto_audit outcome=awaiting_in_flight worker=<id>`. With the same staging plus a valid receipt at `.choir/audit/abc123.json`, the log contains `file_pr_auto_audit outcome=receipt_present` and no spawn occurs.

## Boundary (do not)
- Do NOT keep the deterministic-by-sha slug. The unique suffix is the structural fix.
- Do NOT introduce a registry mutation or kill_agent call from inside `file_pr_auto_audit_for_missing_receipt`. Only read; never write. Cleanup of prior workers is the worker-finalize path's job.
- Do NOT add an audit-report disk cache. Receipts are the cache; reports are intermediate.
- Do NOT change `file_pr_audit_receipt_validation`'s signature or semantics. Reuse it as-is.
- Do NOT change the `audit_worker_alive` adapter's semantics. Add `list_audit_workers` as a sibling.
- Do NOT call `@sys.*` / `@process.*` directly in the new helpers. Pure; takes snapshots / adapters as input.
- Do NOT introduce stringly status. Outcomes flow through the existing `AuditReportWaitResult` / `Result[Unit, ChoirError]` shape.
- Do NOT add a retry loop inside `file_pr_auto_audit_for_missing_receipt`. Single spawn or single await.
- Do NOT leave behind any `legacy_*` / `compat_*` wrapper for the old deterministic slug. Replace; don't shim.
- Do NOT widen `audit_on_file_pr_worker_args` to take adapters it doesn't use. Pass only `now_ms`.
- Do NOT run `choir init` / `choir claude` / anything that spawns zellij from inside the leaf.

## Follow-Ups
- Orphan-worktree sweeper for `.choir/worktrees/audit-on-file-pr-*` directories whose registry entry is finalized but whose worktree wasn't cleaned. Today the worker-finalize path handles cleanup; if real-world retries produce orphans, a small sweeper closes that gap.
- Surface the in-flight-piggyback outcome in `wave_state` so the TL pane sees `audit_status=awaiting_in_flight` instead of inferring from log prose.
- Once choir-mu1 (merge audit gate) and this fix are both shipped, the codex-spark gh-fallback failure mode should be impossible: spark hits cap → progress-watchdog rescues with another agent_type → new agent calls file_pr → audit gate runs without collision → receipt lands → merge gate validates.
- Consider extending the same unique-slug + in-flight piggyback pattern to other deterministic-slug worker spawns (audit-on-merge worker from choir-mu1 ships with the same shape; verify it doesn't share the bug).
