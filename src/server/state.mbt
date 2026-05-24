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
pub(all) struct AuditProgress {
  cycles_so_far : Int
  last_findings_count : Int?
  last_receipt_path : String?
  last_cycle_at_ms : Int64?
  exhausted : Bool
} derive(Debug, Eq)

///|
pub(all) struct DisconnectContext {
  connected_sec : Int64?
  last_request_name : String?
} derive(Debug, Eq)

///|
pub(all) struct AuditPrCommentTask {
  run : async () -> Unit
}

///|
fn audit_progress_report_receipt_path(message : String) -> String? {
  let marker = ".choir/audit-receipts/"
  match message.find(marker) {
    None => None
    Some(start) => {
      let mut end = start
      while end < message.length() {
        let ch = message[end]
        if ch == ' ' ||
          ch == '\n' ||
          ch == '\r' ||
          ch == '\t' ||
          ch == ')' ||
          ch == ']' ||
          ch == '"' ||
          ch == '\'' {
          break
        }
        end = end + 1
      }
      if end > start {
        Some(message[start:end].to_owned())
      } else {
        None
      }
    }
  }
}

///|
fn audit_progress_short_sha_is_valid(value : String) -> Bool {
  if value.length() < 7 || value.length() > 12 {
    return false
  }
  for i = 0; i < value.length(); i = i + 1 {
    let c = value[i]
    let is_digit = c >= '0' && c <= '9'
    let is_lower_hex = c >= 'a' && c <= 'f'
    if !is_digit && !is_lower_hex {
      return false
    }
  }
  true
}

///|
fn audit_progress_short_sha_from_worker_id(agent_id : String) -> String? {
  let marker = "audit-on-file-pr-"
  match agent_id.find(marker) {
    None => None
    Some(marker_start) => {
      let sha_start = marker_start + marker.length()
      let mut sha_end = sha_start
      while sha_end < agent_id.length() && agent_id[sha_end] != '-' {
        sha_end = sha_end + 1
      }
      let token = agent_id[sha_start:sha_end].to_owned()
      if audit_progress_short_sha_is_valid(token) {
        Some(token)
      } else {
        None
      }
    }
  }
}

///|
fn audit_progress_receipt_path_from_worker_id(agent_id : String) -> String? {
  match audit_progress_short_sha_from_worker_id(agent_id) {
    Some(short_sha) => Some(".choir/audit-receipts/" + short_sha + ".json")
    None => None
  }
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
  agent_pids : Map[String, Int]
  disconnect_contexts : Map[String, DisconnectContext]
  delivery_failures : Map[String, Int]
  handoff_delivered : Map[String, Bool]
  audit_on_file_pr_reports : Map[
    String,
    @aqueue.Queue[@tools.AuditOnFilePrReport],
  ]
  mutation_gate_reports : Map[
    String,
    @aqueue.Queue[@tools.MutationGateWorkerReport],
  ]
  audit_pr_comment_tasks : @aqueue.Queue[AuditPrCommentTask]
  audit_cycle_counts : Map[String, Int]
  audit_progress : Map[String, AuditProgress]
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
    audit_on_file_pr_reports: {},
    mutation_gate_reports: {},
    audit_pr_comment_tasks: @aqueue.Queue(kind=@aqueue.Kind::Unbounded),
    audit_cycle_counts: {},
    audit_progress: {},
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
fn ServerState::audit_on_file_pr_report_queue(
  self : ServerState,
  agent_id : String,
) -> @aqueue.Queue[@tools.AuditOnFilePrReport] {
  match self.audit_on_file_pr_reports.get(agent_id) {
    Some(queue) => queue
    None => {
      let queue = @aqueue.Queue(kind=@aqueue.Kind::Unbounded)
      self.audit_on_file_pr_reports.set(agent_id, queue)
      queue
    }
  }
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
pub(all) struct AuditDigestContext {
  leaf_agent_id : String
  parent_id : String
  pr_number : Int?
  branch : String
  receipt_path : String
  cycle : Int
  findings_count : Int
  exhausted : Bool
} derive(Debug, Eq)

///|
pub fn audit_worker_short_sha(agent_id : String) -> String? {
  let agent_slug = @phase.extract_slug(agent_id)
  let prefix = @tools.audit_on_file_pr_internal_caller_id + "-"
  if !agent_slug.has_prefix(prefix) {
    return None
  }
  let rest = agent_slug[prefix.length():].to_owned()
  match rest.find("-") {
    Some(idx) => {
      let short = rest[0:idx].to_owned()
      if short == "" {
        None
      } else {
        Some(short)
      }
    }
    None => None
  }
}

///|
fn ServerState::tracked_pr_for_agent_id(
  self : ServerState,
  agent_id : String,
) -> @poller.TrackedPR? {
  for tracked in self.poller.tracked.values() {
    if tracked.agent_id == agent_id {
      return Some(tracked)
    }
  }
  None
}

///|
fn ServerState::tracked_pr_for_audit_capture(
  self : ServerState,
  agent_id : String,
) -> @poller.TrackedPR? {
  match self.tracked_pr_for_agent_id(agent_id) {
    Some(tracked) => return Some(tracked)
    None => ()
  }
  match self.registry.get_opt(agent_id) {
    Some(agent) =>
      match agent.parent {
        Some(parent_id) =>
          match self.tracked_pr_for_agent_id(parent_id) {
            Some(tracked) => return Some(tracked)
            None => ()
          }
        _ => ()
      }
    None => ()
  }
  None
}

///|
fn AuditDigestContext::pr_label(self : AuditDigestContext) -> String {
  match self.pr_number {
    Some(number) => number.to_string()
    None => "pending"
  }
}

///|
fn AuditDigestContext::branch_or_unknown(self : AuditDigestContext) -> String {
  if self.branch == "" {
    "unknown"
  } else {
    self.branch
  }
}

///|
fn audit_receipt_path_for_tracked(
  tracked : @poller.TrackedPR,
  agent_id : String,
) -> String? {
  if tracked.last_sha != "" {
    Some(@tools.file_pr_audit_receipt_path_for_head(tracked.last_sha))
  } else {
    match audit_worker_short_sha(agent_id) {
      Some(short_sha) =>
        Some(@tools.file_pr_audit_receipt_path_for_head(short_sha))
      None => None
    }
  }
}

///|
pub fn ServerState::audit_digest_context(
  self : ServerState,
  agent_id : String,
  report : @tools.AuditOnFilePrReport,
) -> AuditDigestContext? {
  if report.status != @types.Status::Success {
    return None
  }
  let tracked = self.tracked_pr_for_audit_capture(agent_id)
  let leaf_agent_id = match tracked {
    Some(tracked) => tracked.agent_id
    None => agent_id
  }
  let parent_agent_id = match tracked {
    Some(_) => leaf_agent_id
    None =>
      match self.registry.get_opt(agent_id) {
        Some(agent) =>
          match agent.parent {
            Some(value) => value
            None => leaf_agent_id
          }
        None => leaf_agent_id
      }
  }
  let branch = match tracked {
    Some(tracked) => tracked.branch
    None =>
      match self.registry.get_opt(parent_agent_id) {
        Some(agent) => agent.branch
        None => "unknown"
      }
  }
  let parent_id = match self.registry.get_opt(leaf_agent_id) {
    Some(agent) =>
      match agent.parent {
        Some(value) => value
        None => return None
      }
    None => return None
  }
  let receipt_path = match tracked {
    Some(found) =>
      match audit_receipt_path_for_tracked(found, agent_id) {
        Some(value) => value
        None =>
          match audit_progress_receipt_path_from_worker_id(agent_id) {
            Some(value) => value
            None => return None
          }
      }
    None =>
      match audit_progress_receipt_path_from_worker_id(agent_id) {
        Some(value) => value
        None => return None
      }
  }
  let raw_cycle = self.audit_cycle_count_for_agent(leaf_agent_id)
  let cycle = if raw_cycle <= 0 { 1 } else { raw_cycle }
  let findings_count = @tools.parse_findings_count(report.message)
  let exhausted = findings_count > 0 &&
    self.config.audit_max_rounds > 0 &&
    cycle >= self.config.audit_max_rounds
  Some({
    leaf_agent_id,
    parent_id,
    pr_number: match tracked {
      Some(tracked) => Some(tracked.pr_number)
      None => None
    },
    branch,
    receipt_path,
    cycle,
    findings_count,
    exhausted,
  })
}

///|
pub fn audit_digest_body(
  ctx : AuditDigestContext,
  findings_text : String,
) -> String {
  if ctx.exhausted {
    tl_exhaustion_notification_body(ctx, findings_text)
  } else {
    audit_pr_comment_body(ctx, findings_text)
  }
}

///|
pub fn tl_exhaustion_notification_body(
  ctx : AuditDigestContext,
  findings_text : String,
) -> String {
  let pr_label = ctx.pr_label()
  "[AUDIT LOOP EXHAUSTED] " +
  ctx.cycle.to_string() +
  " cycles, " +
  ctx.findings_count.to_string() +
  " findings remain on PR #" +
  pr_label +
  " — TL decision required\nbranch: " +
  ctx.branch_or_unknown() +
  "\nreceipt: " +
  ctx.receipt_path +
  "\n\n" +
  findings_text
}

///|
pub fn audit_pr_comment_body(
  ctx : AuditDigestContext,
  findings_text : String,
) -> String {
  let pr_label = ctx.pr_label()
  let tag = if ctx.exhausted {
    "[AUDIT cycle " + ctx.cycle.to_string() + " — LOOP EXHAUSTED]"
  } else {
    "[AUDIT cycle " + ctx.cycle.to_string() + "]"
  }
  let tl_suffix = if ctx.exhausted { " — TL decision required" } else { "" }
  tag +
  " PR #" +
  pr_label +
  " on " +
  ctx.branch_or_unknown() +
  tl_suffix +
  "\nfindings_count=" +
  ctx.findings_count.to_string() +
  "\nreceipt: " +
  ctx.receipt_path +
  "\n\n" +
  findings_text
}

///|
pub async fn ServerState::notify_parent_audit_started(
  self : ServerState,
  tracked_agent_id : String,
  cycle_number : Int,
  pr_number? : Int? = None,
  runner? : async (Array[@workspace.Command]) -> Array[Int] = @exec.run_sequence,
  sleep_fn? : async (Int) -> Unit = @async.sleep,
  send_message? : async (@types.Agent, String, String, @types.Status) -> Unit = async fn(
    parent,
    sender_id,
    body,
    status,
  ) {
    let plan = @tools.send_message_plan(
      parent.agent_id.to_string(),
      sender_id,
      body,
      status,
      Some(Ok(parent)),
    )
    ignore(
      @tools.interpret_send_message(
        plan,
        self.config.project_dir,
        runner,
        sleep_fn~,
      ),
    )
  },
) -> Unit {
  match self.registry.get_opt(tracked_agent_id) {
    Some(agent) =>
      match agent.parent {
        Some(parent_id) =>
          match self.registry.get_opt(parent_id) {
            Some(parent) =>
              send_message(
                parent,
                tracked_agent_id,
                @tools.audit_started_notification_body(cycle_number, pr_number~),
                @types.Status::Info,
              )
            None =>
              @moontrace.warn("audit start notification parent missing", fields=[
                @moontrace.field("agent_id", tracked_agent_id),
                @moontrace.field("parent_id", parent_id),
              ])
          }
        None =>
          @moontrace.warn("audit start notification leaf parent missing", fields=[
            @moontrace.field("agent_id", tracked_agent_id),
          ])
      }
    None =>
      @moontrace.warn("audit start notification agent missing", fields=[
        @moontrace.field("agent_id", tracked_agent_id),
      ])
  }
}

///|
pub async fn ServerState::notify_parent_about_audit(
  self : ServerState,
  agent_id : String,
  report : @tools.AuditOnFilePrReport,
  runner? : async (Array[@workspace.Command]) -> Array[Int] = @exec.run_sequence,
  sleep_fn? : async (Int) -> Unit = @async.sleep,
  send_message? : async (@types.Agent, String, String, @types.Status) -> Unit = async fn(
    parent,
    sender_id,
    body,
    status,
  ) {
    let plan = @tools.send_message_plan(
      parent.agent_id.to_string(),
      sender_id,
      body,
      status,
      Some(Ok(parent)),
    )
    ignore(
      @tools.interpret_send_message(
        plan,
        self.config.project_dir,
        runner,
        sleep_fn~,
      ),
    )
  },
) -> Unit {
  match self.audit_digest_context(agent_id, report) {
    Some(ctx) =>
      match self.registry.get_opt(ctx.parent_id) {
        Some(parent) =>
          send_message(
            parent,
            ctx.leaf_agent_id,
            audit_digest_body(ctx, report.message),
            @types.Status::Info,
          )
        None =>
          @moontrace.warn("audit notification parent missing", fields=[
            @moontrace.field("agent_id", ctx.leaf_agent_id),
            @moontrace.field("parent_id", ctx.parent_id),
          ])
      }
    None => ()
  }
}

///|
fn ServerState::enqueue_audit_pr_comment_task(
  self : ServerState,
  task : AuditPrCommentTask,
) -> Bool {
  self.audit_pr_comment_tasks.try_put(task) catch {
    e => {
      @moontrace.warn("audit PR comment enqueue failed", fields=[
        @moontrace.field("error", e.to_string()),
      ])
      false
    }
  }
}

///|
pub async fn ServerState::run_next_audit_pr_comment_task(
  self : ServerState,
) -> Bool {
  let maybe_task = self.audit_pr_comment_tasks.try_get() catch {
    e => {
      @moontrace.warn("audit PR comment dequeue failed", fields=[
        @moontrace.field("error", e.to_string()),
      ])
      None
    }
  }
  match maybe_task {
    Some(task) => {
      (task.run)() catch {
        e =>
          @moontrace.warn("audit PR comment task failed", fields=[
            @moontrace.field("error", e.to_string()),
          ])
      }
      true
    }
    None => false
  }
}

///|
pub async fn ServerState::run_audit_pr_comment_task_loop(
  self : ServerState,
) -> Unit {
  for ;; {
    let task = self.audit_pr_comment_tasks.get()
    (task.run)() catch {
      e =>
        @moontrace.warn("audit PR comment task failed", fields=[
          @moontrace.field("error", e.to_string()),
        ])
    }
  }
}

///|
pub fn ServerState::post_audit_pr_comment(
  self : ServerState,
  agent_id : String,
  report : @tools.AuditOnFilePrReport,
  capture? : async (@workspace.Command) -> (Int, String) = @exec.capture_command_merged,
  post_comment? : async (Int, String) -> Result[Unit, @types.ChoirError] = async fn(
    pr_number,
    body,
  ) {
    @poller.gh_pr_comment(pr_number, body, self.config.project_dir, capture~)
  },
) -> Unit {
  match self.audit_digest_context(agent_id, report) {
    Some(ctx) => {
      let body = audit_pr_comment_body(ctx, report.message)
      match ctx.pr_number {
        Some(pr_number) =>
          ignore(
            self.enqueue_audit_pr_comment_task({
              run: async fn() {
                let pr_number = pr_number
                try {
                  match post_comment(pr_number, body) {
                    Ok(_) => ()
                    Err(e) =>
                      @moontrace.warn("audit PR comment failed", fields=[
                        @moontrace.field("agent_id", ctx.leaf_agent_id),
                        @moontrace.field("pr_number", ctx.pr_label()),
                        @moontrace.field("error", e.message()),
                      ])
                  }
                } catch {
                  e =>
                    @moontrace.warn("audit PR comment failed", fields=[
                      @moontrace.field("agent_id", ctx.leaf_agent_id),
                      @moontrace.field("pr_number", ctx.pr_label()),
                      @moontrace.field("error", e.to_string()),
                    ])
                }
              },
            }),
          )
        None => ()
      }
    }
    None => ()
  }
}

///|
pub async fn ServerState::capture_audit_on_file_pr_report(
  self : ServerState,
  agent_id : String,
  report : @tools.AuditOnFilePrReport,
  runner? : async (Array[@workspace.Command]) -> Array[Int] = @exec.run_sequence,
  capture? : async (@workspace.Command) -> (Int, String) = @exec.capture_command_merged,
  sleep_fn? : async (Int) -> Unit = @async.sleep,
) -> Unit {
  self.capture_audit_progress(agent_id, report)
  match self.audit_on_file_pr_reports.get(agent_id) {
    Some(queue) => ignore(queue.try_put(report) catch { _ => false })
    None => ()
  }
  self.notify_parent_about_audit(agent_id, report, runner~, sleep_fn~)
  self.post_audit_pr_comment(agent_id, report, capture~)
}

///|
fn ServerState::audit_progress_agent_id_for_capture(
  self : ServerState,
  agent_id : String,
) -> String? {
  match self.tracked_pr_for_agent_id(agent_id) {
    Some(tracked) => return Some(tracked.agent_id)
    None => ()
  }
  match self.registry.get_opt(agent_id) {
    Some(agent) =>
      match agent.parent {
        Some(parent) =>
          match self.tracked_pr_for_agent_id(parent) {
            Some(_) => return Some(parent)
            None => ()
          }
        None => ()
      }
    None => ()
  }
  None
}

///|
fn ServerState::capture_audit_progress(
  self : ServerState,
  agent_id : String,
  report : @tools.AuditOnFilePrReport,
) -> Unit {
  match self.audit_progress_agent_id_for_capture(agent_id) {
    Some(tracked_agent_id) => {
      let exhausted = match self.audit_digest_context(agent_id, report) {
        Some(ctx) => ctx.exhausted
        None => false
      }
      self.update_audit_progress(
        tracked_agent_id,
        report,
        receipt_path=audit_progress_receipt_path_from_worker_id(agent_id),
        exhausted~,
      )
    }
    None => ()
  }
}

///|
pub fn ServerState::update_audit_progress(
  self : ServerState,
  agent_id : String,
  report : @tools.AuditOnFilePrReport,
  receipt_path? : String? = None,
  exhausted? : Bool = false,
  now_ms? : Int64 = @env.now().reinterpret_as_int64(),
) -> Unit {
  let previous = self.audit_progress_for_agent(agent_id)
  let previous_cycles = match previous {
    Some(progress) => progress.cycles_so_far
    None => 0
  }
  let recorded_cycles = self.audit_cycle_count_for_agent(agent_id)
  let cycles_so_far = if recorded_cycles > previous_cycles {
    recorded_cycles
  } else {
    previous_cycles + 1
  }
  let (last_findings_count, last_receipt_path) = if report.status ==
    @types.Status::Success {
    (
      Some(@tools.parse_findings_count(report.message)),
      match receipt_path {
        Some(path) => Some(path)
        None =>
          match audit_progress_report_receipt_path(report.message) {
            Some(path) => Some(path)
            None => audit_progress_receipt_path_from_worker_id(agent_id)
          }
      },
    )
  } else {
    (None, None)
  }
  self.audit_progress.set(agent_id, {
    cycles_so_far,
    last_findings_count,
    last_receipt_path,
    last_cycle_at_ms: Some(now_ms),
    exhausted,
  })
}

///|
pub fn ServerState::audit_progress_for_agent(
  self : ServerState,
  agent_id : String,
) -> AuditProgress? {
  self.audit_progress.get(agent_id)
}

///|
pub fn ServerState::clear_audit_progress_for_agent(
  self : ServerState,
  agent_id : String,
) -> Unit {
  self.audit_progress.remove(agent_id)
}

///|
pub fn ServerState::record_audit_cycle_for_agent(
  self : ServerState,
  agent_id : String,
) -> Int {
  let next = self.audit_cycle_count_for_agent(agent_id) + 1
  self.audit_cycle_counts.set(agent_id, next)
  next
}

///|
pub fn ServerState::audit_cycle_count_for_agent(
  self : ServerState,
  agent_id : String,
) -> Int {
  self.audit_cycle_counts.get(agent_id).unwrap_or(0)
}

///|
pub fn ServerState::clear_audit_cycle_count_for_agent(
  self : ServerState,
  agent_id : String,
) -> Unit {
  self.audit_cycle_counts.remove(agent_id)
}

///|
pub fn ServerState::prepare_audit_on_file_pr_report(
  self : ServerState,
  agent_id : String,
) -> Unit {
  ignore(self.audit_on_file_pr_report_queue(agent_id))
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
