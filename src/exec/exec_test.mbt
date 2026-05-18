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

///|
test "replace_self returns error for missing binary" {
  let missing = "/tmp/choir-missing-reload-binary-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.rm_rf(missing))
  match @exec.replace_self(missing, 4) {
    Ok(_) => fail("expected missing binary to fail before exec")
    Err(e) => {
      let message = e.message()
      assert_true(message.contains("replace_self failed for " + missing))
      assert_true(message.contains("errno="))
    }
  }
}
