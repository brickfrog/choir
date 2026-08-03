///|
priv struct NativeDirectTakeRuntimeOwnershipReceipt {
  version : Int
  repository_id : @workflow.RepositoryId
  runtime_key : String
  owner_pid : Int
  base_box_id : String?
  take_box_id : String?
} derive(ToJson, FromJson)

///|
fn native_direct_take_repository_key(
  repository_id : @workflow.RepositoryId,
) -> String {
  @storage.artifact_digest(@utf8.encode(repository_id.0)).0[:20].to_owned()
}

///|
fn native_direct_take_runtime_prefix(
  repository_id : @workflow.RepositoryId,
) -> String {
  "choir-take-direct-" + native_direct_take_repository_key(repository_id) + "-"
}

///|
fn native_direct_take_owned_root(
  repository_id : @workflow.RepositoryId,
  runtime_key : String,
) -> String {
  "/tmp/" + native_direct_take_runtime_prefix(repository_id) + runtime_key
}

///|
fn native_direct_take_owner_path(root : String) -> String {
  root + "/state/owner.json"
}

///|
fn native_direct_take_runtime_token(value : String) -> Bool {
  if value == "" || value.length() > 120 {
    return false
  }
  for character in value {
    if !((character >= 'a' && character <= 'z') ||
      (character >= '0' && character <= '9') ||
      character == '-') {
      return false
    }
  }
  true
}

///|
fn write_native_direct_take_receipt(
  root : String,
  receipt : NativeDirectTakeRuntimeOwnershipReceipt,
) -> Result[Unit, @types.ChoirError] {
  let state = root + "/state"
  if !@sys.create_dir_all(state) || @sys.realpath_native(root) != Some(root) {
    return Err(
      native_direct_take_runtime_error("ownership root is unavailable"),
    )
  }
  let content = ToJson::to_json(receipt).stringify(indent=0) + "\n"
  let path = native_direct_take_owner_path(root)
  if !@sys.write_file_atomic(path, content) || @sys.read_file(path) != content {
    return Err(native_direct_take_runtime_error("ownership receipt failed"))
  }
  Ok(())
}

///|
fn read_native_direct_take_receipt(
  root : String,
) -> NativeDirectTakeRuntimeOwnershipReceipt? {
  if @sys.realpath_native(root) != Some(root) {
    return None
  }
  let json = @json.parse(@sys.read_file(native_direct_take_owner_path(root))) catch {
    _ => return None
  }
  let receipt : NativeDirectTakeRuntimeOwnershipReceipt = @json.from_json(json) catch {
    _ => return None
  }
  let expected = native_direct_take_runtime_prefix(receipt.repository_id) +
    receipt.runtime_key
  let valid_box = fn(value : String?) {
    match value {
      Some(id) => @sandbox.valid_boxlite_state_token(id)
      None => true
    }
  }
  if receipt.version != 1 ||
    !native_direct_take_runtime_token(receipt.runtime_key) ||
    receipt.owner_pid <= 1 ||
    !root.has_suffix("/" + expected) ||
    !valid_box(receipt.base_box_id) ||
    !valid_box(receipt.take_box_id) {
    None
  } else {
    Some(receipt)
  }
}

///|
fn native_direct_take_receipt(
  repository_id : @workflow.RepositoryId,
  runtime_key : String,
  owner_pid : Int,
  base_box_id : String?,
  take_box_id : String?,
) -> NativeDirectTakeRuntimeOwnershipReceipt {
  {
    version: 1,
    repository_id,
    runtime_key,
    owner_pid,
    base_box_id,
    take_box_id,
  }
}

///|
fn native_direct_take_boxlite_config(
  repository_id : @workflow.RepositoryId,
  runtime_key : String,
) -> Result[@take_host.NativeBoxLiteServerConfig, @types.ChoirError] {
  let binary = match @process_host.native_boxlite_binary_path() {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let runtime_dir = match @process_host.native_boxlite_runtime_dir() {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let home = match @goal_host.native_goal_boxlite_home(repository_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    binary,
    runtime_dir,
    root: native_direct_take_owned_root(repository_id, runtime_key),
    home,
    port: 20000 + @sys.get_pid() % 10000,
    api_key: "choir-direct-" + runtime_key,
  })
}

///|
fn native_direct_take_moon_home() -> Result[String, @types.ChoirError] {
  match @sys.getenv("CHOIR_MOON_HOME") {
    Some(value) if value.has_prefix("/") => Ok(value)
    _ =>
      match @sys.getenv("HOME") {
        Some(value) if value.has_prefix("/") => Ok(value + "/.moon")
        _ => Err(native_direct_take_runtime_error("Moon home is absent"))
      }
  }
}

///|
fn native_direct_take_session(
  surface : @control.ProviderSurfaceId,
  runtime_key : String,
) -> Result[@control.HarnessSession, @types.ChoirError] {
  let tools = match surface {
    @control.ProviderSurfaceId::ClaudeSubscriptionCli =>
      @sandbox.boxlite_take_mcp_tools()
    @control.ProviderSurfaceId::CodexSubscriptionCli =>
      @sandbox.boxlite_take_codex_mcp_tools()
  }
  let planned : @control.HarnessSession = {
    id: @control.HarnessSessionId("direct-take-session-" + runtime_key),
    take_id: @control.TakeId("direct-take-" + runtime_key),
    sandbox_generation_id: @control.SandboxGenerationId(
      "direct-take-generation-" + runtime_key,
    ),
    surface,
    effective_surface_manifest_digest: match surface {
      @control.ProviderSurfaceId::ClaudeSubscriptionCli =>
        @harness.expected_claude_take_surface_manifest_digest(
          tools, "choir_sandbox",
        )
      @control.ProviderSurfaceId::CodexSubscriptionCli =>
        @harness.codex_effective_surface_manifest_digest(tools, "choir_sandbox")
    },
    cursor_class: match surface {
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
  match surface {
    @control.ProviderSurfaceId::ClaudeSubscriptionCli =>
      @harness.start_claude_harness_session(planned)
    @control.ProviderSurfaceId::CodexSubscriptionCli =>
      @harness.start_codex_harness_session(planned)
  }
}

///|
async fn run_native_direct_take_provider(
  surface : @control.ProviderSurfaceId,
  runtime_key : String,
  root : String,
  node : String,
  mcp_script : String,
  sandbox : @take_host.NativeBoxLiteTakeSandbox,
  instruction : String,
) -> Result[NativeDirectTakeProviderEvidence, @types.ChoirError] {
  let session = match native_direct_take_session(surface, runtime_key) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let mcp_arguments = match
    @take_host.native_boxlite_take_mcp_arguments(
      sandbox,
      mcp_script,
      owner_socket=Some(@provider_host.native_provider_owner_socket_path()),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let now = fn() { @env.now().reinterpret_as_int64() / 1000L }
  match surface {
    @control.ProviderSurfaceId::ClaudeSubscriptionCli => {
      let result = match
        @provider_host.run_native_claude_take(
          {
            sterile_root: root + "/providers/claude-" + runtime_key,
            mcp_executable: node,
            mcp_arguments,
            execution_token: @take_host.native_boxlite_take_execution_token(
              sandbox,
            ),
            boxlite_owner_socket_root: Some(
              sandbox.prepared.server.owner_socket_root,
            ),
            mcp_server_name: "choir_sandbox",
            allowed_tools: @sandbox.boxlite_take_mcp_tools(),
            timeout_ms: 3600000,
            connect_trace_path: None,
          },
          session,
          @harness.ClaudeTakeRole::ClaudeImplementationTake,
          instruction,
          now,
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if !(result.outcome
        is @harness.ClaudeTakeOutcome::ClaudeImplementationCompleted) {
        return Err(
          native_direct_take_runtime_error("provider outcome is invalid"),
        )
      }
      Ok({
        surface,
        surface_manifest_digest: result.effective_surface_manifest_digest,
        response_digest: @storage.artifact_digest(
          @utf8.encode(result.terminal_response),
        ),
        usage: result.session.usage.unwrap_or(@control.empty_take_usage()),
        started_at: result.started_at,
        finished_at: result.finished_at,
      })
    }
    @control.ProviderSurfaceId::CodexSubscriptionCli => {
      let result = match
        @provider_host.run_native_codex_take(
          {
            sterile_root: root + "/providers/codex-" + runtime_key,
            mcp_executable: node,
            mcp_arguments,
            execution_token: @take_host.native_boxlite_take_execution_token(
              sandbox,
            ),
            boxlite_owner_socket_root: Some(
              sandbox.prepared.server.owner_socket_root,
            ),
            mcp_server_name: "choir_sandbox",
            allowed_tools: @sandbox.boxlite_take_codex_mcp_tools(),
            timeout_ms: 3600000,
            connect_trace_path: None,
          },
          session,
          @harness.CodexTakeRole::CodexImplementationTake,
          instruction,
          now,
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if !(result.outcome
        is @harness.CodexTakeOutcome::CodexImplementationCompleted) {
        return Err(
          native_direct_take_runtime_error("provider outcome is invalid"),
        )
      }
      Ok({
        surface,
        surface_manifest_digest: result.session.effective_surface_manifest_digest,
        response_digest: @storage.artifact_digest(
          @utf8.encode(result.terminal_response),
        ),
        usage: result.session.usage.unwrap_or(@control.empty_take_usage()),
        started_at: result.started_at,
        finished_at: result.finished_at,
      })
    }
  }
}

///|
fn native_direct_take_verification_outcome(
  outcome : @take_host.NativeSandboxProcessOutcome,
) -> NativeDirectTakeVerificationOutcome {
  match outcome {
    @take_host.NativeSandboxProcessExited(result) =>
      if result.exit_code == 0 {
        NativeDirectTakeVerificationPassed(result)
      } else {
        NativeDirectTakeVerificationFailed(result)
      }
    @take_host.NativeSandboxProcessInterrupted =>
      NativeDirectTakeVerificationInterrupted
    @take_host.NativeSandboxProcessTimedOut =>
      NativeDirectTakeVerificationTimedOut
    @take_host.NativeSandboxProcessOutputExceeded =>
      NativeDirectTakeVerificationOutputExceeded
  }
}

///|
async fn execute_native_direct_take_boxlite_body(
  surface : @control.ProviderSurfaceId,
  snapshot : NativeDirectTakeSnapshot,
  instruction : String,
  verification_plan : @workflow.DirectTakeVerificationPlan,
  runtime_key : String,
  repository_id : @workflow.RepositoryId,
  config : @take_host.NativeBoxLiteServerConfig,
  server_ref : Ref[@take_host.NativeBoxLiteServerHandle?],
  box_ids : Array[String],
) -> Result[NativeDirectTakeIsolatedResult, @types.ChoirError] {
  let moon_home = match native_direct_take_moon_home() {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let node = match @process_host.resolve_executable_in_path("node") {
    Some(value) => value
    None => return Err(native_direct_take_runtime_error("Node is absent"))
  }
  let mcp_script = match @goal_host.native_goal_mcp_script() {
    Some(value) => value
    None =>
      return Err(native_direct_take_runtime_error("sandbox MCP is absent"))
  }
  let git_config : @git_host.NativeGitWorkspaceConfig = {
    repository_root: snapshot.repository_root,
    object_directory: snapshot.object_directory,
    staging_root: config.root + "/staging",
  }
  if !@sys.create_dir_all(git_config.staging_root) ||
    @sys.realpath_native(git_config.staging_root) !=
    Some(git_config.staging_root) {
    return Err(native_direct_take_runtime_error("staging root is unavailable"))
  }
  let staged = match
    @git_host.stage_native_git_workspace(
      git_config,
      "source-" + runtime_key,
      snapshot.commit_oid,
      snapshot.tree_oid,
      snapshot.source_digest,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let server = match @take_host.start_native_boxlite_server(config) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  server_ref.val = Some(server)
  let prepared = match
    @take_host.prepare_native_boxlite_environment(
      server,
      moon_home,
      "choir-base-direct-" + runtime_key,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  server_ref.val = Some(prepared.server)
  box_ids.push(prepared.base_box_id)
  match
    write_native_direct_take_receipt(
      config.root,
      native_direct_take_receipt(
        repository_id,
        runtime_key,
        @sys.get_pid(),
        Some(prepared.base_box_id),
        None,
      ),
    ) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let mutable_sandbox = match
    @take_host.clone_native_boxlite_take(
      prepared,
      moon_home,
      "choir-direct-" + runtime_key,
      staged.root,
      staged.source_digest,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  server_ref.val = Some(mutable_sandbox.prepared.server)
  box_ids.push(mutable_sandbox.box_id)
  match
    write_native_direct_take_receipt(
      config.root,
      native_direct_take_receipt(
        repository_id,
        runtime_key,
        @sys.get_pid(),
        Some(prepared.base_box_id),
        Some(mutable_sandbox.box_id),
      ),
    ) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let provider = match
    run_native_direct_take_provider(
      surface,
      runtime_key,
      config.root,
      node,
      mcp_script,
      mutable_sandbox,
      instruction,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let assurance_subject = match
    @take_host.seal_native_boxlite_assurance_subject(mutable_sandbox) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let verification = match
    @take_host.execute_native_boxlite_process(
      assurance_subject,
      verification_plan.capability,
      verification_plan.process_spec_digest,
      verification_plan.process,
      fn(_) { false },
    ) {
    Ok(value) => native_direct_take_verification_outcome(value)
    Err(error) => return Err(error)
  }
  let result_root = match
    @take_host.copy_native_boxlite_take_result(assurance_subject) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let patch = match
    observe_native_direct_take_patch(
      snapshot, git_config, result_root, runtime_key,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    patch,
    verification,
    provider,
    image_digest: prepared.image_digest,
    tool_manifest_digest: prepared.tool_manifest_digest,
    runtime_policy_digest: prepared.runtime_policy_digest,
    verification_process_spec_digest: verification_plan.process_spec_digest,
  })
}

///|
async fn cleanup_native_direct_take_boxlite(
  config : @take_host.NativeBoxLiteServerConfig,
  server : @take_host.NativeBoxLiteServerHandle?,
  box_ids : Array[String],
) -> Result[Unit, @types.ChoirError] {
  match server {
    Some(value) => {
      @take_host.stop_native_boxlite_server(value)
      @async.sleep(400)
    }
    None => ()
  }
  @take_host.cleanup_native_boxlite_owned_runtime(config, box_ids)
}

///|
async fn execute_native_direct_take_boxlite(
  surface : @control.ProviderSurfaceId,
  snapshot : NativeDirectTakeSnapshot,
  instruction : String,
  verification_plan : @workflow.DirectTakeVerificationPlan,
) -> Result[NativeDirectTakeIsolatedResult, @types.ChoirError] {
  let repository_id = @workflow.repository_id(snapshot.repository_root)
  let runtime_key = snapshot.source_digest.0[:12].to_owned() +
    "-" +
    @sys.get_pid().to_string()
  let config = match
    native_direct_take_boxlite_config(repository_id, runtime_key) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if @sys.path_entry_exists(config.root) ||
    !@sys.create_dir_all(config.root) ||
    @sys.realpath_native(config.root) != Some(config.root) {
    return Err(native_direct_take_runtime_error("runtime root is unavailable"))
  }
  match
    write_native_direct_take_receipt(
      config.root,
      native_direct_take_receipt(
        repository_id,
        runtime_key,
        @sys.get_pid(),
        None,
        None,
      ),
    ) {
    Ok(_) => ()
    Err(error) => {
      ignore(@sys.rm_rf(config.root))
      return Err(error)
    }
  }
  let server_ref : Ref[@take_host.NativeBoxLiteServerHandle?] = @ref.new(None)
  let box_ids : Array[String] = []
  let result = execute_native_direct_take_boxlite_body(
    surface, snapshot, instruction, verification_plan, runtime_key, repository_id,
    config, server_ref, box_ids,
  )
  let cleanup = cleanup_native_direct_take_boxlite(
    config,
    server_ref.val,
    box_ids,
  )
  match result {
    Err(error) => Err(error)
    Ok(value) =>
      match cleanup {
        Ok(_) => Ok(value)
        Err(error) => Err(error)
      }
  }
}

///|
pub async fn run_native_direct_take(
  project_dir : String,
  command : @command.DirectTakeCommand,
) -> Result[NativeDirectTakeReport, @types.ChoirError] {
  run_native_direct_take_with(command, {
    capture_snapshot: async fn() {
      capture_native_direct_take_snapshot(project_dir)
    },
    execute_isolated: async fn(snapshot, instruction, verification) {
      execute_native_direct_take_boxlite(
        command.surface,
        snapshot,
        instruction,
        verification,
      )
    },
    apply_patch: async fn(snapshot, patch) {
      apply_native_direct_take_patch(snapshot, patch)
    },
    is_nfc: @process_host.native_path_is_nfc,
  })
}

///|
fn native_direct_take_receipts_at(
  repository_id : @workflow.RepositoryId,
  temporary_root : String,
  entries : Array[String],
  canonicalize : (String) -> String?,
  read_receipt : (String) -> NativeDirectTakeRuntimeOwnershipReceipt?,
) -> Result[Array[NativeDirectTakeRuntimeOwnershipReceipt], @types.ChoirError] {
  if !temporary_root.has_prefix("/") ||
    temporary_root == "/" ||
    temporary_root.has_suffix("/") ||
    temporary_root.contains("/../") {
    return Err(native_direct_take_runtime_error("receipt root is invalid"))
  }
  let prefix = native_direct_take_runtime_prefix(repository_id)
  let observed : Array[String] = []
  let receipts : Array[NativeDirectTakeRuntimeOwnershipReceipt] = []
  for entry in entries {
    if !entry.has_prefix(prefix) {
      continue
    }
    if entry == prefix || entry.contains("/") || observed.contains(entry) {
      return Err(
        native_direct_take_runtime_error("runtime ownership is ambiguous"),
      )
    }
    observed.push(entry)
    let root = temporary_root + "/" + entry
    if canonicalize(root) != Some(root) {
      return Err(
        native_direct_take_runtime_error("runtime ownership is unproven"),
      )
    }
    let receipt = match read_receipt(root) {
      Some(value) if value.repository_id == repository_id &&
        prefix + value.runtime_key == entry => value
      _ =>
        return Err(
          native_direct_take_runtime_error("runtime ownership is unproven"),
        )
    }
    if receipts.any(fn(value) { value.runtime_key == receipt.runtime_key }) {
      return Err(
        native_direct_take_runtime_error("runtime ownership is ambiguous"),
      )
    }
    receipts.push(receipt)
  }
  receipts.sort_by(fn(left, right) {
    left.runtime_key.compare(right.runtime_key)
  })
  Ok(receipts)
}

///|
test "direct Take runtime enumeration accepts only exact repository receipts" {
  let repository = @workflow.RepositoryId("direct-take-repository")
  assert_true(
    native_direct_take_owned_root(repository, "first-123").has_prefix(
      "/tmp/choir-take-",
    ),
  )
  let first = native_direct_take_receipt(
    repository,
    "first-123",
    123,
    Some("base-first"),
    Some("take-first"),
  )
  let second = native_direct_take_receipt(
    repository,
    "second-456",
    456,
    None,
    None,
  )
  let prefix = native_direct_take_runtime_prefix(repository)
  let by_root : Map[String, NativeDirectTakeRuntimeOwnershipReceipt] = Map([])
  by_root["/tmp/" + prefix + "first-123"] = first
  by_root["/tmp/" + prefix + "second-456"] = second
  let receipts = native_direct_take_receipts_at(
    repository,
    "/tmp",
    [prefix + "second-456", "unrelated", prefix + "first-123"],
    fn(path) { Some(path) },
    fn(path) { by_root.get(path) },
  ).unwrap()
  assert_eq(receipts.length(), 2)
  assert_eq(receipts[0].runtime_key, "first-123")
  assert_true(
    native_direct_take_receipts_at(
      repository,
      "/tmp",
      [prefix + "first-123", prefix + "first-123"],
      fn(path) { Some(path) },
      fn(path) { by_root.get(path) },
    )
    is Err(_),
  )
}

///|
pub(all) struct NativeDirectTakePurgeReport {
  runtime_roots_removed : Int
} derive(Debug, Eq)

///|
async fn native_direct_take_repository_root_for_purge(
  project_dir : String,
) -> Result[String, @types.ChoirError] {
  let root = match
    native_direct_take_git_text(
      project_dir,
      ["rev-parse", "--show-toplevel"],
      4096,
      capture_native_direct_take_git,
      label="repository root",
    ) {
    Ok(value) => value.trim().to_owned()
    Err(error) => return Err(error)
  }
  if @sys.realpath_native(root) != Some(root) {
    Err(native_direct_take_runtime_error("repository root is invalid"))
  } else {
    Ok(root)
  }
}

///|
pub async fn purge_native_direct_take_resources(
  project_dir : String,
) -> Result[NativeDirectTakePurgeReport, @types.ChoirError] {
  let root = match native_direct_take_repository_root_for_purge(project_dir) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let repository_id = @workflow.repository_id(root)
  let entries = match @sys.list_dir_all_complete("/tmp") {
    Some(value) => value
    None =>
      return Err(native_direct_take_runtime_error("receipt enumeration failed"))
  }
  let receipts = match
    native_direct_take_receipts_at(
      repository_id, "/tmp", entries, @sys.realpath_native, read_native_direct_take_receipt,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let mut removed = 0
  for receipt in receipts {
    if @sys.pid_is_alive(receipt.owner_pid) {
      return Err(
        native_direct_take_runtime_error("an active direct Take exists"),
      )
    }
    let config = match
      native_direct_take_boxlite_config(repository_id, receipt.runtime_key) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let box_ids : Array[String] = []
    match receipt.take_box_id {
      Some(value) => box_ids.push(value)
      None => ()
    }
    match receipt.base_box_id {
      Some(value) if !box_ids.contains(value) => box_ids.push(value)
      _ => ()
    }
    match @take_host.cleanup_native_boxlite_owned_runtime(config, box_ids) {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
    if @sys.path_entry_exists(config.root) {
      return Err(
        native_direct_take_runtime_error("runtime cleanup was incomplete"),
      )
    }
    removed = removed + 1
  }
  Ok({ runtime_roots_removed: removed })
}
