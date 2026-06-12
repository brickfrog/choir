///|
/// In-memory agent registry.
pub(all) struct AgentRegistry {
  agents : Map[String, @types.Agent]
  alive : Map[String, Bool]
  /// Last tool call per agent, recorded at the dispatch layer. Lives here
  /// (not on the connection) so it survives reconnects and is snapshot-able.
  last_tool_calls : Map[String, @types.ToolCallRecord]
  /// Unix second at which the agent's current session connection
  /// authenticated (registered). A connection knows only its fd and who it
  /// authenticated as; uptime is a fact about the agent.
  connected_at : Map[String, Int64]
  /// TUI journal choke point for registry mutations; installed by the server
  /// at boot, never required for correctness.
  mut on_event : ((@types.TuiEvent) -> Unit)?
}

///|
/// Create a new empty registry.
pub fn AgentRegistry::new() -> AgentRegistry {
  {
    agents: {},
    alive: {},
    last_tool_calls: {},
    connected_at: {},
    on_event: None,
  }
}

///|
pub fn AgentRegistry::record_agent_connected(
  self : AgentRegistry,
  agent_id : String,
  at_sec : Int64,
) -> Unit {
  self.connected_at.set(agent_id, at_sec)
}

///|
pub fn AgentRegistry::agent_connected_at(
  self : AgentRegistry,
  agent_id : String,
) -> Int64? {
  self.connected_at.get(agent_id)
}

///|
pub fn AgentRegistry::set_observer(
  self : AgentRegistry,
  observer : (@types.TuiEvent) -> Unit,
) -> Unit {
  self.on_event = Some(observer)
}

///|
fn AgentRegistry::notify(self : AgentRegistry, event : @types.TuiEvent) -> Unit {
  match self.on_event {
    Some(f) => f(event)
    None => ()
  }
}

///|
fn agent_registered_event(agent : @types.Agent) -> @types.TuiEvent {
  @types.TuiEvent::AgentRegistered(
    agent_id=agent.agent_id.to_string(),
    role=agent.role,
    agent_type=agent.agent_type,
    parent=agent.parent,
    workspace=agent.workspace,
    branch=agent.branch,
    terminal_target=match agent.terminal_target {
      Some(target) => Some(target.to_string())
      None => None
    },
    state=agent.state,
    spawn_depth=agent.spawn_depth,
  )
}

///|
/// Register a new agent. Raises if ID already exists.
pub fn AgentRegistry::insert(
  self : AgentRegistry,
  agent : @types.Agent,
) -> Unit raise @types.ChoirError {
  let id = agent.agent_id.to_string()
  if self.agents.contains(id) {
    raise @types.ChoirError::validation_error("agent already exists: " + id)
  } else {
    self.agents.set(id, agent)
    self.alive.set(id, true)
    self.notify(agent_registered_event(agent))
  }
}

///|
/// Register or refresh an agent in place, marking it alive.
pub fn AgentRegistry::upsert(
  self : AgentRegistry,
  agent : @types.Agent,
) -> Bool {
  let id = agent.agent_id.to_string()
  let existed = self.agents.contains(id)
  self.agents.set(id, agent)
  self.alive.set(id, true)
  self.notify(agent_registered_event(agent))
  existed
}

///|
/// Record the most recent tool call for an agent. Dispatch-layer choke
/// point: the server calls this once per completed tool call.
pub fn AgentRegistry::record_last_tool_call(
  self : AgentRegistry,
  agent_id : String,
  record : @types.ToolCallRecord,
) -> Unit {
  self.last_tool_calls.set(agent_id, record)
}

///|
pub fn AgentRegistry::last_tool_call(
  self : AgentRegistry,
  agent_id : String,
) -> @types.ToolCallRecord? {
  self.last_tool_calls.get(agent_id)
}

///|
/// Look up an agent by ID.
pub fn AgentRegistry::get(
  self : AgentRegistry,
  agent_id : String,
) -> @types.Agent raise @types.ChoirError {
  match self.agents.get(agent_id) {
    Some(agent) => agent
    None => raise @types.ChoirError::agent_not_found(agent_id)
  }
}

///|
/// Look up an agent by ID, returning None when absent.
pub fn AgentRegistry::get_opt(
  self : AgentRegistry,
  agent_id : String,
) -> @types.Agent? {
  self.agents.get(agent_id)
}

///|
/// Get the parent agent for a given agent ID.
pub fn AgentRegistry::get_parent(
  self : AgentRegistry,
  agent_id : String,
) -> @types.Agent raise @types.ChoirError {
  let agent = self.get(agent_id)
  match agent.parent {
    Some(parent_id) => self.get(parent_id)
    None =>
      raise @types.ChoirError::agent_not_found("no parent for " + agent_id)
  }
}

///|
/// Remove an agent from the registry.
pub fn AgentRegistry::remove(
  self : AgentRegistry,
  agent_id : String,
) -> @types.Agent raise @types.ChoirError {
  match self.agents.get(agent_id) {
    Some(agent) => {
      self.agents.remove(agent_id)
      self.alive.remove(agent_id)
      self.last_tool_calls.remove(agent_id)
      self.connected_at.remove(agent_id)
      self.notify(@types.TuiEvent::AgentRemoved(agent_id~))
      agent
    }
    None => raise @types.ChoirError::agent_not_found(agent_id)
  }
}

///|
/// List all agents.
pub fn AgentRegistry::list(self : AgentRegistry) -> Array[@types.Agent] {
  self.agents.values().collect()
}

///|
/// List children of a given agent.
pub fn AgentRegistry::children(
  self : AgentRegistry,
  parent_id : String,
) -> Array[@types.Agent] {
  self.agents.values()
  |> Iter::filter(fn(a) { a.parent == Some(parent_id) })
  |> Iter::collect()
}

///|
/// Update agent state with validation.
pub fn AgentRegistry::set_state(
  self : AgentRegistry,
  agent_id : String,
  new_state : @types.AgentState,
) -> Unit raise @types.ChoirError {
  match self.agents.get(agent_id) {
    Some(agent) => {
      let valid = match (agent.state, new_state) {
        (Spawning, Active) => true
        (Spawning, Failed) => true
        (Active, Completing) => true
        (Active, Failed) => true
        (Active, Suspended) => true
        (Suspended, Active) => true
        (Completing, Done) => true
        (Failed, Done) => true
        _ => false
      }
      if valid {
        let updated_agent = { ..agent, state: new_state }
        self.agents.set(agent_id, updated_agent)
        self.notify(
          @types.TuiEvent::AgentStateChanged(agent_id~, state=new_state),
        )
      } else {
        raise @types.ChoirError::validation_error(
          "invalid state transition: " +
          agent.state.to_wire_string() +
          " -> " +
          new_state.to_wire_string(),
        )
      }
    }
    None => raise @types.ChoirError::agent_not_found(agent_id)
  }
}

///|
/// Set agent alive status.
pub fn AgentRegistry::set_alive(
  self : AgentRegistry,
  agent_id : String,
  alive : Bool,
) -> Unit raise @types.ChoirError {
  match self.agents.get(agent_id) {
    Some(_) => self.alive.set(agent_id, alive)
    None => raise @types.ChoirError::agent_not_found(agent_id)
  }
}

///|
/// Get all active agents.
pub fn AgentRegistry::active_agents(
  self : AgentRegistry,
) -> Array[@types.Agent] {
  self.agents.values()
  |> Iter::filter(fn(a) { a.state == @types.AgentState::Active })
  |> Iter::collect()
}

///|
/// Get agents by role.
pub fn AgentRegistry::by_role(
  self : AgentRegistry,
  role : @types.Role,
) -> Array[@types.Agent] {
  self.agents.values()
  |> Iter::filter(fn(a) { a.role == role })
  |> Iter::collect()
}

///|
pub fn AgentRegistry::is_alive(
  self : AgentRegistry,
  agent_id : String,
) -> Bool? {
  self.alive.get(agent_id)
}

///|
pub fn AgentRegistry::clear(self : AgentRegistry) -> Unit {
  let ids : Array[String] = []
  for agent in self.agents.values() {
    ids.push(agent.agent_id.to_string())
  }
  for id in ids {
    self.agents.remove(id)
    self.alive.remove(id)
    self.last_tool_calls.remove(id)
    self.connected_at.remove(id)
  }
}

///|
pub fn registry_snapshot_path(project_dir : String) -> String {
  project_dir + "/.choir/registry_snapshot.json"
}

///|
fn registry_null_json() -> Json {
  @json.parse("null") catch {
    _ => "".to_json()
  }
}

///|
fn registry_optional_string_json(value : String?) -> Json {
  match value {
    Some(v) => v.to_json()
    None => registry_null_json()
  }
}

///|
fn registry_optional_target_json(value : @types.LocalTarget?) -> Json {
  match value {
    Some(v) => v.to_string().to_json()
    None => registry_null_json()
  }
}

///|
fn registry_host_json(host : @types.Host) -> Json {
  match host {
    @types.Host::Local => { "kind": "local".to_json() }.to_json()
    @types.Host::Remote(addr) =>
      { "kind": "remote".to_json(), "addr": addr.to_json() }.to_json()
  }
}

///|
fn registry_agent_snapshot_json(agent : @types.Agent, alive : Bool) -> Json {
  {
    "agent_id": agent.agent_id.to_string().to_json(),
    "role": agent.role.to_wire_string().to_json(),
    "agent_type": agent.agent_type.to_wire_string().to_json(),
    "parent": registry_optional_string_json(agent.parent),
    "workspace": agent.workspace.to_json(),
    "branch": agent.branch.to_json(),
    "terminal_target": registry_optional_target_json(agent.terminal_target),
    "host": registry_host_json(agent.host),
    "state": agent.state.to_wire_string().to_json(),
    "spawn_depth": agent.spawn_depth.to_json(),
    "alive": alive.to_json(),
  }.to_json()
}

///|
pub fn AgentRegistry::to_snapshot_json(self : AgentRegistry) -> Json {
  let agents : Array[Json] = []
  for agent in self.agents.values() {
    let id = agent.agent_id.to_string()
    agents.push(
      registry_agent_snapshot_json(agent, self.alive.get(id).unwrap_or(false)),
    )
  }
  { "version": (1).to_json(), "agents": agents.to_json() }.to_json()
}

///|
pub fn AgentRegistry::to_snapshot_string(self : AgentRegistry) -> String {
  self.to_snapshot_json().stringify(indent=2)
}

///|
fn registry_parse_error(message : String) -> @types.ChoirError {
  @types.ChoirError::validation_error(
    "registry snapshot parse error: " + message,
  )
}

///|
fn registry_string_field(
  obj : Map[String, Json],
  key : String,
) -> Result[String, @types.ChoirError] {
  match obj.get(key) {
    Some(String(value)) => Ok(value)
    _ => Err(registry_parse_error("missing string field: " + key))
  }
}

///|
fn registry_optional_string_field(
  obj : Map[String, Json],
  key : String,
) -> Result[String?, @types.ChoirError] {
  match obj.get(key) {
    Some(String(value)) => Ok(Some(value))
    // Absent OR explicit JSON `null` both encode "no value" — the encoder
    // (registry_optional_string_json) writes `null` for None, so accept
    // it on read.
    None | Some(Null) => Ok(None)
    // Present-but-malformed (a non-string, non-null value) must NOT
    // silently drop to None — that would let a corrupt snapshot apply
    // cleanly with the field's semantics quietly lost. Reject as a parse
    // error so the caller's transactional restore aborts and the live
    // state is preserved.
    Some(_) =>
      Err(registry_parse_error("optional field is not a string: " + key))
  }
}

///|
fn registry_int_field(
  obj : Map[String, Json],
  key : String,
) -> Result[Int, @types.ChoirError] {
  match obj.get(key) {
    Some(Number(value, ..)) => Ok(value.to_int())
    _ => Err(registry_parse_error("missing numeric field: " + key))
  }
}

///|
fn registry_bool_field(
  obj : Map[String, Json],
  key : String,
) -> Result[Bool, @types.ChoirError] {
  match obj.get(key) {
    Some(True) => Ok(true)
    Some(False) => Ok(false)
    _ => Err(registry_parse_error("missing boolean field: " + key))
  }
}

///|
fn registry_parse_host(json : Json?) -> Result[@types.Host, @types.ChoirError] {
  match json {
    Some(Object(obj)) =>
      match obj.get("kind") {
        Some(String("local")) => Ok(@types.Host::Local)
        Some(String("remote")) =>
          match obj.get("addr") {
            Some(String(addr)) => Ok(@types.Host::Remote(addr))
            _ => Err(registry_parse_error("remote host missing addr"))
          }
        Some(String(kind)) => Err(registry_parse_error("unknown host: " + kind))
        _ => Err(registry_parse_error("host missing kind"))
      }
    _ => Err(registry_parse_error("missing host object"))
  }
}

///|
fn registry_parse_agent_snapshot(
  obj : Map[String, Json],
) -> Result[(@types.Agent, Bool), @types.ChoirError] {
  let agent_id = match registry_string_field(obj, "agent_id") {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let role = match registry_string_field(obj, "role") {
    Ok(v) =>
      match @types.Role::try_parse_wire(v) {
        Ok(parsed) => parsed
        Err(e) => return Err(e)
      }
    Err(e) => return Err(e)
  }
  let agent_type = match registry_string_field(obj, "agent_type") {
    Ok(v) =>
      match @types.AgentType::try_parse_wire(v) {
        Ok(parsed) => parsed
        Err(e) => return Err(e)
      }
    Err(e) => return Err(e)
  }
  let parent = match registry_optional_string_field(obj, "parent") {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let workspace = match registry_string_field(obj, "workspace") {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let branch = match registry_string_field(obj, "branch") {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let terminal_target = match
    registry_optional_string_field(obj, "terminal_target") {
    Ok(Some(raw)) => @types.LocalTarget::parse(raw)
    Ok(None) => None
    Err(e) => return Err(e)
  }
  let host = match registry_parse_host(obj.get("host")) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let state = match registry_string_field(obj, "state") {
    Ok(v) =>
      match @types.AgentState::try_parse_wire(v) {
        Ok(parsed) => parsed
        Err(e) => return Err(e)
      }
    Err(e) => return Err(e)
  }
  let spawn_depth = match registry_int_field(obj, "spawn_depth") {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let alive = match registry_bool_field(obj, "alive") {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  Ok(
    (
      {
        agent_id,
        role,
        agent_type,
        parent,
        workspace,
        branch,
        terminal_target,
        host,
        state,
        spawn_depth,
      },
      alive,
    ),
  )
}

///|
pub(all) struct RegistrySnapshot {
  agents : Array[(@types.Agent, Bool)]
}

///|
/// Parse a registry snapshot JSON payload into a staging value without
/// touching any live registry. Caller commits via `apply_parsed_snapshot`
/// only after every required field has parsed cleanly.
pub fn parse_registry_snapshot_json(
  content : String,
) -> Result[RegistrySnapshot, @types.ChoirError] {
  let json = @json.parse(content) catch {
    _ => return Err(registry_parse_error("invalid JSON"))
  }
  guard json is Object(root) else {
    return Err(registry_parse_error("expected object"))
  }
  guard root.get("agents") is Some(Array(items)) else {
    return Err(registry_parse_error("missing agents array"))
  }
  let parsed : Array[(@types.Agent, Bool)] = []
  for item in items {
    guard item is Object(obj) else {
      return Err(registry_parse_error("agent entry is not an object"))
    }
    match registry_parse_agent_snapshot(obj) {
      Ok(pair) => parsed.push(pair)
      Err(e) => return Err(e)
    }
  }
  Ok({ agents: parsed })
}

///|
/// Replace the registry contents with a previously-parsed snapshot. The
/// caller is responsible for parse+validation; this is the commit step. The
/// old behavior of `restore_snapshot_json` (parse + apply in one call) is
/// preserved as a thin wrapper.
pub fn AgentRegistry::apply_parsed_snapshot(
  self : AgentRegistry,
  snapshot : RegistrySnapshot,
) -> Result[Unit, @types.ChoirError] {
  self.clear()
  for pair in snapshot.agents {
    let (agent, alive) = pair
    let id = agent.agent_id.to_string()
    self.agents.set(id, agent)
    self.alive.set(id, alive)
  }
  Ok(())
}

///|
pub fn AgentRegistry::restore_snapshot_json(
  self : AgentRegistry,
  content : String,
) -> Result[Unit, @types.ChoirError] {
  match parse_registry_snapshot_json(content) {
    Ok(snapshot) => self.apply_parsed_snapshot(snapshot)
    Err(e) => Err(e)
  }
}

///|
pub fn AgentRegistry::write_snapshot_file(
  self : AgentRegistry,
  project_dir : String,
  write_file? : (String, String) -> Bool = @sys.write_file_atomic,
) -> Result[Unit, @types.ChoirError] {
  ignore(@sys.create_dir_all(project_dir + "/.choir"))
  let path = registry_snapshot_path(project_dir)
  if write_file(path, self.to_snapshot_string()) {
    Ok(())
  } else {
    Err(
      @types.ChoirError::workspace_error(
        "failed to write registry snapshot: " + path,
      ),
    )
  }
}

///|
pub fn read_registry_snapshot_file(
  project_dir : String,
  read_file? : (String) -> String = @sys.read_file,
) -> Result[AgentRegistry, @types.ChoirError] {
  let path = registry_snapshot_path(project_dir)
  let content = read_file(path)
  if content == "" {
    return Err(
      @types.ChoirError::workspace_error("missing registry snapshot: " + path),
    )
  }
  let registry = AgentRegistry::new()
  match registry.restore_snapshot_json(content) {
    Ok(_) => Ok(registry)
    Err(e) => Err(e)
  }
}
