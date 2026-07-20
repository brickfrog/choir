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
pub async fn advance_native_goal_finalization_with_adapters(
  project_dir : String,
  goal_id : @control.GoalId,
  forge : NativePullRequestForgeAdapters,
  fault? : @workflow.GoalFinalizationFaultPoint? = None,
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
    @workflow.GoalExecutionState::GoalExecutionAssured {
    return Err(native_pull_request_error("Goal is not ready for finalization"))
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
  if native_remote_branch_observation(git, publication.intent) !=
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
      if fault ==
        Some(
          @workflow.GoalFinalizationFaultPoint::PullRequestAfterReadinessObservationBeforeSuccessTransaction,
        ) {
        return Err(
          native_pull_request_error("injected Goal finalization fault"),
        )
      }
      match
        @workflow.persist_goal_execution_success(
          repository, adapters, execution, assurance, publication, pull_request,
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
    resolve_repository: async fn(_) { Ok("choir/finalization-fixture") },
    lookup: async fn(_, _, _) {
      match remote_pull_request.val {
        Some(snapshot) =>
          @workflow.PullRequestLookupObservation::PullRequestUniqueMarkerMatch(
            snapshot,
          )
        None => @workflow.PullRequestLookupObservation::PullRequestNoMatch
      }
    },
    create: async fn(_, _, intent, document) {
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
async test "real exec integration: final PR readiness and terminal decisions linearize exactly" {
  let before = prepare_goal_finalization_fixture("edit-before-response")
  guard before.3.val is Some(before_snapshot) else {
    fail("pre-response fixture has no remote pull request")
  }
  before.3.val = Some({
    ..before_snapshot,
    evidence_manifest_link_present: false,
  })
  let before_outcome = match
    advance_native_goal_finalization_with_adapters(before.0, before.2, before.4) {
    Ok(value) => value
    Err(error) => fail("edit before response: " + error.message())
  }
  assert_eq(
    before_outcome,
    @workflow.GoalFinalizationTickOutcome::GoalFinalizationNeedsUserInput,
  )
  let before_repository = native_goal_repository(before.0)
  let adapters = local_part_workflow_repository_adapters()
  assert_eq(
    @workflow.load_goal_execution_record(before_repository, adapters, before.2)
    .unwrap()
    .unwrap().record.state,
    @workflow.GoalExecutionState::GoalExecutionAssured,
  )
  ignore(@sys.rm_rf(before.0))
  ignore(@sys.rm_rf(before.1))

  let after = prepare_goal_finalization_fixture("edit-after-response")
  guard after.3.val is Some(after_snapshot) else {
    fail("post-response fixture has no remote pull request")
  }
  let edit_after_response = Ref(true)
  let after_forge : NativePullRequestForgeAdapters = {
    resolve_repository: after.4.resolve_repository,
    lookup: async fn(_, _, _) {
      let observed = after.3.val.unwrap()
      if edit_after_response.val {
        edit_after_response.val = false
        after.3.val = Some({ ..observed, evidence_manifest_link_present: false })
      }
      @workflow.PullRequestLookupObservation::PullRequestUniqueMarkerMatch(
        observed,
      )
    },
    create: after.4.create,
  }
  assert_eq(after_snapshot.evidence_manifest_link_present, true)
  let after_outcome = match
    advance_native_goal_finalization_with_adapters(
      after.0,
      after.2,
      after_forge,
    ) {
    Ok(value) => value
    Err(error) => fail("edit after response: " + error.message())
  }
  assert_eq(
    after_outcome,
    @workflow.GoalFinalizationTickOutcome::GoalFinalizationSucceeded,
  )
  guard after.3.val is Some(edited_snapshot) else {
    fail("post-response remote edit disappeared")
  }
  assert_false(edited_snapshot.evidence_manifest_link_present)
  let after_repository = native_goal_repository(after.0)
  assert_eq(
    cancel_native_goal(after.0, after.2, 100L).unwrap(),
    @workflow.GoalCancellationPersistenceResult::GoalCancellationTerminal(
      @workflow.GoalExecutionState::GoalExecutionSucceeded,
    ),
  )
  assert_true(
    (adapters.state.read_outbox)(
      after_repository.state_store,
      goal_execution_outbox_key(after.2, 2),
    ).unwrap()
    is Some(_),
  )
  assert_true(
    (adapters.state.read_outbox)(
      after_repository.state_store,
      goal_execution_outbox_key(after.2, 3),
    ).unwrap()
    is None,
  )
  ignore(@sys.rm_rf(after.0))
  ignore(@sys.rm_rf(after.1))

  let canceled = prepare_goal_finalization_fixture("cancellation-wins")
  assert_true(
    advance_native_goal_finalization_with_adapters(
      canceled.0,
      canceled.2,
      canceled.4,
      fault=Some(
        @workflow.GoalFinalizationFaultPoint::PullRequestAfterReadinessObservationBeforeSuccessTransaction,
      ),
    )
    is Err(_),
  )
  let canceled_repository = native_goal_repository(canceled.0)
  assert_eq(
    @workflow.load_goal_finalization_record(
      canceled_repository,
      adapters,
      canceled.2,
    )
    .unwrap()
    .unwrap().record.readiness.decision,
    @workflow.PullRequestReadinessDecision::PullRequestReady,
  )
  assert_true(
    cancel_native_goal(canceled.0, canceled.2, 200L).unwrap()
    is @workflow.GoalCancellationPersistenceResult::GoalCancellationPersisted(_),
  )
  assert_true(
    advance_native_goal_finalization_with_adapters(
      canceled.0,
      canceled.2,
      canceled.4,
    )
    is Err(_),
  )
  let canceling_record = @workflow.load_goal_execution_record(
      canceled_repository,
      adapters,
      canceled.2,
    )
    .unwrap()
    .unwrap()
  let canceled_record = match
    @workflow.persist_goal_cancellation_completion(
      canceled_repository, adapters, canceling_record,
    ) {
    Ok(value) => value.record
    Err(error) => fail("cancellation completion: " + error.message())
  }
  assert_eq(
    canceled_record.state,
    @workflow.GoalExecutionState::GoalExecutionCanceled,
  )
  assert_true(
    (adapters.state.read_outbox)(
      canceled_repository.state_store,
      goal_execution_outbox_key(canceled.2, canceled_record.durable_version),
    ).unwrap()
    is Some(_),
  )
  assert_true(
    (adapters.state.read_outbox)(
      canceled_repository.state_store,
      goal_execution_outbox_key(canceled.2, canceled_record.durable_version + 1),
    ).unwrap()
    is None,
  )
  ignore(@sys.rm_rf(canceled.0))
  ignore(@sys.rm_rf(canceled.1))
}
