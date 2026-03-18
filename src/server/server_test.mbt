///|
fn build_agent(id : String, parent : String?) -> @types.Agent {
  {
    agent_id: id,
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Claude,
    parent,
    workspace: "/tmp",
    branch: "main",
    tmux_target: None,
    host: @types.Host::Local,
    state: @types.AgentState::Active,
  }
}

///|
test "ServerState::handle valid request returns Ok" {
  let state = ServerState::new(@types.Config::default())
  let req = @types.Request::{
    req_method: "tools/call",
    role: @types.Role::Dev,
    name: "task_list",
    args: {},
  }
  let res = state.handle(req)
  assert_true(res is Ok(_))
}

///|
test "ServerState::handle invalid role returns Err" {
  let state = ServerState::new(@types.Config::default())
  let req = @types.Request::{
    req_method: "tools/call",
    role: @types.Role::Dev,
    name: "fork_wave",
    args: {},
  }
  let res = state.handle(req)
  assert_true(res is Err(_))
}

///|
test "register_agent and list_agents" {
  let state = ServerState::new(@types.Config::default())
  let agent = build_agent("child-1", None)
  let res = state.register_agent(agent)
  assert_true(res is Ok(_))
  let agents = state.list_agents()
  assert_eq(agents.length(), 1)
  assert_eq(agents[0].agent_id, "child-1")
}

///|
test "register_agent duplicate returns Err" {
  let state = ServerState::new(@types.Config::default())
  let agent = build_agent("child-1", None)
  let _ = state.register_agent(agent)
  let res = state.register_agent(agent)
  assert_true(res is Err(_))
}

///|
test "notify_parent with valid parent returns Ok DeliveryMethod" {
  let state = ServerState::new(@types.Config::default())
  let parent = build_agent("parent-1", None)
  let child = build_agent("child-1", Some("parent-1"))
  let _ = state.register_agent(parent)
  let _ = state.register_agent(child)
  let res = state.notify_parent("child-1", "hello", "success")
  assert_true(res is Ok(_))
  match res {
    Ok(delivery) =>
      assert_true(delivery is @message.DeliveryMethod::TeamsInbox(_, _))
    Err(_) => fail("Expected Ok")
  }
}

///|
test "notify_parent with no parent returns Err" {
  let state = ServerState::new(@types.Config::default())
  let root = build_agent("root-1", None)
  let _ = state.register_agent(root)
  let res = state.notify_parent("root-1", "hello", "success")
  assert_true(res is Err(_))
}
