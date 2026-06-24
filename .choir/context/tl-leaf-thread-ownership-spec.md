# Spec: tl-leaf-thread-ownership

## Context
A code review landing on a PR currently wakes BOTH the still-alive leaf and the TL with overlapping, uncoordinated mandates on the same review threads. The leaf receives the review in its pane and is told to address comments (`.choir/prompts/profiles/leaf.md:18-21`); independently, the poller hands the TL `next_action: ResolveThreadsNow` (`src/poller/tl_decision.mbt:210`, emitted from the decision logic at `:882`/`:908`/`:935`). Nothing gates one against the other, and `resolve_my_review_threads` is callable by both TL and Dev roles. On 2026-06-08 this produced a self-contradicting public record: the TL posted a rationale defending a `curl | bash` line while the leaf pushed a rework deleting it (bead choir-3rp5).

We want a single authoritative writer of each PR's *contested* review threads at every instant, enforced at the server boundary (not in prose), keyed on the leaf's process lifecycle, with no way for a dead or wedged leaf to orphan its threads.

This spec was revised after an adversarial spec-audit (see `## Audit Resolutions`); its earlier draft asserted guarantees that the cited code did not provide. Anchors below were re-read against source.

## Clarifications
> Q&A from the crystallize step + the post-audit revision. Durable; leaves read this.

**Q: For a leaf that is still process-alive but stuck (holding a PR's threads, no progress), how is it driven terminal?**
A: NOT by the 300s idle watchdog — `lifecycle_idle_watchdog_exempt` (`src/phase/lifecycle.mbt:541`) returns `true` for `Dev(ReviewOwned)`, `Dev(ChangesRequested)`, `Dev(ExitRequestedDeferred)`, `Dev(WaitingForRedGate)`, i.e. it exempts exactly the thread-owning states. The original "reuse the idle watchdog" plan was wrong: a process-alive, wedged, `ReviewOwned` leaf is skipped by the idle watchdog (exempt) AND by the dead-only reaper (still alive) → permanent thread orphan, gate never opens. A **long, progress-based backstop is therefore MANDATORY in this work, not deferred.** It must (a) be progress-based (no thread/PR-state advance for N hours), not idle-based — that covers both idle-hang and busy-loop; (b) explicitly cover the watchdog-exempt thread-owning states by name; (c) extend the existing `progress_watchdog_applies` concept (`src/phase/lifecycle.mbt:553`) rather than invent a primitive; (d) use a deliberately long net (hours, beyond any legitimate review round), never a tight SLA — a net needs no precise tuning, an SLA does, and a tight one reaps honest slow deliberation. Firing it = automated kill-to-take-over, so it inherits the reconnect-fence requirement below.

**Q: While the owning leaf is alive, how hard is the TL prevented from acting on its PR's threads?**
A: Hard server-side gate, non-negotiable. Prose mandates are not enforcement — on 06-08 both actors followed their prose and still raced. The gate makes the illegal state unrepresentable; suppressing the TL notification is kept only as a cosmetic layer (don't dangle an action the TL can't take). Enforce at the boundary, never in the prompt.

**Q: When the reaper drives a dead/orphaned leaf terminal, which state?**
A: Terminal as **Done** for now (matches the only existing offline-finalize path, which is unconditional — see Audit Resolution F3). The Fail branch is DEFERRED, but the signal is NOT discarded: record the PR-health determinant as data at finalize time, and forbid anything downstream from consuming a Done/Fail distinction until the Fail branch lands (Audit Resolution F3 / rider 2). We defer the state-machine work without recording a falsehood we cannot reconstruct.

**Q: How long after a PR-owning leaf goes Disconnected before reaping?**
A: Reuse the existing 60s disconnect grace (`disconnect_grace_sec = 60L`, `src/bin/choir/uds_server.mbt:3817`; tick 30s) — safe ONLY ONCE both resurrection doors are absorbing. The reconnect door already is (`lifecycle_transport_reconnect`, `src/server/handler_disconnect.mbt:740`); the register door is NOT yet (`lifecycle_for_registered_agent` resurrects `Finalizing` — see F5, fix in Leaf 1). With both closed, the TL-side gate (leaf non-terminal ⇒ TL blocked) and the absorbing fence (terminal ⇒ leaf blocked, no resurrection) are one symmetric invariant keyed on `ProcessState::is_terminal`, and the grace becomes a pure cleanup-latency knob. Until the register-door arm lands, the invariant has a `Finalizing` hole.

### Audit Resolutions (post spec-audit, choir-3rp5)
Every "reuse" claim below was re-read against source. Standing rule going forward: **verify the anchor, never trust the name.**

- **F1 (CONFIRMED, critical):** idle watchdog exempts thread-owning states (`lifecycle.mbt:541`). Fix = mandatory long progress-backstop (Clarification Q1).
- **F2 (CONFIRMED):** `transfer_leaf_ownership` (`handler_disconnect.mbt:84-110`) raises across differing parent/role and supports only `Dev|Worker` — it is leaf→leaf (respawn), cannot reach the TL. **TL takeover requires NO ownership mutation**: TL authority is purely the gate opening when the leaf is terminal. The PR's `TrackedPR.agent_id` may stay the dead leaf. Do NOT call `transfer_leaf_ownership` for TL takeover.
- **F3 (CONFIRMED):** `finalize_recovered_offline_agent` (`src/server/handler_agent_lifecycle.mbt:162`) forces `Finalized(RecoveredDone)` unless the agent is already `Finalized`/`Failed` (no-op at `:167`) — no health check, no Fail branch in either case; `FinalizeOfflineAgent` (`src/runtime/recovery.mbt:946`) is emitted for any `!alive` agent. There is no `FailOfflineAgent`. So "context-aware Done-vs-Fail by mirroring recovery" was fiction. Resolution: Done now, record health determinant, defer Fail (Clarification Q3).
- **F4 (CONFIRMED):** `ProcessState` and `DevLifecycle` are orthogonal axes (`lifecycle.mbt:103` vs `:137`). **Authoritative axis for the gate = `ProcessState::is_terminal`** (`lifecycle.mbt:156` = `Finalizing|Finalized|Failed`). `DevLifecycle` (`ReviewOwned`/`ChangesRequested`/`ExitRequestedDeferred`) is used only as the reaper's *selection* predicate ("owns a PR"), never as the gate predicate.
- **F5 (PARTIALLY resolved — register door is OPEN, fix in scope):** the *reconnect* fence exists — `lifecycle_transport_reconnect` (`handler_disconnect.mbt:740`) only resurrects from `Disconnected`; terminal returns `None`. BUT the *fresh-register* door does NOT: `lifecycle_for_registered_agent` (`src/server/handler_agent_lifecycle.mbt:5-12`) preserves `Finalized`/`Failed` but lets `Finalizing` fall into the `_` arm → `Connected`. Since `is_terminal` includes `Finalizing` (`lifecycle.mbt:156`) and F17 makes `Finalizing` the handoff instant, a register call resurrects a leaf the gate already treats as terminal — reachable on recovery (`apply_recovered_agent`) and the live register handler (`handler.mbt:622`). **REQUIRED CODE FIX (in scope, Leaf 1):** add a `Finalizing(..) => existing` arm to `lifecycle_for_registered_agent` so all three terminal states are absorbing. The symmetric invariant is NOT true until this lands.
- **F6 (CONFIRMED):** "PR healthy" defined concretely below from `TrackedPR` fields.
- **F7 (RESOLVED favorably):** server auto-resolve only touches **outdated, Copilot-authored** threads — `review_thread_ids_to_auto_resolve_for_pending` (`src/poller/poller.mbt:182`) filters `thread.is_outdated && gh_login_is_copilot_issue_comment_author(...)`. These are provably-dead (the diffed line moved), never live/contested. Resolution: documented carve-out; the invariant is "exactly one writer of **contested** threads," with the server independently closing only outdated threads. The prose is now literally true.
- **F8 (CONFIRMED):** TL-direct PRs (no leaf) — the gate must treat "no non-terminal leaf owns this PR" as TL-permitted, else the TL deadlocks on its own PR (its own agent is never terminal). Owner lookup returning the TL itself, or no live leaf, ⇒ TL allowed.
- **F9 (CONFIRMED):** one leaf may own N PRs (`poller.tracked : Map[Int, TrackedPR]`). The reaper drives the *agent* terminal once (per-agent), and records PR-health *per owned PR* (per-PR). No single agent-level health verdict.
- **F10 (CONFIRMED):** the reaper must not duplicate `process_pending_disconnects_with_runner` (`handler_disconnect.mbt:2087`), which already drives disconnect-confirmed-dead agents toward teardown. The dead-leaf path is reuse/extension of that; the genuinely new coverage is the progress-backstop (F1), which fires WITHOUT a disconnect event (a process wedged with transport up is never in `pending_disconnects`).
- **F11 (must specify):** the gate's lifecycle read and the reaper/finalize lifecycle write must share a serialization point. Choir runs request handlers and the poller tick as cooperative fibers (`uds_server.mbt:3815`); specify and rely on cooperative non-preemption + terminal-absorbing so a TL gate-pass cannot be invalidated mid-action. Re-check terminal-ness immediately before a mutating resolve.
- **F12 (anchors corrected):** `tl_decision.mbt` is under `src/poller/`, not `src/server/`. `src/server/recovery.mbt:149-165` is the `ReapStaleLifecycle` handler, NOT the offline-finalize path (that is `handler_agent_lifecycle.mbt:162`). `post_tool.mbt:686` is POST-execution refresh (`RefreshPR`), NOT a pre-execution gate seam — the rejecting gate belongs at the tool execution seam in `src/tools/dispatch.mbt:713` (`resolve_my_review_threads_for_target`) / `registry.mbt:233`.
- **F13 (repo rule):** the reaper must be justified as liveness/teardown that would exist even if the gate did not (dead/wedged leaves must be reclaimed for resource reasons regardless). It must NOT be framed or built as "open the TL gate." If its sole consumer were the gate, it would be a self-satisfying gate (banned). State the independent justification; the gate-opening is a consequence, not the purpose.
- **F14 (effect arch):** pane/process liveness goes through the injected `recovery_provider.agent_process_alive` (`handler_disconnect.mbt:2079`), never a raw `@process`/`@sys` probe in the new sweep.
- **F17 (handoff instant):** `is_terminal` is true at `Finalizing` (`lifecycle.mbt:156`). Define the handoff: the leaf-side gate closes and TL-side opens at `Finalizing`, but teardown (worktree removal) may still be settling. The TL must not be *handed* a resolve action until `Finalized`; the gate may permit it at `Finalizing` but the cosmetic next_action waits for `Finalized` to avoid acting on threads while the leaf's last push is in flight.
- **F18 (snapshot source):** the gate reads **live registry lifecycle** (authoritative, request-time); the next_action suppression reads the **poller snapshot** (cosmetic, may lag one tick). Mismatch is safe-by-construction in only one direction (TL handed an action the gate then rejects = harmless), which is acceptable for a cosmetic layer.

### Re-audit (pass 2) resolutions
All 19 anchors above were independently re-read and confirmed accurate. The second pass surfaced four implementation blockers (now folded into the entries/leaves above) — recorded here so they survive decompose:
- **RA-1 (was F5 mislabel):** register door resurrects `Finalizing` → `Connected` (`handler_agent_lifecycle.mbt:5-12`). F5 relabeled PARTIALLY-resolved; the `Finalizing(..) => existing` arm is a required Leaf 1 code fix. The symmetric invariant is false until it lands.
- **RA-2 (owner-lookup contradiction):** the gate seam has no registry handle and keys on `tracked.agent_id`. Resolved by the two-source predicate (identity ← `TrackedPR.agent_id`, terminal-ness ← `ProcessState`) and a required plumbing of a lifecycle lookup into `dispatch.mbt:727`. `find_agent_for_pr_in_lifecycle` explicitly rejected (forbidden axis).
- **RA-3 (dead-code "extend"):** `progress_watchdog_applies` has no runtime caller; Leaf 2 is BUILD not extend.
- **RA-4 (multi-PR orphan):** per-agent kill vs per-PR progress → backstop fires only when ALL owned PRs are stalled.
- Nits absorbed: gate anchor corrected `:713`→`:727`; "unconditional" tightened in F3; emission-site plumbing flagged in Leaf 1.

### "PR healthy" — concrete definition (F6)
Evaluated per-PR from `TrackedPR` (`src/poller/poller.mbt:121`) at finalize time:
- **Healthy** ⇔ `merged_at_unix is Some` OR (`last_ci_rollup` ≠ `Failure` AND `last_review_state` ≠ `ChangesRequested`).
- **Unhealthy** ⇔ otherwise (failing CI, or changes-requested-and-abandoned).
Record the determinant fields (`merged_at_unix`, `last_ci_rollup`, `last_review_state`, `mergeable`, `merge_state_status`) onto the finalize record so the deferred Fail branch can reconstruct the verdict without re-querying. This decides Done-vs-Fail later; it does NOT change the terminal label now (always Done).

## Goals
- **Symmetric single-writer gate** on `resolve_my_review_threads`, keyed on `ProcessState::is_terminal` of the PR's owning leaf, enforced at the tool execution seam (`src/tools/dispatch.mbt:713`):
  - TL caller REJECTED while a non-terminal leaf owns the target PR (message → kill-to-take-over).
  - Leaf caller REJECTED once that leaf is terminal (durable fence; backed by the absorbing reconnect at `handler_disconnect.mbt:740`).
  - No non-terminal leaf owner (TL-direct PR, or owner is the TL) ⇒ TL permitted (F8).
  - `ResolveThreadsNow` emission (`src/poller/tl_decision.mbt:210`) gated on the owning leaf being terminal; otherwise suppressed.
- **Kill-to-take-over.** TL acquires a live leaf's threads only by ending the leaf (`kill_agent` → terminal). No force-claim.
- **Mandatory progress-backstop** (F1): a long, progress-based watchdog covering `ReviewOwned`/`ChangesRequested` drives a wedged-but-alive leaf terminal so threads cannot orphan; extends `progress_watchdog_applies` (`lifecycle.mbt:553`).
- **Dead-leaf reaper** (extends the existing disconnect-confirm path, F10): a disconnect-confirmed-dead leaf still owning a PR is driven terminal (Done), justified as teardown independent of the gate (F13).
- **Health determinant recorded** per owned PR at finalize (F6/F3); Done-vs-Fail distinction quarantined from all consumers until the Fail branch lands.
- **Cosmetic notification suppression** while leaf non-terminal; gate is the guarantee.
- **Invariant prose is literally true**: "exactly one writer of contested threads; the server independently auto-resolves only outdated Copilot threads (F7)."

## Non-Goals
- No tight progress-SLA. The backstop is a long net (hours), not a tuned deadline.
- No force-claim / TL preemption of a live leaf.
- No new mutex/CAS or separate ownership store; `ProcessState` lifecycle is the sole source of truth.
- No Fail terminal state for the reaper yet (deferred; health signal preserved).
- No change to review detection/fetch/pane-injection, nor to what the server auto-resolves (outdated Copilot threads stays as-is).

## Design
Patterns: enforce the invariant at the server boundary (illegal state unrepresentable); reuse verified mechanisms; record-don't-destroy for deferred distinctions.

**Single-writer predicate:** `owner_may_write(pr, caller)`. Two data sources, each for what it's authoritative on (this is the F4/Finding-2 bridge): **identity** of the owning agent comes from `TrackedPR.agent_id` (the only pr→agent map at the seam; it stays current via `poller.transfer_owner` on respawn, and harmlessly names the dead leaf otherwise — fine for identity); **terminal-ness** of that agent comes from its `ProcessState::is_terminal` in the registry/lifecycle. Do NOT use `find_agent_for_pr_in_lifecycle` (`runtime/recovery.mbt:188`) — it derives identity by scanning the `DevLifecycle` `pr_number`, the axis F4 forbids. Predicate: let `owner_id = TrackedPR.agent_id`; `owner_terminal = is_terminal(lifecycle(owner_id))`. If `owner_id` is a real leaf and `!owner_terminal`: `caller == owner_id` ⇒ allow; `caller == TL` ⇒ reject (kill-to-take-over). If `owner_terminal`, or `owner_id` is absent/the TL (TL-direct PR, F8): `caller == TL` ⇒ allow; a terminal former-owner leaf calling ⇒ reject (fence).

### Leaf 1 — symmetric gate + register-door fence + emission gating + cosmetic suppression
- Gate (rejecting, pre-execution) at `src/tools/dispatch.mbt:727` (`resolve_my_review_threads_targets` — it already carries `caller_role` and houses the permission logic; `:713` only collects PRs and lacks role). This seam currently has `poller_state` + `args` + `caller_role` and **no registry/lifecycle handle** — Leaf 1 must thread a lifecycle/terminal-ness lookup into it (or hoist the gate to the dispatch site that has registry access). Typed `ChoirError`; messages distinguish kill-to-take-over (TL blocked) vs fenced (terminal leaf blocked). NOT `post_tool.mbt:686` (post-exec).
- **Register-door fence (F5 fix):** add a `@phase.ProcessState::Finalizing(..) => existing` arm to `lifecycle_for_registered_agent` (`src/server/handler_agent_lifecycle.mbt:5-12`) so all terminal states are absorbing on fresh register, matching `lifecycle_transport_reconnect`.
- Gate `ResolveThreadsNow` emission in `src/poller/tl_decision.mbt` (`:210` text; decision sites `:882`/`:908`/`:935`). NOTE the emission functions (`merge_gate_next_action`/`recheck_next_action`/`next_action_for_pr_state_notification`, `tl_decision.mbt:875-936`) are pure over `(decision, tracked, unresolved, mode)` and have NO lifecycle arg — owner terminal-ness must be threaded into them; this is real surgery, not a toggle. Suppress unless owning leaf terminal (optionally emit an action-free informational line). Cosmetic layer reads poller snapshot (F18); waits for `Finalized` not `Finalizing` (F17).
- Owner identity from `TrackedPR.agent_id`, terminal-ness from registry `ProcessState`; handle no-leaf / TL-owner / terminal-owner per F8 and the predicate above.

### Leaf 2 — progress-backstop (the mandatory F1 fix) — BUILD, not "extend"
- SCOPE CORRECTION (Re-audit Finding 3): `progress_watchdog_applies` (`src/phase/lifecycle.mbt:554`) has ZERO runtime callers — it is dead code; the live watchdog is `check_idle_agents` (`handler_disconnect.mbt:1065`, driven from `uds_server.mbt:3835`, threshold 300L) keyed on the DIFFERENT predicate `lifecycle_idle_watchdog_exempt`. There is no consumer loop to "extend." Leaf 2 must BUILD a progress-watchdog runtime path: either wire `progress_watchdog_applies` into a new long-threshold sweep on the poller fiber, or graft progress logic into `check_idle_agents` with a long threshold for the thread-owning states. Cover `Dev(ReviewOwned)` and `Dev(ChangesRequested)` by name (the states `lifecycle_idle_watchdog_exempt:541` skips). This is materially more than a predicate edit — decompose it as such.
- Progress signal per `TrackedPR`: no advance ⇔ `last_sha` unchanged AND `unresolved_thread_ids` count not decreasing, for ≥ N hours.
- **MULTI-PR RULE (Re-audit Finding 4):** firing drives the leaf terminal, which is PER-AGENT, while progress is PER-PR. A leaf may own N PRs (`poller.tracked` keyed by `agent_id`). The backstop MUST fire only when **ALL** of the agent's owned PRs are stalled past the threshold. Killing a live leaf because ONE owned PR is parked while it actively advances another would orphan the healthy PR — the exact failure the backstop exists to prevent. (The dead-leaf reaper has no such constraint: a dead leaf orphans all its PRs regardless.)
- Firing drives the leaf terminal via the existing finalize path (`finalize_agent_with_runner`, `handler_disconnect.mbt:366`); inherits the absorbing fence (incl. the F5 register-door arm).
- Liveness probe via injected `recovery_provider.agent_process_alive` (F14), never raw `@process`.

### Leaf 3 — dead-leaf reaper + health record (extends disconnect path)
- Reuse/extend `process_pending_disconnects_with_runner` (`handler_disconnect.mbt:2087`) so a disconnect-confirmed-dead (`pending_disconnect_target_still_alive` false past grace) leaf still in a thread-owning `DevLifecycle` is finalized to Done (`finalize_recovered_offline_agent` semantics / `finalize_agent_with_runner`). Do NOT call `transfer_leaf_ownership` (F2).
- Record per-owned-PR health determinant (F6) at finalize. Quarantine Done/Fail distinction (F3).
- Justify in code comments as teardown independent of the gate (F13).

### Leaf 4 — profile/prose alignment (foldable into Leaf 1)
- `.choir/prompts/profiles/leaf.md:18-21` + TL profile: state the ownership rule as description of the enforced gate, no longer load-bearing.

## Verify
- `moon test --target native` — unit/whitebox: `owner_may_write` truth table (TL-blocked, leaf-allowed, fenced-terminal-leaf, no-leaf-TL-allowed, TL-owner-allowed); backstop predicate covers `ReviewOwned`/`ChangesRequested` and fires only past the long threshold; "PR healthy" classifier over `TrackedPR` field combinations.
- Observable gate rejection: handler/dispatch-level test invoking `resolve_my_review_threads` as TL against a PR whose leaf is non-terminal → rejected; grep the returned error for the kill-to-take-over text. Symmetric: terminal leaf caller → fenced rejection.
- Observable handoff: lifecycle test — leaf `Disconnected`+`ReviewOwned`, run reaper → leaf `Finalized(Done)`, health determinant recorded, TL gate now OPENS for that PR.
- Observable fence: a `Finalized` leaf that re-registers/reconnects stays terminal (no `Connected` resurrection) — assert `lifecycle_transport_reconnect` returns `None` for terminal, and the register door rejects resurrecting a terminal `agent_id`.
- `moon run src/bin/choir_lint --target native` — clean.

## Boundary (do not)
- Do NOT enforce single-writer only in profile prose; the server gate is the guarantee.
- Do NOT add a force-claim path, a progress-SLA (only the long net), or a new mutex/ownership store.
- Do NOT call `transfer_leaf_ownership` for TL takeover (F2) — TL authority is the gate opening; no ownership mutation.
- Do NOT key the gate on `DevLifecycle`; key on `ProcessState::is_terminal` (F4).
- Do NOT let a terminal `agent_id` resurrect to `Connected` via reconnect OR fresh register — the reconnect door is already absorbing, the register door (`lifecycle_for_registered_agent`) needs the `Finalizing(..) => existing` arm (F5/RA-1).
- Do NOT fire the progress-backstop on a live leaf while it is advancing ANY of its owned PRs — require ALL owned PRs stalled (RA-4), else you orphan the healthy one.
- Do NOT gate on `tracked.agent_id` terminal-ness via lifecycle pr_number scanning (`find_agent_for_pr_in_lifecycle`) — identity from `tracked.agent_id`, terminal-ness from `ProcessState` (RA-2).
- Do NOT mark the reaper terminal as Failed (always Done for now); do NOT let any consumer branch on Done-vs-Fail until the Fail branch lands (F3).
- Do NOT frame/build the reaper as a gate-opener; it is independent teardown (F13).
- Do NOT duplicate `process_pending_disconnects`; extend it (F10).
- Do NOT probe liveness with raw `@process`/`@sys`; use the injected provider (F14).
- Do NOT cite an anchor without reading it; corrected anchors above are authoritative.
- Preserve effect-architecture: terminal transitions via `plan_finalize`/`plan_fail` + injected runner.

## Follow-Ups
- **Fail terminal branch:** build `FailOfflineAgent` (or equivalent) consuming the recorded health determinant, then lift the Done/Fail consumer quarantine. This is the deferred half of F3 — the expensive label we chose not to fake.
- **F11 serialization audit:** confirm the request-fiber/poller-fiber cooperative model holds the gate↔transition serialization assumption; if preemption is possible, add an explicit lock.
- **choir-9z3** (server auto-resolve after green): confirm it continues to touch only outdated Copilot threads; if it ever widens to contested threads, it must enter the gate.
- **choir-5fv** (leaves calling `gh` directly for review state): direct `gh` bypasses the gate; consider routing leaf review-state reads through the server.
- **Informational TL line vs full silence** while leaf owns threads — cosmetic, pick during impl.
