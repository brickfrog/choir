///|
pub(all) struct SqliteStateStore {
  path : String
} derive(Debug, Eq)

///|
pub(all) struct StateRecordKey(String) derive (
  Debug,
  Eq,
  Compare,
  Hash,
  ToJson,
  FromJson,
)

///|
pub(all) struct SemanticEventKey(String) derive (
  Debug,
  Eq,
  Compare,
  Hash,
  ToJson,
  FromJson,
)

///|
pub(all) enum StateStoreFaultPoint {
  StateAfterMutationBeforeOutbox
  StateAfterOutboxBeforeCommit
  StateAfterCommitBeforeAck
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct StateMutation {
  key : StateRecordKey
  expected_version : Int?
  next_version : Int
  fencing_epoch : @control.FencingEpoch
  value_digest : @control.Digest
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct CompletionOutboxMutation {
  semantic_key : SemanticEventKey
  payload_digest : @control.Digest
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct StateTransactionRequest {
  state : StateMutation
  outbox : CompletionOutboxMutation
  fault_point : StateStoreFaultPoint?
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum StateTransactionOutcome {
  StateTransactionCommitted
  StateTransactionReplayed
  StateTransactionVersionConflict
  StateTransactionStaleFence
  StateTransactionSemanticConflict
  StateTransactionFaultRolledBack(StateStoreFaultPoint)
  StateTransactionCommittedAckLost
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct StateRecord {
  key : StateRecordKey
  version : Int
  fencing_epoch : @control.FencingEpoch
  value_digest : @control.Digest
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct CompletionOutboxRecord {
  semantic_key : SemanticEventKey
  payload_digest : @control.Digest
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct StateStoreAdapters {
  initialize : (SqliteStateStore) -> Result[Unit, @types.ChoirError]
  commit : (SqliteStateStore, StateTransactionRequest) -> Result[
    StateTransactionOutcome,
    @types.ChoirError,
  ]
  read_state : (SqliteStateStore, StateRecordKey) -> Result[
    StateRecord?,
    @types.ChoirError,
  ]
  read_outbox : (SqliteStateStore, SemanticEventKey) -> Result[
    CompletionOutboxRecord?,
    @types.ChoirError,
  ]
}

///|
fn valid_storage_key_text(value : String) -> Bool {
  if value == "" || value == "." || value.contains("..") {
    return false
  }
  for char in value {
    if !((char >= 'a' && char <= 'z') ||
      (char >= 'A' && char <= 'Z') ||
      (char >= '0' && char <= '9') ||
      char == '-' ||
      char == '_' ||
      char == '.' ||
      char == ':') {
      return false
    }
  }
  true
}

///|
pub fn validate_state_record_key(
  key : StateRecordKey,
) -> Result[Unit, @types.ChoirError] {
  guard key is StateRecordKey(value) else {
    return Err(@types.ChoirError::validation_error("invalid state record key"))
  }
  if valid_storage_key_text(value) {
    Ok(())
  } else {
    Err(@types.ChoirError::validation_error("invalid state record key"))
  }
}

///|
pub fn validate_semantic_event_key(
  key : SemanticEventKey,
) -> Result[Unit, @types.ChoirError] {
  guard key is SemanticEventKey(value) else {
    return Err(
      @types.ChoirError::validation_error("invalid semantic event key"),
    )
  }
  if valid_storage_key_text(value) {
    Ok(())
  } else {
    Err(@types.ChoirError::validation_error("invalid semantic event key"))
  }
}

///|
pub fn digest_text(digest : @control.Digest) -> String {
  guard digest is @control.Digest(value) else { return "" }
  value
}

///|
pub fn state_record_key_text(key : StateRecordKey) -> String {
  guard key is StateRecordKey(value) else { return "" }
  value
}

///|
pub fn semantic_event_key_text(key : SemanticEventKey) -> String {
  guard key is SemanticEventKey(value) else { return "" }
  value
}

///|
pub fn fencing_epoch_value(epoch : @control.FencingEpoch) -> Int64 {
  guard epoch is @control.FencingEpoch(value) else { return 0L }
  value
}

///|
fn digest_is_lower_hex(value : String) -> Bool {
  if value.length() != 64 {
    return false
  }
  for char in value {
    if !((char >= '0' && char <= '9') || (char >= 'a' && char <= 'f')) {
      return false
    }
  }
  true
}

///|
pub fn validate_digest(
  digest : @control.Digest,
) -> Result[Unit, @types.ChoirError] {
  if digest_is_lower_hex(digest_text(digest)) {
    Ok(())
  } else {
    Err(
      @types.ChoirError::validation_error(
        "state-store digest must be lowercase SHA-256",
      ),
    )
  }
}

///|
pub fn validate_state_transaction(
  request : StateTransactionRequest,
) -> Result[Unit, @types.ChoirError] {
  match validate_state_record_key(request.state.key) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match validate_semantic_event_key(request.outbox.semantic_key) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match validate_digest(request.state.value_digest) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match validate_digest(request.outbox.payload_digest) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let expected_next = match request.state.expected_version {
    None => 1
    Some(version) => version + 1
  }
  if request.state.next_version != expected_next {
    return Err(
      @types.ChoirError::validation_error(
        "state mutation next version must be exactly expected version plus one",
      ),
    )
  }
  if fencing_epoch_value(request.state.fencing_epoch) <= 0L {
    return Err(
      @types.ChoirError::validation_error(
        "state mutation requires a positive fencing epoch",
      ),
    )
  }
  Ok(())
}
