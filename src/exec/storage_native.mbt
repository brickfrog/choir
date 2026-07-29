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
/// Result code 9: the write lock stayed contended past busy_timeout. Unlike
/// the generic storage failure this is retryable, so surface it through the
/// typed timeout classification callers can already distinguish.
fn state_store_busy(operation : String) -> @types.ChoirError {
  @types.ChoirError::timeout("SQLite state store " + operation + " busy")
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
/// Drop any pooled connection to this store.
///
/// Required before replacing a store file in place: a pooled connection would
/// still refer to the unlinked inode, so everything afterwards would read and
/// write a file nothing else can see.
pub fn forget_state_store(store : @storage.SqliteStateStore) -> Unit {
  match validate_store_path(store.path) {
    Ok(_) => {
      let (path, path_len) = exec_string_to_null_terminated_bytes(store.path)
      ignore(state_store_forget_ffi(path, path_len))
    }
    Err(_) => ()
  }
}

///|
/// What generation the store records for itself.
///
/// Three answers, deliberately distinguishable, because they call for opposite
/// decisions: `Err` when the store cannot be opened at all, `Ok(None)` when it
/// opens but predates recording a generation, and `Ok(Some(_))` when it says
/// what it is. Collapsing the first two is how a lost marker used to authorize
/// deleting healthy state.
pub fn read_state_store_generation(
  store : @storage.SqliteStateStore,
) -> Result[String?, @types.ChoirError] {
  match validate_store_path(store.path) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let (path, path_len) = exec_string_to_null_terminated_bytes(store.path)
  let buf = Bytes::new(256)
  let read = state_store_read_generation_ffi(path, path_len, buf, 256)
  if read < 0 {
    Err(state_store_failure("generation read"))
  } else if read == 0 {
    Ok(None)
  } else {
    Ok(Some(@utf8.decode_lossy(buf[:read])))
  }
}

///|
/// The DDL version this build's SQL is written against.
///
/// Declared beside the `CREATE TABLE` statements in `store.c` and bumped in the
/// same edit that changes them. Nothing derives it, and nothing can: the
/// durable-value generation digests record VALUES, which say nothing about
/// which columns a table has, and `CREATE TABLE IF NOT EXISTS` accepts a table
/// whose columns are not these without complaint. The test below is what makes
/// "in the same edit" more than an instruction in a comment.
pub fn state_store_ddl_version() -> Int {
  state_store_ddl_version_ffi()
}

///|
/// A DDL edit that did not bump the version fails here.
///
/// That failure is the whole point. `CREATE TABLE IF NOT EXISTS` accepts a
/// table whose columns are not the ones this build's SQL names, and the version
/// is the only thing that notices; hand-bumped and unchecked, forgetting it
/// leaves every store in the field reporting Current and failing every query at
/// runtime — the exact failure the version exists to prevent.
///
/// The check is a pinned digest rather than a runtime comparison because a
/// digest over SQL text moves for a reindentation, and at runtime this number
/// authorizes destroying the store. Here it costs a failing test.
test "the control store DDL is pinned to the version it declares" {
  // One digest per DDL version, oldest first: entry `i` pins the SQL text that
  // version `i + 1` was declared for. Appending is the only way to add one, and
  // the version is asserted to equal this array's length, so a new pin cannot
  // be recorded without the version moving with it. Editing an entry in place
  // is the way around that, and it is the wrong edit: it discards the pin for a
  // DDL already stamped onto stores in the field.
  let pins = [
    "7a0eb3bd1ed169bdf66f683e43da2b61855cabb53d03b778936432bdaec54662", "9905a47a5e19f9ef5771e8d2dc9c6b7cead67345a1cbea9891ecaa742087b6d9",
    "b15d2a95253f2ffbc53cd9c1138015b493c164f4dd59a614ca91251bbfc5fbe4",
  ]
  let buf = Bytes::new(4096)
  let written = state_store_ddl_text_ffi(buf, 4096)
  guard written > 0 else { fail("the control store DDL did not fit in 4096") }
  // Bump `CHOIR_STATE_STORE_DDL_VERSION` in `store.c` to match, or drop the pin
  // that should not have been appended.
  assert_eq(state_store_ddl_version(), pins.length())
  // Append the digest reported below and bump the version in the same edit; the
  // DDL changed.
  assert_eq(
    @storage.digest_text(
      @storage.artifact_digest(@utf8.encode(@utf8.decode_lossy(buf[:written]))),
    ),
    pins[pins.length() - 1],
  )
}

///|
test "the schedulable state query uses its composite index" {
  let path = "/tmp/choir-schedule-query-plan-" + @sys.get_pid().to_string()
  ignore(@sys.rm_rf(path))
  let store : @storage.SqliteStateStore = { path, }
  initialize_state_store(store).unwrap()
  let (encoded, length) = exec_string_to_null_terminated_bytes(path)
  assert_eq(state_store_schedule_query_uses_index_ffi(encoded, length), 1)
  forget_state_store(store)
  ignore(@sys.rm_rf(path))
}

///|
/// What DDL version the store's tables were created under.
///
/// `Ok(0)` means the store predates the stamp, which is adopted rather than
/// reset; `Err` means the file is not a usable database. The two are kept apart
/// for the same reason they are for the generation: they call for opposite
/// decisions.
pub fn read_state_store_ddl_version(
  store : @storage.SqliteStateStore,
) -> Result[Int, @types.ChoirError] {
  match validate_store_path(store.path) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let (path, path_len) = exec_string_to_null_terminated_bytes(store.path)
  let version = state_store_read_ddl_version_ffi(path, path_len)
  if version < 0 {
    Err(state_store_failure("DDL version read"))
  } else {
    Ok(version)
  }
}

///|
/// Stamp the DDL version onto a store this build has decided it can serve.
pub fn write_state_store_ddl_version(
  store : @storage.SqliteStateStore,
  version : Int,
) -> Result[Unit, @types.ChoirError] {
  match validate_store_path(store.path) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let (path, path_len) = exec_string_to_null_terminated_bytes(store.path)
  if state_store_write_ddl_version_ffi(path, path_len, version) == 0 {
    Ok(())
  } else {
    Err(state_store_failure("DDL version write"))
  }
}

///|
pub fn write_state_store_generation(
  store : @storage.SqliteStateStore,
  generation : String,
) -> Result[Unit, @types.ChoirError] {
  match validate_store_path(store.path) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let (path, path_len) = exec_string_to_null_terminated_bytes(store.path)
  let (encoded, _) = exec_string_to_null_terminated_bytes(generation)
  if state_store_write_generation_ffi(path, path_len, encoded) == 0 {
    Ok(())
  } else {
    Err(state_store_failure("generation write"))
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
fn state_outbox_owner_bytes(
  outbox : @storage.CompletionOutboxMutation,
) -> (Bytes, Int) {
  exec_string_to_null_terminated_bytes(
    @storage.completion_outbox_owner_text(outbox).unwrap_or(""),
  )
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
  let (owner_goal_id, owner_goal_id_len) = state_outbox_owner_bytes(
    request.outbox,
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
    @storage.state_record_schedule_class_code(request.state.schedule_class),
    value,
    value_len,
    semantic,
    semantic_len,
    payload,
    payload_len,
    owner_goal_id,
    owner_goal_id_len,
    state_fault_code(request.fault_point),
    0,
    empty,
    empty_len,
    0,
    0L,
    0,
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
    9 => Err(state_store_busy("transaction"))
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
  let (owner_goal_id, owner_goal_id_len) = state_outbox_owner_bytes(
    transaction.outbox,
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
    @storage.state_record_schedule_class_code(transaction.state.schedule_class),
    value,
    value_len,
    semantic,
    semantic_len,
    payload,
    payload_len,
    owner_goal_id,
    owner_goal_id_len,
    state_fault_code(transaction.fault_point),
    1,
    precondition_key,
    precondition_key_len,
    precondition.version,
    @storage.fencing_epoch_value(precondition.fencing_epoch),
    @storage.state_record_schedule_class_code(precondition.schedule_class),
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
    9 => return Err(state_store_busy("guarded transaction"))
    _ => return Err(state_store_failure("guarded transaction"))
  }
  Ok(
    @storage.GuardedStateTransactionOutcome::GuardedStateTransactionCompleted(
      outcome,
    ),
  )
}

///|
/// Delete idempotency witnesses only for one explicitly terminal Goal. Rows
/// without an owner are intentionally unreachable from this operation.
pub fn prune_completion_outbox_for_goal(
  store : @storage.SqliteStateStore,
  goal_id : @control.GoalId,
) -> Result[Int, @types.ChoirError] {
  match validate_store_path(store.path) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if goal_id.0 == "" || goal_id.0.contains("\u{00}") {
    return Err(@types.ChoirError::validation_error("invalid outbox Goal id"))
  }
  let (path, path_len) = exec_string_to_null_terminated_bytes(store.path)
  let (goal, goal_len) = exec_string_to_null_terminated_bytes(goal_id.0)
  match state_store_prune_goal_outbox_ffi(path, path_len, goal, goal_len) {
    value if value >= 0 => Ok(value)
    -2 => Err(state_store_busy("outbox pruning"))
    _ => Err(state_store_failure("outbox pruning"))
  }
}

///|
fn parse_state_record_capture(
  key : @storage.StateRecordKey,
  output : String,
) -> Result[@storage.StateRecord, @types.ChoirError] {
  let fields = output.split("|").to_array()
  if fields.length() != 4 {
    return Err(state_store_failure("record decoding"))
  }
  let version = @string.parse_int(fields[0]) catch {
    _ => return Err(state_store_failure("record version decoding"))
  }
  let fence = @string.parse_int(fields[1]) catch {
    _ => return Err(state_store_failure("record fence decoding"))
  }
  let schedule_code = @string.parse_int(fields[2]) catch {
    _ => return Err(state_store_failure("record schedule class decoding"))
  }
  let schedule_class = match
    @storage.state_record_schedule_class_from_code(schedule_code) {
    Ok(value) => value
    Err(_) => return Err(state_store_failure("record schedule class decoding"))
  }
  let digest = @control.Digest(fields[3].to_owned())
  match @storage.validate_digest(digest) {
    Ok(_) =>
      Ok({
        key,
        version,
        fencing_epoch: @control.FencingEpoch(fence.to_int64()),
        schedule_class,
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
/// What the store returns when the rows did not fit the buffer it was given.
/// Distinct from an ordinary failure so the caller can retry larger rather
/// than report a listing error for a store that is merely bigger than
/// expected.
fn state_store_list_overflow() -> Int {
  -2
}

///|
/// The largest listing Choir will assemble in one call. A store past this is a
/// real problem to report, not one to keep allocating against.
fn maximum_state_listing_bytes() -> Int {
  64 * 1024 * 1024
}

///|
fn list_state_records_with_schedule_class(
  store : @storage.SqliteStateStore,
  prefix : String,
  schedule_class : @storage.StateRecordScheduleClass?,
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
  // Start small and grow only when the store says the rows did not fit. This
  // ran once per Goal tick and allocated 4 MiB every time regardless of how
  // little came back — and 4 MiB was also a silent ceiling, because an
  // overflow reported as an ordinary listing failure.
  let mut capacity = 64 * 1024
  let mut output = Bytes::new(capacity)
  let list = fn(output : Bytes, capacity : Int) {
    match schedule_class {
      Some(class) =>
        state_store_list_state_by_schedule_class_ffi(
          path,
          path_len,
          prefix_bytes,
          prefix_len,
          @storage.state_record_schedule_class_code(class),
          output,
          capacity,
        )
      None =>
        state_store_list_state_ffi(
          path, path_len, prefix_bytes, prefix_len, output, capacity,
        )
    }
  }
  let mut result = list(output, capacity)
  while result == state_store_list_overflow() &&
        capacity < maximum_state_listing_bytes() {
    capacity = capacity * 4
    if capacity > maximum_state_listing_bytes() {
      capacity = maximum_state_listing_bytes()
    }
    output = Bytes::new(capacity)
    result = list(output, capacity)
  }
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
    if fields.length() != 5 {
      return Err(state_store_failure("record listing decode"))
    }
    let key = @storage.StateRecordKey(fields[0].to_owned())
    if !@storage.state_record_key_text(key).has_prefix(prefix) {
      return Err(state_store_failure("record listing prefix"))
    }
    let encoded = fields[1] +
      "|" +
      fields[2] +
      "|" +
      fields[3] +
      "|" +
      fields[4]
    match parse_state_record_capture(key, encoded.to_owned()) {
      Ok(record) => records.push(record)
      Err(error) => return Err(error)
    }
  }
  Ok(records)
}

///|
pub fn list_state_records(
  store : @storage.SqliteStateStore,
  prefix : String,
) -> Result[Array[@storage.StateRecord], @types.ChoirError] {
  list_state_records_with_schedule_class(store, prefix, None)
}

///|
pub fn list_state_records_by_schedule_class(
  store : @storage.SqliteStateStore,
  prefix : String,
  schedule_class : @storage.StateRecordScheduleClass,
) -> Result[Array[@storage.StateRecord], @types.ChoirError] {
  list_state_records_with_schedule_class(store, prefix, Some(schedule_class))
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
    list_state_by_schedule_class: list_state_records_by_schedule_class,
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
  // Record what this content is being kept for. Adoption previously returned
  // the retention in a receipt and dropped it, so the store knew only digests
  // and bytes and nothing could ever decide what was collectable.
  ignore(
    @sys.append_file_sync(
      artifact_retention_ledger_path(store),
      @storage.encode_artifact_retention_ledger([
        { digest: request.expected_digest, retentions: [request.retention] },
      ]),
    ),
  )
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
/// Where the store records what each artifact is being kept for.
pub fn artifact_retention_ledger_path(store : @storage.ArtifactStore) -> String {
  store.root + "/retention.ledger"
}

///|
/// What the store is currently keeping each artifact for. An absent ledger
/// reads as empty, which makes nothing collectable.
pub fn read_artifact_retention_ledger(
  store : @storage.ArtifactStore,
) -> Array[@storage.ArtifactRetentionEntry] {
  let path = artifact_retention_ledger_path(store)
  if !@sys.path_exists(path) {
    []
  } else {
    @storage.decode_artifact_retention_ledger(@sys.read_file(path))
  }
}

///|
/// Remove named content and drop its ledger entries.
///
/// Ordered content-first: the ledger is only rewritten once the bytes are
/// gone. A crash between them leaves an entry naming content that is already
/// absent, and the next collection removes it again — remove reports success
/// on an already-absent artifact precisely so this converges. The reverse
/// order would drop the record while the bytes remained, and nothing would
/// ever know to collect them.
///
/// The caller decides what is collectable; this only executes the decision.
///
/// Returns how much content this call actually unlinked, which is not always
/// how much was named: an archive resumed after a crash between the removal and
/// the ledger rewrite is asked again for content that is already gone, and
/// reporting that as released would tell an operator space was reclaimed that
/// was reclaimed the first time.
pub fn collect_artifacts(
  store : @storage.ArtifactStore,
  collect : Array[@control.Digest],
) -> Result[Int, @types.ChoirError] {
  match validate_store_path(store.root) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if collect.length() == 0 {
    return Ok(0)
  }
  let (root, root_len) = exec_string_to_null_terminated_bytes(store.root)
  let mut released = 0
  for digest in collect {
    let (encoded, digest_len) = exec_string_to_null_terminated_bytes(
      @storage.digest_text(digest),
    )
    match artifact_store_remove_ffi(root, root_len, encoded, digest_len) {
      1 => released = released + 1
      0 => ()
      _ => return Err(artifact_store_failure("collection"))
    }
  }
  let retained = read_artifact_retention_ledger(store).filter(fn(entry) {
    !collect.contains(entry.digest)
  })
  if !@sys.write_file_atomic(
      artifact_retention_ledger_path(store),
      @storage.encode_artifact_retention_ledger(retained),
    ) {
    return Err(artifact_store_failure("collection ledger rewrite"))
  }
  Ok(released)
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
