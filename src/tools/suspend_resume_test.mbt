///|
fn make_test_registry_with_active_agent(
  agent_id : String,
) -> @registry.AgentRegistry {
  let reg = @registry.AgentRegistry::new()
  let agent : @types.Agent = {
    agent_id,
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Gemini,
    parent: None,
    workspace: ".",
    branch: agent_id,
    terminal_target: None,
    host: @types.Host::Local,
    spawn_depth: 0,
    state: @types.AgentState::Active,
  }
  ignore(try? reg.insert(agent))
  reg
}

///|
async test "interpret_suspend transitions agent to Suspended and returns ok" {
  let reg = make_test_registry_with_active_agent("tl.leaf")
  let resp = interpret_suspend(
    { agent_id: "tl.leaf", reason: "human review needed" },
    Some(reg),
    ".",
    hook_capture=fn(_path, _input, _dir) { (0, "") },
  )
  assert_true(resp.is_ok())
  try reg.get("tl.leaf") catch {
    _ => fail("expected agent after suspend")
  } noraise {
    a => assert_eq(a.state, @types.AgentState::Suspended)
  }
}

///|
async test "interpret_suspend returns error for unknown agent" {
  let reg = @registry.AgentRegistry::new()
  let resp = interpret_suspend(
    { agent_id: "nonexistent", reason: "test" },
    Some(reg),
    ".",
    hook_capture=fn(_path, _input, _dir) { (0, "") },
  )
  assert_false(resp.is_ok())
}

///|
async test "interpret_suspend returns error when no registry" {
  let resp = interpret_suspend(
    { agent_id: "tl.leaf", reason: "test" },
    None,
    ".",
    hook_capture=fn(_path, _input, _dir) { (0, "") },
  )
  assert_false(resp.is_ok())
}

///|
test "interpret_resume transitions agent back to Active and returns ok" {
  let reg = make_test_registry_with_active_agent("tl.leaf")
  ignore(try? reg.set_state("tl.leaf", @types.AgentState::Suspended))
  let resp = interpret_resume({ agent_id: "tl.leaf" }, Some(reg))
  assert_true(resp.is_ok())
  try reg.get("tl.leaf") catch {
    _ => fail("expected agent after resume")
  } noraise {
    a => assert_eq(a.state, @types.AgentState::Active)
  }
}

///|
test "interpret_resume returns error for unknown agent" {
  let reg = @registry.AgentRegistry::new()
  let resp = interpret_resume({ agent_id: "nonexistent" }, Some(reg))
  assert_false(resp.is_ok())
}

///|
test "interpret_resume returns error when no registry" {
  let resp = interpret_resume({ agent_id: "tl.leaf" }, None)
  assert_false(resp.is_ok())
}
