///|
/// Review state for a tracked PR.
pub(all) enum ReviewState {
  None_
  Approved
  ChangesRequested
  Commented
} derive(Debug, Eq)

///|
pub impl Show for ReviewState with output(self, logger) {
  match self {
    None_ => logger.write_string("None")
    Approved => logger.write_string("Approved")
    ChangesRequested => logger.write_string("ChangesRequested")
    Commented => logger.write_string("Commented")
  }
}

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
} derive(Debug, Eq)

///|
pub impl Show for CiRollupStatus with output(self, logger) {
  match self {
    Unknown => logger.write_string("Unknown")
    InProgress => logger.write_string("InProgress")
    Success => logger.write_string("Success")
    Failure => logger.write_string("Failure")
  }
}

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
  mut orphan_notified : Bool
  mut changes_requested_since : Int64
  mut stall_notified : Bool
} derive(Debug, Eq)

///|
pub impl Show for TrackedPR with output(self, logger) {
  logger.write_string("TrackedPR { pr_number: ")
  logger.write_string(self.pr_number.to_string())
  logger.write_string(" }")
}

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
  MergeReady(Int)
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
} derive(Debug, Eq)

///|
pub impl Show for PollEvent with output(self, logger) {
  match self {
    ReviewReceived(n, s) =>
      logger.write_string("ReviewReceived(" + n.to_string() + ", " + s + ")")
    ReviewCommented(n, s) =>
      logger.write_string("ReviewCommented(" + n.to_string() + ", " + s + ")")
    PRReady(n) => logger.write_string("PRReady(" + n.to_string() + ")")
    MergeReady(n) => logger.write_string("MergeReady(" + n.to_string() + ")")
    FixesPushed(n) => logger.write_string("FixesPushed(" + n.to_string() + ")")
    ReviewTimeout(n) =>
      logger.write_string("ReviewTimeout(" + n.to_string() + ")")
    CIFailed(n) => logger.write_string("CIFailed(" + n.to_string() + ")")
    CIFailureCleared(n) =>
      logger.write_string("CIFailureCleared(" + n.to_string() + ")")
    CILatestHeadRollupSucceeded(n) =>
      logger.write_string("CILatestHeadRollupSucceeded(" + n.to_string() + ")")
    CopilotIssueCommentSeen(n) =>
      logger.write_string("CopilotIssueCommentSeen(" + n.to_string() + ")")
    PRMerged(n) => logger.write_string("PRMerged(" + n.to_string() + ")")
  }
}
