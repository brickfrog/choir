///|
test "command_to_shell_string simple" {
  let cmd = Command::{ program: "ls", args: ["-l", "/tmp"], workdir: None }
  assert_eq(command_to_shell_string(cmd), "'ls' '-l' '/tmp'")
}

///|
test "command_to_shell_string workdir" {
  let cmd = Command::{
    program: "ls",
    args: ["-l"],
    workdir: Some("/home/user"),
  }
  assert_eq(command_to_shell_string(cmd), "cd '/home/user' && 'ls' '-l'")
}

///|
test "command_to_shell_string quotes" {
  let cmd = Command::{
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
async test "real exec integration: capture_command_merged captures stdout" {
  if !@test_support.real_exec_integration_enabled() {
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
  if !@test_support.real_exec_integration_enabled() {
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
