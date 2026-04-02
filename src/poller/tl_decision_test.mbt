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
test "plan_tl_poll_event_parent CI events are ReadyForTLRecheck" {
  let t = sample_tracked(ChangesRequested, Unknown, 9)
  let p1 = plan_tl_poll_event_parent(CIFailureCleared(9), t, Some(0))
  assert_eq(p1.category, ReadyForTLRecheck)
  let p2 = plan_tl_poll_event_parent(
    CILatestHeadRollupSucceeded(9),
    { ..t, last_review_state: Approved, last_ci_rollup: Success },
    Some(0),
  )
  assert_eq(p2.category, ReadyForTLRecheck)
}

///|
test "plan_tl_poll_event_parent PRReady uses merge gate category when snapshot allows" {
  let t = sample_tracked(Approved, Success, 3)
  let p = plan_tl_poll_event_parent(PRReady(3), t, Some(0))
  assert_eq(p.category, MergeGateOpenPendingPolicyConfirmation)
  assert_true(p.merge_gate_snapshot_ready)
}

///|
test "plan_tl_poll_event_parent FixesPushed is waiting" {
  let t = sample_tracked(Approved, InProgress, 4)
  let p = plan_tl_poll_event_parent(FixesPushed(4), t, None)
  assert_eq(p.category, WaitingOnReviewOrCI)
}

///|
test "plan_tl_poll_event_parent ReviewReceived changes requested is blocked" {
  let t = sample_tracked(ChangesRequested, Success, 5)
  let p = plan_tl_poll_event_parent(ReviewReceived(5, "fix it"), t, Some(0))
  assert_eq(p.category, BlockedOnChanges)
}

///|
test "tl_tracked_pr_recheck_gate_line matches no blocked snapshot" {
  let t = sample_tracked(Approved, Success, 6)
  let line = tl_tracked_pr_recheck_gate_line(t, Some(0))
  assert_true(line.contains("no tracked blockers"))
  assert_true(line.contains("Does not merge"))
}
