///|
/// Non-native: `moonbitlang/async/process` is native-only; stubs keep wasm/js type-check clean.
pub fn default_reload_binary_path(project_dir : String) -> String {
  project_dir + "/_build/native/release/build/src/bin/choir/choir.exe"
}

///|
pub fn reload_binary_path(project_dir : String) -> String {
  default_reload_binary_path(project_dir)
}

///|
pub fn hook_xdg_config_home() -> String? {
  None
}

///|
pub fn hook_home() -> String {
  ""
}

///|
pub fn path_entry_exists(_path : String) -> Bool {
  false
}

///|
pub fn read_file(_path : String) -> String {
  ""
}

///|
pub fn validate_replace_self_binary(
  binary_path : String,
) -> Result[Unit, @types.ChoirError] {
  Err(
    @types.ChoirError::workspace_error(
      "replace_self is native-only: " + binary_path,
    ),
  )
}

///|
pub fn replace_self(
  binary_path : String,
  _inherited_uds_fd : Int,
) -> Result[Unit, @types.ChoirError] {
  Err(
    @types.ChoirError::workspace_error(
      "replace_self is native-only: " + binary_path,
    ),
  )
}

///|
pub async fn run_dev_entr_watcher(
  _entr_path : String,
  _choir_exe : String,
) -> Int {
  -1
}

///|
pub async fn capture_command_merged(_cmd : @workspace.Command) -> (Int, String) {
  (-1, "")
}

///|
pub async fn capture_hook_script_merged(
  _hook_path : String,
  _stdin_body : String,
  _cwd : String?,
) -> (Int, String) {
  (-1, "")
}

///|
pub async fn capture_command_stdout(_cmd : @workspace.Command) -> (Int, String) {
  (-1, "")
}

///|
pub async fn capture_command_stdout_with_stderr_on_error(
  _cmd : @workspace.Command,
) -> (Int, String) {
  (-1, "")
}

///|
pub async fn capture_plugin_shell_command(
  _plugin_command : String,
  _request_line : String,
  _timeout_sec : Int,
) -> (Int, String) {
  (-1, "")
}

///|
pub async fn capture_stdout(_program : String, _args : Array[String]) -> String {
  ""
}

///|
pub async fn capture_stdout_with_cwd(
  _program : String,
  _args : Array[String],
  _cwd : String?,
) -> String {
  ""
}

///|
pub async fn run(cmd : @workspace.Command) -> Int {
  let native = @workspace.run_native_choir_file_command(cmd)
  if native >= 0 {
    return native
  }
  let native_rel = @workspace.run_native_workspace_rel_file_command(cmd)
  if native_rel >= 0 {
    return native_rel
  }
  let native_leaf_helpers = @workspace.run_native_leaf_helpers_command(cmd)
  if native_leaf_helpers >= 0 {
    return native_leaf_helpers
  }
  let native_wt_cleanup = @workspace.run_native_worktree_bootstrap_cleanup_command(
    cmd,
  )
  if native_wt_cleanup >= 0 {
    return native_wt_cleanup
  }
  let native_fetch = @workspace.run_native_git_fetch_origin_branch_best_effort_command(
    cmd,
  )
  if native_fetch >= 0 {
    return native_fetch
  }
  let native_seed = @workspace.run_native_worktree_seed_agent_runtime_gitexclude_command(
    cmd,
  )
  if native_seed >= 0 {
    return native_seed
  }
  -1
}

///|
pub async fn run_sequence(cmds : Array[@workspace.Command]) -> Array[Int] {
  let results = []
  for cmd in cmds {
    let status = run(cmd)
    results.push(status)
    if status != 0 {
      return results
    }
  }
  results
}
