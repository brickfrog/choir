///|
pub(all) struct NativeClaudeDriverConfig {
  sterile_root : String
  mcp_executable : String
  mcp_arguments : Array[String]
  boxlite_owner_socket_root : String?
  mcp_server_name : String
  allowed_tools : Array[String]
  timeout_ms : Int
} derive(Debug, Eq)

///|
fn native_claude_driver_error(message : String) -> @types.ChoirError {
  @types.ChoirError::transport_error("Claude driver: " + message)
}

///|
fn valid_native_claude_token(value : String) -> Bool {
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
fn validate_native_claude_config(
  config : NativeClaudeDriverConfig,
) -> Result[Unit, @types.ChoirError] {
  if !config.sterile_root.has_prefix("/") ||
    !config.mcp_executable.has_prefix("/") ||
    !valid_native_claude_token(config.mcp_server_name) ||
    config.allowed_tools.length() == 0 ||
    config.timeout_ms < 1000 ||
    config.timeout_ms > 3600000 {
    return Err(
      @types.ChoirError::validation_error(
        "native Claude driver configuration is invalid",
      ),
    )
  }
  for index, tool in config.allowed_tools {
    if !tool.has_prefix("mcp__" + config.mcp_server_name + "__") ||
      config.allowed_tools[:index].contains(tool) {
      return Err(
        @types.ChoirError::validation_error(
          "native Claude driver tool declaration is invalid",
        ),
      )
    }
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
            "native Claude owner socket target is invalid",
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
          "native Claude owner socket binding is invalid",
        ),
      )
    None if owner_socket_argument_count != 0 =>
      return Err(
        @types.ChoirError::validation_error(
          "native Claude owner socket source is absent",
        ),
      )
    _ => ()
  }
  Ok(())
}

///|
fn native_claude_system_prompt(role : @harness.ClaudeTakeRole) -> String {
  let common = "Use only the declared MCP tools. Never request native host file, shell, network, plugin, hook, skill, or subagent access. "
  match role {
    @harness.ClaudeTakeRole::ClaudeImplementationTake =>
      common +
      "Complete the instruction in the sandbox. End with exactly {\"outcome\":\"completed\"}."
    @harness.ClaudeTakeRole::ClaudeVerificationTake =>
      common +
      "Verify the supplied candidate with the declared verification tool. End with exactly {\"outcome\":\"passed\"} or {\"outcome\":\"failed\"}."
    @harness.ClaudeTakeRole::ClaudeAuditTake =>
      common +
      "Independently audit the supplied candidate. End with exactly {\"outcome\":\"passed\",\"total_findings\":0,\"blocking_findings\":0} when clean, otherwise {\"outcome\":\"findings\",\"total_findings\":N,\"blocking_findings\":N}."
  }
}

///|
fn native_claude_output_schema(role : @harness.ClaudeTakeRole) -> String {
  let outcome : Json = match role {
    @harness.ClaudeTakeRole::ClaudeImplementationTake =>
      { "const": "completed".to_json() }.to_json()
    @harness.ClaudeTakeRole::ClaudeVerificationTake =>
      { "enum": ["passed", "failed"].to_json() }.to_json()
    @harness.ClaudeTakeRole::ClaudeAuditTake =>
      { "enum": ["passed", "findings"].to_json() }.to_json()
  }
  let properties : Map[String, Json] = { "outcome": outcome }
  let required : Array[String] = ["outcome"]
  match role {
    @harness.ClaudeTakeRole::ClaudeAuditTake => {
      properties["total_findings"] = {
        "type": "integer".to_json(),
        "minimum": (0).to_json(),
      }.to_json()
      properties["blocking_findings"] = {
        "type": "integer".to_json(),
        "minimum": (0).to_json(),
      }.to_json()
      required.push("total_findings")
      required.push("blocking_findings")
    }
    _ => ()
  }
  let schema : Map[String, Json] = {
    "type": "object".to_json(),
    "properties": properties.to_json(),
    "required": required.to_json(),
    "additionalProperties": false.to_json(),
  }
  schema.to_json().stringify(indent=0)
}

///|
fn native_claude_driver_args(
  config : NativeClaudeDriverConfig,
  role : @harness.ClaudeTakeRole,
) -> Array[String] {
  let server : Map[String, Json] = {
    "command": config.mcp_executable.to_json(),
    "args": config.mcp_arguments.to_json(),
  }
  let servers : Map[String, Json] = Map([])
  servers[config.mcp_server_name] = server.to_json()
  let mcp_config : Map[String, Json] = { "mcpServers": servers.to_json() }
  [
    "-p",
    "--input-format",
    "text",
    "--setting-sources",
    "",
    "--tools",
    "",
    "--disable-slash-commands",
    "--permission-mode",
    "dontAsk",
    "--allowedTools",
    config.allowed_tools.join(","),
    "--strict-mcp-config",
    "--mcp-config",
    mcp_config.to_json().stringify(),
    "--output-format",
    "stream-json",
    "--verbose",
    "--no-session-persistence",
    "--json-schema",
    native_claude_output_schema(role),
    "--system-prompt",
    native_claude_system_prompt(role),
  ]
}

///|
fn native_claude_environment(
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
test "native Claude Take environment is an exact allowlist" {
  let environment = native_claude_environment("/provider-home", "/sterile-take")
  assert_eq(environment.length(), 5)
  assert_eq(environment["HOME"], "/provider-home")
  assert_eq(environment["TMPDIR"], "/sterile-take/tmp")
  assert_false(environment.contains("ANTHROPIC_API_KEY"))
  assert_false(environment.contains("CLAUDE_CODE_OAUTH_TOKEN"))
  assert_false(environment.contains("CHOIR_CONDUCTOR_TOKEN"))
}

///|
test "native Claude owner socket binding is exact and paired with MCP argv" {
  let root = "/tmp/choir-boxlite-test/claude/session-test"
  let source = "/tmp/choir-boxlite-test/owner-socket"
  let target = native_provider_owner_socket_path()
  let config : NativeClaudeDriverConfig = {
    sterile_root: root,
    mcp_executable: "/usr/bin/node",
    mcp_arguments: ["/opt/choir/sandbox-mcp.mjs", "--owner-socket", target],
    boxlite_owner_socket_root: Some(source),
    mcp_server_name: "choir_sandbox",
    allowed_tools: ["mcp__choir_sandbox__read_file"],
    timeout_ms: 60000,
  }
  assert_true(validate_native_claude_config(config) is Ok(_))
  assert_true(
    validate_native_claude_config({
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
    validate_native_claude_config({ ..config, boxlite_owner_socket_root: None })
    is Err(_),
  )
}

///|
async fn verify_native_claude_binary(
  claude : String,
) -> Result[Unit, @types.ChoirError] {
  let collected = @process.collect_output_merged(
    "/usr/bin/sha256sum",
    [claude],
    extra_env={ "PATH": "/usr/bin:/bin", "LC_ALL": "C" },
    inherit_env=false,
    cwd="/tmp",
  ) catch {
    _ => return Err(native_claude_driver_error("binary hash probe failed"))
  }
  let (exit_code, data) = collected
  let output = data.text() catch {
    _ => return Err(native_claude_driver_error("binary hash was not UTF-8"))
  }
  if exit_code != 0 ||
    !output.has_prefix(@harness.expected_claude_executable_sha256 + " ") {
    Err(
      @types.ChoirError::policy_blocked(
        "Claude executable does not match the admitted pin",
      ),
    )
  } else {
    Ok(())
  }
}

///|
pub async fn run_native_claude_take(
  config : NativeClaudeDriverConfig,
  session : @control.HarnessSession,
  role : @harness.ClaudeTakeRole,
  instruction : String,
  now : () -> Int64,
  cancellation_requested? : () -> Bool = fn() { false },
) -> Result[@harness.ClaudeDriverResult, @types.ChoirError] {
  match validate_native_claude_config(config) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let instruction_bytes = @utf8.encode(instruction)
  if instruction_bytes.length() == 0 ||
    instruction_bytes.length() > 16384 ||
    instruction.contains("\u{00}") {
    return Err(
      @types.ChoirError::validation_error(
        "Claude Take instruction is empty or exceeds the safe bound",
      ),
    )
  }
  if session.lifecycle !=
    @control.HarnessSessionLifecycle::HarnessSessionAwaitingEvents {
    return Err(
      @types.ChoirError::validation_error(
        "native Claude driver requires an authorized started session",
      ),
    )
  }
  match claude_conflicting_credential_environment() {
    Some(name) =>
      return Err(
        @types.ChoirError::policy_blocked(
          "conflicting Claude credential environment is present: " + name,
        ),
      )
    None => ()
  }
  let provider_home = match @sys.getenv("HOME") {
    Some(value) if value.has_prefix("/") => value
    _ => return Err(native_claude_driver_error("provider home is unavailable"))
  }
  let claude = match claude_probe_executable() {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match verify_native_claude_binary(claude) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match validate_native_provider_host_boundary() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if !@sys.create_dir_all(config.sterile_root + "/tmp") {
    return Err(native_claude_driver_error("sterile root is unavailable"))
  }
  let (stdin_read, stdin_write) = @process.write_to_process() catch {
    _ => return Err(native_claude_driver_error("stdin pipe failed"))
  }
  ignore(
    stdin_write.write(instruction) catch {
      _ => {
        stdin_write.close()
        return Err(native_claude_driver_error("instruction write failed"))
      }
    },
  )
  stdin_write.close()
  let started_at = now()
  let args = native_claude_driver_args(config, role)
  let bounded_args = native_provider_host_boundary_args(
    config.sterile_root,
    config.sterile_root,
    config.boxlite_owner_socket_root,
    claude,
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
      native_claude_environment(provider_home, config.sterile_root),
      stdin_read,
      config.sterile_root,
      config.timeout_ms,
      cancellation_requested,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let (exit_code, data) = match collected {
    NativeInterruptibleProcessOutcome::NativeProcessCompleted(code, output) =>
      (code, output)
    NativeInterruptibleProcessOutcome::NativeProcessInterrupted(_) =>
      return Err(
        @types.ChoirError::canceled(
          "Claude Take interrupted at the Goal cutoff",
        ),
      )
    NativeInterruptibleProcessOutcome::NativeProcessTimedOut(_) =>
      return Err(@types.ChoirError::timeout("Claude Take"))
  }
  let output = data
  if exit_code != 0 {
    return Err(
      @types.ChoirError::provider_process_lost(
        "nonresumable Claude process exited before a complete trace",
      ),
    )
  }
  @harness.evaluate_claude_driver_capture({
    session,
    role,
    allowed_tools: config.allowed_tools,
    expected_mcp_server: config.mcp_server_name,
    capture: { exit_code, output, started_at, finished_at: now() },
  })
}

///|
test "native Claude driver argv removes host tools and ambient configuration" {
  let args = native_claude_driver_args(
    {
      sterile_root: "/tmp/choir-claude-driver-test",
      mcp_executable: "/opt/choir/sandbox-mcp",
      mcp_arguments: ["serve", "sandbox-1"],
      boxlite_owner_socket_root: None,
      mcp_server_name: "choir_sandbox",
      allowed_tools: ["mcp__choir_sandbox__execute"],
      timeout_ms: 60000,
    },
    @harness.ClaudeTakeRole::ClaudeImplementationTake,
  )
  assert_true(args.contains("--setting-sources"))
  assert_true(args.contains("--tools"))
  assert_true(args.contains("--strict-mcp-config"))
  assert_true(args.contains("--no-session-persistence"))
  assert_true(args.contains("--json-schema"))
  assert_true(args.contains("mcp__choir_sandbox__execute"))
  assert_false(args.contains("--bare"))
  assert_false(args.contains("--dangerously-skip-permissions"))
}
