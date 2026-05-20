///|
/// Register a pane for idle watchdog monitoring.
/// Starts a `zellij subscribe` process that streams pane viewport updates
/// to a snapshot file, replacing the old dump-screen polling approach.
pub fn ServerState::watch_pane(self : ServerState, agent_id : String) -> Unit {
  let agent = self.registry.get(agent_id) catch { _ => return }
  let target = match agent.terminal_target {
    Some(t) => t
    None => return
  }
  self.pane_watcher.watch_pane(agent_id, target, @poller.now_sec())
}

///|
/// Stop the zellij subscribe process for an agent and clean up state.
fn ServerState::stop_subscribe(self : ServerState, agent_id : String) -> Unit {
  self.pane_watcher.stop_subscribe(agent_id)
}

///|
fn ServerState::current_lifecycle(
  self : ServerState,
  agent_id : String,
) -> @phase.AgentLifecycle {
  try self.registry.get(agent_id) catch {
    _ =>
      match @phase.read_lifecycle(self.config.project_dir, agent_id) {
        Some(lifecycle) => lifecycle
        None => @phase.lifecycle_for_role(agent_id, @types.Role::Dev)
      }
  } noraise {
    agent =>
      @phase.read_or_default_lifecycle(
        self.config.project_dir,
        agent_id,
        agent.role,
      )
  }
}

///|
pub fn ServerState::transfer_leaf_ownership(
  self : ServerState,
  from_agent_id : String,
  to_agent_id : String,
) -> Int raise @types.ChoirError {
  if from_agent_id == to_agent_id {
    return 0
  }
  let from_agent = self.registry.get(from_agent_id)
  let to_agent = self.registry.get(to_agent_id)
  if from_agent.parent != to_agent.parent {
    raise @types.ChoirError::validation_error(
      "cannot transfer ownership across different parents",
    )
  }
  if from_agent.role != to_agent.role {
    raise @types.ChoirError::validation_error(
      "cannot transfer ownership across different roles",
    )
  }
  match from_agent.role {
    @types.Role::Dev | @types.Role::Worker => ()
    _ =>
      raise @types.ChoirError::validation_error(
        "ownership transfer only supports leaf roles",
      )
  }
  let transferred = self.poller.transfer_owner(
    from_agent_id,
    to_agent_id,
    to_agent.branch,
    @workspace.parent_branch(to_agent.branch).unwrap_or(""),
  )
  let from_lifecycle = self.current_lifecycle(from_agent_id)
  let to_lifecycle = self.current_lifecycle(to_agent_id)
  let workflow = match (from_lifecycle.workflow, to_lifecycle.workflow) {
    (@phase.WorkflowState::Dev(from_dev), @phase.WorkflowState::Dev(_)) =>
      @phase.WorkflowState::Dev(from_dev)
    (@phase.WorkflowState::Worker(from_worker), @phase.WorkflowState::Worker(_)) =>
      @phase.WorkflowState::Worker(from_worker)
    _ => to_lifecycle.workflow
  }
  let carried_lifecycle = {
    ..to_lifecycle,
    agent_id: to_agent_id,
    role: to_agent.role,
    workflow,
  }
  ignore(
    @phase.persist_lifecycle(
      self.config.project_dir,
      self.registry,
      carried_lifecycle,
    ),
  )
  @phase.sync_parent_child_lifecycle(
    self.config.project_dir,
    self.config.terminal_session,
    self.registry,
    to_agent_id,
    carried_lifecycle,
  )
  @phase.remove_parent_child_lifecycle(
    self.config.project_dir,
    self.registry,
    from_agent_id,
  )
  transferred
}

///|
fn ServerState::clear_agent_runtime_tracking(
  self : ServerState,
  agent_id : String,
) -> Unit {
  self.stop_subscribe(agent_id)
  self.pending_disconnects.remove(agent_id)
  self.pending_disconnect_soft_notified.remove(agent_id)
  self.worker_no_handoff_prodded_at.remove(agent_id)
  self.worker_no_handoff_stalled_emitted.remove(agent_id)
  self.handoff_delivered.remove(agent_id)
  self.worker_no_handoff_exit_emitted.remove(agent_id)
  self.idle_agent_warned_at_70.remove(agent_id)
  self.clear_audit_cycle_count_for_agent(agent_id)
  self.clear_audit_progress_for_agent(agent_id)
  self.last_commit_observed_at.remove(agent_id)
  self.last_commit_observed_sha.remove(agent_id)
  self.last_commit_probe_at.remove(agent_id)
  self.recent_poller_event_emissions.remove(agent_id)
}

///|
pub fn ServerState::mark_handoff_delivered(
  self : ServerState,
  agent_id : String,
) -> Unit {
  self.handoff_delivered.set(agent_id, true)
  self.worker_no_handoff_prodded_at.remove(agent_id)
  self.worker_no_handoff_stalled_emitted.remove(agent_id)
  self.worker_no_handoff_exit_emitted.remove(agent_id)
}

///|
fn first_whitespace_token(raw : String) -> String {
  let s = raw.trim().to_owned()
  for i = 0; i < s.length(); i = i + 1 {
    let c = s[i]
    if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
      return s[:i].to_owned()
    }
  }
  s
}

///|
fn parse_ls_remote_head_sha(output : String) -> String {
  for raw in output.split("\n") {
    let sha = first_whitespace_token(raw.to_owned())
    if sha != "" {
      return sha
    }
  }
  ""
}

///|
fn progress_watchdog_ls_remote_command(
  project_dir : String,
  branch : String,
) -> @workspace.Command {
  {
    program: "timeout",
    args: [
      PROGRESS_LS_REMOTE_TIMEOUT_SEC.to_string() + "s",
      "git",
      "ls-remote",
      "--heads",
      "origin",
      branch,
    ],
    workdir: Some(project_dir),
  }
}

///|
fn ServerState::record_leaf_commit_observed(
  self : ServerState,
  agent_id : String,
  sha : String,
  now : Int64,
) -> Unit {
  if sha == "" {
    return
  }
  match self.last_commit_observed_sha.get(agent_id) {
    Some(previous) if previous == sha => ()
    _ => {
      self.last_commit_observed_sha.set(agent_id, sha)
      self.last_commit_observed_at.set(agent_id, now)
    }
  }
}

///|
pub fn poller_last_sha_snapshot(
  poller : @poller.PollerState,
) -> Map[Int, String] {
  let snapshot : Map[Int, String] = {}
  for tracked in poller.tracked.values() {
    snapshot.set(tracked.pr_number, tracked.last_sha)
  }
  snapshot
}

///|
pub fn ServerState::record_poller_sha_transitions(
  self : ServerState,
  before : Map[Int, String],
  now : Int64,
) -> Int {
  let mut observed = 0
  for tracked in self.poller.tracked.values() {
    let sha = tracked.last_sha
    if sha == "" {
      continue
    }
    match before.get(tracked.pr_number) {
      Some(previous) if previous == sha => ()
      _ => {
        self.record_leaf_commit_observed(tracked.agent_id, sha, now)
        observed = observed + 1
      }
    }
  }
  observed
}

///|
fn ServerState::tracked_sha_for_agent(
  self : ServerState,
  agent_id : String,
) -> String? {
  for tracked in self.poller.tracked.values() {
    if tracked.agent_id == agent_id && tracked.last_sha != "" {
      return Some(tracked.last_sha)
    }
  }
  None
}

///|
fn ServerState::fixes_pushed_at_for_agent(
  self : ServerState,
  agent_id : String,
  workflow : @phase.WorkflowState,
) -> Int64 {
  let pr_number = match workflow {
    @phase.WorkflowState::Dev(@phase.DevLifecycle::ReviewOwned(pr_number=n, ..))
    | @phase.WorkflowState::Dev(
      @phase.DevLifecycle::ChangesRequested(pr_number=n, ..)
    )
    | @phase.WorkflowState::Dev(
      @phase.DevLifecycle::ExitRequestedDeferred(pr_number=n, ..)
    ) => Some(n)
    _ => None
  }
  match pr_number {
    Some(n) =>
      match self.poller.get(n) {
        Some(tracked) if tracked.agent_id == agent_id => tracked.fixes_pushed_at
        _ => 0L
      }
    None => {
      let mut latest = 0L
      for tracked in self.poller.tracked.values() {
        if tracked.agent_id == agent_id && tracked.fixes_pushed_at > latest {
          latest = tracked.fixes_pushed_at
        }
      }
      latest
    }
  }
}

///|
async fn ServerState::ensure_progress_commit_observed(
  self : ServerState,
  agent : @types.Agent,
  now : Int64,
  capture : async (@workspace.Command) -> (Int, String),
) -> Int64 {
  let agent_id = agent.agent_id.to_string()
  match self.tracked_sha_for_agent(agent_id) {
    Some(sha) => {
      self.record_leaf_commit_observed(agent_id, sha, now)
      return self.last_commit_observed_at.get(agent_id).unwrap_or(0L)
    }
    None => ()
  }
  match self.last_commit_probe_at.get(agent_id) {
    Some(last_probe) if now - last_probe < PROGRESS_LS_REMOTE_PROBE_SEC =>
      return self.last_commit_observed_at.get(agent_id).unwrap_or(0L)
    _ => ()
  }
  let branch = if agent.branch != "" { agent.branch } else { agent_id }
  self.last_commit_probe_at.set(agent_id, now)
  let (status, output) = capture(
    progress_watchdog_ls_remote_command(self.config.project_dir, branch),
  ) catch {
    _ => return self.last_commit_observed_at.get(agent_id).unwrap_or(0L)
  }
  if status == 0 {
    let sha = parse_ls_remote_head_sha(output)
    self.record_leaf_commit_observed(agent_id, sha, now)
  }
  self.last_commit_observed_at.get(agent_id).unwrap_or(0L)
}

///|
fn progress_watchdog_suffix_number(slug : String, base_slug : String) -> Int? {
  let prefix = base_slug + "-r"
  if !slug.has_prefix(prefix) || slug.length() <= prefix.length() {
    return None
  }
  let raw = slug[prefix.length():].to_owned()
  for c in raw {
    if c < '0' || c > '9' {
      return None
    }
  }
  Some(@string.parse_int(raw)) catch {
    _ => None
  }
}

///|
fn progress_watchdog_base_slug(slug : String) -> String {
  match slug.rev_find("-r") {
    Some(i) if i + 2 < slug.length() => {
      let suffix = slug[i + 2:].to_owned()
      for c in suffix {
        if c < '0' || c > '9' {
          return slug
        }
      }
      slug[:i].to_owned()
    }
    _ => slug
  }
}

///|
fn ServerState::next_progress_rescue_slug(
  self : ServerState,
  from_agent_id : String,
) -> String {
  let current_slug = @phase.extract_slug(from_agent_id)
  let base_slug = progress_watchdog_base_slug(current_slug)
  let mut max_seen = 0
  for agent in self.registry.list() {
    let slug = @phase.extract_slug(agent.agent_id.to_string())
    match progress_watchdog_suffix_number(slug, base_slug) {
      Some(n) if n > max_seen => max_seen = n
      _ => ()
    }
  }
  base_slug + "-r" + (max_seen + 1).to_string()
}

///|
fn ServerState::task_contract_for_progress_rescue(
  self : ServerState,
  agent : @types.Agent,
) -> @types.TaskContract {
  let agent_id = agent.agent_id.to_string()
  let slug = @phase.extract_slug(agent_id)
  let paths : Array[String] = [
    @workspace.inline_agent_metadata_dir(self.config.project_dir, agent_id) +
    "/.choir/config.local.toml",
    agent.workspace + "/.choir/config.local.toml",
    @workspace.worktree_path(self.config.project_dir, slug) +
    "/.choir/config.local.toml",
  ]
  for path in paths {
    let content = (self.read_file)(path)
    if content == "" {
      continue
    }
    match @config.parse_local_config(content) {
      Ok(local_cfg) =>
        match local_cfg.task_contract {
          Some(contract) if contract.goal != "" => return contract
          Some(contract) => {
            let goal = "Continue progress-watchdog rescue for " + agent_id
            return { ..contract, goal, }
          }
          None => ()
        }
      Err(_) => ()
    }
  }
  {
    ..@types.TaskContract::empty(),
    goal: "Continue progress-watchdog rescue for " + agent_id,
  }
}

///|
fn progress_watchdog_rescue_args(
  task_contract : @types.TaskContract,
  caller_id : String,
  from_agent_id : String,
  new_slug : String,
  agent_type : @types.AgentType,
) -> @tools.RescueLeafArgs {
  {
    task: task_contract.goal,
    task_contract,
    caller_id,
    from_agent_id,
    new_slug,
    agent_type,
    parent_session_id: None,
  }
}

///|
pub async fn ServerState::check_leaf_progress(
  self : ServerState,
  agent : @types.Agent,
  lifecycle : @phase.AgentLifecycle,
  fixes_pushed_at : Int64,
  now : Int64,
  capture : async (@workspace.Command) -> (Int, String),
  rescue_invoker : async (@tools.RescueLeafArgs) -> @types.Response,
) -> Unit {
  if agent.role != @types.Role::Dev && agent.role != @types.Role::Worker {
    return
  }
  let applies = @phase.progress_watchdog_applies(
    lifecycle.workflow,
    fixes_pushed_at,
  )
  if !applies {
    return
  }
  let from_agent_id = agent.agent_id.to_string()
  let last_commit_at = self.ensure_progress_commit_observed(agent, now, capture)
  match
    progress_watchdog_decision(applies, last_commit_at, now, PROGRESS_STALL_SEC) {
    ProgressWatchdogDecision::DoNothing => ()
    ProgressWatchdogDecision::Rescue => {
      let caller_id = match agent.parent {
        Some(parent_id) => parent_id
        None => return
      }
      let new_type = pick_rescue_agent_type(agent.agent_type)
      let new_slug = self.next_progress_rescue_slug(from_agent_id)
      let task_contract = self.task_contract_for_progress_rescue(agent)
      let resp = rescue_invoker(
        progress_watchdog_rescue_args(
          task_contract, caller_id, from_agent_id, new_slug, new_type,
        ),
      )
      if resp.is_ok() {
        let to_agent_id = resp.ok_field("agent_id").unwrap_or("")
        ignore(
          @poller.append_delivery_log_line(
            self.append_file,
            self.config.project_dir,
            "progress_watchdog outcome=rescued from=" +
            from_agent_id +
            " to=" +
            to_agent_id +
            " agent_type=" +
            new_type.to_wire_string(),
            now_ms=now * 1000L,
          ),
        )
        self.clear_agent_runtime_tracking(from_agent_id)
        if to_agent_id != "" {
          self.watch_pane(to_agent_id)
        }
      } else {
        @moontrace.warn("progress watchdog rescue failed", fields=[
          @moontrace.field("agent_id", from_agent_id),
          @moontrace.field("agent_type", new_type.to_wire_string()),
          @moontrace.field(
            "error",
            resp.error_message().unwrap_or("unknown error"),
          ),
        ])
      }
    }
  }
}

///|
fn ServerState::handoff_was_delivered(
  self : ServerState,
  agent_id : String,
) -> Bool {
  self.handoff_delivered.contains(agent_id)
}

///|
pub let disconnect_auto_rescue_review_grace_sec : Int64 = 300L

///|
pub let disconnect_auto_rescue_slug_prefix : String = "auto-rescue-pr-"

///|
pub let disconnect_confirmation_min_signals : Int = 2

///|
pub let disconnect_confirmation_stale_heartbeat_sec : Int64 = 300L

///|
/// Disconnect-signal inventory for the hard `[FAILED: ...] disconnected unexpectedly` path:
/// - `handler_disconnect` / pending UDS close: session/registry timeout after grace.
/// - `pane_watch.check_idle`: no-heartbeat fallback proxy via unchanged pane output.
/// - `handler_poll_delivery`: stale registry reads emit `[ORPHANED PR]`, not `[FAILED]`.
/// A hard failure requires at least two independent signals; single-signal cases
/// are kept soft so a live leaf is not killed by a phantom UDS close.
pub(all) enum DisconnectConfirmationSignal {
  RegistryTimeout
  PaneClosed
  NoRecentHeartbeat
} derive(Debug, Eq)

///|
pub(all) struct DisconnectConfirmation {
  signals : Array[DisconnectConfirmationSignal]
} derive(Debug, Eq)

///|
pub(all) enum DisconnectHandlingResult {
  Handled
  AwaitingConfirmation
} derive(Debug, Eq)

///|
fn disconnect_confirmation_signal_label(
  signal : DisconnectConfirmationSignal,
) -> String {
  match signal {
    RegistryTimeout => "registry_timeout"
    PaneClosed => "pane_closed"
    NoRecentHeartbeat => "no_recent_heartbeat"
  }
}

///|
fn disconnect_confirmation_signal_summary(
  signals : Array[DisconnectConfirmationSignal],
) -> String {
  if signals.length() == 0 {
    return "none"
  }
  signals.map(disconnect_confirmation_signal_label).join(",")
}

///|
pub fn DisconnectConfirmation::is_confirmed(
  self : DisconnectConfirmation,
) -> Bool {
  self.signals.length() >= disconnect_confirmation_min_signals
}

///|
fn raw_lifecycle_last_updated_unix_sec(
  project_dir : String,
  read_file : (String) -> String,
  agent_id : String,
) -> Int64? {
  let path = project_dir + "/.choir/kv/" + @phase.lifecycle_key(agent_id)
  let content = read_file(path)
  if content == "" {
    return None
  }
  let parsed = @json.parse(content) catch { _ => return None }
  guard parsed is Object(fields) else { return None }
  @types.json_field_int64(fields, "last_updated_unix_sec")
}

///|
fn ServerState::disconnect_no_recent_heartbeat(
  self : ServerState,
  agent_id : String,
  now : Int64,
) -> Bool {
  // Treat a positive `last_updated_unix_sec` as the authoritative heartbeat
  // and compare it to the staleness threshold. Treat 0 (or a missing field
  // on an old on-disk payload) as "unknown" and fall back to the pane-watch
  // idle proxy — never as "always stale", because that would mark every
  // freshly-spawned agent as no-heartbeat the moment its lifecycle KV
  // exists but hasn't been re-persisted yet by this wave's
  // `write_lifecycle`.
  match
    raw_lifecycle_last_updated_unix_sec(
      self.config.project_dir,
      self.read_file,
      agent_id,
    ) {
    Some(last_updated) if last_updated > 0L =>
      now - last_updated >= disconnect_confirmation_stale_heartbeat_sec
    _ =>
      match
        self.pane_watcher.check_idle(
          agent_id, now, disconnect_confirmation_stale_heartbeat_sec,
        ) {
        Some(_) => true
        None => false
      }
  }
}

///|
async fn ServerState::disconnect_pane_closed(
  self : ServerState,
  agent : @types.Agent,
) -> Bool {
  let target = match agent.terminal_target {
    Some(t) => t
    None => return false
  }
  let live = (self.recovery_provider.zellij_live)(
    self.config.project_dir,
    target.session,
  ) catch {
    _ => return false
  }
  !@runtime.is_local_target_alive(Some(target), target.session, live)
}

///|
async fn ServerState::disconnect_confirmation_signals(
  self : ServerState,
  agent : @types.Agent,
  now : Int64,
  registry_timeout_signal : Bool,
) -> DisconnectConfirmation {
  let signals : Array[DisconnectConfirmationSignal] = []
  if registry_timeout_signal {
    signals.push(RegistryTimeout)
  }
  if self.disconnect_pane_closed(agent) {
    signals.push(PaneClosed)
  }
  if self.disconnect_no_recent_heartbeat(agent.agent_id.to_string(), now) {
    signals.push(NoRecentHeartbeat)
  }
  { signals, }
}

///|
fn possible_disconnect_message(
  agent_id : String,
  confirmation : DisconnectConfirmation,
) -> String {
  "[POSSIBLY DISCONNECTED: " +
  agent_id +
  "] disconnect signal observed but not confirmed; waiting for another independent signal before marking the agent failed\nsignals: " +
  disconnect_confirmation_signal_summary(confirmation.signals)
}

///|
async fn ServerState::notify_possible_disconnect(
  self : ServerState,
  agent : @types.Agent,
  confirmation : DisconnectConfirmation,
  runner : async (Array[@workspace.Command]) -> Array[Int],
) -> Unit {
  match agent.parent {
    Some(parent_id) =>
      try {
        let parent = self.resolve_parent_by_id(parent_id)
        ignore(
          self.durable_deliver_to_agent(
            parent,
            agent.agent_id.to_string(),
            possible_disconnect_message(
              agent.agent_id.to_string(),
              confirmation,
            ),
            @types.Status::Info,
            runner,
          ),
        )
      } catch {
        _ => ()
      }
    None => ()
  }
}

///|
pub(all) struct DisconnectAutoRescuePlan {
  pr_number : Int
  new_slug : String
  task : String
  agent_type : @types.AgentType
} derive(Debug, Eq)

///|
pub(all) enum DisconnectAutoRescueDecision {
  Rescue(plan~ : DisconnectAutoRescuePlan)
  NoRescue
} derive(Debug, Eq)

///|
pub(all) enum DisconnectAutoRescuePrecheck {
  RescueWithoutThreadFetch(plan~ : DisconnectAutoRescuePlan)
  FetchThreads(plan~ : DisconnectAutoRescuePlan)
  Ineligible
} derive(Debug, Eq)

///|
fn disconnect_auto_rescue_pr_number(lifecycle : @phase.AgentLifecycle) -> Int? {
  match lifecycle.workflow {
    @phase.WorkflowState::Dev(@phase.DevLifecycle::ReviewOwned(pr_number~, ..))
    | @phase.WorkflowState::Dev(
      @phase.DevLifecycle::ChangesRequested(pr_number~, ..)
    )
    | @phase.WorkflowState::Dev(
      @phase.DevLifecycle::ExitRequestedDeferred(pr_number~, ..)
    ) => Some(pr_number)
    _ => None
  }
}

///|
fn disconnect_auto_rescue_agent_type(
  agent_type : @types.AgentType,
) -> @types.AgentType {
  match agent_type {
    @types.AgentType::Unknown => @types.AgentType::CursorAgent
    other => other
  }
}

///|
fn disconnect_auto_rescue_task(pr_number : Int) -> String {
  "PR " +
  pr_number.to_string() +
  ": address Copilot review threads then notify_parent"
}

///|
pub fn disconnect_auto_rescue_pending_copilot_review(
  tracked : @poller.TrackedPR,
  now : Int64,
) -> Bool {
  !tracked.copilot_issue_comment_seen &&
  now - tracked.first_seen < disconnect_auto_rescue_review_grace_sec
}

///|
fn disconnect_auto_rescue_plan(
  agent : @types.Agent,
  lifecycle : @phase.AgentLifecycle,
  tracked : @poller.TrackedPR?,
) -> DisconnectAutoRescuePlan? {
  if agent.role != @types.Role::Dev {
    return None
  }
  let agent_id = agent.agent_id.to_string()
  if @phase.extract_slug(agent_id).has_prefix(
      disconnect_auto_rescue_slug_prefix,
    ) {
    return None
  }
  let pr_number = match disconnect_auto_rescue_pr_number(lifecycle) {
    Some(n) => n
    None => return None
  }
  match tracked {
    Some(t) if t.agent_id == agent_id && t.pr_number == pr_number => ()
    _ => return None
  }
  let new_slug = disconnect_auto_rescue_slug_prefix + pr_number.to_string()
  Some({
    pr_number,
    new_slug,
    task: disconnect_auto_rescue_task(pr_number),
    agent_type: disconnect_auto_rescue_agent_type(agent.agent_type),
  })
}

///|
pub fn disconnect_auto_rescue_precheck(
  agent : @types.Agent,
  lifecycle : @phase.AgentLifecycle,
  tracked : @poller.TrackedPR?,
  now : Int64,
) -> DisconnectAutoRescuePrecheck {
  let plan = match disconnect_auto_rescue_plan(agent, lifecycle, tracked) {
    Some(p) => p
    None => return Ineligible
  }
  match tracked {
    Some(t) if disconnect_auto_rescue_pending_copilot_review(t, now) =>
      RescueWithoutThreadFetch(plan~)
    _ => FetchThreads(plan~)
  }
}

///|
pub fn disconnect_auto_rescue_decision(
  agent : @types.Agent,
  lifecycle : @phase.AgentLifecycle,
  tracked : @poller.TrackedPR?,
  unresolved_thread_count : Int,
  now : Int64,
) -> DisconnectAutoRescueDecision {
  match disconnect_auto_rescue_precheck(agent, lifecycle, tracked, now) {
    RescueWithoutThreadFetch(plan~) => Rescue(plan~)
    FetchThreads(plan~) =>
      if unresolved_thread_count > 0 {
        Rescue(plan~)
      } else {
        NoRescue
      }
    Ineligible => NoRescue
  }
}

///|
fn disconnect_auto_rescue_args(
  plan : DisconnectAutoRescuePlan,
  caller_id : String,
  from_agent_id : String,
) -> @tools.RescueLeafArgs {
  {
    task: plan.task,
    task_contract: { ..@types.TaskContract::empty(), goal: plan.task },
    caller_id,
    from_agent_id,
    new_slug: plan.new_slug,
    agent_type: plan.agent_type,
    parent_session_id: None,
  }
}

///|
async fn ServerState::auto_rescue_disconnected_review_leaf(
  self : ServerState,
  agent : @types.Agent,
  lifecycle : @phase.AgentLifecycle,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  capture : async (@workspace.Command) -> (Int, String),
) -> Bool {
  let pr_number = match disconnect_auto_rescue_pr_number(lifecycle) {
    Some(n) => n
    None => return false
  }
  let tracked = self.poller.get(pr_number)
  let precheck = disconnect_auto_rescue_precheck(
    agent,
    lifecycle,
    tracked,
    @poller.now_sec(),
  )
  let plan = match precheck {
    Ineligible => return false
    RescueWithoutThreadFetch(plan~) => plan
    FetchThreads(plan~) => {
      let (thread_count, _) = @tools.fetch_unresolved_review_threads(
        plan.pr_number,
        self.config.project_dir,
        capture,
      )
      if thread_count <= 0 {
        return false
      }
      plan
    }
  }
  let from_agent_id = agent.agent_id.to_string()
  let caller_id = match agent.parent {
    Some(parent_id) => parent_id
    None => return false
  }
  let resp = @tools.interpret_rescue_leaf(
    disconnect_auto_rescue_args(plan, caller_id, from_agent_id),
    self.config.project_dir,
    self.config.terminal_session,
    runner,
    capture,
    Some(self.registry),
    Some(self.poller),
    extra_mcp_servers_json=self.config.extra_mcp_servers_json,
    shell_command=self.config.shell_command,
    listen_uds=self.config.listen_uds,
    listen_tcp=self.config.listen_tcp,
    tcp_auth_token=self.config.tcp_auth_token,
  )
  if resp.is_ok() {
    self.clear_agent_runtime_tracking(from_agent_id)
    match resp.ok_field("agent_id") {
      Some(new_agent_id) => self.watch_pane(new_agent_id)
      None => ()
    }
    true
  } else {
    @moontrace.warn("auto rescue failed", fields=[
      @moontrace.field("agent_id", from_agent_id),
      @moontrace.field("pr_number", plan.pr_number),
      @moontrace.field("error", resp.error_message().unwrap_or("unknown error")),
    ])
    false
  }
}

///|
async fn ServerState::reconcile_external_merge_with_runner(
  self : ServerState,
  agent_id : String,
  pr_number : Int,
  branch : String,
  parent_branch : String,
  pr_url : String,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  notify_parent? : Bool = true,
) -> Unit {
  let agent = try self.registry.get(agent_id) catch {
    _ =>
      @phase.resolve_agent_with_fallback(
        self.config.project_dir,
        self.config.terminal_session,
        self.registry,
        agent_id,
      )
  } noraise {
    resolved => resolved
  }
  let lifecycle = self.current_lifecycle(agent_id)
  let effects = plan_external_merge_finalization(
    agent,
    lifecycle,
    pr_number,
    branch,
    parent_branch,
    pr_url,
    self.config.project_dir,
    notify_parent~,
  )
  self.interpret_teardown_effects(effects, runner)
}

///|
async fn ServerState::finalize_agent_with_runner(
  self : ServerState,
  agent_id : String,
  exit_reason : @types.ExitReason,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  notify_parent? : Bool = false,
  close_target? : Bool = true,
  remove_worktree? : Bool = true,
) -> Unit {
  try self.registry.get(agent_id) catch {
    _ => self.clear_agent_runtime_tracking(agent_id)
  } noraise {
    agent => {
      if @types.is_supervisor_role(agent.role) {
        @moontrace.warn("finalize_agent refused: target is supervisor", fields=[
          @moontrace.field("agent_id", agent_id),
        ])
        return
      }
      let lifecycle = self.current_lifecycle(agent_id)
      let effects = plan_finalize(
        agent,
        lifecycle,
        exit_reason,
        notify_parent~,
        close_target~,
        remove_worktree~,
      )
      self.interpret_teardown_effects(effects, runner)
    }
  }
}

///|
pub async fn ServerState::fail_agent_with_runner(
  self : ServerState,
  agent_id : String,
  reason : @phase.FailureReason,
  parent_message : String,
  exit_reason : @types.ExitReason,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  close_target? : Bool = false,
) -> Unit {
  @async.sleep(0)
  try self.registry.get(agent_id) catch {
    _ => self.clear_agent_runtime_tracking(agent_id)
  } noraise {
    agent => {
      if @types.is_supervisor_role(agent.role) {
        @moontrace.warn("fail_agent refused: target is supervisor", fields=[
          @moontrace.field("agent_id", agent_id),
        ])
        return
      }
      let lifecycle = self.current_lifecycle(agent_id)
      let parent = match agent.parent {
        Some(pid) =>
          try self.resolve_parent_by_id(pid) catch {
            _ => None
          } noraise {
            p => Some(p)
          }
        None => None
      }
      let effects = plan_fail(
        agent,
        lifecycle,
        reason,
        parent_message,
        exit_reason,
        parent,
        close_target~,
      )
      self.interpret_teardown_effects(effects, runner)
    }
  }
}

///|
pub async fn ServerState::interpret_teardown_effects(
  self : ServerState,
  effects : Array[TeardownEffect],
  runner : async (Array[@workspace.Command]) -> Array[Int],
) -> Unit {
  for effect in effects {
    match effect {
      PersistLifecycle(agent_id~, lifecycle~, trigger~) => {
        let prev = self.current_lifecycle(agent_id)
        if @phase.persist_lifecycle(
            self.config.project_dir,
            self.registry,
            lifecycle,
          ) {
          ignore(
            append_lifecycle_event(
              self.config.project_dir,
              agent_id,
              prev,
              lifecycle,
              trigger,
            ),
          )
        }
      }
      SyncParentLifecycle(agent_id~, lifecycle~) =>
        @phase.sync_parent_child_lifecycle(
          self.config.project_dir,
          self.config.terminal_session,
          self.registry,
          agent_id,
          lifecycle,
        )
      NotifyParent(parent_id~, agent_id~, message~, status~) =>
        try {
          let parent = self.resolve_parent_by_id(parent_id)
          ignore(
            self.durable_deliver_to_agent(
              parent, agent_id, message, status, runner,
            ),
          )
        } catch {
          _ => ()
        }
      RemoveTeamMember(parent_id~, slug~) =>
        ignore(@workspace.remove_team_member(parent_id, slug))
      FireHook(agent_id~, role~, exit_reason~) =>
        @tools.fire_hook_async(
          @hooks.HookEvent::AgentExit,
          {
            event: @hooks.HookEvent::AgentExit,
            session_id: None,
            agent_id: Some(agent_id),
            pr_number: None,
            pr_url: None,
            branch: None,
            parent_branch: None,
            merge_provenance: None,
            role: Some(role),
            tool_name: None,
            tool_args: None,
            tool_result_status: None,
            exit_reason: Some(exit_reason),
            suspend_reason: None,
          },
          self.config.project_dir,
        )
      RemoveWorktree(path) =>
        if @types.is_choir_managed_worktree_path(self.config.project_dir, path) {
          ignore(
            runner([@workspace.git_worktree_remove(path)]) catch {
              _ => []
            },
          )
        } else {
          @moontrace.warn("RemoveWorktree refused: unsafe path", fields=[
            @moontrace.field("path", path),
          ])
        }
      CloseTerminal(target) => {
        let cmd = @workspace.local_close_target(target)
        try {
          let codes = runner([cmd])
          if codes.length() == 0 || codes[0] != 0 {
            @moontrace.warn("CloseTerminal failed", fields=[
              @moontrace.field(
                "exit",
                if codes.length() > 0 {
                  codes[0]
                } else {
                  -1
                },
              ),
              @moontrace.field("cmd", cmd.to_string()),
            ])
          }
        } catch {
          err =>
            @moontrace.warn("CloseTerminal failed", fields=[
              @moontrace.field("error", err.to_string()),
              @moontrace.field("cmd", cmd.to_string()),
            ])
        }
      }
      InjectTerminalMessage(target, message) =>
        ignore(
          @tools.execute_delivery(
            @message.DeliveryMethod::LocalTerminalInput(target, message),
            runner,
          ) catch {
            _ => Ok(())
          },
        )
      ClearRuntimeTracking(agent_id) =>
        self.clear_agent_runtime_tracking(agent_id)
      WatchPane(agent_id~) =>
        try self.registry.get(agent_id) catch {
          _ => ()
        } noraise {
          agent =>
            match agent.terminal_target {
              Some(_) => self.watch_pane(agent_id)
              None => ()
            }
        }
      UpdateDevLifecycle(agent_id~, event~) =>
        ignore(
          @tools.apply_dev_event_checked(
            self.config.project_dir,
            agent_id,
            event,
            registry=Some(self.registry),
          ),
        )
      DeliverToParentMerged(
        leaf_id~,
        pr_number~,
        branch~,
        parent_branch~,
        url~,
        source~,
        merge_execution_mode~,
        parent_id~
      ) => {
        match parent_id {
          Some(pid) =>
            try {
              let parent = self.resolve_parent_by_id(pid)
              let body = merged_pr_parent_message(
                pr_number,
                leaf_id,
                branch,
                parent_branch,
                url,
                source,
                merge_execution_mode~,
              )
              ignore(
                self.durable_deliver_to_agent(
                  parent,
                  leaf_id,
                  body,
                  @types.Status::Success,
                  runner,
                ),
              )
            } catch {
              _ => ()
            }
          None => ()
        }
        ignore(source)
      }
      ParentFailureTerminalEchoIfNeeded(
        parent_id~,
        agent_id~,
        parent_message~,
        reason~
      ) =>
        try {
          let p = self.resolve_parent_by_id(parent_id)
          let delivery = @message.plan_delivery(
            p,
            agent_id,
            parent_message,
            @types.Status::Failure,
          )
          let already_terminal = match delivery {
            @message.DeliveryMethod::LocalTerminalInput(_, _) => true
            _ => false
          }
          let is_self_reported = match reason {
            @phase.FailureReason::ChildFailure(_) => true
            _ => false
          }
          if !is_self_reported && !already_terminal {
            match p.terminal_target {
              Some(target) => {
                let reason_str = reason.to_wire_string()
                let msg = @message.format_failure(agent_id, reason_str)
                ignore(
                  @tools.execute_delivery(
                    @message.DeliveryMethod::LocalTerminalInput(target, msg),
                    runner,
                  ) catch {
                    _ => Ok(())
                  },
                )
              }
              None => ()
            }
          }
        } catch {
          _ => ()
        }
      RefreshPR(pr_number) => self.refresh_pr_with_runner(pr_number, runner)
    }
  }
}

///|
fn nonnegative_elapsed(now : Int64, then : Int64) -> Int64 {
  if now >= then {
    now - then
  } else {
    0L
  }
}

///|
fn ServerState::leaf_merge_gate_ready_for_agent(
  self : ServerState,
  agent_id : String,
) -> Bool {
  for tracked in self.poller.tracked.values() {
    if tracked.agent_id == agent_id {
      let unresolved_threads = tracked_unresolved_thread_count_for_gate(tracked)
      if @poller.tl_tracked_pr_merge_gate_snapshot_ready(
          tracked,
          unresolved_threads,
          review_mode=tracked.review_mode,
        ) {
        return true
      }
    }
  }
  false
}

///|
fn worker_no_handoff_terminal_process(
  lifecycle : @phase.AgentLifecycle,
) -> Bool {
  match lifecycle.process {
    @phase.ProcessState::Finalized(..) | @phase.ProcessState::Failed(..) => true
    _ => false
  }
}

///|
async fn ServerState::prod_leaf_no_handoff(
  self : ServerState,
  agent : @types.Agent,
  now : Int64,
  runner : async (Array[@workspace.Command]) -> Array[Int],
) -> Unit {
  let agent_id = agent.agent_id.to_string()
  if self.worker_no_handoff_prodded_at.contains(agent_id) ||
    self.handoff_was_delivered(agent_id) {
    return
  }
  self.worker_no_handoff_prodded_at.set(agent_id, now)
  ignore(
    self.durable_deliver_to_agent(
      agent,
      "watchdog",
      leaf_stalled_no_handoff_prod_message(@phase.extract_slug(agent_id)),
      @types.Status::Info,
      runner,
    ),
  ) catch {
    _ => ()
  }
}

///|
async fn ServerState::emit_leaf_stalled_no_handoff(
  self : ServerState,
  agent : @types.Agent,
  idle_sec : Int64,
  screen : String,
  runner : async (Array[@workspace.Command]) -> Array[Int],
) -> Unit {
  let agent_id = agent.agent_id.to_string()
  if self.worker_no_handoff_stalled_emitted.contains(agent_id) ||
    self.handoff_was_delivered(agent_id) {
    return
  }
  self.worker_no_handoff_stalled_emitted.set(agent_id, true)
  let message = leaf_stalled_no_handoff_parent_message(
    @phase.extract_slug(agent_id),
    idle_sec,
    screen,
  )
  ignore(
    self.durable_deliver_to_parent(
      agent_id,
      message,
      @types.Status::Failure,
      runner,
    ),
  ) catch {
    _ => ()
  }
}

///|
async fn ServerState::prod_worker_no_handoff(
  self : ServerState,
  agent : @types.Agent,
  now : Int64,
  runner : async (Array[@workspace.Command]) -> Array[Int],
) -> Unit {
  let agent_id = agent.agent_id.to_string()
  if self.worker_no_handoff_prodded_at.contains(agent_id) ||
    self.handoff_was_delivered(agent_id) {
    return
  }
  let target = match agent.terminal_target {
    Some(t) => t
    None => return
  }
  self.worker_no_handoff_prodded_at.set(agent_id, now)
  ignore(
    @tools.execute_delivery(
      @message.DeliveryMethod::LocalTerminalInput(
        target, worker_no_handoff_prod_text,
      ),
      runner,
      project_dir=self.config.project_dir,
    ),
  ) catch {
    _ => ()
  }
}

///|
async fn ServerState::emit_worker_stalled_no_handoff(
  self : ServerState,
  agent : @types.Agent,
  idle_sec : Int64,
  screen : String,
  runner : async (Array[@workspace.Command]) -> Array[Int],
) -> Unit {
  let agent_id = agent.agent_id.to_string()
  if self.worker_no_handoff_stalled_emitted.contains(agent_id) ||
    self.handoff_was_delivered(agent_id) {
    return
  }
  self.worker_no_handoff_stalled_emitted.set(agent_id, true)
  let message = worker_stalled_no_handoff_message(
    @phase.extract_slug(agent_id),
    idle_sec,
    screen,
  )
  ignore(
    self.durable_deliver_to_parent(
      agent_id,
      message,
      @types.Status::Failure,
      runner,
    ),
  ) catch {
    _ => ()
  }
}

///|
async fn ServerState::emit_worker_exited_without_notify_if_needed(
  self : ServerState,
  agent : @types.Agent,
  screen : String?,
  runner : async (Array[@workspace.Command]) -> Array[Int],
) -> Unit {
  if agent.role != @types.Role::Worker {
    return
  }
  let agent_id = agent.agent_id.to_string()
  if self.handoff_was_delivered(agent_id) ||
    self.worker_no_handoff_exit_emitted.contains(agent_id) {
    return
  }
  self.worker_no_handoff_exit_emitted.set(agent_id, true)
  let screen_text = match screen {
    Some(s) => s
    None =>
      @runtime.extract_viewport_text(self.pane_watcher.read_viewport(agent_id))
  }
  let message = worker_exited_without_notify_message(
    @phase.extract_slug(agent_id),
    screen_text,
  )
  ignore(
    self.durable_deliver_to_parent(
      agent_id,
      message,
      @types.Status::Failure,
      runner,
    ),
  ) catch {
    _ => ()
  }
}

///|
async fn ServerState::check_leaf_no_handoff(
  self : ServerState,
  agent : @types.Agent,
  lifecycle : @phase.WorkflowState,
  now : Int64,
  observation : @runtime.PaneIdleObservation,
  prod_sec : Int64,
  escalate_sec : Int64,
  runner : async (Array[@workspace.Command]) -> Array[Int],
) -> Unit {
  let agent_id = agent.agent_id.to_string()
  if agent.role != @types.Role::Dev ||
    self.handoff_was_delivered(agent_id) ||
    prod_sec <= 0L {
    return
  }
  let prodded_at = self.worker_no_handoff_prodded_at.get(agent_id)
  let prodded = prodded_at != None
  let idle_timeout = if prodded { escalate_sec } else { prod_sec }
  if idle_timeout <= 0L {
    return
  }
  if observation.idle_sec < idle_timeout {
    return
  }
  let gate_ready = self.leaf_merge_gate_ready_for_agent(agent_id)
  let decision_idle_sec = match prodded_at {
    Some(t) => {
      let elapsed_since_prod = nonnegative_elapsed(now, t)
      let post_prod_idle_sec = if observation.idle_sec < elapsed_since_prod {
        observation.idle_sec
      } else {
        elapsed_since_prod
      }
      prod_sec + post_prod_idle_sec
    }
    None => observation.idle_sec
  }
  match
    leaf_no_handoff_decision(
      agent.role,
      lifecycle,
      gate_ready,
      decision_idle_sec,
      self.handoff_was_delivered(agent_id),
      prodded,
      self.worker_no_handoff_stalled_emitted.contains(agent_id),
      prod_sec,
      escalate_sec,
    ) {
    WorkerNoHandoffDecision::Prod =>
      self.prod_leaf_no_handoff(agent, now, runner)
    WorkerNoHandoffDecision::EmitStalled =>
      self.emit_leaf_stalled_no_handoff(
        agent,
        observation.idle_sec,
        observation.screen,
        runner,
      )
    WorkerNoHandoffDecision::DoNothing => ()
  }
}

///|
async fn ServerState::check_worker_no_handoff(
  self : ServerState,
  agent : @types.Agent,
  now : Int64,
  observation : @runtime.PaneIdleObservation,
  prod_sec : Int64,
  escalate_sec : Int64,
  runner : async (Array[@workspace.Command]) -> Array[Int],
) -> Unit {
  let agent_id = agent.agent_id.to_string()
  if agent.role != @types.Role::Worker ||
    self.handoff_was_delivered(agent_id) ||
    prod_sec <= 0L {
    return
  }
  let prodded_at = self.worker_no_handoff_prodded_at.get(agent_id)
  let prodded = prodded_at != None
  let idle_timeout = if prodded { escalate_sec } else { prod_sec }
  if idle_timeout <= 0L {
    return
  }
  if observation.idle_sec < idle_timeout {
    return
  }
  let decision_idle_sec = match prodded_at {
    Some(t) => nonnegative_elapsed(now, t)
    None => observation.idle_sec
  }
  match
    worker_no_handoff_decision(
      agent.role,
      decision_idle_sec,
      self.handoff_was_delivered(agent_id),
      prodded,
      self.worker_no_handoff_stalled_emitted.contains(agent_id),
      prod_sec,
      escalate_sec,
    ) {
    WorkerNoHandoffDecision::Prod =>
      self.prod_worker_no_handoff(agent, now, runner)
    WorkerNoHandoffDecision::EmitStalled =>
      self.emit_worker_stalled_no_handoff(
        agent,
        observation.idle_sec,
        observation.screen,
        runner,
      )
    WorkerNoHandoffDecision::DoNothing => ()
  }
}

///|
/// Check for idle agents by dumping pane screens and comparing hashes.
/// If a pane's screen hasn't changed for `timeout` seconds, kill the agent.
pub async fn ServerState::check_idle_agents(
  self : ServerState,
  now : Int64,
  timeout : Int64,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  worker_no_handoff_prod_sec? : Int64 = 120L,
  worker_no_handoff_escalate_sec? : Int64 = 120L,
  capture? : async (@workspace.Command) -> (Int, String) = @exec.capture_command_stdout,
  rescue_invoker? : (async (@tools.RescueLeafArgs) -> @types.Response)? = None,
) -> Unit {
  let progress_rescue_invoker = match rescue_invoker {
    Some(invoker) => invoker
    None =>
      @tools.build_rescue_leaf_invoker(
        self.config.project_dir,
        self.config.terminal_session,
        runner,
        capture,
        Some(self.registry),
        Some(self.poller),
        extra_mcp_servers_json=self.config.extra_mcp_servers_json,
        shell_command=self.config.shell_command,
        listen_uds=self.config.listen_uds,
        listen_tcp=self.config.listen_tcp,
        tcp_auth_token=self.config.tcp_auth_token,
      )
  }
  let agent_ids = self.pane_watcher.watched_agents()
  for agent_id in agent_ids {
    let agent = try self.registry.get(agent_id) catch {
      _ => {
        self.stop_subscribe(agent_id)
        continue
      }
    } noraise {
      a => a
    }
    if agent.state != @types.AgentState::Active {
      self.stop_subscribe(agent_id)
      continue
    }
    if @types.is_supervisor_role(agent.role) {
      continue
    }
    let lifecycle = self.current_lifecycle(agent_id)
    // Some lifecycle states are kill-watchdog-exempt, but no-handoff checks
    // may still need to prod or notify without terminating the agent.
    let watchdog_exempt = @phase.lifecycle_idle_watchdog_exempt(lifecycle)
    let fixes_pushed_at = self.fixes_pushed_at_for_agent(
      agent_id,
      lifecycle.workflow,
    )
    self.check_leaf_progress(
      agent, lifecycle, fixes_pushed_at, now, capture, progress_rescue_invoker,
    )
    if self.registry.get_opt(agent_id) is None {
      continue
    }
    match agent.terminal_target {
      Some(_) => ()
      None => continue
    }

    // Read and parse the pane snapshot once for all idle decisions this tick.
    match self.pane_watcher.observe_idle(agent_id, now) {
      Some(observation) => {
        self.check_worker_no_handoff(
          agent, now, observation, worker_no_handoff_prod_sec, worker_no_handoff_escalate_sec,
          runner,
        )
        self.check_leaf_no_handoff(
          agent,
          lifecycle.workflow,
          now,
          observation,
          worker_no_handoff_prod_sec,
          worker_no_handoff_escalate_sec,
          runner,
        )
        if watchdog_exempt {
          continue
        }
        if should_emit_70_pct_warning(
            observation.idle_sec,
            timeout,
            self.idle_agent_warned_at_70.contains(agent_id),
          ) {
          self.idle_agent_warned_at_70.set(agent_id, true)
          @moontrace.warn("idle agent approaching kill threshold", fields=[
            @moontrace.field("agent_id", agent_id),
            @moontrace.field("idle_sec", observation.idle_sec),
            @moontrace.field("threshold", timeout),
            @moontrace.field("percent", idle_watchdog_warning_percent),
          ])
        }
        if observation.idle_sec < timeout {
          continue
        }
        self.emit_worker_exited_without_notify_if_needed(
          agent,
          Some(observation.screen),
          runner,
        )
        // Kill the agent
        @moontrace.warn("watchdog killing idle agent", fields=[
          @moontrace.field("agent", agent_id),
          @moontrace.field("idle_sec", timeout),
        ])
        let message = "[WATCHDOG] agent " +
          agent_id +
          " killed after " +
          timeout.to_string() +
          "s idle (no pane output change)"
        self.fail_agent_with_runner(
          agent_id,
          @phase.FailureReason::WatchdogTimeout,
          message,
          @types.ExitReason::Shutdown,
          runner,
          close_target=true,
        )
      }
      None => continue
    }
  }
}

///|
async test "check_idle_agents skips supervisor roles before reading panes" {
  let project_dir = "/tmp/choir-check-idle-supervisor-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.create_dir_all(project_dir + "/.choir/kv"))
  let reads : Array[String] = []
  let spawned : Array[String] = []
  let killed : Array[Int] = []
  let host : @runtime.PaneWatchHost = {
    spawn_zellij_pane_viewport_subscribe: fn(_session, name, _snapshot_path) {
      spawned.push(name)
      100
    },
    kill_pid_best_effort: fn(pid) { killed.push(pid) },
    delete_file_sync: fn(_path) {  },
    read_file: fn(path) {
      reads.push(path)
      "{\"event\":\"pane_update\",\"viewport\":[\"idle\"]}"
    },
  }
  let state = {
    ..ServerState::new(
      { ..@types.Config::default(), project_dir, terminal_session: "s" },
      make_hermetic_recovery_provider(),
    ),
    pane_watcher: @runtime.PaneWatcher::with_host(host),
  }
  for role in [@types.Role::Root, @types.Role::TL] {
    let agent_id = match role {
      @types.Role::Root => "root"
      @types.Role::TL => "main.tl"
      _ => "main.supervisor"
    }
    ignore(
      state.register_agent({
        agent_id: @types.AgentId(agent_id),
        role,
        agent_type: @types.AgentType::Claude,
        parent: None,
        workspace: project_dir,
        branch: "main",
        terminal_target: Some({
          kind: @types.TargetKind::ZellijPane,
          session: "s",
          name: agent_id,
        }),
        host: @types.Host::Local,
        spawn_depth: 0,
        state: @types.AgentState::Active,
      }),
    )
    state.watch_pane(agent_id)
  }
  let calls : Array[@workspace.Command] = []
  state.check_idle_agents(1000L, 0L, async fn(cmds) {
    @async.sleep(0)
    for cmd in cmds {
      calls.push(cmd)
    }
    [0]
  })
  assert_eq(spawned.length(), 2)
  @debug.assert_eq(reads, [])
  @debug.assert_eq(killed, [])
  @debug.assert_eq(calls, [])
  assert_eq(state.registry.get("root").state, @types.AgentState::Active)
  assert_eq(state.registry.get("main.tl").state, @types.AgentState::Active)
  ignore(@sys.rm_rf(project_dir))
}

///|
test "clear_agent_runtime_tracking clears worker no-handoff maps" {
  let project_dir = "/tmp/choir-clear-worker-handoff-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.create_dir_all(project_dir + "/.choir/kv"))
  let state = ServerState::new(
    { ..@types.Config::default(), project_dir, terminal_session: "s" },
    make_hermetic_recovery_provider(),
  )
  let agent_id = "main.worker"
  state.pending_disconnects.set(agent_id, 1L)
  state.pending_disconnect_soft_notified.set(agent_id, true)
  state.handoff_delivered.set(agent_id, true)
  state.worker_no_handoff_prodded_at.set(agent_id, 2L)
  state.worker_no_handoff_stalled_emitted.set(agent_id, true)
  state.worker_no_handoff_exit_emitted.set(agent_id, true)
  state.idle_agent_warned_at_70.set(agent_id, true)
  state.recent_poller_event_emissions.set(agent_id, {
    "merge_ready": { content_hash: "hash", emitted_at_unix: 3L },
  })

  state.clear_agent_runtime_tracking(agent_id)

  assert_eq(state.pending_disconnects.contains(agent_id), false)
  assert_eq(state.pending_disconnect_soft_notified.contains(agent_id), false)
  assert_eq(state.handoff_delivered.contains(agent_id), false)
  assert_eq(state.worker_no_handoff_prodded_at.contains(agent_id), false)
  assert_eq(state.worker_no_handoff_stalled_emitted.contains(agent_id), false)
  assert_eq(state.worker_no_handoff_exit_emitted.contains(agent_id), false)
  assert_eq(state.idle_agent_warned_at_70.contains(agent_id), false)
  assert_eq(state.recent_poller_event_emissions.contains(agent_id), false)
  ignore(@sys.rm_rf(project_dir))
}

///|
pub fn ServerState::list_agents(self : ServerState) -> Array[@types.Agent] {
  self.registry.list()
}

///|
pub fn ServerState::get_agent(
  self : ServerState,
  agent_id : String,
) -> @types.Agent raise @types.ChoirError {
  self.registry.get(agent_id)
}

///|
/// Called when a connection closes. Detects unexpected agent death and notifies parent.
/// Review-owned agents are preserved; agent-owned disconnects fail.
pub fn disconnect_pr_recovery_candidate(agent : @types.Agent) -> Bool {
  agent.role == @types.Role::Dev && agent.branch.trim() != ""
}

///|
async fn ServerState::handle_disconnect_confirming_with_runner(
  self : ServerState,
  agent_id : String,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  capture : async (@workspace.Command) -> (Int, String),
  now : Int64,
  registry_timeout_signal? : Bool = true,
  emit_possible_disconnect? : Bool = true,
) -> DisconnectHandlingResult {
  let agent = self.registry.get(agent_id) catch {
    _ => {
      self.clear_agent_runtime_tracking(agent_id)
      return Handled
    }
  }
  if @types.is_supervisor_role(agent.role) {
    return Handled
  }
  let lifecycle = self.current_lifecycle(agent_id)
  match agent.state {
    Done | Failed => {
      if !worker_no_handoff_terminal_process(lifecycle) {
        self.emit_worker_exited_without_notify_if_needed(agent, None, runner)
      }
      match agent.terminal_target {
        Some(target) =>
          self.interpret_teardown_effects([CloseTerminal(target)], runner)
        None => ()
      }
      self.clear_agent_runtime_tracking(agent_id)
    }
    Completing => {
      if !worker_no_handoff_terminal_process(lifecycle) {
        self.emit_worker_exited_without_notify_if_needed(agent, None, runner)
      }
      let exit_reason = match lifecycle.process {
        @phase.ProcessState::Finalizing(reason=@phase.FinalizeReason::Merged) =>
          @types.ExitReason::Merged
        @phase.ProcessState::Finalizing(
          reason=@phase.FinalizeReason::DisconnectFinalized
        ) => @types.ExitReason::Disconnected
        _ => @types.ExitReason::Shutdown
      }
      self.finalize_agent_with_runner(
        agent_id,
        exit_reason,
        runner,
        notify_parent=false,
        close_target=false,
        remove_worktree=false,
      )
    }
    _ =>
      if self.auto_rescue_disconnected_review_leaf(
          agent, lifecycle, runner, capture,
        ) {
        ()
      } else {
        match @phase.lifecycle_disconnect_policy(lifecycle) {
          @phase.LifecycleDisconnectPolicy::Preserve => ()
          @phase.LifecycleDisconnectPolicy::FinalizeDone(..) => {
            self.emit_worker_exited_without_notify_if_needed(
              agent,
              None,
              runner,
            )
            self.finalize_agent_with_runner(
              agent_id,
              @types.ExitReason::Disconnected,
              runner,
              notify_parent=false,
              close_target=false,
              remove_worktree=false,
            )
          }
          @phase.LifecycleDisconnectPolicy::Ignore => ()
          @phase.LifecycleDisconnectPolicy::Fail(reason=default_reason) => {
            let confirmation = self.disconnect_confirmation_signals(
              agent, now, registry_timeout_signal,
            )
            if !confirmation.is_confirmed() {
              if emit_possible_disconnect {
                self.notify_possible_disconnect(agent, confirmation, runner)
              }
              return AwaitingConfirmation
            }
            // Before failing: check if a dev leaf filed a PR via raw `gh pr create`
            // (bypassing file_pr). Restrict this to branch-owning dev agents so
            // top-level TLs/workers with empty branches cannot steal tracked PR ownership.
            let recovered_pr = if disconnect_pr_recovery_candidate(agent) {
              @runtime.find_pr_for_branch_in_provider(
                self.recovery_provider,
                self.config.project_dir,
                agent.branch,
              )
            } else {
              None
            }
            match recovered_pr {
              Some((pr_number, pr_url)) => {
                let parent_branch = match
                  @workspace.parent_branch(agent.branch) {
                  Some(pb) => pb
                  None => "main"
                }
                @tools.apply_dev_event(
                  self.config.project_dir,
                  agent_id,
                  @phase.DevEvent::PRCreated(
                    pr_number~,
                    url=pr_url,
                    branch=agent.branch,
                  ),
                  registry=Some(self.registry),
                )
                let review_mode = match self.poller.get(pr_number) {
                  Some(existing) => existing.review_mode
                  None =>
                    @workspace.review_mode_for_agent_workspace(
                      self.config.project_dir,
                      Some(agent.workspace),
                      @phase.extract_slug(agent_id),
                      agent_id=Some(agent_id),
                      global_review_mode=self.config.review_mode,
                    )
                }
                self.poller.ensure_tracked(
                  pr_number,
                  agent_id,
                  agent.branch,
                  parent_branch,
                  pr_url,
                  @poller.now_sec(),
                  review_mode=Some(review_mode),
                )
                ignore(self.poller.write_state_file(self.config.project_dir))
              }
              None => {
                self.emit_worker_exited_without_notify_if_needed(
                  agent,
                  None,
                  runner,
                )
                let snapshot = self.pane_watcher.read_viewport(agent_id)
                let screen = @runtime.extract_viewport_text(snapshot)
                let (reason, msg) = if screen != "" {
                  let classified = @phase.classify_failure(screen)
                  match classified {
                    @phase.FailureReason::ChildFailure(_) =>
                      (
                        default_reason,
                        "[FAILED: " +
                        agent_id +
                        "] disconnected unexpectedly - agent may have crashed or run out of context",
                      )
                    _ =>
                      (
                        classified,
                        "[FAILED: " +
                        agent_id +
                        "] " +
                        @phase.failure_reason_message(classified),
                      )
                  }
                } else {
                  (
                    default_reason,
                    "[FAILED: " +
                    agent_id +
                    "] disconnected unexpectedly - agent may have crashed or run out of context",
                  )
                }
                self.fail_agent_with_runner(
                  agent_id,
                  reason,
                  msg,
                  @types.ExitReason::Disconnected,
                  runner,
                )
              }
            }
          }
        }
      }
  }
  Handled
}

///|
pub async fn ServerState::handle_disconnect_with_runner(
  self : ServerState,
  agent_id : String,
  runner? : async (Array[@workspace.Command]) -> Array[Int] = @exec.run_sequence,
  capture? : async (@workspace.Command) -> (Int, String) = @exec.capture_command_stdout,
) -> Unit {
  let now = @poller.now_sec()
  match
    self.handle_disconnect_confirming_with_runner(
      agent_id, runner, capture, now,
    ) {
    Handled => ()
    AwaitingConfirmation => {
      self.pending_disconnects.set(agent_id, now)
      self.pending_disconnect_soft_notified.set(agent_id, true)
    }
  }
}

///|
pub async fn ServerState::handle_disconnect(
  self : ServerState,
  agent_id : String,
) -> Unit {
  self.handle_disconnect_with_runner(agent_id, runner=@exec.run_sequence)
}

///|
/// Schedule a disconnect instead of firing immediately.
/// The pending disconnect is resolved on the next poller tick after the grace period.
pub fn ServerState::schedule_disconnect(
  self : ServerState,
  agent_id : String,
  now : Int64,
) -> Unit {
  self.pending_disconnects.set(agent_id, now)
}

///|
/// Clear a pending disconnect (called when an agent re-registers).
pub fn ServerState::clear_pending_disconnect(
  self : ServerState,
  agent_id : String,
) -> Unit {
  self.pending_disconnects.remove(agent_id)
  self.pending_disconnect_soft_notified.remove(agent_id)
}

///|
/// Process pending disconnects older than grace_seconds. Fire handle_disconnect for stale ones.
pub async fn ServerState::process_pending_disconnects_with_runner(
  self : ServerState,
  now : Int64,
  grace_seconds : Int64,
  runner? : async (Array[@workspace.Command]) -> Array[Int] = @exec.run_sequence,
  capture? : async (@workspace.Command) -> (Int, String) = @exec.capture_command_stdout,
) -> Unit {
  let stale : Array[String] = []
  for agent_id, disconnect_time in self.pending_disconnects {
    if now - disconnect_time >= grace_seconds {
      stale.push(agent_id)
    }
  }
  for agent_id in stale {
    let result = self.handle_disconnect_confirming_with_runner(
      agent_id,
      runner,
      capture,
      now,
      registry_timeout_signal=true,
      emit_possible_disconnect=!self.pending_disconnect_soft_notified.contains(
        agent_id,
      ),
    )
    match result {
      Handled => {
        self.pending_disconnects.remove(agent_id)
        self.pending_disconnect_soft_notified.remove(agent_id)
      }
      AwaitingConfirmation =>
        self.pending_disconnect_soft_notified.set(agent_id, true)
    }
  }
}

///|
pub async fn ServerState::process_pending_disconnects(
  self : ServerState,
  now : Int64,
  grace_seconds : Int64,
) -> Unit {
  self.process_pending_disconnects_with_runner(
    now,
    grace_seconds,
    runner=@exec.run_sequence,
  )
}

///|
