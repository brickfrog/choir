///|
/// Review state for a tracked PR.
pub(all) enum ReviewState {
  None_
  Approved
  ChangesRequested
  Commented
} derive(Debug, Eq)

///|
pub impl Show for ReviewState with output(self, logger) -> Unit {
  logger.write_string(self.to_wire_string())
}

///|
pub fn ReviewState::to_wire_string(self : ReviewState) -> String {
  match self {
    None_ => "none"
    Approved => "approved"
    ChangesRequested => "changes_requested"
    Commented => "commented"
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
  MergeReady(Int)
} derive(Debug, Eq)

///|
pub impl Show for CiRollupStatus with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for TrackedPR with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for PollEvent with output(self, logger) -> Unit {
  match self {
    ReviewReceived(n, s) => {
      logger.write_string("ReviewReceived(")
      logger.write_string(n.to_string())
      logger.write_string(", ")
      logger.write_string(s)
      logger.write_string(")")
    }
    ReviewCommented(n, s) => {
      logger.write_string("ReviewCommented(")
      logger.write_string(n.to_string())
      logger.write_string(", ")
      logger.write_string(s)
      logger.write_string(")")
    }
    PRReady(n) => {
      logger.write_string("PRReady(")
      logger.write_string(n.to_string())
      logger.write_string(")")
    }
    FixesPushed(n) => {
      logger.write_string("FixesPushed(")
      logger.write_string(n.to_string())
      logger.write_string(")")
    }
    ReviewTimeout(n) => {
      logger.write_string("ReviewTimeout(")
      logger.write_string(n.to_string())
      logger.write_string(")")
    }
    CIFailed(n) => {
      logger.write_string("CIFailed(")
      logger.write_string(n.to_string())
      logger.write_string(")")
    }
    CIFailureCleared(n) => {
      logger.write_string("CIFailureCleared(")
      logger.write_string(n.to_string())
      logger.write_string(")")
    }
    CILatestHeadRollupSucceeded(n) => {
      logger.write_string("CILatestHeadRollupSucceeded(")
      logger.write_string(n.to_string())
      logger.write_string(")")
    }
    CopilotIssueCommentSeen(n) => {
      logger.write_string("CopilotIssueCommentSeen(")
      logger.write_string(n.to_string())
      logger.write_string(")")
    }
    PRMerged(n) => {
      logger.write_string("PRMerged(")
      logger.write_string(n.to_string())
      logger.write_string(")")
    }
    MergeReady(n) => {
      logger.write_string("MergeReady(")
      logger.write_string(n.to_string())
      logger.write_string(")")
    }
  }
}
