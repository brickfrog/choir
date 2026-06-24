///|
/// Tests for the "PR healthy" determinant classifier (choir-3rp5, F6). The
/// classifier feeds the per-owned-PR health record taken at liveness finalize;
/// the Done-vs-Fail distinction is quarantined from consumers until the Fail
/// branch lands (F3), so these tests only pin the pure classification.
fn pr_health_sample(
  review~ : ReviewState,
  ci~ : CiRollupStatus,
  merged_at~ : Int64?,
) -> TrackedPR {
  {
    pr_number: 99,
    agent_id: "main.dev",
    branch: "work/x",
    parent_branch: "main",
    pr_url: "https://ex/pr/99",
    first_seen: 0L,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: review,
    last_review_bodies: "",
    last_sha: "sha",
    last_automerge_attempt_sha: "",
    notified_parent: false,
    last_ci_rollup: ci,
    mergeable: Mergeable::Unknown,
    merge_state_status: MergeStateStatus::Unknown,
    merged_at_unix: merged_at,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: false,
    orphan_notified: false,
    orphan_reconciling: false,
    changes_requested_since: 0L,
    stall_notified: false,
    fixes_pushed_at: 0L,
    review_mode: @types.ReviewMode::Iterative,
    unresolved_thread_ids: [],
    unresolved_thread_ids_fetched: false,
    auto_resolve_outdated_pending: false,
  }
}

///|
test "tracked_pr_health: merged is always healthy regardless of CI/review" {
  // merged_at_unix Some => Healthy even if CI failed and changes were requested.
  assert_eq(
    tracked_pr_health(
      pr_health_sample(
        review=ReviewState::ChangesRequested,
        ci=CiRollupStatus::Failure,
        merged_at=Some(123L),
      ),
    ),
    PrHealth::Healthy,
  )
}

///|
test "tracked_pr_health: unmerged with clean CI and no changes requested is healthy" {
  assert_eq(
    tracked_pr_health(
      pr_health_sample(
        review=ReviewState::Approved,
        ci=CiRollupStatus::Success,
        merged_at=None,
      ),
    ),
    PrHealth::Healthy,
  )
  // Unknown/in-progress CI is not Failure, so still healthy.
  assert_eq(
    tracked_pr_health(
      pr_health_sample(
        review=ReviewState::None_,
        ci=CiRollupStatus::InProgress,
        merged_at=None,
      ),
    ),
    PrHealth::Healthy,
  )
}

///|
test "tracked_pr_health: failing CI is unhealthy" {
  assert_eq(
    tracked_pr_health(
      pr_health_sample(
        review=ReviewState::Approved,
        ci=CiRollupStatus::Failure,
        merged_at=None,
      ),
    ),
    PrHealth::Unhealthy,
  )
}

///|
test "tracked_pr_health: changes-requested-and-abandoned is unhealthy" {
  assert_eq(
    tracked_pr_health(
      pr_health_sample(
        review=ReviewState::ChangesRequested,
        ci=CiRollupStatus::Success,
        merged_at=None,
      ),
    ),
    PrHealth::Unhealthy,
  )
}

///|
test "tracked_pr_health_determinant carries the spec's determinant fields" {
  let tracked = {
    ..pr_health_sample(
      review=ReviewState::ChangesRequested,
      ci=CiRollupStatus::Failure,
      merged_at=None,
    ),
    mergeable: Mergeable::Conflicting,
    merge_state_status: MergeStateStatus::Dirty,
  }
  let det = tracked_pr_health_determinant(tracked)
  assert_eq(det.pr_number, 99)
  @debug.assert_eq(det.merged_at_unix, None)
  @debug.assert_eq(det.last_ci_rollup, CiRollupStatus::Failure)
  @debug.assert_eq(det.last_review_state, ReviewState::ChangesRequested)
  @debug.assert_eq(det.mergeable, Mergeable::Conflicting)
  @debug.assert_eq(det.merge_state_status, MergeStateStatus::Dirty)
  @debug.assert_eq(det.health, PrHealth::Unhealthy)
}
