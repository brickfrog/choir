///|
/// Daemon-side per-agent inbox. Message content is persisted here as a
/// durable ledger: small single-line payloads can be sent inline, while
/// larger payloads remain pending for `check_inbox` drain/ack.
fn inbox_state_path(project_dir : String) -> String {
  project_dir + "/.choir/inbox.json"
}

///|
pub let inbox_inline_body_limit : Int = 200

///|
pub let inbox_renudge_after_sec : Int64 = 120L

///|
pub let inbox_nudge_attempt_cap : Int = 5

///|
fn inbox_state_json(inboxes : Map[String, Array[@types.InboxMessage]]) -> Json {
  let entries : Map[String, Json] = {}
  for entry in inboxes {
    let (recipient_id, messages) = entry
    let items : Array[Json] = []
    for message in messages {
      items.push(message.to_json())
    }
    entries.set(recipient_id, items.to_json())
  }
  { "version": (1).to_json(), "inboxes": entries.to_json() }.to_json()
}

///|
fn parse_inbox_state_json(
  content : String,
) -> Result[Map[String, Array[@types.InboxMessage]], @types.ChoirError] {
  let parse_error = fn(message : String) {
    @types.ChoirError::validation_error("inbox.json parse error: " + message)
  }
  let json = @json.parse(content) catch {
    _ => return Err(parse_error("invalid JSON"))
  }
  guard json is Object(root) else { return Err(parse_error("expected object")) }
  match @types.json_field_int(root, "version") {
    Some(1) => ()
    _ => return Err(parse_error("unsupported version"))
  }
  let out : Map[String, Array[@types.InboxMessage]] = {}
  match root.get("inboxes") {
    Some(Object(entries)) =>
      for entry in entries {
        let (recipient_id, value) = entry
        guard value is Array(items) else {
          return Err(parse_error("inbox entry is not an array"))
        }
        let messages : Array[@types.InboxMessage] = []
        for item in items {
          match @types.parse_inbox_message_json(item) {
            Ok(message) => messages.push(message)
            Err(e) => return Err(e)
          }
        }
        out.set(recipient_id, messages)
      }
    _ => return Err(parse_error("missing inboxes object"))
  }
  Ok(out)
}

///|
fn load_inboxes_for_boot(
  project_dir : String,
  path_exists : (String) -> Bool,
  boot_read_file : (String) -> String,
  write_file_atomic : (String, String) -> Bool,
  now_unix_sec : () -> Int64,
) -> Map[String, Array[@types.InboxMessage]] {
  let path = inbox_state_path(project_dir)
  if !path_exists(path) {
    return {}
  }
  let content = boot_read_file(path)
  if content == "" {
    return {}
  }
  match parse_inbox_state_json(content) {
    Ok(parsed) => parsed
    Err(e) => {
      let quarantine_path = path + ".quarantine." + now_unix_sec().to_string()
      if write_file_atomic(quarantine_path, content) {
        @moontrace.warn(
          "inbox.json parse error at boot; quarantined and starting with empty inboxes",
          fields=[
            @moontrace.field("event", "inbox_boot_parse_quarantined"),
            @moontrace.field("path", path),
            @moontrace.field("quarantine_path", quarantine_path),
            @moontrace.field("error", e.message()),
          ],
        )
      } else {
        @moontrace.error(
          "inbox.json parse error at boot; failed to write quarantine",
          fields=[
            @moontrace.field("event", "inbox_boot_quarantine_failed"),
            @moontrace.field("path", path),
            @moontrace.field("error", e.message()),
          ],
        )
      }
      {}
    }
  }
}

///|
fn ServerState::persist_inboxes(self : ServerState) -> Unit {
  let path = inbox_state_path(self.config.project_dir)
  if !(self.write_file_atomic)(
      path,
      inbox_state_json(self.inboxes).stringify(indent=2),
    ) {
    @moontrace.error("inbox persist failed; in-memory inbox retained", fields=[
      @moontrace.field("event", "inbox_persist_failed"),
      @moontrace.field("path", path),
    ])
  }
}

///|
pub fn ServerState::pending_inbox_count(
  self : ServerState,
  recipient_id : String,
) -> Int {
  match self.inboxes.get(recipient_id) {
    Some(messages) => {
      let mut pending = 0
      for message in messages {
        if message.delivery_state == @types.InboxDeliveryState::Pending {
          pending = pending + 1
        }
      }
      pending
    }
    None => 0
  }
}

///|
fn ServerState::enqueue_inbox_message(
  self : ServerState,
  recipient_id : String,
  sender_id : String,
  body : String,
  status : @types.Status,
  queued_at_unix? : Int64 = @env.now().reinterpret_as_int64() / 1000L,
) -> (@types.InboxMessage, Int) {
  let message_id = self.run_id +
    "-inbox-" +
    queued_at_unix.to_string() +
    "-" +
    @runtime.simple_hash(recipient_id + "|" + sender_id + "|" + body).to_string()
  let message : @types.InboxMessage = {
    message_id,
    sender_id,
    recipient_id,
    body,
    status,
    queued_at_unix,
    delivery_state: @types.InboxDeliveryState::Pending,
    nudge_attempts: 0,
    last_nudged_at_unix: None,
  }
  let queue = match self.inboxes.get(recipient_id) {
    Some(messages) => messages
    None => {
      let fresh : Array[@types.InboxMessage] = []
      self.inboxes.set(recipient_id, fresh)
      fresh
    }
  }
  queue.push(message)
  self.persist_inboxes()
  self.emit_tui_event(
    @types.TuiEvent::MessageQueued(recipient_id~, sender_id~, message_id~),
  )
  (message, self.pending_inbox_count(recipient_id))
}

///|
/// Queue one message for an agent; returns the pending count afterwards.
/// Emits the message-queued journal event and checkpoints the inbox.
pub fn ServerState::queue_inbox_message(
  self : ServerState,
  recipient_id : String,
  sender_id : String,
  body : String,
  status : @types.Status,
  queued_at_unix? : Int64 = @env.now().reinterpret_as_int64() / 1000L,
) -> Int {
  let (_, pending) = self.enqueue_inbox_message(
    recipient_id,
    sender_id,
    body,
    status,
    queued_at_unix~,
  )
  pending
}

///|
fn inbox_body_inline_eligible(body : String) -> Bool {
  let trimmed = body.trim()
  trimmed.length() <= inbox_inline_body_limit &&
  !trimmed.contains("\n") &&
  !trimmed.contains("\r")
}

///|
fn inbox_terminal_payload(
  message : @types.InboxMessage,
  pending : Int,
) -> String {
  if inbox_body_inline_eligible(message.body) {
    @message.format_message(message.sender_id, message.body.trim().to_owned())
  } else {
    @message.format_inbox_nudge(pending)
  }
}

///|
fn ServerState::replace_inbox_message(
  self : ServerState,
  recipient_id : String,
  message_id : String,
  update : (@types.InboxMessage) -> @types.InboxMessage,
) -> @types.InboxMessage? {
  match self.inboxes.get(recipient_id) {
    Some(messages) => {
      let updated : Array[@types.InboxMessage] = []
      let mut changed : @types.InboxMessage? = None
      for message in messages {
        if message.message_id == message_id {
          let next = update(message)
          updated.push(next)
          changed = Some(next)
        } else {
          updated.push(message)
        }
      }
      match changed {
        Some(_) => {
          self.inboxes.set(recipient_id, updated)
          self.persist_inboxes()
        }
        None => ()
      }
      changed
    }
    None => None
  }
}

///|
fn ServerState::record_inbox_nudge_attempt(
  self : ServerState,
  recipient_id : String,
  message_id : String,
  now_unix_sec : Int64,
) -> @types.InboxMessage? {
  self.replace_inbox_message(recipient_id, message_id, fn(message) {
    {
      ..message,
      nudge_attempts: message.nudge_attempts + 1,
      last_nudged_at_unix: Some(now_unix_sec),
    }
  })
}

///|
fn ServerState::mark_inbox_delivered_inline(
  self : ServerState,
  recipient_id : String,
  message_id : String,
) -> Unit {
  match
    self.replace_inbox_message(recipient_id, message_id, fn(message) {
      { ..message, delivery_state: @types.InboxDeliveryState::DeliveredInline }
    }) {
    Some(_) =>
      self.emit_tui_event(
        @types.TuiEvent::MessageDelivered(recipient_id~, message_id~),
      )
    None => ()
  }
}

///|
fn warn_if_inbox_nudge_exhausted(message : @types.InboxMessage?) -> Unit {
  match message {
    Some(current) =>
      if current.delivery_state == @types.InboxDeliveryState::Pending &&
        current.nudge_attempts >= inbox_nudge_attempt_cap {
        @moontrace.warn("inbox nudge attempts exhausted", fields=[
          @moontrace.field("event", "inbox_nudge_attempts_exhausted"),
          @moontrace.field("recipient_id", current.recipient_id),
          @moontrace.field("sender_id", current.sender_id),
          @moontrace.field("message_id", current.message_id),
          @moontrace.field("attempts", current.nudge_attempts),
        ])
      }
    None => ()
  }
}

///|
pub async fn ServerState::deliver_inbox_terminal_message(
  self : ServerState,
  recipient_id : String,
  target : @types.LocalTarget,
  sender_id : String,
  body : String,
  status : @types.Status,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  now_unix_sec? : Int64 = @poller.now_sec(),
  sleep_fn? : async (Int) -> Unit = @async.sleep,
) -> Result[Unit, @types.ChoirError] {
  let (message, pending) = self.enqueue_inbox_message(
    recipient_id,
    sender_id,
    body,
    status,
    queued_at_unix=now_unix_sec,
  )
  let inline = inbox_body_inline_eligible(message.body)
  let delivery = @message.DeliveryMethod::LocalTerminalInput(
    target,
    inbox_terminal_payload(message, pending),
  )
  let result = @tools.execute_delivery(
    delivery,
    runner,
    project_dir=self.config.project_dir,
    sleep_fn~,
  )
  let attempted = self.record_inbox_nudge_attempt(
    recipient_id,
    message.message_id,
    now_unix_sec,
  )
  match result {
    Ok(_) => {
      if inline {
        self.mark_inbox_delivered_inline(recipient_id, message.message_id)
      } else {
        warn_if_inbox_nudge_exhausted(attempted)
      }
      Ok(())
    }
    Err(e) => {
      warn_if_inbox_nudge_exhausted(attempted)
      Err(e)
    }
  }
}

///|
fn inbox_message_stale_for_nudge(
  message : @types.InboxMessage,
  now_unix_sec : Int64,
) -> Bool {
  if message.delivery_state != @types.InboxDeliveryState::Pending ||
    message.nudge_attempts >= inbox_nudge_attempt_cap {
    return false
  }
  let last_reference = match message.last_nudged_at_unix {
    Some(value) => value
    None => message.queued_at_unix
  }
  now_unix_sec >= last_reference &&
  now_unix_sec - last_reference >= inbox_renudge_after_sec
}

///|
fn first_stale_inbox_message(
  messages : Array[@types.InboxMessage],
  now_unix_sec : Int64,
) -> @types.InboxMessage? {
  for message in messages {
    if inbox_message_stale_for_nudge(message, now_unix_sec) {
      return Some(message)
    }
  }
  None
}

///|
async fn ServerState::renudge_inbox_message(
  self : ServerState,
  message : @types.InboxMessage,
  target : @types.LocalTarget,
  now_unix_sec : Int64,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  sleep_fn : async (Int) -> Unit,
) -> Unit {
  let pending = self.pending_inbox_count(message.recipient_id)
  let inline = inbox_body_inline_eligible(message.body)
  let delivery = @message.DeliveryMethod::LocalTerminalInput(
    target,
    inbox_terminal_payload(message, pending),
  )
  let result = @tools.execute_delivery(
    delivery,
    runner,
    project_dir=self.config.project_dir,
    sleep_fn~,
  )
  let attempted = self.record_inbox_nudge_attempt(
    message.recipient_id,
    message.message_id,
    now_unix_sec,
  )
  match result {
    Ok(_) =>
      if inline {
        self.mark_inbox_delivered_inline(
          message.recipient_id,
          message.message_id,
        )
      } else {
        warn_if_inbox_nudge_exhausted(attempted)
      }
    Err(_) => warn_if_inbox_nudge_exhausted(attempted)
  }
}

///|
pub async fn ServerState::sweep_stale_inbox_nudges(
  self : ServerState,
  now_unix_sec : Int64,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  sleep_fn? : async (Int) -> Unit = @async.sleep,
) -> Unit {
  for entry in self.inboxes {
    let (recipient_id, messages) = entry
    match first_stale_inbox_message(messages, now_unix_sec) {
      Some(message) =>
        match self.registry.get_opt(recipient_id) {
          Some(agent) =>
            match agent.terminal_target {
              Some(target) =>
                self.renudge_inbox_message(
                  message, target, now_unix_sec, runner, sleep_fn,
                )
              None => ()
            }
          None => ()
        }
      None => ()
    }
  }
}

///|
/// Drain all pending messages for an agent. The pull itself is the ack:
/// pending messages are marked drained, the journal records one
/// message-delivered event per message, and the checkpoint is rewritten.
pub fn ServerState::drain_inbox(
  self : ServerState,
  recipient_id : String,
) -> Array[@types.InboxMessage] {
  match self.inboxes.get(recipient_id) {
    Some(messages) => {
      let drained : Array[@types.InboxMessage] = []
      let updated : Array[@types.InboxMessage] = []
      for message in messages {
        if message.delivery_state == @types.InboxDeliveryState::Pending {
          drained.push(message)
          updated.push({
            ..message,
            delivery_state: @types.InboxDeliveryState::Drained,
          })
        } else {
          updated.push(message)
        }
      }
      if drained.length() == 0 {
        return []
      }
      self.inboxes.set(recipient_id, updated)
      self.persist_inboxes()
      for message in drained {
        self.emit_tui_event(
          @types.TuiEvent::MessageDelivered(
            recipient_id~,
            message_id=message.message_id,
          ),
        )
      }
      drained
    }
    None => []
  }
}

///|
/// `check_inbox`: agent-facing pull tool. Returns all pending messages for
/// the caller and marks them delivered.
pub fn ServerState::handle_check_inbox_request(
  self : ServerState,
  req : @types.Request,
) -> @types.Response {
  ignore(self.tool_registry.lookup(req.role, req.name)) catch {
    e => return @tools.tool_response_err_from_caught(e)
  }
  let caller_id = match request_agent_id(req) {
    Some(value) if value != "" => value
    _ => return @types.Response::Err("check_inbox requires caller_id")
  }
  let caller = match self.registry.get_opt(caller_id) {
    Some(agent) => agent
    None =>
      return @types.Response::Err(
        "check_inbox caller is not registered: " + caller_id,
      )
  }
  if caller.role != req.role {
    return @types.Response::Err(
      "check_inbox caller role mismatch: " +
      caller_id +
      " is " +
      caller.role.to_wire_string() +
      ", request role is " +
      req.role.to_wire_string(),
    )
  }
  let drained = self.drain_inbox(caller_id)
  let items : Array[Json] = []
  for message in drained {
    items.push(message.to_json())
  }
  @types.Response::ok_values({
    "messages": items.to_json(),
    "count": drained.length().to_json(),
  })
}
