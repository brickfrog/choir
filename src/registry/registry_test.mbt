///|
test "registry insert and get" {
  let reg = @registry.AgentRegistry::new()
  let agent : @types.Agent = {
    agent_id: "main.feat",
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Gemini,
    parent: Some("root"),
    workspace: ".choir/worktrees/feat",
    branch: "main.feat",
    terminal_target: None,
    host: @types.Host::Local,
    spawn_depth: 0,
    state: @types.AgentState::Active,
  }
  ignore(try? reg.insert(agent))
  let found = try? reg.get("main.feat")
  assert_true(found is Ok(_))
}

///|
test "registry duplicate insert fails" {
  let reg = @registry.AgentRegistry::new()
  let agent : @types.Agent = {
    agent_id: "main.dup",
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Claude,
    parent: None,
    workspace: ".choir/worktrees/dup",
    branch: "main.dup",
    terminal_target: None,
    host: @types.Host::Local,
    spawn_depth: 0,
    state: @types.AgentState::Active,
  }
  ignore(try? reg.insert(agent))
  let result = try? reg.insert(agent)
  assert_true(result is Err(_))
}

///|
test "registry upsert refreshes existing agent metadata" {
  let reg = @registry.AgentRegistry::new()
  let agent : @types.Agent = {
    agent_id: "main.refresh",
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Claude,
    parent: Some("root"),
    workspace: ".choir/worktrees/refresh-a",
    branch: "main.refresh",
    terminal_target: @types.LocalTarget::parse("zellij-tab:choir:refresh-a"),
    host: @types.Host::Local,
    spawn_depth: 0,
    state: @types.AgentState::Active,
  }
  let refreshed_first = reg.upsert(agent)
  assert_false(refreshed_first)
  let refreshed_second = reg.upsert({
    ..agent,
    workspace: ".choir/worktrees/refresh-b",
    terminal_target: @types.LocalTarget::parse("zellij-tab:choir:refresh-b"),
  })
  assert_true(refreshed_second)
  try reg.get("main.refresh") catch {
    _ => fail("expected refreshed agent")
  } noraise {
    found => {
      assert_eq(found.workspace, ".choir/worktrees/refresh-b")
      @debug.assert_eq(
        found.terminal_target,
        @types.LocalTarget::parse("zellij-tab:choir:refresh-b"),
      )
    }
  }
}

///|
test "registry get parent" {
  let reg = @registry.AgentRegistry::new()
  let parent : @types.Agent = {
    agent_id: "root",
    role: @types.Role::TL,
    agent_type: @types.AgentType::Claude,
    parent: None,
    workspace: ".",
    branch: "main",
    terminal_target: None,
    host: @types.Host::Local,
    spawn_depth: 0,
    state: @types.AgentState::Active,
  }
  let child : @types.Agent = {
    agent_id: "main.child",
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Gemini,
    parent: Some("root"),
    workspace: ".choir/worktrees/child",
    branch: "main.child",
    terminal_target: None,
    host: @types.Host::Local,
    spawn_depth: 0,
    state: @types.AgentState::Active,
  }
  ignore(try? reg.insert(parent))
  ignore(try? reg.insert(child))
  let found_parent = try? reg.get_parent("main.child")
  match found_parent {
    Ok(p) => assert_eq(p.agent_id, "root")
    Err(_) => fail("expected parent")
  }
}

///|
test "registry children" {
  let reg = @registry.AgentRegistry::new()
  let parent : @types.Agent = {
    agent_id: "root",
    role: @types.Role::TL,
    agent_type: @types.AgentType::Claude,
    parent: None,
    workspace: ".",
    branch: "main",
    terminal_target: None,
    host: @types.Host::Local,
    spawn_depth: 0,
    state: @types.AgentState::Active,
  }
  let child1 : @types.Agent = {
    agent_id: "main.a",
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Gemini,
    parent: Some("root"),
    workspace: ".choir/worktrees/a",
    branch: "main.a",
    terminal_target: None,
    host: @types.Host::Local,
    spawn_depth: 0,
    state: @types.AgentState::Active,
  }
  let child2 : @types.Agent = {
    agent_id: "main.b",
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Gemini,
    parent: Some("root"),
    workspace: ".choir/worktrees/b",
    branch: "main.b",
    terminal_target: None,
    host: @types.Host::Local,
    spawn_depth: 0,
    state: @types.AgentState::Active,
  }
  ignore(try? reg.insert(parent))
  ignore(try? reg.insert(child1))
  ignore(try? reg.insert(child2))
  let kids = reg.children("root")
  assert_eq(kids.length(), 2)
}

///|
test "registry set state valid transitions" {
  let reg = @registry.AgentRegistry::new()
  let agent : @types.Agent = {
    agent_id: "main.test",
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Gemini,
    parent: None,
    workspace: ".",
    branch: "main.test",
    terminal_target: None,
    host: @types.Host::Local,
    spawn_depth: 0,
    state: @types.AgentState::Spawning,
  }
  ignore(try? reg.insert(agent))

  // Spawning -> Active
  let res = try? reg.set_state("main.test", @types.AgentState::Active)
  assert_true(res is Ok(_))
  try reg.get("main.test") catch {
    _ => fail("expected agent")
  } noraise {
    a => assert_eq(a.state, @types.AgentState::Active)
  }

  // Active -> Completing
  let res2 = try? reg.set_state("main.test", @types.AgentState::Completing)
  assert_true(res2 is Ok(_))

  // Completing -> Done
  let res3 = try? reg.set_state("main.test", @types.AgentState::Done)
  assert_true(res3 is Ok(_))

  // Test Active -> Failed and Failed -> Done
  let agent2 : @types.Agent = {
    ..agent,
    agent_id: "main.fail",
    state: @types.AgentState::Active,
  }
  ignore(try? reg.insert(agent2))

  let res4 = try? reg.set_state("main.fail", @types.AgentState::Failed)
  assert_true(res4 is Ok(_))

  let res5 = try? reg.set_state("main.fail", @types.AgentState::Done)
  assert_true(res5 is Ok(_))
}

///|
test "registry set state invalid transition" {
  let reg = @registry.AgentRegistry::new()
  let agent : @types.Agent = {
    agent_id: "main.test",
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Gemini,
    parent: None,
    workspace: ".",
    branch: "main.test",
    terminal_target: None,
    host: @types.Host::Local,
    spawn_depth: 0,
    state: @types.AgentState::Spawning,
  }
  ignore(try? reg.insert(agent))

  // Spawning -> Done (invalid)
  let res = try? reg.set_state("main.test", @types.AgentState::Done)
  assert_true(res is Err(_))
}

///|
test "registry set alive" {
  let reg = @registry.AgentRegistry::new()
  let agent : @types.Agent = {
    agent_id: "main.test",
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Gemini,
    parent: None,
    workspace: ".",
    branch: "main.test",
    terminal_target: None,
    host: @types.Host::Local,
    spawn_depth: 0,
    state: @types.AgentState::Active,
  }
  ignore(try? reg.insert(agent))

  let res = try? reg.set_alive("main.test", false)
  assert_true(res is Ok(_))

  let res_err = try? reg.set_alive("nonexistent", false)
  assert_true(res_err is Err(_))
}

///|
test "registry active agents" {
  let reg = @registry.AgentRegistry::new()
  let a1 : @types.Agent = {
    agent_id: "a1",
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Gemini,
    parent: None,
    workspace: ".",
    branch: "a1",
    terminal_target: None,
    host: @types.Host::Local,
    spawn_depth: 0,
    state: @types.AgentState::Spawning,
  }
  let a2 : @types.Agent = {
    ..a1,
    agent_id: "a2",
    state: @types.AgentState::Active,
  }
  let a3 : @types.Agent = {
    ..a1,
    agent_id: "a3",
    state: @types.AgentState::Completing,
  }

  ignore(try? reg.insert(a1))
  ignore(try? reg.insert(a2))
  ignore(try? reg.insert(a3))

  let active = reg.active_agents()
  assert_eq(active.length(), 1)
  assert_eq(active[0].agent_id, "a2")
}

///|
test "registry by role" {
  let reg = @registry.AgentRegistry::new()
  let a1 : @types.Agent = {
    agent_id: "a1",
    role: @types.Role::TL,
    agent_type: @types.AgentType::Gemini,
    parent: None,
    workspace: ".",
    branch: "a1",
    terminal_target: None,
    host: @types.Host::Local,
    spawn_depth: 0,
    state: @types.AgentState::Active,
  }
  let a2 : @types.Agent = { ..a1, agent_id: "a2", role: @types.Role::Dev }
  let a3 : @types.Agent = { ..a1, agent_id: "a3", role: @types.Role::Dev }

  ignore(try? reg.insert(a1))
  ignore(try? reg.insert(a2))
  ignore(try? reg.insert(a3))

  let tl_agents = reg.by_role(@types.Role::TL)
  assert_eq(tl_agents.length(), 1)
  assert_eq(tl_agents[0].agent_id, "a1")

  let dev_agents = reg.by_role(@types.Role::Dev)
  assert_eq(dev_agents.length(), 2)
}

///|
test "mutex registry acquire and status" {
  let reg = @registry.MutexRegistry::new()
  let (acquired, queue_position) = reg.acquire("README", "agent-a", 300L, 10L)
  assert_true(acquired)
  assert_eq(queue_position, 0)
  let (holder, queue) = reg.status("README")
  @debug.assert_eq(holder, Some("agent-a"))
  assert_eq(queue.length(), 0)
}

///|
test "mutex registry acquire is fifo and idempotent" {
  let reg = @registry.MutexRegistry::new()
  let first = reg.acquire("README", "agent-a", 300L, 10L)
  let second = reg.acquire("README", "agent-b", 300L, 11L)
  let third = reg.acquire("README", "agent-c", 300L, 12L)
  let repeat = reg.acquire("README", "agent-b", 300L, 13L)
  assert_eq(first, (true, 0))
  assert_eq(second, (false, 1))
  assert_eq(third, (false, 2))
  assert_eq(repeat, (false, 1))
  let (holder, queue) = reg.status("README")
  @debug.assert_eq(holder, Some("agent-a"))
  assert_eq(queue.length(), 2)
  assert_eq(queue[0], "agent-b")
  assert_eq(queue[1], "agent-c")
}

///|
test "mutex registry release hands off to next waiter" {
  let reg = @registry.MutexRegistry::new()
  ignore(reg.acquire("README", "agent-a", 300L, 10L))
  ignore(reg.acquire("README", "agent-b", 300L, 11L))
  ignore(reg.acquire("README", "agent-c", 300L, 12L))
  let next = reg.release("README", "agent-a", 15L)
  @debug.assert_eq(next, Some("agent-b"))
  let (holder, queue) = reg.status("README")
  @debug.assert_eq(holder, Some("agent-b"))
  assert_eq(queue.length(), 1)
  assert_eq(queue[0], "agent-c")
  let reacquire = reg.acquire("README", "agent-b", 300L, 20L)
  assert_eq(reacquire, (true, 0))
}

///|
test "mutex registry release removes non-holder from queue" {
  let reg = @registry.MutexRegistry::new()
  ignore(reg.acquire("README", "agent-a", 300L, 10L))
  ignore(reg.acquire("README", "agent-b", 300L, 11L))
  ignore(reg.acquire("README", "agent-c", 300L, 12L))
  let next = reg.release("README", "agent-b", 13L)
  @debug.assert_eq(next, None)
  let (holder, queue) = reg.status("README")
  @debug.assert_eq(holder, Some("agent-a"))
  assert_eq(queue.length(), 1)
  assert_eq(queue[0], "agent-c")
}

///|
test "mutex registry expire clears stale waiters on reacquire" {
  let reg = @registry.MutexRegistry::new()
  ignore(reg.acquire("README", "agent-a", 5L, 10L))
  ignore(reg.acquire("README", "agent-b", 5L, 11L))
  let result = reg.acquire("README", "agent-c", 5L, 17L)
  assert_eq(result, (true, 0))
  let (holder, queue) = reg.status("README")
  @debug.assert_eq(holder, Some("agent-c"))
  assert_eq(queue.length(), 0)
}

///|
fn make_active_agent(id : String) -> @types.Agent {
  {
    agent_id: id,
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Gemini,
    parent: None,
    workspace: ".",
    branch: id,
    terminal_target: None,
    host: @types.Host::Local,
    spawn_depth: 0,
    state: @types.AgentState::Active,
  }
}

///|
test "registry Active → Suspended → Active round-trip" {
  let reg = @registry.AgentRegistry::new()
  ignore(try? reg.insert(make_active_agent("tl.leaf")))
  let r1 = try? reg.set_state("tl.leaf", @types.AgentState::Suspended)
  assert_true(r1 is Ok(_))
  try reg.get("tl.leaf") catch {
    _ => fail("expected agent")
  } noraise {
    a => assert_eq(a.state, @types.AgentState::Suspended)
  }
  let r2 = try? reg.set_state("tl.leaf", @types.AgentState::Active)
  assert_true(r2 is Ok(_))
  try reg.get("tl.leaf") catch {
    _ => fail("expected agent")
  } noraise {
    a => assert_eq(a.state, @types.AgentState::Active)
  }
}

///|
test "registry Suspended → Failed is rejected" {
  let reg = @registry.AgentRegistry::new()
  ignore(try? reg.insert(make_active_agent("tl.leaf2")))
  ignore(try? reg.set_state("tl.leaf2", @types.AgentState::Suspended))
  let r = try? reg.set_state("tl.leaf2", @types.AgentState::Failed)
  assert_true(r is Err(_))
}

///|
test "registry Suspended → Done is rejected" {
  let reg = @registry.AgentRegistry::new()
  ignore(try? reg.insert(make_active_agent("tl.leaf3")))
  ignore(try? reg.set_state("tl.leaf3", @types.AgentState::Suspended))
  let r = try? reg.set_state("tl.leaf3", @types.AgentState::Done)
  assert_true(r is Err(_))
}

///|
test "registry Spawning → Suspended is rejected" {
  let reg = @registry.AgentRegistry::new()
  let agent : @types.Agent = {
    ..make_active_agent("tl.leaf4"),
    state: @types.AgentState::Spawning,
  }
  ignore(try? reg.insert(agent))
  let r = try? reg.set_state("tl.leaf4", @types.AgentState::Suspended)
  assert_true(r is Err(_))
}

///|
test "mutex registry expire hands off to queued waiter" {
  let reg = @registry.MutexRegistry::new()
  ignore(reg.acquire("README", "agent-a", 5L, 10L))
  ignore(reg.acquire("README", "agent-b", 5L, 11L))
  reg.expire(16L)
  let (holder, queue) = reg.status("README")
  @debug.assert_eq(holder, Some("agent-b"))
  assert_eq(queue.length(), 0)
}

///|
/// Regression: release() used to set acquired_sec=0L on handoff, which
/// made `now - 0L > ttl_sec` trivially true for any Unix timestamp —
/// the new holder was expire-eligible on the very next tick. Assert
/// that a fresh handoff survives expire() under real Unix-scale `now`
/// values within the TTL.
test "mutex registry release handoff survives expire within ttl" {
  let reg = @registry.MutexRegistry::new()
  let now_acquire : Int64 = 1700000000L
  let ttl : Int64 = 120L
  ignore(reg.acquire("README", "agent-a", ttl, now_acquire))
  ignore(reg.acquire("README", "agent-b", ttl, now_acquire + 1L))
  let next = reg.release("README", "agent-a", now_acquire + 2L)
  @debug.assert_eq(next, Some("agent-b"))
  reg.expire(now_acquire + 3L)
  let (holder, _) = reg.status("README")
  @debug.assert_eq(holder, Some("agent-b"))
  reg.expire(now_acquire + ttl)
  let (holder_still, _) = reg.status("README")
  @debug.assert_eq(holder_still, Some("agent-b"))
}

///|
/// Regression: merge_pr used to release only in the Ok arm, leaking the
/// mutex on merge failure until expire() cleared it. Exercised indirectly
/// via `interpret_merge_pr_merge_host` in merge_pr_test.mbt; this unit-
/// level test confirms release() is agnostic to why the caller releases.
test "mutex registry release succeeds on any holder state" {
  let reg = @registry.MutexRegistry::new()
  ignore(reg.acquire("README", "agent-a", 120L, 1700000000L))
  let next = reg.release("README", "agent-a", 1700000001L)
  @debug.assert_eq(next, None)
  let (holder, _) = reg.status("README")
  @debug.assert_eq(holder, None)
}
