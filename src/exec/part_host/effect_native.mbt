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
  server : @take_host.NativeBoxLiteServerHandle
  git_workspace : @git_host.NativeGitWorkspaceConfig
  git_integration : @git_integration.NativeGitIntegrationConfig
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
  server : Ref[@take_host.NativeBoxLiteServerHandle]
  prepared : Ref[@take_host.NativeBoxLitePreparedEnvironment?]
  sandboxes : Map[String, @take_host.NativeBoxLiteTakeSandbox]
}

///|
fn native_part_effect_error(message : String) -> @types.ChoirError {
  @types.ChoirError::workspace_error("native Part effect: " + message)
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
pub fn read_native_effect_artifact(
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
pub fn adopt_native_effect_artifact(
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
pub fn read_native_instruction(
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
fn execute_native_command_preparation(
  runtime : NativePartEffectRuntime,
  snapshot : @workflow.PartWorkflowSnapshot,
  plan : @workflow.PartCommandPreparationPlan,
) -> Result[@workflow.PartPreparedCommand, @types.ChoirError] {
  let template = @command.default_command_template(plan.role)
  if template.digest != plan.template_digest {
    return Err(@types.ChoirError::command_preparation_stale_binding())
  }
  let context_artifacts : Array[@command.CommandContextArtifact] = []
  for
    digest in @command.required_part_context_digests(
      plan.instruction_artifact_digest,
      plan.context_manifest,
    ) {
    let content = match
      read_native_effect_artifact(runtime, digest, plan.maximum_command_bytes) {
      Ok(value) => value
      Err(_) =>
        return Err(
          @types.ChoirError::command_preparation_missing_required_artifact(
            digest.0,
          ),
        )
    }
    context_artifacts.push({ digest, content })
  }
  let prepared = match
    @command.prepare_command({
      schema_version: 1,
      take: plan.take,
      subject: plan.subject,
      goal_contract_digest: plan.goal_contract_digest,
      task_contract_revision_id: plan.task_contract_revision_id,
      task_contract_digest: plan.task_contract_digest,
      instruction_artifact_digest: plan.instruction_artifact_digest,
      migration_contract_ref: plan.migration_contract_ref,
      provider_surface: plan.provider_surface,
      provider_surface_and_profile_digest: plan.provider_surface_and_profile_digest,
      context_assembly_policy_digest: plan.context_assembly_policy_digest,
      context_manifest: plan.context_manifest,
      template,
      context_artifacts,
      maximum_command_bytes: plan.maximum_command_bytes,
    }) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let command_artifact = match
    adopt_native_effect_artifact(
      runtime,
      snapshot.goal.id,
      prepared.command_bytes,
      @storage.ArtifactProvenance::ArtifactHarnessCommand(plan.take.id),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if command_artifact.digest != prepared.provenance.command_artifact_digest {
    return Err(@types.ChoirError::command_preparation_digest_mismatch())
  }
  Ok({ plan, command_artifact, provenance: prepared.provenance })
}

///|
fn read_native_harness_command(
  runtime : NativePartEffectRuntime,
  command : @control.HarnessCommandIntent,
) -> Result[String, @types.ChoirError] {
  let content = match
    read_native_effect_artifact(
      runtime,
      command.command_artifact_digest,
      1048576,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let instruction = @utf8.decode(content) catch {
    _ => return Err(native_part_effect_error("prepared command is not UTF-8"))
  }
  if instruction == "" {
    Err(native_part_effect_error("prepared command is empty"))
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
  if !@sandbox.valid_boxlite_state_token(generation_id.0) {
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
  sandbox : @take_host.NativeBoxLiteTakeSandbox,
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
fn read_native_sandbox_resource(
  runtime : NativePartEffectRuntime,
  generation_id : @control.SandboxGenerationId,
) -> Result[@take_host.NativeBoxLiteTakeSandbox, @types.ChoirError] {
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
    !@sandbox.valid_boxlite_state_token(manifest.base_box_id) ||
    !@sandbox.valid_boxlite_state_token(manifest.box_id) ||
    manifest.image_digest != @sandbox.boxlite_take_image_digest ||
    manifest.tool_manifest_digest !=
    @sandbox.boxlite_take_tool_manifest_digest() ||
    manifest.runtime_policy_digest !=
    @sandbox.boxlite_take_runtime_policy_digest() {
    return Err(native_part_effect_error("sandbox registry identity is invalid"))
  }
  let prepared : @take_host.NativeBoxLitePreparedEnvironment = {
    server: runtime.server.val,
    base_box_id: manifest.base_box_id,
    image_digest: manifest.image_digest,
    tool_manifest_digest: manifest.tool_manifest_digest,
    runtime_policy_digest: manifest.runtime_policy_digest,
  }
  let sandbox : @take_host.NativeBoxLiteTakeSandbox = {
    prepared,
    box_id: manifest.box_id,
    source_digest: manifest.source_digest,
    workspace_access: manifest.workspace_access,
  }
  Ok(sandbox)
}

///|
pub fn native_runtime_owned_box_ids(
  runtime_root : String,
  path_exists? : (String) -> Bool = @sys.path_exists,
  canonicalize? : (String) -> String? = @sys.realpath_native,
  list_dir? : (String) -> Array[String] = @sys.list_dir,
  read_file? : (String) -> String = @sys.read_file,
) -> Result[Array[String], @types.ChoirError] {
  let registry = runtime_root + "/state/sandboxes"
  if !path_exists(registry) {
    return Ok([])
  }
  if canonicalize(runtime_root) != Some(runtime_root) ||
    canonicalize(registry) != Some(registry) {
    return Err(native_part_effect_error("sandbox registry is not canonical"))
  }
  let owned : Array[String] = []
  for entry in list_dir(registry) {
    let suffix = ".json"
    if !entry.has_suffix(suffix) || entry.length() <= suffix.length() {
      return Err(native_part_effect_error("sandbox registry entry is invalid"))
    }
    let generation = entry[:entry.length() - suffix.length()].to_owned()
    if !@sandbox.valid_boxlite_state_token(generation) {
      return Err(
        native_part_effect_error("sandbox registry identity is invalid"),
      )
    }
    let json = @json.parse(read_file(registry + "/" + entry)) catch {
      _ => return Err(native_part_effect_error("sandbox registry is not JSON"))
    }
    let manifest : NativeSandboxResourceManifest = @json.from_json(json) catch {
      _ =>
        return Err(
          native_part_effect_error("sandbox registry schema is invalid"),
        )
    }
    if manifest.version != 2 ||
      manifest.generation_id != @control.SandboxGenerationId(generation) ||
      !@sandbox.valid_boxlite_state_token(manifest.base_box_id) ||
      !@sandbox.valid_boxlite_state_token(manifest.box_id) ||
      manifest.image_digest != @sandbox.boxlite_take_image_digest ||
      manifest.tool_manifest_digest !=
      @sandbox.boxlite_take_tool_manifest_digest() ||
      manifest.runtime_policy_digest !=
      @sandbox.boxlite_take_runtime_policy_digest() {
      return Err(
        native_part_effect_error("sandbox registry identity is invalid"),
      )
    }
    if !owned.contains(manifest.box_id) {
      owned.push(manifest.box_id)
    }
    if !owned.contains(manifest.base_box_id) {
      owned.push(manifest.base_box_id)
    }
  }
  Ok(owned)
}

///|
test "runtime owned-box observation fails closed before returning IDs" {
  let root = "/tmp/choir-take-owned-observation"
  let registry = root + "/state/sandboxes"
  assert_true(
    native_runtime_owned_box_ids(
      root,
      path_exists=fn(path) { path == registry },
      canonicalize=fn(path) { Some(path) },
      list_dir=fn(_) { ["generation.json", "unexpected"] },
      read_file=fn(_) { "{}" },
    )
    is Err(_),
  )
}

///|
pub async fn native_runtime_sandbox(
  runtime : NativePartEffectRuntime,
  generation_id : @control.SandboxGenerationId,
) -> Result[@take_host.NativeBoxLiteTakeSandbox, @types.ChoirError] {
  match runtime.sandboxes.get(generation_id.0) {
    Some(value) => return Ok(value)
    None => ()
  }
  let sandbox = match read_native_sandbox_resource(runtime, generation_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match @take_host.inspect_native_boxlite_take(sandbox) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  runtime.prepared.val = Some(sandbox.prepared)
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
fn native_part_sandbox_source(
  implementation : Bool,
  contract_source : @workflow.PartRepairSource,
  candidate_source : @workflow.PartRepairSource?,
) -> Result[(@control.GitOid, @control.GitOid, Bool), @types.ChoirError] {
  if implementation {
    Ok((contract_source.commit_oid, contract_source.tree_oid, false))
  } else {
    match candidate_source {
      Some(candidate) => Ok((candidate.commit_oid, candidate.tree_oid, true))
      None => Err(native_part_effect_error("candidate is missing"))
    }
  }
}

///|
async fn prepare_native_part_sandbox(
  runtime : NativePartEffectRuntime,
  snapshot : @workflow.PartWorkflowSnapshot,
  lease : @control.SandboxLease,
) -> Result[@control.SandboxLease, @types.ChoirError] {
  let candidate_source : @workflow.PartRepairSource? = snapshot.candidate.map(fn(
    candidate,
  ) {
    { commit_oid: candidate.commit_oid, tree_oid: candidate.tree_oid }
  })
  let (commit_oid, tree_oid, read_only_subject) = match
    native_part_sandbox_source(
      lease.take_id == snapshot.implementation_take.id,
      {
        commit_oid: snapshot.task_contract.base_commit_oid,
        tree_oid: snapshot.task_contract.base_tree_oid,
      },
      candidate_source,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  prepare_native_source_sandbox(
    runtime,
    lease,
    commit_oid,
    tree_oid,
    read_only_subject~,
  )
}

///|
test "implementation sandbox selects the contract base after repair" {
  let contract_source : @workflow.PartRepairSource = {
    commit_oid: @control.GitOid("rejected-candidate"),
    tree_oid: @control.GitOid("rejected-tree"),
  }
  match native_part_sandbox_source(true, contract_source, None) {
    Ok((commit_oid, tree_oid, read_only)) => {
      assert_eq(commit_oid, @control.GitOid("rejected-candidate"))
      assert_eq(tree_oid, @control.GitOid("rejected-tree"))
      assert_false(read_only)
    }
    Err(error) => fail(error.message())
  }
  let candidate_source : @workflow.PartRepairSource = {
    commit_oid: @control.GitOid("verified-candidate"),
    tree_oid: @control.GitOid("verified-tree"),
  }
  match
    native_part_sandbox_source(false, contract_source, Some(candidate_source)) {
    Ok((commit_oid, tree_oid, read_only)) => {
      assert_eq(commit_oid, @control.GitOid("verified-candidate"))
      assert_eq(tree_oid, @control.GitOid("verified-tree"))
      assert_true(read_only)
    }
    Err(error) => fail(error.message())
  }
  assert_true(
    native_part_sandbox_source(false, contract_source, None) is Err(_),
  )
}

///|
pub async fn prepare_native_source_sandbox(
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
        @take_host.prepare_native_boxlite_environment(
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
    @git_host.stage_native_git_workspace(
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
    @take_host.clone_native_boxlite_take(
      prepared,
      runtime.config.moon_home,
      "choir-" + lease.generation_id.0,
      staged.root,
      staged.source_digest,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let sandbox = if read_only_subject {
    match @take_host.seal_native_boxlite_assurance_subject(mutable_sandbox) {
      Ok(value) => value
      Err(error) => {
        ignore(@take_host.destroy_native_boxlite_take(mutable_sandbox))
        return Err(error)
      }
    }
  } else {
    mutable_sandbox
  }
  runtime.server.val = sandbox.prepared.server
  runtime.prepared.val = Some(sandbox.prepared)
  match store_native_sandbox_resource(runtime, lease.generation_id, sandbox) {
    Ok(_) => ()
    Err(error) => {
      ignore(@take_host.destroy_native_boxlite_take(sandbox))
      return Err(error)
    }
  }
  runtime.sandboxes[lease.generation_id.0] = sandbox
  Ok({ ..lease, lifecycle: @control.SandboxLeaseLifecycle::SandboxLeaseActive })
}

///|
fn native_claude_config(
  runtime : NativePartEffectRuntime,
  session : @control.HarnessSession,
  sandbox : @take_host.NativeBoxLiteTakeSandbox,
) -> Result[@provider_host.NativeClaudeDriverConfig, @types.ChoirError] {
  let arguments = match
    @take_host.native_boxlite_take_mcp_arguments(
      sandbox,
      runtime.config.sandbox_mcp_script,
      owner_socket=Some(@provider_host.native_provider_owner_socket_path()),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    sterile_root: runtime.config.claude_root + session.id.0,
    mcp_executable: runtime.config.node_executable,
    mcp_arguments: arguments,
    execution_token: @take_host.native_boxlite_take_execution_token(sandbox),
    boxlite_owner_socket_root: Some(sandbox.prepared.server.owner_socket_root),
    mcp_server_name: "choir_sandbox",
    allowed_tools: match sandbox.workspace_access {
      @sandbox.BoxLiteWorkspaceAccess::BoxLiteMutableWorkspace =>
        @sandbox.boxlite_take_mcp_tools()
      @sandbox.BoxLiteWorkspaceAccess::BoxLiteReadOnlySubject =>
        @sandbox.boxlite_assurance_mcp_tools()
    },
    timeout_ms: 3600000,
    connect_trace_path: None,
  })
}

///|
fn native_codex_config(
  runtime : NativePartEffectRuntime,
  session : @control.HarnessSession,
  sandbox : @take_host.NativeBoxLiteTakeSandbox,
) -> Result[@provider_host.NativeCodexDriverConfig, @types.ChoirError] {
  let sterile_root = runtime.config.codex_root + session.id.0
  let arguments = match
    @take_host.native_boxlite_take_mcp_arguments(
      sandbox,
      runtime.config.sandbox_mcp_script,
      owner_socket=Some(@provider_host.native_provider_owner_socket_path()),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    sterile_root,
    mcp_executable: runtime.config.node_executable,
    mcp_arguments: arguments,
    execution_token: @take_host.native_boxlite_take_execution_token(sandbox),
    boxlite_owner_socket_root: Some(sandbox.prepared.server.owner_socket_root),
    mcp_server_name: "choir_sandbox",
    allowed_tools: match sandbox.workspace_access {
      @sandbox.BoxLiteWorkspaceAccess::BoxLiteMutableWorkspace =>
        @sandbox.boxlite_take_codex_mcp_tools()
      @sandbox.BoxLiteWorkspaceAccess::BoxLiteReadOnlySubject =>
        @sandbox.boxlite_assurance_codex_mcp_tools()
    },
    timeout_ms: 3600000,
    connect_trace_path: None,
  })
}

///|
pub(all) enum NativeTakeRole {
  NativeImplementationTake
  NativeAuditTake
}

///|
pub(all) enum NativeTakeOutcome {
  NativeImplementationCompleted
  NativeAuditPassed
  NativeAuditFindings(Int, Int)
} derive(Eq, ToJson)

///|
pub(all) struct NativeProviderResult {
  session : @control.HarnessSession
  events : Array[@control.HarnessEventEnvelope]
  terminal_response : String
  outcome : NativeTakeOutcome
  started_at : Int64
  finished_at : Int64
}

///|
pub async fn run_native_part_provider_take(
  runtime : NativePartEffectRuntime,
  session : @control.HarnessSession,
  sandbox : @take_host.NativeBoxLiteTakeSandbox,
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
        NativeAuditTake => @harness.ClaudeTakeRole::ClaudeAuditTake
      }
      let result = match
        @provider_host.run_native_claude_take(
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
        @harness.ClaudeTakeOutcome::ClaudeAuditPassed => NativeAuditPassed
        @harness.ClaudeTakeOutcome::ClaudeAuditFindings(total, blocking) =>
          NativeAuditFindings(total, blocking)
        @harness.ClaudeTakeOutcome::ClaudeWorkOrderPlanningCompleted =>
          return Err(
            native_part_effect_error(
              "WorkOrder planner outcome reached a Part Take",
            ),
          )
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
        NativeAuditTake => @harness.CodexTakeRole::CodexAuditTake
      }
      let result = match
        @provider_host.run_native_codex_take(
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
        @harness.CodexTakeOutcome::CodexAuditPassed => NativeAuditPassed
        @harness.CodexTakeOutcome::CodexAuditFindings(total, blocking) =>
          NativeAuditFindings(total, blocking)
        @harness.CodexTakeOutcome::CodexWorkOrderPlanningCompleted =>
          return Err(
            native_part_effect_error(
              "WorkOrder planner outcome reached a Part Take",
            ),
          )
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
pub fn start_native_part_harness(
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
pub async fn store_native_take_result(
  runtime : NativePartEffectRuntime,
  goal_id : @control.GoalId,
  take_id : @control.TakeId,
  sandbox_generation_id : @control.SandboxGenerationId,
  sandbox : @take_host.NativeBoxLiteTakeSandbox,
) -> Result[@control.ArtifactReference, @types.ChoirError] {
  let result_root = match @take_host.copy_native_boxlite_take_result(sandbox) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let expected_root = sandbox.prepared.server.config.root +
    "/results/" +
    sandbox.box_id +
    "/workspace"
  if result_root != expected_root ||
    !@sandbox.valid_boxlite_state_token(sandbox.box_id) {
    return Err(native_part_effect_error("Take result identity is invalid"))
  }
  let manifest : NativeTakeResultManifest = {
    version: 1,
    take_id,
    sandbox_generation_id,
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
pub fn read_native_take_result_manifest(
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
    !@sandbox.valid_boxlite_state_token(manifest.result_key) ||
    manifest.source_digest.0.length() != 64 {
    Err(native_part_effect_error("Take result manifest is invalid"))
  } else {
    Ok(manifest)
  }
}

///|
pub fn native_take_result_root(
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
  command : @control.HarnessCommandIntent,
) -> Result[@workflow.PartEffectObservation, @types.ChoirError] {
  let session_id = command.session_id
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
  let instruction = match read_native_harness_command(runtime, command) {
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
      session.sandbox_generation_id,
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
    @git_host.normalize_native_git_candidate(
      runtime.config.git_workspace,
      "candidate-" + take_id.0,
      snapshot.goal.id,
      snapshot.part.id,
      take_id,
      snapshot.task_contract.commit_title,
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
  // The authority proves this process spec was minted for this Part's
  // verification, which the spec identity and digest carry. The Take that
  // minted it is fixed at submission, while a retried Part is fenced onto a
  // fresh verification Take, so demanding the current Take rejected the
  // Part's own spec on every retry. A superseded Take of this same Part still
  // authorizes it; anything else does not.
  match process.authority {
    @sandbox.SandboxProcessAuthority::SandboxVerificationTool(
      authority_take_id,
      verification_spec_id,
      verification_spec_digest
    ) if verification_spec_id == spec.id &&
      verification_spec_digest == spec.digest &&
      (
        authority_take_id == take_id ||
        snapshot.prior_takes.any(fn(prior) { prior.id == authority_take_id })
      ) => Ok(process)
    _ =>
      Err(native_part_effect_error("verification process authority is stale"))
  }
}

///|
pub fn native_prepared_environment_digest(
  prepared : @take_host.NativeBoxLitePreparedEnvironment,
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
  sandbox_generation_id : @control.SandboxGenerationId,
  sandbox : @take_host.NativeBoxLiteTakeSandbox,
  candidate : @control.CandidateCommit,
  suffix : String,
) -> Result[@control.GitOid, @types.ChoirError] {
  match @take_host.cleanup_native_boxlite_assurance_subject(sandbox) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let artifact = match
    store_native_take_result(
      runtime,
      snapshot.goal.id,
      take_id,
      sandbox_generation_id,
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
    @git_host.normalize_native_git_candidate(
      runtime.config.git_workspace,
      suffix + "-" + take_id.0,
      snapshot.goal.id,
      snapshot.part.id,
      take_id,
      snapshot.task_contract.commit_title,
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
  intent : @workflow.PartEffectIntent,
  take_id : @control.TakeId,
  subject : @control.PartVerificationSubject,
) -> Result[@workflow.PartEffectObservation, @types.ChoirError] {
  let candidate = match snapshot.candidate {
    Some(value) if value.commit_oid == subject.candidate_commit_oid &&
      value.tree_oid == subject.candidate_tree_oid => value
    _ => return Err(native_part_effect_error("verification subject is stale"))
  }
  let sandbox = match
    native_runtime_sandbox(
      runtime,
      snapshot.identities.verification_sandbox.generation_id,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let process = match
    decode_native_verification_process(runtime, snapshot, take_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  // The task contract's verification process is minted once, against the Take
  // that existed at submission. A retried Part runs on a fresh verification
  // Take, and the sandbox capability admits a process only for the Take it is
  // executing, so the contract's own spec was refused. Rebinding the
  // authority to the executing Take — and adopting that exact bytes as the
  // persisted spec — keeps the digest the executor validates honest without
  // rewriting the immutable contract. This mirrors how Goal-level assurance
  // rebinds each Part spec onto its own verification Take.
  let spec = snapshot.task_contract.verification_specs[0]
  let authority_take_id = match process.authority {
    @sandbox.SandboxProcessAuthority::SandboxImplementationTool(id, _)
    | @sandbox.SandboxProcessAuthority::SandboxVerificationTool(id, _, _)
    | @sandbox.SandboxProcessAuthority::SandboxAuditTool(id, _) => id
  }
  let (persisted_digest, bound_process) = if authority_take_id == take_id {
    (spec.process_spec_digest, process)
  } else {
    let rebound = {
      ..process,
      authority: @sandbox.SandboxProcessAuthority::SandboxVerificationTool(
        take_id,
        spec.id,
        spec.digest,
      ),
    }
    match
      adopt_native_effect_artifact(
        runtime,
        snapshot.goal.id,
        @utf8.encode(rebound.to_json().stringify(indent=0)),
        @storage.ArtifactProvenance::ArtifactVerificationProcessSpec(spec.id),
      ) {
      Ok(reference) => (reference.digest, rebound)
      Err(error) => return Err(error)
    }
  }
  let process_result = match
    execute_durable_native_boxlite_process(
      runtime, snapshot, intent, take_id, sandbox, persisted_digest, bound_process,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let started_at = match process_result.started_at {
    Some(value) => value
    None =>
      return Err(native_part_effect_error("process start was not durable"))
  }
  let finished_at = match process_result.finished_at {
    Some(value) => value
    None =>
      return Err(native_part_effect_error("process finish was not durable"))
  }
  let post_tree = match
    native_post_take_tree(
      runtime,
      snapshot,
      take_id,
      snapshot.identities.verification_sandbox.generation_id,
      sandbox,
      candidate,
      "verification-post",
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let outcome = if process_result.exit_code == 0 {
    @control.VerificationOutcome::VerificationPassed
  } else {
    @control.VerificationOutcome::VerificationFailed
  }
  let evidence_fields : Map[String, Json] = {
    "subject": subject.to_json(),
    "process_spec_digest": snapshot.task_contract.verification_specs[0].process_spec_digest.to_json(),
    "process_result": @take_host.native_sandbox_process_evidence(process_result),
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
    @workflow.PartEffectObservation::VerificationCompleted({
      take_id,
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
      finished_at,
      outcome,
    }),
  )
}

///|
async fn execute_native_audit(
  runtime : NativePartEffectRuntime,
  snapshot : @workflow.PartWorkflowSnapshot,
  take_id : @control.TakeId,
  command : @control.HarnessCommandIntent,
  subject : @control.PartAuditSubject,
) -> Result[@workflow.PartEffectObservation, @types.ChoirError] {
  let session_id = command.session_id
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
  let passed_verification_receipts = snapshot.verification_receipts.filter(fn(
    receipt,
  ) {
    receipt.subject.part_id == subject.part_id &&
    receipt.subject.candidate_commit_oid == subject.candidate_commit_oid &&
    receipt.outcome == @control.VerificationOutcome::VerificationPassed
  })
  if passed_verification_receipts.length() == 0 {
    return Err(
      native_part_effect_error("audit lacks passed verification evidence"),
    )
  }
  let instruction = match read_native_harness_command(runtime, command) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
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
        runtime,
        snapshot,
        take_id,
        session.sandbox_generation_id,
        sandbox,
        candidate,
        "audit-post",
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
  match
    @provider_host.native_audit_repair_findings(
      provider.terminal_response,
      total,
      blocking,
    ) {
    Ok(repair_findings) =>
      for finding in repair_findings {
        if finding.severity ==
          @provider_host.NativeRepairFindingSeverity::Blocking {
          for raw_path in finding.affected_paths {
            if !@control.mutation_declaration_covers(
                snapshot.task_contract.mutation_declaration,
                @control.RepoPath(raw_path),
              ) {
              return Err(
                native_part_effect_error(
                  "blocking audit repair path is outside the Part mutation declaration",
                ),
              )
            }
          }
        }
      }
    Err(error) => return Err(error)
  }
  let findings = match snapshot.task_contract.migration_contract_ref {
    Some(_) =>
      match
        native_migration_findings_artifact(
          runtime,
          snapshot,
          take_id,
          subject,
          provider.terminal_response,
          total,
          blocking,
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
    None if total == 0 => None
    None =>
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
    @workflow.PartEffectKind::PrepareImplementationCommand(plan) =>
      match execute_native_command_preparation(runtime, snapshot, plan) {
        Ok(value) =>
          Ok(
            @workflow.PartEffectObservation::ImplementationCommandPrepared(
              value,
            ),
          )
        Err(error) => Err(error)
      }
    @workflow.PartEffectKind::PrepareAuditCommand(plan) =>
      match execute_native_command_preparation(runtime, snapshot, plan) {
        Ok(value) =>
          Ok(@workflow.PartEffectObservation::AuditCommandPrepared(value))
        Err(error) => Err(error)
      }
    @workflow.PartEffectKind::StartImplementationHarness(session, _) =>
      match start_native_part_harness(session) {
        Ok(value) =>
          Ok(
            @workflow.PartEffectObservation::ImplementationHarnessStarted(value),
          )
        Err(error) => Err(error)
      }
    @workflow.PartEffectKind::StartAuditHarness(session, _) =>
      match start_native_part_harness(session) {
        Ok(value) =>
          Ok(@workflow.PartEffectObservation::AuditHarnessStarted(value))
        Err(error) => Err(error)
      }
    @workflow.PartEffectKind::DispatchImplementation(take_id, command) =>
      execute_native_implementation(runtime, snapshot, take_id, command)
    @workflow.PartEffectKind::NormalizeImplementationCandidate(take_id, digest) =>
      normalize_native_implementation(runtime, snapshot, take_id, digest)
    @workflow.PartEffectKind::DispatchVerification(take_id, subject) =>
      execute_native_verification(runtime, snapshot, intent, take_id, subject)
    @workflow.PartEffectKind::DispatchAudit(take_id, command, subject) =>
      execute_native_audit(runtime, snapshot, take_id, command, subject)
    @workflow.PartEffectKind::GeneratePromotion(_)
    | @workflow.PartEffectKind::ApplyIntegration(_, _) =>
      @git_integration.execute_native_git_effect(
        runtime.config.git_integration,
        snapshot,
        intent,
        @git_host.native_git_integration_adapters(),
      )
  }
}

///|
fn native_provider_dispatch_recovery(
  surface : @control.ProviderSurfaceId,
) -> Result[@workflow.PartEffectRecovery, @types.ChoirError] {
  match surface {
    @control.ProviderSurfaceId::CodexSubscriptionCli =>
      Ok(@workflow.PartEffectRecovery::ExactEffectRetryAuthorized)
    @control.ProviderSurfaceId::ClaudeSubscriptionCli =>
      Err(
        @types.ChoirError::provider_process_lost(
          "nonresumable Claude Take lost its owning Goal worker",
        ),
      )
  }
}

///|
test "provider dispatch recovery never retries a lost Claude Take" {
  assert_true(
    native_provider_dispatch_recovery(
      @control.ProviderSurfaceId::CodexSubscriptionCli,
    )
    is Ok(@workflow.PartEffectRecovery::ExactEffectRetryAuthorized),
  )
  let claude = native_provider_dispatch_recovery(
    @control.ProviderSurfaceId::ClaudeSubscriptionCli,
  )
  assert_true(claude is Err(_))
  match claude {
    Err(error) => assert_true(error.is_provider_process_lost())
    Ok(_) => fail("lost Claude Take was retried")
  }
}

///|
async fn reconcile_unwitnessed_native_part_effect(
  runtime : NativePartEffectRuntime,
  snapshot : @workflow.PartWorkflowSnapshot,
  intent : @workflow.PartEffectIntent,
) -> Result[@workflow.PartEffectRecovery, @types.ChoirError] {
  match intent.kind {
    @workflow.PartEffectKind::PrepareImplementationCommand(_)
    | @workflow.PartEffectKind::PrepareAuditCommand(_)
    | @workflow.PartEffectKind::StartImplementationHarness(_, _)
    | @workflow.PartEffectKind::StartAuditHarness(_, _)
    | @workflow.PartEffectKind::NormalizeImplementationCandidate(_, _) =>
      Ok(@workflow.PartEffectRecovery::ExactEffectRetryAuthorized)
    @workflow.PartEffectKind::GeneratePromotion(_)
    | @workflow.PartEffectKind::ApplyIntegration(_, _) =>
      @git_integration.reconcile_native_git_effect(
        runtime.config.git_integration,
        snapshot,
        intent,
        @git_host.native_git_integration_adapters(),
      )
    @workflow.PartEffectKind::PrepareImplementationSandbox(lease)
    | @workflow.PartEffectKind::PrepareVerificationSandbox(lease)
    | @workflow.PartEffectKind::PrepareAuditSandbox(lease) =>
      match native_sandbox_registry_path(runtime, lease.generation_id) {
        Err(error) => Err(error)
        Ok(path) if @sys.path_exists(path) =>
          match native_runtime_sandbox(runtime, lease.generation_id) {
            Ok(_) =>
              Ok(@workflow.PartEffectRecovery::ExactEffectRetryAuthorized)
            Err(error) => Err(error)
          }
        Ok(_) => {
          let name = "choir-" + lease.generation_id.0
          match
            @take_host.lookup_native_boxlite_named_box(runtime.server.val, name) {
            Ok(NativeBoxLiteNamedBoxAbsent) =>
              Ok(@workflow.PartEffectRecovery::ExactEffectRetryAuthorized)
            Ok(
              NativeBoxLiteNamedBoxExact(_, _)
              | NativeBoxLiteNamedBoxUncertain
            ) => Ok(@workflow.PartEffectRecovery::EffectWitnessUnavailable)
            Err(error) => Err(error)
          }
        }
      }
    @workflow.PartEffectKind::DispatchVerification(_, _) => {
      let process_uncertain = match
        reconcile_unadoptable_native_process(runtime, snapshot, intent) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if process_uncertain {
        Err(
          @types.ChoirError::provider_process_lost(
            "an unkeyed guest process may have started; its sandbox generation was retired",
          ),
        )
      } else {
        Ok(@workflow.PartEffectRecovery::ExactEffectRetryAuthorized)
      }
    }
    @workflow.PartEffectKind::DispatchImplementation(_, _)
    | @workflow.PartEffectKind::DispatchAudit(_, _, _) => {
      let process_uncertain = match
        reconcile_unadoptable_native_process(runtime, snapshot, intent) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if process_uncertain {
        return Err(
          @types.ChoirError::provider_process_lost(
            "an unkeyed guest process may have started; its sandbox generation was retired",
          ),
        )
      }
      let session_id = match intent.kind {
        @workflow.PartEffectKind::DispatchImplementation(_, command)
        | @workflow.PartEffectKind::DispatchAudit(_, command, _) =>
          command.session_id
        _ => return Ok(@workflow.PartEffectRecovery::EffectWitnessUnavailable)
      }
      let session = match native_snapshot_session(snapshot, session_id) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      match session.surface {
        @control.ProviderSurfaceId::ClaudeSubscriptionCli =>
          match
            @provider_host.reconcile_native_claude_process_witness(
              runtime.config.claude_root + session.id.0,
            ) {
            Ok(_) => ()
            Err(error) => return Err(error)
          }
        @control.ProviderSurfaceId::CodexSubscriptionCli => ()
      }
      native_provider_dispatch_recovery(session.surface)
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
