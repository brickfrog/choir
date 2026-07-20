///|
pub(all) enum PartPersistenceBoundary {
  WorkflowAcceptedSnapshot
  WorkflowEffectPlanned
  WorkflowEffectAuthorized
  WorkflowEffectObserved
  WorkflowProviderProtocolViolationRecorded
  WorkflowEventIngestionOverflowRecorded
  WorkflowProviderProcessLossRecorded
  WorkflowAuditResultRecorded
  WorkflowAuditReceiptRecorded
  WorkflowIntegrationPlanned
  WorkflowIntegrationAuthorized
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum PartEffectRecovery {
  EffectObservationRecovered(PartEffectObservation)
  ExactEffectRetryAuthorized
  EffectWitnessUnavailable
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct PartWorkflowDriverAdapters {
  execute : async (PartWorkflowSnapshot, PartEffectIntent) -> Result[
    PartEffectObservation,
    @types.ChoirError,
  ]
  reconcile : async (PartWorkflowSnapshot, PartEffectIntent) -> Result[
    PartEffectRecovery,
    @types.ChoirError,
  ]
}

///|
pub fn witnessed_part_effect_adapters(
  repository : PartWorkflowRepository,
  repository_adapters : PartWorkflowRepositoryAdapters,
  effects : PartWorkflowDriverAdapters,
  now : () -> Int64,
) -> PartWorkflowDriverAdapters {
  {
    execute: async fn(snapshot, intent) {
      let observation = match (effects.execute)(snapshot, intent) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      match
        record_part_effect_witness(
          repository,
          repository_adapters,
          snapshot,
          intent,
          observation,
          now(),
        ) {
        Ok(_) => Ok(observation)
        Err(error) => Err(error)
      }
    },
    reconcile: async fn(snapshot, intent) {
      match load_part_effect_witness(repository, repository_adapters, intent) {
        Ok(Some(witness)) => Ok(EffectObservationRecovered(witness.observation))
        Ok(None) => (effects.reconcile)(snapshot, intent)
        Err(error) => Err(error)
      }
    },
  }
}

///|
pub(all) struct PartWorkflowDriverDependencies {
  now : () -> Int64
  persistence_fault : (PartPersistenceBoundary) -> @storage.StateStoreFaultPoint?
  effects : PartWorkflowDriverAdapters
  artifact_exists : (@control.ArtifactReference) -> Bool
  artifact_digest_exists : (@control.Digest) -> Bool
  is_nfc : (String) -> Bool
  audit_receipt_metadata : (PartWorkflowSnapshot) -> Result[
    AuditReceiptMetadata,
    @types.ChoirError,
  ]
  integration_admission : (PartWorkflowSnapshot) -> Result[
    PartIntegrationAdmission,
    @types.ChoirError,
  ]
  goal_authorizes_new_effects : () -> Result[
    PartGoalAuthorization,
    @types.ChoirError,
  ]
  verification_environment_digest : (PartWorkflowSnapshot) -> @control.Digest
  verification_runtime_digest : (PartWorkflowSnapshot) -> @control.Digest
}

///|
pub(all) enum PartIntegrationAdmission {
  PartIntegrationDeferred
  PartIntegrationAdmitted(IntegrationPlanInput)
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum PartGoalAuthorization {
  PartGoalNotAuthorized
  PartGoalAuthorized(@storage.StateRecordPrecondition?)
} derive(Debug, Eq)

///|
pub(all) enum PartWorkflowRunOutcome {
  PartRunIntegrated
  PartRunCanceled
  PartRunAwaitingPromotion
  PartRunBlocked
  PartRunRecoveryUncertain
  PartRunGoalNotAuthorizing
  PartRunWaitingForEffectWitness(String)
  PartRunPersistenceFault(
    PartPersistenceBoundary,
    @storage.StateStoreFaultPoint
  )
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct PartWorkflowRunResult {
  snapshot : PartWorkflowSnapshot
  store_version : Int?
  outcome : PartWorkflowRunOutcome
} derive(Debug, Eq)

///|
priv enum PartPersistenceDecision {
  WorkflowSnapshotPersisted(Int)
  WorkflowSnapshotAuthorizationRejected
  WorkflowSnapshotPersistencePaused(
    PartPersistenceBoundary,
    @storage.StateStoreFaultPoint
  )
}

///|
fn load_exact_persisted_snapshot(
  repository : PartWorkflowRepository,
  repository_adapters : PartWorkflowRepositoryAdapters,
  snapshot : PartWorkflowSnapshot,
  expected_store_version : Int,
) -> Result[Unit, @types.ChoirError] {
  match
    load_part_snapshot(repository, repository_adapters, snapshot.workflow_id) {
    Ok(Some(stored)) =>
      if stored.state_record.version == expected_store_version &&
        stored.state_record.value_digest == part_snapshot_digest(snapshot) &&
        stored.snapshot == snapshot {
        Ok(())
      } else {
        Err(workflow_error("persistence replay resolved to another snapshot"))
      }
    Ok(None) => Err(workflow_error("persisted snapshot could not be recovered"))
    Err(error) => Err(error)
  }
}

///|
fn persist_driver_snapshot(
  repository : PartWorkflowRepository,
  repository_adapters : PartWorkflowRepositoryAdapters,
  snapshot : PartWorkflowSnapshot,
  expected_store_version : Int?,
  boundary : PartPersistenceBoundary,
  dependencies : PartWorkflowDriverDependencies,
  authorization_precondition : @storage.StateRecordPrecondition?,
) -> Result[PartPersistenceDecision, @types.ChoirError] {
  let request : PartSnapshotPersistenceRequest = {
    snapshot,
    expected_store_version,
    fault_point: (dependencies.persistence_fault)(boundary),
  }
  let guarded = match authorization_precondition {
    None =>
      match persist_part_snapshot(repository, repository_adapters, request) {
        Ok(value) => GuardedPartSnapshotPersisted(value)
        Err(error) => return Err(error)
      }
    Some(precondition) =>
      match
        persist_part_snapshot_guarded(
          repository, repository_adapters, request, precondition,
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
  }
  let receipt = match guarded {
    GuardedPartSnapshotPersisted(value) => value
    GuardedPartSnapshotPreconditionConflict =>
      return Ok(WorkflowSnapshotAuthorizationRejected)
  }
  match receipt.transaction_outcome {
    @storage.StateTransactionOutcome::StateTransactionCommitted =>
      Ok(WorkflowSnapshotPersisted(receipt.store_version))
    @storage.StateTransactionOutcome::StateTransactionReplayed
    | @storage.StateTransactionOutcome::StateTransactionCommittedAckLost =>
      match
        load_exact_persisted_snapshot(
          repository,
          repository_adapters,
          snapshot,
          receipt.store_version,
        ) {
        Ok(_) => Ok(WorkflowSnapshotPersisted(receipt.store_version))
        Err(error) => Err(error)
      }
    @storage.StateTransactionOutcome::StateTransactionFaultRolledBack(point) =>
      Ok(WorkflowSnapshotPersistencePaused(boundary, point))
    @storage.StateTransactionOutcome::StateTransactionVersionConflict =>
      Err(workflow_error("snapshot persistence version conflict"))
    @storage.StateTransactionOutcome::StateTransactionStaleFence =>
      Err(workflow_error("snapshot persistence fencing conflict"))
    @storage.StateTransactionOutcome::StateTransactionSemanticConflict =>
      Err(workflow_error("snapshot persistence semantic conflict"))
  }
}

///|
fn persistence_result(
  snapshot : PartWorkflowSnapshot,
  store_version : Int?,
  boundary : PartPersistenceBoundary,
  point : @storage.StateStoreFaultPoint,
) -> PartWorkflowRunResult {
  { snapshot, store_version, outcome: PartRunPersistenceFault(boundary, point) }
}

///|
fn persist_provider_dispatch_uncertainty(
  repository : PartWorkflowRepository,
  repository_adapters : PartWorkflowRepositoryAdapters,
  snapshot : PartWorkflowSnapshot,
  store_version : Int,
  uncertain : PartWorkflowSnapshot,
  boundary : PartPersistenceBoundary,
  dependencies : PartWorkflowDriverDependencies,
) -> Result[PartWorkflowRunResult, @types.ChoirError] {
  match
    persist_driver_snapshot(
      repository,
      repository_adapters,
      uncertain,
      Some(store_version),
      boundary,
      dependencies,
      None,
    ) {
    Ok(WorkflowSnapshotPersisted(version)) =>
      Ok({
        snapshot: uncertain,
        store_version: Some(version),
        outcome: PartRunRecoveryUncertain,
      })
    Ok(WorkflowSnapshotPersistencePaused(boundary, point)) =>
      Ok(persistence_result(snapshot, Some(store_version), boundary, point))
    Ok(WorkflowSnapshotAuthorizationRejected) =>
      Err(workflow_error("provider uncertainty used an authorization guard"))
    Err(error) => Err(error)
  }
}

///|
fn persist_provider_protocol_violation(
  repository : PartWorkflowRepository,
  repository_adapters : PartWorkflowRepositoryAdapters,
  snapshot : PartWorkflowSnapshot,
  store_version : Int,
  intent : PartEffectIntent,
  dependencies : PartWorkflowDriverDependencies,
) -> Result[PartWorkflowRunResult, @types.ChoirError] {
  let violated = match
    record_part_provider_protocol_violation(snapshot, intent) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  persist_provider_dispatch_uncertainty(
    repository,
    repository_adapters,
    snapshot,
    store_version,
    violated,
    WorkflowProviderProtocolViolationRecorded,
    dependencies,
  )
}

///|
fn persist_event_ingestion_overflow(
  repository : PartWorkflowRepository,
  repository_adapters : PartWorkflowRepositoryAdapters,
  snapshot : PartWorkflowSnapshot,
  store_version : Int,
  intent : PartEffectIntent,
  dependencies : PartWorkflowDriverDependencies,
) -> Result[PartWorkflowRunResult, @types.ChoirError] {
  let uncertain = match record_part_event_ingestion_overflow(snapshot, intent) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  persist_provider_dispatch_uncertainty(
    repository,
    repository_adapters,
    snapshot,
    store_version,
    uncertain,
    WorkflowEventIngestionOverflowRecorded,
    dependencies,
  )
}

///|
fn persist_provider_process_loss(
  repository : PartWorkflowRepository,
  repository_adapters : PartWorkflowRepositoryAdapters,
  snapshot : PartWorkflowSnapshot,
  store_version : Int,
  intent : PartEffectIntent,
  dependencies : PartWorkflowDriverDependencies,
) -> Result[PartWorkflowRunResult, @types.ChoirError] {
  let uncertain = match record_part_provider_process_loss(snapshot, intent) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  persist_provider_dispatch_uncertainty(
    repository,
    repository_adapters,
    snapshot,
    store_version,
    uncertain,
    WorkflowProviderProcessLossRecorded,
    dependencies,
  )
}

///|
async fn drive_part_workflow(
  repository : PartWorkflowRepository,
  repository_adapters : PartWorkflowRepositoryAdapters,
  starting_snapshot : PartWorkflowSnapshot,
  starting_store_version : Int,
  dependencies : PartWorkflowDriverDependencies,
) -> Result[PartWorkflowRunResult, @types.ChoirError] {
  let mut snapshot = starting_snapshot
  let mut store_version = starting_store_version
  let mut authorized_in_this_process = false
  while true {
    match snapshot.stage {
      PartIntegrated =>
        return Ok({
          snapshot,
          store_version: Some(store_version),
          outcome: PartRunIntegrated,
        })
      PartCanceled =>
        return Ok({
          snapshot,
          store_version: Some(store_version),
          outcome: PartRunCanceled,
        })
      PartBlocked =>
        return Ok({
          snapshot,
          store_version: Some(store_version),
          outcome: PartRunBlocked,
        })
      PartRecoveryUncertain =>
        return Ok({
          snapshot,
          store_version: Some(store_version),
          outcome: PartRunRecoveryUncertain,
        })
      _ => ()
    }
    match snapshot.pending_effect {
      Some({ lifecycle: PartEffectPlanned, .. }) => {
        let authorizes = match (dependencies.goal_authorizes_new_effects)() {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        let authorization_precondition = match authorizes {
          PartGoalAuthorized(value) => value
          PartGoalNotAuthorized =>
            return Ok({
              snapshot,
              store_version: Some(store_version),
              outcome: PartRunGoalNotAuthorizing,
            })
        }
        let authorized = match authorize_pending_part_effect(snapshot) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        match
          persist_driver_snapshot(
            repository,
            repository_adapters,
            authorized,
            Some(store_version),
            WorkflowEffectAuthorized,
            dependencies,
            authorization_precondition,
          ) {
          Ok(WorkflowSnapshotPersisted(version)) => {
            snapshot = authorized
            store_version = version
            authorized_in_this_process = true
            continue
          }
          Ok(WorkflowSnapshotPersistencePaused(boundary, point)) =>
            return Ok(
              persistence_result(snapshot, Some(store_version), boundary, point),
            )
          Ok(WorkflowSnapshotAuthorizationRejected) =>
            return Ok({
              snapshot,
              store_version: Some(store_version),
              outcome: PartRunGoalNotAuthorizing,
            })
          Err(error) => return Err(error)
        }
      }
      Some({ lifecycle: PartEffectMayHaveOccurred, .. } as intent) => {
        let observation = if authorized_in_this_process {
          match (dependencies.effects.execute)(snapshot, intent) {
            Ok(value) => value
            Err(error) => {
              if error.is_provider_protocol_violation() {
                return persist_provider_protocol_violation(
                  repository, repository_adapters, snapshot, store_version, intent,
                  dependencies,
                )
              }
              if error.is_event_ingestion_overflow() {
                return persist_event_ingestion_overflow(
                  repository, repository_adapters, snapshot, store_version, intent,
                  dependencies,
                )
              }
              if error.is_provider_process_lost() || error.is_timeout() {
                return persist_provider_process_loss(
                  repository, repository_adapters, snapshot, store_version, intent,
                  dependencies,
                )
              }
              return Err(error)
            }
          }
        } else {
          match (dependencies.effects.reconcile)(snapshot, intent) {
            Ok(EffectObservationRecovered(value)) => value
            Ok(ExactEffectRetryAuthorized) =>
              match (dependencies.effects.execute)(snapshot, intent) {
                Ok(value) => value
                Err(error) => {
                  if error.is_provider_protocol_violation() {
                    return persist_provider_protocol_violation(
                      repository, repository_adapters, snapshot, store_version, intent,
                      dependencies,
                    )
                  }
                  if error.is_event_ingestion_overflow() {
                    return persist_event_ingestion_overflow(
                      repository, repository_adapters, snapshot, store_version, intent,
                      dependencies,
                    )
                  }
                  if error.is_provider_process_lost() || error.is_timeout() {
                    return persist_provider_process_loss(
                      repository, repository_adapters, snapshot, store_version, intent,
                      dependencies,
                    )
                  }
                  return Err(error)
                }
              }
            Ok(EffectWitnessUnavailable) =>
              return Ok({
                snapshot,
                store_version: Some(store_version),
                outcome: PartRunWaitingForEffectWitness(intent.effect_id),
              })
            Err(error) => {
              if error.is_provider_protocol_violation() {
                return persist_provider_protocol_violation(
                  repository, repository_adapters, snapshot, store_version, intent,
                  dependencies,
                )
              }
              if error.is_event_ingestion_overflow() {
                return persist_event_ingestion_overflow(
                  repository, repository_adapters, snapshot, store_version, intent,
                  dependencies,
                )
              }
              if error.is_provider_process_lost() || error.is_timeout() {
                return persist_provider_process_loss(
                  repository, repository_adapters, snapshot, store_version, intent,
                  dependencies,
                )
              }
              return Err(error)
            }
          }
        }
        let observed = match
          apply_part_effect_observation(
            snapshot,
            observation,
            (dependencies.now)(),
            dependencies.artifact_exists,
            dependencies.is_nfc,
          ) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        let observed_boundary = if observed.stage == PartAuditResultRecorded {
          WorkflowAuditResultRecorded
        } else {
          WorkflowEffectObserved
        }
        match
          persist_driver_snapshot(
            repository,
            repository_adapters,
            observed,
            Some(store_version),
            observed_boundary,
            dependencies,
            None,
          ) {
          Ok(WorkflowSnapshotPersisted(version)) => {
            snapshot = observed
            store_version = version
            authorized_in_this_process = false
            continue
          }
          Ok(WorkflowSnapshotPersistencePaused(boundary, point)) =>
            return Ok(
              persistence_result(snapshot, Some(store_version), boundary, point),
            )
          Ok(WorkflowSnapshotAuthorizationRejected) =>
            return Err(
              workflow_error("effect observation used an authorization guard"),
            )
          Err(error) => return Err(error)
        }
      }
      Some(_) =>
        return Ok({
          snapshot,
          store_version: Some(store_version),
          outcome: PartRunRecoveryUncertain,
        })
      None => ()
    }
    let (advanced, boundary, authorization_precondition) = match
      snapshot.stage {
      PartAuditResultRecorded => {
        let metadata = match (dependencies.audit_receipt_metadata)(snapshot) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        let next = match
          mint_part_audit_receipt(
            snapshot,
            metadata,
            dependencies.artifact_digest_exists,
          ) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        (next, WorkflowAuditReceiptRecorded, None)
      }
      PartAudited => {
        let authorizes = match (dependencies.goal_authorizes_new_effects)() {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        let authorization_precondition = match authorizes {
          PartGoalAuthorized(value) => value
          PartGoalNotAuthorized =>
            return Ok({
              snapshot,
              store_version: Some(store_version),
              outcome: PartRunGoalNotAuthorizing,
            })
        }
        let admission = match (dependencies.integration_admission)(snapshot) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        let input = match admission {
          PartIntegrationDeferred =>
            return Ok({
              snapshot,
              store_version: Some(store_version),
              outcome: PartRunAwaitingPromotion,
            })
          PartIntegrationAdmitted(value) => value
        }
        let next = match plan_part_integration(snapshot, input) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        (next, WorkflowIntegrationPlanned, authorization_precondition)
      }
      PartPromotionPrepared => {
        let authorizes = match (dependencies.goal_authorizes_new_effects)() {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        let authorization_precondition = match authorizes {
          PartGoalAuthorized(value) => value
          PartGoalNotAuthorized =>
            return Ok({
              snapshot,
              store_version: Some(store_version),
              outcome: PartRunGoalNotAuthorizing,
            })
        }
        let next = match
          authorize_part_integration(
            snapshot,
            (dependencies.verification_environment_digest)(snapshot),
            (dependencies.verification_runtime_digest)(snapshot),
            dependencies.artifact_exists,
            dependencies.artifact_digest_exists,
          ) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        (next, WorkflowIntegrationAuthorized, authorization_precondition)
      }
      _ => {
        let authorizes = match (dependencies.goal_authorizes_new_effects)() {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        let authorization_precondition = match authorizes {
          PartGoalAuthorized(value) => value
          PartGoalNotAuthorized =>
            return Ok({
              snapshot,
              store_version: Some(store_version),
              outcome: PartRunGoalNotAuthorizing,
            })
        }
        let intent = match plan_next_part_effect(snapshot) {
          Ok(Some(value)) => value
          Ok(None) =>
            return Err(
              workflow_error("nonterminal workflow has no next effect"),
            )
          Err(error) => return Err(error)
        }
        let next = match persist_planned_part_effect(snapshot, intent) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        (next, WorkflowEffectPlanned, authorization_precondition)
      }
    }
    match
      persist_driver_snapshot(
        repository,
        repository_adapters,
        advanced,
        Some(store_version),
        boundary,
        dependencies,
        authorization_precondition,
      ) {
      Ok(WorkflowSnapshotPersisted(version)) => {
        snapshot = advanced
        store_version = version
      }
      Ok(WorkflowSnapshotPersistencePaused(actual_boundary, point)) =>
        return Ok(
          persistence_result(
            snapshot,
            Some(store_version),
            actual_boundary,
            point,
          ),
        )
      Ok(WorkflowSnapshotAuthorizationRejected) =>
        return Ok({
          snapshot,
          store_version: Some(store_version),
          outcome: PartRunGoalNotAuthorizing,
        })
      Err(error) => return Err(error)
    }
  } nobreak {
    Err(workflow_error("workflow driver stopped unexpectedly"))
  }
}

///|
pub async fn run_new_part_workflow(
  repository : PartWorkflowRepository,
  repository_adapters : PartWorkflowRepositoryAdapters,
  snapshot : PartWorkflowSnapshot,
  dependencies : PartWorkflowDriverDependencies,
) -> Result[PartWorkflowRunResult, @types.ChoirError] {
  match initialize_part_workflow_repository(repository, repository_adapters) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match
    persist_driver_snapshot(
      repository,
      repository_adapters,
      snapshot,
      None,
      WorkflowAcceptedSnapshot,
      dependencies,
      None,
    ) {
    Ok(WorkflowSnapshotPersisted(version)) =>
      drive_part_workflow(
        repository, repository_adapters, snapshot, version, dependencies,
      )
    Ok(WorkflowSnapshotPersistencePaused(boundary, point)) =>
      Ok(persistence_result(snapshot, None, boundary, point))
    Ok(WorkflowSnapshotAuthorizationRejected) =>
      Err(workflow_error("accepted snapshot used an authorization guard"))
    Err(error) => Err(error)
  }
}

///|
pub async fn resume_part_workflow(
  repository : PartWorkflowRepository,
  repository_adapters : PartWorkflowRepositoryAdapters,
  workflow_id : String,
  dependencies : PartWorkflowDriverDependencies,
) -> Result[PartWorkflowRunResult, @types.ChoirError] {
  match initialize_part_workflow_repository(repository, repository_adapters) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match load_part_snapshot(repository, repository_adapters, workflow_id) {
    Ok(Some(stored)) =>
      drive_part_workflow(
        repository,
        repository_adapters,
        stored.snapshot,
        stored.state_record.version,
        dependencies,
      )
    Ok(None) => Err(workflow_error("workflow snapshot does not exist"))
    Err(error) => Err(error)
  }
}
