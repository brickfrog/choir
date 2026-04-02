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
