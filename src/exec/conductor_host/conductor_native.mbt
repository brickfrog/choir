///|
fn native_conductor_error(detail : String) -> @types.Response {
  @types.Response::err_text("native Conductor: " + detail)
}

///|
/// Refuse to launch the Conductor against a Claude whose advertised surface no
/// longer matches the launch it is about to receive.
pub async fn validate_native_conductor_surface(
  claude_executable : String,
  capture~ : async (@process_host.Command) -> (Int, String),
) -> Result[Unit, @types.ChoirError] {
  if !claude_executable.has_prefix("/") {
    return Err(
      @types.ChoirError::validation_error(
        "unqualified Conductor surface: Claude executable is not canonical",
      ),
    )
  }
  let (exit_code, output) = capture({
    program: claude_executable,
    args: ["--help"],
    workdir: Some("/tmp"),
  })
  if exit_code != 0 {
    return Err(
      @types.ChoirError::transport_error(
        "unqualified Conductor surface: claude --help exited with status " +
        exit_code.to_string(),
      ),
    )
  }
  let findings = @harness.qualify_conductor_surface(
    output,
    @harness.conductor_surface_flags(),
  )
  if @harness.conductor_surface_is_qualified(findings) {
    Ok(())
  } else {
    Err(
      @types.ChoirError::validation_error(
        findings
        .map(fn(finding) { @harness.conductor_surface_finding_text(finding) })
        .join("; "),
      ),
    )
  }
}

///|
pub fn resolve_native_claude_conductor_executable(
  resolve? : (String) -> String? = @process_host.resolve_executable_in_path,
  canonicalize? : (String) -> String? = @sys.realpath_native,
  executable? : (String) -> Bool = @sys.path_executable,
) -> Result[String, @types.ChoirError] {
  let discovered = match resolve("claude") {
    Some(value) => value
    None =>
      return Err(
        @types.ChoirError::transport_error(
          "Claude Conductor executable is unavailable",
        ),
      )
  }
  let canonical = match canonicalize(discovered) {
    Some(value) => value
    None =>
      return Err(
        @types.ChoirError::policy_blocked(
          "Claude Conductor executable is not canonical",
        ),
      )
  }
  if canonical == "/" || !executable(canonical) {
    Err(
      @types.ChoirError::policy_blocked(
        "Claude Conductor executable is not executable",
      ),
    )
  } else {
    Ok(canonical)
  }
}

///|
pub fn native_claude_conductor_credential_file(
  home? : String? = @sys.getenv("HOME"),
) -> Result[String, @types.ChoirError] {
  match home {
    Some(value) if value.has_prefix("/") && value != "/" =>
      Ok(value + "/.claude/.credentials.json")
    _ =>
      Err(
        @types.ChoirError::policy_blocked(
          "Claude Conductor credential home is unavailable",
        ),
      )
  }
}

///|
pub fn validate_native_claude_conductor_sources(
  project_dir : String,
  claude_executable : String,
  choir_executable : String,
  credential_file : String,
  canonicalize? : (String) -> String? = @sys.realpath_native,
  executable? : (String) -> Bool = @sys.path_executable,
  file_mode? : (String) -> Int = @sys.file_mode,
) -> Result[Unit, @types.ChoirError] {
  if project_dir == "/" ||
    canonicalize(project_dir) != Some(project_dir) ||
    canonicalize(claude_executable) != Some(claude_executable) ||
    canonicalize(choir_executable) != Some(choir_executable) ||
    canonicalize(credential_file) != Some(credential_file) ||
    canonicalize("/usr/bin/bwrap") != Some("/usr/bin/bwrap") {
    return Err(
      @types.ChoirError::policy_blocked(
        "Claude Conductor boundary source is not canonical",
      ),
    )
  }
  if !executable(claude_executable) ||
    !executable(choir_executable) ||
    !executable("/usr/bin/bwrap") {
    return Err(
      @types.ChoirError::policy_blocked(
        "Claude Conductor boundary executable is unavailable",
      ),
    )
  }
  if file_mode(credential_file) != 0o600 {
    return Err(
      @types.ChoirError::policy_blocked(
        "Claude Conductor credential must be a canonical owner-only file",
      ),
    )
  }
  Ok(())
}

///|
pub fn validate_native_claude_conductor_config(
  config : NativeClaudeConductorConfig,
  canonicalize? : (String) -> String? = @sys.realpath_native,
  executable? : (String) -> Bool = @sys.path_executable,
  file_mode? : (String) -> Int = @sys.file_mode,
) -> Result[Unit, @types.ChoirError] {
  match
    validate_native_claude_conductor_sources(
      config.project_dir,
      config.claude_executable,
      config.choir_executable,
      config.credential_file,
      canonicalize~,
      executable~,
      file_mode~,
    ) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  if canonicalize(config.daemon_socket) != Some(config.daemon_socket) ||
    file_mode(config.daemon_socket) != 0o600 ||
    config.environment.workspace != config.project_dir ||
    config.environment.listen_uds != config.daemon_socket {
    return Err(
      @types.ChoirError::policy_blocked(
        "Claude Conductor daemon socket identity is invalid",
      ),
    )
  }
  match
    native_claude_conductor_command(
      config,
      ClaudeConductorLaunchMode::ClaudeConductorInteractive,
    ) {
    Ok(_) => Ok(())
    Err(error) => Err(error)
  }
}

///|
pub async fn run_native_claude_conductor(
  config : NativeClaudeConductorConfig,
) -> Result[Int, @types.ChoirError] {
  match validate_native_claude_conductor_config(config) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let command = match
    native_claude_conductor_command(
      config,
      ClaudeConductorLaunchMode::ClaudeConductorInteractive,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  @process_host.abort_if_hermetic_test_exec(
    @process_host.command_to_shell_string(command),
  )
  let exit_code = @process.run(
    command.program,
    command.args[:],
    extra_env=native_claude_conductor_environment(config),
    inherit_env=false,
    cwd=config.project_dir,
  ) catch {
    _ =>
      return Err(
        @types.ChoirError::transport_error(
          "Claude Conductor boundary process failed to start",
        ),
      )
  }
  Ok(exit_code)
}

///|
pub async fn capture_native_claude_conductor_qualification(
  config : NativeClaudeConductorConfig,
  instruction : String,
) -> Result[String, @types.ChoirError] {
  if instruction.trim() == "" || instruction.length() > 65536 {
    return Err(
      @types.ChoirError::validation_error(
        "Claude Conductor qualification instruction is invalid",
      ),
    )
  }
  match validate_native_claude_conductor_config(config) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let command = match
    native_claude_conductor_command(
      config,
      ClaudeConductorLaunchMode::ClaudeConductorQualification,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let (stdin_read, stdin_write) = @process.write_to_process() catch {
    _ =>
      return Err(
        @types.ChoirError::transport_error(
          "Claude Conductor qualification stdin failed",
        ),
      )
  }
  ignore(
    stdin_write.write(instruction) catch {
      _ => {
        stdin_write.close()
        return Err(
          @types.ChoirError::transport_error(
            "Claude Conductor qualification input failed",
          ),
        )
      }
    },
  )
  stdin_write.close()
  @process_host.abort_if_hermetic_test_exec(
    @process_host.command_to_shell_string(command),
  )
  match
    @process_host.collect_interruptible_process(
      command.program,
      command.args,
      native_claude_conductor_environment(config),
      stdin_read,
      config.project_dir,
      120000,
      fn() { false },
    ) {
    Ok(@process_host.NativeProcessCompleted(0, output)) => Ok(output)
    Ok(@process_host.NativeProcessCompleted(_, _)) =>
      Err(
        @types.ChoirError::provider_process_lost(
          "Claude Conductor qualification exited before a complete trace",
        ),
      )
    Ok(@process_host.NativeProcessTimedOut(_)) =>
      Err(@types.ChoirError::timeout("Claude Conductor qualification"))
    Ok(@process_host.NativeProcessInterrupted(_)) =>
      Err(
        @types.ChoirError::provider_process_lost(
          "Claude Conductor qualification was interrupted",
        ),
      )
    Err(error) => Err(error)
  }
}

///|
pub async fn dispatch_native_conductor_request(
  project_dir : String,
  request : @types.Request,
  now? : Int64 = @env.now().reinterpret_as_int64() / 1000L,
  capture~ : async (@process_host.Command) -> (Int, String),
) -> @types.Response {
  if request.req_method != @types.WireMethod::WireToolsCall {
    return native_conductor_error("authenticated Conductor required")
  }
  if request.name.has_prefix("goal_") {
    @goal_host.dispatch_native_goal_request(project_dir, request, now, capture~)
  } else if request.name.has_prefix("task_") {
    @beads_host.dispatch_native_beads_request(project_dir, request, capture~)
  } else {
    native_conductor_error("unknown tool " + request.name)
  }
}
