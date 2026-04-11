///|
fn request_agent_id(req : @types.Request) -> String? {
  match req.args.get("agent_id") {
    Some(agent_id) => Some(agent_id)
    None =>
      match req.args.get("caller_id") {
        Some(agent_id) => Some(agent_id)
        None =>
          match req.args.get("sender_id") {
            Some(agent_id) => Some(agent_id)
            None => None
          }
      }
  }
}

///|
fn request_int_arg(req : @types.Request, key : String) -> Int? {
  match req.args.get_int(key) {
    Some(value) => Some(value)
    None =>
      match req.args.get(key) {
        Some(value) => {
          let parsed = @json.parse(value) catch { _ => return None }
          match parsed {
            Number(n, ..) => Some(n.to_int())
            _ => None
          }
        }
        None => None
      }
  }
}

///|
fn request_bool_arg(req : @types.Request, key : String) -> Bool? {
  match req.args.get_bool(key) {
    Some(value) => Some(value)
    None =>
      match req.args.get(key) {
        Some(value) => {
          let lowered = value.trim().to_lower()
          if lowered == "true" || lowered == "1" || lowered == "yes" {
            Some(true)
          } else if lowered == "false" || lowered == "0" || lowered == "no" {
            Some(false)
          } else {
            None
          }
        }
        None => None
      }
  }
}

///|
fn tracked_prs_for_agent(
  state : ServerState,
  agent_id : String,
) -> Array[@poller.TrackedPR] {
  let prs : Array[@poller.TrackedPR] = []
  state.poller.tracked.each(fn(_k, pr) {
    if pr.agent_id == agent_id {
      prs.push(pr)
    }
  })
  prs
}

///|
fn stale_pr_close_comment(agent_id : String) -> String {
  "Closed automatically by Choir: owning leaf `" +
  agent_id +
  "` was killed by parent, so this PR is no longer active."
}

///|
fn stale_pr_close_command(
  project_dir : String,
  pr_number : Int,
  agent_id : String,
) -> @workspace.Command {
  {
    program: "gh",
    args: [
      "pr",
      "close",
      pr_number.to_string(),
      "--comment",
      stale_pr_close_comment(agent_id),
    ],
    workdir: Some(project_dir),
  }
}

///|
fn stale_pr_close_failure_detail(output : String) -> String {
  let trimmed = output.trim().to_string()
  if trimmed == "" {
    ""
  } else if trimmed.length() <= 160 {
    trimmed
  } else {
    trimmed[:160].to_string() + "..."
  }
}

///|
pub(all) struct PlannedDelivery {
  recipient_id : String
  sender_id : String
  body : String
  status : @types.Status
  delivery : @message.DeliveryMethod
} derive(Debug, Eq)

///|
fn durable_delivery_message_id(
  state : ServerState,
  recipient_id : String,
  sender_id : String,
  body : String,
  status : @types.Status,
  now_ms : Int64,
) -> String {
  let hash_input = state.run_id +
    "|" +
    recipient_id +
    "|" +
    sender_id +
    "|" +
    status.to_wire_string() +
    "|" +
    body
  state.run_id +
  "-" +
  now_ms.to_string() +
  "-" +
  @runtime.simple_hash(hash_input).to_string()
}

///|
fn ServerState::append_outbox_snapshot(
  self : ServerState,
  message : @outbox.OutboxMessage,
) -> Result[Unit, @types.ChoirError] {
  if @outbox.append_outbox_snapshot(
      self.append_file,
      self.config.project_dir,
      message,
    ) {
    Ok(())
  } else {
    Err(
      @types.ChoirError::workspace_error(
        "failed to append outbox snapshot for " + message.recipient_id,
      ),
    )
  }
}

///|
fn ServerState::write_recipient_outbox_snapshots(
  self : ServerState,
  recipient_id : String,
  messages : Array[@outbox.OutboxMessage],
) -> Result[Unit, @types.ChoirError] {
  if @outbox.write_recipient_outbox(
      self.write_file_atomic,
      self.config.project_dir,
      recipient_id,
      messages,
    ) {
    Ok(())
  } else {
    Err(
      @types.ChoirError::workspace_error(
        "failed to rewrite outbox for " + recipient_id,
      ),
    )
  }
}

///|
async fn ServerState::durable_dispatch_planned(
  self : ServerState,
  planned : PlannedDelivery,
  runner : async (Array[@workspace.Command]) -> Array[Int],
) -> Result[Unit, @types.ChoirError] {
  let created_at = @poller.now_sec()
  let initial = @outbox.OutboxMessage::new(
    durable_delivery_message_id(
      self,
      planned.recipient_id,
      planned.sender_id,
      planned.body,
      planned.status,
      @env.now().reinterpret_as_int64(),
    ),
    planned.sender_id,
    planned.recipient_id,
    planned.body,
    planned.status,
    planned.delivery,
    created_at,
    created_at + @outbox.default_outbox_ttl_sec,
  )
  match self.append_outbox_snapshot(initial) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  match
    @tools.execute_delivery(
      planned.delivery,
      runner,
      project_dir=self.config.project_dir,
    ) {
    Ok(_) => {
      let delivered = initial.mark_delivered(@poller.now_sec())
      match self.append_outbox_snapshot(delivered) {
        Ok(_) => Ok(())
        Err(e) => Err(e)
      }
    }
    Err(e) => {
      let failed = initial.record_failed_attempt(@poller.now_sec(), e.message())
      match self.append_outbox_snapshot(failed) {
        Ok(_) => Err(e)
        Err(write_err) => Err(write_err)
      }
    }
  }
}

///|
async fn ServerState::durable_deliver_to_agent(
  self : ServerState,
  recipient : @types.Agent,
  sender_id : String,
  body : String,
  status : @types.Status,
  runner : async (Array[@workspace.Command]) -> Array[Int],
) -> Result[Unit, @types.ChoirError] {
  let delivery = @message.plan_delivery(recipient, sender_id, body, status)
  self.durable_dispatch_planned(
    {
      recipient_id: recipient.agent_id.to_string(),
      sender_id,
      body,
      status,
      delivery,
    },
    runner,
  )
}

///|
async fn ServerState::durable_deliver_to_parent(
  self : ServerState,
  sender_id : String,
  body : String,
  status : @types.Status,
  runner : async (Array[@workspace.Command]) -> Array[Int],
) -> Result[Unit, @types.ChoirError] {
  try self.resolve_parent_for_delivery(sender_id) catch {
    e =>
      Err(
        @types.ChoirError::workspace_error(
          @types.choir_error_message_from_caught(e),
        ),
      )
  } noraise {
    parent =>
      self.durable_deliver_to_agent(parent, sender_id, body, status, runner)
  }
}

///|
async fn deliver_stale_pr_reconciliation_message(
  state : ServerState,
  pr : @poller.TrackedPR,
  message : String,
  status : @types.Status,
  runner : async (Array[@workspace.Command]) -> Array[Int],
) -> Unit {
  ignore(state.durable_deliver_to_parent(pr.agent_id, message, status, runner))
}

///|
async fn reconcile_killed_agent_tracked_prs(
  state : ServerState,
  agent_id : String,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  capture : async (@workspace.Command) -> (Int, String),
) -> Unit {
  let prs = tracked_prs_for_agent(state, agent_id)
  if prs.length() == 0 {
    return
  }
  let mut wrote_state = false
  for pr in prs {
    match state.poller.get(pr.pr_number) {
      Some(current) => {
        state.poller.restore({ ..current, orphan_reconciling: true })
        wrote_state = true
      }
      None => continue
    }
    let (exit_code, output) = capture(
      stale_pr_close_command(
        state.config.project_dir,
        pr.pr_number,
        pr.agent_id,
      ),
    )
    if exit_code == 0 {
      state.poller.untrack(pr.pr_number)
      append_poller_delivery_line(
        state.append_file,
        state.config.project_dir,
        "stale pr auto-closed pr=" +
        pr.pr_number.to_string() +
        " agent=" +
        pr.agent_id,
      )
      deliver_stale_pr_reconciliation_message(
        state,
        pr,
        "[STALE PR CLOSED] PR #" +
        pr.pr_number.to_string() +
        " (" +
        pr.agent_id +
        ") — closed automatically after leaf was killed by parent",
        @types.Status::Info,
        runner,
      )
    } else {
      let detail = stale_pr_close_failure_detail(output)
      match state.poller.get(pr.pr_number) {
        Some(current) =>
          state.poller.restore({
            ..current,
            orphan_notified: true,
            orphan_reconciling: false,
          })
        None => ()
      }
      append_poller_delivery_line(
        state.append_file,
        state.config.project_dir,
        "stale pr auto-close failed pr=" +
        pr.pr_number.to_string() +
        " agent=" +
        pr.agent_id +
        " exit=" +
        exit_code.to_string(),
      )
      let detail_suffix = if detail == "" { "" } else { ": " + detail }
      deliver_stale_pr_reconciliation_message(
        state,
        pr,
        "[STALE PR CLOSE FAILED] PR #" +
        pr.pr_number.to_string() +
        " (" +
        pr.agent_id +
        ") — auto-close after leaf kill failed; manual cleanup may be needed" +
        detail_suffix,
        @types.Status::Failure,
        runner,
      )
    }
  }
  if wrote_state {
    ignore(state.poller.write_state_file(state.config.project_dir))
  }
}

///|
fn request_span_name(req : @types.Request) -> String {
  if req.req_method == "tools/list" {
    "tools/list"
  } else {
    "tools/call " + req.name
  }
}

///|
fn emit_span(
  state : ServerState,
  req : @types.Request,
  start_ms : UInt64,
  end_ms : UInt64,
  resp : @types.Response,
) -> Unit {
  let name = request_span_name(req)
  let agent_id_str = request_agent_id(req).unwrap_or("")
  let role_str = req.role.to_wire_string()
  let status = resp.status_tag()
  let duration_ms = end_ms - start_ms
  let fields = [
    @moontrace.field("agent_id", agent_id_str),
    @moontrace.field("role", role_str),
    @moontrace.field("status", status),
    @moontrace.field("duration_ms", duration_ms),
  ]
  match resp.error_message() {
    Some(msg) => fields.push(@moontrace.field("error", msg))
    None => ()
  }
  @moontrace.info(name, fields~)
  match state.config.otlp_endpoint {
    Some(ep) => {
      let mt_span = @moontrace.span_with_trace(
        name,
        normalize_trace_id(state.run_id),
        fields~,
      )
      mt_span.start_time = start_ms
      mt_span.end_time = end_ms
      mt_span.status = if resp.is_ok() {
        @moontrace.Ok
      } else {
        @moontrace.SpanError
      }
      mt_span.status_message = resp.error_message().unwrap_or("")
      let otlp_span = @otlp.span_to_otlp(mt_span)
      export_otlp_span(otlp_span, ep)
    }
    None => ()
  }
  if agent_id_str != "" {
    let data : Map[String, Json] = {
      "tool": req.name.to_json(),
      "status": resp.status_tag().to_json(),
    }
    ignore(
      append_event(
        state.append_file,
        state.config.project_dir,
        agent_id_str,
        "tools.call",
        data.to_json(),
      ),
    )
  }
}

///|
pub async fn ServerState::handle(
  self : ServerState,
  req : @types.Request,
) -> @types.Response {
  self.handle_with_runner_and_capture(
    req,
    runner=@exec.run_sequence,
    capture=@exec.capture_command_merged,
  )
}

///|
pub async fn ServerState::handle_with_runner(
  self : ServerState,
  req : @types.Request,
  runner? : async (Array[@workspace.Command]) -> Array[Int] = @exec.run_sequence,
) -> @types.Response {
  self.handle_with_runner_and_capture(
    req,
    runner~,
    capture=@exec.capture_command_merged,
  )
}

///|
pub async fn ServerState::handle_with_runner_and_capture(
  self : ServerState,
  req : @types.Request,
  runner? : async (Array[@workspace.Command]) -> Array[Int] = @exec.run_sequence,
  capture? : async (@workspace.Command) -> (Int, String) = @exec.capture_command_merged,
) -> @types.Response {
  let start_ms = @env.now()
  let merged_pr_context : (String, String?)? = if req.name == "merge_pr" {
    match request_int_arg(req, "pr_number") {
      Some(pr_number) =>
        match self.poller.get(pr_number) {
          Some(tracked) =>
            Some((tracked.agent_id, evidence_optional_string(tracked.pr_url)))
          None =>
            // Poller doesn't have this PR (server restart, file_pr bypassed).
            // Fall back to scanning the registry for an agent in ReviewOwned
            // for this PR number.
            match
              @runtime.find_agent_for_pr_in_lifecycle(
                self.recovery_provider,
                self.config.project_dir,
                pr_number,
              ) {
              Some(agent_id) => Some((agent_id, None))
              None => None
            }
        }
      None => None
    }
  } else {
    None
  }
  let resp = if req.req_method == "tools/list" {
    @types.Response::ok({ "tools_list": "true" })
  } else {
    @tools.handle_request(
      self.tool_registry,
      req,
      project_dir=self.config.project_dir,
      session=self.config.terminal_session,
      runner~,
      capture~,
      extra_mcp_servers_json=self.config.extra_mcp_servers_json,
      shell_command=self.config.shell_command,
      listen_uds=self.config.listen_uds,
      listen_tcp=self.config.listen_tcp,
      tcp_auth_token=self.config.tcp_auth_token,
      agent_registry=Some(self.registry),
      mutex_registry=Some(self.mutex_registry),
      poller_state=Some(self.poller),
      plugins_json=self.config.plugins_json,
      pr_review=self.config.pr_review,
    ) catch {
      e => @tools.tool_response_err_from_caught(e)
    }
  }

  let effects = plan_post_tool_actions(
    req,
    resp,
    merged_agent_id=match merged_pr_context {
      Some((agent_id, _)) => Some(agent_id)
      None => None
    },
    self.poller,
    self.registry,
    self.config.project_dir,
    self.config.terminal_session,
  )
  // Yield like the legacy `fail_agent_with_runner` path so other fibers can observe registry
  // updates before teardown side effects run (kill_agent is entirely effect-driven now).
  if req.name == "kill_agent" {
    @async.sleep(0)
  }
  self.interpret_teardown_effects(effects, runner)
  if req.name == "kill_agent" && resp.is_ok() {
    match req.args.get("agent_id") {
      Some(agent_id) =>
        reconcile_killed_agent_tracked_prs(self, agent_id, runner, capture)
      None => ()
    }
  }

  let end_ms = @env.now()
  emit_span(self, req, start_ms, end_ms, resp)
  match merged_pr_context {
    Some((agent_id, pr_url)) =>
      append_merge_pr_evidence_if_needed(
        self,
        req,
        resp,
        Some(agent_id),
        pr_url,
      )
    None => append_merge_pr_evidence_if_needed(self, req, resp, None, None)
  }
  resp
}

///|
pub fn ServerState::register_agent(
  self : ServerState,
  agent : @types.Agent,
) -> Unit {
  self.clear_pending_disconnect(agent.agent_id.to_string())
  let agent_id = agent.agent_id.to_string()
  let lifecycle = match
    @phase.read_lifecycle(self.config.project_dir, agent_id) {
    Some(existing) =>
      match existing.process {
        @phase.ProcessState::Finalized(..) | @phase.ProcessState::Failed(..) =>
          existing
        _ => { ..existing, process: @phase.ProcessState::Connected }
      }
    None => @phase.lifecycle_for_agent(agent)
  }
  ignore(self.registry.upsert({ ..agent, state: lifecycle.to_agent_state() }))
  ignore(
    @phase.persist_lifecycle(self.config.project_dir, self.registry, lifecycle),
  )
  @phase.sync_parent_child_lifecycle(
    self.config.project_dir,
    self.config.terminal_session,
    self.registry,
    agent_id,
    lifecycle,
  )
}

///|
pub fn ServerState::apply_recovered_agent(
  self : ServerState,
  agent : @types.Agent,
  alive : Bool,
) -> Unit {
  try {
    self.register_agent(agent)
    if !alive {
      ignore(self.registry.set_alive(agent.agent_id.to_string(), false))
    }
  } catch {
    _ => ()
  }
}

///|
pub fn ServerState::restore_recovered_pr_tracking(
  self : ServerState,
  tracked : @poller.TrackedPR,
) -> Unit {
  self.poller.restore(tracked)
}

///|
pub fn ServerState::track_recovered_pr(
  self : ServerState,
  pr_number : Int,
  agent_id : String,
  branch : String,
  parent_branch : String,
  pr_url : String,
  created_at : Int64,
  review : @poller.ReviewState,
  review_bodies : String,
  sha : String,
  ci_rollup : @poller.CiRollupStatus,
  copilot_issue_comment_seen : Bool,
) -> Unit {
  self.poller.track_recovered(
    pr_number, agent_id, branch, parent_branch, pr_url, created_at, review, review_bodies,
    sha, ci_rollup, copilot_issue_comment_seen,
  )
}

///|
pub fn ServerState::sync_recovered_pr_lifecycle(
  self : ServerState,
  agent_id : String,
  pr : @runtime.OpenPR,
  review : @poller.ReviewState,
) -> Unit {
  let agent_opt = try self.registry.get(agent_id) catch {
    _ => None
  } noraise {
    a => Some(a)
  }
  let lifecycle = self.current_lifecycle(agent_id)
  let workflow = match lifecycle.workflow {
    @phase.WorkflowState::Dev(dev) =>
      @phase.WorkflowState::Dev(
        @runtime.recover_dev_lifecycle_for_pr(dev, pr.pr_number, pr.url, review),
      )
    other => other
  }
  let recovered = {
    ..lifecycle,
    workflow,
    process: match agent_opt {
      Some(agent) if agent.terminal_target is Some(_) =>
        @phase.ProcessState::Connected
      _ => lifecycle.process
    },
  }
  @phase.apply_recovered_lifecycle(
    self.config.project_dir,
    self.config.terminal_session,
    self.registry,
    agent_id,
    recovered,
  )
}

///|
pub fn ServerState::finalize_recovered_offline_agent(
  self : ServerState,
  agent_id : String,
) -> Unit {
  let lifecycle = self.current_lifecycle(agent_id)
  match lifecycle.process {
    @phase.ProcessState::Finalized(..) | @phase.ProcessState::Failed(..) => ()
    _ => {
      let finalized = {
        ..lifecycle,
        process: @phase.ProcessState::Finalized(
          reason=@phase.FinalizeReason::RecoveredDone,
        ),
      }
      @phase.apply_recovered_lifecycle(
        self.config.project_dir,
        self.config.terminal_session,
        self.registry,
        agent_id,
        finalized,
      )
    }
  }
}

///|
pub async fn ServerState::persist_recovered_poller_state(
  self : ServerState,
) -> Unit {
  let tracked = []
  self.poller.tracked.each(fn(_k, v) { tracked.push(v) })
  (self.recovery_provider.write_poller_state)(self.config.project_dir, tracked)
}

///|
async fn ServerState::replay_outbox_recipient_ids(
  self : ServerState,
) -> Array[String] {
  let ids : Map[String, Bool] = {}
  for agent in self.registry.list() {
    ids.set(agent.agent_id.to_string(), true)
  }
  let outbox_files = (self.recovery_provider.list_agents_in_container)(
    self.config.project_dir,
    "outbox",
  )
  for filename in outbox_files {
    if !filename.has_suffix(".jsonl") {
      continue
    }
    let path = self.config.project_dir + "/.choir/outbox/" + filename
    let messages = @outbox.load_recipient_outbox_from_content(
      (self.read_file)(path),
    )
    if messages.length() == 0 {
      continue
    }
    ids.set(messages[0].recipient_id, true)
  }
  let recipient_ids = []
  ids.each(fn(recipient_id, _present) { recipient_ids.push(recipient_id) })
  recipient_ids
}

///|
pub async fn ServerState::replay_pending_outbox_with(
  self : ServerState,
  now : Int64,
  runner? : async (Array[@workspace.Command]) -> Array[Int] = @exec.run_sequence,
) -> Unit {
  for recipient_id in self.replay_outbox_recipient_ids() {
    let messages = @outbox.load_recipient_outbox(
      self.read_file,
      self.config.project_dir,
      recipient_id,
    )
    if messages.length() == 0 {
      continue
    }
    let updated : Array[@outbox.OutboxMessage] = []
    for message in messages {
      let next = if message.delivery_state !=
        @outbox.OutboxDeliveryState::Pending {
        message
      } else if now >= message.expires_at {
        message.mark_expired()
      } else {
        match
          @tools.execute_delivery(
            message.delivery_method,
            runner,
            project_dir=self.config.project_dir,
          ) {
          Ok(_) => message.mark_delivered(now)
          Err(e) => message.record_failed_attempt(now, e.message())
        }
      }
      updated.push(next)
    }
    ignore(self.write_recipient_outbox_snapshots(recipient_id, updated))
  }
}

///|
pub async fn ServerState::replay_pending_outbox(
  self : ServerState,
  runner? : async (Array[@workspace.Command]) -> Array[Int] = @exec.run_sequence,
) -> Unit {
  self.replay_pending_outbox_with(@poller.now_sec(), runner~)
}

///|
pub fn ServerState::sweep_outbox(self : ServerState, now : Int64) -> Unit {
  for agent in self.registry.list() {
    let recipient_id = agent.agent_id.to_string()
    let messages = @outbox.load_recipient_outbox(
      self.read_file,
      self.config.project_dir,
      recipient_id,
    )
    if messages.length() == 0 {
      continue
    }
    let updated : Array[@outbox.OutboxMessage] = []
    for message in messages {
      if message.delivery_state == @outbox.OutboxDeliveryState::Pending &&
        now >= message.expires_at {
        updated.push(message.mark_expired())
      } else {
        updated.push(message)
      }
    }
    ignore(self.write_recipient_outbox_snapshots(recipient_id, updated))
  }
}

///|
pub fn ServerState::notify_parent(
  self : ServerState,
  caller_id : String,
  message : String,
  status : @types.Status,
) -> @message.DeliveryMethod raise @types.ChoirError {
  let parent = self.resolve_parent_for_delivery(caller_id)
  @message.plan_delivery(parent, caller_id, message, status)
}

///|
fn ServerState::resolve_parent_by_id(
  self : ServerState,
  parent_id : String,
) -> @types.Agent raise @types.ChoirError {
  @phase.resolve_agent_with_fallback(
    self.config.project_dir,
    self.config.terminal_session,
    self.registry,
    parent_id,
  )
}

///|
fn ServerState::resolve_parent_for_delivery(
  self : ServerState,
  caller_id : String,
) -> @types.Agent raise @types.ChoirError {
  @phase.resolve_parent_with_fallback(
    self.config.project_dir,
    self.config.terminal_session,
    self.registry,
    caller_id,
  )
}

///|
fn render_parent_next_action(
  pr_number : Int,
  parent_branch : String?,
  merge_mode : @poller.MergeOperatorMode,
) -> String {
  @poller.merge_ready_next_action(pr_number, parent_branch, merge_mode)
}

///|
/// When review-wait already timed out with no review in snapshot, CI-only parent lines must not read like ordinary progress.
fn parent_poll_ci_escalation_prefix(tracked : @poller.TrackedPR) -> String {
  if @poller.tl_tracked_pr_copilot_review_silent_escalation_active(tracked) {
    "Review timeout already fired — no review in snapshot. Run: gh pr edit --add-reviewer @copilot\n\n"
  } else {
    ""
  }
}

///|
fn task_contract_for_agent(
  project_dir : String,
  registry : @registry.AgentRegistry,
  agent_id : String,
) -> @types.TaskContract? {
  let agent_workspace = Some(registry.get(agent_id).workspace) catch {
    _ => None
  }
  @workspace.task_contract_for_agent_workspace(
    project_dir,
    agent_workspace,
    @phase.extract_slug(agent_id),
  )
}

///|
fn local_config_for_agent(
  project_dir : String,
  registry : @registry.AgentRegistry,
  agent_id : String,
) -> @types.LocalConfig? {
  let agent_workspace = Some(registry.get(agent_id).workspace) catch {
    _ => None
  }
  let candidate_paths : Array[String] = []
  match agent_workspace {
    Some(w) => if w != "" { candidate_paths.push(w + "/config.local.toml") }
    None => ()
  }
  let fallback_path = @workspace.worktree_path(
      project_dir,
      @phase.extract_slug(agent_id),
    ) +
    "/config.local.toml"
  if !candidate_paths.contains(fallback_path) {
    candidate_paths.push(fallback_path)
  }
  for path in candidate_paths {
    let content = @sys.read_file(path)
    if content == "" {
      continue
    }
    match @config.parse_local_config(content) {
      Ok(local_cfg) => return Some(local_cfg)
      Err(_) => ()
    }
  }
  None
}

///|
fn automerge_enabled_for_agent(
  config : @types.Config,
  local_cfg : @types.LocalConfig?,
) -> Bool {
  match local_cfg {
    Some(cfg) =>
      match cfg.automerge {
        Some(value) => value
        None => config.automerge
      }
    None => config.automerge
  }
}

///|
fn automerge_candidate_event(event : @poller.PollEvent) -> Bool {
  match event {
    @poller.PollEvent::PRReady(_)
    | @poller.PollEvent::CIFailureCleared(_)
    | @poller.PollEvent::CILatestHeadRollupSucceeded(_)
    | @poller.PollEvent::CopilotIssueCommentSeen(_)
    | @poller.PollEvent::MergeReady(_)
    | @poller.PollEvent::ReviewThreadsResolved(_) => true
    _ => false
  }
}

///|
fn should_fetch_unresolved_threads_for_pending_event(
  event : @poller.PollEvent,
  automerge_enabled : Bool,
) -> Bool {
  match event {
    @poller.PollEvent::CIFailureCleared(_)
    | @poller.PollEvent::CILatestHeadRollupSucceeded(_)
    | @poller.PollEvent::ReviewThreadsResolved(_) => true
    _ => automerge_enabled && automerge_candidate_event(event)
  }
}

///|
fn merge_execution_mode_for_request(
  req : @types.Request,
) -> @evidence.MergeExecutionMode {
  if request_bool_arg(req, "force").unwrap_or(false) {
    return @evidence.MergeExecutionMode::ForceOverride
  }
  if request_bool_arg(req, "automerge").unwrap_or(false) {
    return @evidence.MergeExecutionMode::ServerAutomerge
  }
  @evidence.MergeExecutionMode::Manual
}

///|
fn automerge_parent_caller_id_for_tracked_pr(
  state : ServerState,
  tracked : @poller.TrackedPR,
) -> String? {
  Some(state.resolve_parent_for_delivery(tracked.agent_id).agent_id.to_string()) catch {
    _ => None
  }
}

///|
fn automerge_merge_pr_request(
  tracked : @poller.TrackedPR,
  caller_id : String,
) -> @types.Request {
  let parent_branch = if tracked.parent_branch == "" {
    "main"
  } else {
    tracked.parent_branch
  }
  let args : Map[String, Json] = {
    "pr_number": tracked.pr_number.to_json(),
    "caller_id": caller_id.to_json(),
    "parent_branch": parent_branch.to_json(),
    "automerge": true.to_json(),
  }
  {
    req_method: "tools/call",
    role: @types.Role::TL,
    name: "merge_pr",
    args: @types.RequestArgs::from_values(args),
  }
}

///|
async fn maybe_trigger_automerge_for_pending_event(
  state : ServerState,
  event : @poller.PollEvent,
  tracked : @poller.TrackedPR,
  unresolved_threads : Int?,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  capture? : async (@workspace.Command) -> (Int, String) = @exec.capture_command_merged,
) -> Bool {
  if !automerge_candidate_event(event) {
    return false
  }
  let local_cfg = local_config_for_agent(
    state.config.project_dir,
    state.registry,
    tracked.agent_id,
  )
  if !automerge_enabled_for_agent(state.config, local_cfg) {
    return false
  }
  let task_contract = task_contract_for_agent(
    state.config.project_dir,
    state.registry,
    tracked.agent_id,
  )
  let decision = @poller.merge_policy_decision_for_tracked_pr(
    tracked,
    unresolved_threads,
    task_contract~,
  )
  guard decision is @policy.MergeDecision::MergeNow(_) else { return false }
  let caller_id = match
    automerge_parent_caller_id_for_tracked_pr(state, tracked) {
    Some(value) => value
    None => return false
  }
  append_poller_delivery_line(
    state.append_file,
    state.config.project_dir,
    "automerge attempt pr=" +
    tracked.pr_number.to_string() +
    " agent=" +
    tracked.agent_id,
  )
  let resp = state.handle_with_runner_and_capture(
    automerge_merge_pr_request(tracked, caller_id),
    runner~,
    capture~,
  )
  append_poller_delivery_line(
    state.append_file,
    state.config.project_dir,
    "automerge result pr=" +
    tracked.pr_number.to_string() +
    " status=" +
    resp.status_tag(),
  )
  resp.is_ok()
}

///|
fn evidence_review_state_from_snapshot(
  review : @poller.ReviewState,
) -> @evidence.EvidenceReviewState {
  match review {
    @poller.ReviewState::None_ => @evidence.EvidenceReviewState::None_
    @poller.ReviewState::Commented => @evidence.EvidenceReviewState::Commented
    @poller.ReviewState::Approved => @evidence.EvidenceReviewState::Approved
    @poller.ReviewState::ChangesRequested =>
      @evidence.EvidenceReviewState::ChangesRequested
  }
}

///|
fn evidence_ci_status_from_snapshot(
  ci : @poller.CiRollupStatus,
) -> @evidence.EvidenceCiStatus {
  match ci {
    @poller.CiRollupStatus::Unknown => @evidence.EvidenceCiStatus::Unknown
    @poller.CiRollupStatus::InProgress => @evidence.EvidenceCiStatus::InProgress
    @poller.CiRollupStatus::Success => @evidence.EvidenceCiStatus::Success
    @poller.CiRollupStatus::Failure => @evidence.EvidenceCiStatus::Failure
  }
}

///|
fn evidence_optional_string(value : String) -> String? {
  if value == "" {
    None
  } else {
    Some(value)
  }
}

///|
fn evidence_events_for_poll_snapshot(
  tracked : @poller.TrackedPR,
  event : @poller.PollEvent,
  unresolved_threads_for_recheck : Int?,
) -> Array[@evidence.EvidenceEvent] {
  let events : Array[@evidence.EvidenceEvent] = [
    @evidence.EvidenceEvent::ReviewObserved(
      state=evidence_review_state_from_snapshot(tracked.last_review_state),
      body=evidence_optional_string(tracked.last_review_bodies),
    ),
    @evidence.EvidenceEvent::CiObserved(
      status=evidence_ci_status_from_snapshot(tracked.last_ci_rollup),
      head_sha=evidence_optional_string(tracked.last_sha),
    ),
  ]
  match unresolved_threads_for_recheck {
    Some(count) => events.push(@evidence.EvidenceEvent::ThreadsObserved(count~))
    None => events.push(@evidence.EvidenceEvent::ThreadsUnobserved)
  }
  if tracked.copilot_issue_comment_seen {
    events.push(@evidence.EvidenceEvent::CopilotIssueCommentObserved)
  } else {
    events.push(@evidence.EvidenceEvent::CopilotIssueCommentUnobserved)
  }
  match event {
    @poller.PollEvent::PRMerged(merged_pr) =>
      events.push(
        @evidence.EvidenceEvent::MergeObserved(
          pr_number=merged_pr.pr_number,
          pr_url=evidence_optional_string(merged_pr.pr_url),
        ),
      )
    @poller.PollEvent::ReviewThreadsResolved(_) =>
      events.push(@evidence.EvidenceEvent::ReviewThreadsResolved)
    _ => ()
  }
  events
}

///|
fn append_poll_snapshot_evidence(
  state : ServerState,
  tracked : @poller.TrackedPR,
  event : @poller.PollEvent,
  unresolved_threads_for_recheck : Int?,
) -> Unit {
  for
    evidence_event in evidence_events_for_poll_snapshot(
      tracked, event, unresolved_threads_for_recheck,
    ) {
    ignore(
      append_evidence_event(
        state.append_file,
        state.config.project_dir,
        tracked.agent_id,
        evidence_event,
      ),
    )
  }
}

///|
fn append_merge_pr_evidence_if_needed(
  state : ServerState,
  req : @types.Request,
  resp : @types.Response,
  merged_agent_id : String?,
  merged_pr_url : String?,
) -> Unit {
  guard req.name == "merge_pr" else { return }
  let pr_number = match request_int_arg(req, "pr_number") {
    Some(value) => value
    None => return
  }
  let force = request_bool_arg(req, "force").unwrap_or(false)
  let merge_mode = merge_execution_mode_for_request(req)
  match merged_agent_id {
    Some(agent_id) => {
      ignore(
        append_evidence_event(
          state.append_file,
          state.config.project_dir,
          agent_id,
          @evidence.EvidenceEvent::MergeExecutionRequested(mode=merge_mode),
        ),
      )
      if force {
        ignore(
          append_evidence_event(
            state.append_file,
            state.config.project_dir,
            agent_id,
            @evidence.EvidenceEvent::UserOverrideObserved(
              scope="merge_pr.force",
              reason=Some("merge_pr invoked with force=true"),
            ),
          ),
        )
      }
      if resp.is_ok() {
        ignore(
          append_evidence_event(
            state.append_file,
            state.config.project_dir,
            agent_id,
            @evidence.EvidenceEvent::MergeObserved(
              pr_number~,
              pr_url=merged_pr_url,
            ),
          ),
        )
      }
    }
    None => ()
  }
}

///|
/// Canonical TL decision line for parent delivery (see `@poller.plan_tl_poll_event_parent`).
fn parent_poll_tl_decision_suffix(
  tracked : @poller.TrackedPR,
  event : @poller.PollEvent,
  unresolved_threads_for_recheck : Int?,
  merge_mode : @poller.MergeOperatorMode,
) -> String {
  let category = @poller.plan_tl_poll_event_parent(
    event, tracked, unresolved_threads_for_recheck,
  )
  let sentence = match category {
    @poller.TlTrackedPrWorkflowCategory::MergeGateOpenPendingPolicyConfirmation =>
      @poller.tl_merge_gate_sentence(merge_mode)
    _ => @poller.tl_tracked_pr_workflow_category_sentence(category)
  }
  match event {
    PRMerged(_) => ""
    _ => "\nTLDecision: " + sentence
  }
}

///|
fn parent_merge_policy_line(
  tracked : @poller.TrackedPR,
  unresolved_threads_for_recheck : Int?,
  task_contract? : @types.TaskContract? = None,
) -> String {
  "\n" +
  @poller.merge_policy_summary_line(
    tracked,
    unresolved_threads_for_recheck,
    task_contract~,
  )
}

///|
fn parent_poll_event_message(
  tracked : @poller.TrackedPR,
  project_dir : String,
  event : @poller.PollEvent,
  unresolved_threads_for_recheck : Int?,
  task_contract? : @types.TaskContract? = None,
  merge_mode? : @poller.MergeOperatorMode = @poller.MergeOperatorMode::Manual,
) -> (String, @types.Status)? {
  let agent_id = tracked.agent_id
  let branch = tracked.branch
  let parent_branch = if tracked.parent_branch == "" {
    None
  } else {
    Some(tracked.parent_branch)
  }
  let pr_url = if tracked.pr_url == "" {
    ""
  } else {
    "\npr_url: " + tracked.pr_url
  }
  match event {
    PRReady(n) => {
      let message = "[PR READY] " +
        agent_id +
        " PR #" +
        n.to_string() +
        " approved (not merged yet)\n" +
        "branch: " +
        branch +
        "\n" +
        "parent_branch: " +
        parent_branch.unwrap_or("<unknown>") +
        pr_url +
        "\n" +
        @poller.merge_mode_line(merge_mode) +
        "\n" +
        @poller.premerge_wait_line(merge_mode) +
        "\n" +
        render_parent_next_action(n, parent_branch, merge_mode) +
        parent_poll_tl_decision_suffix(
          tracked, event, unresolved_threads_for_recheck, merge_mode,
        )
      Some((message, @types.Status::Success))
    }
    FixesPushed(n) => {
      let message = "[FIXES PUSHED] " +
        agent_id +
        " PR #" +
        n.to_string() +
        " has new commits after review (not merged yet)\n" +
        "branch: " +
        branch +
        "\n" +
        "parent_branch: " +
        parent_branch.unwrap_or("<unknown>") +
        pr_url +
        "\n" +
        "Pre-merge: re-check the PR; merge only after review is clear and merge_pr succeeds.\n" +
        "Next action: re-check the PR and merge when ready." +
        parent_poll_tl_decision_suffix(
          tracked, event, unresolved_threads_for_recheck, merge_mode,
        )
      Some((message, @types.Status::Info))
    }
    ReviewTimeout(n) => {
      let message = "[REVIEW TIMEOUT] " +
        agent_id +
        " PR #" +
        n.to_string() +
        " — no review after timeout\n" +
        "branch: " +
        branch +
        "\n" +
        "parent_branch: " +
        parent_branch.unwrap_or("<unknown>") +
        pr_url +
        "\n" +
        "Next action: gh pr edit --add-reviewer @copilot" +
        parent_poll_tl_decision_suffix(
          tracked, event, unresolved_threads_for_recheck, merge_mode,
        )
      Some((message, @types.Status::Failure))
    }
    ReviewReceived(n, comments) =>
      if comments == "" {
        Some(
          (
            "[REVIEW] " +
            agent_id +
            " PR #" +
            n.to_string() +
            " has review comments\n" +
            "branch: " +
            branch +
            "\n" +
            "parent_branch: " +
            parent_branch.unwrap_or("<unknown>") +
            pr_url +
            parent_poll_tl_decision_suffix(
              tracked, event, unresolved_threads_for_recheck, merge_mode,
            ),
            @types.Status::Info,
          ),
        )
      } else {
        Some(
          (
            "[REVIEW] " +
            agent_id +
            " PR #" +
            n.to_string() +
            " has review comments:\n" +
            comments +
            parent_poll_tl_decision_suffix(
              tracked, event, unresolved_threads_for_recheck, merge_mode,
            ),
            @types.Status::Info,
          ),
        )
      }
    ReviewCommented(_, _) => None
    CIFailed(n) =>
      Some(
        (
          "[CI FAILED] " +
          agent_id +
          " PR #" +
          n.to_string() +
          " CI checks failing\n" +
          "branch: " +
          branch +
          "\n" +
          "parent_branch: " +
          parent_branch.unwrap_or("<unknown>") +
          pr_url +
          parent_poll_tl_decision_suffix(
            tracked, event, unresolved_threads_for_recheck, merge_mode,
          ),
          @types.Status::Failure,
        ),
      )
    CIFailureCleared(n) => {
      let summary = @tools.format_tl_pr_recheck_summary(
        tracked,
        project_dir,
        unresolved_threads_for_recheck,
        task_contract~,
      )
      let prefix = parent_poll_ci_escalation_prefix(tracked)
      Some(
        (
          "[CI FAILURE CLEARED] " +
          agent_id +
          " PR #" +
          n.to_string() +
          " latest head: rollup no longer reports FAILURE/ERROR (may still be pending or incomplete; not a merge/review verdict)\n" +
          "branch: " +
          branch +
          "\n" +
          "parent_branch: " +
          parent_branch.unwrap_or("<unknown>") +
          pr_url +
          "\n" +
          prefix +
          "Next action: re-check the PR thread and full CI status on GitHub before merging or requesting review.\n\n" +
          summary +
          parent_poll_tl_decision_suffix(
            tracked, event, unresolved_threads_for_recheck, merge_mode,
          ),
          @types.Status::Info,
        ),
      )
    }
    CILatestHeadRollupSucceeded(n) => {
      let summary = @tools.format_tl_pr_recheck_summary(
        tracked,
        project_dir,
        unresolved_threads_for_recheck,
        task_contract~,
      )
      let prefix = parent_poll_ci_escalation_prefix(tracked)
      Some(
        (
          "[CI LATEST HEAD] " +
          agent_id +
          " PR #" +
          n.to_string() +
          " GitHub Actions rollup reports all checks successful on the current head (not merge approval, mergeability, or review verdict).\n" +
          "branch: " +
          branch +
          "\n" +
          "parent_branch: " +
          parent_branch.unwrap_or("<unknown>") +
          pr_url +
          "\n" +
          prefix +
          "Next action: re-check Copilot/review thread and branch policy, then merge_pr only if appropriate.\n\n" +
          summary +
          parent_poll_tl_decision_suffix(
            tracked, event, unresolved_threads_for_recheck, merge_mode,
          ),
          @types.Status::Info,
        ),
      )
    }
    CopilotIssueCommentSeen(n) => {
      let summary = @tools.format_tl_pr_recheck_summary(
        tracked,
        project_dir,
        unresolved_threads_for_recheck,
        task_contract~,
      )
      Some(
        (
          "[COPILOT ISSUE COMMENT] " +
          agent_id +
          " PR #" +
          n.to_string() +
          " — GitHub Copilot issue-thread comment observed (REST). Re-check remaining review/CI/thread gates and policy.\n" +
          "branch: " +
          branch +
          "\n" +
          "parent_branch: " +
          parent_branch.unwrap_or("<unknown>") +
          pr_url +
          "\n\n" +
          summary +
          parent_poll_tl_decision_suffix(
            tracked, event, unresolved_threads_for_recheck, merge_mode,
          ),
          @types.Status::Info,
        ),
      )
    }
    PRMerged(_) => None
    MergeReady(n) => {
      let message = "[MERGE READY] " +
        agent_id +
        " PR #" +
        n.to_string() +
        " — reviewed, CI green, merge gate open\n" +
        "branch: " +
        branch +
        "\n" +
        "parent_branch: " +
        parent_branch.unwrap_or("<unknown>") +
        pr_url +
        "\n" +
        @poller.merge_mode_line(merge_mode) +
        parent_merge_policy_line(
          tracked,
          unresolved_threads_for_recheck,
          task_contract~,
        ) +
        "\n" +
        render_parent_next_action(n, parent_branch, merge_mode) +
        parent_poll_tl_decision_suffix(
          tracked, event, unresolved_threads_for_recheck, merge_mode,
        )
      Some((message, @poller.merge_ready_status(merge_mode)))
    }
    ReviewThreadsResolved(n) => {
      let summary = @tools.format_tl_pr_recheck_summary(
        tracked,
        project_dir,
        unresolved_threads_for_recheck,
        task_contract~,
      )
      let message = "[THREADS RESOLVED] " +
        agent_id +
        " PR #" +
        n.to_string() +
        " review threads were marked resolved (not a merge/review verdict).\n" +
        "branch: " +
        branch +
        "\n" +
        "parent_branch: " +
        parent_branch.unwrap_or("<unknown>") +
        pr_url +
        "\n\n" +
        summary +
        parent_poll_tl_decision_suffix(
          tracked, event, unresolved_threads_for_recheck, merge_mode,
        )
      Some((message, @types.Status::Info))
    }
  }
}

///|
fn poll_event_pr_number(event : @poller.PollEvent) -> Int {
  match event {
    PRReady(n) => n
    ReviewReceived(n, _) => n
    ReviewCommented(n, _) => n
    FixesPushed(n) => n
    ReviewTimeout(n) => n
    CIFailed(n) => n
    CIFailureCleared(n) => n
    CILatestHeadRollupSucceeded(n) => n
    CopilotIssueCommentSeen(n) => n
    PRMerged(pr) => pr.pr_number
    MergeReady(n) => n
    ReviewThreadsResolved(n) => n
  }
}

///|
fn poll_event_tracked_snapshot(
  event : @poller.PollEvent,
  tracked : @poller.TrackedPR?,
) -> @poller.TrackedPR? {
  match event {
    PRMerged(pr) => Some(pr)
    _ => tracked
  }
}

///|
fn poll_event_is_external_merge(event : @poller.PollEvent) -> Bool {
  match event {
    PRMerged(_) => true
    _ => false
  }
}

///|
fn lifecycle_suppresses_poller_followups(
  lifecycle : @phase.AgentLifecycle,
) -> Bool {
  match lifecycle.process {
    @phase.ProcessState::Finalized(..) | @phase.ProcessState::Failed(..) => true
    @phase.ProcessState::Finalizing(reason=@phase.FinalizeReason::Merged) =>
      true
    _ => false
  }
}

///|
/// Cap API review bodies for terminal injection (Copilot/GitHub can return full PR markdown).
let review_summary_pane_max_chars : Int = 2500

///|
fn clamp_review_summary_for_pane(body : String) -> String {
  let suffix = "\n... [truncated; open PR on GitHub for full review text]"
  if body.length() <= review_summary_pane_max_chars {
    body
  } else {
    body[0:review_summary_pane_max_chars].to_string() + suffix
  }
}

///|
/// Direct review/CI injection for the owning leaf pane (`plan_delivery` adds `[from: …]`).
/// Parent still receives `parent_poll_event_message` for triage/merge except
/// `ReviewCommented` (non-blocking thread goes to the leaf only).
/// `tracked` supplies poller snapshot for CI lines when review-wait timeout escalation applies.
fn leaf_poll_review_injection_message(
  event : @poller.PollEvent,
  tracked : @poller.TrackedPR?,
) -> (String, @types.Status)? {
  match event {
    ReviewReceived(n, body) =>
      Some(
        (
          if body == "" {
            "[REVIEW] PR #" + n.to_string() + ": changes requested"
          } else {
            "[REVIEW] PR #" +
            n.to_string() +
            ": " +
            clamp_review_summary_for_pane(body)
          },
          @types.Status::Info,
        ),
      )
    ReviewCommented(n, body) =>
      Some(
        (
          if body == "" {
            "[REVIEW] PR #" + n.to_string() + ": non-blocking review comments"
          } else {
            "[REVIEW] PR #" +
            n.to_string() +
            ": " +
            clamp_review_summary_for_pane(body)
          },
          @types.Status::Info,
        ),
      )
    CIFailed(n) =>
      Some(
        (
          "[REVIEW] PR #" + n.to_string() + ": CI checks failing",
          @types.Status::Failure,
        ),
      )
    CIFailureCleared(n) => {
      let base = "[REVIEW] PR #" +
        n.to_string() +
        ": CI no longer reports failure on latest head — verify full status on GitHub (not merge or approval)"
      let msg = match tracked {
        Some(pr) =>
          if @poller.tl_tracked_pr_copilot_review_silent_escalation_active(pr) {
            "[REVIEW] PR #" +
            n.to_string() +
            ": CI cleared but still no review. Run: gh pr edit --add-reviewer @copilot"
          } else {
            base
          }
        None => base
      }
      Some((msg, @types.Status::Info))
    }
    CILatestHeadRollupSucceeded(n) => {
      let base = "[REVIEW] PR #" +
        n.to_string() +
        ": Actions rollup: all checks successful on latest head — re-check review thread and policy (not merge or approval by itself)"
      let msg = match tracked {
        Some(pr) =>
          if @poller.tl_tracked_pr_copilot_review_silent_escalation_active(pr) {
            "[REVIEW] PR #" +
            n.to_string() +
            ": CI green but still no review. Run: gh pr edit --add-reviewer @copilot"
          } else {
            base
          }
        None => base
      }
      Some((msg, @types.Status::Info))
    }
    CopilotIssueCommentSeen(n) =>
      Some(
        (
          "[REVIEW] PR #" +
          n.to_string() +
          ": GitHub Copilot issue-thread comment observed — re-check remaining gates (not merge or approval by itself)",
          @types.Status::Info,
        ),
      )
    PRReady(n) =>
      Some(
        (
          "[REVIEW] PR #" +
          n.to_string() +
          ": approved (not merged until merge_pr succeeds)",
          @types.Status::Success,
        ),
      )
    FixesPushed(_) => None
    ReviewTimeout(_) => None
    PRMerged(_) => None
    MergeReady(_) => None
    ReviewThreadsResolved(n) =>
      Some(
        (
          "[REVIEW] PR #" +
          n.to_string() +
          ": review threads marked resolved (re-check state)",
          @types.Status::Info,
        ),
      )
  }
}

///|
priv struct PendingPollParentRow {
  tracked : @poller.TrackedPR
  leaf_agent_id : String
  message : String
  status : @types.Status
  category : @poller.TlTrackedPrWorkflowCategory
  merge_mode : @poller.MergeOperatorMode
}

///|
fn supervisor_children_len_for_parent(
  project_dir : String,
  parent_id : String,
) -> Int {
  match @phase.read_lifecycle(project_dir, parent_id) {
    Some(lc) =>
      match lc.workflow {
        @phase.WorkflowState::Supervisor(
          @phase.SupervisorLifecycle::Supervising(children~, ..)
        ) => children.length()
        @phase.WorkflowState::Supervisor(
          @phase.SupervisorLifecycle::WaveComplete(children~, ..)
        ) => children.length()
        _ => 0
      }
    None => 0
  }
}

///|
fn build_agent_wave_map(
  poller : @poller.PollerState,
  registry : @registry.AgentRegistry,
  project_dir : String,
) -> Map[String, (String, Int)] {
  let m : Map[String, (String, Int)] = {}
  for tracked in poller.tracked.values() {
    try {
      let parent = registry.get_parent(tracked.agent_id)
      let parent_id = parent.agent_id.to_string()
      match @phase.read_lifecycle(project_dir, parent_id) {
        Some(plc) =>
          match plc.workflow {
            @phase.WorkflowState::Supervisor(
              @phase.SupervisorLifecycle::Supervising(wave~, ..)
            ) => m.set(tracked.agent_id, (parent_id, wave))
            @phase.WorkflowState::Supervisor(
              @phase.SupervisorLifecycle::WaveComplete(wave~, ..)
            ) => m.set(tracked.agent_id, (parent_id, wave))
            _ => ()
          }
        None => ()
      }
    } catch {
      _ => ()
    }
  }
  m
}

///|
fn rollup_contains_entry(
  rollup : @poller.WaveRollup,
  t : @poller.WaveRollupEntry,
) -> Bool {
  for e in rollup.entries {
    if e == t {
      return true
    }
  }
  false
}

///|
fn row_in_any_multi_rollup(
  row : PendingPollParentRow,
  rollups : Array[@poller.WaveRollup],
) -> Bool {
  let t : @poller.WaveRollupEntry = {
    pr_number: row.tracked.pr_number,
    agent_id: row.leaf_agent_id,
    category: row.category,
  }
  for r in rollups {
    if rollup_contains_entry(r, t) {
      return true
    }
  }
  false
}

///|
fn rollup_rows_for(
  rows : Array[PendingPollParentRow],
  rollup : @poller.WaveRollup,
) -> Array[PendingPollParentRow] {
  let matched : Array[PendingPollParentRow] = []
  for row in rows {
    let t : @poller.WaveRollupEntry = {
      pr_number: row.tracked.pr_number,
      agent_id: row.leaf_agent_id,
      category: row.category,
    }
    if rollup_contains_entry(rollup, t) {
      matched.push(row)
    }
  }
  matched
}

///|
fn rollup_delivery_status(rows : Array[PendingPollParentRow]) -> @types.Status {
  let mut has_failure = false
  let mut has_success = false
  for row in rows {
    if row.status == @types.Status::Failure {
      has_failure = true
    }
    if row.status == @types.Status::Success {
      has_success = true
    }
  }
  if has_failure {
    @types.Status::Failure
  } else if has_success {
    @types.Status::Success
  } else {
    @types.Status::Info
  }
}

///|
fn rollup_merge_mode(
  rows : Array[PendingPollParentRow],
) -> @poller.MergeOperatorMode? {
  if rows.length() == 0 {
    return None
  }
  let mut has_manual = false
  let mut has_automerge = false
  for row in rows {
    match row.merge_mode {
      @poller.MergeOperatorMode::Manual => has_manual = true
      @poller.MergeOperatorMode::Automerge => has_automerge = true
      @poller.MergeOperatorMode::Mixed => {
        has_manual = true
        has_automerge = true
      }
    }
  }
  Some(
    if has_manual && has_automerge {
      @poller.MergeOperatorMode::Mixed
    } else if has_automerge {
      @poller.MergeOperatorMode::Automerge
    } else {
      @poller.MergeOperatorMode::Manual
    },
  )
}

///|
pub fn ServerState::plan_poll_event_deliveries(
  self : ServerState,
  event : @poller.PollEvent,
  agent_id : String,
  unresolved_threads_for_recheck : Int?,
  skip_parent? : Bool = false,
) -> Array[PlannedDelivery] {
  let deliveries : Array[PlannedDelivery] = []
  let tracked = self.poller.get(poll_event_pr_number(event))
  let leaf_agent_id = match tracked {
    Some(pr) => pr.agent_id
    None => agent_id
  }
  let leaf_owner = try self.registry.get(leaf_agent_id) catch {
    _ => None
  } noraise {
    agent => Some(agent)
  }
  match (tracked, event) {
    (Some(_), ReviewReceived(n, body)) =>
      @tools.apply_dev_event(
        self.config.project_dir,
        leaf_agent_id,
        @phase.DevEvent::ReviewReceivedEv(pr_number=n, body~),
        registry=Some(self.registry),
      )
    (Some(_), ReviewCommented(_, _)) => ()
    (Some(_), PRReady(n)) =>
      @tools.apply_dev_event(
        self.config.project_dir,
        leaf_agent_id,
        @phase.DevEvent::ReviewApprovedEv(pr_number=n),
        registry=Some(self.registry),
      )
    (Some(pr), FixesPushed(n)) =>
      @tools.apply_dev_event(
        self.config.project_dir,
        leaf_agent_id,
        @phase.DevEvent::FixesPushedEv(pr_number=n, sha=pr.last_sha),
        registry=Some(self.registry),
      )
    _ => ()
  }
  @phase.sync_parent_child_lifecycle(
    self.config.project_dir,
    self.config.terminal_session,
    self.registry,
    leaf_agent_id,
    self.current_lifecycle(leaf_agent_id),
  )
  // Parent notification — TL triage / merge signals (comment-only reviews: leaf only)
  if !skip_parent {
    match tracked {
      Some(pr) =>
        match
          parent_poll_event_message(
            pr,
            self.config.project_dir,
            event,
            unresolved_threads_for_recheck,
            merge_mode=@poller.merge_operator_mode_from_automerge(
              automerge_enabled_for_agent(
                self.config,
                local_config_for_agent(
                  self.config.project_dir,
                  self.registry,
                  pr.agent_id,
                ),
              ),
            ),
          ) {
          Some((message, status)) =>
            try {
              let parent = self.resolve_parent_for_delivery(leaf_agent_id)
              ignore(
                (self.append_file)(
                  self.config.project_dir + "/.choir/delivery.log",
                  "[poller-parent] agent=" +
                  leaf_agent_id +
                  " parent=" +
                  parent.agent_id.to_string() +
                  " terminal_target=" +
                  parent.terminal_target
                  .map(@types.LocalTarget::to_string)
                  .unwrap_or("NONE") +
                  "\n",
                ),
              )
              deliveries.push({
                recipient_id: parent.agent_id.to_string(),
                sender_id: leaf_agent_id,
                body: message,
                status,
                delivery: @message.plan_delivery(
                  parent, leaf_agent_id, message, status,
                ),
              })
            } catch {
              _ => ()
            }
          None => ()
        }
      None => ()
    }
  }
  // Owning leaf — direct `[REVIEW] PR #n: …` injection (terminal_target in registry)
  match leaf_owner {
    Some(agent) =>
      match agent.state {
        @types.AgentState::Active | @types.AgentState::Completing =>
          match leaf_poll_review_injection_message(event, tracked) {
            Some((message, status)) =>
              deliveries.push({
                recipient_id: agent.agent_id.to_string(),
                sender_id: "poller",
                body: message,
                status,
                delivery: @message.plan_delivery(
                  agent, "poller", message, status,
                ),
              })
            None => ()
          }
        _ => () // Done/Failed/Spawning — skip leaf delivery
      }
    None => ()
  }
  deliveries
}

///|
/// Generate a PR comment body for a poll event, if it warrants one.
fn pr_comment_body(
  event : @poller.PollEvent,
  agent_id : String,
) -> (Int, String)? {
  match event {
    ReviewReceived(n, _) =>
      Some(
        (
          n,
          "**Choir:** review received — routed to `" +
          agent_id +
          "` and parent for triage.",
        ),
      )
    ReviewCommented(n, _) =>
      Some(
        (
          n,
          "**Choir:** comment-only review received — routed to `" +
          agent_id +
          "` (leaf pane).",
        ),
      )
    PRReady(n) =>
      Some(
        (
          n, "**Choir:** PR approved — parent notified. PR is not merged until merge_pr succeeds.",
        ),
      )
    CIFailed(n) =>
      Some(
        (
          n,
          "**Choir:** CI checks failing — routed to `" +
          agent_id +
          "` for fixes.",
        ),
      )
    CIFailureCleared(n) =>
      Some(
        (
          n, "**Choir:** CI rollup no longer shows FAILURE/ERROR on the latest head (may still be pending) — re-check the PR on GitHub (not a merge signal).",
        ),
      )
    CILatestHeadRollupSucceeded(n) =>
      Some(
        (
          n, "**Choir:** GitHub Actions rollup reports all checks successful on the latest head — re-check review/merge policy on GitHub (not an approval or merge signal by itself).",
        ),
      )
    FixesPushed(n) =>
      Some(
        (
          n,
          "**Choir:** fixes pushed by `" +
          agent_id +
          "` — awaiting re-review (not merged yet).",
        ),
      )
    ReviewTimeout(_) => None
    CopilotIssueCommentSeen(n) =>
      Some(
        (
          n, "**Choir:** GitHub Copilot issue-thread comment observed on PR — parent notified with updated gate snapshot (not merge approval).",
        ),
      )
    PRMerged(_) => None
    MergeReady(_) => None
    ReviewThreadsResolved(n) =>
      Some(
        (
          n, "**Choir:** review threads marked resolved — re-checking PR state (not a merge signal).",
        ),
      )
  }
}

///|
async fn deliver_poller_stall_notification_for(
  state : ServerState,
  pr : @poller.TrackedPR,
  now : Int64,
  runner : async (Array[@workspace.Command]) -> Array[Int],
) -> Unit {
  if lifecycle_suppresses_poller_followups(state.current_lifecycle(pr.agent_id)) {
    return
  }
  let active = try state.registry.get(pr.agent_id) catch {
    _ => false
  } noraise {
    agent =>
      match agent.state {
        @types.AgentState::Active | @types.AgentState::Completing => true
        _ => false
      }
  }
  let stall_threshold_seconds : Int64 = 600L
  let stalled = @poller.detect_stalled_on_review(
    [(pr, active)],
    now,
    stall_threshold_seconds,
  )
  for p in stalled {
    let mins = (now - p.changes_requested_since) / 60L
    let msg = "[STALLED] PR #" +
      p.pr_number.to_string() +
      " (" +
      p.agent_id +
      ") — changes requested " +
      mins.to_string() +
      "m ago, no new commits from leaf"
    try {
      let parent = state.resolve_parent_for_delivery(p.agent_id)
      ignore(
        (state.append_file)(
          state.config.project_dir + "/.choir/delivery.log",
          "[poller-parent] agent=" +
          p.agent_id +
          " parent=" +
          parent.agent_id.to_string() +
          " terminal_target=" +
          parent.terminal_target
          .map(@types.LocalTarget::to_string)
          .unwrap_or("NONE") +
          "\n",
        ),
      )
      let delivery = @message.plan_delivery(
        parent,
        p.agent_id,
        msg,
        @types.Status::Info,
      )
      ignore(delivery)
      match
        state.durable_deliver_to_agent(
          parent,
          p.agent_id,
          msg,
          @types.Status::Info,
          runner,
        ) {
        Ok(_) =>
          match state.poller.get(p.pr_number) {
            Some(cur) => state.poller.restore({ ..cur, stall_notified: true })
            None => ()
          }
        Err(_) => ()
      }
    } catch {
      _ => ()
    }
  }
}

///|
async fn deliver_poller_stall_notifications(
  state : ServerState,
  now : Int64,
  runner : async (Array[@workspace.Command]) -> Array[Int],
) -> Unit {
  let prs : Array[@poller.TrackedPR] = []
  state.poller.tracked.each(fn(_k, pr) { prs.push(pr) })
  for pr in prs {
    deliver_poller_stall_notification_for(state, pr, now, runner)
  }
}

///|
async fn deliver_pending_poll_events(
  state : ServerState,
  pending_events : Array[@poller.PollEvent],
  pending_agent_ids : Array[String],
  runner : async (Array[@workspace.Command]) -> Array[Int],
  capture? : async (@workspace.Command) -> (Int, String) = @exec.capture_command_stdout,
) -> Unit {
  let pending_parent_rows : Array[PendingPollParentRow] = []
  let automerge_attempted_prs : Map[Int, Bool] = {}
  for i = 0; i < pending_events.length(); i = i + 1 {
    let event = pending_events[i]
    let agent_id = pending_agent_ids[i]
    let tracked_before_delivery = poll_event_tracked_snapshot(
      event,
      state.poller.get(poll_event_pr_number(event)),
    )
    let automerge_enabled = match tracked_before_delivery {
      Some(pr) =>
        automerge_enabled_for_agent(
          state.config,
          local_config_for_agent(
            state.config.project_dir,
            state.registry,
            pr.agent_id,
          ),
        )
      None => false
    }
    let unresolved_threads : Int? = if should_fetch_unresolved_threads_for_pending_event(
        event, automerge_enabled,
      ) {
      let (count, _) = @tools.fetch_unresolved_review_threads(
        poll_event_pr_number(event),
        state.config.project_dir,
        capture,
      )
      Some(count)
    } else {
      None
    }
    match (event, tracked_before_delivery) {
      (PRMerged(pr), Some(_)) =>
        state.reconcile_external_merge_with_runner(
          pr.agent_id,
          pr.pr_number,
          pr.branch,
          pr.parent_branch,
          pr.pr_url,
          runner,
        )
      _ =>
        for
          planned in state.plan_poll_event_deliveries(
            event,
            agent_id,
            unresolved_threads,
            skip_parent=true,
          ) {
          ignore(state.durable_dispatch_planned(planned, runner))
        }
    }
    match tracked_before_delivery {
      Some(pr) => {
        append_poll_snapshot_evidence(state, pr, event, unresolved_threads)
        if poll_event_is_external_merge(event) {
          continue
        }
        if !automerge_attempted_prs.contains(pr.pr_number) {
          automerge_attempted_prs.set(pr.pr_number, true)
          if maybe_trigger_automerge_for_pending_event(
              state,
              event,
              pr,
              unresolved_threads,
              runner,
              capture=@exec.capture_command_merged,
            ) {
            continue
          }
        }
        match
          parent_poll_event_message(
            pr,
            state.config.project_dir,
            event,
            unresolved_threads,
            task_contract=task_contract_for_agent(
              state.config.project_dir,
              state.registry,
              pr.agent_id,
            ),
            merge_mode=@poller.merge_operator_mode_from_automerge(
              automerge_enabled,
            ),
          ) {
          Some((message, status)) => {
            let category = @poller.plan_tl_poll_event_parent(
              event, pr, unresolved_threads,
            )
            pending_parent_rows.push({
              tracked: pr,
              leaf_agent_id: pr.agent_id,
              message,
              status,
              category,
              merge_mode: @poller.merge_operator_mode_from_automerge(
                automerge_enabled,
              ),
            })
          }
          None => ()
        }
      }
      None => ()
    }
    match pr_comment_body(event, agent_id) {
      Some((pr_number, body)) =>
        ignore(
          runner([
            @workspace.gh_pr_comment(pr_number, body, state.config.project_dir),
          ]),
        )
      None => ()
    }
  }
  if pending_parent_rows.length() > 0 {
    let rollup_entries : Array[@poller.WaveRollupEntry] = []
    for row in pending_parent_rows {
      rollup_entries.push({
        pr_number: row.tracked.pr_number,
        agent_id: row.leaf_agent_id,
        category: row.category,
      })
    }
    let wave_map = build_agent_wave_map(
      state.poller,
      state.registry,
      state.config.project_dir,
    )
    let (rollups, _) = @poller.build_wave_rollups(rollup_entries, wave_map)
    for rollup in rollups {
      let total_in_wave = supervisor_children_len_for_parent(
        state.config.project_dir,
        rollup.parent_id,
      )
      let matched = rollup_rows_for(pending_parent_rows, rollup)
      let body = @poller.format_wave_rollup(
        rollup,
        total_in_wave,
        merge_mode=rollup_merge_mode(matched),
      )
      let status = rollup_delivery_status(matched)
      let sender = "poller"
      try {
        let parent = state.resolve_parent_by_id(rollup.parent_id)
        ignore(
          (state.append_file)(
            state.config.project_dir + "/.choir/delivery.log",
            "[poller-parent-wave] parent=" +
            rollup.parent_id +
            " wave=" +
            rollup.wave.to_string() +
            "\n",
          ),
        )
        let delivery = @message.plan_delivery(parent, sender, body, status)
        ignore(delivery)
        ignore(
          state.durable_deliver_to_agent(parent, sender, body, status, runner),
        )
      } catch {
        _ => ()
      }
    }
    for row in pending_parent_rows {
      if row_in_any_multi_rollup(row, rollups) {
        continue
      }
      try {
        let parent = state.resolve_parent_for_delivery(row.leaf_agent_id)
        ignore(
          (state.append_file)(
            state.config.project_dir + "/.choir/delivery.log",
            "[poller-parent] agent=" +
            row.leaf_agent_id +
            " parent=" +
            parent.agent_id.to_string() +
            " terminal_target=" +
            parent.terminal_target
            .map(@types.LocalTarget::to_string)
            .unwrap_or("NONE") +
            "\n",
          ),
        )
        let delivery = @message.plan_delivery(
          parent,
          row.leaf_agent_id,
          row.message,
          row.status,
        )
        ignore(delivery)
        ignore(
          state.durable_deliver_to_agent(
            parent,
            row.leaf_agent_id,
            row.message,
            row.status,
            runner,
          ),
        )
      } catch {
        _ => ()
      }
    }
  }
}

///|
fn append_poller_delivery_line(
  append_file : (String, String) -> Bool,
  project_dir : String,
  line : String,
) -> Unit {
  ignore(
    append_file(project_dir + "/.choir/delivery.log", "[poller] " + line + "\n"),
  )
}

///|
fn poller_sanitize_event_for_log(raw : String) -> String {
  let buf = StringBuilder::new()
  for c in raw {
    if c == '\n' {
      buf.write_string("\\n")
    } else if c == '\r' {
      buf.write_string("\\r")
    } else {
      buf.write_char(c)
    }
  }
  let escaped = buf.to_string()
  let max_len = 200
  if escaped.length() <= max_len {
    escaped
  } else {
    escaped[0:max_len].to_string() + "..."
  }
}

///|
async fn deliver_orphaned_pr_notification_for(
  state : ServerState,
  pr : @poller.TrackedPR,
  runner : async (Array[@workspace.Command]) -> Array[Int],
) -> Unit {
  if lifecycle_suppresses_poller_followups(state.current_lifecycle(pr.agent_id)) {
    return
  }
  let agent_opt = try state.registry.get(pr.agent_id) catch {
    _ => None
  } noraise {
    a => Some(a)
  }
  let agent_is_active = match agent_opt {
    Some(agent) =>
      agent.state == @types.AgentState::Active ||
      agent.state == @types.AgentState::Completing
    None => false
  }
  let orphans = @poller.detect_orphaned_prs([(pr, agent_is_active)])
  let append_file = state.append_file
  let project_dir = state.config.project_dir
  for p in orphans {
    let message = "[ORPHANED PR] PR #" +
      p.pr_number.to_string() +
      " (" +
      p.agent_id +
      ") — owning agent is no longer active; merge manually via merge_pr or respawn via rescue_leaf"
    try {
      let parent = state.resolve_parent_for_delivery(p.agent_id)
      ignore(
        append_file(
          project_dir + "/.choir/delivery.log",
          "[poller-parent] agent=" +
          p.agent_id +
          " parent=" +
          parent.agent_id.to_string() +
          " terminal_target=" +
          parent.terminal_target
          .map(@types.LocalTarget::to_string)
          .unwrap_or("NONE") +
          "\n",
        ),
      )
      let delivery = @message.plan_delivery(
        parent,
        p.agent_id,
        message,
        @types.Status::Failure,
      )
      ignore(delivery)
      match
        state.durable_deliver_to_agent(
          parent,
          p.agent_id,
          message,
          @types.Status::Failure,
          runner,
        ) {
        Ok(_) =>
          match state.poller.get(p.pr_number) {
            Some(current) =>
              state.poller.restore({ ..current, orphan_notified: true })
            None => ()
          }
        Err(_) => ()
      }
    } catch {
      _ => ()
    }
  }
}

///|
async fn deliver_orphaned_pr_notifications(
  state : ServerState,
  runner : async (Array[@workspace.Command]) -> Array[Int],
) -> Unit {
  let prs : Array[@poller.TrackedPR] = []
  state.poller.tracked.each(fn(_k, pr) { prs.push(pr) })
  for pr in prs {
    deliver_orphaned_pr_notification_for(state, pr, runner)
  }
}

///|
fn poll_events_delivery_summary(events : Array[@poller.PollEvent]) -> String {
  if events.length() == 0 {
    return "no change"
  }
  let parts : Array[String] = []
  for e in events {
    parts.push(poller_sanitize_event_for_log(e.to_string()))
  }
  parts.join("; ")
}

///|
fn log_poller_pr_tick(
  append_file : (String, String) -> Bool,
  project_dir : String,
  log : @poller.PollerPrTickLog,
) -> Unit {
  let action = if log.skipped_backoff {
    "skipped_backoff"
  } else if log.untracked_closed {
    "untracked_closed"
  } else if log.polled_network && !log.poll_succeeded {
    "poll_failed"
  } else {
    "polled"
  }
  let events_summary = poll_events_delivery_summary(log.events)
  let skip_reason = if log.skipped_backoff {
    "backoff_until=" + log.backoff_until.to_string()
  } else {
    ""
  }
  @moontrace.info("poller pr", fields=[
    @moontrace.field("pr", log.pr_number),
    @moontrace.field("agent", log.agent_id),
    @moontrace.field("action", action),
    @moontrace.field("skip_reason", skip_reason),
    @moontrace.field("prior_review", log.prior_review_state.to_wire_string()),
    @moontrace.field(
      "detected_review",
      log.detected_review_state.to_wire_string(),
    ),
    @moontrace.field("events", events_summary),
    @moontrace.field("failures", log.consecutive_failures),
    @moontrace.field("prev_failures", log.previous_consecutive_failures),
  ])
  let line = "pr=" +
    log.pr_number.to_string() +
    " agent=" +
    log.agent_id +
    " action=" +
    action +
    (if skip_reason != "" { " " + skip_reason } else { "" }) +
    " prior=" +
    log.prior_review_state.to_wire_string() +
    " detected=" +
    log.detected_review_state.to_wire_string() +
    " events=" +
    events_summary +
    " failures=" +
    log.consecutive_failures.to_string()
  append_poller_delivery_line(append_file, project_dir, line)
  if log.consecutive_failures > log.previous_consecutive_failures {
    @moontrace.info("poller backoff", fields=[
      @moontrace.field("pr", log.pr_number),
      @moontrace.field("agent", log.agent_id),
      @moontrace.field("consecutive_failures", log.consecutive_failures),
      @moontrace.field("backoff_until", log.backoff_until),
    ])
    append_poller_delivery_line(
      append_file,
      project_dir,
      "backoff pr=" +
      log.pr_number.to_string() +
      " consecutive_failures=" +
      log.consecutive_failures.to_string() +
      " backoff_until=" +
      log.backoff_until.to_string(),
    )
  }
}

///|
pub async fn ServerState::process_poller_tick_with(
  self : ServerState,
  now : Int64,
  timeout : Int64,
  poll : async (Int, Bool) -> (
    Bool,
    @poller.ReviewState,
    String,
    @poller.CiRollupStatus,
    String,
    Bool,
    Bool,
  ),
  runner? : async (Array[@workspace.Command]) -> Array[Int] = @exec.run_sequence,
) -> Unit {
  let pending_events = []
  let pending_agent_ids = []
  self.poller.tick_with(
    now,
    timeout,
    poll,
    fn(event, agent_id) {
      pending_events.push(event)
      pending_agent_ids.push(agent_id)
    },
    fn(_) { () },
  )
  deliver_orphaned_pr_notifications(self, runner)
  deliver_pending_poll_events(self, pending_events, pending_agent_ids, runner)
  deliver_poller_stall_notifications(self, now, runner)
  self.sweep_outbox(now)
  ignore(self.poller.write_state_file(self.config.project_dir))
}

///|
pub async fn ServerState::process_poller_tick(
  self : ServerState,
  now : Int64,
  timeout : Int64,
  runner? : async (Array[@workspace.Command]) -> Array[Int] = @exec.run_sequence,
) -> Unit {
  let tracked_before = self.poller.tracked.length()
  let pending_events = []
  let pending_agent_ids = []
  let mut tick_event_total = 0
  @moontrace.info("poller tick start", fields=[
    @moontrace.field("tracked_prs", tracked_before),
  ])
  let project_dir = self.config.project_dir
  let append_file = self.append_file
  append_poller_delivery_line(
    append_file,
    project_dir,
    "tick_start tracked_prs=" + tracked_before.to_string(),
  )
  self.poller.tick_with(
    now,
    timeout,
    @poller.gh_poll_pr,
    fn(event, agent_id) {
      pending_events.push(event)
      pending_agent_ids.push(agent_id)
    },
    fn(log) {
      tick_event_total = tick_event_total + log.events.length()
      log_poller_pr_tick(append_file, project_dir, log)
    },
  )
  let tracked_after = self.poller.tracked.length()
  @moontrace.info("poller tick end", fields=[
    @moontrace.field("events_generated", tick_event_total),
    @moontrace.field("tracked_after", tracked_after),
  ])
  append_poller_delivery_line(
    append_file,
    project_dir,
    "tick_end events_generated=" +
    tick_event_total.to_string() +
    " tracked_after=" +
    tracked_after.to_string(),
  )
  deliver_orphaned_pr_notifications(self, runner)
  deliver_pending_poll_events(self, pending_events, pending_agent_ids, runner)
  deliver_poller_stall_notifications(self, now, runner)
  self.sweep_outbox(now)
  ignore(self.poller.write_state_file(self.config.project_dir))
}

///|
pub async fn ServerState::refresh_pr_with(
  self : ServerState,
  pr_number : Int,
  now : Int64,
  timeout : Int64,
  poll : async (Int, Bool) -> (
    Bool,
    @poller.ReviewState,
    String,
    @poller.CiRollupStatus,
    String,
    Bool,
    Bool,
  ),
  runner? : async (Array[@workspace.Command]) -> Array[Int] = @exec.run_sequence,
  capture? : async (@workspace.Command) -> (Int, String) = @exec.capture_command_stdout,
) -> Unit {
  let pending_events : Array[@poller.PollEvent] = []
  let pending_agent_ids : Array[String] = []
  self.poller.tick_pr_with(
    pr_number,
    now,
    timeout,
    poll,
    fn(event, agent_id) {
      pending_events.push(event)
      pending_agent_ids.push(agent_id)
    },
    fn(_) { () },
    force_refresh=true,
  )
  match self.poller.get(pr_number) {
    Some(pr) => {
      if pending_events.length() == 0 {
        pending_events.push(@poller.PollEvent::ReviewThreadsResolved(pr_number))
        pending_agent_ids.push(pr.agent_id)
      }
      deliver_orphaned_pr_notification_for(self, pr, runner)
      deliver_poller_stall_notification_for(self, pr, now, runner)
    }
    None => ()
  }
  if pending_events.length() > 0 {
    deliver_pending_poll_events(
      self,
      pending_events,
      pending_agent_ids,
      runner,
      capture~,
    )
  }
  ignore(self.poller.write_state_file(self.config.project_dir))
}

///|
pub async fn ServerState::refresh_pr_with_runner(
  self : ServerState,
  pr_number : Int,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  capture? : async (@workspace.Command) -> (Int, String) = @exec.capture_command_stdout,
) -> Unit {
  self.refresh_pr_with(
    pr_number,
    @poller.now_sec(),
    900L,
    @poller.gh_poll_pr,
    runner~,
    capture~,
  )
}

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
async fn ServerState::fail_agent_with_runner(
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
async fn ServerState::interpret_teardown_effects(
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
            role: Some(role),
            tool_name: None,
            tool_args: None,
            tool_result_status: None,
            exit_reason: Some(exit_reason),
          },
          self.config.project_dir,
        )
      RemoveWorktree(path) =>
        ignore(runner([@workspace.git_worktree_remove(path)]) catch { _ => [] })
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
        if source == ExternalObservation {
          try {
            let leaf = self.registry.get(leaf_id)
            best_effort_release_chainlink_lock_for_agent(
              self.config.project_dir,
              leaf,
            )
          } catch {
            _ => ()
          }
        }
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
/// Check for idle agents by dumping pane screens and comparing hashes.
/// If a pane's screen hasn't changed for `timeout` seconds, kill the agent.
pub async fn ServerState::check_idle_agents(
  self : ServerState,
  now : Int64,
  timeout : Int64,
  runner : async (Array[@workspace.Command]) -> Array[Int],
) -> Unit {
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
    if agent.role == @types.Role::Root || agent.role == @types.Role::TL {
      continue
    }
    // `ReviewOwned` devs are watchdog-exempt (idle while waiting for TL merge /
    // review). Dispatch still warns the parent when `notify_parent` is blocked on
    // unresolved threads.
    if @phase.lifecycle_idle_watchdog_exempt(self.current_lifecycle(agent_id)) {
      continue
    }
    match agent.terminal_target {
      Some(_) => ()
      None => continue
    }

    // Check if idle too long
    match self.pane_watcher.check_idle(agent_id, now, timeout) {
      Some(screen) => {
        ignore(screen) // We could extract failure reason from screen if desired, but watchdog just kills it
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
fn disconnect_pr_recovery_candidate(agent : @types.Agent) -> Bool {
  agent.role == @types.Role::Dev && agent.branch.trim() != ""
}

///|
pub async fn ServerState::handle_disconnect_with_runner(
  self : ServerState,
  agent_id : String,
  runner? : async (Array[@workspace.Command]) -> Array[Int] = @exec.run_sequence,
) -> Unit {
  let agent = self.registry.get(agent_id) catch { _ => return }
  match agent.state {
    Done | Failed =>
      match agent.terminal_target {
        Some(target) =>
          self.interpret_teardown_effects([CloseTerminal(target)], runner)
        None => ()
      }
    Completing => {
      let lifecycle = self.current_lifecycle(agent_id)
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
      match
        @phase.lifecycle_disconnect_policy(self.current_lifecycle(agent_id)) {
        @phase.LifecycleDisconnectPolicy::Preserve => ()
        @phase.LifecycleDisconnectPolicy::FinalizeDone(..) =>
          self.finalize_agent_with_runner(
            agent_id,
            @types.ExitReason::Disconnected,
            runner,
            notify_parent=false,
            close_target=false,
            remove_worktree=false,
          )
        @phase.LifecycleDisconnectPolicy::Ignore => ()
        @phase.LifecycleDisconnectPolicy::Fail(reason=default_reason) => {
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
              let parent_branch = match @workspace.parent_branch(agent.branch) {
                Some(pb) => pb
                None => "main"
              }
              @tools.apply_dev_event(
                self.config.project_dir,
                agent.branch,
                @phase.DevEvent::PRCreated(
                  pr_number~,
                  url=pr_url,
                  branch=agent.branch,
                ),
                registry=Some(self.registry),
              )
              self.poller.ensure_tracked(
                pr_number,
                agent_id,
                agent.branch,
                parent_branch,
                pr_url,
                @poller.now_sec(),
              )
              ignore(self.poller.write_state_file(self.config.project_dir))
            }
            None => {
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
}

///|
/// Process pending disconnects older than grace_seconds. Fire handle_disconnect for stale ones.
pub async fn ServerState::process_pending_disconnects_with_runner(
  self : ServerState,
  now : Int64,
  grace_seconds : Int64,
  runner? : async (Array[@workspace.Command]) -> Array[Int] = @exec.run_sequence,
) -> Unit {
  let stale : Array[String] = []
  for agent_id, disconnect_time in self.pending_disconnects {
    if now - disconnect_time >= grace_seconds {
      stale.push(agent_id)
    }
  }
  for agent_id in stale {
    self.pending_disconnects.remove(agent_id)
    self.handle_disconnect_with_runner(agent_id, runner~)
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
test "poll_events_delivery_summary escapes newlines and truncates long events" {
  let tail = "b".repeat(220)
  let ev = @poller.PollEvent::ReviewReceived(3, "alpha\nbeta\n" + tail)
  let s = poll_events_delivery_summary([ev])
  assert_false(s.contains("\n"))
  assert_true(s.contains("\\n"))
  assert_eq(s.length(), 203)
}

///|
test "merge_execution_mode_for_request distinguishes manual automerge and force" {
  let manual_req : @types.Request = {
    req_method: "tools/call",
    role: @types.Role::TL,
    name: "merge_pr",
    args: @types.RequestArgs::new({ "pr_number": "5" }),
  }
  assert_eq(
    merge_execution_mode_for_request(manual_req),
    @evidence.MergeExecutionMode::Manual,
  )
  let automerge_args : Map[String, Json] = {
    "pr_number": Int::to_json(5),
    "automerge": Bool::to_json(true),
  }
  let automerge_req : @types.Request = {
    req_method: "tools/call",
    role: @types.Role::TL,
    name: "merge_pr",
    args: @types.RequestArgs::from_values(automerge_args),
  }
  assert_eq(
    merge_execution_mode_for_request(automerge_req),
    @evidence.MergeExecutionMode::ServerAutomerge,
  )
  let force_args : Map[String, Json] = {
    "pr_number": Int::to_json(5),
    "automerge": Bool::to_json(true),
    "force": Bool::to_json(true),
  }
  let force_req : @types.Request = {
    req_method: "tools/call",
    role: @types.Role::TL,
    name: "merge_pr",
    args: @types.RequestArgs::from_values(force_args),
  }
  assert_eq(
    merge_execution_mode_for_request(force_req),
    @evidence.MergeExecutionMode::ForceOverride,
  )
}

///|
test "should_fetch_unresolved_threads_for_pending_event widens for automerge" {
  assert_false(
    should_fetch_unresolved_threads_for_pending_event(
      @poller.PollEvent::MergeReady(7),
      false,
    ),
  )
  assert_true(
    should_fetch_unresolved_threads_for_pending_event(
      @poller.PollEvent::MergeReady(7),
      true,
    ),
  )
  assert_true(
    should_fetch_unresolved_threads_for_pending_event(
      @poller.PollEvent::CILatestHeadRollupSucceeded(7),
      false,
    ),
  )
}

///|
test "automerge_enabled_for_agent respects local override" {
  let global_true = { ..@types.Config::default(), automerge: true }
  assert_true(automerge_enabled_for_agent(global_true, None))
  assert_false(
    automerge_enabled_for_agent(
      global_true,
      Some({ ..@types.LocalConfig::default(), automerge: Some(false) }),
    ),
  )
  assert_true(
    automerge_enabled_for_agent(
      { ..@types.Config::default(), automerge: false },
      Some({ ..@types.LocalConfig::default(), automerge: Some(true) }),
    ),
  )
}

///|
async test "maybe_trigger_automerge_for_pending_event reuses merge_pr path" {
  let project_dir = "/tmp/choir-automerge-handler-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.system("mkdir -p " + project_dir + "/.choir/kv"))
  let terminal_session = "test-session"
  let config = {
    ..@types.Config::default(),
    project_dir,
    terminal_session,
    automerge: true,
  }
  let state = ServerState::new(config, make_recovery_provider())
  let parent_id = "main.tl"
  let child_id = "main.auto-leaf"
  let pr_number = 90
  ignore(
    state.register_agent({
      agent_id: parent_id,
      role: @types.Role::TL,
      agent_type: @types.AgentType::Claude,
      parent: None,
      workspace: project_dir,
      branch: "main",
      terminal_target: Some(
        @workspace.local_target_for(
          terminal_session,
          "TL",
          @types.IsolationMode::Worktree,
        ),
      ),
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  ignore(
    state.register_agent({
      agent_id: child_id,
      role: @types.Role::Dev,
      agent_type: @types.AgentType::MoonPilot,
      parent: Some(parent_id),
      workspace: project_dir + "/.choir/worktrees/auto-leaf",
      branch: child_id,
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  let parent_child : @phase.ChildLifecycle = {
    child_id,
    slug: @phase.extract_slug(child_id),
    branch: child_id,
    agent_type: @types.AgentType::MoonPilot,
    summary: @phase.ChildLifecycleSummary::ReviewOwned(
      pr_number~,
      state=@phase.ReviewOwnership::ApprovedAwaitingMerge,
    ),
  }
  assert_true(
    @phase.write_lifecycle(project_dir, {
      agent_id: parent_id,
      role: @types.Role::TL,
      process: @phase.ProcessState::Connected,
      workflow: @phase.WorkflowState::Supervisor(
        @phase.SupervisorLifecycle::Supervising(children=[parent_child], wave=1),
      ),
    }),
  )
  assert_true(
    @phase.write_lifecycle(project_dir, {
      agent_id: child_id,
      role: @types.Role::Dev,
      process: @phase.ProcessState::Connected,
      workflow: @phase.WorkflowState::Dev(
        @phase.DevLifecycle::ReviewOwned(
          pr_number~,
          state=@phase.ReviewOwnership::ApprovedAwaitingMerge,
        ),
      ),
    }),
  )
  state.poller.track(
    pr_number, child_id, child_id, "main", "https://github.com/brickfrog/choir/pull/90",
    100L,
  )
  match state.poller.get(pr_number) {
    Some(tracked) =>
      state.poller.restore({
        ..tracked,
        last_review_state: @poller.ReviewState::Approved,
        last_ci_rollup: @poller.CiRollupStatus::Success,
      })
    None => fail("expected tracked PR")
  }
  let tracked = match state.poller.get(pr_number) {
    Some(value) => value
    None => fail("expected tracked PR")
  }
  let mut merge_seen = false
  let runner = async fn(cmds : Array[@workspace.Command]) {
    @async.sleep(0)
    let statuses = []
    for cmd in cmds {
      if cmd.program == "gh" &&
        cmd.args.length() >= 3 &&
        cmd.args[0] == "pr" &&
        cmd.args[1] == "merge" {
        merge_seen = true
      }
      statuses.push(0)
    }
    statuses
  }
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    let repo_view_json =
      #|{"owner":{"login":"brickfrog"},"name":"choir"}
    let review_threads_json =
      #|{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}
    if cmd.program == "gh" &&
      cmd.args.length() >= 2 &&
      cmd.args[0] == "api" &&
      cmd.args[1].has_suffix("/reviews") {
      return (0, "[{\"state\":\"APPROVED\"}]")
    }
    if cmd.program == "gh" &&
      cmd.args == ["repo", "view", "--json", "owner,name"] {
      return (0, repo_view_json)
    }
    if cmd.program == "gh" &&
      cmd.args.length() >= 2 &&
      cmd.args[0] == "api" &&
      cmd.args[1] == "graphql" {
      return (0, review_threads_json)
    }
    (0, "")
  }
  let merged = maybe_trigger_automerge_for_pending_event(
    state,
    @poller.PollEvent::ReviewThreadsResolved(pr_number),
    tracked,
    Some(0),
    runner,
    capture~,
  )
  assert_true(merged)
  assert_true(merge_seen)
  assert_true(state.poller.get(pr_number) == None)
  match @phase.read_lifecycle(project_dir, child_id) {
    Some(lifecycle) =>
      assert_eq(
        lifecycle.process,
        @phase.ProcessState::Finalized(reason=@phase.FinalizeReason::Merged),
      )
    None => fail("expected merged child lifecycle")
  }
}

///|
fn kill_agent_reconciliation_fixture(
  label : String,
  pr_number : Int,
) -> (ServerState, String, String) {
  let project_dir = "/tmp/choir-kill-reconcile-" +
    label +
    "-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.system("mkdir -p " + project_dir + "/.choir/kv"))
  let terminal_session = "test-session"
  let config = { ..@types.Config::default(), project_dir, terminal_session }
  let state = ServerState::new(config, make_recovery_provider())
  let parent_id = "main.parent"
  let child_id = "main.child"
  let live_target = match
    @types.LocalTarget::parse("zellij-tab:" + terminal_session + ":live-parent") {
    Some(t) => t
    None => panic()
  }
  ignore(
    state.register_agent({
      agent_id: parent_id,
      role: @types.Role::TL,
      agent_type: @types.AgentType::Claude,
      parent: None,
      workspace: project_dir,
      branch: "main",
      terminal_target: Some(live_target),
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  ignore(
    state.register_agent({
      agent_id: child_id,
      role: @types.Role::Dev,
      agent_type: @types.AgentType::MoonPilot,
      parent: Some(parent_id),
      workspace: project_dir + "/child",
      branch: child_id,
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  state.poller.track(
    pr_number,
    child_id,
    child_id,
    "main",
    "https://example.test/pr/" + pr_number.to_string(),
    100L,
  )
  (state, parent_id, child_id)
}

///|
async test "kill_agent auto-closes tracked stale PR and untracks it" {
  let pr_number = 208
  let (state, _parent_id, child_id) = kill_agent_reconciliation_fixture(
    "ok", pr_number,
  )
  let mut close_seen = false
  let mut stale_closed_delivered = false
  let runner = async fn(cmds : Array[@workspace.Command]) {
    @async.sleep(0)
    let statuses = []
    for cmd in cmds {
      if cmd.program == "choir" &&
        cmd.args.contains("zellij-action") &&
        cmd.args.contains("send") {
        let text = cmd.args[cmd.args.length() - 1]
        if text.contains("[STALE PR CLOSED]") &&
          text.contains("PR #" + pr_number.to_string()) {
          stale_closed_delivered = true
        }
      }
      statuses.push(0)
    }
    statuses
  }
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    if cmd.program == "gh" &&
      cmd.args.length() >= 3 &&
      cmd.args[0] == "pr" &&
      cmd.args[1] == "close" &&
      cmd.args[2] == pr_number.to_string() {
      close_seen = true
      return (0, "closed")
    }
    (0, "")
  }
  let req : @types.Request = {
    req_method: "tools/call",
    role: @types.Role::TL,
    name: "kill_agent",
    args: @types.RequestArgs::new({ "agent_id": child_id }),
  }
  let resp = state.handle_with_runner_and_capture(req, runner~, capture~)
  assert_true(resp.is_ok())
  assert_true(close_seen)
  assert_true(stale_closed_delivered)
  assert_true(state.poller.get(pr_number) == None)
}

///|
async test "kill_agent close failure sends one explicit stale PR failure and suppresses generic orphan notification" {
  let pr_number = 209
  let (state, _parent_id, child_id) = kill_agent_reconciliation_fixture(
    "fail", pr_number,
  )
  let mut stale_failed_delivered = false
  let runner = async fn(cmds : Array[@workspace.Command]) {
    @async.sleep(0)
    let statuses = []
    for cmd in cmds {
      if cmd.program == "choir" &&
        cmd.args.contains("zellij-action") &&
        cmd.args.contains("send") {
        let text = cmd.args[cmd.args.length() - 1]
        if text.contains("[STALE PR CLOSE FAILED]") &&
          text.contains("PR #" + pr_number.to_string()) {
          stale_failed_delivered = true
        }
      }
      statuses.push(0)
    }
    statuses
  }
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    if cmd.program == "gh" &&
      cmd.args.length() >= 3 &&
      cmd.args[0] == "pr" &&
      cmd.args[1] == "close" &&
      cmd.args[2] == pr_number.to_string() {
      return (1, "permission denied")
    }
    (0, "")
  }
  let req : @types.Request = {
    req_method: "tools/call",
    role: @types.Role::TL,
    name: "kill_agent",
    args: @types.RequestArgs::new({ "agent_id": child_id }),
  }
  let resp = state.handle_with_runner_and_capture(req, runner~, capture~)
  assert_true(resp.is_ok())
  assert_true(stale_failed_delivered)
  match state.poller.get(pr_number) {
    Some(tracked) => {
      assert_true(tracked.orphan_notified)
      assert_false(tracked.orphan_reconciling)
      assert_eq(@poller.detect_orphaned_prs([(tracked, false)]).length(), 0)
    }
    None => fail("expected tracked PR to remain after close failure")
  }
}

///|
test "parent_poll_event_message PR READY stresses not merged" {
  let tracked : @poller.TrackedPR = {
    pr_number: 7,
    agent_id: "main.dev-a",
    branch: "work/a",
    parent_branch: "main",
    pr_url: "https://ex/pr/7",
    first_seen: 0,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::Approved,
    last_review_bodies: "",
    last_sha: "",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Unknown,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: false,
    orphan_notified: false,
    orphan_reconciling: false,
    changes_requested_since: 0L,
    stall_notified: false,
  }
  match
    parent_poll_event_message(
      tracked,
      "/repo",
      @poller.PollEvent::PRReady(7),
      None,
    ) {
    Some((message, status)) => {
      assert_eq(status, @types.Status::Success)
      assert_true(message.contains("[PR READY]"))
      assert_true(message.contains("(not merged yet)"))
      assert_true(message.contains("merge_mode: manual"))
      assert_true(message.contains("Pre-merge:"))
      assert_true(message.contains("[PR MERGED]"))
      assert_true(message.contains("TLDecision:"))
      assert_true(message.contains("Waiting on Copilot review"))
    }
    None => fail("expected PRReady message")
  }
}

///|
test "parent_poll_event_message PR READY shows merge gate when snapshot allows" {
  let tracked : @poller.TrackedPR = {
    pr_number: 70,
    agent_id: "main.dev-a",
    branch: "work/a",
    parent_branch: "main",
    pr_url: "https://ex/pr/70",
    first_seen: 0,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::Approved,
    last_review_bodies: "",
    last_sha: "",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Success,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: false,
    orphan_notified: false,
    orphan_reconciling: false,
    changes_requested_since: 0L,
    stall_notified: false,
  }
  match
    parent_poll_event_message(
      tracked,
      "/repo",
      @poller.PollEvent::PRReady(70),
      Some(0),
    ) {
    Some((message, status)) => {
      assert_eq(status, @types.Status::Success)
      assert_true(message.contains("TLDecision:"))
      assert_true(message.contains("MERGE NOW"))
    }
    None => fail("expected merge-gate-open PRReady message")
  }
}

///|
test "parent_poll_event_message MergeReady is actionable in manual mode" {
  let tracked : @poller.TrackedPR = {
    pr_number: 71,
    agent_id: "main.dev-manual",
    branch: "work/manual",
    parent_branch: "main",
    pr_url: "https://ex/pr/71",
    first_seen: 0,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::Approved,
    last_review_bodies: "",
    last_sha: "",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Success,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: true,
    orphan_notified: false,
    orphan_reconciling: false,
    changes_requested_since: 0L,
    stall_notified: false,
  }
  match
    parent_poll_event_message(
      tracked,
      "/repo",
      @poller.PollEvent::MergeReady(71),
      Some(0),
      merge_mode=@poller.MergeOperatorMode::Manual,
    ) {
    Some((message, status)) => {
      assert_eq(status, @types.Status::Success)
      assert_true(message.contains("[MERGE READY]"))
      assert_true(message.contains("merge_mode: manual"))
      assert_true(message.contains("Merge policy decision: merge_now"))
      assert_true(message.contains("merge_pr("))
      assert_true(message.contains("MERGE NOW"))
    }
    None => fail("expected manual MergeReady message")
  }
}

///|
test "parent_poll_event_message MergeReady is informational in automerge mode" {
  let tracked : @poller.TrackedPR = {
    pr_number: 72,
    agent_id: "main.dev-auto",
    branch: "work/auto",
    parent_branch: "main",
    pr_url: "https://ex/pr/72",
    first_seen: 0,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::Approved,
    last_review_bodies: "",
    last_sha: "",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Success,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: true,
    orphan_notified: false,
    orphan_reconciling: false,
    changes_requested_since: 0L,
    stall_notified: false,
  }
  match
    parent_poll_event_message(
      tracked,
      "/repo",
      @poller.PollEvent::MergeReady(72),
      Some(0),
      merge_mode=@poller.MergeOperatorMode::Automerge,
    ) {
    Some((message, status)) => {
      assert_eq(status, @types.Status::Info)
      assert_true(message.contains("merge_mode: automerge"))
      assert_true(message.contains("server will attempt merge automatically"))
      assert_true(message.contains("AUTO-MERGE READY"))
      assert_false(message.contains("`merge_pr("))
    }
    None => fail("expected automerge MergeReady message")
  }
}

///|
test "parent_poll_event_message FixesPushed stresses not merged" {
  let tracked : @poller.TrackedPR = {
    pr_number: 8,
    agent_id: "main.dev-b",
    branch: "work/b",
    parent_branch: "main",
    pr_url: "",
    first_seen: 0,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::Approved,
    last_review_bodies: "",
    last_sha: "abc",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Unknown,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: false,
    orphan_notified: false,
    orphan_reconciling: false,
    changes_requested_since: 0L,
    stall_notified: false,
  }
  match
    parent_poll_event_message(
      tracked,
      "/repo",
      @poller.PollEvent::FixesPushed(8),
      None,
    ) {
    Some((message, status)) => {
      assert_eq(status, @types.Status::Info)
      assert_true(message.contains("[FIXES PUSHED]"))
      assert_true(message.contains("(not merged yet)"))
      assert_true(message.contains("Pre-merge:"))
      assert_true(message.contains("TLDecision:"))
      assert_true(message.contains("Waiting on review or CI"))
    }
    None => fail("expected FixesPushed message")
  }
}

///|
test "parent_poll_event_message CIFailureCleared stresses re-check not merge" {
  let tracked : @poller.TrackedPR = {
    pr_number: 10,
    agent_id: "main.dev-x",
    branch: "work/x",
    parent_branch: "main",
    pr_url: "https://ex/pr/10",
    first_seen: 0,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::ChangesRequested,
    last_review_bodies: "",
    last_sha: "abc",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Unknown,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: false,
    orphan_notified: false,
    orphan_reconciling: false,
    changes_requested_since: 0L,
    stall_notified: false,
  }
  match
    parent_poll_event_message(
      tracked,
      "/repo",
      @poller.PollEvent::CIFailureCleared(10),
      Some(0),
    ) {
    Some((message, status)) => {
      assert_eq(status, @types.Status::Info)
      assert_true(message.contains("[CI FAILURE CLEARED]"))
      assert_true(message.contains("not a merge/review verdict"))
      assert_true(message.contains("pending"))
      assert_true(message.contains("re-check"))
      assert_false(message.contains("CI PASSED"))
      assert_false(message.to_lower().contains("green"))
      assert_true(message.contains("PR re-check summary"))
      assert_true(message.contains("changes_requested"))
      assert_true(message.contains("GitHub review requests changes"))
      assert_true(message.contains("TLDecision:"))
      assert_true(message.contains("BLOCKED: review requested changes"))
    }
    None => fail("expected CIFailureCleared message")
  }
}

///|
test "leaf_poll_review_injection_message CIFailureCleared is honest about scope" {
  match
    leaf_poll_review_injection_message(
      @poller.PollEvent::CIFailureCleared(44),
      None,
    ) {
    Some((message, status)) => {
      assert_eq(status, @types.Status::Info)
      assert_true(message.contains("no longer reports failure"))
      assert_true(message.contains("GitHub"))
      assert_true(message.contains("not merge"))
      assert_false(message.to_lower().contains("green"))
    }
    None => fail("expected leaf CIFailureCleared injection")
  }
}

///|
test "pr_comment_body CIFailureCleared contains pending caveat and no merge signal" {
  match pr_comment_body(@poller.PollEvent::CIFailureCleared(55), "main.dev-x") {
    Some((pr_number, body)) => {
      assert_eq(pr_number, 55)
      assert_true(body.contains("pending"))
      assert_true(body.contains("not a merge signal"))
      assert_false(body.to_lower().contains("passed"))
      assert_false(body.to_lower().contains("green"))
    }
    None => fail("expected pr_comment_body for CIFailureCleared")
  }
}

///|
test "parent_poll_event_message CILatestHeadRollupSucceeded stresses not merge or approval" {
  let tracked : @poller.TrackedPR = {
    pr_number: 171,
    agent_id: "main.dev-z",
    branch: "work/z",
    parent_branch: "main",
    pr_url: "https://ex/pr/171",
    first_seen: 0,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::Approved,
    last_review_bodies: "",
    last_sha: "abc",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Success,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: false,
    orphan_notified: false,
    orphan_reconciling: false,
    changes_requested_since: 0L,
    stall_notified: false,
  }
  match
    parent_poll_event_message(
      tracked,
      "/repo",
      @poller.PollEvent::CILatestHeadRollupSucceeded(171),
      Some(0),
    ) {
    Some((message, status)) => {
      assert_eq(status, @types.Status::Info)
      assert_true(message.contains("[CI LATEST HEAD]"))
      assert_true(message.contains("not merge approval"))
      assert_true(message.contains("re-check"))
      assert_false(message.to_lower().contains("mergeable"))
      assert_true(message.contains("PR re-check summary"))
      assert_true(message.contains("approved"))
      assert_true(message.contains("success"))
      assert_true(message.contains("no tracked blockers"))
      assert_true(message.contains("Does not merge"))
      assert_true(message.contains("TLDecision:"))
      assert_true(message.contains("MERGE NOW"))
    }
    None => fail("expected CILatestHeadRollupSucceeded message")
  }
}

///|
test "leaf_poll_review_injection_message CILatestHeadRollupSucceeded is scoped" {
  match
    leaf_poll_review_injection_message(
      @poller.PollEvent::CILatestHeadRollupSucceeded(171),
      None,
    ) {
    Some((message, status)) => {
      assert_eq(status, @types.Status::Info)
      assert_true(message.contains("all checks successful"))
      assert_true(message.contains("not merge"))
    }
    None => fail("expected leaf CILatestHeadRollupSucceeded injection")
  }
}

///|
test "leaf_poll_review_injection_message CILatestHeadRollupSucceeded escalates when review timed out with no snapshot review" {
  let tracked : @poller.TrackedPR = {
    pr_number: 178,
    agent_id: "main.dev-leaf",
    branch: "work/leaf",
    parent_branch: "main",
    pr_url: "https://ex/pr/178",
    first_seen: 0,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::None_,
    last_review_bodies: "",
    last_sha: "abc",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Success,
    last_timeout_at: 100L,
    copilot_issue_comment_seen: false,
    orphan_notified: false,
    orphan_reconciling: false,
    changes_requested_since: 0L,
    stall_notified: false,
  }
  match
    leaf_poll_review_injection_message(
      @poller.PollEvent::CILatestHeadRollupSucceeded(178),
      Some(tracked),
    ) {
    Some((message, status)) => {
      assert_eq(status, @types.Status::Info)
      assert_true(message.contains("no review"))
      assert_true(message.contains("add-reviewer"))
      assert_false(message.contains("re-check review thread and policy"))
    }
    None => fail("expected leaf CI escalation injection")
  }
}

///|
test "pr_comment_body CILatestHeadRollupSucceeded avoids approval language" {
  match
    pr_comment_body(
      @poller.PollEvent::CILatestHeadRollupSucceeded(60),
      "main.dev-z",
    ) {
    Some((pr_number, body)) => {
      assert_eq(pr_number, 60)
      assert_true(body.contains("successful"))
      assert_true(body.contains("not an approval"))
      assert_false(body.to_lower().contains("approved"))
    }
    None => fail("expected pr_comment_body for CILatestHeadRollupSucceeded")
  }
}

///|
test "parent_poll_event_message suppresses non-blocking review comments" {
  let tracked : @poller.TrackedPR = {
    pr_number: 9,
    agent_id: "main.dev-c",
    branch: "work/c",
    parent_branch: "main",
    pr_url: "https://ex/pr/9",
    first_seen: 0,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::Commented,
    last_review_bodies: "note",
    last_sha: "abc",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Unknown,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: false,
    orphan_notified: false,
    orphan_reconciling: false,
    changes_requested_since: 0L,
    stall_notified: false,
  }
  assert_eq(
    parent_poll_event_message(
      tracked,
      "/repo",
      @poller.PollEvent::ReviewCommented(9, "minor suggestion"),
      None,
    ),
    None,
  )
}

///|
test "clamp_review_summary_for_pane leaves short text unchanged" {
  let s = "fix the typo in handler"
  assert_eq(clamp_review_summary_for_pane(s), s)
}

///|
test "clamp_review_summary_for_pane truncates long Copilot-style bodies" {
  let long = "x".repeat(review_summary_pane_max_chars + 500)
  let out = clamp_review_summary_for_pane(long)
  assert_true(out.contains("[truncated"))
  assert_true(out.length() < long.length())
}

///|
test "disconnect PR recovery only applies to branch-owning dev agents" {
  let mk = fn(role : @types.Role, branch : String) {
    @types.Agent::{
      agent_id: "agent",
      role,
      agent_type: @types.AgentType::Claude,
      parent: Some("root"),
      workspace: "/proj",
      branch,
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }
  }
  assert_true(
    disconnect_pr_recovery_candidate(mk(@types.Role::Dev, "main.leaf")),
  )
  assert_false(disconnect_pr_recovery_candidate(mk(@types.Role::Dev, "")))
  assert_false(
    disconnect_pr_recovery_candidate(mk(@types.Role::Worker, "main.worker")),
  )
  assert_false(disconnect_pr_recovery_candidate(mk(@types.Role::TL, "main")))
}

///|
async test "fail_agent_with_runner injects failure to parent terminal" {
  let project_dir = "/tmp/choir-watchdog-test-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.system("mkdir -p " + project_dir + "/.choir/kv"))

  let terminal_session = "test-session"
  let config = { ..@types.Config::default(), project_dir, terminal_session }
  let state = ServerState::new(config, make_recovery_provider())

  let parent_id = "main.parent"
  let live_target = match
    @types.LocalTarget::parse("zellij-tab:" + terminal_session + ":live-parent") {
    Some(t) => t
    None => fail("expected parseable local target")
  }

  ignore(
    state.register_agent({
      agent_id: parent_id,
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Claude,
      parent: None,
      workspace: project_dir,
      branch: parent_id,
      terminal_target: Some(live_target),
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )

  let caller_id = "main.child"
  ignore(
    state.register_agent({
      agent_id: caller_id,
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Claude,
      parent: Some(parent_id),
      workspace: project_dir,
      branch: caller_id,
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )

  ignore(
    @phase.write_lifecycle(
      project_dir,
      @phase.lifecycle_for_role(caller_id, @types.Role::Dev),
    ),
  )

  @async.sleep(0)

  let mut injected_failure_msg = false
  let runner = async fn(cmds : Array[@workspace.Command]) {
    @async.sleep(0)
    for cmd in cmds {
      if cmd.program == "choir" &&
        cmd.args.contains("zellij-action") &&
        cmd.args.contains("send") {
        let text = cmd.args[cmd.args.length() - 1]
        if text.contains("[from: " + caller_id + "]") &&
          text.contains("watchdog timeout") {
          injected_failure_msg = true
        }
      }
    }
    [0]
  }

  state.fail_agent_with_runner(
    caller_id,
    @phase.FailureReason::WatchdogTimeout,
    "watchdog timeout",
    @types.ExitReason::Shutdown,
    runner,
  )

  assert_true(injected_failure_msg)
}

///|
test "parent_poll_event_message REVIEW TIMEOUT uses attention-required decision" {
  let tracked : @poller.TrackedPR = {
    pr_number: 61,
    agent_id: "main.dev-timeout",
    branch: "work/timeout",
    parent_branch: "main",
    pr_url: "https://ex/pr/61",
    first_seen: 0,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::Approved,
    last_review_bodies: "",
    last_sha: "sha",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Success,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: false,
    orphan_notified: false,
    orphan_reconciling: false,
    changes_requested_since: 0L,
    stall_notified: false,
  }
  match
    parent_poll_event_message(
      tracked,
      "/repo",
      @poller.PollEvent::ReviewTimeout(61),
      None,
    ) {
    Some((message, status)) => {
      assert_eq(status, @types.Status::Failure)
      assert_true(message.contains("TLDecision:"))
      assert_true(message.contains("ACTION REQUIRED: no review"))
      assert_true(message.contains("add-reviewer"))
      assert_true(message.contains("add-reviewer"))
      assert_false(message.contains("15min"))
    }
    None => fail("expected ReviewTimeout message")
  }
}

///|
test "parent_poll_event_message CI LATEST HEAD adds escalation when review timeout already fired" {
  let tracked : @poller.TrackedPR = {
    pr_number: 171,
    agent_id: "main.dev-z",
    branch: "work/z",
    parent_branch: "main",
    pr_url: "https://ex/pr/171",
    first_seen: 0,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::None_,
    last_review_bodies: "",
    last_sha: "abc",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Success,
    last_timeout_at: 999L,
    copilot_issue_comment_seen: false,
    orphan_notified: false,
    orphan_reconciling: false,
    changes_requested_since: 0L,
    stall_notified: false,
  }
  match
    parent_poll_event_message(
      tracked,
      "/repo",
      @poller.PollEvent::CILatestHeadRollupSucceeded(171),
      Some(0),
    ) {
    Some((message, status)) => {
      assert_eq(status, @types.Status::Info)
      assert_true(message.contains("Review timeout already fired"))
      assert_true(message.contains("TLDecision:"))
      assert_true(message.contains("ACTION REQUIRED: no review"))
    }
    None => fail("expected CILatestHeadRollupSucceeded escalation message")
  }
}

///|
test "parent_poll_event_message CI FAILED uses attention-required decision" {
  let tracked : @poller.TrackedPR = {
    pr_number: 62,
    agent_id: "main.dev-ci",
    branch: "work/ci",
    parent_branch: "main",
    pr_url: "https://ex/pr/62",
    first_seen: 0,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::Approved,
    last_review_bodies: "",
    last_sha: "sha",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Failure,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: false,
    orphan_notified: false,
    orphan_reconciling: false,
    changes_requested_since: 0L,
    stall_notified: false,
  }
  match
    parent_poll_event_message(
      tracked,
      "/repo",
      @poller.PollEvent::CIFailed(62),
      None,
    ) {
    Some((message, status)) => {
      assert_eq(status, @types.Status::Failure)
      assert_true(message.contains("TLDecision:"))
      assert_true(message.contains("BLOCKED: CI failing"))
    }
    None => fail("expected CIFailed message")
  }
}

///|
test "parent_poll_event_message PRMerged is handled by canonical teardown delivery" {
  let tracked : @poller.TrackedPR = {
    pr_number: 63,
    agent_id: "main.dev-merged",
    branch: "work/merged",
    parent_branch: "main",
    pr_url: "https://ex/pr/63",
    first_seen: 0,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::Approved,
    last_review_bodies: "",
    last_sha: "sha",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Success,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: false,
    orphan_notified: false,
    orphan_reconciling: false,
    changes_requested_since: 0L,
    stall_notified: false,
  }
  assert_eq(
    parent_poll_event_message(
      tracked,
      "/repo",
      @poller.PollEvent::PRMerged(tracked),
      Some(0),
    ),
    None,
  )
}

///|
test "evidence_events_for_poll_snapshot emits normalized snapshot events" {
  let tracked : @poller.TrackedPR = {
    pr_number: 64,
    agent_id: "main.dev-evidence",
    branch: "work/evidence",
    parent_branch: "main",
    pr_url: "https://ex/pr/64",
    first_seen: 0,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::Approved,
    last_review_bodies: "looks good",
    last_sha: "sha64",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Success,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: true,
    orphan_notified: false,
    orphan_reconciling: false,
    changes_requested_since: 0L,
    stall_notified: false,
  }
  let events = evidence_events_for_poll_snapshot(
    tracked,
    @poller.PollEvent::CILatestHeadRollupSucceeded(64),
    Some(0),
  )
  assert_eq(events.length(), 4)
  match events[0] {
    @evidence.EvidenceEvent::ReviewObserved(state~, body~) => {
      assert_eq(state, @evidence.EvidenceReviewState::Approved)
      assert_eq(body, Some("looks good"))
    }
    _ => fail("expected review evidence")
  }
  match events[1] {
    @evidence.EvidenceEvent::CiObserved(status~, head_sha~) => {
      assert_eq(status, @evidence.EvidenceCiStatus::Success)
      assert_eq(head_sha, Some("sha64"))
    }
    _ => fail("expected ci evidence")
  }
  match events[2] {
    @evidence.EvidenceEvent::ThreadsObserved(count~) => assert_eq(count, 0)
    _ => fail("expected threads evidence")
  }
  match events[3] {
    @evidence.EvidenceEvent::CopilotIssueCommentObserved => ()
    _ => fail("expected copilot evidence")
  }
}

///|
test "evidence_events_for_poll_snapshot includes merge observed on PRMerged" {
  let tracked : @poller.TrackedPR = {
    pr_number: 65,
    agent_id: "main.dev-evidence-merged",
    branch: "work/evidence-merged",
    parent_branch: "main",
    pr_url: "https://ex/pr/65",
    first_seen: 0,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::Approved,
    last_review_bodies: "",
    last_sha: "sha65",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Success,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: false,
    orphan_notified: false,
    orphan_reconciling: false,
    changes_requested_since: 0L,
    stall_notified: false,
  }
  let events = evidence_events_for_poll_snapshot(
    tracked,
    @poller.PollEvent::PRMerged(tracked),
    None,
  )
  assert_eq(events.length(), 5)
  match events[4] {
    @evidence.EvidenceEvent::MergeObserved(pr_number~, pr_url~) => {
      assert_eq(pr_number, 65)
      assert_eq(pr_url, Some("https://ex/pr/65"))
    }
    _ => fail("expected merge evidence")
  }
}

///|
async test "deliver_orphaned_pr_notification_for skips finalized merged lifecycle" {
  let project_dir = "/tmp/choir-handler-orphan-skip-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.system("mkdir -p " + project_dir + "/.choir/kv"))
  let config = {
    ..@types.Config::default(),
    project_dir,
    terminal_session: "test-session",
  }
  let state = ServerState::new(config, make_recovery_provider())
  let agent_id = "main.dev-finalized"
  assert_true(
    @phase.write_lifecycle(project_dir, {
      ..@phase.lifecycle_for_role(agent_id, @types.Role::Dev),
      process: @phase.ProcessState::Finalized(
        reason=@phase.FinalizeReason::Merged,
      ),
      workflow: @phase.WorkflowState::Dev(
        @phase.DevLifecycle::Done(reason=@phase.FinalizeReason::Merged),
      ),
    }),
  )
  let pr : @poller.TrackedPR = {
    pr_number: 88,
    agent_id,
    branch: "feat/finalized",
    parent_branch: "main",
    pr_url: "https://gh.test/88",
    first_seen: 0L,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::Approved,
    last_review_bodies: "",
    last_sha: "sha",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Success,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: false,
    orphan_notified: false,
    orphan_reconciling: false,
    changes_requested_since: 0L,
    stall_notified: false,
  }
  let mut runner_calls = 0
  deliver_orphaned_pr_notification_for(state, pr, async fn(cmds) {
    @async.sleep(0)
    runner_calls = runner_calls + cmds.length()
    []
  })
  assert_eq(runner_calls, 0)
}

///|
async test "deliver_poller_stall_notification_for skips finalized merged lifecycle" {
  let project_dir = "/tmp/choir-handler-stall-skip-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.system("mkdir -p " + project_dir + "/.choir/kv"))
  let config = {
    ..@types.Config::default(),
    project_dir,
    terminal_session: "test-session",
  }
  let state = ServerState::new(config, make_recovery_provider())
  let agent_id = "main.dev-finalized"
  assert_true(
    @phase.write_lifecycle(project_dir, {
      ..@phase.lifecycle_for_role(agent_id, @types.Role::Dev),
      process: @phase.ProcessState::Finalized(
        reason=@phase.FinalizeReason::Merged,
      ),
      workflow: @phase.WorkflowState::Dev(
        @phase.DevLifecycle::Done(reason=@phase.FinalizeReason::Merged),
      ),
    }),
  )
  let pr : @poller.TrackedPR = {
    pr_number: 89,
    agent_id,
    branch: "feat/finalized",
    parent_branch: "main",
    pr_url: "https://gh.test/89",
    first_seen: 0L,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::ChangesRequested,
    last_review_bodies: "",
    last_sha: "sha",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Success,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: false,
    orphan_notified: false,
    orphan_reconciling: false,
    changes_requested_since: 1L,
    stall_notified: false,
  }
  let mut runner_calls = 0
  deliver_poller_stall_notification_for(state, pr, 1000L, async fn(cmds) {
    @async.sleep(0)
    runner_calls = runner_calls + cmds.length()
    []
  })
  assert_eq(runner_calls, 0)
}

///|
async fn handler_with_moontrace_capture(
  captured : Array[@moontrace.Event],
  f : async () -> Unit,
) -> Unit {
  @moontrace.set_subscriber(fn(event) { captured.push(event) })
  f() catch {
    err => {
      @moontrace.clear_subscriber()
      raise err
    }
  }
  @moontrace.clear_subscriber()
}

///|
fn handler_auto_close_test_state(label : String) -> ServerState {
  let project_dir = "/tmp/choir-handler-auto-close-" +
    label +
    "-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.system("mkdir -p " + project_dir + "/.choir/kv"))
  let config = {
    ..@types.Config::default(),
    project_dir,
    terminal_session: "test-session",
  }
  ServerState::new(config, make_recovery_provider())
}

///|
fn handler_auto_close_target(label : String) -> @types.LocalTarget {
  { kind: @types.TargetKind::ZellijPane, session: "test-session", name: label }
}

///|
fn handler_close_terminal_warn_count(events : Array[@moontrace.Event]) -> Int {
  let mut count = 0
  for event in events {
    if event.level == @moontrace.Level::Warn &&
      event.message == "CloseTerminal failed" {
      count = count + 1
    }
  }
  count
}

///|
async test "test_close_terminal_warns_on_nonzero_exit" {
  let state = handler_auto_close_test_state("close-warn")
  let target = handler_auto_close_target("leaf-pane")
  let captured : Array[@moontrace.Event] = []
  handler_with_moontrace_capture(captured, async fn() {
    state.interpret_teardown_effects([CloseTerminal(target)], _cmds => [1])
  })
  assert_eq(handler_close_terminal_warn_count(captured), 1)
}

///|
async test "test_close_terminal_no_warn_on_zero_exit" {
  let state = handler_auto_close_test_state("close-ok")
  let target = handler_auto_close_target("leaf-pane")
  let captured : Array[@moontrace.Event] = []
  handler_with_moontrace_capture(captured, async fn() {
    state.interpret_teardown_effects([CloseTerminal(target)], _cmds => [0])
  })
  assert_eq(handler_close_terminal_warn_count(captured), 0)
}

///|
async test "test_close_terminal_warns_on_error" {
  let state = handler_auto_close_test_state("close-error")
  let target = handler_auto_close_target("leaf-pane")
  let captured : Array[@moontrace.Event] = []
  handler_with_moontrace_capture(captured, async fn() {
    state.interpret_teardown_effects([CloseTerminal(target)], _cmds => {
      raise @types.ChoirError::agent_not_found("test error")
    })
  })
  assert_eq(handler_close_terminal_warn_count(captured), 1)
}

///|
fn handler_auto_close_agent(
  agent_id : String,
  state : @types.AgentState,
  target : @types.LocalTarget?,
) -> @types.Agent {
  {
    agent_id: @types.AgentId(agent_id),
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Claude,
    parent: Some("main.parent"),
    workspace: "/tmp/choir-handler-auto-close-workspace",
    branch: agent_id,
    terminal_target: target,
    host: @types.Host::Local,
    spawn_depth: 0,
    state,
  }
}

///|
async test "test_disconnect_done_agent_closes_pane" {
  let state = handler_auto_close_test_state("disconnect-done")
  let agent_id = "main.done-leaf"
  let target = handler_auto_close_target("done-pane")
  ignore(
    state.register_agent(handler_auto_close_agent(agent_id, Done, Some(target))),
  )
  let expected = @workspace.local_close_target(target)
  let calls : Array[@workspace.Command] = []
  state.handle_disconnect_with_runner(agent_id, runner=async fn(cmds) {
    @async.sleep(0)
    for cmd in cmds {
      calls.push(cmd)
    }
    [0]
  })
  assert_eq(calls.length(), 1)
  assert_eq(calls[0], expected)
}

///|
async test "test_disconnect_failed_agent_closes_pane" {
  let state = handler_auto_close_test_state("disconnect-failed")
  let agent_id = "main.failed-leaf"
  let target = handler_auto_close_target("failed-pane")
  ignore(
    state.register_agent(
      handler_auto_close_agent(agent_id, Failed, Some(target)),
    ),
  )
  let expected = @workspace.local_close_target(target)
  let calls : Array[@workspace.Command] = []
  state.handle_disconnect_with_runner(agent_id, runner=async fn(cmds) {
    @async.sleep(0)
    for cmd in cmds {
      calls.push(cmd)
    }
    [0]
  })
  assert_eq(calls.length(), 1)
  assert_eq(calls[0], expected)
}

///|
async test "test_disconnect_done_agent_no_target_no_call" {
  let state = handler_auto_close_test_state("disconnect-done-no-target")
  let agent_id = "main.done-leaf-no-target"
  ignore(state.register_agent(handler_auto_close_agent(agent_id, Done, None)))
  let calls : Array[@workspace.Command] = []
  state.handle_disconnect_with_runner(agent_id, runner=async fn(cmds) {
    @async.sleep(0)
    for cmd in cmds {
      calls.push(cmd)
    }
    [0]
  })
  assert_eq(calls.length(), 0)
}

///|
async test "test_disconnect_completing_agent_no_close" {
  let state = handler_auto_close_test_state("disconnect-completing")
  let agent_id = "main.completing-leaf"
  let target = handler_auto_close_target("completing-pane")
  ignore(
    state.register_agent(
      handler_auto_close_agent(agent_id, Completing, Some(target)),
    ),
  )
  let calls : Array[@workspace.Command] = []
  state.handle_disconnect_with_runner(agent_id, runner=async fn(cmds) {
    @async.sleep(0)
    for cmd in cmds {
      calls.push(cmd)
    }
    [0]
  })

  // Completing agents finalize state (PersistLifecycle) then transition to Done.
  // finalize_agent_with_runner is called with close_target=false and remove_worktree=false,
  // so plan_finalize emits no CloseTerminal or RemoveWorktree effects — the only effects
  // that invoke the runner. The assertion confirms no premature pane close occurs.
  assert_true(calls.is_empty())

  let agent = state.registry.get(agent_id) catch {
    _ => fail("agent not found")
  }
  assert_eq(agent.state, Done)
}
