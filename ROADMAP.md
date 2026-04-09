# Choir Roadmap

## Current state: Policy-Driven Merge Control (2026-04-09)

Choir now has typed task contracts, a typed evidence ledger, a pure merge policy, and an explicit automerge control plane. `fork_wave` can persist a per-wave `automerge` override, the server can trigger the existing `merge_pr` path when policy reaches `MergeNow`, and merge provenance is recorded as manual, server-automerge, or force-override. The codebase remains idiomatic MoonBit with strict effect boundaries and pure planners, and the PR workflow is reliable through official Reviewer Requests and contextualized Copilot guidance. TL prompt guidance now explicitly forbids parent-branch feature work when the user asked for leaf execution, and parent-killed stale leaf PRs are reconciled instead of left to generic orphan spam.

---

## 🚀 Immediate Next: Delivery and Supervision

The next milestone is not more merge architecture. The merge control plane is now explicit. The next work is making delivery, cleanup, and operator visibility as durable as the policy layer.

### 1. TL Policy Enforcement
- Prompt text is not enough. Add hard server-side enforcement so an active TL cannot implement feature work on the parent branch while a wave is live unless the user explicitly overrides it.
- Detect "leaf mode" from active spawned children / tracked wave state and reject parent-branch non-doc writes in that mode.
- Allow narrowly-scoped exceptions for pre-fork scaffold, integration of completed leaf work, and cleanup of stale leaves/PRs.
- Surface a direct policy error when the TL attempts prohibited parent-branch implementation instead of relying on etiquette.
- Extend the same enforcement to superseded leaves so kill/close happens as a control-plane rule, not just an instruction in the prompt.

### 2. Durable Team Inbox
- Replace viewport-sniffed delivery assumptions with a durable inbox or queue model.
- Persist outbound parent/child messages until acknowledged or expired.
- Re-deliver pending important notifications after restart.
- Separate "evidence for policy" from "messages for humans" so retries do not duplicate policy state.
- Keep the current pane integrations as adapters, not as the source of truth.

### 3. External Merge and Orphan Reconciliation
- Initial stale-leaf cleanup is now in place: `kill_agent` auto-closes tracked PRs for parent-killed leaves, emits one explicit stale-PR outcome to the parent, and suppresses generic orphan spam for that path.
- Tighten the post-merge/finalization path for merges observed outside the server-triggered `merge_pr` flow.
- Ensure external merges, manual merges, and recovered leaves converge to one canonical lifecycle outcome.
- Reduce repeated re-check nudges once a leaf is definitely done in the remaining external/manual-merge paths.
- Add focused tests for merged-orphan cleanup and restart recovery after merge.

### 4. Merge Audit and Operator UX
- Surface merge provenance and policy reason clearly in TL/operator summaries.
- Make it obvious when a wave is `automerge=true` versus manual mode.
- Improve parent-facing notifications so `[MERGE READY]` is informational when automerge is enabled and actionable when it is not.
- Keep `merge_pr force=true` as an explicit override path with evidence attached.

### 5. External Task Memory Provider
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
