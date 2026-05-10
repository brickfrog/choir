///|
fn lifecycle_path(project_dir : String, agent_id : String) -> String {
  project_dir + "/.choir/kv/" + lifecycle_key(agent_id)
}

///|
pub fn read_lifecycle(
  project_dir : String,
  agent_id : String,
) -> AgentLifecycle? {
  let content : String = @sys.read_file(lifecycle_path(project_dir, agent_id))
  if content == "" {
    None
  } else {
    lifecycle_from_json(content)
  }
}

///|
/// Persist a lifecycle and stamp `last_updated_unix_sec` to now. Every write
/// site (including raw `write_lifecycle` callers in lifecycle.mbt and any
/// rescue/handoff path that explicitly set 0L) gets the same monotonic
/// timestamp without each call having to remember to compute it. Consumers
/// of staleness (`active_agent_ids_from_lifecycle`, the wave_state long-
/// running-root check) can therefore trust this field.
pub fn write_lifecycle(
  project_dir : String,
  lifecycle : AgentLifecycle,
) -> Bool {
  let stamped = {
    ..lifecycle,
    last_updated_unix_sec: @env.now().reinterpret_as_int64() / 1000L,
  }
  @sys.write_file_atomic(
    lifecycle_path(project_dir, stamped.agent_id),
    lifecycle_to_json(stamped),
  )
}

///|
pub fn delete_lifecycle(project_dir : String, agent_id : String) -> Bool {
  @sys.delete_file_sync(lifecycle_path(project_dir, agent_id))
}

///|
pub fn read_or_default_lifecycle(
  project_dir : String,
  agent_id : String,
  role : @types.Role,
) -> AgentLifecycle {
  match read_lifecycle(project_dir, agent_id) {
    Some(lifecycle) => lifecycle
    None => lifecycle_for_role(agent_id, role)
  }
}

///|
pub(all) struct LifecycleStore {
  project_dir : String
}

///|
pub fn LifecycleStore::new(project_dir : String) -> LifecycleStore {
  { project_dir, }
}

///|
pub fn LifecycleStore::read(
  self : LifecycleStore,
  agent_id : String,
) -> AgentLifecycle? {
  read_lifecycle(self.project_dir, agent_id)
}

///|
pub fn LifecycleStore::write(
  self : LifecycleStore,
  lc : AgentLifecycle,
) -> Bool {
  write_lifecycle(self.project_dir, lc)
}

///|
pub fn LifecycleStore::read_or_default(
  self : LifecycleStore,
  agent_id : String,
  role : @types.Role,
) -> AgentLifecycle {
  read_or_default_lifecycle(self.project_dir, agent_id, role)
}

///|
pub fn LifecycleStore::append_event(
  self : LifecycleStore,
  agent_id : String,
  from_lc : AgentLifecycle,
  to_lc : AgentLifecycle,
  trigger : @types.LifecycleTrigger,
) -> Bool {
  append_lifecycle_event(self.project_dir, agent_id, from_lc, to_lc, trigger)
}
