///|
pub(all) struct NativeCodexDriverConfig {
  sterile_root : String
  mcp_executable : String
  mcp_arguments : Array[String]
  mcp_server_name : String
  allowed_tools : Array[String]
  timeout_ms : Int
} derive(Debug, Eq)

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
  Ok(())
}

///|
fn native_codex_role_prompt(role : @harness.CodexTakeRole) -> String {
  let common = "Use only tools from the required Choir MCP server. Never use native host file, shell, network, browser, plugin, hook, skill, app, or subagent capabilities. "
  match role {
    @harness.CodexTakeRole::CodexImplementationTake =>
      common +
      "Complete the instruction in the sandbox. End with exactly {\"outcome\":\"completed\"}."
    @harness.CodexTakeRole::CodexVerificationTake =>
      common +
      "Verify the supplied candidate in the sandbox. End with exactly {\"outcome\":\"passed\"} or {\"outcome\":\"failed\"}."
    @harness.CodexTakeRole::CodexAuditTake =>
      common +
      "Independently audit the supplied candidate. End with exactly {\"outcome\":\"passed\",\"total_findings\":0,\"blocking_findings\":0} when clean, otherwise {\"outcome\":\"findings\",\"total_findings\":N,\"blocking_findings\":N}."
  }
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
fn native_codex_driver_args(config : NativeCodexDriverConfig) -> Array[String] {
  let args : Array[String] = [
    "exec", "--json", "--ephemeral", "--skip-git-repo-check", "--ignore-user-config",
    "--ignore-rules", "--strict-config",
  ]
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
) -> Result[Unit, @types.ChoirError] {
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
  verify_native_codex_file(
    native, @harness.expected_codex_native_executable_sha256, "native executable",
  )
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
pub async fn run_native_codex_take(
  config : NativeCodexDriverConfig,
  session : @control.HarnessSession,
  role : @harness.CodexTakeRole,
  instruction : String,
  now : () -> Int64,
  cancellation_requested? : () -> Bool = fn() { false },
) -> Result[@harness.CodexDriverResult, @types.ChoirError] {
  match validate_native_codex_config(config) {
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
  match verify_native_codex_binary(codex) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if !@sys.create_dir_all(config.sterile_root + "/tmp") {
    return Err(native_codex_driver_error("sterile root is unavailable"))
  }
  match
    verify_native_codex_subscription(codex, provider_home, config.sterile_root) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let prompt = native_codex_role_prompt(role) +
    "\n\nInstruction:\n" +
    instruction
  let (stdin_read, stdin_write) = @process.write_to_process() catch {
    _ => return Err(native_codex_driver_error("stdin pipe failed"))
  }
  ignore(
    stdin_write.write(prompt) catch {
      _ => {
        stdin_write.close()
        return Err(native_codex_driver_error("instruction write failed"))
      }
    },
  )
  stdin_write.close()
  let started_at = now()
  let args = native_codex_driver_args(config)
  abort_if_hermetic_test_exec(
    command_to_shell_string({
      program: codex,
      args,
      workdir: Some(config.sterile_root),
    }),
  )
  let collected = match
    collect_interruptible_process(
      codex,
      args,
      native_codex_environment(provider_home, config.sterile_root),
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
        @types.ChoirError::canceled("Codex Take interrupted at the Goal cutoff"),
      )
    NativeInterruptibleProcessOutcome::NativeProcessTimedOut(_) =>
      return Err(@types.ChoirError::timeout("Codex Take"))
  }
  let output = data
  if exit_code != 0 {
    let usage_limited = output.contains("usage limit") ||
      output.contains("rate limit") ||
      output.contains("Usage limit") ||
      output.contains("Rate limit")
    let mcp_failed = (output.contains("MCP") || output.contains("mcp")) &&
      (output.contains("failed") || output.contains("error"))
    return Err(
      native_codex_driver_error(
        "provider process exited with status " +
        exit_code.to_string() +
        " usage_limited=" +
        usage_limited.to_string() +
        " mcp_failed=" +
        mcp_failed.to_string(),
      ),
    )
  }
  @harness.evaluate_codex_driver_capture({
    session,
    role,
    allowed_tools: config.allowed_tools,
    expected_mcp_server: config.mcp_server_name,
    capture: { exit_code, output, started_at, finished_at: now() },
  })
}

///|
test "native Codex driver argv removes ambient and native execution surfaces" {
  let args = native_codex_driver_args({
    sterile_root: "/tmp/choir-codex-driver-test",
    mcp_executable: "/usr/bin/node",
    mcp_arguments: ["/opt/choir/sandbox-mcp.mjs"],
    mcp_server_name: "choir_sandbox",
    allowed_tools: ["read_file", "run"],
    timeout_ms: 60000,
  })
  assert_true(args.contains("--ignore-user-config"))
  assert_true(args.contains("--ignore-rules"))
  assert_true(args.contains("shell_tool"))
  assert_true(args.contains("multi_agent"))
  assert_true(args.contains("mcp_servers.choir_sandbox.required=true"))
  assert_eq(args[args.length() - 1], "-")
  assert_true(
    args.contains(
      "mcp_servers.choir_sandbox.enabled_tools=[\"read_file\",\"run\"]",
    ),
  )
  assert_false(args.contains("--dangerously-bypass-approvals-and-sandbox"))
}
