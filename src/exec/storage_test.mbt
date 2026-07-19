///|
let store_digest_a : @control.Digest = @control.Digest(
  "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
)

///|
let store_digest_b : @control.Digest = @control.Digest(
  "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
)

///|
let store_digest_c : @control.Digest = @control.Digest(
  "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
)

///|
fn storage_test_path(name : String) -> String {
  "/tmp/choir-storage-test-" + @sys.get_pid().to_string() + "-" + name
}

///|
fn initial_state_request(
  semantic_suffix : String,
  fault_point : @storage.StateStoreFaultPoint?,
) -> @storage.StateTransactionRequest {
  {
    state: {
      key: @storage.StateRecordKey("goal:g-1"),
      expected_version: None,
      next_version: 1,
      fencing_epoch: @control.FencingEpoch(1L),
      value_digest: store_digest_a,
    },
    outbox: {
      semantic_key: @storage.SemanticEventKey("goal:g-1:" + semantic_suffix),
      payload_digest: store_digest_b,
    },
    fault_point,
  }
}

///|
fn expect_state_outcome(
  result : Result[@storage.StateTransactionOutcome, @types.ChoirError],
  expected : @storage.StateTransactionOutcome,
) -> Unit raise {
  match result {
    Ok(actual) => assert_eq(actual, expected)
    Err(error) => fail(error.message())
  }
}

///|
fn expect_state_absent(
  result : Result[@storage.StateRecord?, @types.ChoirError],
) -> Unit raise {
  match result {
    Ok(None) => ()
    Ok(Some(_)) => fail("expected state record to be absent")
    Err(error) => fail(error.message())
  }
}

///|
fn expect_outbox_absent(
  result : Result[@storage.CompletionOutboxRecord?, @types.ChoirError],
) -> Unit raise {
  match result {
    Ok(None) => ()
    Ok(Some(_)) => fail("expected outbox record to be absent")
    Err(error) => fail(error.message())
  }
}

///|
test "SQLite state transaction persists atomically and replays after restart" {
  let path = storage_test_path("sqlite-restart.db")
  ignore(@sys.rm_rf(path))
  ignore(@sys.rm_rf(path + "-shm"))
  ignore(@sys.rm_rf(path + "-wal"))
  let store : @storage.SqliteStateStore = { path, }
  let request = initial_state_request("started", None)
  match initialize_state_store(store) {
    Ok(_) => ()
    Err(error) => fail(error.message())
  }
  match commit_state_transaction(store, request) {
    Ok(@storage.StateTransactionOutcome::StateTransactionCommitted) => ()
    Ok(_) => fail("unexpected initial transaction outcome")
    Err(error) => fail(error.message())
  }
  let restarted : @storage.SqliteStateStore = { path, }
  match read_state_record(restarted, request.state.key) {
    Ok(
      Some(
        {
          version: 1,
          fencing_epoch: @control.FencingEpoch(1L),
          value_digest: actual_digest,
          ..,
        }
      )
    ) => assert_eq(actual_digest, store_digest_a)
    Ok(_) => fail("unexpected durable state")
    Err(error) => fail(error.message())
  }
  match read_completion_outbox(restarted, request.outbox.semantic_key) {
    Ok(Some({ payload_digest, .. })) =>
      assert_eq(payload_digest, store_digest_b)
    Ok(_) => fail("unexpected durable outbox record")
    Err(error) => fail(error.message())
  }
  match commit_state_transaction(restarted, request) {
    Ok(@storage.StateTransactionOutcome::StateTransactionReplayed) => ()
    Ok(_) => fail("unexpected replay outcome")
    Err(error) => fail(error.message())
  }
  ignore(@sys.rm_rf(path))
  ignore(@sys.rm_rf(path + "-shm"))
  ignore(@sys.rm_rf(path + "-wal"))
}

///|
test "SQLite state transaction enforces semantic uniqueness versions and fences" {
  let path = storage_test_path("sqlite-conflicts.db")
  ignore(@sys.rm_rf(path))
  ignore(@sys.rm_rf(path + "-shm"))
  ignore(@sys.rm_rf(path + "-wal"))
  let store : @storage.SqliteStateStore = { path, }
  let initial = initial_state_request("accepted", None)
  guard initialize_state_store(store) is Ok(_) else {
    fail("initialize state store")
  }
  guard commit_state_transaction(store, initial)
    is Ok(@storage.StateTransactionOutcome::StateTransactionCommitted) else {
    fail("commit initial state")
  }
  let semantic_conflict : @storage.StateTransactionRequest = {
    ..initial,
    outbox: { ..initial.outbox, payload_digest: store_digest_c },
  }
  expect_state_outcome(
    commit_state_transaction(store, semantic_conflict),
    @storage.StateTransactionOutcome::StateTransactionSemanticConflict,
  )
  let version_conflict : @storage.StateTransactionRequest = {
    state: {
      ..initial.state,
      expected_version: Some(9),
      next_version: 10,
      fencing_epoch: @control.FencingEpoch(10L),
      value_digest: store_digest_b,
    },
    outbox: {
      semantic_key: @storage.SemanticEventKey("goal:g-1:bad-version"),
      payload_digest: store_digest_c,
    },
    fault_point: None,
  }
  expect_state_outcome(
    commit_state_transaction(store, version_conflict),
    @storage.StateTransactionOutcome::StateTransactionVersionConflict,
  )
  let fenced_update : @storage.StateTransactionRequest = {
    state: {
      ..initial.state,
      expected_version: Some(1),
      next_version: 2,
      fencing_epoch: @control.FencingEpoch(10L),
      value_digest: store_digest_b,
    },
    outbox: {
      semantic_key: @storage.SemanticEventKey("goal:g-1:advanced"),
      payload_digest: store_digest_c,
    },
    fault_point: None,
  }
  expect_state_outcome(
    commit_state_transaction(store, fenced_update),
    @storage.StateTransactionOutcome::StateTransactionCommitted,
  )
  expect_state_outcome(
    commit_state_transaction(store, initial),
    @storage.StateTransactionOutcome::StateTransactionReplayed,
  )
  let stale_update : @storage.StateTransactionRequest = {
    state: {
      ..fenced_update.state,
      expected_version: Some(2),
      next_version: 3,
      fencing_epoch: @control.FencingEpoch(9L),
      value_digest: store_digest_c,
    },
    outbox: {
      semantic_key: @storage.SemanticEventKey("goal:g-1:stale"),
      payload_digest: store_digest_a,
    },
    fault_point: None,
  }
  expect_state_outcome(
    commit_state_transaction(store, stale_update),
    @storage.StateTransactionOutcome::StateTransactionStaleFence,
  )
  match read_state_record(store, initial.state.key) {
    Ok(Some({ version: 2, fencing_epoch: @control.FencingEpoch(10L), .. })) =>
      ()
    Ok(_) => fail("stale writer changed durable state")
    Err(error) => fail(error.message())
  }
  ignore(@sys.rm_rf(path))
  ignore(@sys.rm_rf(path + "-shm"))
  ignore(@sys.rm_rf(path + "-wal"))
}

///|
test "SQLite fault points roll back or reconcile committed acknowledgment loss" {
  for
    fault_case in [
      (
        "after-state",
        @storage.StateStoreFaultPoint::StateAfterMutationBeforeOutbox,
      ),
      (
        "before-commit",
        @storage.StateStoreFaultPoint::StateAfterOutboxBeforeCommit,
      ),
    ] {
    let (suffix, point) = fault_case
    let path = storage_test_path("sqlite-fault-" + suffix + ".db")
    ignore(@sys.rm_rf(path))
    ignore(@sys.rm_rf(path + "-shm"))
    ignore(@sys.rm_rf(path + "-wal"))
    let store : @storage.SqliteStateStore = { path, }
    let request = initial_state_request(suffix, Some(point))
    guard initialize_state_store(store) is Ok(_) else {
      fail("initialize fault state store")
    }
    expect_state_outcome(
      commit_state_transaction(store, request),
      @storage.StateTransactionOutcome::StateTransactionFaultRolledBack(point),
    )
    expect_state_absent(read_state_record(store, request.state.key))
    expect_outbox_absent(
      read_completion_outbox(store, request.outbox.semantic_key),
    )
    ignore(@sys.rm_rf(path))
    ignore(@sys.rm_rf(path + "-shm"))
    ignore(@sys.rm_rf(path + "-wal"))
  }
  let ack_path = storage_test_path("sqlite-fault-ack.db")
  ignore(@sys.rm_rf(ack_path))
  ignore(@sys.rm_rf(ack_path + "-shm"))
  ignore(@sys.rm_rf(ack_path + "-wal"))
  let ack_store : @storage.SqliteStateStore = { path: ack_path }
  let ack_request = initial_state_request(
    "ack-lost",
    Some(@storage.StateStoreFaultPoint::StateAfterCommitBeforeAck),
  )
  guard initialize_state_store(ack_store) is Ok(_) else {
    fail("initialize acknowledgment-loss store")
  }
  expect_state_outcome(
    commit_state_transaction(ack_store, ack_request),
    @storage.StateTransactionOutcome::StateTransactionCommittedAckLost,
  )
  let restarted : @storage.SqliteStateStore = { path: ack_path }
  assert_true(
    read_state_record(restarted, ack_request.state.key) is Ok(Some(_)),
  )
  assert_true(
    read_completion_outbox(restarted, ack_request.outbox.semantic_key)
    is Ok(Some(_)),
  )
  expect_state_outcome(
    commit_state_transaction(restarted, { ..ack_request, fault_point: None }),
    @storage.StateTransactionOutcome::StateTransactionReplayed,
  )
  ignore(@sys.rm_rf(ack_path))
  ignore(@sys.rm_rf(ack_path + "-shm"))
  ignore(@sys.rm_rf(ack_path + "-wal"))
}

///|
test "local artifact store atomically adopts immutable content" {
  let root = storage_test_path("artifacts")
  ignore(@sys.rm_rf(root))
  let store : @storage.ArtifactStore = { root, }
  let content = b"durable evidence"
  let digest = @storage.artifact_digest(content)
  let request : @storage.ArtifactAdoptionRequest = {
    content,
    expected_digest: digest,
    provenance: @storage.ArtifactProvenance::ArtifactConformanceEvidence,
    retention: @storage.ArtifactRetention::ArtifactPermanent,
  }
  match adopt_artifact(store, request) {
    Ok({ outcome: @storage.ArtifactAdoptionOutcome::ArtifactAdopted, .. }) => ()
    Ok(_) => fail("unexpected artifact adoption receipt")
    Err(error) => fail(error.message())
  }
  match artifact_store_contains(store, digest) {
    Ok(true) => ()
    Ok(false) => fail("adopted artifact was not found")
    Err(error) => fail(error.message())
  }
  assert_eq(
    @sys.read_file(root + "/" + @storage.artifact_object_relative_path(digest)),
    "durable evidence",
  )
  match adopt_artifact(store, request) {
    Ok(
      { outcome: @storage.ArtifactAdoptionOutcome::ArtifactAlreadyPresent, .. }
    ) => ()
    Ok(_) => fail("unexpected repeated adoption receipt")
    Err(error) => fail(error.message())
  }
  ignore(@sys.rm_rf(root))
}

///|
test "local artifact store rejects corrupt targets and symlinked roots" {
  let corrupt_root = storage_test_path("artifacts-corrupt")
  ignore(@sys.rm_rf(corrupt_root))
  let content = b"expected evidence"
  let digest = @storage.artifact_digest(content)
  let target = corrupt_root +
    "/" +
    @storage.artifact_object_relative_path(digest)
  guard @sys.create_dir_all(
    corrupt_root + "/sha256/" + @storage.digest_text(digest)[:2].to_owned(),
  ) else {
    fail("create corrupt artifact shard")
  }
  guard @sys.write_file_sync(target, "wrong") else {
    fail("write corrupt target")
  }
  let request : @storage.ArtifactAdoptionRequest = {
    content,
    expected_digest: digest,
    provenance: @storage.ArtifactProvenance::ArtifactConformanceEvidence,
    retention: @storage.ArtifactRetention::ArtifactPermanent,
  }
  assert_true(
    adopt_artifact(@storage.ArtifactStore::{ root: corrupt_root }, request)
    is Err(_),
  )
  assert_eq(@sys.read_file(target), "wrong")
  ignore(@sys.rm_rf(corrupt_root))

  let outside = storage_test_path("artifacts-outside")
  let linked_root = storage_test_path("artifacts-link")
  ignore(@sys.rm_rf(outside))
  ignore(@sys.rm_rf(linked_root))
  guard @sys.create_dir_all(outside) else { fail("create symlink canary dir") }
  guard @sys.write_file_sync(outside + "/canary", "unchanged") else {
    fail("write symlink canary")
  }
  guard @sys.symlink_force(outside, linked_root) else {
    fail("create artifact root symlink")
  }
  assert_true(
    adopt_artifact(@storage.ArtifactStore::{ root: linked_root }, request)
    is Err(_),
  )
  assert_eq(@sys.read_file(outside + "/canary"), "unchanged")
  assert_false(@sys.path_exists(outside + "/sha256"))
  ignore(@sys.rm_rf(linked_root))
  ignore(@sys.rm_rf(outside))
}
