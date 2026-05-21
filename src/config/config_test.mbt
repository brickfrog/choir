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
    #|worker_no_handoff_prod_sec = 90
    #|worker_no_handoff_escalate_sec = 45
    #|audit_heartbeat_sec = 30
    #|audit_max_rounds = 2
    #|poller_heartbeat_tick_sec = 10
    #|agy_migration_incomplete = true
    #|auto_pull_after_integration = false
    #|auto_rebuild_after_pull = true
    #|auto_reload_after_rebuild = true
    #|[pr_policy]
    #|require_integration_audit = false

  let cfg = parse_config(content).unwrap()
  assert_eq(cfg.default_role, @types.Role::Dev)
  assert_eq(cfg.project_dir, "/tmp")
  @debug.assert_eq(cfg.shell_command, Some("bash"))
  assert_eq(cfg.listen_uds, "/tmp/sock")
  @debug.assert_eq(cfg.listen_tcp, Some("127.0.0.1:9000"))
  @debug.assert_eq(cfg.tcp_auth_token, Some("secret-token-abc"))
  @debug.assert_eq(cfg.otlp_endpoint, Some("http://localhost:4318"))
  @debug.assert_eq(
    cfg.extra_mcp_servers_json,
    Some("{\"notebook\":{\"type\":\"stdio\",\"command\":\"node\"}}"),
  )
  @debug.assert_eq(
    cfg.companions_json,
    Some(
      "[{\"name\":\"monitor\",\"role\":\"worker\",\"command\":\"claude\",\"task\":\"Monitor the build\"}]",
    ),
  )
  @debug.assert_eq(
    cfg.plugins_json,
    Some(
      "[{\"name\":\"plugin\",\"command\":\"./plugin\",\"tools\":\"search\"}]",
    ),
  )
  assert_eq(cfg.worker_no_handoff_prod_sec, 90L)
  assert_eq(cfg.worker_no_handoff_escalate_sec, 45L)
  assert_eq(cfg.audit_heartbeat_sec, 30)
  assert_eq(cfg.audit_max_rounds, 2)
  assert_eq(cfg.poller_heartbeat_tick_sec, 10)
  assert_eq(cfg.agy_migration_incomplete, true)
  assert_eq(cfg.auto_pull_after_integration, false)
  assert_eq(cfg.pr_policy.require_integration_audit, false)
  assert_eq(cfg.auto_rebuild_after_pull, true)
  assert_eq(cfg.auto_reload_after_rebuild, true)
}

///|
test "parse_config - minimal" {
  let content = "default_role = \"worker\""
  let cfg = parse_config(content).unwrap()
  assert_eq(cfg.default_role, @types.Role::Worker)
  assert_eq(cfg.project_dir, ".")
  @debug.assert_eq(cfg.shell_command, None)
  assert_eq(cfg.terminal_session, "choir")
  assert_eq(cfg.pr_review, true)
  assert_eq(cfg.automerge, false)
  assert_eq(cfg.review_mode, @types.ReviewMode::SinglePass)
  assert_eq(cfg.worker_no_handoff_prod_sec, 120L)
  assert_eq(cfg.worker_no_handoff_escalate_sec, 120L)
  assert_eq(cfg.audit_heartbeat_sec, 60)
  assert_eq(cfg.audit_max_rounds, 3)
  assert_eq(cfg.poller_heartbeat_tick_sec, 60)
  assert_eq(cfg.agy_migration_incomplete, false)
  assert_eq(cfg.auto_pull_after_integration, true)
  assert_eq(cfg.pr_policy.require_integration_audit, true)
  assert_eq(cfg.auto_rebuild_after_pull, false)
  assert_eq(cfg.auto_reload_after_rebuild, false)
}

///|
test "parse_toml_doc optional helpers" {
  let doc = parse_toml_doc(
    (
      #|shell_command = "bash"
      #|empty_value = ""
      #|[pricing.codex]
      #|rate_in = 0.001
    ),
  )
  @debug.assert_eq(doc.get("shell_command"), Some("bash"))
  @debug.assert_eq(doc.get("pricing.codex.rate_in"), Some("0.001"))
  assert_eq(doc.get_or("missing", "fallback"), "fallback")
  @debug.assert_eq(doc.get_optional_nonempty("shell_command"), Some("bash"))
  @debug.assert_eq(doc.get_optional_nonempty("empty_value"), None)
  @debug.assert_eq(doc.get_optional_nonempty("missing"), None)
}

///|
test "parse_toml_doc unescapes double-quoted strings" {
  let doc = parse_toml_doc(
    "json = \"{\\\"goal\\\":\\\"ship feature\\\"}\"\npath = \"line\\\\two\"",
  )
  @debug.assert_eq(doc.get("json"), Some("{\"goal\":\"ship feature\"}"))
  @debug.assert_eq(doc.get("path"), Some("line\\two"))
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
  @debug.assert_eq(cfg.shell_command, None)
  @debug.assert_eq(cfg.listen_tcp, None)
  @debug.assert_eq(cfg.tcp_auth_token, None)
  @debug.assert_eq(cfg.otlp_endpoint, None)
  @debug.assert_eq(cfg.agent_id, None)
  @debug.assert_eq(cfg.extra_mcp_servers_json, None)
  @debug.assert_eq(cfg.companions_json, None)
  @debug.assert_eq(cfg.plugins_json, None)
}

///|
test "parse_config - agent_id set" {
  let cfg = parse_config("agent_id = \"my-agent\"").unwrap()
  @debug.assert_eq(cfg.agent_id, Some("my-agent"))
}

///|
test "parse_config - agent_id defaults to None" {
  let cfg = parse_config("").unwrap()
  @debug.assert_eq(cfg.agent_id, None)
  @debug.assert_eq(cfg.extra_mcp_servers_json, None)
  @debug.assert_eq(cfg.companions_json, None)
  @debug.assert_eq(cfg.plugins_json, None)
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
test "parse_config worker no-handoff knobs accept zero disable" {
  let cfg = parse_config(
    (
      #|worker_no_handoff_prod_sec = 0
      #|worker_no_handoff_escalate_sec = 0
      #|audit_heartbeat_sec = 0
      #|poller_heartbeat_tick_sec = 0
    ),
  ).unwrap()
  assert_eq(cfg.worker_no_handoff_prod_sec, 0L)
  assert_eq(cfg.worker_no_handoff_escalate_sec, 0L)
  assert_eq(cfg.audit_heartbeat_sec, 0)
  assert_eq(cfg.poller_heartbeat_tick_sec, 0)
}

///|
test "parse_config worker no-handoff knobs reject negatives" {
  match parse_config("worker_no_handoff_prod_sec = -1") {
    Err(e) => assert_true(e.message().contains("expected >= 0"))
    Ok(_) => fail("expected negative prod config to fail")
  }
}

///|
test "parse_config worker no-handoff knobs reject fractional values" {
  match parse_config("worker_no_handoff_escalate_sec = 1.5") {
    Err(e) => assert_true(e.message().contains("expected integer"))
    Ok(_) => fail("expected fractional escalate config to fail")
  }
}

///|
test "parse_config audit heartbeat knob rejects invalid values" {
  let max_cfg = parse_config(
    "audit_heartbeat_sec = " + @types.audit_heartbeat_sec_max.to_string(),
  ).unwrap()
  assert_eq(max_cfg.audit_heartbeat_sec, @types.audit_heartbeat_sec_max)
  match parse_config("audit_heartbeat_sec = -1") {
    Err(e) => assert_true(e.message().contains("expected >= 0"))
    Ok(_) => fail("expected negative audit heartbeat config to fail")
  }
  match parse_config("audit_heartbeat_sec = 1.5") {
    Err(e) => assert_true(e.message().contains("expected integer"))
    Ok(_) => fail("expected fractional audit heartbeat config to fail")
  }
  match
    parse_config(
      "audit_heartbeat_sec = " +
      (@types.audit_heartbeat_sec_max.to_int64() + 1L).to_string(),
    ) {
    Err(e) => assert_true(e.message().contains("expected <= "))
    Ok(_) => fail("expected oversized audit heartbeat config to fail")
  }
}

///|
test "parse_config audit max rounds knob parses default and rejects invalid values" {
  assert_eq(parse_config("").unwrap().audit_max_rounds, 3)
  let one_cfg = parse_config("audit_max_rounds = 1").unwrap()
  assert_eq(one_cfg.audit_max_rounds, 1)
  let max_cfg = parse_config(
    "audit_max_rounds = " + @types.audit_max_rounds_max.to_string(),
  ).unwrap()
  assert_eq(max_cfg.audit_max_rounds, @types.audit_max_rounds_max)
  match parse_config("audit_max_rounds = 0") {
    Err(e) =>
      assert_true(e.message().contains("audit_max_rounds must be >= 1; got 0"))
    Ok(_) => fail("expected zero audit max rounds config to fail")
  }
  match parse_config("audit_max_rounds = -1") {
    Err(e) =>
      assert_true(e.message().contains("audit_max_rounds must be >= 1; got -1"))
    Ok(_) => fail("expected negative audit max rounds config to fail")
  }
  match parse_config("audit_max_rounds = 1.5") {
    Err(e) => assert_true(e.message().contains("expected integer"))
    Ok(_) => fail("expected fractional audit max rounds config to fail")
  }
  match parse_config("audit_max_rounds = 9999999") {
    Err(e) => assert_true(e.message().contains("expected <= "))
    Ok(_) => fail("expected oversized audit max rounds config to fail")
  }
}

///|
test "parse_config poller heartbeat knob rejects invalid values" {
  let max_cfg = parse_config(
    "poller_heartbeat_tick_sec = " + @types.audit_heartbeat_sec_max.to_string(),
  ).unwrap()
  assert_eq(max_cfg.poller_heartbeat_tick_sec, @types.audit_heartbeat_sec_max)
  match parse_config("poller_heartbeat_tick_sec = -1") {
    Err(e) => assert_true(e.message().contains("expected >= 0"))
    Ok(_) => fail("expected negative poller heartbeat config to fail")
  }
  match parse_config("poller_heartbeat_tick_sec = 1.5") {
    Err(e) => assert_true(e.message().contains("expected integer"))
    Ok(_) => fail("expected fractional poller heartbeat config to fail")
  }
  match
    parse_config(
      "poller_heartbeat_tick_sec = " +
      (@types.audit_heartbeat_sec_max.to_int64() + 1L).to_string(),
    ) {
    Err(e) => assert_true(e.message().contains("expected <= "))
    Ok(_) => fail("expected oversized poller heartbeat config to fail")
  }
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
test "parse_config automerge explicit true" {
  let cfg = parse_config("automerge = true").unwrap()
  assert_eq(cfg.automerge, true)
}

///|
test "parse_config automerge explicit false" {
  let cfg = parse_config("automerge = false").unwrap()
  assert_eq(cfg.automerge, false)
}

///|
test "parse_config automerge invalid is error" {
  let r = parse_config("automerge = maybe")
  assert_true(r is Err(_))
}

///|
test "parse_config review_mode explicit iterative" {
  let cfg = parse_config("review_mode = \"iterative\"").unwrap()
  assert_eq(cfg.review_mode, @types.ReviewMode::Iterative)
}

///|
test "parse_config review_mode explicit single_pass" {
  let cfg = parse_config("review_mode = \"single_pass\"").unwrap()
  assert_eq(cfg.review_mode, @types.ReviewMode::SinglePass)
}

///|
test "parse_config review_mode invalid is error" {
  let r = parse_config("review_mode = \"again\"")
  assert_true(r is Err(_))
}

///|
test "parse_config pr_policy require_integration_audit invalid is error" {
  let r = parse_config(
    (
      #|[pr_policy]
      #|require_integration_audit = "maybe"
    ),
  )
  match r {
    Ok(_) => fail("expected invalid pr_policy.require_integration_audit")
    Err(e) =>
      assert_true(e.message().contains("pr_policy.require_integration_audit"))
  }
}

///|
test "parse_config pricing tables are typed" {
  let cfg = parse_config(
    (
      #|[pricing.codex]
      #|rate_in = 0.001
      #|rate_out = 0.002
    ),
  ).unwrap()
  match cfg.pricing.get("codex") {
    Some(rate) => {
      assert_eq(rate.rate_in, 0.001)
      assert_eq(rate.rate_out, 0.002)
    }
    None => fail("missing codex pricing")
  }
}

///|
test "parse_config pricing invalid number reports key" {
  match
    parse_config(
      (
        #|[pricing.codex]
        #|rate_in = nope
        #|rate_out = 0.002
      ),
    ) {
    Ok(_) => fail("invalid pricing number should fail")
    Err(e) => assert_true(e.message().contains("pricing.codex.rate_in"))
  }
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
  @debug.assert_eq(cfg.tcp_auth_token, Some("secret-token-abc"))
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
  @debug.assert_eq(cfg.tcp_auth_token, None)
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
    #|wave_id = "wv-demo"
  let local_cfg = parse_local_config(content).unwrap()
  @debug.assert_eq(local_cfg.role, Some(@types.Role::Dev))
  @debug.assert_eq(local_cfg.agent_id, Some("main.child"))
  @debug.assert_eq(local_cfg.parent_id, Some("main"))
  @debug.assert_eq(local_cfg.branch, Some("main.child"))
  @debug.assert_eq(local_cfg.parent_branch, Some("main"))
  @debug.assert_eq(local_cfg.workspace, Some("/tmp/worktree"))
  @debug.assert_eq(
    local_cfg.terminal_target,
    @types.LocalTarget::parse("zellij-tab:choir:child"),
  )
  @debug.assert_eq(local_cfg.agent_type, Some(@types.AgentType::Gemini))
  @debug.assert_eq(local_cfg.wave_id, Some("wv-demo"))
}

///|
test "parse_local_config spawn_depth" {
  let with_depth =
    #|role = "tl"
    #|spawn_depth = 1
    #|agent_id = "main.sub"
  let local_cfg = parse_local_config(with_depth).unwrap()
  @debug.assert_eq(local_cfg.spawn_depth, Some(1))
}

///|
test "parse_local_config automerge override" {
  let content =
    #|role = "dev"
    #|automerge = true
  let local_cfg = parse_local_config(content).unwrap()
  @debug.assert_eq(local_cfg.automerge, Some(true))
}

///|
test "parse_local_config review_mode override" {
  let content =
    #|role = "dev"
    #|review_mode = "iterative"
  let local_cfg = parse_local_config(content).unwrap()
  @debug.assert_eq(local_cfg.review_mode, Some(@types.ReviewMode::Iterative))
}

///|
test "parse_local_config post merge loop flags" {
  let content =
    #|role = "tl"
    #|auto_pull_after_integration = false
    #|auto_rebuild_after_pull = true
    #|auto_reload_after_rebuild = true
  let local_cfg = parse_local_config(content).unwrap()
  @debug.assert_eq(local_cfg.auto_pull_after_integration, Some(false))
  @debug.assert_eq(local_cfg.auto_rebuild_after_pull, Some(true))
  @debug.assert_eq(local_cfg.auto_reload_after_rebuild, Some(true))
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
    beads_issue_id: Some("choir-beads-contract-propagation"),
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
      @debug.assert_eq(
        parsed.beads_issue_id,
        Some("choir-beads-contract-propagation"),
      )
      @debug.assert_eq(parsed.verify, ["moon test --target native"])
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
  @debug.assert_eq(
    hook_command_path(content, "hook.session_start"),
    Some("/tmp/hook-start"),
  )
  @debug.assert_eq(hook_command_path(content, "hook.pre_tool_use"), None)
  @debug.assert_eq(hook_command_path(content, "hook.unknown"), None)
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
