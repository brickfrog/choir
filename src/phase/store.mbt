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
pub fn write_lifecycle(
  project_dir : String,
  lifecycle : AgentLifecycle,
) -> Bool {
  @sys.write_file_atomic(
    lifecycle_path(project_dir, lifecycle.agent_id),
    lifecycle_to_json(lifecycle),
  )
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
