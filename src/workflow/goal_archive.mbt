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
/// releases is the durable storage only this Goal could ever read again — its
/// idempotency witness refs, and content whose every recorded retention has
/// expired.
///
/// The Goal's sandbox runtime root is deliberately not in that set. It is
/// removed at the Goal's own terminal boundary and again by the daemon's
/// start-up reclaim, and the only thing left to release with it — the BoxLite
/// box store — is keyed per repository, not per Goal. Releasing it from a
/// single Goal's archive would take a concurrently running Goal's boxes with
/// it, so archival names refs and content only.
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
  /// The per-Part integration witness refs this Goal's own durable records
  /// name. They are digests with no Goal in the name, so unlike the other two
  /// namespaces they cannot be recognized by looking at a ref; they are read
  /// out of the Goal's Parts instead. Every one is under
  /// `part_integration_witness_ref_prefix`, which `goal_archive_subject`
  /// enforces on the way in.
  part_witness_refs : Array[GitRefName]
} derive(Debug, Eq)

///|
/// The namespace every per-Part integration witness ref lives in.
///
/// The refs reach this module as durable record `String`s, and nothing in the
/// control plane types them: `IntegrationIntent::git_witness_ref` and
/// `IntegrationReceipt::witness_ref` are bare strings a record could hold
/// anything in. Every writer produces this prefix, so a record that does not is
/// not a witness and never becomes one here.
let part_integration_witness_ref_prefix : String = "refs/choir/witness/"

///|
/// Read the archive subject out of a Goal and its Parts.
///
/// The Parts are needed only for the witness refs. A snapshot naming a
/// different Goal contributes nothing: the whole safety of releasing a ref
/// whose name carries no Goal is that the name came from this Goal's own
/// record.
///
/// A recorded ref outside the witness namespace contributes nothing either.
/// The release set is otherwise a function of the Goal id alone, and these two
/// durable strings are the only thing that could widen it; without this guard a
/// record naming the Goal's own branch would put that branch in the release
/// set, which is the one ref archival exists to keep.
pub fn goal_archive_subject(
  record : GoalExecutionRecord,
  parts : Array[PartWorkflowSnapshot],
) -> GoalArchiveSubject {
  let part_witness_refs : Array[GitRefName] = []
  let note = fn(reference : String) {
    if reference.has_prefix(part_integration_witness_ref_prefix) {
      let named = GitRefName(reference)
      if !part_witness_refs.contains(named) {
        part_witness_refs.push(named)
      }
    }
  }
  for snapshot in parts {
    if snapshot.goal.id != record.goal.id {
      continue
    }
    // Both, because a Goal canceled mid-integration has an intent whose ref may
    // exist and no receipt naming it.
    match snapshot.integration_intent {
      Some(intent) => note(intent.git_witness_ref)
      None => ()
    }
    match snapshot.integration_receipt {
      Some(receipt) => note(receipt.witness_ref)
      None => ()
    }
  }
  {
    goal_id: record.goal.id,
    state: record.state,
    pause: record.pause,
    goal_ref: record.goal_ref,
    part_witness_refs,
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
  now : Int64
}

///|
/// One archivable Goal's releases and retentions, named exactly.
pub(all) struct GoalArchivePlan {
  goal_id : @control.GoalId
  /// The terminal state being archived.
  state : GoalExecutionState
  /// This Goal's idempotency witness refs: the ones under namespaces derived
  /// from its id, and the per-Part integration witnesses its own Parts named.
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
/// Whether one observed ref is a witness only this Goal can have named.
///
/// Two of the three cases are namespaces digested from this Goal's own id, so
/// every other Goal's witnesses sit under `refs/choir/goals/` too and none of
/// them match. That is the case worth guarding: the host enumerates the whole
/// namespace, so an archive is handed every live Goal's witness on every run.
///
/// The third is the per-Part integration witness under `refs/choir/witness/`,
/// whose name is a digest with no Goal in it. Nothing about such a ref can be
/// read off its name, so it is not recognized — it is matched against the exact
/// refs this Goal's own Parts recorded. The Goal id is in the digested
/// preimage, so no other Goal's integration can produce one of these names, and
/// the name was taken from a Part whose Goal is this one — and, because
/// `goal_archive_subject` admits only the witness namespace, from a record that
/// named a witness rather than some other ref entirely.
fn goal_archive_ref_is_releasable(
  subject : GoalArchiveSubject,
  reference : GitRefName,
) -> Bool {
  reference.0.has_prefix(goal_branch_witness_ref_prefix(subject.goal_id)) ||
  reference.0.has_prefix(goal_seal_witness_ref_prefix(subject.goal_id)) ||
  subject.part_witness_refs.contains(reference)
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
    // The branch is answered for first. It is the one ref this module promises
    // to keep, so it is decided before anything that could widen the release
    // set rather than after.
    if reference == subject.goal_ref {
      retain_refs.push(reference)
    } else if goal_archive_ref_is_releasable(subject, reference) {
      release_refs.push(reference)
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
