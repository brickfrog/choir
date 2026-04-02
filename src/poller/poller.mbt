///|
/// Review state for a tracked PR.
pub(all) enum ReviewState {
  None_
  Approved
  ChangesRequested
  Commented
} derive(Show, Eq)

///|
/// GitHub `statusCheckRollup` aggregate for the PR head (honest, coarse).
pub(all) enum CiRollupStatus {
  /// No checks in the rollup or insufficient fields to classify.
  Unknown
  /// At least one check is pending, queued, or in progress.
  InProgress
  /// Rollup shows all checks completed successfully (or skipped); not a merge/review verdict.
  Success
  /// At least one check failed or errored.
  Failure
} derive(Show, Eq)

///|
/// Tracked state for a single PR in the poller.
pub(all) struct TrackedPR {
  pr_number : Int
  agent_id : String
  branch : String
  parent_branch : String
  pr_url : String
  first_seen : Int64
  mut consecutive_failures : Int
  mut backoff_until : Int64
  mut last_review_state : ReviewState
  mut last_review_bodies : String
  mut last_sha : String
  mut notified_parent : Bool
  mut last_ci_rollup : CiRollupStatus
  mut last_timeout_at : Int64
  /// True once the poller has observed an issue-thread comment authored by a
  /// GitHub Copilot bot login (REST `/issues/{n}/comments`), distinct from review objects.
  mut copilot_issue_comment_seen : Bool
} derive(Show, Eq)

///|
/// Per-PR outcome of one poller tick (for tracing and delivery logs).
pub(all) struct PollerPrTickLog {
  pr_number : Int
  agent_id : String
  skipped_backoff : Bool
  polled_network : Bool
  poll_succeeded : Bool
  untracked_closed : Bool
  backoff_until : Int64
  prior_review_state : ReviewState
  detected_review_state : ReviewState
  events : Array[PollEvent]
  consecutive_failures : Int
  previous_consecutive_failures : Int
}

///|
/// Events emitted by the poller on each tick.
pub(all) enum PollEvent {
  ReviewReceived(Int, String)
  ReviewCommented(Int, String)
  PRReady(Int)
  FixesPushed(Int)
  ReviewTimeout(Int)
  CIFailed(Int)
  /// Rollup no longer reports FAILURE/ERROR on this head, after it did on the prior poll for the same SHA.
  /// Checks may still be pending, neutral, or absent; this is not a success or merge verdict.
  CIFailureCleared(Int)
  /// Rollup reports all checks successful on this head after a prior non-success on the same SHA (e.g. CI finished green).
  /// Not merge approval, mergeability, or review verdict — re-check thread and policy before merge_pr.
  CILatestHeadRollupSucceeded(Int)
  /// First poll tick where a GitHub Copilot issue-thread comment was observed (REST); sticky state updated.
  CopilotIssueCommentSeen(Int)
  PRMerged(Int)
} derive(Show, Eq)
