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
/// Builds one JSONL record (including trailing newline) for tests and append.
fn build_lifecycle_transition_jsonl_line(
  ts : Int64,
  agent_id : String,
  from_state : String,
  to_state : String,
  trigger : String,
) -> String {
  let data = "{\"from\":\"" +
    escape_json_string(from_state) +
    "\",\"to\":\"" +
    escape_json_string(to_state) +
    "\",\"trigger\":\"" +
    escape_json_string(trigger) +
    "\"}"
  "{\"ts\":" +
  ts.to_string() +
  ",\"type\":\"lifecycle.transition\",\"agent_id\":\"" +
  escape_json_string(agent_id) +
  "\",\"data\":" +
  data +
  "}\n"
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
  if not(@sys.create_dir_all(events_dir)) {
    return false
  }
  let path = events_dir + sanitized_id + ".jsonl"
  let line = build_lifecycle_transition_jsonl_line(
    @poller.now_sec(),
    agent_id,
    from_state,
    to_state,
    trigger,
  )
  @sys.append_file_sync(path, line)
}

///|
test "lifecycle transition jsonl line escapes and parses" {
  let line = build_lifecycle_transition_jsonl_line(
    99, "a\"b\\c", "from\"x", "to\"y", "tr\"g",
  )
  let parsed : Json = @json.parse(line.trim()) catch {
    _ => {
      fail("expected valid json")
      panic()
    }
  }
  guard parsed is Object(root) else {
    fail("expected object")
    panic()
  }
  match root.get("ts") {
    Some(Number(n, ..)) => assert_eq(n.to_int(), 99)
    _ => fail("ts")
  }
  match root.get("type") {
    Some(String(s)) => assert_eq(s, "lifecycle.transition")
    _ => fail("type")
  }
  match root.get("agent_id") {
    Some(String(s)) => assert_eq(s, "a\"b\\c")
    _ => fail("agent_id")
  }
  guard root.get("data") is Some(Object(d)) else {
    fail("data object")
    panic()
  }
  match d.get("from") {
    Some(String(s)) => assert_eq(s, "from\"x")
    _ => fail("from")
  }
  match d.get("to") {
    Some(String(s)) => assert_eq(s, "to\"y")
    _ => fail("to")
  }
  match d.get("trigger") {
    Some(String(s)) => assert_eq(s, "tr\"g")
    _ => fail("trigger")
  }
}
