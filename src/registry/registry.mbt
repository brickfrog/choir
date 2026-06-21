///|
/// Authoritative credential minted by the server when it spawns an agent.
pub(all) struct AgentCredential {
  role : @types.Role
  token : String
} derive(Debug, Eq)

///|
/// In-memory agent registry.
pub(all) struct AgentRegistry {
  agents : Map[String, @types.Agent]
  alive : Map[String, Bool]
  spawn_credentials : Map[String, AgentCredential]
}

///|
/// Create a new empty registry.
pub fn AgentRegistry::new() -> AgentRegistry {
  { agents: {}, alive: {}, spawn_credentials: {} }
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
  existed
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
pub fn AgentRegistry::record_spawn_credential(
  self : AgentRegistry,
  agent_id : String,
  credential : AgentCredential,
) -> Unit {
  self.spawn_credentials.set(agent_id, credential)
}

///|
pub fn AgentRegistry::remove_spawn_credential(
  self : AgentRegistry,
  agent_id : String,
) -> Unit {
  self.spawn_credentials.remove(agent_id)
}

///|
pub fn AgentRegistry::credential_for_agent(
  self : AgentRegistry,
  agent_id : String,
) -> AgentCredential? {
  self.spawn_credentials.get(agent_id)
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
      self.spawn_credentials.remove(agent_id)
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
  }
  self.spawn_credentials.clear()
}

///|
pub fn registry_snapshot_path(project_dir : String) -> String {
  project_dir + "/.choir/state/registry_snapshot.json"
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
let registry_reload_credentials_version : Int = 1

///|
let registry_reload_credentials_root_agent_id : String = "root"

///|
pub(all) struct RegistryReloadCredentialEntry {
  agent_id : String
  credential : AgentCredential
} derive(Debug, Eq)

///|
pub(all) struct RegistryReloadCredentials {
  entries : Array[RegistryReloadCredentialEntry]
} derive(Debug, Eq)

///|
fn registry_reload_credential_entry_json(
  agent_id : String,
  credential : AgentCredential,
) -> Json {
  {
    "agent_id": agent_id.to_json(),
    "role": credential.role.to_wire_string().to_json(),
    "token": credential.token.to_json(),
  }.to_json()
}

///|
pub fn AgentRegistry::to_reload_credentials_env_json(
  self : AgentRegistry,
) -> Json {
  let credentials : Array[Json] = []
  for agent_id, credential in self.spawn_credentials {
    if agent_id != registry_reload_credentials_root_agent_id &&
      agent_id != "" &&
      credential.token != "" {
      credentials.push(
        registry_reload_credential_entry_json(agent_id, credential),
      )
    }
  }
  {
    "version": registry_reload_credentials_version.to_json(),
    "credentials": credentials.to_json(),
  }.to_json()
}

///|
pub fn AgentRegistry::to_reload_credentials_env_string(
  self : AgentRegistry,
) -> String {
  self.to_reload_credentials_env_json().stringify()
}

///|
fn registry_reload_credentials_parse_error(
  message : String,
) -> @types.ChoirError {
  @types.ChoirError::validation_error(
    "registry reload credentials parse error: " + message,
  )
}

///|
fn registry_reload_credentials_string_field(
  obj : Map[String, Json],
  key : String,
) -> Result[String, @types.ChoirError] {
  match obj.get(key) {
    Some(String(value)) => Ok(value)
    _ =>
      Err(
        registry_reload_credentials_parse_error("missing string field: " + key),
      )
  }
}

///|
fn registry_reload_credentials_int_field(
  obj : Map[String, Json],
  key : String,
) -> Result[Int, @types.ChoirError] {
  match obj.get(key) {
    Some(Number(value, ..)) => Ok(value.to_int())
    _ =>
      Err(
        registry_reload_credentials_parse_error("missing numeric field: " + key),
      )
  }
}

///|
pub fn parse_reload_credentials_env_string(
  content : String,
) -> Result[RegistryReloadCredentials, @types.ChoirError] {
  if content.trim() == "" {
    return Err(registry_reload_credentials_parse_error("empty payload"))
  }
  let json = @json.parse(content) catch {
    _ => return Err(registry_reload_credentials_parse_error("invalid JSON"))
  }
  guard json is Object(root) else {
    return Err(registry_reload_credentials_parse_error("expected object"))
  }
  let version = match registry_reload_credentials_int_field(root, "version") {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  if version != registry_reload_credentials_version {
    return Err(
      registry_reload_credentials_parse_error(
        "unsupported version " + version.to_string(),
      ),
    )
  }
  guard root.get("credentials") is Some(Array(items)) else {
    return Err(
      registry_reload_credentials_parse_error("missing credentials array"),
    )
  }
  let entries : Array[RegistryReloadCredentialEntry] = []
  let seen : Map[String, Bool] = {}
  for item in items {
    guard item is Object(obj) else {
      return Err(
        registry_reload_credentials_parse_error(
          "credential entry is not an object",
        ),
      )
    }
    let agent_id = match
      registry_reload_credentials_string_field(obj, "agent_id") {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    if agent_id == "" {
      return Err(
        registry_reload_credentials_parse_error("empty credential agent_id"),
      )
    }
    if agent_id == registry_reload_credentials_root_agent_id {
      return Err(
        registry_reload_credentials_parse_error(
          "root credential is not restored from reload env",
        ),
      )
    }
    if seen.contains(agent_id) {
      return Err(
        registry_reload_credentials_parse_error("duplicate credential agent_id"),
      )
    }
    let role_raw = match registry_reload_credentials_string_field(obj, "role") {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    let role = match @types.Role::try_parse_wire(role_raw) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    let token = match registry_reload_credentials_string_field(obj, "token") {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    if token == "" {
      return Err(
        registry_reload_credentials_parse_error("empty credential token"),
      )
    }
    seen.set(agent_id, true)
    entries.push({ agent_id, credential: { role, token } })
  }
  Ok({ entries, })
}

///|
pub fn AgentRegistry::restore_reload_credentials_env_string(
  self : AgentRegistry,
  content : String,
) -> Result[Int, @types.ChoirError] {
  let parsed = match parse_reload_credentials_env_string(content) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  for entry in parsed.entries {
    self.record_spawn_credential(entry.agent_id, entry.credential)
  }
  Ok(parsed.entries.length())
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

///|
test "agent registry records authoritative spawn credentials" {
  let reg = AgentRegistry::new()
  reg.record_spawn_credential("main.leaf-a", AgentCredential::{
    role: @types.Role::Dev,
    token: "token-a",
  })
  match reg.credential_for_agent("main.leaf-a") {
    Some(credential) => {
      assert_eq(credential.role, @types.Role::Dev)
      assert_eq(credential.token, "token-a")
    }
    None => fail("expected recorded credential")
  }
  @debug.assert_eq(reg.credential_for_agent("main.unknown"), None)
  assert_true(reg.spawn_credentials.contains("main.leaf-a"))
  reg.remove_spawn_credential("main.leaf-a")
  @debug.assert_eq(reg.credential_for_agent("main.leaf-a"), None)
}

///|
test "agent registry reload credentials round trip without disk snapshot tokens" {
  let source = AgentRegistry::new()
  source.record_spawn_credential("root", AgentCredential::{
    role: @types.Role::TL,
    token: "root-token-unchanged",
  })
  source.record_spawn_credential("root.leaf", AgentCredential::{
    role: @types.Role::Dev,
    token: "leaf-reload-token",
  })
  source.record_spawn_credential("root.worker", AgentCredential::{
    role: @types.Role::Worker,
    token: "worker-reload-token",
  })
  let payload = source.to_reload_credentials_env_string()
  assert_true(payload.contains("leaf-reload-token"))
  assert_true(payload.contains("worker-reload-token"))
  assert_false(payload.contains("root-token-unchanged"))

  let snapshot = source.to_snapshot_string()
  assert_false(snapshot.contains("leaf-reload-token"))
  assert_false(snapshot.contains("worker-reload-token"))
  assert_false(snapshot.contains("root-token-unchanged"))

  let restored = AgentRegistry::new()
  match restored.restore_reload_credentials_env_string(payload) {
    Ok(count) => assert_eq(count, 2)
    Err(e) => fail(e.message())
  }
  match restored.credential_for_agent("root.leaf") {
    Some(credential) => {
      assert_eq(credential.role, @types.Role::Dev)
      assert_eq(credential.token, "leaf-reload-token")
    }
    None => fail("expected restored leaf credential")
  }
  match restored.credential_for_agent("root.worker") {
    Some(credential) => {
      assert_eq(credential.role, @types.Role::Worker)
      assert_eq(credential.token, "worker-reload-token")
    }
    None => fail("expected restored worker credential")
  }
  @debug.assert_eq(restored.credential_for_agent("root"), None)
}

///|
test "agent registry reload credential restore fails closed on malformed or empty tokens" {
  let empty_token_payload =
    #|{"version":1,"credentials":[{"agent_id":"root.leaf","role":"dev","token":""}]}|
  let empty_agent_payload =
    #|{"version":1,"credentials":[{"agent_id":"","role":"dev","token":"secret"}]}|
  let invalid_role_payload =
    #|{"version":1,"credentials":[{"agent_id":"root.leaf","role":"definitely-not-a-role","token":"secret"}]}|
  let malformed_payloads = [
    "", "not-json", empty_token_payload, empty_agent_payload, invalid_role_payload,
  ]
  for payload in malformed_payloads {
    let restored = AgentRegistry::new()
    match restored.restore_reload_credentials_env_string(payload) {
      Err(_) => ()
      Ok(_) => fail("expected reload credential restore to reject payload")
    }
    @debug.assert_eq(restored.credential_for_agent("root.leaf"), None)
  }
}
