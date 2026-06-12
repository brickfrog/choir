///|
fn file_pr_test_tdd_done(_agent_id : String) -> @types.LeafTddPhase? {
  Some(@types.LeafTddPhase::Done)
}

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
      assert_eq(tracked.review_mode, @types.Config::default().review_mode)
      @debug.assert_eq(tracked.unresolved_thread_ids, [])
      assert_false(tracked.unresolved_thread_ids_fetched)
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
test "file_pr_plan stores explicit review mode on tracked PR" {
  let args : FilePrArgs = {
    branch: "main.task-leaf",
    parent_branch: Some("main"),
    tracked_agent_id: "main.task-leaf",
    title: None,
    body: None,
    review_context: None,
  }
  let pr : PullRequestInfo = {
    number: 8,
    url: "https://example.test/pr/8",
    state: "OPEN",
  }
  let plan = file_pr_plan(
    args,
    "main",
    pr,
    true,
    review_mode=@types.ReviewMode::SinglePass,
  )
  match plan.tracked_pr {
    Some(tracked) =>
      assert_eq(tracked.review_mode, @types.ReviewMode::SinglePass)
    None => fail("expected tracked PR")
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
  let now_ms = 1776000000123L
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
  let plan = file_pr_auto_notify_plan(Ok(parent), "main.leaf", msg, now_ms~)
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
        @poller.delivery_log_line(
          "[auto-notify] caller=main.leaf parent=main.tl delivery=" +
          delivery.to_display_string(),
          now_ms~,
        ),
      )
    }
    _ => fail("expected Deliver")
  }
}

///|
test "file_pr_auto_notify_plan logs only when parent resolution fails" {
  let now_ms = 1776000000123L
  let err = @types.ChoirError::agent_not_found("main.tl")
  let plan = file_pr_auto_notify_plan(
    Err(err),
    "main.leaf",
    "[PR READY] PR #1 filed: https://ex/pr/1",
    now_ms~,
  )
  match plan {
    FilePrAutoNotifyPlan::ParentResolutionFailed(
      delivery_log_append~,
      parent_resolve_error~
    ) => {
      assert_eq(parent_resolve_error, err.message())
      assert_eq(
        delivery_log_append,
        @poller.delivery_log_line(
          "[auto-notify] resolve_parent_for_notify failed error=" +
          err.message(),
          now_ms~,
        ),
      )
    }
    _ => fail("expected ParentResolutionFailed")
  }
}

///|
test "file_pr_auto_notify_delivery_failed_log_append normalizes one line" {
  let now_ms = 1776000000123L
  assert_eq(
    file_pr_auto_notify_delivery_failed_log_append("oops", now_ms~),
    @poller.delivery_log_line(
      "[auto-notify] delivery failed error=oops",
      now_ms~,
    ),
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
  let got = interpret_file_pr_post_success_test(
    project_dir,
    "choir",
    args.branch,
    args.tracked_agent_id,
    project_dir,
    pr.number,
    @types.Reviewer::None,
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
  let got = interpret_file_pr_post_success_test(
    project_dir,
    "choir",
    args.branch,
    args.tracked_agent_id,
    project_dir,
    pr.number,
    @types.Reviewer::None,
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
  let now_ms = 1776000000123L
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
  let got = interpret_file_pr_post_success_test(
    project_dir,
    "choir",
    args.branch,
    args.tracked_agent_id,
    project_dir,
    pr.number,
    @types.Reviewer::None,
    effects,
    None,
    Some(reg),
    mock_runner_all_ok,
    now_ms_fn=fn() { now_ms },
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
  let expected_log = @poller.delivery_log_line(
    "[auto-notify] caller=main.leaf parent=main.tl delivery=" +
    expected_delivery.to_display_string(),
    now_ms~,
  )
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
  let got = interpret_file_pr_post_success_test(
    project_dir,
    "choir",
    args.branch,
    args.tracked_agent_id,
    project_dir,
    pr.number,
    @types.Reviewer::None,
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
async test "interpret_file_pr_post_success reads the clock fresh for each delivery-log append" {
  let project_dir = file_pr_post_success_test_dir()
  assert_true(@sys.create_dir_all(project_dir + "/.choir"))
  let log_path = project_dir + "/.choir/delivery.log"
  ignore(@sys.delete_file_sync(log_path))
  let args : FilePrArgs = {
    branch: "main.leaf",
    parent_branch: Some("main"),
    tracked_agent_id: "main.leaf",
    title: None,
    body: None,
    review_context: Some("ctx"),
  }
  let pr : PullRequestInfo = {
    number: 55,
    url: "https://example.test/pr/55",
    state: "OPEN",
  }
  let plan = file_pr_plan(args, "main", pr, false)
  // No registry -> no auto-notify append; reviewer=copilot + a runner that fails
  // both copilot commands → exactly two delivery-log appends.
  let effects = file_pr_post_success_effects(plan, false, false)
  let base = 1_700_000_000_000L
  let clock_calls : Array[Int] = [0]
  let runner_calls : Array[Int] = [0]
  let got = interpret_file_pr_post_success(
    project_dir,
    "choir",
    args.branch,
    args.tracked_agent_id,
    project_dir,
    pr.number,
    @types.Reviewer::Copilot,
    effects,
    None,
    None,
    async fn(cmds : Array[@workspace.Command]) -> Array[Int] {
      @async.sleep(0)
      assert_eq(cmds.length(), 1)
      runner_calls[0] = runner_calls[0] + 1
      [1]
    },
    now_ms_fn=fn() {
      clock_calls[0] = clock_calls[0] + 1
      base + clock_calls[0].to_int64() * 1000L
    },
  )
  match got {
    @types.Response::Ok(_) => ()
    _ => fail("expected ok despite copilot failures")
  }
  assert_eq(runner_calls[0], 2)
  assert_eq(clock_calls[0], 2)
  let log = @sys.read_file(log_path)
  // Distinct timestamps on the two appends: a captured-once clock would stamp
  // both with base+1000 and the second assert would fail.
  assert_true(
    log.contains(
      @poller.delivery_log_line(
        "[file_pr] copilot_review_comment failed pr=55",
        now_ms=base + 1000L,
      ),
    ),
  )
  assert_true(
    log.contains(
      @poller.delivery_log_line(
        "[file_pr] reviewer_request failed pr=55 reviewer=@copilot",
        now_ms=base + 2000L,
      ),
    ),
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
async fn file_pr_test_no_sleep(_ms : Int) -> Unit {
  @async.sleep(0)
}

///|
async fn interpret_file_pr_post_success_test(
  project_dir : String,
  session : String,
  branch : String,
  tracked_agent_id : String,
  file_pr_workdir : String,
  pr_number : Int,
  reviewer : @types.Reviewer,
  effects : FilePrPostSuccessEffects,
  poller_state : @poller.PollerState?,
  registry : @registry.AgentRegistry?,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  now_ms_fn? : () -> Int64 = fn() { @env.now().reinterpret_as_int64() },
) -> @types.Response {
  interpret_file_pr_post_success(
    project_dir,
    session,
    branch,
    tracked_agent_id,
    file_pr_workdir,
    pr_number,
    reviewer,
    effects,
    poller_state,
    registry,
    runner,
    sleep_fn=file_pr_test_no_sleep,
    now_ms_fn~,
  )
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
    merge_strategy: None,
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
fn file_pr_test_task_contract(verify : Array[String]) -> @types.TaskContract {
  { ..@types.TaskContract::empty(), goal: "verify before PR", verify }
}

///|
fn file_pr_test_task_contract_reader(
  contract : @types.TaskContract,
) -> (String) -> @types.TaskContract? {
  fn(_agent_id : String) -> @types.TaskContract? { Some(contract) }
}

///|
fn file_pr_test_empty_task_contract_reader(
  _agent_id : String,
) -> @types.TaskContract? {
  Some(file_pr_test_task_contract([]))
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
    ["moon test"],
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
    @types.Reviewer::None,
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
    @types.Reviewer::None,
    mock_preflight_err,
    mock_runner_all_ok,
    fn(cmd : @workspace.Command) -> (Int, String) {
      if cmd.program == "sh" {
        verify_capture_called = true
      }
      (0, "")
    },
    mock_ensure_pr_ok,
    tdd_phase_reader=file_pr_test_tdd_done,
    sleep_fn=file_pr_test_no_sleep,
  )
  match got {
    @types.Response::Err(msg) => assert_true(msg.contains("missing locally"))
    _ => fail("expected preflight Err")
  }
  assert_false(verify_capture_called)
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "interpret_file_pr fails closed when server task contract is missing" {
  let project_dir = "/tmp/choir-fpr-missing-contract-" +
    @sys.get_pid().to_string()
  let file_pr_dir = project_dir + "/.choir/worktrees/leaf"
  ignore(@sys.rm_rf(project_dir))
  let reg = file_pr_test_registry(file_pr_dir)
  let mut ensure_pr_called = false
  let mut verify_capture_called = false
  let got = interpret_file_pr(
    {
      branch: "main.leaf",
      parent_branch: Some("feature/missing-contract"),
      tracked_agent_id: "main.leaf",
      title: None,
      body: None,
      review_context: None,
    },
    project_dir,
    "choir",
    None,
    Some(reg),
    @types.Reviewer::None,
    mock_preflight_ok,
    mock_runner_all_ok,
    fn(cmd : @workspace.Command) -> (Int, String) {
      if cmd.program == "sh" {
        verify_capture_called = true
      }
      (0, "")
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
    tdd_phase_reader=file_pr_test_tdd_done,
    sleep_fn=file_pr_test_no_sleep,
  )
  match got {
    @types.Response::Err(msg) => {
      assert_true(msg.contains("server task contract unavailable"))
      assert_true(msg.contains("main.leaf"))
      assert_true(msg.contains("refusing to skip required verify"))
    }
    @types.Response::Ok(_) => fail("expected missing contract to block file_pr")
  }
  assert_false(verify_capture_called)
  assert_false(ensure_pr_called)
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "interpret_file_pr feature main succeeds without audit receipt" {
  let project_dir = "/tmp/choir-fpr-audit-missing-" + @sys.get_pid().to_string()
  let head = "123456789abcdef0123456789abcdef012345678"
  ignore(@sys.rm_rf(project_dir))
  assert_true(@sys.create_dir_all(project_dir + "/.choir"))
  let mut ensure_pr_called = false
  let got = interpret_file_pr(
    {
      branch: "feature/discipline-gates",
      parent_branch: Some("main"),
      tracked_agent_id: "feature/discipline-gates",
      title: None,
      body: None,
      review_context: None,
    },
    project_dir,
    "choir",
    None,
    None,
    @types.Reviewer::None,
    mock_preflight_ok,
    mock_runner_all_ok,
    fn(cmd : @workspace.Command) -> (Int, String) {
      if cmd.program == "git" {
        (0, head + "\n")
      } else if cmd.program == "cat" {
        (1, "")
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
    task_contract_reader=file_pr_test_empty_task_contract_reader,
  )
  match got {
    @types.Response::Ok(fields) => {
      assert_eq(fields.get("status").unwrap_or(""), "pr_created")
      assert_eq(fields.get("pr_number").unwrap_or(""), "42")
    }
    @types.Response::Err(msg) =>
      fail("expected file_pr to file without audit receipt: " + msg)
  }
  assert_true(ensure_pr_called)
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "interpret_file_pr leaf to feature does not require audit receipt" {
  let project_dir = "/tmp/choir-fpr-audit-leaf-" + @sys.get_pid().to_string()
  ignore(@sys.rm_rf(project_dir))
  assert_true(@sys.create_dir_all(project_dir + "/.choir"))
  let mut audit_receipt_read = false
  let mut ensure_pr_called = false
  let got = interpret_file_pr(
    {
      branch: "feature/discipline-gates.leaf-0",
      parent_branch: Some("feature/discipline-gates"),
      tracked_agent_id: "feature/discipline-gates.leaf-0",
      title: None,
      body: None,
      review_context: None,
    },
    project_dir,
    "choir",
    None,
    None,
    @types.Reviewer::None,
    mock_preflight_ok,
    mock_runner_all_ok,
    fn(cmd : @workspace.Command) -> (Int, String) {
      if cmd.program == "cat" {
        audit_receipt_read = true
      }
      (0, "")
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
    task_contract_reader=file_pr_test_empty_task_contract_reader,
  )
  match got {
    @types.Response::Ok(_) => ()
    @types.Response::Err(msg) => fail("expected leaf PR success: " + msg)
  }
  assert_false(audit_receipt_read)
  assert_true(ensure_pr_called)
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "interpret_file_pr tracked dev leaf refuses before TDD phase is done" {
  let project_dir = "/tmp/choir-fpr-tdd-gate-" + @sys.get_pid().to_string()
  ignore(@sys.rm_rf(project_dir))
  assert_true(@sys.create_dir_all(project_dir + "/.choir"))
  let mut ensure_pr_called = false
  let reg = file_pr_test_registry(project_dir + "/.choir/worktrees/main.leaf")
  let got = interpret_file_pr(
    {
      branch: "main.leaf",
      parent_branch: Some("feature/leaf-tdd-discipline"),
      tracked_agent_id: "main.leaf",
      title: None,
      body: None,
      review_context: None,
    },
    project_dir,
    "choir",
    None,
    Some(reg),
    @types.Reviewer::None,
    mock_preflight_ok,
    mock_runner_all_ok,
    mock_capture_empty,
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
    caller_role=@types.Role::TL,
    task_contract_reader=file_pr_test_empty_task_contract_reader,
    tdd_phase_reader=fn(_agent_id : String) { Some(@types.LeafTddPhase::Green) },
    sleep_fn=file_pr_test_no_sleep,
  )
  match got {
    @types.Response::Err(msg) => {
      assert_true(msg.contains("file_pr: leaf TDD phase must be done"))
      assert_true(msg.contains("current phase is green"))
    }
    _ => fail("expected TDD gate failure")
  }
  assert_false(ensure_pr_called)
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "interpret_file_pr runs required verify with configured moon target and injects generated PR body" {
  let project_dir = "/tmp/choir-fpr-verify-pr-body-" +
    @sys.get_pid().to_string()
  let file_pr_dir = project_dir + "/.choir/worktrees/leaf"
  ignore(@sys.rm_rf(project_dir))
  let contract = file_pr_test_task_contract(["moon check"])
  file_pr_test_write_verify_config(file_pr_dir, contract.verify)
  let reg = file_pr_test_registry(file_pr_dir)
  let bodies : Array[String] = []
  let sh_args : Array[Array[String]] = []
  let captured : Array[@moontrace.Event] = []
  @moontrace.set_subscriber(fn(event) { captured.push(event) })
  let got = interpret_file_pr(
    {
      branch: "main.leaf",
      parent_branch: Some("feature/verify-pr-body"),
      tracked_agent_id: "main.leaf",
      title: Some("schema wiring"),
      body: Some("Implements claim schema wiring."),
      review_context: None,
    },
    project_dir,
    "choir",
    None,
    Some(reg),
    @types.Reviewer::None,
    mock_preflight_ok,
    mock_runner_all_ok,
    fn(cmd : @workspace.Command) -> (Int, String) {
      if cmd.program == "git" {
        (0, "sha-pr-body\n")
      } else if cmd.program == "sh" {
        sh_args.push(cmd.args)
        (0, "moon check ok\n")
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
    task_contract_reader=file_pr_test_task_contract_reader(contract),
    tdd_phase_reader=file_pr_test_tdd_done,
    moon_verify_target=@types.MoonVerifyTarget::WasmGc,
    sleep_fn=file_pr_test_no_sleep,
  )
  @moontrace.clear_subscriber()
  match got {
    @types.Response::Ok(_) => ()
    @types.Response::Err(msg) => fail("expected file_pr success: " + msg)
  }
  assert_eq(bodies.length(), 1)
  assert_eq(sh_args.length(), 1)
  @debug.assert_eq(sh_args[0], ["-lc", "moon check --target wasm-gc"])
  assert_true(bodies[0].contains("Implements claim schema wiring."))
  assert_true(bodies[0].contains("## Verification"))
  assert_true(bodies[0].contains("`moon check --target wasm-gc`"))
  assert_true(bodies[0].contains("moon check ok"))
  assert_true(
    captured
    .iter()
    .any(fn(event) {
      event.level == @moontrace.Level::Warn &&
      event.message == "moon verify command normalized"
    }),
  )
  let records = @evidence.load_agent_evidence_records(project_dir, "main.leaf")
  assert_eq(records.length(), 1)
  match records[0].event {
    @evidence.EvidenceEvent::VerifyResultObserved(name~, ok~, details~) => {
      assert_eq(name, "moon check --target wasm-gc")
      assert_true(ok)
      let detail_text = details.unwrap_or("")
      assert_true(detail_text.contains("cwd: " + file_pr_dir))
      assert_true(detail_text.contains("head: sha-pr-body"))
      assert_true(detail_text.contains("moon check ok"))
    }
    _ => fail("expected VerifyResultObserved")
  }
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "dispatch file_pr records verify evidence through injected append_file" {
  let project_dir = "/tmp/choir-fpr-dispatch-verify-event-" +
    @sys.get_pid().to_string()
  let file_pr_dir = project_dir + "/.choir/worktrees/leaf"
  ignore(@sys.rm_rf(project_dir))
  let contract = file_pr_test_task_contract(["npm run typecheck"])
  file_pr_test_write_verify_config(file_pr_dir, contract.verify)
  let reg = file_pr_test_registry(file_pr_dir)
  let appends : Array[(String, String)] = []
  let resp = dispatch(
    ToolRequest::FilePr({
      branch: "main.leaf",
      parent_branch: Some("feature/verify-pr-body"),
      tracked_agent_id: "main.leaf",
      title: Some("schema wiring"),
      body: Some("Implements claim schema wiring."),
      review_context: None,
    }),
    project_dir~,
    session="choir",
    registry=Some(reg),
    reviewer=@types.Reviewer::None,
    ensure_branch_ready=Some(mock_preflight_ok),
    runner=mock_runner_all_ok,
    capture=async fn(cmd : @workspace.Command) -> (Int, String) {
      @async.sleep(0)
      if cmd.program == "git" {
        (0, "sha-dispatch-verify\n")
      } else if cmd.program == "sh" {
        (0, "typecheck ok\n")
      } else {
        (0, "")
      }
    },
    ensure_pr=Some(async fn(
      branch : String,
      _parent_branch : String,
      _dir : String,
      _title : String?,
      _body : String?,
    ) -> Result[PullRequestInfo, @types.ChoirError] {
      @async.sleep(0)
      Ok({ number: 42, url: "https://example.test/pr/" + branch, state: "OPEN" })
    }),
    append_file=fn(path, content) {
      appends.push((path, content))
      true
    },
    task_contract_reader=file_pr_test_task_contract_reader(contract),
    tdd_phase_reader=file_pr_test_tdd_done,
    sleep_fn=file_pr_test_no_sleep,
  )
  match resp {
    @types.Response::Ok(_) => ()
    @types.Response::Err(msg) => fail("expected dispatch success: " + msg)
  }
  assert_eq(appends.length(), 1)
  let (path, content) = appends[0]
  assert_true(path.contains("/.choir/events/main.leaf.jsonl"))
  assert_true(content.contains("npm run typecheck"))
  assert_true(content.contains("sha-dispatch-verify"))
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "interpret_file_pr blocks before PR creation when required verify fails" {
  let project_dir = "/tmp/choir-fpr-verify-block-" + @sys.get_pid().to_string()
  let file_pr_dir = project_dir + "/.choir/worktrees/leaf"
  ignore(@sys.rm_rf(project_dir))
  let contract = file_pr_test_task_contract(["npm run typecheck"])
  file_pr_test_write_verify_config(file_pr_dir, contract.verify)
  let reg = file_pr_test_registry(file_pr_dir)
  let mut ensure_pr_called = false
  let got = interpret_file_pr(
    {
      branch: "main.leaf",
      parent_branch: Some("feature/verify-block"),
      tracked_agent_id: "main.leaf",
      title: None,
      body: None,
      review_context: None,
    },
    project_dir,
    "choir",
    None,
    Some(reg),
    @types.Reviewer::None,
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
    task_contract_reader=file_pr_test_task_contract_reader(contract),
    tdd_phase_reader=file_pr_test_tdd_done,
    sleep_fn=file_pr_test_no_sleep,
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
async test "interpret_file_pr files leaf PR with changed tests without hidden mutation worker" {
  let project_dir = "/tmp/choir-fpr-no-hidden-mutation-" +
    @sys.get_pid().to_string()
  let file_pr_dir = project_dir + "/.choir/worktrees/leaf"
  let head = "abcdef1234567890abcdef1234567890abcdef12"
  ignore(@sys.rm_rf(project_dir))
  let contract = file_pr_test_task_contract(["moon test --target native"])
  file_pr_test_write_verify_config(file_pr_dir, contract.verify)
  let reg = file_pr_test_registry(file_pr_dir)
  let runner_cmds : Array[@workspace.Command] = []
  let mut ensure_pr_called = false
  let got = interpret_file_pr(
    {
      branch: "main.leaf",
      parent_branch: Some("feature/no-hidden-mutation"),
      tracked_agent_id: "main.leaf",
      title: None,
      body: None,
      review_context: None,
    },
    project_dir,
    "choir",
    None,
    Some(reg),
    @types.Reviewer::None,
    async fn(_branch, _parent_branch, _dir) {
      @async.sleep(0)
      Ok(())
    },
    async fn(cmds : Array[@workspace.Command]) -> Array[Int] {
      @async.sleep(0)
      let statuses : Array[Int] = []
      for cmd in cmds {
        runner_cmds.push(cmd)
        statuses.push(0)
      }
      statuses
    },
    fn(cmd : @workspace.Command) -> (Int, String) {
      if cmd.program == "git" && cmd.args == ["rev-parse", "HEAD"] {
        return (0, head + "\n")
      }
      if cmd.program == "git" &&
        cmd.args == ["rev-parse", "--abbrev-ref", "HEAD"] {
        return (0, "main.leaf\n")
      }
      if cmd.program == "git" &&
        cmd.args ==
        ["diff", "--name-only", "feature/no-hidden-mutation..." + head] {
        return (0, "src/tools/new_behavior_test.mbt\n")
      }
      if cmd.program == "sh" {
        return (0, "native tests passed\n")
      }
      (0, "")
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
    caller_role=@types.Role::Dev,
    record_verify_event=file_pr_test_record_verify_event(project_dir),
    task_contract_reader=file_pr_test_task_contract_reader(contract),
    tdd_phase_reader=file_pr_test_tdd_done,
    sleep_fn=file_pr_test_no_sleep,
  )
  match got {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      @debug.assert_eq(map.get("status"), Some(String::to_json("pr_created")))
      @debug.assert_eq(map.get("pr_number"), Some(Int::to_json(42)))
    }
    @types.Response::Err(msg) => fail("expected file_pr success: " + msg)
  }
  assert_true(ensure_pr_called)
  let removed_worker_slug = "mutation" + "-" + "gate"
  assert_false(
    runner_cmds.any(fn(cmd) {
      cmd.program.contains(removed_worker_slug) ||
      cmd.args.any(fn(arg) { arg.contains(removed_worker_slug) }) ||
      cmd.workdir.unwrap_or("").contains(removed_worker_slug)
    }),
  )
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "interpret_file_pr ok response matches full pipeline" {
  let project_dir = "/tmp/choir-fpr-interpret-" + @sys.get_pid().to_string()
  assert_true(@sys.create_dir_all(project_dir + "/.choir"))
  let args : FilePrArgs = {
    branch: "main.leaf",
    parent_branch: Some("feature/interpret"),
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
    @types.Reviewer::None,
    mock_preflight_ok,
    mock_runner_all_ok,
    mock_capture_empty,
    mock_ensure_pr_ok,
    task_contract_reader=file_pr_test_empty_task_contract_reader,
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
async test "interpret_file_pr tracks global review mode when no local override exists" {
  let project_dir = "/tmp/choir-fpr-global-review-mode-" +
    @sys.get_pid().to_string()
  ignore(@sys.rm_rf(project_dir))
  assert_true(@sys.create_dir_all(project_dir + "/.choir"))
  let ps = @poller.PollerState::new()
  let got = interpret_file_pr(
    {
      branch: "feature/base.leaf",
      parent_branch: Some("feature/base"),
      tracked_agent_id: "main.leaf",
      title: None,
      body: None,
      review_context: None,
    },
    project_dir,
    "choir",
    Some(ps),
    None,
    @types.Reviewer::None,
    mock_preflight_ok,
    mock_runner_all_ok,
    mock_capture_empty,
    mock_ensure_pr_ok,
    task_contract_reader=file_pr_test_empty_task_contract_reader,
  )
  match got {
    @types.Response::Ok(_) => ()
    _ => fail("expected ok")
  }
  match ps.get(42) {
    Some(tracked) =>
      assert_eq(tracked.review_mode, @types.ReviewMode::SinglePass)
    None => fail("expected tracked PR")
  }
  ignore(@sys.rm_rf(project_dir))
}

///|
test "file_pr_copilot_reviewer_gh_command requests @copilot reviewer" {
  let cmd = file_pr_copilot_reviewer_gh_command(44, "/wt/agent-checkout")
  assert_eq(cmd.program, "timeout")
  @debug.assert_eq(cmd.workdir, Some("/wt/agent-checkout"))
  @debug.assert_eq(cmd.args, [
    "30s", "gh", "pr", "edit", "44", "--add-reviewer", file_pr_copilot_reviewer_handle,
  ])
}

///|
test "interpret_request_review_result returns success envelope" {
  let got = interpret_request_review_result(0, "", 45, "@copilot")
  match got {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      @debug.assert_eq(map.get("status"), Some(String::to_json("ok")))
      @debug.assert_eq(map.get("pr_number"), Some(Int::to_json(45)))
      @debug.assert_eq(map.get("reviewer"), Some(String::to_json("@copilot")))
    }
    @types.Response::Err(msg) => fail("expected ok: " + msg)
  }
}

///|
async test "dispatch request_review runs reviewer request through server capture" {
  let seen : Array[@workspace.Command] = []
  let ps = @poller.PollerState::new()
  ps.track(
    46, "main.leaf", "main.leaf", "main", "https://github.com/brickfrog/choir/pull/46",
    0L,
  )
  let got = dispatch(
    ToolRequest::RequestReview({ pr_number: 46, reviewer: "@copilot" }),
    project_dir="/srv/choir",
    poller_state=Some(ps),
    capture=async fn(cmd : @workspace.Command) -> (Int, String) {
      @async.sleep(0)
      seen.push(cmd)
      (0, "")
    },
  )
  match got {
    @types.Response::Ok(_) => ()
    @types.Response::Err(msg) => fail("expected ok: " + msg)
  }
  assert_eq(seen.length(), 1)
  assert_eq(seen[0].program, "timeout")
  @debug.assert_eq(seen[0].workdir, Some("/srv/choir"))
  @debug.assert_eq(seen[0].args, [
    "30s", "gh", "pr", "edit", "46", "--add-reviewer", "@copilot",
  ])
}

///|
async test "dispatch request_review rejects untracked PR" {
  let ps = @poller.PollerState::new()
  let got = dispatch(
    ToolRequest::RequestReview({ pr_number: 999, reviewer: "@copilot" }),
    project_dir="/srv/choir",
    poller_state=Some(ps),
    capture=async fn(_cmd : @workspace.Command) -> (Int, String) {
      @async.sleep(0)
      fail("request_review should not call capture for untracked PR")
    },
  )
  match got {
    @types.Response::Err(msg) => assert_true(msg.contains("is not tracked"))
    @types.Response::Ok(_) => fail("expected untracked PR rejection")
  }
}

///|
async test "interpret_file_pr requests reviewer after verify push and ensure_pr" {
  let project_dir = "/tmp/choir-fpr-existing-reviewer-after-gates-" +
    @sys.get_pid().to_string()
  let file_pr_dir = project_dir
  let head = "abcdef1234567890abcdef1234567890abcdef12"
  ignore(@sys.rm_rf(project_dir))
  assert_true(@sys.create_dir_all(project_dir + "/.choir"))
  let contract = file_pr_test_task_contract(["npm run typecheck"])
  file_pr_test_write_verify_config(file_pr_dir, contract.verify)
  let runner_cmds : Array[@workspace.Command] = []
  let events : Array[String] = []
  let mut ensure_pr_called = false
  let got = interpret_file_pr(
    {
      branch: "feature/existing-reviewer",
      parent_branch: Some("main"),
      tracked_agent_id: "feature/existing-reviewer",
      title: None,
      body: None,
      review_context: None,
    },
    project_dir,
    "choir",
    None,
    None,
    @types.Reviewer::Copilot,
    mock_preflight_ok,
    async fn(cmds : Array[@workspace.Command]) -> Array[Int] {
      @async.sleep(0)
      let codes : Array[Int] = []
      for cmd in cmds {
        if cmd.program == "git" &&
          cmd.args.length() > 0 &&
          cmd.args[0] == "push" {
          events.push("push")
        }
        if cmd.program == "timeout" && cmd.args.contains("--add-reviewer") {
          events.push("reviewer")
        }
        runner_cmds.push(cmd)
        codes.push(0)
      }
      codes
    },
    fn(cmd : @workspace.Command) -> (Int, String) raise {
      if cmd.program == "git" && cmd.args == ["rev-parse", "HEAD"] {
        events.push("head")
        return (0, head + "\n")
      }
      if cmd.program == "cat" {
        fail("file_pr should not read audit receipts")
      }
      if cmd.program == "sh" {
        events.push("verify")
        return (0, "typecheck ok\n")
      }
      (0, "")
    },
    fn(
      _branch : String,
      _parent_branch : String,
      _dir : String,
      _title : String?,
      _body : String?,
    ) -> Result[PullRequestInfo, @types.ChoirError] {
      events.push("ensure_pr")
      ensure_pr_called = true
      Ok({ number: 45, url: "https://example.test/pr/45", state: "OPEN" })
    },
    task_contract_reader=file_pr_test_task_contract_reader(contract),
    sleep_fn=file_pr_test_no_sleep,
  )
  match got {
    @types.Response::Ok(_) => ()
    @types.Response::Err(msg) => fail("expected file_pr success: " + msg)
  }
  assert_true(ensure_pr_called)
  @debug.assert_eq(events, ["head", "verify", "push", "ensure_pr", "reviewer"])
  assert_eq(runner_cmds.length(), 2)
  assert_eq(runner_cmds[1].program, "timeout")
  @debug.assert_eq(runner_cmds[1].args, [
    "30s", "gh", "pr", "edit", "45", "--add-reviewer", "@copilot",
  ])
  ignore(@sys.rm_rf(project_dir))
}

///|
struct FilePrCopilotPolicyObserved {
  requested_reviewers : Array[String]
  review_comments : Array[String]
} derive(Debug, Eq)

///|
async fn file_pr_copilot_policy_observed_for_parent(
  parent_branch : String,
  default_branch : String,
  skip_copilot_on_feature_branch : Bool,
  reviewer : @types.Reviewer,
  review_context : String?,
) -> FilePrCopilotPolicyObserved {
  let project_dir = "/tmp/choir-fpr-copilot-policy-" +
    @sys.get_pid().to_string() +
    "-" +
    parent_branch.replace(old="/", new="-") +
    "-" +
    default_branch +
    "-" +
    skip_copilot_on_feature_branch.to_string()
  ignore(@sys.rm_rf(project_dir))
  assert_true(@sys.create_dir_all(project_dir + "/.choir"))
  let requested_reviewers : Array[String] = []
  let review_comments : Array[String] = []
  let got = interpret_file_pr(
    {
      branch: "feature/copilot-policy.leaf",
      parent_branch: Some(parent_branch),
      tracked_agent_id: "feature/copilot-policy.leaf",
      title: None,
      body: None,
      review_context,
    },
    project_dir,
    "choir",
    None,
    None,
    reviewer,
    mock_preflight_ok,
    async fn(cmds : Array[@workspace.Command]) -> Array[Int] {
      @async.sleep(0)
      let codes : Array[Int] = []
      for cmd in cmds {
        if cmd.args.length() >= 5 &&
          cmd.args[0] == "pr" &&
          cmd.args[1] == "comment" &&
          cmd.args[3] == "--body" {
          review_comments.push(cmd.args[4])
        }
        for i = 0; i + 1 < cmd.args.length(); i = i + 1 {
          if cmd.args[i] == "--add-reviewer" {
            requested_reviewers.push(cmd.args[i + 1])
          }
        }
        codes.push(0)
      }
      codes
    },
    fn(cmd : @workspace.Command) -> (Int, String) {
      if cmd.program == "git" &&
        cmd.args == ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"] {
        (0, "origin/" + default_branch + "\n")
      } else if cmd.program == "git" && cmd.args == ["rev-parse", "HEAD"] {
        (0, "abcdef1234567890abcdef1234567890abcdef12\n")
      } else {
        (0, "")
      }
    },
    mock_ensure_pr_ok,
    task_contract_reader=file_pr_test_empty_task_contract_reader,
    skip_copilot_on_feature_branch~,
    sleep_fn=file_pr_test_no_sleep,
  )
  match got {
    @types.Response::Ok(_) => ()
    @types.Response::Err(msg) => fail("expected file_pr success: " + msg)
  }
  ignore(@sys.rm_rf(project_dir))
  { requested_reviewers, review_comments }
}

///|
async test "interpret_file_pr gates copilot reviewer request by parent branch policy" {
  let feature_enabled = file_pr_copilot_policy_observed_for_parent(
    "feature/foo",
    "main",
    true,
    @types.Reviewer::Copilot,
    None,
  )
  assert_false(feature_enabled.requested_reviewers.contains("@copilot"))

  let main_enabled = file_pr_copilot_policy_observed_for_parent(
    "main",
    "main",
    true,
    @types.Reviewer::Copilot,
    None,
  )
  assert_true(main_enabled.requested_reviewers.contains("@copilot"))

  let master_enabled = file_pr_copilot_policy_observed_for_parent(
    "master",
    "master",
    true,
    @types.Reviewer::Copilot,
    None,
  )
  assert_true(master_enabled.requested_reviewers.contains("@copilot"))

  let feature_disabled = file_pr_copilot_policy_observed_for_parent(
    "feature/foo",
    "main",
    false,
    @types.Reviewer::Copilot,
    None,
  )
  assert_true(feature_disabled.requested_reviewers.contains("@copilot"))

  let main_disabled = file_pr_copilot_policy_observed_for_parent(
    "main",
    "main",
    false,
    @types.Reviewer::Copilot,
    None,
  )
  assert_true(main_disabled.requested_reviewers.contains("@copilot"))
}

///|
async test "interpret_file_pr requests configured named reviewer handle" {
  let observed = file_pr_copilot_policy_observed_for_parent(
    "main",
    "main",
    true,
    @types.Reviewer::Named("octocat"),
    None,
  )
  assert_true(observed.requested_reviewers.contains("octocat"))
  assert_false(observed.requested_reviewers.contains("@copilot"))
}

///|
async test "interpret_file_pr skips reviewer request when reviewer none" {
  let observed = file_pr_copilot_policy_observed_for_parent(
    "main",
    "main",
    true,
    @types.Reviewer::None,
    Some("trace context"),
  )
  assert_eq(observed.requested_reviewers.length(), 0)
  assert_eq(observed.review_comments.length(), 0)
}

///|
async test "interpret_file_pr keeps copilot context comment when feature branch reviewer is skipped" {
  let observed = file_pr_copilot_policy_observed_for_parent(
    "feature/foo",
    "main",
    true,
    @types.Reviewer::Copilot,
    Some("trace context"),
  )
  assert_false(observed.requested_reviewers.contains("@copilot"))
  let expected_comment = file_pr_copilot_review_comment_body("trace context")
  if !observed.review_comments.contains(expected_comment) {
    fail(
      "expected copilot context comment, saw: " +
      observed.review_comments.join("|"),
    )
  }
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
