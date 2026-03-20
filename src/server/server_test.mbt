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
async fn mock_runner_server(cmds : Array[@workspace.Command]) -> Array[Int] {
  @async.sleep(0)
  let statuses = []
  for _ in cmds {
    statuses.push(0)
  }
  statuses
}

///|
async fn record_runner_server(
  sink : Array[@workspace.Command],
  cmds : Array[@workspace.Command],
) -> Array[Int] {
  @async.sleep(0)
  let statuses = []
  for cmd in cmds {
    sink.push(cmd)
    statuses.push(0)
  }
  statuses
}

///|
async fn mock_ensure_pr_server(
  branch : String,
  _parent_branch : String,
  _project_dir : String,
) -> Result[@tools.PullRequestInfo, String] {
  @async.sleep(0)
  Ok({ number: 52, url: "https://example.test/pr/" + branch })
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
        payload.contains(
          "merge_pr(pr_number: \\\"42\\\", parent_branch: \\\"main\\\")",
        ),
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
          "[REVIEW] PR #42 has review comments:\\nPlease add tests",
        ),
      )
      assert_true(payload.contains("\"from\":\"poller\""))
    }
    _ => fail("expected owning agent Teams inbox delivery")
  }
}

///|
test "process_poller_tick_with drives PR review workflow and merge cleanup" {
  @async.with_event_loop(_ => {
    let state = ServerState::new(@types.Config::default())
    let parent = { ..build_agent("parent-1", None), role: @types.Role::TL }
    let child = {
      ..build_agent("main.leaf-1", Some("parent-1")),
      role: @types.Role::Dev,
      branch: "main.leaf-1",
    }
    ignore(state.registry.insert(parent))
    ignore(state.registry.insert(child))

    let file_req = @types.Request::{
      req_method: "tools/call",
      role: @types.Role::Dev,
      name: "file_pr",
      args: @types.RequestArgs::from_values({
        "branch": @types.wire_string("main.leaf-1"),
        "parent_branch": @types.wire_string("main"),
        "caller_id": @types.wire_string("main.leaf-1"),
      }),
    }
    let file_res = @tools.handle_request(
      state.tool_registry,
      file_req,
      project_dir="/tmp",
      runner=mock_runner_server,
      ensure_pr=mock_ensure_pr_server,
      agent_registry=Some(state.registry),
      mutex_registry=Some(state.mutex_registry),
      poller_state=Some(state.poller),
    )
    assert_eq(file_res.ok_field("status"), Some("pr_created"))
    assert_eq(file_res.ok_field("tracked"), Some("true"))
    match state.poller.get(52) {
      Some(tracked) => {
        assert_eq(tracked.agent_id, "main.leaf-1")
        assert_eq(tracked.branch, "main.leaf-1")
        assert_eq(tracked.parent_branch, "main")
        assert_eq(tracked.pr_url, "https://example.test/pr/main.leaf-1")
      }
      None => fail("expected tracked PR after file_pr")
    }

    let review_cmds : Array[@workspace.Command] = []
    state.process_poller_tick_with(
      200L,
      900L,
      fn(_pr_number) {
        (
          @poller.ReviewState::ChangesRequested,
          "sha-review-1",
          false,
          "Please add tests",
        )
      },
      runner=async fn(cmds) { record_runner_server(review_cmds, cmds) },
    )
    assert_eq(review_cmds.length(), 1)
    assert_eq(review_cmds[0].program, "sh")
    assert_true(
      review_cmds[0].args[4].contains(
        "/.claude/teams/main.leaf-1/inboxes/default.json",
      ),
    )
    assert_true(
      review_cmds[0].args[3].contains(
        "[REVIEW] PR #52 has review comments:\\nPlease add tests",
      ),
    )
    assert_true(review_cmds[0].args[3].contains("\"from\":\"poller\""))

    let fixes_cmds : Array[@workspace.Command] = []
    state.process_poller_tick_with(
      201L,
      900L,
      fn(_pr_number) {
        (
          @poller.ReviewState::ChangesRequested,
          "sha-review-2",
          false,
          "Please add tests",
        )
      },
      runner=async fn(cmds) { record_runner_server(fixes_cmds, cmds) },
    )
    assert_eq(fixes_cmds.length(), 1)
    assert_true(
      fixes_cmds[0].args[4].contains(
        "/.claude/teams/parent-1/inboxes/default.json",
      ),
    )
    assert_true(
      fixes_cmds[0].args[3].contains(
        "[FIXES PUSHED] main.leaf-1 PR #52 has new commits after review",
      ),
    )
    assert_true(fixes_cmds[0].args[3].contains("\"from\":\"main.leaf-1\""))

    let ready_cmds : Array[@workspace.Command] = []
    state.process_poller_tick_with(
      202L,
      900L,
      fn(_pr_number) {
        (@poller.ReviewState::Approved, "sha-review-2", false, "")
      },
      runner=async fn(cmds) { record_runner_server(ready_cmds, cmds) },
    )
    assert_eq(ready_cmds.length(), 1)
    assert_true(
      ready_cmds[0].args[4].contains(
        "/.claude/teams/parent-1/inboxes/default.json",
      ),
    )
    assert_true(
      ready_cmds[0].args[3].contains("[PR READY] main.leaf-1 PR #52 approved"),
    )
    assert_true(
      ready_cmds[0].args[3].contains(
        "merge_pr(pr_number: \\\"52\\\", parent_branch: \\\"main\\\")",
      ),
    )
    assert_true(ready_cmds[0].args[3].contains("\"from\":\"main.leaf-1\""))

    let merge_req = @types.Request::{
      req_method: "tools/call",
      role: @types.Role::TL,
      name: "merge_pr",
      args: @types.RequestArgs::from_values({
        "pr_number": @types.wire_int(52),
        "parent_branch": @types.wire_string("main"),
        "caller_id": @types.wire_string("parent-1"),
      }),
    }
    let merge_res = @tools.handle_request(
      state.tool_registry,
      merge_req,
      project_dir="/tmp",
      runner=mock_runner_server,
      agent_registry=Some(state.registry),
      mutex_registry=Some(state.mutex_registry),
      poller_state=Some(state.poller),
    )
    assert_eq(merge_res.ok_field("status"), Some("merged"))
    assert_eq(state.poller.get(52), None)
  })
}

///|
test "process_poller_tick_with suppresses duplicate recovered review events" {
  @async.with_event_loop(_ => {
    let state = ServerState::new(@types.Config::default())
    let parent = { ..build_agent("parent-1", None), role: @types.Role::TL }
    let child = {
      ..build_agent("main.leaf-1", Some("parent-1")),
      role: @types.Role::Dev,
      branch: "main.leaf-1",
    }
    ignore(state.registry.insert(parent))
    ignore(state.registry.insert(child))
    state.poller.track_recovered(
      52,
      "main.leaf-1",
      "main.leaf-1",
      "main",
      "https://example.test/pr/52",
      100L,
      @poller.ReviewState::ChangesRequested,
      "sha-review-1",
      false,
    )

    let duplicate_cmds : Array[@workspace.Command] = []
    state.process_poller_tick_with(
      200L,
      900L,
      fn(_pr_number) {
        (
          @poller.ReviewState::ChangesRequested,
          "sha-review-1",
          false,
          "Please add tests",
        )
      },
      runner=async fn(cmds) { record_runner_server(duplicate_cmds, cmds) },
    )
    assert_eq(duplicate_cmds.length(), 0)

    let fixes_cmds : Array[@workspace.Command] = []
    state.process_poller_tick_with(
      201L,
      900L,
      fn(_pr_number) {
        (
          @poller.ReviewState::ChangesRequested,
          "sha-review-2",
          false,
          "Please add tests",
        )
      },
      runner=async fn(cmds) { record_runner_server(fixes_cmds, cmds) },
    )
    assert_eq(fixes_cmds.length(), 1)
    assert_true(
      fixes_cmds[0].args[4].contains(
        "/.claude/teams/parent-1/inboxes/default.json",
      ),
    )
    assert_true(
      fixes_cmds[0].args[3].contains(
        "[FIXES PUSHED] main.leaf-1 PR #52 has new commits after review",
      ),
    )
  })
}

///|
test "process_poller_tick_with suppresses duplicate recovered approval events" {
  @async.with_event_loop(_ => {
    let state = ServerState::new(@types.Config::default())
    let parent = { ..build_agent("parent-1", None), role: @types.Role::TL }
    let child = {
      ..build_agent("main.leaf-1", Some("parent-1")),
      role: @types.Role::Dev,
      branch: "main.leaf-1",
    }
    ignore(state.registry.insert(parent))
    ignore(state.registry.insert(child))
    state.poller.track_recovered(
      53,
      "main.leaf-1",
      "main.leaf-1",
      "main",
      "https://example.test/pr/53",
      100L,
      @poller.ReviewState::Approved,
      "sha-review-2",
      false,
    )

    let duplicate_cmds : Array[@workspace.Command] = []
    state.process_poller_tick_with(
      200L,
      900L,
      fn(_pr_number) {
        (@poller.ReviewState::Approved, "sha-review-2", false, "")
      },
      runner=async fn(cmds) { record_runner_server(duplicate_cmds, cmds) },
    )
    assert_eq(duplicate_cmds.length(), 0)
  })
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
    let delivered_cmds : Array[@workspace.Command] = []
    state.handle_disconnect_with_runner("main.worker-1", runner=async fn(cmds) {
      record_runner_server(delivered_cmds, cmds)
    })
    match state.registry.get("main.worker-1") {
      Ok(agent) => assert_eq(agent.state, @types.AgentState::Failed)
      Err(_) => fail("Expected child agent to remain in registry")
    }
    assert_eq(delivered_cmds.length(), 1)
    assert_eq(delivered_cmds[0].program, "sh")
    assert_true(
      delivered_cmds[0].args[4].contains(
        "/.claude/teams/root/inboxes/default.json",
      ),
    )
    assert_true(
      delivered_cmds[0].args[3].contains(
        "[FAILED: main.worker-1] disconnected unexpectedly - agent may have crashed or run out of context",
      ),
    )
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
