///|
test "file_pr_plan builds tracked result when tracking enabled" {
  let args : FilePrArgs = {
    branch: "main.task-leaf",
    parent_branch: Some("main"),
    tracked_agent_id: "main.task-leaf",
    title: None,
    body: None,
  }
  let pr : PullRequestInfo = {
    number: 7,
    url: "https://example.test/pr/7",
    state: "OPEN",
  }
  let plan = file_pr_plan(args, "main", pr, true)
  match plan.tracked_pr {
    Some(tracked) => {
      assert_eq(tracked.pr_number, 7)
      assert_eq(tracked.agent_id, "main.task-leaf")
      assert_eq(tracked.branch, "main.task-leaf")
      assert_eq(tracked.parent_branch, "main")
      assert_eq(tracked.pr_url, "https://example.test/pr/7")
    }
    None => fail("expected tracked PR")
  }
  match plan.dev_event {
    @phase.DevEvent::PRCreated(pr_number~, url~, branch~) => {
      assert_eq(pr_number, 7)
      assert_eq(url, "https://example.test/pr/7")
      assert_eq(branch, "main.task-leaf")
    }
    _ => fail("expected PRCreated")
  }
  assert_eq(
    plan.notify_message,
    "[PR READY] PR #7 filed: https://example.test/pr/7",
  )
  match plan.response {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      assert_eq(map.get("status"), Some(String::to_json("pr_created")))
      assert_eq(map.get("tracked"), Some(Bool::to_json(true)))
    }
    _ => fail("expected OK response")
  }
}

///|
test "file_pr_plan omits tracked PR when tracking disabled" {
  let args : FilePrArgs = {
    branch: "leaf",
    parent_branch: Some("main"),
    tracked_agent_id: "leaf",
    title: None,
    body: None,
  }
  let pr : PullRequestInfo = {
    number: 9,
    url: "https://example.test/pr/9",
    state: "OPEN",
  }
  let plan = file_pr_plan(args, "main", pr, false)
  assert_eq(plan.tracked_pr, None)
  match plan.response {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      assert_eq(map.get("tracked"), Some(Bool::to_json(false)))
      assert_eq(map.get("pr_number"), Some(Int::to_json(9)))
    }
    _ => fail("expected OK response")
  }
}

///|
test "file_pr_post_success_effects gates poller track and parent notify on capabilities" {
  let args : FilePrArgs = {
    branch: "main.leaf",
    parent_branch: Some("main"),
    tracked_agent_id: "main.leaf",
    title: None,
    body: None,
  }
  let pr : PullRequestInfo = {
    number: 3,
    url: "https://example.test/pr/3",
    state: "OPEN",
  }
  let plan_full = file_pr_plan(args, "main", pr, true)
  let full = file_pr_post_success_effects(plan_full, true, true)
  match full.poller_track {
    Some(t) => assert_eq(t.pr_number, 3)
    None => fail("expected poller track when poller available")
  }
  match full.notify_message_for_parent {
    Some(m) => assert_eq(m, "[PR READY] PR #3 filed: https://example.test/pr/3")
    None => fail("expected notify message when registry available")
  }
  let plan_no_poller = file_pr_plan(args, "main", pr, true)
  let no_poller = file_pr_post_success_effects(plan_no_poller, false, true)
  assert_eq(no_poller.poller_track, None)
  let plan_no_reg = file_pr_plan(args, "main", pr, true)
  let no_registry = file_pr_post_success_effects(plan_no_reg, true, false)
  assert_eq(no_registry.notify_message_for_parent, None)
}

///|
test "file_pr_auto_notify_plan delivers and formats delivery log append" {
  let parent : @types.Agent = {
    agent_id: @types.AgentId("main.tl"),
    role: @types.Role::TL,
    agent_type: @types.AgentType::Claude,
    parent: None,
    workspace: "/tmp",
    branch: "main",
    terminal_target: @types.LocalTarget::parse("zellij-tab:choir:tl"),
    host: @types.Host::Local,
    spawn_depth: 0,
    state: @types.AgentState::Active,
  }
  let msg = "[PR READY] PR #1 filed: https://ex/pr/1"
  let plan = file_pr_auto_notify_plan(Ok(parent), "main.leaf", msg)
  match plan {
    FilePrAutoNotifyPlan::Deliver(delivery~, delivery_log_append~) => {
      let expected = @message.plan_delivery(parent, "main.leaf", msg, "success")
      assert_eq(delivery, expected)
      assert_eq(
        delivery_log_append,
        "[auto-notify] caller=main.leaf parent=main.tl delivery=" +
        delivery.to_string() +
        "\n",
      )
    }
    _ => fail("expected Deliver")
  }
}

///|
test "file_pr_auto_notify_plan logs only when parent resolution fails" {
  let err = @types.ChoirError::AgentNotFound("main.tl")
  let plan = file_pr_auto_notify_plan(
    Err(err),
    "main.leaf",
    "[PR READY] PR #1 filed: https://ex/pr/1",
  )
  match plan {
    FilePrAutoNotifyPlan::ParentResolutionFailed(
      delivery_log_append~,
      parent_resolve_error~
    ) => {
      assert_eq(parent_resolve_error, err.message())
      assert_eq(
        delivery_log_append,
        "[auto-notify] resolve_parent_for_notify failed error=" +
        err.message() +
        "\n",
      )
    }
    _ => fail("expected ParentResolutionFailed")
  }
}

///|
test "file_pr_auto_notify_delivery_failed_log_append normalizes one line" {
  assert_eq(
    file_pr_auto_notify_delivery_failed_log_append("oops"),
    "[auto-notify] delivery failed error=oops\n",
  )
}

///|
test "notify_parent_plan no registry records success event and ok response" {
  let args : CallerMessageArgs = {
    caller_id: "main.leaf",
    message: "done",
    status: "success",
  }
  match notify_parent_plan(args, None) {
    NotifyParentPlan::NoRegistry(dev_event~, response~) => {
      assert_eq(dev_event, @phase.DevEvent::NotifyParentSuccess(message="done"))
      match response {
        @types.Response::Ok(fields) => {
          let map = fields.to_json_map()
          assert_eq(map.get("status"), Some(String::to_json("notified")))
        }
        _ => fail("expected ok response")
      }
    }
    _ => fail("expected NoRegistry")
  }
}

///|
test "notify_parent_plan maps parent resolve error to ParentResolveFailed" {
  let args : CallerMessageArgs = {
    caller_id: "main.leaf",
    message: "x",
    status: "info",
  }
  let err = @types.ChoirError::AgentNotFound("main.tl")
  match notify_parent_plan(args, Some(Err(err))) {
    NotifyParentPlan::ParentResolveFailed(error_message~) =>
      assert_eq(error_message, err.message())
    _ => fail("expected ParentResolveFailed")
  }
}

///|
test "notify_parent_plan deliver matches plan_delivery and success response" {
  let parent : @types.Agent = {
    agent_id: @types.AgentId("main.tl"),
    role: @types.Role::TL,
    agent_type: @types.AgentType::Claude,
    parent: None,
    workspace: "/tmp",
    branch: "main",
    terminal_target: @types.LocalTarget::parse("zellij-tab:choir:tl"),
    host: @types.Host::Local,
    spawn_depth: 0,
    state: @types.AgentState::Active,
  }
  let args : CallerMessageArgs = {
    caller_id: "main.leaf",
    message: "hello",
    status: "failure",
  }
  let expected_delivery = @message.plan_delivery(
    parent, "main.leaf", "hello", "failure",
  )
  match notify_parent_plan(args, Some(Ok(parent))) {
    NotifyParentPlan::Deliver(delivery~, dev_event_on_success~, response_ok~) => {
      assert_eq(delivery, expected_delivery)
      assert_eq(
        dev_event_on_success,
        @phase.DevEvent::NotifyParentSuccess(message="hello"),
      )
      match response_ok {
        @types.Response::Ok(fields) => {
          let map = fields.to_json_map()
          assert_eq(map.get("status"), Some(String::to_json("notified")))
        }
        _ => fail("expected ok response")
      }
    }
    _ => fail("expected Deliver")
  }
}

///|
test "send_message_delivery_log_append matches dispatch log shape" {
  let agent : @types.Agent = {
    agent_id: @types.AgentId("main.leaf"),
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Claude,
    parent: Some("main"),
    workspace: "/tmp",
    branch: "main.leaf",
    terminal_target: @types.LocalTarget::parse("zellij-tab:choir:leaf"),
    host: @types.Host::Local,
    spawn_depth: 0,
    state: @types.AgentState::Active,
  }
  let delivery = @message.plan_delivery(agent, "main.tl", "hi", "success")
  assert_eq(
    send_message_delivery_log_append("main.leaf", agent, delivery),
    "[send_message] target=main.leaf terminal_target=zellij-tab:choir:leaf delivery=" +
    delivery.to_string() +
    "\n",
  )
}

///|
test "send_message_delivery_log_append uses NONE without terminal_target" {
  let agent : @types.Agent = {
    agent_id: @types.AgentId("main.leaf"),
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Claude,
    parent: Some("main"),
    workspace: "/tmp",
    branch: "main.leaf",
    terminal_target: None,
    host: @types.Host::Local,
    spawn_depth: 0,
    state: @types.AgentState::Active,
  }
  let delivery = @message.plan_delivery(agent, "main.tl", "hi", "success")
  assert_true(
    send_message_delivery_log_append("main.leaf", agent, delivery).contains(
      "terminal_target=NONE",
    ),
  )
}

///|
test "send_message_plan no registry returns best-effort sent" {
  match send_message_plan("main.x", "a", "m", "success", None) {
    SendMessagePlan::NoRegistry(response~) =>
      match response {
        @types.Response::Ok(fields) => {
          let map = fields.to_json_map()
          assert_eq(map.get("status"), Some(String::to_json("sent")))
        }
        _ => fail("expected ok")
      }
    _ => fail("expected NoRegistry")
  }
}

///|
test "send_message_plan maps registry lookup error" {
  let err = @types.ChoirError::AgentNotFound("main.missing")
  match send_message_plan("main.missing", "a", "m", "info", Some(Err(err))) {
    SendMessagePlan::RegistryLookupFailed(error_message~) =>
      assert_eq(error_message, err.message())
    _ => fail("expected RegistryLookupFailed")
  }
}

///|
test "send_message_plan deliver matches plan_delivery and log append" {
  let agent : @types.Agent = {
    agent_id: @types.AgentId("main.leaf"),
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Claude,
    parent: Some("main"),
    workspace: "/tmp",
    branch: "main.leaf",
    terminal_target: @types.LocalTarget::parse("zellij-tab:choir:leaf"),
    host: @types.Host::Local,
    spawn_depth: 0,
    state: @types.AgentState::Active,
  }
  let expected_delivery = @message.plan_delivery(
    agent, "main.tl", "hello", "failure",
  )
  match
    send_message_plan(
      "main.leaf",
      "main.tl",
      "hello",
      "failure",
      Some(Ok(agent)),
    ) {
    SendMessagePlan::Deliver(delivery~, delivery_log_append~, response_ok~) => {
      assert_eq(delivery, expected_delivery)
      assert_eq(
        delivery_log_append,
        send_message_delivery_log_append("main.leaf", agent, expected_delivery),
      )
      match response_ok {
        @types.Response::Ok(fields) => {
          let map = fields.to_json_map()
          assert_eq(map.get("status"), Some(String::to_json("sent")))
        }
        _ => fail("expected ok")
      }
    }
    _ => fail("expected Deliver")
  }
}

///|
async test "interpret_send_message no registry skips delivery" {
  let plan = send_message_plan("t", "s", "m", "ok", None)
  let got = interpret_send_message(
    plan, "/tmp/choir-send-msg-test", mock_runner_all_ok,
  )
  match got {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      assert_eq(map.get("status"), Some(String::to_json("sent")))
    }
    _ => fail("expected ok")
  }
}

///|
async test "interpret_send_message registry lookup failed returns err" {
  let err = @types.ChoirError::AgentNotFound("x")
  let plan = send_message_plan("x", "s", "m", "ok", Some(Err(err)))
  let got = interpret_send_message(
    plan, "/tmp/choir-send-msg-test", mock_runner_all_ok,
  )
  match got {
    @types.Response::Err(msg) => assert_eq(msg, err.message())
    _ => fail("expected err")
  }
}

///|
fn send_message_interpret_test_project_dir() -> String {
  "/tmp/choir-send-msg-interpret-" + @sys.get_pid().to_string()
}

///|
async fn sleep_zero_for_send_msg(_ms : Int) -> Unit {
  @async.sleep(0)
}

///|
async fn runner_send_msg_always_fail(
  cmds : Array[@workspace.Command],
) -> Array[Int] {
  @async.sleep(0)
  let statuses = []
  for _ in cmds {
    statuses.push(1)
  }
  statuses
}

///|
async test "interpret_send_message deliver tcp success appends send_message log" {
  let project_dir = send_message_interpret_test_project_dir()
  assert_true(@sys.create_dir_all(project_dir + "/.choir"))
  let log_path = project_dir + "/.choir/delivery.log"
  ignore(@sys.delete_file_sync(log_path))
  let agent : @types.Agent = {
    agent_id: @types.AgentId("main.rleaf"),
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Claude,
    parent: Some("main"),
    workspace: "/tmp",
    branch: "main.rleaf",
    terminal_target: None,
    host: @types.Host::Remote("127.0.0.1"),
    spawn_depth: 0,
    state: @types.AgentState::Active,
  }
  let plan = send_message_plan(
    "main.rleaf",
    "main.tl",
    "text",
    "success",
    Some(Ok(agent)),
  )
  let got = interpret_send_message(plan, project_dir, mock_runner_all_ok)
  match got {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      assert_eq(map.get("status"), Some(String::to_json("sent")))
    }
    _ => fail("expected ok")
  }
  let delivery = @message.plan_delivery(agent, "main.tl", "text", "success")
  let expected_log = send_message_delivery_log_append(
    "main.rleaf", agent, delivery,
  )
  assert_eq(@sys.read_file(log_path), expected_log)
}

///|
async test "interpret_send_message deliver local terminal failure returns err and keeps send_message log" {
  let project_dir = send_message_interpret_test_project_dir()
  assert_true(@sys.create_dir_all(project_dir + "/.choir"))
  let log_path = project_dir + "/.choir/delivery.log"
  ignore(@sys.delete_file_sync(log_path))
  let agent : @types.Agent = {
    agent_id: @types.AgentId("main.leaf"),
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Claude,
    parent: Some("main"),
    workspace: "/tmp",
    branch: "main.leaf",
    terminal_target: @types.LocalTarget::parse("zellij-tab:choir:leaf"),
    host: @types.Host::Local,
    spawn_depth: 0,
    state: @types.AgentState::Active,
  }
  let plan = send_message_plan(
    "main.leaf",
    "main.tl",
    "x",
    "info",
    Some(Ok(agent)),
  )
  let got = interpret_send_message(
    plan,
    project_dir,
    runner_send_msg_always_fail,
    sleep_fn=sleep_zero_for_send_msg,
  )
  match got {
    @types.Response::Err(msg) =>
      assert_true(msg.contains("delivery command failed"))
    _ => fail("expected err from execute_delivery")
  }
  let delivery = @message.plan_delivery(agent, "main.tl", "x", "info")
  let send_line = send_message_delivery_log_append("main.leaf", agent, delivery)
  assert_true(@sys.read_file(log_path).contains(send_line))
}

///|
test "file_pr_preflight_create_inputs copies branch paths and title/body" {
  let args : FilePrArgs = {
    branch: "main.leaf",
    parent_branch: Some("ignored"),
    tracked_agent_id: "main.leaf",
    title: Some("title"),
    body: Some("body"),
  }
  let ins = file_pr_preflight_create_inputs(args, "main", "/tmp/wt")
  assert_eq(ins.branch, "main.leaf")
  assert_eq(ins.parent_branch, "main")
  assert_eq(ins.file_pr_dir, "/tmp/wt")
  assert_eq(ins.title, Some("title"))
  assert_eq(ins.body, Some("body"))
}

///|
test "file_pr_preflight_host_steps is preflight then push then ensure_pr" {
  let steps = file_pr_preflight_host_steps()
  assert_eq(steps.length(), 3)
  assert_eq(steps[0], FilePrPreflightHostStep::EnsureBranchReady)
  assert_eq(steps[1], FilePrPreflightHostStep::GitPush)
  assert_eq(steps[2], FilePrPreflightHostStep::EnsurePullRequest)
}

///|
async fn mock_preflight_err(
  _branch : String,
  _parent_branch : String,
  _dir : String,
) -> Result[Unit, String] {
  @async.sleep(0)
  Err("cannot file PR: branch 'x' is missing locally.")
}

///|
async fn mock_preflight_ok(
  _branch : String,
  _parent_branch : String,
  _dir : String,
) -> Result[Unit, String] {
  @async.sleep(0)
  Ok(())
}

///|
async fn mock_runner_all_ok(cmds : Array[@workspace.Command]) -> Array[Int] {
  @async.sleep(0)
  let statuses = []
  for _ in cmds {
    statuses.push(0)
  }
  statuses
}

///|
async fn mock_runner_first_fails(
  cmds : Array[@workspace.Command],
) -> Array[Int] {
  @async.sleep(0)
  let statuses = []
  for i = 0; i < cmds.length(); i = i + 1 {
    statuses.push(if i == 0 { 3 } else { 0 })
  }
  statuses
}

///|
async fn mock_capture_empty(_cmd : @workspace.Command) -> (Int, String) {
  @async.sleep(0)
  (0, "")
}

///|
async fn mock_ensure_pr_ok(
  _branch : String,
  _parent_branch : String,
  _dir : String,
  _title : String?,
  _body : String?,
) -> Result[PullRequestInfo, String] {
  @async.sleep(0)
  Ok({ number: 42, url: "https://example.test/pr/42", state: "OPEN" })
}

///|
async fn mock_ensure_pr_err(
  _branch : String,
  _parent_branch : String,
  _dir : String,
  _title : String?,
  _body : String?,
) -> Result[PullRequestInfo, String] {
  @async.sleep(0)
  Err("gh pr create failed for branch: main.leaf")
}

///|
async test "interpret_file_pr_preflight_create returns preflight error and skips push" {
  let inputs : FilePrPreflightCreateInputs = {
    branch: "main.leaf",
    parent_branch: "main",
    file_pr_dir: "/wt",
    title: None,
    body: None,
  }
  let got = interpret_file_pr_preflight_create(
    inputs, mock_preflight_err, mock_runner_all_ok, mock_capture_empty, mock_ensure_pr_ok,
  )
  match got {
    Err(msg) => assert_true(msg.contains("missing locally"))
    Ok(_) => fail("expected Err from preflight")
  }
}

///|
async test "interpret_file_pr_preflight_create returns push failure detail" {
  let inputs : FilePrPreflightCreateInputs = {
    branch: "main.leaf",
    parent_branch: "main",
    file_pr_dir: "/wt",
    title: None,
    body: None,
  }
  let got = interpret_file_pr_preflight_create(
    inputs, mock_preflight_ok, mock_runner_first_fails, mock_capture_empty, mock_ensure_pr_ok,
  )
  match got {
    Err(msg) =>
      // `run_strict` uses either `git failed (exit …)` with stderr detail or
      // `command failed with status …` when capture returned empty output.
      assert_true(msg.contains("3") && msg.contains("failed"))
    Ok(_) => fail("expected Err from push")
  }
}

///|
async test "interpret_file_pr_preflight_create returns ensure_pr error after push" {
  let inputs : FilePrPreflightCreateInputs = {
    branch: "main.leaf",
    parent_branch: "main",
    file_pr_dir: "/wt",
    title: None,
    body: None,
  }
  let got = interpret_file_pr_preflight_create(
    inputs, mock_preflight_ok, mock_runner_all_ok, mock_capture_empty, mock_ensure_pr_err,
  )
  match got {
    Err(msg) => assert_eq(msg, "gh pr create failed for branch: main.leaf")
    Ok(_) => fail("expected Err from ensure_pr")
  }
}

///|
async test "interpret_file_pr_preflight_create yields PR on happy path" {
  let inputs : FilePrPreflightCreateInputs = {
    branch: "main.leaf",
    parent_branch: "main",
    file_pr_dir: "/wt",
    title: Some("t"),
    body: Some("b"),
  }
  let got = interpret_file_pr_preflight_create(
    inputs, mock_preflight_ok, mock_runner_all_ok, mock_capture_empty, mock_ensure_pr_ok,
  )
  match got {
    Ok(pr) => {
      assert_eq(pr.number, 42)
      assert_eq(pr.url, "https://example.test/pr/42")
      assert_eq(pr.state, "OPEN")
    }
    Err(_) => fail("expected Ok")
  }
}

///|
fn merge_pr_test_tracked(
  review : @poller.ReviewState,
  branch : String,
) -> @poller.TrackedPR {
  {
    pr_number: 9,
    agent_id: "main.leaf",
    branch,
    parent_branch: "main",
    pr_url: "https://example.test/pr/9",
    first_seen: 0L,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: review,
    last_review_bodies: "",
    last_sha: "",
    notified_parent: false,
    last_ci_failed: false,
    last_timeout_at: 0L,
  }
}

///|
test "merge_pr_preflight_host_steps is poller snapshot then thread fetch" {
  let steps = merge_pr_preflight_host_steps()
  assert_eq(steps.length(), 2)
  assert_eq(steps[0], MergePrPreflightHostStep::PollerSnapshot)
  assert_eq(steps[1], MergePrPreflightHostStep::FetchUnresolvedReviewThreads)
}

///|
async fn mock_preflight_capture_unreachable(
  _cmd : @workspace.Command,
) -> (Int, String) {
  @async.sleep(0)
  fail("unexpected gh capture when force=true")
  (0, "")
}

///|
async test "interpret_merge_pr_preflight force bypass skips capture" {
  let got = interpret_merge_pr_preflight(
    true,
    1,
    None,
    "/repo",
    mock_preflight_capture_unreachable,
  )
  match got {
    Ok(_) => ()
    Err(e) => fail(e)
  }
}

///|
async fn mock_preflight_capture_no_unresolved_threads(
  cmd : @workspace.Command,
) -> (Int, String) {
  @async.sleep(0)
  if cmd.program == "gh" && cmd.args.contains("repo") {
    return (0, "{\"owner\":{\"login\":\"o\"},\"name\":\"r\"}")
  }
  if cmd.program == "gh" && cmd.args.contains("graphql") {
    return (
      0, "{\"data\":{\"repository\":{\"pullRequest\":{\"reviewThreads\":{\"nodes\":[]}}}}}",
    )
  }
  (0, "")
}

///|
async test "interpret_merge_pr_preflight ok when no poller block and no threads" {
  let got = interpret_merge_pr_preflight(
    false,
    7,
    None,
    "/repo",
    mock_preflight_capture_no_unresolved_threads,
  )
  match got {
    Ok(_) => ()
    Err(e) => fail(e)
  }
}

///|
async fn mock_preflight_capture_one_unresolved_thread(
  cmd : @workspace.Command,
) -> (Int, String) {
  @async.sleep(0)
  if cmd.program == "gh" && cmd.args.contains("repo") {
    return (0, "{\"owner\":{\"login\":\"o\"},\"name\":\"r\"}")
  }
  if cmd.program == "gh" && cmd.args.contains("graphql") {
    let body =
      #|{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"PRRT_abc","isResolved":false,"path":"src/x.mbt","comments":{"nodes":[{"body":"fix it"}]}}]}}}}}
    return (0, body)
  }
  (0, "")
}

///|
async test "interpret_merge_pr_preflight err when review threads unresolved" {
  let got = interpret_merge_pr_preflight(
    false,
    3,
    None,
    "/repo",
    mock_preflight_capture_one_unresolved_thread,
  )
  match got {
    Err(msg) => {
      assert_true(msg.contains("PR #3"))
      assert_true(msg.contains("unresolved review thread"))
      assert_true(msg.contains("fix it"))
    }
    Ok(_) => fail("expected Err")
  }
}

///|
async test "interpret_merge_pr_preflight err when poller ChangesRequested" {
  let ps = @poller.PollerState::new()
  ps.track_recovered(
    9,
    "main.leaf",
    "main.topic",
    "main",
    "https://ex/9",
    0L,
    @poller.ReviewState::ChangesRequested,
    "",
    "",
    false,
  )
  let got = interpret_merge_pr_preflight(
    false,
    9,
    Some(ps),
    "/repo",
    mock_preflight_capture_no_unresolved_threads,
  )
  match got {
    Err(msg) => assert_true(msg.contains("ChangesRequested"))
    Ok(_) => fail("expected Err from poller gate")
  }
}

///|
test "merge_pr_preflight_block_message prefers ChangesRequested over thread gate" {
  let t = merge_pr_test_tracked(
    @poller.ReviewState::ChangesRequested,
    "main.leaf",
  )
  match merge_pr_preflight_block_message(9, Some(t), 2, "threads") {
    Some(msg) => {
      assert_true(msg.contains("ChangesRequested"))
      assert_false(msg.contains("unresolved review thread"))
    }
    None => fail("expected block")
  }
}

///|
test "merge_pr_preflight_block_message blocks on unresolved threads" {
  match merge_pr_preflight_block_message(3, None, 1, "body") {
    Some(msg) => {
      assert_true(msg.contains("PR #3"))
      assert_true(msg.contains("1 unresolved review thread"))
      assert_true(msg.contains("body"))
      assert_true(msg.contains("resolve_review_thread"))
    }
    None => fail("expected block")
  }
}

///|
test "merge_pr_preflight_block_message allows Approved with no threads" {
  let t = merge_pr_test_tracked(@poller.ReviewState::Approved, "main.leaf")
  assert_eq(merge_pr_preflight_block_message(9, Some(t), 0, ""), None)
}

///|
test "merge_pr_merge_failure_message classifies conflict output" {
  assert_eq(
    merge_pr_merge_failure_message(7, "Merge conflict: foo"),
    "merge conflict on PR #7: Merge conflict: foo",
  )
}

///|
test "merge_pr_merge_failure_message classifies not mergeable" {
  assert_eq(
    merge_pr_merge_failure_message(2, "NOT MERGEABLE because"),
    "merge conflict on PR #2: NOT MERGEABLE because",
  )
}

///|
test "merge_pr_merge_failure_message uses generic when non-empty" {
  assert_eq(
    merge_pr_merge_failure_message(4, "permission denied"),
    "merge failed for PR #4: permission denied",
  )
}

///|
test "merge_pr_merge_failure_message empty stderr" {
  assert_eq(merge_pr_merge_failure_message(5, ""), "merge failed for PR #5")
}

///|
test "merge_pr_pr_merged_event_url_slug uses extract_slug from branch" {
  assert_eq(
    merge_pr_pr_merged_event_url_slug(1, Some("main.my-slug")),
    "my-slug",
  )
}

///|
test "merge_pr_pr_merged_event_url_slug fallback without branch" {
  assert_eq(merge_pr_pr_merged_event_url_slug(42, None), "PR-42")
}

///|
test "merge_pr_post_success_plan uses tracked branch slug when poller available" {
  let plan = merge_pr_post_success_plan(5, true, Some("main.leaf-slug"))
  assert_eq(plan.poller_untrack_and_write_state, true)
  assert_eq(plan.tl_event, @phase.TLEvent::PRMerged(number=5, url="leaf-slug"))
  match plan.response {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      assert_eq(map.get("status"), Some(String::to_json("merged")))
    }
    _ => fail("expected OK merged response")
  }
}

///|
test "merge_pr_post_success_plan untrack intent when poller on but PR not tracked" {
  let plan = merge_pr_post_success_plan(9, true, None)
  assert_eq(plan.poller_untrack_and_write_state, true)
  assert_eq(plan.tl_event, @phase.TLEvent::PRMerged(number=9, url="PR-9"))
}

///|
test "merge_pr_post_success_plan ignores branch when poller unavailable" {
  let plan = merge_pr_post_success_plan(3, false, Some("main.ignored"))
  assert_eq(plan.poller_untrack_and_write_state, false)
  assert_eq(plan.tl_event, @phase.TLEvent::PRMerged(number=3, url="PR-3"))
}

///|
test "merge_pr_mutex_name prefixes branch" {
  assert_eq(merge_pr_mutex_name("main"), "branch:main")
}

///|
test "merge_pr_host_step_sequence is gh merge then git fetch" {
  let steps = merge_pr_host_step_sequence()
  assert_eq(steps.length(), 2)
  assert_eq(steps[0], MergePrHostStep::GhPrMerge)
  assert_eq(steps[1], MergePrHostStep::GitFetch)
}

///|
test "merge_pr_serialization_busy_message is stable" {
  assert_eq(
    merge_pr_serialization_busy_message(),
    "merge serialization lock held by another agent, retry shortly",
  )
}

///|
async fn mock_merge_host_runner_ok(
  cmds : Array[@workspace.Command],
) -> Array[Int] {
  @async.sleep(0)
  let statuses = []
  for _ in cmds {
    statuses.push(0)
  }
  statuses
}

///|
async fn mock_merge_host_runner_gh_fails(
  cmds : Array[@workspace.Command],
) -> Array[Int] {
  @async.sleep(0)
  let statuses = []
  for i = 0; i < cmds.length(); i = i + 1 {
    statuses.push(if i == 0 { 1 } else { 0 })
  }
  statuses
}

///|
async fn mock_merge_host_capture_for_merge(
  cmd : @workspace.Command,
) -> (Int, String) {
  @async.sleep(0)
  if cmd.program == "gh" && cmd.args.length() >= 2 && cmd.args[0] == "pr" {
    return (1, "permission denied\n")
  }
  (0, "")
}

///|
async test "interpret_merge_pr_merge_host ok without mutex" {
  let got = interpret_merge_pr_merge_host(
    "main",
    42,
    "main.tl",
    None,
    0L,
    mock_merge_host_runner_ok,
    mock_capture_empty,
  )
  match got {
    Ok(_) => ()
    Err(e) => fail("expected Ok got " + e)
  }
}

///|
async test "interpret_merge_pr_merge_host maps merge failure via merge_pr_command capture" {
  let got = interpret_merge_pr_merge_host(
    "main",
    4,
    "main.tl",
    None,
    0L,
    mock_merge_host_runner_gh_fails,
    mock_merge_host_capture_for_merge,
  )
  match got {
    Err(msg) =>
      assert_eq(msg, merge_pr_merge_failure_message(4, "permission denied"))
    Ok(_) => fail("expected Err")
  }
}

///|
async test "interpret_merge_pr_merge_host returns busy when mutex held" {
  let reg = @registry.MutexRegistry::new()
  let name = merge_pr_mutex_name("main")
  let (holder_ok, _) = reg.acquire(
    name, "other-agent", merge_pr_mutex_ttl_sec, 50L,
  )
  assert_true(holder_ok)
  let got = interpret_merge_pr_merge_host(
    "main",
    1,
    "waiter",
    Some(reg),
    50L,
    mock_merge_host_runner_ok,
    mock_capture_empty,
  )
  match got {
    Err(msg) => assert_eq(msg, merge_pr_serialization_busy_message())
    Ok(_) => fail("expected busy Err")
  }
}

///|
test "merge_pr_tracked_branch_for_post_success is None without poller" {
  assert_eq(merge_pr_tracked_branch_for_post_success(None, 1), None)
}

///|
test "merge_pr_tracked_branch_for_post_success is None when PR not tracked" {
  let ps = @poller.PollerState::new()
  assert_eq(merge_pr_tracked_branch_for_post_success(Some(ps), 7), None)
}

///|
test "merge_pr_tracked_branch_for_post_success returns branch when tracked" {
  let ps = @poller.PollerState::new()
  ps.track(4, "main.leaf", "main.topic", "main", "https://ex/4", 0L)
  assert_eq(
    merge_pr_tracked_branch_for_post_success(Some(ps), 4),
    Some("main.topic"),
  )
}

///|
test "shutdown_missing_caller_response is best-effort ok" {
  let r = shutdown_missing_caller_response()
  match r {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      assert_eq(map.get("status"), Some(String::to_json("shutdown")))
    }
    _ => fail("expected ok")
  }
}

///|
test "shutdown_poller_block_message matches dispatch wording" {
  assert_eq(
    shutdown_poller_block_message(42),
    "cannot shutdown: PR #42 has changes requested — push fixes first",
  )
}

///|
test "shutdown_intent_remove_choir_worktree matches choir worktree paths" {
  assert_true(
    shutdown_intent_remove_choir_worktree("/repo/.choir/worktrees/foo"),
  )
  assert_false(shutdown_intent_remove_choir_worktree("/repo"))
}

///|
fn kill_agent_test_agent(
  terminal_target : @types.LocalTarget?,
  workspace : String,
) -> @types.Agent {
  {
    agent_id: @types.AgentId("main.leaf"),
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Claude,
    parent: None,
    workspace,
    branch: "main.leaf",
    terminal_target,
    host: @types.Host::Local,
    spawn_depth: 0,
    state: @types.AgentState::Active,
  }
}

///|
test "kill_agent_pane_close_command is none without terminal_target" {
  let a = kill_agent_test_agent(None, "/repo")
  assert_eq(kill_agent_pane_close_command(a), None)
}

///|
test "kill_agent_pane_close_command matches local_close_target" {
  let t = match @types.LocalTarget::parse("zellij-tab:choir:leaf") {
    Some(v) => v
    None => fail("expected parse")
  }
  let a = kill_agent_test_agent(Some(t), "/repo")
  let expected = @workspace.local_close_target(t)
  match kill_agent_pane_close_command(a) {
    Some(cmd) => {
      assert_eq(cmd.program, expected.program)
      assert_eq(cmd.args, expected.args)
    }
    None => fail("expected close command")
  }
}

///|
test "kill_agent_worktree_remove_command follows choir worktree path rule" {
  let a = kill_agent_test_agent(None, "/proj/.choir/worktrees/slug-0")
  match kill_agent_worktree_remove_command(a) {
    Some(cmd) => {
      assert_eq(cmd.program, "git")
      assert_eq(cmd.args, [
        "worktree", "remove", "--force", "/proj/.choir/worktrees/slug-0",
      ])
    }
    None => fail("expected worktree remove")
  }
  let no_wt = kill_agent_test_agent(None, "/proj")
  assert_eq(kill_agent_worktree_remove_command(no_wt), None)
}

///|
test "kill_agent_ok_response matches killed envelope" {
  match kill_agent_ok_response("main.topic") {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      assert_eq(map.get("status"), Some(String::to_json("killed")))
      assert_eq(map.get("agent_id"), Some(String::to_json("main.topic")))
    }
    _ => fail("expected ok")
  }
}

///|
test "kill_agent_adapter_host_steps is pane close then worktree remove" {
  let steps = kill_agent_adapter_host_steps()
  assert_eq(steps.length(), 2)
  assert_eq(steps[0], KillAgentAdapterHostStep::PaneClose)
  assert_eq(steps[1], KillAgentAdapterHostStep::WorktreeRemove)
}

///|
async test "interpret_kill_agent err when no registry" {
  let args : KillAgentArgs = { agent_id: "main.x", reason: "r" }
  let got = interpret_kill_agent(args, None, mock_runner_all_ok)
  match got {
    @types.Response::Err(msg) => assert_eq(msg, "no agent registry available")
    _ => fail("expected no-registry err")
  }
}

///|
async test "interpret_kill_agent err when agent missing" {
  let reg = @registry.AgentRegistry::new()
  let args : KillAgentArgs = { agent_id: "main.missing", reason: "r" }
  let got = interpret_kill_agent(args, Some(reg), mock_runner_all_ok)
  match got {
    @types.Response::Err(msg) => assert_eq(msg, "agent not found: main.missing")
    _ => fail("expected not-found err")
  }
}

///|
async test "interpret_kill_agent closes pane, removes worktree, marks failed, returns killed" {
  let t = match @types.LocalTarget::parse("zellij-tab:choir:leaf") {
    Some(v) => v
    None => fail("expected parse")
  }
  let reg = @registry.AgentRegistry::new()
  let agent = kill_agent_test_agent(Some(t), "/proj/.choir/worktrees/slug-0")
  ignore(reg.upsert(agent))
  let args : KillAgentArgs = { agent_id: "main.leaf", reason: "cleanup" }
  let got = interpret_kill_agent(args, Some(reg), mock_runner_all_ok)
  match got {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      assert_eq(map.get("status"), Some(String::to_json("killed")))
      assert_eq(map.get("agent_id"), Some(String::to_json("main.leaf")))
    }
    _ => fail("expected ok")
  }
  match reg.get("main.leaf") {
    Ok(a) => assert_eq(a.state, @types.AgentState::Failed)
    Err(_) => fail("expected agent in registry")
  }
}

///|
test "shutdown_exit_plan blocked dev changes requested" {
  let lifecycle : @phase.AgentLifecycle = {
    agent_id: "main.l",
    role: @types.Role::Dev,
    process: @phase.ProcessState::Connected,
    workflow: @phase.WorkflowState::Dev(
      @phase.DevLifecycle::ChangesRequested(pr_number=3, next_round=1),
    ),
  }
  let plan = shutdown_exit_plan(lifecycle)
  assert_false(plan.apply_dev_exit_requested)
  assert_false(plan.attempt_worktree_cleanup)
  match plan.response {
    @types.Response::Err(msg) => assert_eq(msg, "Changes requested")
    _ => fail("expected Err")
  }
}

///|
test "shutdown_exit_plan deferred dev applies exit and skips cleanup" {
  let lifecycle : @phase.AgentLifecycle = {
    agent_id: "main.l",
    role: @types.Role::Dev,
    process: @phase.ProcessState::Connected,
    workflow: @phase.WorkflowState::Dev(
      @phase.DevLifecycle::ReviewOwned(
        pr_number=7,
        state=@phase.ReviewOwnership::OpenUnreviewed(url="https://ex/7"),
      ),
    ),
  }
  let plan = shutdown_exit_plan(lifecycle)
  assert_true(plan.apply_dev_exit_requested)
  assert_false(plan.attempt_worktree_cleanup)
  match plan.response {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      assert_eq(map.get("status"), Some(String::to_json("deferred")))
      assert_eq(
        map.get("warning"),
        Some("PR filed (7) at https://ex/7".to_json()),
      )
    }
    _ => fail("expected deferred ok")
  }
}

///|
test "shutdown_exit_plan allowed dev allows cleanup and exit" {
  let lifecycle : @phase.AgentLifecycle = {
    agent_id: "main.l",
    role: @types.Role::Dev,
    process: @phase.ProcessState::Connected,
    workflow: @phase.WorkflowState::Dev(@phase.DevLifecycle::Working),
  }
  let plan = shutdown_exit_plan(lifecycle)
  assert_true(plan.apply_dev_exit_requested)
  assert_true(plan.attempt_worktree_cleanup)
  match plan.response {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      assert_eq(map.get("status"), Some(String::to_json("shutdown")))
    }
    _ => fail("expected shutdown ok")
  }
}

///|
test "shutdown_exit_plan allowed tl skips dev exit but may cleanup worktree" {
  let lifecycle : @phase.AgentLifecycle = {
    agent_id: "main.tl",
    role: @types.Role::TL,
    process: @phase.ProcessState::Connected,
    workflow: @phase.WorkflowState::Supervisor(
      @phase.SupervisorLifecycle::Planning,
    ),
  }
  let plan = shutdown_exit_plan(lifecycle)
  assert_false(plan.apply_dev_exit_requested)
  assert_true(plan.attempt_worktree_cleanup)
  match plan.response {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      assert_eq(map.get("status"), Some(String::to_json("shutdown")))
    }
    _ => fail("expected shutdown ok")
  }
}

///|
test "shutdown_adapter_host_steps lists poller through cleanup" {
  let steps = shutdown_adapter_host_steps()
  assert_eq(steps.length(), 5)
  assert_eq(steps[0], ShutdownAdapterHostStep::PollerCriticalPhaseRead)
  assert_eq(steps[1], ShutdownAdapterHostStep::RegistryRoleLookup)
  assert_eq(steps[2], ShutdownAdapterHostStep::LifecycleRead)
  assert_eq(steps[3], ShutdownAdapterHostStep::DevExitEventApply)
  assert_eq(steps[4], ShutdownAdapterHostStep::WorktreeCleanupAttempt)
}

///|
test "shutdown_poller_block_pr_number is none without poller" {
  assert_eq(shutdown_poller_block_pr_number(None, "main.leaf"), None)
}

///|
test "shutdown_poller_block_pr_number matches critical phase" {
  let ps = @poller.PollerState::new()
  ps.track_recovered(
    77,
    "main.leaf",
    "main.topic",
    "main",
    "https://ex/77",
    0L,
    @poller.ReviewState::ChangesRequested,
    "",
    "",
    false,
  )
  assert_eq(shutdown_poller_block_pr_number(Some(ps), "main.leaf"), Some(77))
}

///|
test "shutdown_poller_block_pr_number is none when agent not in critical phase" {
  let ps = @poller.PollerState::new()
  ps.track_recovered(
    77,
    "other.leaf",
    "main.topic",
    "main",
    "https://ex/77",
    0L,
    @poller.ReviewState::ChangesRequested,
    "",
    "",
    false,
  )
  assert_eq(shutdown_poller_block_pr_number(Some(ps), "main.leaf"), None)
}

///|
test "shutdown_registry_role_for_caller falls back to dev" {
  assert_eq(shutdown_registry_role_for_caller(None, "main.x"), @types.Role::Dev)
  let reg = @registry.AgentRegistry::new()
  assert_eq(
    shutdown_registry_role_for_caller(Some(reg), "main.x"),
    @types.Role::Dev,
  )
}

///|
test "shutdown_registry_role_for_caller uses registry role" {
  let reg = @registry.AgentRegistry::new()
  ignore(
    reg.upsert({
      agent_id: "main.leaf",
      role: @types.Role::TL,
      agent_type: @types.AgentType::Claude,
      parent: None,
      workspace: "/tmp",
      branch: "main.leaf",
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  assert_eq(
    shutdown_registry_role_for_caller(Some(reg), "main.leaf"),
    @types.Role::TL,
  )
}

///|
async fn mock_shutdown_runner_record_worktree(
  cmds : Array[@workspace.Command],
) -> Array[Int] {
  @async.sleep(0)
  let statuses = []
  for _ in cmds {
    statuses.push(0)
  }
  statuses
}

///|
async test "interpret_shutdown blocks poller critical phase before plan" {
  let ps = @poller.PollerState::new()
  ps.track_recovered(
    5,
    "main.leaf",
    "b",
    "main",
    "https://ex/5",
    0L,
    @poller.ReviewState::ChangesRequested,
    "",
    "",
    false,
  )
  let args : ShutdownArgs = { caller_id: Some("main.leaf") }
  let got = interpret_shutdown(
    args,
    "/tmp",
    Some(ps),
    None,
    mock_shutdown_runner_record_worktree,
  )
  match got {
    @types.Response::Err(msg) =>
      assert_eq(msg, shutdown_poller_block_message(5))
    _ => fail("expected poller block")
  }
}

///|
async test "interpret_shutdown ok when caller missing uses best-effort" {
  let args : ShutdownArgs = { caller_id: None }
  let got = interpret_shutdown(
    args,
    "/tmp",
    None,
    None,
    mock_shutdown_runner_record_worktree,
  )
  match got {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      assert_eq(map.get("status"), Some(String::to_json("shutdown")))
    }
    _ => fail("expected missing-caller ok")
  }
}

///|
test "cancel_wave_resolved_caller_id defaults to main" {
  assert_eq(cancel_wave_resolved_caller_id(None), "main")
  assert_eq(cancel_wave_resolved_caller_id(Some("main.tl")), "main.tl")
}

///|
test "cancel_wave_non_terminal_agents keeps spawning and active only" {
  let base : @types.Agent = {
    agent_id: @types.AgentId("main.s"),
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Claude,
    parent: Some("main"),
    workspace: "/w",
    branch: "b",
    terminal_target: (None : @types.LocalTarget?),
    host: @types.Host::Local,
    spawn_depth: 0,
    state: @types.AgentState::Spawning,
  }
  let active = {
    ..base,
    agent_id: @types.AgentId("main.a"),
    state: @types.AgentState::Active,
  }
  let done = {
    ..base,
    agent_id: @types.AgentId("main.d"),
    state: @types.AgentState::Done,
  }
  let got = cancel_wave_non_terminal_agents([base, active, done])
  assert_eq(got.length(), 2)
  assert_eq(got[0].agent_id.to_string(), "main.s")
  assert_eq(got[1].agent_id.to_string(), "main.a")
}

///|
test "cancel_wave_poller_block_message matches dispatch wording" {
  assert_eq(
    cancel_wave_poller_block_message("main.leaf", 99),
    "cancel_wave: agent main.leaf is blocked by PR #99 with changes requested -- use force=true to override",
  )
}

///|
test "cancel_wave_preflight_block_message force skips gate" {
  let agent : @types.Agent = {
    agent_id: @types.AgentId("main.leaf"),
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Claude,
    parent: Some("main"),
    workspace: "/w",
    branch: "b",
    terminal_target: (None : @types.LocalTarget?),
    host: @types.Host::Local,
    spawn_depth: 0,
    state: @types.AgentState::Active,
  }
  let ps = @poller.PollerState::new()
  ps.track_recovered(
    5,
    "main.leaf",
    "b",
    "main",
    "url",
    0L,
    @poller.ReviewState::ChangesRequested,
    "",
    "",
    false,
  )
  assert_eq(cancel_wave_preflight_block_message(true, [agent], Some(ps)), None)
}

///|
test "cancel_wave_preflight_block_message none without poller" {
  let agent : @types.Agent = {
    agent_id: @types.AgentId("main.leaf"),
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Claude,
    parent: Some("main"),
    workspace: "/w",
    branch: "b",
    terminal_target: (None : @types.LocalTarget?),
    host: @types.Host::Local,
    spawn_depth: 0,
    state: @types.AgentState::Active,
  }
  assert_eq(cancel_wave_preflight_block_message(false, [agent], None), None)
}

///|
test "cancel_wave_preflight_block_message first agent wins" {
  let a1 : @types.Agent = {
    agent_id: @types.AgentId("main.first"),
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Claude,
    parent: Some("main"),
    workspace: "/w",
    branch: "b",
    terminal_target: (None : @types.LocalTarget?),
    host: @types.Host::Local,
    spawn_depth: 0,
    state: @types.AgentState::Active,
  }
  let a2 : @types.Agent = {
    agent_id: @types.AgentId("main.second"),
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Claude,
    parent: Some("main"),
    workspace: "/w",
    branch: "b",
    terminal_target: (None : @types.LocalTarget?),
    host: @types.Host::Local,
    spawn_depth: 0,
    state: @types.AgentState::Active,
  }
  let ps = @poller.PollerState::new()
  ps.track_recovered(
    1,
    "main.first",
    "b",
    "main",
    "u",
    0L,
    @poller.ReviewState::ChangesRequested,
    "",
    "",
    false,
  )
  ps.track_recovered(
    2,
    "main.second",
    "b",
    "main",
    "u",
    0L,
    @poller.ReviewState::ChangesRequested,
    "",
    "",
    false,
  )
  match cancel_wave_preflight_block_message(false, [a1, a2], Some(ps)) {
    Some(msg) => assert_true(msg.contains("main.first") && msg.contains("#1"))
    None => fail("expected block")
  }
}

///|
test "cancel_wave_ok_response shape" {
  match cancel_wave_ok_response(3) {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      assert_eq(map.get("status"), Some(String::to_json("ok")))
      assert_eq(map.get("cancelled"), Some(Int::to_json(3)))
    }
    _ => fail("expected ok")
  }
}

///|
test "cancel_wave_per_agent_host_steps ordering" {
  let steps = cancel_wave_per_agent_host_steps()
  assert_eq(steps.length(), 4)
  assert_eq(steps[0], CancelWavePerAgentHostStep::PaneClose)
  assert_eq(steps[1], CancelWavePerAgentHostStep::WorktreeRemove)
  assert_eq(steps[2], CancelWavePerAgentHostStep::RegistryFailed)
  assert_eq(steps[3], CancelWavePerAgentHostStep::PollerUntrack)
}

///|
async test "interpret_cancel_wave err when no registry" {
  let got = interpret_cancel_wave(
    { force: false },
    Some("main"),
    "/tmp",
    None,
    None,
    mock_runner_all_ok,
  )
  match got {
    @types.Response::Err(msg) => assert_eq(msg, "no agent registry available")
    _ => fail("expected no-registry err")
  }
}

///|
test "spawn_worker_ok_response matches spawned envelope" {
  match spawn_worker_ok_response("main.w1") {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      assert_eq(map.get("status"), Some(String::to_json("spawned")))
      assert_eq(map.get("agent_id"), Some(String::to_json("main.w1")))
      assert_eq(map.get("agent_ids"), Some(String::to_json("main.w1")))
    }
    _ => fail("expected ok")
  }
}

///|
test "spawn_worker_plan builds inline worker spec registry row and response" {
  let worker_args : WorkerSpawnArgs = {
    task: "t",
    caller_id: "main.tl",
    slug: "w1",
    agent_type: @types.AgentType::MoonPilot,
  }
  let plan = spawn_worker_plan(worker_args, "develop", "sess", "/proj")
  assert_eq(plan.agent_id, "develop.w1")
  assert_eq(plan.spec.parent_branch, "develop")
  assert_eq(plan.spec.slug, "w1")
  assert_eq(plan.spec.role, @types.Role::Worker)
  assert_eq(plan.spec.isolation, @types.IsolationMode::Inline)
  assert_eq(plan.spec.parent_id, "main.tl")
  assert_eq(plan.spec.spawn_depth, 0)
  let expected_tt = @workspace.local_target_for(
    "sess",
    "w1",
    @types.IsolationMode::Inline,
  )
  assert_eq(plan.terminal_target, expected_tt)
  assert_eq(plan.registry_agent.role, @types.Role::Worker)
  assert_eq(plan.registry_agent.agent_type, @types.AgentType::MoonPilot)
  assert_eq(plan.registry_agent.workspace, "/proj")
  assert_eq(plan.registry_agent.branch, "develop.w1")
  assert_eq(plan.registry_agent.state, @types.AgentState::Active)
  match plan.registry_agent.parent {
    Some(p) => assert_eq(p, "main.tl")
    None => fail("expected parent")
  }
  match plan.ok_response {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      assert_eq(map.get("agent_id"), Some(String::to_json("develop.w1")))
    }
    _ => fail("expected ok")
  }
}

///|
async fn mock_capture_origin_main(_cmd : @workspace.Command) -> (Int, String) {
  @async.sleep(0)
  (0, "origin/main\n")
}

///|
async test "interpret_spawn_worker registers agent on success" {
  let worker_args : WorkerSpawnArgs = {
    task: "unit",
    caller_id: "main.tl",
    slug: "w1",
    agent_type: @types.AgentType::Claude,
  }
  let reg = @registry.AgentRegistry::new()
  let got = interpret_spawn_worker(
    worker_args,
    "/tmp/p",
    "choir",
    mock_runner_all_ok,
    mock_capture_origin_main,
    Some(reg),
  )
  match got {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      assert_eq(map.get("status"), Some(String::to_json("spawned")))
    }
    _ => fail("expected ok")
  }
  match reg.get("main.w1") {
    Ok(a) => {
      assert_eq(a.role, @types.Role::Worker)
      assert_eq(a.workspace, "/tmp/p")
    }
    Err(_) => fail("expected worker in registry")
  }
}

///|
test "spawn_remote_plan builds dev claude worktree spec and spawned response" {
  let spawn_args : RemoteSpawnArgs = {
    task: "remote-task",
    caller_id: "main.tl",
    slug: "leaf-a",
    parent_branch: "main",
    ssh_target: "user@remote.example",
    repo_url: "https://github.com/o/r.git",
    tcp_addr: "192.168.1.10:7777",
    parent_session_id: Some("sess-1"),
  }
  let plan = spawn_remote_plan(spawn_args)
  assert_eq(plan.spec.slug, "leaf-a")
  assert_eq(plan.spec.role, @types.Role::Dev)
  assert_eq(plan.spec.agent_type, @types.AgentType::Claude)
  assert_eq(plan.spec.task, "remote-task")
  assert_eq(plan.spec.isolation, @types.IsolationMode::Worktree)
  assert_eq(plan.spec.parent_id, "main.tl")
  assert_eq(plan.spec.parent_branch, "main")
  assert_eq(plan.spec.reuse_workspace, false)
  assert_eq(plan.spec.workspace_slug, None)
  assert_eq(plan.spec.reuse_git_branch, None)
  assert_eq(plan.spec.spawn_depth, 0)
  match plan.ok_response {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      assert_eq(map.get("status"), Some(String::to_json("spawned")))
      assert_eq(map.get("agent_id"), Some(String::to_json("main.leaf-a")))
      assert_eq(map.get("slug"), Some(String::to_json("leaf-a")))
      assert_eq(map.get("host"), Some(String::to_json("user@remote.example")))
    }
    _ => fail("expected ok response")
  }
}

///|
async test "interpret_spawn_remote returns plan ok when runner succeeds" {
  let spawn_args : RemoteSpawnArgs = {
    task: "t",
    caller_id: "pb.caller",
    slug: "s1",
    parent_branch: "pb",
    ssh_target: "h",
    repo_url: "u",
    tcp_addr: "a",
    parent_session_id: None,
  }
  let got = interpret_spawn_remote(
    spawn_args, mock_runner_all_ok, mock_capture_empty,
  )
  match got {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      assert_eq(map.get("status"), Some(String::to_json("spawned")))
      assert_eq(map.get("agent_id"), Some(String::to_json("pb.s1")))
      assert_eq(map.get("slug"), Some(String::to_json("s1")))
      assert_eq(map.get("host"), Some(String::to_json("h")))
    }
    _ => fail("expected ok")
  }
}

///|
async test "interpret_spawn_remote returns err when run_strict fails" {
  let spawn_args : RemoteSpawnArgs = {
    task: "t",
    caller_id: "x",
    slug: "y",
    parent_branch: "main",
    ssh_target: "h",
    repo_url: "u",
    tcp_addr: "a",
    parent_session_id: None,
  }
  let got = interpret_spawn_remote(
    spawn_args, mock_runner_first_fails, mock_capture_empty,
  )
  match got {
    @types.Response::Err(msg) =>
      assert_true(msg.contains("failed") || msg.contains("status"))
    _ => fail("expected err from run_strict")
  }
}

///|
test "spawn_gemini_plan builds dev gemini worktree spec and spawned response" {
  let spawn_args : SpawnGeminiArgs = {
    task: "do the thing",
    caller_id: "main.tl",
    slug: "g1",
    parent_branch: "main",
    parent_session_id: Some("sess-1"),
  }
  let plan = spawn_gemini_plan(spawn_args)
  assert_eq(plan.spec.slug, "g1")
  assert_eq(plan.spec.role, @types.Role::Dev)
  assert_eq(plan.spec.agent_type, @types.AgentType::Gemini)
  assert_eq(plan.spec.task, "do the thing")
  assert_eq(plan.spec.isolation, @types.IsolationMode::Worktree)
  assert_eq(plan.spec.parent_id, "main.tl")
  assert_eq(plan.spec.parent_branch, "main")
  assert_eq(plan.spec.reuse_workspace, false)
  assert_eq(plan.spec.workspace_slug, None)
  assert_eq(plan.spec.reuse_git_branch, None)
  assert_eq(plan.spec.spawn_depth, 0)
  match plan.ok_response {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      assert_eq(map.get("status"), Some(String::to_json("spawned")))
      assert_eq(map.get("agent_id"), Some(String::to_json("main.g1")))
      assert_eq(map.get("slug"), Some(String::to_json("g1")))
    }
    _ => fail("expected ok response")
  }
}

///|
async test "interpret_spawn_gemini returns plan ok when runner succeeds" {
  let spawn_args : SpawnGeminiArgs = {
    task: "t",
    caller_id: "pb.caller",
    slug: "gem",
    parent_branch: "pb",
    parent_session_id: None,
  }
  let got = interpret_spawn_gemini(
    spawn_args, "/tmp/p", "choir", mock_runner_all_ok, mock_capture_empty,
  )
  match got {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      assert_eq(map.get("status"), Some(String::to_json("spawned")))
      assert_eq(map.get("agent_id"), Some(String::to_json("pb.gem")))
      assert_eq(map.get("slug"), Some(String::to_json("gem")))
    }
    _ => fail("expected ok")
  }
}

///|
async test "interpret_spawn_gemini returns err when run_strict fails" {
  let spawn_args : SpawnGeminiArgs = {
    task: "t",
    caller_id: "x",
    slug: "y",
    parent_branch: "main",
    parent_session_id: None,
  }
  let got = interpret_spawn_gemini(
    spawn_args, "/tmp/p", "choir", mock_runner_first_fails, mock_capture_empty,
  )
  match got {
    @types.Response::Err(msg) =>
      assert_true(msg.contains("failed") || msg.contains("status"))
    _ => fail("expected err from run_strict")
  }
}

///|
fn rescue_leaf_base_args() -> RescueLeafArgs {
  {
    task: "continue",
    caller_id: "main.tl",
    from_agent_id: "main.old-leaf",
    new_slug: "new-leaf",
    agent_type: @types.AgentType::MoonPilot,
    parent_session_id: None,
  }
}

///|
fn rescue_leaf_ok_dev(
  from_agent_id : String,
  workspace : String,
  branch : String,
) -> @types.Agent {
  {
    agent_id: @types.AgentId(from_agent_id),
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Claude,
    parent: Some("main.tl"),
    workspace,
    branch,
    terminal_target: None,
    host: @types.Host::Local,
    spawn_depth: 0,
    state: @types.AgentState::Active,
  }
}

///|
test "rescue_leaf_spawn_plan builds reuse spec and ids" {
  let args = rescue_leaf_base_args()
  let from_agent = rescue_leaf_ok_dev(
    "main.old-leaf", "/proj/.choir/worktrees/old-leaf-0", "main.old-leaf",
  )
  let got = rescue_leaf_spawn_plan(args, from_agent)
  match got {
    Ok(plan) => {
      assert_eq(plan.from_agent_id, "main.old-leaf")
      assert_eq(plan.to_id, "main.new-leaf")
      assert_eq(plan.salvage_slug, "old-leaf")
      assert_eq(plan.git_branch, "main.old-leaf")
      assert_eq(plan.spec.slug, "new-leaf")
      assert_eq(plan.spec.parent_branch, "main")
      assert_eq(plan.spec.parent_id, "main.tl")
      assert_eq(plan.spec.reuse_workspace, true)
      assert_eq(plan.spec.workspace_slug, Some("old-leaf"))
      assert_eq(plan.spec.reuse_git_branch, Some("main.old-leaf"))
      assert_eq(plan.spec.agent_type, @types.AgentType::MoonPilot)
      assert_eq(plan.spec.spawn_depth, 0)
    }
    Err(e) => fail("expected Ok got " + e)
  }
}

///|
test "rescue_leaf_spawn_plan uses from_agent_id when branch empty" {
  let args = rescue_leaf_base_args()
  let from_agent = rescue_leaf_ok_dev(
    "main.old-leaf", "/proj/.choir/worktrees/old-leaf-0", "",
  )
  match rescue_leaf_spawn_plan(args, from_agent) {
    Ok(plan) => assert_eq(plan.git_branch, "main.old-leaf")
    Err(e) => fail(e)
  }
}

///|
test "rescue_leaf_spawn_plan err non-dev role" {
  let args = rescue_leaf_base_args()
  let dev = rescue_leaf_ok_dev("main.old-leaf", "/proj/.choir/worktrees/x", "b")
  let non_dev = { ..dev, role: @types.Role::TL }
  match rescue_leaf_spawn_plan(args, non_dev) {
    Err(msg) => assert_eq(msg, "rescue_leaf only supports dev leaves")
    Ok(_) => fail("expected Err")
  }
}

///|
test "rescue_leaf_spawn_plan err parent mismatch" {
  let args = rescue_leaf_base_args()
  let from_agent = rescue_leaf_ok_dev(
    "main.old-leaf", "/proj/.choir/worktrees/x", "b",
  )
  match rescue_leaf_spawn_plan(args, { ..from_agent, parent: Some("other") }) {
    Err(msg) => assert_eq(msg, "caller_id must match the salvaged leaf parent")
    Ok(_) => fail("expected Err")
  }
}

///|
test "rescue_leaf_spawn_plan err no parent" {
  let args = rescue_leaf_base_args()
  let from_agent = rescue_leaf_ok_dev(
    "main.old-leaf", "/proj/.choir/worktrees/x", "b",
  )
  match rescue_leaf_spawn_plan(args, { ..from_agent, parent: None }) {
    Err(msg) => assert_eq(msg, "salvaged leaf has no parent in registry")
    Ok(_) => fail("expected Err")
  }
}

///|
test "rescue_leaf_spawn_plan err no choir worktree path" {
  let args = rescue_leaf_base_args()
  let from_agent = rescue_leaf_ok_dev("main.old-leaf", "/proj/other", "b")
  match rescue_leaf_spawn_plan(args, from_agent) {
    Err(msg) =>
      assert_eq(msg, "salvaged leaf has no choir worktree path to reuse")
    Ok(_) => fail("expected Err")
  }
}

///|
test "rescue_leaf_spawn_plan err invalid from_agent_id" {
  let args = { ..rescue_leaf_base_args(), from_agent_id: "mainleaf" }
  let from_agent = rescue_leaf_ok_dev(
    "mainleaf", "/proj/.choir/worktrees/x", "b",
  )
  match rescue_leaf_spawn_plan(args, from_agent) {
    Err(msg) =>
      assert_eq(
        msg, "invalid from_agent_id (expected nested branch like parent.child)",
      )
    Ok(_) => fail("expected Err")
  }
}

///|
test "rescue_leaf_remove_supervisor_alias matches slug inequality" {
  assert_true(rescue_leaf_remove_supervisor_alias("a", "main.a"))
  assert_false(rescue_leaf_remove_supervisor_alias("main.leaf", "main.leaf"))
}

///|
test "rescue_leaf_ok_response matches spawned envelope" {
  match rescue_leaf_ok_response("main.new", "main.old", "new") {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      assert_eq(map.get("status"), Some(String::to_json("spawned")))
      assert_eq(map.get("agent_id"), Some(String::to_json("main.new")))
      assert_eq(map.get("from_agent_id"), Some(String::to_json("main.old")))
      assert_eq(map.get("slug"), Some(String::to_json("new")))
    }
    _ => fail("expected ok")
  }
}

///|
test "rescue_leaf_handoff_failure_message matches dispatch wording" {
  assert_eq(
    rescue_leaf_handoff_failure_message("e"),
    "rescue_leaf: replacement spawned but lifecycle handoff failed — manual repair may be needed: e",
  )
}

///|
test "rescue_leaf_superseded_persist_failure_message matches dispatch wording" {
  assert_eq(
    rescue_leaf_superseded_persist_failure_message("main.old"),
    "failed to persist superseded lifecycle for main.old",
  )
}

///|
test "rescue_leaf_post_spawn_host_steps ordering" {
  let steps = rescue_leaf_post_spawn_host_steps()
  assert_eq(steps.length(), 9)
  assert_eq(steps[0], RescueLeafPostSpawnHostStep::LifecycleHandoff)
  assert_eq(
    steps[1],
    RescueLeafPostSpawnHostStep::PollerTransferOwnerAndWriteState,
  )
  assert_eq(steps[2], RescueLeafPostSpawnHostStep::MarkSuperseded)
  assert_eq(steps[3], RescueLeafPostSpawnHostStep::RegistryRemoveOld)
  assert_eq(
    steps[4],
    RescueLeafPostSpawnHostStep::SupervisorRemoveChildFromAgent,
  )
  assert_eq(
    steps[5],
    RescueLeafPostSpawnHostStep::SupervisorRemoveChildAliasIfNeeded,
  )
  assert_eq(steps[6], RescueLeafPostSpawnHostStep::TeamRegisterMember)
  assert_eq(steps[7], RescueLeafPostSpawnHostStep::TlEventChildSpawned)
  assert_eq(steps[8], RescueLeafPostSpawnHostStep::PaneResolveAndUpsertTerminal)
}

///|
async test "interpret_rescue_leaf err when no registry" {
  let args = rescue_leaf_base_args()
  let got = interpret_rescue_leaf(
    args,
    "/tmp",
    "choir",
    mock_runner_all_ok,
    mock_capture_empty,
    None,
    None,
  )
  match got {
    @types.Response::Err(msg) =>
      assert_eq(msg, "agent registry unavailable for rescue_leaf")
    _ => fail("expected no-registry err")
  }
}

///|
async test "interpret_rescue_leaf err when no poller" {
  let reg = @registry.AgentRegistry::new()
  let args = rescue_leaf_base_args()
  let got = interpret_rescue_leaf(
    args,
    "/tmp",
    "choir",
    mock_runner_all_ok,
    mock_capture_empty,
    Some(reg),
    None,
  )
  match got {
    @types.Response::Err(msg) =>
      assert_eq(msg, "poller unavailable for rescue_leaf")
    _ => fail("expected no-poller err")
  }
}

///|
async test "interpret_rescue_leaf err when from_agent missing" {
  let reg = @registry.AgentRegistry::new()
  let ps = @poller.PollerState::new()
  let args = rescue_leaf_base_args()
  let got = interpret_rescue_leaf(
    args,
    "/tmp",
    "choir",
    mock_runner_all_ok,
    mock_capture_empty,
    Some(reg),
    Some(ps),
  )
  match got {
    @types.Response::Err(msg) =>
      assert_eq(msg, "agent not found: main.old-leaf")
    _ => fail("expected not-found err")
  }
}

///|
async test "interpret_rescue_leaf err when spawn plan rejects role" {
  let reg = @registry.AgentRegistry::new()
  let ps = @poller.PollerState::new()
  let tl = {
    ..rescue_leaf_ok_dev("main.old-leaf", "/proj/.choir/worktrees/x", "b"),
    role: @types.Role::TL,
  }
  ignore(reg.upsert(tl))
  let args = rescue_leaf_base_args()
  let got = interpret_rescue_leaf(
    args,
    "/tmp",
    "choir",
    mock_runner_all_ok,
    mock_capture_empty,
    Some(reg),
    Some(ps),
  )
  match got {
    @types.Response::Err(msg) =>
      assert_eq(msg, "rescue_leaf only supports dev leaves")
    _ => fail("expected spawn-plan err")
  }
}

///|
async test "interpret_rescue_leaf err when run_strict fails" {
  let reg = @registry.AgentRegistry::new()
  let ps = @poller.PollerState::new()
  let from_agent = rescue_leaf_ok_dev(
    "main.old-leaf", "/proj/.choir/worktrees/old-leaf-0", "main.old-leaf",
  )
  ignore(reg.upsert(from_agent))
  let args = rescue_leaf_base_args()
  let got = interpret_rescue_leaf(
    args,
    "/tmp",
    "choir",
    mock_runner_first_fails,
    mock_capture_empty,
    Some(reg),
    Some(ps),
  )
  match got {
    @types.Response::Err(msg) =>
      assert_true(msg.contains("failed") || msg.contains("status"))
    _ => fail("expected run_strict err")
  }
}
