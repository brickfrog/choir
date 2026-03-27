///|
async fn mock_registry_ensure_pr(
  branch : String,
  _parent_branch : String,
  _project_dir : String,
  _title : String?,
  _body : String?,
) -> Result[@tools.PullRequestInfo, String] {
  @async.sleep(0)
  Ok({ number: 1, url: "https://example.test/pr/" + branch, state: "OPEN" })
}

///|
async fn mock_registry_branch_ready(
  _branch : String,
  _parent_branch : String,
  _project_dir : String,
) -> Result[Unit, String] {
  @async.sleep(0)
  Ok(())
}

///|
async fn mock_registry_runner(cmds : Array[@workspace.Command]) -> Array[Int] {
  @async.sleep(0)
  let statuses = []
  for _ in cmds {
    statuses.push(0)
  }
  statuses
}

///|
async fn mock_registry_branch_ready_capture(
  _branch : String,
  _parent_branch : String,
  project_dir : String,
) -> Result[Unit, String] {
  @async.sleep(0)
  if project_dir == "/tmp/task-leaf-worktree" {
    Ok(())
  } else {
    Err("wrong ensure_branch_ready project_dir: " + project_dir)
  }
}

///|
async fn mock_registry_ensure_pr_capture(
  branch : String,
  _parent_branch : String,
  project_dir : String,
  _title : String?,
  _body : String?,
) -> Result[@tools.PullRequestInfo, String] {
  @async.sleep(0)
  if project_dir != "/tmp/task-leaf-worktree" {
    return Err("wrong ensure_pr project_dir: " + project_dir)
  }
  Ok({ number: 1, url: "https://example.test/pr/" + branch, state: "OPEN" })
}

///|
async fn mock_registry_runner_capture_workdir(
  cmds : Array[@workspace.Command],
) -> Array[Int] {
  @async.sleep(0)
  let statuses = []
  for cmd in cmds {
    let status = match cmd.workdir {
      Some(path) => if path == "/tmp/task-leaf-worktree" { 0 } else { 17 }
      None => 18
    }
    statuses.push(status)
  }
  statuses
}

///|
test "tool registry lookup success" {
  let reg = @tools.ToolRegistry::new()
  let result = reg.lookup(@types.Role::TL, "fork_wave")
  assert_true(result is Ok(_))
}

///|
test "tool registry lookup wrong role" {
  let reg = @tools.ToolRegistry::new()
  let result = reg.lookup(@types.Role::Worker, "fork_wave")
  assert_true(result is Err(_))
}

///|
test "tool registry lookup unknown tool" {
  let reg = @tools.ToolRegistry::new()
  let result = reg.lookup(@types.Role::TL, "nonexistent")
  assert_true(result is Err(_))
}

///|
test "send_message allowed for all roles" {
  let reg = @tools.ToolRegistry::new()
  let roles : Array[@types.Role] = [
    @types.Role::Root,
    @types.Role::TL,
    @types.Role::Dev,
    @types.Role::Worker,
  ]
  for role in roles {
    let result = reg.lookup(role, "send_message")
    assert_true(result is Ok(_))
  }
}

///|
test "reply allowed for all roles" {
  let reg = @tools.ToolRegistry::new()
  let roles : Array[@types.Role] = [
    @types.Role::Root,
    @types.Role::TL,
    @types.Role::Dev,
    @types.Role::Worker,
  ]
  for role in roles {
    let result = reg.lookup(role, "reply")
    assert_true(result is Ok(_))
  }
}

///|
test "kv tools allowed for all roles" {
  let reg = @tools.ToolRegistry::new()
  let roles : Array[@types.Role] = [
    @types.Role::Root,
    @types.Role::TL,
    @types.Role::Dev,
    @types.Role::Worker,
  ]
  let names = [
    "kv_get", "kv_set", "kv_delete", "kv_list", "mutex_acquire", "mutex_release",
    "mutex_status",
  ]
  for role in roles {
    for name in names {
      let result = reg.lookup(role, name)
      assert_true(result is Ok(_))
    }
  }
}

///|
async test "handle_request with valid tool returns Ok" {
  let reg = @tools.ToolRegistry::new()
  let req = @types.Request::{
    req_method: "tools/call",
    role: @types.Role::TL,
    name: "fork_wave",
    args: @types.RequestArgs::new({ "count": "3" }),
  }
  let res = handle_request(reg, req, runner=mock_registry_runner)
  assert_true(res is Ok(_))
}

///|
async test "handle_request with wrong role returns Err" {
  let reg = @tools.ToolRegistry::new()
  let req = @types.Request::{
    req_method: "tools/call",
    role: @types.Role::Worker,
    name: "fork_wave",
    args: @types.RequestArgs::new({}),
  }
  let res = handle_request(reg, req)
  assert_true(res is Err(_))
}

///|
async test "handle_request with unknown tool returns Err" {
  let reg = @tools.ToolRegistry::new()
  let req = @types.Request::{
    req_method: "tools/call",
    role: @types.Role::TL,
    name: "nonexistent",
    args: @types.RequestArgs::new({}),
  }
  let res = handle_request(reg, req)
  assert_true(res is Err(_))
}

///|
async test "dispatch returns correct stub for each tool name" {
  let cases = [
    ("fork_wave", "spawned", { "count": "1" }),
    ("fork_session", "ok", { "name": "nested-team" }),
    ("file_pr", "pr_created", { "branch": "test" }),
    ("merge_pr", "merged", { "pr_number": "1" }),
    ("track_pr", "tracked", { "pr_number": "1", "agent_id": "agent-1" }),
    ("notify_parent", "notified", { "caller_id": "test-agent" }),
    ("send_message", "sent", { "target_id": "test-agent" }),
    ("reply", "ok", { "id": "req-1" }),
    ("kv_get", "", { "key": "missing" }),
    ("mutex_status", "", { "name": "readme" }),
    ("shutdown", "shutdown", Map::new()),
    ("task_list", "ok", Map::new()),
    ("spawn_worker", "spawned", Map::new()),
  ]
  for c in cases {
    let (name, expected_status, args) = c
    let call = ToolCall::{ role: @types.Role::Dev, name, args }
    let res = @tools.dispatch_call(
      call,
      runner=mock_registry_runner,
      ensure_branch_ready=mock_registry_branch_ready,
      ensure_pr=mock_registry_ensure_pr,
      mutex_registry=Some(@registry.MutexRegistry::new()),
      poller_state=Some(@poller.PollerState::new()),
    )
    match res {
      Ok(map) =>
        if name == "kv_get" {
          assert_eq(map.get("value"), Some("null"))
        } else if name == "mutex_status" {
          assert_eq(map.get("holder"), Some(""))
          assert_eq(map.get("queue_length"), Some("0"))
          assert_eq(map.get_json("queue_length"), Some((0).to_json()))
        } else if name == "track_pr" {
          assert_eq(map.get("status"), Some("tracked"))
          assert_eq(map.get("branch"), Some("agent-1"))
          assert_eq(map.get("parent_branch"), Some("main"))
          assert_eq(map.get("pr_url"), Some(""))
          assert_eq(map.get_json("status"), Some("tracked".to_json()))
        } else {
          assert_eq(map.get("status"), Some(expected_status))
        }
      Err(msg) => {
        println(name + ": " + msg)
        assert_true(false)
      }
    }
  }
}

///|
async test "dispatch file_pr uses registered agent workspace for git and gh operations" {
  let reg = @registry.AgentRegistry::new()
  ignore(
    reg.upsert({
      agent_id: "main.task-leaf",
      role: @types.Role::Dev,
      agent_type: @types.AgentType::CursorAgent,
      parent: Some("root"),
      workspace: "/tmp/task-leaf-worktree",
      branch: "main.task-leaf",
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  let call = ToolCall::{
    role: @types.Role::Dev,
    name: "file_pr",
    args: {
      "caller_id": "main.task-leaf",
      "branch": "main.task-leaf",
      "parent_branch": "main",
    },
  }
  let res = @tools.dispatch_call(
    call,
    project_dir="/mnt/data/Code/choir",
    runner=mock_registry_runner_capture_workdir,
    ensure_branch_ready=mock_registry_branch_ready_capture,
    ensure_pr=mock_registry_ensure_pr_capture,
    registry=Some(reg),
    mutex_registry=Some(@registry.MutexRegistry::new()),
    poller_state=Some(@poller.PollerState::new()),
  )
  match res {
    Ok(map) => assert_eq(map.get("status"), Some("pr_created"))
    Err(msg) => fail("expected file_pr success: " + msg)
  }
}

///|
test "tool registry lookup spawn_worker allowed for TL" {
  let reg = @tools.ToolRegistry::new()
  let result = reg.lookup(@types.Role::TL, "spawn_worker")
  assert_true(result is Ok(_))
}

///|
test "tool registry spawn descriptions distinguish leaves from workers" {
  let reg = @tools.ToolRegistry::new()
  match reg.lookup(@types.Role::TL, "spawn_worker") {
    Ok(def) => {
      assert_true(def.description.contains("research/review"))
      assert_true(def.description.contains("do not own a branch or PR"))
    }
    Err(_) => fail("expected spawn_worker definition")
  }
  match reg.lookup(@types.Role::TL, "fork_wave") {
    Ok(def) =>
      assert_true(
        def.description.contains("worktrees") &&
        def.description.contains("optional role"),
      )
    Err(_) => fail("expected fork_wave definition")
  }
}

///|
test "tool registry lookup fork_session allowed for TL" {
  let reg = @tools.ToolRegistry::new()
  let result = reg.lookup(@types.Role::TL, "fork_session")
  assert_true(result is Ok(_))
}

///|
async test "fork_wave role tl requires agent registry" {
  let call = ToolCall::{
    role: @types.Role::TL,
    name: "fork_wave",
    args: {
      "caller_id": "main.tl",
      "count": "1",
      "task": "subtree",
      "parent_branch": "main",
      "role": "tl",
    },
  }
  let res = @tools.dispatch_call(call, runner=mock_registry_runner)
  match res {
    Ok(_) => fail("expected fork_wave role=tl to fail without registry")
    Err(msg) => assert_true(msg.contains("fork_wave role=tl requires"))
  }
}

///|
async test "fork_wave role tl requires registered caller_id" {
  let reg = @registry.AgentRegistry::new()
  let call = ToolCall::{
    role: @types.Role::TL,
    name: "fork_wave",
    args: {
      "caller_id": "main.unknown-tl",
      "count": "1",
      "task": "subtree",
      "parent_branch": "main",
      "role": "tl",
    },
  }
  let res = @tools.dispatch_call(
    call,
    runner=mock_registry_runner,
    registry=Some(reg),
  )
  match res {
    Ok(_) => fail("expected fork_wave role=tl to fail for unregistered caller")
    Err(msg) => assert_true(msg.contains("fork_wave role=tl requires"))
  }
}

///|
async test "register accepts whitespace-trimmed spawn_depth" {
  let reg = @registry.AgentRegistry::new()
  let call = ToolCall::{
    role: @types.Role::TL,
    name: "register",
    args: {
      "agent_id": "main.depth-trim",
      "spawn_depth": " 1",
      "workspace": "/tmp/w",
      "branch": "main.depth-trim",
    },
  }
  let res = @tools.dispatch_call(call, registry=Some(reg))
  match res {
    Ok(_) => ()
    Err(e) => fail("register failed: " + e)
  }
  match reg.get("main.depth-trim") {
    Ok(agent) => assert_eq(agent.spawn_depth, 1)
    Err(_) => fail("expected registered agent")
  }
}

///|
async test "fork_wave role tl rejected when caller spawn_depth is 1" {
  let reg = @registry.AgentRegistry::new()
  ignore(
    reg.upsert({
      agent_id: "main.subtl",
      role: @types.Role::TL,
      agent_type: @types.AgentType::Claude,
      parent: Some("root"),
      workspace: ".",
      branch: "main.subtl",
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 1,
      state: @types.AgentState::Active,
    }),
  )
  let call = ToolCall::{
    role: @types.Role::TL,
    name: "fork_wave",
    args: {
      "caller_id": "main.subtl",
      "count": "1",
      "task": "nested",
      "parent_branch": "main.subtl",
      "role": "tl",
    },
  }
  let res = @tools.dispatch_call(
    call,
    runner=mock_registry_runner,
    registry=Some(reg),
  )
  match res {
    Ok(_) => fail("expected fork_wave to fail for nested sub-TL")
    Err(msg) => assert_true(msg.contains("sub-TL nesting limited to depth 1"))
  }
}
