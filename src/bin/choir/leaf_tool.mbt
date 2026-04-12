///|
priv struct LeafCliArgs {
  flags : Map[String, String]
  positionals : Array[String]
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
fn parse_leaf_cli_args(args : Array[String]) -> LeafCliArgs {
  let flags : Map[String, String] = {}
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
        let key = normalize_cli_key(arg[2:eq_idx].to_string())
        let value = arg[eq_idx + 1:arg.length()].to_string()
        flags.set(key, value)
        i = i + 1
      } else {
        let key = normalize_cli_key(arg[2:arg.length()].to_string())
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
fn join_positionals(items : Array[String], start : Int) -> String {
  let buf = StringBuilder::new()
  for i = start; i < items.length(); i = i + 1 {
    if i > start {
      buf.write_char(' ')
    }
    buf.write_string(items[i])
  }
  buf.to_string()
}

///|
fn is_status_word(s : String) -> Bool {
  let lowered = s.trim().to_lower()
  lowered == "success" || lowered == "failure" || lowered == "info"
}

///|
fn looks_like_branch_token(s : String) -> Bool {
  let trimmed = s.trim().to_string()
  if trimmed == "" {
    return false
  }
  for c in trimmed {
    if !((c >= 'a' && c <= 'z') ||
      (c >= 'A' && c <= 'Z') ||
      (c >= '0' && c <= '9') ||
      c == '-' ||
      c == '_' ||
      c == '/' ||
      c == '.') {
      return false
    }
  }
  true
}

///|
fn looks_like_legacy_branch_arg(s : String) -> Bool {
  looks_like_branch_token(s) &&
  (s.contains(".") || s.contains("/") || s.contains("-") || s.contains("_"))
}

///|
fn leaf_tool_request_args(
  tool : String,
  cli_args : LeafCliArgs,
) -> Result[Map[String, String], String] {
  let flags = cli_args.flags
  let positionals = cli_args.positionals
  match tool {
    "file_pr" => {
      if !flags.contains("caller_id") {
        match @sys.getenv("CHOIR_AGENT_ID") {
          Some(id) => if id != "" { flags.set("caller_id", id) }
          None => ()
        }
      }
      let used_legacy_branch = !flags.contains("branch") &&
        positionals.length() > 0 &&
        looks_like_legacy_branch_arg(positionals[0])
      if !flags.contains("branch") {
        if used_legacy_branch {
          flags.set("branch", positionals[0])
        } else if positionals.length() == 0 {
          match @sys.getenv("CHOIR_BRANCH") {
            Some(branch) => if branch != "" { flags.set("branch", branch) }
            None => ()
          }
        }
      }
      if !flags.contains("parent_branch") {
        if used_legacy_branch {
          if positionals.length() > 2 && looks_like_branch_token(positionals[2]) {
            flags.set("parent_branch", positionals[2])
          } else if positionals.length() > 1 &&
            looks_like_branch_token(positionals[1]) {
            flags.set("parent_branch", positionals[1])
          }
        } else if positionals.length() == 0 {
          match @sys.getenv("CHOIR_PARENT_BRANCH") {
            Some(parent_branch) =>
              if parent_branch != "" {
                flags.set("parent_branch", parent_branch)
              }
            None => ()
          }
        }
      }
      Ok(flags)
    }
    "notify_parent" => {
      if !flags.contains("caller_id") {
        match @sys.getenv("CHOIR_AGENT_ID") {
          Some(id) => if id != "" { flags.set("caller_id", id) }
          None => ()
        }
      }
      if !flags.contains("status") &&
        positionals.length() > 0 &&
        is_status_word(positionals[0]) {
        flags.set("status", positionals[0].trim().to_lower().to_string())
      }
      if !flags.contains("message") {
        let message_start = if flags.contains("status") &&
          positionals.length() > 0 &&
          is_status_word(positionals[0]) {
          1
        } else {
          0
        }
        let message = join_positionals(positionals, message_start)
          .trim()
          .to_string()
        if message != "" {
          flags.set("message", message)
        }
      }
      match flags.get("message") {
        Some(message) =>
          if message.trim() == "" {
            Err("notify_parent requires a message")
          } else {
            Ok(flags)
          }
        None => Err("notify_parent requires a message")
      }
    }
    "shutdown" => {
      if !flags.contains("caller_id") {
        match @sys.getenv("CHOIR_AGENT_ID") {
          Some(id) => if id != "" { flags.set("caller_id", id) }
          None => ()
        }
      }
      Ok(flags)
    }
    "task_list" => Ok(flags)
    "task_get" =>
      match flags.get("id") {
        Some(id) =>
          if id.trim() == "" {
            Err("task_get requires id")
          } else {
            Ok(flags)
          }
        None =>
          if positionals.length() == 0 || positionals[0].trim() == "" {
            Err("task_get requires id")
          } else {
            flags.set("id", positionals[0])
            Ok(flags)
          }
      }
    "task_create" => {
      if !flags.contains("id") && positionals.length() > 0 {
        flags.set("id", positionals[0])
      }
      if !flags.contains("title") && positionals.length() > 1 {
        flags.set("title", join_positionals(positionals, 1))
      }
      match (flags.get("id"), flags.get("title")) {
        (Some(id), Some(title)) =>
          if id.trim() == "" || title.trim() == "" {
            Err("task_create requires id and title")
          } else {
            Ok(flags)
          }
        _ => Err("task_create requires id and title")
      }
    }
    "task_update" => {
      if !flags.contains("id") && positionals.length() > 0 {
        flags.set("id", positionals[0])
      }
      match flags.get("id") {
        Some(id) =>
          if id.trim() == "" {
            Err("task_update requires id")
          } else {
            Ok(flags)
          }
        None => Err("task_update requires id")
      }
    }
    _ => Err("unsupported leaf tool: " + tool)
  }
}

///|
fn leaf_tool_usage(tool : String) -> String {
  match tool {
    "file_pr" =>
      "usage: file_pr [--branch <branch>] [--parent-branch <parent_branch>]"
    "notify_parent" =>
      "usage: notify_parent [--status <success|failure|info>] <message>"
    "shutdown" => "usage: shutdown [--caller-id <caller_id>]"
    "task_list" => "usage: task_list"
    "task_get" => "usage: task_get <id>"
    "task_create" =>
      "usage: task_create <id> <title...> [--status <status>] [--assignee <assignee>] [--notes <notes>]"
    "task_update" =>
      "usage: task_update <id> [--status <status>] [--assignee <assignee>] [--notes <notes>]"
    _ => "usage: choir leaf-tool <tool> [args...]"
  }
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
fn leaf_tool_response_json(resp : @types.Response) -> String {
  client_response_json(resp)
}

///|
fn leaf_tool_emit(resp : @types.Response) -> Unit {
  @sys.write_stdout(leaf_tool_response_json(resp))
  @sys.exit(if resp.is_ok() { 0 } else { 1 })
}

///|
fn leaf_tool_load_config(
  args : Array[String],
) -> Result[(@types.Role, @types.Config, @types.LocalConfig), String] {
  let config_content = @sys.read_file(".choir/config.toml")
  if config_content == "" {
    return Err("missing .choir/config.toml")
  }
  let base_config = match @config.parse_config(config_content) {
    Ok(cfg) => cfg
    Err(e) => return Err(e.message())
  }
  let local_content = @sys.read_file(".choir/config.local.toml")
  if local_content == "" {
    return Err("missing .choir/config.local.toml")
  }
  let local_cfg = match @config.parse_local_config(local_content) {
    Ok(cfg) => cfg
    Err(e) => return Err(e.message())
  }
  let config = mcp_config_with_cli_overrides(base_config, local_cfg, args)
  let role = match mcp_cli_override_role(args) {
    Some(role) => role
    None => @config.resolve_role(local_cfg.role, config)
  }
  Ok((role, config, local_cfg))
}

///|
fn tool_cli_override_role(
  cli_args : LeafCliArgs,
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
fn tool_effective_config(
  config : @types.Config,
  local_cfg : @types.LocalConfig,
) -> @types.Config {
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
      let trimmed = value.trim().to_string()
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
  }
}

///|
fn local_cfg_from_env() -> @types.LocalConfig {
  local_cfg_from_env_lookup(fn(key) { @sys.getenv(key) })
}

///|
fn tool_local_cfg_with_env_fallback(
  local_cfg : @types.LocalConfig,
) -> @types.LocalConfig {
  if local_cfg_has_registration_identity(local_cfg) {
    local_cfg
  } else {
    local_cfg_from_env()
  }
}

///|
fn tool_load_config(
  cli_args : LeafCliArgs,
) -> Result[(@types.Role, @types.Config, @types.LocalConfig), String] {
  let config_content = @sys.read_file(".choir/config.toml")
  if config_content == "" {
    return Err("missing .choir/config.toml")
  }
  let base_config = match @config.parse_config(config_content) {
    Ok(cfg) => cfg
    Err(e) => return Err(e.message())
  }
  let local_content = @sys.read_file(".choir/config.local.toml")
  let local_cfg = tool_local_cfg_with_env_fallback(
    match @config.parse_local_config(local_content) {
      Ok(cfg) => cfg
      Err(_) => @types.LocalConfig::default()
    },
  )
  let config = tool_effective_config(base_config, local_cfg)
  let role = match tool_cli_override_role(cli_args) {
    Ok(Some(role)) => role
    Ok(None) => @config.resolve_role(local_cfg.role, config)
    Err(err) => return Err(err)
  }
  Ok((role, config, local_cfg))
}

///|
fn client_register_if_needed(
  uds_fd : Int,
  reader : UDSLineReader,
  role : @types.Role,
  config : @types.Config,
  local_cfg : @types.LocalConfig,
) -> Result[Unit, String] {
  let reg_msg = mcp_build_registration_message(role, config, local_cfg)
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
  cli_args : LeafCliArgs,
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
    None => {}
  }
  cli_args.flags.each(fn(k, v) {
    if !tool_reserved_cli_key(k) {
      values.set(k, v.to_json())
    }
  })
  Ok(values)
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
  let cli_args = parse_leaf_cli_args(args_tail(args, 3))
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
  let (role, config, local_cfg) = match tool_load_config(cli_args) {
    Ok(loaded) => loaded
    Err(err) => {
      client_emit(@types.Response::Err(err))
      return
    }
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
fn leaf_tool_run() -> Unit {
  let args = @env.args()
  if args.length() < 3 {
    leaf_tool_emit(
      @types.Response::Err("usage: choir leaf-tool <tool> [args...]"),
    )
    return
  }
  let tool = args[2]
  let cli_args = parse_leaf_cli_args(args_tail(args, 3))
  if cli_args.flags.contains("help") {
    leaf_tool_emit(
      @types.Response::ok_values({ "usage": leaf_tool_usage(tool).to_json() }),
    )
    return
  }
  let req_args = match leaf_tool_request_args(tool, cli_args) {
    Ok(parsed) => parsed
    Err(err) => {
      leaf_tool_emit(@types.Response::Err(err))
      return
    }
  }
  let (role, config, local_cfg) = match leaf_tool_load_config(args) {
    Ok(loaded) => loaded
    Err(err) => {
      leaf_tool_emit(@types.Response::Err(err))
      return
    }
  }
  let req : @types.Request = {
    req_method: "tools/call",
    role,
    name: tool,
    args: @types.RequestArgs::new(req_args),
  }
  match client_call_uds(role, config, local_cfg, req) {
    Ok(resp) => leaf_tool_emit(resp)
    Err(err) => leaf_tool_emit(@types.Response::Err(err))
  }
}

///|
test "leaf tool parser supports notify_parent positional message and status" {
  let parsed = leaf_tool_request_args(
    "notify_parent",
    parse_leaf_cli_args(["failure", "[BLOCKED]", "need", "help"]),
  ).unwrap()
  assert_eq(parsed.get("status"), Some("failure"))
  assert_eq(parsed.get("message"), Some("[BLOCKED] need help"))
}

///|
test "leaf tool parser accepts legacy file_pr positional triplet" {
  let parsed = leaf_tool_request_args(
    "file_pr",
    parse_leaf_cli_args(["main.gemini-leaf", "main.gemini-leaf", "main"]),
  ).unwrap()
  assert_eq(parsed.get("branch"), Some("main.gemini-leaf"))
  assert_eq(parsed.get("parent_branch"), Some("main"))
}

///|
test "leaf tool parser ignores prose positionals for file_pr" {
  let parsed = leaf_tool_request_args(
    "file_pr",
    parse_leaf_cli_args(["Add", "pytest", "integration", "tests"]),
  ).unwrap()
  // Prose must not be interpreted as the legacy branch triplet (ambient CHOIR_* may still set branch).
  assert_not_eq(parsed.get("branch"), Some("Add"))
  assert_not_eq(parsed.get("branch"), Some("pytest"))
  assert_not_eq(parsed.get("parent_branch"), Some("Add"))
  assert_not_eq(parsed.get("parent_branch"), Some("pytest"))
  assert_not_eq(parsed.get("parent_branch"), Some("integration"))
}

///|
test "leaf tool usage includes file_pr args" {
  assert_eq(
    leaf_tool_usage("file_pr"),
    "usage: file_pr [--branch <branch>] [--parent-branch <parent_branch>]",
  )
}

///|
test "client response helpers preserve Choir JSON envelope and newline" {
  let ok_json = client_response_json(
    @types.Response::ok_values({ "status": "ok".to_json() }),
  )
  assert_true(ok_json.contains("\"ok\":true"))
  assert_true(ok_json.contains("\"status\":\"ok\""))
  assert_true(ok_json.has_suffix("\n"))

  let err_json = leaf_tool_response_json(@types.Response::Err("boom"))
  assert_eq(err_json, "{\"ok\":false,\"error\":\"boom\"}\n")
}

///|
test "tool usage documents caller role and json entrypoints" {
  let usage = tool_usage("agent_list")
  assert_true(usage.contains("choir tool agent_list"))
  assert_true(usage.contains("--caller-role <root|tl|dev|worker>"))
  assert_true(usage.contains("--json <json-object>"))
}

///|
test "leaf tool parser supports task_create positionals" {
  let parsed = leaf_tool_request_args(
    "task_create",
    parse_leaf_cli_args(["task-1", "Write", "better", "tests"]),
  ).unwrap()
  assert_eq(parsed.get("id"), Some("task-1"))
  assert_eq(parsed.get("title"), Some("Write better tests"))
}

///|
test "tool request args preserve name as a tool field" {
  let parsed = tool_request_args(parse_leaf_cli_args(["--name", "lock-a"])).unwrap()
  assert_eq(parsed.get("name"), Some("lock-a".to_json()))
}

///|
test "tool request args merge json payload with flags" {
  let parsed = tool_request_args(
    parse_leaf_cli_args([
      "--json", "{\"tasks\":[\"a\",\"b\"],\"force\":false,\"count\":2}", "--force",
      "--caller-id", "root",
    ]),
  ).unwrap()
  match parsed.get("tasks") {
    Some(json) => assert_eq(json.stringify(), "[\"a\",\"b\"]")
    None => fail("expected tasks field")
  }
  match parsed.get("count") {
    Some(json) => assert_eq(json.stringify(), "2")
    None => fail("expected count field")
  }
  assert_eq(parsed.get("force"), Some("true".to_json()))
  assert_eq(parsed.get("caller_id"), Some("root".to_json()))
}

///|
test "tool request args reject positional arguments" {
  match tool_request_args(parse_leaf_cli_args(["extra-arg"])) {
    Ok(_) => fail("expected positional argument error")
    Err(err) =>
      assert_true(err.contains("does not accept positional arguments"))
  }
}

///|
test "tool caller role rejects invalid role" {
  match tool_cli_override_role(parse_leaf_cli_args(["--caller-role", "boss"])) {
    Ok(_) => fail("expected invalid caller role")
    Err(err) => assert_true(err.contains("unknown role: boss"))
  }
}

///|
test "tool root control plane uses stable root caller without registration" {
  let local_cfg = @types.LocalConfig::default()
  let config = tool_effective_config(@types.Config::default(), local_cfg)
  assert_false(tool_should_register(local_cfg))
  assert_eq(config.agent_id, Some("root"))
  let req : @types.Request = {
    req_method: "tools/call",
    role: @types.Role::TL,
    name: "agent_list",
    args: @types.RequestArgs::from_values({}),
  }
  let wire_req = mcp_build_wire_request(req, @types.Role::TL, config, local_cfg)
  assert_true(wire_req.contains("\"caller_id\":\"root\""))
}

///|
test "tool local agent context keeps registration path" {
  let local_cfg = {
    ..@types.LocalConfig::default(),
    role: Some(@types.Role::Dev),
    agent_id: Some("main.child"),
    parent_id: Some("root"),
    workspace: Some("/tmp/worktree"),
  }
  let config = tool_effective_config(@types.Config::default(), local_cfg)
  assert_true(tool_should_register(local_cfg))
  assert_eq(config.agent_id, None)
  let req : @types.Request = {
    req_method: "tools/call",
    role: @types.Role::Dev,
    name: "task_list",
    args: @types.RequestArgs::from_values({}),
  }
  let wire_req = mcp_build_wire_request(
    req,
    @types.Role::Dev,
    config,
    local_cfg,
  )
  assert_true(wire_req.contains("\"caller_id\":\"main.child\""))
}

///|
test "tool env fallback synthesizes inline worker identity" {
  let env : Map[String, String] = {
    "CHOIR_ROLE": "worker",
    "CHOIR_AGENT_ID": "main.claude-worker",
    "CHOIR_PARENT_ID": "root",
    "CHOIR_BRANCH": "main.claude-worker",
    "CHOIR_PARENT_BRANCH": "main",
    "CHOIR_WORKSPACE": "/proj",
    "CHOIR_TERMINAL_TARGET": "zellij-pane:choir:claude-worker",
    "CHOIR_AGENT_TYPE": "claude",
  }
  let local_cfg = local_cfg_from_env_lookup(fn(key) { env.get(key) })
  assert_eq(local_cfg.role, Some(@types.Role::Worker))
  assert_eq(local_cfg.agent_id, Some("main.claude-worker"))
  assert_eq(local_cfg.parent_id, Some("root"))
  assert_eq(local_cfg.branch, Some("main.claude-worker"))
  assert_eq(local_cfg.parent_branch, Some("main"))
  assert_eq(local_cfg.workspace, Some("/proj"))
  assert_eq(local_cfg.agent_type, Some(@types.AgentType::Claude))
  assert_true(tool_should_register(local_cfg))
}

///|
test "tool env fallback preserves root control plane when env is empty" {
  let local_cfg = local_cfg_from_env_lookup(fn(_) { None })
  let config = tool_effective_config(@types.Config::default(), local_cfg)
  assert_false(tool_should_register(local_cfg))
  assert_eq(config.agent_id, Some("root"))
}
