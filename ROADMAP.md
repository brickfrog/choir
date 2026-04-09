# Choir Roadmap

## Current state: Policy-Ready Core (2026-04-09)

Choir now has the core pieces needed for policy-driven autonomy: typed task contracts, a typed evidence ledger, a pure merge policy, and manual merge gating backed by that policy. The codebase remains idiomatic MoonBit with strict effect boundaries and pure planners, and the PR workflow is reliable through official Reviewer Requests and contextualized Copilot guidance.

---

## 🚀 Immediate Next: Policy-Driven Autonomy

The next milestone is not more architecture work. It is executing the new typed policy layer end-to-end so the Team Lead stops doing repetitive merge and cleanup work by hand.

### 1. Autonomous Merge Execution
- Add an explicit per-wave or per-PR opt-in policy flag for autonomous merge.
- Interpret `MergeDecision::MergeNow` in the server/poller path instead of only surfacing it in summaries and `merge_pr` preflight.
- Preserve manual `merge_pr` as the override and fallback path.
- Require clear audit evidence for every autonomous merge decision, including the exact typed reason.
- Add end-to-end tests for `MergeNow`, `Wait`, `Blocked`, and `NeedsHuman`.

### 2. Wave Auto-Finalization
- When merge is observed, automatically shut down the owning leaf if appropriate.
- Transition the lifecycle to the correct completed state without waiting for manual TL cleanup.
- Clear tracked PR state and persist the final evidence/lifecycle snapshot.
- Notify the parent with one canonical completion message instead of repeated re-check nudges.
- Add tests for normal merge, external merge, forced merge, and merged-orphan cleanup.

### 3. Durable Team Inbox
- Replace viewport-sniffed delivery assumptions with a durable inbox or queue model.
- Persist outbound parent/child messages until acknowledged or expired.
- Re-deliver pending important notifications after restart.
- Separate "evidence for policy" from "messages for humans" so retries do not duplicate policy state.
- Keep the current pane integrations as adapters, not as the source of truth.

### 4. External Task Memory Provider
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
