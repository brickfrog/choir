///|
fn default_append_file_sync(path : String, content : String) -> Bool {
  @sys.append_file_sync(path, content)
}

///|
fn default_read_file(path : String) -> String {
  @sys.read_file(path)
}

///|
fn default_write_file_atomic(path : String, content : String) -> Bool {
  @sys.write_file_atomic(path, content)
}

///|
fn default_path_exists(path : String) -> Bool {
  @sys.path_exists(path)
}

///|
fn ensure_audit_gate_state_initialized(
  project_dir : String,
  path_exists : (String) -> Bool,
  write_file_atomic : (String, String) -> Bool,
  now_unix_sec : () -> Int64,
) -> Result[Unit, @types.ChoirError] {
  let path = @tools.merge_pr_audit_gate_state_path(project_dir)
  if path_exists(path) {
    return Ok(())
  }
  let body = "{\"enabled_at_unix\":" + now_unix_sec().to_string() + "}\n"
  if write_file_atomic(path, body) {
    Ok(())
  } else {
    Err(
      @types.ChoirError::workspace_error(
        "server boot: could not seed audit receipt gate state at " +
        path +
        "; refusing to start without a durable grandfather boundary",
      ),
    )
  }
}

///|
fn load_poller_state_for_boot(
  project_dir : String,
  path_exists : (String) -> Bool,
  read_file : (String) -> String,
) -> @poller.PollerState {
  let path = @poller.poller_state_path(project_dir)
  if !path_exists(path) {
    return @poller.PollerState::new()
  }
  let content = read_file(path)
  if content == "" {
    return @poller.PollerState::new()
  }
  @poller.parse_poller_state_json(content) catch {
    _ => @poller.PollerState::new()
  }
}

///|
fn seed_untracked_merge_boundary_if_needed(
  persisted_poller : @poller.PollerState,
  project_dir : String,
  write_file_atomic : (String, String) -> Bool,
  now_unix_sec : () -> Int64,
) -> Result[Unit, @types.ChoirError] {
  if persisted_poller.untracked_merge_boundary_unix != 0L {
    return Ok(())
  }
  persisted_poller.set_untracked_merge_boundary_unix(now_unix_sec())
  if persisted_poller.write_state_file(
      project_dir,
      write_file=write_file_atomic,
    ) {
    Ok(())
  } else {
    Err(
      @types.ChoirError::workspace_error(
        "server boot: could not seed untracked merge boundary at " +
        @poller.poller_state_path(project_dir) +
        "; refusing to start without a durable restart boundary",
      ),
    )
  }
}

///|
pub(all) struct DisconnectContext {
  connected_sec : Int64?
  last_request_name : String?
} derive(Debug, Eq)

///|
/// Shared server state, passed to all tool handlers.
pub struct ServerState {
  config : @types.Config
  registry : @registry.AgentRegistry
  mutex_registry : @registry.MutexRegistry
  tool_registry : @tools.ToolRegistry
  poller : @poller.PollerState
  kv_store : @kv.KvStore
  run_id : String
  pending_disconnects : Map[String, Int64]
  agent_pids : Map[String, Int]
  disconnect_contexts : Map[String, DisconnectContext]
  delivery_failures : Map[String, Int]
  handoff_delivered : Map[String, Bool]
  agent_task_contracts : Map[String, @types.TaskContract]
  leaf_tdd_phases : Map[String, @types.LeafTddPhase]
  worker_no_handoff_prodded_at : Map[String, Int64]
  worker_no_handoff_stalled_emitted : Map[String, Bool]
  worker_no_handoff_exit_emitted : Map[String, Bool]
  idle_agent_warned_at_70 : Map[String, Bool]
  list_panes_cache : Map[String, @tools.CachedListPanesSnapshot]
  recent_poller_event_emissions : Map[String, Map[String, RecentEmission]]
  goal_judge : GoalJudgeState
  pane_watcher : @runtime.PaneWatcher
  recovery_provider : @runtime.RecoveryProvider
  append_file : (String, String) -> Bool
  read_file : (String) -> String
  write_file_atomic : (String, String) -> Bool
  delete_file : (String) -> Bool
}

///|
fn persist_run_id(project_dir : String, run_id : String) -> Unit {
  let choir_dir = project_dir + "/.choir"
  let path = choir_dir + "/run_id"
  ignore(@sys.create_dir_all(choir_dir))
  ignore(@sys.write_file_sync(path, run_id))
}

///|
fn normalize_run_id(content : String) -> String? {
  let run_id = content.trim().to_owned()
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
      let generated = @poller.now_sec().to_string() +
        "-" +
        @sys.get_pid().to_string()
      persist_run_id(project_dir, generated)
      generated
    }
  }
}

///|
/// Create initial server state from config.
pub fn ServerState::new(
  config : @types.Config,
  recovery_provider : @runtime.RecoveryProvider,
  path_exists? : (String) -> Bool = default_path_exists,
  write_file_atomic? : (String, String) -> Bool = default_write_file_atomic,
  now_unix_sec? : () -> Int64 = fn() {
    @env.now().reinterpret_as_int64() / 1000L
  },
  read_file? : (String) -> String = default_read_file,
) -> ServerState {
  let run_id = init_run_id(config.project_dir)
  // Seed `.choir/audit-gate.json` on server boot if absent. Operators who
  // want a different grandfather boundary should pre-seed the file before
  // starting the server. merge_pr's load_gate_state fails closed if the
  // file is missing/empty/malformed once the server is running; this init
  // is the one explicit moment Choir writes the boundary itself. A write
  // failure here means the gate cannot be persisted at all — abort boot
  // rather than starting a server whose merge gate has no anchor.
  match
    ensure_audit_gate_state_initialized(
      config.project_dir,
      path_exists,
      write_file_atomic,
      now_unix_sec,
    ) {
    Ok(_) => ()
    Err(e) => abort(e.message())
  }
  let persisted_poller = load_poller_state_for_boot(
    config.project_dir,
    path_exists,
    read_file,
  )
  match
    seed_untracked_merge_boundary_if_needed(
      persisted_poller,
      config.project_dir,
      write_file_atomic,
      now_unix_sec,
    ) {
    Ok(_) => ()
    Err(e) => abort(e.message())
  }
  let poller = @poller.PollerState::new()
  poller.set_untracked_merge_boundary_unix(
    persisted_poller.untracked_merge_boundary_unix,
  )
  {
    config,
    registry: @registry.AgentRegistry::new(),
    mutex_registry: @registry.MutexRegistry::new(),
    tool_registry: @tools.ToolRegistry::new(),
    poller,
    kv_store: @kv.KvStore::new(config.project_dir),
    run_id,
    pending_disconnects: {},
    agent_pids: {},
    disconnect_contexts: {},
    delivery_failures: {},
    handoff_delivered: {},
    agent_task_contracts: {},
    leaf_tdd_phases: {},
    worker_no_handoff_prodded_at: {},
    worker_no_handoff_stalled_emitted: {},
    worker_no_handoff_exit_emitted: {},
    idle_agent_warned_at_70: {},
    list_panes_cache: {},
    recent_poller_event_emissions: {},
    goal_judge: GoalJudgeState::new(),
    pane_watcher: @runtime.PaneWatcher::new(),
    recovery_provider,
    append_file: default_append_file_sync,
    read_file: default_read_file,
    write_file_atomic: default_write_file_atomic,
    delete_file: @exec.delete_file_sync,
  }
}

///|
pub fn ServerState::register_agent_pid(
  self : ServerState,
  agent_id : String,
  pid : Int,
) -> Unit {
  self.agent_pids.set(agent_id, pid)
}

///|
pub fn ServerState::forget_agent_pid(
  self : ServerState,
  agent_id : String,
) -> Int? {
  match self.agent_pids.get(agent_id) {
    Some(pid) => {
      self.agent_pids.remove(agent_id)
      Some(pid)
    }
    None => None
  }
}

///|
pub fn ServerState::leaf_tdd_phase_for_agent(
  self : ServerState,
  agent_id : String,
) -> @types.LeafTddPhase? {
  self.leaf_tdd_phases.get(agent_id)
}

///|
pub fn ServerState::leaf_tdd_state_for_agent(
  self : ServerState,
  agent_id : String,
) -> @types.LeafTddState? {
  match self.leaf_tdd_phases.get(agent_id) {
    Some(phase) => Some({ phase, })
    None => None
  }
}

///|
pub fn ServerState::record_leaf_tdd_state(
  self : ServerState,
  agent_id : String,
  state : @types.LeafTddState,
) -> Unit {
  self.leaf_tdd_phases.set(agent_id, state.phase)
}

///|
pub fn ServerState::record_agent_task_contract(
  self : ServerState,
  agent_id : String,
  contract : @types.TaskContract?,
) -> Unit {
  if self.agent_task_contracts.contains(agent_id) {
    return
  }
  match contract {
    Some(value) => self.agent_task_contracts.set(agent_id, value)
    None => ()
  }
}

///|
pub fn ServerState::task_contract_for_agent(
  self : ServerState,
  agent_id : String,
) -> @types.TaskContract? {
  self.agent_task_contracts.get(agent_id)
}

///|
pub fn ServerState::with_pane_watcher(
  self : ServerState,
  pane_watcher : @runtime.PaneWatcher,
) -> ServerState {
  { ..self, pane_watcher, }
}
