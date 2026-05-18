///|
async fn mock_registry_ensure_pr(
  branch : String,
  _parent_branch : String,
  _project_dir : String,
  _title : String?,
  _body : String?,
) -> Result[@tools.PullRequestInfo, @types.ChoirError] {
  @async.sleep(0)
  Ok({ number: 1, url: "https://example.test/pr/" + branch, state: "OPEN" })
}

///|
async fn mock_registry_branch_ready(
  _branch : String,
  _parent_branch : String,
  _project_dir : String,
) -> Result[Unit, @types.ChoirError] {
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
fn registry_test_audit_receipt(sha : String) -> String {
  let receipt : @types.AuditReceipt = {
    sha,
    branch: "test",
    audited_at: 1770000000L,
    agent_id: "main.tl",
    findings_count: 0,
  }
  receipt.to_json().stringify() + "\n"
}

///|
async fn mock_registry_capture(cmd : @workspace.Command) -> (Int, String) {
  @async.sleep(0)
  if cmd.program == "git" &&
    cmd.args == ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"] {
    return (0, "origin/main\n")
  }
  if cmd.program == "git" && cmd.args == ["rev-parse", "HEAD"] {
    return (0, "hash\n")
  }
  if cmd.program == "git" && cmd.args == ["remote", "get-url", "origin"] {
    return (0, "https://github.com/brickfrog/choir.git\n")
  }
  if cmd.program == "cat" &&
    cmd.args.length() == 1 &&
    cmd.args[0] == ".choir/audit-receipts/hash.json" {
    return (0, registry_test_audit_receipt("hash"))
  }
  if cmd.program == "zellij" {
    return (1, "")
  }
  if cmd.program == "timeout" && cmd.args.length() >= 2 && cmd.args[1] == "gh" {
    if cmd.args.contains("repo") && cmd.args.contains("view") {
      return (0, "{\"owner\":{\"login\":\"brickfrog\"},\"name\":\"choir\"}")
    }
    if cmd.args.contains("graphql") {
      return (
        0, "{\"data\":{\"repository\":{\"pullRequest\":{\"reviewThreads\":{\"nodes\":[]}}}}}",
      )
    }
    return (0, "")
  }
  if cmd.program == "gh" {
    if cmd.args.length() >= 2 &&
      cmd.args[0] == "api" &&
      cmd.args[1].has_suffix("/reviews") {
      return (0, "[{\"state\":\"APPROVED\"}]")
    }
    if cmd.args.contains("repo") && cmd.args.contains("view") {
      return (0, "{\"owner\":{\"login\":\"brickfrog\"},\"name\":\"choir\"}")
    }
    if cmd.args.contains("graphql") {
      return (
        0, "{\"data\":{\"repository\":{\"pullRequest\":{\"reviewThreads\":{\"nodes\":[]}}}}}",
      )
    }
    if cmd.args.contains("comments") {
      return (0, "[]")
    }
    return (0, "")
  }
  if cmd.program == "bd" && cmd.args == ["list", "--json", "--all"] {
    return (0, "[]")
  }
  (0, "")
}

///|
async fn mock_registry_capture_with_pane(
  cmd : @workspace.Command,
) -> (Int, String) {
  @async.sleep(0)
  if cmd.program == "zellij" {
    return (
      0, "[{\"id\":17,\"tab_name\":\"claude-pane-leaf-0\",\"is_plugin\":false}]",
    )
  }
  mock_registry_capture(cmd)
}

///|
fn escape_registry_test_toml_string(s : String) -> String {
  let buf = StringBuilder::new()
  for c in s {
    match c {
      '"' => buf.write_string("\\\"")
      '\\' => buf.write_string("\\\\")
      '\n' => buf.write_string("\\n")
      '\r' => buf.write_string("\\r")
      '\t' => buf.write_string("\\t")
      _ => buf.write_char(c)
    }
  }
  buf.to_string()
}

///|
async fn mock_clean_git(program : String, args : Array[String]) -> String {
  @async.sleep(0)
  if args.contains("rev-parse") {
    if args.contains("--abbrev-ref") {
      for i = 0; i < args.length() - 1; i = i + 1 {
        if args[i] == "-C" {
          let dir = args[i + 1]
          if dir.contains("task-leaf") {
            return "main.task-leaf\n"
          }
          if dir.contains("auto-notify-leaf") {
            return "main.auto-notify-leaf\n"
          }
          if dir.contains("auto-notify-orphan") {
            return "main.auto-notify-orphan\n"
          }
          if dir.contains("auto-notify") {
            // This covers the generic auto-notify test which uses main.auto-notify-leaf
            return "main.auto-notify-leaf\n"
          }
        }
      }
      return "test\n"
    }
    return "hash\n"
  } else if program == "gh" && args.contains("view") {
    let mut pr_number = 1
    for i = 0; i < args.length() - 1; i = i + 1 {
      if args[i] == "-C" {
        let dir = args[i + 1]
        if dir.contains("auto-notify") {
          pr_number = 99
        }
      }
    }
    let mut url = "http://github.com/pr/" + pr_number.to_string()
    for i = 0; i < args.length() - 1; i = i + 1 {
      if args[i] == "-C" {
        let dir = args[i + 1]
        if dir.contains("auto-notify") {
          pr_number = 99
          url = "https://auto.test/pr"
        }
      }
    }
    "{\"number\": " +
    pr_number.to_string() +
    ", \"url\": \"" +
    url +
    "\", \"state\": \"OPEN\"}\n"
  } else {
    ""
  }
}

///|
async fn mock_dirty_git(program : String, args : Array[String]) -> String {
  @async.sleep(0)
  if args.contains("status") {
    " M src/foo.mbt\n"
  } else if args.contains("rev-parse") {
    if args.contains("--abbrev-ref") {
      return "test\n"
    }
    "hash\n"
  } else if program == "gh" && args.contains("view") {
    let mut pr_number = 1
    for i = 0; i < args.length() - 1; i = i + 1 {
      if args[i] == "-C" {
        let dir = args[i + 1]
        if dir.contains("auto-notify") {
          pr_number = 99
        }
      }
    }
    let mut url = "http://github.com/pr/" + pr_number.to_string()
    for i = 0; i < args.length() - 1; i = i + 1 {
      if args[i] == "-C" {
        let dir = args[i + 1]
        if dir.contains("auto-notify") {
          pr_number = 99
          url = "https://auto.test/pr"
        }
      }
    }
    "{\"number\": " +
    pr_number.to_string() +
    ", \"url\": \"" +
    url +
    "\", \"state\": \"OPEN\"}\n"
  } else {
    ""
  }
}

///|
async fn mock_unpushed_git(program : String, args : Array[String]) -> String {
  @async.sleep(0)
  if args.contains("log") {
    "hash commit title\n"
  } else if args.contains("rev-parse") {
    if args.contains("--abbrev-ref") {
      return "test\n"
    }
    "hash\n"
  } else if program == "gh" && args.contains("view") {
    let mut pr_number = 1
    for i = 0; i < args.length() - 1; i = i + 1 {
      if args[i] == "-C" {
        let dir = args[i + 1]
        if dir.contains("auto-notify") {
          pr_number = 99
        }
      }
    }
    let mut url = "http://github.com/pr/" + pr_number.to_string()
    for i = 0; i < args.length() - 1; i = i + 1 {
      if args[i] == "-C" {
        let dir = args[i + 1]
        if dir.contains("auto-notify") {
          pr_number = 99
          url = "https://auto.test/pr"
        }
      }
    }
    "{\"number\": " +
    pr_number.to_string() +
    ", \"url\": \"" +
    url +
    "\", \"state\": \"OPEN\"}\n"
  } else {
    ""
  }
}

///|
async fn mock_registry_branch_ready_capture(
  _branch : String,
  _parent_branch : String,
  project_dir : String,
) -> Result[Unit, @types.ChoirError] {
  @async.sleep(0)
  if project_dir == "/tmp/task-leaf-worktree" {
    Ok(())
  } else {
    Err(
      @types.ChoirError::validation_error(
        "wrong ensure_branch_ready project_dir: " + project_dir,
      ),
    )
  }
}

///|
async fn mock_registry_ensure_pr_capture(
  branch : String,
  _parent_branch : String,
  project_dir : String,
  _title : String?,
  _body : String?,
) -> Result[@tools.PullRequestInfo, @types.ChoirError] {
  @async.sleep(0)
  if project_dir != "/tmp/task-leaf-worktree" {
    return Err(
      @types.ChoirError::validation_error(
        "wrong ensure_pr project_dir: " + project_dir,
      ),
    )
  }
  Ok({ number: 1, url: "https://example.test/pr/" + branch, state: "OPEN" })
}

///|
async fn mock_auto_notify_ensure_pr(
  _branch : String,
  _parent_branch : String,
  _project_dir : String,
  _title : String?,
  _body : String?,
) -> Result[@tools.PullRequestInfo, @types.ChoirError] {
  @async.sleep(0)
  Ok({ number: 99, url: "https://auto.test/pr", state: "OPEN" })
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
  let result = try? reg.lookup(@types.Role::TL, "fork_wave")
  assert_true(result is Ok(_))
}

///|
test "tool registry marks read-only tools" {
  let reg = @tools.ToolRegistry::new()
  for
    name in [
      "status_bar_state", "wave_state", "kv_get", "kv_list", "mutex_status", "goal_status",
      "agent_list",
    ] {
    try reg.lookup(@types.Role::Root, name) catch {
      _ => fail("expected read-only tool lookup: " + name)
    } noraise {
      def => assert_true(def.read_only)
    }
  }
  for name in ["task_get", "task_list"] {
    try reg.lookup(@types.Role::TL, name) catch {
      _ => fail("expected read-only tool lookup: " + name)
    } noraise {
      def => assert_true(def.read_only)
    }
  }
}

///|
test "tool registry defaults mutating tools to read_only false" {
  let reg = @tools.ToolRegistry::new()
  for name in ["merge_pr", "kv_set", "mutex_acquire", "server_reload"] {
    try reg.lookup(@types.Role::Root, name) catch {
      _ => fail("expected mutating tool lookup: " + name)
    } noraise {
      def => assert_false(def.read_only)
    }
  }
  for name in ["file_pr", "track_pr", "task_update"] {
    try reg.lookup(@types.Role::TL, name) catch {
      _ => fail("expected mutating tool lookup: " + name)
    } noraise {
      def => assert_false(def.read_only)
    }
  }
}

///|
test "tool registry lookup wrong role" {
  let reg = @tools.ToolRegistry::new()
  let result = try? reg.lookup(@types.Role::Worker, "fork_wave")
  assert_true(result is Err(_))
}

///|
test "permission denied response uses wire role casing" {
  let reg = @tools.ToolRegistry::new()
  try reg.lookup(@types.Role::Worker, "fork_wave") catch {
    e =>
      assert_eq(
        @types.choir_error_message_from_caught(e),
        "role worker cannot call fork_wave",
      )
  } noraise {
    _ => fail("expected permission denied for Worker calling fork_wave")
  }
}

///|
test "tool registry lookup unknown tool" {
  let reg = @tools.ToolRegistry::new()
  let result = try? reg.lookup(@types.Role::TL, "nonexistent")
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
    let result = try? reg.lookup(role, "send_message")
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
    let result = try? reg.lookup(role, "reply")
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
      let result = try? reg.lookup(role, name)
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
    args: @types.RequestArgs::new({ "count": "3", "caller_id": "main.tl" }),
  }
  let res = handle_request(
    reg,
    req,
    project_dir="/tmp/choir-test-noop",
    runner=mock_registry_runner,
    git_capture=mock_clean_git,
    capture=mock_registry_capture,
  )
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
async test "dispatch_call rejects goal tools for non TL roles" {
  let resp = @tools.dispatch_call(
    ToolCall::{
      role: @types.Role::Dev,
      name: "goal_set",
      args: { "input": "ship it", "verify": "true" },
    },
    project_dir="/repo",
  )
  match resp.error_message() {
    Some(msg) => assert_eq(msg, "role dev cannot call goal_set")
    None => fail("expected dispatch_call goal_set permission denial")
  }
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
  let project_dir = "/tmp/choir-dispatch-stub-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  assert_true(@sys.create_dir_all(project_dir + "/.choir/kv"))
  let cases = [
    ("fork_wave", "spawned", { "count": "1", "caller_id": "main.tl" }),
    ("fork_session", "ok", { "name": "nested-team" }),
    ("file_pr", "pr_created", { "branch": "test" }),
    ("merge_pr", "merged", { "pr_number": "1" }),
    ("track_pr", "tracked", { "pr_number": "1", "agent_id": "agent-1" }),
    ("notify_parent", "notified", { "caller_id": "test-agent" }),
    ("send_message", "sent", { "target_id": "test-agent" }),
    ("reply", "ok", { "id": "req-1" }),
    ("kv_get", "", { "key": "missing" }),
    ("mutex_status", "", { "name": "readme" }),
    ("shutdown", "shutdown", Map([], capacity=0)),
    ("task_list", "ok", Map([], capacity=0)),
    (
      "write_audit_receipt",
      "ok",
      {
        "caller_id": "main.tl",
        // Must be a 40-char lowercase-hex SHA-1; the validator rejects
        // anything else to defend against path traversal in the on-disk
        // receipt filename.
        "sha": "0123456789abcdef0123456789abcdef01234567",
        "branch": "test",
        "findings_count": "0",
      },
    ),
    ("spawn_worker", "spawned", { "caller_id": "main.tl" }),
  ]
  for c in cases {
    let (name, expected_status, args) = c
    // write_audit_receipt is restricted to Root/TL/Worker — Dev forging
    // its own audit receipt would bypass the file_pr feature→main gate.
    // Drive the dispatch with a TL role for that case; everything else
    // stays on Dev to exercise the broader role permissions.
    let role = if name == "write_audit_receipt" {
      @types.Role::TL
    } else {
      @types.Role::Dev
    }
    let call = ToolCall::{ role, name, args }
    let res = @tools.dispatch_call(
      call,
      project_dir~,
      runner=mock_registry_runner,
      git_capture=mock_clean_git,
      capture=mock_registry_capture,
      bd_capture=mock_registry_capture,
      ensure_branch_ready=Some(mock_registry_branch_ready),
      ensure_pr=Some(mock_registry_ensure_pr),
      mutex_registry=Some(@registry.MutexRegistry::new()),
      poller_state=Some(@poller.PollerState::new()),
    )
    match res {
      Ok(map) =>
        if name == "kv_get" {
          @debug.assert_eq(map.get("value"), Some("null"))
        } else if name == "mutex_status" {
          @debug.assert_eq(map.get("holder"), Some(""))
          @debug.assert_eq(map.get("queue_length"), Some("0"))
          @debug.assert_eq(map.get_json("queue_length"), Some((0).to_json()))
        } else if name == "track_pr" {
          @debug.assert_eq(map.get("status"), Some("tracked"))
          @debug.assert_eq(map.get("branch"), Some("agent-1"))
          @debug.assert_eq(map.get("parent_branch"), Some("main"))
          @debug.assert_eq(map.get("pr_url"), Some(""))
          @debug.assert_eq(map.get_json("status"), Some("tracked".to_json()))
        } else {
          @debug.assert_eq(map.get("status"), Some(expected_status))
        }
      Err(msg) => {
        println(name + ": " + msg)
        assert_true(false)
      }
    }
  }
}

///|
async test "dispatch_call reply then kv_get round trip reply-- key" {
  let project_dir = "/tmp/choir-reply-kv-rt-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.create_dir_all(project_dir + "/.choir/kv"))
  let reply_id = "req-roundtrip-7"
  let payload = "hello-from-reply-tool"
  let key = "reply--" + reply_id
  let reply_call = @tools.ToolCall::{
    role: @types.Role::Dev,
    name: "reply",
    args: { "id": reply_id, "payload": payload },
  }
  match
    @tools.dispatch_call(
      reply_call,
      project_dir~,
      runner=mock_registry_runner,
      git_capture=mock_clean_git,
      capture=mock_registry_capture,
      ensure_branch_ready=Some(mock_registry_branch_ready),
      ensure_pr=Some(mock_registry_ensure_pr),
      mutex_registry=Some(@registry.MutexRegistry::new()),
      poller_state=Some(@poller.PollerState::new()),
    ) {
    Ok(map) => {
      @debug.assert_eq(map.get("status"), Some("ok"))
      @debug.assert_eq(map.get("id"), Some(reply_id))
    }
    Err(m) => fail("reply dispatch: " + m)
  }
  let get_call = @tools.ToolCall::{
    role: @types.Role::Dev,
    name: "kv_get",
    args: { "key": key },
  }
  match
    @tools.dispatch_call(
      get_call,
      project_dir~,
      runner=mock_registry_runner,
      git_capture=mock_clean_git,
      capture=mock_registry_capture,
      ensure_branch_ready=Some(mock_registry_branch_ready),
      ensure_pr=Some(mock_registry_ensure_pr),
      mutex_registry=Some(@registry.MutexRegistry::new()),
      poller_state=Some(@poller.PollerState::new()),
    ) {
    Ok(map) => @debug.assert_eq(map.get("value"), Some(payload))
    Err(m) => fail("kv_get: " + m)
  }
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "dispatch spawn_worker registers inline worker with stable agent id" {
  let project_dir = "/tmp/choir-spawn-worker-reg-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  assert_true(@sys.create_dir_all(project_dir + "/.choir/kv"))
  let agent_reg = @registry.AgentRegistry::new()
  let call = ToolCall::{
    role: @types.Role::TL,
    name: "spawn_worker",
    args: {
      "caller_id": "root",
      "slug": "claude-worker",
      "agent_type": "claude",
      "task": "report findings",
    },
  }
  let res = @tools.dispatch_call(
    call,
    project_dir~,
    session="choir",
    runner=mock_registry_runner,
    git_capture=mock_clean_git,
    capture=mock_registry_capture,
    ensure_branch_ready=Some(mock_registry_branch_ready),
    ensure_pr=Some(mock_registry_ensure_pr),
    registry=Some(agent_reg),
    mutex_registry=Some(@registry.MutexRegistry::new()),
    poller_state=Some(@poller.PollerState::new()),
  )
  match res {
    Ok(map) => {
      @debug.assert_eq(map.get("status"), Some("spawned"))
      @debug.assert_eq(map.get("agent_id"), Some("main.claude-worker"))
      @debug.assert_eq(map.get("agent_ids"), Some("main.claude-worker"))
    }
    Err(msg) => fail("spawn_worker failed: " + msg)
  }
  try agent_reg.get("main.claude-worker") catch {
    e =>
      fail(
        "missing worker registration: " +
        @types.choir_error_message_from_caught(e),
      )
  } noraise {
    agent => {
      assert_eq(agent.role, @types.Role::Worker)
      assert_eq(agent.agent_type, @types.AgentType::Claude)
      @debug.assert_eq(agent.parent, Some("root"))
      assert_eq(agent.workspace, project_dir)
      @debug.assert_eq(
        agent.terminal_target,
        @types.LocalTarget::parse("zellij-pane:choir:claude-worker"),
      )
    }
  }
}

///|
async test "dispatch fork_wave preregisters spawned child for immediate agent_list visibility" {
  let project_dir = "/tmp/choir-fork-wave-reg-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  assert_true(@sys.create_dir_all(project_dir + "/.choir/kv"))
  let agent_reg = @registry.AgentRegistry::new()
  ignore(
    agent_reg.upsert({
      agent_id: "root",
      role: @types.Role::TL,
      agent_type: @types.AgentType::Claude,
      parent: None,
      workspace: project_dir,
      branch: "",
      terminal_target: @types.LocalTarget::parse("zellij-tab:choir:TL"),
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  let call = ToolCall::{
    role: @types.Role::TL,
    name: "fork_wave",
    args: {
      "caller_id": "root",
      "parent_branch": "master",
      "slug_prefix": "claude-smoke-leaf",
      "count": "1",
      "agent_type": "claude",
      "task": "open a PR",
    },
  }
  let res = @tools.dispatch_call(
    call,
    project_dir~,
    session="choir",
    runner=mock_registry_runner,
    git_capture=mock_clean_git,
    capture=mock_registry_capture,
    ensure_branch_ready=Some(mock_registry_branch_ready),
    ensure_pr=Some(mock_registry_ensure_pr),
    registry=Some(agent_reg),
    mutex_registry=Some(@registry.MutexRegistry::new()),
    poller_state=Some(@poller.PollerState::new()),
  )
  match res {
    Ok(map) => {
      @debug.assert_eq(map.get("status"), Some("spawned"))
      @debug.assert_eq(map.get("agent_ids"), Some("master.claude-smoke-leaf-0"))
    }
    Err(msg) => fail("fork_wave failed: " + msg)
  }
  try agent_reg.get("master.claude-smoke-leaf-0") catch {
    e =>
      fail(
        "missing child registration: " +
        @types.choir_error_message_from_caught(e),
      )
  } noraise {
    agent => {
      assert_eq(agent.role, @types.Role::Dev)
      assert_eq(agent.agent_type, @types.AgentType::Claude)
      @debug.assert_eq(agent.parent, Some("root"))
      assert_eq(agent.state, @types.AgentState::Spawning)
      assert_true(
        agent.workspace.contains("/.choir/worktrees/claude-smoke-leaf-0"),
      )
      @debug.assert_eq(
        agent.terminal_target,
        @types.LocalTarget::parse("zellij-tab:choir:claude-smoke-leaf-0"),
      )
    }
  }
}

///|
async test "dispatch fork_wave post-spawn pane resolution uses injected capture" {
  let project_dir = "/tmp/choir-fork-wave-pane-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  assert_true(@sys.create_dir_all(project_dir + "/.choir/kv"))
  let agent_reg = @registry.AgentRegistry::new()
  ignore(
    agent_reg.upsert({
      agent_id: "root",
      role: @types.Role::TL,
      agent_type: @types.AgentType::Claude,
      parent: None,
      workspace: project_dir,
      branch: "",
      terminal_target: @types.LocalTarget::parse("zellij-tab:choir:TL"),
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  let call = ToolCall::{
    role: @types.Role::TL,
    name: "fork_wave",
    args: {
      "caller_id": "root",
      "parent_branch": "master",
      "slug_prefix": "claude-pane-leaf",
      "count": "1",
      "agent_type": "claude",
      "task": "open a PR",
    },
  }
  let res = @tools.dispatch_call(
    call,
    project_dir~,
    session="choir",
    runner=mock_registry_runner,
    git_capture=mock_clean_git,
    capture=mock_registry_capture_with_pane,
    ensure_branch_ready=Some(mock_registry_branch_ready),
    ensure_pr=Some(mock_registry_ensure_pr),
    registry=Some(agent_reg),
    mutex_registry=Some(@registry.MutexRegistry::new()),
    poller_state=Some(@poller.PollerState::new()),
  )
  match res {
    Ok(map) => @debug.assert_eq(map.get("status"), Some("spawned"))
    Err(msg) => fail("fork_wave failed: " + msg)
  }
  try agent_reg.get("master.claude-pane-leaf-0") catch {
    e =>
      fail(
        "missing child registration: " +
        @types.choir_error_message_from_caught(e),
      )
  } noraise {
    agent =>
      @debug.assert_eq(
        agent.terminal_target,
        @types.LocalTarget::parse("zellij-pane:choir:terminal_17"),
      )
  }
}

///|
async test "dispatch file_pr uses registered agent workspace for git and gh operations" {
  let project_dir = "/tmp/choir-file-pr-workdir-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  assert_true(@sys.create_dir_all(project_dir + "/.choir/kv"))
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
    project_dir~,
    runner=mock_registry_runner_capture_workdir,
    git_capture=mock_clean_git,
    capture=mock_registry_capture,
    ensure_branch_ready=Some(mock_registry_branch_ready_capture),
    ensure_pr=Some(mock_registry_ensure_pr_capture),
    registry=Some(reg),
    mutex_registry=Some(@registry.MutexRegistry::new()),
    poller_state=Some(@poller.PollerState::new()),
  )
  match res {
    Ok(map) => @debug.assert_eq(map.get("status"), Some("pr_created"))
    Err(msg) => fail("expected file_pr success: " + msg)
  }
}

///|
async test "dispatch file_pr auto-notifies resolvable parent with PR READY" {
  let project_dir = "/tmp/choir-file-pr-auto-notify-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  assert_true(@sys.create_dir_all(project_dir + "/.choir"))
  let tl_target = match
    @types.LocalTarget::parse("zellij-tab:choir-session:auto-notify-tl") {
    Some(t) => t
    None => fail("expected parseable zellij target")
  }
  let reg = @registry.AgentRegistry::new()
  ignore(
    reg.upsert({
      agent_id: "main.auto-notify-tl",
      role: @types.Role::TL,
      agent_type: @types.AgentType::Claude,
      parent: None,
      workspace: project_dir,
      branch: "main.auto-notify-tl",
      terminal_target: Some(tl_target),
      host: @types.Host::Local,
      state: @types.AgentState::Active,
      spawn_depth: 0,
    }),
  )
  ignore(
    reg.upsert({
      agent_id: "main.auto-notify-leaf",
      role: @types.Role::Dev,
      agent_type: @types.AgentType::CursorAgent,
      parent: Some("main.auto-notify-tl"),
      workspace: project_dir,
      branch: "main.auto-notify-leaf",
      terminal_target: None,
      host: @types.Host::Local,
      state: @types.AgentState::Active,
      spawn_depth: 1,
    }),
  )
  let call = ToolCall::{
    role: @types.Role::Dev,
    name: "file_pr",
    args: {
      "caller_id": "main.auto-notify-leaf",
      "branch": "main.auto-notify-leaf",
      "parent_branch": "main",
    },
  }
  let res = @tools.dispatch_call(
    call,
    project_dir~,
    runner=mock_registry_runner,
    git_capture=mock_clean_git,
    capture=mock_registry_capture,
    ensure_branch_ready=Some(mock_registry_branch_ready),
    ensure_pr=Some(mock_auto_notify_ensure_pr),
    registry=Some(reg),
    mutex_registry=Some(@registry.MutexRegistry::new()),
    poller_state=Some(@poller.PollerState::new()),
  )
  match res {
    Ok(map) => @debug.assert_eq(map.get("pr_number"), Some("99"))
    Err(msg) => fail("expected file_pr success: " + msg)
  }
  let log = @sys.read_file(project_dir + "/.choir/delivery.log")
  assert_true(log.contains("[auto-notify] caller=main.auto-notify-leaf"))
  assert_true(log.contains("parent=main.auto-notify-tl"))
  let expected_payload = "[from: main.auto-notify-leaf] [PR READY] PR #99 filed: https://auto.test/pr"
  assert_true(log.contains(expected_payload))
}

///|
async test "dispatch file_pr logs auto-notify failure when parent is not resolvable" {
  let project_dir = "/tmp/choir-file-pr-auto-notify-orphan-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  assert_true(@sys.create_dir_all(project_dir + "/.choir"))
  let reg = @registry.AgentRegistry::new()
  ignore(
    reg.upsert({
      agent_id: "main.auto-notify-orphan",
      role: @types.Role::Dev,
      agent_type: @types.AgentType::CursorAgent,
      parent: None,
      workspace: project_dir,
      branch: "main.auto-notify-orphan",
      terminal_target: None,
      host: @types.Host::Local,
      state: @types.AgentState::Active,
      spawn_depth: 0,
    }),
  )
  let call = ToolCall::{
    role: @types.Role::Dev,
    name: "file_pr",
    args: {
      "caller_id": "main.auto-notify-orphan",
      "branch": "main.auto-notify-orphan",
      "parent_branch": "main",
    },
  }
  let res = @tools.dispatch_call(
    call,
    project_dir~,
    runner=mock_registry_runner,
    git_capture=mock_clean_git,
    capture=mock_registry_capture,
    ensure_branch_ready=Some(mock_registry_branch_ready),
    ensure_pr=Some(mock_auto_notify_ensure_pr),
    registry=Some(reg),
    mutex_registry=Some(@registry.MutexRegistry::new()),
    poller_state=Some(@poller.PollerState::new()),
  )
  match res {
    Ok(map) => @debug.assert_eq(map.get("status"), Some("pr_created"))
    Err(msg) => fail("expected file_pr success: " + msg)
  }
  let log = @sys.read_file(project_dir + "/.choir/delivery.log")
  assert_true(log.contains("[auto-notify] resolve_parent_for_notify failed"))
  assert_true(
    log.contains("agent not found: no parent for main.auto-notify-orphan"),
  )
}

///|
test "tool registry lookup spawn_worker allowed for TL" {
  let reg = @tools.ToolRegistry::new()
  let result = try? reg.lookup(@types.Role::TL, "spawn_worker")
  assert_true(result is Ok(_))
}

///|
test "tool registry spawn descriptions distinguish leaves from workers" {
  let reg = @tools.ToolRegistry::new()
  try reg.lookup(@types.Role::TL, "spawn_worker") catch {
    _ => fail("expected spawn_worker definition")
  } noraise {
    def => {
      assert_true(def.description.contains("research/review"))
      assert_true(def.description.contains("do not own a branch or PR"))
      assert_true(def.description.contains("pass beads_issue_id"))
    }
  }
  try reg.lookup(@types.Role::TL, "fork_wave") catch {
    _ => fail("expected fork_wave definition")
  } noraise {
    def =>
      assert_true(
        def.description.contains("worktrees") &&
        def.description.contains("optional role") &&
        def.description.contains("per-leaf task_contracts"),
      )
  }
}

///|
test "tool registry lookup fork_session allowed for TL" {
  let reg = @tools.ToolRegistry::new()
  let result = try? reg.lookup(@types.Role::TL, "fork_session")
  assert_true(result is Ok(_))
}

///|
async test "fork_wave scaffold gate blocks dirty working tree" {
  let call = ToolCall::{
    role: @types.Role::TL,
    name: "fork_wave",
    args: {
      "caller_id": "main",
      "count": "1",
      "task": "work",
      "parent_branch": "main",
    },
  }
  let res = @tools.dispatch_call(
    call,
    project_dir="/tmp/choir-test-noop",
    runner=mock_registry_runner,
    git_capture=mock_dirty_git,
    capture=mock_registry_capture,
  )
  match res {
    Err(msg) => assert_true(msg.contains("uncommitted changes"))
    Ok(_) => fail("expected scaffold gate to block")
  }
}

///|
async test "fork_wave scaffold gate blocks unpushed commits" {
  let call = ToolCall::{
    role: @types.Role::TL,
    name: "fork_wave",
    args: {
      "caller_id": "main",
      "count": "1",
      "task": "work",
      "parent_branch": "main",
    },
  }
  let res = @tools.dispatch_call(
    call,
    project_dir="/tmp/choir-test-noop",
    runner=mock_registry_runner,
    git_capture=mock_unpushed_git,
    capture=mock_registry_capture,
  )
  match res {
    Err(msg) => assert_true(msg.contains("Unpushed commits"))
    Ok(_) => fail("expected scaffold gate to block")
  }
}

///|
async test "re-register without parent preserves prior parent metadata" {
  // Inline workers can re-register with a missing parent_id when their MCP
  // session reads the parent's cwd config instead of their own inline
  // metadata. Make sure the registry does not lose the parent link in that
  // case so notify_parent can still resolve.
  let reg = @registry.AgentRegistry::new()
  ignore(
    reg.upsert({
      agent_id: "master.sarcasmotron-agenda",
      role: @types.Role::Worker,
      agent_type: @types.AgentType::Claude,
      state: @types.AgentState::Active,
      parent: Some("root"),
      terminal_target: None,
      host: @types.Host::Local,
      workspace: "/repo",
      branch: "master.sarcasmotron-agenda",
      spawn_depth: 0,
    }),
  )
  let call = ToolCall::{
    role: @types.Role::Worker,
    name: "register",
    args: {
      "agent_id": "master.sarcasmotron-agenda",
      "role": "worker",
      "workspace": "/repo",
      "branch": "master.sarcasmotron-agenda",
    },
  }
  let res = @tools.dispatch_call(
    call,
    project_dir="/tmp/choir-test-noop",
    registry=Some(reg),
    capture=mock_registry_capture,
  )
  match res {
    Ok(_) => ()
    Err(e) => fail("register failed: " + e)
  }
  try reg.get("master.sarcasmotron-agenda") catch {
    _ => fail("expected registered agent")
  } noraise {
    agent => @debug.assert_eq(agent.parent, Some("root"))
  }
}

///|
async test "re-register preserves prior stable metadata when caller metadata is stale" {
  let reg = @registry.AgentRegistry::new()
  let target = match @types.LocalTarget::parse("zellij-tab:choir:leaf-role") {
    Some(t) => t
    None => fail("expected parseable target")
  }
  ignore(
    reg.upsert({
      agent_id: "main.leaf-role",
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Codex,
      state: @types.AgentState::Active,
      parent: Some("main.tl"),
      terminal_target: Some(target),
      host: @types.Host::Local,
      workspace: "/repo/.choir/worktrees/leaf-role",
      branch: "main.leaf-role",
      spawn_depth: 0,
    }),
  )
  let call = ToolCall::{
    role: @types.Role::TL,
    name: "register",
    args: {
      "agent_id": "main.leaf-role",
      "parent_id": "root",
      "workspace": "/repo",
      "branch": "main",
    },
  }
  let res = @tools.dispatch_call(
    call,
    project_dir="/tmp/choir-test-noop",
    registry=Some(reg),
    capture=mock_registry_capture,
  )
  match res {
    Ok(_) => ()
    Err(e) => fail("register failed: " + e)
  }
  try reg.get("main.leaf-role") catch {
    _ => fail("expected registered agent")
  } noraise {
    agent => {
      assert_eq(agent.role, @types.Role::Dev)
      assert_eq(agent.agent_type, @types.AgentType::Codex)
      @debug.assert_eq(agent.parent, Some("main.tl"))
      @debug.assert_eq(agent.terminal_target, Some(target))
      assert_eq(agent.workspace, "/repo/.choir/worktrees/leaf-role")
      assert_eq(agent.branch, "main.leaf-role")
    }
  }
}

///|
async test "re-register explicit leaf metadata repairs stale prior row" {
  let reg = @registry.AgentRegistry::new()
  let target = match @types.LocalTarget::parse("zellij-tab:choir:leaf-repair") {
    Some(t) => t
    None => fail("expected parseable target")
  }
  ignore(
    reg.upsert({
      agent_id: "main.leaf-repair",
      role: @types.Role::TL,
      agent_type: @types.AgentType::Claude,
      state: @types.AgentState::Active,
      parent: Some("root"),
      terminal_target: None,
      host: @types.Host::Local,
      workspace: "/repo",
      branch: "main",
      spawn_depth: 0,
    }),
  )
  let call = ToolCall::{
    role: @types.Role::Dev,
    name: "register",
    args: {
      "agent_id": "main.leaf-repair",
      "parent_id": "main.tl",
      "workspace": "/repo/.choir/worktrees/leaf-repair",
      "branch": "main.leaf-repair",
      "terminal_target": target.to_string(),
      "agent_type": "codex",
    },
  }
  let res = @tools.dispatch_call(
    call,
    project_dir="/tmp/choir-test-noop",
    registry=Some(reg),
    capture=mock_registry_capture,
  )
  match res {
    Ok(_) => ()
    Err(e) => fail("register failed: " + e)
  }
  try reg.get("main.leaf-repair") catch {
    _ => fail("expected registered agent")
  } noraise {
    agent => {
      assert_eq(agent.role, @types.Role::Dev)
      assert_eq(agent.agent_type, @types.AgentType::Codex)
      @debug.assert_eq(agent.parent, Some("main.tl"))
      @debug.assert_eq(agent.terminal_target, Some(target))
      assert_eq(agent.workspace, "/repo/.choir/worktrees/leaf-repair")
      assert_eq(agent.branch, "main.leaf-repair")
    }
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
  let res = @tools.dispatch_call(
    call,
    project_dir="/tmp/choir-test-noop",
    registry=Some(reg),
    capture=mock_registry_capture,
  )
  match res {
    Ok(_) => ()
    Err(e) => fail("register failed: " + e)
  }
  try reg.get("main.depth-trim") catch {
    _ => fail("expected registered agent")
  } noraise {
    agent => assert_eq(agent.spawn_depth, 1)
  }
}

///|
async test "dispatch agent_list defaults to active agents only" {
  let reg = @registry.AgentRegistry::new()
  ignore(
    reg.upsert({
      agent_id: "agent-1",
      role: @types.Role::TL,
      agent_type: @types.AgentType::Claude,
      parent: None,
      workspace: "/tmp/w1",
      branch: "branch-1",
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  ignore(
    reg.upsert({
      agent_id: "agent-2",
      role: @types.Role::Dev,
      agent_type: @types.AgentType::CursorAgent,
      parent: Some("agent-1"),
      workspace: "/tmp/w2",
      branch: "branch-2",
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 1,
      state: @types.AgentState::Done,
    }),
  )
  let call = ToolCall::{ role: @types.Role::TL, name: "agent_list", args: {} }
  let res = @tools.dispatch_call(
    call,
    project_dir="/tmp/choir-test-noop",
    registry=Some(reg),
    capture=mock_registry_capture,
  )
  match res {
    Ok(map) => {
      @debug.assert_eq(map.get("status"), Some("ok"))
      match map.get_json("agents") {
        Some(Array(arr)) => {
          assert_eq(arr.length(), 1)
          assert_true(arr[0].stringify().contains("\"agent_id\":\"agent-1\""))
        }
        _ => fail("expected agents array")
      }
    }
    Err(e) => fail("agent_list failed: " + e)
  }
}

///|
async test "dispatch agent_list include_inactive returns full registry view" {
  let reg = @registry.AgentRegistry::new()
  ignore(
    reg.upsert({
      agent_id: "agent-1",
      role: @types.Role::TL,
      agent_type: @types.AgentType::Claude,
      parent: None,
      workspace: "/tmp/w1",
      branch: "branch-1",
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  ignore(
    reg.upsert({
      agent_id: "agent-2",
      role: @types.Role::Dev,
      agent_type: @types.AgentType::CursorAgent,
      parent: Some("agent-1"),
      workspace: "/tmp/w2",
      branch: "branch-2",
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 1,
      state: @types.AgentState::Done,
    }),
  )
  let call = ToolCall::{
    role: @types.Role::TL,
    name: "agent_list",
    args: { "include_inactive": "true" },
  }
  let res = @tools.dispatch_call(
    call,
    project_dir="/tmp/choir-test-noop",
    registry=Some(reg),
    capture=mock_registry_capture,
  )
  match res {
    Ok(map) => {
      @debug.assert_eq(map.get("status"), Some("ok"))
      match map.get_json("agents") {
        Some(Array(arr)) => assert_eq(arr.length(), 2)
        _ => fail("expected agents array")
      }
    }
    Err(e) => fail("agent_list failed: " + e)
  }
}

///|
async test "dispatch agent_list surfaces beads_issue_id from inline metadata" {
  let project_dir = "/tmp/choir-agent-list-beads-" + @sys.get_pid().to_string()
  let agent_id = "main.beads-smoke"
  let metadata_dir = @workspace.inline_agent_metadata_dir(project_dir, agent_id)
  assert_true(@sys.create_dir_all(metadata_dir + "/.choir"))
  let contract = {
    ..@types.TaskContract::empty(),
    goal: "read bead",
    beads_issue_id: Some("choir-beads-live-smoke"),
  }
  ignore(
    @sys.write_file_sync(
      metadata_dir + "/.choir/config.local.toml",
      "task_contract_json = \"" +
      escape_registry_test_toml_string(contract.to_json_string()) +
      "\"\n",
    ),
  )
  let reg = @registry.AgentRegistry::new()
  ignore(
    reg.upsert({
      agent_id,
      role: @types.Role::Worker,
      agent_type: @types.AgentType::Codex,
      parent: Some("root"),
      workspace: project_dir,
      branch: agent_id,
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  let call = ToolCall::{ role: @types.Role::TL, name: "agent_list", args: {} }
  let res = @tools.dispatch_call(
    call,
    project_dir~,
    registry=Some(reg),
    capture=mock_registry_capture,
  )
  ignore(@sys.rm_rf(project_dir))
  match res {
    Ok(map) =>
      match map.get_json("agents") {
        Some(Array(arr)) => {
          assert_eq(arr.length(), 1)
          let rendered = arr[0].stringify()
          if !rendered.contains("\"beads_issue_id\":\"choir-beads-live-smoke\"") {
            fail(rendered)
          }
        }
        _ => fail("expected agents array")
      }
    Err(e) => fail("agent_list failed: " + e)
  }
}

///|
async test "dispatch agent_list filters by parent_id before include_inactive handling" {
  let reg = @registry.AgentRegistry::new()
  ignore(
    reg.upsert({
      agent_id: "parent",
      role: @types.Role::TL,
      agent_type: @types.AgentType::Claude,
      parent: None,
      workspace: "/tmp/w",
      branch: "branch-p",
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  ignore(
    reg.upsert({
      agent_id: "child-1",
      role: @types.Role::Dev,
      agent_type: @types.AgentType::CursorAgent,
      parent: Some("parent"),
      workspace: "/tmp/w1",
      branch: "branch-c1",
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 1,
      state: @types.AgentState::Active,
    }),
  )
  ignore(
    reg.upsert({
      agent_id: "child-2",
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Gemini,
      parent: Some("parent"),
      workspace: "/tmp/w2",
      branch: "branch-c2",
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 1,
      state: @types.AgentState::Done,
    }),
  )
  let call = ToolCall::{
    role: @types.Role::TL,
    name: "agent_list",
    args: { "parent_id": "parent" },
  }
  let res = @tools.dispatch_call(
    call,
    project_dir="/tmp/choir-test-noop",
    registry=Some(reg),
    capture=mock_registry_capture,
  )
  match res {
    Ok(map) => {
      @debug.assert_eq(map.get("status"), Some("ok"))
      match map.get_json("agents") {
        Some(Array(arr)) => {
          assert_eq(arr.length(), 1)
          assert_true(arr[0].stringify().contains("\"agent_id\":\"child-1\""))
        }
        _ => fail("expected agents array")
      }
    }
    Err(e) => fail("agent_list failed: " + e)
  }
}

///|
test "tool registry fork_wave description mentions automerge" {
  let reg = @tools.ToolRegistry::new()
  try reg.lookup(@types.Role::TL, "fork_wave") catch {
    _ => fail("expected fork_wave definition")
  } noraise {
    def => assert_true(def.description.contains("automerge"))
  }
}
