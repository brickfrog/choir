///|
/// Review state for a tracked PR.
pub(all) enum ReviewState {
  None_
  Approved
  ChangesRequested
  Commented
} derive(Debug, Eq)

///|
pub impl Show for ReviewState with fn output(self, logger) -> Unit {
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
pub impl ToJson for ReviewState with fn to_json(self) -> Json {
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
pub impl ToJson for Mergeable with fn to_json(self) -> Json {
  self.to_wire_string().to_json()
}

///|
pub impl Show for Mergeable with fn output(self, logger) -> Unit {
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
pub impl ToJson for MergeStateStatus with fn to_json(self) -> Json {
  self.to_wire_string().to_json()
}

///|
pub impl Show for MergeStateStatus with fn output(self, logger) -> Unit {
  logger.write_string(self.to_wire_string())
}

///|
pub(all) struct ReviewThreadRef {
  id : String
  is_outdated : Bool
  author_login : String
} derive(Debug, Eq)

///|
pub impl Show for ReviewThreadRef with fn output(self, logger) -> Unit {
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
  mut audit_receipt_state : @types.AuditReceiptState
  mut last_timeout_at : Int64
  /// True once the poller has observed an issue-thread comment authored by a
  /// GitHub Copilot bot login (REST `/issues/{n}/comments`), distinct from review objects.
  mut copilot_issue_comment_seen : Bool
  mut orphan_notified : Bool
  /// True once the poller has emitted `PollEvent::PRClosedUnmerged` for this PR,
  /// so a re-detect/re-track cannot re-emit the close (choir-56ax AR-5; cf.
  /// `orphan_notified`).
  mut closed_unmerged_notified : Bool
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
pub impl Show for TrackedPR with fn output(self, logger) -> Unit {
  self.to_repr().output(logger)
}

///|
/// PR-health verdict at liveness-finalize time (choir-3rp5, F6). This is
/// recorded data only: until the deferred Fail terminal branch lands, NO
/// consumer may branch on a Done-vs-Fail distinction derived from it (F3). The
/// liveness reaper/backstop always finalize as Done now; this preserves the
/// signal so the Fail branch can reconstruct the verdict later without
/// re-querying GitHub.
pub(all) enum PrHealth {
  Healthy
  Unhealthy
} derive(Debug, Eq, ToJson)

///|
pub fn PrHealth::to_wire_string(self : PrHealth) -> String {
  match self {
    Healthy => "healthy"
    Unhealthy => "unhealthy"
  }
}

///|
pub impl Show for PrHealth with fn output(self, logger) -> Unit {
  logger.write_string(self.to_wire_string())
}

///|
/// The exact determinant fields the spec's "PR healthy" definition reads,
/// captured per owned PR at finalize so the deferred Fail branch can
/// reconstruct the verdict (choir-3rp5, F6). Carried as data; quarantined from
/// Done-vs-Fail consumers (F3).
pub(all) struct PrHealthDeterminant {
  pr_number : Int
  merged_at_unix : Int64?
  last_ci_rollup : CiRollupStatus
  last_review_state : ReviewState
  mergeable : Mergeable
  merge_state_status : MergeStateStatus
  health : PrHealth
} derive(Debug, Eq, ToJson)

///|
/// Classify a tracked PR's health per the spec's concrete definition (F6):
/// Healthy ⇔ `merged_at_unix is Some` OR (`last_ci_rollup` ≠ Failure AND
/// `last_review_state` ≠ ChangesRequested). Unhealthy otherwise (failing CI, or
/// changes-requested-and-abandoned).
pub fn tracked_pr_health(tracked : TrackedPR) -> PrHealth {
  match tracked.merged_at_unix {
    Some(_) => PrHealth::Healthy
    None =>
      if tracked.last_ci_rollup != CiRollupStatus::Failure &&
        tracked.last_review_state != ReviewState::ChangesRequested {
        PrHealth::Healthy
      } else {
        PrHealth::Unhealthy
      }
  }
}

///|
/// Capture the per-PR health determinant (F6) for recording at finalize time.
pub fn tracked_pr_health_determinant(
  tracked : TrackedPR,
) -> PrHealthDeterminant {
  {
    pr_number: tracked.pr_number,
    merged_at_unix: tracked.merged_at_unix,
    last_ci_rollup: tracked.last_ci_rollup,
    last_review_state: tracked.last_review_state,
    mergeable: tracked.mergeable,
    merge_state_status: tracked.merge_state_status,
    health: tracked_pr_health(tracked),
  }
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
/// `polled` is throughput accounting; steady-state polls with no changes or
/// errors are intentionally empty so normal polling does not reintroduce noise.
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
  self.changes > 0 || self.errors > 0
}

///|
pub fn TickSummary::elapsed_ms(
  self : TickSummary,
  ended_at_ms : Int64,
) -> Int64 {
  @types.non_negative_i64(ended_at_ms - self.started_at_ms)
}

///|
pub fn build_tick_summary_line(
  summary : TickSummary,
  elapsed_ms : Int64,
) -> String? {
  if !summary.is_non_empty() {
    return None
  }
  let elapsed = @types.non_negative_i64(elapsed_ms)
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
  /// A tracked PR was closed on GitHub WITHOUT being merged. Carries the
  /// `TrackedPR` by value so delivery (finalize/notify) is safe even after the
  /// map entry is removed. DISTINCT from `PRMerged` — never reused for a merge,
  /// never produces `MergeObserved` (choir-56ax).
  PRClosedUnmerged(TrackedPR)
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
pub impl ToJson for CiRollupStatus with fn to_json(self) -> Json {
  self.to_wire_string().to_json()
}

///|
pub impl Show for CiRollupStatus with fn output(self, logger) -> Unit {
  logger.write_string(self.to_wire_string())
}

///|
pub impl Show for PollEvent with fn output(self, logger) -> Unit {
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
    PRClosedUnmerged(pr) => {
      logger.write_string("PRClosedUnmerged(")
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
