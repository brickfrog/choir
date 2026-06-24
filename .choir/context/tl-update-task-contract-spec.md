# Spec: tl-update-task-contract

## Context
A leaf's task contract is write-once: `ServerState::record_agent_task_contract` (`src/server/state.mbt:551-591`) returns without updating if a contract already exists for the `agent_id`, and the TDD gate always reads the spawn-time `verify` (`src/tools/tdd_state.mbt:378-405` via `task_contract_reader`). When the spawn-time verify is wrong for the actual work — classically a non-MoonBit change (bash hook, nix, config, docs) where `moon test --target native` exits 0 both before AND after the fix — `tdd_red_check` can never make the Intent→Red transition, so the leaf wedges at `tdd_phase=intent` and `file_pr` stays blocked forever (bead choir-35qw; re-observed in choir-v3r5, choir-gieb/moonbump, and twice in this session's choir-4hd5 work). Today's only escape is kill-and-refork, which is lossy in spirit (the worktree dies with the leaf) and noisy. We want a TL/root-only tool to swap a live leaf's `verify` mid-flight, safely, with the audit trail preserved.

## Clarifications
> The goal hook directed momentum; tactical forks below are TL-decided defaults (rationale given) — the user can override any. The one STRATEGIC fork (scope) is flagged for explicit review.

**Q (STRATEGIC — scope): Is choir-35qw strictly the mid-flight mutator tool, or should it also fix the deeper "code-shaped red gate can't go red for non-code work" root cause?**
A (default): Strictly the mutator tool (`update_task_contract`). The deeper root cause — the bead's alternatives "run the red check at intent declaration so the mismatch surfaces before the leaf works" and "derive TDD verify from goal_judge's checks (single source of truth)" — are PREVENTIVE and are separate, larger changes to the gate's source-of-truth. The mutator is the CORRECTIVE escape hatch the bead title asks for and is a general capability (useful any time a TL realizes verify was wrong, not only the non-code case). Root-cause options → follow-up beads. REDIRECT IF you want the root cause tackled here.

**Q (tactical — stale TDD phase): On a verify change, what happens to a Red/Green already recorded against the OLD verify?**
A: Reset the leaf's `tdd_phase` to `Intent`. `leaf_tdd_phases` (`state.mbt:312`) stores only the phase enum, not the command it was validated against, so a Green recorded against the old verify would otherwise silently carry over and let `file_pr` pass without re-validating the new command (the explore flagged this HIGH). Reset forces the leaf to re-establish Red→Green against the new verify. For the motivating case the leaf is already at `Intent`, so the reset is a no-op there.

**Q (tactical — mutable field set): Which TaskContract fields may this tool change?**
A: Only `verify` and `verify_satisfied_by_ci`. FROZEN: `goal` and `beads_issue_id` (preserve the audit trail / provenance — per bead). All other fields (`scope`, `acceptance_checks`, `constraints`, `non_goals`, `guard_paths`, `review_context`) are immutable via this tool for now (keep it tight; widen later if a real need appears).

**Q (tactical — leaf notification): How does the leaf learn its verify changed?**
A: The tool pushes a message to the target leaf (existing `send_message` path / synthetic message) stating the new verify and that its TDD phase was reset. There is no built-in "contract changed" event; a wedged leaf will not act on its own. Subsequent `tdd_red_check`/`file_pr` re-fetch the contract regardless, so notification is for promptness, not correctness.

**Q (tactical — audit): Is the swap recorded?**
A: Yes — emit a typed lifecycle/audit event recording {agent_id, caller, old verify, new verify, old/new verify_satisfied_by_ci, phase-reset}. Non-negotiable per the bead's audit-trail requirement.

**Q (tactical — preconditions): When is the tool rejected?**
A: Reject if the target agent is unknown, is not a child of the caller (TL owns its own leaves; root may target any), or is in a terminal ProcessState (can't rescope a finished/merged leaf). TL/root role only.

## Goals
- New MCP tool `update_task_contract(agent_id, verify?, verify_satisfied_by_ci?)`, TL/root only, that updates a live leaf's contract in place (bypassing the spawn write-once guard via a dedicated mutator, NOT by weakening `record_agent_task_contract`).
- Changing `verify` resets the target leaf's `tdd_phase` to `Intent`, so a stale Red/Green cannot carry over.
- `goal` and `beads_issue_id` are immutable through this tool; attempts to change them are rejected (audit-trail integrity).
- The swap is recorded as a typed audit event (old→new verify, caller, agent_id).
- The target leaf is notified (message) that its verify changed and its phase was reset.
- Rejected for unknown / non-child / terminal targets and non-TL callers.
- After the swap, the leaf's subsequent `tdd_red_check` / `file_pr` use the NEW verify (already true via re-fetch; confirm end-to-end).

## Non-Goals
- No change to the TDD red→green gate SEMANTICS (the bead is explicit: this is about the verify source-of-truth, not the gate). Only the verify value and the phase reset.
- No preventive root-cause work: red-check-at-intent-declaration, or deriving TDD verify from goal_judge (→ follow-ups).
- No mutation of `goal`/`beads_issue_id` or the other contract fields.
- Not weakening the spawn-time write-once property of `record_agent_task_contract` (that immutability is a deliberate safety property; the mutator is a separate, explicit, audited path).
- No automatic re-running of the leaf's work; the leaf re-drives its own TDD cycle.

## Design
Pattern: TL-targets-a-child tool, mirroring `kill_agent` (`registry.mbt:144-147`) and `resolve_my_review_threads` with `target_agent_id` (`registry.mbt:233-235`).
- **Type** (`src/types/domain.mbt:1030-1041`): TaskContract unchanged.
- **Tool registration** (`src/tools/registry.mbt`): `tool_def("update_task_contract", ..., [@types.Role::TL])`.
- **Request + args** (`src/tools/tool_request.mbt` + args): `UpdateTaskContract(UpdateTaskContractArgs)` with `caller_id`, `agent_id`, `verify : Array[String]?`, `verify_satisfied_by_ci : Bool?`.
- **Dispatch** (`src/tools/dispatch.mbt`): `interpret_update_task_contract()` — validate role/child/terminal; read current contract via `task_contract_reader`; build the updated contract (only verify / verify_satisfied_by_ci changed; goal/beads_issue_id copied through unchanged); write via a NEW dedicated mutator.
- **Mutator** (`src/server/state.mbt`): add `update_agent_task_contract(agent_id, contract)` that UPDATES in place + `persist_agent_task_contracts()` (`:542-548`), distinct from the write-once `record_agent_task_contract` (`:551-591`). Bind it as a `record_task_contract`-style closure at the server seam (`src/server/handler.mbt:553-561`).
- **Phase reset**: when `verify` changes, call `record_leaf_tdd_state(agent_id, Intent)` (`state.mbt:524-539`).
- **Notify**: push a message to `agent_id` (synthetic `send_message`) describing the new verify + phase reset.
- **Audit event**: emit a typed lifecycle event (reuse the typed lifecycle-event machinery; do NOT hand-stringify) capturing the swap.

## Verify
- `moon test --target native` — unit tests: `update_agent_task_contract` updates in place (vs `record_agent_task_contract` no-op on existing); `interpret_update_task_contract` rejects non-TL caller, unknown agent, non-child, terminal target; verify change resets `tdd_phase` to Intent; `goal`/`beads_issue_id` preserved.
- Observable: a dispatch-level test calling `update_task_contract` with a new verify on a live `Intent`-wedged leaf, asserting (a) the tool returns success echoing the new verify, (b) a follow-up `task_contract_reader(agent_id)` returns the new verify, (c) `leaf_tdd_phase_for_agent(agent_id)` == Intent, (d) `beads_issue_id`/`goal` unchanged. Grep the audit event for old→new verify.
- `moon run src/bin/choir_lint --target native` — clean.

## Boundary (do not)
- Do NOT weaken `record_agent_task_contract`'s write-once guard; add a separate, explicit `update_agent_task_contract` mutator used only by this tool.
- Do NOT allow `goal` or `beads_issue_id` to change through this tool.
- Do NOT change the TDD red→green gate semantics — only the verify value + the phase reset.
- Do NOT skip the phase reset on a verify change (that reopens the stale-Green hole).
- Do NOT allow updating a terminal/merged leaf, a non-child, or via a non-TL caller.
- Preserve effect-architecture: typed `ChoirError`, typed lifecycle/audit event (no manual JSON stringify at the call site), state mutation through the injected closure.

## Follow-Ups
- **Preventive root cause (the bead's alternatives):** run the red check at intent-declaration so a verify/work mismatch surfaces before the leaf does the work; and/or derive the TDD verify from goal_judge's checks (single source of truth) to remove the duplicate verify entirely. Larger; file as its own bead(s).
- Consider widening the mutable field set (e.g., `guard_paths`) if a real mid-flight rescope need appears beyond verify.
- Consider an explicit "contract changed" lifecycle event consumed by the poller (vs an ad-hoc message) if other mid-flight mutations are added later.
