# Choir Roadmap

## Current state: Merge Audit and Operator UX (2026-04-10)

Choir now has typed task contracts, a typed evidence ledger, a pure merge policy, an explicit automerge control plane, hard TL parent-branch enforcement, a durable outbox for server-originated human notifications, a unified external-merge reconciliation path, and operator-facing merge audit surfaces. Parent notifications, wave rollups, and the statusline now distinguish manual merge, server automerge, force override, and external observation without relying on ad hoc wording. The codebase remains idiomatic MoonBit with strict effect boundaries and pure planners, and the PR workflow is reliable through official Reviewer Requests and contextualized Copilot guidance.

---

## 🚀 Immediate Next: External Task Memory Provider

The merge control plane and operator UX are now explicit. The next step in this milestone is task-memory integration rather than more merge-surface cleanup.

- Pilot Chainlink as an optional task-memory provider instead of building a Choir-native issue tracker.
- Start with read-only import of active issue, subissue, dependencies, and handoff context into `TaskContract`.
- Add write-back for PR URL, execution status, merge outcome, and concise handoff notes.
- Treat specs and task structure as living inputs that evolve during execution, not as a rigid up-front gate.
- Non-goal: do not rebuild Chainlink inside Choir unless the pilot exposes a hard architectural gap.

---

## 🛠️ Operational Improvements

### Standardized Error Context
Leverage the new `suberror` system to provide richer, machine-readable error context across the UDS and CLI boundaries.

### Performance: Parallel Verification
Explore parallel `moon test` execution during wave reconciliation to reduce the time-to-merge for large cohorts.

### Adversarial Review Mode
Add an optional high-ceremony path for risky work where Choir requests a fresh-context adversarial review pass before merge. This should layer onto the existing evidence and policy system rather than creating a separate workflow.

---

## ✅ Completed

### Merge Audit and Operator UX (2026-04-10)
- **Explicit Merge Provenance**: Authoritative `[PR MERGED]` notifications now identify whether the merge came from manual `merge_pr`, server automerge, `force=true`, or external observation.
- **Mode-Aware Parent Messaging**: Parent-facing readiness notifications now show `merge_mode: manual` vs `merge_mode: automerge`, and `[MERGE READY]` is actionable only in manual mode.
- **Wave and Statusline Visibility**: Wave rollups can show merge mode in the header, and the CLI statusline now distinguishes manual merge-ready PRs from automerge-ready PRs.
- **Force Override Audit**: `merge_pr force=true` remains explicit in operator-facing merged notifications instead of being buried in evidence only.
- **Quiet Recovery Finalization**: Restart recovery still reconciles merged leaves to `Finalized(Merged)` but no longer interrupts the TL with a fresh `[PR MERGED]` on startup.
- **Focused Coverage**: Tests cover parent message rendering, rollup formatting, compact statusline signals, and quiet recovery finalization.

### External Merge and Orphan Reconciliation (2026-04-10)
- **Unified External-Merge Path**: Poller-observed `PRMerged` events now carry the full tracked-PR snapshot (branch, URL, review, CI) so the server does not lose context when the poller untracks.
- **Canonical Finalization**: `plan_external_merge_finalization` reuses `plan_finalize(...Merged)` so poller merges, manual merges, and `merge_pr` all converge to the same `Finalized(Merged)` lifecycle outcome.
- **Typed Merge Source**: `DeliverToParentMerged` now carries a typed merge source (tool, poller, recovery) and the parent notification no longer emits stale "call shutdown" / "kill the leaf" guidance.
- **Recovery Convergence**: Restart recovery records targeted non-open PR status for known tracked PRs and agent branches, emits `FinalizeMergedAgent`, and converges to `Finalized(Merged)` instead of generic `RecoveredDone`.
- **Orphan/Stall Suppression**: Orphan and stall notifications are suppressed once the lifecycle is already terminal (`Finalized` or `Failed`), eliminating repeated nudges for externally-merged PRs.
- **Merge Evidence from Snapshot**: Evidence events are now persisted from the preserved tracked-PR snapshot at external-merge time, not just from the `merge_pr` tool path.
- **Focused Coverage**: 783 tests passing, with new coverage in `post_tool_test.mbt`, `recovery_test.mbt`, `server_test.mbt`, and `tl_decision_test.mbt`.

### Durable Team Inbox (V1, 2026-04-09)
- **Durable Outbox**: Server-originated human notifications now persist in `.choir/outbox/*.jsonl` instead of relying on pane visibility as the source of truth.
- **Replay After Restart**: Pending outbox messages are replayed on startup after recovery, so missed parent notifications survive `choir init --recreate`.
- **Explicit Message State**: Notifications now carry typed `pending`, `delivered`, and `expired` states with delivery-attempt metadata.
- **Adapter Boundary Preserved**: Existing pane delivery remains an adapter layer; evidence and policy state are still tracked separately from human-facing messages.
- **Focused Coverage**: Tests cover snapshot reduction, expiry/compaction, startup replay, and the root-recipient replay path.

### TL Policy Enforcement (V1, 2026-04-09)
- **Hard Parent-Branch Guard**: Active TLs are now blocked from non-doc parent-branch work while a live wave is active unless explicitly overridden.
- **Leaf-Mode Detection**: Enforcement reads persisted supervisor lifecycle and changed-path classification rather than relying only on prompt etiquette.
- **Explicit Override Path**: Parent-branch work can be temporarily unblocked through a dedicated `tl-parent-override` control path instead of prompt interpretation.
- **Root TL Coverage**: The root TL launched by `choir init` and spawned TLs now run under the same policy supervision path.
- **Focused Coverage**: Tests cover policy classification, launch wrapping, and regression cases around TL enforcement.

### TL Prompt Guardrails (2026-04-09)
- **Leaf-Mode Prompt Rule**: MCP initialize instructions now explicitly say that if the user asked for implementation via leaves/waves/agents, the TL must not implement the feature directly on the parent branch.
- **Allowed Parent Scope**: The prompt narrows parent-branch work to pre-fork scaffold, integrating completed leaf work, or cleaning up stale leaves/PRs.
- **Supersede Cleanup Rule**: The prompt now requires killing superseded leaves immediately and closing or abandoning their PRs before continuing.
- **Regression Coverage**: MCP tests assert that those prompt constraints remain present in the initialize instructions.

### Stale Leaf PR Reconciliation (2026-04-09)
- **Parent-Kill PR Cleanup**: `kill_agent` now reconciles tracked PRs for intentionally killed leaves instead of letting them drift into generic orphan state.
- **Server-Side Auto-Close**: The server issues `gh pr close` directly for those stale PRs and untracks them on success.
- **One-Shot Operator Signal**: Parents now get a single `[STALE PR CLOSED]` or `[STALE PR CLOSE FAILED]` message rather than repeated orphan noise.
- **Poller Quiet Period**: Tracked PR state now records reconciliation-in-progress so the poller does not race the cleanup path with `[ORPHANED PR]` while the server is already resolving it.
- **Focused Coverage**: Poller/server tests now cover reconciliation suppression, close success, and close failure behavior.

### Formalized Auto-Merge Control Plane (2026-04-09)
- **Explicit Auto-Merge Config**: `Config.automerge` now defines the global default, and spawned leaves can persist a per-wave override in `config.local.toml`.
- **Server-Triggered Merge Execution**: The poller/handler path now interprets `MergeDecision::MergeNow` and can invoke the existing `merge_pr` path without relying on the TL prompt as the trigger.
- **Single Merge Executor**: Auto-merge and manual merge both go through `merge_pr`, so preflight policy checks, mutexing, evidence logging, and post-merge lifecycle updates remain unified.
- **Typed Merge Provenance**: Evidence now records whether merge execution was requested manually, via server automerge, or via force override.
- **Forward-Compatible Tool Surface**: `fork_wave` now exposes an `automerge` argument in the registry and MCP schema, and TL instructions explain how manual mode and automerge mode differ.
- **Verification Coverage**: Native build, type-check, and test coverage now exercise the automerge trigger and evidence path.

### Typed Evidence Ledger, Merge Policy & Refresh Reliability (2026-04-09)
- **Typed Evidence Ledger**: Agent-local JSONL evidence now records normalized CI, review, threads, Copilot, verify, merge, and override events.
- **Replayable Evaluation State**: Evidence can be replayed into typed evaluation bundles instead of re-deriving policy only from ad hoc snapshots.
- **Pure Merge Policy**: `MergeDecision::MergeNow | Wait | Blocked | NeedsHuman` now exists as a pure policy layer over typed evaluation data.
- **Policy-Backed Manual Merge Gating**: `merge_pr` preflight now blocks on typed policy decisions unless explicitly overridden with `force=true`.
- **Copilot Review Semantics Tightened**: Comment-only review now counts toward merge readiness only when the Copilot issue comment has actually been observed.
- **Explicit Refresh Reliability**: Manual PR refresh bypasses poller backoff and emits a re-check path even when the snapshot is otherwise unchanged.

### Typed Intent Contracts & Advisory Evaluation (2026-04-08)
- **Typed Task Contracts**: Canonical `TaskContract` values now carry goal, scope, acceptance checks, constraints, non-goals, review context, and verify commands through spawn planning.
- **Backward-Compatible Tool Inputs**: Existing prompt-shaped tool arguments still work, but now canonicalize into typed task data before prompt rendering.
- **Persisted Contract Context**: Spawned agents now persist `task_contract_json` in `config.local.toml`, so lifecycle, recovery, and parent summaries can recover the original typed task intent.
- **Advisory Evaluation Layer**: CI state, review state, unresolved-thread observations, Copilot presence, and local verify results now normalize into typed evaluation bundles and verdicts.
- **TL Merge Readiness Summaries**: PR recheck summaries now include advisory `ready` / `blocked` / `needs_human` evaluation output without enabling autonomous merge yet.
- **Parser Boundary Cleanup**: Local TOML parsing now round-trips escaped structured strings correctly at the I/O edge instead of leaking transport quirks into planner code.

### 100% Architecture Purification (Migrations 1-6)
- **Hard Effect Boundary**: Orchestration logic is now separated from host I/O.
- **Pure Planners**: Lifecycles, tool execution, and recovery are now pure data-to-data functions.
- **Host Adapters**: Formal boundaries for Zellij, GitHub, and Filesystem.
- **Idiomatic Conversion**: Eliminated 1,500+ lines of boilerplate; switched to `raise`, `suberror`, and derived JSON.

### Copilot Reliability & Context
- **Automated Reviewer Requests**: Replaced flaky comment-triggers with official `gh pr edit --add-reviewer @copilot`.
- **Context Injection**: Automated `@copilot review: <context>` to guide adversarial reviews.
- **Login Recognition**: Robust detection of both bot and non-bot Copilot identities.

### Pi × Choir North Star
- Pi as a first-class TL/leaf/worker runtime.
- Structured `choir tool` control plane.
- Pi extension for native tool exposure.
- Restart-recovery for offline agents and open PRs.

### Core Foundation
- MoonBit-based local server with UDS transport.
- Git worktree-based leaf isolation.
- Typed state machines for all roles.
- CAN bus-style event logging and delivery.
