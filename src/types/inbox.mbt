///|
/// One message queued in the daemon-side per-agent inbox. Message content
/// travels to agents via the pull-based `check_inbox` tool (channel (b) of
/// the economic invariant); send-keys only ever carries the fixed short
/// nudge. Self-contained: queued/delivered is daemon state, not inferred
/// from delivery.log.
pub(all) struct InboxMessage {
  message_id : String
  sender_id : String
  recipient_id : String
  body : String
  status : Status
  queued_at_unix : Int64
} derive(Debug, Eq)

///|
pub impl ToJson for InboxMessage with fn to_json(self) -> Json {
  {
    "message_id": self.message_id.to_json(),
    "sender_id": self.sender_id.to_json(),
    "recipient_id": self.recipient_id.to_json(),
    "body": self.body.to_json(),
    "status": self.status.to_wire_string().to_json(),
    "queued_at_unix": self.queued_at_unix.to_json(),
  }.to_json()
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
  Ok({ message_id, sender_id, recipient_id, body, status, queued_at_unix })
}
