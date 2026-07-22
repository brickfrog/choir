///|
async fn create_native_goal_assurance_runtime(
  repository : @workflow.PartWorkflowRepository,
  execution : @workflow.GoalExecutionRecord,
  git : NativeGoalRepositoryIdentity,
  assurance : @workflow.GoalAssuranceRecord,
) -> Result[NativePartEffectRuntime, @types.ChoirError] {
  let runtime_key = native_goal_runtime_key(
    execution.repository_id,
    execution.goal.id,
  )
  let runtime_root = native_goal_runtime_root(
    execution.repository_id,
    execution.goal.id,
  )
  if !@sys.create_dir_all(runtime_root) ||
    @sys.realpath_native(runtime_root) != Some(runtime_root) {
    return Err(native_goal_execution_error("runtime root is unavailable"))
  }
  let server_config = match native_goal_boxlite_server_config(execution) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let moon_home = match @sys.getenv("CHOIR_MOON_HOME") {
    Some(value) => value
    None =>
      match @sys.getenv("HOME") {
        Some(value) => value + "/.moon"
        None => return Err(native_goal_execution_error("Moon home is absent"))
      }
  }
  let node = match resolve_executable_in_path("node") {
    Some(value) => value
    None => return Err(native_goal_execution_error("Node is absent"))
  }
  let mcp_script = match native_goal_mcp_script() {
    Some(value) => value
    None => return Err(native_goal_execution_error("sandbox MCP is absent"))
  }
  let server = match start_native_boxlite_server(server_config) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let clock = @ref.new(@env.now().reinterpret_as_int64() / 1000L)
  let now = fn() {
    clock.val = clock.val + 1L
    clock.val
  }
  let cancellation_requested = fn() {
    match
      @workflow.load_goal_execution_record(
        repository,
        local_part_workflow_repository_adapters(),
        execution.goal.id,
      ) {
      Ok(Some(current)) =>
        current.record.state !=
        @workflow.GoalExecutionState::GoalExecutionAssuring ||
        current.record.goal.lifecycle !=
        @control.GoalLifecycle::GoalActive(
          @control.GoalActiveCondition::GoalRunning,
        )
      _ => true
    }
  }
  let existing_generation = if @sys.path_exists(
      runtime_root +
      "/state/sandboxes/" +
      assurance.identities.verification_sandbox.generation_id.0 +
      ".json",
    ) {
    Some(assurance.identities.verification_sandbox.generation_id)
  } else if @sys.path_exists(
      runtime_root +
      "/state/sandboxes/" +
      assurance.identities.audit_sandbox.generation_id.0 +
      ".json",
    ) {
    Some(assurance.identities.audit_sandbox.generation_id)
  } else {
    None
  }
  let (active_server, prepared) = match existing_generation {
    Some(_) => (server, None)
    None =>
      match
        prepare_native_boxlite_environment(
          server,
          moon_home,
          "choir-base-goal-" + runtime_key,
        ) {
        Ok(value) => (value.server, Some(value))
        Err(error) => {
          stop_native_boxlite_server(server)
          return Err(error)
        }
      }
  }
  let runtime = match
    create_native_part_effect_runtime(
      native_part_runtime_config_for_paths(
        repository,
        active_server,
        git.root,
        git.git_directory,
        git.object_directory,
        execution.goal_ref.0,
        moon_home,
        node,
        mcp_script,
        now,
        goal_cancellation_requested=cancellation_requested,
      ),
    ) {
    Ok(value) => value
    Err(error) => {
      stop_native_boxlite_server(active_server)
      return Err(error)
    }
  }
  match prepared {
    Some(value) => runtime.prepared.val = Some(value)
    None =>
      match existing_generation {
        Some(generation_id) =>
          match native_runtime_sandbox(runtime, generation_id) {
            Ok(_) => ()
            Err(error) => {
              stop_native_boxlite_server(runtime.server.val)
              return Err(error)
            }
          }
        None => ()
      }
  }
  Ok(runtime)
}

///|
fn native_goal_assurance_session(
  record : @workflow.GoalAssuranceRecord,
  session_id : @control.HarnessSessionId,
) -> Result[@control.HarnessSession, @types.ChoirError] {
  for session in record.harness_sessions {
    if session.id == session_id {
      return Ok(session)
    }
  }
  Err(native_goal_execution_error("Goal assurance session is absent"))
}

///|
fn decode_native_goal_verification_process(
  runtime : NativePartEffectRuntime,
  take_id : @control.TakeId,
  spec : @control.VerificationSpec,
) -> Result[@sandbox.SandboxProcessSpec, @types.ChoirError] {
  let content = match
    read_native_effect_artifact(runtime, spec.process_spec_digest, 65536) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let json = @json.parse(@utf8.decode_lossy(content)) catch {
    _ =>
      return Err(
        native_goal_execution_error("verification process is not JSON"),
      )
  }
  let process : @sandbox.SandboxProcessSpec = @json.from_json(json) catch {
    _ =>
      return Err(
        native_goal_execution_error("verification process schema is invalid"),
      )
  }
  match process.authority {
    @sandbox.SandboxProcessAuthority::SandboxVerificationTool(
      authority_take_id,
      verification_spec_id,
      verification_spec_digest
    ) if authority_take_id == take_id &&
      verification_spec_id == spec.id &&
      verification_spec_digest == spec.digest => Ok(process)
    _ => Err(native_goal_execution_error("verification authority is stale"))
  }
}

///|
fn native_goal_assurance_task_summary(
  runtime : NativePartEffectRuntime,
  record : @workflow.GoalAssuranceRecord,
) -> Result[String, @types.ChoirError] {
  let stored_execution = match
    @workflow.load_goal_execution_record(
      runtime.config.repository,
      local_part_workflow_repository_adapters(),
      record.goal_id,
    ) {
    Ok(Some(value)) => value.record
    Ok(None) => return Err(native_goal_execution_error("Goal is absent"))
    Err(error) => return Err(error)
  }
  if stored_execution.goal.contract_digest != record.goal_contract_digest {
    return Err(native_goal_execution_error("Goal contract is stale"))
  }
  let tasks : Array[String] = []
  for workflow_id in stored_execution.part_workflow_ids {
    let snapshot = match
      @workflow.load_part_snapshot(
        runtime.config.repository,
        local_part_workflow_repository_adapters(),
        workflow_id,
      ) {
      Ok(Some(value)) => value.snapshot
      Ok(None) => return Err(native_goal_execution_error("Part is absent"))
      Err(error) => return Err(error)
    }
    if snapshot.goal.id != record.goal_id ||
      !(snapshot.part.lifecycle is @control.PartLifecycle::PartIntegrated(_)) {
      return Err(native_goal_execution_error("Part assurance state is stale"))
    }
    let instruction = match
      read_native_instruction(
        runtime,
        snapshot.task_contract.instruction_artifact,
      ) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    tasks.push("Part " + snapshot.part.id.0 + ":\n" + instruction)
  }
  if tasks.length() == 0 {
    Err(native_goal_execution_error("Goal has no Part tasks"))
  } else {
    Ok(tasks.join("\n\n"))
  }
}

///|
async fn native_goal_assurance_post_tree(
  runtime : NativePartEffectRuntime,
  record : @workflow.GoalAssuranceRecord,
  take_id : @control.TakeId,
  session : @control.HarnessSession,
  sandbox : NativeBoxLiteTakeSandbox,
  suffix : String,
) -> Result[@control.GitOid, @types.ChoirError] {
  let seal = match record.seal {
    Some(value) => value
    None => return Err(native_goal_execution_error("Goal seal is absent"))
  }
  match cleanup_native_boxlite_assurance_subject(sandbox) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let artifact = match
    store_native_take_result(runtime, record.goal_id, take_id, session, sandbox) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let manifest = match read_native_take_result_manifest(runtime, artifact) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let tree = match
    observe_native_git_result_tree(
      runtime.config.git_workspace,
      suffix + "-" + take_id.0,
      seal.head_oid,
      manifest.source_digest,
      native_take_result_root(runtime, manifest),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if tree == seal.tree_oid {
    Ok(tree)
  } else {
    Err(native_goal_execution_error("Goal assurance Take mutated the seal"))
  }
}

///|
fn native_goal_assurance_active_lease(
  record : @workflow.GoalAssuranceRecord,
  take_id : @control.TakeId,
  generation_id : @control.SandboxGenerationId,
) -> Result[@control.SandboxLease, @types.ChoirError] {
  for lease in record.sandbox_leases {
    if lease.take_id == take_id && lease.generation_id == generation_id {
      return if lease.lifecycle ==
        @control.SandboxLeaseLifecycle::SandboxLeaseActive {
        Ok(lease)
      } else {
        Err(
          native_goal_execution_error("assurance sandbox lease is not active"),
        )
      }
    }
  }
  Err(native_goal_execution_error("assurance sandbox lease is missing"))
}

///|
async fn execute_native_goal_verification(
  runtime : NativePartEffectRuntime,
  record : @workflow.GoalAssuranceRecord,
  intent : @workflow.GoalAssuranceEffectIntent,
  take_id : @control.TakeId,
  session_id : @control.HarnessSessionId,
  subject : @control.GoalVerificationSubject,
) -> Result[@workflow.GoalAssuranceEffectObservation, @types.ChoirError] {
  if record.verification_subject != Some(subject) ||
    record.verification_take.id != take_id {
    return Err(native_goal_execution_error("verification subject is stale"))
  }
  let session = match native_goal_assurance_session(record, session_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let sandbox = match
    native_runtime_sandbox(runtime, session.sandbox_generation_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let lease = match
    native_goal_assurance_active_lease(
      record,
      take_id,
      session.sandbox_generation_id,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let processes : Array[
    (@control.VerificationSpec, NativeSandboxProcessResult, Int64),
  ] = []
  for spec in record.verification_specs {
    let process = match
      decode_native_goal_verification_process(runtime, take_id, spec) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let result = match
      execute_durable_native_process(
        runtime,
        record.goal_id,
        record.fencing_epoch,
        intent.effect_id,
        spec.id.0,
        take_id,
        session,
        lease,
        sandbox,
        spec.process_spec_digest,
        process,
      ) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let started_at = match result.started_at {
      Some(value) => value
      None => return Err(native_goal_execution_error("process start is absent"))
    }
    processes.push((spec, result, started_at))
  }
  let process_summary = processes
    .map(fn(entry) { entry.0.id.0 + " exit=" + entry.1.exit_code.to_string() })
    .join("; ")
  let task_summary = match native_goal_assurance_task_summary(runtime, record) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let instruction = "Independently verify the complete sealed Goal tree " +
    subject.goal_head_oid.0 +
    " against these exact persisted Part tasks:\n" +
    task_summary +
    "\nThe trusted typed checks reported: " +
    process_summary +
    ". Inspect the whole combined tree and the Goal-level interactions. Return failed only for a concrete defect in the sealed result or its declared checks. Do not modify the workspace."
  let provider = match
    run_native_part_provider_take(
      runtime,
      session,
      sandbox,
      NativeVerificationTake,
      instruction,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let post_tree = match
    native_goal_assurance_post_tree(
      runtime, record, take_id, session, sandbox, "goal-verification-post",
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let provider_passed = provider.outcome == NativeVerificationPassed
  let executions : Array[@workflow.GoalVerificationSpecExecution] = []
  let evidence_references : Array[@control.ArtifactReference] = []
  for entry in processes {
    let outcome = if entry.1.exit_code == 0 && provider_passed {
      @control.VerificationOutcome::VerificationPassed
    } else {
      @control.VerificationOutcome::VerificationFailed
    }
    let evidence_fields : Map[String, Json] = {
      "subject": subject.to_json(),
      "verification_spec": entry.0.to_json(),
      "process_result": native_sandbox_process_evidence(entry.1),
      "provider_outcome": ToJson::to_json(provider.outcome),
      "provider_terminal_response": provider.terminal_response.to_json(),
      "pre_tree": subject.goal_tree_oid.to_json(),
      "post_tree": post_tree.to_json(),
    }
    let evidence = match
      adopt_native_effect_artifact(
        runtime,
        record.goal_id,
        @utf8.encode(evidence_fields.to_json().stringify(indent=0)),
        @storage.ArtifactProvenance::ArtifactVerificationEvidence(take_id),
      ) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    evidence_references.push(evidence)
    executions.push({
      verification_execution_id: @control.VerificationExecutionId(
        "goal-verification-" + take_id.0 + "-" + entry.0.id.0,
      ),
      verification_spec: entry.0,
      environment_and_image_digest: native_prepared_environment_digest(
        sandbox.prepared,
      ),
      runtime_and_policy_digest: sandbox.prepared.runtime_policy_digest,
      subject_pre_tree_oid: subject.goal_tree_oid,
      subject_post_tree_oid: post_tree,
      evidence,
      started_at: entry.2,
      finished_at: provider.finished_at,
      outcome,
    })
  }
  let evidence_manifest = match
    adopt_native_effect_artifact(
      runtime,
      record.goal_id,
      @utf8.encode(evidence_references.to_json().stringify(indent=0)),
      @storage.ArtifactProvenance::ArtifactVerificationEvidence(take_id),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok(
    @workflow.GoalAssuranceEffectObservation::GoalVerificationCompleted(
      { take_id, session_id, subject, executions, evidence_manifest },
      provider.session,
      provider.events,
    ),
  )
}

///|
async fn execute_native_goal_audit(
  runtime : NativePartEffectRuntime,
  record : @workflow.GoalAssuranceRecord,
  take_id : @control.TakeId,
  session_id : @control.HarnessSessionId,
  subject : @control.GoalAuditSubject,
) -> Result[@workflow.GoalAssuranceEffectObservation, @types.ChoirError] {
  if record.audit_subject != Some(subject) || record.audit_take.id != take_id {
    return Err(native_goal_execution_error("audit subject is stale"))
  }
  let session = match native_goal_assurance_session(record, session_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let sandbox = match
    native_runtime_sandbox(runtime, session.sandbox_generation_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let task_summary = match native_goal_assurance_task_summary(runtime, record) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let instruction = "Independently audit the complete sealed Goal tree " +
    subject.goal_head_oid.0 +
    " after combined verification authorization " +
    subject.goal_verification_receipt_set_digest.0 +
    " against these exact persisted Part tasks:\n" +
    task_summary +
    "\nInspect cross-Part interactions, the exact declared checks, and the final combined result. Report every concrete finding attributable to this sealed tree. Do not modify the workspace."
  let provider = match
    run_native_part_provider_take(
      runtime,
      session,
      sandbox,
      NativeAuditTake,
      instruction,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  ignore(
    match
      native_goal_assurance_post_tree(
        runtime, record, take_id, session, sandbox, "goal-audit-post",
      ) {
      Ok(value) => value
      Err(error) => return Err(error)
    },
  )
  let (outcome, total, blocking) = match provider.outcome {
    NativeAuditPassed => (@control.AuditOutcome::AuditPassed, 0, 0)
    NativeAuditFindings(total, blocking) =>
      (@control.AuditOutcome::AuditFindings, total, blocking)
    _ => return Err(native_goal_execution_error("audit outcome is invalid"))
  }
  let findings = if total == 0 {
    None
  } else {
    match
      adopt_native_effect_artifact(
        runtime,
        record.goal_id,
        @utf8.encode(provider.terminal_response),
        @storage.ArtifactProvenance::ArtifactAuditFindings(take_id),
      ) {
      Ok(value) => Some(value)
      Err(error) => return Err(error)
    }
  }
  Ok(
    @workflow.GoalAssuranceEffectObservation::GoalAuditCompleted(
      {
        audit_take_id: take_id,
        take_fencing_epoch: record.fencing_epoch,
        audit_harness_session_id: session_id,
        subject,
        provider_conformance_report_digest: (runtime.config.provider_conformance_report_digest)(
          session.surface,
        ),
        findings_artifact: findings,
        total_findings_count: total,
        blocking_findings_count: blocking,
        started_at: provider.started_at,
        finished_at: provider.finished_at,
        outcome,
      },
      provider.session,
      provider.events,
    ),
  )
}

///|
async fn execute_native_goal_assurance_effect(
  runtime : NativePartEffectRuntime,
  record : @workflow.GoalAssuranceRecord,
  intent : @workflow.GoalAssuranceEffectIntent,
) -> Result[@workflow.GoalAssuranceEffectObservation, @types.ChoirError] {
  let seal = match record.seal {
    Some(value) => value
    None => return Err(native_goal_execution_error("Goal seal is absent"))
  }
  match intent.kind {
    @workflow.GoalAssuranceEffectKind::PrepareGoalVerificationSandbox(lease) =>
      match
        prepare_native_source_sandbox(
          runtime,
          lease,
          seal.head_oid,
          seal.tree_oid,
          read_only_subject=true,
        ) {
        Ok(value) =>
          Ok(
            @workflow.GoalAssuranceEffectObservation::GoalVerificationSandboxPrepared(
              value,
            ),
          )
        Err(error) => Err(error)
      }
    @workflow.GoalAssuranceEffectKind::PrepareGoalAuditSandbox(lease) =>
      match
        prepare_native_source_sandbox(
          runtime,
          lease,
          seal.head_oid,
          seal.tree_oid,
          read_only_subject=true,
        ) {
        Ok(value) =>
          Ok(
            @workflow.GoalAssuranceEffectObservation::GoalAuditSandboxPrepared(
              value,
            ),
          )
        Err(error) => Err(error)
      }
    @workflow.GoalAssuranceEffectKind::StartGoalVerificationHarness(session) =>
      match start_native_part_harness(session) {
        Ok(value) =>
          Ok(
            @workflow.GoalAssuranceEffectObservation::GoalVerificationHarnessStarted(
              value,
            ),
          )
        Err(error) => Err(error)
      }
    @workflow.GoalAssuranceEffectKind::StartGoalAuditHarness(session) =>
      match start_native_part_harness(session) {
        Ok(value) =>
          Ok(
            @workflow.GoalAssuranceEffectObservation::GoalAuditHarnessStarted(
              value,
            ),
          )
        Err(error) => Err(error)
      }
    @workflow.GoalAssuranceEffectKind::DispatchGoalVerification(
      take_id,
      session_id,
      subject
    ) =>
      execute_native_goal_verification(
        runtime, record, intent, take_id, session_id, subject,
      )
    @workflow.GoalAssuranceEffectKind::DispatchGoalAudit(
      take_id,
      session_id,
      subject
    ) =>
      execute_native_goal_audit(runtime, record, take_id, session_id, subject)
  }
}

///|
async fn execute_native_goal_assurance_effect_once(
  repository : @workflow.PartWorkflowRepository,
  execution : @workflow.GoalExecutionRecord,
  git : NativeGoalRepositoryIdentity,
  record : @workflow.GoalAssuranceRecord,
  intent : @workflow.GoalAssuranceEffectIntent,
) -> Result[@workflow.GoalAssuranceEffectObservation, @types.ChoirError] {
  let runtime = match
    create_native_goal_assurance_runtime(repository, execution, git, record) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let result = execute_native_goal_assurance_effect(runtime, record, intent)
  let mut stop_error : @types.ChoirError? = None
  for sandbox in runtime.sandboxes.values() {
    match stop_native_boxlite_take(sandbox) {
      Ok(_) => ()
      Err(error) => stop_error = Some(error)
    }
  }
  // Each durable effect gets a fresh host process, while its stopped VM and
  // disk remain available for exact re-adoption by the next effect.
  stop_native_boxlite_server(runtime.server.val)
  match result {
    Err(error) => Err(error)
    Ok(value) =>
      match stop_error {
        Some(error) => Err(error)
        None => Ok(value)
      }
  }
}

///|
async fn reconcile_native_goal_processes_once(
  repository : @workflow.PartWorkflowRepository,
  execution : @workflow.GoalExecutionRecord,
  git : NativeGoalRepositoryIdentity,
  record : @workflow.GoalAssuranceRecord,
  intent : @workflow.GoalAssuranceEffectIntent,
) -> Result[Bool, @types.ChoirError] {
  let runtime = match
    create_native_goal_assurance_runtime(repository, execution, git, record) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let mut uncertain = false
  match intent.kind {
    @workflow.GoalAssuranceEffectKind::DispatchGoalVerification(_, _, _) =>
      for spec in record.verification_specs {
        let value = match
          reconcile_unadoptable_native_process_id(
            runtime,
            record.goal_id,
            record.fencing_epoch,
            @sandbox.ProcessExecutionId(
              intent.effect_id + ".process." + spec.id.0,
            ),
          ) {
          Ok(result) => result
          Err(error) => {
            stop_native_boxlite_server(runtime.server.val)
            return Err(error)
          }
        }
        uncertain = uncertain || value
      }
    _ => ()
  }
  let mut stop_error : @types.ChoirError? = None
  for sandbox in runtime.sandboxes.values() {
    match stop_native_boxlite_take(sandbox) {
      Ok(_) => ()
      Err(error) => stop_error = Some(error)
    }
  }
  stop_native_boxlite_server(runtime.server.val)
  match stop_error {
    Some(error) => Err(error)
    None => Ok(uncertain)
  }
}
