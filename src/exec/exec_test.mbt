///|
test "command_to_shell_string simple" {
  let cmd = @workspace.Command::{
    program: "ls",
    args: ["-l", "/tmp"],
    workdir: None,
  }
  assert_eq(command_to_shell_string(cmd), "'ls' '-l' '/tmp'")
}

///|
test "command_to_shell_string workdir" {
  let cmd = @workspace.Command::{
    program: "ls",
    args: ["-l"],
    workdir: Some("/home/user"),
  }
  assert_eq(command_to_shell_string(cmd), "cd '/home/user' && 'ls' '-l'")
}

///|
test "command_to_shell_string quotes" {
  let cmd = @workspace.Command::{
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
  let cmd = @workspace.Command::{
    program: "git",
    args: ["status"],
    workdir: None,
  }
  assert_eq(
    hermetic_exec_violation_message(command_to_shell_string(cmd)),
    "hermetic-test violation: real exec 'git' 'status' -- inject a mock capture/runner",
  )
}

///|
test "replace_self returns error for missing binary" {
  if !real_exec_integration_enabled() {
    return
  }
  let missing = "/tmp/choir-missing-reload-binary-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.rm_rf(missing))
  match replace_self(missing, 4) {
    Ok(_) => fail("expected missing binary to fail before exec")
    Err(e) => {
      let message = e.message()
      assert_true(message.contains("replace_self failed for " + missing))
      assert_true(message.contains("errno="))
    }
  }
}

///|
test "default reload binary path resolves current executable" {
  let seen : Array[String] = []
  match
    default_reload_binary_path(realpath=fn(path) {
      seen.push(path)
      Some("/opt/choir/bin/choir")
    }) {
    Ok(path) => {
      assert_eq(path, "/opt/choir/bin/choir")
      @debug.assert_eq(seen, ["/proc/self/exe"])
    }
    Err(e) => fail(e.message())
  }
}

///|
test "default reload binary path fails closed when current executable is missing" {
  match default_reload_binary_path(realpath=fn(_) { None }) {
    Ok(path) => fail("expected missing /proc/self/exe to fail, got " + path)
    Err(e) => {
      let message = e.message()
      assert_true(
        message.contains(
          "cannot resolve reload binary path from /proc/self/exe",
        ),
      )
      assert_false(message.contains("_build/native/release"))
    }
  }
}

///|
test "default reload binary path fails closed when current executable is empty" {
  match default_reload_binary_path(realpath=fn(_) { Some("") }) {
    Ok(path) => fail("expected empty /proc/self/exe to fail, got " + path)
    Err(e) => {
      let message = e.message()
      assert_true(
        message.contains(
          "cannot resolve reload binary path from /proc/self/exe",
        ),
      )
      assert_false(message.contains("_build/native/release"))
    }
  }
}

///|
test "default reload binary path resolves real native executable" {
  match @sys.realpath_native("/proc/self/exe") {
    Some(self_exe) =>
      match default_reload_binary_path() {
        Ok(path) => {
          assert_eq(path, self_exe)
          assert_false(path.contains("_build/native/release"))
        }
        Err(e) => fail(e.message())
      }
    None => fail("expected /proc/self/exe to resolve on native backend")
  }
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
async test "real exec integration: capture_hook_script_merged pipes stdin" {
  if !real_exec_integration_enabled() {
    return
  }
  let dir = "/tmp/choir-hook-capture-" + @sys.get_pid().to_string()
  assert_true(@sys.create_dir_all(dir))
  let script = dir + "/hook.sh"
  let script_body = "#!/bin/sh\n" +
    "body=$(cat)\n" +
    "if [ \"$body\" != '{\"event\":\"PreToolUse\"}' ]; then exit 2; fi\n" +
    "echo '{\"continue\":true}'\n"
  if !@sys.write_file_sync(script, script_body) {
    fail("write hook script")
  }
  assert_true(@sys.chmod_mode(script, 0o755))
  let stdin_json = "{\"event\":\"PreToolUse\"}"
  let (code, out) = capture_hook_script_merged(script, stdin_json, Some(dir))
  assert_eq(code, 0)
  assert_true(out.contains("continue"))
}

///|
async test "real exec integration: capture_plugin_shell_command pipes stdin" {
  if !real_exec_integration_enabled() {
    return
  }
  let (exit_code, out) = capture_plugin_shell_command(
    "cat", "{\"ok\":true}", 10,
  )
  assert_eq(exit_code, 0)
  assert_eq(out.trim(), "{\"ok\":true}")
}

///|
test "read_agent_pgid parses the recorded pidfile and rejects unsafe values" {
  let seen : Array[String] = []
  let got = read_agent_pgid("/proj", "main.leaf/x", read_file=fn(path) {
    seen.push(path)
    "12345"
  })
  @debug.assert_eq(got, Some(12345))
  @debug.assert_eq(seen, ["/proj/.choir/pids/main.leaf_x"])
  @debug.assert_eq(
    read_agent_pgid("/proj", "main.leaf", read_file=fn(_) { " 777\n" }),
    Some(777),
  )
  // Missing, garbage, and unsafe (<= 1) values must all read as no-handle.
  for raw in ["", "not-a-pid", "0", "1", "-5"] {
    @debug.assert_eq(
      read_agent_pgid("/proj", "main.leaf", read_file=fn(_) { raw }),
      None,
    )
  }
}

///|
test "agent_recorded_process_alive probes the recorded pgid" {
  let probed : Array[Int] = []
  assert_true(
    agent_recorded_process_alive(
      "/proj",
      "main.leaf",
      read_file=fn(_) { "4242" },
      alive=fn(pgid) {
        probed.push(pgid)
        true
      },
    ),
  )
  @debug.assert_eq(probed, [4242])
  assert_false(
    agent_recorded_process_alive(
      "/proj",
      "main.leaf",
      read_file=fn(_) { "" },
      alive=fn(pgid) {
        probed.push(pgid)
        true
      },
    ),
  )
  @debug.assert_eq(probed, [4242])
}

///|
test "process liveness scan resolves dot project and relative workspace" {
  let seen : Array[String] = []
  let alive = agent_process_alive_for_workspace(
    ".",
    ".choir/worktrees/leaf",
    current_dir=fn() { "/repo" },
    realpath=fn(path) {
      seen.push("realpath:" + path)
      None
    },
    list_pids=fn(prefix, cap) {
      seen.push("scan:" + prefix + ":" + cap.to_string())
      if prefix == "/repo/.choir/worktrees/leaf" {
        [42]
      } else {
        []
      }
    },
  )
  assert_true(alive)
  @debug.assert_eq(seen, [
    "realpath:/repo/.choir/worktrees/leaf", "scan:/repo/.choir/worktrees/leaf:16",
  ])
}

///|
test "process liveness scan prefers realpath when available" {
  @debug.assert_eq(
    process_liveness_scan_prefix(
      "/repo",
      ".choir/worktrees/leaf",
      current_dir=fn() { "/ignored" },
      realpath=fn(path) {
        if path == "/repo/.choir/worktrees/leaf" {
          Some("/real/repo/.choir/worktrees/leaf")
        } else {
          None
        }
      },
    ),
    "/real/repo/.choir/worktrees/leaf",
  )
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
test "dev_watchexec_command uses argv hook without sh -c" {
  let cmd = dev_watchexec_command("/usr/bin/watchexec", "/tmp/choir")
  assert_eq(cmd.program, "/usr/bin/watchexec")
  @debug.assert_eq(cmd.args, [
    "-e",
    "mbt,toml",
    "-r",
    "--shell=none",
    "--",
    "/tmp/choir",
    DEV_RELOAD_SUBCOMMAND,
  ])
}

///|
test "dev_entr_find_src_mbt_command matches former pipeline first find" {
  let c = dev_entr_find_src_mbt_command()
  assert_eq(c.program, "find")
  @debug.assert_eq(c.args, ["src", "-name", "*.mbt"])
  @debug.assert_eq(c.workdir, None)
}

///|
test "dev_entr_find_toml_command matches former pipeline second find" {
  let c = dev_entr_find_toml_command()
  assert_eq(c.program, "find")
  @debug.assert_eq(c.args, [".", "-maxdepth", "2", "-name", "*.toml"])
}

///|
test "dev_entr_entr_command is argv entr without sh" {
  let c = dev_entr_entr_command("/usr/bin/entr", "/tmp/choir")
  assert_eq(c.program, "/usr/bin/entr")
  @debug.assert_eq(c.args, ["-r", "/tmp/choir", DEV_RELOAD_SUBCOMMAND])
  assert_false(c.program.contains("/bin/sh"))
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
test "command_with_suppressed_moon_render adds no-render to direct moon build" {
  let cmd = @workspace.Command::{
    program: "moon",
    args: ["build", "--target", "native", "--release"],
    workdir: None,
  }
  @debug.assert_eq(command_with_suppressed_moon_render(cmd).args, [
    "build", "--no-render", "--target", "native", "--release",
  ])
  let target_before_subcommand = @workspace.Command::{
    program: "/usr/bin/moon",
    args: ["--target", "wasm-gc", "test"],
    workdir: None,
  }
  @debug.assert_eq(
    command_with_suppressed_moon_render(target_before_subcommand).args,
    ["--target", "wasm-gc", "test", "--no-render"],
  )
}

///|
test "command_with_suppressed_moon_render rewrites shell moon verify commands" {
  let cmd = @workspace.Command::{
    program: "sh",
    args: ["-lc", "moon check --target native && echo ok && moon test"],
    workdir: Some("/repo"),
  }
  @debug.assert_eq(command_with_suppressed_moon_render(cmd), @workspace.Command::{
    program: "sh",
    args: [
      "-lc", "moon check --target native --no-render && echo ok && moon test --no-render",
    ],
    workdir: Some("/repo"),
  })
}

///|
test "command_with_suppressed_moon_render does not rewrite non-moon commands" {
  let cmd = @workspace.Command::{
    program: "sh",
    args: ["-lc", "echo 'moon test'"],
    workdir: None,
  }
  @debug.assert_eq(command_with_suppressed_moon_render(cmd), cmd)
}

///|
test "plugin_capture_uses_shell detects unquoted compound commands" {
  assert_true(plugin_capture_uses_shell("a && b"))
  assert_false(plugin_capture_uses_shell("choir tool x"))
}

///|
test "plugin_capture_uses_shell does not force shell for metachars only inside quotes" {
  assert_false(plugin_capture_uses_shell("echo \"a && b\""))
  assert_false(plugin_capture_uses_shell("python3 -c \"print(1>2)\""))
}

///|
test "plugin_capture_uses_shell still requires shell for glob and expansion markers" {
  assert_true(plugin_capture_uses_shell("echo *"))
  assert_true(plugin_capture_uses_shell("echo $HOME"))
}

///|
test "plugin_capture_uses_shell requires shell for unquoted subshell parens" {
  assert_true(plugin_capture_uses_shell("( echo hi )"))
}

///|
test "plugin_capture_uses_shell requires shell for env assignment prefix" {
  assert_true(plugin_capture_uses_shell("FOO=bar choir tool x"))
}

///|
test "plugin_capture_uses_shell requires shell when parse fails" {
  assert_true(plugin_capture_uses_shell("echo \""))
}
