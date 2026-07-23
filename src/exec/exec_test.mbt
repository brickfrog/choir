///|
test "Claude Conductor launch is terminal-local and strict MCP only" {
  let command = conductor_launch_command("/repo", "/opt/choir/bin/choir")
  let joined = command.args.join(" ")
  assert_eq(command.program, "claude")
  assert_true(joined.contains("--strict-mcp-config"))
  assert_true(
    joined.contains(
      "--append-system-prompt-file /repo/.choir/state/conductor-prompt.md",
    ),
  )
  assert_false(joined.contains("--plugin-dir"))
  assert_true(joined.contains("\"command\":\"/opt/choir/bin/choir\""))
  assert_false(joined.contains("\"command\":\"choir\""))
  assert_false(joined.contains("zellij"))
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
