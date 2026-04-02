///|
/// Canonical TL-facing workflow category for a tracked PR, derived from the
/// poller snapshot (and optional unresolved thread count when fetched).
pub(all) enum TlTrackedPrWorkflowCategory {
  BlockedOnChanges
  /// Review-wait window elapsed; Choir snapshot still shows no review (comment-triggered Copilot is unreliable).
  AttentionRequiredCopilotSilentAfterTimeout
  AttentionRequiredCIFailed
  WaitingOnReviewOrCI
  /// No Copilot issue comment observed yet on the PR issue thread (REST).
  WaitingOnCopilotIssueComment
  /// Copilot issue comment seen; other snapshot gates may still block merge.
  CopilotIssueCommentSeenRecheckRemainingGates
  ReadyForTLRecheck
  MergeGateOpenPendingPolicyConfirmation
  /// Approved + CI + threads clear in snapshot, but Copilot issue comment not seen.
  MergeSnapshotReadyCopilotIssueCommentMissing
  ObservedMergedExternal
} derive(Show, Eq)

///|
/// Pure merge gate: approved + CI rollup success + zero unresolved threads when
/// the GraphQL count is available. `None` threads means the gate is not open
/// (honest: unknown thread state).

///|
/// True after at least one [`PollEvent::ReviewTimeout`] has been recorded for this PR
/// and the GitHub review rollup is still `none` in Choir's snapshot. Used to surface
/// reviewer-request flakiness (accepted but no review posted) vs ordinary waiting.
pub fn tl_tracked_pr_copilot_review_silent_escalation_active(
  tracked : TrackedPR,
) -> Bool {
  tracked.last_timeout_at > 0L && tracked.last_review_state == None_
}

///|
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
fn tl_snapshot_workflow_category(
  tracked : TrackedPR,
  merge_ready : Bool,
) -> TlTrackedPrWorkflowCategory {
  if tracked.last_review_state == ChangesRequested {
    return BlockedOnChanges
  }
  if merge_ready {
    if !tracked.copilot_issue_comment_seen {
      return MergeSnapshotReadyCopilotIssueCommentMissing
    }
    return MergeGateOpenPendingPolicyConfirmation
  }
  if tl_tracked_pr_copilot_review_silent_escalation_active(tracked) {
    return AttentionRequiredCopilotSilentAfterTimeout
  }
  if !tracked.copilot_issue_comment_seen {
    return WaitingOnCopilotIssueComment
  }
  CopilotIssueCommentSeenRecheckRemainingGates
}

///|
/// Classify the snapshot when no specific poll event lens applies (e.g. generic
/// triage). `ChangesRequested` is always blocked; a satisfied merge gate is a
/// distinct category; otherwise wait on review/CI/thread data.
pub fn tl_classify_tracked_pr_workflow(
  tracked : TrackedPR,
  unresolved_threads : Int?,
) -> TlTrackedPrWorkflowCategory {
  let merge_ready = tl_tracked_pr_merge_gate_snapshot_ready(
    tracked, unresolved_threads,
  )
  tl_snapshot_workflow_category(tracked, merge_ready)
}

///|
/// One stable sentence per category for parent-facing notifications (`TLDecision:` line).
pub fn tl_tracked_pr_workflow_category_sentence(
  cat : TlTrackedPrWorkflowCategory,
) -> String {
  match cat {
    BlockedOnChanges =>
      "Blocked on review changes — leaf owns follow-up before merge."
    AttentionRequiredCopilotSilentAfterTimeout =>
      "Attention required: review wait timed out and Choir still sees no PR review in its snapshot; the reviewer request may not have been accepted — inspect the PR on GitHub or add a reviewer manually before merge decisions."
    AttentionRequiredCIFailed =>
      "Attention required: CI is failing on the latest head — do not merge until the failure is understood or fixed."
    WaitingOnReviewOrCI =>
      "Waiting on approving review, CI, or unresolved threads — do not infer merge from partial snapshot."
    WaitingOnCopilotIssueComment =>
      "Waiting on a GitHub Copilot issue comment on this PR — review-rollups alone do not prove Copilot commented on the issue thread; CI/review/thread gates may still apply."
    CopilotIssueCommentSeenRecheckRemainingGates =>
      "GitHub Copilot issue comment observed on the PR; re-check remaining review, CI, and thread gates before merge."
    ReadyForTLRecheck =>
      "TL re-check required — CI/review signal changed; verify GitHub before merge_pr."
    MergeGateOpenPendingPolicyConfirmation =>
      "Merge gate open on Choir snapshot (approved, CI success, zero unresolved threads when known); confirm policy, then merge_pr if appropriate. Does not merge automatically."
    MergeSnapshotReadyCopilotIssueCommentMissing =>
      "Choir snapshot shows merge blockers cleared on GitHub, but no Copilot issue comment has been observed on this PR yet — confirm policy before merge_pr."
    ObservedMergedExternal =>
      "PR merged or closed externally — use lifecycle/leaf shutdown as appropriate."
  }
}

///|
/// Map a poll event and the current tracked snapshot to the TL decision model.
/// `unresolved_threads` is the GraphQL unresolved count when fetched for this
/// delivery (CI re-check events), else `None`.
pub fn plan_tl_poll_event_parent(
  event : PollEvent,
  tracked : TrackedPR,
  unresolved_threads : Int?,
) -> TlTrackedPrWorkflowCategory {
  let merge_ready = tl_tracked_pr_merge_gate_snapshot_ready(
    tracked, unresolved_threads,
  )
  match event {
    PRMerged(_) => ObservedMergedExternal
    ReviewTimeout(_) => AttentionRequiredCopilotSilentAfterTimeout
    CIFailed(_) => AttentionRequiredCIFailed
    CIFailureCleared(_) | CILatestHeadRollupSucceeded(_) =>
      if merge_ready {
        if !tracked.copilot_issue_comment_seen {
          MergeSnapshotReadyCopilotIssueCommentMissing
        } else {
          MergeGateOpenPendingPolicyConfirmation
        }
      } else if tracked.last_review_state == ChangesRequested {
        BlockedOnChanges
      } else if tl_tracked_pr_copilot_review_silent_escalation_active(tracked) {
        AttentionRequiredCopilotSilentAfterTimeout
      } else if !tracked.copilot_issue_comment_seen {
        WaitingOnCopilotIssueComment
      } else {
        ReadyForTLRecheck
      }
    PRReady(_) => tl_snapshot_workflow_category(tracked, merge_ready)
    FixesPushed(_) =>
      if !tracked.copilot_issue_comment_seen {
        WaitingOnCopilotIssueComment
      } else {
        WaitingOnReviewOrCI
      }
    ReviewReceived(_, _) =>
      if tracked.last_review_state == ChangesRequested {
        BlockedOnChanges
      } else if !tracked.copilot_issue_comment_seen {
        WaitingOnCopilotIssueComment
      } else {
        WaitingOnReviewOrCI
      }
    ReviewCommented(_, _) =>
      if !tracked.copilot_issue_comment_seen {
        WaitingOnCopilotIssueComment
      } else {
        WaitingOnReviewOrCI
      }
    CopilotIssueCommentSeen(_) =>
      tl_snapshot_workflow_category(tracked, merge_ready)
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
    if tracked.copilot_issue_comment_seen {
      "Choir snapshot: no tracked blockers (approved, CI success, zero unresolved threads). Copilot issue comment observed. Confirm repo policy, then merge_pr if appropriate. Does not merge."
    } else {
      "Choir snapshot: no tracked blockers (approved, CI success, zero unresolved threads), but no Copilot issue comment observed on this PR yet — confirm policy before merge_pr. Does not merge."
    }
  } else {
    let parts : Array[String] = []
    if tl_tracked_pr_copilot_review_silent_escalation_active(tracked) {
      parts.push(
        "review wait already timed out with no review in Choir snapshot (comment-triggered Copilot may be unreliable)",
      )
    }
    if !tracked.copilot_issue_comment_seen {
      parts.push(
        "no GitHub Copilot issue comment observed (REST issue comments)",
      )
    }
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
