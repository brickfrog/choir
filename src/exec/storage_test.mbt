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
      schedule_class: @storage.StateRecordScheduleClass::StateRecordNotSchedulable,
      value_digest: store_digest_a,
    },
    outbox: {
      semantic_key: @storage.SemanticEventKey("goal:g-1:" + semantic_suffix),
      payload_digest: store_digest_b,
      owner_goal_id: None,
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
  assert_eq(
    commit_state_transaction(restarted, {
      ..request,
      state: {
        ..request.state,
        schedule_class: @storage.StateRecordScheduleClass::StateRecordSchedulable,
      },
    }).unwrap(),
    @storage.StateTransactionOutcome::StateTransactionSemanticConflict,
  )
  ignore(@sys.rm_rf(path))
  ignore(@sys.rm_rf(path + "-shm"))
  ignore(@sys.rm_rf(path + "-wal"))
}

///|
test "completion outbox pruning deletes only one typed Goal owner" {
  let path = storage_test_path("outbox-owner-prune.db")
  ignore(@sys.rm_rf(path))
  ignore(@sys.rm_rf(path + "-shm"))
  ignore(@sys.rm_rf(path + "-wal"))
  let store : @storage.SqliteStateStore = { path, }
  initialize_state_store(store).unwrap()
  let request = fn(
    state_key : String,
    semantic_key : String,
    owner_goal_id : @control.GoalId?,
  ) -> @storage.StateTransactionRequest {
    {
      state: {
        key: @storage.StateRecordKey(state_key),
        expected_version: None,
        next_version: 1,
        fencing_epoch: @control.FencingEpoch(1L),
        schedule_class: @storage.StateRecordScheduleClass::StateRecordNotSchedulable,
        value_digest: store_digest_a,
      },
      outbox: {
        semantic_key: @storage.SemanticEventKey(semantic_key),
        payload_digest: store_digest_b,
        owner_goal_id,
      },
      fault_point: None,
    }
  }
  let goal_a_key = @storage.SemanticEventKey("goal:a:owned")
  let goal_b_key = @storage.SemanticEventKey("goal:b:owned")
  let global_key = @storage.SemanticEventKey("global:unowned")
  for
    transaction in [
      request("state:a", "goal:a:owned", Some(@control.GoalId("goal-a"))),
      request("state:b", "goal:b:owned", Some(@control.GoalId("goal-b"))),
      request("state:global", "global:unowned", None),
    ] {
    assert_eq(
      commit_state_transaction(store, transaction).unwrap(),
      @storage.StateTransactionOutcome::StateTransactionCommitted,
    )
  }
  assert_eq(
    commit_state_transaction(
      store,
      request("state:a", "goal:a:owned", Some(@control.GoalId("goal-other"))),
    ).unwrap(),
    @storage.StateTransactionOutcome::StateTransactionSemanticConflict,
  )
  assert_eq(
    prune_completion_outbox_for_goal(store, @control.GoalId("goal-a")).unwrap(),
    1,
  )
  assert_eq(read_completion_outbox(store, goal_a_key).unwrap(), None)
  assert_true(read_completion_outbox(store, goal_b_key).unwrap() is Some(_))
  assert_true(read_completion_outbox(store, global_key).unwrap() is Some(_))
  // Convergent after a crash or repeated archive.
  assert_eq(
    prune_completion_outbox_for_goal(store, @control.GoalId("goal-a")).unwrap(),
    0,
  )
  ignore(@sys.rm_rf(path))
  ignore(@sys.rm_rf(path + "-shm"))
  ignore(@sys.rm_rf(path + "-wal"))
}

///|
test "SQLite state listing returns only the requested durable prefix" {
  let path = storage_test_path("sqlite-list.db")
  ignore(@sys.rm_rf(path))
  ignore(@sys.rm_rf(path + "-shm"))
  ignore(@sys.rm_rf(path + "-wal"))
  let store : @storage.SqliteStateStore = { path, }
  guard initialize_state_store(store) is Ok(_) else {
    fail("initialize state store")
  }
  let requests : Array[@storage.StateTransactionRequest] = [
    {
      state: {
        key: @storage.StateRecordKey("goal-run:first"),
        expected_version: None,
        next_version: 1,
        fencing_epoch: @control.FencingEpoch(1L),
        schedule_class: @storage.StateRecordScheduleClass::StateRecordSchedulable,
        value_digest: store_digest_a,
      },
      outbox: {
        semantic_key: @storage.SemanticEventKey("goal-run:first:created"),
        payload_digest: store_digest_a,
        owner_goal_id: None,
      },
      fault_point: None,
    },
    {
      state: {
        key: @storage.StateRecordKey("goal-run:second"),
        expected_version: None,
        next_version: 1,
        fencing_epoch: @control.FencingEpoch(2L),
        schedule_class: @storage.StateRecordScheduleClass::StateRecordNotSchedulable,
        value_digest: store_digest_b,
      },
      outbox: {
        semantic_key: @storage.SemanticEventKey("goal-run:second:created"),
        payload_digest: store_digest_b,
        owner_goal_id: None,
      },
      fault_point: None,
    },
    initial_state_request("unrelated", None),
  ]
  for request in requests {
    guard commit_state_transaction(store, request)
      is Ok(@storage.StateTransactionOutcome::StateTransactionCommitted) else {
      fail("commit listed state")
    }
  }
  match list_state_records(store, "goal-run:") {
    Ok(records) => {
      assert_eq(records.length(), 2)
      assert_eq(
        records.map(fn(record) { @storage.state_record_key_text(record.key) }),
        ["goal-run:first", "goal-run:second"],
      )
      assert_eq(records[0].value_digest, store_digest_a)
      assert_eq(records[1].fencing_epoch, @control.FencingEpoch(2L))
    }
    Err(error) => fail(error.message())
  }
  match
    list_state_records_by_schedule_class(
      store,
      "goal-run:",
      @storage.StateRecordScheduleClass::StateRecordSchedulable,
    ) {
    Ok([record]) => {
      assert_eq(@storage.state_record_key_text(record.key), "goal-run:first")
      assert_eq(
        record.schedule_class,
        @storage.StateRecordScheduleClass::StateRecordSchedulable,
      )
    }
    Ok(_) => fail("schedulable listing returned the wrong records")
    Err(error) => fail(error.message())
  }
  match
    list_state_records_by_schedule_class(
      store,
      "goal-run:",
      @storage.StateRecordScheduleClass::StateRecordNotSchedulable,
    ) {
    Ok([record]) =>
      assert_eq(@storage.state_record_key_text(record.key), "goal-run:second")
    Ok(_) => fail("terminal listing returned the wrong records")
    Err(error) => fail(error.message())
  }
  assert_eq(
    list_state_records_by_schedule_class(
      store,
      "goal:",
      @storage.StateRecordScheduleClass::StateRecordSchedulable,
    )
    .unwrap()
    .length(),
    0,
  )
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
      owner_goal_id: None,
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
      owner_goal_id: None,
    },
    fault_point: None,
  }
  expect_state_outcome(
    commit_state_transaction(store, fenced_update),
    @storage.StateTransactionOutcome::StateTransactionCommitted,
  )
  expect_state_outcome(
    commit_state_transaction(store, initial),
    @storage.StateTransactionOutcome::StateTransactionVersionConflict,
  )
  // Once a newer version commits, replaying the old semantic event cannot
  // mutate state: its expected version is stale. The superseded idempotency row
  // is therefore safe to prune, while the current transition stays protected.
  assert_eq(
    read_completion_outbox(store, initial.outbox.semantic_key).unwrap(),
    None,
  )
  assert_true(
    read_completion_outbox(store, fenced_update.outbox.semantic_key).unwrap()
    is Some(_),
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
      owner_goal_id: None,
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
test "guarded state transaction orders Part authorization against Goal cutoff" {
  let path = storage_test_path("sqlite-guarded-cutoff.db")
  ignore(@sys.rm_rf(path))
  ignore(@sys.rm_rf(path + "-shm"))
  ignore(@sys.rm_rf(path + "-wal"))
  let store : @storage.SqliteStateStore = { path, }
  let running = initial_state_request("running", None)
  guard initialize_state_store(store) is Ok(_) else {
    fail("initialize guarded state store")
  }
  guard commit_state_transaction(store, running)
    is Ok(@storage.StateTransactionOutcome::StateTransactionCommitted) else {
    fail("commit running Goal")
  }
  let running_record = match read_state_record(store, running.state.key) {
    Ok(Some(value)) => value
    Ok(None) => fail("running Goal record is absent")
    Err(error) => fail(error.message())
  }
  let authorized : @storage.StateTransactionRequest = {
    state: {
      key: @storage.StateRecordKey("part:p-1"),
      expected_version: None,
      next_version: 1,
      fencing_epoch: @control.FencingEpoch(1L),
      schedule_class: @storage.StateRecordScheduleClass::StateRecordNotSchedulable,
      value_digest: store_digest_b,
    },
    outbox: {
      semantic_key: @storage.SemanticEventKey("part:p-1:authorized"),
      payload_digest: store_digest_b,
      owner_goal_id: None,
    },
    fault_point: None,
  }
  let guarded_authorized : @storage.GuardedStateTransactionRequest = {
    transaction: authorized,
    precondition: { record: running_record },
  }
  assert_eq(
    commit_guarded_state_transaction(store, guarded_authorized).unwrap(),
    @storage.GuardedStateTransactionOutcome::GuardedStateTransactionCompleted(
      @storage.StateTransactionOutcome::StateTransactionCommitted,
    ),
  )
  let wrong_class_guard : @storage.GuardedStateTransactionRequest = {
    transaction: {
      ..authorized,
      state: {
        ..authorized.state,
        key: @storage.StateRecordKey("part:p-class"),
      },
      outbox: {
        ..authorized.outbox,
        semantic_key: @storage.SemanticEventKey("part:p-class:authorized"),
      },
    },
    precondition: {
      record: {
        ..running_record,
        schedule_class: @storage.StateRecordScheduleClass::StateRecordSchedulable,
      },
    },
  }
  assert_eq(
    commit_guarded_state_transaction(store, wrong_class_guard).unwrap(),
    @storage.GuardedStateTransactionOutcome::GuardedStateTransactionPreconditionConflict,
  )
  let cancellation : @storage.StateTransactionRequest = {
    state: {
      ..running.state,
      expected_version: Some(1),
      next_version: 2,
      value_digest: store_digest_c,
    },
    outbox: {
      semantic_key: @storage.SemanticEventKey("goal:g-1:canceling"),
      payload_digest: store_digest_c,
      owner_goal_id: None,
    },
    fault_point: None,
  }
  guard commit_state_transaction(store, cancellation)
    is Ok(@storage.StateTransactionOutcome::StateTransactionCommitted) else {
    fail("commit Goal cancellation cutoff")
  }
  let rejected : @storage.StateTransactionRequest = {
    state: { ..authorized.state, key: @storage.StateRecordKey("part:p-2") },
    outbox: {
      semantic_key: @storage.SemanticEventKey("part:p-2:authorized"),
      payload_digest: store_digest_b,
      owner_goal_id: None,
    },
    fault_point: None,
  }
  assert_eq(
    commit_guarded_state_transaction(store, {
      transaction: rejected,
      precondition: { record: running_record },
    }).unwrap(),
    @storage.GuardedStateTransactionOutcome::GuardedStateTransactionPreconditionConflict,
  )
  expect_state_absent(read_state_record(store, rejected.state.key))
  expect_outbox_absent(
    read_completion_outbox(store, rejected.outbox.semantic_key),
  )
  assert_eq(
    commit_guarded_state_transaction(store, guarded_authorized).unwrap(),
    @storage.GuardedStateTransactionOutcome::GuardedStateTransactionCompleted(
      @storage.StateTransactionOutcome::StateTransactionReplayed,
    ),
  )
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
  let restarted : @storage.ArtifactStore = { root, }
  match read_artifact(restarted, { digest, max_bytes: 1024 }) {
    Ok(actual) => assert_eq(actual, content)
    Err(error) => fail(error.message())
  }
  assert_true(read_artifact(restarted, { digest, max_bytes: 4 }) is Err(_))
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
  assert_true(
    read_artifact(@storage.ArtifactStore::{ root: corrupt_root }, {
      digest,
      max_bytes: 1024,
    })
    is Err(_),
  )
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

///|
/// The schema generation lives in the store it describes, so it cannot be lost
/// separately. A sibling marker could be, and its absence used to authorize
/// deleting the whole control store.
test "the schema generation round-trips inside the store" {
  let path = storage_test_path("sqlite-generation.db")
  ignore(@sys.rm_rf(path))
  ignore(@sys.rm_rf(path + "-shm"))
  ignore(@sys.rm_rf(path + "-wal"))
  let store : @storage.SqliteStateStore = { path, }
  guard initialize_state_store(store) is Ok(_) else {
    fail("initialize state store")
  }
  // Freshly created: readable, and recording nothing yet.
  assert_true(read_state_store_generation(store) is Ok(None))
  guard write_state_store_generation(store, "choir-durable-shape-aaaa") is Ok(_) else {
    fail("write generation")
  }
  let restarted : @storage.SqliteStateStore = { path, }
  assert_eq(
    read_state_store_generation(restarted).unwrap(),
    Some("choir-durable-shape-aaaa"),
  )
  // Recording it again replaces rather than duplicating, so a restart that
  // rewrites the same value stays readable.
  guard write_state_store_generation(store, "choir-durable-shape-bbbb") is Ok(_) else {
    fail("rewrite generation")
  }
  assert_eq(
    read_state_store_generation(restarted).unwrap(),
    Some("choir-durable-shape-bbbb"),
  )
  // A file that is not a database at all must read as unreadable, not as a
  // store that simply records nothing. Adopting a corrupt store would keep
  // Choir running against state it cannot decode.
  let corrupt = storage_test_path("sqlite-corrupt.db")
  ignore(@sys.rm_rf(corrupt))
  ignore(@sys.write_file_sync(corrupt, "this is not a database"))
  assert_true(read_state_store_generation({ path: corrupt }) is Err(_))
  ignore(@sys.rm_rf(corrupt))
  ignore(@sys.rm_rf(path))
  ignore(@sys.rm_rf(path + "-shm"))
  ignore(@sys.rm_rf(path + "-wal"))
}

///|
/// The DDL version says which `CREATE TABLE` statements built these tables, and
/// it is stamped by the call that runs them — a store this build created can
/// therefore never be mistaken for one an older DDL built.
///
/// The other half matters more: re-running the schema over tables that already
/// exist must leave the stamp alone. `CREATE TABLE IF NOT EXISTS` does nothing
/// to a table whose columns are not these, so stamping there would overwrite
/// the only evidence that the tables on disk are not the ones this build's SQL
/// names, and every query would fail at runtime with the store reporting
/// itself current.
test "the DDL version is stamped by the statements it describes, once" {
  let path = storage_test_path("sqlite-ddl-version.db")
  let clean = fn() {
    ignore(@sys.rm_rf(path))
    ignore(@sys.rm_rf(path + "-shm"))
    ignore(@sys.rm_rf(path + "-wal"))
  }
  clean()
  let store : @storage.SqliteStateStore = { path, }
  guard initialize_state_store(store) is Ok(_) else {
    fail("initialize state store")
  }
  assert_eq(
    read_state_store_ddl_version(store).unwrap(),
    state_store_ddl_version(),
  )
  // Stand in for a store whose tables predate the stamp.
  guard write_state_store_ddl_version(
      store, @storage.control_store_unstamped_ddl_version,
    )
    is Ok(_) else {
    fail("clear the stamp")
  }
  // Drop the pooled connection so the schema batch actually runs again rather
  // than being skipped as already applied.
  forget_state_store(store)
  guard initialize_state_store(store) is Ok(_) else { fail("re-initialize") }
  assert_eq(
    read_state_store_ddl_version(store).unwrap(),
    @storage.control_store_unstamped_ddl_version,
  )
  // A file that is not a database at all is unreadable, not version 0: the two
  // call for opposite decisions.
  let corrupt = storage_test_path("sqlite-ddl-corrupt.db")
  ignore(@sys.rm_rf(corrupt))
  ignore(@sys.write_file_sync(corrupt, "this is not a database"))
  assert_true(read_state_store_ddl_version({ path: corrupt }) is Err(_))
  ignore(@sys.rm_rf(corrupt))
  // The writer refuses a version it could never mean, and a store carrying one
  // anyway reads as unreadable rather than as some version this build should
  // compare against.
  assert_true(write_state_store_ddl_version(store, -1) is Err(_))
  assert_eq(
    read_state_store_ddl_version(store).unwrap(),
    @storage.control_store_unstamped_ddl_version,
  )
  clean()
}

///|
/// The prefix filter is a half-open key range rather than a per-row function,
/// so it has to select exactly what the function form did — including not
/// matching a sibling prefix one byte higher.
test "a prefix listing selects its own keys and grows past one buffer" {
  let path = storage_test_path("sqlite-listing.db")
  ignore(@sys.rm_rf(path))
  ignore(@sys.rm_rf(path + "-shm"))
  ignore(@sys.rm_rf(path + "-wal"))
  let store : @storage.SqliteStateStore = { path, }
  guard initialize_state_store(store) is Ok(_) else {
    fail("initialize state store")
  }
  let write = fn(key : String) {
    let request = initial_state_request("listed:" + key, None)
    ignore(
      commit_state_transaction(store, {
        ..request,
        state: { ..request.state, key: @storage.StateRecordKey(key) },
        outbox: {
          ..request.outbox,
          semantic_key: @storage.SemanticEventKey("listed:" + key),
        },
      }).unwrap(),
    )
  }
  // Enough rows that the listing cannot fit the initial buffer, so the growth
  // path is exercised rather than merely present.
  for index = 0; index < 900; index = index + 1 {
    write("goal-run-" + index.to_string().pad_start(6, '0'))
  }
  // The range's upper bound is the prefix with its last byte incremented, and
  // '-' increments to '.', which is itself a legal key character. A key just
  // above the bound must not be swept in.
  write("goal-run.sibling")
  write("goal-run")
  write("other:thing")
  let listed = list_state_records(store, "goal-run-").unwrap()
  assert_eq(listed.length(), 900)
  for record in listed {
    assert_true(
      @storage.state_record_key_text(record.key).has_prefix("goal-run-"),
    )
  }
  // Ordering is still by key, which the runner relies on for determinism.
  assert_eq(@storage.state_record_key_text(listed[0].key), "goal-run-000000")
  assert_eq(@storage.state_record_key_text(listed[899].key), "goal-run-000899")
  ignore(@sys.rm_rf(path))
  ignore(@sys.rm_rf(path + "-shm"))
  ignore(@sys.rm_rf(path + "-wal"))
}

///|
/// Connections are pooled and the schema is applied once per connection, so a
/// store replaced at the same path has to drop its pooled connection first.
/// Otherwise the surviving connection serves the unlinked inode and the
/// replacement is never initialized.
test "a store replaced in place is reinitialized, not served from the old file" {
  let path = storage_test_path("sqlite-replaced.db")
  ignore(@sys.rm_rf(path))
  let store : @storage.SqliteStateStore = { path, }
  guard initialize_state_store(store) is Ok(_) else { fail("initialize") }
  guard write_state_store_generation(store, "before") is Ok(_) else {
    fail("write generation")
  }
  assert_eq(read_state_store_generation(store).unwrap(), Some("before"))
  // Replace the file exactly as the control-state reset does.
  forget_state_store(store)
  ignore(@sys.rm_rf(path))
  ignore(@sys.rm_rf(path + "-shm"))
  ignore(@sys.rm_rf(path + "-wal"))
  guard initialize_state_store(store) is Ok(_) else { fail("reinitialize") }
  // A fresh store, not the old one still being served through a stale handle.
  assert_eq(read_state_store_generation(store).unwrap(), None)
  let request = initial_state_request("replaced", None)
  assert_eq(
    commit_state_transaction(store, request).unwrap(),
    @storage.StateTransactionOutcome::StateTransactionCommitted,
  )
  ignore(@sys.rm_rf(path))
  ignore(@sys.rm_rf(path + "-shm"))
  ignore(@sys.rm_rf(path + "-wal"))
}

///|
/// Retention was recorded in a receipt and dropped, so nothing could ever
/// decide what was collectable. This drives the whole path against a real
/// store: adopt under different terms, sweep, and confirm only the expired
/// content is gone.
test "an artifact sweep collects only content whose every term expired" {
  let root = storage_test_path("artifact-sweep")
  ignore(@sys.rm_rf(root))
  let store : @storage.ArtifactStore = { root, }
  // A whole-store sweep is the ledger read, the sweep decision, and the
  // collection composed: the store executes what the decision names.
  let sweep = fn(now : Int64, goal_terminal : (@control.GoalId) -> Bool) {
    collect_artifacts(
      store,
      @storage.plan_artifact_sweep(
        read_artifact_retention_ledger(store),
        now,
        goal_terminal,
      ).collect,
    )
  }
  let adopt = fn(content : String, retention : @storage.ArtifactRetention) {
    let bytes = @utf8.encode(content)
    adopt_artifact(store, {
      content: bytes,
      expected_digest: @storage.artifact_digest(bytes),
      provenance: @storage.ArtifactProvenance::ArtifactConformanceEvidence,
      retention,
    }).unwrap()
  }
  let permanent = adopt(
    "keep me",
    @storage.ArtifactRetention::ArtifactPermanent,
  )
  let expiring = adopt(
    "collect me",
    @storage.ArtifactRetention::ArtifactUntilTimestamp(1_000L),
  )
  // The same bytes adopted twice under different terms must survive both.
  let shared_bytes = @utf8.encode("shared")
  let shared = @storage.artifact_digest(shared_bytes)
  ignore(
    adopt("shared", @storage.ArtifactRetention::ArtifactUntilTimestamp(1_000L)),
  )
  ignore(
    adopt(
      "shared",
      @storage.ArtifactRetention::ArtifactUntilGoalTerminal(
        @control.GoalId("goal-live"),
      ),
    ),
  )
  // Before the deadline nothing is collectable.
  assert_eq(sweep(999L, fn(_) { false }).unwrap(), 0)
  assert_true(artifact_store_contains(store, expiring.digest).unwrap())

  // Past it, the timestamped one goes; the permanent one and the one still
  // held by a live Goal stay.
  assert_eq(sweep(1_000L, fn(_) { false }).unwrap(), 1)
  assert_false(artifact_store_contains(store, expiring.digest).unwrap())
  assert_true(artifact_store_contains(store, permanent.digest).unwrap())
  assert_true(artifact_store_contains(store, shared).unwrap())

  // Once the Goal is terminal too, the shared content becomes collectable.
  assert_eq(sweep(1_000L, fn(_) { true }).unwrap(), 1)
  assert_false(artifact_store_contains(store, shared).unwrap())
  assert_true(artifact_store_contains(store, permanent.digest).unwrap())

  // Sweeping again is a no-op rather than an error, so a rerun after a crash
  // converges.
  assert_eq(sweep(2_000L, fn(_) { true }).unwrap(), 0)
  ignore(@sys.rm_rf(root))
}

///|
/// The count a collection reports is what it released, not what it was asked to
/// release.
///
/// Content removal happens before the ledger rewrite, so an archive interrupted
/// between them is asked for the same digests again on the next run. Removing
/// content that is already gone still has to succeed — that is what makes the
/// rerun converge — but counting it as released tells an operator space was
/// reclaimed that the interrupted run reclaimed already.
test "a collection counts the content it removed, not the content it was named" {
  let root = storage_test_path("artifact-recollect")
  ignore(@sys.rm_rf(root))
  let store : @storage.ArtifactStore = { root, }
  let content = @utf8.encode("collect me twice")
  let digest = @storage.artifact_digest(content)
  guard adopt_artifact(store, {
      content,
      expected_digest: digest,
      provenance: @storage.ArtifactProvenance::ArtifactConformanceEvidence,
      retention: @storage.ArtifactRetention::ArtifactUntilTimestamp(1_000L),
    })
    is Ok(_) else {
    fail("adopt collectable content")
  }
  assert_eq(collect_artifacts(store, [digest]).unwrap(), 1)
  assert_false(artifact_store_contains(store, digest).unwrap())
  // The rerun: same digests, nothing left to release.
  assert_eq(collect_artifacts(store, [digest]).unwrap(), 0)
  ignore(@sys.rm_rf(root))
}

///|
/// A durable process execution this build reads without complaint.
fn control_probe_execution(suffix : String) -> @sandbox.ProcessExecution {
  {
    execution_id: @sandbox.ProcessExecutionId("execution-" + suffix),
    effect_intent_id: @control.EffectId("effect-" + suffix),
    runtime_execution_key: @sandbox.RuntimeExecutionKey("runtime-" + suffix),
    take_id: @control.TakeId("take-" + suffix),
    process_authority: @sandbox.SandboxProcessAuthority::SandboxImplementationTool(
      @control.TakeId("take-" + suffix),
      store_digest_a,
    ),
    validated_process_spec_digest: store_digest_a,
    sandbox_lease_id: @control.SandboxLeaseId("lease-" + suffix),
    sandbox_generation_id: @control.SandboxGenerationId("generation-" + suffix),
    capability_profile_digest: store_digest_b,
    input_artifact_set_digest: store_digest_c,
    output_artifact_set_digest: None,
    started_at: None,
    finished_at: None,
    disposition: @sandbox.ProcessExecutionDisposition::ProcessStartPlanned,
  }
}

///|
/// Put one durable record in the control store: the content in the artifact
/// store, and a state record pointing at it. Content of `None` records a state
/// row whose content was never adopted.
fn control_probe_record(
  control_root : String,
  key : String,
  content : Bytes?,
) -> Unit raise {
  let digest = match content {
    Some(bytes) => @storage.artifact_digest(bytes)
    None => store_digest_a
  }
  let adopted = match content {
    Some(bytes) =>
      adopt_artifact({ root: control_root + "/artifacts" }, {
        content: bytes,
        expected_digest: digest,
        provenance: @storage.ArtifactProvenance::ArtifactConformanceEvidence,
        retention: @storage.ArtifactRetention::ArtifactPermanent,
      })
      is Ok(_)
    None => true
  }
  guard adopted else { fail("adopt durable record content") }
  guard commit_state_transaction({ path: control_root + "/workflow.db" }, {
      state: {
        key: @storage.StateRecordKey(key),
        expected_version: None,
        next_version: 1,
        fencing_epoch: @control.FencingEpoch(1L),
        schedule_class: @storage.StateRecordScheduleClass::StateRecordNotSchedulable,
        value_digest: digest,
      },
      outbox: {
        semantic_key: @storage.SemanticEventKey(key + ":state:1"),
        payload_digest: digest,
        owner_goal_id: None,
      },
      fault_point: None,
    })
    is Ok(_) else {
    fail("commit durable record")
  }
}

///|
/// The generation is a digest, so it reports only "different". Whether a
/// different generation matters is answered by reading the records, and only a
/// record this build cannot decode answers yes.
test "the record scan names only a record this build cannot decode" {
  let control_root = storage_test_path("control-probe")
  ignore(@sys.rm_rf(control_root))
  guard @sys.create_dir_all(control_root) else { fail("create control root") }
  guard initialize_state_store({ path: control_root + "/workflow.db" }) is Ok(_) else {
    fail("initialize state store")
  }
  // Nothing stored yet: nothing can be evidence of anything.
  assert_true(probe_native_durable_record_decoding(control_root) is Ok(None))
  let prefix = @workflow.durable_record_key_prefix(
    @workflow.DurableRecordKind::DurableProcessExecution,
  )
  control_probe_record(
    control_root,
    prefix + "readable",
    Some(
      @utf8.encode(
        control_probe_execution("readable").to_json().stringify(indent=0),
      ),
    ),
  )
  assert_true(probe_native_durable_record_decoding(control_root) is Ok(None))

  // Content that is not in the store cannot demonstrate that the shapes moved
  // incompatibly, and this evidence authorizes deleting the whole store.
  control_probe_record(control_root, prefix + "missing", None)
  assert_true(probe_native_durable_record_decoding(control_root) is Ok(None))

  // A record that is present and does not decode is the evidence.
  control_probe_record(control_root, prefix + "broken", Some(b"{}"))
  assert_eq(
    probe_native_durable_record_decoding(control_root).unwrap(),
    Some(@storage.StateRecordKey(prefix + "broken")),
  )
  ignore(@sys.rm_rf(control_root))
}

///|
/// The regression this guards: every additive shape change moves the derived
/// generation, and treating a moved generation as authority to destroy would
/// release source claims, purge Choir's whole git ref namespace, remove runtime
/// roots and delete the control root — on records that read perfectly well.
///
/// The two effects that outlive the control root — releasing Bead claims and
/// purging refs — are injected and counted, so the assertion is that they were
/// not reached at all rather than that nothing observable happened.
async test "a store from another generation whose records read is adopted" {
  let reached : Array[String] = []
  let project_dir = storage_test_path("control-adopt")
  let control_root = project_dir + "/.choir/state/control"
  ignore(@sys.rm_rf(project_dir))
  guard @sys.create_dir_all(control_root) else { fail("create control root") }
  guard initialize_state_store({ path: control_root + "/workflow.db" }) is Ok(_) else {
    fail("initialize state store")
  }
  guard write_state_store_generation(
      { path: control_root + "/workflow.db" },
      "choir-durable-shape-from-an-older-build",
    )
    is Ok(_) else {
    fail("record an older generation")
  }
  let prefix = @workflow.durable_record_key_prefix(
    @workflow.DurableRecordKind::DurableProcessExecution,
  )
  control_probe_record(
    control_root,
    prefix + "readable",
    Some(
      @utf8.encode(
        control_probe_execution("readable").to_json().stringify(indent=0),
      ),
    ),
  )
  let prepared = prepare_native_goal_control_state(
    project_dir,
    capture=fn(command) {
      reached.push("capture:" + command.args[0])
      (0, "[]")
    },
    cleanup_runtime=fn(_, goal_id) {
      reached.push("runtime:" + goal_id.0)
      Ok(())
    },
    purge_refs=fn(_) {
      reached.push("refs")
      Ok(0)
    },
  )
  assert_eq(prepared.unwrap(), NativeGoalControlStateCurrent)
  assert_eq(reached, [])
  // Adopted, not rebuilt: the record is still there and the store now answers
  // to this build's generation, so restarting is a no-op.
  assert_eq(
    read_state_store_generation({ path: control_root + "/workflow.db" }).unwrap(),
    Some(@workflow.durable_value_shape_generation()),
  )
  assert_eq(
    list_state_records({ path: control_root + "/workflow.db" }, prefix)
    .unwrap()
    .length(),
    1,
  )
  ignore(@sys.rm_rf(project_dir))
}

///|
/// The other half: a stored record this build cannot decode is the one thing
/// that authorizes the destructive branch, and when it fires the report names
/// the record rather than leaving an operator with a deleted control root and a
/// pair of digests.
async test "a record this build cannot decode authorizes the reset" {
  let reached : Array[String] = []
  let project_dir = storage_test_path("control-reset")
  let control_root = project_dir + "/.choir/state/control"
  let store : @storage.SqliteStateStore = {
    path: control_root + "/workflow.db",
  }
  ignore(@sys.rm_rf(project_dir))
  guard @sys.create_dir_all(control_root) else { fail("create control root") }
  guard initialize_state_store(store) is Ok(_) else {
    fail("initialize state store")
  }
  guard write_state_store_generation(
      store, "choir-durable-shape-from-an-older-build",
    )
    is Ok(_) else {
    fail("record an older generation")
  }
  let prefix = @workflow.durable_record_key_prefix(
    @workflow.DurableRecordKind::DurableProcessExecution,
  )
  control_probe_record(control_root, prefix + "broken", Some(b"{}"))
  let prepared = prepare_native_goal_control_state(
    project_dir,
    capture=fn(command) {
      reached.push("beads:" + command.args[0])
      if command.args[0] == "list" {
        (
          0,
          (
            #|[{"id":"claimed-part","title":"Claimed","status":"in_progress","assignee":"choir:goal-reset"}]
          ),
        )
      } else {
        (
          0,
          (
            #|[{"id":"claimed-part","title":"Claimed","status":"open","assignee":""}]
          ),
        )
      }
    },
    cleanup_runtime=fn(_, goal_id) {
      reached.push("runtime:" + goal_id.0)
      Ok(())
    },
    purge_refs=fn(_) {
      reached.push("refs")
      Ok(3)
    },
  )
  assert_eq(
    prepared.unwrap(),
    NativeGoalControlStatePreparation::NativeGoalControlStateReset({
      source_claims_released: 1,
      runtime_roots_removed: 0,
      git_refs_removed: 3,
      reason: @storage.ControlStateResetReason::ControlRecordUndecodable(
        @storage.StateRecordKey(prefix + "broken"),
        "choir-durable-shape-from-an-older-build",
        @workflow.durable_value_shape_generation(),
      ),
    }),
  )
  @debug.assert_eq(reached, [
    "beads:list", "runtime:goal-reset", "refs", "beads:update",
  ])
  // Rebuilt, not adopted: the record this build could not read is gone and the
  // fresh store answers to this build's generation.
  assert_eq(list_state_records(store, prefix).unwrap().length(), 0)
  assert_eq(
    read_state_store_generation(store).unwrap(),
    Some(@workflow.durable_value_shape_generation()),
  )
  ignore(@sys.rm_rf(project_dir))
}

///|
/// A matching generation stamp cannot override what the real record decoder
/// says. This is the live failure: startup accepted the stamp, then the same
/// retained row made every portfolio tick fail before any Goal could advance.
async test "a current stamp with an undecodable record authorizes the reset" {
  let reached : Array[String] = []
  let project_dir = storage_test_path("control-current-record-reset")
  let control_root = project_dir + "/.choir/state/control"
  let store : @storage.SqliteStateStore = {
    path: control_root + "/workflow.db",
  }
  ignore(@sys.rm_rf(project_dir))
  guard @sys.create_dir_all(control_root) else { fail("create control root") }
  guard initialize_state_store(store) is Ok(_) else {
    fail("initialize state store")
  }
  guard write_state_store_generation(
      store,
      @workflow.durable_value_shape_generation(),
    )
    is Ok(_) else {
    fail("record this build's generation")
  }
  let prefix = @workflow.durable_record_key_prefix(
    @workflow.DurableRecordKind::DurableGoalExecutionRecord,
  )
  control_probe_record(control_root, prefix + "stale", Some(b"{}"))
  let prepared = prepare_native_goal_control_state(
    project_dir,
    capture=fn(command) {
      reached.push("beads:" + command.args[0])
      (0, "[]")
    },
    cleanup_runtime=fn(_, goal_id) {
      reached.push("runtime:" + goal_id.0)
      Ok(())
    },
    purge_refs=fn(_) {
      reached.push("refs")
      Ok(2)
    },
  )
  assert_eq(
    prepared.unwrap(),
    NativeGoalControlStatePreparation::NativeGoalControlStateReset({
      source_claims_released: 0,
      runtime_roots_removed: 0,
      git_refs_removed: 2,
      reason: @storage.ControlStateResetReason::ControlRecordUndecodable(
        @storage.StateRecordKey(prefix + "stale"),
        @workflow.durable_value_shape_generation(),
        @workflow.durable_value_shape_generation(),
      ),
    }),
  )
  @debug.assert_eq(reached, ["beads:list", "refs"])
  assert_eq(list_state_records(store, prefix).unwrap().length(), 0)
  assert_eq(
    read_state_store_generation(store).unwrap(),
    Some(@workflow.durable_value_shape_generation()),
  )
  ignore(@sys.rm_rf(project_dir))
}

///|
/// Revalidating a current store is observational when its rows still decode.
async test "a current stamp with a decodable record remains untouched" {
  let reached : Array[String] = []
  let project_dir = storage_test_path("control-current-record-keep")
  let control_root = project_dir + "/.choir/state/control"
  let store : @storage.SqliteStateStore = {
    path: control_root + "/workflow.db",
  }
  ignore(@sys.rm_rf(project_dir))
  guard @sys.create_dir_all(control_root) else { fail("create control root") }
  guard initialize_state_store(store) is Ok(_) else {
    fail("initialize state store")
  }
  write_state_store_generation(
    store,
    @workflow.durable_value_shape_generation(),
  ).unwrap()
  let prefix = @workflow.durable_record_key_prefix(
    @workflow.DurableRecordKind::DurableProcessExecution,
  )
  control_probe_record(
    control_root,
    prefix + "current",
    Some(
      @utf8.encode(
        control_probe_execution("current").to_json().stringify(indent=0),
      ),
    ),
  )
  let prepared = prepare_native_goal_control_state(
    project_dir,
    capture=fn(_) {
      reached.push("claims")
      (0, "[]")
    },
    cleanup_runtime=fn(_, _) {
      reached.push("runtime")
      Ok(())
    },
    purge_refs=fn(_) {
      reached.push("refs")
      Ok(0)
    },
  )
  assert_eq(prepared.unwrap(), NativeGoalControlStateCurrent)
  assert_eq(reached, [])
  assert_eq(list_state_records(store, prefix).unwrap().length(), 1)
  ignore(@sys.rm_rf(project_dir))
}

///|
/// The failure the DDL version exists for, driven end to end.
///
/// The store here is healthy by every other measure: its generation is exactly
/// this build's and its one record decodes, so the record probe would report
/// nothing wrong. Only the DDL version says its tables were built by
/// statements this build does not write SQL against — and once they were, every
/// query naming a column those tables lack fails at runtime, with no record
/// ever read and no reset ever reached.
async test "tables built by a superseded DDL authorize the reset" {
  let reached : Array[String] = []
  let project_dir = storage_test_path("control-ddl-reset")
  let control_root = project_dir + "/.choir/state/control"
  let store : @storage.SqliteStateStore = {
    path: control_root + "/workflow.db",
  }
  ignore(@sys.rm_rf(project_dir))
  guard @sys.create_dir_all(control_root) else { fail("create control root") }
  guard initialize_state_store(store) is Ok(_) else {
    fail("initialize state store")
  }
  guard write_state_store_generation(
      store,
      @workflow.durable_value_shape_generation(),
    )
    is Ok(_) else {
    fail("record this build's generation")
  }
  let superseded = state_store_ddl_version() + 1
  guard write_state_store_ddl_version(store, superseded) is Ok(_) else {
    fail("record another DDL version")
  }
  let prefix = @workflow.durable_record_key_prefix(
    @workflow.DurableRecordKind::DurableProcessExecution,
  )
  control_probe_record(
    control_root,
    prefix + "readable",
    Some(
      @utf8.encode(
        control_probe_execution("readable").to_json().stringify(indent=0),
      ),
    ),
  )
  let prepared = prepare_native_goal_control_state(
    project_dir,
    capture=fn(_) {
      reached.push("capture")
      (0, "[]")
    },
    cleanup_runtime=fn(_, goal_id) {
      reached.push("runtime:" + goal_id.0)
      Ok(())
    },
    purge_refs=fn(_) {
      reached.push("refs")
      Ok(2)
    },
  )
  assert_eq(
    prepared.unwrap(),
    NativeGoalControlStatePreparation::NativeGoalControlStateReset({
      source_claims_released: 0,
      runtime_roots_removed: 0,
      git_refs_removed: 2,
      reason: @storage.ControlStateResetReason::ControlStoreDdlSuperseded(
        superseded,
        state_store_ddl_version(),
      ),
    }),
  )
  assert_true(reached.contains("refs"))
  // Rebuilt by this build's statements, and stamped by them.
  assert_eq(list_state_records(store, prefix).unwrap().length(), 0)
  assert_eq(
    read_state_store_ddl_version(store).unwrap(),
    state_store_ddl_version(),
  )
  ignore(@sys.rm_rf(project_dir))
}

///|
/// The other direction, which is the one every store in existence takes the
/// first time this build starts: tables that predate the stamp are the tables
/// this DDL creates, so they are stamped rather than destroyed. Not stamping
/// them would leave the version at 0 forever and never load-bearing for them.
async test "tables that predate the DDL stamp are stamped, not destroyed" {
  let reached : Array[String] = []
  let project_dir = storage_test_path("control-ddl-adopt")
  let control_root = project_dir + "/.choir/state/control"
  let store : @storage.SqliteStateStore = {
    path: control_root + "/workflow.db",
  }
  ignore(@sys.rm_rf(project_dir))
  guard @sys.create_dir_all(control_root) else { fail("create control root") }
  guard initialize_state_store(store) is Ok(_) else {
    fail("initialize state store")
  }
  guard write_state_store_generation(
      store,
      @workflow.durable_value_shape_generation(),
    )
    is Ok(_) else {
    fail("record this build's generation")
  }
  guard write_state_store_ddl_version(
      store, @storage.control_store_unstamped_ddl_version,
    )
    is Ok(_) else {
    fail("clear the stamp")
  }
  let prefix = @workflow.durable_record_key_prefix(
    @workflow.DurableRecordKind::DurableProcessExecution,
  )
  control_probe_record(
    control_root,
    prefix + "readable",
    Some(
      @utf8.encode(
        control_probe_execution("readable").to_json().stringify(indent=0),
      ),
    ),
  )
  let prepared = prepare_native_goal_control_state(
    project_dir,
    capture=fn(_) {
      reached.push("capture")
      (0, "[]")
    },
    cleanup_runtime=fn(_, goal_id) {
      reached.push("runtime:" + goal_id.0)
      Ok(())
    },
    purge_refs=fn(_) {
      reached.push("refs")
      Ok(0)
    },
  )
  assert_eq(prepared.unwrap(), NativeGoalControlStateCurrent)
  assert_eq(reached, [])
  assert_eq(list_state_records(store, prefix).unwrap().length(), 1)
  assert_eq(
    read_state_store_ddl_version(store).unwrap(),
    state_store_ddl_version(),
  )
  ignore(@sys.rm_rf(project_dir))
}
