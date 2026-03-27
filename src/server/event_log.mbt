///|
fn append_event(
  project_dir : String,
  agent_id : String,
  event_type : String,
  data_json : String,
) -> Bool {
  let sanitized_id = @types.sanitize_agent_id(agent_id)
  let events_dir = project_dir + "/.choir/events/"
  let path = events_dir + sanitized_id + ".jsonl"
  let now = @poller.now_sec()
  let line = "{\"ts\":" +
    now.to_string() +
    ",\"type\":\"" +
    event_type +
    "\",\"agent_id\":\"" +
    agent_id +
    "\",\"data\":" +
    data_json +
    "}\n"
  @sys.append_file_sync(path, line)
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
