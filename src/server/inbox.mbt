///|
/// Daemon-side per-agent inbox (Phase 2a). Message content is persisted
/// here and pulled by agents via `check_inbox`; send-keys carries only the
/// fixed nudge. Checkpointed like the rest of ServerState.
fn inbox_state_path(project_dir : String) -> String {
  project_dir + "/.choir/inbox.json"
}

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
    Some(messages) => messages.length()
    None => 0
  }
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
) -> Int {
  let now_ms = @env.now().reinterpret_as_int64()
  let message_id = self.run_id +
    "-inbox-" +
    now_ms.to_string() +
    "-" +
    @runtime.simple_hash(recipient_id + "|" + sender_id + "|" + body).to_string()
  let message : @types.InboxMessage = {
    message_id,
    sender_id,
    recipient_id,
    body,
    status,
    queued_at_unix: now_ms / 1000L,
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
  queue.length()
}

///|
/// Drain all pending messages for an agent. The pull itself is the ack:
/// messages are marked delivered (removed from the pending queue), the
/// journal records one message-delivered event per message, and the
/// checkpoint is rewritten.
pub fn ServerState::drain_inbox(
  self : ServerState,
  recipient_id : String,
) -> Array[@types.InboxMessage] {
  match self.inboxes.get(recipient_id) {
    Some(messages) => {
      if messages.length() == 0 {
        return []
      }
      let drained = messages
      self.inboxes.set(recipient_id, [])
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
/// Inbox-routing capability handed to delivery planners: queues content and
/// returns the pending count so the terminal payload can shrink to the
/// fixed nudge.
pub fn ServerState::inbox_queue_capability(
  self : ServerState,
) -> (String, String, String, @types.Status) -> Int? {
  fn(recipient_id, sender_id, body, status) {
    Some(self.queue_inbox_message(recipient_id, sender_id, body, status))
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
