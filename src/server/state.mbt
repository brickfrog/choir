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
fn ensure_audit_gate_state_initialized(project_dir : String) -> Unit {
  let path = @tools.merge_pr_audit_gate_state_path(project_dir)
  if @sys.path_exists(path) {
    return
  }
  let now = @env.now().reinterpret_as_int64() / 1000L
  let body = "{\"enabled_at_unix\":" + now.to_string() + "}\n"
  ignore(@sys.write_file_atomic(path, body))
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
  mutation_gate_reports : Map[
    String,
    @aqueue.Queue[@tools.MutationGateWorkerReport],
  ]
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
) -> ServerState {
  let run_id = init_run_id(config.project_dir)
  // Seed `.choir/audit-gate.json` on server boot if absent. Operators who
  // want a different grandfather boundary should pre-seed the file before
  // starting the server. merge_pr's load_gate_state fails closed if the
  // file is missing/empty/malformed once the server is running; this init
  // is the one explicit moment Choir writes the boundary itself.
  ensure_audit_gate_state_initialized(config.project_dir)
  {
    config,
    registry: @registry.AgentRegistry::new(),
    mutex_registry: @registry.MutexRegistry::new(),
    tool_registry: @tools.ToolRegistry::new(),
    poller: @poller.PollerState::new(),
    kv_store: @kv.KvStore::new(config.project_dir),
    run_id,
    pending_disconnects: {},
    agent_pids: {},
    disconnect_contexts: {},
    delivery_failures: {},
    handoff_delivered: {},
    mutation_gate_reports: {},
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

///|
fn ServerState::mutation_gate_report_queue(
  self : ServerState,
  agent_id : String,
) -> @aqueue.Queue[@tools.MutationGateWorkerReport] {
  match self.mutation_gate_reports.get(agent_id) {
    Some(queue) => queue
    None => {
      let queue = @aqueue.Queue(kind=@aqueue.Kind::Unbounded)
      self.mutation_gate_reports.set(agent_id, queue)
      queue
    }
  }
}

///|
pub fn ServerState::prepare_mutation_gate_report(
  self : ServerState,
  agent_id : String,
) -> Unit {
  ignore(self.mutation_gate_report_queue(agent_id))
}

///|
pub fn ServerState::cleanup_mutation_gate_report(
  self : ServerState,
  agent_id : String,
) -> Unit {
  match self.mutation_gate_reports.get(agent_id) {
    Some(queue) => {
      self.mutation_gate_reports.remove(agent_id)
      ignore(
        queue.try_put({
          message: "mutation gate worker cleaned up without report",
          status: @types.Status::Failure,
        }) catch {
          _ => false
        },
      )
    }
    None => ()
  }
}

///|
pub fn ServerState::capture_mutation_gate_report(
  self : ServerState,
  agent_id : String,
  report : @tools.MutationGateWorkerReport,
) -> Unit {
  match self.mutation_gate_reports.get(agent_id) {
    Some(queue) => ignore(queue.try_put(report) catch { _ => false })
    None => ()
  }
}

///|
pub async fn ServerState::wait_for_mutation_gate_report(
  self : ServerState,
  agent_id : String,
) -> @tools.MutationGateWorkerReport? {
  let queue = self.mutation_gate_report_queue(agent_id)
  let report = queue.get()
  self.mutation_gate_reports.remove(agent_id)
  Some(report)
}
