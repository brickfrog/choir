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
      @storage_host.adopt_artifact({ root: control_root + "/artifacts" }, {
        content: bytes,
        expected_digest: digest,
        provenance: @storage.ArtifactProvenance::ArtifactConformanceEvidence,
        retention: @storage.ArtifactRetention::ArtifactPermanent,
      })
      is Ok(_)
    None => true
  }
  guard adopted else { fail("adopt durable record content") }
  guard @storage_host.commit_state_transaction(
      { path: control_root + "/workflow.db" },
      {
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
      },
    )
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
  guard @storage_host.initialize_state_store({
      path: control_root + "/workflow.db",
    })
    is Ok(_) else {
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
  guard @storage_host.initialize_state_store({
      path: control_root + "/workflow.db",
    })
    is Ok(_) else {
    fail("initialize state store")
  }
  guard @storage_host.write_state_store_generation(
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
    @storage_host.read_state_store_generation({
      path: control_root + "/workflow.db",
    }).unwrap(),
    Some(@workflow.durable_value_shape_generation()),
  )
  assert_eq(
    @storage_host.list_state_records(
      { path: control_root + "/workflow.db" },
      prefix,
    )
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
  guard @storage_host.initialize_state_store(store) is Ok(_) else {
    fail("initialize state store")
  }
  guard @storage_host.write_state_store_generation(
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
  assert_eq(
    @storage_host.list_state_records(store, prefix).unwrap().length(),
    0,
  )
  assert_eq(
    @storage_host.read_state_store_generation(store).unwrap(),
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
  guard @storage_host.initialize_state_store(store) is Ok(_) else {
    fail("initialize state store")
  }
  guard @storage_host.write_state_store_generation(
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
  assert_eq(
    @storage_host.list_state_records(store, prefix).unwrap().length(),
    0,
  )
  assert_eq(
    @storage_host.read_state_store_generation(store).unwrap(),
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
  guard @storage_host.initialize_state_store(store) is Ok(_) else {
    fail("initialize state store")
  }
  @storage_host.write_state_store_generation(
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
  assert_eq(
    @storage_host.list_state_records(store, prefix).unwrap().length(),
    1,
  )
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
  guard @storage_host.initialize_state_store(store) is Ok(_) else {
    fail("initialize state store")
  }
  guard @storage_host.write_state_store_generation(
      store,
      @workflow.durable_value_shape_generation(),
    )
    is Ok(_) else {
    fail("record this build's generation")
  }
  let superseded = @storage_host.state_store_ddl_version() + 1
  guard @storage_host.write_state_store_ddl_version(store, superseded) is Ok(_) else {
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
        @storage_host.state_store_ddl_version(),
      ),
    }),
  )
  assert_true(reached.contains("refs"))
  // Rebuilt by this build's statements, and stamped by them.
  assert_eq(
    @storage_host.list_state_records(store, prefix).unwrap().length(),
    0,
  )
  assert_eq(
    @storage_host.read_state_store_ddl_version(store).unwrap(),
    @storage_host.state_store_ddl_version(),
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
  guard @storage_host.initialize_state_store(store) is Ok(_) else {
    fail("initialize state store")
  }
  guard @storage_host.write_state_store_generation(
      store,
      @workflow.durable_value_shape_generation(),
    )
    is Ok(_) else {
    fail("record this build's generation")
  }
  guard @storage_host.write_state_store_ddl_version(
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
  assert_eq(
    @storage_host.list_state_records(store, prefix).unwrap().length(),
    1,
  )
  assert_eq(
    @storage_host.read_state_store_ddl_version(store).unwrap(),
    @storage_host.state_store_ddl_version(),
  )
  ignore(@sys.rm_rf(project_dir))
}
