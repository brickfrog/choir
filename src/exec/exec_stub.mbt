///|
/// Non-native: `moonbitlang/async/process` is native-only; stubs keep wasm/js type-check clean.
pub fn default_reload_binary_path() -> Result[String, @types.ChoirError] {
  Err(
    @types.ChoirError::workspace_error(
      "reload binary path resolution is native-only",
    ),
  )
}

///|
pub fn reload_binary_path() -> Result[String, @types.ChoirError] {
  default_reload_binary_path()
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
pub async fn capture_harness_probe(
  _spec : @harness.HarnessProbeProcess,
) -> Result[@harness.HarnessProbeCapture, @types.ChoirError] {
  Err(
    @types.ChoirError::transport_error(
      "provider declaration probes require the native target",
    ),
  )
}

///|
pub async fn capture_boxlite_live_evidence(
  _dedicated_root : String,
) -> Result[@sandbox.BoxLiteLiveEvidence, @types.ChoirError] {
  Err(
    @types.ChoirError::transport_error(
      "BoxLite live probes require the native target",
    ),
  )
}

///|
pub async fn capture_claude_synthetic_startup(
  _synthetic_root : String,
  _mcp_executable : String,
  _mcp_args : Array[String],
) -> Result[@harness.HarnessProbeCapture, @types.ChoirError] {
  Err(
    @types.ChoirError::transport_error(
      "Claude synthetic startup probes require the native target",
    ),
  )
}

///|
pub async fn capture_claude_live_startup(
  _dedicated_root : String,
  _mcp_executable : String,
  _mcp_args : Array[String],
) -> Result[@harness.HarnessProbeCapture, @types.ChoirError] {
  Err(
    @types.ChoirError::transport_error(
      "Claude live startup probes require the native target",
    ),
  )
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
pub fn command_with_suppressed_moon_render(
  cmd : @workspace.Command,
) -> @workspace.Command {
  cmd
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
  let native_agy_cache_links = @workspace.run_native_agy_cache_links_command(
    cmd,
  )
  if native_agy_cache_links >= 0 {
    return native_agy_cache_links
  }
  let native_agy_prepare = @workspace.run_native_agy_shared_cache_prepare_command(
    cmd,
  )
  if native_agy_prepare >= 0 {
    return native_agy_prepare
  }
  let native_agy_validate = @workspace.run_native_agy_shared_cache_validate_command(
    cmd,
  )
  if native_agy_validate >= 0 {
    return native_agy_validate
  }
  let native_agy_seed_if_needed = @workspace.run_native_agy_shared_cache_seed_if_needed_command_with_runner(
    cmd,
    fn(_) { (-1, "") },
  )
  if native_agy_seed_if_needed >= 0 {
    return native_agy_seed_if_needed
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
