///|
pub(all) enum OnePartPersistenceBoundary {
  WorkflowAcceptedSnapshot
  WorkflowEffectPlanned
  WorkflowEffectAuthorized
  WorkflowEffectObserved
  WorkflowAuditReceiptRecorded
  WorkflowIntegrationPlanned
  WorkflowIntegrationAuthorized
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum OnePartEffectRecovery {
  EffectObservationRecovered(OnePartEffectObservation)
  ExactEffectRetryAuthorized
  EffectWitnessUnavailable
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct OnePartWorkflowDriverAdapters {
  execute : async (OnePartWorkflowSnapshot, OnePartEffectIntent) -> Result[
    OnePartEffectObservation,
    @types.ChoirError,
  ]
  reconcile : async (OnePartWorkflowSnapshot, OnePartEffectIntent) -> Result[
    OnePartEffectRecovery,
    @types.ChoirError,
  ]
}

///|
pub(all) struct OnePartWorkflowDriverDependencies {
  now : () -> Int64
  persistence_fault : (OnePartPersistenceBoundary) -> @storage.StateStoreFaultPoint?
  effects : OnePartWorkflowDriverAdapters
  artifact_exists : (@control.ArtifactReference) -> Bool
  artifact_digest_exists : (@control.Digest) -> Bool
  is_nfc : (String) -> Bool
  audit_receipt_metadata : (OnePartWorkflowSnapshot) -> Result[
    AuditReceiptMetadata,
    @types.ChoirError,
  ]
  integration_plan : (OnePartWorkflowSnapshot) -> Result[
    IntegrationPlanInput,
    @types.ChoirError,
  ]
  verification_environment_digest : (OnePartWorkflowSnapshot) -> @control.Digest
  verification_runtime_digest : (OnePartWorkflowSnapshot) -> @control.Digest
}

///|
pub(all) enum OnePartWorkflowRunOutcome {
  OnePartRunIntegrated
  OnePartRunBlocked
  OnePartRunRecoveryUncertain
  OnePartRunWaitingForEffectWitness(String)
  OnePartRunPersistenceFault(
    OnePartPersistenceBoundary,
    @storage.StateStoreFaultPoint
  )
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct OnePartWorkflowRunResult {
  snapshot : OnePartWorkflowSnapshot
  store_version : Int?
  outcome : OnePartWorkflowRunOutcome
} derive(Debug, Eq)

///|
priv enum OnePartPersistenceDecision {
  WorkflowSnapshotPersisted(Int)
  WorkflowSnapshotPersistencePaused(
    OnePartPersistenceBoundary,
    @storage.StateStoreFaultPoint
  )
}

///|
fn load_exact_persisted_snapshot(
  repository : OnePartWorkflowRepository,
  repository_adapters : OnePartWorkflowRepositoryAdapters,
  snapshot : OnePartWorkflowSnapshot,
  expected_store_version : Int,
) -> Result[Unit, @types.ChoirError] {
  match
    load_one_part_snapshot(
      repository,
      repository_adapters,
      snapshot.workflow_id,
    ) {
    Ok(Some(stored)) =>
      if stored.state_record.version == expected_store_version &&
        stored.state_record.value_digest == one_part_snapshot_digest(snapshot) &&
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
  repository : OnePartWorkflowRepository,
  repository_adapters : OnePartWorkflowRepositoryAdapters,
  snapshot : OnePartWorkflowSnapshot,
  expected_store_version : Int?,
  boundary : OnePartPersistenceBoundary,
  dependencies : OnePartWorkflowDriverDependencies,
) -> Result[OnePartPersistenceDecision, @types.ChoirError] {
  let receipt = match
    persist_one_part_snapshot(repository, repository_adapters, {
      snapshot,
      expected_store_version,
      fault_point: (dependencies.persistence_fault)(boundary),
    }) {
    Ok(value) => value
    Err(error) => return Err(error)
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
  snapshot : OnePartWorkflowSnapshot,
  store_version : Int?,
  boundary : OnePartPersistenceBoundary,
  point : @storage.StateStoreFaultPoint,
) -> OnePartWorkflowRunResult {
  {
    snapshot,
    store_version,
    outcome: OnePartRunPersistenceFault(boundary, point),
  }
}

///|
async fn drive_one_part_workflow(
  repository : OnePartWorkflowRepository,
  repository_adapters : OnePartWorkflowRepositoryAdapters,
  starting_snapshot : OnePartWorkflowSnapshot,
  starting_store_version : Int,
  dependencies : OnePartWorkflowDriverDependencies,
) -> Result[OnePartWorkflowRunResult, @types.ChoirError] {
  let mut snapshot = starting_snapshot
  let mut store_version = starting_store_version
  let mut authorized_in_this_process = false
  while true {
    match snapshot.stage {
      OnePartIntegrated =>
        return Ok({
          snapshot,
          store_version: Some(store_version),
          outcome: OnePartRunIntegrated,
        })
      OnePartBlocked =>
        return Ok({
          snapshot,
          store_version: Some(store_version),
          outcome: OnePartRunBlocked,
        })
      OnePartRecoveryUncertain =>
        return Ok({
          snapshot,
          store_version: Some(store_version),
          outcome: OnePartRunRecoveryUncertain,
        })
      _ => ()
    }
    match snapshot.pending_effect {
      Some({ lifecycle: OnePartEffectPlanned, .. }) => {
        let authorized = match authorize_pending_one_part_effect(snapshot) {
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
          Err(error) => return Err(error)
        }
      }
      Some({ lifecycle: OnePartEffectMayHaveOccurred, .. } as intent) => {
        let observation = if authorized_in_this_process {
          match (dependencies.effects.execute)(snapshot, intent) {
            Ok(value) => value
            Err(error) => return Err(error)
          }
        } else {
          match (dependencies.effects.reconcile)(snapshot, intent) {
            Ok(EffectObservationRecovered(value)) => value
            Ok(ExactEffectRetryAuthorized) =>
              match (dependencies.effects.execute)(snapshot, intent) {
                Ok(value) => value
                Err(error) => return Err(error)
              }
            Ok(EffectWitnessUnavailable) =>
              return Ok({
                snapshot,
                store_version: Some(store_version),
                outcome: OnePartRunWaitingForEffectWitness(intent.effect_id),
              })
            Err(error) => return Err(error)
          }
        }
        let observed = match
          apply_one_part_effect_observation(
            snapshot,
            observation,
            (dependencies.now)(),
            dependencies.artifact_exists,
            dependencies.is_nfc,
          ) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        match
          persist_driver_snapshot(
            repository,
            repository_adapters,
            observed,
            Some(store_version),
            WorkflowEffectObserved,
            dependencies,
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
          Err(error) => return Err(error)
        }
      }
      Some(_) =>
        return Ok({
          snapshot,
          store_version: Some(store_version),
          outcome: OnePartRunRecoveryUncertain,
        })
      None => ()
    }
    let (advanced, boundary) = match snapshot.stage {
      OnePartAuditResultRecorded => {
        let metadata = match (dependencies.audit_receipt_metadata)(snapshot) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        let next = match
          mint_one_part_audit_receipt(
            snapshot,
            metadata,
            dependencies.artifact_digest_exists,
          ) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        (next, WorkflowAuditReceiptRecorded)
      }
      OnePartAudited => {
        let input = match (dependencies.integration_plan)(snapshot) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        let next = match plan_one_part_integration(snapshot, input) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        (next, WorkflowIntegrationPlanned)
      }
      OnePartPromotionPrepared => {
        let next = match
          authorize_one_part_integration(
            snapshot,
            (dependencies.verification_environment_digest)(snapshot),
            (dependencies.verification_runtime_digest)(snapshot),
            dependencies.artifact_exists,
            dependencies.artifact_digest_exists,
          ) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        (next, WorkflowIntegrationAuthorized)
      }
      _ => {
        let intent = match plan_next_one_part_effect(snapshot) {
          Ok(Some(value)) => value
          Ok(None) =>
            return Err(
              workflow_error("nonterminal workflow has no next effect"),
            )
          Err(error) => return Err(error)
        }
        let next = match persist_planned_one_part_effect(snapshot, intent) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        (next, WorkflowEffectPlanned)
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
      Err(error) => return Err(error)
    }
  } nobreak {
    Err(workflow_error("workflow driver stopped unexpectedly"))
  }
}

///|
pub async fn run_new_one_part_workflow(
  repository : OnePartWorkflowRepository,
  repository_adapters : OnePartWorkflowRepositoryAdapters,
  snapshot : OnePartWorkflowSnapshot,
  dependencies : OnePartWorkflowDriverDependencies,
) -> Result[OnePartWorkflowRunResult, @types.ChoirError] {
  match
    initialize_one_part_workflow_repository(repository, repository_adapters) {
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
    ) {
    Ok(WorkflowSnapshotPersisted(version)) =>
      drive_one_part_workflow(
        repository, repository_adapters, snapshot, version, dependencies,
      )
    Ok(WorkflowSnapshotPersistencePaused(boundary, point)) =>
      Ok(persistence_result(snapshot, None, boundary, point))
    Err(error) => Err(error)
  }
}

///|
pub async fn resume_one_part_workflow(
  repository : OnePartWorkflowRepository,
  repository_adapters : OnePartWorkflowRepositoryAdapters,
  workflow_id : String,
  dependencies : OnePartWorkflowDriverDependencies,
) -> Result[OnePartWorkflowRunResult, @types.ChoirError] {
  match
    initialize_one_part_workflow_repository(repository, repository_adapters) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match load_one_part_snapshot(repository, repository_adapters, workflow_id) {
    Ok(Some(stored)) =>
      drive_one_part_workflow(
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
