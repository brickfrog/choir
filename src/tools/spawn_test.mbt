///|
test "spawn_worker_ok_response matches spawned envelope" {
  match spawn_worker_ok_response("main.w1") {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      @debug.assert_eq(map.get("status"), Some(String::to_json("spawned")))
      @debug.assert_eq(map.get("agent_id"), Some(String::to_json("main.w1")))
      @debug.assert_eq(map.get("agent_ids"), Some(String::to_json("main.w1")))
    }
    _ => fail("expected ok")
  }
}

///|
test "spawn_worker_plan builds inline worker spec registry row and response" {
  let worker_args : WorkerSpawnArgs = {
    task: "t",
    task_contract: { ..@types.TaskContract::empty(), goal: "t" },
    caller_id: "main.tl",
    slug: "w1",
    agent_type: @types.AgentType::MoonPilot,
  }
  let plan = spawn_worker_plan(worker_args, "develop", "sess", "/proj")
  assert_eq(plan.agent_id, "develop.w1")
  assert_eq(plan.spec.parent_branch, "develop")
  assert_eq(plan.spec.slug, "w1")
  assert_eq(plan.spec.role, @types.Role::Worker)
  assert_eq(plan.spec.isolation, @types.IsolationMode::Inline)
  assert_eq(plan.spec.parent_id, "main.tl")
  assert_eq(plan.spec.spawn_depth, 0)
  let expected_tt = @workspace.local_target_for(
    "sess",
    "w1",
    @types.IsolationMode::Inline,
  )
  assert_eq(plan.terminal_target, expected_tt)
  assert_eq(plan.registry_agent.role, @types.Role::Worker)
  assert_eq(plan.registry_agent.agent_type, @types.AgentType::MoonPilot)
  assert_eq(plan.registry_agent.workspace, "/proj")
  assert_eq(plan.registry_agent.branch, "develop.w1")
  assert_eq(plan.registry_agent.state, @types.AgentState::Active)
  match plan.registry_agent.parent {
    Some(p) => assert_eq(p, "main.tl")
    None => fail("expected parent")
  }
  match plan.ok_response {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      @debug.assert_eq(map.get("agent_id"), Some(String::to_json("develop.w1")))
    }
    _ => fail("expected ok")
  }
}

///|
async fn mock_capture_origin_main(_cmd : @workspace.Command) -> (Int, String) {
  @async.sleep(0)
  (0, "origin/main\n")
}

///|
async test "interpret_spawn_worker registers agent on success" {
  let worker_args : WorkerSpawnArgs = {
    task: "unit",
    task_contract: { ..@types.TaskContract::empty(), goal: "unit" },
    caller_id: "main.tl",
    slug: "w1",
    agent_type: @types.AgentType::Claude,
  }
  let reg = @registry.AgentRegistry::new()
  let got = interpret_spawn_worker(
    worker_args,
    "/tmp/p",
    "choir",
    mock_runner_all_ok,
    mock_capture_origin_main,
    Some(reg),
  )
  match got {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      @debug.assert_eq(map.get("status"), Some(String::to_json("spawned")))
    }
    _ => fail("expected ok")
  }
  try reg.get("main.w1") catch {
    _ => fail("expected worker in registry")
  } noraise {
    a => {
      assert_eq(a.role, @types.Role::Worker)
      assert_eq(a.workspace, "/tmp/p")
    }
  }
}

///|
test "spawn_remote_plan builds dev claude worktree spec and spawned response" {
  let spawn_args : RemoteSpawnArgs = {
    task: "remote-task",
    task_contract: { ..@types.TaskContract::empty(), goal: "remote-task" },
    caller_id: "main.tl",
    slug: "leaf-a",
    parent_branch: "main",
    ssh_target: "user@remote.example",
    repo_url: "https://github.com/o/r.git",
    tcp_addr: "192.168.1.10:7777",
    parent_session_id: Some("sess-1"),
  }
  let plan = spawn_remote_plan(spawn_args)
  assert_eq(plan.spec.slug, "leaf-a")
  assert_eq(plan.spec.role, @types.Role::Dev)
  assert_eq(plan.spec.agent_type, @types.AgentType::Claude)
  assert_eq(plan.spec.task, "remote-task")
  assert_eq(plan.spec.isolation, @types.IsolationMode::Worktree)
  assert_eq(plan.spec.parent_id, "main.tl")
  assert_eq(plan.spec.parent_branch, "main")
  assert_eq(plan.spec.reuse_workspace, false)
  @debug.assert_eq(plan.spec.workspace_slug, None)
  @debug.assert_eq(plan.spec.reuse_git_branch, None)
  assert_eq(plan.spec.spawn_depth, 0)
  match plan.ok_response {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      @debug.assert_eq(map.get("status"), Some(String::to_json("spawned")))
      @debug.assert_eq(
        map.get("agent_id"),
        Some(String::to_json("main.leaf-a")),
      )
      @debug.assert_eq(map.get("slug"), Some(String::to_json("leaf-a")))
      @debug.assert_eq(
        map.get("host"),
        Some(String::to_json("user@remote.example")),
      )
    }
    _ => fail("expected ok response")
  }
}

///|
async test "interpret_spawn_remote returns plan ok when runner succeeds" {
  let spawn_args : RemoteSpawnArgs = {
    task: "t",
    task_contract: { ..@types.TaskContract::empty(), goal: "t" },
    caller_id: "pb.caller",
    slug: "s1",
    parent_branch: "pb",
    ssh_target: "h",
    repo_url: "u",
    tcp_addr: "a",
    parent_session_id: None,
  }
  let got = interpret_spawn_remote(
    spawn_args, mock_runner_all_ok, mock_capture_empty,
  )
  match got {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      @debug.assert_eq(map.get("status"), Some(String::to_json("spawned")))
      @debug.assert_eq(map.get("agent_id"), Some(String::to_json("pb.s1")))
      @debug.assert_eq(map.get("slug"), Some(String::to_json("s1")))
      @debug.assert_eq(map.get("host"), Some(String::to_json("h")))
    }
    _ => fail("expected ok")
  }
}

///|
async test "interpret_spawn_remote returns err when run_strict fails" {
  let spawn_args : RemoteSpawnArgs = {
    task: "t",
    task_contract: { ..@types.TaskContract::empty(), goal: "t" },
    caller_id: "x",
    slug: "y",
    parent_branch: "main",
    ssh_target: "h",
    repo_url: "u",
    tcp_addr: "a",
    parent_session_id: None,
  }
  let got = interpret_spawn_remote(
    spawn_args, mock_runner_first_fails, mock_capture_empty,
  )
  match got {
    @types.Response::Err(msg) =>
      assert_true(msg.contains("failed") || msg.contains("status"))
    _ => fail("expected err from run_strict")
  }
}

///|
test "spawn_gemini_plan builds dev gemini worktree spec and spawned response" {
  let spawn_args : SpawnGeminiArgs = {
    task: "do the thing",
    task_contract: { ..@types.TaskContract::empty(), goal: "do the thing" },
    caller_id: "main.tl",
    slug: "g1",
    parent_branch: "main",
    parent_session_id: Some("sess-1"),
  }
  let plan = spawn_gemini_plan(spawn_args)
  assert_eq(plan.spec.slug, "g1")
  assert_eq(plan.spec.role, @types.Role::Dev)
  assert_eq(plan.spec.agent_type, @types.AgentType::Gemini)
  assert_eq(plan.spec.task, "do the thing")
  assert_eq(plan.spec.isolation, @types.IsolationMode::Worktree)
  assert_eq(plan.spec.parent_id, "main.tl")
  assert_eq(plan.spec.parent_branch, "main")
  assert_eq(plan.spec.reuse_workspace, false)
  @debug.assert_eq(plan.spec.workspace_slug, None)
  @debug.assert_eq(plan.spec.reuse_git_branch, None)
  assert_eq(plan.spec.spawn_depth, 0)
  match plan.ok_response {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      @debug.assert_eq(map.get("status"), Some(String::to_json("spawned")))
      @debug.assert_eq(map.get("agent_id"), Some(String::to_json("main.g1")))
      @debug.assert_eq(map.get("slug"), Some(String::to_json("g1")))
    }
    _ => fail("expected ok response")
  }
}

///|
async test "interpret_spawn_gemini returns plan ok when runner succeeds" {
  let spawn_args : SpawnGeminiArgs = {
    task: "t",
    task_contract: { ..@types.TaskContract::empty(), goal: "t" },
    caller_id: "pb.caller",
    slug: "gem",
    parent_branch: "pb",
    parent_session_id: None,
  }
  let got = interpret_spawn_gemini(
    spawn_args, "/tmp/p", "choir", mock_runner_all_ok, mock_capture_empty,
  )
  match got {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      @debug.assert_eq(map.get("status"), Some(String::to_json("spawned")))
      @debug.assert_eq(map.get("agent_id"), Some(String::to_json("pb.gem")))
      @debug.assert_eq(map.get("slug"), Some(String::to_json("gem")))
    }
    _ => fail("expected ok")
  }
}

///|
async test "interpret_spawn_gemini returns err when run_strict fails" {
  let spawn_args : SpawnGeminiArgs = {
    task: "t",
    task_contract: { ..@types.TaskContract::empty(), goal: "t" },
    caller_id: "x",
    slug: "y",
    parent_branch: "main",
    parent_session_id: None,
  }
  let got = interpret_spawn_gemini(
    spawn_args, "/tmp/p", "choir", mock_runner_first_fails, mock_capture_empty,
  )
  match got {
    @types.Response::Err(msg) =>
      assert_true(msg.contains("failed") || msg.contains("status"))
    _ => fail("expected err from run_strict")
  }
}

///|
test "ensure_caller_can_spawn rejects callers in Failed state" {
  // Regression: a worker spawned against a Failed parent has no live terminal
  // to receive `notify_parent`; the work output dies in the worker's pane.
  let reg = @registry.AgentRegistry::new()
  ignore(
    reg.upsert({
      agent_id: @types.AgentId("root"),
      role: @types.Role::TL,
      agent_type: @types.AgentType::Claude,
      parent: None,
      workspace: "/proj",
      branch: "main",
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Failed,
    }),
  )
  match ensure_caller_can_spawn("root", Some(reg)) {
    Ok(_) => fail("expected Err for caller in Failed state")
    Err(e) => {
      let msg = e.message()
      assert_true(msg.contains("root"))
      assert_true(msg.contains("terminal state"))
      assert_true(msg.contains("notify_parent"))
    }
  }
}

///|
test "ensure_caller_can_spawn rejects callers in Done state" {
  let reg = @registry.AgentRegistry::new()
  ignore(
    reg.upsert({
      agent_id: @types.AgentId("main.tl"),
      role: @types.Role::TL,
      agent_type: @types.AgentType::Claude,
      parent: None,
      workspace: "/proj",
      branch: "main",
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Done,
    }),
  )
  match ensure_caller_can_spawn("main.tl", Some(reg)) {
    Ok(_) => fail("expected Err for caller in Done state")
    Err(_) => ()
  }
}

///|
test "ensure_caller_can_spawn allows callers in Active state" {
  let reg = @registry.AgentRegistry::new()
  ignore(
    reg.upsert({
      agent_id: @types.AgentId("main.tl"),
      role: @types.Role::TL,
      agent_type: @types.AgentType::Claude,
      parent: None,
      workspace: "/proj",
      branch: "main",
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  match ensure_caller_can_spawn("main.tl", Some(reg)) {
    Ok(_) => ()
    Err(e) => fail("expected Ok for Active caller, got: " + e.message())
  }
}

///|
test "ensure_caller_can_spawn allows callers not in registry (synthesized root path)" {
  // The synthesized root TL agent isn't in the registry until it registers.
  // Pre-registration spawns from a freshly-launched TL session (or test
  // harnesses without a registry) must still go through.
  let reg = @registry.AgentRegistry::new()
  match ensure_caller_can_spawn("user-12345-67890", Some(reg)) {
    Ok(_) => ()
    Err(e) => fail("expected Ok for unregistered caller, got: " + e.message())
  }
}

///|
test "ensure_caller_can_spawn allows None registry (test/non-orchestration paths)" {
  match ensure_caller_can_spawn("anyone", None) {
    Ok(_) => ()
    Err(e) => fail("expected Ok for None registry, got: " + e.message())
  }
}

///|
