///|
pub(all) enum InboxDeliveryState {
  Pending
  DeliveredInline
  Drained
} derive(Debug, Eq)

///|
pub fn InboxDeliveryState::to_wire_string(self : InboxDeliveryState) -> String {
  match self {
    Pending => "pending"
    DeliveredInline => "delivered_inline"
    Drained => "drained"
  }
}

///|
pub fn InboxDeliveryState::try_parse_wire(
  raw : String,
) -> Result[InboxDeliveryState, ChoirError] {
  match raw {
    "pending" => Ok(Pending)
    "delivered_inline" => Ok(DeliveredInline)
    "drained" => Ok(Drained)
    _ =>
      Err(ChoirError::validation_error("unknown inbox delivery state: " + raw))
  }
}

///|
pub impl Show for InboxDeliveryState with fn output(self, logger) -> Unit {
  logger.write_string(self.to_wire_string())
}

///|
/// One message queued in the daemon-side per-agent inbox. Message content
/// travels to agents via the pull-based `check_inbox` tool (channel (b) of
/// the economic invariant) when too large for inline nudge delivery.
/// Self-contained: pending/drained/inline-delivered is daemon state, not
/// inferred from delivery.log.
pub(all) struct InboxMessage {
  message_id : String
  sender_id : String
  recipient_id : String
  body : String
  status : Status
  queued_at_unix : Int64
  delivery_state : InboxDeliveryState
  nudge_attempts : Int
  last_nudged_at_unix : Int64?
} derive(Debug, Eq)

///|
pub impl ToJson for InboxMessage with fn to_json(self) -> Json {
  let obj : Map[String, Json] = {
    "message_id": self.message_id.to_json(),
    "sender_id": self.sender_id.to_json(),
    "recipient_id": self.recipient_id.to_json(),
    "body": self.body.to_json(),
    "status": self.status.to_wire_string().to_json(),
    "queued_at_unix": self.queued_at_unix.to_json(),
    "delivery_state": self.delivery_state.to_wire_string().to_json(),
    "nudge_attempts": self.nudge_attempts.to_json(),
  }
  match self.last_nudged_at_unix {
    Some(value) => obj.set("last_nudged_at_unix", value.to_json())
    None => ()
  }
  obj.to_json()
}

///|
pub fn parse_inbox_message_json(
  json : Json,
) -> Result[InboxMessage, ChoirError] {
  guard json is Object(obj) else {
    return Err(ChoirError::validation_error("inbox message: expected object"))
  }
  let message_id = match json_field_string(obj, "message_id") {
    Some(v) => v
    None =>
      return Err(ChoirError::validation_error("inbox message: message_id"))
  }
  let sender_id = json_field_string(obj, "sender_id").unwrap_or("")
  let recipient_id = match json_field_string(obj, "recipient_id") {
    Some(v) => v
    None =>
      return Err(ChoirError::validation_error("inbox message: recipient_id"))
  }
  let body = json_field_string(obj, "body").unwrap_or("")
  let status = match json_field_string(obj, "status") {
    Some(raw) =>
      match Status::try_parse_wire(raw) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
    None => Status::Info
  }
  let queued_at_unix = json_field_int64(obj, "queued_at_unix").unwrap_or(0L)
  let delivery_state = match json_field_string(obj, "delivery_state") {
    Some(raw) =>
      match InboxDeliveryState::try_parse_wire(raw) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
    None => InboxDeliveryState::Pending
  }
  let nudge_attempts = json_field_int(obj, "nudge_attempts").unwrap_or(0)
  let last_nudged_at_unix = json_field_int64(obj, "last_nudged_at_unix")
  Ok({
    message_id,
    sender_id,
    recipient_id,
    body,
    status,
    queued_at_unix,
    delivery_state,
    nudge_attempts,
    last_nudged_at_unix,
  })
}
