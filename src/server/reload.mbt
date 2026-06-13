///|
pub fn server_reload_runtime_snapshot_path(project_dir : String) -> String {
  project_dir + "/.choir/server_reload_state.json"
}

///|
/// Typed status returned in the `server_reload` response. Fixed domain —
/// per CLAUDE.md (use enums, not strings, for fixed domains). `ReloadScheduled`
/// is the only success-path value; the response field is named `status` for
/// caller ergonomics and serialized via `to_wire_string`.
pub(all) enum ServerReloadStatus {
  ReloadScheduled
} derive(Debug, Eq)

///|
pub fn ServerReloadStatus::to_wire_string(self : ServerReloadStatus) -> String {
  match self {
    ReloadScheduled => "reload_scheduled"
  }
}

///|
fn server_reload_null_json() -> Json {
  @json.parse("null") catch {
    _ => "".to_json()
  }
}

///|
fn server_reload_optional_string_json(value : String?) -> Json {
  match value {
    Some(v) => v.to_json()
    None => server_reload_null_json()
  }
}

///|
fn[V : ToJson] map_to_json_entries(values : Map[String, V]) -> Json {
  let entries : Array[Json] = []
  for key, value in values {
    entries.push({ "key": key.to_json(), "value": value.to_json() }.to_json())
  }
  entries.to_json()
}

///|
fn server_reload_int64_entries_json(values : Map[String, Int64]) -> Json {
  map_to_json_entries(values)
}

///|
fn server_reload_bool_entries_json(values : Map[String, Bool]) -> Json {
  map_to_json_entries(values)
}

///|
fn server_reload_int_entries_json(values : Map[String, Int]) -> Json {
  map_to_json_entries(values)
}

///|
fn server_reload_leaf_tdd_phase_entries_json(
  values : Map[String, @types.LeafTddPhase],
) -> Json {
  map_to_json_entries(values)
}

///|
fn server_reload_task_contract_entries_json(
  values : Map[String, @types.TaskContract],
) -> Json {
  map_to_json_entries(values)
}

///|
fn ServerState::reload_runtime_snapshot_json(
  self : ServerState,
  binary_path : String?,
) -> Json {
  {
    "version": (2).to_json(),
    "run_id": self.run_id.to_json(),
    "binary_path": server_reload_optional_string_json(binary_path),
    "pending_disconnects": server_reload_int64_entries_json(
      self.pending_disconnects,
    ),
    "delivery_failures": server_reload_int_entries_json(self.delivery_failures),
    "handoff_delivered": server_reload_bool_entries_json(self.handoff_delivered),
    "worker_no_handoff_stalled_emitted": server_reload_bool_entries_json(
      self.worker_no_handoff_stalled_emitted,
    ),
    "worker_no_handoff_exit_emitted": server_reload_bool_entries_json(
      self.worker_no_handoff_exit_emitted,
    ),
    "spawn_registration_first_unseen": server_reload_int64_entries_json(
      self.spawn_registration_first_unseen,
    ),
    "idle_agent_warned_at_70": server_reload_bool_entries_json(
      self.idle_agent_warned_at_70,
    ),
    "leaf_tdd_phases": server_reload_leaf_tdd_phase_entries_json(
      self.leaf_tdd_phases,
    ),
    "agent_task_contracts": server_reload_task_contract_entries_json(
      self.agent_task_contracts,
    ),
    "mutex_registry": self.mutex_registry.to_snapshot_json(),
  }.to_json()
}

///|
fn ServerState::reload_runtime_snapshot_string(
  self : ServerState,
  binary_path : String?,
) -> String {
  self.reload_runtime_snapshot_json(binary_path).stringify(indent=2)
}

///|
pub fn ServerState::persist_reload_snapshot(
  self : ServerState,
  binary_path : String,
) -> Result[Unit, @types.ChoirError] {
  // Route all three writes through the injected write_file_atomic so the
  // orchestration path is hermetic (testable with a mock writer, and the
  // effect-architecture rule for src/server holds end-to-end).
  match
    self.registry.write_snapshot_file(
      self.config.project_dir,
      write_file=self.write_file_atomic,
    ) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  if !self.poller.write_state_file(
      self.config.project_dir,
      write_file=self.write_file_atomic,
    ) {
    return Err(
      @types.ChoirError::workspace_error(
        "failed to write poller state before reload",
      ),
    )
  }
  let path = server_reload_runtime_snapshot_path(self.config.project_dir)
  if (self.write_file_atomic)(
      path,
      self.reload_runtime_snapshot_string(Some(binary_path)),
    ) {
    Ok(())
  } else {
    Err(
      @types.ChoirError::workspace_error(
        "failed to write server reload snapshot: " + path,
      ),
    )
  }
}

///|
fn server_reload_parse_error(message : String) -> @types.ChoirError {
  @types.ChoirError::validation_error(
    "server reload snapshot parse error: " + message,
  )
}

///|
fn server_reload_string_field(
  obj : Map[String, Json],
  key : String,
) -> Result[String, @types.ChoirError] {
  match obj.get(key) {
    Some(String(value)) => Ok(value)
    _ => Err(server_reload_parse_error("missing string field: " + key))
  }
}

///|
fn server_reload_int64_field(
  obj : Map[String, Json],
  key : String,
) -> Result[Int64, @types.ChoirError] {
  match @types.json_field_int64(obj, key) {
    Some(value) => Ok(value)
    None => Err(server_reload_parse_error("missing numeric field: " + key))
  }
}

///|
fn server_reload_int_field(
  obj : Map[String, Json],
  key : String,
) -> Result[Int, @types.ChoirError] {
  match obj.get(key) {
    Some(Number(value, ..)) => Ok(value.to_int())
    _ => Err(server_reload_parse_error("missing numeric field: " + key))
  }
}

///|
fn server_reload_bool_field(
  obj : Map[String, Json],
  key : String,
) -> Result[Bool, @types.ChoirError] {
  match obj.get(key) {
    Some(True) => Ok(true)
    Some(False) => Ok(false)
    _ => Err(server_reload_parse_error("missing boolean field: " + key))
  }
}

///|
fn server_reload_parse_int64_map(
  json : Json?,
) -> Result[Map[String, Int64], @types.ChoirError] {
  guard json is Some(Array(items)) else {
    return Err(server_reload_parse_error("missing int64 map array"))
  }
  let out : Map[String, Int64] = {}
  for item in items {
    guard item is Object(obj) else {
      return Err(server_reload_parse_error("int64 map entry is not an object"))
    }
    let key = match server_reload_string_field(obj, "key") {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    let value = match server_reload_int64_field(obj, "value") {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    out.set(key, value)
  }
  Ok(out)
}

///|
fn server_reload_parse_int64_map_or_empty(
  json : Json?,
) -> Result[Map[String, Int64], @types.ChoirError] {
  match json {
    None => Ok({})
    Some(_) => server_reload_parse_int64_map(json)
  }
}

///|
fn server_reload_parse_bool_map(
  json : Json?,
) -> Result[Map[String, Bool], @types.ChoirError] {
  guard json is Some(Array(items)) else {
    return Err(server_reload_parse_error("missing bool map array"))
  }
  let out : Map[String, Bool] = {}
  for item in items {
    guard item is Object(obj) else {
      return Err(server_reload_parse_error("bool map entry is not an object"))
    }
    let key = match server_reload_string_field(obj, "key") {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    let value = match server_reload_bool_field(obj, "value") {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    out.set(key, value)
  }
  Ok(out)
}

///|
fn server_reload_parse_bool_map_or_empty(
  json : Json?,
) -> Result[Map[String, Bool], @types.ChoirError] {
  match json {
    None => Ok({})
    Some(_) => server_reload_parse_bool_map(json)
  }
}

///|
fn server_reload_parse_int_map(
  json : Json?,
) -> Result[Map[String, Int], @types.ChoirError] {
  guard json is Some(Array(items)) else {
    return Err(server_reload_parse_error("missing int map array"))
  }
  let out : Map[String, Int] = {}
  for item in items {
    guard item is Object(obj) else {
      return Err(server_reload_parse_error("int map entry is not an object"))
    }
    let key = match server_reload_string_field(obj, "key") {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    let value = match server_reload_int_field(obj, "value") {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    out.set(key, value)
  }
  Ok(out)
}

///|
fn server_reload_parse_leaf_tdd_phase_map(
  json : Json?,
) -> Result[Map[String, @types.LeafTddPhase], @types.ChoirError] {
  guard json is Some(Array(items)) else {
    return Err(server_reload_parse_error("missing leaf_tdd_phases map array"))
  }
  let out : Map[String, @types.LeafTddPhase] = {}
  for item in items {
    guard item is Object(obj) else {
      return Err(
        server_reload_parse_error("leaf_tdd_phases map entry is not an object"),
      )
    }
    let key = match server_reload_string_field(obj, "key") {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    let raw = match server_reload_string_field(obj, "value") {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    let value = match @types.LeafTddPhase::try_parse_wire(raw) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    out.set(key, value)
  }
  Ok(out)
}

///|
fn server_reload_parse_leaf_tdd_phase_map_or_empty(
  json : Json?,
) -> Result[Map[String, @types.LeafTddPhase], @types.ChoirError] {
  match json {
    None => Ok({})
    Some(_) => server_reload_parse_leaf_tdd_phase_map(json)
  }
}

///|
fn server_reload_parse_task_contract_map(
  json : Json?,
) -> Result[Map[String, @types.TaskContract], @types.ChoirError] {
  guard json is Some(Array(items)) else {
    return Err(server_reload_parse_error("missing task contract map array"))
  }
  let out : Map[String, @types.TaskContract] = {}
  for item in items {
    guard item is Object(obj) else {
      return Err(
        server_reload_parse_error("task contract map entry is not an object"),
      )
    }
    let key = match server_reload_string_field(obj, "key") {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    let raw = match obj.get("value") {
      Some(value) => value
      None =>
        return Err(server_reload_parse_error("missing task contract value"))
    }
    let value : @types.TaskContract = @json.from_json(raw) catch {
      _ => return Err(server_reload_parse_error("invalid task contract value"))
    }
    out.set(key, value)
  }
  Ok(out)
}

///|
/// Replace every entry in `target` with the entries from `source`. Drops any
/// pre-existing keys not in `source`. Used to atomically commit a parsed
/// snapshot into the live in-memory map.
fn[V] server_reload_replace_map_contents(
  target : Map[String, V],
  source : Map[String, V],
) -> Unit {
  let existing_keys : Array[String] = []
  for k, _ in target {
    existing_keys.push(k)
  }
  for k in existing_keys {
    target.remove(k)
  }
  for k, v in source {
    target.set(k, v)
  }
}

///|
pub fn ServerState::restore_reload_snapshot(
  self : ServerState,
) -> Result[Unit, @types.ChoirError] {
  // Phase 1: load and parse everything into staging values. No live state
  // mutates until every field parses cleanly. A corrupt or partial snapshot
  // returns an error and leaves the server's in-memory state untouched,
  // rather than half-restored.
  let registry_content = (self.read_file)(
    @registry.registry_snapshot_path(self.config.project_dir),
  )
  if registry_content == "" {
    return Err(
      @types.ChoirError::workspace_error("missing registry snapshot for reload"),
    )
  }
  let registry_snapshot = match
    @registry.parse_registry_snapshot_json(registry_content) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let content = (self.read_file)(
    server_reload_runtime_snapshot_path(self.config.project_dir),
  )
  if content == "" {
    return Err(
      @types.ChoirError::workspace_error("missing server reload snapshot"),
    )
  }
  let json = @json.parse(content) catch {
    _ => return Err(server_reload_parse_error("invalid JSON"))
  }
  guard json is Object(root) else {
    return Err(server_reload_parse_error("expected object"))
  }
  let version = match server_reload_int_field(root, "version") {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  if version != 2 {
    return Err(
      server_reload_parse_error(
        "unsupported snapshot version " +
        version.to_string() +
        "; authoritative agent_task_contracts are required",
      ),
    )
  }
  let parsed_pending = match
    server_reload_parse_int64_map(root.get("pending_disconnects")) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let parsed_failures = match
    server_reload_parse_int_map(root.get("delivery_failures")) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let parsed_handoff_delivered = match
    server_reload_parse_bool_map_or_empty(root.get("handoff_delivered")) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let parsed_worker_no_handoff_stalled_emitted = match
    server_reload_parse_bool_map_or_empty(
      root.get("worker_no_handoff_stalled_emitted"),
    ) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let parsed_worker_no_handoff_exit_emitted = match
    server_reload_parse_bool_map_or_empty(
      root.get("worker_no_handoff_exit_emitted"),
    ) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let parsed_spawn_registration_first_unseen = match
    server_reload_parse_int64_map_or_empty(
      root.get("spawn_registration_first_unseen"),
    ) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let parsed_idle_agent_warned_at_70 = match
    server_reload_parse_bool_map_or_empty(root.get("idle_agent_warned_at_70")) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let parsed_leaf_tdd_phases = match
    server_reload_parse_leaf_tdd_phase_map_or_empty(root.get("leaf_tdd_phases")) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let parsed_agent_task_contracts = match
    server_reload_parse_task_contract_map(root.get("agent_task_contracts")) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let parsed_mutex = match root.get("mutex_registry") {
    Some(j) =>
      match @registry.parse_mutex_registry_snapshot_json(j) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
    None => return Err(server_reload_parse_error("missing mutex_registry"))
  }
  // Phase 2: commit. Every parse succeeded; now bulk-apply.
  match self.registry.apply_parsed_snapshot(registry_snapshot) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  server_reload_replace_map_contents(self.pending_disconnects, parsed_pending)
  server_reload_replace_map_contents(self.delivery_failures, parsed_failures)
  server_reload_replace_map_contents(
    self.handoff_delivered,
    parsed_handoff_delivered,
  )
  server_reload_replace_map_contents(
    self.worker_no_handoff_stalled_emitted,
    parsed_worker_no_handoff_stalled_emitted,
  )
  server_reload_replace_map_contents(
    self.worker_no_handoff_exit_emitted,
    parsed_worker_no_handoff_exit_emitted,
  )
  server_reload_replace_map_contents(
    self.spawn_registration_first_unseen,
    parsed_spawn_registration_first_unseen,
  )
  server_reload_replace_map_contents(
    self.idle_agent_warned_at_70,
    parsed_idle_agent_warned_at_70,
  )
  server_reload_replace_map_contents(
    self.leaf_tdd_phases,
    parsed_leaf_tdd_phases,
  )
  server_reload_replace_map_contents(
    self.agent_task_contracts,
    parsed_agent_task_contracts,
  )
  // Release any mutex whose holder isn't in the just-restored registry —
  // otherwise a stale lock would block unrelated callers until TTL.
  let registry = self.registry
  self.mutex_registry.apply_parsed_snapshot(parsed_mutex, is_known_agent=fn(
    id,
  ) {
    try {
      ignore(registry.get(id))
      true
    } catch {
      _ => false
    }
  })
  Ok(())
}

///|
pub fn ServerState::handle_server_reload_request(
  self : ServerState,
  req : @types.Request,
) -> @types.Response {
  if req.req_method != "tools/call" || req.name != "server_reload" {
    return @types.Response::Err("not a server_reload request")
  }
  ignore(self.tool_registry.lookup(req.role, req.name)) catch {
    e => return @tools.tool_response_err_from_caught(e)
  }
  let binary_path = match req.args.get("binary_path") {
    Some(path) => path
    None =>
      match @exec.reload_binary_path() {
        Ok(path) => path
        Err(e) => return @types.Response::Err(e.message())
      }
  }
  match @exec.validate_replace_self_binary(binary_path) {
    Ok(_) => ()
    Err(e) => return @types.Response::Err(e.message())
  }
  // Snapshots have been persisted and the binary has been validated as
  // executable. The actual `execve` happens AFTER this response is written
  // (the runtime loop reads the post-response signal). Exec can still fail
  // — `clear_cloexec` on the listener fd, or `execve` itself returning. On
  // that failure the original server keeps running with the snapshots it
  // just wrote; callers that depended on the reload landing will need to
  // observe via a follow-up probe (e.g. `wave_state` against the new
  // version's build identity). Reflect this honestly in the status so a
  // success response is not read as "the new binary is now running".
  match self.persist_reload_snapshot(binary_path) {
    Ok(_) =>
      @types.Response::ok_values({
        "status": ServerReloadStatus::ReloadScheduled.to_wire_string().to_json(),
        "binary_path": binary_path.to_json(),
        // Short, client-renderable tokens instead of a long English `note`
        // — some MCP clients truncate long string values in tool responses,
        // which would hide the "exec may fail" disclaimer (the exact thing
        // the field was for). The prose explanation lives in the tool docs
        // and the comment above, not the payload.
        "warnings": [
          "exec_happens_after_this_response", "exec_failure_keeps_original_server_running",
          "in_flight_tool_calls_may_be_dropped_retry_after_reload", "verify_reload_landed_via_followup_probe",
        ].to_json(),
      })
    Err(e) => @types.Response::Err(e.message())
  }
}
