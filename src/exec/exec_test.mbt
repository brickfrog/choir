///|
test "Claude Conductor keeps default tools and uses strict MCP config" {
  let command = conductor_launch_command("/repo", "/opt/choir/bin/choir")
  let joined = command.args.join(" ")
  assert_eq(command.program, "claude")
  assert_true(joined.contains("--strict-mcp-config"))
  assert_false(command.args.contains("--tools"))
  assert_true(
    joined.contains(
      "--allowedTools mcp__choir__goal_submit,mcp__choir__goal_status,mcp__choir__goal_cancel,mcp__choir__goal_steer,mcp__choir__goal_attach,mcp__choir__goal_answer,mcp__choir__task_list,mcp__choir__task_get,mcp__choir__task_create,mcp__choir__task_update",
    ),
  )
  assert_true(
    joined.contains("--dangerously-load-development-channels server:choir"),
  )
  assert_true(joined.contains("--setting-sources project"))
  assert_true(
    joined.contains(
      "--append-system-prompt-file /repo/.choir/state/conductor-prompt.md",
    ),
  )
  assert_false(joined.contains("--plugin-dir"))
  assert_true(joined.contains("\"command\":\"/opt/choir/bin/choir\""))
  assert_true(joined.contains("\"--channel\""))
  assert_false(joined.contains("\"command\":\"choir\""))
  assert_false(joined.contains("zellij"))
  let settings = conductor_claude_settings_json("/opt/choir/bin/choir")
  assert_true(settings.contains("\"Stop\""))
  assert_true(settings.contains("\"enabledMcpjsonServers\":[\"choir\"]"))
  assert_true(settings.contains("/opt/choir/bin/choir"))
  assert_true(settings.contains("conductor-stop"))
  assert_true(settings.contains("conductor-statusline"))
  assert_true(settings.contains("\"statusLine\""))
  assert_true(settings.contains("\"padding\":0"))
  assert_false(settings.contains("refreshInterval"))
  assert_false(settings.contains("automatic_polling_allowed"))
  let parsed = @json.parse(settings) catch {
    _ => fail("Conductor settings are not valid JSON")
  }
  guard parsed is Object(root) else {
    fail("Conductor settings are not an object")
  }
  guard root.get("statusLine") is Some(Object(statusline)) else {
    fail("Conductor statusLine is absent")
  }
  assert_eq(
    statusline.get("command"),
    Some("'/opt/choir/bin/choir' conductor-statusline".to_json()),
  )
  assert_eq(statusline.get("padding"), Some((0 : Int).to_json()))
}

///|
test "Claude Conductor project MCP merge preserves unrelated servers" {
  let existing =
    #|{"custom":{"preserved":true},"mcpServers":{"other":{"type":"stdio","command":"/opt/other","args":[]}}}
  let merged = conductor_claude_project_mcp_config_json(
    existing, "/opt/choir/bin/choir",
  ).unwrap()
  let parsed = @json.parse(merged) catch {
    _ => fail("merged MCP config is invalid")
  }
  guard parsed is Object(root) else {
    fail("merged MCP config is not an object")
  }
  assert_true(root.get("custom") is Some(_))
  guard root.get("mcpServers") is Some(Object(servers)) else {
    fail("merged MCP servers are absent")
  }
  assert_true(servers.get("other") is Some(_))
  guard servers.get("choir") is Some(Object(choir)) else {
    fail("Choir MCP server is absent")
  }
  assert_eq(choir.get("command"), Some("/opt/choir/bin/choir".to_json()))
  assert_true(choir.to_json().stringify().contains("\"--channel\""))
  assert_true(
    conductor_claude_project_mcp_config_json(
      "{\"mcpServers\":[]}", "/opt/choir/bin/choir",
    )
    is Err(_),
  )
}

///|
test "command_to_shell_string simple" {
  let cmd = @exec.Command::{
    program: "ls",
    args: ["-l", "/tmp"],
    workdir: None,
  }
  assert_eq(command_to_shell_string(cmd), "'ls' '-l' '/tmp'")
}

///|
test "command_to_shell_string workdir" {
  let cmd = @exec.Command::{
    program: "ls",
    args: ["-l"],
    workdir: Some("/home/user"),
  }
  assert_eq(command_to_shell_string(cmd), "cd '/home/user' && 'ls' '-l'")
}

///|
test "command_to_shell_string quotes" {
  let cmd = @exec.Command::{
    program: "echo",
    args: ["it's fine", "quoted \"arg\""],
    workdir: None,
  }
  assert_eq(
    command_to_shell_string(cmd),
    "'echo' 'it'\\''s fine' 'quoted \"arg\"'",
  )
}

///|
test "hermetic exec violation message names command and mock guidance" {
  let cmd = @exec.Command::{ program: "git", args: ["status"], workdir: None }
  assert_eq(
    hermetic_exec_violation_message(command_to_shell_string(cmd)),
    "hermetic-test violation: real exec 'git' 'status' -- inject a mock capture/runner",
  )
}

///|
async test "real exec integration: capture_command_merged captures stdout" {
  if !real_exec_integration_enabled() {
    return
  }
  let (code, out) = capture_command_merged({
    program: "echo",
    args: ["hello-capture"],
    workdir: None,
  })
  assert_eq(code, 0)
  assert_eq(out.trim(), "hello-capture")
}

///|
async test "real exec integration: capture_command_merged merges stderr" {
  if !real_exec_integration_enabled() {
    return
  }
  let (code, out) = capture_command_merged({
    program: "/bin/sh",
    args: ["-c", "echo stdout_line; echo stderr_line >&2"],
    workdir: None,
  })
  assert_eq(code, 0)
  assert_true(out.contains("stdout_line"))
  assert_true(out.contains("stderr_line"))
}

///|
test "resolve_executable_in_path_from_path_var misses when absent" {
  let got = resolve_executable_in_path_from_path_var(
    "___choir_test_nonexistent_tool___", "/__nope_choir__/bin:/__also_bad_choir__",
  )
  @debug.assert_eq(got, None)
}

///|
test "resolve_executable_in_path_from_path_var finds sh under /bin when present" {
  let got = resolve_executable_in_path_from_path_var("sh", "/bin")
  @debug.assert_eq(got, Some("/bin/sh"))
}

///|
test "strip_terminal_responses removes OSC replies and keeps SGR" {
  let raw = "before \u{1b}[31mred\u{1b}[0m \u{1b}]11;rgb:0a0a/0f0f/1414\u{1b}\\after"
  let got = strip_terminal_responses(raw)
  assert_eq(got, "before \u{1b}[31mred\u{1b}[0m after")
}

///|
test "strip_terminal_responses removes BEL terminated OSC 10 and OSC 4 replies" {
  let raw = "a\u{1b}]10;rgb:ffff/ffff/ffff\u{07}b\u{1b}]4;2;rgb:0000/1111/2222\u{07}c"
  assert_eq(strip_terminal_responses(raw), "abc")
}

///|
test "strip_terminal_responses removes CSI Primary DA replies" {
  assert_eq(strip_terminal_responses("x\u{1b}[?62;4;52cy"), "xy")
}

///|
test "strip_terminal_responses removes CSI Cursor Position Reports" {
  assert_eq(strip_terminal_responses("x\u{1b}[61;1Ry"), "xy")
}

///|
test "strip_terminal_responses preserves unknown escapes and normal text" {
  let raw = "plain \u{1b}[?25l hidden \u{1b}[32mgreen\u{1b}[0m"
  assert_eq(strip_terminal_responses(raw), raw)
}

///|
test "strip_terminal_responses leaves normal text unchanged" {
  assert_eq(strip_terminal_responses("plain log line"), "plain log line")
}

///|
test "Goal runtime preflight validates every required installed path" {
  let observed : Array[String] = []
  let result = validate_native_goal_runtime(
    validate_assets=fn() {
      observed.push("assets")
      Ok(())
    },
    resolve_binary=fn() {
      observed.push("binary")
      Ok("/opt/choir/boxlite")
    },
    resolve_runtime=fn() {
      observed.push("runtime")
      Ok("/opt/choir/runtime")
    },
    canonicalize=fn(path) {
      observed.push(path)
      Some(path)
    },
  )
  assert_true(result is Ok(_))
  assert_eq(observed, [
    "assets", "binary", "/opt/choir/boxlite", "runtime", "/opt/choir/runtime",
  ])
}

///|
test "Goal runtime preflight fails before resolving later requirements" {
  let binary_called = @ref.new(false)
  let result = validate_native_goal_runtime(
    validate_assets=fn() {
      Err(@types.ChoirError::workspace_error("assets absent"))
    },
    resolve_binary=fn() {
      binary_called.val = true
      Ok("/opt/choir/boxlite")
    },
    resolve_runtime=fn() { Ok("/opt/choir/runtime") },
    canonicalize=fn(path) { Some(path) },
  )
  assert_false(binary_called.val)
  match result {
    Err(error) => assert_true(error.message().contains("assets absent"))
    Ok(_) => fail("incomplete Goal runtime passed preflight")
  }
}

///|

///|
/// The launch argv and the declared surface are two lists that used to drift —
/// the flags changed five times in one day. This is the coupling: every flag
/// the launch passes must be declared, or qualification would never check it
/// against the installed CLI.
test "every Conductor launch flag is declared in the qualified surface" {
  let declared = @harness.conductor_surface_flags().map(fn(flag) { flag.name })
  let passed : Array[String] = []
  for lean in [false, true] {
    let command = conductor_launch_command("/repo", "/usr/bin/choir", lean~)
    for argument in command.args {
      if argument.has_prefix("--") && !passed.contains(argument) {
        passed.push(argument)
      }
    }
  }
  for argument in passed {
    assert_true(declared.contains(argument))
  }
  // And nothing is declared that the launch never passes, so the surface is
  // exactly what Choir depends on rather than a wish list.
  for flag in declared {
    assert_true(passed.contains(flag))
  }
}

///|
/// The same coupling for the environment half. It cannot be qualified against
/// the installed CLI — help advertises flags, not environment — so declaring it
/// buys exactly one thing: what the Conductor receives cannot drift from what
/// is written down. That is only true if this holds in both directions.
test "the Conductor launch environment is exactly the declared surface" {
  let variables = conductor_process_environment_variables({
    conductor_token: "token",
    statusline_cache_key: "conductor-42",
    workspace: "/repo",
    listen_uds: "/repo/.choir/run/server.sock",
  })
  for requirement in @harness.conductor_surface_environment() {
    assert_eq(variables.get(requirement.name), Some(requirement.value))
  }
  // Nothing belonging to Claude's surface may be passed that the manifest does
  // not declare: a new `CLAUDE_*` literal added at the spawn site is precisely
  // the undeclared dependency this exists to prevent. Choir's own handles are
  // per-launch values, not a dependency on the installed CLI.
  let declared = @harness.conductor_surface_environment().map(fn(requirement) {
    requirement.name
  })
  for name in variables.keys() {
    if name.has_prefix("CLAUDE_") {
      assert_true(declared.contains(name))
    } else {
      assert_true(name.has_prefix("CHOIR_"))
    }
  }
}

///|
/// The live probe and the runtime Take path each built this argv independently,
/// so a protocol change had to be made twice and the probe could silently stop
/// exercising what the runtime actually does. One builder now, and this pins
/// the wire contract it produces.
test "a BoxLite request carries its auth and body exactly once" {
  let with_body = boxlite_http_arguments(
    "secret-key",
    "http://127.0.0.1:22000",
    "POST",
    "/v1/boxes",
    Some("{\"name\":\"box-1\"}"),
    30,
  )
  @debug.assert_eq(with_body, [
    "-fsS", "--max-time", "30", "-X", "POST", "-H", "Authorization: Bearer secret-key",
    "-H", "Content-Type: application/json", "--data-binary", "{\"name\":\"box-1\"}",
    "http://127.0.0.1:22000/v1/boxes",
  ])
  // A bodyless call sends no content type and no body flag, so a GET cannot
  // accidentally carry an empty payload.
  let without_body = boxlite_http_arguments(
    "secret-key",
    "http://127.0.0.1:22000",
    "GET",
    "/v1/boxes/box-1",
    None,
    20,
  )
  @debug.assert_eq(without_body, [
    "-fsS", "--max-time", "20", "-X", "GET", "-H", "Authorization: Bearer secret-key",
    "http://127.0.0.1:22000/v1/boxes/box-1",
  ])
  // The timeout is the only thing the two stacks disagree about, and it is a
  // parameter rather than a second copy of the protocol.
  assert_true(with_body.contains("30"))
  assert_true(without_body.contains("20"))
  // The clone body is one definition both stacks use.
  assert_eq(boxlite_clone_request_body("box-2"), "{\"name\":\"box-2\"}")
}
