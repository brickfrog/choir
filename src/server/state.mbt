///|
/// Shared server state, passed to all tool handlers.
pub struct ServerState {
  config : @types.Config
  registry : @registry.AgentRegistry
  mutex_registry : @registry.MutexRegistry
  tool_registry : @tools.ToolRegistry
  poller : @poller.PollerState
  run_id : String
  pending_disconnects : Map[String, Int64]
  pane_watchers : Map[String, Int64] // agent_id -> last_change_at (unix sec)
  pane_hashes : Map[String, Int] // agent_id -> hash of last screen dump
  subscribe_pids : Map[String, Int] // agent_id -> PID of zellij subscribe process
}

///|
#borrow(cmd)
extern "C" fn c_system(cmd : Bytes) -> Int = "system"

///|
fn string_to_null_terminated_bytes(s : String) -> Bytes {
  let b = @utf8.encode(s)
  let len = b.length()
  let result = FixedArray::make(len + 1, (0 : Byte))
  for i = 0; i < len; i = i + 1 {
    result[i] = b[i]
  }
  result[len] = (0 : Byte)
  result.unsafe_reinterpret_as_bytes()
}

///|
fn persist_run_id(project_dir : String, run_id : String) -> Unit {
  let exo_dir = project_dir + "/.choir"
  let path = exo_dir + "/run_id"
  let script = "mkdir -p " +
    @exec.quote(exo_dir) +
    " && printf '%s' " +
    @exec.quote(run_id) +
    " > " +
    @exec.quote(path)
  ignore(
    c_system(string_to_null_terminated_bytes("sh -c " + @exec.quote(script))),
  )
}

///|
fn normalize_run_id(content : String) -> String? {
  let run_id = content.trim().to_string()
  if run_id == "" {
    None
  } else {
    Some(run_id)
  }
}

///|
fn init_run_id(project_dir : String) -> String {
  let run_id_path = project_dir + "/.choir/run_id"
  match normalize_run_id(@sys.read_file(run_id_path)) {
    Some(existing) => existing
    None => {
      let generated = @poller.now_sec().to_string()
      persist_run_id(project_dir, generated)
      generated
    }
  }
}

///|
/// Create initial server state from config.
pub fn ServerState::new(config : @types.Config) -> ServerState {
  let run_id = init_run_id(config.project_dir)
  {
    config,
    registry: @registry.AgentRegistry::new(),
    mutex_registry: @registry.MutexRegistry::new(),
    tool_registry: @tools.ToolRegistry::new(),
    poller: @poller.PollerState::new(),
    run_id,
    pending_disconnects: {},
    pane_watchers: {},
    pane_hashes: {},
    subscribe_pids: {},
  }
}
