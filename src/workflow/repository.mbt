///|
pub(all) struct OnePartWorkflowRepository {
  state_store : @storage.SqliteStateStore
  artifact_store : @storage.ArtifactStore
  max_snapshot_bytes : Int
}

///|
pub(all) struct OnePartWorkflowRepositoryAdapters {
  state : @storage.StateStoreAdapters
  artifacts : @storage.ArtifactStoreAdapters
}

///|
pub(all) struct OnePartSnapshotPersistenceRequest {
  snapshot : OnePartWorkflowSnapshot
  expected_store_version : Int?
  fault_point : @storage.StateStoreFaultPoint?
}

///|
pub(all) struct OnePartSnapshotPersistenceReceipt {
  store_version : Int
  snapshot_digest : @control.Digest
  transaction_outcome : @storage.StateTransactionOutcome
} derive(Debug, Eq)

///|
pub(all) struct OnePartStoredSnapshot {
  state_record : @storage.StateRecord
  snapshot : OnePartWorkflowSnapshot
} derive(Debug, Eq)

///|
fn workflow_state_key(workflow_id : String) -> @storage.StateRecordKey {
  @storage.StateRecordKey("workflow:" + workflow_id)
}

///|
fn workflow_snapshot_event_key(
  snapshot : OnePartWorkflowSnapshot,
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
  repository : OnePartWorkflowRepository,
) -> Result[Unit, @types.ChoirError] {
  if repository.max_snapshot_bytes <= 0 {
    Err(workflow_error("snapshot repository requires a positive read limit"))
  } else {
    Ok(())
  }
}

///|
pub fn initialize_one_part_workflow_repository(
  repository : OnePartWorkflowRepository,
  adapters : OnePartWorkflowRepositoryAdapters,
) -> Result[Unit, @types.ChoirError] {
  match validate_workflow_repository(repository) {
    Ok(_) => (adapters.state.initialize)(repository.state_store)
    Err(error) => Err(error)
  }
}

///|
pub fn persist_one_part_snapshot(
  repository : OnePartWorkflowRepository,
  adapters : OnePartWorkflowRepositoryAdapters,
  request : OnePartSnapshotPersistenceRequest,
) -> Result[OnePartSnapshotPersistenceReceipt, @types.ChoirError] {
  match validate_workflow_repository(repository) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let snapshot_bytes = one_part_snapshot_bytes(request.snapshot)
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
  let outcome = match
    (adapters.state.commit)(repository.state_store, transaction) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({ store_version, snapshot_digest, transaction_outcome: outcome })
}

///|
pub fn load_one_part_snapshot(
  repository : OnePartWorkflowRepository,
  adapters : OnePartWorkflowRepositoryAdapters,
  workflow_id : String,
) -> Result[OnePartStoredSnapshot?, @types.ChoirError] {
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
  let snapshot = match decode_one_part_snapshot(content) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if snapshot.workflow_id != workflow_id ||
    snapshot.fencing_epoch != state_record.fencing_epoch {
    return Err(workflow_error("snapshot identity or fence is inconsistent"))
  }
  Ok(Some({ state_record, snapshot }))
}
