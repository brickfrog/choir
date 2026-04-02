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
