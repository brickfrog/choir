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
    "ts": Json::number(ts.to_double()),
    "type": "lifecycle.transition".to_json(),
    "agent_id": agent_id.to_json(),
    "data": data.to_json(),
  }
  obj.to_json().stringify() + "\n"
}

///|
fn lifecycle_failed_reason(lifecycle : AgentLifecycle) -> FailureReason? {
  match lifecycle.workflow {
    Supervisor(Failed(reason~)) => Some(reason)
    Dev(Failed(reason~)) => Some(reason)
    Worker(Failed(reason~)) => Some(reason)
    _ => None
  }
}

///|
pub fn is_active_to_failed_transition(
  from_lc : AgentLifecycle,
  to_lc : AgentLifecycle,
) -> Bool {
  lifecycle_failed_reason(from_lc) is None &&
  lifecycle_failed_reason(to_lc) is Some(_)
}

///|
fn warn_active_to_failed_transition(
  agent_id : String,
  from_lc : AgentLifecycle,
  to_lc : AgentLifecycle,
  trigger : @types.LifecycleTrigger,
) -> Unit {
  match lifecycle_failed_reason(to_lc) {
    Some(reason) =>
      @moontrace.warn("agent lifecycle transitioned to failed", fields=[
        @moontrace.field("agent_id", agent_id),
        @moontrace.field("from_state", lifecycle_to_json(from_lc)),
        @moontrace.field("to_state", lifecycle_to_json(to_lc)),
        @moontrace.field("trigger", trigger.to_wire_string()),
        @moontrace.field("reason", reason.to_wire_string()),
      ])
    None => ()
  }
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
  let ok = @sys.append_file_sync(path, line)
  if ok && is_active_to_failed_transition(from_lc, to_lc) {
    warn_active_to_failed_transition(agent_id, from_lc, to_lc, trigger)
  }
  ok
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
