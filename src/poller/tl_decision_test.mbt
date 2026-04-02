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
    WaitingOnReviewOrCI,
  )
  assert_eq(
    tl_classify_tracked_pr_workflow(
      sample_tracked(Approved, Success, 4),
      Some(0),
    ),
    MergeGateOpenPendingPolicyConfirmation,
  )
}

///|
test "tl_tracked_pr_workflow_category_sentence covers alert categories" {
  assert_true(
    tl_tracked_pr_workflow_category_sentence(AttentionRequiredReviewTimeout).contains(
      "review timed out",
    ),
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
  assert_eq(cat, WaitingOnReviewOrCI)
}

///|
test "plan_tl_poll_event_parent PRReady uses merge gate category when snapshot allows" {
  let t = sample_tracked(Approved, Success, 6)
  let cat = plan_tl_poll_event_parent(PRReady(6), t, Some(0))
  assert_eq(cat, MergeGateOpenPendingPolicyConfirmation)
}

///|
test "plan_tl_poll_event_parent CI actionable events can open merge gate" {
  let t = sample_tracked(Approved, Success, 7)
  let cat = plan_tl_poll_event_parent(
    CILatestHeadRollupSucceeded(7),
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
    AttentionRequiredReviewTimeout,
  )
  assert_eq(
    plan_tl_poll_event_parent(CIFailed(9), t, None),
    AttentionRequiredCIFailed,
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
}
