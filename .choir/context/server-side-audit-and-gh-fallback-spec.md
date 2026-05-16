# Spec: server-side-audit-and-gh-fallback

## Context

Two related server-side resilience bugs batched into one PR because they share
the conceptual theme "the server should handle this rather than ping-ponging
work back to the TL":

- **`choir-cbm` (P2 bug)**: a `Role::Dev` leaf filing `file_pr` against `main`
  is blocked by the audit-receipt gate but CANNOT mint the receipt itself
  (`write_audit_receipt` is `allowed_roles: [Root, TL, Worker]` by design — a
  Dev forging `findings_count=0` for its own HEAD would bypass the gate). The
  only documented unblock path is a 3-trip TL handshake (leaf → notify_parent
  "need audit" → TL runs `/audit` skill → TL writes receipt → TL tells leaf
  to retry file_pr). Observed 4× this session alone (PRs #342, #343, #344,
  #345). The alternative — observed in PRs #339, #340, #341 — is the leaf
  silently violating the skill rule by writing `.choir/audit-receipts/<sha>.json`
  directly. Well-behaved leaves block; rule-breaking leaves sail through.
- **`choir-cx6` (P3 chore)**: even with `timeout 30s` bounding, `gh pr view
  --json reviews,comments` from a TL/parent context occasionally returns no
  output (live evidence on PRs #305/#308/#311/#312); the TL's review-state
  probe stalls indefinitely. Choir already maintains `poller_state.json` with
  the same data; the TL probe should fall back to the cached snapshot with a
  `stale: true, age_sec: N` flag.

Observable outcome: (1) a `fork_wave(automerge, iterative)` leaf calls
`file_pr` against `main` exactly once; the server transparently audits + writes
the receipt + finishes `gh pr create` and returns the PR URL; no TL round-trips.
(2) When a TL-context `gh pr view` stalls, the TL's caller gets a structured
`{data: <snapshot>, stale: true, age_sec: N}` from poller_state.json instead
of waiting indefinitely.

## Clarifications
> Q&A from the crystallize step. Durable; leaves read this.

**Q: choir-cbm — what does the server-side auto-audit actually DO?**
A: Spawn a Sarcasmotron-style review worker (same shape as the `/audit` skill
uses today), await its findings, write the receipt with a server-internal
caller_id, then continue the leaf's original file_pr flow. Slow (~minutes)
but parity with what `/audit` already does for TL-driven audits; the user
already accepts that latency.

**Q: choir-cbm — how does the leaf's `file_pr` call behave during the audit
wait?**
A: Block — file_pr returns when the audit completes (and the gh pr create that
follows it does). The leaf treats file_pr exactly as today; it doesn't need
to know an audit happened. Matches how file_pr already takes minutes for `gh
pr create`.

**Q: choir-cx6 — which gh calls get the poller_state.json fallback wrapper?**
A: TL/parent probes only. Wrap only the TL/parent-side gh probes the bead
names (`gh pr view --json reviews,comments`-shaped); the poller's own polling
loop, merge_pr's `gh pr merge`, and file_pr's `gh pr create` stay untouched.
Widening is a follow-up.

**Q: choir-cx6 — how does the wrapper handle staleness?**
A: Always return stale data with a flag — `{data, stale: bool, age_sec: int}`.
The caller checks `stale + age_sec` against its own tolerance (merge gate
might accept <30s old; force-merge probably wants !stale). No hard cap in
the wrapper.

## Goals

### choir-cbm — server-side auto-audit on file_pr→main for Dev leaves

- `file_pr_require_audit_receipt` in `src/tools/file_pr.mbt:697` currently
  returns `Err(file_pr_missing_audit_receipt_error(...))` when no receipt
  exists for HEAD. Replace that error path with an in-call audit:
  - Determine if the caller is a Dev leaf (look up the agent in registry; if
    `agent.role == Role::Dev`, this path applies; Root/TL/Worker callers
    still get the existing error so the TL-driven `/audit` flow keeps
    working).
  - Spawn a Sarcasmotron-style review worker via `interpret_spawn_worker`
    (or its inner plan-builder) with a server-internal caller_id (e.g.
    `"audit-on-file-pr"` or a `Role::Root` synthetic caller), a task body
    that is the Sarcasmotron persona + `git diff main...HEAD` review surface
    + the relevant spec file from `.choir/context/<slug>-spec.md` if the
    leaf's task contract references one, modeled on the `/audit` skill's
    spawn payload at `.choir/plugin/skills/audit/SKILL.md`.
  - Await the worker's `notify_parent` (success-status report). The
    interpretation here is: parse the worker's findings_count from the
    report body (the same `Finding N:` counter the `/audit` skill uses).
  - If `findings_count == 0`: call `interpret_write_audit_receipt` with the
    server-internal caller_id, the leaf's branch, and the current HEAD sha,
    persisting the receipt to `<project_dir>/.choir/audit-receipts/<short>.json`.
  - If `findings_count > 0` OR the worker reports failure: return a
    structured `ChoirError` to the leaf's file_pr call carrying the findings
    summary, so the leaf can address them, push, and retry file_pr.
  - On success, fall through to the existing `ensure_pull_request` / gh pr
    create path. The leaf's single file_pr call returns the PR URL exactly
    as if no audit had happened.
- **Worker lifecycle**: the audit worker is treated like any other
  `spawn_worker --type review`. The choir-q4y no-handoff watchdog (which we
  shipped) and the 5-min idle-kill watchdog both apply — a Sarcasmotron
  worker that wedges does not hang file_pr indefinitely. The file_pr
  preflight has an outer budget (e.g. 15 min for the whole audit + gh pr
  create) beyond which it returns a `ChoirError::timeout("audit budget
  exceeded")` so the leaf isn't stuck forever either.
- **TL-side `/audit` skill**: the existing TL skill stays exactly as today.
  This bead adds a *server-side* fast path that fires when a Dev leaf hits
  the gate; it doesn't replace the TL flow.

### choir-cx6 — `poller_state.json` fallback for TL gh probes

- New helper module `src/poller/gh_with_fallback.mbt`:
  ```
  pub(all) struct GhWithFallback {
    data : String         // gh output, or cached snapshot JSON, or ""
    stale : Bool          // false if fresh gh succeeded, true if cached
    age_sec : Int         // 0 if !stale; how old the cached snapshot is otherwise
  }
  pub async fn gh_pr_view_with_fallback(
    pr_number : Int,
    poller_state : @poller.PollerState,
    capture : async (@workspace.Command) -> (Int, String) = @exec.capture_command_stdout,
    now_sec : () -> Int64 = @poller.now_sec,
  ) -> GhWithFallback { ... }
  ```
  Runs the bounded `gh pr view --json reviews,comments,statusCheckRollup,...`
  for `pr_number`. On exit-code 0 with non-empty output: returns `{data,
  stale: false, age_sec: 0}`. On timeout (exit 124) OR exit 0 with empty
  output OR any non-zero exit: looks up the `TrackedPR` in `poller_state`,
  serializes its last-observed snapshot fields (review state, CI rollup,
  unresolved threads count, copilot_issue_comment_seen, last_sha) as JSON
  into `data`, computes `age_sec` from `tracked.last_polled_sec` (or
  equivalent) and `now_sec()`, returns `{data, stale: true, age_sec}`.
  If no TrackedPR exists for that PR number: returns `{data: "", stale:
  true, age_sec: 0}` (caller treats as no-data).
- **Pure decision function** `pub fn gh_fallback_classify(exit_code : Int,
  output : String) -> GhFallbackOutcome` returning `Fresh(output) | Stall
  | EmptyOutput | Error(exit_code)` so the wrapper's branching is
  unit-testable without a live `gh`.
- **Caller wiring**: identify the TL/parent gh-probe call sites
  (`src/tools/pr.mbt:514`'s `gh_pr_view_command(branch)` capture is the
  canonical one — confirm by grep) and route them through the new wrapper.
  Each caller decides how to use `stale`/`age_sec` (e.g. merge gate may
  accept stale < 30s; strict probes only use !stale).
- **No widening**: poller's own poll loop is NOT touched; it remains the
  source of truth that populates `poller_state.json`. merge_pr's `gh pr
  merge` is NOT touched (write-side; stale data dangerous). file_pr's `gh
  pr create` is NOT touched.

## Non-Goals

- A `request_audit` MCP tool exposed to Dev role (option (b) in choir-cbm).
  The auto-audit is opaque to the leaf; the protocol surface stays the same.
- Closing the "leaf writes receipt directly via filesystem" hole at the
  server level (option (c) in choir-cbm). With the auto-audit, well-behaved
  leaves no longer need to write directly; the hole becomes a much smaller
  concern and can be closed later if needed.
- Widening the gh-fallback wrapper beyond TL/parent probes — poller, merge_pr,
  file_pr stay on their existing gh paths.
- Changing what `write_audit_receipt` itself does (role gates, on-disk format,
  receipt fields). The server-internal caller_id flows through the existing
  tool plumbing.
- A new MCP event for "audit in progress" on the leaf side. file_pr just
  takes longer; no new surface.
- Caching staleness policy / hard cap (`stale_age_sec > N ⇒ refuse`). The
  wrapper always returns; callers decide.

## Design

### choir-cbm

`src/tools/file_pr.mbt::file_pr_require_audit_receipt` (current signature
post-PR-#343: `async fn file_pr_require_audit_receipt(parent_branch, project_dir,
file_pr_dir, capture) -> Result[Unit, ChoirError]`). Add a `caller_role :
@types.Role` parameter and (optionally) a `runner` / spawn-worker capability
for testability. When `caller_role == Role::Dev` AND the receipt is missing,
instead of returning the error:
1. Build a Sarcasmotron review-worker task body via a new helper
   `build_audit_on_file_pr_task(project_dir, branch, head_sha) -> String`
   that emits the persona + review-surface instructions modeled on
   `.choir/plugin/skills/audit/SKILL.md`. Read `.choir/context/<slug>-spec.md`
   if the branch corresponds to a wave with a known spec slug.
2. Spawn the worker through the existing `interpret_spawn_worker` path
   with `caller_id = "audit-on-file-pr"` (or a server-internal sentinel
   resolved via the registry as a synthetic Root). Wait for its
   `notify_parent` (event-driven, not polling — reuse the existing
   notify-parent capture seam).
3. Parse `findings_count` from the worker's report body (the `Finding N:`
   counter; reuse the parsing logic from the `/audit` skill's response
   handling — currently in markdown; lift the count-parsing into a pure
   `pub fn parse_findings_count(report : String) -> Int` in the appropriate
   module).
4. If `findings_count == 0`: call `interpret_write_audit_receipt` with the
   server-internal caller_id, leaf's branch, and HEAD sha. Continue.
5. If `findings_count > 0`: return `ChoirError::audit_findings_remain(short_sha,
   findings_count, summary_line)` — a new ChoirError variant or use the
   existing `file_pr_audit_findings_remain_error` shape; surface up to ~3
   finding lines from the worker's report.
6. Outer budget: wrap the spawn+await in a `bounded_audit_budget_sec`
   timeout (default 900s / 15 min); on expiry, return
   `ChoirError::timeout("audit budget exceeded")` so the leaf isn't stuck.

Tests in `src/tools/file_pr_test.mbt`:
- Mock the spawn-worker seam (inject a runner/capture capability returning
  a synthetic notify_parent report). Truth table: Dev caller + missing
  receipt + worker returns findings_count=0 ⇒ Ok + receipt file exists at
  `<project_dir>/.choir/audit-receipts/<short>.json`. Dev caller + missing
  receipt + worker returns findings_count=3 ⇒ specific ChoirError carrying
  the count. TL caller + missing receipt ⇒ existing missing-receipt error
  (TL-driven /audit path preserved). Dev caller + existing valid receipt ⇒
  no audit spawned (existing happy path).
- Outer-budget timeout: mock the spawn-worker capture to never return;
  assert the call returns the timeout ChoirError within the budget.

### choir-cx6

New module `src/poller/gh_with_fallback.mbt`:
- `pub(all) enum GhFallbackOutcome { Fresh(String) ; Stall ; EmptyOutput ;
  Error(Int) } derive(Debug, Eq)`.
- `pub fn gh_fallback_classify(exit_code, output) -> GhFallbackOutcome` —
  pure decision: 124 ⇒ Stall; 0 + empty(trimmed) ⇒ EmptyOutput; 0 +
  non-empty ⇒ Fresh; else Error(code).
- `pub(all) struct GhWithFallback { data : String ; stale : Bool ; age_sec
  : Int } derive(Debug, Eq)`.
- `pub async fn gh_pr_view_with_fallback(pr_number, poller_state, capture?,
  now_sec?) -> GhWithFallback` — wraps the existing `gh_pr_view_command`
  shape, runs `capture` with `timeout 30s` bounding (reuse the existing
  bounding helper if one exists; otherwise pre-pend `timeout` to args),
  classifies the outcome, falls back to `poller_state.tracked[pr_number]`'s
  serialized snapshot if not Fresh.
- Snapshot serialization helper `pub fn tracked_pr_snapshot_json(tracked
  : @poller.TrackedPR) -> String` that emits the same JSON shape `gh pr
  view --json reviews,comments,statusCheckRollup,...` produces (or as close
  as we can; the bead's existing callers parse a specific subset — match
  that subset).

Call sites identified in `src/tools/pr.mbt:514` and `src/poller/gh_spawn.mbt:143`
(`parse_gh_pr_view_output`-fed paths): route the TL-context calls through
the new wrapper. Don't touch the poller's own poll loop (it populates the
state we're falling back to — must stay on the live path).

Tests in `src/poller/gh_with_fallback_test.mbt`:
- `gh_fallback_classify` truth table (all 4 outcomes).
- `gh_pr_view_with_fallback`: mock the capture to return Fresh ⇒ `{stale:
  false}`; mock to return Stall AND populate poller_state with a snapshot
  ⇒ `{data: <snapshot json>, stale: true, age_sec: N}`; mock Stall + no
  tracked PR ⇒ `{data: "", stale: true, age_sec: 0}`.

## Verify

- `moon test --target native`: tests for the cbm audit-spawn truth table
  (Dev+missing+0-findings, Dev+missing+N-findings, TL+missing, Dev+existing,
  outer-budget-timeout); tests for cx6's pure classifier + the wrapper's
  Fresh/Stall/EmptyOutput/Error→fallback truth table; existing
  `file_pr_test.mbt` + poller tests stay green.
- Observable (smoke, document in PR): on a fresh wave, a `fork_wave(automerge,
  iterative)` Dev leaf that previously hit the receipt gate now files PR
  successfully on the first `file_pr` call (no notify_parent BLOCKED, no
  manual TL audit). `choir logs --grep "audit-on-file-pr"` shows the
  spawn + completion. Also: `grep -A8 "audit-on-file-pr"
  .choir/audit-receipts/<short>.json` shows the server-minted receipt with
  `agent_id: "audit-on-file-pr"` (or whatever sentinel is chosen).
- `grep -c "gh_pr_view_with_fallback" src/tools/pr.mbt src/poller/gh_spawn.mbt`
  ⇒ ≥1 (wrapper actually wired); the poller's own poll loop file
  (`src/poller/poller.mbt` or wherever the polling tick lives) ⇒ no
  reference (poller untouched).

## Boundary (do not)

- The auto-audit fires ONLY for `caller_role == Role::Dev` AND a missing/invalid
  receipt for the current HEAD. TL/Root/Worker callers hitting the gate
  still get the existing missing-receipt error (the `/audit` skill's flow
  stays intact). Existing valid receipts ⇒ no audit spawned.
- The audit must use the existing `spawn_worker` + `write_audit_receipt`
  paths — no parallel receipt-writing path that bypasses role gates.
- file_pr's outer budget for the audit MUST timeout cleanly with a structured
  error, never hang the leaf's call indefinitely.
- The cx6 wrapper applies ONLY to TL/parent-context `gh pr view`-shaped
  probes named in the bead. The poller's own poll loop, merge_pr's gh pr
  merge, and file_pr's gh pr create are untouched.
- The wrapper always returns; never raises. Callers branch on
  `stale`/`age_sec` themselves.
- No new MCP tool surface. No new poller event types.
- No `@sys.*`/`@process.*` direct calls in `src/server`/`src/tools`/`src/poller`
  beyond existing adapter seams.
- Use `Role` / `GhFallbackOutcome` enums (not strings); `ChoirError` for new
  error paths.
- Tests hermetic — mock the spawn-worker seam, mock the gh capture, no
  real-checkout/repo-git/network mutation.

## Follow-Ups

- Widen the gh-fallback wrapper to merge_pr's `gh pr merge` and file_pr's
  `gh pr create` if stalls are observed there (write-side; needs careful
  staleness rules).
- Close the "leaf writes receipt directly via filesystem" hole at the
  server level (e.g. receipt JSON must carry a server-signed token), only
  if observed needing it after this lands.
- A typed `request_audit` MCP tool for Dev role if observed needing explicit
  leaf-initiated audits in addition to the auto path.
- Allow the auto-audit to skip Sarcasmotron and just run tests for
  small/mechanical PRs (heuristic: diff size, file types). Defer; the
  current Sarcasmotron-on-every-Dev-file_pr is a safe default.
