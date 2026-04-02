///|
/// Canonical TL-facing workflow category for a tracked PR, derived from the
/// poller snapshot (and optional unresolved thread count when fetched).
pub(all) enum TlTrackedPrWorkflowCategory {
  BlockedOnChanges
  WaitingOnReviewOrCI
  ReadyForTLRecheck
  MergeGateOpenPendingPolicyConfirmation
  ObservedMergedExternal
} derive(Show, Eq)

///|
/// Pure merge gate: approved + CI rollup success + zero unresolved threads when
/// the GraphQL count is available. `None` threads means the gate is not open
/// (honest: unknown thread state).
pub fn tl_tracked_pr_merge_gate_snapshot_ready(
  tracked : TrackedPR,
  unresolved_threads : Int?,
) -> Bool {
  if tracked.last_review_state != Approved {
    return false
  }
  if tracked.last_ci_rollup != Success {
    return false
  }
  match unresolved_threads {
    Some(n) => n == 0
    None => false
  }
}

///|
/// Classify the snapshot when no specific poll event lens applies (e.g. generic
/// triage). `ChangesRequested` is always blocked; a satisfied merge gate is a
/// distinct category; otherwise wait on review/CI/thread data.
pub fn tl_classify_tracked_pr_workflow(
  tracked : TrackedPR,
  unresolved_threads : Int?,
) -> TlTrackedPrWorkflowCategory {
  if tracked.last_review_state == ChangesRequested {
    return BlockedOnChanges
  }
  if tl_tracked_pr_merge_gate_snapshot_ready(tracked, unresolved_threads) {
    return MergeGateOpenPendingPolicyConfirmation
  }
  WaitingOnReviewOrCI
}

///|
/// One stable sentence per category for parent-facing notifications (`TLDecision:` line).
pub fn tl_tracked_pr_workflow_category_sentence(
  cat : TlTrackedPrWorkflowCategory,
) -> String {
  match cat {
    BlockedOnChanges =>
      "Blocked on review changes — leaf owns follow-up before merge."
    WaitingOnReviewOrCI =>
      "Waiting on approving review, CI, or unresolved threads — do not infer merge from partial snapshot."
    ReadyForTLRecheck =>
      "TL re-check required — CI/review signal changed; verify GitHub before merge_pr."
    MergeGateOpenPendingPolicyConfirmation =>
      "Merge gate open on Choir snapshot (approved, CI success, zero unresolved threads when known); confirm policy, then merge_pr if appropriate. Does not merge automatically."
    ObservedMergedExternal =>
      "PR merged or closed externally — use lifecycle/leaf shutdown as appropriate."
  }
}

///|
/// Plan for a single parent-facing poller notification: canonical category plus
/// whether the merge gate is open on snapshot (for next-action hints).
pub(all) struct TlPollEventParentPlan {
  category : TlTrackedPrWorkflowCategory
  merge_gate_snapshot_ready : Bool
} derive(Show, Eq)

///|
/// Map a poll event and the current tracked snapshot to the TL decision model.
/// `unresolved_threads` is the GraphQL unresolved count when fetched for this
/// delivery (CI re-check events), else `None`.
pub fn plan_tl_poll_event_parent(
  event : PollEvent,
  tracked : TrackedPR,
  unresolved_threads : Int?,
) -> TlPollEventParentPlan {
  let merge_ready = tl_tracked_pr_merge_gate_snapshot_ready(
    tracked, unresolved_threads,
  )
  match event {
    PRMerged(_) =>
      { category: ObservedMergedExternal, merge_gate_snapshot_ready: false }
    CIFailureCleared(_) | CILatestHeadRollupSucceeded(_) =>
      { category: ReadyForTLRecheck, merge_gate_snapshot_ready: merge_ready }
    PRReady(_) =>
      if merge_ready {
        {
          category: MergeGateOpenPendingPolicyConfirmation,
          merge_gate_snapshot_ready: true,
        }
      } else {
        {
          category: tl_classify_tracked_pr_workflow(tracked, unresolved_threads),
          merge_gate_snapshot_ready: false,
        }
      }
    FixesPushed(_) | ReviewTimeout(_) | CIFailed(_) =>
      { category: WaitingOnReviewOrCI, merge_gate_snapshot_ready: merge_ready }
    ReviewReceived(_, _) =>
      if tracked.last_review_state == ChangesRequested {
        { category: BlockedOnChanges, merge_gate_snapshot_ready: merge_ready }
      } else {
        {
          category: WaitingOnReviewOrCI,
          merge_gate_snapshot_ready: merge_ready,
        }
      }
    ReviewCommented(_, _) =>
      { category: WaitingOnReviewOrCI, merge_gate_snapshot_ready: merge_ready }
  }
}

///|
/// Gate paragraph for `format_tl_pr_recheck_summary` (shared with tools package).
/// Same strings as the historical inline implementation.
pub fn tl_tracked_pr_recheck_gate_line(
  tracked : TrackedPR,
  unresolved_thread_count : Int?,
) -> String {
  let snapshot_ready = tl_tracked_pr_merge_gate_snapshot_ready(
    tracked, unresolved_thread_count,
  )
  if snapshot_ready {
    "Choir snapshot: no tracked blockers (approved, CI success, zero unresolved threads). Confirm repo policy, then merge_pr if appropriate. Does not merge."
  } else {
    let parts : Array[String] = []
    if tracked.last_review_state == ChangesRequested {
      parts.push("GitHub review requests changes")
    }
    if tracked.last_review_state == None_ {
      parts.push("no approving review in GitHub snapshot")
    }
    if tracked.last_review_state == Commented {
      parts.push("latest review is comment-only (not an approval)")
    }
    match unresolved_thread_count {
      Some(n) =>
        if n > 0 {
          parts.push(n.to_string() + " unresolved inline thread(s) remain")
        }
      None => ()
    }
    if tracked.last_ci_rollup != Success {
      parts.push("latest head CI rollup is not all-success")
    }
    if parts.length() == 0 {
      "TL re-check still needed before merge_pr (policy and GitHub state can differ from this snapshot)."
    } else {
      "TL re-check needed: " + parts.join("; ") + "."
    }
  }
}
