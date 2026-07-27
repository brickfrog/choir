///| Selective archival of one terminal Goal.
///
/// `choir stop --purge` was the only cleanup: it stops the daemon and takes
/// every Goal runtime, every owned ref, and the whole database with it. An
/// installation that runs Goals for months needs to reclaim one finished Goal
/// without losing the record of the others.
///
/// Archiving is not deleting, and this module keeps the two apart. What the
/// Goal *is* survives an archive untouched: its durable execution record and
/// every other permanently adopted artifact, the branch holding the commits it
/// produced, and any content something else still retains. What archiving
/// releases is the working storage only this Goal could ever read again — its
/// sandbox runtime root, the idempotency witness refs under namespaces derived
/// from its own id, and content whose every recorded retention has expired.
///
/// Reachability is not re-derived here. An artifact is a candidate only when
/// the retention ledger records it as kept for this Goal, and it is released
/// only when `@storage.plan_artifact_sweep` says every retention on it has
/// expired. Content two Goals adopted survives until both are done, which is
/// the ledger's rule rather than a second one invented for archival.

///|
/// Why a Goal was refused. Every non-terminal condition is named rather than
/// collapsed into "not terminal", because the operator's next move differs:
/// a paused Goal resumes, a blocked one is retried, a running one is waited on.
pub(all) enum GoalArchiveRefusal {
  /// Queued, running, assuring, assured, or canceling: still moving.
  GoalArchiveGoalActive(GoalExecutionState)
  /// Paused, including the recovery-uncertain pause a lost tick leaves behind.
  /// The reason is absent only when the durable record lost it.
  GoalArchiveGoalPaused(GoalPauseReason?)
  /// Stopped on something that needs a decision before it can move again.
  GoalArchiveGoalBlocked
} derive(Debug, Eq)

///|
/// Exactly what the archive decision reads from a durable Goal.
pub(all) struct GoalArchiveSubject {
  goal_id : @control.GoalId
  state : GoalExecutionState
  pause : GoalPause?
  /// The branch holding this Goal's commits. Reported as retained, never
  /// released: the commits are the work the Goal was run to produce.
  goal_ref : GitRefName
} derive(Debug, Eq)

///|
pub fn goal_archive_subject(record : GoalExecutionRecord) -> GoalArchiveSubject {
  {
    goal_id: record.goal.id,
    state: record.state,
    pause: record.pause,
    goal_ref: record.goal_ref,
  }
}

///|
/// What the host observed, and therefore what the plan may name. The planner
/// never invents a resource: a ref it did not see is not in the plan, so a dry
/// run reports the same list the applied archive removes.
pub(all) struct GoalArchiveObservation {
  subject : GoalArchiveSubject
  /// Every Choir-owned ref currently present in the repository.
  observed_refs : Array[GitRefName]
  retention_ledger : Array[@storage.ArtifactRetentionEntry]
  runtime_root_present : Bool
  now : Int64
}

///|
/// One archivable Goal's releases and retentions, named exactly.
pub(all) struct GoalArchivePlan {
  goal_id : @control.GoalId
  /// The terminal state being archived.
  state : GoalExecutionState
  /// Whether the Goal's sandbox runtime root is still present to reclaim.
  release_runtime_root : Bool
  /// Idempotency witness refs under this Goal's own namespaces.
  release_refs : Array[GitRefName]
  /// Digests reachable from this Goal whose every retention has expired.
  release_artifacts : Array[@control.Digest]
  /// This Goal's refs the archive deliberately keeps — its branch.
  retain_refs : Array[GitRefName]
  /// Content this Goal reached that something else still retains.
  retain_artifacts : Array[@control.Digest]
} derive(Debug, Eq)

///|
pub(all) enum GoalArchiveDecision {
  GoalArchiveRefused(GoalArchiveRefusal)
  GoalArchivePlanned(GoalArchivePlan)
} derive(Debug, Eq)

///|
/// Witness namespace for this Goal's branch initialization. Derived from the
/// Goal id alone, so no other Goal can name a ref under it.
fn goal_branch_witness_ref_prefix(goal_id : @control.GoalId) -> String {
  "refs/choir/goals/" +
  @storage.digest_text(goal_execution_identity_digest(goal_id)) +
  "/"
}

///|
/// Witness namespace for this Goal's branch seals.
fn goal_seal_witness_ref_prefix(goal_id : @control.GoalId) -> String {
  "refs/choir/goals/" +
  @storage.digest_text(@storage.artifact_digest(@utf8.encode(goal_id.0))) +
  "/"
}

///|
/// Whether one observed ref is a witness under a namespace only this Goal can
/// name. Part-keyed witnesses under `refs/choir/witness/` are deliberately not
/// released: their key names an intent, and the Bead behind it may be
/// reselected by a later Goal, so no Goal can prove one is its own.
fn goal_archive_ref_is_releasable(
  goal_id : @control.GoalId,
  reference : GitRefName,
) -> Bool {
  reference.0.has_prefix(goal_branch_witness_ref_prefix(goal_id)) ||
  reference.0.has_prefix(goal_seal_witness_ref_prefix(goal_id))
}

///|
/// Decide whether one Goal may be archived, and what archiving it releases.
///
/// `goal_terminal` answers for every Goal, not just this one: an artifact this
/// Goal adopted may also be retained until a different Goal finishes, and that
/// content must survive until it does.
pub fn plan_goal_archive(
  observation : GoalArchiveObservation,
  goal_terminal : (@control.GoalId) -> Bool,
) -> GoalArchiveDecision {
  let subject = observation.subject
  match subject.state {
    GoalExecutionState::GoalExecutionSucceeded
    | GoalExecutionState::GoalExecutionCanceled => ()
    GoalExecutionState::GoalExecutionPaused =>
      return GoalArchiveDecision::GoalArchiveRefused(
        GoalArchiveRefusal::GoalArchiveGoalPaused(
          match subject.pause {
            Some(pause) => Some(pause.reason)
            None => None
          },
        ),
      )
    GoalExecutionState::GoalExecutionBlocked =>
      return GoalArchiveDecision::GoalArchiveRefused(
        GoalArchiveRefusal::GoalArchiveGoalBlocked,
      )
    state =>
      return GoalArchiveDecision::GoalArchiveRefused(
        GoalArchiveRefusal::GoalArchiveGoalActive(state),
      )
  }
  let release_refs : Array[GitRefName] = []
  let retain_refs : Array[GitRefName] = []
  for reference in observation.observed_refs {
    if goal_archive_ref_is_releasable(subject.goal_id, reference) {
      release_refs.push(reference)
    } else if reference == subject.goal_ref {
      retain_refs.push(reference)
    }
  }
  let reachable : Array[@storage.ArtifactRetentionEntry] = []
  for entry in observation.retention_ledger {
    if entry.retentions.contains(
        @storage.ArtifactRetention::ArtifactUntilGoalTerminal(subject.goal_id),
      ) {
      reachable.push(entry)
    }
  }
  let sweep = @storage.plan_artifact_sweep(
    reachable,
    observation.now,
    goal_terminal,
  )
  GoalArchiveDecision::GoalArchivePlanned({
    goal_id: subject.goal_id,
    state: subject.state,
    release_runtime_root: observation.runtime_root_present,
    release_refs,
    release_artifacts: sweep.collect,
    retain_refs,
    retain_artifacts: sweep.retain.map(fn(entry) { entry.digest }),
  })
}

///|
/// One line naming why the Goal was refused and what would make it
/// archivable, rendered from the typed reason so the wire never carries a
/// hand-written string.
pub fn goal_archive_refusal_message(
  goal_id : @control.GoalId,
  refusal : GoalArchiveRefusal,
) -> String {
  let condition = match refusal {
    GoalArchiveRefusal::GoalArchiveGoalActive(state) =>
      match state {
        GoalExecutionState::GoalExecutionQueued => "queued"
        GoalExecutionState::GoalExecutionRunning => "running"
        GoalExecutionState::GoalExecutionAssuring => "under assurance"
        GoalExecutionState::GoalExecutionAssured =>
          "assured and awaiting finalization"
        GoalExecutionState::GoalExecutionCanceling => "canceling"
        // Terminal states never reach a refusal.
        _ => "still active"
      }
    GoalArchiveRefusal::GoalArchiveGoalPaused(reason) =>
      match reason {
        Some(GoalPauseReason::GoalPauseRecoveryUncertain) =>
          "paused because its recovery is uncertain"
        Some(GoalPauseReason::GoalPauseRequested) => "paused at your request"
        Some(GoalPauseReason::GoalPauseAwaitingAnswer(request)) =>
          "paused awaiting an answer to request " + request.0
        None => "paused"
      }
    GoalArchiveRefusal::GoalArchiveGoalBlocked => "blocked"
  }
  "Goal " +
  goal_id.0 +
  " is " +
  condition +
  "; archive accepts only a succeeded or canceled Goal. Cancel it, or wait for it to finish, and archive it then."
}
