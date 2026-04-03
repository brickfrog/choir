///|
/// Builds one JSONL record (including trailing newline) for tests and append.
fn build_lifecycle_transition_jsonl_line(
  ts : Int64,
  agent_id : String,
  from_state : String,
  to_state : String,
  trigger : String,
) -> String {
  let data : Map[String, Json] = {
    "from": from_state.to_json(),
    "to": to_state.to_json(),
    "trigger": trigger.to_json(),
  }
  let obj : Map[String, Json] = {
    "ts": ts.to_int().to_json(),
    "type": "lifecycle.transition".to_json(),
    "agent_id": agent_id.to_json(),
    "data": data.to_json(),
  }
  obj.to_json().stringify() + "\n"
}

///|
pub fn append_lifecycle_event(
  project_dir : String,
  agent_id : String,
  from_lc : AgentLifecycle,
  to_lc : AgentLifecycle,
  trigger : @types.LifecycleTrigger,
) -> Bool {
  let sanitized_id = @types.sanitize_agent_id(agent_id)
  let events_dir = project_dir + "/.choir/events/"
  if !@sys.create_dir_all(events_dir) {
    return false
  }
  let path = events_dir + sanitized_id + ".jsonl"
  let line = build_lifecycle_transition_jsonl_line(
    @poller.now_sec(),
    agent_id,
    lifecycle_to_json(from_lc),
    lifecycle_to_json(to_lc),
    trigger.to_wire_string(),
  )
  @sys.append_file_sync(path, line)
}

///|
test "lifecycle transition jsonl line escapes and parses" {
  let line = build_lifecycle_transition_jsonl_line(
    99L, "a\"b\\c", "from\"x", "to\"y", "tr\"g",
  )
  let parsed : Json = @json.parse(line.trim()) catch {
    _ => {
      fail("expected valid json")
      return
    }
  }
  guard parsed is Object(root) else {
    fail("expected object")
    return
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
    return
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
