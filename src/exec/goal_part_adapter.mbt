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
  if binding.scheduling_record.task_contract != record.task_contract ||
    binding.scheduling_record.part.id != record.part.id ||
    binding.scheduling_record.part.goal_id != record.part.goal_id ||
    binding.scheduling_record.part.dependency_ids != record.part.dependency_ids ||
    binding.scheduling_record.part.task_contract_revision_id !=
    record.part.task_contract_revision_id ||
    binding.initial_snapshot.part.id != record.part.id ||
    binding.initial_snapshot.goal.id != record.part.goal_id ||
    binding.initial_snapshot.task_contract != record.task_contract {
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
    Some(_) =>
      @workflow.resume_part_workflow(
        binding.repository,
        config.repository_adapters,
        binding.initial_snapshot.workflow_id,
        dependencies,
      )
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
    Ok(Some(value)) => value.snapshot
    Ok(None) => return Err(goal_part_adapter_error("Part snapshot is absent"))
    Err(error) => return Err(error)
  }
  if scheduling_record_from_snapshot(stored) != record {
    return Err(goal_part_adapter_error("promotion record is stale"))
  }
  let input = match (config.integration_input)(stored, selection) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if selection.part_id != stored.part.id ||
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
