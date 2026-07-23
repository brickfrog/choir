///|
fn client_response_json(response : @types.Response) -> String {
  @transport.format_response(response) + "\n"
}

///|
fn client_emit(response : @types.Response) -> Unit {
  @sys.write_stdout(client_response_json(response))
  @sys.exit(if response.is_ok() { 0 } else { 1 })
}

///|
fn client_environment_value(
  env_get : (String) -> String?,
  key : String,
) -> String? {
  match env_get(key) {
    Some(value) => {
      let trimmed = value.trim().to_owned()
      if trimmed == "" {
        None
      } else {
        Some(trimmed)
      }
    }
    None => None
  }
}

///|
fn goal_client_load_config_with(
  env_get? : (String) -> String? = fn(key) { @sys.getenv(key) },
  path_exists? : (String) -> Bool = fn(path) { @sys.path_exists(path) },
  read_file? : (String) -> String = fn(path) { @sys.read_file(path) },
) -> Result[@types.Config, String] {
  if !path_exists(".choir/config.toml") {
    return Err("missing .choir/config.toml")
  }
  let local_content = if path_exists(".choir/config.local.toml") {
    read_file(".choir/config.local.toml")
  } else {
    ""
  }
  let parsed = match
    @config.parse_config(
      read_file(".choir/config.toml"),
      local_content=Some(local_content),
    ) {
    Ok(config) => config
    Err(error) => return Err(error.message())
  }
  Ok({
    project_dir: client_environment_value(env_get, "CHOIR_WORKSPACE").unwrap_or(
      parsed.project_dir,
    ),
    listen_uds: client_environment_value(env_get, "CHOIR_LISTEN_UDS").unwrap_or(
      parsed.listen_uds,
    ),
  })
}

///|
fn goal_client_load_config() -> Result[@types.Config, String] {
  goal_client_load_config_with()
}

///|
fn client_register(
  fd : Int,
  reader : UDSLineReader,
  capability : String,
) -> Result[Unit, String] {
  let message = @transport.format_conductor_registration_request(capability) +
    "\n"
  if !mcp_write_all_uds(fd, @utf8.encode(message)) {
    return Err("failed to write registration request")
  }
  let line = reader.read_line()
  if line == "" {
    return Err("server connection closed during registration")
  }
  match @transport.parse_response(line) {
    Ok(response) =>
      if response.is_ok() {
        Ok(())
      } else {
        Err(response.error_message().unwrap_or("registration failed"))
      }
    Err(error) => Err("failed to parse registration response: " + error)
  }
}

///|
fn client_register_local_cli(
  fd : Int,
  reader : UDSLineReader,
) -> Result[Unit, String] {
  let request : @types.Request = {
    req_method: local_cli_register_method,
    name: local_cli_register_method,
    args: @types.RequestArgs::from_values(Map([])),
  }
  if !mcp_write_all_uds(fd, @utf8.encode(mcp_build_wire_request(request))) {
    return Err("failed to write local CLI registration request")
  }
  let line = reader.read_line()
  if line == "" {
    return Err("server connection closed during local CLI registration")
  }
  match @transport.parse_response(line) {
    Ok(response) =>
      if response.is_ok() {
        Ok(())
      } else {
        Err(response.error_message().unwrap_or("local CLI registration failed"))
      }
    Err(error) => Err("failed to parse local CLI registration: " + error)
  }
}

///|
fn client_call_uds(
  config : @types.Config,
  request : @types.Request,
  capability : String?,
) -> Result[@types.Response, String] {
  let mut fd = @uds.client_connect(config.listen_uds)
  if fd < 0 && @sys.wait_for_socket(config.listen_uds, 60) {
    fd = @uds.client_connect(config.listen_uds)
  }
  if fd < 0 {
    return Err("cannot connect to server at " + config.listen_uds)
  }
  let reader = UDSLineReader::new(fd)
  let registered = match capability {
    Some(value) => client_register(fd, reader, value)
    None => client_register_local_cli(fd, reader)
  }
  match registered {
    Ok(_) => ()
    Err(error) => {
      @uds.close(fd)
      return Err(error)
    }
  }
  if !mcp_write_all_uds(fd, @utf8.encode(mcp_build_wire_request(request))) {
    @uds.close(fd)
    return Err("failed to write Goal request")
  }
  let line = reader.read_line()
  @uds.close(fd)
  if line == "" {
    return Err("server connection closed")
  }
  @transport.parse_response(line).map_err(fn(error) {
    "failed to parse response: " + error
  })
}

///|
fn conductor_transcript_goal_active(transcript : String) -> Bool {
  let mut active = false
  for line in transcript.split("\n") {
    let parsed = @json.parse(line) catch { _ => continue }
    guard parsed is Object(entry) else { continue }
    guard entry.get("attachment") is Some(Object(attachment)) else { continue }
    if attachment.get("type") != Some("goal_status".to_json()) {
      continue
    }
    active = attachment.get("met") == Some(false.to_json())
  }
  active
}

///|
fn conductor_stop_goal_active(
  hook_input : String,
  read_file? : (String) -> String = fn(path) { @sys.read_file(path) },
) -> Bool {
  let parsed = @json.parse(hook_input) catch { _ => return false }
  guard parsed is Object(input) else { return false }
  guard input.get("transcript_path") is Some(String(path)) else { return false }
  conductor_transcript_goal_active(read_file(path))
}

///|
fn conductor_stop_output(park : Bool) -> String {
  if park {
    {
      "continue": false.to_json(),
      "stopReason": "Waiting for a durable Choir Goal state change.".to_json(),
    }
    .to_json()
    .stringify(indent=0) +
    "\n"
  } else {
    "{}\n"
  }
}

///|
fn conductor_stop_run() -> Unit {
  let hook_input = match @sys.read_stdin_line(262144) {
    Some(value) => value
    None => {
      @sys.write_stdout(conductor_stop_output(false))
      return
    }
  }
  if !conductor_stop_goal_active(hook_input) {
    @sys.write_stdout(conductor_stop_output(false))
    return
  }
  let config = match goal_client_load_config() {
    Ok(value) => value
    Err(_) => {
      @sys.write_stdout(conductor_stop_output(false))
      return
    }
  }
  let token = match @sys.getenv("CHOIR_CONDUCTOR_TOKEN") {
    Some(value) =>
      if value.trim() != "" {
        value
      } else {
        @sys.write_stdout(conductor_stop_output(false))
        return
      }
    None => {
      @sys.write_stdout(conductor_stop_output(false))
      return
    }
  }
  let request : @types.Request = {
    req_method: conductor_stop_decision_method,
    name: conductor_stop_decision_method,
    args: @types.RequestArgs::from_values(Map([])),
  }
  let park = match client_call_uds(config, request, Some(token)) {
    Ok(response) =>
      match response.ok_payload() {
        Some(fields) => fields.get_bool("park").unwrap_or(false)
        None => false
      }
    Err(_) => false
  }
  @sys.write_stdout(conductor_stop_output(park))
}

///|
test "Goal client uses the fixed Conductor launch environment" {
  let loaded = goal_client_load_config_with(
    env_get=fn(key) {
      match key {
        "CHOIR_WORKSPACE" => Some("/runtime/repo")
        "CHOIR_LISTEN_UDS" => Some("/runtime/choir.sock")
        _ => None
      }
    },
    path_exists=fn(path) { path == ".choir/config.toml" },
    read_file=fn(path) {
      if path == ".choir/config.toml" {
        "project_dir = \"/configured/repo\"\nlisten_uds = \"/configured.sock\"\n"
      } else {
        ""
      }
    },
  ).unwrap()
  assert_eq(loaded.project_dir, "/runtime/repo")
  assert_eq(loaded.listen_uds, "/runtime/choir.sock")
}

///|
test "Goal client reads local launch settings outside a Conductor" {
  let loaded = goal_client_load_config_with(
    env_get=fn(_) { None },
    path_exists=fn(_) { true },
    read_file=fn(path) {
      if path == ".choir/config.toml" {
        "# project configuration\n"
      } else {
        "project_dir = \"/local/repo\"\nlisten_uds = \"/local/choir.sock\"\n"
      }
    },
  ).unwrap()
  assert_eq(loaded.project_dir, "/local/repo")
  assert_eq(loaded.listen_uds, "/local/choir.sock")
}

///|
test "Goal client response preserves the Choir envelope" {
  assert_eq(
    client_response_json(@types.Response::Err("boom")),
    "{\"ok\":false,\"error\":\"boom\"}\n",
  )
}

///|
test "Conductor Stop hook recognizes only an active built-in Goal" {
  let active =
    #|{"type":"attachment","attachment":{"type":"goal_status","met":false,"sentinel":true,"condition":"part-a"}}
    #|
  assert_true(conductor_transcript_goal_active(active))
  let achieved = active +
    (
      #|{"type":"attachment","attachment":{"type":"goal_status","met":true,"condition":"part-a"}}
      #|
    )
  assert_false(conductor_transcript_goal_active(achieved))
  assert_false(conductor_transcript_goal_active("{\"type\":\"user\"}\n"))
  assert_true(
    conductor_stop_goal_active("{\"transcript_path\":\"/session.jsonl\"}", read_file=fn(
      _,
    ) {
      active
    }),
  )
}

///|
test "Conductor Stop hook parks without asking the model to poll" {
  assert_eq(
    conductor_stop_output(true),
    "{\"continue\":false,\"stopReason\":\"Waiting for a durable Choir Goal state change.\"}\n",
  )
  assert_eq(conductor_stop_output(false), "{}\n")
}
