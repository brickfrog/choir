///|
test "parse_config - full" {
  let content =
    #|default_role = "dev"
    #|project_dir = "/tmp"
    #|shell_command = "bash"
    #|listen_uds = "/tmp/sock"
    #|listen_tcp = "127.0.0.1:9000"
    #|tcp_auth_token = "secret-token-abc"
    #|otlp_endpoint = "http://localhost:4318"
    #|extra_mcp_servers_json = '{"notebook":{"type":"stdio","command":"node"}}'
    #|companions_json = '[{"name":"monitor","role":"worker","command":"claude","task":"Monitor the build"}]'
    #|plugins_json = '[{"name":"plugin","command":"./plugin","tools":"search"}]'

  let cfg = parse_config(content).unwrap()
  assert_eq(cfg.default_role, @types.Role::Dev)
  assert_eq(cfg.project_dir, "/tmp")
  assert_eq(cfg.shell_command, Some("bash"))
  assert_eq(cfg.listen_uds, "/tmp/sock")
  assert_eq(cfg.listen_tcp, Some("127.0.0.1:9000"))
  assert_eq(cfg.tcp_auth_token, Some("secret-token-abc"))
  assert_eq(cfg.otlp_endpoint, Some("http://localhost:4318"))
  assert_eq(
    cfg.extra_mcp_servers_json,
    Some("{\"notebook\":{\"type\":\"stdio\",\"command\":\"node\"}}"),
  )
  assert_eq(
    cfg.companions_json,
    Some(
      "[{\"name\":\"monitor\",\"role\":\"worker\",\"command\":\"claude\",\"task\":\"Monitor the build\"}]",
    ),
  )
  assert_eq(
    cfg.plugins_json,
    Some(
      "[{\"name\":\"plugin\",\"command\":\"./plugin\",\"tools\":\"search\"}]",
    ),
  )
}

///|
test "parse_config - minimal" {
  let content = "default_role = \"worker\""
  let cfg = parse_config(content).unwrap()
  assert_eq(cfg.default_role, @types.Role::Worker)
  assert_eq(cfg.project_dir, ".")
  assert_eq(cfg.shell_command, None)
}

///|
test "parse_config - empty string defaults" {
  let content =
    #|shell_command = ""
    #|listen_tcp = ""
    #|tcp_auth_token = ""
    #|otlp_endpoint = ""
    #|agent_id = ""
    #|companions_json = ""
    #|plugins_json = ""

  let cfg = parse_config(content).unwrap()
  assert_eq(cfg.shell_command, None)
  assert_eq(cfg.listen_tcp, None)
  assert_eq(cfg.tcp_auth_token, None)
  assert_eq(cfg.otlp_endpoint, None)
  assert_eq(cfg.agent_id, None)
  assert_eq(cfg.extra_mcp_servers_json, None)
  assert_eq(cfg.companions_json, None)
  assert_eq(cfg.plugins_json, None)
}

///|
test "parse_config - agent_id set" {
  let cfg = parse_config("agent_id = \"my-agent\"").unwrap()
  assert_eq(cfg.agent_id, Some("my-agent"))
}

///|
test "parse_config - agent_id defaults to None" {
  let cfg = parse_config("").unwrap()
  assert_eq(cfg.agent_id, None)
  assert_eq(cfg.extra_mcp_servers_json, None)
  assert_eq(cfg.companions_json, None)
  assert_eq(cfg.plugins_json, None)
}

///|
test "parse config with tcp_auth_token" {
  let content =
    #|default_role = "tl"
    #|tcp_auth_token = "secret-token-abc"
  let cfg = match @config.parse_config(content) {
    Ok(c) => c
    Err(_) => {
      assert_true(false)
      @types.Config::default()
    }
  }
  assert_eq(cfg.tcp_auth_token, Some("secret-token-abc"))
}

///|
test "parse config with empty tcp_auth_token treated as None" {
  let content =
    #|tcp_auth_token = ""
  let cfg = match @config.parse_config(content) {
    Ok(c) => c
    Err(_) => {
      assert_true(false)
      @types.Config::default()
    }
  }
  assert_eq(cfg.tcp_auth_token, None)
}

///|
test "parse_config_local - valid" {
  let content = "role = \"tl\""
  let role = parse_config_local(content).unwrap()
  assert_eq(role, @types.Role::TL)
}

///|
test "resolve_role" {
  let cfg = @types.Config::default()
  let local_role : @types.Role? = Some(@types.Role::Dev)
  let resolved = resolve_role(local_role, cfg)
  assert_eq(resolved, @types.Role::Dev)

  let none_role : @types.Role? = None
  let resolved_none = resolve_role(none_role, cfg)
  assert_eq(resolved_none, @types.Role::TL)
}

///|
test "invalid role error" {
  let content = "default_role = \"invalid\""
  let result = parse_config(content)
  assert_eq(result is Ok(_), false)
}

///|
test "malformed TOML error" {
  let content = "just some garbage"
  let result = parse_config_local(content)
  assert_eq(result is Ok(_), false)
}
