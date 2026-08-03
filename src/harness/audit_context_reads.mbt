///|
priv struct RetainedAuditReadRequest {
  digest : @control.Digest
  cursor : Int
}

///|
fn failed_retained_read(
  request : RetainedAuditReadRequest,
) -> @control.AuditContextReadObservation {
  {
    digest: request.digest,
    cursor: request.cursor,
    total: 0,
    next_cursor: None,
    eof: false,
    succeeded: false,
  }
}

///|
fn retained_json_string(fields : Map[String, Json], key : String) -> String? {
  match fields.get(key) {
    Some(String(value)) => Some(value)
    _ => None
  }
}

///|
fn retained_json_int(fields : Map[String, Json], key : String) -> Int? {
  match fields.get(key) {
    Some(Number(value, ..)) => Some(value.to_int())
    _ => None
  }
}

///|
fn retained_json_bool(fields : Map[String, Json], key : String) -> Bool? {
  match fields.get(key) {
    Some(True) => Some(true)
    Some(False) => Some(false)
    _ => None
  }
}

///|
fn retained_json_object(value : Json?) -> Map[String, Json]? {
  match value {
    Some(Object(fields)) => Some(fields)
    _ => None
  }
}

///|
fn retained_json_value(value : Json?) -> Json? {
  match value {
    Some(String(text)) => Some(@json.parse(text) catch { _ => return None })
    Some(value) => Some(value)
    None => None
  }
}

///|
fn retained_read_request(value : Json?) -> RetainedAuditReadRequest? {
  guard retained_json_value(value) is Some(Object(fields)) else { return None }
  guard retained_json_string(fields, "digest") is Some(digest) &&
    retained_json_int(fields, "cursor") is Some(cursor) else {
    return None
  }
  let typed = @control.Digest(digest)
  if !typed.is_valid() || cursor < 0 {
    None
  } else {
    Some({ digest: typed, cursor })
  }
}

///|
fn retained_read_page(value : Json?) -> @control.AuditContextReadObservation? {
  let value = retained_json_value(value)
  // Accept the MCP text-content envelope as well as the flattened text used by
  // subscription CLIs. Both are retained provider output, never a reread.
  let page = match value {
    Some(Object(fields)) =>
      match fields.get("content") {
        Some(Array([Object(block), ..])) =>
          retained_json_value(block.get("text"))
        _ => value
      }
    _ => value
  }
  guard page is Some(Object(fields)) else { return None }
  guard retained_json_string(fields, "digest") is Some(digest) &&
    retained_json_int(fields, "cursor") is Some(cursor) &&
    retained_json_int(fields, "total") is Some(total) &&
    retained_json_bool(fields, "eof") is Some(eof) else {
    return None
  }
  let next_cursor = match fields.get("next_cursor") {
    Some(Null) | None => None
    Some(Number(value, ..)) => Some(value.to_int())
    _ => return None
  }
  Some({
    digest: @control.Digest(digest),
    cursor,
    total,
    next_cursor,
    eof,
    succeeded: true,
  })
}

///|
/// Extract successful audit-context pages from retained Claude/Codex provider
/// events and bind each page to the tool execution that requested it.
pub fn retained_audit_context_reads_by_execution(
  output : String,
) -> Map[String, @control.AuditContextReadObservation] {
  let requests : Map[String, RetainedAuditReadRequest] = Map([])
  let reads : Map[String, @control.AuditContextReadObservation] = Map([])
  for raw in output.split("\n") {
    let json = @json.parse(raw.trim().to_owned()) catch { _ => continue }
    guard json is Object(fields) else { continue }
    match retained_json_string(fields, "type") {
      Some("assistant") =>
        match retained_json_object(fields.get("message")) {
          Some(message) =>
            match message.get("content") {
              Some(Array(blocks)) =>
                for block in blocks {
                  guard block is Object(item) else { continue }
                  if retained_json_string(item, "type") == Some("tool_use") &&
                    retained_json_string(item, "name") ==
                    Some("mcp__choir_sandbox__read_audit_context") {
                    match
                      (
                        retained_json_string(item, "id"),
                        retained_read_request(item.get("input")),
                      ) {
                      (Some(id), Some(request)) => requests[id] = request
                      _ => ()
                    }
                  }
                }
              _ => ()
            }
          None => ()
        }
      Some("user") =>
        match retained_json_object(fields.get("message")) {
          Some(message) =>
            match message.get("content") {
              Some(Array(blocks)) =>
                for block in blocks {
                  guard block is Object(item) else { continue }
                  guard retained_json_string(item, "type") ==
                    Some("tool_result") &&
                    retained_json_bool(item, "is_error") != Some(true) &&
                    retained_json_string(item, "tool_use_id") is Some(id) &&
                    requests.contains(id) else {
                    continue
                  }
                  let request = requests[id]
                  match retained_read_page(item.get("content")) {
                    Some(read) if read.digest == request.digest &&
                      read.cursor == request.cursor => reads[id] = read
                    _ => reads[id] = failed_retained_read(request)
                  }
                }
              _ => ()
            }
          None => ()
        }
      Some("item.started") | Some("item.completed") => {
        guard retained_json_object(fields.get("item")) is Some(item) &&
          retained_json_string(item, "type") == Some("mcp_tool_call") &&
          retained_json_string(item, "tool") == Some("read_audit_context") &&
          retained_json_string(item, "id") is Some(id) else {
          continue
        }
        if retained_json_string(fields, "type") == Some("item.started") {
          match retained_read_request(item.get("arguments")) {
            Some(request) => requests[id] = request
            None => ()
          }
        } else if requests.contains(id) {
          let request = requests[id]
          match
            retained_read_page(
              match item.get("result") {
                Some(value) => Some(value)
                None => item.get("output")
              },
            ) {
            Some(read) if retained_json_string(item, "status") ==
              Some("completed") &&
              read.digest == request.digest &&
              read.cursor == request.cursor => reads[id] = read
            _ => reads[id] = failed_retained_read(request)
          }
        }
      }
      _ => ()
    }
  }
  reads
}
