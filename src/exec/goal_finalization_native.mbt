///|
fn persist_native_goal_finalization_record(
  repository : @workflow.PartWorkflowRepository,
  adapters : @workflow.PartWorkflowRepositoryAdapters,
  execution : @workflow.GoalExecutionRecord,
  record : @workflow.GoalFinalizationRecord,
  expected_store_version : Int?,
) -> Result[@workflow.StoredGoalFinalizationRecord, @types.ChoirError] {
  let receipt = match
    @workflow.persist_goal_finalization_record(repository, adapters, {
      record,
      expected_store_version,
      goal_precondition: @workflow.goal_execution_state_precondition(execution),
      fault_point: None,
    }) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match receipt.outcome {
    @workflow.GoalFinalizationPersistenceOutcome::GoalFinalizationGoalPreconditionConflict =>
      Err(
        native_pull_request_error("Goal changed during readiness observation"),
      )
    @workflow.GoalFinalizationPersistenceOutcome::GoalFinalizationPersistenceCompleted(
      @storage.StateTransactionOutcome::StateTransactionCommitted
      | @storage.StateTransactionOutcome::StateTransactionReplayed
      | @storage.StateTransactionOutcome::StateTransactionCommittedAckLost
    ) =>
      match
        @workflow.load_goal_finalization_record(
          repository,
          adapters,
          execution.goal.id,
        ) {
        Ok(Some(value)) if value.record == record => Ok(value)
        Ok(_) =>
          Err(native_pull_request_error("readiness did not reload exactly"))
        Err(error) => Err(error)
      }
    _ => Err(native_pull_request_error("readiness persistence conflicted"))
  }
}

///|
fn readiness_lookup_merge_commit(
  lookup : @workflow.PullRequestLookupObservation,
) -> @control.GitOid? {
  match lookup {
    @workflow.PullRequestLookupObservation::PullRequestStoredIdMatch(value)
    | @workflow.PullRequestLookupObservation::PullRequestUniqueMarkerMatch(
      value
    )
    | @workflow.PullRequestLookupObservation::PullRequestPossibleExistingMatch(
      value
    ) => value.merge_commit_oid
    _ => None
  }
}

///|
/// Passive delivery observation: fetch the integration target from the
/// publication remote and check whether it contains the reported merge
/// commit. The reviewed head SHA is deliberately not consulted — squash and
/// rebase merges rewrite it, so the merge commit is the delivery link.
async fn observe_native_goal_delivery(
  git : NativeGoalRepositoryIdentity,
  publication_intent : @workflow.BranchPublicationIntent,
  record : @workflow.GoalExecutionRecord,
  merge_commit_oid : @control.GitOid,
  observed_at : Int64,
) -> Result[@workflow.GoalDeliveryObservation, @types.ChoirError] {
  guard pull_request_short_ref(record.integration_target_ref) is Some(target) else {
    return Err(native_pull_request_error("integration target ref is invalid"))
  }
  let remote = publication_intent.remote_name.0
  let fetched = match
    capture_native_goal_git(git.root, ["fetch", "--quiet", remote, target]) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if fetched.exit_code != 0 {
    return Err(native_pull_request_error("delivery target fetch failed"))
  }
  let head = match
    capture_native_goal_git(git.root, ["rev-parse", "FETCH_HEAD"]) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let target_head = head.output.trim().to_owned()
  if head.exit_code != 0 || target_head == "" {
    return Err(native_pull_request_error("delivery target head is unreadable"))
  }
  let ancestry = match
    capture_native_goal_git(git.root, [
      "merge-base",
      "--is-ancestor",
      merge_commit_oid.0,
      target_head,
    ]) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    merge_commit_oid,
    observed_target_head_oid: @control.GitOid(target_head),
    // Exit 1 means not an ancestor; an unknown object behaves the same and
    // both read as replication lag, so the caller re-observes on backoff.
    target_contains_merge: ancestry.exit_code == 0,
    observed_at,
  })
}

///|
/// Delivery-boundary source completion used by production finalization: the
/// host adapter closes each integrated Part's source Bead and re-observes
/// the closure before the Goal success transaction commits. Fixtures without
/// real Beads inject a no-op completion instead.
async fn reconcile_native_goal_delivery_sources(
  project_dir : String,
  repository : @workflow.PartWorkflowRepository,
  record : @workflow.GoalExecutionRecord,
) -> Result[Unit, @types.ChoirError] {
  reconcile_native_integrated_part_sources(project_dir, repository, record)
}

///|
pub async fn advance_native_goal_finalization_with_adapters(
  project_dir : String,
  goal_id : @control.GoalId,
  forge : NativePullRequestForgeAdapters,
  fault? : @workflow.GoalFinalizationFaultPoint? = None,
  reconcile_sources? : async (
    String,
    @workflow.PartWorkflowRepository,
    @workflow.GoalExecutionRecord,
  ) -> Result[Unit, @types.ChoirError] = reconcile_native_goal_delivery_sources,
) -> Result[@workflow.GoalFinalizationTickOutcome, @types.ChoirError] {
  let repository = native_goal_repository(project_dir)
  let adapters = local_part_workflow_repository_adapters()
  match @workflow.initialize_part_workflow_repository(repository, adapters) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let execution = match
    @workflow.load_goal_execution_record(repository, adapters, goal_id) {
    Ok(Some(value)) => value
    Ok(None) => return Err(native_pull_request_error("Goal is not registered"))
    Err(error) => return Err(error)
  }
  if execution.record.state ==
    @workflow.GoalExecutionState::GoalExecutionSucceeded {
    return Ok(@workflow.GoalFinalizationTickOutcome::GoalFinalizationSucceeded)
  }
  if execution.record.state !=
    @workflow.GoalExecutionState::GoalExecutionAssured &&
    execution.record.state !=
    @workflow.GoalExecutionState::GoalExecutionAwaitingMerge {
    return Err(native_pull_request_error("Goal is not ready for finalization"))
  }
  if execution.record.completion_mode !=
    @workflow.GoalCompletionMode::GoalPublishable {
    return Err(native_pull_request_error("Goal is not publishable"))
  }
  let assurance = match
    @workflow.load_goal_assurance_record(repository, adapters, goal_id) {
    Ok(Some(value)) => value.record
    Ok(None) =>
      return Err(native_pull_request_error("Goal assurance is absent"))
    Err(error) => return Err(error)
  }
  let publication = match
    @workflow.load_goal_publication_record(repository, adapters, goal_id) {
    Ok(Some(value)) => value.record
    Ok(None) =>
      return Err(native_pull_request_error("Goal publication is absent"))
    Err(error) => return Err(error)
  }
  let pull_request = match
    @workflow.load_goal_pull_request_record(repository, adapters, goal_id) {
    Ok(Some(value)) => value.record
    Ok(None) =>
      return Err(native_pull_request_error("Goal pull request is absent"))
    Err(error) => return Err(error)
  }
  guard publication.receipt is Some(publication_receipt) &&
    pull_request.receipt is Some(_) else {
    return Err(
      native_pull_request_error("finalization receipts are incomplete"),
    )
  }
  let git = match
    discover_native_goal_repository(project_dir, execution.record) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  // The exact-branch preflight applies only before the pull request is
  // handed to review: after a merge GitHub commonly deletes the Goal branch,
  // and an awaiting-merge Goal must still be able to observe delivery.
  if execution.record.state == @workflow.GoalExecutionState::GoalExecutionAssured &&
    native_remote_branch_observation(git, publication.intent) !=
    @workflow.RemoteBranchObservation::RemoteBranchAt(
      publication_receipt.published_oid,
    ) {
    return Err(native_pull_request_error("published remote head is not exact"))
  }
  let repository_name = match (forge.resolve_repository)(git.root) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let lookup = (forge.lookup)(git.root, repository_name, pull_request.intent)
  let previous = match
    @workflow.load_goal_finalization_record(repository, adapters, goal_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let sequence = previous
    .map(fn(value) { value.record.readiness.observation_sequence + 1L })
    .unwrap_or(1L)
  let now = @env.now().reinterpret_as_int64() / 1000L
  let observed = match
    @workflow.observe_goal_pull_request_readiness(
      execution.record,
      assurance,
      publication,
      pull_request,
      lookup,
      None,
      sequence,
      now,
      now,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let next = match previous {
    Some(value) =>
      { ..observed, durable_version: value.record.durable_version + 1 }
    None => observed
  }
  // Delivery evidence joins the same durable observation: one persisted
  // record binds the merged decision and the target-containment check.
  let next = if next.readiness.decision ==
    @workflow.PullRequestReadinessDecision::PullRequestMergeObserved &&
    execution.record.state ==
    @workflow.GoalExecutionState::GoalExecutionAwaitingMerge {
    let merge_commit_oid = match readiness_lookup_merge_commit(lookup) {
      Some(value) => value
      None =>
        return Err(
          native_pull_request_error(
            "merged pull request reported no merge commit",
          ),
        )
    }
    let delivery = match
      observe_native_goal_delivery(
        git,
        publication.intent,
        execution.record,
        merge_commit_oid,
        now,
      ) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    { ..next, delivery: Some(delivery) }
  } else {
    next
  }
  let stored = match
    persist_native_goal_finalization_record(
      repository,
      adapters,
      execution.record,
      next,
      previous.map(fn(value) { value.state_record.version }),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match stored.record.readiness.decision {
    @workflow.PullRequestReadinessDecision::PullRequestReady => {
      if execution.record.state ==
        @workflow.GoalExecutionState::GoalExecutionAssured {
        match
          @workflow.persist_goal_awaiting_merge(
            repository,
            adapters,
            execution,
            assurance,
            publication,
            pull_request,
            stored,
          ) {
          Ok(_) => ()
          Err(error) => return Err(error)
        }
      }
      Ok(@workflow.GoalFinalizationTickOutcome::GoalFinalizationAwaitingMerge)
    }
    @workflow.PullRequestReadinessDecision::PullRequestMergeObserved => {
      if execution.record.state ==
        @workflow.GoalExecutionState::GoalExecutionAssured {
        // Merged before the Goal entered AwaitingMerge: record the wait state
        // first; the next due observation completes delivery.
        match
          @workflow.persist_goal_awaiting_merge(
            repository,
            adapters,
            execution,
            assurance,
            publication,
            pull_request,
            stored,
          ) {
          Ok(_) => ()
          Err(error) => return Err(error)
        }
        return Ok(
          @workflow.GoalFinalizationTickOutcome::GoalFinalizationAwaitingMerge,
        )
      }
      guard stored.record.delivery is Some(delivery) else {
        return Err(native_pull_request_error("delivery evidence is absent"))
      }
      if !delivery.target_contains_merge {
        // The forge reports the merge but the target head does not contain
        // the merge commit yet; treat as replication lag and re-observe.
        return Ok(
          @workflow.GoalFinalizationTickOutcome::GoalFinalizationAwaitingMerge,
        )
      }
      if fault ==
        Some(
          @workflow.GoalFinalizationFaultPoint::PullRequestAfterReadinessObservationBeforeSuccessTransaction,
        ) {
        return Err(
          native_pull_request_error("injected Goal finalization fault"),
        )
      }
      // Close source Beads only now, with delivery observed, and before the
      // success transaction: a crash in between retries idempotently on the
      // next tick, while success-before-closure would strand open Beads on a
      // Goal the runner never ticks again.
      match reconcile_sources(project_dir, repository, execution.record) {
        Ok(_) => ()
        Err(error) => return Err(error)
      }
      match
        @workflow.persist_goal_execution_success(
          repository,
          adapters,
          execution,
          assurance,
          publication,
          pull_request,
          stored,
        ) {
        Ok(_) =>
          Ok(@workflow.GoalFinalizationTickOutcome::GoalFinalizationSucceeded)
        Err(error) => Err(error)
      }
    }
    @workflow.PullRequestReadinessDecision::PullRequestReadinessNeedsInput(_) =>
      Ok(@workflow.GoalFinalizationTickOutcome::GoalFinalizationNeedsUserInput)
    @workflow.PullRequestReadinessDecision::PullRequestReadinessDrift(_) =>
      Ok(@workflow.GoalFinalizationTickOutcome::GoalFinalizationDrifted)
    @workflow.PullRequestReadinessDecision::PullRequestReadinessAmbiguous =>
      Ok(@workflow.GoalFinalizationTickOutcome::GoalFinalizationAmbiguous)
  }
}

///|
pub async fn advance_native_goal_finalization(
  project_dir : String,
  goal_id : @control.GoalId,
) -> Result[@workflow.GoalFinalizationTickOutcome, @types.ChoirError] {
  advance_native_goal_finalization_with_adapters(
    project_dir,
    goal_id,
    native_pull_request_forge_adapters(),
  )
}

///|
async fn prepare_goal_finalization_fixture(
  label : String,
) -> (
  String,
  String,
  @control.GoalId,
  Ref[@workflow.RemotePullRequestSnapshot?],
  NativePullRequestForgeAdapters,
) {
  let fixture = prove_publication_fault_recovery(
    "finalization-" + label,
    @workflow.GoalPublicationFaultPoint::PublicationAfterIntentBeforeAuthorized,
    @workflow.BranchPublicationState::BranchPublicationPlanned,
    false,
  )
  let remote_pull_request : Ref[@workflow.RemotePullRequestSnapshot?] = Ref(
    None,
  )
  let forge : NativePullRequestForgeAdapters = {
    resolve_repository: _ => Ok("choir/finalization-fixture"),
    lookup: (_, _, _) => {
      match remote_pull_request.val {
        Some(snapshot) =>
          @workflow.PullRequestLookupObservation::PullRequestUniqueMarkerMatch(
            snapshot,
          )
        None => @workflow.PullRequestLookupObservation::PullRequestNoMatch
      }
    },
    create: (_, _, intent, document) => {
      remote_pull_request.val = Some(
        pull_request_fault_snapshot(intent, document),
      )
    },
  }
  let pull_request_outcome = match
    advance_native_goal_pull_request_with_adapters(fixture.0, fixture.2, forge) {
    Ok(value) => value
    Err(error) => fail(label + ": PR setup: " + error.message())
  }
  assert_eq(
    pull_request_outcome,
    @workflow.GoalPullRequestTickOutcome::GoalPullRequestComplete,
  )
  (fixture.0, fixture.1, fixture.2, remote_pull_request, forge)
}

///|
fn goal_execution_outbox_key(
  goal_id : @control.GoalId,
  version : Int,
) -> @storage.SemanticEventKey {
  @storage.SemanticEventKey(
    "goal-run:" +
    @storage.digest_text(@storage.artifact_digest(@utf8.encode(goal_id.0))) +
    ":state:" +
    version.to_string(),
  )
}

///|
pub(all) enum NativePullRequestRemoteStateCase {
  PullRequestRemoteExact
  PullRequestRemoteClosed
  PullRequestRemoteRetargeted
  PullRequestRemoteHeadChanged
  PullRequestRemoteEdited
  PullRequestRemoteDuplicate
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct NativePullRequestRemoteStateObservation {
  case : NativePullRequestRemoteStateCase
  outcome : @workflow.GoalFinalizationTickOutcome
  decision : @workflow.PullRequestReadinessDecision
  goal_state : @workflow.GoalExecutionState
  passed : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct NativePullRequestRemoteStateConformanceReport {
  observations : Array[NativePullRequestRemoteStateObservation]
  passed : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
fn pull_request_remote_state_label(
  case : NativePullRequestRemoteStateCase,
) -> String {
  match case {
    PullRequestRemoteExact => "exact"
    PullRequestRemoteClosed => "closed"
    PullRequestRemoteRetargeted => "retargeted"
    PullRequestRemoteHeadChanged => "head-changed"
    PullRequestRemoteEdited => "edited"
    PullRequestRemoteDuplicate => "duplicate"
  }
}

///|
async fn observe_pull_request_remote_state(
  case : NativePullRequestRemoteStateCase,
) -> NativePullRequestRemoteStateObservation {
  let fixture = prepare_goal_finalization_fixture(
    pull_request_remote_state_label(case),
  )
  guard fixture.3.val is Some(snapshot) else {
    fail("remote-state fixture has no pull request")
  }
  let lookup = match case {
    PullRequestRemoteExact =>
      @workflow.PullRequestLookupObservation::PullRequestUniqueMarkerMatch(
        snapshot,
      )
    PullRequestRemoteClosed =>
      @workflow.PullRequestLookupObservation::PullRequestUniqueMarkerMatch({
        ..snapshot,
        state: @workflow.RemotePullRequestState::RemotePullRequestClosed,
      })
    PullRequestRemoteRetargeted =>
      @workflow.PullRequestLookupObservation::PullRequestUniqueMarkerMatch({
        ..snapshot,
        base_ref: @workflow.GitRefName("refs/heads/release"),
      })
    PullRequestRemoteHeadChanged =>
      @workflow.PullRequestLookupObservation::PullRequestUniqueMarkerMatch({
        ..snapshot,
        observed_head_oid: @control.GitOid("remote-state-other-head"),
      })
    PullRequestRemoteEdited =>
      @workflow.PullRequestLookupObservation::PullRequestUniqueMarkerMatch({
        ..snapshot,
        title_digest: @storage.artifact_digest(@utf8.encode("edited title")),
        body_digest: @storage.artifact_digest(@utf8.encode("edited body")),
      })
    PullRequestRemoteDuplicate =>
      @workflow.PullRequestLookupObservation::PullRequestMultipleMarkerMatches
  }
  let observed_lookup : Ref[@workflow.PullRequestLookupObservation] = Ref(
    lookup,
  )
  let forge : NativePullRequestForgeAdapters = {
    resolve_repository: fixture.4.resolve_repository,
    lookup: (_, _, _) => observed_lookup.val,
    create: fixture.4.create,
  }
  let mut outcome = match
    advance_native_goal_finalization_with_adapters(
      fixture.0,
      fixture.2,
      forge,
      reconcile_sources=fn(_, _, _) { Ok(()) },
    ) {
    Ok(value) => value
    Err(error) => fail("remote-state finalization: " + error.message())
  }
  if case == NativePullRequestRemoteStateCase::PullRequestRemoteExact {
    // The ready pull request parks the Goal awaiting merge; simulate the
    // human merge and observe delivery on the follow-up tick.
    assert_eq(
      outcome,
      @workflow.GoalFinalizationTickOutcome::GoalFinalizationAwaitingMerge,
    )
    simulate_fixture_pull_request_merge(fixture.1, fixture.3)
    guard fixture.3.val is Some(merged_snapshot) else {
      fail("merge simulation lost the pull request")
    }
    observed_lookup.val = @workflow.PullRequestLookupObservation::PullRequestUniqueMarkerMatch(
      merged_snapshot,
    )
    outcome = match
      advance_native_goal_finalization_with_adapters(
        fixture.0,
        fixture.2,
        forge,
        reconcile_sources=fn(_, _, _) { Ok(()) },
      ) {
      Ok(value) => value
      Err(error) => fail("remote-state delivery: " + error.message())
    }
  }
  let repository = native_goal_repository(fixture.0)
  let adapters = local_part_workflow_repository_adapters()
  let decision = @workflow.load_goal_finalization_record(
      repository,
      adapters,
      fixture.2,
    )
    .unwrap()
    .unwrap().record.readiness.decision
  let goal_state = @workflow.load_goal_execution_record(
      repository,
      adapters,
      fixture.2,
    )
    .unwrap()
    .unwrap().record.state
  let passed = match case {
    PullRequestRemoteExact =>
      outcome ==
      @workflow.GoalFinalizationTickOutcome::GoalFinalizationSucceeded &&
      decision ==
      @workflow.PullRequestReadinessDecision::PullRequestMergeObserved &&
      goal_state == @workflow.GoalExecutionState::GoalExecutionSucceeded
    PullRequestRemoteEdited =>
      outcome ==
      @workflow.GoalFinalizationTickOutcome::GoalFinalizationAwaitingMerge &&
      decision == @workflow.PullRequestReadinessDecision::PullRequestReady &&
      goal_state == @workflow.GoalExecutionState::GoalExecutionAwaitingMerge
    PullRequestRemoteClosed =>
      outcome ==
      @workflow.GoalFinalizationTickOutcome::GoalFinalizationNeedsUserInput &&
      decision ==
      @workflow.PullRequestReadinessDecision::PullRequestReadinessNeedsInput(
        @workflow.PullRequestReadinessNeedsInputReason::PullRequestNotOpen,
      ) &&
      goal_state == @workflow.GoalExecutionState::GoalExecutionAssured
    PullRequestRemoteRetargeted | PullRequestRemoteHeadChanged =>
      outcome == @workflow.GoalFinalizationTickOutcome::GoalFinalizationDrifted &&
      decision ==
      @workflow.PullRequestReadinessDecision::PullRequestReadinessDrift(
        @workflow.PullRequestReadinessDriftReason::PullRequestHeadOrBaseChanged,
      ) &&
      goal_state == @workflow.GoalExecutionState::GoalExecutionAssured
    PullRequestRemoteDuplicate =>
      outcome ==
      @workflow.GoalFinalizationTickOutcome::GoalFinalizationAmbiguous &&
      decision ==
      @workflow.PullRequestReadinessDecision::PullRequestReadinessAmbiguous &&
      goal_state == @workflow.GoalExecutionState::GoalExecutionAssured
  }
  ignore(@sys.rm_rf(fixture.0))
  ignore(@sys.rm_rf(fixture.1))
  { case, outcome, decision, goal_state, passed }
}

///|
/// Simulate the human merge for a finalization fixture: fast-forward the
/// bare remote's target branch to the pull request head and report the pull
/// request merged with that head as the merge commit.
async fn simulate_fixture_pull_request_merge(
  remote_root : String,
  snapshot_ref : Ref[@workflow.RemotePullRequestSnapshot?],
) -> Unit {
  guard snapshot_ref.val is Some(snapshot) else {
    abort("merge simulation fixture has no pull request")
  }
  match
    capture_native_goal_git(remote_root, [
      "update-ref",
      snapshot.base_ref.0,
      snapshot.observed_head_oid.0,
    ]) {
    Ok(capture) =>
      if capture.exit_code != 0 {
        abort("merge simulation update-ref failed: " + capture.output)
      }
    Err(error) => abort("merge simulation git failed: " + error.message())
  }
  snapshot_ref.val = Some({
    ..snapshot,
    state: @workflow.RemotePullRequestState::RemotePullRequestMerged,
    merge_commit_oid: Some(snapshot.observed_head_oid),
  })
}

///|
pub async fn run_native_pull_request_remote_state_conformance() -> NativePullRequestRemoteStateConformanceReport {
  let observations : Array[NativePullRequestRemoteStateObservation] = []
  let cases = [
    NativePullRequestRemoteStateCase::PullRequestRemoteExact,
    NativePullRequestRemoteStateCase::PullRequestRemoteClosed,
    NativePullRequestRemoteStateCase::PullRequestRemoteRetargeted,
    NativePullRequestRemoteStateCase::PullRequestRemoteHeadChanged,
    NativePullRequestRemoteStateCase::PullRequestRemoteEdited,
    NativePullRequestRemoteStateCase::PullRequestRemoteDuplicate,
  ]
  for case in cases {
    observations.push(observe_pull_request_remote_state(case))
  }
  {
    observations,
    passed: observations.length() == cases.length() &&
    observations.all(fn(observation) { observation.passed }),
  }
}

///|
async test "real exec integration: final PR remote states have exact outcomes" {
  if !real_exec_integration_enabled() {
    return
  }
  let report = run_native_pull_request_remote_state_conformance()
  assert_true(report.passed)
  assert_eq(report.observations.length(), 6)
}

///|
pub(all) struct NativeGoalFinalizationRaceConformanceReport {
  edit_before_response_accepted : Bool
  edit_after_response_did_not_retroactively_change_decision : Bool
  success_won_before_late_cancellation : Bool
  cancellation_won_after_ready_before_success : Bool
  terminal_outboxes_unique : Bool
  passed : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
pub async fn run_native_goal_finalization_race_conformance() -> NativeGoalFinalizationRaceConformanceReport {
  let before = prepare_goal_finalization_fixture("edit-before-response")
  guard before.3.val is Some(before_snapshot) else {
    fail("pre-response fixture has no remote pull request")
  }
  before.3.val = Some({
    ..before_snapshot,
    body_digest: @storage.artifact_digest(
      @utf8.encode("reviewer edited the PR body"),
    ),
  })
  let before_wait_outcome = match
    advance_native_goal_finalization_with_adapters(
      before.0,
      before.2,
      before.4,
      reconcile_sources=fn(_, _, _) { Ok(()) },
    ) {
    Ok(value) => value
    Err(error) => fail("edit before response: " + error.message())
  }
  simulate_fixture_pull_request_merge(before.1, before.3)
  let before_outcome = match
    advance_native_goal_finalization_with_adapters(
      before.0,
      before.2,
      before.4,
      reconcile_sources=fn(_, _, _) { Ok(()) },
    ) {
    Ok(value) => value
    Err(error) => fail("edit before delivery: " + error.message())
  }
  let before_repository = native_goal_repository(before.0)
  let adapters = local_part_workflow_repository_adapters()
  let before_goal_state = @workflow.load_goal_execution_record(
      before_repository,
      adapters,
      before.2,
    )
    .unwrap()
    .unwrap().record.state
  let edit_before_response_accepted = before_wait_outcome ==
    @workflow.GoalFinalizationTickOutcome::GoalFinalizationAwaitingMerge &&
    before_outcome ==
    @workflow.GoalFinalizationTickOutcome::GoalFinalizationSucceeded &&
    before_goal_state == @workflow.GoalExecutionState::GoalExecutionSucceeded
  assert_true(edit_before_response_accepted)
  ignore(@sys.rm_rf(before.0))
  ignore(@sys.rm_rf(before.1))

  let after = prepare_goal_finalization_fixture("edit-after-response")
  guard after.3.val is Some(after_snapshot) else {
    fail("post-response fixture has no remote pull request")
  }
  let edit_after_response = Ref(true)
  let after_forge : NativePullRequestForgeAdapters = {
    resolve_repository: after.4.resolve_repository,
    lookup: (_, _, _) => {
      let observed = after.3.val.unwrap()
      if edit_after_response.val {
        edit_after_response.val = false
        after.3.val = Some({
          ..observed,
          body_digest: @storage.artifact_digest(
            @utf8.encode("body edited after the readiness observation"),
          ),
        })
      }
      @workflow.PullRequestLookupObservation::PullRequestUniqueMarkerMatch(
        observed,
      )
    },
    create: after.4.create,
  }
  let original_body_digest = after_snapshot.body_digest
  let after_wait_outcome = match
    advance_native_goal_finalization_with_adapters(
      after.0,
      after.2,
      after_forge,
      reconcile_sources=fn(_, _, _) { Ok(()) },
    ) {
    Ok(value) => value
    Err(error) => fail("edit after response: " + error.message())
  }
  guard after.3.val is Some(edited_snapshot) else {
    fail("post-response remote edit disappeared")
  }
  simulate_fixture_pull_request_merge(after.1, after.3)
  let after_outcome = match
    advance_native_goal_finalization_with_adapters(
      after.0,
      after.2,
      after_forge,
      reconcile_sources=fn(_, _, _) { Ok(()) },
    ) {
    Ok(value) => value
    Err(error) => fail("edit after delivery: " + error.message())
  }
  let edit_after_response_did_not_retroactively_change_decision = after_wait_outcome ==
    @workflow.GoalFinalizationTickOutcome::GoalFinalizationAwaitingMerge &&
    after_outcome ==
    @workflow.GoalFinalizationTickOutcome::GoalFinalizationSucceeded &&
    edited_snapshot.body_digest != original_body_digest
  assert_true(edit_after_response_did_not_retroactively_change_decision)
  let after_repository = native_goal_repository(after.0)
  let success_won_before_late_cancellation = cancel_native_goal(
      after.0,
      after.2,
      100L,
    ).unwrap() ==
    @workflow.GoalCancellationPersistenceResult::GoalCancellationTerminal(
      @workflow.GoalExecutionState::GoalExecutionSucceeded,
    )
  assert_true(success_won_before_late_cancellation)
  // Version 2 is the AwaitingMerge advance, version 3 the success.
  let success_outbox_present = (adapters.state.read_outbox)(
      after_repository.state_store,
      goal_execution_outbox_key(after.2, 3),
    ).unwrap()
    is Some(_)
  let success_next_outbox_absent = (adapters.state.read_outbox)(
      after_repository.state_store,
      goal_execution_outbox_key(after.2, 4),
    ).unwrap()
    is None
  assert_true(success_outbox_present && success_next_outbox_absent)
  ignore(@sys.rm_rf(after.0))
  ignore(@sys.rm_rf(after.1))

  let canceled = prepare_goal_finalization_fixture("cancellation-wins")
  // Reach AwaitingMerge with the merge already observed, then inject the
  // crash between the delivery observation and the success transaction.
  simulate_fixture_pull_request_merge(canceled.1, canceled.3)
  assert_eq(
    advance_native_goal_finalization_with_adapters(
      canceled.0,
      canceled.2,
      canceled.4,
      reconcile_sources=fn(_, _, _) { Ok(()) },
    ).unwrap(),
    @workflow.GoalFinalizationTickOutcome::GoalFinalizationAwaitingMerge,
  )
  assert_true(
    advance_native_goal_finalization_with_adapters(
      canceled.0,
      canceled.2,
      canceled.4,
      reconcile_sources=fn(_, _, _) { Ok(()) },
      fault=Some(
        @workflow.GoalFinalizationFaultPoint::PullRequestAfterReadinessObservationBeforeSuccessTransaction,
      ),
    )
    is Err(_),
  )
  let canceled_repository = native_goal_repository(canceled.0)
  let ready_before_race = @workflow.load_goal_finalization_record(
      canceled_repository,
      adapters,
      canceled.2,
    )
    .unwrap()
    .unwrap().record.readiness.decision ==
    @workflow.PullRequestReadinessDecision::PullRequestMergeObserved
  let cancellation_linearized = cancel_native_goal(canceled.0, canceled.2, 200L).unwrap()
    is @workflow.GoalCancellationPersistenceResult::GoalCancellationPersisted(_)
  let success_rejected = advance_native_goal_finalization_with_adapters(
      canceled.0,
      canceled.2,
      canceled.4,
      reconcile_sources=fn(_, _, _) { Ok(()) },
    )
    is Err(_)
  let canceling_record = @workflow.load_goal_execution_record(
      canceled_repository,
      adapters,
      canceled.2,
    )
    .unwrap()
    .unwrap()
  let release_authorized = @workflow.authorize_goal_source_release(
    canceling_record.record,
    canceling_record.record.source_claims[0].part_id,
  ).unwrap()
  let canceling_record = @workflow.persist_goal_execution_transition(
    canceled_repository, adapters, canceling_record, release_authorized,
  ).unwrap()
  let released = @workflow.reconcile_goal_source_release(
    canceling_record.record,
    canceling_record.record.source_claims[0].part_id,
    @workflow.GoalSourceClaimObservation::GoalSourceUnclaimedExact,
    201L,
  ).unwrap()
  let canceling_record = @workflow.persist_goal_execution_transition(
    canceled_repository, adapters, canceling_record, released,
  ).unwrap()
  let canceled_record = match
    @workflow.persist_goal_cancellation_completion(
      canceled_repository, adapters, canceling_record,
    ) {
    Ok(value) => value.record
    Err(error) => fail("cancellation completion: " + error.message())
  }
  let cancellation_won_after_ready_before_success = ready_before_race &&
    cancellation_linearized &&
    success_rejected &&
    canceled_record.state == @workflow.GoalExecutionState::GoalExecutionCanceled
  assert_true(cancellation_won_after_ready_before_success)
  let cancellation_outbox_present = (adapters.state.read_outbox)(
      canceled_repository.state_store,
      goal_execution_outbox_key(canceled.2, canceled_record.durable_version),
    ).unwrap()
    is Some(_)
  let cancellation_next_outbox_absent = (adapters.state.read_outbox)(
      canceled_repository.state_store,
      goal_execution_outbox_key(canceled.2, canceled_record.durable_version + 1),
    ).unwrap()
    is None
  let terminal_outboxes_unique = success_outbox_present &&
    success_next_outbox_absent &&
    cancellation_outbox_present &&
    cancellation_next_outbox_absent
  assert_true(terminal_outboxes_unique)
  ignore(@sys.rm_rf(canceled.0))
  ignore(@sys.rm_rf(canceled.1))
  {
    edit_before_response_accepted,
    edit_after_response_did_not_retroactively_change_decision,
    success_won_before_late_cancellation,
    cancellation_won_after_ready_before_success,
    terminal_outboxes_unique,
    passed: edit_before_response_accepted &&
    edit_after_response_did_not_retroactively_change_decision &&
    success_won_before_late_cancellation &&
    cancellation_won_after_ready_before_success &&
    terminal_outboxes_unique,
  }
}

///|
async test "real exec integration: final PR readiness and terminal decisions linearize exactly" {
  if !real_exec_integration_enabled() {
    return
  }
  let report = run_native_goal_finalization_race_conformance()
  assert_true(report.passed)
}
