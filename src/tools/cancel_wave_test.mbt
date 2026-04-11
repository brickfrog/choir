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
  ignore(try? reg.insert(agent1))
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
  try reg.get("main.leaf1") catch {
    _ => fail("expected agent1 in registry")
  } noraise {
    a => assert_eq(a.state, @types.AgentState::Failed)
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
  ignore(try? reg.insert(agent1))

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
  try reg.get("main.spawning1") catch {
    _ => fail("expected spawning1 in registry")
  } noraise {
    a => assert_eq(a.state, @types.AgentState::Failed)
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
  ignore(try? reg.insert(agent1))

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
    @poller.CiRollupStatus::Unknown,
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
      if !msg.contains("blocked by PR #123") {
        fail("expected blocked error message, got: " + msg)
      }
    _ => fail("expected response: Err")
  }

  // Verify agent state is still Active
  try reg.get("main.leaf1") catch {
    _ => fail("expected agent1 in registry")
  } noraise {
    a => assert_eq(a.state, @types.AgentState::Active)
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
  ignore(try? reg.insert(agent1))

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
    @poller.CiRollupStatus::Unknown,
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
  try reg.get("main.leaf1") catch {
    _ => fail("expected agent1 in registry")
  } noraise {
    a => assert_eq(a.state, @types.AgentState::Failed)
  }

  // Verify PR is untracked
  match ps.get(123) {
    Some(_) => fail("expected PR 123 to be untracked")
    None => ()
  }
}

///|
test "cancel_wave_resolved_caller_id defaults to main" {
  assert_eq(cancel_wave_resolved_caller_id(None), "main")
  assert_eq(cancel_wave_resolved_caller_id(Some("main.tl")), "main.tl")
}

///|
test "cancel_wave_non_terminal_agents keeps spawning and active only" {
  let base : @types.Agent = {
    agent_id: @types.AgentId("main.s"),
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Claude,
    parent: Some("main"),
    workspace: "/w",
    branch: "b",
    terminal_target: (None : @types.LocalTarget?),
    host: @types.Host::Local,
    spawn_depth: 0,
    state: @types.AgentState::Spawning,
  }
  let active = {
    ..base,
    agent_id: @types.AgentId("main.a"),
    state: @types.AgentState::Active,
  }
  let done = {
    ..base,
    agent_id: @types.AgentId("main.d"),
    state: @types.AgentState::Done,
  }
  let got = cancel_wave_non_terminal_agents([base, active, done])
  assert_eq(got.length(), 2)
  assert_eq(got[0].agent_id.to_string(), "main.s")
  assert_eq(got[1].agent_id.to_string(), "main.a")
}

///|
test "cancel_wave_poller_block_message matches dispatch wording" {
  assert_eq(
    cancel_wave_poller_block_message("main.leaf", 99),
    "cancel_wave: agent main.leaf is blocked by PR #99 with changes requested -- use force=true to override",
  )
}

///|
test "cancel_wave_preflight_block_message force skips gate" {
  let agent : @types.Agent = {
    agent_id: @types.AgentId("main.leaf"),
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Claude,
    parent: Some("main"),
    workspace: "/w",
    branch: "b",
    terminal_target: (None : @types.LocalTarget?),
    host: @types.Host::Local,
    spawn_depth: 0,
    state: @types.AgentState::Active,
  }
  let ps = @poller.PollerState::new()
  ps.track_recovered(
    5,
    "main.leaf",
    "b",
    "main",
    "url",
    0L,
    @poller.ReviewState::ChangesRequested,
    "",
    "",
    @poller.CiRollupStatus::Unknown,
    false,
  )
  assert_eq(cancel_wave_preflight_block_message(true, [agent], Some(ps)), None)
}

///|
test "cancel_wave_preflight_block_message none without poller" {
  let agent : @types.Agent = {
    agent_id: @types.AgentId("main.leaf"),
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Claude,
    parent: Some("main"),
    workspace: "/w",
    branch: "b",
    terminal_target: (None : @types.LocalTarget?),
    host: @types.Host::Local,
    spawn_depth: 0,
    state: @types.AgentState::Active,
  }
  assert_eq(cancel_wave_preflight_block_message(false, [agent], None), None)
}

///|
test "cancel_wave_preflight_block_message first agent wins" {
  let a1 : @types.Agent = {
    agent_id: @types.AgentId("main.first"),
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Claude,
    parent: Some("main"),
    workspace: "/w",
    branch: "b",
    terminal_target: (None : @types.LocalTarget?),
    host: @types.Host::Local,
    spawn_depth: 0,
    state: @types.AgentState::Active,
  }
  let a2 : @types.Agent = {
    agent_id: @types.AgentId("main.second"),
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Claude,
    parent: Some("main"),
    workspace: "/w",
    branch: "b",
    terminal_target: (None : @types.LocalTarget?),
    host: @types.Host::Local,
    spawn_depth: 0,
    state: @types.AgentState::Active,
  }
  let ps = @poller.PollerState::new()
  ps.track_recovered(
    1,
    "main.first",
    "b",
    "main",
    "u",
    0L,
    @poller.ReviewState::ChangesRequested,
    "",
    "",
    @poller.CiRollupStatus::Unknown,
    false,
  )
  ps.track_recovered(
    2,
    "main.second",
    "b",
    "main",
    "u",
    0L,
    @poller.ReviewState::ChangesRequested,
    "",
    "",
    @poller.CiRollupStatus::Unknown,
    false,
  )
  match cancel_wave_preflight_block_message(false, [a1, a2], Some(ps)) {
    Some(msg) => assert_true(msg.contains("main.first") && msg.contains("#1"))
    None => fail("expected block")
  }
}

///|
test "cancel_wave_ok_response shape" {
  match cancel_wave_ok_response(3) {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      assert_eq(map.get("status"), Some(String::to_json("ok")))
      assert_eq(map.get("cancelled"), Some(Int::to_json(3)))
    }
    _ => fail("expected ok")
  }
}

///|
test "cancel_wave_per_agent_host_steps ordering" {
  let steps = cancel_wave_per_agent_host_steps()
  assert_eq(steps.length(), 4)
  assert_eq(steps[0], CancelWavePerAgentHostStep::PaneClose)
  assert_eq(steps[1], CancelWavePerAgentHostStep::WorktreeRemove)
  assert_eq(steps[2], CancelWavePerAgentHostStep::RegistryFailed)
  assert_eq(steps[3], CancelWavePerAgentHostStep::PollerUntrack)
}

///|
async test "interpret_cancel_wave err when no registry" {
  let got = interpret_cancel_wave(
    { force: false },
    Some("main"),
    "/tmp",
    None,
    None,
    mock_runner_all_ok,
  )
  match got {
    @types.Response::Err(msg) => assert_eq(msg, "no agent registry available")
    _ => fail("expected no-registry err")
  }
}

///|
