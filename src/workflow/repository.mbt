///|
pub(all) struct PartWorkflowRepository {
  state_store : @storage.SqliteStateStore
  artifact_store : @storage.ArtifactStore
  max_snapshot_bytes : Int
}

///|
pub(all) struct PartWorkflowRepositoryAdapters {
  state : @storage.StateStoreAdapters
  artifacts : @storage.ArtifactStoreAdapters
}

///|
pub(all) struct PartSnapshotPersistenceRequest {
  snapshot : PartWorkflowSnapshot
  expected_store_version : Int?
  fault_point : @storage.StateStoreFaultPoint?
}

///|
pub(all) struct PartSnapshotPersistenceReceipt {
  store_version : Int
  snapshot_digest : @control.Digest
  transaction_outcome : @storage.StateTransactionOutcome
} derive(Debug, Eq)

///|
pub(all) enum GuardedPartSnapshotPersistenceResult {
  GuardedPartSnapshotPersisted(PartSnapshotPersistenceReceipt)
  GuardedPartSnapshotPreconditionConflict
} derive(Debug, Eq)

///|
pub(all) struct PartStoredSnapshot {
  state_record : @storage.StateRecord
  snapshot : PartWorkflowSnapshot
} derive(Debug, Eq)

///|
fn workflow_state_key(workflow_id : String) -> @storage.StateRecordKey {
  @storage.StateRecordKey("workflow:" + workflow_id)
}

///|
fn effect_witness_state_key(effect_id : String) -> @storage.StateRecordKey {
  @storage.StateRecordKey("effect-witness:" + effect_id)
}

///|
fn effect_witness_event_key(effect_id : String) -> @storage.SemanticEventKey {
  @storage.SemanticEventKey("effect-witness:" + effect_id)
}

///|
fn workflow_snapshot_event_key(
  snapshot : PartWorkflowSnapshot,
) -> @storage.SemanticEventKey {
  @storage.SemanticEventKey(
    "workflow:" +
    snapshot.workflow_id +
    ":snapshot:" +
    snapshot.durable_version.to_string(),
  )
}

///|
fn validate_workflow_repository(
  repository : PartWorkflowRepository,
) -> Result[Unit, @types.ChoirError] {
  if repository.max_snapshot_bytes <= 0 {
    Err(workflow_error("snapshot repository requires a positive read limit"))
  } else {
    Ok(())
  }
}

///|
pub fn initialize_part_workflow_repository(
  repository : PartWorkflowRepository,
  adapters : PartWorkflowRepositoryAdapters,
) -> Result[Unit, @types.ChoirError] {
  match validate_workflow_repository(repository) {
    Ok(_) => (adapters.state.initialize)(repository.state_store)
    Err(error) => Err(error)
  }
}

///|
fn persist_part_snapshot_internal(
  repository : PartWorkflowRepository,
  adapters : PartWorkflowRepositoryAdapters,
  request : PartSnapshotPersistenceRequest,
  precondition : @storage.StateRecordPrecondition?,
) -> Result[GuardedPartSnapshotPersistenceResult, @types.ChoirError] {
  match validate_workflow_repository(repository) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let snapshot_bytes = part_snapshot_bytes(request.snapshot)
  if snapshot_bytes.length() > repository.max_snapshot_bytes {
    return Err(workflow_error("snapshot exceeds the repository read limit"))
  }
  let snapshot_digest = @storage.artifact_digest(snapshot_bytes)
  let adoption_request : @storage.ArtifactAdoptionRequest = {
    content: snapshot_bytes,
    expected_digest: snapshot_digest,
    provenance: @storage.ArtifactProvenance::ArtifactWorkflowSnapshot(
      request.snapshot.goal.id,
    ),
    retention: @storage.ArtifactRetention::ArtifactPermanent,
  }
  let adoption = match
    (adapters.artifacts.adopt)(repository.artifact_store, adoption_request) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if adoption.digest != snapshot_digest ||
    adoption.byte_length != snapshot_bytes.length() {
    return Err(workflow_error("artifact adapter returned a false receipt"))
  }
  let store_version = match request.expected_store_version {
    None => 1
    Some(version) => version + 1
  }
  let transaction : @storage.StateTransactionRequest = {
    state: {
      key: workflow_state_key(request.snapshot.workflow_id),
      expected_version: request.expected_store_version,
      next_version: store_version,
      fencing_epoch: request.snapshot.fencing_epoch,
      value_digest: snapshot_digest,
    },
    outbox: {
      semantic_key: workflow_snapshot_event_key(request.snapshot),
      payload_digest: snapshot_digest,
    },
    fault_point: request.fault_point,
  }
  let guarded_outcome = match precondition {
    None =>
      match (adapters.state.commit)(repository.state_store, transaction) {
        Ok(value) =>
          @storage.GuardedStateTransactionOutcome::GuardedStateTransactionCompleted(
            value,
          )
        Err(error) => return Err(error)
      }
    Some(value) =>
      match
        (adapters.state.commit_guarded)(repository.state_store, {
          transaction,
          precondition: value,
        }) {
        Ok(result) => result
        Err(error) => return Err(error)
      }
  }
  match guarded_outcome {
    @storage.GuardedStateTransactionOutcome::GuardedStateTransactionCompleted(
      outcome
    ) =>
      Ok(
        GuardedPartSnapshotPersisted({
          store_version,
          snapshot_digest,
          transaction_outcome: outcome,
        }),
      )
    @storage.GuardedStateTransactionOutcome::GuardedStateTransactionPreconditionConflict =>
      Ok(GuardedPartSnapshotPreconditionConflict)
  }
}

///|
pub fn persist_part_snapshot(
  repository : PartWorkflowRepository,
  adapters : PartWorkflowRepositoryAdapters,
  request : PartSnapshotPersistenceRequest,
) -> Result[PartSnapshotPersistenceReceipt, @types.ChoirError] {
  match persist_part_snapshot_internal(repository, adapters, request, None) {
    Ok(GuardedPartSnapshotPersisted(receipt)) => Ok(receipt)
    Ok(GuardedPartSnapshotPreconditionConflict) =>
      Err(workflow_error("unguarded snapshot persistence was rejected"))
    Err(error) => Err(error)
  }
}

///|
pub fn persist_part_snapshot_guarded(
  repository : PartWorkflowRepository,
  adapters : PartWorkflowRepositoryAdapters,
  request : PartSnapshotPersistenceRequest,
  precondition : @storage.StateRecordPrecondition,
) -> Result[GuardedPartSnapshotPersistenceResult, @types.ChoirError] {
  persist_part_snapshot_internal(
    repository,
    adapters,
    request,
    Some(precondition),
  )
}

///|
pub fn load_part_snapshot(
  repository : PartWorkflowRepository,
  adapters : PartWorkflowRepositoryAdapters,
  workflow_id : String,
) -> Result[PartStoredSnapshot?, @types.ChoirError] {
  match validate_workflow_repository(repository) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let state_record = match
    (adapters.state.read_state)(
      repository.state_store,
      workflow_state_key(workflow_id),
    ) {
    Ok(Some(value)) => value
    Ok(None) => return Ok(None)
    Err(error) => return Err(error)
  }
  let read_request : @storage.ArtifactReadRequest = {
    digest: state_record.value_digest,
    max_bytes: repository.max_snapshot_bytes,
  }
  let content = match
    (adapters.artifacts.read)(repository.artifact_store, read_request) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if @storage.artifact_digest(content) != state_record.value_digest {
    return Err(workflow_error("snapshot content disagrees with durable state"))
  }
  let snapshot = match decode_part_snapshot(content) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if snapshot.workflow_id != workflow_id ||
    snapshot.fencing_epoch != state_record.fencing_epoch {
    return Err(workflow_error("snapshot identity or fence is inconsistent"))
  }
  Ok(Some({ state_record, snapshot }))
}

///|
pub fn persist_part_goal_cancellation(
  repository : PartWorkflowRepository,
  adapters : PartWorkflowRepositoryAdapters,
  stored : PartStoredSnapshot,
) -> Result[PartStoredSnapshot, @types.ChoirError] {
  let next = match record_part_goal_cancellation(stored.snapshot) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if next == stored.snapshot {
    return Ok(stored)
  }
  let receipt = match
    persist_part_snapshot(repository, adapters, {
      snapshot: next,
      expected_store_version: Some(stored.state_record.version),
      fault_point: None,
    }) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match receipt.transaction_outcome {
    @storage.StateTransactionOutcome::StateTransactionCommitted
    | @storage.StateTransactionOutcome::StateTransactionReplayed
    | @storage.StateTransactionOutcome::StateTransactionCommittedAckLost => ()
    @storage.StateTransactionOutcome::StateTransactionVersionConflict =>
      match load_part_snapshot(repository, adapters, next.workflow_id) {
        Ok(Some(current)) =>
          if part_cancellation_disposition_is_known(current.snapshot) {
            return Ok(current)
          } else {
            return Err(
              workflow_error("Part changed while cancellation was recorded"),
            )
          }
        Ok(_) =>
          return Err(
            workflow_error("Part changed while cancellation was recorded"),
          )
        Err(error) => return Err(error)
      }
    @storage.StateTransactionOutcome::StateTransactionStaleFence =>
      return Err(workflow_error("Part cancellation fencing conflict"))
    @storage.StateTransactionOutcome::StateTransactionSemanticConflict =>
      return Err(workflow_error("Part cancellation semantic conflict"))
    @storage.StateTransactionOutcome::StateTransactionFaultRolledBack(_) =>
      return Err(workflow_error("Part cancellation persistence fault"))
  }
  match load_part_snapshot(repository, adapters, next.workflow_id) {
    Ok(Some(current)) if current.snapshot == next => Ok(current)
    Ok(_) => Err(workflow_error("Part cancellation did not reload"))
    Err(error) => Err(error)
  }
}

///|
pub fn persist_recovered_part_effect_observation(
  repository : PartWorkflowRepository,
  adapters : PartWorkflowRepositoryAdapters,
  stored : PartStoredSnapshot,
  intent : PartEffectIntent,
  observation : PartEffectObservation,
  observed_at : Int64,
  artifact_exists : (@control.ArtifactReference) -> Bool,
  is_nfc : (String) -> Bool,
) -> Result[PartStoredSnapshot, @types.ChoirError] {
  let next = match
    apply_or_reconcile_part_effect_observation(
      stored.snapshot,
      intent,
      observation,
      observed_at,
      artifact_exists,
      is_nfc,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let receipt = match
    persist_part_snapshot(repository, adapters, {
      snapshot: next,
      expected_store_version: Some(stored.state_record.version),
      fault_point: None,
    }) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match receipt.transaction_outcome {
    @storage.StateTransactionOutcome::StateTransactionCommitted
    | @storage.StateTransactionOutcome::StateTransactionReplayed
    | @storage.StateTransactionOutcome::StateTransactionCommittedAckLost =>
      match load_part_snapshot(repository, adapters, next.workflow_id) {
        Ok(Some(current)) if current.snapshot == next => Ok(current)
        Ok(_) =>
          Err(workflow_error("recovered effect observation did not reload"))
        Err(error) => Err(error)
      }
    @storage.StateTransactionOutcome::StateTransactionVersionConflict =>
      match load_part_snapshot(repository, adapters, next.workflow_id) {
        Ok(Some(current)) if current.snapshot == next => Ok(current)
        Ok(_) =>
          Err(
            workflow_error(
              "Part changed while its effect observation was recovered",
            ),
          )
        Err(error) => Err(error)
      }
    @storage.StateTransactionOutcome::StateTransactionStaleFence =>
      Err(workflow_error("recovered effect observation fencing conflict"))
    @storage.StateTransactionOutcome::StateTransactionSemanticConflict =>
      Err(workflow_error("recovered effect observation semantic conflict"))
    @storage.StateTransactionOutcome::StateTransactionFaultRolledBack(_) =>
      Err(workflow_error("recovered effect observation persistence fault"))
  }
}

///|
pub fn load_part_effect_witness(
  repository : PartWorkflowRepository,
  adapters : PartWorkflowRepositoryAdapters,
  intent : PartEffectIntent,
) -> Result[PartEffectWitness?, @types.ChoirError] {
  let state = match
    (adapters.state.read_state)(
      repository.state_store,
      effect_witness_state_key(intent.effect_id),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let record = match state {
    Some(value) => value
    None => return Ok(None)
  }
  let content = match
    (adapters.artifacts.read)(repository.artifact_store, {
      digest: record.value_digest,
      max_bytes: repository.max_snapshot_bytes,
    }) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let witness = match decode_part_effect_witness(content) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if witness.effect_id != intent.effect_id ||
    witness.request_digest != intent.request_digest ||
    record.fencing_epoch.0 <= 0L {
    Err(workflow_error("effect witness does not match its durable intent"))
  } else {
    Ok(Some(witness))
  }
}

///|
pub fn record_part_effect_witness(
  repository : PartWorkflowRepository,
  adapters : PartWorkflowRepositoryAdapters,
  snapshot : PartWorkflowSnapshot,
  intent : PartEffectIntent,
  observation : PartEffectObservation,
  observed_at : Int64,
) -> Result[PartEffectWitness, @types.ChoirError] {
  if snapshot.pending_effect != Some(intent) ||
    intent.lifecycle != PartEffectMayHaveOccurred ||
    observed_at <= 0L {
    return Err(workflow_error("effect witness has no authorized intent"))
  }
  let witness : PartEffectWitness = {
    effect_id: intent.effect_id,
    request_digest: intent.request_digest,
    observation,
    observation_digest: part_effect_observation_digest(observation),
    observed_at,
  }
  let witness_conflict = fn(detail : String) {
    match intent.kind {
      DispatchImplementation(_, _)
      | DispatchVerification(_, _)
      | DispatchAudit(_, _, _) =>
        @types.ChoirError::provider_protocol_violation(detail)
      _ => workflow_error(detail)
    }
  }
  let content = part_effect_witness_bytes(witness)
  let digest = @storage.artifact_digest(content)
  let adopted = match
    (adapters.artifacts.adopt)(repository.artifact_store, {
      content,
      expected_digest: digest,
      provenance: @storage.ArtifactProvenance::ArtifactEffectWitness(
        snapshot.goal.id,
      ),
      retention: @storage.ArtifactRetention::ArtifactUntilGoalTerminal(
        snapshot.goal.id,
      ),
    }) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if adopted.digest != digest || adopted.byte_length != content.length() {
    return Err(workflow_error("effect witness artifact receipt is false"))
  }
  match load_part_effect_witness(repository, adapters, intent) {
    Ok(Some(existing)) =>
      return if existing == witness {
        Ok(existing)
      } else {
        Err(
          witness_conflict(
            "Part effect witness identity was reused with different semantics",
          ),
        )
      }
    Ok(None) => ()
    Err(error) => return Err(error)
  }
  let outcome = match
    (adapters.state.commit)(repository.state_store, {
      state: {
        key: effect_witness_state_key(intent.effect_id),
        expected_version: None,
        next_version: 1,
        fencing_epoch: snapshot.fencing_epoch,
        value_digest: digest,
      },
      outbox: {
        semantic_key: effect_witness_event_key(intent.effect_id),
        payload_digest: digest,
      },
      fault_point: None,
    }) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match outcome {
    @storage.StateTransactionOutcome::StateTransactionCommitted
    | @storage.StateTransactionOutcome::StateTransactionReplayed
    | @storage.StateTransactionOutcome::StateTransactionCommittedAckLost
    | @storage.StateTransactionOutcome::StateTransactionVersionConflict =>
      match load_part_effect_witness(repository, adapters, intent) {
        Ok(Some(stored)) if stored == witness => Ok(stored)
        Ok(Some(_)) =>
          Err(
            witness_conflict(
              "Part effect witness commit resolved to different semantics",
            ),
          )
        Ok(None) =>
          Err(workflow_error("effect witness commit was not recovered"))
        Err(error) => Err(error)
      }
    @storage.StateTransactionOutcome::StateTransactionStaleFence =>
      Err(workflow_error("effect witness fencing conflict"))
    @storage.StateTransactionOutcome::StateTransactionSemanticConflict =>
      Err(witness_conflict("Part effect witness semantic key was reused"))
    @storage.StateTransactionOutcome::StateTransactionFaultRolledBack(_) =>
      Err(workflow_error("effect witness transaction rolled back"))
  }
}
