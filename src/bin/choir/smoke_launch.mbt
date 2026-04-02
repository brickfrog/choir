///|
/// Path for a one-shot POSIX shell file used to run embedded smoke scripts without `sh -c`.
pub fn smoke_wrapper_script_path() -> String {
  let mut dir = match @sys.getenv("TMPDIR") {
    Some(d) => d.trim().to_string()
    None => ""
  }
  if dir == "" {
    dir = "/tmp"
  }
  let n = dir.length()
  if n > 0 && dir[n - 1] != '/' {
    dir = dir + "/"
  }
  dir + "choir-smoke-wrapper-" + @sys.get_pid().to_string() + ".sh"
}

///|
/// Run the embedded smoke script as `sh /path/to/script <argv...>` (no `-c`), preserving `$1`–`3`
/// for `BIN`, `KEEP_TEMP`, and `REPO` inside the script bodies.
pub fn smoke_shell_launch_command(
  wrapper_path : String,
  self_exe : String,
  keep_temp : String,
  repo_dir : String,
) -> @workspace.Command {
  {
    program: "sh",
    args: [wrapper_path, self_exe, keep_temp, repo_dir],
    workdir: None,
  }
}

///|
test "smoke shell launch uses script file not sh -c" {
  let cmd = smoke_shell_launch_command(
    "/tmp/foo.sh", "/bin/choir", "0", "/repo",
  )
  assert_eq(cmd.program, "sh")
  assert_eq(cmd.args, ["/tmp/foo.sh", "/bin/choir", "0", "/repo"])
  assert_false(cmd.args.contains("-c"))
}
