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
pub impl ToJson for ReviewState with to_json(self) -> Json {
  self.to_wire_string().to_json()
}

///|
/// GitHub `statusCheckRollup` aggregate for the PR head (honest, coarse).
pub(all) enum CiRollupStatus {
  /// Insufficient fields to classify the rollup.
  Unknown
  /// GitHub reported an empty statusCheckRollup; there are no checks to wait on.
  NoChecks
  /// At least one check is pending, queued, or in progress.
  InProgress
  /// Rollup shows all checks completed successfully (or skipped); not a merge/review verdict.
  Success
  /// At least one check failed or errored.
  Failure
} derive(Debug, Eq)

///|
/// GitHub mergeability snapshot for a tracked PR.
pub(all) enum Mergeable {
  Mergeable
  Conflicting
  Unknown
} derive(Debug, Eq)

///|
pub fn Mergeable::to_wire_string(self : Mergeable) -> String {
  match self {
    Mergeable => "mergeable"
    Conflicting => "conflicting"
    Unknown => "unknown"
  }
}

///|
pub impl ToJson for Mergeable with to_json(self) -> Json {
  self.to_wire_string().to_json()
}

///|
pub impl Show for Mergeable with output(self, logger) -> Unit {
  logger.write_string(self.to_wire_string())
}

///|
/// GitHub `mergeStateStatus` snapshot for a tracked PR.
pub(all) enum MergeStateStatus {
  Clean
  Unstable
  Blocked
  HasHooks
  Behind
  Unknown
  Dirty
} derive(Debug, Eq)

///|
pub fn MergeStateStatus::to_wire_string(self : MergeStateStatus) -> String {
  match self {
    Clean => "clean"
    Unstable => "unstable"
    Blocked => "blocked"
    HasHooks => "has_hooks"
    Behind => "behind"
    Unknown => "unknown"
    Dirty => "dirty"
  }
}

///|
pub impl ToJson for MergeStateStatus with to_json(self) -> Json {
  self.to_wire_string().to_json()
}

///|
pub impl Show for MergeStateStatus with output(self, logger) -> Unit {
  logger.write_string(self.to_wire_string())
}

///|
pub(all) struct ReviewThreadRef {
  id : String
  is_outdated : Bool
  author_login : String
} derive(Debug, Eq)

///|
pub impl Show for ReviewThreadRef with output(self, logger) -> Unit {
  self.to_repr().output(logger)
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
  mut last_automerge_attempt_sha : String
  mut notified_parent : Bool
  mut last_ci_rollup : CiRollupStatus
  mut mergeable : Mergeable
  mut merge_state_status : MergeStateStatus
  mut merged_at_unix : Int64?
  mut last_timeout_at : Int64
  /// True once the poller has observed an issue-thread comment authored by a
  /// GitHub Copilot bot login (REST `/issues/{n}/comments`), distinct from review objects.
  mut copilot_issue_comment_seen : Bool
  mut orphan_notified : Bool
  /// True while the server is explicitly reconciling a stale PR for an inactive
  /// leaf, so generic orphan detection stays quiet during cleanup.
  mut orphan_reconciling : Bool
  mut changes_requested_since : Int64
  mut stall_notified : Bool
  /// Timestamp (epoch seconds) when SHA last moved out of `ChangesRequested`;
  /// `0L` means no post-review push has been observed. Used by SinglePass
  /// merge-gate to distinguish "fixes pushed after changes requested" from
  /// "fresh PR that never had a review" (both would have `changes_requested_since == 0L`).
  mut fixes_pushed_at : Int64
  mut review_mode : @types.ReviewMode
  mut unresolved_thread_ids : Array[ReviewThreadRef]
  mut unresolved_thread_ids_fetched : Bool
  mut auto_resolve_outdated_pending : Bool
} derive(Debug, Eq)

///|
pub impl Show for TrackedPR with output(self, logger) -> Unit {
  self.to_repr().output(logger)
}

///|
pub fn review_thread_ids_to_auto_resolve(
  event : PollEvent,
  review_mode : @types.ReviewMode,
  thread_refs : Array[ReviewThreadRef],
) -> Array[String] {
  match event {
    FixesPushed(_) =>
      if review_mode != @types.ReviewMode::Iterative {
        return []
      }
    _ => return []
  }
  review_thread_ids_to_auto_resolve_for_pending(review_mode, thread_refs)
}

///|
pub fn review_thread_ids_to_auto_resolve_for_pending(
  review_mode : @types.ReviewMode,
  thread_refs : Array[ReviewThreadRef],
) -> Array[String] {
  if review_mode != @types.ReviewMode::Iterative {
    return []
  }
  let ids : Array[String] = []
  for thread in thread_refs {
    if thread.is_outdated &&
      thread.id != "" &&
      gh_login_is_copilot_issue_comment_author(thread.author_login) {
      ids.push(thread.id)
    }
  }
  ids
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
/// Per-runtime-tick summary for operator-visible INFO logging.
pub(all) struct TickSummary {
  mut polled : Int
  mut changes : Int
  mut errors : Int
  started_at_ms : Int64
} derive(Debug, Eq)

///|
pub fn TickSummary::new(started_at_ms : Int64) -> TickSummary {
  { polled: 0, changes: 0, errors: 0, started_at_ms }
}

///|
pub fn TickSummary::is_non_empty(self : TickSummary) -> Bool {
  // M5 defines a non-empty tick as any tick where at least one PR was polled,
  // a state transition fired, or an error occurred.
  self.polled > 0 || self.changes > 0 || self.errors > 0
}

///|
pub fn TickSummary::elapsed_ms(
  self : TickSummary,
  ended_at_ms : Int64,
) -> Int64 {
  let elapsed = ended_at_ms - self.started_at_ms
  if elapsed < 0L {
    0L
  } else {
    elapsed
  }
}

///|
pub fn build_tick_summary_line(
  summary : TickSummary,
  elapsed_ms : Int64,
) -> String? {
  if !summary.is_non_empty() {
    return None
  }
  let elapsed = if elapsed_ms < 0L { 0L } else { elapsed_ms }
  Some(
    "tick poll=" +
    summary.polled.to_string() +
    " changes=" +
    summary.changes.to_string() +
    " errors=" +
    summary.errors.to_string() +
    " elapsed=" +
    elapsed.to_string() +
    "ms",
  )
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
  PRMerged(TrackedPR)
  MergeReady(Int)
  ReviewThreadsResolved(Int)
} derive(Debug, Eq)

///|
pub fn CiRollupStatus::to_wire_string(self : CiRollupStatus) -> String {
  match self {
    Unknown => "unknown"
    NoChecks => "no_checks"
    InProgress => "in_progress"
    Success => "success"
    Failure => "failure"
  }
}

///|
pub impl ToJson for CiRollupStatus with to_json(self) -> Json {
  self.to_wire_string().to_json()
}

///|
pub impl Show for CiRollupStatus with output(self, logger) -> Unit {
  logger.write_string(self.to_wire_string())
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
    PRMerged(pr) => {
      logger.write_string("PRMerged(")
      logger.write_string(pr.pr_number.to_string())
      logger.write_string(")")
    }
    MergeReady(n) => {
      logger.write_string("MergeReady(")
      logger.write_string(n.to_string())
      logger.write_string(")")
    }
    ReviewThreadsResolved(n) => {
      logger.write_string("ReviewThreadsResolved(")
      logger.write_string(n.to_string())
      logger.write_string(")")
    }
  }
}
