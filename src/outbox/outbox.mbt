///|
pub let default_outbox_ttl_sec : Int64 = 86400L

///|
pub(all) enum OutboxDeliveryState {
  Pending
  Delivered
  Expired
} derive(Debug, Eq)

///|
pub fn OutboxDeliveryState::to_wire_string(
  self : OutboxDeliveryState,
) -> String {
  match self {
    Pending => "pending"
    Delivered => "delivered"
    Expired => "expired"
  }
}

///|
pub impl Show for OutboxDeliveryState with output(self, logger) -> Unit {
  logger.write_string(self.to_wire_string())
}

///|
fn parse_outbox_delivery_state(s : String) -> OutboxDeliveryState? {
  match s {
    "pending" => Some(Pending)
    "delivered" => Some(Delivered)
    "expired" => Some(Expired)
    _ => None
  }
}

///|
pub(all) struct OutboxMessage {
  message_id : String
  sender_id : String
  recipient_id : String
  body : String
  message_status : @types.Status
  delivery_state : OutboxDeliveryState
  delivery_method : @message.DeliveryMethod
  created_at : Int64
  expires_at : Int64
  delivery_attempts : Int
  last_attempt_at : Int64?
  last_error : String?
} derive(Debug, Eq)

///|
fn outbox_dir(project_dir : String) -> String {
  project_dir + "/.choir/outbox"
}

///|
pub fn recipient_outbox_path(
  project_dir : String,
  recipient_id : String,
) -> String {
  outbox_dir(project_dir) +
  "/" +
  @types.sanitize_agent_id(recipient_id) +
  ".jsonl"
}

///|
pub fn OutboxMessage::new(
  message_id : String,
  sender_id : String,
  recipient_id : String,
  body : String,
  message_status : @types.Status,
  delivery_method : @message.DeliveryMethod,
  created_at : Int64,
  expires_at : Int64,
) -> OutboxMessage {
  {
    message_id,
    sender_id,
    recipient_id,
    body,
    message_status,
    delivery_state: Pending,
    delivery_method,
    created_at,
    expires_at,
    delivery_attempts: 0,
    last_attempt_at: None,
    last_error: None,
  }
}

///|
pub fn OutboxMessage::mark_delivered(
  self : OutboxMessage,
  now : Int64,
) -> OutboxMessage {
  {
    ..self,
    delivery_state: Delivered,
    delivery_attempts: self.delivery_attempts + 1,
    last_attempt_at: Some(now),
    last_error: None,
  }
}

///|
pub fn OutboxMessage::record_failed_attempt(
  self : OutboxMessage,
  now : Int64,
  error : String,
) -> OutboxMessage {
  {
    ..self,
    delivery_attempts: self.delivery_attempts + 1,
    last_attempt_at: Some(now),
    last_error: Some(error),
  }
}

///|
pub fn OutboxMessage::mark_expired(self : OutboxMessage) -> OutboxMessage {
  { ..self, delivery_state: Expired }
}

///|
pub fn OutboxMessage::is_actionable(self : OutboxMessage, now : Int64) -> Bool {
  self.delivery_state == Pending && now < self.expires_at
}

///|
fn delivery_method_to_json(delivery : @message.DeliveryMethod) -> Json {
  let obj : Map[String, Json] = {}
  match delivery {
    @message.DeliveryMethod::TeamsInbox(path, json, fallback_target~) => {
      obj.set("tag", "teams_inbox".to_json())
      obj.set("path", path.to_json())
      obj.set("message_json", json.to_json())
      match fallback_target {
        Some(target) => obj.set("fallback_target", target.to_json())
        None => ()
      }
    }
    @message.DeliveryMethod::LocalTerminalInput(target, text) => {
      obj.set("tag", "local_terminal_input".to_json())
      obj.set("target", target.to_string().to_json())
      obj.set("text", text.to_json())
    }
    @message.DeliveryMethod::TcpPush(host, body) => {
      obj.set("tag", "tcp_push".to_json())
      obj.set("host", host.to_json())
      obj.set("body", body.to_json())
    }
    @message.DeliveryMethod::UdsHttp(path, body) => {
      obj.set("tag", "uds_http".to_json())
      obj.set("path", path.to_json())
      obj.set("body", body.to_json())
    }
  }
  obj.to_json()
}

///|
fn parse_delivery_method(json : Json) -> @message.DeliveryMethod? {
  guard json is Object(obj) else { return None }
  let tag = @types.json_field_string(obj, "tag").unwrap_or("")
  match tag {
    "teams_inbox" =>
      match
        (
          @types.json_field_string(obj, "path"),
          @types.json_field_string(obj, "message_json"),
        ) {
        (Some(path), Some(message_json)) =>
          Some(
            @message.DeliveryMethod::TeamsInbox(
              path,
              message_json,
              fallback_target=@types.json_field_string(obj, "fallback_target"),
            ),
          )
        _ => None
      }
    "local_terminal_input" =>
      match
        (
          @types.json_field_string(obj, "target"),
          @types.json_field_string(obj, "text"),
        ) {
        (Some(target), Some(text)) =>
          match @types.LocalTarget::parse(target) {
            Some(parsed) =>
              Some(@message.DeliveryMethod::LocalTerminalInput(parsed, text))
            None => None
          }
        _ => None
      }
    "tcp_push" =>
      match
        (
          @types.json_field_string(obj, "host"),
          @types.json_field_string(obj, "body"),
        ) {
        (Some(host), Some(body)) =>
          Some(@message.DeliveryMethod::TcpPush(host, body))
        _ => None
      }
    "uds_http" =>
      match
        (
          @types.json_field_string(obj, "path"),
          @types.json_field_string(obj, "body"),
        ) {
        (Some(path), Some(body)) =>
          Some(@message.DeliveryMethod::UdsHttp(path, body))
        _ => None
      }
    _ => None
  }
}

///|
fn parse_outbox_message_json(json : Json) -> OutboxMessage? {
  guard json is Object(obj) else { return None }
  let message_id = @types.json_field_string(obj, "message_id").unwrap_or("")
  let sender_id = @types.json_field_string(obj, "sender_id").unwrap_or("")
  let recipient_id = @types.json_field_string(obj, "recipient_id").unwrap_or("")
  let body = @types.json_field_string(obj, "body").unwrap_or("")
  let created_at = @types.json_field_int64(obj, "created_at").unwrap_or(-1L)
  let expires_at = @types.json_field_int64(obj, "expires_at").unwrap_or(-1L)
  let delivery_attempts = @types.json_field_int(obj, "delivery_attempts").unwrap_or(
    -1,
  )
  if message_id == "" ||
    sender_id == "" ||
    recipient_id == "" ||
    created_at < 0 ||
    expires_at < 0 ||
    delivery_attempts < 0 {
    return None
  }
  let message_status = match obj.get("message_status") {
    Some(value) => {
      let parsed : @types.Status? = Some(@json.from_json(value)) catch {
        _ => None
      }
      match parsed {
        Some(status) => status
        None => return None
      }
    }
    None => return None
  }
  let delivery_state = match
    parse_outbox_delivery_state(
      @types.json_field_string(obj, "delivery_state").unwrap_or(""),
    ) {
    Some(value) => value
    None => return None
  }
  let delivery_method = match obj.get("delivery_method") {
    Some(value) =>
      match parse_delivery_method(value) {
        Some(delivery) => delivery
        None => return None
      }
    None => return None
  }
  Some({
    message_id,
    sender_id,
    recipient_id,
    body,
    message_status,
    delivery_state,
    delivery_method,
    created_at,
    expires_at,
    delivery_attempts,
    last_attempt_at: @types.json_field_int64(obj, "last_attempt_at"),
    last_error: @types.json_field_string(obj, "last_error"),
  })
}

///|
pub fn build_outbox_snapshot_line(message : OutboxMessage) -> String {
  let obj : Map[String, Json] = {
    "message_id": message.message_id.to_json(),
    "sender_id": message.sender_id.to_json(),
    "recipient_id": message.recipient_id.to_json(),
    "body": message.body.to_json(),
    "message_status": message.message_status.to_json(),
    "delivery_state": message.delivery_state.to_wire_string().to_json(),
    "delivery_method": delivery_method_to_json(message.delivery_method),
    "created_at": message.created_at.to_int().to_json(),
    "expires_at": message.expires_at.to_int().to_json(),
    "delivery_attempts": message.delivery_attempts.to_json(),
  }
  match message.last_attempt_at {
    Some(value) => obj.set("last_attempt_at", value.to_int().to_json())
    None => ()
  }
  match message.last_error {
    Some(value) => obj.set("last_error", value.to_json())
    None => ()
  }
  obj.to_json().stringify() + "\n"
}

///|
pub fn append_outbox_snapshot(
  append_file : (String, String) -> Bool,
  project_dir : String,
  message : OutboxMessage,
) -> Bool {
  if !@sys.create_dir_all(outbox_dir(project_dir)) {
    return false
  }
  append_file(
    recipient_outbox_path(project_dir, message.recipient_id),
    build_outbox_snapshot_line(message),
  )
}

///|
pub fn load_recipient_outbox_from_content(
  content : String,
) -> Array[OutboxMessage] {
  let latest : Map[String, OutboxMessage] = {}
  for line in content.split("\n") {
    let trimmed = line.to_string().trim().to_string()
    if trimmed == "" {
      continue
    }
    let parsed : Json? = Some(@json.parse(trimmed)) catch { _ => None }
    match parsed {
      Some(json) =>
        match parse_outbox_message_json(json) {
          Some(message) => latest.set(message.message_id, message)
          None => ()
        }
      None => ()
    }
  }
  latest.values().collect()
}

///|
pub fn load_recipient_outbox(
  read_file : (String) -> String,
  project_dir : String,
  recipient_id : String,
) -> Array[OutboxMessage] {
  load_recipient_outbox_from_content(
    read_file(recipient_outbox_path(project_dir, recipient_id)),
  )
}

///|
pub fn write_recipient_outbox(
  write_file_atomic : (String, String) -> Bool,
  project_dir : String,
  recipient_id : String,
  messages : Array[OutboxMessage],
) -> Bool {
  if !@sys.create_dir_all(outbox_dir(project_dir)) {
    return false
  }
  let buf = StringBuilder::new()
  for message in messages {
    buf.write_string(build_outbox_snapshot_line(message))
  }
  write_file_atomic(
    recipient_outbox_path(project_dir, recipient_id),
    buf.to_string(),
  )
}

///|
pub fn compact_recipient_outbox(
  read_file : (String) -> String,
  write_file_atomic : (String, String) -> Bool,
  project_dir : String,
  recipient_id : String,
) -> Bool {
  write_recipient_outbox(
    write_file_atomic,
    project_dir,
    recipient_id,
    load_recipient_outbox(read_file, project_dir, recipient_id),
  )
}
