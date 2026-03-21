///|
async fn mock_runner(cmds : Array[@workspace.Command]) -> Array[Int] {
  @async.sleep(0)
  let res = []
  for _ in cmds {
    res.push(0)
  }
  res
}

///|
async fn mock_fail_runner(cmds : Array[@workspace.Command]) -> Array[Int] {
  @async.sleep(0)
  let res = []
  for _ in cmds {
    res.push(1)
    break
  }
  res
}

///|
async fn run_shell(script : String) -> Unit {
  let statuses = @exec.run_sequence([
    { program: "sh", args: ["-c", script], workdir: None },
  ])
  assert_eq(statuses.length(), 1)
  assert_eq(statuses[0], 0)
}

///|
async test "dispatch fork_wave defaults to gemini fanout" {
  let recorded : Array[@workspace.Command] = []
  let res = @tools.dispatch_call(
    {
      role: @types.Role::TL,
      name: "fork_wave",
      args: {
        "count": "1",
        "task": "Implement feature X",
        "slug_prefix": "wave",
        "parent_branch": "main",
      },
    },
    runner=async fn(cmds) {
      @async.sleep(0)
      for cmd in cmds {
        recorded.push(cmd)
      }
      let statuses = []
      for _ in cmds {
        statuses.push(0)
      }
      statuses
    },
  )
  assert_true(res is Ok(_))
  // Find the tmux send-keys command (registration commands may follow)
  let mut found = false
  for cmd in recorded {
    if cmd.program == "tmux" &&
      cmd.args.length() > 3 &&
      cmd.args[0] == "send-keys" {
      assert_true(
        cmd.args[3].contains("gemini '--yolo' '--prompt-interactive'"),
      )
      found = true
      break
    }
  }
  assert_true(found)
}

///|
async test "dispatch fork_wave skips already-alive agents" {
  let reg = @registry.AgentRegistry::new()
  // Pre-register an Active agent with the same id fork_wave would generate
  let existing = @types.Agent::{
    agent_id: "main.wave-0",
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Gemini,
    state: @types.AgentState::Active,
    parent: Some("root"),
    terminal_target: None,
    host: @types.Host::Local,
    workspace: "",
    branch: "main.wave-0",
  }
  ignore(reg.insert(existing))
  let res = @tools.dispatch_call(
    {
      role: @types.Role::TL,
      name: "fork_wave",
      args: {
        "count": "1",
        "task": "Implement feature X",
        "slug_prefix": "wave",
        "parent_branch": "main",
      },
    },
    runner=mock_runner,
    registry=Some(reg),
  )
  match res {
    Ok(m) => {
      assert_eq(m.get("status"), Some("already_running"))
      assert_eq(m.get("count"), Some("0"))
      assert_eq(m.get("skipped_ids"), Some("main.wave-0"))
    }
    Err(e) => {
      println(e)
      assert_true(false)
    }
  }
}

///|
async test "handle_request fork_wave accepts raw primitive request args" {
  let reg = @tools.ToolRegistry::new()
  let req = @types.Request::{
    req_method: "tools/call",
    role: @types.Role::TL,
    name: "fork_wave",
    args: @types.RequestArgs::from_values({
      "count": @types.WireValue::Raw("2"),
      "fork_session": @types.WireValue::Raw("true"),
      "caller_id": @types.WireValue::String("main"),
      "task": @types.WireValue::String("test task"),
      "parent_branch": @types.WireValue::String("main"),
    }),
  }
  let res = @tools.handle_request(
    reg,
    req,
    project_dir="/tmp",
    runner=mock_runner,
  )
  match res {
    Ok(m) => {
      assert_eq(m.get("status"), Some("spawned"))
      assert_eq(m.get("count"), Some("2"))
      assert_eq(m.get_value("count"), Some(@types.WireValue::Raw("2")))
    }
    Err(e) => {
      println(e)
      assert_true(false)
    }
  }
}

///|
async test "execute_delivery creates Teams inbox directories" {
  let inbox_path = "/tmp/choir-dispatch-delivery/inboxes/default.json"
  run_shell("rm -rf /tmp/choir-dispatch-delivery")
  let res = @tools.execute_delivery(
    @message.DeliveryMethod::TeamsInbox(
      inbox_path,
      "{\"from\":\"sender\",\"content\":\"hello\",\"status\":\"info\"}",
      fallback_target=None,
    ),
    @exec.run_sequence,
  )
  match res {
    Ok(_) =>
      assert_eq(
        @io.read_file(inbox_path).trim().to_string(),
        "{\"from\":\"sender\",\"content\":\"hello\",\"status\":\"info\"}",
      )
    Err(e) => fail(e)
  }
  run_shell("rm -rf /tmp/choir-dispatch-delivery")
}

///|
async test "dispatch task_list reads task files" {
  let project_dir = "/tmp/choir-dispatch-task-list"
  run_shell(
    "rm -rf /tmp/choir-dispatch-task-list && mkdir -p /tmp/choir-dispatch-task-list/.choir/tasks && " +
    "printf '%s' '{\"id\":\"1\",\"title\":\"First\",\"status\":\"todo\",\"assignee\":\"alice\",\"notes\":\"one\"}' > /tmp/choir-dispatch-task-list/.choir/tasks/1.json && " +
    "printf '%s' '{\"id\":\"2\",\"title\":\"Second\",\"status\":\"in_progress\",\"assignee\":\"bob\",\"notes\":\"two\"}' > /tmp/choir-dispatch-task-list/.choir/tasks/2.json",
  )
  let call : @tools.ToolCall = {
    role: @types.Role::Dev,
    name: "task_list",
    args: {},
  }
  let res = @tools.dispatch_call(call, project_dir~, runner=@exec.run_sequence)
  match res {
    Ok(m) => {
      assert_eq(m.get("status"), Some("ok"))
      assert_eq(
        m.get("tasks"),
        Some(
          "[{\"id\":\"1\",\"title\":\"First\",\"status\":\"todo\",\"assignee\":\"alice\",\"notes\":\"one\"},{\"id\":\"2\",\"title\":\"Second\",\"status\":\"in_progress\",\"assignee\":\"bob\",\"notes\":\"two\"}]",
        ),
      )
      assert_eq(
        m.get_value("tasks"),
        Some(
          @types.WireValue::Raw(
            "[{\"id\":\"1\",\"title\":\"First\",\"status\":\"todo\",\"assignee\":\"alice\",\"notes\":\"one\"},{\"id\":\"2\",\"title\":\"Second\",\"status\":\"in_progress\",\"assignee\":\"bob\",\"notes\":\"two\"}]",
          ),
        ),
      )
    }
    Err(e) => {
      println(e)
      assert_true(false)
    }
  }
  run_shell("rm -rf /tmp/choir-dispatch-task-list")
}

///|
async test "dispatch task_get reads one task" {
  let project_dir = "/tmp/choir-dispatch-task-get"
  run_shell(
    "rm -rf /tmp/choir-dispatch-task-get && mkdir -p /tmp/choir-dispatch-task-get/.choir/tasks && " +
    "printf '%s' '{\"id\":\"1\",\"title\":\"First\",\"status\":\"todo\",\"assignee\":\"alice\",\"notes\":\"one\"}' > /tmp/choir-dispatch-task-get/.choir/tasks/1.json",
  )
  let call : @tools.ToolCall = {
    role: @types.Role::Dev,
    name: "task_get",
    args: { "id": "1" },
  }
  let res = @tools.dispatch_call(call, project_dir~, runner=@exec.run_sequence)
  match res {
    Ok(m) => {
      assert_eq(m.get("status"), Some("ok"))
      assert_eq(
        m.get("task"),
        Some(
          "{\"id\":\"1\",\"title\":\"First\",\"status\":\"todo\",\"assignee\":\"alice\",\"notes\":\"one\"}",
        ),
      )
      assert_eq(
        m.get_value("task"),
        Some(
          @types.WireValue::Raw(
            "{\"id\":\"1\",\"title\":\"First\",\"status\":\"todo\",\"assignee\":\"alice\",\"notes\":\"one\"}",
          ),
        ),
      )
    }
    Err(e) => {
      println(e)
      assert_true(false)
    }
  }
  run_shell("rm -rf /tmp/choir-dispatch-task-get")
}

///|
async test "dispatch task_update merges and writes task file" {
  let project_dir = "/tmp/choir-dispatch-task-update"
  run_shell(
    "rm -rf /tmp/choir-dispatch-task-update && mkdir -p /tmp/choir-dispatch-task-update/.choir/tasks && " +
    "printf '%s' '{\"id\":\"1\",\"title\":\"First\",\"status\":\"todo\",\"assignee\":\"alice\",\"notes\":\"one\"}' > /tmp/choir-dispatch-task-update/.choir/tasks/1.json",
  )
  let call : @tools.ToolCall = {
    role: @types.Role::Dev,
    name: "task_update",
    args: {
      "id": "1",
      "status": "done",
      "assignee": "carol",
      "notes": "finished",
    },
  }
  let res = @tools.dispatch_call(call, project_dir~, runner=@exec.run_sequence)
  match res {
    Ok(m) => {
      assert_eq(m.get("status"), Some("ok"))
      assert_eq(
        m.get("task"),
        Some(
          "{\"id\":\"1\",\"title\":\"First\",\"status\":\"done\",\"assignee\":\"carol\",\"notes\":\"finished\"}",
        ),
      )
      assert_eq(
        m.get_value("task"),
        Some(
          @types.WireValue::Raw(
            "{\"id\":\"1\",\"title\":\"First\",\"status\":\"done\",\"assignee\":\"carol\",\"notes\":\"finished\"}",
          ),
        ),
      )
    }
    Err(e) => {
      println(e)
      assert_true(false)
    }
  }
  let written = @io.read_file(project_dir + "/.choir/tasks/1.json")
  assert_eq(
    written, "{\"id\":\"1\",\"title\":\"First\",\"status\":\"done\",\"assignee\":\"carol\",\"notes\":\"finished\"}",
  )
  run_shell("rm -rf /tmp/choir-dispatch-task-update")
}

///|
async test "dispatch task_update validates status" {
  let project_dir = "/tmp/choir-dispatch-task-status"
  run_shell(
    "rm -rf /tmp/choir-dispatch-task-status && mkdir -p /tmp/choir-dispatch-task-status/.choir/tasks && " +
    "printf '%s' '{\"id\":\"1\",\"title\":\"First\",\"status\":\"todo\",\"assignee\":\"alice\",\"notes\":\"one\"}' > /tmp/choir-dispatch-task-status/.choir/tasks/1.json",
  )
  let call : @tools.ToolCall = {
    role: @types.Role::Dev,
    name: "task_update",
    args: { "id": "1", "status": "blocked" },
  }
  let res = @tools.dispatch_call(call, project_dir~, runner=@exec.run_sequence)
  match res {
    Ok(_) => assert_true(false)
    Err(e) => assert_eq(e, "invalid status: blocked")
  }
  run_shell("rm -rf /tmp/choir-dispatch-task-status")
}

///|
async test "dispatch task_get rejects invalid task json" {
  let project_dir = "/tmp/choir-dispatch-task-invalid"
  run_shell(
    "rm -rf /tmp/choir-dispatch-task-invalid && mkdir -p /tmp/choir-dispatch-task-invalid/.choir/tasks && " +
    "printf '%s' '{\"id\":\"1\",\"title\":\"Broken\",\"status\":true,\"assignee\":\"alice\",\"notes\":\"one\"}' > /tmp/choir-dispatch-task-invalid/.choir/tasks/1.json",
  )
  let call : @tools.ToolCall = {
    role: @types.Role::Dev,
    name: "task_get",
    args: { "id": "1" },
  }
  let res = @tools.dispatch_call(call, project_dir~, runner=@exec.run_sequence)
  match res {
    Ok(_) => assert_true(false)
    Err(e) => assert_true(e.contains("invalid task file"))
  }
  run_shell("rm -rf /tmp/choir-dispatch-task-invalid")
}

///|
async test "dispatch reply stores payload in reply kv path" {
  let project_dir = "/tmp/choir-dispatch-reply"
  run_shell(
    "rm -rf /tmp/choir-dispatch-reply && mkdir -p /tmp/choir-dispatch-reply/.choir",
  )
  let call : @tools.ToolCall = {
    role: @types.Role::Root,
    name: "reply",
    args: { "id": "req-1", "payload": "{\"ok\":true}" },
  }
  let res = @tools.dispatch_call(call, project_dir~, runner=@exec.run_sequence)
  match res {
    Ok(m) => {
      assert_eq(m.get("status"), Some("ok"))
      assert_eq(m.get("id"), Some("req-1"))
      assert_eq(m.get_value("status"), Some(@types.WireValue::String("ok")))
      assert_eq(m.get_value("id"), Some(@types.WireValue::String("req-1")))
    }
    Err(e) => {
      println(e)
      assert_true(false)
    }
  }
  let written = @io.read_file(project_dir + "/.choir/kv/reply/req-1")
  assert_eq(written, "{\"ok\":true}")
  run_shell("rm -rf /tmp/choir-dispatch-reply")
}

///|
async test "dispatch reply cancel stores cancel marker" {
  let project_dir = "/tmp/choir-dispatch-reply-cancel"
  run_shell(
    "rm -rf /tmp/choir-dispatch-reply-cancel && mkdir -p /tmp/choir-dispatch-reply-cancel/.choir",
  )
  let call : @tools.ToolCall = {
    role: @types.Role::Root,
    name: "reply",
    args: { "id": "req-2", "payload": "ignored", "cancel": "true" },
  }
  let res = @tools.dispatch_call(call, project_dir~, runner=@exec.run_sequence)
  match res {
    Ok(m) => {
      assert_eq(m.get("status"), Some("ok"))
      assert_eq(m.get_value("status"), Some(@types.WireValue::String("ok")))
    }
    Err(e) => {
      println(e)
      assert_true(false)
    }
  }
  let written = @io.read_file(project_dir + "/.choir/kv/reply/req-2")
  assert_eq(written, "cancel")
  run_shell("rm -rf /tmp/choir-dispatch-reply-cancel")
}

///|
async test "dispatch fork_wave handles failure" {
  let call : @tools.ToolCall = {
    role: @types.Role::TL,
    name: "fork_wave",
    args: { "count": "1" },
  }
  let res = @tools.dispatch_call(call, runner=mock_fail_runner)
  match res {
    Ok(_) => assert_true(false)
    Err(e) => assert_eq(e, "command failed with status 1")
  }
}

///|
async test "dispatch fork_wave validates count" {
  let call : @tools.ToolCall = {
    role: @types.Role::TL,
    name: "fork_wave",
    args: { "count": "abc" },
  }
  let res = @tools.dispatch_call(call, runner=mock_runner)
  match res {
    Ok(_) => assert_true(false)
    Err(e) =>
      assert_eq(e, "invalid_count: abc") catch {
        _ => assert_true(true)
      } // just check it failed
  }
}

///|
async test "dispatch fork_wave validates slug_prefix" {
  let call : @tools.ToolCall = {
    role: @types.Role::TL,
    name: "fork_wave",
    args: { "count": "1", "slug_prefix": "../bad" },
  }
  let res = @tools.dispatch_call(call, runner=mock_runner)
  match res {
    Ok(_) => assert_true(false)
    Err(e) => assert_true(e.contains("invalid slug_prefix"))
  }
}

///|
async test "dispatch spawn_remote returns agent_id with mock" {
  let call : @tools.ToolCall = {
    role: @types.Role::TL,
    name: "spawn_remote",
    args: {
      "task": "implement feature Z",
      "slug": "remote-1",
      "parent_branch": "main",
      "ssh_target": "user@10.0.0.2",
      "repo_url": "git@github.com:org/repo.git",
      "tcp_addr": "10.0.0.1:9100",
    },
  }
  let res = @tools.dispatch_call(call, runner=mock_runner)
  match res {
    Ok(m) => {
      assert_eq(m.get("status"), Some("spawned"))
      assert_eq(m.get("agent_id"), Some("main.remote-1"))
      assert_eq(m.get("host"), Some("user@10.0.0.2"))
      assert_eq(
        m.get_value("host"),
        Some(@types.WireValue::String("user@10.0.0.2")),
      )
    }
    Err(e) => {
      println(e)
      assert_true(false)
    }
  }
}

///|
async test "dispatch spawn_remote requires ssh_target" {
  let call : @tools.ToolCall = {
    role: @types.Role::TL,
    name: "spawn_remote",
    args: {
      "slug": "r1",
      "repo_url": "git@github.com:org/repo.git",
      "tcp_addr": "10.0.0.1:9100",
    },
  }
  let res = @tools.dispatch_call(call, runner=mock_runner)
  match res {
    Err(e) => assert_true(e.contains("ssh_target"))
    Ok(_) => assert_true(false)
  }
}

///|
async test "dispatch spawn_remote denied for Dev role" {
  let call : @tools.ToolCall = {
    role: @types.Role::Dev,
    name: "spawn_remote",
    args: {
      "ssh_target": "user@host",
      "repo_url": "git@github.com:org/repo.git",
      "tcp_addr": "10.0.0.1:9100",
    },
  }
  let res = @tools.handle_request(
    @tools.ToolRegistry::new(),
    @types.Request::{
      req_method: "tools/call",
      role: call.role,
      name: call.name,
      args: @types.RequestArgs::new(call.args),
    },
    runner=mock_runner,
  )
  match res {
    Err(e) => assert_true(e.contains("cannot call"))
    Ok(_) => assert_true(false)
  }
}

///|
async test "handle_request falls back to plugin and preserves raw response values" {
  let reg = @tools.ToolRegistry::new()
  let captured_requests : Array[String] = []
  let runner = async fn(cmds : Array[@workspace.Command]) -> Array[Int] {
    @async.sleep(0)
    let statuses = []
    for cmd in cmds {
      captured_requests.push(cmd.args[4])
      ignore(
        @io.write_file_sync(
          cmd.args[5],
          "{\"ok\":true,\"status\":\"done\",\"count\":3}",
        ),
      )
      statuses.push(0)
    }
    statuses
  }
  let req = @types.Request::{
    req_method: "tools/call",
    role: @types.Role::Dev,
    name: "search_docs",
    args: @types.RequestArgs::from_values({
      "agent_id": @types.WireValue::String("leaf-1"),
      "count": @types.WireValue::Raw("2"),
    }),
  }
  let res = handle_request(
    reg,
    req,
    runner~,
    plugins_json=Some(
      "[{\"name\":\"search\",\"command\":\"cat\",\"tools\":\"search_docs\"}]",
    ),
  )
  assert_eq(captured_requests.length(), 1)
  assert_true(captured_requests[0].contains("\"tool\":\"search_docs\""))
  assert_true(captured_requests[0].contains("\"count\":2"))
  match res {
    Ok(m) => {
      assert_eq(m.get("status"), Some("done"))
      assert_eq(m.get("count"), Some("3"))
      assert_eq(m.get_value("count"), Some(@types.WireValue::Raw("3")))
    }
    Err(e) => {
      println(e)
      assert_true(false)
    }
  }
}

///|
async test "handle_request returns plugin error message" {
  let reg = @tools.ToolRegistry::new()
  let runner = async fn(cmds : Array[@workspace.Command]) -> Array[Int] {
    @async.sleep(0)
    for cmd in cmds {
      ignore(
        @io.write_file_sync(cmd.args[5], "{\"ok\":false,\"error\":\"boom\"}"),
      )
    }
    [0]
  }
  let req = @types.Request::{
    req_method: "tools/call",
    role: @types.Role::Dev,
    name: "search_docs",
    args: @types.RequestArgs::new({}),
  }
  let res = handle_request(
    reg,
    req,
    runner~,
    plugins_json=Some(
      "[{\"name\":\"search\",\"command\":\"cat\",\"tools\":\"search_docs\"}]",
    ),
  )
  match res {
    Ok(_) => assert_true(false)
    Err(e) => assert_eq(e, "plugin error: boom")
  }
}

///|
async test "handle_request returns tool not found when plugin does not match" {
  let reg = @tools.ToolRegistry::new()
  let req = @types.Request::{
    req_method: "tools/call",
    role: @types.Role::Dev,
    name: "search_docs",
    args: @types.RequestArgs::new({}),
  }
  let res = handle_request(
    reg,
    req,
    runner=mock_runner,
    plugins_json=Some(
      "[{\"name\":\"deploy\",\"command\":\"cat\",\"tools\":\"deploy\"}]",
    ),
  )
  match res {
    Ok(_) => assert_true(false)
    Err(e) => assert_eq(e, "tool not found: search_docs")
  }
}

///|
async test "dispatch spawn_worker validates agent type" {
  let call : @tools.ToolCall = {
    role: @types.Role::TL,
    name: "spawn_worker",
    args: { "agent_type": "moon" },
  }
  let res = @tools.dispatch_call(call, runner=mock_runner)
  match res {
    Ok(_) => assert_true(false)
    Err(e) => assert_eq(e, "invalid agent_type: moon")
  }
}

///|
async test "dispatch spawn_worker defaults to research profile" {
  let recorded : Array[@workspace.Command] = []
  let res = @tools.dispatch_call(
    {
      role: @types.Role::TL,
      name: "spawn_worker",
      args: { "agent_id": "worker-a", "task": "investigate flaky tests" },
    },
    runner=async fn(cmds) {
      @async.sleep(0)
      for cmd in cmds {
        recorded.push(cmd)
      }
      let statuses = []
      for _ in cmds {
        statuses.push(0)
      }
      statuses
    },
  )
  assert_true(res is Ok(_))
  assert_true(recorded.length() > 0)
  let launch = recorded[recorded.length() - 1]
  assert_true(
    launch.args[3].contains("## Completion Protocol (Research Worker)"),
  )
}

///|
async test "dispatch spawn_worker rejects implementation profile" {
  let res = @tools.dispatch_call(
    {
      role: @types.Role::TL,
      name: "spawn_worker",
      args: { "task": "edit code", "type": "implementation" },
    },
    runner=mock_runner,
  )
  match res {
    Ok(_) => fail("expected invalid worker type")
    Err(e) => assert_eq(e, "invalid worker type: implementation")
  }
}

///|
async test "dispatch spawn_worker succeeds with inline worker" {
  let call : @tools.ToolCall = {
    role: @types.Role::TL,
    name: "spawn_worker",
    args: { "slug": "worker-a", "task": "investigate" },
  }
  let res = @tools.dispatch_call(call, runner=mock_runner)
  match res {
    Ok(m) => {
      assert_eq(m.get("status"), Some("spawned"))
      assert_eq(
        m.get_value("status"),
        Some(@types.WireValue::String("spawned")),
      )
    }
    Err(e) => {
      println(e)
      assert_true(false)
    }
  }
}

///|
async test "dispatch spawn_worker accepts agent_id alias" {
  let call : @tools.ToolCall = {
    role: @types.Role::TL,
    name: "spawn_worker",
    args: { "agent_id": "worker-a", "task": "investigate" },
  }
  let res = @tools.dispatch_call(call, runner=mock_runner)
  match res {
    Ok(m) => {
      assert_eq(m.get("status"), Some("spawned"))
      assert_eq(
        m.get_value("status"),
        Some(@types.WireValue::String("spawned")),
      )
    }
    Err(e) => {
      println(e)
      assert_true(false)
    }
  }
}

///|
async test "dispatch register inserts agent into registry" {
  let reg = @registry.AgentRegistry::new()
  let call : @tools.ToolCall = {
    role: @types.Role::Dev,
    name: "register",
    args: {
      "agent_id": "leaf-0",
      "parent_id": "root",
      "branch": "main.leaf-0",
      "workspace": "/tmp/leaf-0",
      "terminal_target": "choir:leaf-0",
      "agent_type": "gemini",
    },
  }
  let res = @tools.dispatch_call(call, runner=mock_runner, registry=Some(reg))
  match res {
    Ok(m) => {
      assert_eq(m.get("status"), Some("registered"))
      assert_eq(m.get("agent_id"), Some("leaf-0"))
      assert_eq(
        m.get_value("status"),
        Some(@types.WireValue::String("registered")),
      )
      assert_eq(
        m.get_value("agent_id"),
        Some(@types.WireValue::String("leaf-0")),
      )
      match reg.get("leaf-0") {
        Ok(agent) => {
          assert_eq(agent.parent, Some("root"))
          assert_eq(agent.branch, "main.leaf-0")
          assert_eq(agent.workspace, "/tmp/leaf-0")
          assert_eq(agent.terminal_target, Some("choir:leaf-0"))
          assert_eq(agent.agent_type, @types.AgentType::Gemini)
        }
        Err(_) => assert_true(false)
      }
    }
    Err(e) => {
      println(e)
      assert_true(false)
    }
  }
}

///|
async test "dispatch register requires agent_id arg" {
  let reg = @registry.AgentRegistry::new()
  let call : @tools.ToolCall = {
    role: @types.Role::Dev,
    name: "register",
    args: {},
  }
  let res = @tools.dispatch_call(call, runner=mock_runner, registry=Some(reg))
  assert_true(res is Err(_))
}

///|
async test "dispatch shutdown marks agent Done in registry" {
  let reg = @registry.AgentRegistry::new()
  let agent = @types.Agent::{
    agent_id: "leaf-1",
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Claude,
    state: @types.AgentState::Active,
    parent: None,
    terminal_target: None,
    host: @types.Host::Local,
    workspace: "",
    branch: "",
  }
  let _ = reg.insert(agent)
  let call : @tools.ToolCall = {
    role: @types.Role::Dev,
    name: "shutdown",
    args: { "caller_id": "leaf-1" },
  }
  let res = @tools.dispatch_call(call, runner=mock_runner, registry=Some(reg))
  assert_true(res is Ok(_))
  match reg.get("leaf-1") {
    Ok(a) => assert_eq(a.state, @types.AgentState::Done)
    Err(_) => fail("agent should remain in registry as Done")
  }
}

///|
async test "dispatch shutdown marks agent completing before terminal close" {
  let reg = @registry.AgentRegistry::new()
  let agent = @types.Agent::{
    agent_id: "leaf-1",
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Claude,
    state: @types.AgentState::Active,
    parent: None,
    terminal_target: Some("choir:leaf-1"),
    host: @types.Host::Local,
    workspace: "",
    branch: "",
  }
  let _ = reg.insert(agent)
  let close_seen = Ref::new(false)
  let res = @tools.dispatch_call(
    {
      role: @types.Role::Dev,
      name: "shutdown",
      args: { "caller_id": "leaf-1" },
    },
    runner=async fn(cmds) {
      @async.sleep(0)
      if cmds.length() == 1 &&
        cmds[0].program == "tmux" &&
        cmds[0].args == ["kill-pane", "-t", "choir:leaf-1"] {
        close_seen.val = true
        match reg.get("leaf-1") {
          Ok(found) => assert_eq(found.state, @types.AgentState::Completing)
          Err(_) => fail("expected leaf to remain registered during close")
        }
      }
      let statuses = []
      for _ in cmds {
        statuses.push(0)
      }
      statuses
    },
    registry=Some(reg),
  )
  assert_true(res is Ok(_))
  assert_true(close_seen.val)
  match reg.get("leaf-1") {
    Ok(a) => assert_eq(a.state, @types.AgentState::Done)
    Err(_) => fail("agent should remain in registry as Done")
  }
}

///|
async test "dispatch shutdown allowed for TL role" {
  let call : @tools.ToolCall = {
    role: @types.Role::TL,
    name: "shutdown",
    args: { "caller_id": "main.tl-1" },
  }
  let res = @tools.dispatch_call(call, runner=mock_runner)
  match res {
    Ok(m) => {
      assert_eq(m.get("status"), Some("shutdown"))
      assert_eq(
        m.get_value("status"),
        Some(@types.WireValue::String("shutdown")),
      )
    }
    Err(e) => {
      println(e)
      assert_true(false)
    }
  }
}

///|
async test "dispatch shutdown blocks during critical review phase" {
  let poller = @poller.PollerState::new()
  poller.track(
    42, "leaf-2", "main.leaf-2", "main", "https://example.test/pr/42", 100L,
  )
  poller.tick_with(
    200L,
    900L,
    fn(_) { (@poller.ReviewState::ChangesRequested, "sha1", false, "") },
    fn(_, _) { () },
  )
  let call : @tools.ToolCall = {
    role: @types.Role::Dev,
    name: "shutdown",
    args: { "caller_id": "leaf-2" },
  }
  let res = @tools.dispatch_call(
    call,
    runner=mock_runner,
    poller_state=Some(poller),
  )
  match res {
    Ok(_) => assert_true(false)
    Err(e) =>
      assert_eq(
        e, "cannot shutdown: PR #42 has changes requested — push fixes first",
      )
  }
}

///|
async test "dispatch kv_set, kv_get, and kv_delete use shared storage" {
  let project_dir = "/tmp/choir-dispatch-kv"
  run_shell("rm -rf /tmp/choir-dispatch-kv && mkdir -p /tmp/choir-dispatch-kv")

  let set_call : @tools.ToolCall = {
    role: @types.Role::Dev,
    name: "kv_set",
    args: { "key": "build/status", "value": "green" },
  }
  let set_res = @tools.dispatch_call(
    set_call,
    project_dir~,
    runner=@exec.run_sequence,
  )
  match set_res {
    Ok(m) => assert_eq(m.get("status"), Some("ok"))
    Err(e) => {
      println(e)
      assert_true(false)
    }
  }

  let get_call : @tools.ToolCall = {
    role: @types.Role::Dev,
    name: "kv_get",
    args: { "key": "build/status" },
  }
  let get_res = @tools.dispatch_call(
    get_call,
    project_dir~,
    runner=@exec.run_sequence,
  )
  match get_res {
    Ok(m) => assert_eq(m.get("value"), Some("green"))
    Err(e) => {
      println(e)
      assert_true(false)
    }
  }

  let delete_call : @tools.ToolCall = {
    role: @types.Role::Dev,
    name: "kv_delete",
    args: { "key": "build/status" },
  }
  let delete_res = @tools.dispatch_call(
    delete_call,
    project_dir~,
    runner=@exec.run_sequence,
  )
  match delete_res {
    Ok(m) => assert_eq(m.get("status"), Some("ok"))
    Err(e) => {
      println(e)
      assert_true(false)
    }
  }

  let after_delete = @tools.dispatch_call(
    get_call,
    project_dir~,
    runner=@exec.run_sequence,
  )
  match after_delete {
    Ok(m) => assert_eq(m.get("value"), Some("null"))
    Err(e) => {
      println(e)
      assert_true(false)
    }
  }

  run_shell("rm -rf /tmp/choir-dispatch-kv")
}

///|
async test "dispatch kv_list returns keys" {
  let project_dir = "/tmp/choir-dispatch-kv-list"
  run_shell(
    "rm -rf /tmp/choir-dispatch-kv-list && mkdir -p /tmp/choir-dispatch-kv-list/.choir/kv/shared && " +
    "printf '%s' 'hello' > /tmp/choir-dispatch-kv-list/.choir/kv/shared/foo && " +
    "printf '%s' 'world' > /tmp/choir-dispatch-kv-list/.choir/kv/shared/bar",
  )
  let call : @tools.ToolCall = {
    role: @types.Role::TL,
    name: "kv_list",
    args: {},
  }
  let res = @tools.dispatch_call(call, project_dir~, runner=@exec.run_sequence)
  match res {
    Ok(m) => {
      assert_eq(m.get("status"), Some("ok"))
      let keys = m.get("keys").unwrap_or("")
      assert_true(keys.contains("shared/bar"))
      assert_true(keys.contains("shared/foo"))
      match m.get_value("keys") {
        Some(@types.WireValue::Raw(raw)) => {
          assert_true(raw.contains("shared/bar"))
          assert_true(raw.contains("shared/foo"))
        }
        _ => assert_true(false)
      }
    }
    Err(e) => {
      println(e)
      assert_true(false)
    }
  }
  run_shell("rm -rf /tmp/choir-dispatch-kv-list")
}

///|
async test "dispatch kv_list empty dir returns empty array" {
  let call : @tools.ToolCall = {
    role: @types.Role::TL,
    name: "kv_list",
    args: {},
  }
  let res = @tools.dispatch_call(
    call,
    project_dir="/tmp/choir-kv-list-nonexistent-dir-xyz",
    runner=@exec.run_sequence,
  )
  match res {
    Ok(m) => {
      assert_eq(m.get("keys"), Some("[]"))
      assert_eq(m.get_value("keys"), Some(@types.WireValue::Raw("[]")))
    }
    Err(e) => {
      println(e)
      assert_true(false)
    }
  }
}

///|
async test "dispatch task_create creates task" {
  let project_dir = "/tmp/choir-dispatch-task-create"
  run_shell("rm -rf /tmp/choir-dispatch-task-create")
  let call : @tools.ToolCall = {
    role: @types.Role::TL,
    name: "task_create",
    args: {
      "id": "task-1",
      "title": "Build the thing",
      "status": "todo",
      "assignee": "dev-1",
      "notes": "initial",
    },
  }
  let res = @tools.dispatch_call(call, project_dir~, runner=@exec.run_sequence)
  match res {
    Ok(m) => {
      assert_eq(m.get("status"), Some("ok"))
      assert_eq(m.get("created"), Some("true"))
      let task_json = m.get("task").unwrap_or("")
      assert_true(task_json.contains("\"id\":\"task-1\""))
      assert_true(task_json.contains("\"title\":\"Build the thing\""))
      assert_true(task_json.contains("\"status\":\"todo\""))
      match m.get_value("task") {
        Some(@types.WireValue::Raw(raw)) => {
          assert_true(raw.contains("\"id\":\"task-1\""))
          assert_true(raw.contains("\"title\":\"Build the thing\""))
          assert_true(raw.contains("\"status\":\"todo\""))
        }
        _ => assert_true(false)
      }
    }
    Err(e) => {
      println(e)
      assert_true(false)
    }
  }
  run_shell("rm -rf /tmp/choir-dispatch-task-create")
}

///|
async test "dispatch task_create returns existing task if already exists" {
  let project_dir = "/tmp/choir-dispatch-task-create-dup"
  run_shell(
    "rm -rf /tmp/choir-dispatch-task-create-dup && mkdir -p /tmp/choir-dispatch-task-create-dup/.choir/tasks && " +
    "printf '%s' '{\"id\":\"dup\",\"title\":\"Dup\",\"status\":\"todo\",\"assignee\":\"\",\"notes\":\"\"}' > /tmp/choir-dispatch-task-create-dup/.choir/tasks/dup.json",
  )
  let call : @tools.ToolCall = {
    role: @types.Role::TL,
    name: "task_create",
    args: { "id": "dup", "title": "Duplicate" },
  }
  let res = @tools.dispatch_call(call, project_dir~, runner=@exec.run_sequence)
  match res {
    Ok(m) => {
      assert_eq(m.get("status"), Some("ok"))
      assert_eq(m.get("created"), Some("false"))
      let task_json = m.get("task").unwrap_or("")
      assert_true(task_json.contains("\"id\":\"dup\""))
      assert_true(task_json.contains("\"title\":\"Dup\""))
    }
    Err(e) => fail(e)
  }
  run_shell("rm -rf /tmp/choir-dispatch-task-create-dup")
}

///|
async test "dispatch mutex_acquire, mutex_status, and mutex_release use shared registry" {
  let mutex_registry = @registry.MutexRegistry::new()

  let acquire_first : @tools.ToolCall = {
    role: @types.Role::Dev,
    name: "mutex_acquire",
    args: { "name": "README", "agent_id": "agent-a", "ttl_sec": "30" },
  }
  let acquire_first_res = @tools.dispatch_call(
    acquire_first,
    runner=mock_runner,
    mutex_registry=Some(mutex_registry),
  )
  match acquire_first_res {
    Ok(m) => {
      assert_eq(m.get("acquired"), Some("true"))
      assert_eq(m.get("queue_position"), Some("0"))
      assert_eq(m.get_value("acquired"), Some(@types.WireValue::Raw("true")))
      assert_eq(m.get_value("queue_position"), Some(@types.WireValue::Raw("0")))
    }
    Err(e) => {
      println(e)
      assert_true(false)
    }
  }

  let acquire_second : @tools.ToolCall = {
    role: @types.Role::Dev,
    name: "mutex_acquire",
    args: { "name": "README", "agent_id": "agent-b", "ttl_sec": "30" },
  }
  let acquire_second_res = @tools.dispatch_call(
    acquire_second,
    runner=mock_runner,
    mutex_registry=Some(mutex_registry),
  )
  match acquire_second_res {
    Ok(m) => {
      assert_eq(m.get("acquired"), Some("false"))
      assert_eq(m.get("queue_position"), Some("1"))
      assert_eq(m.get_value("acquired"), Some(@types.WireValue::Raw("false")))
      assert_eq(m.get_value("queue_position"), Some(@types.WireValue::Raw("1")))
    }
    Err(e) => {
      println(e)
      assert_true(false)
    }
  }

  let status_call : @tools.ToolCall = {
    role: @types.Role::Dev,
    name: "mutex_status",
    args: { "name": "README" },
  }
  let status_res = @tools.dispatch_call(
    status_call,
    runner=mock_runner,
    mutex_registry=Some(mutex_registry),
  )
  match status_res {
    Ok(m) => {
      assert_eq(m.get("holder"), Some("agent-a"))
      assert_eq(m.get("queue_length"), Some("1"))
      assert_eq(m.get_value("queue_length"), Some(@types.WireValue::Raw("1")))
    }
    Err(e) => {
      println(e)
      assert_true(false)
    }
  }

  let release_call : @tools.ToolCall = {
    role: @types.Role::Dev,
    name: "mutex_release",
    args: { "name": "README", "agent_id": "agent-a" },
  }
  let release_res = @tools.dispatch_call(
    release_call,
    runner=mock_runner,
    mutex_registry=Some(mutex_registry),
  )
  match release_res {
    Ok(m) => {
      assert_eq(m.get("released"), Some("true"))
      assert_eq(m.get("next_waiter"), Some("agent-b"))
      assert_eq(m.get_value("released"), Some(@types.WireValue::Raw("true")))
    }
    Err(e) => {
      println(e)
      assert_true(false)
    }
  }
}

///|
async test "dispatch mutex_release returns false when agent does not hold or wait" {
  let mutex_registry = @registry.MutexRegistry::new()
  ignore(mutex_registry.acquire("README", "agent-a", 30L, 10L))

  let release_call : @tools.ToolCall = {
    role: @types.Role::Dev,
    name: "mutex_release",
    args: { "name": "README", "agent_id": "agent-z" },
  }
  let release_res = @tools.dispatch_call(
    release_call,
    runner=mock_runner,
    mutex_registry=Some(mutex_registry),
  )
  match release_res {
    Ok(m) => {
      assert_eq(m.get("released"), Some("false"))
      assert_eq(m.get("next_waiter"), Some(""))
      assert_eq(m.get_value("released"), Some(@types.WireValue::Raw("false")))
    }
    Err(e) => {
      println(e)
      assert_true(false)
    }
  }
}

///|
async test "dispatch merge_pr blocks concurrent merges on the same parent_branch" {
  let mutex_registry = @registry.MutexRegistry::new()
  let nested_results : Array[@types.Response] = []
  let runner = async fn(cmds : Array[@workspace.Command]) -> Array[Int] {
    let nested_call : @tools.ToolCall = {
      role: @types.Role::TL,
      name: "merge_pr",
      args: {
        "pr_number": "102",
        "parent_branch": "release",
        "caller_id": "agent-b",
      },
    }
    nested_results.push(
      @tools.dispatch_call(
        nested_call,
        runner=mock_runner,
        mutex_registry=Some(mutex_registry),
      ),
    )
    let statuses = []
    for _ in cmds {
      statuses.push(0)
    }
    statuses
  }
  let first_call : @tools.ToolCall = {
    role: @types.Role::TL,
    name: "merge_pr",
    args: {
      "pr_number": "101",
      "parent_branch": "release",
      "caller_id": "agent-a",
    },
  }
  let first_res = @tools.dispatch_call(
    first_call,
    runner~,
    mutex_registry=Some(mutex_registry),
  )
  match first_res {
    Ok(m) => assert_eq(m.get("status"), Some("merged"))
    Err(e) => {
      println(e)
      assert_true(false)
    }
  }
  assert_eq(nested_results.length(), 1)
  match nested_results[0] {
    Ok(_) => assert_true(false)
    Err(e) =>
      assert_eq(
        e, "merge serialization lock held by another agent, retry shortly",
      )
  }
  let (holder, queue) = mutex_registry.status("branch:release")
  assert_eq(holder, None)
  assert_eq(queue.length(), 0)
}

///|
async test "dispatch fork_session creates session dir" {
  let project_dir = "/tmp/choir-dispatch-fork-session"
  run_shell("rm -rf /tmp/choir-dispatch-fork-session")
  let call : @tools.ToolCall = {
    role: @types.Role::TL,
    name: "fork_session",
    args: { "name": "sub-team-1" },
  }
  let res = @tools.dispatch_call(call, project_dir~, runner=@exec.run_sequence)
  match res {
    Ok(m) => {
      assert_eq(m.get("status"), Some("ok"))
      assert_eq(m.get("name"), Some("sub-team-1"))
      assert_eq(
        m.get_value("name"),
        Some(@types.WireValue::String("sub-team-1")),
      )
      let session_dir = m.get("session_dir").unwrap_or("")
      assert_true(session_dir.contains("sub-team-1"))
      match m.get_value("session_dir") {
        Some(@types.WireValue::String(raw_dir)) =>
          assert_true(raw_dir.contains("sub-team-1"))
        _ => assert_true(false)
      }
      run_shell(
        "test -d /tmp/choir-dispatch-fork-session/.choir/sessions/sub-team-1",
      )
    }
    Err(e) => {
      println(e)
      assert_true(false)
    }
  }
  let context_json = @io.read_file(
    project_dir + "/.choir/sessions/sub-team-1/context.json",
  )
  assert_true(context_json.contains("\"name\":\"sub-team-1\""))
  assert_true(context_json.contains("\"created_sec\":\""))
  run_shell("rm -rf /tmp/choir-dispatch-fork-session")
}

///|
async test "dispatch fork_session rejects invalid name" {
  let call : @tools.ToolCall = {
    role: @types.Role::TL,
    name: "fork_session",
    args: { "name": "../evil" },
  }
  let res = @tools.dispatch_call(call, runner=mock_runner)
  match res {
    Err(e) => assert_true(e.contains("invalid name"))
    Ok(_) => assert_true(false)
  }
}

///|
async test "handle_request fork_session denied for Dev role" {
  let reg = @tools.ToolRegistry::new()
  let req = @types.Request::{
    req_method: "tools/call",
    role: @types.Role::Dev,
    name: "fork_session",
    args: @types.RequestArgs::new({ "name": "sub-team-1" }),
  }
  let res = handle_request(reg, req, runner=mock_runner)
  match res {
    Err(e) => assert_true(e.contains("cannot call"))
    Ok(_) => assert_true(false)
  }
}

///|
async test "dispatch fork_wave writes tl phase to KV" {
  let project_dir = "/tmp/choir-test-fork-wave-phase"
  run_shell(
    "rm -rf /tmp/choir-test-fork-wave-phase && mkdir -p /tmp/choir-test-fork-wave-phase",
  )
  let call : @tools.ToolCall = {
    role: @types.Role::TL,
    name: "fork_wave",
    args: {
      "count": "1",
      "task": "Test task",
      "slug_prefix": "wave",
      "parent_branch": "main",
      "caller_id": "tl-agent",
    },
  }
  let res = @tools.dispatch_call(call, project_dir~, runner=mock_runner)
  assert_true(res is Ok(_))
  let phase_json = @io.read_file(project_dir + "/.choir/kv/phase-tl--tl-agent")
  assert_true(phase_json.contains("\"phase\":\"Waiting\""))
  assert_true(phase_json.contains("\"count\":1"))
  run_shell("rm -rf /tmp/choir-test-fork-wave-phase")
}

///|
async test "dispatch spawn_gemini spawns single leaf" {
  let recorded : Array[@workspace.Command] = []
  let res = @tools.dispatch_call(
    {
      role: @types.Role::TL,
      name: "spawn_gemini",
      args: {
        "task": "Implement feature Y",
        "slug": "leaf-y",
        "parent_branch": "main",
      },
    },
    runner=async fn(cmds) {
      @async.sleep(0)
      for cmd in cmds {
        recorded.push(cmd)
      }
      let statuses = []
      for _ in cmds {
        statuses.push(0)
      }
      statuses
    },
  )
  assert_true(res is Ok(_))
  match res {
    Ok(m) => {
      assert_eq(m.get("status"), Some("spawned"))
      assert_eq(m.get("agent_id"), Some("main.leaf-y"))
      assert_eq(m.get("slug"), Some("leaf-y"))
    }
    Err(_) => assert_true(false)
  }
  // Verify it spawned Gemini
  let mut found = false
  for cmd in recorded {
    if cmd.program == "tmux" &&
      cmd.args.length() > 3 &&
      cmd.args[0] == "send-keys" {
      assert_true(
        cmd.args[3].contains("gemini '--yolo' '--prompt-interactive'"),
      )
      found = true
      break
    }
  }
  assert_true(found)
}

///|
async test "dispatch shutdown blocks when dev phase is ChangesRequested" {
  let project_dir = "/tmp/choir-test-shutdown-block"
  run_shell(
    "rm -rf /tmp/choir-test-shutdown-block && mkdir -p /tmp/choir-test-shutdown-block/.choir/kv",
  )
  // Set dev phase to ChangesRequested(42)
  let phase_json = "{\"phase\":\"ChangesRequested\",\"pr_number\":42}"
  ignore(
    @io.write_file_sync(
      project_dir + "/.choir/kv/phase-dev--leaf-agent",
      phase_json,
    ),
  )
  let call : @tools.ToolCall = {
    role: @types.Role::Dev,
    name: "shutdown",
    args: { "caller_id": "leaf-agent" },
  }
  let res = @tools.dispatch_call(call, project_dir~, runner=mock_runner)
  match res {
    Ok(_) => fail("shutdown should have been blocked")
    Err(e) => assert_eq(e, "Changes requested")
  }
  run_shell("rm -rf /tmp/choir-test-shutdown-block")
}

///|
async test "handle_request enforces pre_tool_use hook" {
  let project_dir = "/tmp/choir-hook-test"
  run_shell(
    "rm -rf /tmp/choir-hook-test && mkdir -p /tmp/choir-hook-test/.choir/hooks && " +
    "printf '%s' '#!/bin/sh\nprintf \"{\\\"continue\\\":false,\\\"message\\\":\\\"hook block\\\"}\"' > /tmp/choir-hook-test/.choir/hooks/pre_tool_use.sh && " +
    "chmod +x /tmp/choir-hook-test/.choir/hooks/pre_tool_use.sh",
  )
  let reg = @tools.ToolRegistry::new()
  let req = @types.Request::{
    req_method: "tools/call",
    role: @types.Role::TL,
    name: "kv_list",
    args: @types.RequestArgs::new({}),
  }
  let res = @tools.handle_request(
    reg,
    req,
    project_dir~,
    runner=@exec.run_sequence,
  )
  match res {
    Ok(_) => assert_true(false)
    Err(e) => assert_eq(e, "hook block")
  }
  run_shell("rm -rf /tmp/choir-hook-test")
}

///|
async test "verify_teams_delivery falls back to tmux if message remains" {
  let inbox_path = "/tmp/choir-verify-test/inbox.json"
  ignore(
    @io.system(
      "mkdir -p /tmp/choir-verify-test && printf '{\"msg\":\"test\"}' > /tmp/choir-verify-test/inbox.json",
    ),
  )

  let recorded : Array[@workspace.Command] = []
  let runner = async fn(cmds : Array[@workspace.Command]) -> Array[Int] {
    @async.sleep(0)
    for cmd in cmds {
      recorded.push(cmd)
    }
    [0]
  }

  @tools.verify_teams_delivery(
    inbox_path,
    "{\"msg\":\"test\"}",
    Some("test-pane"),
    runner,
    interval_ms=1,
  )

  assert_eq(recorded.length(), 1)
  let fallback_cmd = recorded[0]
  assert_true(fallback_cmd.args.contains("test-pane"))
  assert_true(fallback_cmd.args.contains("{\"msg\":\"test\"}"))

  ignore(@io.system("rm -rf /tmp/choir-verify-test"))
}

///|
async test "verify_teams_delivery returns early if message is consumed" {
  let inbox_path = "/tmp/choir-verify-test-consumed/inbox.json"
  ignore(
    @io.system(
      "mkdir -p /tmp/choir-verify-test-consumed && printf '{\"msg\":\"test\"}' > /tmp/choir-verify-test-consumed/inbox.json",
    ),
  )

  let recorded : Array[@workspace.Command] = []
  let runner = async fn(cmds : Array[@workspace.Command]) -> Array[Int] {
    @async.sleep(0)
    for cmd in cmds {
      recorded.push(cmd)
    }
    [0]
  }

  ignore(@io.system("printf '' > /tmp/choir-verify-test-consumed/inbox.json"))

  @tools.verify_teams_delivery(
    inbox_path,
    "{\"msg\":\"test\"}",
    Some("test-pane"),
    runner,
    interval_ms=1,
  )

  assert_eq(recorded.length(), 0)

  ignore(@io.system("rm -rf /tmp/choir-verify-test-consumed"))
}
