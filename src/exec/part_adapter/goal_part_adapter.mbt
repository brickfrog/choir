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
  plan_audit_repair : (@workflow.PartWorkflowSnapshot) -> Result[
    @workflow.PartAuditRepairDecision,
    @types.ChoirError,
  ]
  plan_verification_repair : (@workflow.PartWorkflowSnapshot) -> Result[
    @workflow.PartVerificationRepairDecision,
    @types.ChoirError,
  ]
  plan_recovery_retry : (@workflow.PartWorkflowSnapshot) -> Result[
    @workflow.PartRecoveryRetryDecision,
    @types.ChoirError,
  ]
  read_goal_head : async () -> Result[@control.GitOid, @types.ChoirError]
  /// Give back the provider slot this Part's admission gate took.
  release_provider_lease : (@control.PartId) -> Result[Unit, @types.ChoirError]
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
      // A Part parked on provider-dispatch uncertainty cannot resume: resolve
      // it here from durable evidence so unattended work never waits on an
      // operator `retry_part`.
      if value.snapshot.stage ==
        @workflow.PartWorkflowStage::PartRecoveryUncertain {
        let (recovered, repair_name) = match
          (config.plan_recovery_retry)(value.snapshot) {
          Ok(
            @workflow.PartRecoveryRetryDecision::PartRecoveryRetryPlanned(
              planned
            )
          ) => (planned, "recovery")
          // The surface the Part was on cannot serve and its contract admits
          // another: the fresh Take is armed there. The durable record of the
          // move is the snapshot's provider failovers; this label only names
          // the transition if persisting it fails.
          Ok(
            @workflow.PartRecoveryRetryDecision::PartRecoveryRetryFailedOver(
              planned,
              _
            )
          ) => (planned, "provider-failover")
          Ok(@workflow.PartRecoveryRetryDecision::PartRecoveryRetryRetained)
          | Ok(
            @workflow.PartRecoveryRetryDecision::PartRecoveryRetryLimitReached
          )
          | Ok(
            @workflow.PartRecoveryRetryDecision::PartRecoveryRetryDeferred(_)
          ) => return Ok(scheduling_record_from_snapshot(value.snapshot))
          Err(error) => return Err(error)
        }
        match
          persist_bound_part_repair(
            config,
            binding,
            dependencies,
            recovered,
            value.state_record.version,
            repair_name,
          ) {
          Ok(Some(persisted)) =>
            return Ok(scheduling_record_from_snapshot(persisted))
          Ok(None) => return Ok(scheduling_record_from_snapshot(value.snapshot))
          Err(error) => return Err(error)
        }
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
        return Err(
          goal_part_adapter_error(
            "active Part snapshot is absent: part=" +
            record.part.id.0 +
            " lifecycle=" +
            record.part.lifecycle.to_json().stringify(indent=0),
          ),
        )
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
    Ok(value) => {
      let (repaired, repair_name) = match value.snapshot.part.lifecycle {
        @control.PartLifecycle::PartBlocked(
          @control.PartBlockReason::PartAuditFindings
        ) => {
          guard value.snapshot.audit_result is Some(audit_result) &&
            audit_result.outcome == @control.AuditOutcome::AuditFindings &&
            audit_result.blocking_findings_count > 0 &&
            audit_result.findings_artifact is Some(_) else {
            return Ok(scheduling_record_from_snapshot(value.snapshot))
          }
          match (config.plan_audit_repair)(value.snapshot) {
            Ok(
              @workflow.PartAuditRepairDecision::PartAuditRepairPlanned(planned)
            ) => (planned, "audit")
            Ok(@workflow.PartAuditRepairDecision::PartAuditRepairLimitReached) =>
              return Ok(scheduling_record_from_snapshot(value.snapshot))
            Err(error) => return Err(error)
          }
        }
        @control.PartLifecycle::PartBlocked(
          @control.PartBlockReason::PartVerificationFailed
        ) =>
          match (config.plan_verification_repair)(value.snapshot) {
            Ok(
              @workflow.PartVerificationRepairDecision::PartVerificationRepairPlanned(
                planned
              )
            ) => (planned, "verification")
            Ok(
              @workflow.PartVerificationRepairDecision::PartVerificationRepairLimitReached
            ) => return Ok(scheduling_record_from_snapshot(value.snapshot))
            Err(error) => return Err(error)
          }
        @control.PartLifecycle::PartBlocked(
          @control.PartBlockReason::PartOwnershipViolation
        ) =>
          match (config.plan_recovery_retry)(value.snapshot) {
            Ok(
              @workflow.PartRecoveryRetryDecision::PartRecoveryRetryPlanned(
                planned
              )
            ) => (planned, "ownership")
            Ok(
              @workflow.PartRecoveryRetryDecision::PartRecoveryRetryLimitReached
            ) => return Ok(scheduling_record_from_snapshot(value.snapshot))
            Ok(_) =>
              return Err(
                goal_part_adapter_error(
                  "ownership repair returned an invalid disposition",
                ),
              )
            Err(error) => return Err(error)
          }
        _ => return Ok(scheduling_record_from_snapshot(value.snapshot))
      }
      let current_version = match value.store_version {
        Some(version) => version
        None =>
          return Err(
            goal_part_adapter_error(
              repair_name + " repair snapshot is unpersisted",
            ),
          )
      }
      match
        persist_bound_part_repair(
          config, binding, dependencies, repaired, current_version, repair_name,
        ) {
        Ok(Some(persisted)) => Ok(scheduling_record_from_snapshot(persisted))
        Ok(None) => Ok(scheduling_record_from_snapshot(value.snapshot))
        Err(error) => Err(error)
      }
    }
    Err(error) => Err(error)
  }
}

///|
/// Persist a re-armed Part under the Goal's current authorization. `None` means
/// the Goal withdrew authority or another writer won the compare-and-set: the
/// caller keeps the observed snapshot and retries on a later tick.
fn persist_bound_part_repair(
  config : GoalPartWorkflowAdapterConfig,
  binding : GoalPartWorkflowBinding,
  dependencies : @workflow.PartWorkflowDriverDependencies,
  repaired : @workflow.PartWorkflowSnapshot,
  current_version : Int,
  label : String,
) -> Result[@workflow.PartWorkflowSnapshot?, @types.ChoirError] {
  let authorization = match (dependencies.goal_authorizes_new_effects)() {
    Ok(current) => current
    Err(error) => return Err(error)
  }
  let request : @workflow.PartSnapshotPersistenceRequest = {
    snapshot: repaired,
    expected_store_version: Some(current_version),
    fault_point: None,
  }
  let persisted = match authorization {
    // A deferral and a standing refusal both mean the repair is not persisted
    // on this pass. The gate itself told the tick which surface refused and
    // when, so nothing has to be forwarded from here — and with nothing to
    // forward, one arm rather than two identical ones.
    @workflow.PartGoalAuthorization::PartGoalDeferredUntil(_)
    | @workflow.PartGoalAuthorization::PartGoalNotAuthorized => return Ok(None)
    @workflow.PartGoalAuthorization::PartGoalAuthorized(None) =>
      match
        @workflow.persist_part_snapshot(
          binding.repository,
          config.repository_adapters,
          request,
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
    @workflow.PartGoalAuthorization::PartGoalAuthorized(Some(precondition)) =>
      match
        @workflow.persist_part_snapshot_guarded(
          binding.repository,
          config.repository_adapters,
          request,
          precondition,
        ) {
        Ok(
          @workflow.GuardedPartSnapshotPersistenceResult::GuardedPartSnapshotPersisted(
            value
          )
        ) => value
        Ok(
          @workflow.GuardedPartSnapshotPersistenceResult::GuardedPartSnapshotPreconditionConflict
        ) => return Ok(None)
        Err(error) => return Err(error)
      }
  }
  match persisted.transaction_outcome {
    @storage.StateTransactionOutcome::StateTransactionCommitted
    | @storage.StateTransactionOutcome::StateTransactionReplayed
    | @storage.StateTransactionOutcome::StateTransactionCommittedAckLost =>
      Ok(Some(repaired))
    _ => Err(goal_part_adapter_error(label + " repair did not persist"))
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
  if !(result.snapshot.part.lifecycle
    is @control.PartLifecycle::PartBlocked(
      @control.PartBlockReason::PartIntegrationConflict
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
    None =>
      return Err(goal_part_adapter_error("conflict snapshot is unpersisted"))
  }
  let authorization = match (dependencies.goal_authorizes_new_effects)() {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let persisted = match authorization {
    // A promotion the gate refused keeps the observed snapshot, whether the
    // refusal was standing or a capacity deferral: the gate has already told
    // the tick which surface refused it and when, so neither arm has anything
    // of its own left to do.
    @workflow.PartGoalAuthorization::PartGoalDeferredUntil(_)
    | @workflow.PartGoalAuthorization::PartGoalNotAuthorized =>
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
        Ok(
          @workflow.GuardedPartSnapshotPersistenceResult::GuardedPartSnapshotPersisted(
            value
          )
        ) => value
        Ok(
          @workflow.GuardedPartSnapshotPersistenceResult::GuardedPartSnapshotPreconditionConflict
        ) => return Ok(scheduling_record_from_snapshot(result.snapshot))
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
    advance_part: async fn(record) {
      release_after_part_pass(
        config,
        record.part.id,
        advance_bound_part(config, record),
      )
    },
    read_goal_head: config.read_goal_head,
    promote_part: async fn(record, selection) {
      release_after_part_pass(
        config,
        record.part.id,
        promote_bound_part(config, record, selection),
      )
    },
    resume_promotion: async fn(record) {
      release_after_part_pass(
        config,
        record.part.id,
        resume_bound_promotion(config, record),
      )
    },
  }
}

///|
/// Give the Part's provider slot back now that its pass has returned.
///
/// Every pass goes through the admission gate, so every pass may have taken a
/// slot. Holding it until the Goal tick ends would keep the Goal's other Parts
/// — and every other Goal — out of a surface that is idle, so the slot is
/// returned at the boundary the gate was entered at. Release is idempotent, so
/// a pass that took no slot is not a special case, and a release error is only
/// reported when the pass itself succeeded.
fn release_after_part_pass(
  config : GoalPartWorkflowAdapterConfig,
  part_id : @control.PartId,
  outcome : Result[@workflow.GoalPartSchedulingRecord, @types.ChoirError],
) -> Result[@workflow.GoalPartSchedulingRecord, @types.ChoirError] {
  match (config.release_provider_lease)(part_id) {
    Ok(_) => outcome
    Err(error) =>
      match outcome {
        Err(_) => outcome
        Ok(_) => Err(error)
      }
  }
}
