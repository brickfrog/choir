///|
priv struct ClientCliArgs {
  flags : Map[String, String]
  positionals : Array[String]
}

///|
priv struct ClientLocalConfigResolution {
  local_cfg : @types.LocalConfig
  identity_source : @tools.ShutdownIdentitySource?
}

///|
fn normalize_cli_key(key : String) -> String {
  let buf = StringBuilder::new()
  for c in key {
    if c == '-' {
      buf.write_char('_')
    } else {
      buf.write_char(c)
    }
  }
  buf.to_string()
}

///|
fn parse_client_cli_args(args : Array[String]) -> ClientCliArgs {
  let flags : Map[String, String] = Map([])
  let positionals : Array[String] = []
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if arg.has_prefix("--") {
      let eq_idx = match arg.find("=") {
        Some(idx) => idx
        None => -1
      }
      if eq_idx > 2 {
        let key = normalize_cli_key(arg[2:eq_idx].to_owned())
        let value = arg[eq_idx + 1:arg.length()].to_owned()
        flags.set(key, value)
        i = i + 1
      } else {
        let key = normalize_cli_key(arg[2:arg.length()].to_owned())
        if i + 1 < args.length() && !args[i + 1].has_prefix("--") {
          flags.set(key, args[i + 1])
          i = i + 2
        } else {
          flags.set(key, "true")
          i = i + 1
        }
      }
    } else {
      positionals.push(arg)
      i = i + 1
    }
  }
  { flags, positionals }
}

///|
fn args_tail(args : Array[String], start : Int) -> Array[String] {
  let tail : Array[String] = []
  for i = start; i < args.length(); i = i + 1 {
    tail.push(args[i])
  }
  tail
}

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
fn client_default_path_exists(path : String) -> Bool {
  @sys.path_exists(path)
}

///|
fn client_default_env_get(key : String) -> String? {
  @sys.getenv(key)
}

///|
fn client_default_read_file(path : String) -> String {
  @sys.read_file(path)
}

///|
fn tool_cli_override_role(
  cli_args : ClientCliArgs,
) -> Result[@types.Role?, String] {
  match cli_args.flags.get("caller_role") {
    Some(role_raw) =>
      match @config.parse_role(role_raw) {
        Ok(role) => Ok(Some(role))
        Err(e) => Err(e.message())
      }
    None => Ok(None)
  }
}

///|
fn local_cfg_has_registration_identity(local_cfg : @types.LocalConfig) -> Bool {
  match local_cfg.role {
    Some(_) => true
    None =>
      match local_cfg.agent_id {
        Some(_) => true
        None =>
          match local_cfg.parent_id {
            Some(_) => true
            None =>
              match local_cfg.branch {
                Some(_) => true
                None =>
                  match local_cfg.parent_branch {
                    Some(_) => true
                    None =>
                      match local_cfg.workspace {
                        Some(_) => true
                        None =>
                          match local_cfg.terminal_target {
                            Some(_) => true
                            None =>
                              match local_cfg.agent_type {
                                Some(_) => true
                                None => local_cfg.spawn_depth is Some(_)
                              }
                          }
                      }
                  }
              }
          }
      }
  }
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
fn tool_effective_config(
  config : @types.Config,
  local_cfg : @types.LocalConfig,
) -> @types.Config {
  let config = config_with_local_listen_uds(config, local_cfg)
  if local_cfg_has_registration_identity(local_cfg) {
    config
  } else {
    match config.agent_id {
      Some(_) => config
      None => { ..config, agent_id: Some("root") }
    }
  }
}

///|
fn tool_should_register(local_cfg : @types.LocalConfig) -> Bool {
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
    role,
    default_role: None,
    project_dir: None,
    listen_uds: local_cfg_env_value(getenv, "CHOIR_LISTEN_UDS"),
    terminal_session: None,
    agent_id: local_cfg_env_value(getenv, "CHOIR_AGENT_ID"),
    parent_id: local_cfg_env_value(getenv, "CHOIR_PARENT_ID"),
    branch: local_cfg_env_value(getenv, "CHOIR_BRANCH"),
    parent_branch: local_cfg_env_value(getenv, "CHOIR_PARENT_BRANCH"),
    workspace: local_cfg_env_value(getenv, "CHOIR_WORKSPACE"),
    terminal_target,
    agent_type,
    spawn_depth: None,
    task_contract: None,
    automerge: None,
    review_mode: None,
    merge_strategy: None,
    auto_pull_after_integration: None,
    auto_rebuild_after_pull: None,
    auto_reload_after_rebuild: None,
    wave_id: None,
  }
}

///|
fn tool_local_cfg_with_env_fallback_resolution(
  local_cfg : @types.LocalConfig,
  env_get? : (String) -> String? = client_default_env_get,
) -> ClientLocalConfigResolution {
  if local_cfg_has_registration_identity(local_cfg) {
    let identity_source = match local_cfg.agent_id {
      Some(_) => Some(@tools.ShutdownIdentitySource::LocalConfig)
      None => None
    }
    { local_cfg, identity_source }
  } else {
    let env_cfg = local_cfg_from_env_lookup(env_get)
    let identity_source = match env_cfg.agent_id {
      Some(_) => Some(@tools.ShutdownIdentitySource::Env)
      None => None
    }
    { local_cfg: env_cfg, identity_source }
  }
}

///|
fn tool_load_config(
  cli_args : ClientCliArgs,
) -> Result[(@types.Role, @types.Config, @types.LocalConfig), String] {
  match tool_load_config_with_identity_source(cli_args) {
    Ok((role, config, local_cfg, _identity_source)) =>
      Ok((role, config, local_cfg))
    Err(err) => Err(err)
  }
}

///|
fn tool_load_config_with_identity_source(
  cli_args : ClientCliArgs,
  env_get? : (String) -> String? = client_default_env_get,
  path_exists? : (String) -> Bool = client_default_path_exists,
  read_file? : (String) -> String = client_default_read_file,
) -> Result[
  (
    @types.Role,
    @types.Config,
    @types.LocalConfig,
    @tools.ShutdownIdentitySource?,
  ),
  String,
] {
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
    Ok(cfg) => cfg
    Err(e) => return Err(e.message())
  }
  let local_resolution = tool_local_cfg_with_env_fallback_resolution(
    match @config.parse_local_config(local_content) {
      Ok(cfg) => cfg
      Err(_) => @types.LocalConfig::default()
    },
    env_get~,
  )
  let local_cfg = local_resolution.local_cfg
  let config = tool_effective_config(base_config, local_cfg)
  let identity_source = match base_config.agent_id {
    Some(_) => Some(@tools.ShutdownIdentitySource::LocalConfig)
    None => local_resolution.identity_source
  }
  let role = match tool_cli_override_role(cli_args) {
    Ok(Some(role)) => role
    Ok(None) => @config.resolve_role(local_cfg.role, config)
    Err(err) => return Err(err)
  }
  Ok((role, config, local_cfg, identity_source))
}

///|
fn client_register_if_needed(
  uds_fd : Int,
  reader : UDSLineReader,
  role : @types.Role,
  config : @types.Config,
  local_cfg : @types.LocalConfig,
) -> Result[Unit, String] {
  let reg_msg = client_registration_message(role, config, local_cfg)
  if !mcp_write_all_uds(uds_fd, @utf8.encode(reg_msg)) {
    return Err("failed to write registration request")
  }
  let reg_resp_line = reader.read_line()
  if reg_resp_line == "" {
    return Err("server connection closed during registration")
  }
  match @transport.parse_response(reg_resp_line) {
    Ok(resp) =>
      if resp.is_ok() {
        Ok(())
      } else {
        let err = resp.error_message().unwrap_or("registration failed")
        if err.contains("agent already exists:") {
          Ok(())
        } else {
          Err(err)
        }
      }
    Err(err) => Err("failed to parse registration response: " + err)
  }
}

///|
fn client_registration_message(
  role : @types.Role,
  config : @types.Config,
  local_cfg : @types.LocalConfig,
) -> String {
  mcp_build_registration_message(
    role,
    config,
    local_cfg,
    connection_lifetime=@transport.ConnectionLifetime::OneShot,
  )
}

///|
fn client_connect_uds(config : @types.Config) -> Int {
  let mut uds_fd = @uds.client_connect(config.listen_uds)
  if uds_fd < 0 {
    if @sys.wait_for_socket(config.listen_uds, 60) {
      uds_fd = @uds.client_connect(config.listen_uds)
    }
  }
  uds_fd
}

///|
fn client_call_uds(
  role : @types.Role,
  config : @types.Config,
  local_cfg : @types.LocalConfig,
  req : @types.Request,
  register_if_needed? : Bool = true,
) -> Result[@types.Response, String] {
  let uds_fd = client_connect_uds(config)
  if uds_fd < 0 {
    return Err("cannot connect to server at " + config.listen_uds)
  }
  let reader = UDSLineReader::new(uds_fd)
  if register_if_needed {
    match client_register_if_needed(uds_fd, reader, role, config, local_cfg) {
      Ok(_) => ()
      Err(err) => {
        @uds.close(uds_fd)
        return Err(err)
      }
    }
  }
  let wire_req = mcp_build_wire_request(req, role, config, local_cfg)
  if !mcp_write_all_uds(uds_fd, @utf8.encode(wire_req)) {
    @uds.close(uds_fd)
    return Err("failed to write tool request")
  }
  let resp_line = reader.read_line()
  @uds.close(uds_fd)
  if resp_line == "" {
    return Err("server connection closed")
  }
  match @transport.parse_response(resp_line) {
    Ok(resp) => Ok(resp)
    Err(err) => Err("failed to parse response: " + err)
  }
}

///|
fn tool_reserved_cli_key(key : String) -> Bool {
  key == "help" || key == "json" || key == "caller_role"
}

///|
fn parse_tool_json_args(raw : String) -> Result[Map[String, Json], String] {
  let json = @json.parse(raw) catch {
    _ => return Err("invalid --json: expected JSON object")
  }
  guard json is Object(obj) else {
    return Err("invalid --json: expected JSON object")
  }
  Ok(obj)
}

///|
fn tool_request_args(
  cli_args : ClientCliArgs,
) -> Result[Map[String, Json], String] {
  if cli_args.positionals.length() > 0 {
    return Err(
      "choir tool does not accept positional arguments after the tool name; use --json or --key value flags",
    )
  }
  let values : Map[String, Json] = match cli_args.flags.get("json") {
    Some(raw) =>
      match parse_tool_json_args(raw) {
        Ok(parsed) => parsed
        Err(err) => return Err(err)
      }
    None => Map([])
  }
  cli_args.flags.each(fn(k, v) {
    if !tool_reserved_cli_key(k) {
      values.set(k, v.to_json())
    }
  })
  Ok(values)
}

///|
fn proc_stat_parent_pid(stat : String) -> String {
  match stat.rev_find(")") {
    Some(close_idx) => {
      let rest = stat[close_idx + 1:stat.length()].trim().to_owned()
      let parts = rest.split(" ")
      let compact : Array[String] = []
      for part in parts {
        let trimmed = part.trim().to_owned()
        if trimmed != "" {
          compact.push(trimmed)
        }
      }
      if compact.length() >= 2 {
        compact[1]
      } else {
        ""
      }
    }
    None => ""
  }
}

///|
fn shutdown_origin_fields(
  identity_source : @tools.ShutdownIdentitySource,
  read_file? : (String) -> String = fn(path) { @sys.read_file(path) },
) -> Map[String, String] {
  let ppid = proc_stat_parent_pid(read_file("/proc/self/stat"))
  let comm = if ppid == "" {
    ""
  } else {
    read_file("/proc/" + ppid + "/comm").trim().to_owned()
  }
  let fields : Map[String, String] = Map([])
  if ppid != "" {
    fields.set("origin_ppid", ppid)
  }
  if comm != "" {
    fields.set("origin_comm", comm)
  }
  match identity_source {
    @tools.ShutdownIdentitySource::Unknown => ()
    _ => fields.set("origin_identity_source", identity_source.to_wire_string())
  }
  fields
}

///|
fn shutdown_identity_source(
  resolved_source : @tools.ShutdownIdentitySource?,
  config_source : @tools.ShutdownIdentitySource?,
  local_cfg : @types.LocalConfig,
) -> @tools.ShutdownIdentitySource {
  match resolved_source {
    Some(source) => return source
    None => ()
  }
  match config_source {
    Some(source) => return source
    None => ()
  }
  match local_cfg.agent_id {
    Some(_) => @tools.ShutdownIdentitySource::LocalConfig
    None => @tools.ShutdownIdentitySource::Unknown
  }
}

///|
fn shutdown_request_identity_source(
  req_args : Map[String, Json],
) -> @tools.ShutdownIdentitySource? {
  if req_args.get("caller_id") is Some(_) {
    Some(@tools.ShutdownIdentitySource::Flag)
  } else {
    None
  }
}

///|
fn enrich_shutdown_origin_json_args(
  args : Map[String, Json],
  identity_source : @tools.ShutdownIdentitySource,
  read_file? : (String) -> String = fn(path) { @sys.read_file(path) },
) -> Unit {
  let fields = shutdown_origin_fields(identity_source, read_file~)
  fields.each(fn(k, v) { args.set(k, v.to_json()) })
}

///|
fn strip_shutdown_origin_json_args(args : Map[String, Json]) -> Unit {
  for key in ["origin_ppid", "origin_comm", "origin_identity_source"] {
    ignore(args.remove(key))
  }
}

///|
fn tool_usage(tool : String) -> String {
  let command = if tool == "" { "<tool>" } else { tool }
  "usage: choir tool " +
  command +
  " [--caller-role <root|tl|dev|worker>] [--json <json-object>] [--key <value> ...]"
}

///|
fn tool_run() -> Unit {
  let args = @env.args()
  if args.length() < 3 {
    client_emit(@types.Response::Err(tool_usage("")))
    return
  }
  let tool = args[2]
  let cli_args = parse_client_cli_args(args_tail(args, 3))
  if cli_args.flags.contains("help") {
    client_emit(
      @types.Response::ok_values({ "usage": tool_usage(tool).to_json() }),
    )
    return
  }
  let req_args = match tool_request_args(cli_args) {
    Ok(parsed) => parsed
    Err(err) => {
      client_emit(@types.Response::Err(err))
      return
    }
  }
  let (role, config, local_cfg, config_identity_source) = match
    tool_load_config_with_identity_source(cli_args) {
    Ok(loaded) => loaded
    Err(err) => {
      client_emit(@types.Response::Err(err))
      return
    }
  }
  if tool == "shutdown" {
    strip_shutdown_origin_json_args(req_args)
    enrich_shutdown_origin_json_args(
      req_args,
      shutdown_identity_source(
        shutdown_request_identity_source(req_args),
        config_identity_source,
        local_cfg,
      ),
    )
  }
  let req : @types.Request = {
    req_method: "tools/call",
    role,
    name: tool,
    args: @types.RequestArgs::from_values(req_args),
  }
  match
    client_call_uds(
      role,
      config,
      local_cfg,
      req,
      register_if_needed=tool_should_register(local_cfg),
    ) {
    Ok(resp) => client_emit(resp)
    Err(err) => client_emit(@types.Response::Err(err))
  }
}

///|
test "client CLI accepts typed flags and rejects positionals" {
  let parsed = parse_client_cli_args([
    "--json", "{\"part_id\":\"part-a\"}", "--take-id=take-a",
  ])
  let values = tool_request_args(parsed).unwrap()
  @debug.assert_eq(values.get("part_id"), Some("part-a".to_json()))
  @debug.assert_eq(values.get("take_id"), Some("take-a".to_json()))
  assert_true(
    tool_request_args(parse_client_cli_args(["unexpected"])) is Err(_),
  )
}

///|
test "client config uses spawned identity when local config has none" {
  let env_get = fn(key : String) -> String? {
    match key {
      "CHOIR_AGENT_ID" => Some("session-a")
      "CHOIR_ROLE" => Some("dev")
      "CHOIR_LISTEN_UDS" => Some("/tmp/choir-session.sock")
      _ => None
    }
  }
  let read_file = fn(path : String) -> String {
    match path {
      ".choir/config.toml" => "project_dir = \"/repo\"\n"
      ".choir/config.local.toml" =>
        "default_role = \"tl\"\nlisten_uds = \"/tmp/root.sock\"\n"
      _ => ""
    }
  }
  let loaded = tool_load_config_with_identity_source(
    parse_client_cli_args([]),
    env_get~,
    path_exists=fn(path) { path == ".choir/config.local.toml" },
    read_file~,
  ).unwrap()
  assert_eq(loaded.0, @types.Role::Dev)
  assert_eq(loaded.1.listen_uds, "/tmp/choir-session.sock")
  @debug.assert_eq(loaded.2.agent_id, Some("session-a"))
  @debug.assert_eq(loaded.3, Some(@tools.ShutdownIdentitySource::Env))
}

///|
test "client config keeps an explicit local identity" {
  let read_file = fn(path : String) -> String {
    match path {
      ".choir/config.toml" => "project_dir = \"/repo\"\n"
      ".choir/config.local.toml" =>
        "role = \"dev\"\nagent_id = \"session-local\"\nlisten_uds = \"/tmp/local.sock\"\n"
      _ => ""
    }
  }
  let loaded = tool_load_config_with_identity_source(
    parse_client_cli_args([]),
    env_get=fn(_) { Some("ignored") },
    path_exists=fn(path) { path == ".choir/config.local.toml" },
    read_file~,
  ).unwrap()
  assert_eq(loaded.1.listen_uds, "/tmp/local.sock")
  @debug.assert_eq(loaded.2.agent_id, Some("session-local"))
  @debug.assert_eq(loaded.3, Some(@tools.ShutdownIdentitySource::LocalConfig))
}

///|
test "client response preserves the Choir envelope" {
  assert_eq(
    client_response_json(@types.Response::Err("boom")),
    "{\"ok\":false,\"error\":\"boom\"}\n",
  )
}

///|
test "shutdown metadata replaces caller supplied origin fields" {
  let values : Map[String, Json] = {
    "caller_id": "session-a".to_json(),
    "origin_ppid": "forged".to_json(),
    "origin_comm": "forged".to_json(),
  }
  strip_shutdown_origin_json_args(values)
  enrich_shutdown_origin_json_args(
    values,
    @tools.ShutdownIdentitySource::Flag,
    read_file=fn(path) {
      match path {
        "/proc/self/stat" => "88 (choir tool) S 42 1 1 0"
        "/proc/42/comm" => "claude\n"
        _ => ""
      }
    },
  )
  @debug.assert_eq(values.get("caller_id"), Some("session-a".to_json()))
  @debug.assert_eq(values.get("origin_ppid"), Some("42".to_json()))
  @debug.assert_eq(values.get("origin_comm"), Some("claude".to_json()))
  @debug.assert_eq(values.get("origin_identity_source"), Some("flag".to_json()))
}
