# Spec: audit-tl-visibility

## Context

`audit-on-file-pr` Sarcasmotron workers run during every leaf's `file_pr` call. Each cycle takes 8–12 minutes and may emit N findings the leaf must address before the PR is filed. Today this loop is **invisible to the TL**: `wave_state` reports the leaf as `Dev/Working`, no `notify_parent` fires, no `send_message` arrives, and the only trace is in `serve.log`'s stderr stream. During the `choir-u7v` wave I sat polling `wave_state` for an hour while two leaves silently iterated through 5+ Sarcasmotron rounds each — I read the silence as "leaves stuck" and admin-merged through unresolved findings.

We want the audit loop to be a **first-class observable subsystem**: the TL sees each cycle start, sees the full findings on return, sees the cycle count climbing, and gets a hard backstop that escalates to the TL before the wave silently re-loops forever.

## Clarifications

**Q: How should audit progress reach the TL?**
A: wave_state field + push notification. Add a typed `audits` array under `WaveStateChild.pr` so the TL can query state on demand, AND have the server push a one-line digest to the TL pane via `send_message` on each audit-cycle return event (started, findings_count, abbreviated finding text). Combined: cheap polling + visible pivot moments.

**Q: How much finding content reaches the TL?**
A: Full finding text + receipt path. Every Sarcasmotron line goes into the push notification, and the receipt path (`.choir/audit-receipts/<sha>.json`) is appended so the TL can grep back later. Accept ~1–3KB per notification — message volume is bounded by audit cycle frequency, not noise.

**Q: Should the system auto-abort an audit loop after N consecutive rounds with findings?**
A: **Hard limit at 3 rounds, escalate to TL — and make the limit configurable in `.choir/config.toml`.** After 3 audit-fix-retry cycles, the audit worker stops re-running and the leaf's next `file_pr` call gets back a typed `AuditLoopExhausted` error with the round count and remaining-findings text. The TL pane receives a `send_message` saying `[AUDIT LOOP EXHAUSTED] N cycles, M findings remain on PR #X — TL decision required`. Config key: `audit_max_rounds : Int` (default `3`).

**Q: Auto-post audit findings as PR comments?**
A: Yes, each audit cycle posts a PR comment. The server posts the Sarcasmotron findings as a `gh pr comment` on the leaf's PR after every audit cycle, tagged `[AUDIT cycle N]` so the chronology is visible on GitHub. Replaces today's manual retroactive comments (the ones I added on PR #386 / #387). When `audit_max_rounds` is hit, the final comment is `[AUDIT cycle N — LOOP EXHAUSTED]` with the same body so an off-line reviewer sees why the loop stopped.

## Goals

- TL can read per-leaf audit-loop state from `wave_state` at any time: cycle count, last-cycle findings count, last receipt path, exhausted flag.
- TL receives a `send_message` notification at each audit transition (started, returned with N findings, exhausted) containing the full findings text and the receipt path.
- The audit subsystem hard-stops after `audit_max_rounds` cycles (default 3, configurable via `.choir/config.toml`'s `audit_max_rounds`).
- Each audit cycle posts a tagged comment on the leaf's PR via `gh pr comment` so the audit chronology is durable on GitHub.
- A reader on the PR (`gh pr view <N>`) can see the full audit history without needing repo-local files.
- The TL pane never falls into the silent-`Dev/Working` failure mode again — every audit cycle is a visible event.

## Non-Goals

- Replacing Sarcasmotron with a different auditor. Out of scope.
- Auto-merging when the audit returns clean. The TL still decides; this spec is about visibility, not policy.
- Changing the audit prompt or findings format. Sarcasmotron's persona stays as-is.
- Eliminating the admin-merge path (covered separately by `choir-t92` and the gh shim ban).
- Auto-resolving Copilot threads. That's `choir-9z3`.
- Building a new audit UI. The surface stays: `wave_state` query, `send_message` push, PR comment, audit receipt.

## Design

Four leaves, mostly independent file ownership:

### Leaf A: wave_state field for audit progress

**Files (exclusive):** `src/tools/wave_state.mbt`, possibly `src/server/state.mbt` (add audit progress map keyed by agent_id, parallel to the existing `audit_on_file_pr_reports`).

**Approach:** Extend `WaveStatePR` (`src/tools/wave_state.mbt:7-21`) with an `audits` field:
```moonbit
audits : WaveStateAuditProgress?
```
where `WaveStateAuditProgress` is a new struct: `cycles_so_far : Int`, `last_findings_count : Int?`, `last_receipt_path : String?`, `last_cycle_at_ms : Int64?`, `exhausted : Bool`. ToJson derived. `audits=None` when the leaf hasn't entered an audit cycle yet; `audits=Some(...)` after the first cycle.

The state lives on `ServerState` as a `Map[String, AuditProgress]` keyed by agent_id, populated by the audit worker lifecycle hooks (started / report-captured / exhausted).

### Leaf B: send_message push on every audit event

**Files (exclusive):** `src/tools/file_pr.mbt` (around the existing `wait_for_audit_report_with_heartbeats` flow at line 741), `src/server/state.mbt` (capture hook).

**Approach:** When `capture_audit_on_file_pr_report` (`src/server/state.mbt:148`) fires, look up the leaf's parent agent_id and send a `send_message` to the parent pane with:
```
[AUDIT cycle <N>] PR #<pr_number> on <branch>
findings_count=<M>
receipt: .choir/audit-receipts/<sha>.json

<full Sarcasmotron findings text, verbatim>
```
Similarly for the "audit started" event (fire when the worker registers) — a one-liner `[AUDIT cycle <N> started] PR #<pr_number>`. And for exhaustion — `[AUDIT LOOP EXHAUSTED] N cycles, M findings remain — TL decision required`.

### Leaf C: configurable hard limit (default 3), exhaustion path

**Files (exclusive):** `src/types/config.mbt` (add `audit_max_rounds : Int` field, default 3, with a `audit_max_rounds_max` ceiling like the existing `audit_heartbeat_sec_max`), `src/tools/file_pr.mbt` (track cycle count per agent_id, return typed `AuditLoopExhausted` after limit), `src/types/error.mbt` (new `ChoirError::AuditLoopExhausted { cycles : Int, findings_count : Int, receipt_path : String }` variant).

**Approach:** The cycle counter lives on `ServerState` (new `Map[String, Int]` keyed by agent_id, incremented per `capture_audit_on_file_pr_report` call). When `cycle_count >= config.audit_max_rounds` AND the latest report has `findings_count > 0`, `file_pr` returns `Err(ChoirError::AuditLoopExhausted)` to the leaf instead of running another audit. The leaf's existing error-handling surfaces the message to the TL. Concurrent: the server-side notification from Leaf B emits `[AUDIT LOOP EXHAUSTED]` simultaneously so the TL has both pull (file_pr error) and push (send_message).

### Leaf D: auto-post PR comments per cycle

**Files (exclusive):** `src/tools/file_pr.mbt` (the cycle-return path), plus a new helper in `src/poller/gh.mbt` (or `src/poller/gh_spawn.mbt`) that runs `gh pr comment <pr> --body <findings>` via the existing `gh_spawn` capture pattern. Do not use raw `@process.run` — go through the same exec adapter the poller uses.

**Approach:** On each `capture_audit_on_file_pr_report`, after the wave_state and send_message updates, post a PR comment tagged `[AUDIT cycle N]` with the full findings text + receipt path. On exhaustion, the final comment is `[AUDIT cycle N — LOOP EXHAUSTED]` with the remaining-findings body. The comment-posting itself is fire-and-forget for the leaf (don't block the leaf's `file_pr` return on a slow `gh pr comment` round-trip; capture+log error if it fails but continue).

## Verify

Per `feedback_spec_hygiene`, must include at least one observable verify command:

- `moon check --target native` clean.
- `moon test --target native` green — all four leaves' new unit tests pass.
- **Observable:** spawn a real wave that triggers an audit cycle (e.g., a leaf intentionally touching `src/server/log.mbt` without injected adapters), then:
  - `mcp__choir__wave_state caller_id=root` returns `.children[].pr.audits` populated with cycle count, findings count, receipt path.
  - The TL pane received at least one `[AUDIT cycle ...]` send_message with the verbatim Sarcasmotron text.
  - `gh pr view <N>` shows tagged `[AUDIT cycle N]` comments matching the cycle count.
- **Loop limit:** set `audit_max_rounds = 1` in `.choir/config.toml`, spawn a wave where the audit will find a defect, observe the leaf's `file_pr` returns `AuditLoopExhausted` after one cycle and the TL pane receives `[AUDIT LOOP EXHAUSTED]`.
- **Default config:** absent `audit_max_rounds`, the system uses 3 (existing config-default unit test pattern in `src/types/config_test.mbt`).

## Boundary (do not)

- Do NOT raw-`gh pr comment` from a leaf worktree — go through the gh shim or the poller's gh capture adapter. The shim path keeps the comment auditable in `serve.log`.
- Do NOT block the leaf's `file_pr` return on `gh pr comment` completion. Fire-and-forget with error capture.
- Do NOT remove the existing `audit_on_file_pr_reports` queue surface in `src/server/state.mbt` — the new push notifications are additive, not a replacement; the queue is still how the leaf waits for the report.
- Do NOT change the Sarcasmotron persona, prompt, or findings format. The audit subsystem's output stays as-is; this spec only changes what choir does WITH that output.
- Do NOT add a new authority that auto-merges on audit clean. TL still owns the merge decision; this spec adds visibility, not policy.
- Do NOT skip the `audit_max_rounds` config plumbing — the limit MUST be readable from `.choir/config.toml`, not hardcoded.
- Do NOT make audit-comments-on-PR optional via config. Always-on by design; this is the durable artifact rule from PR #388.

## Follow-Ups

- `choir-t92` (audit gate bypass via gh pr merge) — related but separate; this spec doesn't enforce the gate, only makes the bypass visible.
- `choir-9z3` (auto-resolve threads) — adjacent observability concern; could share the `send_message` notification plumbing.
- Audit-receipt rotation: receipts in `.choir/audit-receipts/` accumulate forever. Worth a follow-up bead to cap retention (e.g., last 100 receipts or 30 days).
- Configurable per-PR comment style: future bead could let projects opt for a single rolling "audit thread" instead of N tagged comments. Not in this spec; default is N tagged comments.
- Cycle-history compaction: `wave_state.audits` only carries the last cycle's summary. A future bead could expose the full cycle history (or link to it in the receipt).
