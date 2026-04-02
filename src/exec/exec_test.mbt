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
  assert_eq(got, None)
}

///|
test "resolve_executable_in_path_from_path_var finds sh under /bin when present" {
  let got = resolve_executable_in_path_from_path_var("sh", "/bin")
  assert_eq(got, Some("/bin/sh"))
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
test "dev_entr_watcher_shell_pipeline runs entr with choir argv not sh -c hook" {
  let s = dev_entr_watcher_shell_pipeline("/usr/bin/entr", "/tmp/choir")
  assert_false(s.contains("sh -c"))
  assert_true(s.contains(DEV_RELOAD_SUBCOMMAND))
  assert_true(s.contains("/usr/bin/entr"))
  assert_true(s.contains("/tmp/choir"))
}

///|
test "dev_entr_watcher_shell_command uses argv sh -c without system wrapper" {
  let cmd = dev_entr_watcher_shell_command("/usr/bin/entr", "/tmp/choir")
  assert_eq(cmd.program, "/bin/sh")
  assert_eq(cmd.args.length(), 2)
  assert_eq(cmd.args[0], "-c")
  let inner = cmd.args[1]
  assert_eq(
    inner,
    dev_entr_watcher_shell_pipeline("/usr/bin/entr", "/tmp/choir"),
  )
}
