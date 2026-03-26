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
    terminal_target: None,
    host: @types.Host::Local,
    state: @types.AgentState::Active,
  }
}

///|
async fn mock_spawn_runner_server(
  cmds : Array[@workspace.Command],
) -> Array[Int] {
  @async.sleep(0)
  assert_eq(cmds.length(), 8)
  assert_true(cmds[0].args[1].contains("git worktree remove --force"))
  assert_true(
    cmds[3].args[4].contains(
      "terminal_target = \"zellij-tab:server-proof:leaf-a-0\"",
    ),
  )
  assert_eq(cmds[5].program, "choir")
  assert_eq(cmds[5].args, [
    "trust-gemini-folder", "/tmp/server-proof/.choir/worktrees/leaf-a-0",
  ])
  assert_eq(cmds[6].program, "sh") // write_gemini_settings
  assert_eq(cmds[7].program, "zellij")
  assert_eq(cmds[7].args[3], "new-tab")
  assert_eq(cmds[7].args[5], "leaf-a-0")
  [0, 0, 0, 0, 0, 0, 0, 0]
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
  _title : String?,
  _body : String?,
) -> Result[@tools.PullRequestInfo, String] {
  @async.sleep(0)
  Ok({ number: 52, url: "https://example.test/pr/" + branch, state: "OPEN" })
}

///|
async fn mock_branch_ready_server(
  _branch : String,
  _parent_branch : String,
  _project_dir : String,
) -> Result[Unit, String] {
  @async.sleep(0)
  Ok(())
}

///|
async test "ServerState::handle valid request returns Ok" {
  let state = ServerState::new(@types.Config::default())
  let req = @types.Request::{
    req_method: "tools/call",
    role: @types.Role::Dev,
    name: "task_list",
    args: @types.RequestArgs::new({}),
  }
  let res = state.handle(req)
  assert_true(res.is_ok())
}

///|
async test "ServerState::handle invalid role returns Err" {
  let state = ServerState::new(@types.Config::default())
  let req = @types.Request::{
    req_method: "tools/call",
    role: @types.Role::Dev,
    name: "fork_wave",
    args: @types.RequestArgs::new({}),
  }
  let res = state.handle(req)
  assert_false(res.is_ok())
}

///|
async test "ServerState::handle_with_runner finalizes exitable shutdown" {
  let project_dir = "/tmp/choir-server-shutdown"
  run_shell(
    "rm -rf /tmp/choir-server-shutdown && mkdir -p /tmp/choir-server-shutdown/.choir/kv",
  )
  let state = ServerState::new({ ..@types.Config::default(), project_dir, })
  let parent = {
    ..build_agent("root", None),
    role: @types.Role::TL,
    terminal_target: @types.LocalTarget::parse("zellij-tab:choir:TL"),
  }
  let child = {
    ..build_agent("main.dev-1", Some("root")),
    branch: "main.dev-1",
    workspace: project_dir + "/.choir/worktrees/main.dev-1",
    terminal_target: @types.LocalTarget::parse("zellij-tab:choir:main.dev-1"),
  }
  ignore(state.registry.insert(parent))
  ignore(state.registry.insert(child))
  let req = @types.Request::{
    req_method: "tools/call",
    role: @types.Role::Dev,
    name: "shutdown",
    args: @types.RequestArgs::from_values({
      "caller_id": "main.dev-1".to_json(),
    }),
  }
  let recorded : Array[@workspace.Command] = []
  let res = state.handle_with_runner(req, runner=async fn(cmds) {
    record_runner_server(recorded, cmds)
  })
  assert_eq(res.ok_field("status"), Some("shutdown"))
  match state.registry.get("main.dev-1") {
    Ok(agent) => assert_eq(agent.state, @types.AgentState::Done)
    Err(_) => fail("expected finalized agent")
  }
  match @phase.read_lifecycle(project_dir, "main.dev-1") {
    Some(lifecycle) =>
      match lifecycle.workflow {
        @phase.WorkflowState::Dev(@phase.DevLifecycle::Done(reason=Shutdown)) =>
          ()
        _ => fail("expected persisted dev lifecycle")
      }
    None => fail("expected persisted lifecycle")
  }
  let mut first_choir_index = -1
  let mut git_index = -1
  let mut last_choir_index = -1
  for i = 0; i < recorded.length(); i = i + 1 {
    if recorded[i].program == "choir" {
      if first_choir_index == -1 {
        first_choir_index = i
      }
      last_choir_index = i
    } else if recorded[i].program == "git" && git_index == -1 {
      git_index = i
    }
  }
  if first_choir_index == -1 {
    fail("expected at least one 'choir' command")
  }
  if git_index == -1 {
    fail("expected a 'git' command")
  }
  if last_choir_index == -1 {
    fail("expected at least one 'choir' command after 'git'")
  }
  if not(first_choir_index < git_index && git_index < last_choir_index) {
    fail("expected 'choir', then 'git', then 'choir' in order")
  }
  run_shell("rm -rf /tmp/choir-server-shutdown")
}

///|
async test "ServerState::handle_with_runner defers shutdown for review-owned dev lifecycle" {
  let project_dir = "/tmp/choir-server-shutdown-deferred"
  run_shell(
    "rm -rf /tmp/choir-server-shutdown-deferred && mkdir -p /tmp/choir-server-shutdown-deferred/.choir/kv",
  )
  let state = ServerState::new({ ..@types.Config::default(), project_dir, })
  let child = {
    ..build_agent("main.dev-review", None),
    branch: "main.dev-review",
  }
  ignore(state.registry.insert(child))
  ignore(
    @phase.write_lifecycle(project_dir, {
      agent_id: "main.dev-review",
      role: @types.Role::Dev,
      process: @phase.ProcessState::Connected,
      workflow: @phase.WorkflowState::Dev(
        @phase.DevLifecycle::ReviewOwned(
          pr_number=11,
          state=@phase.ReviewOwnership::OpenUnreviewed(
            url="https://example.test/pr/11",
          ),
        ),
      ),
    }),
  )
  let req = @types.Request::{
    req_method: "tools/call",
    role: @types.Role::Dev,
    name: "shutdown",
    args: @types.RequestArgs::from_values({
      "caller_id": "main.dev-review".to_json(),
    }),
  }
  let recorded : Array[@workspace.Command] = []
  let res = state.handle_with_runner(req, runner=async fn(cmds) {
    record_runner_server(recorded, cmds)
  })
  assert_eq(res.ok_field("status"), Some("deferred"))
  match state.registry.get("main.dev-review") {
    Ok(agent) => assert_eq(agent.state, @types.AgentState::Active)
    Err(_) => fail("expected active agent")
  }
  assert_eq(recorded.length(), 0)
  run_shell("rm -rf /tmp/choir-server-shutdown-deferred")
}

///|
async test "ServerState::handle_with_runner records kill_agent as ParentKilled failure" {
  let project_dir = "/tmp/choir-server-kill-agent"
  run_shell(
    "rm -rf /tmp/choir-server-kill-agent && mkdir -p /tmp/choir-server-kill-agent/.choir/kv",
  )
  let state = ServerState::new({ ..@types.Config::default(), project_dir, })
  let child = {
    ..build_agent("main.leaf-kill", None),
    branch: "main.leaf-kill",
    workspace: project_dir + "/.choir/worktrees/main.leaf-kill",
    terminal_target: @types.LocalTarget::parse(
      "zellij-tab:choir:main.leaf-kill",
    ),
  }
  ignore(state.registry.insert(child))
  let req = @types.Request::{
    req_method: "tools/call",
    role: @types.Role::TL,
    name: "kill_agent",
    args: @types.RequestArgs::from_values({
      "agent_id": "main.leaf-kill".to_json(),
      "reason": "testing kill".to_json(),
    }),
  }
  let recorded : Array[@workspace.Command] = []
  let res = state.handle_with_runner(req, runner=async fn(cmds) {
    record_runner_server(recorded, cmds)
  })
  assert_eq(res.ok_field("status"), Some("killed"))
  match state.registry.get("main.leaf-kill") {
    Ok(agent) => assert_eq(agent.state, @types.AgentState::Failed)
    Err(_) => fail("expected agent in registry")
  }
  match @phase.read_lifecycle(project_dir, "main.leaf-kill") {
    Some(lifecycle) =>
      match lifecycle.workflow {
        @phase.WorkflowState::Dev(
          @phase.DevLifecycle::Failed(reason=ParentKilled)
        ) => ()
        _ => fail("expected ParentKilled lifecycle failure")
      }
    None => fail("expected persisted lifecycle")
  }
  run_shell("rm -rf /tmp/choir-server-kill-agent")
}

///|
async test "ServerState::handle_with_runner passes zellij session to spawns" {
  let config = {
    ..@types.Config::default(),
    project_dir: "/tmp/server-proof",
    terminal_session: "server-proof",
  }
  let state = ServerState::new(config)
  let req = @types.Request::{
    req_method: "tools/call",
    role: @types.Role::TL,
    name: "fork_wave",
    args: @types.RequestArgs::new({
      "caller_id": "root",
      "slug_prefix": "leaf-a",
      "parent_branch": "main",
      "task": "reply READY",
      "count": "1",
      "read_first": ".choir/context/dev.md",
    }),
  }
  let res = state.handle_with_runner(req, runner=mock_spawn_runner_server)
  assert_eq(res.ok_field("status"), Some("spawned"))
  assert_eq(res.ok_field("agent_ids"), Some("main.leaf-a-0"))
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
test "register_agent duplicate refreshes existing agent" {
  let state = ServerState::new(@types.Config::default())
  let agent = build_agent("child-1", None)
  let _ = state.register_agent(agent)
  let res = state.register_agent({
    ..agent,
    workspace: ".choir/worktrees/child-1",
    terminal_target: @types.LocalTarget::parse("zellij-tab:choir:child-1"),
  })
  assert_true(res is Ok(_))
  match state.registry.get("child-1") {
    Ok(found) => {
      assert_eq(found.workspace, ".choir/worktrees/child-1")
      assert_eq(
        found.terminal_target,
        @types.LocalTarget::parse("zellij-tab:choir:child-1"),
      )
    }
    Err(_) => fail("expected refreshed agent")
  }
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
      assert_true(delivery is @message.DeliveryMethod::TeamsInbox(_, _, ..))
    Err(_) => fail("Expected Ok")
  }
}

///|
test "notify_parent delivers to Claude parent with terminal via LocalTerminalInput" {
  let state = ServerState::new(@types.Config::default())
  let parent = {
    ..build_agent("parent-1", None),
    role: @types.Role::TL,
    terminal_target: @types.LocalTarget::parse("zellij-tab:choir:TL"),
  }
  let child = build_agent("child-1", Some("parent-1"))
  let _ = state.register_agent(parent)
  let _ = state.register_agent(child)
  let res = state.notify_parent("child-1", "hello", "success")
  assert_true(res is Ok(_))
  match res {
    Ok(@message.DeliveryMethod::LocalTerminalInput(target, text)) => {
      assert_eq(
        target,
        @types.LocalTarget::parse("zellij-tab:choir:TL").unwrap(),
      )
      assert_eq(text, "[from: child-1] hello")
    }
    _ =>
      fail("expected local terminal delivery for Claude parent with terminal")
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
test "plan_poll_event_deliveries routes PR ready to parent" {
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
  let deliveries = state.plan_poll_event_deliveries(
    @poller.PollEvent::PRReady(42),
    "child-1",
  )
  assert_true(deliveries.length() >= 1)
  match deliveries[0] {
    @message.DeliveryMethod::TeamsInbox(path, payload, ..) => {
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
test "plan_poll_event_deliveries routes fixes pushed to parent with next action" {
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
  let deliveries = state.plan_poll_event_deliveries(
    @poller.PollEvent::FixesPushed(43),
    "child-1",
  )
  assert_true(deliveries.length() >= 1)
  match deliveries[0] {
    @message.DeliveryMethod::TeamsInbox(path, payload, ..) => {
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
test "plan_poll_event_deliveries routes review to both parent and owner" {
  let state = ServerState::new(@types.Config::default())
  let parent = build_agent("parent-1", None)
  let child = build_agent("child-1", Some("parent-1"))
  let _ = state.register_agent(parent)
  let _ = state.register_agent(child)
  state.poller.track(
    42, "child-1", "main.child-1", "main", "https://example.test/pr/42", 100L,
  )
  let deliveries = state.plan_poll_event_deliveries(
    @poller.PollEvent::ReviewReceived(42, "Please add tests"),
    "child-1",
  )
  // Both parent and owner should receive deliveries
  assert_eq(deliveries.length(), 2)
  // First delivery: parent gets summary
  match deliveries[0] {
    @message.DeliveryMethod::TeamsInbox(path, payload, ..) => {
      assert_true(path.contains("parent-1"))
      assert_true(payload.contains("[REVIEW] child-1 PR #42"))
      assert_true(payload.contains("Please add tests"))
      assert_true(payload.contains("\"from\":\"child-1\""))
    }
    _ => fail("expected parent Teams inbox delivery")
  }
  // Second delivery: owner gets detail
  match deliveries[1] {
    @message.DeliveryMethod::TeamsInbox(path, payload, ..) => {
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
test "plan_poll_event_deliveries routes review to parent when owner is Done" {
  let state = ServerState::new(@types.Config::default())
  let parent = build_agent("parent-1", None)
  let child = {
    ..build_agent("child-1", Some("parent-1")),
    state: @types.AgentState::Done,
  }
  let _ = state.register_agent(parent)
  ignore(state.registry.insert(child))
  state.poller.track(
    42, "child-1", "main.child-1", "main", "https://example.test/pr/42", 100L,
  )
  let deliveries = state.plan_poll_event_deliveries(
    @poller.PollEvent::ReviewReceived(42, "Copilot review summary"),
    "child-1",
  )
  // Only parent gets delivery — owner is Done
  assert_eq(deliveries.length(), 1)
  match deliveries[0] {
    @message.DeliveryMethod::TeamsInbox(path, payload, ..) => {
      assert_true(path.contains("parent-1"))
      assert_true(payload.contains("[REVIEW] child-1 PR #42"))
      assert_true(payload.contains("Copilot review summary"))
    }
    _ => fail("expected parent Teams inbox delivery")
  }
}

///|
async test "process_poller_tick_with routes comment-only reviews to owning agent" {
  let state = ServerState::new(@types.Config::default())
  let parent = { ..build_agent("parent-1", None), role: @types.Role::TL }
  let child = {
    ..build_agent("main.leaf-1", Some("parent-1")),
    role: @types.Role::Dev,
    branch: "main.leaf-1",
  }
  ignore(state.registry.insert(parent))
  ignore(state.registry.insert(child))
  state.poller.track(
    61, "main.leaf-1", "main.leaf-1", "main", "https://example.test/pr/61", 100L,
  )

  let review_cmds : Array[@workspace.Command] = []
  state.process_poller_tick_with(
    200L,
    900L,
    fn(_pr_number) {
      (
        @poller.ReviewState::None_,
        "sha-comment-1",
        false,
        "Please tighten the wording in .choir/context/common.md",
        true,
      )
    },
    runner=async fn(cmds) { record_runner_server(review_cmds, cmds) },
  )
  // Parent + owner deliveries + gh pr comment
  assert_eq(review_cmds.length(), 3)
  // Parent gets summary
  assert_true(
    review_cmds[0].args[4].contains(
      "/.claude/teams/parent-1/inboxes/default.json",
    ),
  )
  assert_true(review_cmds[0].args[3].contains("[REVIEW] main.leaf-1 PR #61"))
  // Owner gets detail
  assert_true(
    review_cmds[1].args[4].contains(
      "/.claude/teams/main.leaf-1/inboxes/default.json",
    ),
  )
  assert_true(
    review_cmds[1].args[3].contains(
      "[REVIEW] PR #61 has review comments:\\nPlease tighten the wording in .choir/context/common.md",
    ),
  )
  // PR comment audit trail
  assert_eq(review_cmds[2].program, "gh")
  assert_eq(review_cmds[2].args[0], "pr")
  assert_eq(review_cmds[2].args[1], "comment")
  assert_eq(review_cmds[2].args[2], "61")
  assert_true(review_cmds[2].args[4].contains("**Choir:** review received"))
}

///|
async test "process_poller_tick_with drives PR review workflow and merge cleanup" {
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
      "branch": "main.leaf-1".to_json(),
      "parent_branch": "main".to_json(),
      "caller_id": "main.leaf-1".to_json(),
    }),
  }
  let file_res = @tools.handle_request(
    state.tool_registry,
    file_req,
    project_dir="/tmp",
    runner=mock_runner_server,
    ensure_branch_ready=mock_branch_ready_server,
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
        true,
      )
    },
    runner=async fn(cmds) { record_runner_server(review_cmds, cmds) },
  )
  // Parent + owner + gh pr comment
  assert_eq(review_cmds.length(), 3)
  assert_eq(review_cmds[0].program, "sh")
  // Parent delivery
  assert_true(
    review_cmds[0].args[4].contains(
      "/.claude/teams/parent-1/inboxes/default.json",
    ),
  )
  assert_true(review_cmds[0].args[3].contains("[REVIEW] main.leaf-1 PR #52"))
  // Owner delivery
  assert_true(
    review_cmds[1].args[4].contains(
      "/.claude/teams/main.leaf-1/inboxes/default.json",
    ),
  )
  assert_true(
    review_cmds[1].args[3].contains(
      "[REVIEW] PR #52 has review comments:\\nPlease add tests",
    ),
  )
  assert_true(review_cmds[1].args[3].contains("\"from\":\"poller\""))
  // PR comment
  assert_eq(review_cmds[2].program, "gh")

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
        true,
      )
    },
    runner=async fn(cmds) { record_runner_server(fixes_cmds, cmds) },
  )
  // Parent delivery + gh pr comment
  assert_eq(fixes_cmds.length(), 2)
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
  assert_eq(fixes_cmds[1].program, "gh")

  let ready_cmds : Array[@workspace.Command] = []
  state.process_poller_tick_with(
    202L,
    900L,
    fn(_pr_number) {
      (@poller.ReviewState::Approved, "sha-review-2", false, "", true)
    },
    runner=async fn(cmds) { record_runner_server(ready_cmds, cmds) },
  )
  // Parent delivery + gh pr comment
  assert_eq(ready_cmds.length(), 2)
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
      "pr_number": Int::to_json(52),
      "parent_branch": "main".to_json(),
      "caller_id": "parent-1".to_json(),
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
}

///|
async test "ServerState::handle_with_runner finalizes merged dev agent" {
  let project_dir = "/tmp/choir-server-merge-finalize"
  run_shell(
    "rm -rf /tmp/choir-server-merge-finalize && mkdir -p /tmp/choir-server-merge-finalize/.choir/kv",
  )
  let state = ServerState::new({ ..@types.Config::default(), project_dir, })
  let parent = { ..build_agent("parent-1", None), role: @types.Role::TL }
  let child = {
    ..build_agent("main.leaf-1", Some("parent-1")),
    role: @types.Role::Dev,
    branch: "main.leaf-1",
    workspace: project_dir + "/.choir/worktrees/main.leaf-1",
    terminal_target: @types.LocalTarget::parse("zellij-tab:choir:main.leaf-1"),
  }
  ignore(state.registry.insert(parent))
  ignore(state.registry.insert(child))
  state.poller.track(
    52, "main.leaf-1", "main.leaf-1", "main", "https://example.test/pr/52", 100L,
  )
  ignore(
    @phase.write_lifecycle(project_dir, {
      agent_id: "main.leaf-1",
      role: @types.Role::Dev,
      process: @phase.ProcessState::Connected,
      workflow: @phase.WorkflowState::Dev(
        @phase.DevLifecycle::ReviewOwned(
          pr_number=52,
          state=@phase.ReviewOwnership::ApprovedAwaitingMerge,
        ),
      ),
    }),
  )
  let merge_req = @types.Request::{
    req_method: "tools/call",
    role: @types.Role::TL,
    name: "merge_pr",
    args: @types.RequestArgs::from_values({
      "pr_number": Int::to_json(52),
      "parent_branch": "main".to_json(),
      "caller_id": "parent-1".to_json(),
    }),
  }
  let recorded : Array[@workspace.Command] = []
  let merge_res = state.handle_with_runner(merge_req, runner=async fn(cmds) {
    record_runner_server(recorded, cmds)
  })
  assert_eq(merge_res.ok_field("status"), Some("merged"))
  assert_eq(state.poller.get(52), None)
  match state.registry.get("main.leaf-1") {
    Ok(agent) => assert_eq(agent.state, @types.AgentState::Done)
    Err(_) => fail("expected finalized agent")
  }
  match @phase.read_lifecycle(project_dir, "main.leaf-1") {
    Some(lifecycle) =>
      match lifecycle.workflow {
        @phase.WorkflowState::Dev(@phase.DevLifecycle::Done(reason=Merged)) =>
          ()
        _ => fail("expected Done lifecycle")
      }
    None => fail("expected persisted lifecycle")
  }
  let mut choir_count = 0
  for cmd in recorded {
    if cmd.program == "choir" {
      choir_count = choir_count + 1
    }
  }
  assert_true(choir_count >= 1)
  run_shell("rm -rf /tmp/choir-server-merge-finalize")
}

///|
async test "process_poller_tick_with suppresses duplicate recovered review events" {
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
    "Please add tests",
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
        true,
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
        true,
      )
    },
    runner=async fn(cmds) { record_runner_server(fixes_cmds, cmds) },
  )
  // Parent delivery + gh pr comment
  assert_eq(fixes_cmds.length(), 2)
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
}

///|
async test "process_poller_tick_with suppresses duplicate recovered approval events" {
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
    "",
    "sha-review-2",
    false,
  )

  let duplicate_cmds : Array[@workspace.Command] = []
  state.process_poller_tick_with(
    200L,
    900L,
    fn(_pr_number) {
      (@poller.ReviewState::Approved, "sha-review-2", false, "", true)
    },
    runner=async fn(cmds) { record_runner_server(duplicate_cmds, cmds) },
  )
  assert_eq(duplicate_cmds.length(), 0)
}

///|
async test "process_poller_tick_with preserves timeout age after recovery" {
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
    54,
    "main.leaf-1",
    "main.leaf-1",
    "main",
    "https://example.test/pr/54",
    100L,
    @poller.ReviewState::None_,
    "",
    "",
    false,
  )

  let timeout_cmds : Array[@workspace.Command] = []
  state.process_poller_tick_with(
    1101L,
    900L,
    fn(_pr_number) { (@poller.ReviewState::None_, "", false, "", true) },
    runner=async fn(cmds) { record_runner_server(timeout_cmds, cmds) },
  )
  assert_eq(timeout_cmds.length(), 1)
  assert_true(
    timeout_cmds[0].args[4].contains(
      "/.claude/teams/parent-1/inboxes/default.json",
    ),
  )
  assert_true(
    timeout_cmds[0].args[3].contains(
      "[REVIEW TIMEOUT] main.leaf-1 PR #54 has no review after 15min",
    ),
  )
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
  let persisted = @sys.read_file(project_dir + "/.choir/run_id")
  assert_eq(persisted, state.run_id)
  let (holder, queue) = state.mutex_registry.status("missing")
  assert_eq(holder, None)
  assert_eq(queue.length(), 0)
  run_shell("rm -rf /tmp/choir-server-state")
}

///|
async test "handle_disconnect notifies parent when agent was Active" {
  let project_dir = "/tmp/choir-server-disconnect-active"
  run_shell(
    "rm -rf /tmp/choir-server-disconnect-active && mkdir -p /tmp/choir-server-disconnect-active/.choir/kv",
  )
  let state = ServerState::new({ ..@types.Config::default(), project_dir, })
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
  run_shell("rm -rf /tmp/choir-server-disconnect-active")
}

///|
async test "handle_disconnect transitions Completing agent to Done" {
  let project_dir = "/tmp/choir-server-disconnect-completing"
  run_shell(
    "rm -rf /tmp/choir-server-disconnect-completing && mkdir -p /tmp/choir-server-disconnect-completing/.choir/kv",
  )
  let state = ServerState::new({ ..@types.Config::default(), project_dir, })
  let agent = {
    ..build_agent("main.dev-1", None),
    branch: "main.dev-1",
    state: @types.AgentState::Completing,
  }
  ignore(state.registry.insert(agent))
  state.handle_disconnect("main.dev-1")
  match state.registry.get("main.dev-1") {
    Ok(updated_agent) => assert_eq(updated_agent.state, @types.AgentState::Done)
    Err(_) => fail("Expected agent to remain in registry")
  }
  match @phase.read_lifecycle(project_dir, "main.dev-1") {
    Some(lifecycle) => {
      assert_eq(
        lifecycle.process,
        @phase.ProcessState::Finalized(reason=@phase.FinalizeReason::Shutdown),
      )
      match lifecycle.workflow {
        @phase.WorkflowState::Dev(
          @phase.DevLifecycle::Done(reason=@phase.FinalizeReason::Shutdown)
        ) => ()
        _ => fail("expected shutdown finalized lifecycle")
      }
    }
    None => fail("expected persisted lifecycle")
  }
  run_shell("rm -rf /tmp/choir-server-disconnect-completing")
}

///|
async test "handle_disconnect is no-op when agent already removed" {
  let state = ServerState::new(@types.Config::default())
  state.handle_disconnect("main.never-existed")
  assert_true(true)
}

///|
async test "handle_disconnect preserves review-owned dev agents" {
  let project_dir = "/tmp/choir-server-disconnect-review"
  run_shell(
    "rm -rf /tmp/choir-server-disconnect-review && mkdir -p /tmp/choir-server-disconnect-review/.choir/kv",
  )
  let state = ServerState::new({ ..@types.Config::default(), project_dir, })
  let parent = { ..build_agent("root", None), role: @types.Role::TL }
  ignore(state.registry.insert(parent))
  let child = {
    ..build_agent("main.leaf-pr", Some("root")),
    branch: "main.leaf-pr",
  }
  ignore(state.registry.insert(child))
  ignore(
    @phase.write_lifecycle(state.config.project_dir, {
      agent_id: "main.leaf-pr",
      role: @types.Role::Dev,
      process: @phase.ProcessState::Connected,
      workflow: @phase.WorkflowState::Dev(
        @phase.DevLifecycle::ReviewOwned(
          pr_number=99,
          state=@phase.ReviewOwnership::OpenUnreviewed(
            url="https://example.test/pr/99",
          ),
        ),
      ),
    }),
  )
  let delivered_cmds : Array[@workspace.Command] = []
  state.handle_disconnect_with_runner("main.leaf-pr", runner=async fn(cmds) {
    record_runner_server(delivered_cmds, cmds)
  })
  match state.registry.get("main.leaf-pr") {
    Ok(agent) => assert_eq(agent.state, @types.AgentState::Active)
    Err(_) => fail("agent should remain in registry")
  }
  assert_eq(delivered_cmds.length(), 0)
  run_shell("rm -rf /tmp/choir-server-disconnect-review")
}

///|
async test "handle_disconnect fails dev agents with requested changes" {
  let project_dir = "/tmp/choir-server-disconnect-fixes"
  run_shell(
    "rm -rf /tmp/choir-server-disconnect-fixes && mkdir -p /tmp/choir-server-disconnect-fixes/.choir/kv",
  )
  let state = ServerState::new({ ..@types.Config::default(), project_dir, })
  let parent = { ..build_agent("root", None), role: @types.Role::TL }
  ignore(state.registry.insert(parent))
  let child = {
    ..build_agent("main.leaf-fix", Some("root")),
    branch: "main.leaf-fix",
  }
  ignore(state.registry.insert(child))
  ignore(
    @phase.write_lifecycle(state.config.project_dir, {
      agent_id: "main.leaf-fix",
      role: @types.Role::Dev,
      process: @phase.ProcessState::Connected,
      workflow: @phase.WorkflowState::Dev(
        @phase.DevLifecycle::ChangesRequested(pr_number=77, next_round=1),
      ),
    }),
  )
  let delivered_cmds : Array[@workspace.Command] = []
  state.handle_disconnect_with_runner("main.leaf-fix", runner=async fn(cmds) {
    record_runner_server(delivered_cmds, cmds)
  })
  match state.registry.get("main.leaf-fix") {
    Ok(agent) => assert_eq(agent.state, @types.AgentState::Failed)
    Err(_) => fail("agent should remain in registry")
  }
  assert_eq(delivered_cmds.length(), 1)
  assert_true(
    delivered_cmds[0].args[3].contains(
      "[FAILED: main.leaf-fix] disconnected unexpectedly - agent may have crashed or run out of context",
    ),
  )
  run_shell("rm -rf /tmp/choir-server-disconnect-fixes")
}

///|
async test "handle_disconnect classifies viewport failure details" {
  let project_dir = "/tmp/choir-server-disconnect-capacity"
  let snapshot_path = "/tmp/choir-viewport-main.worker-capacity.json"
  run_shell(
    "rm -rf /tmp/choir-server-disconnect-capacity && mkdir -p /tmp/choir-server-disconnect-capacity/.choir/kv && rm -f /tmp/choir-viewport-main.worker-capacity.json",
  )
  let state = ServerState::new({ ..@types.Config::default(), project_dir, })
  let parent = { ..build_agent("root", None), role: @types.Role::TL }
  ignore(state.registry.insert(parent))
  let child = {
    ..build_agent("main.worker-capacity", Some("root")),
    role: @types.Role::Worker,
    branch: "main.worker-capacity",
  }
  ignore(state.registry.insert(child))
  ignore(
    @sys.write_file_sync(
      snapshot_path, "{\"viewport\":[\"Error: model at capacity\"]}",
    ),
  )
  let delivered_cmds : Array[@workspace.Command] = []
  state.handle_disconnect_with_runner("main.worker-capacity", runner=async fn(
    cmds,
  ) {
    record_runner_server(delivered_cmds, cmds)
  })
  match state.registry.get("main.worker-capacity") {
    Ok(agent) => assert_eq(agent.state, @types.AgentState::Failed)
    Err(_) => fail("agent should remain in registry")
  }
  match @phase.read_lifecycle(project_dir, "main.worker-capacity") {
    Some(lifecycle) => {
      assert_eq(
        lifecycle.process,
        @phase.ProcessState::Failed(
          reason=@phase.FailureReason::ModelAtCapacity,
        ),
      )
      match lifecycle.workflow {
        @phase.WorkflowState::Worker(
          @phase.WorkerLifecycle::Failed(
            reason=@phase.FailureReason::ModelAtCapacity
          )
        ) => ()
        _ => fail("expected typed model-capacity failure")
      }
    }
    None => fail("expected persisted lifecycle")
  }
  assert_eq(delivered_cmds.length(), 1)
  assert_true(
    delivered_cmds[0].args[3].contains(
      "[FAILED: main.worker-capacity] model at capacity",
    ),
  )
  run_shell(
    "rm -rf /tmp/choir-server-disconnect-capacity && rm -f /tmp/choir-viewport-main.worker-capacity.json",
  )
}

///|
async test "schedule_disconnect is cancelled by re-register within grace period" {
  let state = ServerState::new(@types.Config::default())
  let parent = { ..build_agent("root", None), role: @types.Role::TL }
  ignore(state.registry.insert(parent))
  let child = {
    ..build_agent("main.gem-1", Some("root")),
    branch: "main.gem-1",
  }
  ignore(state.registry.insert(child))
  // Connection closes — schedule disconnect at t=100
  state.schedule_disconnect("main.gem-1", 100L)
  assert_true(state.pending_disconnects.contains("main.gem-1"))
  // Agent re-registers at t=105 (within grace period)
  ignore(state.register_agent(child))
  assert_false(state.pending_disconnects.contains("main.gem-1"))
  // Process at t=200 — nothing should happen, agent is still Active
  let delivered_cmds : Array[@workspace.Command] = []
  state.process_pending_disconnects_with_runner(200L, 60L, runner=async fn(
    cmds,
  ) {
    record_runner_server(delivered_cmds, cmds)
  })
  match state.registry.get("main.gem-1") {
    Ok(agent) => assert_eq(agent.state, @types.AgentState::Active)
    Err(_) => fail("Expected agent to remain Active")
  }
  assert_eq(delivered_cmds.length(), 0)
}

///|
async test "schedule_disconnect fires after grace period expires" {
  let project_dir = "/tmp/choir-server-disconnect-expiry"
  run_shell(
    "rm -rf /tmp/choir-server-disconnect-expiry && mkdir -p /tmp/choir-server-disconnect-expiry/.choir/kv",
  )
  let state = ServerState::new({ ..@types.Config::default(), project_dir, })
  let parent = { ..build_agent("root", None), role: @types.Role::TL }
  ignore(state.registry.insert(parent))
  let child = {
    ..build_agent("main.dead-1", Some("root")),
    branch: "main.dead-1",
  }
  ignore(state.registry.insert(child))
  // Connection closes at t=100
  state.schedule_disconnect("main.dead-1", 100L)
  // Process at t=130 — within grace period, nothing happens
  let cmds1 : Array[@workspace.Command] = []
  state.process_pending_disconnects_with_runner(130L, 60L, runner=async fn(
    cmds,
  ) {
    record_runner_server(cmds1, cmds)
  })
  assert_eq(cmds1.length(), 0)
  match state.registry.get("main.dead-1") {
    Ok(agent) => assert_eq(agent.state, @types.AgentState::Active)
    Err(_) => fail("Expected agent still Active")
  }
  // Process at t=161 — grace period expired, fires FAILED
  let cmds2 : Array[@workspace.Command] = []
  state.process_pending_disconnects_with_runner(161L, 60L, runner=async fn(
    cmds,
  ) {
    record_runner_server(cmds2, cmds)
  })
  match state.registry.get("main.dead-1") {
    Ok(agent) => assert_eq(agent.state, @types.AgentState::Failed)
    Err(_) => fail("Expected agent to remain in registry")
  }
  assert_eq(cmds2.length(), 1)
  assert_true(cmds2[0].args[3].contains("[FAILED: main.dead-1]"))
  run_shell("rm -rf /tmp/choir-server-disconnect-expiry")
}
