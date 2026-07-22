///|
fn validate_store_path(path : String) -> Result[Unit, @types.ChoirError] {
  if !path.has_prefix("/") || path.contains("\u{00}") {
    Err(
      @types.ChoirError::validation_error(
        "storage adapter requires an absolute daemon-controlled path",
      ),
    )
  } else {
    Ok(())
  }
}

///|
fn state_store_failure(operation : String) -> @types.ChoirError {
  @types.ChoirError::workspace_error(
    "SQLite state store " + operation + " failed",
  )
}

///|
pub fn initialize_state_store(
  store : @storage.SqliteStateStore,
) -> Result[Unit, @types.ChoirError] {
  match validate_store_path(store.path) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let (path, path_len) = exec_string_to_null_terminated_bytes(store.path)
  if state_store_init_ffi(path, path_len) == 0 {
    Ok(())
  } else {
    Err(state_store_failure("initialization"))
  }
}

///|
fn state_fault_code(point : @storage.StateStoreFaultPoint?) -> Int {
  match point {
    None => 0
    Some(@storage.StateStoreFaultPoint::StateAfterMutationBeforeOutbox) => 1
    Some(@storage.StateStoreFaultPoint::StateAfterOutboxBeforeCommit) => 2
    Some(@storage.StateStoreFaultPoint::StateAfterCommitBeforeAck) => 3
  }
}

///|
pub fn commit_state_transaction(
  store : @storage.SqliteStateStore,
  request : @storage.StateTransactionRequest,
) -> Result[@storage.StateTransactionOutcome, @types.ChoirError] {
  match validate_store_path(store.path) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match @storage.validate_state_transaction(request) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let (path, path_len) = exec_string_to_null_terminated_bytes(store.path)
  let key_text = @storage.state_record_key_text(request.state.key)
  let (key, key_len) = exec_string_to_null_terminated_bytes(key_text)
  let value_text = @storage.digest_text(request.state.value_digest)
  let (value, value_len) = exec_string_to_null_terminated_bytes(value_text)
  let semantic_text = @storage.semantic_event_key_text(
    request.outbox.semantic_key,
  )
  let (semantic, semantic_len) = exec_string_to_null_terminated_bytes(
    semantic_text,
  )
  let payload_text = @storage.digest_text(request.outbox.payload_digest)
  let (payload, payload_len) = exec_string_to_null_terminated_bytes(
    payload_text,
  )
  let (has_expected, expected) = match request.state.expected_version {
    None => (0, 0)
    Some(version) => (1, version)
  }
  let (empty, empty_len) = exec_string_to_null_terminated_bytes("")
  let result = state_store_commit_ffi(
    path,
    path_len,
    key,
    key_len,
    has_expected,
    expected,
    request.state.next_version,
    @storage.fencing_epoch_value(request.state.fencing_epoch),
    value,
    value_len,
    semantic,
    semantic_len,
    payload,
    payload_len,
    state_fault_code(request.fault_point),
    0,
    empty,
    empty_len,
    0,
    0L,
    empty,
    empty_len,
  )
  match result {
    0 => Ok(@storage.StateTransactionOutcome::StateTransactionCommitted)
    1 => Ok(@storage.StateTransactionOutcome::StateTransactionReplayed)
    2 => Ok(@storage.StateTransactionOutcome::StateTransactionVersionConflict)
    3 => Ok(@storage.StateTransactionOutcome::StateTransactionStaleFence)
    4 => Ok(@storage.StateTransactionOutcome::StateTransactionSemanticConflict)
    5 =>
      match request.fault_point {
        Some(point) =>
          Ok(
            @storage.StateTransactionOutcome::StateTransactionFaultRolledBack(
              point,
            ),
          )
        None => Err(state_store_failure("fault classification"))
      }
    7 => Ok(@storage.StateTransactionOutcome::StateTransactionCommittedAckLost)
    _ => Err(state_store_failure("transaction"))
  }
}

///|
pub fn commit_guarded_state_transaction(
  store : @storage.SqliteStateStore,
  request : @storage.GuardedStateTransactionRequest,
) -> Result[@storage.GuardedStateTransactionOutcome, @types.ChoirError] {
  match validate_store_path(store.path) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match @storage.validate_guarded_state_transaction(request) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let transaction = request.transaction
  let precondition = request.precondition.record
  let (path, path_len) = exec_string_to_null_terminated_bytes(store.path)
  let key_text = @storage.state_record_key_text(transaction.state.key)
  let (key, key_len) = exec_string_to_null_terminated_bytes(key_text)
  let value_text = @storage.digest_text(transaction.state.value_digest)
  let (value, value_len) = exec_string_to_null_terminated_bytes(value_text)
  let semantic_text = @storage.semantic_event_key_text(
    transaction.outbox.semantic_key,
  )
  let (semantic, semantic_len) = exec_string_to_null_terminated_bytes(
    semantic_text,
  )
  let payload_text = @storage.digest_text(transaction.outbox.payload_digest)
  let (payload, payload_len) = exec_string_to_null_terminated_bytes(
    payload_text,
  )
  let precondition_key_text = @storage.state_record_key_text(precondition.key)
  let (precondition_key, precondition_key_len) = exec_string_to_null_terminated_bytes(
    precondition_key_text,
  )
  let precondition_digest_text = @storage.digest_text(precondition.value_digest)
  let (precondition_digest, precondition_digest_len) = exec_string_to_null_terminated_bytes(
    precondition_digest_text,
  )
  let (has_expected, expected) = match transaction.state.expected_version {
    None => (0, 0)
    Some(version) => (1, version)
  }
  let result = state_store_commit_ffi(
    path,
    path_len,
    key,
    key_len,
    has_expected,
    expected,
    transaction.state.next_version,
    @storage.fencing_epoch_value(transaction.state.fencing_epoch),
    value,
    value_len,
    semantic,
    semantic_len,
    payload,
    payload_len,
    state_fault_code(transaction.fault_point),
    1,
    precondition_key,
    precondition_key_len,
    precondition.version,
    @storage.fencing_epoch_value(precondition.fencing_epoch),
    precondition_digest,
    precondition_digest_len,
  )
  if result == 8 {
    return Ok(
      @storage.GuardedStateTransactionOutcome::GuardedStateTransactionPreconditionConflict,
    )
  }
  let outcome = match result {
    0 => @storage.StateTransactionOutcome::StateTransactionCommitted
    1 => @storage.StateTransactionOutcome::StateTransactionReplayed
    2 => @storage.StateTransactionOutcome::StateTransactionVersionConflict
    3 => @storage.StateTransactionOutcome::StateTransactionStaleFence
    4 => @storage.StateTransactionOutcome::StateTransactionSemanticConflict
    5 =>
      match transaction.fault_point {
        Some(point) =>
          @storage.StateTransactionOutcome::StateTransactionFaultRolledBack(
            point,
          )
        None => return Err(state_store_failure("guarded fault classification"))
      }
    7 => @storage.StateTransactionOutcome::StateTransactionCommittedAckLost
    _ => return Err(state_store_failure("guarded transaction"))
  }
  Ok(
    @storage.GuardedStateTransactionOutcome::GuardedStateTransactionCompleted(
      outcome,
    ),
  )
}

///|
fn parse_state_record_capture(
  key : @storage.StateRecordKey,
  output : String,
) -> Result[@storage.StateRecord, @types.ChoirError] {
  let fields = output.split("|").to_array()
  if fields.length() != 3 {
    return Err(state_store_failure("record decoding"))
  }
  let version = @string.parse_int(fields[0]) catch {
    _ => return Err(state_store_failure("record version decoding"))
  }
  let fence = @string.parse_int(fields[1]) catch {
    _ => return Err(state_store_failure("record fence decoding"))
  }
  let digest = @control.Digest(fields[2].to_owned())
  match @storage.validate_digest(digest) {
    Ok(_) =>
      Ok({
        key,
        version,
        fencing_epoch: @control.FencingEpoch(fence.to_int64()),
        value_digest: digest,
      })
    Err(_) => Err(state_store_failure("record digest decoding"))
  }
}

///|
pub fn read_state_record(
  store : @storage.SqliteStateStore,
  key : @storage.StateRecordKey,
) -> Result[@storage.StateRecord?, @types.ChoirError] {
  match validate_store_path(store.path) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match @storage.validate_state_record_key(key) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let (path, path_len) = exec_string_to_null_terminated_bytes(store.path)
  let key_text = @storage.state_record_key_text(key)
  let (key_bytes, key_len) = exec_string_to_null_terminated_bytes(key_text)
  let output = Bytes::new(160)
  let result = state_store_read_state_ffi(
    path,
    path_len,
    key_bytes,
    key_len,
    output,
    output.length(),
  )
  if result == 0 {
    Ok(None)
  } else if result > 0 {
    match parse_state_record_capture(key, @utf8.decode_lossy(output[:result])) {
      Ok(record) => Ok(Some(record))
      Err(error) => Err(error)
    }
  } else {
    Err(state_store_failure("record read"))
  }
}

///|
pub fn list_state_records(
  store : @storage.SqliteStateStore,
  prefix : String,
) -> Result[Array[@storage.StateRecord], @types.ChoirError] {
  match validate_store_path(store.path) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match @storage.validate_state_record_prefix(prefix) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let (path, path_len) = exec_string_to_null_terminated_bytes(store.path)
  let (prefix_bytes, prefix_len) = exec_string_to_null_terminated_bytes(prefix)
  let output = Bytes::new(4 * 1024 * 1024)
  let result = state_store_list_state_ffi(
    path,
    path_len,
    prefix_bytes,
    prefix_len,
    output,
    output.length(),
  )
  if result < 0 {
    return Err(state_store_failure("record listing"))
  }
  if result == 0 {
    return Ok([])
  }
  let records : Array[@storage.StateRecord] = []
  for line in @utf8.decode_lossy(output[:result]).split("\n") {
    if line == "" {
      continue
    }
    let fields = line.split("|").to_array()
    if fields.length() != 4 {
      return Err(state_store_failure("record listing decode"))
    }
    let key = @storage.StateRecordKey(fields[0].to_owned())
    if !@storage.state_record_key_text(key).has_prefix(prefix) {
      return Err(state_store_failure("record listing prefix"))
    }
    let encoded = fields[1] + "|" + fields[2] + "|" + fields[3]
    match parse_state_record_capture(key, encoded.to_owned()) {
      Ok(record) => records.push(record)
      Err(error) => return Err(error)
    }
  }
  Ok(records)
}

///|
pub fn read_completion_outbox(
  store : @storage.SqliteStateStore,
  key : @storage.SemanticEventKey,
) -> Result[@storage.CompletionOutboxRecord?, @types.ChoirError] {
  match validate_store_path(store.path) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match @storage.validate_semantic_event_key(key) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let (path, path_len) = exec_string_to_null_terminated_bytes(store.path)
  let key_text = @storage.semantic_event_key_text(key)
  let (key_bytes, key_len) = exec_string_to_null_terminated_bytes(key_text)
  let output = Bytes::new(65)
  let result = state_store_read_outbox_ffi(
    path,
    path_len,
    key_bytes,
    key_len,
    output,
    output.length(),
  )
  if result == 0 {
    Ok(None)
  } else if result > 0 {
    let digest = @control.Digest(@utf8.decode_lossy(output[:result]))
    match @storage.validate_digest(digest) {
      Ok(_) => Ok(Some({ semantic_key: key, payload_digest: digest }))
      Err(_) => Err(state_store_failure("outbox digest decoding"))
    }
  } else {
    Err(state_store_failure("outbox read"))
  }
}

///|
pub fn sqlite_state_store_adapters() -> @storage.StateStoreAdapters {
  {
    initialize: initialize_state_store,
    commit: commit_state_transaction,
    commit_guarded: commit_guarded_state_transaction,
    read_state: read_state_record,
    list_state: list_state_records,
    read_outbox: read_completion_outbox,
  }
}

///|
fn artifact_store_failure(operation : String) -> @types.ChoirError {
  @types.ChoirError::workspace_error("artifact store " + operation + " failed")
}

///|
pub fn adopt_artifact(
  store : @storage.ArtifactStore,
  request : @storage.ArtifactAdoptionRequest,
) -> Result[@storage.ArtifactReceipt, @types.ChoirError] {
  match validate_store_path(store.root) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match @storage.validate_artifact_adoption(request) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let (root, root_len) = exec_string_to_null_terminated_bytes(store.root)
  let digest_text = @storage.digest_text(request.expected_digest)
  let (digest, digest_len) = exec_string_to_null_terminated_bytes(digest_text)
  let outcome = match
    artifact_store_adopt_ffi(
      root,
      root_len,
      digest,
      digest_len,
      request.content,
      request.content.length(),
    ) {
    0 => @storage.ArtifactAdoptionOutcome::ArtifactAdopted
    1 => @storage.ArtifactAdoptionOutcome::ArtifactAlreadyPresent
    -2 =>
      return Err(
        @types.ChoirError::workspace_error(
          "artifact store detected corrupt content at the expected digest path",
        ),
      )
    _ => return Err(artifact_store_failure("adoption"))
  }
  Ok({
    artifact_id: @storage.artifact_id_for_digest(request.expected_digest),
    digest: request.expected_digest,
    byte_length: request.content.length(),
    provenance: request.provenance,
    retention: request.retention,
    outcome,
  })
}

///|
pub fn artifact_store_contains(
  store : @storage.ArtifactStore,
  digest_value : @control.Digest,
) -> Result[Bool, @types.ChoirError] {
  match validate_store_path(store.root) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match @storage.validate_digest(digest_value) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let (root, root_len) = exec_string_to_null_terminated_bytes(store.root)
  let digest_text = @storage.digest_text(digest_value)
  let (digest, digest_len) = exec_string_to_null_terminated_bytes(digest_text)
  match artifact_store_contains_ffi(root, root_len, digest, digest_len) {
    0 => Ok(false)
    1 => Ok(true)
    -2 =>
      Err(
        @types.ChoirError::workspace_error(
          "artifact store digest path is not a regular immutable object",
        ),
      )
    _ => Err(artifact_store_failure("lookup"))
  }
}

///|
pub fn read_artifact(
  store : @storage.ArtifactStore,
  request : @storage.ArtifactReadRequest,
) -> Result[Bytes, @types.ChoirError] {
  match validate_store_path(store.root) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match @storage.validate_artifact_read(request) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let (root, root_len) = exec_string_to_null_terminated_bytes(store.root)
  let digest_text = @storage.digest_text(request.digest)
  let (digest, digest_len) = exec_string_to_null_terminated_bytes(digest_text)
  let size = artifact_store_size_ffi(root, root_len, digest, digest_len)
  if size < 0 {
    return Err(artifact_store_failure("read sizing"))
  }
  if size > request.max_bytes {
    return Err(
      @types.ChoirError::validation_error(
        "artifact exceeds the authorized read byte limit",
      ),
    )
  }
  let output = Bytes::new(size)
  if artifact_store_read_ffi(root, root_len, digest, digest_len, output, size) !=
    size {
    return Err(artifact_store_failure("read"))
  }
  if @storage.artifact_digest(output) != request.digest {
    return Err(
      @types.ChoirError::workspace_error(
        "artifact store content no longer matches its digest path",
      ),
    )
  }
  Ok(output)
}

///|
pub fn local_artifact_store_adapters() -> @storage.ArtifactStoreAdapters {
  {
    adopt: adopt_artifact,
    contains: artifact_store_contains,
    read: read_artifact,
  }
}
