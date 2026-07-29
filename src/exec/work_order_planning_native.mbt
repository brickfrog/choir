///|
pub(all) struct NativeWorkOrderPlanningSnapshot {
  repository_root : String
  object_directory : String
  commit_oid : @control.GitOid
  tree_oid : @control.GitOid
  repository_digest : @control.Digest
  bead_digest : @control.Digest
  beads : Array[@command.BeadRecord]
} derive(Debug, Eq)

///|
pub(all) enum NativeWorkOrderPlannerRecovery {
  NativeWorkOrderPlannerRecovered(Bytes)
  NativeWorkOrderPlannerExactRetryAuthorized
  NativeWorkOrderPlannerRecoveryUncertain(@control.Digest)
} derive(Debug, Eq)

///|
pub(all) struct NativeWorkOrderBeadDeliveryReceipt {
  batch_digest : @control.Digest
  bead_snapshot_digest : @control.Digest
} derive(Debug, Eq)

///|
pub(all) enum NativeWorkOrderPlannerAdmission {
  NativeWorkOrderPlannerAdmitted
  NativeWorkOrderPlannerDeferredUntil(Int64)
} derive(Debug, Eq)

///|
pub(all) struct NativeWorkOrderPlanningAdapters {
  capture_snapshot : async () -> Result[
    NativeWorkOrderPlanningSnapshot,
    @types.ChoirError,
  ]
  execute_planner : async (
    @workflow.WorkOrderRecord,
    @workflow.WorkOrderPlanningRound,
  ) -> Result[Bytes, @types.ChoirError]
  recover_planner : async (
    @workflow.WorkOrderRecord,
    @workflow.WorkOrderPlanningRound,
  ) -> Result[NativeWorkOrderPlannerRecovery, @types.ChoirError]
  authorize_planner : (
    @workflow.WorkOrderRecord,
    @workflow.WorkOrderPlanningRound,
  ) -> Result[NativeWorkOrderPlannerAdmission, @types.ChoirError]
  release_planner : (
    @workflow.WorkOrderRecord,
    @workflow.WorkOrderPlanningRound,
  ) -> Result[Unit, @types.ChoirError]
  deliver_beads : async (
    @workflow.WorkOrderPlanningRoundId,
    @command.BeadBatchProposal,
  ) -> Result[NativeWorkOrderBeadDeliveryReceipt, @types.ChoirError]
  now : () -> Int64
}

///|
pub(all) enum NativeWorkOrderPlanningTick {
  NativeWorkOrderPlanningIdle
  NativeWorkOrderPlanningAdvanced(@workflow.WorkOrderRecord)
} derive(Debug, Eq)

///|
pub(all) enum NativeWorkOrderExecutionTick {
  NativeWorkOrderExecutionIdle
  NativeWorkOrderExecutionAdvanced(@workflow.WorkOrderRecord)
} derive(Debug, Eq)

///|
fn native_work_order_planning_error(detail : String) -> @types.ChoirError {
  @types.ChoirError::validation_error("native WorkOrder planning: " + detail)
}

///|
/// Provider-side shape for the advisory planning proposal. The authoritative
/// decoder still lives in workflow and rejects every malformed or
/// authority-expanding value before any tracker or Goal effect is planned.
fn native_work_order_planning_output_schema() -> String {
  let string_array : Json = {
    "type": "array".to_json(),
    "items": { "type": "string".to_json() }.to_json(),
  }.to_json()
  let nullable_string : Json = { "type": ["string", "null"].to_json() }.to_json()
  let mutation : Json = {
    "type": "object".to_json(),
    "properties": {
      "id": { "type": "string".to_json() }.to_json(),
      "intent": {
        "type": "string".to_json(),
        "enum": ["BeadCreateIntent", "BeadUpdateIntent"].to_json(),
      }.to_json(),
      "title": nullable_string,
      "description": nullable_string,
      "acceptance_criteria": nullable_string,
      "notes": nullable_string,
      "priority": { "type": ["string", "null"].to_json() }.to_json(),
      "issue_type": { "type": ["string", "null"].to_json() }.to_json(),
      "labels": {
        "anyOf": [string_array, { "type": "null".to_json() }.to_json()].to_json(),
      }.to_json(),
      "blocked_by": string_array,
      "parent": nullable_string,
      "expected_updated_at": nullable_string,
    }.to_json(),
    "required": [
      "id", "intent", "title", "description", "acceptance_criteria", "notes", "priority",
      "issue_type", "labels", "blocked_by", "parent", "expected_updated_at",
    ].to_json(),
    "additionalProperties": false.to_json(),
  }.to_json()
  let schema : Json = {
    "$schema": "https://json-schema.org/draft/2020-12/schema".to_json(),
    "type": "object".to_json(),
    "properties": {
      "findings": {
        "type": "array".to_json(),
        "items": {
          "type": "object".to_json(),
          "properties": {
            "summary": { "type": "string".to_json() }.to_json(),
            "evidence": { "type": "string".to_json() }.to_json(),
            "related_bead_ids": string_array,
          }.to_json(),
          "required": ["summary", "evidence", "related_bead_ids"].to_json(),
          "additionalProperties": false.to_json(),
        }.to_json(),
      }.to_json(),
      "eligible_work_observed": { "type": "boolean".to_json() }.to_json(),
      "bead_mutations": {
        "type": "object".to_json(),
        "properties": {
          "mutations": { "type": "array".to_json(), "items": mutation }.to_json(),
        }.to_json(),
        "required": ["mutations"].to_json(),
        "additionalProperties": false.to_json(),
      }.to_json(),
      "primary_target_ids": string_array,
      "prerequisite_closure_ids": string_array,
      // Transport the nested draft as JSON text. Strict structured-output
      // implementations require closed schemas for nested objects; Choir
      // parses this back before the authoritative workflow decode.
      "finite_goal": { "type": ["string", "null"].to_json() }.to_json(),
    }.to_json(),
    "required": [
      "findings", "eligible_work_observed", "bead_mutations", "primary_target_ids",
      "prerequisite_closure_ids", "finite_goal",
    ].to_json(),
    "additionalProperties": false.to_json(),
  }.to_json()
  schema.stringify(indent=0) + "\n"
}

///|
fn native_work_order_planner_instruction(
  record : @workflow.WorkOrderRecord,
  round : @workflow.WorkOrderPlanningRound,
) -> String {
  let context_digest = @storage.artifact_digest(
    native_work_order_planner_context_bytes(record, round),
  )
  (
    #|Plan exactly one bounded successor for this already accepted WorkOrder.
    #|First read .choir/work-order-planner-context.json, then read AGENTS.md
    #|when present. The context is an injected Choir control artifact, not part
    #|of the repository commit. Its expected SHA-256 digest is
  ) +
  " " +
  context_digest.0 +
  (
    #|. You may inspect only the read-only repository and may not edit it. Do
    #|not run tracker commands, submit a Goal, or claim completion. Return only
    #|the structured proposal.
    #|
    #|The proposal must remain within the WorkOrder objective and captured
    #|authority. finite_goal must be null or a compact JSON-encoded
    #|ConductorGoalDraft string; it must not contain a nested WorkOrder. Its
    #|primary targets and prerequisite closure must match the proposal fields.
    #|
  )
}

///|
fn normalize_native_work_order_planning_response(
  content : Bytes,
) -> Result[Bytes, @types.ChoirError] {
  let json = @json.parse(@utf8.decode(content)) catch {
    _ =>
      return Err(
        native_work_order_planning_error("planner response is not JSON"),
      )
  }
  guard json is Object(fields) else {
    return Err(
      native_work_order_planning_error("planner response is not an object"),
    )
  }
  match fields.get("finite_goal") {
    Some(String(encoded)) => {
      let goal = @json.parse(encoded) catch {
        _ =>
          return Err(
            native_work_order_planning_error(
              "finite Goal transport is not JSON",
            ),
          )
      }
      guard goal is Object(_) else {
        return Err(
          native_work_order_planning_error(
            "finite Goal transport is not an object",
          ),
        )
      }
      fields["finite_goal"] = goal
    }
    Some(Null) => ()
    // Recovered artifacts and injected adapter tests may already contain the
    // normalized workflow shape.
    Some(Object(_)) => ()
    _ =>
      return Err(
        native_work_order_planning_error(
          "finite Goal transport is missing or invalid",
        ),
      )
  }
  Ok(@utf8.encode(fields.to_json().stringify(indent=0)))
}

///|
test "WorkOrder planner transport normalizes a nested finite Goal" {
  let normalized = normalize_native_work_order_planning_response(
    @utf8.encode("{\"finite_goal\":\"{\\\"proposal_id\\\":\\\"p\\\"}\"}"),
  ).unwrap()
  let json = @json.parse(@utf8.decode(normalized))
  guard json is Object(fields) &&
    fields.get("finite_goal") is Some(Object(goal)) else {
    fail("finite Goal was not normalized")
  }
  assert_eq(goal.get("proposal_id"), Some("p".to_json()))
  assert_true(
    normalize_native_work_order_planning_response(
      @utf8.encode("{\"finite_goal\":\"[]\"}"),
    )
    is Err(_),
  )
}

///|
fn native_work_order_planner_context_bytes(
  record : @workflow.WorkOrderRecord,
  round : @workflow.WorkOrderPlanningRound,
) -> Bytes {
  @utf8.encode(
    {
      "work_order": {
        "id": record.id.to_json(),
        "repository_id": record.repository_id.to_json(),
        "objective": record.objective.to_json(),
        "selection_policy": record.selection_policy.to_json(),
        "planner": record.planner.to_json(),
        "initial_primary_target_ids": record.initial_primary_target_ids.to_json(),
        "initial_prerequisite_closure_ids": record.initial_prerequisite_closure_ids.to_json(),
        "max_active_child_goals": record.max_active_child_goals.to_json(),
        "budget": record.budget.to_json(),
        "child_goals": record.child_goals.to_json(),
        "planning_rounds": record.planning_rounds.to_json(),
        "lifecycle": record.lifecycle.to_json(),
      }.to_json(),
      "planning_round": round.to_json(),
    }
    .to_json()
    .stringify(indent=0) +
    "\n",
  )
}

///|
fn native_work_order_runtime_key(
  record : @workflow.WorkOrderRecord,
  round : @workflow.WorkOrderPlanningRound,
) -> String {
  @storage.artifact_digest(
    @utf8.encode(
      record.repository_id.0 + "\u{00}" + record.id.0 + "\u{00}" + round.id.0,
    ),
  ).0[:20].to_owned()
}

///|
fn native_work_order_executor_port(
  slot : Int,
) -> Result[Int, @types.ChoirError] {
  if slot < 0 || slot >= @types.maximum_goal_executor_jobs() {
    return Err(native_work_order_planning_error("executor slot is invalid"))
  }
  // Goal BoxLite servers use 40000..65535. WorkOrder planners occupy their own
  // 30000..39999 range, so a Goal and WorkOrder with the same slot can run at
  // once without sharing a server or port.
  Ok(30000 + (@sys.get_pid() % 10000 + slot * 7919) % 10000)
}

///|
fn native_work_order_planner_server_config(
  record : @workflow.WorkOrderRecord,
  round : @workflow.WorkOrderPlanningRound,
  executor_slot : Int,
) -> Result[NativeBoxLiteServerConfig, @types.ChoirError] {
  let key = native_work_order_runtime_key(record, round)
  let binary = match native_boxlite_binary_path() {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let runtime_dir = match native_boxlite_runtime_dir() {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let home = match native_goal_boxlite_home(record.repository_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let port = match native_work_order_executor_port(executor_slot) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    binary,
    runtime_dir,
    root: "/tmp/choir-take-work-order-" + key,
    home,
    port,
    api_key: "choir-work-order-" + key,
  })
}

///|
fn native_work_order_planner_session(
  attempt : @workflow.WorkOrderPlannerAttemptRecord,
  sandbox : NativeBoxLiteTakeSandbox,
) -> Result[@control.HarnessSession, @types.ChoirError] {
  if sandbox.workspace_access !=
    @sandbox.BoxLiteWorkspaceAccess::BoxLiteReadOnlySubject {
    return Err(
      native_work_order_planning_error("planner sandbox is not read-only"),
    )
  }
  let server = "choir_sandbox"
  let surface_digest = match attempt.surface {
    @control.ProviderSurfaceId::ClaudeSubscriptionCli =>
      @harness.claude_effective_surface_manifest_digest({
        client_version: "",
        permission_mode: "dontAsk",
        api_key_source: "none",
        tools: [..@sandbox.boxlite_assurance_mcp_tools(), "StructuredOutput"],
        mcp_servers: [
          { name: server, status: @harness.McpConnectionState::McpConnected },
        ],
        slash_commands: [],
        skills: [],
        plugins: [],
        agents: [],
      })
    @control.ProviderSurfaceId::CodexSubscriptionCli =>
      @harness.codex_effective_surface_manifest_digest(
        @sandbox.boxlite_assurance_codex_mcp_tools(),
        server,
      )
  }
  let planned : @control.HarnessSession = {
    id: attempt.session_id,
    take_id: @control.TakeId(attempt.effect_id.0),
    sandbox_generation_id: @control.SandboxGenerationId(
      "sandbox-" + attempt.id.0,
    ),
    surface: attempt.surface,
    effective_surface_manifest_digest: surface_digest,
    cursor_class: match attempt.surface {
      @control.ProviderSurfaceId::ClaudeSubscriptionCli =>
        @control.HarnessCursorClass::HarnessCursorNotResumable
      @control.ProviderSurfaceId::CodexSubscriptionCli =>
        @control.HarnessCursorClass::HarnessCursorProviderEventId
    },
    provider_cursor: None,
    last_choir_sequence: @control.EventSequence(0L),
    open_tool_execution_ids: [],
    lifecycle: @control.HarnessSessionLifecycle::HarnessSessionPlanned,
    usage: None,
  }
  match attempt.surface {
    @control.ProviderSurfaceId::ClaudeSubscriptionCli =>
      @harness.start_claude_harness_session(planned)
    @control.ProviderSurfaceId::CodexSubscriptionCli =>
      @harness.start_codex_harness_session(planned)
  }
}

///|
async fn cleanup_native_work_order_planner_runtime(
  server : NativeBoxLiteServerHandle,
  prepared : NativeBoxLitePreparedEnvironment?,
  sandbox : NativeBoxLiteTakeSandbox?,
) -> Unit {
  match sandbox {
    Some(value) => ignore(destroy_native_boxlite_take(value))
    None => ()
  }
  match prepared {
    Some(value) => ignore(destroy_native_boxlite_prepared_environment(value))
    None => ()
  }
  stop_native_boxlite_server(server)
  ignore(cleanup_native_boxlite_runtime_root(server.config))
}

///|
async fn execute_native_work_order_planner(
  project_dir : String,
  executor_slot : Int,
  record : @workflow.WorkOrderRecord,
  round : @workflow.WorkOrderPlanningRound,
) -> Result[Bytes, @types.ChoirError] {
  let repository = native_goal_repository(project_dir)
  let adapters = local_part_workflow_repository_adapters()
  let instruction = native_work_order_planner_instruction(record, round)
  let schema = native_work_order_planning_output_schema()
  let instruction_digest = @storage.artifact_digest(@utf8.encode(instruction))
  let schema_digest = @storage.artifact_digest(@utf8.encode(schema))
  let stored = match
    @workflow.ensure_work_order_planner_attempt(
      repository, adapters, record, round, instruction_digest, schema_digest,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if stored.record.lifecycle !=
    @workflow.WorkOrderPlannerAttemptLifecycle::WorkOrderPlannerAttemptPlanned {
    return Err(
      native_work_order_planning_error(
        "planner attempt is not proved never issued",
      ),
    )
  }
  let snapshot = match
    capture_native_work_order_planning_snapshot(
      project_dir, capture_command_merged,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if snapshot.repository_digest != round.repository_snapshot_digest ||
    @workflow.repository_id(snapshot.repository_root) != record.repository_id {
    return Err(
      native_work_order_planning_error(
        "repository changed before planner dispatch",
      ),
    )
  }
  let server_config = match
    native_work_order_planner_server_config(record, round, executor_slot) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if @sys.path_exists(server_config.root) {
    match cleanup_native_boxlite_runtime_root(server_config) {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
  }
  let staging = server_config.root + "/staging"
  if !@sys.create_dir_all(staging) ||
    @sys.realpath_native(staging) != Some(staging) {
    return Err(native_work_order_planning_error("staging root is unavailable"))
  }
  let source_digest = @storage.artifact_digest(
    @utf8.encode(
      "choir.work-order-planner-source.v1\u{00}" +
      snapshot.commit_oid.0 +
      "\u{00}" +
      snapshot.tree_oid.0,
    ),
  )
  let staged = match
    stage_native_git_workspace(
      {
        repository_root: snapshot.repository_root,
        object_directory: snapshot.object_directory,
        staging_root: staging,
      },
      "planner-" + native_work_order_runtime_key(record, round),
      snapshot.commit_oid,
      snapshot.tree_oid,
      source_digest,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let context_dir = staged.root + "/.choir"
  let context_path = context_dir + "/work-order-planner-context.json"
  let context = native_work_order_planner_context_bytes(record, round)
  if (!@sys.path_exists(context_dir) && !@sys.create_dir_all(context_dir)) ||
    !@sys.write_file_sync(context_path, @utf8.decode(context)) {
    return Err(
      native_work_order_planning_error("planner context staging failed"),
    )
  }
  let server = match start_native_boxlite_server(server_config) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let moon_home = match @sys.getenv("CHOIR_MOON_HOME") {
    Some(value) => value
    None =>
      match @sys.getenv("HOME") {
        Some(value) => value + "/.moon"
        None => {
          cleanup_native_work_order_planner_runtime(server, None, None)
          return Err(native_work_order_planning_error("Moon home is absent"))
        }
      }
  }
  let prepared = match
    prepare_native_boxlite_environment(
      server,
      moon_home,
      "choir-base-work-order-" + native_work_order_runtime_key(record, round),
    ) {
    Ok(value) => value
    Err(error) => {
      cleanup_native_work_order_planner_runtime(server, None, None)
      return Err(error)
    }
  }
  let mutable = match
    clone_native_boxlite_take(
      prepared,
      moon_home,
      "choir-" + native_work_order_runtime_key(record, round),
      staged.root,
      staged.source_digest,
    ) {
    Ok(value) => value
    Err(error) => {
      cleanup_native_work_order_planner_runtime(
        prepared.server,
        Some(prepared),
        None,
      )
      return Err(error)
    }
  }
  let sandbox = match seal_native_boxlite_assurance_subject(mutable) {
    Ok(value) => value
    Err(error) => {
      cleanup_native_work_order_planner_runtime(
        mutable.prepared.server,
        Some(mutable.prepared),
        Some(mutable),
      )
      return Err(error)
    }
  }
  let session = match
    native_work_order_planner_session(stored.record, sandbox) {
    Ok(value) => value
    Err(error) => {
      cleanup_native_work_order_planner_runtime(
        sandbox.prepared.server,
        Some(sandbox.prepared),
        Some(sandbox),
      )
      return Err(error)
    }
  }
  let node = match resolve_executable_in_path("node") {
    Some(value) => value
    None => {
      cleanup_native_work_order_planner_runtime(
        sandbox.prepared.server,
        Some(sandbox.prepared),
        Some(sandbox),
      )
      return Err(native_work_order_planning_error("Node is absent"))
    }
  }
  let mcp_script = match native_goal_mcp_script() {
    Some(value) => value
    None => {
      cleanup_native_work_order_planner_runtime(
        sandbox.prepared.server,
        Some(sandbox.prepared),
        Some(sandbox),
      )
      return Err(native_work_order_planning_error("sandbox MCP is absent"))
    }
  }
  let arguments = match
    native_boxlite_take_mcp_arguments(
      sandbox,
      mcp_script,
      owner_socket=Some(native_provider_owner_socket_path()),
    ) {
    Ok(value) => value
    Err(error) => {
      cleanup_native_work_order_planner_runtime(
        sandbox.prepared.server,
        Some(sandbox.prepared),
        Some(sandbox),
      )
      return Err(error)
    }
  }
  // Last durable boundary before the provider may observe the instruction.
  // Preflight failures leave Planned evidence and are exactly retryable;
  // failures after this point are conservatively reconciled as issued.
  let issued = match
    @workflow.issue_work_order_planner_attempt(
      stored.record,
      @env.now().reinterpret_as_int64() / 1000L,
    ) {
    Ok(value) => value
    Err(error) => {
      cleanup_native_work_order_planner_runtime(
        sandbox.prepared.server,
        Some(sandbox.prepared),
        Some(sandbox),
      )
      return Err(error)
    }
  }
  let issued = match
    @workflow.persist_work_order_planner_attempt_transition(
      repository, adapters, stored, issued,
    ) {
    Ok(value) => value
    Err(error) => {
      cleanup_native_work_order_planner_runtime(
        sandbox.prepared.server,
        Some(sandbox.prepared),
        Some(sandbox),
      )
      return Err(error)
    }
  }
  let terminal = match round.planner_surface {
    @control.ProviderSurfaceId::ClaudeSubscriptionCli => {
      let tools = @sandbox.boxlite_assurance_mcp_tools()
      match
        run_native_claude_take(
          {
            sterile_root: server_config.root + "/providers/claude",
            mcp_executable: node,
            mcp_arguments: arguments,
            execution_token: native_boxlite_take_execution_token(sandbox),
            boxlite_owner_socket_root: Some(
              sandbox.prepared.server.owner_socket_root,
            ),
            mcp_server_name: "choir_sandbox",
            allowed_tools: tools,
            timeout_ms: 3600000,
            connect_trace_path: None,
          },
          session,
          @harness.ClaudeTakeRole::ClaudeWorkOrderPlanningTake,
          instruction,
          fn() { @env.now().reinterpret_as_int64() / 1000L },
        ) {
        Ok(result) =>
          match result.outcome {
            @harness.ClaudeTakeOutcome::ClaudeWorkOrderPlanningCompleted =>
              Ok(result.terminal_response)
            _ =>
              Err(
                native_work_order_planning_error(
                  "Claude returned a non-planner outcome",
                ),
              )
          }
        Err(error) => Err(error)
      }
    }
    @control.ProviderSurfaceId::CodexSubscriptionCli => {
      let tools = @sandbox.boxlite_assurance_codex_mcp_tools()
      match
        run_native_codex_take(
          {
            sterile_root: server_config.root + "/providers/codex",
            mcp_executable: node,
            mcp_arguments: arguments,
            execution_token: native_boxlite_take_execution_token(sandbox),
            boxlite_owner_socket_root: Some(
              sandbox.prepared.server.owner_socket_root,
            ),
            mcp_server_name: "choir_sandbox",
            allowed_tools: tools,
            timeout_ms: 3600000,
            connect_trace_path: None,
          },
          session,
          @harness.CodexTakeRole::CodexWorkOrderPlanningTake,
          instruction,
          fn() { @env.now().reinterpret_as_int64() / 1000L },
        ) {
        Ok(result) =>
          match result.outcome {
            @harness.CodexTakeOutcome::CodexWorkOrderPlanningCompleted =>
              Ok(result.terminal_response)
            _ =>
              Err(
                native_work_order_planning_error(
                  "Codex returned a non-planner outcome",
                ),
              )
          }
        Err(error) => Err(error)
      }
    }
  }
  let content = match terminal {
    Ok(value) =>
      match normalize_native_work_order_planning_response(@utf8.encode(value)) {
        Ok(content) => content
        Err(error) => {
          cleanup_native_work_order_planner_runtime(
            sandbox.prepared.server,
            Some(sandbox.prepared),
            Some(sandbox),
          )
          return Err(error)
        }
      }
    Err(error) => {
      cleanup_native_work_order_planner_runtime(
        sandbox.prepared.server,
        Some(sandbox.prepared),
        Some(sandbox),
      )
      return Err(error)
    }
  }
  // Decode before retaining provider output. The workflow decoder is the
  // authority boundary; structured output is transport validation only.
  match @workflow.decode_work_order_planning_proposal(content) {
    Ok(_) => ()
    Err(error) => {
      cleanup_native_work_order_planner_runtime(
        sandbox.prepared.server,
        Some(sandbox.prepared),
        Some(sandbox),
      )
      return Err(error)
    }
  }
  let digest = @storage.artifact_digest(content)
  let receipt = match
    (adapters.artifacts.adopt)(repository.artifact_store, {
      content,
      expected_digest: digest,
      provenance: @storage.ArtifactProvenance::ArtifactWorkOrderPlannerResult,
      retention: @storage.ArtifactRetention::ArtifactPermanent,
    }) {
    Ok(value) => value
    Err(error) => {
      cleanup_native_work_order_planner_runtime(
        sandbox.prepared.server,
        Some(sandbox.prepared),
        Some(sandbox),
      )
      return Err(error)
    }
  }
  let completed = match
    @workflow.complete_work_order_planner_attempt(
      issued.record,
      { artifact_id: receipt.artifact_id.0, digest: receipt.digest },
      @env.now().reinterpret_as_int64() / 1000L,
    ) {
    Ok(value) => value
    Err(error) => {
      cleanup_native_work_order_planner_runtime(
        sandbox.prepared.server,
        Some(sandbox.prepared),
        Some(sandbox),
      )
      return Err(error)
    }
  }
  match
    @workflow.persist_work_order_planner_attempt_transition(
      repository, adapters, issued, completed,
    ) {
    Ok(_) => ()
    Err(error) => {
      cleanup_native_work_order_planner_runtime(
        sandbox.prepared.server,
        Some(sandbox.prepared),
        Some(sandbox),
      )
      return Err(error)
    }
  }
  cleanup_native_work_order_planner_runtime(
    sandbox.prepared.server,
    Some(sandbox.prepared),
    Some(sandbox),
  )
  Ok(content)
}

///|
fn recover_native_work_order_planner(
  project_dir : String,
  record : @workflow.WorkOrderRecord,
  round : @workflow.WorkOrderPlanningRound,
) -> Result[NativeWorkOrderPlannerRecovery, @types.ChoirError] {
  let repository = native_goal_repository(project_dir)
  let adapters = local_part_workflow_repository_adapters()
  let instruction_digest = @storage.artifact_digest(
    @utf8.encode(native_work_order_planner_instruction(record, round)),
  )
  let schema_digest = @storage.artifact_digest(
    @utf8.encode(native_work_order_planning_output_schema()),
  )
  let stored = match
    @workflow.load_work_order_planner_attempt(repository, adapters, round) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match stored {
    None => Ok(NativeWorkOrderPlannerExactRetryAuthorized)
    Some(value) => {
      if value.record.work_order_id != record.id ||
        value.record.effect_id != round.effect_id ||
        value.record.surface != round.planner_surface ||
        value.record.instruction_digest != instruction_digest ||
        value.record.schema_digest != schema_digest {
        return Err(
          native_work_order_planning_error(
            "planner attempt identity disagrees with round",
          ),
        )
      }
      match value.record.lifecycle {
        @workflow.WorkOrderPlannerAttemptLifecycle::WorkOrderPlannerAttemptPlanned =>
          Ok(NativeWorkOrderPlannerExactRetryAuthorized)
        @workflow.WorkOrderPlannerAttemptLifecycle::WorkOrderPlannerAttemptCompleted(
          artifact,
          _
        ) =>
          match
            (adapters.artifacts.read)(repository.artifact_store, {
              digest: artifact.digest,
              max_bytes: repository.max_snapshot_bytes,
            }) {
            Ok(content) =>
              if @storage.artifact_digest(content) == artifact.digest {
                Ok(NativeWorkOrderPlannerRecovered(content))
              } else {
                Err(
                  native_work_order_planning_error(
                    "planner result artifact disagrees",
                  ),
                )
              }
            Err(error) => Err(error)
          }
        @workflow.WorkOrderPlannerAttemptLifecycle::WorkOrderPlannerAttemptIssued(
          _
        ) =>
          Ok(
            NativeWorkOrderPlannerRecoveryUncertain(
              @storage.artifact_digest(
                @utf8.encode(
                  "choir.work-order-planner-issued-without-result.v1\u{00}" +
                  value.record.id.0,
                ),
              ),
            ),
          )
        @workflow.WorkOrderPlannerAttemptLifecycle::WorkOrderPlannerAttemptUncertain(
          digest
        ) => Ok(NativeWorkOrderPlannerRecoveryUncertain(digest))
      }
    }
  }
}

///|
fn native_work_order_planning_adapters(
  project_dir : String,
  executor_slot : Int,
  provider_capacity : @types.ProviderCapacityPolicy,
) -> NativeWorkOrderPlanningAdapters {
  let repository = native_goal_repository(project_dir)
  {
    capture_snapshot: async fn() {
      capture_native_work_order_planning_snapshot(
        project_dir, capture_command_merged,
      )
    },
    execute_planner: async fn(record, round) {
      execute_native_work_order_planner(
        project_dir, executor_slot, record, round,
      )
    },
    recover_planner: fn(record, round) {
      recover_native_work_order_planner(project_dir, record, round)
    },
    authorize_planner: fn(record, round) {
      authorize_native_work_order_planner(
        repository,
        record,
        round,
        provider_capacity,
        current_native_goal_fencing_epoch(),
        @env.now().reinterpret_as_int64() / 1000L,
      )
    },
    release_planner: fn(record, round) {
      release_native_work_order_planner(
        repository,
        record,
        round,
        current_native_goal_fencing_epoch(),
      )
    },
    deliver_beads: async fn(round_id, proposal) {
      deliver_native_work_order_beads(
        project_dir, round_id, proposal, capture_command_merged,
      )
    },
    now: fn() { @env.now().reinterpret_as_int64() / 1000L },
  }
}

///|
pub async fn run_native_work_order_execution_job(
  project_dir : String,
  lease : @workflow.WorkOrderExecutorLease,
  provider_capacity : @types.ProviderCapacityPolicy,
) -> (
  Result[NativeWorkOrderExecutionTick, @types.ChoirError],
  Array[@workflow.ProviderSurfaceTickReport],
) {
  let planning = native_work_order_planning_adapters(
    project_dir,
    lease.slot,
    provider_capacity,
  )
  run_native_work_order_execution_job_with_adapters(
    project_dir,
    lease,
    planning,
    fn(goal_id) { reconcile_native_work_order_child(project_dir, goal_id) },
    async fn(work_order_id) {
      let snapshot = match
        capture_native_work_order_planning_snapshot(
          project_dir, capture_command_merged,
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      admit_observed_native_work_order_successor(
        project_dir, work_order_id, snapshot, capture_command_merged,
      )
    },
  )
}

///|
pub fn plan_native_work_order_executor_dispatches(
  project_dir : String,
  capacity : @types.WorkOrderExecutorCapacityPolicy,
) -> Result[@workflow.WorkOrderExecutorDispatchBatch, @types.ChoirError] {
  match @types.validate_work_order_executor_capacity_policy(capacity) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let repository = native_goal_repository(project_dir)
  let adapters = local_part_workflow_repository_adapters()
  match @workflow.initialize_part_workflow_repository(repository, adapters) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  @workflow.acquire_work_order_executor_dispatches(
    repository,
    adapters,
    capacity.maximum_parallel_jobs,
    @env.now().reinterpret_as_int64() / 1000L,
    current_native_goal_fencing_epoch(),
  )
}

///|
pub fn complete_native_work_order_executor_dispatch(
  project_dir : String,
  lease : @workflow.WorkOrderExecutorLease,
  outcome : @workflow.WorkOrderExecutionJobTickOutcome,
) -> Result[@workflow.WorkOrderExecutionJob, @types.ChoirError] {
  @workflow.persist_work_order_executor_completion(
    native_goal_repository(project_dir),
    local_part_workflow_repository_adapters(),
    lease,
    outcome,
    @env.now().reinterpret_as_int64() / 1000L,
  )
}

///|
async fn native_work_order_capture(
  project_dir : String,
  program : String,
  arguments : Array[String],
  capture : async (Command) -> (Int, String),
) -> Result[String, @types.ChoirError] {
  let (status, output) = capture({
    program,
    args: arguments,
    workdir: Some(project_dir),
  })
  if status == 0 {
    Ok(output.trim().to_owned())
  } else {
    Err(
      native_work_order_planning_error(
        program + " snapshot command failed with status " + status.to_string(),
      ),
    )
  }
}

///|
/// Capture the exact repository commit/tree and canonical Bead graph a round
/// is planned against. Later admission compares these digests after delivery.
pub async fn capture_native_work_order_planning_snapshot(
  project_dir : String,
  capture : async (Command) -> (Int, String),
) -> Result[NativeWorkOrderPlanningSnapshot, @types.ChoirError] {
  let root = match
    native_work_order_capture(
      project_dir,
      "git",
      ["rev-parse", "--show-toplevel"],
      capture,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let commit = match
    native_work_order_capture(
      project_dir,
      "git",
      ["rev-parse", "--verify", "HEAD^{commit}"],
      capture,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let tree = match
    native_work_order_capture(
      project_dir,
      "git",
      ["show", "-s", "--format=%T", "--no-show-signature", commit],
      capture,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let object_directory = match
    native_work_order_capture(
      root,
      "git",
      ["rev-parse", "--path-format=absolute", "--git-path", "objects"],
      capture,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if @sys.realpath_native(root) != Some(root) ||
    @sys.realpath_native(object_directory) != Some(object_directory) {
    return Err(native_work_order_planning_error("Git roots are not canonical"))
  }
  let beads = match native_conductor_bead_graph(project_dir, capture) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    repository_root: root,
    object_directory,
    commit_oid: @control.GitOid(commit),
    tree_oid: @control.GitOid(tree),
    repository_digest: @storage.artifact_digest(
      @utf8.encode(
        "choir.work-order-repository-snapshot.v1\u{00}" +
        @workflow.repository_id(root).0 +
        "\u{00}" +
        commit +
        "\u{00}" +
        tree,
      ),
    ),
    bead_digest: @command.bead_graph_digest(beads),
    beads,
  })
}

///|
pub async fn deliver_native_work_order_beads(
  project_dir : String,
  _round_id : @workflow.WorkOrderPlanningRoundId,
  proposal : @command.BeadBatchProposal,
  capture : async (Command) -> (Int, String),
) -> Result[NativeWorkOrderBeadDeliveryReceipt, @types.ChoirError] {
  let applied = match apply_native_bead_batch(project_dir, proposal, capture) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    batch_digest: applied.digest,
    bead_snapshot_digest: @command.bead_graph_digest(applied.records),
  })
}

///|
/// Admit the finite Goal authorized by a delivered planning round from a
/// caller-captured repository and tracker observation.
pub async fn admit_observed_native_work_order_successor(
  project_dir : String,
  work_order_id : @workflow.WorkOrderId,
  snapshot : NativeWorkOrderPlanningSnapshot,
  capture : async (Command) -> (Int, String),
) -> Result[NativeConductorGoalSubmissionReport, @types.ChoirError] {
  let state_root = project_dir + "/.choir/state/control"
  let repository : @workflow.PartWorkflowRepository = {
    state_store: { path: state_root + "/workflow.db" },
    artifact_store: { root: state_root + "/artifacts" },
    max_snapshot_bytes: 4 * 1024 * 1024,
  }
  let repository_adapters = local_part_workflow_repository_adapters()
  let stored = match
    @workflow.load_work_order_record(
      repository, repository_adapters, work_order_id,
    ) {
    Ok(Some(value)) => value
    Ok(None) =>
      return Err(native_work_order_planning_error("WorkOrder disappeared"))
    Err(error) => return Err(error)
  }
  let stored = if stored.record.fencing_epoch.0 <
    current_native_goal_fencing_epoch().0 {
    match
      @workflow.persist_work_order_fencing_epoch_adoption(
        repository,
        repository_adapters,
        stored,
        current_native_goal_fencing_epoch(),
      ) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
  } else {
    stored
  }
  if stored.record.lifecycle != @workflow.WorkOrderLifecycle::WorkOrderActive {
    return Err(
      native_work_order_planning_error("WorkOrder no longer accepts new work"),
    )
  }
  guard stored.record.planning_rounds.last() is Some(round) &&
    (
      round.phase ==
      @workflow.WorkOrderPlanningPhase::WorkOrderPlanningBeadsDelivered ||
      round.phase ==
      @workflow.WorkOrderPlanningPhase::WorkOrderPlanningGoalReady
    ) &&
    round.proposal_artifact is Some(artifact) &&
    round.delivered_bead_snapshot_digest is Some(delivered_bead_digest) else {
    return Err(
      native_work_order_planning_error(
        "current round has no delivered successor authority",
      ),
    )
  }
  let content = match
    (repository_adapters.artifacts.read)(repository.artifact_store, {
      digest: artifact.digest,
      max_bytes: repository.max_snapshot_bytes,
    }) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let proposal = match @workflow.decode_work_order_planning_proposal(content) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  guard proposal.finite_goal is Some(goal) else {
    return Err(
      native_work_order_planning_error("delivered round has no finite Goal"),
    )
  }
  if snapshot.repository_digest != round.repository_snapshot_digest {
    return Err(
      native_work_order_planning_error(
        "repository changed after planning; successor admission requires a new round",
      ),
    )
  }
  if snapshot.bead_digest != delivered_bead_digest {
    return Err(
      native_work_order_planning_error(
        "Bead graph changed after delivery; successor admission requires a new round",
      ),
    )
  }
  let draft_json = match @workflow.successor_conductor_goal_draft_input(goal) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let report = match
    submit_native_conductor_goal_draft(
      project_dir,
      draft_json,
      capture,
      work_order_authority=Some(stored.record),
      work_order_round_id=Some(round.id),
      work_order_primary_targets=Some(proposal.primary_target_ids),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if !report.accepted || report.work_order_id != Some(work_order_id) {
    return Err(
      native_work_order_planning_error(
        "successor Goal was not accepted under its WorkOrder",
      ),
    )
  }
  Ok(report)
}

///|
/// Recapture the repository and tracker after Bead delivery, then admit the
/// finite Goal only if both observations still match durable round authority.
pub async fn admit_native_work_order_successor(
  project_dir : String,
  work_order_id : @workflow.WorkOrderId,
  capture : async (Command) -> (Int, String),
) -> Result[NativeConductorGoalSubmissionReport, @types.ChoirError] {
  let snapshot = match
    capture_native_work_order_planning_snapshot(project_dir, capture) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  admit_observed_native_work_order_successor(
    project_dir, work_order_id, snapshot, capture,
  )
}

///|
/// Reconcile one Goal observation into its durable WorkOrder owner. This runs
/// independently of new-work admission so deadlines and cutoffs cannot suppress
/// delivery accounting or terminal cleanup.
pub fn reconcile_native_work_order_child(
  project_dir : String,
  goal_id : @control.GoalId,
  now? : () -> Int64 = fn() { @env.now().reinterpret_as_int64() / 1000L },
) -> Result[@workflow.WorkOrderRecord?, @types.ChoirError] {
  let repository = native_goal_repository(project_dir)
  let adapters = local_part_workflow_repository_adapters()
  let execution = match
    @workflow.load_goal_execution_record(repository, adapters, goal_id) {
    Ok(Some(value)) => value.record
    Ok(None) =>
      return Err(native_work_order_planning_error("child Goal disappeared"))
    Err(error) => return Err(error)
  }
  guard execution.work_order_id is Some(work_order_id) else { return Ok(None) }
  let stored = match
    @workflow.load_work_order_record(repository, adapters, work_order_id) {
    Ok(Some(value)) => value
    Ok(None) =>
      return Err(native_work_order_planning_error("WorkOrder disappeared"))
    Err(error) => return Err(error)
  }
  let stored = if stored.record.fencing_epoch.0 <
    current_native_goal_fencing_epoch().0 {
    match
      @workflow.persist_work_order_fencing_epoch_adoption(
        repository,
        adapters,
        stored,
        current_native_goal_fencing_epoch(),
      ) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
  } else {
    stored
  }
  let pull_request = match
    @workflow.load_goal_pull_request_record(repository, adapters, goal_id) {
    Ok(Some(value)) => Some(value.record)
    Ok(None) => None
    Err(error) => return Err(error)
  }
  let next = match
    @workflow.reconcile_work_order_child(
      stored.record,
      execution,
      pull_request,
      now(),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if next == stored.record {
    return Ok(Some(stored.record))
  }
  match
    @workflow.persist_work_order_transition(repository, adapters, stored, next) {
    Ok(value) => Ok(Some(value.record))
    Err(error) => Err(error)
  }
}

///|
pub async fn run_native_work_order_execution_job_with_adapters(
  project_dir : String,
  lease : @workflow.WorkOrderExecutorLease,
  planning_adapters : NativeWorkOrderPlanningAdapters,
  reconcile_child : (@control.GoalId) -> Result[
    @workflow.WorkOrderRecord?,
    @types.ChoirError,
  ],
  admit_successor : async (@workflow.WorkOrderId) -> Result[
    NativeConductorGoalSubmissionReport,
    @types.ChoirError,
  ],
) -> (
  Result[NativeWorkOrderExecutionTick, @types.ChoirError],
  Array[@workflow.ProviderSurfaceTickReport],
) {
  if lease.fencing_epoch != current_native_goal_fencing_epoch() {
    return (
      Err(native_work_order_planning_error("executor lease fence is stale")),
      [],
    )
  }
  let repository = native_goal_repository(project_dir)
  let repository_adapters = local_part_workflow_repository_adapters()
  match
    @workflow.work_order_executor_lease_is_authorized(
      repository, repository_adapters, lease,
    ) {
    Ok(true) => ()
    Ok(false) =>
      return (
        Err(native_work_order_planning_error("executor lease is not held")),
        [],
      )
    Err(error) => return (Err(error), [])
  }
  let reports : Array[@workflow.ProviderSurfaceTickReport] = []
  let observed_planning_adapters : NativeWorkOrderPlanningAdapters = {
    ..planning_adapters,
    authorize_planner: (record, round) => {
      match (planning_adapters.authorize_planner)(record, round) {
        Ok(NativeWorkOrderPlannerAdmitted) => {
          reports.push({
            surface: round.planner_surface,
            disposition: @workflow.ProviderSurfaceTickDisposition::ProviderSurfaceAdmitted,
          })
          Ok(NativeWorkOrderPlannerAdmitted)
        }
        Ok(NativeWorkOrderPlannerDeferredUntil(instant)) => {
          reports.push({
            surface: round.planner_surface,
            disposition: @workflow.ProviderSurfaceTickDisposition::ProviderSurfaceDeferredUntil(
              instant,
            ),
          })
          Ok(NativeWorkOrderPlannerDeferredUntil(instant))
        }
        Err(error) => Err(error)
      }
    },
  }
  let load = fn() -> Result[@workflow.StoredWorkOrderRecord, @types.ChoirError] {
    match
      @workflow.load_work_order_record(
        repository,
        repository_adapters,
        lease.work_order_id,
      ) {
      Ok(Some(value)) => Ok(value)
      Ok(None) => Err(native_work_order_planning_error("WorkOrder disappeared"))
      Err(error) => Err(error)
    }
  }
  let before = match load() {
    Ok(value) => value
    Err(error) => return (Err(error), reports)
  }
  if before.record.lifecycle != @workflow.WorkOrderLifecycle::WorkOrderActive {
    return (Ok(NativeWorkOrderExecutionIdle), reports)
  }
  let mut active_child : @workflow.WorkOrderChildGoalBinding? = None
  for binding in before.record.child_goals {
    if binding.outcome == @workflow.WorkOrderChildOutcome::WorkOrderChildActive {
      active_child = Some(binding)
      break
    }
  }
  match active_child {
    Some(binding) =>
      match reconcile_child(binding.goal_id) {
        Ok(_) => ()
        Err(error) => return (Err(error), reports)
      }
    None => ()
  }
  let current = match load() {
    Ok(value) => value
    Err(error) => return (Err(error), reports)
  }
  if current.record.lifecycle != @workflow.WorkOrderLifecycle::WorkOrderActive {
    return (Ok(NativeWorkOrderExecutionAdvanced(current.record)), reports)
  }
  if current.record.child_goals.any(fn(binding) {
      binding.outcome == @workflow.WorkOrderChildOutcome::WorkOrderChildActive
    }) {
    return (Ok(NativeWorkOrderExecutionIdle), reports)
  }
  match current.record.planning_rounds.last() {
    Some(round) if round.phase ==
      @workflow.WorkOrderPlanningPhase::WorkOrderPlanningBeadsDelivered =>
      match admit_successor(current.record.id) {
        Ok(_) =>
          match load() {
            Ok(value) =>
              (Ok(NativeWorkOrderExecutionAdvanced(value.record)), reports)
            Err(error) => (Err(error), reports)
          }
        Err(error) => (Err(error), reports)
      }
    _ =>
      match
        run_native_work_order_planning_tick(
          repository,
          repository_adapters,
          current.record.id,
          observed_planning_adapters,
        ) {
        Ok(NativeWorkOrderPlanningIdle) =>
          (Ok(NativeWorkOrderExecutionIdle), reports)
        Ok(NativeWorkOrderPlanningAdvanced(record)) =>
          (Ok(NativeWorkOrderExecutionAdvanced(record)), reports)
        Err(error) => (Err(error), reports)
      }
  }
}

///|
fn native_work_order_planner_lease_request(
  record : @workflow.WorkOrderRecord,
  round : @workflow.WorkOrderPlanningRound,
  fencing_epoch : @control.FencingEpoch,
) -> @workflow.ProviderLeaseRequest {
  let goal_id = @control.GoalId("work-order:" + record.id.0)
  let part_id = @control.PartId("planning-round:" + round.id.0)
  {
    lease_id: @workflow.provider_lease_id(
      goal_id,
      part_id,
      round.planner_surface,
    ),
    take_id: @control.TakeId(round.effect_id.0),
    goal_id,
    fencing_epoch,
  }
}

///|
pub fn authorize_native_work_order_planner(
  repository : @workflow.PartWorkflowRepository,
  record : @workflow.WorkOrderRecord,
  round : @workflow.WorkOrderPlanningRound,
  capacity : @types.ProviderCapacityPolicy,
  fencing_epoch : @control.FencingEpoch,
  now : Int64,
) -> Result[NativeWorkOrderPlannerAdmission, @types.ChoirError] {
  match
    @workflow.acquire_provider_lease(
      repository,
      local_part_workflow_repository_adapters(),
      round.planner_surface,
      native_work_order_planner_lease_request(record, round, fencing_epoch),
      capacity,
      now,
    ) {
    Ok(@workflow.ProviderLeaseDecision::ProviderLeaseGranted(_, _)) =>
      Ok(NativeWorkOrderPlannerAdmission::NativeWorkOrderPlannerAdmitted)
    Ok(@workflow.ProviderLeaseDecision::ProviderLeaseDeferredUntil(instant)) =>
      Ok(
        NativeWorkOrderPlannerAdmission::NativeWorkOrderPlannerDeferredUntil(
          instant,
        ),
      )
    Err(error) => Err(error)
  }
}

///|
pub fn release_native_work_order_planner(
  repository : @workflow.PartWorkflowRepository,
  record : @workflow.WorkOrderRecord,
  round : @workflow.WorkOrderPlanningRound,
  fencing_epoch : @control.FencingEpoch,
) -> Result[Unit, @types.ChoirError] {
  let request = native_work_order_planner_lease_request(
    record, round, fencing_epoch,
  )
  match
    @workflow.release_provider_lease(
      repository,
      local_part_workflow_repository_adapters(),
      round.planner_surface,
      request.lease_id,
      fencing_epoch,
    ) {
    Ok(_) => Ok(())
    Err(error) => Err(error)
  }
}

///|
fn persist_native_work_order_planning(
  repository : @workflow.PartWorkflowRepository,
  repository_adapters : @workflow.PartWorkflowRepositoryAdapters,
  stored : @workflow.StoredWorkOrderRecord,
  next : @workflow.WorkOrderRecord,
) -> Result[NativeWorkOrderPlanningTick, @types.ChoirError] {
  match
    @workflow.persist_work_order_transition(
      repository, repository_adapters, stored, next,
    ) {
    Ok(value) =>
      Ok(
        NativeWorkOrderPlanningTick::NativeWorkOrderPlanningAdvanced(
          value.record,
        ),
      )
    Err(error) => Err(error)
  }
}

///|
/// Advance one crash-safe WorkOrder planning boundary.
///
/// The phase is always persisted before the corresponding provider or tracker
/// effect. Recovery therefore reconciles the exact effect or batch identity;
/// it never infers success from an empty response and never asks a passive gate
/// to produce its own evidence.
pub async fn run_native_work_order_planning_tick(
  repository : @workflow.PartWorkflowRepository,
  repository_adapters : @workflow.PartWorkflowRepositoryAdapters,
  work_order_id : @workflow.WorkOrderId,
  adapters : NativeWorkOrderPlanningAdapters,
) -> Result[NativeWorkOrderPlanningTick, @types.ChoirError] {
  let stored = match
    @workflow.load_work_order_record(
      repository, repository_adapters, work_order_id,
    ) {
    Ok(Some(value)) => value
    Ok(None) =>
      return Err(native_work_order_planning_error("WorkOrder disappeared"))
    Err(error) => return Err(error)
  }
  let stored = if stored.record.fencing_epoch.0 <
    current_native_goal_fencing_epoch().0 {
    match
      @workflow.persist_work_order_fencing_epoch_adoption(
        repository,
        repository_adapters,
        stored,
        current_native_goal_fencing_epoch(),
      ) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
  } else {
    stored
  }
  if stored.record.lifecycle != @workflow.WorkOrderLifecycle::WorkOrderActive {
    return Ok(NativeWorkOrderPlanningTick::NativeWorkOrderPlanningIdle)
  }
  match stored.record.planning_rounds.last() {
    None => {
      let snapshot = match (adapters.capture_snapshot)() {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let next = match
        @workflow.plan_work_order_round(
          stored.record,
          snapshot.repository_digest,
          snapshot.bead_digest,
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      persist_native_work_order_planning(
        repository, repository_adapters, stored, next,
      )
    }
    Some(round) =>
      match round.phase {
        @workflow.WorkOrderPlanningPhase::WorkOrderPlanningIntentRecorded => {
          match (adapters.authorize_planner)(stored.record, round) {
            Ok(NativeWorkOrderPlannerAdmitted) => ()
            Ok(NativeWorkOrderPlannerDeferredUntil(_)) =>
              return Ok(
                NativeWorkOrderPlanningTick::NativeWorkOrderPlanningIdle,
              )
            Err(error) => return Err(error)
          }
          let next = match
            @workflow.dispatch_work_order_planning_round(
              stored.record,
              (adapters.now)(),
            ) {
            Ok(value) => value
            Err(error) => return Err(error)
          }
          persist_native_work_order_planning(
            repository, repository_adapters, stored, next,
          )
        }
        @workflow.WorkOrderPlanningPhase::WorkOrderPlanningDispatched => {
          let content = match (adapters.recover_planner)(stored.record, round) {
            Ok(NativeWorkOrderPlannerRecovered(value)) => value
            Ok(NativeWorkOrderPlannerExactRetryAuthorized) =>
              match (adapters.execute_planner)(stored.record, round) {
                Ok(value) => value
                Err(error) => {
                  let failure = @storage.artifact_digest(
                    @utf8.encode(error.message()),
                  )
                  let next = match
                    @workflow.record_work_order_planner_failure(
                      stored.record,
                      failure,
                    ) {
                    Ok(value) => value
                    Err(transition_error) => return Err(transition_error)
                  }
                  let persisted = persist_native_work_order_planning(
                    repository, repository_adapters, stored, next,
                  )
                  ignore((adapters.release_planner)(stored.record, round))
                  return persisted
                }
              }
            Ok(NativeWorkOrderPlannerRecoveryUncertain(digest)) => {
              let next = match
                @workflow.record_work_order_planner_failure(
                  stored.record,
                  digest,
                ) {
                Ok(value) => value
                Err(error) => return Err(error)
              }
              let persisted = persist_native_work_order_planning(
                repository, repository_adapters, stored, next,
              )
              ignore((adapters.release_planner)(stored.record, round))
              return persisted
            }
            Err(error) => return Err(error)
          }
          if content.length() == 0 {
            let next = match
              @workflow.record_empty_work_order_planner_response(stored.record) {
              Ok(value) => value
              Err(error) => return Err(error)
            }
            let persisted = persist_native_work_order_planning(
              repository, repository_adapters, stored, next,
            )
            ignore((adapters.release_planner)(stored.record, round))
            return persisted
          }
          let digest = @storage.artifact_digest(content)
          let receipt = match
            (repository_adapters.artifacts.adopt)(repository.artifact_store, {
              content,
              expected_digest: digest,
              provenance: @storage.ArtifactProvenance::ArtifactWorkOrderRecord,
              retention: @storage.ArtifactRetention::ArtifactPermanent,
            }) {
            Ok(value) => value
            Err(error) => return Err(error)
          }
          let snapshot = match (adapters.capture_snapshot)() {
            Ok(value) => value
            Err(error) => return Err(error)
          }
          let next = match
            @workflow.record_work_order_planning_proposal(
              stored.record,
              { artifact_id: receipt.artifact_id.0, digest: receipt.digest },
              content,
              snapshot.repository_digest,
              snapshot.bead_digest,
              snapshot.beads,
              (adapters.now)(),
            ) {
            Ok(value) => value
            Err(error) => return Err(error)
          }
          let persisted = persist_native_work_order_planning(
            repository, repository_adapters, stored, next,
          )
          ignore((adapters.release_planner)(stored.record, round))
          persisted
        }
        @workflow.WorkOrderPlanningPhase::WorkOrderPlanningProposalReceived => {
          let next = match
            @workflow.begin_work_order_bead_delivery(stored.record) {
            Ok(value) => value
            Err(error) => return Err(error)
          }
          persist_native_work_order_planning(
            repository, repository_adapters, stored, next,
          )
        }
        @workflow.WorkOrderPlanningPhase::WorkOrderPlanningBeadsDelivering => {
          guard round.proposal_artifact is Some(artifact) else {
            return Err(
              native_work_order_planning_error("proposal artifact is absent"),
            )
          }
          let content = match
            (repository_adapters.artifacts.read)(repository.artifact_store, {
              digest: artifact.digest,
              max_bytes: repository.max_snapshot_bytes,
            }) {
            Ok(value) => value
            Err(error) => return Err(error)
          }
          let proposal = match
            @workflow.decode_work_order_planning_proposal(content) {
            Ok(value) => value
            Err(error) => return Err(error)
          }
          let delivered = match
            (adapters.deliver_beads)(round.id, proposal.bead_mutations) {
            Ok(value) => value
            Err(error) => return Err(error)
          }
          let next = match
            @workflow.complete_work_order_bead_delivery(
              stored.record,
              delivered.batch_digest,
              delivered.bead_snapshot_digest,
            ) {
            Ok(value) => value
            Err(error) => return Err(error)
          }
          persist_native_work_order_planning(
            repository, repository_adapters, stored, next,
          )
        }
        @workflow.WorkOrderPlanningPhase::WorkOrderPlanningBeadsDelivered =>
          Ok(NativeWorkOrderPlanningTick::NativeWorkOrderPlanningIdle)
        @workflow.WorkOrderPlanningPhase::WorkOrderPlanningGoalReady => {
          if stored.record.child_goals.any(fn(binding) {
              binding.outcome ==
              @workflow.WorkOrderChildOutcome::WorkOrderChildActive
            }) {
            return Ok(NativeWorkOrderPlanningTick::NativeWorkOrderPlanningIdle)
          }
          let snapshot = match (adapters.capture_snapshot)() {
            Ok(value) => value
            Err(error) => return Err(error)
          }
          let next = match
            @workflow.plan_work_order_round(
              stored.record,
              snapshot.repository_digest,
              snapshot.bead_digest,
            ) {
            Ok(value) => value
            Err(error) => return Err(error)
          }
          persist_native_work_order_planning(
            repository, repository_adapters, stored, next,
          )
        }
        @workflow.WorkOrderPlanningPhase::WorkOrderPlanningRoundTerminal => {
          let snapshot = match (adapters.capture_snapshot)() {
            Ok(value) => value
            Err(error) => return Err(error)
          }
          let next = match
            @workflow.continue_work_order_after_terminal_round(
              stored.record,
              snapshot.repository_digest,
              snapshot.bead_digest,
            ) {
            Ok(value) => value
            Err(error) => return Err(error)
          }
          persist_native_work_order_planning(
            repository, repository_adapters, stored, next,
          )
        }
      }
  }
}
