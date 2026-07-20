///|
pub(all) struct GoalPartWorkflowBinding {
  scheduling_record : @workflow.GoalPartSchedulingRecord
  initial_snapshot : @workflow.PartWorkflowSnapshot
  repository : @workflow.PartWorkflowRepository
}

///|
pub(all) struct GoalPartWorkflowAdapterConfig {
  bindings : Array[GoalPartWorkflowBinding]
  repository_adapters : @workflow.PartWorkflowRepositoryAdapters
  dependencies : (@control.PartId, @workflow.PartIntegrationAdmission) -> Result[
    @workflow.PartWorkflowDriverDependencies,
    @types.ChoirError,
  ]
  integration_input : (
    @workflow.PartWorkflowSnapshot,
    @workflow.DeterministicPromotionSelection,
  ) -> Result[@workflow.IntegrationPlanInput, @types.ChoirError]
  plan_conflict_repair : (@workflow.PartWorkflowSnapshot) -> Result[
    @workflow.PartConflictRepairDecision,
    @types.ChoirError,
  ]
  read_goal_head : async () -> Result[@control.GitOid, @types.ChoirError]
}

///|
fn goal_part_adapter_error(message : String) -> @types.ChoirError {
  @types.ChoirError::validation_error("Goal Part adapter: " + message)
}

///|
fn goal_part_binding(
  config : GoalPartWorkflowAdapterConfig,
  part_id : @control.PartId,
) -> GoalPartWorkflowBinding? {
  for binding in config.bindings {
    if binding.scheduling_record.part.id == part_id {
      return Some(binding)
    }
  }
  None
}

///|
fn scheduling_record_from_snapshot(
  snapshot : @workflow.PartWorkflowSnapshot,
) -> @workflow.GoalPartSchedulingRecord {
  { part: snapshot.part, task_contract: snapshot.task_contract }
}

///|
fn validate_goal_part_binding(
  binding : GoalPartWorkflowBinding,
  record : @workflow.GoalPartSchedulingRecord,
) -> Result[Unit, @types.ChoirError] {
  if binding.scheduling_record.part.id != record.part.id ||
    binding.scheduling_record.part.goal_id != record.part.goal_id ||
    binding.scheduling_record.part.dependency_ids != record.part.dependency_ids ||
    binding.initial_snapshot.part.id != record.part.id ||
    binding.initial_snapshot.goal.id != record.part.goal_id ||
    record.task_contract.goal_id != record.part.goal_id ||
    record.task_contract.part_id != record.part.id ||
    record.task_contract.id != record.part.task_contract_revision_id {
    Err(goal_part_adapter_error("binding identity is inconsistent"))
  } else {
    Ok(())
  }
}

///|
async fn advance_bound_part(
  config : GoalPartWorkflowAdapterConfig,
  record : @workflow.GoalPartSchedulingRecord,
) -> Result[@workflow.GoalPartSchedulingRecord, @types.ChoirError] {
  let binding = match goal_part_binding(config, record.part.id) {
    Some(value) => value
    None => return Err(goal_part_adapter_error("Part binding is absent"))
  }
  match validate_goal_part_binding(binding, record) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match
    @workflow.initialize_part_workflow_repository(
      binding.repository,
      config.repository_adapters,
    ) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let dependencies = match
    (config.dependencies)(
      record.part.id,
      @workflow.PartIntegrationAdmission::PartIntegrationDeferred,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let stored = match
    @workflow.load_part_snapshot(
      binding.repository,
      config.repository_adapters,
      binding.initial_snapshot.workflow_id,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let result = match stored {
    Some(value) => {
      if scheduling_record_from_snapshot(value.snapshot) != record {
        return Err(goal_part_adapter_error("advance record is stale"))
      }
      @workflow.resume_part_workflow(
        binding.repository,
        config.repository_adapters,
        binding.initial_snapshot.workflow_id,
        dependencies,
      )
    }
    None => {
      if !(record.part.lifecycle is @control.PartLifecycle::PartPending) &&
        !(record.part.lifecycle is @control.PartLifecycle::PartReady) {
        return Err(goal_part_adapter_error("active Part snapshot is absent"))
      }
      @workflow.run_new_part_workflow(
        binding.repository,
        config.repository_adapters,
        binding.initial_snapshot,
        dependencies,
      )
    }
  }
  match result {
    Ok(value) => Ok(scheduling_record_from_snapshot(value.snapshot))
    Err(error) => Err(error)
  }
}

///|
async fn promote_bound_part(
  config : GoalPartWorkflowAdapterConfig,
  record : @workflow.GoalPartSchedulingRecord,
  selection : @workflow.DeterministicPromotionSelection,
) -> Result[@workflow.GoalPartSchedulingRecord, @types.ChoirError] {
  let binding = match goal_part_binding(config, record.part.id) {
    Some(value) => value
    None => return Err(goal_part_adapter_error("Part binding is absent"))
  }
  match
    @workflow.initialize_part_workflow_repository(
      binding.repository,
      config.repository_adapters,
    ) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let stored = match
    @workflow.load_part_snapshot(
      binding.repository,
      config.repository_adapters,
      binding.initial_snapshot.workflow_id,
    ) {
    Ok(Some(value)) => value
    Ok(None) => return Err(goal_part_adapter_error("Part snapshot is absent"))
    Err(error) => return Err(error)
  }
  if scheduling_record_from_snapshot(stored.snapshot) != record {
    return Err(goal_part_adapter_error("promotion record is stale"))
  }
  let input = match (config.integration_input)(stored.snapshot, selection) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if selection.part_id != stored.snapshot.part.id ||
    input.expected_goal_head_oid != selection.expected_goal_head_oid {
    return Err(goal_part_adapter_error("promotion selection is stale"))
  }
  let dependencies = match
    (config.dependencies)(
      record.part.id,
      @workflow.PartIntegrationAdmission::PartIntegrationAdmitted(input),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let result = match
    @workflow.resume_part_workflow(
      binding.repository,
      config.repository_adapters,
      binding.initial_snapshot.workflow_id,
      dependencies,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if !(result.snapshot.part.lifecycle is @control.PartLifecycle::PartBlocked(
      @control.PartBlockReason::PartIntegrationConflict,
    )) {
    return Ok(scheduling_record_from_snapshot(result.snapshot))
  }
  let repaired = match (config.plan_conflict_repair)(result.snapshot) {
    Ok(@workflow.PartConflictRepairDecision::PartConflictRepairPlanned(value)) =>
      value
    Ok(@workflow.PartConflictRepairDecision::PartConflictRepairLimitReached) =>
      return Ok(scheduling_record_from_snapshot(result.snapshot))
    Err(error) => return Err(error)
  }
  let current_version = match result.store_version {
    Some(value) => value
    None => return Err(goal_part_adapter_error("conflict snapshot is unpersisted"))
  }
  let authorization = match (dependencies.goal_authorizes_new_effects)() {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let persisted = match authorization {
    @workflow.PartGoalAuthorization::PartGoalNotAuthorized =>
      return Ok(scheduling_record_from_snapshot(result.snapshot))
    @workflow.PartGoalAuthorization::PartGoalAuthorized(None) =>
      match
        @workflow.persist_part_snapshot(
          binding.repository,
          config.repository_adapters,
          {
            snapshot: repaired,
            expected_store_version: Some(current_version),
            fault_point: None,
          },
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
    @workflow.PartGoalAuthorization::PartGoalAuthorized(Some(precondition)) =>
      match
        @workflow.persist_part_snapshot_guarded(
          binding.repository,
          config.repository_adapters,
          {
            snapshot: repaired,
            expected_store_version: Some(current_version),
            fault_point: None,
          },
          precondition,
        ) {
        Ok(@workflow.GuardedPartSnapshotPersistenceResult::GuardedPartSnapshotPersisted(value)) =>
          value
        Ok(@workflow.GuardedPartSnapshotPersistenceResult::GuardedPartSnapshotPreconditionConflict) =>
          return Ok(scheduling_record_from_snapshot(result.snapshot))
        Err(error) => return Err(error)
      }
  }
  match persisted.transaction_outcome {
    @storage.StateTransactionOutcome::StateTransactionCommitted
    | @storage.StateTransactionOutcome::StateTransactionReplayed
    | @storage.StateTransactionOutcome::StateTransactionCommittedAckLost => ()
    _ => return Err(goal_part_adapter_error("conflict repair did not persist"))
  }
  let repair_dependencies = match
    (config.dependencies)(
      record.part.id,
      @workflow.PartIntegrationAdmission::PartIntegrationDeferred,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match
    @workflow.resume_part_workflow(
      binding.repository,
      config.repository_adapters,
      binding.initial_snapshot.workflow_id,
      repair_dependencies,
    ) {
    Ok(value) => Ok(scheduling_record_from_snapshot(value.snapshot))
    Err(error) => Err(error)
  }
}

///|
async fn resume_bound_promotion(
  config : GoalPartWorkflowAdapterConfig,
  record : @workflow.GoalPartSchedulingRecord,
) -> Result[@workflow.GoalPartSchedulingRecord, @types.ChoirError] {
  let binding = match goal_part_binding(config, record.part.id) {
    Some(value) => value
    None => return Err(goal_part_adapter_error("Part binding is absent"))
  }
  match
    @workflow.initialize_part_workflow_repository(
      binding.repository,
      config.repository_adapters,
    ) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let stored = match
    @workflow.load_part_snapshot(
      binding.repository,
      config.repository_adapters,
      binding.initial_snapshot.workflow_id,
    ) {
    Ok(Some(value)) => value.snapshot
    Ok(None) => return Err(goal_part_adapter_error("Part snapshot is absent"))
    Err(error) => return Err(error)
  }
  if scheduling_record_from_snapshot(stored) != record {
    return Err(goal_part_adapter_error("promotion recovery record is stale"))
  }
  let dependencies = match
    (config.dependencies)(
      record.part.id,
      @workflow.PartIntegrationAdmission::PartIntegrationDeferred,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match
    @workflow.resume_part_workflow(
      binding.repository,
      config.repository_adapters,
      binding.initial_snapshot.workflow_id,
      dependencies,
    ) {
    Ok(value) => Ok(scheduling_record_from_snapshot(value.snapshot))
    Err(error) => Err(error)
  }
}

///|
pub fn goal_part_workflow_adapters(
  config : GoalPartWorkflowAdapterConfig,
) -> @workflow.GoalRunnerAdapters {
  {
    advance_part: async fn(record) { advance_bound_part(config, record) },
    read_goal_head: config.read_goal_head,
    promote_part: async fn(record, selection) {
      promote_bound_part(config, record, selection)
    },
    resume_promotion: async fn(record) {
      resume_bound_promotion(config, record)
    },
  }
}
