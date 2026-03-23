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
    state: @types.AgentState::Active,
  }
  let _ = reg.insert(agent)
  let found = reg.get("main.feat")
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
    state: @types.AgentState::Active,
  }
  let _ = reg.insert(agent)
  let result = reg.insert(agent)
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
  match reg.get("main.refresh") {
    Ok(found) => {
      assert_eq(found.workspace, ".choir/worktrees/refresh-b")
      assert_eq(
        found.terminal_target,
        @types.LocalTarget::parse("zellij-tab:choir:refresh-b"),
      )
    }
    Err(_) => fail("expected refreshed agent")
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
    state: @types.AgentState::Active,
  }
  let _ = reg.insert(parent)
  let _ = reg.insert(child)
  let found_parent = reg.get_parent("main.child")
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
    state: @types.AgentState::Active,
  }
  let _ = reg.insert(parent)
  let _ = reg.insert(child1)
  let _ = reg.insert(child2)
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
    state: @types.AgentState::Spawning,
  }
  let _ = reg.insert(agent)

  // Spawning -> Active
  let res = reg.set_state("main.test", @types.AgentState::Active)
  assert_true(res is Ok(_))
  match reg.get("main.test") {
    Ok(a) => assert_eq(a.state, @types.AgentState::Active)
    Err(_) => fail("expected agent")
  }

  // Active -> Completing
  let res2 = reg.set_state("main.test", @types.AgentState::Completing)
  assert_true(res2 is Ok(_))

  // Completing -> Done
  let res3 = reg.set_state("main.test", @types.AgentState::Done)
  assert_true(res3 is Ok(_))

  // Test Active -> Failed and Failed -> Done
  let agent2 : @types.Agent = {
    ..agent,
    agent_id: "main.fail",
    state: @types.AgentState::Active,
  }
  let _ = reg.insert(agent2)

  let res4 = reg.set_state("main.fail", @types.AgentState::Failed)
  assert_true(res4 is Ok(_))

  let res5 = reg.set_state("main.fail", @types.AgentState::Done)
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
    state: @types.AgentState::Spawning,
  }
  let _ = reg.insert(agent)

  // Spawning -> Done (invalid)
  let res = reg.set_state("main.test", @types.AgentState::Done)
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
    state: @types.AgentState::Active,
  }
  let _ = reg.insert(agent)

  let res = reg.set_alive("main.test", false)
  assert_true(res is Ok(_))

  let res_err = reg.set_alive("nonexistent", false)
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

  let _ = reg.insert(a1)
  let _ = reg.insert(a2)
  let _ = reg.insert(a3)

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
    state: @types.AgentState::Active,
  }
  let a2 : @types.Agent = { ..a1, agent_id: "a2", role: @types.Role::Dev }
  let a3 : @types.Agent = { ..a1, agent_id: "a3", role: @types.Role::Dev }

  let _ = reg.insert(a1)
  let _ = reg.insert(a2)
  let _ = reg.insert(a3)

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
  assert_eq(holder, Some("agent-a"))
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
  assert_eq(holder, Some("agent-a"))
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
  let next = reg.release("README", "agent-a")
  assert_eq(next, Some("agent-b"))
  let (holder, queue) = reg.status("README")
  assert_eq(holder, Some("agent-b"))
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
  let next = reg.release("README", "agent-b")
  assert_eq(next, None)
  let (holder, queue) = reg.status("README")
  assert_eq(holder, Some("agent-a"))
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
  assert_eq(holder, Some("agent-c"))
  assert_eq(queue.length(), 0)
}

///|
test "mutex registry expire hands off to queued waiter" {
  let reg = @registry.MutexRegistry::new()
  ignore(reg.acquire("README", "agent-a", 5L, 10L))
  ignore(reg.acquire("README", "agent-b", 5L, 11L))
  reg.expire(16L)
  let (holder, queue) = reg.status("README")
  assert_eq(holder, Some("agent-b"))
  assert_eq(queue.length(), 0)
}
