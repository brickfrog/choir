///|
test "registry insert and get" {
  let reg = @registry.AgentRegistry::new()
  let agent : @types.Agent = {
    agent_id: "main.feat",
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Gemini,
    parent: Some("root"),
    workspace: ".exo/worktrees/feat",
    branch: "main.feat",
    tmux_target: None,
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
    workspace: ".exo/worktrees/dup",
    branch: "main.dup",
    tmux_target: None,
    host: @types.Host::Local,
    state: @types.AgentState::Active,
  }
  let _ = reg.insert(agent)
  let result = reg.insert(agent)
  assert_true(result is Err(_))
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
    tmux_target: None,
    host: @types.Host::Local,
    state: @types.AgentState::Active,
  }
  let child : @types.Agent = {
    agent_id: "main.child",
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Gemini,
    parent: Some("root"),
    workspace: ".exo/worktrees/child",
    branch: "main.child",
    tmux_target: None,
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
    tmux_target: None,
    host: @types.Host::Local,
    state: @types.AgentState::Active,
  }
  let child1 : @types.Agent = {
    agent_id: "main.a",
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Gemini,
    parent: Some("root"),
    workspace: ".exo/worktrees/a",
    branch: "main.a",
    tmux_target: None,
    host: @types.Host::Local,
    state: @types.AgentState::Active,
  }
  let child2 : @types.Agent = {
    agent_id: "main.b",
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Gemini,
    parent: Some("root"),
    workspace: ".exo/worktrees/b",
    branch: "main.b",
    tmux_target: None,
    host: @types.Host::Local,
    state: @types.AgentState::Active,
  }
  let _ = reg.insert(parent)
  let _ = reg.insert(child1)
  let _ = reg.insert(child2)
  let kids = reg.children("root")
  assert_eq(kids.length(), 2)
}
