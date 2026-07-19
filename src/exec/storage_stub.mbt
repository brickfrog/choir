///|
pub fn initialize_state_store(
  _store : @storage.SqliteStateStore,
) -> Result[Unit, @types.ChoirError] {
  Err(@types.ChoirError::workspace_error("SQLite state store is native-only"))
}

///|
pub fn commit_state_transaction(
  _store : @storage.SqliteStateStore,
  _request : @storage.StateTransactionRequest,
) -> Result[@storage.StateTransactionOutcome, @types.ChoirError] {
  Err(@types.ChoirError::workspace_error("SQLite state store is native-only"))
}

///|
pub fn read_state_record(
  _store : @storage.SqliteStateStore,
  _key : @storage.StateRecordKey,
) -> Result[@storage.StateRecord?, @types.ChoirError] {
  Err(@types.ChoirError::workspace_error("SQLite state store is native-only"))
}

///|
pub fn read_completion_outbox(
  _store : @storage.SqliteStateStore,
  _key : @storage.SemanticEventKey,
) -> Result[@storage.CompletionOutboxRecord?, @types.ChoirError] {
  Err(@types.ChoirError::workspace_error("SQLite state store is native-only"))
}

///|
pub fn sqlite_state_store_adapters() -> @storage.StateStoreAdapters {
  {
    initialize: initialize_state_store,
    commit: commit_state_transaction,
    read_state: read_state_record,
    read_outbox: read_completion_outbox,
  }
}

///|
pub fn adopt_artifact(
  _store : @storage.ArtifactStore,
  _request : @storage.ArtifactAdoptionRequest,
) -> Result[@storage.ArtifactReceipt, @types.ChoirError] {
  Err(@types.ChoirError::workspace_error("artifact store is native-only"))
}

///|
pub fn artifact_store_contains(
  _store : @storage.ArtifactStore,
  _digest : @control.Digest,
) -> Result[Bool, @types.ChoirError] {
  Err(@types.ChoirError::workspace_error("artifact store is native-only"))
}

///|
pub fn read_artifact(
  _store : @storage.ArtifactStore,
  _request : @storage.ArtifactReadRequest,
) -> Result[Bytes, @types.ChoirError] {
  Err(@types.ChoirError::workspace_error("artifact store is native-only"))
}

///|
pub fn local_artifact_store_adapters() -> @storage.ArtifactStoreAdapters {
  {
    adopt: adopt_artifact,
    contains: artifact_store_contains,
    read: read_artifact,
  }
}
