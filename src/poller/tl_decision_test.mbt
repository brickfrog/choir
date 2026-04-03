///|
fn sample_tracked(
  review : ReviewState,
  ci : CiRollupStatus,
  pr_number : Int,
) -> TrackedPR {
  {
    pr_number,
    agent_id: "main.dev",
    branch: "work/x",
    parent_branch: "main",
    pr_url: "https://ex/pr/" + pr_number.to_string(),
    first_seen: 0L,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: review,
    last_review_bodies: "",
    last_sha: "sha",
    notified_parent: false,
    last_ci_rollup: ci,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: false,
    orphan_notified: false,
    changes_requested_since: 0L,
    stall_notified: false,
  }
}

///|
test "tl_tracked_pr_merge_gate_snapshot_ready requires threads when approved and CI green" {
  let t = sample_tracked(Approved, Success, 1)
  assert_true(tl_tracked_pr_merge_gate_snapshot_ready(t, Some(0)))
  assert_false(tl_tracked_pr_merge_gate_snapshot_ready(t, None))
  assert_false(tl_tracked_pr_merge_gate_snapshot_ready(t, Some(2)))
}

///|
test "tl_classify_tracked_pr_workflow distinguishes blocked, waiting, and merge-gate-open" {
  assert_eq(
    tl_classify_tracked_pr_workflow(
      sample_tracked(ChangesRequested, Success, 2),
      Some(0),
    ),
    BlockedOnChanges,
  )
  assert_eq(
    tl_classify_tracked_pr_workflow(
      sample_tracked(Approved, InProgress, 3),
      None,
    ),
    WaitingOnCopilotIssueComment,
  )
  assert_eq(
    tl_classify_tracked_pr_workflow(
      sample_tracked(Approved, Success, 4),
      Some(0),
    ),
    MergeSnapshotReadyCopilotIssueCommentMissing,
  )
}

///|
test "tl_classify_tracked_pr_workflow escalates when review timeout fired and snapshot still has no review" {
  let t_escalated = {
    ..sample_tracked(None_, Success, 40),
    last_timeout_at: 1L,
  }
  assert_eq(
    tl_classify_tracked_pr_workflow(t_escalated, Some(0)),
    AttentionRequiredCopilotSilentAfterTimeout,
  )
}

///|
test "tl_tracked_pr_workflow_category_sentence covers alert categories" {
  assert_true(
    tl_tracked_pr_workflow_category_sentence(
      AttentionRequiredCopilotSilentAfterTimeout,
    ).contains("review wait timed out"),
  )
  assert_true(
    tl_tracked_pr_workflow_category_sentence(
      AttentionRequiredCopilotSilentAfterTimeout,
    ).contains("reviewer request"),
  )
  assert_true(
    tl_tracked_pr_workflow_category_sentence(AttentionRequiredCIFailed).contains(
      "CI is failing",
    ),
  )
  assert_true(
    tl_tracked_pr_workflow_category_sentence(ObservedMergedExternal).contains(
      "merged or closed externally",
    ),
  )
}

///|
test "plan_tl_poll_event_parent PRReady waits when snapshot is not merge-ready" {
  let t = sample_tracked(Approved, InProgress, 5)
  let cat = plan_tl_poll_event_parent(PRReady(5), t, None)
  assert_eq(cat, WaitingOnCopilotIssueComment)
}

///|
test "plan_tl_poll_event_parent PRReady uses merge gate category when snapshot allows" {
  let t = sample_tracked(Approved, Success, 6)
  let cat = plan_tl_poll_event_parent(PRReady(6), t, Some(0))
  assert_eq(cat, MergeSnapshotReadyCopilotIssueCommentMissing)
}

///|
test "plan_tl_poll_event_parent PRReady merge-ready with Copilot issue comment seen" {
  let t = {
    ..sample_tracked(Approved, Success, 61),
    copilot_issue_comment_seen: true,
  }
  assert_eq(
    plan_tl_poll_event_parent(PRReady(61), t, Some(0)),
    MergeGateOpenPendingPolicyConfirmation,
  )
}

///|
test "plan_tl_poll_event_parent CI actionable events can open merge gate" {
  let t = sample_tracked(Approved, Success, 7)
  let cat = plan_tl_poll_event_parent(
    CILatestHeadRollupSucceeded(7),
    t,
    Some(0),
  )
  assert_eq(cat, MergeSnapshotReadyCopilotIssueCommentMissing)
}

///|
test "plan_tl_poll_event_parent CI actionable events merge gate when Copilot seen" {
  let t = {
    ..sample_tracked(Approved, Success, 71),
    copilot_issue_comment_seen: true,
  }
  let cat = plan_tl_poll_event_parent(
    CILatestHeadRollupSucceeded(71),
    t,
    Some(0),
  )
  assert_eq(cat, MergeGateOpenPendingPolicyConfirmation)
}

///|
test "plan_tl_poll_event_parent CI actionable events stay blocked on changes" {
  let t = sample_tracked(ChangesRequested, Success, 8)
  let cat = plan_tl_poll_event_parent(CIFailureCleared(8), t, Some(0))
  assert_eq(cat, BlockedOnChanges)
}

///|
test "plan_tl_poll_event_parent timeout and CI failure are attention states" {
  let t = sample_tracked(Approved, Failure, 9)
  assert_eq(
    plan_tl_poll_event_parent(ReviewTimeout(9), t, None),
    AttentionRequiredCopilotSilentAfterTimeout,
  )
  assert_eq(
    plan_tl_poll_event_parent(CIFailed(9), t, None),
    AttentionRequiredCIFailed,
  )
}

///|
test "plan_tl_poll_event_parent CI rollup success uses escalation when review timeout already fired" {
  let t = { ..sample_tracked(None_, Success, 41), last_timeout_at: 100L }
  assert_eq(
    plan_tl_poll_event_parent(CILatestHeadRollupSucceeded(41), t, Some(0)),
    AttentionRequiredCopilotSilentAfterTimeout,
  )
}

///|
test "plan_tl_poll_event_parent observed merged external" {
  let t = sample_tracked(Approved, Success, 10)
  assert_eq(
    plan_tl_poll_event_parent(PRMerged(10), t, Some(0)),
    ObservedMergedExternal,
  )
}

///|
test "tl_tracked_pr_recheck_gate_line matches no blocked snapshot" {
  let t = sample_tracked(Approved, Success, 11)
  let line = tl_tracked_pr_recheck_gate_line(t, Some(0))
  assert_true(line.contains("no tracked blockers"))
  assert_true(line.contains("Does not merge"))
  assert_true(line.contains("no Copilot issue comment observed"))
}

///|
test "plan_tl_poll_event_parent CopilotIssueCommentSeen uses post-detection snapshot" {
  let t = {
    ..sample_tracked(Approved, Success, 99),
    copilot_issue_comment_seen: true,
  }
  assert_eq(
    plan_tl_poll_event_parent(CopilotIssueCommentSeen(99), t, Some(0)),
    MergeGateOpenPendingPolicyConfirmation,
  )
}

///|
test "tl_tracked_pr_recheck_gate_line merge-ready snapshot notes Copilot when seen" {
  let t = {
    ..sample_tracked(Approved, Success, 12),
    copilot_issue_comment_seen: true,
  }
  let line = tl_tracked_pr_recheck_gate_line(t, Some(0))
  assert_true(line.contains("Copilot issue comment observed"))
}

///|
test "tl_tracked_pr_recheck_gate_line mentions escalation when copilot silent after timeout" {
  let t = { ..sample_tracked(None_, Success, 42), last_timeout_at: 50L }
  let line = tl_tracked_pr_recheck_gate_line(t, Some(0))
  assert_true(line.contains("timed out"))
  assert_true(line.contains("Copilot"))
}

///|
test "detect_orphaned_prs returns PR when agent inactive and not yet notified" {
  let pr = sample_tracked(None_, Unknown, 501)
  let got = detect_orphaned_prs([(pr, false)])
  assert_eq(got.length(), 1)
  assert_eq(got[0].pr_number, 501)
}

///|
test "detect_orphaned_prs skips when orphan_notified" {
  let pr = { ..sample_tracked(None_, Unknown, 502), orphan_notified: true }
  let got = detect_orphaned_prs([(pr, false)])
  assert_eq(got.length(), 0)
}

///|
test "detect_orphaned_prs skips when agent is active" {
  let pr = sample_tracked(None_, Unknown, 503)
  let got = detect_orphaned_prs([(pr, true)])
  assert_eq(got.length(), 0)
}

///|
test "detect_orphaned_prs empty input returns empty" {
  let got : Array[(TrackedPR, Bool)] = []
  assert_eq(detect_orphaned_prs(got).length(), 0)
}
