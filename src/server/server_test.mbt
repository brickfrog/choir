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
async fn mock_spawn_runner_server(
  cmds : Array[@workspace.Command],
) -> Array[Int] {
  @async.sleep(0)
  assert_eq(cmds.length(), 5)
  assert_eq(cmds[3].args, [
    "new-window", "-t", "server-proof", "-n", "leaf-a", "-c", "/tmp/server-proof/.choir/worktrees/leaf-a",
  ])
  assert_eq(cmds[4].args[0], "send-keys")
  assert_eq(cmds[4].args[1], "-t")
  assert_eq(cmds[4].args[2], "server-proof:leaf-a")
  assert_true(cmds[4].args[3].contains("gemini '--prompt-interactive'"))
  assert_true(cmds[4].args[3].contains("## TASK\nreply READY"))
  assert_true(cmds[4].args[3].contains("## READ FIRST\n- AGENTS.md"))
  assert_true(cmds[4].args[3].contains("## Completion Protocol (Leaf)"))
  assert_eq(cmds[4].args[4], "C-m")
  [0, 0, 0, 0, 0]
}

///|
test "ServerState::handle valid request returns Ok" {
  @async.with_event_loop(_ => {
    let state = ServerState::new(@types.Config::default())
    let req = @types.Request::{
      req_method: "tools/call",
      role: @types.Role::Dev,
      name: "task_list",
      args: @types.RequestArgs::new({}),
    }
    let res = state.handle(req)
    assert_true(res.is_ok())
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
      args: @types.RequestArgs::new({}),
    }
    let res = state.handle(req)
    assert_false(res.is_ok())
  })
}

///|
test "ServerState::handle_with_runner passes configured tmux session to spawns" {
  @async.with_event_loop(_ => {
    let config = {
      ..@types.Config::default(),
      project_dir: "/tmp/server-proof",
      tmux_session: "server-proof",
    }
    let state = ServerState::new(config)
    let req = @types.Request::{
      req_method: "tools/call",
      role: @types.Role::TL,
      name: "spawn_gemini",
      args: @types.RequestArgs::new({
        "caller_id": "root",
        "slug": "leaf-a",
        "parent_branch": "main",
        "task": "reply READY",
        "read_first": "AGENTS.md",
      }),
    }
    let res = state.handle_with_runner(req, runner=mock_spawn_runner_server)
    assert_eq(res.ok_field("status"), Some("spawned"))
    assert_eq(res.ok_field("agent_id"), Some("main.leaf-a"))
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
test "plan_poll_event_delivery routes PR ready to parent" {
  let state = ServerState::new(@types.Config::default())
  let parent = build_agent("parent-1", None)
  let child = {
    ..build_agent("child-1", Some("parent-1")),
    branch: "main.child-1",
  }
  let _ = state.register_agent(parent)
  let _ = state.register_agent(child)
  state.poller.track(
    42, "child-1", "main.child-1", "main", "https://example.test/pr/42", 100L,
  )
  let delivery = state.plan_poll_event_delivery(
    @poller.PollEvent::PRReady(42),
    "child-1",
  )
  match delivery {
    Some(@message.DeliveryMethod::TeamsInbox(path, payload)) => {
      assert_true(path.contains("parent-1"))
      assert_true(payload.contains("[PR READY] child-1 PR #42 approved"))
      assert_true(payload.contains("branch: main.child-1"))
      assert_true(payload.contains("parent_branch: main"))
      assert_true(payload.contains("pr_url: https://example.test/pr/42"))
      assert_true(
        payload.contains("merge_pr(pr_number: \"42\", parent_branch: \"main\")"),
      )
      assert_true(payload.contains("\"from\":\"child-1\""))
    }
    _ => fail("expected parent Teams inbox delivery")
  }
}

///|
test "plan_poll_event_delivery routes fixes pushed to parent with next action" {
  let state = ServerState::new(@types.Config::default())
  let parent = build_agent("parent-1", None)
  let child = {
    ..build_agent("child-1", Some("parent-1")),
    branch: "main.subtl.child-1",
  }
  let _ = state.register_agent(parent)
  let _ = state.register_agent(child)
  state.poller.track(
    43, "child-1", "main.subtl.child-1", "main.subtl", "https://example.test/pr/43",
    100L,
  )
  let delivery = state.plan_poll_event_delivery(
    @poller.PollEvent::FixesPushed(43),
    "child-1",
  )
  match delivery {
    Some(@message.DeliveryMethod::TeamsInbox(path, payload)) => {
      assert_true(path.contains("parent-1"))
      assert_true(
        payload.contains(
          "[FIXES PUSHED] child-1 PR #43 has new commits after review",
        ),
      )
      assert_true(payload.contains("branch: main.subtl.child-1"))
      assert_true(payload.contains("parent_branch: main.subtl"))
      assert_true(payload.contains("pr_url: https://example.test/pr/43"))
      assert_true(
        payload.contains("Next action: re-check the PR and merge when ready."),
      )
      assert_true(payload.contains("\"from\":\"child-1\""))
    }
    _ => fail("expected parent Teams inbox delivery")
  }
}

///|
test "plan_poll_event_delivery routes review comments to owning agent" {
  let state = ServerState::new(@types.Config::default())
  let parent = build_agent("parent-1", None)
  let child = build_agent("child-1", Some("parent-1"))
  let _ = state.register_agent(parent)
  let _ = state.register_agent(child)
  let delivery = state.plan_poll_event_delivery(
    @poller.PollEvent::ReviewReceived(42, "Please add tests"),
    "child-1",
  )
  match delivery {
    Some(@message.DeliveryMethod::TeamsInbox(path, payload)) => {
      assert_true(path.contains("child-1"))
      assert_true(
        payload.contains(
          "[REVIEW] PR #42 has review comments:\nPlease add tests",
        ),
      )
      assert_true(payload.contains("\"from\":\"poller\""))
    }
    _ => fail("expected owning agent Teams inbox delivery")
  }
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
  let persisted = @io.read_file(project_dir + "/.choir/run_id")
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
