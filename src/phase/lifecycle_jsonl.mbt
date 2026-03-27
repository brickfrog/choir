///|
fn sanitize_agent_id_for_events(agent_id : String) -> String {
  let buf = StringBuilder::new()
  for c in agent_id {
    if c == '/' || c == '\\' || c == '\u0000' {
      buf.write_char('_')
    } else {
      buf.write_char(c)
    }
  }
  buf.to_string()
}

///|
fn escape_json_string(s : String) -> String {
  let buf = StringBuilder::new()
  for c in s {
    if c == '"' {
      buf.write_string("\\\"")
    } else if c == '\\' {
      buf.write_string("\\\\")
    } else if c == '\n' {
      buf.write_string("\\n")
    } else if c == '\r' {
      buf.write_string("\\r")
    } else if c == '\t' {
      buf.write_string("\\t")
    } else {
      buf.write_char(c)
    }
  }
  buf.to_string()
}

///|
pub fn append_lifecycle_event(
  project_dir : String,
  agent_id : String,
  from_state : String,
  to_state : String,
  trigger : String,
) -> Bool {
  let sanitized_id = sanitize_agent_id_for_events(agent_id)
  let events_dir = project_dir + "/.choir/events/"
  let path = events_dir + sanitized_id + ".jsonl"
  let now = @poller.now_sec()
  let data = "{\"from\":\"" +
    escape_json_string(from_state) +
    "\",\"to\":\"" +
    escape_json_string(to_state) +
    "\",\"trigger\":\"" +
    escape_json_string(trigger) +
    "\"}"
  let line = "{\"ts\":" +
    now.to_string() +
    ",\"type\":\"lifecycle.transition\",\"agent_id\":\"" +
    agent_id +
    "\",\"data\":" +
    data +
    "}\n"
  @sys.append_file_sync(path, line)
}
