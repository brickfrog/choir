///|
fn append_event(
  append_file : (String, String) -> Bool,
  project_dir : String,
  agent_id : String,
  event_type : String,
  data_json : Json,
) -> Bool {
  let sanitized_id = @types.sanitize_agent_id(agent_id)
  let events_dir = project_dir + "/.choir/events/"
  if !@sys.create_dir_all(events_dir) {
    return false
  }
  let path = events_dir + sanitized_id + ".jsonl"
  let now = @poller.now_sec()
  let obj : Map[String, Json] = {
    "ts": now.to_int().to_json(),
    "type": event_type.to_json(),
    "agent_id": agent_id.to_json(),
    "data": data_json,
  }
  append_file(path, obj.to_json().stringify() + "\n")
}

///|
pub fn append_lifecycle_event(
  project_dir : String,
  agent_id : String,
  from_state : String,
  to_state : String,
  trigger : String,
) -> Bool {
  @phase.append_lifecycle_event(
    project_dir, agent_id, from_state, to_state, trigger,
  )
}
