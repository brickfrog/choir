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
    @workflow.PullRequestReadinessDecision::PullRequestReady =>
      match
        @workflow.persist_goal_execution_success(
          repository, adapters, execution, assurance, publication, pull_request,
          stored,
        ) {
        Ok(_) =>
          Ok(@workflow.GoalFinalizationTickOutcome::GoalFinalizationSucceeded)
        Err(error) => Err(error)
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
