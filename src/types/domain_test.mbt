///|
test "role equality" {
  assert_eq(@types.Role::TL, @types.Role::TL)
  assert_not_eq(@types.Role::Root, @types.Role::Dev)
}

///|
test "agent construction" {
  let agent : @types.Agent = {
    agent_id: @types.AgentId("main.feature-a"),
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Gemini,
    parent: Some("root"),
    workspace: ".choir/worktrees/feature-a",
    branch: "main.feature-a",
    terminal_target: @types.LocalTarget::parse("zellij-tab:choir:feature-a"),
    host: @types.Host::Local,
    spawn_depth: 0,
    state: @types.AgentState::Spawning,
  }
  assert_eq(agent.state, @types.AgentState::Spawning)
  assert_eq(agent.role, @types.Role::Dev)
}

///|
test "default config" {
  let config = @types.Config::default()
  assert_eq(config.default_role, @types.Role::TL)
  assert_eq(config.listen_uds, ".choir/server.sock")
  assert_eq(config.listen_tcp, None)
  assert_eq(config.extra_mcp_servers_json, None)
  assert_eq(config.companions_json, None)
  assert_eq(config.plugins_json, None)
}

///|
test "Role to_wire_string encodes all variants in lowercase wire form" {
  assert_eq(@types.Role::Root.to_wire_string(), "root")
  assert_eq(@types.Role::TL.to_wire_string(), "tl")
  assert_eq(@types.Role::Dev.to_wire_string(), "dev")
  assert_eq(@types.Role::Worker.to_wire_string(), "worker")
}

///|
test "Role try_parse_wire accepts each wire string and matches variant" {
  match @types.Role::try_parse_wire("root") {
    Ok(r) => assert_eq(r, @types.Role::Root)
    Err(e) => fail(e.message())
  }
  match @types.Role::try_parse_wire("tl") {
    Ok(r) => assert_eq(r, @types.Role::TL)
    Err(e) => fail(e.message())
  }
  match @types.Role::try_parse_wire("dev") {
    Ok(r) => assert_eq(r, @types.Role::Dev)
    Err(e) => fail(e.message())
  }
  match @types.Role::try_parse_wire("worker") {
    Ok(r) => assert_eq(r, @types.Role::Worker)
    Err(e) => fail(e.message())
  }
}

///|
test "Role try_parse_wire round-trips to_wire_string for all roles" {
  let roles : Array[@types.Role] = [
    @types.Role::Root,
    @types.Role::TL,
    @types.Role::Dev,
    @types.Role::Worker,
  ]
  for r in roles {
    match @types.Role::try_parse_wire(r.to_wire_string()) {
      Ok(parsed) => assert_eq(parsed, r)
      Err(e) => fail(e.message())
    }
  }
}

///|
test "Role try_parse_wire rejects unknown strings with config_error messages" {
  match @types.Role::try_parse_wire("TL") {
    Err(e) => assert_eq(e.message(), "config error: unknown role: TL")
    Ok(_) => fail("expected unknown role error for TL")
  }
  match @types.Role::try_parse_wire("") {
    Err(e) => assert_eq(e.message(), "config error: unknown role: ")
    Ok(_) => fail("expected unknown role error for empty")
  }
}

///|
test "Role parse_wire agrees with try_parse_wire on every wire string" {
  let wires = ["root", "tl", "dev", "worker"]
  for w in wires {
    match @types.Role::try_parse_wire(w) {
      Ok(expected) => assert_eq(@types.Role::parse_wire(w), expected)
      Err(e) => fail(e.message())
    }
  }
}

///|
test "Role parse_wire raises on unknown strings matching try_parse_wire error" {
  let unknowns = ["TL", "Worker", "", "ROOT", "unknown"]
  for s in unknowns {
    let parse_wire_result = try? @types.Role::parse_wire(s)
    match (parse_wire_result, @types.Role::try_parse_wire(s)) {
      (Err(raised), Err(expected)) =>
        assert_eq(raised.message(), expected.message())
      (Ok(_), _) => fail("parse_wire should have raised for: " + s)
      (Err(_), Ok(_)) =>
        fail("try_parse_wire returned Ok but parse_wire raised for: " + s)
    }
  }
}

///|
test "AgentType to_wire_string encodes all variants" {
  assert_eq(@types.AgentType::Claude.to_wire_string(), "claude")
  assert_eq(@types.AgentType::Gemini.to_wire_string(), "gemini")
  assert_eq(@types.AgentType::MoonPilot.to_wire_string(), "moon_pilot")
  assert_eq(@types.AgentType::Codex.to_wire_string(), "codex")
  assert_eq(@types.AgentType::CursorAgent.to_wire_string(), "cursor_agent")
}

///|
test "AgentType try_parse_wire accepts canonical wire strings" {
  match @types.AgentType::try_parse_wire("claude") {
    Ok(t) => assert_eq(t, @types.AgentType::Claude)
    Err(e) => fail(e.message())
  }
  match @types.AgentType::try_parse_wire("gemini") {
    Ok(t) => assert_eq(t, @types.AgentType::Gemini)
    Err(e) => fail(e.message())
  }
  match @types.AgentType::try_parse_wire("moon_pilot") {
    Ok(t) => assert_eq(t, @types.AgentType::MoonPilot)
    Err(e) => fail(e.message())
  }
  match @types.AgentType::try_parse_wire("codex") {
    Ok(t) => assert_eq(t, @types.AgentType::Codex)
    Err(e) => fail(e.message())
  }
  match @types.AgentType::try_parse_wire("cursor_agent") {
    Ok(t) => assert_eq(t, @types.AgentType::CursorAgent)
    Err(e) => fail(e.message())
  }
}

///|
test "AgentType try_parse_wire accepts legacy aliases" {
  match @types.AgentType::try_parse_wire("moonpilot") {
    Ok(t) => assert_eq(t, @types.AgentType::MoonPilot)
    Err(e) => fail(e.message())
  }
  match @types.AgentType::try_parse_wire("cursoragent") {
    Ok(t) => assert_eq(t, @types.AgentType::CursorAgent)
    Err(e) => fail(e.message())
  }
}

///|
test "AgentType try_parse_wire round-trips to_wire_string for all types" {
  let types : Array[@types.AgentType] = [
    @types.AgentType::Claude,
    @types.AgentType::Gemini,
    @types.AgentType::MoonPilot,
    @types.AgentType::Codex,
    @types.AgentType::CursorAgent,
  ]
  for t in types {
    match @types.AgentType::try_parse_wire(t.to_wire_string()) {
      Ok(parsed) => assert_eq(parsed, t)
      Err(e) => fail(e.message())
    }
  }
}

///|
test "AgentType try_parse_wire rejects unknown strings with config_error messages" {
  match @types.AgentType::try_parse_wire("unknown_bot") {
    Err(e) =>
      assert_eq(e.message(), "config error: unknown agent_type: unknown_bot")
    Ok(_) => fail("expected unknown agent_type")
  }
}

///|
test "AgentType parse_wire agrees with try_parse_wire on canonical and alias strings" {
  let inputs = [
    "claude", "gemini", "moon_pilot", "moonpilot", "codex", "cursor_agent", "cursoragent",
  ]
  for s in inputs {
    match @types.AgentType::try_parse_wire(s) {
      Ok(expected) => assert_eq(@types.AgentType::parse_wire(s), expected)
      Err(e) => fail(e.message())
    }
  }
}

///|
test "AgentType parse_wire raises on unknown strings matching try_parse_wire error" {
  let unknowns = ["Claude", "MoonPilot", "", "gpt4", "CODEX"]
  for s in unknowns {
    let parse_wire_result = try? @types.AgentType::parse_wire(s)
    match (parse_wire_result, @types.AgentType::try_parse_wire(s)) {
      (Err(raised), Err(expected)) =>
        assert_eq(raised.message(), expected.message())
      (Ok(_), _) => fail("parse_wire should have raised for: " + s)
      (Err(_), Ok(_)) =>
        fail("try_parse_wire returned Ok but parse_wire raised for: " + s)
    }
  }
}
