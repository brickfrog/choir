///|
test "parse_config - full" {
  let content =
    #|default_role = "dev"
    #|project_dir = "/tmp"
    #|shell_command = "bash"
    #|listen_uds = "/tmp/sock"
    #|listen_tcp = "127.0.0.1:9000"
    #|otlp_endpoint = "http://localhost:4318"

  let cfg = parse_config(content).unwrap()
  assert_eq(cfg.default_role, @types.Role::Dev)
  assert_eq(cfg.project_dir, "/tmp")
  assert_eq(cfg.shell_command, Some("bash"))
  assert_eq(cfg.listen_uds, "/tmp/sock")
  assert_eq(cfg.listen_tcp, Some("127.0.0.1:9000"))
  assert_eq(cfg.otlp_endpoint, Some("http://localhost:4318"))
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
    #|otlp_endpoint = ""

  let cfg = parse_config(content).unwrap()
  assert_eq(cfg.shell_command, None)
  assert_eq(cfg.listen_tcp, None)
  assert_eq(cfg.otlp_endpoint, None)
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
