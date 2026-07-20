///|
pub(all) struct NativeTakeResultManifest {
  version : Int
  take_id : @control.TakeId
  sandbox_generation_id : @control.SandboxGenerationId
  result_key : String
  source_digest : @control.Digest
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct NativeSandboxResourceManifest {
  version : Int
  generation_id : @control.SandboxGenerationId
  base_box_id : String
  box_id : String
  source_digest : @control.Digest
  image_digest : @control.Digest
  tool_manifest_digest : @control.Digest
  runtime_policy_digest : @control.Digest
  workspace_access : @sandbox.BoxLiteWorkspaceAccess
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct NativePartEffectRuntimeConfig {
  repository : @workflow.PartWorkflowRepository
  repository_adapters : @workflow.PartWorkflowRepositoryAdapters
  server : NativeBoxLiteServerHandle
  git_workspace : NativeGitWorkspaceConfig
  git_integration : NativeGitIntegrationConfig
  moon_home : String
  node_executable : String
  sandbox_mcp_script : String
  claude_root : String
  codex_root : String
  provider_conformance_report_digest : (@control.ProviderSurfaceId) -> @control.Digest
  now : () -> Int64
  goal_cancellation_requested : () -> Bool
}

///|
pub(all) struct NativePartEffectRuntime {
  config : NativePartEffectRuntimeConfig
  server : Ref[NativeBoxLiteServerHandle]
  prepared : Ref[NativeBoxLitePreparedEnvironment?]
  sandboxes : Map[String, NativeBoxLiteTakeSandbox]
}

///|
fn native_part_effect_error(message : String) -> @types.ChoirError {
  @types.ChoirError::workspace_error("native Part effect: " + message)
}

///|
fn valid_native_effect_token(value : String) -> Bool {
  if value == "" || value.length() > 180 {
    return false
  }
  for index = 0; index < value.length(); index = index + 1 {
    let code = value[index].to_int()
    let valid = (code >= 'a'.to_int() && code <= 'z'.to_int()) ||
      (code >= 'A'.to_int() && code <= 'Z'.to_int()) ||
      (code >= '0'.to_int() && code <= '9'.to_int()) ||
      code == '_'.to_int() ||
      code == '-'.to_int()
    if !valid {
      return false
    }
  }
  true
}

///|
pub fn create_native_part_effect_runtime(
  config : NativePartEffectRuntimeConfig,
) -> Result[NativePartEffectRuntime, @types.ChoirError] {
  if config.git_workspace.repository_root !=
    config.git_integration.repository_root ||
    config.git_workspace.staging_root != config.server.config.root + "/staging" ||
    !config.moon_home.has_prefix("/") ||
    !config.node_executable.has_prefix("/") ||
    !config.sandbox_mcp_script.has_prefix("/") ||
    !config.claude_root.has_prefix(config.server.config.root + "/claude/") ||
    !config.codex_root.has_prefix(config.server.config.root + "/codex/") ||
    config.repository.max_snapshot_bytes <= 0 {
    return Err(
      @types.ChoirError::validation_error(
        "native Part effect runtime configuration is invalid",
      ),
    )
  }
  for
    surface in [
      @control.ProviderSurfaceId::ClaudeSubscriptionCli,
      @control.ProviderSurfaceId::CodexSubscriptionCli,
    ] {
    match
      @storage.validate_digest(
        (config.provider_conformance_report_digest)(surface),
      ) {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
  }
  Ok({
    config,
    server: @ref.new(config.server),
    prepared: @ref.new(None),
    sandboxes: Map([]),
  })
}

///|
fn native_artifact_exists(
  runtime : NativePartEffectRuntime,
  artifact : @control.ArtifactReference,
) -> Bool {
  match
    (runtime.config.repository_adapters.artifacts.contains)(
      runtime.config.repository.artifact_store,
      artifact.digest,
    ) {
    Ok(value) => value
    Err(_) => false
  }
}

///|
fn read_native_effect_artifact(
  runtime : NativePartEffectRuntime,
  digest : @control.Digest,
  max_bytes : Int,
) -> Result[Bytes, @types.ChoirError] {
  (runtime.config.repository_adapters.artifacts.read)(
    runtime.config.repository.artifact_store,
    { digest, max_bytes },
  )
}

///|
fn adopt_native_effect_artifact(
  runtime : NativePartEffectRuntime,
  goal_id : @control.GoalId,
  content : Bytes,
  provenance : @storage.ArtifactProvenance,
) -> Result[@control.ArtifactReference, @types.ChoirError] {
  let digest = @storage.artifact_digest(content)
  let receipt = match
    (runtime.config.repository_adapters.artifacts.adopt)(
      runtime.config.repository.artifact_store,
      {
        content,
        expected_digest: digest,
        provenance,
        retention: @storage.ArtifactRetention::ArtifactUntilGoalTerminal(
          goal_id,
        ),
      },
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if receipt.digest != digest || receipt.byte_length != content.length() {
    return Err(native_part_effect_error("artifact receipt is false"))
  }
  Ok({ artifact_id: @storage.artifact_id_text(receipt.artifact_id), digest })
}

///|
fn read_native_instruction(
  runtime : NativePartEffectRuntime,
  reference : @control.ArtifactReference,
) -> Result[String, @types.ChoirError] {
  let content = match
    read_native_effect_artifact(runtime, reference.digest, 16384) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let instruction = @utf8.decode(content) catch {
    _ => return Err(native_part_effect_error("instruction is not UTF-8"))
  }
  if instruction == "" {
    Err(native_part_effect_error("instruction is empty"))
  } else {
    Ok(instruction)
  }
}

///|
fn native_snapshot_session(
  snapshot : @workflow.PartWorkflowSnapshot,
  session_id : @control.HarnessSessionId,
) -> Result[@control.HarnessSession, @types.ChoirError] {
  for session in snapshot.harness_sessions {
    if session.id == session_id {
      return Ok(session)
    }
  }
  Err(native_part_effect_error("started harness session is missing"))
}

///|
fn native_sandbox_registry_root(runtime : NativePartEffectRuntime) -> String {
  runtime.server.val.config.root + "/state/sandboxes"
}

///|
fn native_sandbox_registry_path(
  runtime : NativePartEffectRuntime,
  generation_id : @control.SandboxGenerationId,
) -> Result[String, @types.ChoirError] {
  if !valid_native_effect_token(generation_id.0) {
    return Err(native_part_effect_error("sandbox generation is invalid"))
  }
  let root = native_sandbox_registry_root(runtime)
  if !@sys.create_dir_all(root) || @sys.realpath_native(root) != Some(root) {
    return Err(native_part_effect_error("sandbox registry is unavailable"))
  }
  Ok(root + "/" + generation_id.0 + ".json")
}

///|
fn store_native_sandbox_resource(
  runtime : NativePartEffectRuntime,
  generation_id : @control.SandboxGenerationId,
  sandbox : NativeBoxLiteTakeSandbox,
) -> Result[Unit, @types.ChoirError] {
  let path = match native_sandbox_registry_path(runtime, generation_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let manifest : NativeSandboxResourceManifest = {
    version: 2,
    generation_id,
    base_box_id: sandbox.prepared.base_box_id,
    box_id: sandbox.box_id,
    source_digest: sandbox.source_digest,
    image_digest: sandbox.prepared.image_digest,
    tool_manifest_digest: sandbox.prepared.tool_manifest_digest,
    runtime_policy_digest: sandbox.prepared.runtime_policy_digest,
    workspace_access: sandbox.workspace_access,
  }
  let content = manifest.to_json().stringify(indent=0) + "\n"
  if @sys.path_exists(path) {
    if @sys.read_file(path) != content {
      return Err(native_part_effect_error("sandbox registry entry conflicts"))
    }
  } else if !@sys.write_file_sync(path, content) {
    return Err(native_part_effect_error("sandbox registry write failed"))
  }
  if @sys.read_file(path) != content {
    Err(native_part_effect_error("sandbox registry receipt is false"))
  } else {
    Ok(())
  }
}

///|
async fn native_runtime_sandbox(
  runtime : NativePartEffectRuntime,
  generation_id : @control.SandboxGenerationId,
) -> Result[NativeBoxLiteTakeSandbox, @types.ChoirError] {
  match runtime.sandboxes.get(generation_id.0) {
    Some(value) => return Ok(value)
    None => ()
  }
  let path = match native_sandbox_registry_path(runtime, generation_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if !@sys.path_exists(path) {
    return Err(native_part_effect_error("sandbox generation is missing"))
  }
  let json = @json.parse(@sys.read_file(path)) catch {
    _ => return Err(native_part_effect_error("sandbox registry is not JSON"))
  }
  let manifest : NativeSandboxResourceManifest = @json.from_json(json) catch {
    _ =>
      return Err(native_part_effect_error("sandbox registry schema is invalid"))
  }
  if manifest.version != 2 ||
    manifest.generation_id != generation_id ||
    !valid_native_effect_token(manifest.base_box_id) ||
    !valid_native_effect_token(manifest.box_id) ||
    manifest.image_digest != @sandbox.boxlite_take_image_digest ||
    manifest.tool_manifest_digest !=
    @sandbox.boxlite_take_tool_manifest_digest() ||
    manifest.runtime_policy_digest !=
    @sandbox.boxlite_take_runtime_policy_digest() {
    return Err(native_part_effect_error("sandbox registry identity is invalid"))
  }
  let prepared : NativeBoxLitePreparedEnvironment = {
    server: runtime.server.val,
    base_box_id: manifest.base_box_id,
    image_digest: manifest.image_digest,
    tool_manifest_digest: manifest.tool_manifest_digest,
    runtime_policy_digest: manifest.runtime_policy_digest,
  }
  let sandbox : NativeBoxLiteTakeSandbox = {
    prepared,
    box_id: manifest.box_id,
    source_digest: manifest.source_digest,
    workspace_access: manifest.workspace_access,
  }
  match inspect_native_boxlite_take(sandbox) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  runtime.prepared.val = Some(prepared)
  runtime.sandboxes[generation_id.0] = sandbox
  Ok(sandbox)
}

///|
fn native_source_digest(
  commit_oid : @control.GitOid,
  tree_oid : @control.GitOid,
) -> @control.Digest {
  @storage.artifact_digest(
    @utf8.encode(
      "choir.native-take-source.v1\u{00}" + commit_oid.0 + "\u{00}" + tree_oid.0,
    ),
  )
}

///|
async fn prepare_native_part_sandbox(
  runtime : NativePartEffectRuntime,
  snapshot : @workflow.PartWorkflowSnapshot,
  lease : @control.SandboxLease,
) -> Result[@control.SandboxLease, @types.ChoirError] {
  let (commit_oid, tree_oid) = if lease.take_id ==
    snapshot.implementation_take.id {
    (
      snapshot.task_contract.base_commit_oid,
      snapshot.task_contract.base_tree_oid,
    )
  } else {
    match snapshot.candidate {
      Some(candidate) => (candidate.commit_oid, candidate.tree_oid)
      None => return Err(native_part_effect_error("candidate is missing"))
    }
  }
  prepare_native_source_sandbox(
    runtime,
    lease,
    commit_oid,
    tree_oid,
    read_only_subject=lease.take_id != snapshot.implementation_take.id,
  )
}

///|
async fn prepare_native_source_sandbox(
  runtime : NativePartEffectRuntime,
  lease : @control.SandboxLease,
  commit_oid : @control.GitOid,
  tree_oid : @control.GitOid,
  read_only_subject? : Bool = false,
) -> Result[@control.SandboxLease, @types.ChoirError] {
  match runtime.sandboxes.get(lease.generation_id.0) {
    Some(_) =>
      return Ok({
        ..lease,
        lifecycle: @control.SandboxLeaseLifecycle::SandboxLeaseActive,
      })
    None => ()
  }
  let prepared = match runtime.prepared.val {
    Some(value) => value
    None => {
      let value = match
        prepare_native_boxlite_environment(
          runtime.server.val,
          runtime.config.moon_home,
          "choir-base-" +
          @storage.artifact_digest(@utf8.encode(lease.generation_id.0)).0[:16].to_owned(),
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      runtime.server.val = value.server
      runtime.prepared.val = Some(value)
      value
    }
  }
  let source_digest = native_source_digest(commit_oid, tree_oid)
  let staged = match
    stage_native_git_workspace(
      runtime.config.git_workspace,
      lease.generation_id.0 + "-source",
      commit_oid,
      tree_oid,
      source_digest,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let mutable_sandbox = match
    clone_native_boxlite_take(
      prepared,
      "choir-" + lease.generation_id.0,
      staged.root,
      staged.source_digest,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let sandbox = if read_only_subject {
    match seal_native_boxlite_assurance_subject(mutable_sandbox) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
  } else {
    mutable_sandbox
  }
  runtime.server.val = sandbox.prepared.server
  runtime.prepared.val = Some(sandbox.prepared)
  match store_native_sandbox_resource(runtime, lease.generation_id, sandbox) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  runtime.sandboxes[lease.generation_id.0] = sandbox
  Ok({ ..lease, lifecycle: @control.SandboxLeaseLifecycle::SandboxLeaseActive })
}

///|
fn native_claude_config(
  runtime : NativePartEffectRuntime,
  session : @control.HarnessSession,
  sandbox : NativeBoxLiteTakeSandbox,
) -> Result[NativeClaudeDriverConfig, @types.ChoirError] {
  let arguments = match
    native_boxlite_take_mcp_arguments(
      sandbox,
      runtime.config.sandbox_mcp_script,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    sterile_root: runtime.config.claude_root + session.id.0,
    mcp_executable: runtime.config.node_executable,
    mcp_arguments: arguments,
    mcp_server_name: "choir_sandbox",
    allowed_tools: match sandbox.workspace_access {
      @sandbox.BoxLiteWorkspaceAccess::BoxLiteMutableWorkspace =>
        @sandbox.boxlite_take_mcp_tools()
      @sandbox.BoxLiteWorkspaceAccess::BoxLiteReadOnlySubject =>
        @sandbox.boxlite_assurance_mcp_tools()
    },
    timeout_ms: 3600000,
  })
}

///|
fn native_codex_config(
  runtime : NativePartEffectRuntime,
  session : @control.HarnessSession,
  sandbox : NativeBoxLiteTakeSandbox,
) -> Result[NativeCodexDriverConfig, @types.ChoirError] {
  let arguments = match
    native_boxlite_take_mcp_arguments(
      sandbox,
      runtime.config.sandbox_mcp_script,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    sterile_root: runtime.config.codex_root + session.id.0,
    mcp_executable: runtime.config.node_executable,
    mcp_arguments: arguments,
    mcp_server_name: "choir_sandbox",
    allowed_tools: match sandbox.workspace_access {
      @sandbox.BoxLiteWorkspaceAccess::BoxLiteMutableWorkspace =>
        @sandbox.boxlite_take_codex_mcp_tools()
      @sandbox.BoxLiteWorkspaceAccess::BoxLiteReadOnlySubject =>
        @sandbox.boxlite_assurance_codex_mcp_tools()
    },
    timeout_ms: 3600000,
  })
}

///|
enum NativeTakeRole {
  NativeImplementationTake
  NativeVerificationTake
  NativeAuditTake
}

///|
enum NativeTakeOutcome {
  NativeImplementationCompleted
  NativeVerificationPassed
  NativeVerificationFailed
  NativeAuditPassed
  NativeAuditFindings(Int, Int)
} derive(Eq, ToJson)

///|
struct NativeProviderResult {
  session : @control.HarnessSession
  events : Array[@control.HarnessEventEnvelope]
  terminal_response : String
  outcome : NativeTakeOutcome
  started_at : Int64
  finished_at : Int64
}

///|
async fn run_native_part_provider_take(
  runtime : NativePartEffectRuntime,
  session : @control.HarnessSession,
  sandbox : NativeBoxLiteTakeSandbox,
  role : NativeTakeRole,
  instruction : String,
) -> Result[NativeProviderResult, @types.ChoirError] {
  match session.surface {
    @control.ProviderSurfaceId::ClaudeSubscriptionCli => {
      let config = match native_claude_config(runtime, session, sandbox) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let claude_role = match role {
        NativeImplementationTake =>
          @harness.ClaudeTakeRole::ClaudeImplementationTake
        NativeVerificationTake =>
          @harness.ClaudeTakeRole::ClaudeVerificationTake
        NativeAuditTake => @harness.ClaudeTakeRole::ClaudeAuditTake
      }
      let result = match
        run_native_claude_take(
          config,
          session,
          claude_role,
          instruction,
          runtime.config.now,
          cancellation_requested=runtime.config.goal_cancellation_requested,
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let outcome = match result.outcome {
        @harness.ClaudeTakeOutcome::ClaudeImplementationCompleted =>
          NativeImplementationCompleted
        @harness.ClaudeTakeOutcome::ClaudeVerificationPassed =>
          NativeVerificationPassed
        @harness.ClaudeTakeOutcome::ClaudeVerificationFailed =>
          NativeVerificationFailed
        @harness.ClaudeTakeOutcome::ClaudeAuditPassed => NativeAuditPassed
        @harness.ClaudeTakeOutcome::ClaudeAuditFindings(total, blocking) =>
          NativeAuditFindings(total, blocking)
      }
      Ok({
        session: result.session,
        events: result.events,
        terminal_response: result.terminal_response,
        outcome,
        started_at: result.started_at,
        finished_at: result.finished_at,
      })
    }
    @control.ProviderSurfaceId::CodexSubscriptionCli => {
      let config = match native_codex_config(runtime, session, sandbox) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let codex_role = match role {
        NativeImplementationTake =>
          @harness.CodexTakeRole::CodexImplementationTake
        NativeVerificationTake => @harness.CodexTakeRole::CodexVerificationTake
        NativeAuditTake => @harness.CodexTakeRole::CodexAuditTake
      }
      let result = match
        run_native_codex_take(
          config,
          session,
          codex_role,
          instruction,
          runtime.config.now,
          cancellation_requested=runtime.config.goal_cancellation_requested,
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let outcome = match result.outcome {
        @harness.CodexTakeOutcome::CodexImplementationCompleted =>
          NativeImplementationCompleted
        @harness.CodexTakeOutcome::CodexVerificationPassed =>
          NativeVerificationPassed
        @harness.CodexTakeOutcome::CodexVerificationFailed =>
          NativeVerificationFailed
        @harness.CodexTakeOutcome::CodexAuditPassed => NativeAuditPassed
        @harness.CodexTakeOutcome::CodexAuditFindings(total, blocking) =>
          NativeAuditFindings(total, blocking)
      }
      Ok({
        session: result.session,
        events: result.events,
        terminal_response: result.terminal_response,
        outcome,
        started_at: result.started_at,
        finished_at: result.finished_at,
      })
    }
  }
}

///|
fn start_native_part_harness(
  session : @control.HarnessSession,
) -> Result[@control.HarnessSession, @types.ChoirError] {
  match session.surface {
    @control.ProviderSurfaceId::ClaudeSubscriptionCli =>
      @harness.start_claude_harness_session(session)
    @control.ProviderSurfaceId::CodexSubscriptionCli =>
      @harness.start_codex_harness_session(session)
  }
}

///|
async fn store_native_take_result(
  runtime : NativePartEffectRuntime,
  goal_id : @control.GoalId,
  take_id : @control.TakeId,
  session : @control.HarnessSession,
  sandbox : NativeBoxLiteTakeSandbox,
) -> Result[@control.ArtifactReference, @types.ChoirError] {
  let result_root = match copy_native_boxlite_take_result(sandbox) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let expected_root = sandbox.prepared.server.config.root +
    "/results/" +
    sandbox.box_id +
    "/workspace"
  if result_root != expected_root || !valid_native_effect_token(sandbox.box_id) {
    return Err(native_part_effect_error("Take result identity is invalid"))
  }
  let manifest : NativeTakeResultManifest = {
    version: 1,
    take_id,
    sandbox_generation_id: session.sandbox_generation_id,
    result_key: sandbox.box_id,
    source_digest: sandbox.source_digest,
  }
  adopt_native_effect_artifact(
    runtime,
    goal_id,
    @utf8.encode(manifest.to_json().stringify(indent=0)),
    @storage.ArtifactProvenance::ArtifactTakeOutput(take_id),
  )
}

///|
fn read_native_take_result_manifest(
  runtime : NativePartEffectRuntime,
  reference : @control.ArtifactReference,
) -> Result[NativeTakeResultManifest, @types.ChoirError] {
  let content = match
    read_native_effect_artifact(runtime, reference.digest, 8192) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let json = @json.parse(@utf8.decode_lossy(content)) catch {
    _ => return Err(native_part_effect_error("Take result is not JSON"))
  }
  let manifest : NativeTakeResultManifest = @json.from_json(json) catch {
    _ => return Err(native_part_effect_error("Take result schema is invalid"))
  }
  if manifest.version != 1 ||
    !valid_native_effect_token(manifest.result_key) ||
    manifest.source_digest.0.length() != 64 {
    Err(native_part_effect_error("Take result manifest is invalid"))
  } else {
    Ok(manifest)
  }
}

///|
fn native_take_result_root(
  runtime : NativePartEffectRuntime,
  manifest : NativeTakeResultManifest,
) -> String {
  runtime.server.val.config.root +
  "/results/" +
  manifest.result_key +
  "/workspace"
}

///|
async fn execute_native_implementation(
  runtime : NativePartEffectRuntime,
  snapshot : @workflow.PartWorkflowSnapshot,
  take_id : @control.TakeId,
  session_id : @control.HarnessSessionId,
) -> Result[@workflow.PartEffectObservation, @types.ChoirError] {
  let session = match native_snapshot_session(snapshot, session_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if take_id != snapshot.implementation_take.id || session.take_id != take_id {
    return Err(native_part_effect_error("implementation identity is stale"))
  }
  let sandbox = match
    native_runtime_sandbox(runtime, session.sandbox_generation_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let instruction = match
    read_native_instruction(
      runtime,
      snapshot.task_contract.instruction_artifact,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let result = match
    run_native_part_provider_take(
      runtime,
      session,
      sandbox,
      NativeImplementationTake,
      instruction,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if result.outcome != NativeImplementationCompleted {
    return Err(native_part_effect_error("implementation did not complete"))
  }
  let artifact = match
    store_native_take_result(
      runtime,
      snapshot.goal.id,
      take_id,
      session,
      sandbox,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok(
    @workflow.PartEffectObservation::ImplementationCompleted(
      {
        take_id,
        session_id,
        result_artifact: artifact,
        finished_at: result.finished_at,
      },
      result.session,
      result.events,
    ),
  )
}

///|
async fn normalize_native_implementation(
  runtime : NativePartEffectRuntime,
  snapshot : @workflow.PartWorkflowSnapshot,
  take_id : @control.TakeId,
  result_digest : @control.Digest,
) -> Result[@workflow.PartEffectObservation, @types.ChoirError] {
  let result = match snapshot.implementation_result {
    Some(value) if value.take_id == take_id &&
      value.result_artifact.digest == result_digest => value
    _ => return Err(native_part_effect_error("implementation result is stale"))
  }
  let manifest = match
    read_native_take_result_manifest(runtime, result.result_artifact) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if manifest.take_id != take_id ||
    manifest.sandbox_generation_id !=
    snapshot.identities.implementation_sandbox.generation_id {
    return Err(native_part_effect_error("implementation result is misbound"))
  }
  let normalized = match
    normalize_native_git_candidate(
      runtime.config.git_workspace,
      "candidate-" + take_id.0,
      snapshot.goal.id,
      snapshot.part.id,
      take_id,
      snapshot.task_contract.base_commit_oid,
      manifest.source_digest,
      native_take_result_root(runtime, manifest),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok(
    @workflow.PartEffectObservation::CandidateNormalized(
      normalized.0,
      normalized.1,
    ),
  )
}

///|
fn decode_native_verification_process(
  runtime : NativePartEffectRuntime,
  snapshot : @workflow.PartWorkflowSnapshot,
  take_id : @control.TakeId,
) -> Result[@sandbox.SandboxProcessSpec, @types.ChoirError] {
  if snapshot.task_contract.verification_specs.length() != 1 {
    return Err(native_part_effect_error("one verification spec is required"))
  }
  let spec = snapshot.task_contract.verification_specs[0]
  let content = match
    read_native_effect_artifact(runtime, spec.process_spec_digest, 65536) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let json = @json.parse(@utf8.decode_lossy(content)) catch {
    _ => return Err(native_part_effect_error("verification spec is not JSON"))
  }
  let process : @sandbox.SandboxProcessSpec = @json.from_json(json) catch {
    _ =>
      return Err(
        native_part_effect_error("verification process schema is invalid"),
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
    _ =>
      Err(native_part_effect_error("verification process authority is stale"))
  }
}

///|
pub fn native_prepared_environment_digest(
  prepared : NativeBoxLitePreparedEnvironment,
) -> @control.Digest {
  @storage.artifact_digest(
    @utf8.encode(
      "choir.prepared-environment.v1\u{00}" +
      prepared.image_digest.0 +
      "\u{00}" +
      prepared.tool_manifest_digest.0,
    ),
  )
}

///|
async fn native_post_take_tree(
  runtime : NativePartEffectRuntime,
  snapshot : @workflow.PartWorkflowSnapshot,
  take_id : @control.TakeId,
  session : @control.HarnessSession,
  sandbox : NativeBoxLiteTakeSandbox,
  candidate : @control.CandidateCommit,
  suffix : String,
) -> Result[@control.GitOid, @types.ChoirError] {
  let artifact = match
    store_native_take_result(
      runtime,
      snapshot.goal.id,
      take_id,
      session,
      sandbox,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let manifest = match read_native_take_result_manifest(runtime, artifact) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let normalized = match
    normalize_native_git_candidate(
      runtime.config.git_workspace,
      suffix + "-" + take_id.0,
      snapshot.goal.id,
      snapshot.part.id,
      take_id,
      candidate.commit_oid,
      manifest.source_digest,
      native_take_result_root(runtime, manifest),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if normalized.0.changed_paths.length() != 0 {
    Err(native_part_effect_error("assurance Take mutated its subject"))
  } else {
    Ok(normalized.0.tree_oid)
  }
}

///|
async fn execute_native_verification(
  runtime : NativePartEffectRuntime,
  snapshot : @workflow.PartWorkflowSnapshot,
  take_id : @control.TakeId,
  session_id : @control.HarnessSessionId,
  subject : @control.PartVerificationSubject,
) -> Result[@workflow.PartEffectObservation, @types.ChoirError] {
  let candidate = match snapshot.candidate {
    Some(value) if value.commit_oid == subject.candidate_commit_oid &&
      value.tree_oid == subject.candidate_tree_oid => value
    _ => return Err(native_part_effect_error("verification subject is stale"))
  }
  let session = match native_snapshot_session(snapshot, session_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let sandbox = match
    native_runtime_sandbox(runtime, session.sandbox_generation_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let process = match
    decode_native_verification_process(runtime, snapshot, take_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let started_at = (runtime.config.now)()
  let process_result = match
    execute_native_boxlite_process(
      sandbox,
      {
        goal_id: snapshot.goal.id,
        take_id,
        fencing_epoch: snapshot.fencing_epoch,
      },
      snapshot.task_contract.verification_specs[0].process_spec_digest,
      process,
      fn(artifact) { native_artifact_exists(runtime, artifact) },
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let task = match
    read_native_instruction(
      runtime,
      snapshot.task_contract.instruction_artifact,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let changed_paths = candidate.changed_paths.map(fn(path) { path.0 }).join(",")
  let instruction = "Independently verify candidate " +
    candidate.commit_oid.0 +
    " against this exact Part task:\n" +
    task +
    "\nThe candidate changed only these declared paths: " +
    changed_paths +
    ". The trusted typed verifier ran this Part's declared process with exit code " +
    process_result.exit_code.to_string() +
    ". Inspect the changed paths and declared task. Unchanged work assigned to other Parts is outside this verification subject. Return failed only for a defect attributable to this candidate or its declared verification."
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
    native_post_take_tree(
      runtime, snapshot, take_id, session, sandbox, candidate, "verification-post",
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let outcome = if process_result.exit_code == 0 &&
    provider.outcome == NativeVerificationPassed {
    @control.VerificationOutcome::VerificationPassed
  } else {
    @control.VerificationOutcome::VerificationFailed
  }
  let evidence_fields : Map[String, Json] = {
    "subject": subject.to_json(),
    "process_spec_digest": snapshot.task_contract.verification_specs[0].process_spec_digest.to_json(),
    "process_result": process_result.to_json(),
    "provider_outcome": ToJson::to_json(provider.outcome),
    "provider_terminal_response": provider.terminal_response.to_json(),
    "pre_tree": candidate.tree_oid.to_json(),
    "post_tree": post_tree.to_json(),
  }
  let evidence = match
    adopt_native_effect_artifact(
      runtime,
      snapshot.goal.id,
      @utf8.encode(evidence_fields.to_json().stringify(indent=0)),
      @storage.ArtifactProvenance::ArtifactVerificationEvidence(take_id),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok(
    @workflow.PartEffectObservation::VerificationCompleted(
      {
        take_id,
        session_id,
        verification_execution_id: @control.VerificationExecutionId(
          "verification-" + take_id.0,
        ),
        subject,
        verification_spec: snapshot.task_contract.verification_specs[0],
        environment_and_image_digest: native_prepared_environment_digest(
          sandbox.prepared,
        ),
        runtime_and_policy_digest: sandbox.prepared.runtime_policy_digest,
        subject_pre_tree_oid: candidate.tree_oid,
        subject_post_tree_oid: post_tree,
        evidence,
        started_at,
        finished_at: provider.finished_at,
        outcome,
      },
      provider.session,
      provider.events,
    ),
  )
}

///|
async fn execute_native_audit(
  runtime : NativePartEffectRuntime,
  snapshot : @workflow.PartWorkflowSnapshot,
  take_id : @control.TakeId,
  session_id : @control.HarnessSessionId,
  subject : @control.PartAuditSubject,
) -> Result[@workflow.PartEffectObservation, @types.ChoirError] {
  let candidate = match snapshot.candidate {
    Some(value) if value.commit_oid == subject.candidate_commit_oid &&
      value.tree_oid == subject.candidate_tree_oid => value
    _ => return Err(native_part_effect_error("audit subject is stale"))
  }
  let session = match native_snapshot_session(snapshot, session_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let sandbox = match
    native_runtime_sandbox(runtime, session.sandbox_generation_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let task = match
    read_native_instruction(
      runtime,
      snapshot.task_contract.instruction_artifact,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let changed_paths = candidate.changed_paths.map(fn(path) { path.0 }).join(",")
  let instruction = "Independently audit candidate " +
    candidate.commit_oid.0 +
    " against this exact Part task:\n" +
    task +
    "\nThe candidate changed only these declared paths: " +
    changed_paths +
    ". Findings must be attributable to this candidate or its task contract; unchanged work assigned to other Parts is outside this audit subject."
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
      native_post_take_tree(
        runtime, snapshot, take_id, session, sandbox, candidate, "audit-post",
      ) {
      Ok(value) => value
      Err(error) => return Err(error)
    },
  )
  let (outcome, total, blocking) = match provider.outcome {
    NativeAuditPassed => (@control.AuditOutcome::AuditPassed, 0, 0)
    NativeAuditFindings(total, blocking) =>
      (@control.AuditOutcome::AuditFindings, total, blocking)
    _ => return Err(native_part_effect_error("audit outcome is invalid"))
  }
  let findings = if total == 0 {
    None
  } else {
    match
      adopt_native_effect_artifact(
        runtime,
        snapshot.goal.id,
        @utf8.encode(provider.terminal_response),
        @storage.ArtifactProvenance::ArtifactAuditFindings(take_id),
      ) {
      Ok(value) => Some(value)
      Err(error) => return Err(error)
    }
  }
  Ok(
    @workflow.PartEffectObservation::AuditCompleted(
      {
        audit_take_id: take_id,
        take_fencing_epoch: snapshot.fencing_epoch,
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
async fn execute_native_part_effect(
  runtime : NativePartEffectRuntime,
  snapshot : @workflow.PartWorkflowSnapshot,
  intent : @workflow.PartEffectIntent,
) -> Result[@workflow.PartEffectObservation, @types.ChoirError] {
  match intent.kind {
    @workflow.PartEffectKind::PrepareImplementationSandbox(lease) =>
      match prepare_native_part_sandbox(runtime, snapshot, lease) {
        Ok(value) =>
          Ok(
            @workflow.PartEffectObservation::ImplementationSandboxPrepared(
              value,
            ),
          )
        Err(error) => Err(error)
      }
    @workflow.PartEffectKind::PrepareVerificationSandbox(lease) =>
      match prepare_native_part_sandbox(runtime, snapshot, lease) {
        Ok(value) =>
          Ok(
            @workflow.PartEffectObservation::VerificationSandboxPrepared(value),
          )
        Err(error) => Err(error)
      }
    @workflow.PartEffectKind::PrepareAuditSandbox(lease) =>
      match prepare_native_part_sandbox(runtime, snapshot, lease) {
        Ok(value) =>
          Ok(@workflow.PartEffectObservation::AuditSandboxPrepared(value))
        Err(error) => Err(error)
      }
    @workflow.PartEffectKind::StartImplementationHarness(session) =>
      match start_native_part_harness(session) {
        Ok(value) =>
          Ok(
            @workflow.PartEffectObservation::ImplementationHarnessStarted(value),
          )
        Err(error) => Err(error)
      }
    @workflow.PartEffectKind::StartVerificationHarness(session) =>
      match start_native_part_harness(session) {
        Ok(value) =>
          Ok(@workflow.PartEffectObservation::VerificationHarnessStarted(value))
        Err(error) => Err(error)
      }
    @workflow.PartEffectKind::StartAuditHarness(session) =>
      match start_native_part_harness(session) {
        Ok(value) =>
          Ok(@workflow.PartEffectObservation::AuditHarnessStarted(value))
        Err(error) => Err(error)
      }
    @workflow.PartEffectKind::DispatchImplementation(take_id, session_id) =>
      execute_native_implementation(runtime, snapshot, take_id, session_id)
    @workflow.PartEffectKind::NormalizeImplementationCandidate(take_id, digest) =>
      normalize_native_implementation(runtime, snapshot, take_id, digest)
    @workflow.PartEffectKind::DispatchVerification(take_id, session_id, subject) =>
      execute_native_verification(
        runtime, snapshot, take_id, session_id, subject,
      )
    @workflow.PartEffectKind::DispatchAudit(take_id, session_id, subject) =>
      execute_native_audit(runtime, snapshot, take_id, session_id, subject)
    @workflow.PartEffectKind::GeneratePromotion(_)
    | @workflow.PartEffectKind::ApplyIntegration(_, _) =>
      execute_native_git_effect(
        runtime.config.git_integration,
        snapshot,
        intent,
        native_git_integration_adapters(),
      )
  }
}

///|
async fn reconcile_unwitnessed_native_part_effect(
  runtime : NativePartEffectRuntime,
  snapshot : @workflow.PartWorkflowSnapshot,
  intent : @workflow.PartEffectIntent,
) -> Result[@workflow.PartEffectRecovery, @types.ChoirError] {
  match intent.kind {
    @workflow.PartEffectKind::StartImplementationHarness(_)
    | @workflow.PartEffectKind::StartVerificationHarness(_)
    | @workflow.PartEffectKind::StartAuditHarness(_)
    | @workflow.PartEffectKind::NormalizeImplementationCandidate(_, _) =>
      Ok(@workflow.PartEffectRecovery::ExactEffectRetryAuthorized)
    @workflow.PartEffectKind::GeneratePromotion(_)
    | @workflow.PartEffectKind::ApplyIntegration(_, _) =>
      reconcile_native_git_effect(
        runtime.config.git_integration,
        snapshot,
        intent,
        native_git_integration_adapters(),
      )
    @workflow.PartEffectKind::PrepareImplementationSandbox(lease)
    | @workflow.PartEffectKind::PrepareVerificationSandbox(lease)
    | @workflow.PartEffectKind::PrepareAuditSandbox(lease) =>
      match runtime.sandboxes.get(lease.generation_id.0) {
        Some(_) => Ok(@workflow.PartEffectRecovery::ExactEffectRetryAuthorized)
        None => Ok(@workflow.PartEffectRecovery::EffectWitnessUnavailable)
      }
    @workflow.PartEffectKind::DispatchImplementation(_, _)
    | @workflow.PartEffectKind::DispatchVerification(_, _, _)
    | @workflow.PartEffectKind::DispatchAudit(_, _, _) => {
      let session_id = match intent.kind {
        @workflow.PartEffectKind::DispatchImplementation(_, id)
        | @workflow.PartEffectKind::DispatchVerification(_, id, _)
        | @workflow.PartEffectKind::DispatchAudit(_, id, _) => id
        _ => return Ok(@workflow.PartEffectRecovery::EffectWitnessUnavailable)
      }
      let session = match native_snapshot_session(snapshot, session_id) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      match session.surface {
        @control.ProviderSurfaceId::CodexSubscriptionCli =>
          Ok(@workflow.PartEffectRecovery::ExactEffectRetryAuthorized)
        @control.ProviderSurfaceId::ClaudeSubscriptionCli =>
          Ok(@workflow.PartEffectRecovery::EffectWitnessUnavailable)
      }
    }
  }
}

///|
pub fn native_part_effect_adapters(
  runtime : NativePartEffectRuntime,
) -> @workflow.PartWorkflowDriverAdapters {
  {
    execute: async fn(snapshot, intent) {
      execute_native_part_effect(runtime, snapshot, intent)
    },
    reconcile: async fn(snapshot, intent) {
      reconcile_unwitnessed_native_part_effect(runtime, snapshot, intent)
    },
  }
}

///|
pub async fn cleanup_native_part_effect_runtime(
  runtime : NativePartEffectRuntime,
) -> Result[Unit, @types.ChoirError] {
  cleanup_native_boxlite_server(runtime.server.val)
}
