///|
pub(all) struct NativeCodexDriverConfig {
  sterile_root : String
  mcp_executable : String
  mcp_arguments : Array[String]
  /// The BoxLite capability the sandbox bridge authenticates with. Exported to
  /// the app-server environment, never placed on any command line.
  execution_token : String
  boxlite_owner_socket_root : String?
  mcp_server_name : String
  allowed_tools : Array[String]
  timeout_ms : Int
  connect_trace_path : String?
} derive(Debug, Eq)

///|
pub(all) struct NativeCodexConductorConfig {
  sterile_root : String
  mcp_executable : String
  mcp_arguments : Array[String]
  mcp_server_name : String
  allowed_tools : Array[String]
  developer_instructions : String
  timeout_ms : Int
  environment : ConductorProcessEnvironment
}

///|
/// Whether a `thread/read` rejection means the thread simply has no durable
/// turns yet. Only a typed rejection can answer; anything else is a failure.
fn native_codex_thread_is_unmaterialized(error : @types.ChoirError) -> Bool {
  match error.provider_rpc_rejection() {
    Some((code, message)) =>
      @harness.codex_thread_read_disposition(code, message)
      is @harness.CodexThreadReadDisposition::CodexThreadNotMaterialized
    None => false
  }
}

///|
fn native_codex_driver_error(message : String) -> @types.ChoirError {
  @types.ChoirError::transport_error("Codex driver: " + message)
}

///|
fn valid_native_codex_token(value : String) -> Bool {
  if value == "" || value.length() > 120 {
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
fn validate_native_codex_config(
  config : NativeCodexDriverConfig,
) -> Result[Unit, @types.ChoirError] {
  if !config.sterile_root.has_prefix("/") ||
    !config.mcp_executable.has_prefix("/") ||
    !valid_native_codex_token(config.mcp_server_name) ||
    config.allowed_tools.length() == 0 ||
    config.timeout_ms < 1000 ||
    config.timeout_ms > 3600000 {
    return Err(
      @types.ChoirError::validation_error(
        "native Codex driver configuration is invalid",
      ),
    )
  }
  for index, tool in config.allowed_tools {
    if !valid_native_codex_token(tool) ||
      config.allowed_tools[:index].contains(tool) {
      return Err(
        @types.ChoirError::validation_error(
          "native Codex driver tool declaration is invalid",
        ),
      )
    }
  }
  match config.connect_trace_path {
    Some(path) if path != config.sterile_root + "/connect.trace" =>
      return Err(
        @types.ChoirError::validation_error(
          "native Codex connect trace path is invalid",
        ),
      )
    _ => ()
  }
  let owner_socket_target = native_provider_owner_socket_path()
  let mut owner_socket_argument_count = 0
  for index, argument in config.mcp_arguments {
    if argument == "--owner-socket" {
      owner_socket_argument_count = owner_socket_argument_count + 1
      if index + 1 >= config.mcp_arguments.length() ||
        config.mcp_arguments[index + 1] != owner_socket_target {
        return Err(
          @types.ChoirError::validation_error(
            "native Codex owner socket target is invalid",
          ),
        )
      }
    }
  }
  match config.boxlite_owner_socket_root {
    Some(root) if native_provider_expected_owner_socket_root(
        config.sterile_root,
      ) !=
      Some(root) ||
      owner_socket_argument_count != 1 =>
      return Err(
        @types.ChoirError::validation_error(
          "native Codex owner socket binding is invalid",
        ),
      )
    None if owner_socket_argument_count != 0 =>
      return Err(
        @types.ChoirError::validation_error(
          "native Codex owner socket binding is absent",
        ),
      )
    _ => ()
  }
  Ok(())
}

///|
fn native_codex_role_prompt(role : @harness.CodexTakeRole) -> String {
  let common = "Use only tools from the required Choir MCP server. You must call at least one available Choir MCP tool before returning. Never use native host file, shell, network, browser, plugin, hook, skill, app, or subagent capabilities. "
  match role {
    @harness.CodexTakeRole::CodexImplementationTake =>
      common +
      "Complete the instruction in the sandbox. If its prose or acceptance criteria appear internally contradictory, choose and implement the narrowest executable interpretation that preserves the requested outcome and verification intent; never stop to request user input. End with exactly {\"outcome\":\"completed\"}."
    @harness.CodexTakeRole::CodexAuditTake =>
      common +
      "Your first action must be a read_file call for a repository path named in the supplied Part task. Call read_file for every path the Part task permits to change, and do not return before those calls succeed. Independently audit the supplied candidate. Return outcome passed with zero counts when clean, otherwise outcome findings with exact total and blocking counts." +
      native_migration_audit_output_instruction()
  }
}

///|
fn native_codex_output_schema(role : @harness.CodexTakeRole) -> String {
  let outcome = match role {
    @harness.CodexTakeRole::CodexImplementationTake => ["completed"]
    @harness.CodexTakeRole::CodexAuditTake => ["passed", "findings"]
  }
  let properties : Map[String, Json] = {
    "outcome": { "type": "string".to_json(), "enum": outcome.to_json() }.to_json(),
  }
  let required : Array[String] = ["outcome"]
  match role {
    @harness.CodexTakeRole::CodexAuditTake => {
      properties["total_findings"] = {
        "type": "integer".to_json(),
        "minimum": (0).to_json(),
      }.to_json()
      properties["blocking_findings"] = {
        "type": "integer".to_json(),
        "minimum": (0).to_json(),
      }.to_json()
      properties["repair_findings"] = native_repair_findings_output_schema()
      properties["migration_findings"] = native_migration_findings_output_schema()
      required.push("total_findings")
      required.push("blocking_findings")
      required.push("repair_findings")
      required.push("migration_findings")
    }
    _ => ()
  }
  let schema : Map[String, Json] = {
    "$schema": "https://json-schema.org/draft/2020-12/schema".to_json(),
    "type": "object".to_json(),
    "properties": properties.to_json(),
    "required": required.to_json(),
    "additionalProperties": false.to_json(),
  }
  schema.to_json().stringify(indent=0) + "\n"
}

///|
fn push_codex_config(
  args : Array[String],
  key : String,
  value : String,
) -> Unit {
  args.push("-c")
  args.push(key + "=" + value)
}

///|
fn push_native_codex_take_config(
  args : Array[String],
  config : NativeCodexDriverConfig,
) -> Unit {
  for feature in @harness.codex_take_disabled_features() {
    args.push("--disable")
    args.push(feature)
  }
  push_codex_config(args, "approval_policy", "never".to_json().stringify())
  push_codex_config(
    args,
    "default_permissions",
    "choir_take".to_json().stringify(),
  )
  push_codex_config(
    args, "permissions.choir_take.filesystem", "{\":minimal\"=\"read\"}",
  )
  push_codex_config(args, "permissions.choir_take.network.enabled", "false")
  push_codex_config(
    args,
    "shell_environment_policy.inherit",
    "none".to_json().stringify(),
  )
  push_codex_config(
    args, "shell_environment_policy.set", "{PATH=\"/usr/bin:/bin\",HOME=\"/nonexistent\"}",
  )
  push_codex_config(args, "web_search", "disabled".to_json().stringify())
  push_codex_config(args, "personality", "none".to_json().stringify())
  push_codex_config(args, "project_doc_max_bytes", "0")
  let server_key = "mcp_servers." + config.mcp_server_name
  push_codex_config(
    args,
    server_key + ".command",
    config.mcp_executable.to_json().stringify(),
  )
  push_codex_config(
    args,
    server_key + ".args",
    config.mcp_arguments.to_json().stringify(),
  )
  // The app-server does not hand its own environment to the MCP servers it
  // spawns: a probed stdio server saw only HOME, PATH, and TMPDIR. `env_vars`
  // names the variables to forward from the app-server environment, so the
  // argv carries the name of the capability and never its value —
  // /proc/<pid>/cmdline is world-readable, /proc/<pid>/environ is not.
  if config.execution_token != "" {
    push_codex_config(
      args,
      server_key + ".env_vars",
      [native_boxlite_execution_token_variable].to_json().stringify(),
    )
  }
  push_codex_config(args, server_key + ".required", "true")
  push_codex_config(
    args,
    server_key + ".enabled_tools",
    config.allowed_tools.to_json().stringify(),
  )
  push_codex_config(
    args,
    server_key + ".default_tools_approval_mode",
    "approve".to_json().stringify(),
  )
}

///|
fn native_codex_app_server_args(
  config : NativeCodexDriverConfig,
) -> Array[String] {
  let args : Array[String] = ["app-server", "--listen", "stdio://"]
  push_native_codex_take_config(args, config)
  args
}

///|
fn native_codex_conductor_args(
  config : NativeCodexConductorConfig,
  thread_id : String?,
) -> Array[String] {
  let args : Array[String] = match thread_id {
    Some(_) => ["exec", "resume"]
    None => ["exec"]
  }
  args.push("--json")
  args.push("--skip-git-repo-check")
  args.push("--ignore-user-config")
  args.push("--ignore-rules")
  args.push("--strict-config")
  for feature in @harness.codex_take_disabled_features() {
    args.push("--disable")
    args.push(feature)
  }
  push_codex_config(args, "approval_policy", "never".to_json().stringify())
  push_codex_config(
    args,
    "default_permissions",
    "choir_conductor".to_json().stringify(),
  )
  push_codex_config(
    args, "permissions.choir_conductor.filesystem", "{\":minimal\"=\"read\"}",
  )
  push_codex_config(
    args, "permissions.choir_conductor.network.enabled", "false",
  )
  push_codex_config(
    args,
    "shell_environment_policy.inherit",
    "none".to_json().stringify(),
  )
  push_codex_config(
    args, "shell_environment_policy.set", "{PATH=\"/usr/bin:/bin\",HOME=\"/nonexistent\"}",
  )
  push_codex_config(args, "web_search", "disabled".to_json().stringify())
  push_codex_config(args, "personality", "none".to_json().stringify())
  push_codex_config(args, "project_doc_max_bytes", "0")
  push_codex_config(
    args,
    "developer_instructions",
    config.developer_instructions.to_json().stringify(),
  )
  let server_key = "mcp_servers." + config.mcp_server_name
  push_codex_config(
    args,
    server_key + ".command",
    config.mcp_executable.to_json().stringify(),
  )
  push_codex_config(
    args,
    server_key + ".args",
    config.mcp_arguments.to_json().stringify(),
  )
  push_codex_config(args, server_key + ".required", "true")
  push_codex_config(
    args,
    server_key + ".enabled_tools",
    config.allowed_tools.to_json().stringify(),
  )
  push_codex_config(
    args,
    server_key + ".default_tools_approval_mode",
    "approve".to_json().stringify(),
  )
  match thread_id {
    Some(value) => args.push(value)
    None => ()
  }
  args.push("-")
  args
}

///|
fn native_codex_environment(
  provider_home : String,
  sterile_root : String,
) -> Map[String, String] {
  {
    "HOME": provider_home,
    "TMPDIR": sterile_root + "/tmp",
    "PATH": "/usr/local/bin:/usr/bin:/bin",
    "COLUMNS": "200",
    "NO_COLOR": "1",
  }
}

///|
fn native_codex_app_server_environment(
  sterile_root : String,
  execution_token : String,
) -> Map[String, String] {
  let environment = native_codex_environment(
    sterile_root + "/home",
    sterile_root,
  )
  environment["CODEX_HOME"] = sterile_root + "/codex-home"
  // The app-server forwards this to the sandbox bridge because the server
  // configuration names it in `env_vars`. Holding the capability here keeps it
  // off every command line.
  if execution_token != "" {
    environment[native_boxlite_execution_token_variable] = execution_token
  }
  environment
}

///|
fn native_codex_app_server_working_directory(
  config : NativeCodexDriverConfig,
) -> String {
  config.sterile_root + "/work"
}

///|
fn native_codex_ambient_configuration_present(
  config : NativeCodexDriverConfig,
  allow_provider_state : Bool,
) -> Bool {
  let home_entries = @sys.list_dir_all(config.sterile_root + "/home")
  if (
      (!allow_provider_state && home_entries.length() != 0) ||
      (
        allow_provider_state &&
        (
          home_entries.length() > 1 ||
          (home_entries.length() == 1 && home_entries[0] != ".cache")
        )
      )
    ) ||
    @sys.list_dir_all(native_codex_app_server_working_directory(config)).length() !=
    0 {
    return true
  }
  for
    entry in [
      "config.toml", "rules", "plugins", "skills", "commands", "agents", "hooks",
    ] {
    if @sys.path_entry_exists(config.sterile_root + "/codex-home/" + entry) {
      if !(allow_provider_state &&
        entry == "skills" &&
        @sys.list_dir_all(config.sterile_root + "/codex-home/skills") ==
        [".system"]) {
        return true
      }
    }
  }
  false
}

///|
test "native Codex Take environment is an exact allowlist" {
  let environment = native_codex_app_server_environment("/sterile-take", "")
  assert_eq(environment.length(), 6)
  assert_eq(environment["HOME"], "/sterile-take/home")
  assert_eq(environment["CODEX_HOME"], "/sterile-take/codex-home")
  assert_eq(environment["TMPDIR"], "/sterile-take/tmp")
  assert_false(environment.contains("OPENAI_API_KEY"))
  assert_false(environment.contains("CHOIR_CONDUCTOR_TOKEN"))
  assert_false(environment.contains("CHOIR_LISTEN_UDS"))
}

///|
fn native_codex_conductor_environment(
  provider_home : String,
  config : NativeCodexConductorConfig,
) -> Map[String, String] {
  let environment = native_codex_environment(provider_home, config.sterile_root)
  environment["CODEX_HOME"] = config.sterile_root + "/codex-home"
  environment["CHOIR_CONDUCTOR_TOKEN"] = config.environment.conductor_token
  environment["CHOIR_STATUSLINE_CACHE_KEY"] = config.environment.statusline_cache_key
  environment["CHOIR_WORKSPACE"] = config.environment.workspace
  environment["CHOIR_LISTEN_UDS"] = config.environment.listen_uds
  environment
}

///|
fn prepare_native_codex_conductor_home(
  config : NativeCodexConductorConfig,
  provider_home : String,
) -> Result[Unit, @types.ChoirError] {
  for
    path in [
      config.sterile_root,
      config.sterile_root + "/tmp",
      config.sterile_root + "/codex-home",
    ] {
    if !@sys.create_dir_all(path) || !@sys.chmod_mode(path, 0o700) {
      return Err(
        native_codex_driver_error("Conductor state root is unavailable"),
      )
    }
  }
  let provider_codex_home = match @sys.getenv("CODEX_HOME") {
    Some(value) if value.has_prefix("/") => value
    _ => provider_home + "/.codex"
  }
  let auth_source = provider_codex_home + "/auth.json"
  if !@sys.path_exists(auth_source) ||
    !@sys.symlink_force(
      auth_source,
      config.sterile_root + "/codex-home/auth.json",
    ) {
    return Err(
      native_codex_driver_error("provider-managed login is unavailable"),
    )
  }
  Ok(())
}

///|
test "native Codex Conductor environment isolates writable provider state" {
  let config : NativeCodexConductorConfig = {
    sterile_root: "/run/choir/conductor",
    mcp_executable: "/opt/choir/bin/choir",
    mcp_arguments: [],
    mcp_server_name: "choir",
    allowed_tools: ["goal_status"],
    developer_instructions: "Use Choir.",
    timeout_ms: 1000,
    environment: {
      conductor_token: "token",
      statusline_cache_key: "conductor-42",
      workspace: "/repo",
      listen_uds: "/run/choir/server.sock",
    },
  }
  let environment = native_codex_conductor_environment("/home/user", config)
  assert_eq(environment["HOME"], "/home/user")
  assert_eq(environment["CODEX_HOME"], "/run/choir/conductor/codex-home")
  assert_eq(environment["CHOIR_WORKSPACE"], "/repo")
}

///|
async fn verify_native_codex_file(
  path : String,
  expected_sha256 : String,
  label : String,
) -> Result[Unit, @types.ChoirError] {
  let collected = @process.collect_output_merged(
    "/usr/bin/sha256sum",
    [path],
    extra_env={ "PATH": "/usr/bin:/bin", "LC_ALL": "C" },
    inherit_env=false,
    cwd="/tmp",
  ) catch {
    _ => return Err(native_codex_driver_error(label + " hash probe failed"))
  }
  let (exit_code, data) = collected
  let output = data.text() catch {
    _ => return Err(native_codex_driver_error(label + " hash was not UTF-8"))
  }
  if exit_code != 0 || !output.has_prefix(expected_sha256 + " ") {
    Err(
      @types.ChoirError::policy_blocked(
        "Codex " + label + " does not match the admitted pin",
      ),
    )
  } else {
    Ok(())
  }
}

///|
async fn verify_native_codex_binary(
  codex : String,
) -> Result[String, @types.ChoirError] {
  let launcher = match @sys.realpath_native(codex) {
    Some(value) => value
    None => return Err(native_codex_driver_error("launcher path is invalid"))
  }
  let suffix = "/@openai/codex/bin/codex.js"
  if !launcher.has_suffix(suffix) {
    return Err(
      @types.ChoirError::policy_blocked(
        "Codex launcher is outside the admitted package layout",
      ),
    )
  }
  let modules_root = launcher[:launcher.length() - suffix.length()].to_owned()
  let native = modules_root +
    "/@openai/codex-linux-x64/vendor/x86_64-unknown-linux-musl/bin/codex"
  match
    verify_native_codex_file(
      launcher, @harness.expected_codex_executable_sha256, "JavaScript launcher",
    ) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match
    verify_native_codex_file(
      native, @harness.expected_codex_native_executable_sha256, "native executable",
    ) {
    Ok(_) => Ok(native)
    Err(error) => Err(error)
  }
}

///|
async fn verify_native_codex_subscription(
  codex : String,
  provider_home : String,
  sterile_root : String,
) -> Result[Unit, @types.ChoirError] {
  let collected = @process.collect_output_merged(
    codex,
    ["login", "status"],
    extra_env=native_codex_environment(provider_home, sterile_root),
    inherit_env=false,
    cwd=sterile_root,
  ) catch {
    _ => return Err(native_codex_driver_error("login status probe failed"))
  }
  let (exit_code, data) = collected
  let output = data.text() catch {
    _ => return Err(native_codex_driver_error("login status was not UTF-8"))
  }
  if exit_code != 0 || output.trim().to_owned() != "Logged in using ChatGPT" {
    Err(
      @types.ChoirError::policy_blocked(
        "Codex is not using provider-managed ChatGPT authentication",
      ),
    )
  } else {
    Ok(())
  }
}

///|
priv enum NativeCodexTakeState {
  CodexServerStarting
  CodexThreadReady
  CodexTurnRunning
  CodexTurnCompleted
  CodexTurnInterrupted
} derive(Eq, ToJson, FromJson)

///|
priv struct NativeCodexTakeManifest {
  version : Int
  session_id : @control.HarnessSessionId
  take_id : @control.TakeId
  role : @harness.CodexTakeRole
  surface_digest : @control.Digest
  server_pid : Int
  server_generation : Int
  server_initialized : Bool
  initialization_notification_may_have_been_sent : Bool
  initialization_attestation_digest : @control.Digest?
  thread_id : String?
  turn_id : String?
  client_user_message_id : String
  read_ordinal : Int
  state : NativeCodexTakeState
  started_at : Int64
  finished_at : Int64?
  terminal_trace : String?
} derive(ToJson, FromJson)

///|
fn native_codex_manifest_path(config : NativeCodexDriverConfig) -> String {
  config.sterile_root + "/take-session.json"
}

///|
pub fn read_native_codex_initialization_attestation(
  sterile_root : String,
) -> @control.Digest? {
  let path = sterile_root + "/take-session.json"
  if !sterile_root.has_prefix("/") ||
    !@sys.path_exists(path) ||
    @sys.file_size(path) <= 0 ||
    @sys.file_size(path) > 65536 {
    return None
  }
  let json = @json.parse(@sys.read_file(path)) catch { _ => return None }
  let manifest : NativeCodexTakeManifest = @json.from_json(json) catch {
    _ => return None
  }
  if manifest.version == 4 && manifest.server_initialized {
    manifest.initialization_attestation_digest
  } else {
    None
  }
}

///|
fn native_codex_fifo_path(config : NativeCodexDriverConfig) -> String {
  config.sterile_root + "/app-server.stdin"
}

///|
fn native_codex_log_path(config : NativeCodexDriverConfig) -> String {
  config.sterile_root + "/app-server.jsonl"
}

///|
fn native_codex_pid_witness_path(
  config : NativeCodexDriverConfig,
  generation : Int,
) -> String {
  config.sterile_root + "/app-server-" + generation.to_string() + ".pid"
}

///|
fn native_codex_owned_server_alive(
  config : NativeCodexDriverConfig,
  pid : Int,
) -> Bool {
  if pid <= 0 || !@sys.pgid_is_alive(pid) {
    return false
  }
  let command = @sys.read_file_prefix(
    "/proc/" + pid.to_string() + "/cmdline",
    65536,
  )
  (command.contains(config.sterile_root) && command.contains("app-server")) ||
  @sys.pgid_has_process_identity(
    pid,
    "CODEX_HOME=" + config.sterile_root + "/codex-home",
    "app-server",
  )
}

///|
fn native_codex_witnessed_server_pid(
  config : NativeCodexDriverConfig,
  generation : Int,
) -> Int? {
  let pid = match native_codex_pid_witness(config, generation) {
    Some(value) => value
    None => return None
  }
  if native_codex_owned_server_alive(config, pid) {
    Some(pid)
  } else {
    None
  }
}

///|
fn native_codex_pid_witness(
  config : NativeCodexDriverConfig,
  generation : Int,
) -> Int? {
  let raw = @sys.read_file(native_codex_pid_witness_path(config, generation))
    .trim()
    .to_owned()
  let pid = @string.parse_int(raw) catch { _ => return None }
  if pid > 1 {
    Some(pid)
  } else {
    None
  }
}

///|
fn stop_native_codex_owned_server(
  config : NativeCodexDriverConfig,
  pid : Int,
) -> Unit {
  if native_codex_owned_server_alive(config, pid) {
    @sys.kill_pgid_sequence_best_effort(pid)
  }
}

///|
fn store_native_codex_manifest(
  config : NativeCodexDriverConfig,
  manifest : NativeCodexTakeManifest,
) -> Result[Unit, @types.ChoirError] {
  if @sys.write_file_atomic(
      native_codex_manifest_path(config),
      ToJson::to_json(manifest).stringify(indent=0) + "\n",
    ) {
    Ok(())
  } else {
    Err(native_codex_driver_error("Take session manifest write failed"))
  }
}

///|
fn load_native_codex_manifest(
  config : NativeCodexDriverConfig,
  session : @control.HarnessSession,
  role : @harness.CodexTakeRole,
) -> Result[NativeCodexTakeManifest?, @types.ChoirError] {
  let path = native_codex_manifest_path(config)
  if !@sys.path_exists(path) {
    return Ok(None)
  }
  if @sys.file_size(path) <= 0 || @sys.file_size(path) > 65536 {
    return Err(native_codex_driver_error("Take session manifest is invalid"))
  }
  let json = @json.parse(@sys.read_file(path)) catch {
    _ =>
      return Err(native_codex_driver_error("Take session manifest is not JSON"))
  }
  let manifest : NativeCodexTakeManifest = @json.from_json(json) catch {
    _ =>
      return Err(
        native_codex_driver_error("Take session manifest schema is invalid"),
      )
  }
  if manifest.version != 4 ||
    manifest.session_id != session.id ||
    manifest.take_id != session.take_id ||
    manifest.role != role ||
    manifest.surface_digest != session.effective_surface_manifest_digest ||
    manifest.server_generation < 0 ||
    manifest.read_ordinal < 0 ||
    manifest.client_user_message_id == "" ||
    manifest.initialization_notification_may_have_been_sent !=
    (manifest.initialization_attestation_digest is Some(_)) ||
    (
      manifest.server_initialized &&
      !manifest.initialization_notification_may_have_been_sent
    ) {
    Err(native_codex_driver_error("Take session manifest identity is stale"))
  } else {
    Ok(Some(manifest))
  }
}

///|
fn attest_native_codex_initialization(
  config : NativeCodexDriverConfig,
  response : Json,
) -> Result[@control.Digest, @types.ChoirError] {
  guard response is Object(fields) else {
    return Err(native_codex_driver_error("initialization response is invalid"))
  }
  let user_agent = match @types.json_field_string(fields, "userAgent") {
    Some(value) => value
    None =>
      return Err(native_codex_driver_error("initialization identity is absent"))
  }
  let codex_home = match @types.json_field_string(fields, "codexHome") {
    Some(value) => value
    None =>
      return Err(native_codex_driver_error("initialization home is absent"))
  }
  let platform_family = @types.json_field_string(fields, "platformFamily")
  let platform_os = @types.json_field_string(fields, "platformOs")
  if !user_agent.contains(
      "choir/" +
      @harness.expected_surface_version(@harness.ProviderSurface::CodexCli),
    ) ||
    !user_agent.contains("(choir; 0.1.0)") ||
    codex_home != config.sterile_root + "/codex-home" ||
    platform_family != Some("unix") ||
    platform_os != Some("linux") {
    return Err(
      native_codex_driver_error("initialization identity does not match"),
    )
  }
  Ok(
    @storage.artifact_digest(
      @utf8.encode(
        "choir.codex-initialization-attestation.v1\u{00}" +
        user_agent +
        "\u{00}" +
        codex_home +
        "\u{00}unix\u{00}linux",
      ),
    ),
  )
}

///|
fn native_codex_object_field(
  fields : Map[String, Json],
  key : String,
) -> Map[String, Json]? {
  match fields.get(key) {
    Some(Object(value)) => Some(value)
    _ => None
  }
}

///|
fn native_codex_array_field(
  fields : Map[String, Json],
  key : String,
) -> Array[Json]? {
  match fields.get(key) {
    Some(Array(value)) => Some(value)
    _ => None
  }
}

///|
/// Look for one request's response in the spool, scanning only what the spool
/// has grown by since `from_offset`. Returns the response, if it has arrived,
/// and the offset scanned to so the next poll resumes there.
fn native_codex_response_from_log(
  config : NativeCodexDriverConfig,
  request_id : String,
  server_pid? : Int = 0,
  from_offset? : Int = 0,
) -> Result[(Json?, Int), @types.ChoirError] {
  let path = native_codex_log_path(config)
  if !@sys.path_exists(path) {
    return Ok((None, from_offset))
  }
  let size = @sys.file_size(path)
  match @harness.validate_codex_event_spool_size(size) {
    Ok(_) => ()
    Err(error) => {
      if server_pid > 0 {
        @sys.kill_pgid_sequence_best_effort(server_pid)
      }
      return Err(error)
    }
  }
  // The spool is append-only, so each poll reads only what it has grown by.
  // Re-reading and re-parsing all of it every 50ms cost up to 16 MiB per poll
  // for as long as a request was outstanding.
  let (appended, read_to) = @sys.read_file_from(path, from_offset)
  // A trailing fragment is a line the app-server is still writing. Consuming
  // the offset past it would drop that response entirely, so the scan stops at
  // the last newline and the fragment is re-read next poll.
  let complete = match appended.rev_find("\n") {
    Some(index) => appended.view(end_offset=index + 1).to_owned()
    None => ""
  }
  let scanned = from_offset + @utf8.encode(complete).length()
  for raw in complete.split("\n") {
    let line = raw.trim().to_owned()
    if line == "" {
      continue
    }
    let json = @json.parse(line) catch { _ => continue }
    guard json is Object(fields) else { continue }
    if @types.json_field_string(fields, "id") != Some(request_id) {
      continue
    }
    match fields.get("error") {
      Some(Object(error)) => {
        let message = match @types.json_field_string(error, "message") {
          Some(value) => value
          None => "unknown app-server error"
        }
        // The code is retained rather than flattened into prose. It does not
        // discriminate on its own — the app-server answers -32600 for an
        // unknown method, a missing field, and an unloaded thread alike — but
        // a caller that must decide whether to recover deserves the typed
        // value rather than only the text.
        let code = match error.get("code") {
          Some(Number(value, ..)) => value.to_int()
          _ => @harness.codex_invalid_request_code()
        }
        return Err(@types.ChoirError::provider_rpc_error(code, message))
      }
      _ => ()
    }
    match fields.get("result") {
      Some(result) => return Ok((Some(result), scanned))
      None =>
        return Err(
          native_codex_driver_error("app-server response has no result"),
        )
    }
  }
  ignore(read_to)
  Ok((None, scanned))
}

///|
async fn write_native_codex_app_server(
  config : NativeCodexDriverConfig,
  message : Json,
) -> Result[Unit, @types.ChoirError] {
  let fifo = native_codex_fifo_path(config)
  let (stdin_read, stdin_write) = @process.write_to_process() catch {
    _ => return Err(native_codex_driver_error("app-server request pipe failed"))
  }
  ignore(
    stdin_write.write(message.stringify(indent=0) + "\n") catch {
      _ => {
        stdin_write.close()
        return Err(native_codex_driver_error("app-server request write failed"))
      }
    },
  )
  stdin_write.close()
  let sink = @process.redirect_to_file(
    config.sterile_root + "/app-server-request.sink",
    create_mode=@fs.CreateOrTruncate,
  ) catch {
    _ => return Err(native_codex_driver_error("app-server request sink failed"))
  }
  abort_if_hermetic_test_exec("/usr/bin/timeout 5s /usr/bin/tee " + fifo)
  let code = @process.run(
    "/usr/bin/timeout",
    ["5s", "/usr/bin/tee", fifo],
    extra_env={ "PATH": "/usr/bin:/bin", "LC_ALL": "C" },
    inherit_env=false,
    stdin=stdin_read,
    stdout=sink,
    stderr=sink,
    cwd=native_codex_app_server_working_directory(config),
  ) catch {
    _ => return Err(native_codex_driver_error("app-server request failed"))
  }
  if code == 0 {
    Ok(())
  } else {
    Err(native_codex_driver_error("app-server request transport failed"))
  }
}

///|
async fn request_native_codex_app_server(
  config : NativeCodexDriverConfig,
  request_id : String,
  method_name : String,
  params : Json,
  server_pid? : Int = 0,
) -> Result[Json, @types.ChoirError] {
  // The response may already be in the spool: a retried request must not be
  // written twice.
  let mut offset = 0
  match native_codex_response_from_log(config, request_id, server_pid~) {
    Ok((Some(value), _)) => return Ok(value)
    Ok((None, scanned)) => offset = scanned
    Err(error) => return Err(error)
  }
  let request : Map[String, Json] = {
    "id": request_id.to_json(),
    "method": method_name.to_json(),
    "params": params,
  }
  match write_native_codex_app_server(config, request.to_json()) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  for poll = 0; poll < 200; poll = poll + 1 {
    match
      native_codex_response_from_log(
        config,
        request_id,
        server_pid~,
        from_offset=offset,
      ) {
      Ok((Some(value), _)) => return Ok(value)
      Ok((None, scanned)) => {
        offset = scanned
        @async.sleep(50)
      }
      Err(error) => return Err(error)
    }
  }
  Err(@types.ChoirError::timeout("Codex app-server request"))
}

///|
async fn notify_native_codex_app_server(
  config : NativeCodexDriverConfig,
  method_name : String,
  params : Json,
) -> Result[Unit, @types.ChoirError] {
  let notification : Map[String, Json] = {
    "method": method_name.to_json(),
    "params": params,
  }
  write_native_codex_app_server(config, notification.to_json())
}

///|
fn prepare_native_codex_app_server_home(
  config : NativeCodexDriverConfig,
  provider_home : String,
  allow_provider_state : Bool,
) -> Result[Unit, @types.ChoirError] {
  for
    path in [
      config.sterile_root,
      config.sterile_root + "/tmp",
      config.sterile_root + "/home",
      config.sterile_root + "/codex-home",
      native_codex_app_server_working_directory(config),
    ] {
    if !@sys.create_dir_all(path) || !@sys.chmod_mode(path, 0o700) {
      return Err(native_codex_driver_error("app-server root is unavailable"))
    }
  }
  match config.boxlite_owner_socket_root {
    Some(source) =>
      if @sys.realpath_native(source) != Some(source) ||
        @sys.realpath_native(source + "/owner.sock") !=
        Some(source + "/owner.sock") {
        return Err(
          native_codex_driver_error("BoxLite owner socket is unavailable"),
        )
      }
    None => ()
  }
  if native_codex_ambient_configuration_present(config, allow_provider_state) {
    return Err(
      @types.ChoirError::policy_blocked(
        "Codex Take ambient configuration is present",
      ),
    )
  }
  let provider_codex_home = match @sys.getenv("CODEX_HOME") {
    Some(value) if value.has_prefix("/") => value
    _ => provider_home + "/.codex"
  }
  let auth_source = provider_codex_home + "/auth.json"
  if !@sys.path_exists(auth_source) ||
    !@sys.symlink_force(
      auth_source,
      config.sterile_root + "/codex-home/auth.json",
    ) {
    return Err(
      native_codex_driver_error("provider-managed login is unavailable"),
    )
  }
  Ok(())
}

///|
async fn spawn_native_codex_app_server(
  config : NativeCodexDriverConfig,
  codex : String,
  manifest : NativeCodexTakeManifest,
  after_server_started : () -> Unit,
) -> Result[NativeCodexTakeManifest, @types.ChoirError] {
  let prepared = {
    ..manifest,
    server_pid: 0,
    server_generation: manifest.server_generation + 1,
    server_initialized: false,
    initialization_notification_may_have_been_sent: false,
    initialization_attestation_digest: None,
  }
  match store_native_codex_manifest(config, prepared) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let pid_witness = native_codex_pid_witness_path(
    config,
    prepared.server_generation,
  )
  if @sys.path_entry_exists(pid_witness) && !@sys.delete_file_sync(pid_witness) {
    return Err(
      native_codex_driver_error("stale app-server PID witness remains"),
    )
  }
  let fifo = native_codex_fifo_path(config)
  if @sys.path_entry_exists(fifo) && !@sys.delete_file_sync(fifo) {
    return Err(
      native_codex_driver_error("stale app-server input could not be removed"),
    )
  }
  let created = @process.collect_output_merged(
    "/usr/bin/mkfifo",
    ["-m", "600", fifo],
    extra_env={ "PATH": "/usr/bin:/bin", "LC_ALL": "C" },
    inherit_env=false,
    cwd=native_codex_app_server_working_directory(config),
  ) catch {
    _ =>
      return Err(native_codex_driver_error("app-server input creation failed"))
  }
  if created.0 != 0 {
    return Err(native_codex_driver_error("app-server input creation failed"))
  }
  let script =
    #|fifo=$1
    #|output=$2
    #|errors=$3
    #|pid_witness=$4
    #|shift 4
    #|printf '%s\n' "$$" > "$pid_witness"
    #|exec 3<>"$fifo"
    #|"$@" <&3 >>"$output" 2>>"$errors"
  let arguments : Array[String] = [
    "/bin/sh",
    "-c",
    script,
    "choir-codex-app-server",
    fifo,
    native_codex_log_path(config),
    config.sterile_root + "/app-server.stderr",
    pid_witness,
    "/usr/bin/bwrap",
  ]
  let app_server_args = native_codex_app_server_args(config)
  let traced_program = match config.connect_trace_path {
    Some(_) => "/usr/bin/strace"
    None => codex
  }
  let traced_args : Array[String] = match config.connect_trace_path {
    Some(path) =>
      [
        "-f", "-qq", "-s", "256", "-e", "trace=connect", "-o", path, codex, ..app_server_args,
      ]
    None => app_server_args
  }
  for
    argument in native_provider_host_boundary_args(
      config.sterile_root,
      native_codex_app_server_working_directory(config),
      config.boxlite_owner_socket_root,
      traced_program,
      traced_args,
    ) {
    arguments.push(argument)
  }
  let sink = @process.redirect_to_file(
    config.sterile_root + "/app-server.sink",
    create_mode=@fs.CreateOrTruncate,
  ) catch {
    _ => return Err(native_codex_driver_error("app-server sink failed"))
  }
  abort_if_hermetic_test_exec(
    "/usr/bin/setsid /bin/sh -c <bwrap-codex-app-server>",
  )
  let pid = @process.spawn_orphan(
    "/usr/bin/setsid",
    arguments,
    extra_env=native_codex_app_server_environment(
      config.sterile_root,
      config.execution_token,
    ),
    inherit_env=false,
    stdout=sink,
    stderr=sink,
    cwd=native_codex_app_server_working_directory(config),
  ) catch {
    _ => return Err(native_codex_driver_error("app-server failed to start"))
  }
  let mut witnessed_pid : Int? = None
  for poll = 0; poll < 100; poll = poll + 1 {
    match
      native_codex_witnessed_server_pid(config, prepared.server_generation) {
      Some(value) => {
        witnessed_pid = Some(value)
        break
      }
      None => ()
    }
    @async.sleep(10)
  }
  let server_pid = match witnessed_pid {
    Some(value) => value
    None => {
      match native_codex_pid_witness(config, prepared.server_generation) {
        Some(value) => stop_native_codex_owned_server(config, value)
        None => ()
      }
      stop_native_codex_owned_server(config, pid)
      return Err(native_codex_driver_error("app-server PID witness is absent"))
    }
  }
  after_server_started()
  let updated = { ..prepared, server_pid, }
  match store_native_codex_manifest(config, updated) {
    Ok(_) => Ok(updated)
    Err(error) => {
      stop_native_codex_owned_server(config, server_pid)
      Err(error)
    }
  }
}

///|
async fn ensure_native_codex_app_server(
  config : NativeCodexDriverConfig,
  codex : String,
  manifest : NativeCodexTakeManifest,
  after_server_started : () -> Unit,
  after_initialized_notification_sent : () -> Unit,
) -> Result[NativeCodexTakeManifest, @types.ChoirError] {
  let mut manifest = manifest
  if manifest.server_pid > 0 &&
    @sys.pgid_is_alive(manifest.server_pid) &&
    !native_codex_owned_server_alive(config, manifest.server_pid) {
    return Err(native_codex_driver_error("app-server process identity changed"))
  }
  if !native_codex_owned_server_alive(config, manifest.server_pid) &&
    manifest.server_generation > 0 {
    match
      native_codex_witnessed_server_pid(config, manifest.server_generation) {
      Some(pid) => {
        manifest = { ..manifest, server_pid: pid }
        match store_native_codex_manifest(config, manifest) {
          Ok(_) => ()
          Err(error) => return Err(error)
        }
      }
      None => ()
    }
  }
  if !native_codex_owned_server_alive(config, manifest.server_pid) {
    manifest = match
      spawn_native_codex_app_server(
        config, codex, manifest, after_server_started,
      ) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
  }
  if !manifest.server_initialized &&
    manifest.initialization_notification_may_have_been_sent {
    stop_native_codex_owned_server(config, manifest.server_pid)
    manifest = match
      spawn_native_codex_app_server(
        config, codex, manifest, after_server_started,
      ) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
  }
  if manifest.server_initialized {
    return Ok(manifest)
  }
  let generation = manifest.server_generation.to_string()
  let initialize : Map[String, Json] = {
    "clientInfo": {
      "name": "choir".to_json(),
      "title": "Choir".to_json(),
      "version": "0.1.0".to_json(),
    }.to_json(),
  }
  let initialization = match
    request_native_codex_app_server(
      config,
      "initialize:" + generation,
      "initialize",
      initialize.to_json(),
      server_pid=manifest.server_pid,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let attestation_digest = match
    attest_native_codex_initialization(config, initialization) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  manifest = {
    ..manifest,
    initialization_notification_may_have_been_sent: true,
    initialization_attestation_digest: Some(attestation_digest),
  }
  match store_native_codex_manifest(config, manifest) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match
    notify_native_codex_app_server(config, "initialized", Json::empty_object()) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  after_initialized_notification_sent()
  manifest = { ..manifest, server_initialized: true }
  match store_native_codex_manifest(config, manifest) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match manifest.thread_id {
    Some(thread_id) => {
      let params : Map[String, Json] = { "threadId": thread_id.to_json() }
      match
        request_native_codex_app_server(
          config,
          "thread-resume:" + generation,
          "thread/resume",
          params.to_json(),
          server_pid=manifest.server_pid,
        ) {
        Ok(_) => ()
        Err(error) => return Err(error)
      }
    }
    None => ()
  }
  Ok(manifest)
}

///|
fn native_codex_result_object(
  result : Json,
  key : String,
) -> Result[Map[String, Json], @types.ChoirError] {
  guard result is Object(fields) else {
    return Err(native_codex_driver_error("app-server result is not an object"))
  }
  match native_codex_object_field(fields, key) {
    Some(value) => Ok(value)
    None =>
      Err(native_codex_driver_error("app-server result schema is invalid"))
  }
}

///|
async fn read_native_codex_thread(
  config : NativeCodexDriverConfig,
  manifest : NativeCodexTakeManifest,
) -> Result[(NativeCodexTakeManifest, Json), @types.ChoirError] {
  let thread_id = match manifest.thread_id {
    Some(value) => value
    None =>
      return Err(native_codex_driver_error("thread identity is unavailable"))
  }
  let next = { ..manifest, read_ordinal: manifest.read_ordinal + 1 }
  match store_native_codex_manifest(config, next) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let params : Map[String, Json] = {
    "threadId": thread_id.to_json(),
    "includeTurns": true.to_json(),
  }
  let result = match
    request_native_codex_app_server(
      config,
      "thread-read:" + next.read_ordinal.to_string(),
      "thread/read",
      params.to_json(),
      server_pid=next.server_pid,
    ) {
    Ok(value) => value
    Err(error) if native_codex_thread_is_unmaterialized(error) => {
      let empty_thread : Map[String, Json] = {
        "id": thread_id.to_json(),
        "turns": ([] : Array[Json]).to_json(),
      }
      return Ok((next, empty_thread.to_json()))
    }
    Err(error) => return Err(error)
  }
  let thread = match native_codex_result_object(result, "thread") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok((next, thread.to_json()))
}

///|
fn native_codex_turn_client_id(turn : Map[String, Json]) -> String? {
  match native_codex_array_field(turn, "items") {
    Some(items) =>
      for item in items {
        guard item is Object(fields) else { continue }
        if @types.json_field_string(fields, "type") == Some("userMessage") {
          match @types.json_field_string(fields, "clientId") {
            Some(value) => return Some(value)
            None => ()
          }
        }
      }
    None => ()
  }
  None
}

///|
fn find_native_codex_turn(
  thread : Json,
  manifest : NativeCodexTakeManifest,
) -> Map[String, Json]? {
  guard thread is Object(fields) else { return None }
  let turns = match native_codex_array_field(fields, "turns") {
    Some(value) => value
    None => return None
  }
  for turn in turns {
    guard turn is Object(turn_fields) else { continue }
    let id = @types.json_field_string(turn_fields, "id")
    match manifest.turn_id {
      Some(expected) if id == Some(expected) => return Some(turn_fields)
      Some(_) => ()
      None =>
        if native_codex_turn_client_id(turn_fields) ==
          Some(manifest.client_user_message_id) {
          return Some(turn_fields)
        }
    }
  }
  None
}

///|
/// Longest the turn poll may rely on the notification stream alone before it
/// reads the thread again. The read is the authority on turn status; this
/// bounds how long a missing or unrecognized `turn/*` notification can delay
/// observing a terminal turn.
let native_codex_turn_read_interval_ms : Int = 30000

///|
/// Latest status the app-server published for `turn_id` in its notification
/// stream.
///
/// `thread/read` returns the whole thread on every call, so polling it at the
/// turn cadence appends a full thread snapshot to the append-only event spool
/// on every iteration: spool bytes grow with reads times thread size while the
/// thread itself stays small, and the ingestion budget is exhausted by repeated
/// copies of one conversation rather than by event volume. The `turn/started`
/// and `turn/completed` notifications already carry `params.turn.status`, so
/// the poll watches them instead and reads the thread only once the turn is no
/// longer running.
/// What this turn reported spending, read from the app-server's own
/// `thread/tokenUsage/updated` notifications in the response spool. The last
/// notification naming this turn wins: earlier ones are partial.
fn native_codex_turn_usage_from_events(
  spool : String,
  turn_id : String,
) -> @control.TakeUsage? {
  let mut usage = None
  for raw in spool.split("\n") {
    let line = raw.trim().to_owned()
    if line == "" {
      continue
    }
    let json = @json.parse(line) catch { _ => continue }
    guard json is Object(fields) else { continue }
    if @types.json_field_string(fields, "method") !=
      Some("thread/tokenUsage/updated") {
      continue
    }
    let params = match native_codex_object_field(fields, "params") {
      Some(value) => value
      None => continue
    }
    if @types.json_field_string(params, "turnId") != Some(turn_id) {
      continue
    }
    match @harness.codex_turn_usage(params) {
      Some(value) => usage = Some(value)
      None => ()
    }
  }
  usage
}

///|
test "Codex turn usage is read from the spool for the exact turn" {
  let spool =
    #|{"method":"thread/tokenUsage/updated","params":{"threadId":"t","turnId":"turn-other","tokenUsage":{"last":{"cachedInputTokens":1,"inputTokens":1,"outputTokens":1,"reasoningOutputTokens":0,"totalTokens":3}}}}
    #|{"method":"thread/tokenUsage/updated","params":{"threadId":"t","turnId":"turn-1","tokenUsage":{"last":{"cachedInputTokens":10,"inputTokens":20,"outputTokens":5,"reasoningOutputTokens":0,"totalTokens":35}}}}
    #|{"method":"thread/tokenUsage/updated","params":{"threadId":"t","turnId":"turn-1","tokenUsage":{"last":{"cachedInputTokens":900,"inputTokens":120,"outputTokens":45,"reasoningOutputTokens":15,"totalTokens":1080,"cacheWriteInputTokens":30}}}}
  // The last notification for this turn wins; another turn's is ignored.
  assert_eq(
    native_codex_turn_usage_from_events(spool, "turn-1"),
    Some({
      input_tokens: 120,
      output_tokens: 60,
      cache_read_tokens: 900,
      cache_creation_tokens: 30,
      wall_time_ms: 0,
    }),
  )
  assert_eq(native_codex_turn_usage_from_events(spool, "turn-absent"), None)
  assert_eq(native_codex_turn_usage_from_events("", "turn-1"), None)
}

///|
/// What the surface last said about its own allowance, read from the
/// `account/rateLimits/updated` notifications in the response spool. The last
/// one wins: the snapshot is a rolling update, so an earlier reset instant has
/// already been superseded.
///
/// This answers only once the app-server has reported that a limit is reached.
/// A turn can fail for reasons that have nothing to do with the allowance, and
/// attaching a reset to those would defer a surface that is able to serve.
fn native_codex_allowance_from_events(
  spool : String,
) -> @types.ProviderAllowanceObservation? {
  let mut allowance = None
  for raw in spool.split("\n") {
    let line = raw.trim().to_owned()
    if line == "" {
      continue
    }
    let json = @json.parse(line) catch { _ => continue }
    guard json is Object(fields) else { continue }
    if @types.json_field_string(fields, "method") !=
      Some("account/rateLimits/updated") {
      continue
    }
    let params = match native_codex_object_field(fields, "params") {
      Some(value) => value
      None => continue
    }
    match @harness.codex_rate_limit_allowance(params) {
      Some(value) => allowance = Some(value)
      None => ()
    }
  }
  allowance
}

///|
test "a Codex allowance is read only once the surface says it is reached" {
  let healthy =
    #|{"method":"account/rateLimits/updated","params":{"rateLimits":{"limitId":"codex","planType":"prolite","rateLimitReachedType":null,"primary":{"usedPercent":20,"windowDurationMins":10080,"resetsAt":1785614465}}}}
  // A routine snapshot of a healthy window is not evidence of exhaustion.
  assert_eq(native_codex_allowance_from_events(healthy), None)
  let reached = healthy +
    "\n" +
    (
      #|{"method":"account/rateLimits/updated","params":{"rateLimits":{"limitId":"codex","rateLimitReachedType":"rate_limit_reached","primary":{"usedPercent":100,"windowDurationMins":10080,"resetsAt":1785700000}}}}
    )
  assert_eq(
    native_codex_allowance_from_events(reached),
    Some({ reset_at: Some(1785700000L), retry_after_seconds: None }),
  )
  // The rolling update supersedes the earlier reset rather than accumulating.
  let superseded = reached +
    "\n" +
    (
      #|{"method":"account/rateLimits/updated","params":{"rateLimits":{"rateLimitReachedType":"workspace_owner_credits_depleted","primary":{"usedPercent":100,"resetsAt":1785800000}}}}
    )
  assert_eq(
    native_codex_allowance_from_events(superseded),
    Some({ reset_at: Some(1785800000L), retry_after_seconds: None }),
  )
  // The longer window answers only when the primary reported no reset.
  assert_eq(
    native_codex_allowance_from_events(
      (
        #|{"method":"account/rateLimits/updated","params":{"rateLimits":{"rateLimitReachedType":"rate_limit_reached","primary":{"usedPercent":100,"resetsAt":null},"secondary":{"usedPercent":100,"resetsAt":1785900000}}}}
      ),
    ),
    Some({ reset_at: Some(1785900000L), retry_after_seconds: None }),
  )
  assert_eq(native_codex_allowance_from_events(""), None)
}

///|
fn native_codex_turn_status_from_events(
  spool : String,
  turn_id : String,
) -> String? {
  let mut status = None
  for raw in spool.split("\n") {
    let line = raw.trim().to_owned()
    if line == "" {
      continue
    }
    let json = @json.parse(line) catch { _ => continue }
    guard json is Object(fields) else { continue }
    let notification = match @types.json_field_string(fields, "method") {
      Some(value) => value
      None => continue
    }
    if !notification.has_prefix("turn/") {
      continue
    }
    let params = match native_codex_object_field(fields, "params") {
      Some(value) => value
      None => continue
    }
    let turn = match native_codex_object_field(params, "turn") {
      Some(value) => value
      None => continue
    }
    if @types.json_field_string(turn, "id") != Some(turn_id) {
      continue
    }
    match @types.json_field_string(turn, "status") {
      Some(value) => status = Some(value)
      None => ()
    }
  }
  status
}

///|
fn native_codex_observed_turn_status(
  config : NativeCodexDriverConfig,
  turn_id : String,
) -> String? {
  let path = native_codex_log_path(config)
  if !@sys.path_exists(path) {
    return None
  }
  native_codex_turn_status_from_events(@sys.read_file(path), turn_id)
}

///|
fn native_codex_turn_trace(
  thread_id : String,
  turn : Map[String, Json],
) -> Result[String, @types.ChoirError] {
  let turn_id = match @types.json_field_string(turn, "id") {
    Some(value) => value
    None => return Err(native_codex_driver_error("turn identity is absent"))
  }
  let lines : Array[String] = []
  lines.push(
    { "type": "thread.started".to_json(), "thread_id": thread_id.to_json() }
    .to_json()
    .stringify(indent=0),
  )
  lines.push(
    { "type": "turn.started".to_json(), "turn_id": turn_id.to_json() }
    .to_json()
    .stringify(indent=0),
  )
  let items = match native_codex_array_field(turn, "items") {
    Some(value) => value
    None => return Err(native_codex_driver_error("turn items are absent"))
  }
  for item in items {
    guard item is Object(fields) else {
      return Err(native_codex_driver_error("turn item is not an object"))
    }
    match @types.json_field_string(fields, "type") {
      Some("userMessage") | Some("reasoning") => ()
      Some("agentMessage") => {
        let translated : Map[String, Json] = {
          "id": match @types.json_field_string(fields, "id") {
            Some(value) => value.to_json()
            None => "missing".to_json()
          },
          "type": "agent_message".to_json(),
          "text": match @types.json_field_string(fields, "text") {
            Some(value) => value.to_json()
            None => "".to_json()
          },
        }
        lines.push(
          { "type": "item.completed".to_json(), "item": translated.to_json() }
          .to_json()
          .stringify(indent=0),
        )
      }
      Some("mcpToolCall") => {
        let status = match @types.json_field_string(fields, "status") {
          Some(value) => value
          None => "invalid"
        }
        let translated : Map[String, Json] = {
          "id": match @types.json_field_string(fields, "id") {
            Some(value) => value.to_json()
            None => "".to_json()
          },
          "type": "mcp_tool_call".to_json(),
          "server": match @types.json_field_string(fields, "server") {
            Some(value) => value.to_json()
            None => "".to_json()
          },
          "tool": match @types.json_field_string(fields, "tool") {
            Some(value) => value.to_json()
            None => "".to_json()
          },
          "status": "in_progress".to_json(),
        }
        lines.push(
          { "type": "item.started".to_json(), "item": translated.to_json() }
          .to_json()
          .stringify(indent=0),
        )
        translated["status"] = status.to_json()
        lines.push(
          { "type": "item.completed".to_json(), "item": translated.to_json() }
          .to_json()
          .stringify(indent=0),
        )
      }
      Some(other) => {
        let translated : Map[String, Json] = {
          "id": "native-item".to_json(),
          "type": other.to_json(),
        }
        lines.push(
          { "type": "item.completed".to_json(), "item": translated.to_json() }
          .to_json()
          .stringify(indent=0),
        )
      }
      None => return Err(native_codex_driver_error("turn item type is absent"))
    }
  }
  match @types.json_field_string(turn, "status") {
    Some("completed") =>
      lines.push(
        { "type": "turn.completed".to_json(), "turn_id": turn_id.to_json() }
        .to_json()
        .stringify(indent=0),
      )
    _ => return Err(native_codex_driver_error("turn is not complete"))
  }
  Ok(lines.join("\n") + "\n")
}

///|
pub async fn run_native_codex_take(
  config : NativeCodexDriverConfig,
  session : @control.HarnessSession,
  role : @harness.CodexTakeRole,
  instruction : String,
  now : () -> Int64,
  cancellation_requested? : () -> Bool = fn() { false },
  after_server_started? : () -> Unit = fn() { () },
  after_initialized_notification_sent? : () -> Unit = fn() { () },
  after_turn_started? : () -> Unit = fn() { () },
  after_terminal_recorded? : () -> Unit = fn() { () },
) -> Result[@harness.CodexDriverResult, @types.ChoirError] {
  match validate_native_codex_config(config) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match validate_native_provider_host_boundary() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let instruction_bytes = @utf8.encode(instruction)
  if instruction_bytes.length() == 0 ||
    instruction_bytes.length() > 16384 ||
    instruction.contains("\u{00}") {
    return Err(
      @types.ChoirError::validation_error(
        "Codex Take instruction is empty or exceeds the safe bound",
      ),
    )
  }
  if session.lifecycle !=
    @control.HarnessSessionLifecycle::HarnessSessionAwaitingEvents {
    return Err(
      @types.ChoirError::validation_error(
        "native Codex driver requires an authorized started session",
      ),
    )
  }
  let expected_surface_digest = @harness.codex_effective_surface_manifest_digest(
    config.allowed_tools,
    config.mcp_server_name,
  )
  if session.effective_surface_manifest_digest != expected_surface_digest {
    return Err(
      @types.ChoirError::policy_blocked(
        "native Codex driver surface manifest changed before dispatch",
      ),
    )
  }
  match codex_conflicting_credential_environment() {
    Some(name) =>
      return Err(
        @types.ChoirError::policy_blocked(
          "conflicting Codex credential environment is present: " + name,
        ),
      )
    None => ()
  }
  let provider_home = match @sys.getenv("HOME") {
    Some(value) if value.has_prefix("/") => value
    _ => return Err(native_codex_driver_error("provider home is unavailable"))
  }
  let codex = match resolve_executable_in_path("codex") {
    Some(value) => value
    None => return Err(native_codex_driver_error("executable is unavailable"))
  }
  let codex_native = match verify_native_codex_binary(codex) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let loaded = match load_native_codex_manifest(config, session, role) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let allow_provider_state = match loaded {
    Some(_) => true
    None => false
  }
  match
    prepare_native_codex_app_server_home(
      config, provider_home, allow_provider_state,
    ) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match
    verify_native_codex_subscription(codex, provider_home, config.sterile_root) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let prompt = native_codex_role_prompt(role) +
    "\n\nInstruction:\n" +
    instruction
  let output_schema = @json.parse(native_codex_output_schema(role)) catch {
    _ => return Err(native_codex_driver_error("output schema is invalid"))
  }
  let mut manifest = match loaded {
    Some(value) => value
    None => {
      let value : NativeCodexTakeManifest = {
        version: 4,
        session_id: session.id,
        take_id: session.take_id,
        role,
        surface_digest: session.effective_surface_manifest_digest,
        server_pid: 0,
        server_generation: 0,
        server_initialized: false,
        initialization_notification_may_have_been_sent: false,
        initialization_attestation_digest: None,
        thread_id: None,
        turn_id: None,
        client_user_message_id: "choir-" + session.id.0 + "-user-1",
        read_ordinal: 0,
        state: CodexServerStarting,
        started_at: now(),
        finished_at: None,
        terminal_trace: None,
      }
      match store_native_codex_manifest(config, value) {
        Ok(_) => value
        Err(error) => return Err(error)
      }
    }
  }
  match manifest.state {
    CodexTurnInterrupted => {
      stop_native_codex_owned_server(config, manifest.server_pid)
      return Err(
        @types.ChoirError::canceled("Codex Take interrupted at the Goal cutoff"),
      )
    }
    CodexTurnCompleted =>
      stop_native_codex_owned_server(config, manifest.server_pid)
    _ => ()
  }
  let mut terminal_trace = match manifest.terminal_trace {
    Some(value) => value
    None => ""
  }
  if terminal_trace == "" {
    manifest = match
      ensure_native_codex_app_server(
        config, codex_native, manifest, after_server_started, after_initialized_notification_sent,
      ) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    if manifest.thread_id is None {
      let params : Map[String, Json] = {
        "cwd": native_codex_app_server_working_directory(config).to_json(),
        "ephemeral": false.to_json(),
        "approvalPolicy": "never".to_json(),
        "sandbox": "read-only".to_json(),
        "personality": "none".to_json(),
        "baseInstructions": native_codex_role_prompt(role).to_json(),
      }
      let result = match
        request_native_codex_app_server(
          config,
          "thread-start",
          "thread/start",
          params.to_json(),
          server_pid=manifest.server_pid,
        ) {
        Ok(value) => value
        Err(error) => {
          stop_native_codex_owned_server(config, manifest.server_pid)
          return Err(error)
        }
      }
      let thread = match native_codex_result_object(result, "thread") {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let thread_id = match @types.json_field_string(thread, "id") {
        Some(value) => value
        None =>
          return Err(native_codex_driver_error("thread identity is absent"))
      }
      manifest = {
        ..manifest,
        thread_id: Some(thread_id),
        state: CodexThreadReady,
      }
      match store_native_codex_manifest(config, manifest) {
        Ok(_) => ()
        Err(error) => return Err(error)
      }
    }
    let read = match read_native_codex_thread(config, manifest) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    manifest = read.0
    let mut turn = find_native_codex_turn(read.1, manifest)
    if turn is None {
      let thread_id = match manifest.thread_id {
        Some(value) => value
        None =>
          return Err(native_codex_driver_error("thread identity is absent"))
      }
      let input : Array[Json] = [
        { "type": "text".to_json(), "text": prompt.to_json() }.to_json(),
      ]
      let params : Map[String, Json] = {
        "threadId": thread_id.to_json(),
        "input": input.to_json(),
        "clientUserMessageId": manifest.client_user_message_id.to_json(),
        "outputSchema": output_schema,
      }
      let result = match
        request_native_codex_app_server(
          config,
          "turn-start",
          "turn/start",
          params.to_json(),
          server_pid=manifest.server_pid,
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let started_turn = match native_codex_result_object(result, "turn") {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let turn_id = match @types.json_field_string(started_turn, "id") {
        Some(value) => value
        None => return Err(native_codex_driver_error("turn identity is absent"))
      }
      manifest = { ..manifest, turn_id: Some(turn_id), state: CodexTurnRunning }
      match store_native_codex_manifest(config, manifest) {
        Ok(_) => after_turn_started()
        Err(error) => return Err(error)
      }
      turn = Some(started_turn)
    } else {
      let existing_turn = match turn {
        Some(value) => value
        None =>
          return Err(native_codex_driver_error("persisted turn is absent"))
      }
      let turn_id = match @types.json_field_string(existing_turn, "id") {
        Some(value) => value
        None => return Err(native_codex_driver_error("turn identity is absent"))
      }
      if manifest.turn_id != Some(turn_id) || manifest.state == CodexThreadReady {
        manifest = {
          ..manifest,
          turn_id: Some(turn_id),
          state: CodexTurnRunning,
        }
        match store_native_codex_manifest(config, manifest) {
          Ok(_) => ()
          Err(error) => return Err(error)
        }
      }
    }
    let mut elapsed_ms = 0
    let mut last_turn_read_ms = 0
    let mut interrupt_sent = false
    while terminal_trace == "" {
      manifest = match
        ensure_native_codex_app_server(
          config, codex_native, manifest, after_server_started, after_initialized_notification_sent,
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if cancellation_requested() && !interrupt_sent {
        let thread_id = match manifest.thread_id {
          Some(value) => value
          None =>
            return Err(native_codex_driver_error("thread identity is absent"))
        }
        let turn_id = match manifest.turn_id {
          Some(value) => value
          None =>
            return Err(native_codex_driver_error("turn identity is absent"))
        }
        let params : Map[String, Json] = {
          "threadId": thread_id.to_json(),
          "turnId": turn_id.to_json(),
        }
        match
          request_native_codex_app_server(
            config,
            "turn-interrupt",
            "turn/interrupt",
            params.to_json(),
            server_pid=manifest.server_pid,
          ) {
          Ok(_) => interrupt_sent = true
          Err(error) => return Err(error)
        }
      }
      let running_per_events = match manifest.turn_id {
        Some(turn_id) =>
          native_codex_observed_turn_status(config, turn_id) ==
          Some("inProgress")
        None => false
      }
      let read_is_due = elapsed_ms - last_turn_read_ms >=
        native_codex_turn_read_interval_ms
      if running_per_events && !read_is_due {
        if elapsed_ms >= config.timeout_ms {
          return Err(@types.ChoirError::timeout("Codex Take"))
        }
        @async.sleep(200)
        elapsed_ms = elapsed_ms + 200
        continue
      }
      last_turn_read_ms = elapsed_ms
      let read = match read_native_codex_thread(config, manifest) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      manifest = read.0
      let current = match find_native_codex_turn(read.1, manifest) {
        Some(value) => value
        None =>
          return Err(native_codex_driver_error("persisted turn is absent"))
      }
      match @types.json_field_string(current, "status") {
        Some("completed") => {
          let thread_id = match manifest.thread_id {
            Some(value) => value
            None =>
              return Err(native_codex_driver_error("thread identity is absent"))
          }
          terminal_trace = match native_codex_turn_trace(thread_id, current) {
            Ok(value) => value
            Err(error) => return Err(error)
          }
          let finished_at = now()
          manifest = {
            ..manifest,
            state: CodexTurnCompleted,
            finished_at: Some(finished_at),
            terminal_trace: Some(terminal_trace),
          }
          match store_native_codex_manifest(config, manifest) {
            Ok(_) => {
              after_terminal_recorded()
              stop_native_codex_owned_server(config, manifest.server_pid)
            }
            Err(error) => return Err(error)
          }
        }
        Some("interrupted") => {
          manifest = {
            ..manifest,
            state: CodexTurnInterrupted,
            finished_at: Some(now()),
          }
          match store_native_codex_manifest(config, manifest) {
            Ok(_) => {
              after_terminal_recorded()
              stop_native_codex_owned_server(config, manifest.server_pid)
            }
            Err(error) => return Err(error)
          }
          return Err(
            @types.ChoirError::canceled(
              "Codex Take interrupted at the Goal cutoff",
            ),
          )
        }
        Some("failed") => {
          stop_native_codex_owned_server(config, manifest.server_pid)
          // A turn fails for reasons the allowance has nothing to do with, so
          // only a surface that said it is spent reports as provider loss —
          // the rest stays an ordinary driver failure.
          let path = native_codex_log_path(config)
          let allowance = if @sys.path_exists(path) {
            native_codex_allowance_from_events(@sys.read_file(path))
          } else {
            None
          }
          return match allowance {
            Some(_) =>
              Err(
                @types.ChoirError::provider_process_lost(
                  "Codex turn failed against a spent allowance",
                  allowance~,
                ),
              )
            None => Err(native_codex_driver_error("provider turn failed"))
          }
        }
        Some("inProgress") => ()
        _ =>
          return Err(
            native_codex_driver_error("provider turn status is invalid"),
          )
      }
      if terminal_trace == "" {
        if elapsed_ms >= config.timeout_ms {
          return Err(@types.ChoirError::timeout("Codex Take"))
        }
        @async.sleep(200)
        elapsed_ms = elapsed_ms + 200
      }
    }
  }
  let finished_at = match manifest.finished_at {
    Some(value) => value
    None => return Err(native_codex_driver_error("terminal time is absent"))
  }
  let provider_cursor = match (manifest.thread_id, manifest.turn_id) {
    (Some(thread_id), Some(turn_id)) => thread_id + ":" + turn_id
    _ =>
      return Err(
        native_codex_driver_error("terminal provider cursor is absent"),
      )
  }
  // What this turn spent against the user's paid subscription allowance,
  // taken from the app-server's own notifications rather than estimated.
  let reported_usage = match manifest.turn_id {
    Some(turn_id) => {
      let path = native_codex_log_path(config)
      if @sys.path_exists(path) {
        native_codex_turn_usage_from_events(@sys.read_file(path), turn_id)
      } else {
        None
      }
    }
    None => None
  }
  @harness.evaluate_codex_driver_capture({
    session: {
      ..session,
      provider_cursor: Some(provider_cursor),
      usage: match reported_usage {
        Some(usage) if @control.validate_take_usage(usage) => Some(usage)
        _ => session.usage
      },
    },
    role,
    allowed_tools: config.allowed_tools,
    expected_mcp_server: config.mcp_server_name,
    capture: {
      exit_code: 0,
      output: terminal_trace,
      started_at: manifest.started_at,
      finished_at,
    },
  })
}

///|
pub async fn run_native_codex_conductor_turn(
  config : NativeCodexConductorConfig,
  prompt : String,
  thread_id? : String? = None,
) -> Result[@harness.CodexConductorTurn, @types.ChoirError] {
  if !config.sterile_root.has_prefix("/") ||
    !config.mcp_executable.has_prefix("/") ||
    !valid_native_codex_token(config.mcp_server_name) ||
    config.allowed_tools.length() == 0 ||
    config.developer_instructions == "" ||
    config.timeout_ms < 1000 ||
    config.timeout_ms > 3600000 ||
    config.environment.conductor_token == "" ||
    config.environment.workspace == "" ||
    config.environment.listen_uds == "" {
    return Err(
      @types.ChoirError::validation_error(
        "native Codex Conductor configuration is invalid",
      ),
    )
  }
  for index, tool in config.allowed_tools {
    if !valid_native_codex_token(tool) ||
      config.allowed_tools[:index].contains(tool) {
      return Err(
        @types.ChoirError::validation_error(
          "native Codex Conductor tool declaration is invalid",
        ),
      )
    }
  }
  match validate_native_provider_host_boundary() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let prompt_bytes = @utf8.encode(prompt)
  if prompt_bytes.length() == 0 ||
    prompt_bytes.length() > 65536 ||
    prompt.contains("\u{00}") {
    return Err(
      @types.ChoirError::validation_error(
        "Codex Conductor prompt is empty or exceeds the safe bound",
      ),
    )
  }
  let provider_home = match @sys.getenv("HOME") {
    Some(value) if value.has_prefix("/") => value
    _ => return Err(native_codex_driver_error("provider home is unavailable"))
  }
  match codex_conflicting_credential_environment() {
    Some(name) =>
      return Err(
        @types.ChoirError::policy_blocked(
          "conflicting Codex credential environment is present: " + name,
        ),
      )
    None => ()
  }
  let codex = match resolve_executable_in_path("codex") {
    Some(value) => value
    None => return Err(native_codex_driver_error("executable is unavailable"))
  }
  let codex_native = match verify_native_codex_binary(codex) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match prepare_native_codex_conductor_home(config, provider_home) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match
    verify_native_codex_subscription(codex, provider_home, config.sterile_root) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let (stdin_read, stdin_write) = @process.write_to_process() catch {
    _ => return Err(native_codex_driver_error("Conductor stdin pipe failed"))
  }
  ignore(
    stdin_write.write(prompt) catch {
      _ => {
        stdin_write.close()
        return Err(native_codex_driver_error("Conductor prompt write failed"))
      }
    },
  )
  stdin_write.close()
  let args = native_codex_conductor_args(config, thread_id)
  let bounded_args = native_provider_host_boundary_args(
    config.sterile_root,
    config.sterile_root,
    None,
    codex_native,
    args,
  )
  abort_if_hermetic_test_exec(
    command_to_shell_string({
      program: "/usr/bin/bwrap",
      args: bounded_args,
      workdir: Some(config.sterile_root),
    }),
  )
  let collected = match
    collect_interruptible_process(
      "/usr/bin/bwrap",
      bounded_args,
      native_codex_conductor_environment(provider_home, config),
      stdin_read,
      config.sterile_root,
      config.timeout_ms,
      fn() { false },
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let (exit_code, output) = match collected {
    NativeInterruptibleProcessOutcome::NativeProcessCompleted(code, output) =>
      (code, output)
    NativeInterruptibleProcessOutcome::NativeProcessInterrupted(_) =>
      return Err(@types.ChoirError::canceled("Codex Conductor interrupted"))
    NativeInterruptibleProcessOutcome::NativeProcessTimedOut(_) =>
      return Err(@types.ChoirError::timeout("Codex Conductor turn"))
  }
  @harness.evaluate_codex_conductor_capture(
    { exit_code, output },
    thread_id,
    config.mcp_server_name,
    config.allowed_tools,
  )
}

///|
test "native Codex app-server argv removes native execution surfaces" {
  let args = native_codex_app_server_args({
    sterile_root: "/tmp/choir-codex-driver-test",
    mcp_executable: "/usr/bin/node",
    mcp_arguments: ["/opt/choir/sandbox-mcp.mjs"],
    execution_token: "",
    boxlite_owner_socket_root: None,
    mcp_server_name: "choir_sandbox",
    allowed_tools: ["read_file", "run"],
    timeout_ms: 60000,
    connect_trace_path: None,
  })
  assert_eq(args[:3], ["app-server", "--listen", "stdio://"])
  assert_true(args.contains("shell_tool"))
  assert_true(args.contains("multi_agent"))
  assert_true(args.contains("mcp_servers.choir_sandbox.required=true"))
  assert_true(
    args.contains(
      "mcp_servers.choir_sandbox.enabled_tools=[\"read_file\",\"run\"]",
    ),
  )
  assert_false(args.contains("--dangerously-bypass-approvals-and-sandbox"))
}

///|
test "native Codex app-server argv names the capability without carrying it" {
  let token = "f".repeat(64)
  let config : NativeCodexDriverConfig = {
    sterile_root: "/tmp/choir-codex-driver-test",
    mcp_executable: "/usr/bin/node",
    mcp_arguments: ["/opt/choir/sandbox-mcp.mjs"],
    execution_token: token,
    boxlite_owner_socket_root: None,
    mcp_server_name: "choir_sandbox",
    allowed_tools: ["read_file", "run"],
    timeout_ms: 60000,
    connect_trace_path: None,
  }
  let args = native_codex_app_server_args(config)
  assert_true(
    args.contains(
      "mcp_servers.choir_sandbox.env_vars=[\"CHOIR_BOXLITE_EXECUTION_TOKEN\"]",
    ),
  )
  for argument in args {
    assert_false(argument.contains(token))
  }
  let environment = native_codex_app_server_environment(
    config.sterile_root,
    token,
  )
  assert_eq(environment["CHOIR_BOXLITE_EXECUTION_TOKEN"], token)
  let without_capability = native_codex_app_server_args({
    ..config,
    execution_token: "",
  })
  assert_false(
    without_capability.contains(
      "mcp_servers.choir_sandbox.env_vars=[\"CHOIR_BOXLITE_EXECUTION_TOKEN\"]",
    ),
  )
}

///|
test "native Codex connect observation is confined to the sterile root" {
  let config : NativeCodexDriverConfig = {
    sterile_root: "/tmp/choir-codex-driver-test",
    mcp_executable: "/usr/bin/node",
    mcp_arguments: ["/opt/choir/sandbox-mcp.mjs"],
    execution_token: "",
    boxlite_owner_socket_root: None,
    mcp_server_name: "choir_sandbox",
    allowed_tools: ["read_file"],
    timeout_ms: 60000,
    connect_trace_path: Some("/tmp/outside.trace"),
  }
  assert_true(validate_native_codex_config(config) is Err(_))
  assert_true(
    validate_native_codex_config({
      ..config,
      connect_trace_path: Some("/tmp/choir-codex-driver-test/connect.trace"),
    })
    is Ok(_),
  )
}

///|
test "native Codex owner socket binding is exact and paired with MCP argv" {
  let root = "/tmp/choir-boxlite-test/codex/session-test"
  let source = "/tmp/choir-boxlite-test/owner-socket"
  let target = native_provider_owner_socket_path()
  let config : NativeCodexDriverConfig = {
    sterile_root: root,
    mcp_executable: "/usr/bin/node",
    mcp_arguments: ["/opt/choir/sandbox-mcp.mjs", "--owner-socket", target],
    execution_token: "",
    boxlite_owner_socket_root: Some(source),
    mcp_server_name: "choir_sandbox",
    allowed_tools: ["read_file"],
    timeout_ms: 60000,
    connect_trace_path: None,
  }
  assert_true(validate_native_codex_config(config) is Ok(_))
  assert_true(
    validate_native_codex_config({
      ..config,
      mcp_arguments: [
        "/opt/choir/sandbox-mcp.mjs",
        "--owner-socket",
        source + "/owner.sock",
      ],
    })
    is Err(_),
  )
  assert_true(
    validate_native_codex_config({ ..config, boxlite_owner_socket_root: None })
    is Err(_),
  )
  assert_true(
    validate_native_codex_config({
      ..config,
      boxlite_owner_socket_root: Some("/tmp/other/owner-socket"),
    })
    is Err(_),
  )
  let args = native_provider_host_boundary_args(
    root,
    root,
    Some(source),
    "/usr/bin/true",
    [],
    provider_home=None,
    mask_entry_exists=fn(_) { false },
  )
  let source_index = args.search(source).unwrap()
  assert_eq(args[source_index - 1], "--ro-bind")
  assert_eq(args[source_index + 1], native_provider_owner_socket_root())
  assert_false(args.contains("/tmp/choir-boxlite-test"))
}

///|
test "native Codex initialization attests the sterile client identity" {
  let config : NativeCodexDriverConfig = {
    sterile_root: "/tmp/choir-codex-driver-test",
    mcp_executable: "/usr/bin/node",
    mcp_arguments: [],
    execution_token: "",
    boxlite_owner_socket_root: None,
    mcp_server_name: "choir_sandbox",
    allowed_tools: ["probe"],
    timeout_ms: 60000,
    connect_trace_path: None,
  }
  let response : Map[String, Json] = {
    "userAgent": ("choir/" +
    @harness.expected_surface_version(@harness.ProviderSurface::CodexCli) +
    " (Linux; x86_64) terminal (choir; 0.1.0)").to_json(),
    "codexHome": "/tmp/choir-codex-driver-test/codex-home".to_json(),
    "platformFamily": "unix".to_json(),
    "platformOs": "linux".to_json(),
  }
  assert_true(
    attest_native_codex_initialization(config, response.to_json()) is Ok(_),
  )
  response["codexHome"] = "/home/user/.codex".to_json()
  assert_true(
    attest_native_codex_initialization(config, response.to_json()) is Err(_),
  )
}

///|
test "provider host boundary masks host temporary files" {
  let root = "/tmp/choir-provider-host-boundary-test"
  let args = native_provider_host_boundary_args(
    root,
    root,
    None,
    "/usr/bin/true",
    [],
    provider_home=None,
    mask_entry_exists=fn(_) { false },
  )
  assert_eq(args[0], "--die-with-parent")
  assert_false(args.contains("--dev-bind"))
  assert_true(args.contains("--dev"))
  assert_true(args.contains("--proc"))
  assert_true(args.contains("--tmpfs"))
  let tmpfs = args.search("--tmpfs").unwrap()
  assert_eq(args[tmpfs + 1], "/tmp")
  assert_true(args.contains("--bind"))
  assert_eq(args[args.length() - 2], "--")
  assert_eq(args[args.length() - 1], "/usr/bin/true")
}

///|
test "Codex recovery adopts the turn with the durable client message id" {
  let manifest : NativeCodexTakeManifest = {
    version: 4,
    session_id: @control.HarnessSessionId("session-recovery"),
    take_id: @control.TakeId("take-recovery"),
    role: @harness.CodexTakeRole::CodexImplementationTake,
    surface_digest: @control.Digest("digest-recovery"),
    server_pid: 1,
    server_generation: 1,
    server_initialized: true,
    initialization_notification_may_have_been_sent: true,
    initialization_attestation_digest: Some(
      @control.Digest("initialization-recovery"),
    ),
    thread_id: Some("thread-recovery"),
    turn_id: None,
    client_user_message_id: "client-message-recovery",
    read_ordinal: 1,
    state: CodexThreadReady,
    started_at: 10L,
    finished_at: None,
    terminal_trace: None,
  }
  let thread = @json.parse(
    (
      #|{"id":"thread-recovery","turns":[{"id":"turn-recovery","status":"inProgress","items":[{"id":"user-1","type":"userMessage","clientId":"client-message-recovery","content":[]}]}]}
    ),
  ) catch {
    _ => fail("fixture JSON is invalid")
  }
  let turn = find_native_codex_turn(thread, manifest)
  assert_true(turn is Some(_))
  guard turn is Some(fields) else { fail("recovery turn is absent") }
  assert_eq(@types.json_field_string(fields, "id"), Some("turn-recovery"))
}

///|
test "Codex turn status comes from the notification stream" {
  let spool =
    #|{"method":"thread/started","params":{"threadId":"thread-1"}}
    #|{"method":"turn/started","params":{"threadId":"thread-1","turn":{"id":"turn-1","items":[],"itemsView":"notLoaded","status":"inProgress"}}}
    #|{"id":"thread-read:1","result":{"thread":{"id":"thread-1","turns":[]}}}
    #|{"method":"item/completed","params":{"threadId":"thread-1","item":{"id":"item-1"}}}
    #|{"method":"turn/started","params":{"threadId":"thread-1","turn":{"id":"turn-other","status":"inProgress"}}}
    #|{"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-1","items":[],"itemsView":"notLoaded","status":"completed"}}}
    #|
  // The last status published for the turn wins, and a sibling turn's
  // notifications never leak into it.
  assert_eq(
    native_codex_turn_status_from_events(spool, "turn-1"),
    Some("completed"),
  )
  assert_eq(
    native_codex_turn_status_from_events(spool, "turn-other"),
    Some("inProgress"),
  )
  // An unobserved turn keeps the poll on the authoritative thread read.
  assert_eq(native_codex_turn_status_from_events(spool, "turn-absent"), None)
}

///|
test "Codex turn status tolerates a truncated or interleaved spool" {
  let spool =
    #|not json at all
    #|{"method":"turn/started","params":{"threadId":"thread-1","turn":{"id":"turn-1","status":"inProgress"}}}
    #|{"method":"turn/completed","params":{}}
    #|{"method":"turn/completed","params":{"turn":{"id":"turn-1"}}}
    #|{"id":"thread-read:2","result":{"thread":{"id":"thread-1"}}}
    #|{"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"tur
  // Malformed, partial, and field-less records are skipped rather than
  // fabricating a terminal status, so a torn final line keeps the turn running.
  assert_eq(
    native_codex_turn_status_from_events(spool, "turn-1"),
    Some("inProgress"),
  )
}

///|
test "Codex terminal history becomes one balanced provider trace" {
  let turn = @json.parse(
    (
      #|{"id":"turn-terminal","status":"completed","items":[{"id":"user-1","type":"userMessage","clientId":"client-message","content":[]},{"id":"tool-1","type":"mcpToolCall","server":"choir_sandbox","tool":"read_file","status":"completed","arguments":{}},{"id":"message-1","type":"agentMessage","text":"{\"outcome\":\"completed\"}"}]}
    ),
  ) catch {
    _ => fail("fixture JSON is invalid")
  }
  guard turn is Object(fields) else { fail("fixture turn is invalid") }
  let trace = native_codex_turn_trace("thread-terminal", fields).unwrap()
  assert_true(trace.contains("\"thread_id\":\"thread-terminal\""))
  assert_true(trace.contains("\"type\":\"mcp_tool_call\""))
  assert_true(trace.contains("\"type\":\"turn.completed\""))
}

///|
test "native Codex Take schemas constrain every terminal role" {
  let implementation = native_codex_output_schema(
    @harness.CodexTakeRole::CodexImplementationTake,
  )
  let audit = native_codex_output_schema(@harness.CodexTakeRole::CodexAuditTake)
  assert_true(@json.parse(implementation) is Object(_))
  assert_true(implementation.contains("\"completed\""))
  assert_true(audit.contains("\"total_findings\""))
  assert_true(audit.contains("\"blocking_findings\""))
  assert_true(audit.contains("\"repair_findings\""))
  assert_true(audit.contains("\"migration_findings\""))
  assert_true(
    audit.contains(
      "\"required\":[\"outcome\",\"total_findings\",\"blocking_findings\",\"repair_findings\",\"migration_findings\"]",
    ),
  )
  assert_true(audit.contains("\"additionalProperties\":false"))
  for
    role in [
      @harness.CodexTakeRole::CodexImplementationTake,
      @harness.CodexTakeRole::CodexAuditTake,
    ] {
    assert_true(
      native_codex_role_prompt(role).contains(
        "must call at least one available Choir MCP tool",
      ),
    )
  }
  assert_true(
    native_codex_role_prompt(@harness.CodexTakeRole::CodexAuditTake).contains(
      "Call read_file for every path the Part task permits to change",
    ),
  )
}

///|
test "native Codex Conductor argv is resumable and restricted" {
  let config : NativeCodexConductorConfig = {
    sterile_root: "/tmp/choir-codex-conductor-test",
    mcp_executable: "/opt/choir/bin/choir",
    mcp_arguments: [
      "mcp-stdio", "--name", "root", "--raw-stdio", "--inherit-parent-environment",
    ],
    mcp_server_name: "choir",
    allowed_tools: ["goal_status"],
    developer_instructions: "Use Choir.",
    timeout_ms: 60000,
    environment: {
      conductor_token: "token",
      statusline_cache_key: "conductor-42",
      workspace: "/tmp/project",
      listen_uds: "/tmp/project/.choir/run/server.sock",
    },
  }
  let initial = native_codex_conductor_args(config, None)
  assert_eq(initial[:2], ["exec", "--json"])
  assert_true(initial.contains("--ignore-user-config"))
  assert_true(initial.contains("--ignore-rules"))
  assert_true(initial.contains("shell_tool"))
  assert_true(initial.contains("unified_exec"))
  assert_true(initial.contains("mcp_servers.choir.required=true"))
  assert_true(
    initial.contains("mcp_servers.choir.enabled_tools=[\"goal_status\"]"),
  )
  let resumed = native_codex_conductor_args(
    config,
    Some("019f80a5-df42-7411-9065-e0866506338c"),
  )
  assert_eq(resumed[:3], ["exec", "resume", "--json"])
  assert_eq(
    resumed[resumed.length() - 2],
    "019f80a5-df42-7411-9065-e0866506338c",
  )
  assert_eq(resumed[resumed.length() - 1], "-")
}

///|
/// Responses are found by scanning only what the spool has grown by, so this
/// exercises the offset threading directly: a response written after the first
/// poll must still be found, and a line the app-server is midway through
/// writing must not be consumed.
test "a spooled response is found by scanning only appended bytes" {
  let root = "/tmp/choir-codex-spool-test"
  ignore(@sys.create_dir_all(root))
  let config : NativeCodexDriverConfig = {
    sterile_root: root,
    mcp_executable: "/usr/bin/node",
    mcp_arguments: [],
    execution_token: "",
    boxlite_owner_socket_root: None,
    mcp_server_name: "choir_sandbox",
    allowed_tools: ["read_file"],
    timeout_ms: 60000,
    connect_trace_path: None,
  }
  let path = native_codex_log_path(config)
  let unrelated =
    #|{"id":"other","result":{"ok":false}}
  ignore(@sys.write_file_sync(path, unrelated + "\n"))
  // Not here yet, and the scan reports how far it read.
  let first = native_codex_response_from_log(config, "wanted").unwrap()
  assert_eq(first.0, None)
  assert_true(first.1 > 0)
  // A half-written line must not advance the offset past itself, or the
  // response it belongs to is lost when the writer finishes it.
  let partial = unrelated + "\n" + "{\"id\":\"wanted\",\"resu"
  ignore(@sys.write_file_sync(path, partial))
  let second = native_codex_response_from_log(
    config,
    "wanted",
    from_offset=first.1,
  ).unwrap()
  assert_eq(second.0, None)
  assert_eq(second.1, first.1)
  // The writer finishes the line and the response is found from that offset.
  let complete = unrelated +
    "\n" +
    (
      #|{"id":"wanted","result":{"threadId":"t-1"}}
    ) +
    "\n"
  ignore(@sys.write_file_sync(path, complete))
  let third = native_codex_response_from_log(
    config,
    "wanted",
    from_offset=second.1,
  ).unwrap()
  guard third.0 is Some(Object(result)) else {
    fail("the completed response was not found")
  }
  assert_eq(@types.json_field_string(result, "threadId"), Some("t-1"))
  ignore(@sys.delete_file_sync(path))
}

///|
/// An app-server rejection is carried as a typed JSON-RPC error so the caller
/// deciding whether to recover has the code, not only prose.
test "an app-server rejection keeps its JSON-RPC code" {
  let root = "/tmp/choir-codex-rpc-error-test"
  ignore(@sys.create_dir_all(root))
  let config : NativeCodexDriverConfig = {
    sterile_root: root,
    mcp_executable: "/usr/bin/node",
    mcp_arguments: [],
    execution_token: "",
    boxlite_owner_socket_root: None,
    mcp_server_name: "choir_sandbox",
    allowed_tools: ["read_file"],
    timeout_ms: 60000,
    connect_trace_path: None,
  }
  let path = native_codex_log_path(config)
  ignore(
    @sys.write_file_sync(
      path,
      (
        #|{"id":"read-1","error":{"code":-32600,"message":"thread not loaded: t-9"}}
      ) +
      "\n",
    ),
  )
  let failure = match native_codex_response_from_log(config, "read-1") {
    Ok(_) => fail("a rejection was read as a result")
    Err(error) => error
  }
  assert_eq(
    failure.provider_rpc_rejection(),
    Some((-32600, "thread not loaded: t-9")),
  )
  // And it classifies as a thread that simply has nothing written yet, which
  // is the branch that had silently stopped firing.
  assert_true(native_codex_thread_is_unmaterialized(failure))
  ignore(@sys.delete_file_sync(path))
}
