# Choir × Pi North Star Spec

**Status:** Core Choir × Pi shift and all follow-on architecture migrations (1-6) are **100% complete** and live-validated on main.  
**Last updated:** 2026-04-03

## One-sentence north star

Make **Pi a first-class Choir agent runtime and operator surface** without moving orchestration logic out of Choir: Choir remains the typed, authoritative orchestration core; MCP becomes one adapter among several; Pi integration is built on a **first-class CLI/JSON control plane** plus a **Pi extension**.

---

## Why this document exists

This is a **navigation document**, not a ticket list. Its purpose is to keep implementation aligned when the work branches into multiple intermediate steps.

Whenever a design choice is ambiguous, prefer the option that best preserves the following:

1. **Choir owns orchestration.**
2. **Pi owns local agent UX/tooling, not orchestration state.**
3. **There is exactly one authoritative orchestration path inside Choir.**
4. **MCP is optional infrastructure, not the architectural center.**

---

## Implementation reality snapshot (2026-04-03)

The project has achieved its target architecture. Choir is now a modern MoonBit orchestrator with a strict separation between pure logic and effectful host adapters.

- **Unified Control Plane**: `choir tool ...` is the authoritative structured interface.
- **Thin Adapters**: MCP, CLI, and the Pi extension are all thin wrappers over the same core.
- **Pure Orchestration**: All major orchestration loops (Lifecycles, Tools, Recovery, Post-Tool Actions) are implemented as pure planners that emit typed effect lists.
- **Host Boundaries**: All I/O (Process, Git, GitHub, Zellij, Filesystem) is contained within formal host adapters and injected via interpreted effect patterns.
- **Reliable Workflow**: Copilot reviews are automated via official Reviewer Requests and contextualized comments, ensuring a high-confidence PR loop.
- **MoonBit Idioms**: The codebase leverages modern MoonBit features including `suberror`, `raise/try`, and `derive(ToJson, FromJson)`, eliminating over 1,500 lines of manual boilerplate.

---

## Remaining intentional production shell boundaries

Core paths no longer depend on **ambient** `sh -c` orchestration for normal control flow. What remains are **explicit, localized** process edges:

| Boundary | Location (concept) | Why it remains |
|----------|-------------------|----------------|
| **TL init tab trailer** | `src/workspace/spawn.mbt` | Zellij has no “on agent exit, run …” hook; chaining with `exec bash` requires a shell. |
| **Plugin capture fallback** | `src/exec/exec.mbt` | Fallback for complex plugin commands that cannot be treated as a plain argv list. |
| **Remote SSH transport** | `src/workspace/spawn.mbt` | OpenSSH executes remote command strings through the remote user’s default shell. |
| **Smoke script execution** | `src/bin/choir/smoke_launch.mbt` | Uses a POSIX shell to execute embedded smoke script files. |

---

## Final architecture verdict

- **Choir successfully satisfies the exomonad-style invariant**: orchestration logic makes decisions and drives state transitions without ambient I/O power.
- **Testability**: 100% of the orchestration logic (lifecycles, tool plans, recovery reconciliation) is testable in isolation using synthetic effect snapshots.
- **Modernity**: The codebase is lean, idiomatic, and leverages the full power of the MoonBit type system.

---

## Completed migration plan

#### Phase 1 — Finish the easy seam work first [x]
- **Done**: Removed all direct `@sys.system()` calls in orchestration paths. All capture points are injectable. Dead init/test drift removed.

#### Phase 2 — Split lifecycle core from lifecycle persistence [x]
- **Done**: Lifecycle transitions are now pure planners that emit `LifecycleEffect` arrays. Persistence is an interpreter concern. Unified Supervisor/TL models.

#### Phase 3 — Break dispatch into tool core + effect interpreters [x]
- **Done**: `dispatch.mbt` is now a thin routing glue. Tools like `file_pr`, `merge_pr`, and spawn/teardown tools are refactored into pure planners and interpreters.

#### Phase 4 — Extract server post-tool orchestration [x]
- **Done**: `ServerState::handle_with_runner` no longer owns post-tool logic. It uses `plan_post_tool_actions` to get a list of `TeardownEffect` values and interprets them.

#### Phase 5 — Move pane watching and recovery behind adapters [x]
- **Done**: `PaneWatchHost` and `RecoveryReconcileInput` snapshots move all server-heavy I/O behind formal boundaries. Recovery is pure reconciliation over snapshots.

#### Phase 6 — Converge init/runtime asset generation [x]
- **Done**: `choir init` and `fork_wave` now share the exact same generators in `src/workspace`. Dead `init_*` code deleted from `main.mbt`.

---

## Working summary

> **Choir is a high-confidence, typed agent orchestrator with a strict effect boundary and an idiomatic MoonBit core. It leverages Pi as a first-class operator surface while remaining the authoritative source of truth for all orchestration state.**
