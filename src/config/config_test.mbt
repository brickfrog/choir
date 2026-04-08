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
    #|terminal_backend = "zellij"
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
  assert_eq(cfg.terminal_session, "choir")
  assert_eq(cfg.pr_review, true)
}

///|
test "parse_toml_doc optional helpers" {
  let doc = parse_toml_doc(
    (
      #|shell_command = "bash"
      #|empty_value = ""
    ),
  )
  assert_eq(doc.get("shell_command"), Some("bash"))
  assert_eq(doc.get_or("missing", "fallback"), "fallback")
  assert_eq(doc.get_optional_nonempty("shell_command"), Some("bash"))
  assert_eq(doc.get_optional_nonempty("empty_value"), None)
  assert_eq(doc.get_optional_nonempty("missing"), None)
}

///|
test "parse_toml_doc unescapes double-quoted strings" {
  let doc = parse_toml_doc(
    "json = \"{\\\"goal\\\":\\\"ship feature\\\"}\"\npath = \"line\\\\two\"",
  )
  assert_eq(doc.get("json"), Some("{\"goal\":\"ship feature\"}"))
  assert_eq(doc.get("path"), Some("line\\two"))
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
  assert_eq(cfg.pr_review, true)
}

///|
test "parse_config pr_review explicit false" {
  let cfg = parse_config("pr_review = false").unwrap()
  assert_eq(cfg.pr_review, false)
}

///|
test "parse_config pr_review explicit true" {
  let cfg = parse_config("pr_review = true").unwrap()
  assert_eq(cfg.pr_review, true)
}

///|
test "parse_config pr_review false with inline comment" {
  let cfg = parse_config("pr_review = false # disable copilot review").unwrap()
  assert_eq(cfg.pr_review, false)
}

///|
test "parse_config pr_review true with inline comment" {
  let cfg = parse_config("pr_review = true # keep reviews").unwrap()
  assert_eq(cfg.pr_review, true)
}

///|
test "parse_config pr_review invalid is error" {
  let r = parse_config("pr_review = maybe")
  assert_true(r is Err(_))
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
test "parse_local_config - metadata" {
  let content =
    #|role = "dev"
    #|agent_id = "main.child"
    #|parent_id = "main"
    #|branch = "main.child"
    #|parent_branch = "main"
    #|workspace = "/tmp/worktree"
    #|terminal_target = "zellij-tab:choir:child"
    #|agent_type = "gemini"
  let local_cfg = parse_local_config(content).unwrap()
  assert_eq(local_cfg.role, Some(@types.Role::Dev))
  assert_eq(local_cfg.agent_id, Some("main.child"))
  assert_eq(local_cfg.parent_id, Some("main"))
  assert_eq(local_cfg.branch, Some("main.child"))
  assert_eq(local_cfg.parent_branch, Some("main"))
  assert_eq(local_cfg.workspace, Some("/tmp/worktree"))
  assert_eq(
    local_cfg.terminal_target,
    @types.LocalTarget::parse("zellij-tab:choir:child"),
  )
  assert_eq(local_cfg.agent_type, Some(@types.AgentType::Gemini))
}

///|
test "parse_local_config spawn_depth" {
  let with_depth =
    #|role = "tl"
    #|spawn_depth = 1
    #|agent_id = "main.sub"
  let local_cfg = parse_local_config(with_depth).unwrap()
  assert_eq(local_cfg.spawn_depth, Some(1))
}

///|
fn escape_toml_test_string(s : String) -> String {
  let buf = StringBuilder::new()
  for c in s {
    match c {
      '"' => buf.write_string("\\\"")
      '\\' => buf.write_string("\\\\")
      _ => buf.write_char(c)
    }
  }
  buf.to_string()
}

///|
test "parse_local_config task_contract_json" {
  let contract = {
    ..@types.TaskContract::empty(),
    goal: "ship feature",
    verify: ["moon test --target native"],
  }
  let with_contract = "role = \"dev\"\n" +
    "task_contract_json = \"" +
    escape_toml_test_string(contract.to_json_string()) +
    "\"\n"
  let local_cfg = parse_local_config(with_contract).unwrap()
  match local_cfg.task_contract {
    Some(parsed) => {
      assert_eq(parsed.goal, "ship feature")
      assert_eq(parsed.verify, ["moon test --target native"])
    }
    None => fail("expected task_contract")
  }
}

///|
test "parse_local_config rejects spawn_depth above 1" {
  let bad = "role = \"tl\"\nspawn_depth = 2\n"
  assert_true(parse_local_config(bad) is Err(_))
}

///|
test "parse_companions_json shared helper" {
  let parsed = parse_companions_json(
    "[{\"name\":\"monitor\",\"role\":\"worker\",\"command\":\"claude\",\"task\":\"watch build\"},true,{\"name\":\"reviewer\",\"command\":\"gemini\"}]",
  )
  assert_eq(parsed.length(), 2)
  assert_eq(parsed[0].name, "monitor")
  assert_eq(parsed[0].role, "worker")
  assert_eq(parsed[0].command, "claude")
  assert_eq(parsed[0].task, "watch build")
  assert_eq(parsed[1].name, "reviewer")
  assert_eq(parsed[1].role, "worker")
  assert_eq(parsed[1].command, "gemini")
  assert_eq(parsed[1].task, "")
}

///|
test "hook_command_path ignores empty values" {
  let content =
    #|hook.session_start = "/tmp/hook-start"
    #|hook.pre_tool_use = ""
  assert_eq(
    hook_command_path(content, "hook.session_start"),
    Some("/tmp/hook-start"),
  )
  assert_eq(hook_command_path(content, "hook.pre_tool_use"), None)
  assert_eq(hook_command_path(content, "hook.unknown"), None)
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
