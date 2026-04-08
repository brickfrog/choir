///|
pub fn append_jsonl_event(
  append_file : (String, String) -> Bool,
  project_dir : String,
  agent_id : String,
  event_type : String,
  data_json : Json,
) -> Bool {
  @evidence.append_agent_jsonl_event(
    append_file,
    project_dir,
    agent_id,
    @poller.now_sec(),
    event_type,
    data_json,
  )
}

///|
fn append_event(
  append_file : (String, String) -> Bool,
  project_dir : String,
  agent_id : String,
  event_type : String,
  data_json : Json,
) -> Bool {
  append_jsonl_event(append_file, project_dir, agent_id, event_type, data_json)
}

///|
pub fn append_evidence_event(
  append_file : (String, String) -> Bool,
  project_dir : String,
  agent_id : String,
  event : @evidence.EvidenceEvent,
) -> Bool {
  @evidence.append_agent_evidence_event(
    append_file,
    project_dir,
    agent_id,
    @poller.now_sec(),
    event,
  )
}

///|
pub fn append_lifecycle_event(
  project_dir : String,
  agent_id : String,
  from_lc : @phase.AgentLifecycle,
  to_lc : @phase.AgentLifecycle,
  trigger : @types.LifecycleTrigger,
) -> Bool {
  @phase.append_lifecycle_event(project_dir, agent_id, from_lc, to_lc, trigger)
}
