///|
async fn local_mock_runner(cmds : Array[@workspace.Command]) -> Array[Int] {
  @async.sleep(0)
  let statuses = []
  for _ in cmds {
    statuses.push(0)
  }
  statuses
}

///|
async test "cancel_wave force=false clean" {
  let reg = @registry.AgentRegistry::new()
  let agent1 : @types.Agent = {
    agent_id: @types.AgentId("main.leaf1"),
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Gemini,
    parent: Some("main"),
    workspace: "/tmp/.choir/worktrees/w1",
    branch: "b1",
    terminal_target: (None : @types.LocalTarget?),
    host: @types.Host::Local,
    state: @types.AgentState::Active,
    spawn_depth: 0,
  }
  let _ = reg.insert(agent1)
  let ps = @poller.PollerState::new()

  let req = ToolRequest::CancelWave({ force: false })
  let resp = dispatch(
    req,
    registry=Some(reg),
    poller_state=Some(ps),
    caller_id=Some("main"),
    runner=local_mock_runner,
  )

  match resp {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      match map.get("status") {
        Some(Json::String("ok")) => ()
        _ => fail("expected status: ok")
      }
      match map.get("cancelled") {
        Some(Json::Number(n, ..)) => assert_eq(n, 1.0)
        _ => fail("expected cancelled: 1")
      }
    }
    _ => fail("expected response: Ok")
  }

  // Verify agent state is Failed
  match reg.get("main.leaf1") {
    Ok(a) => assert_eq(a.state, @types.AgentState::Failed)
    Err(_) => fail("expected agent1 in registry")
  }
}

///|
async test "cancel_wave cancels spawning agent" {
  let reg = @registry.AgentRegistry::new()
  let agent1 : @types.Agent = {
    agent_id: @types.AgentId("main.spawning1"),
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Gemini,
    parent: Some("main"),
    workspace: "/tmp/.choir/worktrees/w2",
    branch: "b2",
    terminal_target: (None : @types.LocalTarget?),
    host: @types.Host::Local,
    state: @types.AgentState::Spawning,
    spawn_depth: 0,
  }
  let _ = reg.insert(agent1)

  let req = ToolRequest::CancelWave({ force: false })
  let resp = dispatch(
    req,
    registry=Some(reg),
    caller_id=Some("main"),
    runner=local_mock_runner,
  )

  match resp {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      match map.get("cancelled") {
        Some(Json::Number(n, ..)) => assert_eq(n, 1.0)
        _ => fail("expected cancelled: 1")
      }
    }
    _ => fail("expected response: Ok")
  }

  // Verify agent state is Failed
  match reg.get("main.spawning1") {
    Ok(a) => assert_eq(a.state, @types.AgentState::Failed)
    Err(_) => fail("expected spawning1 in registry")
  }
}

///|
async test "cancel_wave force=false blocked by PR" {
  let reg = @registry.AgentRegistry::new()
  let agent1 : @types.Agent = {
    agent_id: @types.AgentId("main.leaf1"),
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Gemini,
    parent: Some("main"),
    workspace: "/tmp/.choir/worktrees/w1",
    branch: "b1",
    terminal_target: (None : @types.LocalTarget?),
    host: @types.Host::Local,
    state: @types.AgentState::Active,
    spawn_depth: 0,
  }
  let _ = reg.insert(agent1)

  let ps = @poller.PollerState::new()
  ps.track_recovered(
    123,
    "main.leaf1",
    "b1",
    "main",
    "url",
    100L,
    ChangesRequested,
    "body",
    "sha",
    false,
  )

  let req = ToolRequest::CancelWave({ force: false })
  let resp = dispatch(
    req,
    registry=Some(reg),
    poller_state=Some(ps),
    caller_id=Some("main"),
    runner=local_mock_runner,
  )

  match resp {
    @types.Response::Err(msg) =>
      if not(msg.contains("blocked by PR #123")) {
        fail("expected blocked error message, got: " + msg)
      }
    _ => fail("expected response: Err")
  }

  // Verify agent state is still Active
  match reg.get("main.leaf1") {
    Ok(a) => assert_eq(a.state, @types.AgentState::Active)
    Err(_) => fail("expected agent1 in registry")
  }
}

///|
async test "cancel_wave force=true overrides PR block" {
  let reg = @registry.AgentRegistry::new()
  let agent1 : @types.Agent = {
    agent_id: @types.AgentId("main.leaf1"),
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Gemini,
    parent: Some("main"),
    workspace: "/tmp/.choir/worktrees/w1",
    branch: "b1",
    terminal_target: (None : @types.LocalTarget?),
    host: @types.Host::Local,
    state: @types.AgentState::Active,
    spawn_depth: 0,
  }
  let _ = reg.insert(agent1)

  let ps = @poller.PollerState::new()
  ps.track_recovered(
    123,
    "main.leaf1",
    "b1",
    "main",
    "url",
    100L,
    ChangesRequested,
    "body",
    "sha",
    false,
  )

  let req = ToolRequest::CancelWave({ force: true })
  let resp = dispatch(
    req,
    registry=Some(reg),
    poller_state=Some(ps),
    caller_id=Some("main"),
    runner=local_mock_runner,
  )

  match resp {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      match map.get("cancelled") {
        Some(Json::Number(n, ..)) => assert_eq(n, 1.0)
        _ => fail("expected cancelled: 1")
      }
    }
    _ => fail("expected response: Ok")
  }

  // Verify agent state is Failed
  match reg.get("main.leaf1") {
    Ok(a) => assert_eq(a.state, @types.AgentState::Failed)
    Err(_) => fail("expected agent1 in registry")
  }

  // Verify PR is untracked
  match ps.get(123) {
    Some(_) => fail("expected PR 123 to be untracked")
    None => ()
  }
}
