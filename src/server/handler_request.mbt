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
  let hash_input = recipient_id +
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
  match state.durable_deliver_to_parent(pr.agent_id, message, status, runner) {
    Ok(_) => ()
    Err(e) =>
      @moontrace.error("outbox write failed for stale PR delivery", fields=[
        @moontrace.field("agent_id", pr.agent_id),
        @moontrace.field("pr_number", pr.pr_number),
        @moontrace.field("error", e.message()),
      ])
  }
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
