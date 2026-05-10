///|
pub fn server_reload_runtime_snapshot_path(project_dir : String) -> String {
  project_dir + "/.choir/server_reload_state.json"
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
fn server_reload_int64_entries_json(values : Map[String, Int64]) -> Json {
  let entries : Array[Json] = []
  for key, value in values {
    entries.push({ "key": key.to_json(), "value": value.to_json() }.to_json())
  }
  entries.to_json()
}

///|
fn server_reload_bool_entries_json(values : Map[String, Bool]) -> Json {
  let entries : Array[Json] = []
  for key, value in values {
    entries.push({ "key": key.to_json(), "value": value.to_json() }.to_json())
  }
  entries.to_json()
}

///|
fn server_reload_int_entries_json(values : Map[String, Int]) -> Json {
  let entries : Array[Json] = []
  for key, value in values {
    entries.push({ "key": key.to_json(), "value": value.to_json() }.to_json())
  }
  entries.to_json()
}

///|
fn ServerState::reload_runtime_snapshot_json(
  self : ServerState,
  binary_path : String?,
) -> Json {
  {
    "version": (1).to_json(),
    "run_id": self.run_id.to_json(),
    "binary_path": server_reload_optional_string_json(binary_path),
    "pending_disconnects": server_reload_int64_entries_json(
      self.pending_disconnects,
    ),
    "pending_disconnect_soft_notified": server_reload_bool_entries_json(
      self.pending_disconnect_soft_notified,
    ),
    "delivery_failures": server_reload_int_entries_json(self.delivery_failures),
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
  match self.registry.write_snapshot_file(self.config.project_dir) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  if !self.poller.write_state_file(self.config.project_dir) {
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
fn server_reload_restore_int64_map(
  target : Map[String, Int64],
  json : Json?,
) -> Result[Unit, @types.ChoirError] {
  guard json is Some(Array(items)) else {
    return Err(server_reload_parse_error("missing int64 map array"))
  }
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
    target.set(key, value)
  }
  Ok(())
}

///|
fn server_reload_restore_bool_map(
  target : Map[String, Bool],
  json : Json?,
) -> Result[Unit, @types.ChoirError] {
  guard json is Some(Array(items)) else {
    return Err(server_reload_parse_error("missing bool map array"))
  }
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
    target.set(key, value)
  }
  Ok(())
}

///|
fn server_reload_restore_int_map(
  target : Map[String, Int],
  json : Json?,
) -> Result[Unit, @types.ChoirError] {
  guard json is Some(Array(items)) else {
    return Err(server_reload_parse_error("missing int map array"))
  }
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
    target.set(key, value)
  }
  Ok(())
}

///|
pub fn ServerState::restore_reload_snapshot(
  self : ServerState,
) -> Result[Unit, @types.ChoirError] {
  let registry_content = (self.read_file)(
    @registry.registry_snapshot_path(self.config.project_dir),
  )
  if registry_content == "" {
    return Err(
      @types.ChoirError::workspace_error("missing registry snapshot for reload"),
    )
  }
  match self.registry.restore_snapshot_json(registry_content) {
    Ok(_) => ()
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
  match
    server_reload_restore_int64_map(
      self.pending_disconnects,
      root.get("pending_disconnects"),
    ) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  match
    server_reload_restore_bool_map(
      self.pending_disconnect_soft_notified,
      root.get("pending_disconnect_soft_notified"),
    ) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  match
    server_reload_restore_int_map(
      self.delivery_failures,
      root.get("delivery_failures"),
    ) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  match root.get("mutex_registry") {
    Some(json) =>
      match self.mutex_registry.restore_snapshot_json(json) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
    None => return Err(server_reload_parse_error("missing mutex_registry"))
  }
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
  let binary_path = req.args
    .get("binary_path")
    .unwrap_or(@exec.reload_binary_path(self.config.project_dir))
  match @exec.validate_replace_self_binary(binary_path) {
    Ok(_) => ()
    Err(e) => return @types.Response::Err(e.message())
  }
  match self.persist_reload_snapshot(binary_path) {
    Ok(_) =>
      @types.Response::ok_values({
        "status": "reloading".to_json(),
        "binary_path": binary_path.to_json(),
        "in_flight_requests": "active tool calls during exec may be dropped; retry after reload".to_json(),
      })
    Err(e) => @types.Response::Err(e.message())
  }
}
