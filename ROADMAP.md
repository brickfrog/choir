# Choir Roadmap

## Current state: Modern & Reliable (2026-04-03)

Choir has achieved its target architecture. The codebase is now idiomatic MoonBit, leveraging strict effect boundaries and pure planners. The PR workflow is reliable through official Reviewer Requests and contextualized Copilot guidance.

---

## 🚀 Immediate Next: Autonomous Team Flow

With the new architecture in place, plus typed task contracts and advisory evaluation, we are moving toward a "Self-Driving" team model that reduces the manual triage burden on the Team Lead.

### Autonomous Merge Decision
When a PR reaches the `MergeGateOpenPendingPolicyConfirmation` state (CI green, Copilot commented, threads resolved), the server should proactively perform the merge if the wave policy allows, or provide a one-click merge affordance in the parent terminal.

### Wave Auto-Finalization
Automatically trigger leaf `shutdown` when a PR is merged and transition the supervisor lifecycle to `WaveComplete` (or the next logical stage) without waiting for a manual check.

### Durable Team Inbox
Now that pane watching and delivery are decoupled, transition toward a durable message delivery system that doesn't rely on terminal viewport "sniffing."

---

## 🛠️ Operational Improvements

### Standardized Error Context
Leverage the new `suberror` system to provide richer, machine-readable error context across the UDS and CLI boundaries.

### Performance: Parallel Verification
Explore parallel `moon test` execution during wave reconciliation to reduce the time-to-merge for large cohorts.

---

## ✅ Completed

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
