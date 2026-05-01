///|
test "file_pr_plan builds tracked result when tracking enabled" {
  let args : FilePrArgs = {
    branch: "main.task-leaf",
    parent_branch: Some("main"),
    tracked_agent_id: "main.task-leaf",
    title: None,
    body: None,
    review_context: None,
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
      @debug.assert_eq(map.get("status"), Some(String::to_json("pr_created")))
      @debug.assert_eq(map.get("tracked"), Some(Bool::to_json(true)))
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
    review_context: None,
  }
  let pr : PullRequestInfo = {
    number: 9,
    url: "https://example.test/pr/9",
    state: "OPEN",
  }
  let plan = file_pr_plan(args, "main", pr, false)
  @debug.assert_eq(plan.tracked_pr, None)
  match plan.response {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      @debug.assert_eq(map.get("tracked"), Some(Bool::to_json(false)))
      @debug.assert_eq(map.get("pr_number"), Some(Int::to_json(9)))
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
    review_context: None,
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
  @debug.assert_eq(no_poller.poller_track, None)
  let plan_no_reg = file_pr_plan(args, "main", pr, true)
  let no_registry = file_pr_post_success_effects(plan_no_reg, true, false)
  @debug.assert_eq(no_registry.notify_message_for_parent, None)
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
      let expected = @message.plan_delivery(
        parent,
        "main.leaf",
        msg,
        @types.Status::Success,
      )
      assert_eq(delivery, expected)
      assert_eq(
        delivery_log_append,
        "[auto-notify] caller=main.leaf parent=main.tl delivery=" +
        delivery.to_display_string() +
        "\n",
      )
    }
    _ => fail("expected Deliver")
  }
}

///|
test "file_pr_auto_notify_plan logs only when parent resolution fails" {
  let err = @types.ChoirError::agent_not_found("main.tl")
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
fn file_pr_post_success_test_dir() -> String {
  "/tmp/choir-fpr-post-" + @sys.get_pid().to_string()
}

///|
async test "interpret_file_pr_post_success returns plan ok without poller or registry notify" {
  let project_dir = file_pr_post_success_test_dir()
  assert_true(@sys.create_dir_all(project_dir + "/.choir"))
  let args : FilePrArgs = {
    branch: "main.leaf",
    parent_branch: Some("main"),
    tracked_agent_id: "main.leaf",
    title: None,
    body: None,
    review_context: None,
  }
  let pr : PullRequestInfo = {
    number: 21,
    url: "https://example.test/pr/21",
    state: "OPEN",
  }
  let plan = file_pr_plan(args, "main", pr, true)
  let effects = file_pr_post_success_effects(plan, false, false)
  let got = interpret_file_pr_post_success(
    project_dir,
    "choir",
    args.branch,
    args.tracked_agent_id,
    project_dir,
    pr.number,
    false,
    effects,
    None,
    None,
    mock_runner_all_ok,
  )
  match got {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      @debug.assert_eq(map.get("status"), Some(String::to_json("pr_created")))
      @debug.assert_eq(map.get("pr_number"), Some(Int::to_json(21)))
    }
    _ => fail("expected ok")
  }
}

///|
async test "interpret_file_pr_post_success registers poller when tracked" {
  let project_dir = file_pr_post_success_test_dir()
  assert_true(@sys.create_dir_all(project_dir + "/.choir"))
  let args : FilePrArgs = {
    branch: "main.topic",
    parent_branch: Some("main"),
    tracked_agent_id: "main.leaf",
    title: None,
    body: None,
    review_context: None,
  }
  let pr : PullRequestInfo = {
    number: 55,
    url: "https://example.test/pr/55",
    state: "OPEN",
  }
  let plan = file_pr_plan(args, "main", pr, true)
  let effects = file_pr_post_success_effects(plan, true, false)
  let ps = @poller.PollerState::new()
  let got = interpret_file_pr_post_success(
    project_dir,
    "choir",
    args.branch,
    args.tracked_agent_id,
    project_dir,
    pr.number,
    false,
    effects,
    Some(ps),
    None,
    mock_runner_all_ok,
  )
  match got {
    @types.Response::Ok(_) => ()
    _ => fail("expected ok")
  }
  match ps.get(55) {
    Some(t) => {
      assert_eq(t.agent_id, "main.leaf")
      assert_eq(t.branch, "main.topic")
      assert_eq(t.pr_url, "https://example.test/pr/55")
    }
    None => fail("expected tracked PR")
  }
}

///|
async test "interpret_file_pr_post_success auto-notify tcp appends delivery log" {
  let project_dir = file_pr_post_success_test_dir()
  assert_true(@sys.create_dir_all(project_dir + "/.choir"))
  let log_path = project_dir + "/.choir/delivery.log"
  ignore(@sys.delete_file_sync(log_path))
  let parent : @types.Agent = {
    agent_id: @types.AgentId("main.tl"),
    role: @types.Role::TL,
    agent_type: @types.AgentType::Claude,
    parent: None,
    workspace: "/tmp",
    branch: "main",
    terminal_target: None,
    host: @types.Host::Remote("127.0.0.1"),
    spawn_depth: 0,
    state: @types.AgentState::Active,
  }
  let leaf : @types.Agent = {
    agent_id: @types.AgentId("main.leaf"),
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Claude,
    parent: Some("main.tl"),
    workspace: "/tmp",
    branch: "main.leaf",
    terminal_target: None,
    host: @types.Host::Local,
    spawn_depth: 0,
    state: @types.AgentState::Active,
  }
  let reg = @registry.AgentRegistry::new()
  ignore(reg.upsert(parent))
  ignore(reg.upsert(leaf))
  let args : FilePrArgs = {
    branch: "main.leaf",
    parent_branch: Some("main"),
    tracked_agent_id: "main.leaf",
    title: None,
    body: None,
    review_context: None,
  }
  let pr : PullRequestInfo = {
    number: 88,
    url: "https://example.test/pr/88",
    state: "OPEN",
  }
  let plan = file_pr_plan(args, "main", pr, false)
  let effects = file_pr_post_success_effects(plan, false, true)
  let got = interpret_file_pr_post_success(
    project_dir,
    "choir",
    args.branch,
    args.tracked_agent_id,
    project_dir,
    pr.number,
    false,
    effects,
    None,
    Some(reg),
    mock_runner_all_ok,
  )
  match got {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      @debug.assert_eq(map.get("pr_number"), Some(Int::to_json(88)))
    }
    _ => fail("expected ok")
  }
  let msg = "[PR READY] PR #88 filed: https://example.test/pr/88"
  let expected_delivery = @message.plan_delivery(
    parent,
    "main.leaf",
    msg,
    @types.Status::Success,
  )
  let expected_log = "[auto-notify] caller=main.leaf parent=main.tl delivery=" +
    expected_delivery.to_display_string() +
    "\n"
  assert_eq(@sys.read_file(log_path), expected_log)
}

///|
async test "interpret_file_pr_post_success parent missing appends resolve failure log" {
  let project_dir = file_pr_post_success_test_dir()
  assert_true(@sys.create_dir_all(project_dir + "/.choir"))
  let log_path = project_dir + "/.choir/delivery.log"
  ignore(@sys.delete_file_sync(log_path))
  let leaf : @types.Agent = {
    agent_id: @types.AgentId("main.leaf"),
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Claude,
    parent: Some("main.tl"),
    workspace: "/tmp",
    branch: "main.leaf",
    terminal_target: None,
    host: @types.Host::Local,
    spawn_depth: 0,
    state: @types.AgentState::Active,
  }
  let reg = @registry.AgentRegistry::new()
  ignore(reg.upsert(leaf))
  let args : FilePrArgs = {
    branch: "main.leaf",
    parent_branch: Some("main"),
    tracked_agent_id: "main.leaf",
    title: None,
    body: None,
    review_context: None,
  }
  let pr : PullRequestInfo = {
    number: 3,
    url: "https://example.test/pr/3",
    state: "OPEN",
  }
  let plan = file_pr_plan(args, "main", pr, false)
  let effects = file_pr_post_success_effects(plan, false, true)
  let got = interpret_file_pr_post_success(
    project_dir,
    "choir",
    args.branch,
    args.tracked_agent_id,
    project_dir,
    pr.number,
    false,
    effects,
    None,
    Some(reg),
    mock_runner_all_ok,
  )
  match got {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      @debug.assert_eq(map.get("pr_number"), Some(Int::to_json(3)))
    }
    _ => fail("expected ok")
  }
  let log = @sys.read_file(log_path)
  assert_true(
    log.contains("[auto-notify] resolve_parent_for_notify failed error="),
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
    review_context: None,
  }
  let ins = file_pr_preflight_create_inputs(args, "main", "/tmp/wt")
  assert_eq(ins.branch, "main.leaf")
  assert_eq(ins.parent_branch, "main")
  assert_eq(ins.file_pr_dir, "/tmp/wt")
  @debug.assert_eq(ins.title, Some("title"))
  @debug.assert_eq(ins.body, Some("body"))
}

///|
async fn mock_preflight_ok(
  _branch : String,
  _parent_branch : String,
  _dir : String,
) -> Result[Unit, @types.ChoirError] {
  @async.sleep(0)
  Ok(())
}

///|
async fn mock_preflight_err(
  _branch : String,
  _parent_branch : String,
  _dir : String,
) -> Result[Unit, @types.ChoirError] {
  @async.sleep(0)
  Err(@types.ChoirError::git_error("branch missing locally"))
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
) -> Result[PullRequestInfo, @types.ChoirError] {
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
) -> Result[PullRequestInfo, @types.ChoirError] {
  @async.sleep(0)
  Err(@types.ChoirError::git_error("gh pr create failed for branch: main.leaf"))
}

///|
fn file_pr_test_local_target() -> @types.LocalTarget {
  { kind: ZellijTab, session: "choir", name: "leaf" }
}

///|
fn file_pr_test_write_verify_config(
  file_pr_dir : String,
  verify : Array[String],
) -> Unit {
  ignore(@sys.create_dir_all(file_pr_dir + "/.choir"))
  let spec : @types.SpawnSpec = {
    slug: "leaf",
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Codex,
    task: "verify before PR",
    task_contract: Some({
      ..@types.TaskContract::empty(),
      goal: "verify before PR",
      verify,
    }),
    isolation: @types.IsolationMode::Worktree,
    parent_id: "main.tl",
    parent_branch: "main",
    reuse_workspace: false,
    workspace_slug: None,
    reuse_git_branch: None,
    spawn_depth: 0,
    automerge: None,
    review_mode: None,
    wave_id: None,
  }
  ignore(
    @sys.write_file_sync(
      file_pr_dir + "/.choir/config.local.toml",
      @workspace.config_local_content(
        spec,
        file_pr_dir,
        file_pr_test_local_target(),
      ),
    ),
  )
}

///|
fn file_pr_test_registry(file_pr_dir : String) -> @registry.AgentRegistry {
  let reg = @registry.AgentRegistry::new()
  ignore(
    reg.upsert({
      agent_id: @types.AgentId("main.tl"),
      role: @types.Role::TL,
      agent_type: @types.AgentType::Claude,
      parent: None,
      workspace: "/proj",
      branch: "main",
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  ignore(
    reg.upsert({
      agent_id: @types.AgentId("main.leaf"),
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Codex,
      parent: Some("main.tl"),
      workspace: file_pr_dir,
      branch: "main.leaf",
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  reg
}

///|
fn file_pr_test_record_verify_event(
  project_dir : String,
) -> (String, @evidence.EvidenceEvent) -> Unit {
  fn(agent_id : String, event : @evidence.EvidenceEvent) -> Unit {
    ignore(
      @evidence.append_agent_evidence_event(
        @sys.append_file_sync, project_dir, agent_id, 1L, event,
      ),
    )
  }
}

///|
fn file_pr_test_record_verify_outcome(
  project_dir : String,
  agent_id : String,
  _file_pr_dir : String,
) -> (FilePrVerifyOutcome) -> Unit {
  let record_event = file_pr_test_record_verify_event(project_dir)
  fn(outcome : FilePrVerifyOutcome) -> Unit {
    let head_line = match outcome.head_sha {
      Some(sha) => "\nhead: " + sha
      None => ""
    }
    record_event(
      agent_id,
      @evidence.EvidenceEvent::VerifyResultObserved(
        name=outcome.command,
        ok=outcome.exit_code == 0,
        details=Some(
          "exit: " +
          outcome.exit_code.to_string() +
          head_line +
          "\n" +
          outcome.output_tail,
        ),
      ),
    )
  }
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
    Err(e) => assert_true(e.message().contains("missing locally"))
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
    Err(e) => {
      let msg = e.message()
      // `run_strict` uses either `git failed (exit …)` with stderr detail or
      // `command failed with status …` when capture returned empty output.
      assert_true(msg.contains("3") && msg.contains("failed"))
    }
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
    Err(e) =>
      assert_eq(
        e.message(),
        @types.ChoirError::git_error(
          "gh pr create failed for branch: main.leaf",
        ).message(),
      )
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
async test "file_pr_run_required_verify appends trusted evidence" {
  let project_dir = "/tmp/choir-fpr-verify-evidence-" +
    @sys.get_pid().to_string()
  ignore(@sys.rm_rf(project_dir))
  assert_true(@sys.create_dir_all(project_dir))
  let mut seen_workdir = ""
  let got = file_pr_run_required_verify(
    "/tmp/leaf-wt",
    ["moon test --target native"],
    fn(cmd : @workspace.Command) -> (Int, String) {
      seen_workdir = cmd.workdir.unwrap_or("")
      if cmd.program == "git" {
        (0, "sha-verify\n")
      } else {
        (0, "Total tests: 1, passed: 1\n")
      }
    },
    record_verify_outcome=file_pr_test_record_verify_outcome(
      project_dir, "main.leaf", "/tmp/leaf-wt",
    ),
  )
  assert_eq(seen_workdir, "/tmp/leaf-wt")
  match got {
    Ok(outcomes) => {
      assert_eq(outcomes.length(), 1)
      assert_eq(outcomes[0].command, "moon test --target native")
      assert_eq(outcomes[0].exit_code, 0)
      assert_true(outcomes[0].output_tail.contains("passed: 1"))
    }
    Err(e) => fail("expected verify success: " + e.message())
  }
  let records = @evidence.load_agent_evidence_records(project_dir, "main.leaf")
  assert_eq(records.length(), 1)
  match records[0].event {
    @evidence.EvidenceEvent::VerifyResultObserved(name~, ok~, details~) => {
      assert_eq(name, "moon test --target native")
      assert_true(ok)
      assert_true(details.unwrap_or("").contains("Total tests: 1"))
    }
    _ => fail("expected VerifyResultObserved")
  }
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "file_pr_run_required_verify stops on failed command" {
  let project_dir = "/tmp/choir-fpr-verify-fail-" + @sys.get_pid().to_string()
  ignore(@sys.rm_rf(project_dir))
  assert_true(@sys.create_dir_all(project_dir))
  let got = file_pr_run_required_verify(
    "/tmp/leaf-wt",
    ["npm run typecheck"],
    fn(cmd : @workspace.Command) -> (Int, String) {
      if cmd.program == "git" {
        (0, "sha-fail\n")
      } else {
        (2, "src/index.ts(10,3): error TS2322\n")
      }
    },
    record_verify_outcome=file_pr_test_record_verify_outcome(
      project_dir, "main.leaf", "/tmp/leaf-wt",
    ),
  )
  match got {
    Err(e) => {
      let msg = e.message()
      assert_true(msg.contains("npm run typecheck"))
      assert_true(msg.contains("TS2322"))
    }
    Ok(_) => fail("expected verify failure")
  }
  let records = @evidence.load_agent_evidence_records(project_dir, "main.leaf")
  assert_eq(records.length(), 1)
  match records[0].event {
    @evidence.EvidenceEvent::VerifyResultObserved(name~, ok~, details~) => {
      assert_eq(name, "npm run typecheck")
      assert_false(ok)
      assert_true(details.unwrap_or("").contains("exit: 2"))
    }
    _ => fail("expected VerifyResultObserved")
  }
  ignore(@sys.rm_rf(project_dir))
}

///|
test "file_pr_body_with_verify_summary appends compact generated section" {
  let body = file_pr_body_with_verify_summary(Some("Changes schema wiring."), [
    {
      command: "npm run typecheck",
      exit_code: 0,
      output_tail: "typecheck ok",
      head_sha: Some("sha-pr"),
    },
  ]).unwrap()
  assert_true(body.contains("Changes schema wiring."))
  assert_true(body.contains("## Verification"))
  assert_true(body.contains("Generated by Choir"))
  assert_true(body.contains("`npm run typecheck`"))
  assert_true(body.contains("head: sha-pr"))
  assert_true(body.contains("typecheck ok"))
}

///|
async test "interpret_file_pr returns preflight error without post-success" {
  let args : FilePrArgs = {
    branch: "main.leaf",
    parent_branch: Some("main"),
    tracked_agent_id: "main.leaf",
    title: None,
    body: None,
    review_context: None,
  }
  let got = interpret_file_pr(
    args,
    "/proj",
    "choir",
    None,
    None,
    false,
    mock_preflight_err,
    mock_runner_all_ok,
    mock_capture_empty,
    mock_ensure_pr_ok,
  )
  match got {
    @types.Response::Err(msg) => assert_true(msg.contains("missing locally"))
    _ => fail("expected Err")
  }
}

///|
async test "interpret_file_pr skips required verify when branch preflight fails" {
  let project_dir = "/tmp/choir-fpr-preflight-before-verify-" +
    @sys.get_pid().to_string()
  let file_pr_dir = project_dir + "/.choir/worktrees/leaf"
  ignore(@sys.rm_rf(project_dir))
  file_pr_test_write_verify_config(file_pr_dir, ["npm run typecheck"])
  let reg = file_pr_test_registry(file_pr_dir)
  let mut verify_capture_called = false
  let got = interpret_file_pr(
    {
      branch: "main.leaf",
      parent_branch: Some("main"),
      tracked_agent_id: "main.leaf",
      title: None,
      body: None,
      review_context: None,
    },
    project_dir,
    "choir",
    None,
    Some(reg),
    false,
    mock_preflight_err,
    mock_runner_all_ok,
    fn(cmd : @workspace.Command) -> (Int, String) {
      if cmd.program == "sh" {
        verify_capture_called = true
      }
      (0, "")
    },
    mock_ensure_pr_ok,
  )
  match got {
    @types.Response::Err(msg) => assert_true(msg.contains("missing locally"))
    _ => fail("expected preflight Err")
  }
  assert_false(verify_capture_called)
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "interpret_file_pr runs required verify and injects generated PR body" {
  let project_dir = "/tmp/choir-fpr-verify-pr-body-" +
    @sys.get_pid().to_string()
  let file_pr_dir = project_dir + "/.choir/worktrees/leaf"
  ignore(@sys.rm_rf(project_dir))
  file_pr_test_write_verify_config(file_pr_dir, ["npm run typecheck"])
  let reg = file_pr_test_registry(file_pr_dir)
  let bodies : Array[String] = []
  let got = interpret_file_pr(
    {
      branch: "main.leaf",
      parent_branch: Some("main"),
      tracked_agent_id: "main.leaf",
      title: Some("schema wiring"),
      body: Some("Implements claim schema wiring."),
      review_context: None,
    },
    project_dir,
    "choir",
    None,
    Some(reg),
    false,
    mock_preflight_ok,
    mock_runner_all_ok,
    fn(cmd : @workspace.Command) -> (Int, String) {
      if cmd.program == "git" {
        (0, "sha-pr-body\n")
      } else if cmd.program == "sh" {
        (0, "typecheck ok\n")
      } else {
        (0, "")
      }
    },
    fn(
      _branch : String,
      _parent_branch : String,
      _dir : String,
      _title : String?,
      body : String?,
    ) -> Result[PullRequestInfo, @types.ChoirError] {
      bodies.push(body.unwrap_or(""))
      Ok({ number: 42, url: "https://example.test/pr/42", state: "OPEN" })
    },
    record_verify_event=file_pr_test_record_verify_event(project_dir),
  )
  match got {
    @types.Response::Ok(_) => ()
    @types.Response::Err(msg) => fail("expected file_pr success: " + msg)
  }
  assert_eq(bodies.length(), 1)
  assert_true(bodies[0].contains("Implements claim schema wiring."))
  assert_true(bodies[0].contains("## Verification"))
  assert_true(bodies[0].contains("`npm run typecheck`"))
  assert_true(bodies[0].contains("typecheck ok"))
  let records = @evidence.load_agent_evidence_records(project_dir, "main.leaf")
  assert_eq(records.length(), 1)
  match records[0].event {
    @evidence.EvidenceEvent::VerifyResultObserved(name~, ok~, details~) => {
      assert_eq(name, "npm run typecheck")
      assert_true(ok)
      let detail_text = details.unwrap_or("")
      assert_true(detail_text.contains("cwd: " + file_pr_dir))
      assert_true(detail_text.contains("head: sha-pr-body"))
      assert_true(detail_text.contains("typecheck ok"))
    }
    _ => fail("expected VerifyResultObserved")
  }
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "interpret_file_pr blocks before PR creation when required verify fails" {
  let project_dir = "/tmp/choir-fpr-verify-block-" + @sys.get_pid().to_string()
  let file_pr_dir = project_dir + "/.choir/worktrees/leaf"
  ignore(@sys.rm_rf(project_dir))
  file_pr_test_write_verify_config(file_pr_dir, ["npm run typecheck"])
  let reg = file_pr_test_registry(file_pr_dir)
  let mut ensure_pr_called = false
  let got = interpret_file_pr(
    {
      branch: "main.leaf",
      parent_branch: Some("main"),
      tracked_agent_id: "main.leaf",
      title: None,
      body: None,
      review_context: None,
    },
    project_dir,
    "choir",
    None,
    Some(reg),
    false,
    mock_preflight_ok,
    mock_runner_all_ok,
    fn(cmd : @workspace.Command) -> (Int, String) {
      if cmd.program == "git" {
        (0, "sha-pr-fail\n")
      } else if cmd.program == "sh" {
        (2, "src/index.ts(10,3): error TS2322\n")
      } else {
        (0, "")
      }
    },
    fn(
      _branch : String,
      _parent_branch : String,
      _dir : String,
      _title : String?,
      _body : String?,
    ) -> Result[PullRequestInfo, @types.ChoirError] {
      ensure_pr_called = true
      Ok({ number: 42, url: "https://example.test/pr/42", state: "OPEN" })
    },
    record_verify_event=file_pr_test_record_verify_event(project_dir),
  )
  match got {
    @types.Response::Err(msg) => {
      assert_true(msg.contains("npm run typecheck"))
      assert_true(msg.contains("TS2322"))
    }
    _ => fail("expected verify failure")
  }
  assert_false(ensure_pr_called)
  let records = @evidence.load_agent_evidence_records(project_dir, "main.leaf")
  assert_eq(records.length(), 1)
  match records[0].event {
    @evidence.EvidenceEvent::VerifyResultObserved(name~, ok~, details~) => {
      assert_eq(name, "npm run typecheck")
      assert_false(ok)
      let detail_text = details.unwrap_or("")
      assert_true(detail_text.contains("exit: 2"))
      assert_true(detail_text.contains("head: sha-pr-fail"))
    }
    _ => fail("expected VerifyResultObserved")
  }
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "interpret_file_pr ok response matches full pipeline" {
  let project_dir = "/tmp/choir-fpr-interpret-" + @sys.get_pid().to_string()
  assert_true(@sys.create_dir_all(project_dir + "/.choir"))
  let args : FilePrArgs = {
    branch: "main.leaf",
    parent_branch: Some("main"),
    tracked_agent_id: "main.leaf",
    title: None,
    body: None,
    review_context: None,
  }
  let got = interpret_file_pr(
    args,
    project_dir,
    "choir",
    None,
    None,
    false,
    mock_preflight_ok,
    mock_runner_all_ok,
    mock_capture_empty,
    mock_ensure_pr_ok,
  )
  match got {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      @debug.assert_eq(map.get("status"), Some(String::to_json("pr_created")))
      @debug.assert_eq(map.get("pr_number"), Some(Int::to_json(42)))
      @debug.assert_eq(
        map.get("pr_url"),
        Some(String::to_json("https://example.test/pr/42")),
      )
      @debug.assert_eq(map.get("tracked"), Some(Bool::to_json(false)))
    }
    _ => fail("expected ok")
  }
}

///|
test "file_pr_copilot_reviewer_gh_command requests @copilot reviewer" {
  let cmd = file_pr_copilot_reviewer_gh_command(44, "/wt/agent-checkout")
  assert_eq(cmd.program, "gh")
  @debug.assert_eq(cmd.workdir, Some("/wt/agent-checkout"))
  assert_eq(cmd.args.length(), 5)
  assert_eq(cmd.args[0], "pr")
  assert_eq(cmd.args[1], "edit")
  assert_eq(cmd.args[2], "44")
  assert_eq(cmd.args[3], "--add-reviewer")
  assert_eq(cmd.args[4], file_pr_copilot_reviewer_handle)
}

///|
test "file_pr_copilot_review_comment_body uses @copilot review prefix" {
  assert_eq(
    file_pr_copilot_review_comment_body("plan vs interpret"),
    "@copilot review: plan vs interpret",
  )
}

///|
test "file_pr_workdir returns the agent's worktree when registered" {
  let leaf : @types.Agent = {
    agent_id: @types.AgentId("main.leaf"),
    role: @types.Role::Dev,
    agent_type: @types.AgentType::CursorAgent,
    parent: Some("root"),
    workspace: "/proj/.choir/worktrees/main.leaf",
    branch: "main.leaf",
    terminal_target: None,
    host: @types.Host::Local,
    spawn_depth: 0,
    state: @types.AgentState::Active,
  }
  let reg = @registry.AgentRegistry::new()
  ignore(reg.upsert(leaf))
  match file_pr_workdir("/proj", "main.leaf", Some(reg)) {
    Ok(d) => assert_eq(d, "/proj/.choir/worktrees/main.leaf")
    Err(e) => fail("expected Ok worktree, got Err: " + e.message())
  }
}

///|
test "file_pr_workdir errors instead of falling back when registered workspace is empty" {
  // Regression: silent fallback to project_dir made `git status --porcelain`
  // run against the user's main checkout and surface unrelated edits as the
  // leaf's "uncommitted changes". Now `file_pr_workdir` must fail loud.
  let leaf : @types.Agent = {
    agent_id: @types.AgentId("master.graph-batched-extract-0"),
    role: @types.Role::Dev,
    agent_type: @types.AgentType::CursorAgent,
    parent: Some("root"),
    workspace: "",
    branch: "master.graph-batched-extract-0",
    terminal_target: None,
    host: @types.Host::Local,
    spawn_depth: 0,
    state: @types.AgentState::Active,
  }
  let reg = @registry.AgentRegistry::new()
  ignore(reg.upsert(leaf))
  match file_pr_workdir("/proj", "master.graph-batched-extract-0", Some(reg)) {
    Ok(d) =>
      fail(
        "expected workspace_error for empty registered workspace, got Ok: " + d,
      )
    Err(e) => {
      let msg = e.message()
      assert_true(msg.contains("master.graph-batched-extract-0"))
      assert_true(msg.contains("empty workspace"))
    }
  }
}

///|
test "file_pr_workdir falls back to project root when agent is not in the registry" {
  let reg = @registry.AgentRegistry::new()
  match file_pr_workdir("/proj", "unknown.leaf", Some(reg)) {
    Ok(d) => assert_eq(d, "/proj")
    Err(e) =>
      fail(
        "expected Ok fallback for unregistered agent, got Err: " + e.message(),
      )
  }
}

///|
test "file_pr_workdir falls back to project root when registry is None" {
  match file_pr_workdir("/proj", "main.leaf", None) {
    Ok(d) => assert_eq(d, "/proj")
    Err(e) =>
      fail("expected Ok fallback for no registry, got Err: " + e.message())
  }
}

///|
