///|
fn client_response_json(resp : @types.Response) -> String {
  @transport.format_response(resp) + "\n"
}

///|
fn client_emit(resp : @types.Response) -> Unit {
  @sys.write_stdout(client_response_json(resp))
  @sys.exit(if resp.is_ok() { 0 } else { 1 })
}

///|
fn local_cfg_has_registration_identity(local_cfg : @types.LocalConfig) -> Bool {
  local_cfg.role is Some(_) ||
  local_cfg.agent_id is Some(_) ||
  local_cfg.parent_id is Some(_) ||
  local_cfg.branch is Some(_) ||
  local_cfg.parent_branch is Some(_) ||
  local_cfg.workspace is Some(_) ||
  local_cfg.terminal_target is Some(_) ||
  local_cfg.agent_type is Some(_) ||
  local_cfg.spawn_depth is Some(_)
}

///|
fn config_with_local_listen_uds(
  config : @types.Config,
  local_cfg : @types.LocalConfig,
) -> @types.Config {
  match local_cfg.listen_uds {
    Some(listen_uds) => { ..config, listen_uds, }
    None => config
  }
}

///|
fn client_should_register(local_cfg : @types.LocalConfig) -> Bool {
  local_cfg_has_registration_identity(local_cfg)
}

///|
fn local_cfg_env_value(getenv : (String) -> String?, key : String) -> String? {
  match getenv(key) {
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
fn local_cfg_from_env_lookup(
  getenv : (String) -> String?,
) -> @types.LocalConfig {
  let role = match local_cfg_env_value(getenv, "CHOIR_ROLE") {
    Some(raw) =>
      match @config.parse_role(raw) {
        Ok(value) => Some(value)
        Err(_) => None
      }
    None => None
  }
  let terminal_target = match
    local_cfg_env_value(getenv, "CHOIR_TERMINAL_TARGET") {
    Some(raw) => @types.LocalTarget::parse(raw)
    None => None
  }
  let agent_type = match local_cfg_env_value(getenv, "CHOIR_AGENT_TYPE") {
    Some(raw) =>
      match @config.parse_agent_type(raw) {
        Ok(value) => Some(value)
        Err(_) => None
      }
    None => None
  }
  {
    ..@types.LocalConfig::default(),
    role,
    listen_uds: local_cfg_env_value(getenv, "CHOIR_LISTEN_UDS"),
    agent_id: local_cfg_env_value(getenv, "CHOIR_AGENT_ID"),
    parent_id: local_cfg_env_value(getenv, "CHOIR_PARENT_ID"),
    branch: local_cfg_env_value(getenv, "CHOIR_BRANCH"),
    parent_branch: local_cfg_env_value(getenv, "CHOIR_PARENT_BRANCH"),
    workspace: local_cfg_env_value(getenv, "CHOIR_WORKSPACE"),
    terminal_target,
    agent_type,
  }
}

///|
fn goal_client_load_config_with(
  env_get? : (String) -> String? = fn(key) { @sys.getenv(key) },
  path_exists? : (String) -> Bool = fn(path) { @sys.path_exists(path) },
  read_file? : (String) -> String = fn(path) { @sys.read_file(path) },
) -> Result[(@types.Role, @types.Config, @types.LocalConfig), String] {
  let config_content = read_file(".choir/config.toml")
  if config_content == "" {
    return Err("missing .choir/config.toml")
  }
  let local_content = if path_exists(".choir/config.local.toml") {
    read_file(".choir/config.local.toml")
  } else {
    ""
  }
  let base_config = match
    @config.parse_config(config_content, local_content=Some(local_content)) {
    Ok(config) => config
    Err(error) => return Err(error.message())
  }
  let parsed_local = @config.parse_local_config(local_content).unwrap_or(
    @types.LocalConfig::default(),
  )
  let local_cfg = if local_cfg_has_registration_identity(parsed_local) {
    parsed_local
  } else {
    local_cfg_from_env_lookup(env_get)
  }
  let config = config_with_local_listen_uds(base_config, local_cfg)
  let config = if local_cfg_has_registration_identity(local_cfg) ||
    config.agent_id is Some(_) {
    config
  } else {
    { ..config, agent_id: Some("root") }
  }
  Ok((@config.resolve_role(local_cfg.role, config), config, local_cfg))
}

///|
fn goal_client_load_config() -> Result[
  (@types.Role, @types.Config, @types.LocalConfig),
  String,
] {
  goal_client_load_config_with()
}

///|
fn client_register_if_needed(
  uds_fd : Int,
  reader : UDSLineReader,
  _role : @types.Role,
  _config : @types.Config,
  _local_cfg : @types.LocalConfig,
) -> Result[Unit, String] {
  let token = match @sys.getenv("CHOIR_AGENT_TOKEN") {
    Some(value) => value
    None => return Err("missing Conductor capability")
  }
  let message = @transport.format_conductor_registration_request(token) + "\n"
  if !mcp_write_all_uds(uds_fd, @utf8.encode(message)) {
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
fn client_call_uds(
  role : @types.Role,
  config : @types.Config,
  local_cfg : @types.LocalConfig,
  request : @types.Request,
  register_if_needed? : Bool = true,
) -> Result[@types.Response, String] {
  let mut uds_fd = @uds.client_connect(config.listen_uds)
  if uds_fd < 0 && @sys.wait_for_socket(config.listen_uds, 60) {
    uds_fd = @uds.client_connect(config.listen_uds)
  }
  if uds_fd < 0 {
    return Err("cannot connect to server at " + config.listen_uds)
  }
  let reader = UDSLineReader::new(uds_fd)
  if register_if_needed {
    match client_register_if_needed(uds_fd, reader, role, config, local_cfg) {
      Ok(_) => ()
      Err(error) => {
        @uds.close(uds_fd)
        return Err(error)
      }
    }
  }
  let wire = mcp_build_wire_request(request)
  if !mcp_write_all_uds(uds_fd, @utf8.encode(wire)) {
    @uds.close(uds_fd)
    return Err("failed to write Goal request")
  }
  let line = reader.read_line()
  @uds.close(uds_fd)
  if line == "" {
    return Err("server connection closed")
  }
  @transport.parse_response(line).map_err(fn(error) {
    "failed to parse response: " + error
  })
}

///|
test "Goal client resolves an environment Conductor identity" {
  let loaded = goal_client_load_config_with(
    env_get=fn(key) {
      match key {
        "CHOIR_AGENT_ID" => Some("root")
        "CHOIR_ROLE" => Some("root")
        "CHOIR_LISTEN_UDS" => Some("/tmp/conductor.sock")
        _ => None
      }
    },
    path_exists=fn(_) { false },
    read_file=fn(path) {
      if path == ".choir/config.toml" {
        "project_dir = \"/repo\"\nlisten_uds = \"/tmp/default.sock\"\n"
      } else {
        ""
      }
    },
  ).unwrap()
  assert_eq(loaded.0, @types.Role::TL)
  assert_eq(loaded.1.listen_uds, "/tmp/conductor.sock")
  @debug.assert_eq(loaded.2.agent_id, Some("root"))
}

///|
test "Goal client response preserves the Choir envelope" {
  assert_eq(
    client_response_json(@types.Response::Err("boom")),
    "{\"ok\":false,\"error\":\"boom\"}\n",
  )
}
