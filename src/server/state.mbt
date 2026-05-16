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
  pending_disconnect_soft_notified : Map[String, Bool]
  delivery_failures : Map[String, Int]
  handoff_delivered : Map[String, Bool]
  audit_on_file_pr_reports : Map[
    String,
    @aqueue.Queue[@tools.AuditOnFilePrReport],
  ]
  worker_no_handoff_prodded_at : Map[String, Int64]
  worker_no_handoff_stalled_emitted : Map[String, Bool]
  worker_no_handoff_exit_emitted : Map[String, Bool]
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
  {
    config,
    registry: @registry.AgentRegistry::new(),
    mutex_registry: @registry.MutexRegistry::new(),
    tool_registry: @tools.ToolRegistry::new(),
    poller: @poller.PollerState::new(),
    kv_store: @kv.KvStore::new(config.project_dir),
    run_id,
    pending_disconnects: {},
    pending_disconnect_soft_notified: {},
    delivery_failures: {},
    handoff_delivered: {},
    audit_on_file_pr_reports: {},
    worker_no_handoff_prodded_at: {},
    worker_no_handoff_stalled_emitted: {},
    worker_no_handoff_exit_emitted: {},
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
pub fn ServerState::with_pane_watcher(
  self : ServerState,
  pane_watcher : @runtime.PaneWatcher,
) -> ServerState {
  { ..self, pane_watcher, }
}

///|
fn ServerState::audit_on_file_pr_report_queue(
  self : ServerState,
  agent_id : String,
) -> @aqueue.Queue[@tools.AuditOnFilePrReport] {
  match self.audit_on_file_pr_reports.get(agent_id) {
    Some(queue) => queue
    None => {
      let queue = @aqueue.Queue::new(kind=@aqueue.Kind::Unbounded)
      self.audit_on_file_pr_reports.set(agent_id, queue)
      queue
    }
  }
}

///|
pub fn ServerState::capture_audit_on_file_pr_report(
  self : ServerState,
  agent_id : String,
  report : @tools.AuditOnFilePrReport,
) -> Unit {
  match self.audit_on_file_pr_reports.get(agent_id) {
    Some(queue) => ignore(queue.try_put(report) catch { _ => false })
    None => ()
  }
}

///|
pub fn ServerState::cleanup_audit_on_file_pr_report(
  self : ServerState,
  agent_id : String,
) -> Unit {
  match self.audit_on_file_pr_reports.get(agent_id) {
    Some(queue) => {
      self.audit_on_file_pr_reports.remove(agent_id)
      ignore(
        queue.try_put({ message: "", status: @types.Status::Failure }) catch {
          _ => false
        },
      )
    }
    None => ()
  }
}

///|
pub async fn ServerState::wait_for_audit_on_file_pr_report(
  self : ServerState,
  agent_id : String,
) -> @tools.AuditOnFilePrReport? {
  let queue = self.audit_on_file_pr_report_queue(agent_id)
  let report = queue.get()
  self.audit_on_file_pr_reports.remove(agent_id)
  Some(report)
}
