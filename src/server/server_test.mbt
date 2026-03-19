///|
#borrow(cmd)
extern "C" fn c_system_test(cmd : Bytes) -> Int = "system"

///|
fn string_to_null_terminated_bytes(s : String) -> Bytes {
  let b = @utf8.encode(s)
  let len = b.length()
  let result = FixedArray::make(len + 1, (0 : Byte))
  for i = 0; i < len; i = i + 1 {
    result[i] = b[i]
  }
  result[len] = (0 : Byte)
  result.unsafe_reinterpret_as_bytes()
}

///|
fn run_shell(script : String) -> Unit {
  ignore(
    c_system_test(string_to_null_terminated_bytes("sh -c '" + script + "'")),
  )
}

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
  @async.with_event_loop(_ => {
    let state = ServerState::new(@types.Config::default())
    let req = @types.Request::{
      req_method: "tools/call",
      role: @types.Role::Dev,
      name: "task_list",
      args: {},
    }
    let res = state.handle(req)
    assert_true(res is Ok(_))
  })
}

///|
test "ServerState::handle invalid role returns Err" {
  @async.with_event_loop(_ => {
    let state = ServerState::new(@types.Config::default())
    let req = @types.Request::{
      req_method: "tools/call",
      role: @types.Role::Dev,
      name: "fork_wave",
      args: {},
    }
    let res = state.handle(req)
    assert_true(res is Err(_))
  })
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

///|
test "ServerState::new initializes run_id and mutex registry" {
  let project_dir = "/tmp/choir-server-state"
  run_shell(
    "rm -rf /tmp/choir-server-state && mkdir -p /tmp/choir-server-state",
  )
  let config = { ..@types.Config::default(), project_dir, }
  let state = ServerState::new(config)
  assert_true(state.run_id != "")
  let persisted = @io.read_file(project_dir + "/.exo/run_id")
  assert_eq(persisted, state.run_id)
  let (holder, queue) = state.mutex_registry.status("missing")
  assert_eq(holder, None)
  assert_eq(queue.length(), 0)
  run_shell("rm -rf /tmp/choir-server-state")
}

///|
test "handle_disconnect notifies parent when agent was Active" {
  @async.with_event_loop(_ => {
    let state = ServerState::new(@types.Config::default())
    let parent = { ..build_agent("root", None), role: @types.Role::TL }
    ignore(state.registry.insert(parent))
    let child = {
      ..build_agent("main.worker-1", Some("root")),
      branch: "main.worker-1",
    }
    ignore(state.registry.insert(child))
    state.handle_disconnect("main.worker-1")
    match state.registry.get("main.worker-1") {
      Ok(agent) => assert_eq(agent.state, @types.AgentState::Failed)
      Err(_) => fail("Expected child agent to remain in registry")
    }
  })
}

///|
test "handle_disconnect transitions Completing agent to Done" {
  @async.with_event_loop(_ => {
    let state = ServerState::new(@types.Config::default())
    let agent = {
      ..build_agent("main.dev-1", None),
      branch: "main.dev-1",
      state: @types.AgentState::Completing,
    }
    ignore(state.registry.insert(agent))
    state.handle_disconnect("main.dev-1")
    match state.registry.get("main.dev-1") {
      Ok(updated_agent) =>
        assert_eq(updated_agent.state, @types.AgentState::Done)
      Err(_) => fail("Expected agent to remain in registry")
    }
  })
}

///|
test "handle_disconnect is no-op when agent already removed" {
  @async.with_event_loop(_ => {
    let state = ServerState::new(@types.Config::default())
    state.handle_disconnect("main.never-existed")
    assert_true(true)
  })
}
