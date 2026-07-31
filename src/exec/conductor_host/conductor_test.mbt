///|
fn conductor_boundary_test_config(
  lean? : Bool = false,
) -> NativeClaudeConductorConfig {
  {
    project_dir: "/repo",
    claude_executable: "/opt/claude/claude",
    choir_executable: "/opt/choir/choir",
    credential_file: "/home/provider/.claude/.credentials.json",
    daemon_socket: "/repo/.choir/run/server.sock",
    environment: {
      conductor_token: "token",
      statusline_cache_key: "conductor-42",
      workspace: "/repo",
      listen_uds: "/repo/.choir/run/server.sock",
    },
    prompt: "Use Choir to plan durable Goals.",
    lean,
  }
}

///|
fn command_has_binding(
  args : Array[String],
  kind : String,
  source : String,
  target : String,
) -> Bool {
  for index = 0; index + 2 < args.length(); index = index + 1 {
    if args[index] == kind &&
      args[index + 1] == source &&
      args[index + 2] == target {
      return true
    }
  }
  false
}

///|
test "Claude Conductor command fixes the host boundary and capability surface" {
  let command = native_claude_conductor_command(
    conductor_boundary_test_config(),
    ClaudeConductorLaunchMode::ClaudeConductorInteractive,
  ).unwrap()
  assert_eq(command.program, "/usr/bin/bwrap")
  assert_eq(command.workdir, Some("/repo"))
  @debug.assert_eq(command.args[:5], [
    "--die-with-parent", "--unshare-pid", "--unshare-ipc", "--unshare-uts", "--unshare-cgroup-try",
  ])
  assert_true(
    command_has_binding(command.args, "--ro-bind", "/repo", "/workspace"),
  )
  assert_true(
    command_has_binding(
      command.args,
      "--ro-bind",
      "/home/provider/.claude/.credentials.json",
      "/runtime/home/.claude/.credentials.json",
    ),
  )
  assert_true(
    command_has_binding(
      command.args,
      "--ro-bind",
      "/opt/claude/claude",
      "/choir-claude",
    ),
  )
  assert_true(
    command_has_binding(command.args, "--ro-bind", "/opt/choir/choir", "/choir"),
  )
  assert_true(
    command_has_binding(
      command.args,
      "--ro-bind",
      "/repo/.choir/run/server.sock",
      "/choir.sock",
    ),
  )
  for index = 0; index + 2 < command.args.length(); index = index + 1 {
    assert_false(
      command.args[index] == "--ro-bind" &&
      command.args[index + 1] == "/" &&
      command.args[index + 2] == "/",
    )
    assert_false(
      command.args[index] == "--bind" && command.args[index + 2] == "/workspace",
    )
  }
  assert_false(command.args.contains("/home/provider"))
  assert_false(command.args.contains("/mnt"))
  let separator = command.args.search("--").unwrap()
  assert_eq(command.args[separator + 1], "/choir-claude")
  let claude_args = command.args[separator + 2:]
  assert_false(claude_args.contains("--dangerously-skip-permissions"))
  assert_true(claude_args.contains("--tools"))
  assert_true(claude_args.contains("Read,Glob,Grep"))
  assert_true(claude_args.contains("--permission-mode"))
  assert_true(claude_args.contains("dontAsk"))
  assert_true(claude_args.contains("--strict-mcp-config"))
  assert_false(claude_args.contains("--disable-slash-commands"))
  assert_true(claude_args.contains("--no-chrome"))
  let setting_sources = claude_args.search("--setting-sources").unwrap()
  assert_eq(claude_args[setting_sources + 1], "")
}

///|
test "Claude Conductor settings and MCP config contain only fixed sandbox paths" {
  let settings = @json.parse(conductor_claude_settings_json()) catch {
    _ => fail("Conductor settings are not valid JSON")
  }
  guard settings is Object(root) else {
    fail("Conductor settings are not an object")
  }
  guard root.get("permissions") is Some(Object(permissions)) else {
    fail("Conductor permissions are absent")
  }
  @debug.assert_eq(
    permissions.get("allow").unwrap(),
    conductor_claude_allowed_tools().to_json(),
  )
  let denied = permissions.get("deny").unwrap().stringify()
  assert_true(denied.contains("Read(//runtime/**)"))
  assert_true(denied.contains("Read(//proc/**)"))
  guard root.get("statusLine") is Some(Object(statusline)) else {
    fail("Conductor statusline is absent")
  }
  assert_eq(
    statusline.get("command"),
    Some("/choir conductor-statusline".to_json()),
  )
  let rendered = settings.stringify()
  assert_true(rendered.contains("\"command\":\"/choir\""))
  assert_true(rendered.contains("conductor-stop"))
  assert_false(rendered.contains("/repo"))
  assert_false(rendered.contains("/home"))

  let mcp = conductor_claude_mcp_config_json()
  assert_true(mcp.contains("\"command\":\"/choir\""))
  assert_true(mcp.contains("/runtime/mcp-stdio.stderr.log"))
  assert_true(mcp.contains("\"--channel\""))
  assert_false(mcp.contains("/repo"))
  assert_false(mcp.contains("/home"))
}

///|
test "Claude Conductor MCP permission list exactly follows the catalog" {
  let expected : Array[String] = ["Read(//workspace/**)", "Glob", "Grep"]
  for name in @mcp.conductor_tool_names() {
    expected.push("mcp__choir__" + name)
  }
  assert_eq(conductor_claude_allowed_tools(), expected)
  assert_true(expected.contains("mcp__choir__goal_list"))
  assert_true(expected.contains("mcp__choir__task_batch"))
}

///|
test "Claude Conductor environment is an exact nonambient allowlist" {
  let environment = native_claude_conductor_environment(
    conductor_boundary_test_config(),
  )
  assert_eq(environment.length(), 14)
  assert_eq(environment["HOME"], "/runtime/home")
  assert_eq(environment["TMPDIR"], "/tmp")
  assert_eq(environment["PATH"], "/usr/bin:/bin")
  assert_eq(environment["CHOIR_WORKSPACE"], "/workspace")
  assert_eq(environment["CHOIR_LISTEN_UDS"], "/choir.sock")
  assert_eq(environment["CHOIR_CONDUCTOR_TOKEN"], "token")
  assert_false(environment.contains("ANTHROPIC_API_KEY"))
  assert_false(environment.contains("CLAUDE_CODE_OAUTH_TOKEN"))
  assert_false(environment.contains("GIT_CONFIG_GLOBAL"))
}

///|
test "qualification adds only the fixed capture transport" {
  let interactive = native_claude_conductor_command(
    conductor_boundary_test_config(),
    ClaudeConductorLaunchMode::ClaudeConductorInteractive,
  ).unwrap()
  let qualification = native_claude_conductor_command(
    conductor_boundary_test_config(),
    ClaudeConductorLaunchMode::ClaudeConductorQualification,
  ).unwrap()
  assert_false(interactive.args.contains("-p"))
  for
    argument in [
      "-p", "--input-format", "text", "--output-format", "stream-json", "--verbose",
      "--no-session-persistence",
    ] {
    assert_true(qualification.args.contains(argument))
  }
  let lean = native_claude_conductor_command(
    conductor_boundary_test_config(lean=true),
    ClaudeConductorLaunchMode::ClaudeConductorInteractive,
  ).unwrap()
  let system_prompt = lean.args.search("--system-prompt").unwrap()
  assert_eq(lean.args[system_prompt + 1], ".")
}

///|
test "Claude Conductor command rejects relative roots and empty prompts" {
  let config = conductor_boundary_test_config()
  assert_true(
    native_claude_conductor_command(
      { ..config, project_dir: "." },
      ClaudeConductorLaunchMode::ClaudeConductorInteractive,
    )
    is Err(_),
  )
  assert_true(
    native_claude_conductor_command(
      { ..config, prompt: " " },
      ClaudeConductorLaunchMode::ClaudeConductorInteractive,
    )
    is Err(_),
  )
}

///|
test "every Conductor launch flag is declared in the qualified surface" {
  let declared = @harness.conductor_surface_flags().map(fn(flag) { flag.name })
  let passed : Array[String] = []
  for
    mode in [
      ClaudeConductorLaunchMode::ClaudeConductorInteractive,
      ClaudeConductorLaunchMode::ClaudeConductorQualification,
    ] {
    for lean in [false, true] {
      let command = native_claude_conductor_command(
        conductor_boundary_test_config(lean~),
        mode,
      ).unwrap()
      let separator = command.args.search("--").unwrap()
      for argument in command.args[separator + 2:] {
        if argument.has_prefix("--") && !passed.contains(argument) {
          passed.push(argument)
        }
      }
    }
  }
  for argument in passed {
    assert_true(declared.contains(argument))
  }
  for flag in declared {
    assert_true(passed.contains(flag))
  }
}
