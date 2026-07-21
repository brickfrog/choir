///|
priv struct NativeStoredProcessExecution {
  state_record : @storage.StateRecord
  execution : @sandbox.ProcessExecution
} derive(Debug, Eq)

///|
enum NativeProcessFaultPoint {
  ProcessAfterPlannedBeforeAuthorization
  ProcessAfterAuthorizationBeforeDispatch
  ProcessAfterDispatchBeforeTerminalPersistence
  ProcessAfterTerminalPersistenceBeforeReturn
} derive(Debug, Eq)

///|
priv struct NativeProcessExecutionAdapters {
  execute : async () -> Result[NativeSandboxProcessResult, @types.ChoirError]
  retire_generation : async () -> Result[Unit, @types.ChoirError]
  fault_enabled : (NativeProcessFaultPoint) -> Bool
}

///|
fn native_process_execution_error(message : String) -> @types.ChoirError {
  @types.ChoirError::workspace_error("native process execution: " + message)
}

///|
fn native_process_state_key(
  execution_id : @sandbox.ProcessExecutionId,
) -> @storage.StateRecordKey {
  @storage.StateRecordKey("process-execution:" + execution_id.0)
}

///|
fn native_process_event_key(
  execution_id : @sandbox.ProcessExecutionId,
  version : Int,
) -> @storage.SemanticEventKey {
  @storage.SemanticEventKey(
    "process-execution:" + execution_id.0 + ":state:" + version.to_string(),
  )
}

///|
fn load_native_process_execution(
  runtime : NativePartEffectRuntime,
  execution_id : @sandbox.ProcessExecutionId,
) -> Result[NativeStoredProcessExecution?, @types.ChoirError] {
  let record = match
    (runtime.config.repository_adapters.state.read_state)(
      runtime.config.repository.state_store,
      native_process_state_key(execution_id),
    ) {
    Ok(Some(value)) => value
    Ok(None) => return Ok(None)
    Err(error) => return Err(error)
  }
  let content = match
    (runtime.config.repository_adapters.artifacts.read)(
      runtime.config.repository.artifact_store,
      {
        digest: record.value_digest,
        max_bytes: runtime.config.repository.max_snapshot_bytes,
      },
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if @storage.artifact_digest(content) != record.value_digest {
    return Err(
      native_process_execution_error("durable content digest is false"),
    )
  }
  let json = @json.parse(@utf8.decode(content)) catch {
    _ =>
      return Err(native_process_execution_error("durable content is not JSON"))
  }
  let execution : @sandbox.ProcessExecution = @json.from_json(json) catch {
    _ => return Err(native_process_execution_error("durable schema is invalid"))
  }
  match @sandbox.validate_process_execution(execution) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if execution.execution_id != execution_id || record.fencing_epoch.0 <= 0L {
    Err(native_process_execution_error("durable identity is inconsistent"))
  } else {
    Ok(Some({ state_record: record, execution }))
  }
}

///|
fn persist_native_process_execution(
  runtime : NativePartEffectRuntime,
  goal_id : @control.GoalId,
  fencing_epoch : @control.FencingEpoch,
  execution : @sandbox.ProcessExecution,
  expected_version : Int?,
) -> Result[NativeStoredProcessExecution, @types.ChoirError] {
  match @sandbox.validate_process_execution(execution) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match load_native_process_execution(runtime, execution.execution_id) {
    Ok(Some(stored)) if stored.execution == execution => return Ok(stored)
    Ok(Some(_)) => ()
    Ok(None) => ()
    Err(error) => return Err(error)
  }
  let content = @utf8.encode(execution.to_json().stringify(indent=0))
  if content.length() > runtime.config.repository.max_snapshot_bytes {
    return Err(native_process_execution_error("durable content is too large"))
  }
  let digest = @storage.artifact_digest(content)
  let adoption = match
    (runtime.config.repository_adapters.artifacts.adopt)(
      runtime.config.repository.artifact_store,
      {
        content,
        expected_digest: digest,
        provenance: @storage.ArtifactProvenance::ArtifactProcessExecution(
          goal_id,
        ),
        retention: @storage.ArtifactRetention::ArtifactUntilGoalTerminal(
          goal_id,
        ),
      },
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if adoption.digest != digest || adoption.byte_length != content.length() {
    return Err(native_process_execution_error("artifact receipt is false"))
  }
  let next_version = expected_version.unwrap_or(0) + 1
  let outcome = match
    (runtime.config.repository_adapters.state.commit)(
      runtime.config.repository.state_store,
      {
        state: {
          key: native_process_state_key(execution.execution_id),
          expected_version,
          next_version,
          fencing_epoch,
          value_digest: digest,
        },
        outbox: {
          semantic_key: native_process_event_key(
            execution.execution_id,
            next_version,
          ),
          payload_digest: digest,
        },
        fault_point: None,
      },
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match outcome {
    @storage.StateTransactionOutcome::StateTransactionCommitted
    | @storage.StateTransactionOutcome::StateTransactionReplayed
    | @storage.StateTransactionOutcome::StateTransactionCommittedAckLost
    | @storage.StateTransactionOutcome::StateTransactionVersionConflict =>
      match load_native_process_execution(runtime, execution.execution_id) {
        Ok(Some(stored)) if stored.execution == execution => Ok(stored)
        Ok(_) =>
          Err(native_process_execution_error("state transition conflicted"))
        Err(error) => Err(error)
      }
    @storage.StateTransactionOutcome::StateTransactionStaleFence =>
      Err(native_process_execution_error("fencing conflict"))
    @storage.StateTransactionOutcome::StateTransactionSemanticConflict =>
      Err(native_process_execution_error("semantic event conflict"))
    @storage.StateTransactionOutcome::StateTransactionFaultRolledBack(_) =>
      Err(native_process_execution_error("state transition rolled back"))
  }
}

///|
fn native_process_execution_id(
  effect_intent_id : String,
  discriminator : String,
) -> @sandbox.ProcessExecutionId {
  let suffix = if discriminator == "" { "" } else { "." + discriminator }
  @sandbox.ProcessExecutionId(effect_intent_id + ".process" + suffix)
}

///|
fn native_process_lease(
  snapshot : @workflow.PartWorkflowSnapshot,
  take_id : @control.TakeId,
  generation_id : @control.SandboxGenerationId,
) -> Result[@control.SandboxLease, @types.ChoirError] {
  for lease in snapshot.sandbox_leases {
    if lease.take_id == take_id && lease.generation_id == generation_id {
      return if lease.lifecycle ==
        @control.SandboxLeaseLifecycle::SandboxLeaseActive {
        Ok(lease)
      } else {
        Err(native_process_execution_error("sandbox lease is not active"))
      }
    }
  }
  Err(native_process_execution_error("sandbox lease is missing"))
}

///|
fn planned_native_process_execution(
  effect_intent_id : String,
  execution_id : @sandbox.ProcessExecutionId,
  take_id : @control.TakeId,
  session : @control.HarnessSession,
  lease : @control.SandboxLease,
  process_digest : @control.Digest,
  process : @sandbox.SandboxProcessSpec,
) -> Result[@sandbox.ProcessExecution, @types.ChoirError] {
  if session.take_id != take_id {
    return Err(native_process_execution_error("session does not own the Take"))
  }
  if lease.take_id != take_id ||
    lease.generation_id != session.sandbox_generation_id ||
    lease.lifecycle != @control.SandboxLeaseLifecycle::SandboxLeaseActive {
    return Err(native_process_execution_error("sandbox lease is not active"))
  }
  let execution : @sandbox.ProcessExecution = {
    execution_id,
    effect_intent_id,
    runtime_execution_key: @sandbox.RuntimeExecutionKey(execution_id.0),
    take_id,
    process_authority: process.authority,
    validated_process_spec_digest: process_digest,
    sandbox_lease_id: lease.id,
    sandbox_generation_id: lease.generation_id,
    capability_profile_digest: lease.capability_profile_digest,
    input_artifact_set_digest: @storage.artifact_digest(
      @utf8.encode(
        "choir.process-input-set.v1\u{00}" +
        process_digest.0 +
        "\u{00}" +
        lease.generation_id.0,
      ),
    ),
    output_artifact_set_digest: None,
    started_at: None,
    finished_at: None,
    disposition: @sandbox.ProcessExecutionDisposition::ProcessStartPlanned,
  }
  match @sandbox.validate_process_execution(execution) {
    Ok(_) => Ok(execution)
    Err(error) => Err(error)
  }
}

///|
fn native_process_identity_matches(
  actual : @sandbox.ProcessExecution,
  expected : @sandbox.ProcessExecution,
) -> Bool {
  {
    ..actual,
    output_artifact_set_digest: None,
    started_at: None,
    finished_at: None,
    disposition: @sandbox.ProcessExecutionDisposition::ProcessStartPlanned,
  } ==
  expected
}

///|
async fn execute_durable_native_process_with(
  runtime : NativePartEffectRuntime,
  goal_id : @control.GoalId,
  fencing_epoch : @control.FencingEpoch,
  effect_intent_id : String,
  discriminator : String,
  take_id : @control.TakeId,
  session : @control.HarnessSession,
  lease : @control.SandboxLease,
  persisted_process_spec_digest : @control.Digest,
  process : @sandbox.SandboxProcessSpec,
  adapters : NativeProcessExecutionAdapters,
) -> Result[NativeSandboxProcessResult, @types.ChoirError] {
  let planned = match
    planned_native_process_execution(
      effect_intent_id,
      native_process_execution_id(effect_intent_id, discriminator),
      take_id,
      session,
      lease,
      persisted_process_spec_digest,
      process,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if (adapters.fault_enabled)(ProcessAfterPlannedBeforeAuthorization) {
    return Err(native_process_execution_error("fault after planned process"))
  }
  let initial = match
    load_native_process_execution(runtime, planned.execution_id) {
    Ok(Some(stored)) => {
      if !native_process_identity_matches(stored.execution, planned) {
        return Err(
          native_process_execution_error("persisted identity conflicts"),
        )
      }
      stored
    }
    Ok(None) =>
      match
        persist_native_process_execution(
          runtime,
          goal_id,
          fencing_epoch,
          planned,
          None,
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
    Err(error) => return Err(error)
  }
  match initial.execution.disposition {
    @sandbox.ProcessExecutionDisposition::ProcessExited(
      exit_code,
      output_digest
    ) =>
      return Ok({
        exit_code,
        output: "",
        output_digest,
        started_at: initial.execution.started_at,
        finished_at: initial.execution.finished_at,
      })
    @sandbox.ProcessExecutionDisposition::ProcessStartMayHaveOccurred
    | @sandbox.ProcessExecutionDisposition::ProcessStartUncertain
    | @sandbox.ProcessExecutionDisposition::ProcessTimedOut
    | @sandbox.ProcessExecutionDisposition::ProcessLimitExceeded
    | @sandbox.ProcessExecutionDisposition::ProcessInterrupted
    | @sandbox.ProcessExecutionDisposition::ProcessSandboxLost =>
      return Err(
        @types.ChoirError::provider_process_lost(
          "guest process start cannot be adopted by the pinned BoxLite server",
        ),
      )
    @sandbox.ProcessExecutionDisposition::ProcessStartPlanned => ()
  }
  let authorized = match
    @sandbox.authorize_process_start(initial.execution, (runtime.config.now)()) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let authorized_store = match
    persist_native_process_execution(
      runtime,
      goal_id,
      fencing_epoch,
      authorized,
      Some(initial.state_record.version),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if (adapters.fault_enabled)(ProcessAfterAuthorizationBeforeDispatch) {
    return Err(native_process_execution_error("fault before process dispatch"))
  }
  let result = match (adapters.execute)() {
    Ok(value) => value
    Err(_) => {
      match (adapters.retire_generation)() {
        Ok(_) => ()
        Err(error) => return Err(error)
      }
      let uncertain = match
        @sandbox.record_unadoptable_process_start(
          authorized,
          (runtime.config.now)(),
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      match
        persist_native_process_execution(
          runtime,
          goal_id,
          fencing_epoch,
          uncertain,
          Some(authorized_store.state_record.version),
        ) {
        Ok(_) => ()
        Err(error) => return Err(error)
      }
      return Err(
        @types.ChoirError::provider_process_lost(
          "guest process result was not durably observed",
        ),
      )
    }
  }
  if (adapters.fault_enabled)(ProcessAfterDispatchBeforeTerminalPersistence) {
    return Err(native_process_execution_error("fault after process dispatch"))
  }
  let terminal = match
    @sandbox.record_process_exit(
      authorized,
      result.exit_code,
      result.output_digest,
      (runtime.config.now)(),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let stored = match
    persist_native_process_execution(
      runtime,
      goal_id,
      fencing_epoch,
      terminal,
      Some(authorized_store.state_record.version),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  ignore(stored)
  if (adapters.fault_enabled)(ProcessAfterTerminalPersistenceBeforeReturn) {
    return Err(native_process_execution_error("fault after process terminal"))
  }
  Ok({
    ..result,
    started_at: terminal.started_at,
    finished_at: terminal.finished_at,
  })
}

///|
async fn execute_durable_native_process(
  runtime : NativePartEffectRuntime,
  goal_id : @control.GoalId,
  fencing_epoch : @control.FencingEpoch,
  effect_intent_id : String,
  discriminator : String,
  take_id : @control.TakeId,
  session : @control.HarnessSession,
  lease : @control.SandboxLease,
  sandbox : NativeBoxLiteTakeSandbox,
  persisted_process_spec_digest : @control.Digest,
  process : @sandbox.SandboxProcessSpec,
) -> Result[NativeSandboxProcessResult, @types.ChoirError] {
  execute_durable_native_process_with(
    runtime,
    goal_id,
    fencing_epoch,
    effect_intent_id,
    discriminator,
    take_id,
    session,
    lease,
    persisted_process_spec_digest,
    process,
    {
      execute: async fn() {
        execute_native_boxlite_process(
          sandbox,
          { goal_id, take_id, fencing_epoch },
          persisted_process_spec_digest,
          process,
          fn(artifact) { native_artifact_exists(runtime, artifact) },
        )
      },
      retire_generation: async fn() {
        let result = destroy_native_boxlite_take(sandbox)
        match result {
          Ok(_) => {
            runtime.sandboxes.remove(lease.generation_id.0)
            Ok(())
          }
          Err(error) => Err(error)
        }
      },
      fault_enabled: fn(_) { false },
    },
  )
}

///|
async fn execute_durable_native_boxlite_process(
  runtime : NativePartEffectRuntime,
  snapshot : @workflow.PartWorkflowSnapshot,
  intent : @workflow.PartEffectIntent,
  take_id : @control.TakeId,
  session : @control.HarnessSession,
  sandbox : NativeBoxLiteTakeSandbox,
  persisted_process_spec_digest : @control.Digest,
  process : @sandbox.SandboxProcessSpec,
) -> Result[NativeSandboxProcessResult, @types.ChoirError] {
  let lease = match
    native_process_lease(snapshot, take_id, session.sandbox_generation_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  execute_durable_native_process(
    runtime,
    snapshot.goal.id,
    snapshot.fencing_epoch,
    intent.effect_id,
    "",
    take_id,
    session,
    lease,
    sandbox,
    persisted_process_spec_digest,
    process,
  )
}

///|
async fn reconcile_unadoptable_native_process(
  runtime : NativePartEffectRuntime,
  snapshot : @workflow.PartWorkflowSnapshot,
  intent : @workflow.PartEffectIntent,
) -> Result[Bool, @types.ChoirError] {
  reconcile_unadoptable_native_process_id(
    runtime,
    snapshot.goal.id,
    snapshot.fencing_epoch,
    native_process_execution_id(intent.effect_id, ""),
  )
}

///|
async fn reconcile_unadoptable_native_process_id(
  runtime : NativePartEffectRuntime,
  goal_id : @control.GoalId,
  fencing_epoch : @control.FencingEpoch,
  execution_id : @sandbox.ProcessExecutionId,
) -> Result[Bool, @types.ChoirError] {
  let stored = match load_native_process_execution(runtime, execution_id) {
    Ok(Some(value)) => value
    Ok(None) => return Ok(false)
    Err(error) => return Err(error)
  }
  let action = match
    @sandbox.recover_process_execution(stored.execution, false) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match action {
    @sandbox.ProcessRecoveryAction::ProcessRetryExactStart
    | @sandbox.ProcessRecoveryAction::ProcessUseTerminal(_, _) => Ok(false)
    @sandbox.ProcessRecoveryAction::ProcessRetireSandboxGeneration(
      generation_id
    ) => {
      let sandbox = match read_native_sandbox_resource(runtime, generation_id) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      match destroy_native_boxlite_take(sandbox) {
        Ok(_) => ()
        Err(error) => return Err(error)
      }
      runtime.sandboxes.remove(generation_id.0)
      let uncertain = match
        @sandbox.record_unadoptable_process_start(
          stored.execution,
          (runtime.config.now)(),
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      match
        persist_native_process_execution(
          runtime,
          goal_id,
          fencing_epoch,
          uncertain,
          Some(stored.state_record.version),
        ) {
        Ok(_) => Ok(true)
        Err(error) => Err(error)
      }
    }
    @sandbox.ProcessRecoveryAction::ProcessRecoveryBlocked => Ok(true)
    @sandbox.ProcessRecoveryAction::ProcessAdoptRuntimeKey(_) =>
      Err(
        native_process_execution_error(
          "pinned BoxLite server falsely selected keyed process adoption",
        ),
      )
  }
}

///|
async test "process execution state persists and recovers every start boundary" {
  let root = "/tmp/choir-take-process-state-" + @sys.get_pid().to_string()
  let repository : @workflow.PartWorkflowRepository = {
    state_store: { path: root + "/state.db" },
    artifact_store: { root: root + "/artifacts" },
    max_snapshot_bytes: 1024 * 1024,
  }
  ignore(@sys.rm_rf(root))
  guard @sys.create_dir_all(root) else { fail("create process state root") }
  let adapters = local_part_workflow_repository_adapters()
  guard @workflow.initialize_part_workflow_repository(repository, adapters)
    is Ok(_) else {
    fail("initialize process state repository")
  }
  let digest = fn(value : String) {
    @storage.artifact_digest(@utf8.encode(value))
  }
  let clock = @ref.new(1L)
  let runtime = create_native_part_effect_runtime({
    repository,
    repository_adapters: adapters,
    server: {
      config: {
        binary: "/bin/false",
        runtime_dir: "/tmp",
        root,
        port: 32123,
        api_key: "process-state-key",
      },
      pid: 1,
      url: "http://127.0.0.1:32123",
    },
    git_workspace: {
      repository_root: root + "/repo",
      object_directory: root + "/objects",
      staging_root: root + "/staging",
    },
    git_integration: {
      repository_root: root + "/repo",
      git_directory: root + "/git",
      object_directory: root + "/objects",
      control_root: root + "/integration",
      goal_ref: "refs/heads/process-state",
    },
    moon_home: "/tmp/moon",
    node_executable: "/bin/false",
    sandbox_mcp_script: "/tmp/mcp.mjs",
    claude_root: root + "/claude/",
    codex_root: root + "/codex/",
    provider_conformance_report_digest: fn(surface) {
      digest(surface.to_json().stringify(indent=0))
    },
    now: fn() {
      clock.val = clock.val + 1L
      clock.val
    },
    goal_cancellation_requested: fn() { false },
  }).unwrap()
  let goal_id = @control.GoalId("process-state-goal")
  let fence = @control.FencingEpoch(3L)
  let planned : @sandbox.ProcessExecution = {
    execution_id: @sandbox.ProcessExecutionId("process-state-effect.process"),
    effect_intent_id: "process-state-effect",
    runtime_execution_key: @sandbox.RuntimeExecutionKey(
      "process-state-effect.process",
    ),
    take_id: @control.TakeId("process-state-take"),
    process_authority: @sandbox.SandboxProcessAuthority::SandboxImplementationTool(
      @control.TakeId("process-state-take"),
      digest("profile"),
    ),
    validated_process_spec_digest: digest("spec"),
    sandbox_lease_id: @control.SandboxLeaseId("process-state-lease"),
    sandbox_generation_id: @control.SandboxGenerationId(
      "process-state-generation",
    ),
    capability_profile_digest: digest("capability"),
    input_artifact_set_digest: digest("inputs"),
    output_artifact_set_digest: None,
    started_at: None,
    finished_at: None,
    disposition: @sandbox.ProcessExecutionDisposition::ProcessStartPlanned,
  }
  let first = persist_native_process_execution(
    runtime,
    goal_id,
    fence,
    planned,
    None,
  ).unwrap()
  let authorized = @sandbox.authorize_process_start(planned, 10L).unwrap()
  let second = persist_native_process_execution(
    runtime,
    goal_id,
    fence,
    authorized,
    Some(first.state_record.version),
  ).unwrap()
  let output = digest("output")
  let terminal = @sandbox.record_process_exit(authorized, 0, output, 11L).unwrap()
  let third = persist_native_process_execution(
    runtime,
    goal_id,
    fence,
    terminal,
    Some(second.state_record.version),
  ).unwrap()
  assert_eq(third.state_record.version, 3)
  assert_eq(
    load_native_process_execution(runtime, planned.execution_id).unwrap(),
    Some(third),
  )
  let take_id = @control.TakeId("process-fault-take")
  let generation_id = @control.SandboxGenerationId("process-fault-generation")
  let lease : @control.SandboxLease = {
    id: @control.SandboxLeaseId("process-fault-lease"),
    take_id,
    generation_id,
    capability_profile_digest: digest("fault-capability"),
    runtime_policy_digest: digest("fault-runtime"),
    lifecycle: @control.SandboxLeaseLifecycle::SandboxLeaseActive,
  }
  let session : @control.HarnessSession = {
    id: @control.HarnessSessionId("process-fault-session"),
    take_id,
    sandbox_generation_id: generation_id,
    surface: @control.ProviderSurfaceId::CodexSubscriptionCli,
    effective_surface_manifest_digest: digest("fault-surface"),
    cursor_class: @control.HarnessCursorClass::HarnessCursorProviderEventId,
    provider_cursor: None,
    last_choir_sequence: @control.EventSequence(0L),
    open_tool_execution_ids: [],
    lifecycle: @control.HarnessSessionLifecycle::HarnessSessionRunning,
  }
  let process : @sandbox.SandboxProcessSpec = {
    authority: @sandbox.SandboxProcessAuthority::SandboxImplementationTool(
      take_id,
      digest("fault-profile"),
    ),
    executable: @sandbox.SandboxExecutable::SandboxRegisteredTool(
      @sandbox.SandboxRegisteredToolId("moon"),
      digest("fault-tool"),
    ),
    arguments: ["version"],
    working_directory: @sandbox.SandboxWorkingDirectory::SandboxWorkspaceRoot,
    environment: [],
    stdin: @sandbox.SandboxStdinPolicy::SandboxStdinClosed,
    timeout_ms: 1000L,
    resources: {
      cpu_millis: 1000L,
      memory_bytes: 268435456L,
      process_count: 32,
      file_bytes: 1048576L,
    },
    network: {
      profile: @sandbox.SandboxNetworkProfile::NetworkDisabled,
      version: 1L,
      policy_digest: digest("fault-runtime"),
    },
    output: {
      stdout_limit_bytes: 1024L,
      stderr_limit_bytes: 1024L,
      on_limit: @sandbox.SandboxOutputLimitDisposition::SandboxTerminateAndMarkExceeded,
    },
  }
  let points = [
    ProcessAfterPlannedBeforeAuthorization,
    ProcessAfterAuthorizationBeforeDispatch,
    ProcessAfterDispatchBeforeTerminalPersistence,
    ProcessAfterTerminalPersistenceBeforeReturn,
  ]
  for index = 0; index < points.length(); index = index + 1 {
    let calls = @ref.new(0)
    let effect_id = "process-fault-" + index.to_string()
    let runner = async fn() {
      @async.sleep(0)
      calls.val = calls.val + 1
      Ok({
        exit_code: 0,
        output: "bounded",
        output_digest: digest("bounded"),
        started_at: None,
        finished_at: None,
      })
    }
    let first = execute_durable_native_process_with(
      runtime,
      goal_id,
      fence,
      effect_id,
      "",
      take_id,
      session,
      lease,
      digest("fault-spec"),
      process,
      {
        execute: runner,
        retire_generation: async fn() {
          @async.sleep(0)
          Ok(())
        },
        fault_enabled: fn(point) { point == points[index] },
      },
    )
    assert_true(first is Err(_))
    let before_retry = calls.val
    let second = execute_durable_native_process_with(
      runtime,
      goal_id,
      fence,
      effect_id,
      "",
      take_id,
      session,
      lease,
      digest("fault-spec"),
      process,
      {
        execute: runner,
        retire_generation: async fn() {
          @async.sleep(0)
          Ok(())
        },
        fault_enabled: fn(_) { false },
      },
    )
    if index == 0 || index == 3 {
      assert_true(second is Ok(_))
    } else {
      assert_true(second is Err(_))
    }
    assert_true(calls.val <= 1)
    if index == 3 {
      assert_eq(calls.val, before_retry)
    }
  }
  let retired = @ref.new(false)
  let failed = execute_durable_native_process_with(
    runtime,
    goal_id,
    fence,
    "process-runner-error",
    "",
    take_id,
    session,
    lease,
    digest("fault-spec"),
    process,
    {
      execute: async fn() {
        @async.sleep(0)
        Err(@types.ChoirError::transport_error("lost guest result"))
      },
      retire_generation: async fn() {
        @async.sleep(0)
        retired.val = true
        Ok(())
      },
      fault_enabled: fn(_) { false },
    },
  )
  assert_true(failed is Err(error) && error.is_provider_process_lost())
  assert_true(retired.val)
  let failed_state = load_native_process_execution(
    runtime,
    @sandbox.ProcessExecutionId("process-runner-error.process"),
  ).unwrap()
  assert_true(
    failed_state is Some({
      execution: {
        disposition: @sandbox.ProcessExecutionDisposition::ProcessStartUncertain,
        ..,
      },
      ..,
    }),
  )
  ignore(@sys.rm_rf(root))
}
