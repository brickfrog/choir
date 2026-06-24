# Spec: closed-unmerged-pr-lifecycle

## Context
When a tracked PR is closed on GitHub WITHOUT being merged (a human/bot closes it, or it's superseded), the poller detects it (`src/poller/state.mbt:987-1010`: `is_open=false && merged_at_unix==None`), logs `untracked_closed:true`, emits **no PollEvent** (`events:[]` at `:1004`), and silently `remove_tracked`s it (`:1008`). Consequence: the owning leaf gets no finalization event and is **left hanging** in its prior `DevLifecycle` (e.g. `ReviewOwned`/`ChangesRequested`) until an unrelated mechanism (disconnect, watchdog) happens to reap it; the parent TL is **never notified** — the PR just vanishes from orchestration. An earlier fix correctly stopped treating closed-unmerged as merged (which had caused false `PRMerged` events); this spec defines the *positive* behavior that should replace the silence, without reviving the false-merge bug at ANY layer.

This spec was hardened after an adversarial spec-audit (see `## Audit Resolutions`); its first draft would have (a) resurrected the false-merge at the lifecycle layer and (b) shipped the choir-3rp5 multi-PR teardown bug into this feature's most common path. Anchors below were re-read against source.

## Clarifications
> One genuine product DECISION at the center (this bead is typed `decision`); TL-recommended default given, flagged for explicit review. Tactical forks are defaults with rationale.

**Q (CENTRAL DECISION — terminal semantics): When a leaf's PR is closed-unmerged, is that a clean terminal (Finalize) or a failure (Fail)?**
A (default — REDIRECT IF you disagree): A clean terminal via a NEW `FinalizeReason::PrClosedUnmerged`, NOT a `FailureReason`. The leaf did not malfunction — its PR was closed by an external actor (human/supersede). Labeling that a "failure" would poison failure metrics / run-trace mining (the 3rp5 wrong-labels lesson). HARD REQUIREMENT from the audit (F1+F6): the honest label is only *reachable* if a matching `ExitReason::PrClosedUnmerged` exists (else `plan_finalize` overwrites it — see Design/AR-1), and the close must be distinguishable from a merge at the REASON level (merge-privileged paths key on `reason==Merged`, so a distinct reason suffices; the wire string collapses all `Done` reasons to "done", so any *metric* that counts "done" must not treat this as a merge — verify, F6).

**Q (tactical — new PollEvent + DevEvent): How is the close surfaced?**
A: Add `PollEvent::PRClosedUnmerged(TrackedPR)`, DISTINCT from `PRMerged`, AND a `DevEvent::PrClosedUnmerged(pr_number)` that the lifecycle transition consumes (the transition table matches DevEvents, not PollEvents — AR-7). Emit the PollEvent on the closed-unmerged detection path BEFORE `remove_tracked`. `PRMerged`/`MergeObserved`/`EvidenceEvent::MergeObserved` stay strictly merged-only — never reused for closes.

**Q (tactical — leaf transition, per-PR): What transition, and for which leaf?**
A: Finalize the owning leaf to terminal `Done(reason=PrClosedUnmerged)` — but ONLY when the closed PR is the one the leaf's lifecycle actually owns (per-PR gate, AR-2). Covered owner states: `ReviewOwned`, `ChangesRequested` (a NET-NEW arm — MergeObserved has none, AR-3), `ExitRequestedDeferred`. If the leaf currently owns a DIFFERENT PR (the supersede case), do NOT finalize — just untrack the stale PR and leave the leaf working. If already terminal, no-op (no double-finalize, no duplicate notify — AR-4).

**Q (tactical — worktree preservation): does finalize remove the worktree?**
A: NO — call `plan_finalize` with `remove_worktree=false` for PrClosedUnmerged (AR-9). The merge path removes the worktree because the work landed; a closed-unmerged leaf may have UNCOMMITTED work, and the whole point of this bead is "don't silently lose the leaf." Preserve the worktree for manual recovery; "commits survive on the branch" is true only for *committed* work.

**Q (tactical — TL notification): What does the TL see?**
A: An actionable next_action/category near `OrphanedPRNeedsManualAction` (`tl_decision.mbt:1185`) — "PR #N closed without merge; leaf finalized. Re-dispatch if superseded, or leave abandoned." De-duplicated (AR-4/AR-5): notify once per close, even across ticks / already-terminal leaves.

**Q (tactical — ordering + dedup): untrack vs notify?**
A: Emit `PRClosedUnmerged` (carrying the TrackedPR by value, so delivery is safe even after the map entry is gone) → finalize (if per-PR gate passes) → notify TL → THEN `remove_tracked`. Add a persistent `closed_unmerged_notified` flag (cf. `orphan_notified`) so a re-detect/re-track can't re-emit (AR-5). Note: the current branch emits NOTHING (`events:[]`), so this ADDS an event before the existing `remove_tracked` — there is nothing to "reorder."

### Audit Resolutions (post spec-audit, choir-56ax) — all anchors re-read against source
- **AR-1 (BLOCKING, was false-merge-at-lifecycle):** `plan_finalize` (`post_tool.mbt:172-189`) UNCONDITIONALLY overwrites the workflow to `Done(reason=finalize_reason)`, where `finalize_reason = finalize_reason_for_exit(exit_reason)` (`post_tool.mbt:73-83`) over `ExitReason ∈ {Merged, Disconnected, Shutdown}` (`domain.mbt:842`). So a DevEvent's `Done(PrClosedUnmerged)` label is clobbered by whatever `ExitReason` the finalize is called with. FIX: add `ExitReason::PrClosedUnmerged` (`domain.mbt:842`), a `finalize_reason_for_exit` arm → `FinalizeReason::PrClosedUnmerged` (`post_tool.mbt:75`), and a `LifecycleTrigger` for it. The close finalize MUST pass `ExitReason::PrClosedUnmerged` — NEVER `ExitReason::Merged` (that writes `Done(Merged)`) and NEVER `Shutdown` (makes the honest label unreachable).
- **AR-2 (BLOCKING, headline — 3rp5 RA-4 redux):** in `plan_external_merge_finalization` (`post_tool.mbt:336-368`) only `UpdateDevLifecycle` is PR-guarded by `lifecycle_accepts_merge_observed(lifecycle, pr_number)` (`:338`); the `plan_finalize` teardown loop (`:360`) runs UNCONDITIONALLY. Mirroring that for closes finalizes a leaf whenever ANY of its tracked PRs closes — including a superseded PR closing while the leaf works its replacement (the most common close case). FIX: gate the ENTIRE finalize on per-PR ownership. If `lifecycle_accepts_pr_closed_unmerged(lifecycle, pr_number)` is false, do NOT call `plan_finalize` at all — only untrack the stale PR; leave the leaf alone.
- **AR-3 (must-fix):** MergeObserved arms (`lifecycle.mbt:657-669`) cover `ReviewOwned`/`ExitRequestedDeferred`/`Exitable` — there is NO `ChangesRequested` arm (catch-all → `InvalidTransition`, `:670`). A `ChangesRequested(pr_number,..)` leaf owns an open PR a human can close, so PrClosedUnmerged needs a NET-NEW `ChangesRequested` arm (NOT a mirror). Covered PR-owning set: `{ReviewOwned, ChangesRequested, ExitRequestedDeferred}` (all carry `pr_number`).
- **AR-3b (Exitable):** the MergeObserved `Exitable` arm (`lifecycle.mbt:669`) is pr-BLIND. Do NOT add a pr-blind Exitable arm for PrClosedUnmerged — Exitable carries no pr_number, and a pr-blind finalize there mislabels a leaf that exited Working-with-no-PR. Exitable is OUT of the covered set; document it.
- **AR-4 (moderate):** double-finalize guard holds only at the transition (`:670` InvalidTransition). `plan_external_merge_finalization`'s early-return (`post_tool.mbt:332-335`) catches only `Failed` and `Finalized(reason=Merged)`; a leaf `Finalized` with a non-merged reason falls through and RE-PUSHES the parent notify before `plan_finalize`. The close path must dedup the parent notify for already-terminal leaves (notify once).
- **AR-5 (moderate):** the merged branch guards once-only with a persistent `merged_observed`/`mark_merged_observed` cache (`state.mbt:1012,1030`); the closed-unmerged branch has none. Add a `closed_unmerged_notified` TrackedPR flag (cf. `orphan_notified`). The event carries the TrackedPR by value so reordering vs `remove_tracked` is data-safe; the flag handles re-detect.
- **AR-6 (central decision survivability):** see Clarifications — Done is acceptable IFF AR-1 lands (reason reachable) AND a test proves no merge-privileged path (`allow_merge_refinalize`/`Finalized(reason=Merged)` special-cases at `post_tool.mbt:101,112-114,334`; `handler_disconnect.mbt:1849-1851`) treats `Done(PrClosedUnmerged)` as a merge, AND a metric/wire-string check (status collapses all Done→"done", `status_bar_state_test.mbt:360-365`).
- **AR-7:** name `DevEvent::PrClosedUnmerged(pr_number)` + a `lifecycle_accepts_pr_closed_unmerged` checked transition + an `UpdateDevLifecycle` effect arm in delivery. The PollEvent and DevEvent are distinct types; don't conflate.
- **AR-8 (total-match compile points + silent wildcards):** `plan_tl_poll_event_parent` (`tl_decision.mbt:1196-1255`), `poll_event_pr_number` (`handler_poll_delivery.mbt:702-727`), `poll_event_beads_note_and_state` are TOTAL matches over PollEvent — the new variant won't compile until handled (good, handle them). But `mirror_poll_event_to_beads` (`handler_poll_delivery.mbt:2093-2139`) and `evidence_events_for_poll_snapshot` (`handler_evidence.mbt:60-72`) have `_ =>` wildcards that SILENTLY swallow it — intentionally NO `EvidenceEvent::MergeObserved` for a close (good), but pin a test asserting that absence, and add a beads note arm if desired.
- **AR-9 (data loss):** `plan_finalize` removes the worktree (`post_tool.mbt:161-163`) and closes the pane (`:165-169`); for an uncommitted-mid-fix leaf that destroys the working tree. Pass `remove_worktree=false` for PrClosedUnmerged (preserve for recovery). Note in Follow-Ups: after finalize+remove_tracked, a future reopen has nothing to re-attach to.

## Goals
- A closed-unmerged tracked PR emits `PollEvent::PRClosedUnmerged` (distinct from `PRMerged`) and a `DevEvent::PrClosedUnmerged`.
- The owning leaf is finalized to `Done(reason=PrClosedUnmerged)` via a NEW `ExitReason::PrClosedUnmerged` (so the label is reachable, not overwritten to Merged/Shutdown) — but ONLY when the leaf's lifecycle owns that exact PR (per-PR gate); otherwise the stale PR is untracked and the leaf is left working.
- Covered owner states: `{ReviewOwned, ChangesRequested (net-new arm), ExitRequestedDeferred}`; `Exitable` excluded (pr-blind).
- The worktree is PRESERVED (`remove_worktree=false`) so uncommitted work isn't lost.
- The TL is notified once with an actionable category; dedup across ticks (`closed_unmerged_notified`) and already-terminal leaves.
- NO `PRMerged` / `MergeObserved` / `EvidenceEvent::MergeObserved` ever fires for a closed-unmerged PR, at any layer.
- The PR is untracked only AFTER emit + (gated) finalize + notify. No leaf or TL left waiting.

## Non-Goals
- No automatic re-filing / rescue (the TL decides; branch + preserved worktree survive for manual re-dispatch).
- No change to the merged-PR path or merge-gate logic.
- No "abandoned but resumable" non-terminal holding state.
- No pr-blind finalize (Exitable stays out).
- Not reviving any treatment of closed-unmerged as merged at any layer.

## Design
- **Enums:** `PollEvent::PRClosedUnmerged(TrackedPR)` (`poller.mbt:344-362`); `DevEvent::PrClosedUnmerged(pr_number)` (AR-7); `ExitReason::PrClosedUnmerged` (`domain.mbt:842`) + `finalize_reason_for_exit` arm → `FinalizeReason::PrClosedUnmerged` (`post_tool.mbt:73`/`lifecycle.mbt` FinalizeReason) + a `LifecycleTrigger`.
- **Detection/emit:** `state.mbt:993-1008` — on `merged_at_unix==None`, emit `on_event(PRClosedUnmerged(closed_ok))` (guarded by `closed_unmerged_notified`) BEFORE `remove_tracked`.
- **Lifecycle transition:** `lifecycle_accepts_pr_closed_unmerged(lifecycle, pr_number)` + checked transition arms for `ReviewOwned`/`ChangesRequested`/`ExitRequestedDeferred` with `c==n` → `Done(PrClosedUnmerged)`; everything else `InvalidTransition`.
- **Finalize path (the AR-1/AR-2 core):** a close-finalize that (1) runs `UpdateDevLifecycle(PrClosedUnmerged)` only if the per-PR gate passes, (2) calls `plan_finalize(..., ExitReason::PrClosedUnmerged, remove_worktree=false)` ONLY when the gate passed (never unconditionally), (3) dedups parent notify for already-terminal leaves, (4) on gate-fail does nothing but untrack.
- **Translate/evidence:** map PollEvent→DevEvent; NO MergeObserved evidence (leave the `_` wildcard in `handler_evidence.mbt:60-72`, pin a test on the absence).
- **TL decision:** new category + next_action near `tl_decision.mbt:1185`; handle the new variant in the total-match `plan_tl_poll_event_parent` (`:1196-1255`).
- **Delivery:** finalize + notify in `handler_poll_delivery.mbt`, handle the new variant in the total-match `poll_event_pr_number`/`poll_event_beads_note_and_state`.

## Verify
- `moon test --target native` — unit: closed-unmerged emits `PRClosedUnmerged` not `PRMerged`; transition covers `ReviewOwned`/`ChangesRequested`/`ExitRequestedDeferred`→`Done(PrClosedUnmerged)`; **per-PR gate**: a leaf in `ReviewOwned(200)` whose stale `#199` closes is NOT finalized (AR-2 — the headline test); already-terminal leaf not double-finalized / not re-notified; finalize uses `ExitReason::PrClosedUnmerged` and `remove_worktree=false`.
- Observable: poller-state test flipping a tracked PR to `closed && merged_at_unix==None`, asserting (a) emitted events contain `PRClosedUnmerged` and NOT `PRMerged`, (b) owning leaf reaches `Done(PrClosedUnmerged)` (grep the persisted lifecycle reason — assert it is NOT `Merged`), (c) the TL next_action shows the closed-unmerged category. Plus a test asserting NO `EvidenceEvent::MergeObserved` is produced.
- `moon run src/bin/choir_lint --target native` — clean.

## Boundary (do not)
- Do NOT emit `PRMerged`/`MergeObserved`/`EvidenceEvent::MergeObserved` for a close (assert absence in tests).
- Do NOT call `plan_finalize` with `ExitReason::Merged` or `Shutdown` for a close — only the new `ExitReason::PrClosedUnmerged` (AR-1).
- Do NOT finalize unconditionally — gate the ENTIRE finalize on per-PR ownership; a superseded-PR close must NOT reap a leaf working its replacement (AR-2).
- Do NOT add a pr-blind `Exitable` arm (AR-3b).
- Do NOT remove the worktree (`remove_worktree=false`) — preserve uncommitted work (AR-9).
- Do NOT re-notify on re-detect or for already-terminal leaves (dedup, AR-4/AR-5).
- Do NOT mark the leaf `Failed` (default decision: clean `Done(PrClosedUnmerged)`).
- Do NOT `remove_tracked` before emit/finalize/notify.
- Preserve effect-architecture: typed enums/events, no manual JSON stringify at call sites.

## Follow-Ups
- Closed-unmerged-then-reopened: define re-tracking. NOTE: after finalize + remove_tracked, a reopen has nothing to re-attach to (the leaf is terminal); the preserved worktree (AR-9) is the recovery handle. Out of scope now, but named.
- Optional grace window: prompt a still-active leaf before finalizing (vs immediate), if TLs want a re-open window. Current default is immediate finalize with worktree preserved.
- If `closed_unmerged_notified` proves insufficient for rapid close/reopen churn, consider a persistent observed-cache like `merged_observed`.
