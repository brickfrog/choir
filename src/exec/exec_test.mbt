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
  assert_eq(cmd.args, [
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
  assert_eq(c.args, ["src", "-name", "*.mbt"])
  @debug.assert_eq(c.workdir, None)
}

///|
test "dev_entr_find_toml_command matches former pipeline second find" {
  let c = dev_entr_find_toml_command()
  assert_eq(c.program, "find")
  assert_eq(c.args, [".", "-maxdepth", "2", "-name", "*.toml"])
}

///|
test "dev_entr_entr_command is argv entr without sh" {
  let c = dev_entr_entr_command("/usr/bin/entr", "/tmp/choir")
  assert_eq(c.program, "/usr/bin/entr")
  assert_eq(c.args, ["-r", "/tmp/choir", DEV_RELOAD_SUBCOMMAND])
  assert_false(c.program.contains("/bin/sh"))
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
