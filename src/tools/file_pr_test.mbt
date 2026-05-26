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
  let got = interpret_file_pr_post_success_test(
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
    false,
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
  // No registry → no auto-notify append; pr_review=true + a runner that fails
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
    true,
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
        "[file_pr] copilot_reviewer_request failed pr=55",
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
  pr_review : Bool,
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
    pr_review,
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
test "mutation gate targets MoonBit source and sibling tests from changed paths" {
  let targets = mutation_gate_targets_for_changed_paths([
    "README.md", "src/math.mbt", "src/math_test.mbt", "src/server/handler_test.mbt",
    "src/server/handler.mbt",
  ])
  assert_eq(targets.length(), 2)
  assert_eq(targets[0].language, MutationLanguage::MoonBit)
  assert_eq(targets[0].source_path, "src/math.mbt")
  @debug.assert_eq(targets[0].test_paths, ["src/math_test.mbt"])
  assert_eq(targets[1].language, MutationLanguage::MoonBit)
  assert_eq(targets[1].source_path, "src/server/handler.mbt")
  @debug.assert_eq(targets[1].test_paths, ["src/server/handler_test.mbt"])
}

///|
test "mutation gate worker task carries MoonBit adapter instructions and no cost pilot" {
  let task = build_mutation_gate_task(
    "/repo",
    "main.leaf",
    "abcdef1234567890abcdef1234567890abcdef12",
    [
      {
        language: MutationLanguage::MoonBit,
        source_path: "src/math.mbt",
        test_paths: ["src/math_test.mbt"],
      },
    ],
    ["moon test --target native"],
    0.75,
  )
  assert_true(task.contains("MoonBit adapter:"))
  assert_true(task.contains("src/math.mbt"))
  assert_true(task.contains("src/math_test.mbt"))
  assert_true(task.contains("moon test --target native"))
  assert_true(task.contains(mutation_gate_report_json_marker))
  assert_true(task.contains("re-fix-tests"))
  assert_true(task.contains("mutation_kill_rate_min=0.75"))
  assert_false(task.contains("cost pilot"))
  assert_false(task.contains("dashboard"))
}

///|
test "build_mutation_gate_task includes adapter-gap immediate-exit directives" {
  let task = build_mutation_gate_task(
    "/repo",
    "main.leaf",
    "abcdef1234567890abcdef1234567890abcdef12",
    [
      {
        language: MutationLanguage::MoonBit,
        source_path: "src/math.mbt",
        test_paths: ["src/math_test.mbt"],
      },
    ],
    ["moon test --target native"],
    0.75,
  )
  assert_true(task.contains("If the adapter gap is detected"))
  assert_true(
    task.contains(
      "run this sequence only once: notify_parent --status failure -> shutdown -> exit",
    ),
  )
  assert_true(task.contains("EXIT IMMEDIATELY after that sequence"))
  assert_true(task.contains("call notify_parent --status failure ONCE"))
  assert_true(task.contains("notify_parent"))
  assert_true(task.contains("Do not background any subprocess"))
  assert_true(
    task.contains("Do not write a helper script that outlives this shell"),
  )
  assert_true(task.contains("Bound every subprocess with `timeout"))
}

///|
test "build_mutation_gate_task includes outer mutation-loop wall-clock cap" {
  let task = build_mutation_gate_task(
    "/repo",
    "main.leaf",
    "abcdef1234567890abcdef1234567890abcdef12",
    [
      {
        language: MutationLanguage::MoonBit,
        source_path: "src/math.mbt",
        test_paths: ["src/math_test.mbt"],
      },
    ],
    ["moon test --target native"],
    0.75,
  )
  assert_true(
    task.contains(
      "Wrap your ENTIRE mutation loop with `timeout 600s` (10 min cap). The 60s per-subprocess bounds protect individual hangs; the 600s outer bound protects against unbounded N-mutant loops.",
    ),
  )
  assert_true(
    task.contains(
      "If your script structure can't be cleanly wrapped, use a wall-clock check before each iteration that exits when `start_time + 600s < now`.",
    ),
  )
}

///|
async test "interpret_file_pr runs mutation gate for TL-filed registered dev PR" {
  let project_dir = "/tmp/choir-fpr-mutation-tl-dev-" +
    @sys.get_pid().to_string()
  let file_pr_dir = project_dir + "/.choir/worktrees/leaf"
  let head = "abcdef1234567890abcdef1234567890abcdef12"
  ignore(@sys.rm_rf(project_dir))
  let contract = file_pr_test_task_contract(["moon test --target native"])
  file_pr_test_write_verify_config(file_pr_dir, contract.verify)
  let reg = file_pr_test_registry(file_pr_dir)
  let mut ensure_pr_called = false
  let prepared_workers : Array[String] = []
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
    false,
    mock_preflight_ok,
    mock_runner_all_ok,
    async fn(cmd : @workspace.Command) -> (Int, String) {
      @async.sleep(0)
      if cmd.program == "git" && cmd.args == ["rev-parse", "HEAD"] {
        return (0, head + "\n")
      }
      if cmd.program == "git" &&
        cmd.args == ["rev-parse", "--abbrev-ref", "HEAD"] {
        return (0, "main.leaf\n")
      }
      if cmd.program == "git" &&
        cmd.args ==
        ["diff", "--name-only", "feature/leaf-tdd-discipline..." + head] {
        return (0, "src/math.mbt\nsrc/math_test.mbt\n")
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
    caller_role=@types.Role::TL,
    prepare_mutation_gate_report=fn(agent_id) {
      prepared_workers.push(agent_id)
    },
    wait_for_mutation_gate_report=async fn(_agent_id) {
      @async.sleep(0)
      Some({
        message: mutation_gate_report_json_marker +
        " {\"kill_rate\":1.0,\"total_mutants\":4,\"killed_mutants\":1,\"surviving_mutants\":[\"src/math.mbt:7 + -> -\"],\"unsupported_languages\":[]}",
        status: @types.Status::Success,
      })
    },
    mutation_gate_now_ms_fn=fn() { 1779000000L },
    record_verify_event=file_pr_test_record_verify_event(project_dir),
    task_contract_reader=file_pr_test_task_contract_reader(contract),
    tdd_phase_reader=file_pr_test_tdd_done,
    sleep_fn=file_pr_test_no_sleep,
  )
  match got {
    @types.Response::Err(msg) => {
      assert_true(msg.contains("mutation gate failed"))
      assert_true(msg.contains("src/math.mbt:7 + -> -"))
      assert_true(msg.contains("re-fix-tests"))
    }
    _ => fail("expected registered Dev mutation gate failure")
  }
  assert_false(ensure_pr_called)
  assert_eq(prepared_workers.length(), 1)
  assert_true(prepared_workers[0].contains("mutation-gate-abcdef123456-"))
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "file_pr_run_mutation_gate cancels worker before cleanup on timeout" {
  let project_dir = "/tmp/choir-fpr-mutation-timeout-cancel-" +
    @sys.get_pid().to_string()
  let head = "abcdef1234567890abcdef1234567890abcdef12"
  let worker_id = "main.mutation-gate-fixed"
  let events : Array[String] = []
  let mut now_ms = 0L
  let got = file_pr_run_mutation_gate(
    project_dir,
    project_dir,
    @types.Role::Dev,
    "main.leaf",
    None,
    "feature/leaf-tdd-discipline",
    head,
    ["moon test --target native"],
    0.8,
    async fn(cmd : @workspace.Command) -> (Int, String) {
      @async.sleep(0)
      if cmd.program == "git" &&
        cmd.args == ["rev-parse", "--abbrev-ref", "HEAD"] {
        return (0, "main.leaf\n")
      }
      if cmd.program == "git" &&
        cmd.args ==
        ["diff", "--name-only", "feature/leaf-tdd-discipline..." + head] {
        return (0, "src/math.mbt\nsrc/math_test.mbt\n")
      }
      (0, "")
    },
    async fn(_) {
      @async.sleep(0)
      Ok(worker_id)
    },
    async fn(_) {
      @async.sleep(10)
      None
    },
    fn(id) { events.push("cleanup:" + id) },
    2,
    fn() {
      let value = now_ms
      now_ms = now_ms + 1L
      value
    },
    cancel_worker=fn(id) { events.push("cancel:" + id) },
    sleep_fn=file_pr_test_no_sleep,
  )
  match got {
    Err(e) =>
      assert_true(
        e
        .validation_detail_or_message()
        .contains("mutation gate budget exceeded"),
      )
    Ok(_) => fail("expected mutation gate timeout")
  }
  @debug.assert_eq(events, ["cancel:" + worker_id, "cleanup:" + worker_id])
}

///|
async test "file_pr_run_mutation_gate cancels worker before cleanup on no report" {
  let project_dir = "/tmp/choir-fpr-mutation-noreport-cancel-" +
    @sys.get_pid().to_string()
  let head = "abcdef1234567890abcdef1234567890abcdef12"
  let worker_id = "main.mutation-gate-fixed"
  let events : Array[String] = []
  let got = file_pr_run_mutation_gate(
    project_dir,
    project_dir,
    @types.Role::Dev,
    "main.leaf",
    None,
    "feature/leaf-tdd-discipline",
    head,
    ["moon test --target native"],
    0.8,
    async fn(cmd : @workspace.Command) -> (Int, String) {
      @async.sleep(0)
      if cmd.program == "git" &&
        cmd.args == ["rev-parse", "--abbrev-ref", "HEAD"] {
        return (0, "main.leaf\n")
      }
      if cmd.program == "git" &&
        cmd.args ==
        ["diff", "--name-only", "feature/leaf-tdd-discipline..." + head] {
        return (0, "src/math.mbt\nsrc/math_test.mbt\n")
      }
      (0, "")
    },
    async fn(_) {
      @async.sleep(0)
      Ok(worker_id)
    },
    async fn(_) {
      @async.sleep(0)
      None
    },
    fn(id) { events.push("cleanup:" + id) },
    1000,
    fn() { 123456789L },
    cancel_worker=fn(id) { events.push("cancel:" + id) },
  )
  match got {
    Err(e) =>
      assert_true(
        e.validation_detail_or_message().contains("worker did not report"),
      )
    Ok(_) => fail("expected mutation gate no-report failure")
  }
  @debug.assert_eq(events, ["cancel:" + worker_id, "cleanup:" + worker_id])
}

///|
async test "file_pr_run_mutation_gate cancels worker before cleanup on worker died" {
  let project_dir = "/tmp/choir-fpr-mutation-dead-cancel-" +
    @sys.get_pid().to_string()
  let head = "abcdef1234567890abcdef1234567890abcdef12"
  let worker_id = "main.mutation-gate-fixed"
  let events : Array[String] = []
  let got = file_pr_run_mutation_gate(
    project_dir,
    project_dir,
    @types.Role::Dev,
    "main.leaf",
    None,
    "feature/leaf-tdd-discipline",
    head,
    ["moon test --target native"],
    0.8,
    async fn(cmd : @workspace.Command) -> (Int, String) {
      @async.sleep(0)
      if cmd.program == "git" &&
        cmd.args == ["rev-parse", "--abbrev-ref", "HEAD"] {
        return (0, "main.leaf\n")
      }
      if cmd.program == "git" &&
        cmd.args ==
        ["diff", "--name-only", "feature/leaf-tdd-discipline..." + head] {
        return (0, "src/math.mbt\nsrc/math_test.mbt\n")
      }
      (0, "")
    },
    async fn(_) {
      @async.sleep(0)
      Ok(worker_id)
    },
    async fn(_) {
      @async.sleep(0)
      None
    },
    fn(id) { events.push("cleanup:" + id) },
    1000,
    fn() { 123456789L },
    cancel_worker=fn(id) { events.push("cancel:" + id) },
    mutation_worker_alive=fn(_) { false },
  )
  match got {
    Err(e) =>
      assert_true(
        e.validation_detail_or_message().contains("exited before report"),
      )
    Ok(_) => fail("expected mutation worker death failure")
  }
  @debug.assert_eq(events, ["cancel:" + worker_id, "cleanup:" + worker_id])
}

///|
async test "file_pr_run_mutation_gate does not cancel worker on success report" {
  let project_dir = "/tmp/choir-fpr-mutation-success-no-cancel-" +
    @sys.get_pid().to_string()
  let head = "abcdef1234567890abcdef1234567890abcdef12"
  let worker_id = "main.mutation-gate-fixed"
  let events : Array[String] = []
  let got = file_pr_run_mutation_gate(
    project_dir,
    project_dir,
    @types.Role::Dev,
    "main.leaf",
    None,
    "feature/leaf-tdd-discipline",
    head,
    ["moon test --target native"],
    0.8,
    async fn(cmd : @workspace.Command) -> (Int, String) {
      @async.sleep(0)
      if cmd.program == "git" &&
        cmd.args == ["rev-parse", "--abbrev-ref", "HEAD"] {
        return (0, "main.leaf\n")
      }
      if cmd.program == "git" &&
        cmd.args ==
        ["diff", "--name-only", "feature/leaf-tdd-discipline..." + head] {
        return (0, "src/math.mbt\nsrc/math_test.mbt\n")
      }
      (0, "")
    },
    async fn(_) {
      @async.sleep(0)
      Ok(worker_id)
    },
    async fn(_) {
      @async.sleep(0)
      Some({
        message: mutation_gate_report_json_marker +
        " {\"kill_rate\":1.0,\"total_mutants\":4,\"killed_mutants\":4,\"surviving_mutants\":[],\"unsupported_languages\":[]}",
        status: @types.Status::Success,
      })
    },
    fn(id) { events.push("cleanup:" + id) },
    1000,
    fn() { 123456789L },
    cancel_worker=fn(id) { events.push("cancel:" + id) },
  )
  match got {
    Ok(_) => ()
    Err(e) => fail("expected mutation gate success: " + e.message())
  }
  @debug.assert_eq(events, ["cleanup:" + worker_id])
}

///|
async test "file_pr_run_mutation_gate cancels worker on failure report" {
  let project_dir = "/tmp/choir-fpr-mutation-report-failure-cancel-" +
    @sys.get_pid().to_string()
  let head = "abcdef1234567890abcdef1234567890abcdef12"
  let worker_id = "main.mutation-gate-fixed"
  let events : Array[String] = []
  let got = file_pr_run_mutation_gate(
    project_dir,
    project_dir,
    @types.Role::Dev,
    "main.leaf",
    None,
    "feature/leaf-tdd-discipline",
    head,
    ["moon test --target native"],
    0.8,
    async fn(cmd : @workspace.Command) -> (Int, String) {
      @async.sleep(0)
      if cmd.program == "git" &&
        cmd.args == ["rev-parse", "--abbrev-ref", "HEAD"] {
        return (0, "main.leaf\n")
      }
      if cmd.program == "git" &&
        cmd.args ==
        ["diff", "--name-only", "feature/leaf-tdd-discipline..." + head] {
        return (0, "src/math.mbt\nsrc/math_test.mbt\n")
      }
      (0, "")
    },
    async fn(_) {
      @async.sleep(0)
      Ok(worker_id)
    },
    async fn(_) {
      @async.sleep(0)
      Some({
        message: "adapter failed before clean shutdown",
        status: @types.Status::Failure,
      })
    },
    fn(id) { events.push("cleanup:" + id) },
    1000,
    fn() { 123456789L },
    cancel_worker=fn(id) { events.push("cancel:" + id) },
  )
  match got {
    Err(e) =>
      assert_true(
        e.validation_detail_or_message().contains("worker reported failure"),
      )
    Ok(_) => fail("expected mutation gate failure report")
  }
  @debug.assert_eq(events, ["cancel:" + worker_id, "cleanup:" + worker_id])
}

///|
async test "file_pr_run_mutation_gate cancels worker when success report lacks JSON marker" {
  // Worker called notify_parent --status success but its message did
  // NOT contain MUTATION_GATE_REPORT_JSON: ... . Per F3 the cancel
  // must still fire — reporting != exiting, and the mutation_gate_incomplete
  // surface in mutation_gate_report_from_message's None arm is the
  // same orphan-shape as the other incomplete branches.
  let project_dir = "/tmp/choir-fpr-mutation-no-marker-" +
    @sys.get_pid().to_string()
  let head = "abcdef1234567890abcdef1234567890abcdef12"
  let worker_id = "main.mutation-gate-fixed"
  let events : Array[String] = []
  let got = file_pr_run_mutation_gate(
    project_dir,
    project_dir,
    @types.Role::Dev,
    "main.leaf",
    None,
    "feature/leaf-tdd-discipline",
    head,
    ["moon test --target native"],
    0.8,
    async fn(cmd : @workspace.Command) -> (Int, String) {
      @async.sleep(0)
      if cmd.program == "git" &&
        cmd.args == ["rev-parse", "--abbrev-ref", "HEAD"] {
        return (0, "main.leaf\n")
      }
      if cmd.program == "git" &&
        cmd.args ==
        ["diff", "--name-only", "feature/leaf-tdd-discipline..." + head] {
        return (0, "src/math.mbt\nsrc/math_test.mbt\n")
      }
      (0, "")
    },
    async fn(_) {
      @async.sleep(0)
      Ok(worker_id)
    },
    async fn(_) {
      @async.sleep(0)
      Some({
        // Success status but message has no JSON marker — the
        // worker swallowed its own report shape.
        message: "mutation pass complete, no findings",
        status: @types.Status::Success,
      })
    },
    fn(id) { events.push("cleanup:" + id) },
    1000,
    fn() { 123456789L },
    cancel_worker=fn(id) { events.push("cancel:" + id) },
  )
  match got {
    Err(e) =>
      assert_true(e.validation_detail_or_message().contains("did not return"))
    Ok(_) =>
      fail("expected mutation_gate_incomplete when JSON marker is absent")
  }
  @debug.assert_eq(events, ["cancel:" + worker_id, "cleanup:" + worker_id])
}

///|
async test "file_pr_run_mutation_gate computes kill rate from mutant counts" {
  let project_dir = "/tmp/choir-fpr-mutation-low-" + @sys.get_pid().to_string()
  let head = "abcdef1234567890abcdef1234567890abcdef12"
  let mut spawned_slug = ""
  let mut waited_worker = ""
  let events : Array[String] = []
  let got = file_pr_run_mutation_gate(
    project_dir,
    project_dir,
    @types.Role::Dev,
    "main.leaf",
    None,
    "feature/leaf-tdd-discipline",
    head,
    ["moon test --target native"],
    0.8,
    async fn(cmd : @workspace.Command) -> (Int, String) {
      @async.sleep(0)
      if cmd.program == "git" &&
        cmd.args == ["rev-parse", "--abbrev-ref", "HEAD"] {
        return (0, "main.leaf\n")
      }
      if cmd.program == "git" &&
        cmd.args ==
        ["diff", "--name-only", "feature/leaf-tdd-discipline..." + head] {
        return (0, "src/math.mbt\nsrc/math_test.mbt\n")
      }
      (0, "")
    },
    async fn(worker_args) {
      @async.sleep(0)
      spawned_slug = worker_args.slug
      Ok("main." + worker_args.slug)
    },
    async fn(worker_id) {
      @async.sleep(0)
      waited_worker = worker_id
      Some({
        message: mutation_gate_report_json_marker +
        " {\"kill_rate\":1.0,\"total_mutants\":4,\"killed_mutants\":2,\"surviving_mutants\":[\"src/math.mbt:12 == -> !=\"],\"unsupported_languages\":[]}",
        status: @types.Status::Success,
      })
    },
    fn(id) { events.push("cleanup:" + id) },
    1000,
    fn() { 123456789L },
    cancel_worker=fn(id) { events.push("cancel:" + id) },
  )
  match got {
    Err(e) => {
      let msg = e.validation_detail_or_message()
      assert_true(msg.contains("mutation gate failed"))
      assert_true(msg.contains("mutant-kill-rate 0.5"))
      assert_true(msg.contains("threshold 0.8"))
      assert_true(msg.contains("src/math.mbt:12 == -> !="))
      assert_true(msg.contains("re-fix-tests"))
    }
    Ok(_) => fail("expected low mutation kill rate to block file_pr")
  }
  assert_eq(spawned_slug, mutation_gate_worker_slug(head, 123456789L))
  assert_eq(waited_worker, "main." + spawned_slug)
  // Worker reported success but kill rate is below threshold → still
  // cancel for consistency with Timeout/NoReport/WorkerDied/Reported(failure).
  // Reporting is not the same as exiting; the worker's shutdown chain
  // can hang on a timeout-wrapped subprocess.
  @debug.assert_eq(events, [
    "cancel:main." + spawned_slug,
    "cleanup:main." + spawned_slug,
  ])
}

///|
async test "file_pr_run_mutation_gate treats timeout as mutation-gate incomplete" {
  let project_dir = "/tmp/choir-fpr-mutation-timeout-" +
    @sys.get_pid().to_string()
  let head = "abcdef1234567890abcdef1234567890abcdef12"
  let mut cleanup_calls = 0
  let mut wait_calls = 0
  let mut now_ms = 0L
  let got = file_pr_run_mutation_gate(
    project_dir,
    project_dir,
    @types.Role::Dev,
    "main.leaf",
    None,
    "feature/leaf-tdd-discipline",
    head,
    ["moon test --target native"],
    0.8,
    async fn(cmd : @workspace.Command) -> (Int, String) {
      @async.sleep(0)
      if cmd.program == "git" &&
        cmd.args == ["rev-parse", "--abbrev-ref", "HEAD"] {
        return (0, "main.leaf\n")
      }
      if cmd.program == "git" &&
        cmd.args ==
        ["diff", "--name-only", "feature/leaf-tdd-discipline..." + head] {
        return (0, "src/math.mbt\nsrc/math_test.mbt\n")
      }
      (0, "")
    },
    async fn(worker_args) {
      @async.sleep(0)
      Ok("main." + worker_args.slug)
    },
    async fn(_agent_id) {
      @async.sleep(0)
      wait_calls = wait_calls + 1
      None
    },
    fn(_) { cleanup_calls = cleanup_calls + 1 },
    1000,
    fn() {
      now_ms = now_ms + 250L
      now_ms
    },
  )
  match got {
    Err(e) => {
      assert_true(e.is_mutation_gate_incomplete())
      let msg = e.validation_detail_or_message()
      assert_true(msg.contains("[MUTATION GATE INCOMPLETE]"))
    }
    Ok(_) => fail("expected timeout to degrade as mutation gate incomplete")
  }
  assert_true(wait_calls > 0)
  assert_eq(cleanup_calls, 1)
}

///|
async test "file_pr_run_mutation_gate exhausts budget when report never resolves" {
  let project_dir = "/tmp/choir-fpr-mutation-real-timeout-" +
    @sys.get_pid().to_string()
  let head = "abcdef1234567890abcdef1234567890abcdef12"
  let mut cleanup_calls = 0
  let mut wait_calls = 0
  let mut now_ms = 0L
  let got = file_pr_run_mutation_gate(
    project_dir,
    project_dir,
    @types.Role::Dev,
    "main.leaf",
    None,
    "feature/leaf-tdd-discipline",
    head,
    ["moon test --target native"],
    0.8,
    async fn(cmd : @workspace.Command) -> (Int, String) {
      @async.sleep(0)
      if cmd.program == "git" &&
        cmd.args == ["rev-parse", "--abbrev-ref", "HEAD"] {
        return (0, "main.leaf\n")
      }
      if cmd.program == "git" &&
        cmd.args ==
        ["diff", "--name-only", "feature/leaf-tdd-discipline..." + head] {
        return (0, "src/math.mbt\nsrc/math_test.mbt\n")
      }
      (0, "")
    },
    async fn(worker_args) {
      @async.sleep(0)
      Ok("main." + worker_args.slug)
    },
    async fn(_agent_id) {
      wait_calls = wait_calls + 1
      @async.sleep(10)
      None
    },
    fn(_) { cleanup_calls = cleanup_calls + 1 },
    2,
    fn() {
      let value = now_ms
      now_ms = now_ms + 1L
      value
    },
    sleep_fn=file_pr_test_no_sleep,
  )
  match got {
    Err(e) => {
      assert_true(e.is_timeout())
      assert_true(
        e
        .validation_detail_or_message()
        .contains("mutation gate budget exceeded"),
      )
    }
    Ok(_) => fail("expected mutation gate timeout")
  }
  assert_true(wait_calls > 0)
  assert_eq(cleanup_calls, 1)
}

///|
async test "file_pr_run_mutation_gate detects dead mutation worker promptly" {
  let project_dir = "/tmp/choir-fpr-mutation-worker-dead-" +
    @sys.get_pid().to_string()
  let head = "abcdef1234567890abcdef1234567890abcdef12"
  let mut cleanup_calls = 0
  let mut wait_calls = 0
  let got = file_pr_run_mutation_gate(
    project_dir,
    project_dir,
    @types.Role::Dev,
    "main.leaf",
    None,
    "feature/leaf-tdd-discipline",
    head,
    ["moon test --target native"],
    0.8,
    async fn(cmd : @workspace.Command) -> (Int, String) {
      @async.sleep(0)
      if cmd.program == "git" &&
        cmd.args == ["rev-parse", "--abbrev-ref", "HEAD"] {
        return (0, "main.leaf\n")
      }
      if cmd.program == "git" &&
        cmd.args ==
        ["diff", "--name-only", "feature/leaf-tdd-discipline..." + head] {
        return (0, "src/math.mbt\nsrc/math_test.mbt\n")
      }
      (0, "")
    },
    async fn(worker_args) {
      @async.sleep(0)
      Ok("main." + worker_args.slug)
    },
    async fn(_agent_id) {
      @async.sleep(0)
      wait_calls = wait_calls + 1
      None
    },
    fn(_) { cleanup_calls = cleanup_calls + 1 },
    1000,
    fn() { 123456789L },
    mutation_worker_alive=fn(_) { false },
  )
  match got {
    Err(e) => {
      assert_true(e.is_mutation_gate_incomplete())
      let msg = e.validation_detail_or_message()
      assert_true(msg.contains("[MUTATION GATE INCOMPLETE]"))
      assert_true(msg.contains("exited before report"))
    }
    Ok(_) => fail("expected dead worker to degrade as mutation gate incomplete")
  }
  assert_eq(wait_calls, 1)
  assert_eq(cleanup_calls, 1)
}

///|
async test "file_pr_run_mutation_gate lets queued report win over worker death" {
  let project_dir = "/tmp/choir-fpr-mutation-worker-dead-report-" +
    @sys.get_pid().to_string()
  let head = "abcdef1234567890abcdef1234567890abcdef12"
  let mut cleanup_calls = 0
  let mut wait_calls = 0
  let got = file_pr_run_mutation_gate(
    project_dir,
    project_dir,
    @types.Role::Dev,
    "main.leaf",
    None,
    "feature/leaf-tdd-discipline",
    head,
    ["moon test --target native"],
    0.8,
    async fn(cmd : @workspace.Command) -> (Int, String) {
      @async.sleep(0)
      if cmd.program == "git" &&
        cmd.args == ["rev-parse", "--abbrev-ref", "HEAD"] {
        return (0, "main.leaf\n")
      }
      if cmd.program == "git" &&
        cmd.args ==
        ["diff", "--name-only", "feature/leaf-tdd-discipline..." + head] {
        return (0, "src/math.mbt\nsrc/math_test.mbt\n")
      }
      (0, "")
    },
    async fn(worker_args) {
      @async.sleep(0)
      Ok("main." + worker_args.slug)
    },
    async fn(_agent_id) {
      @async.sleep(0)
      wait_calls = wait_calls + 1
      Some({
        message: mutation_gate_report_json_marker +
        " {\"kill_rate\":1.0,\"total_mutants\":1,\"killed_mutants\":0,\"surviving_mutants\":[\"src/math.mbt:7 + -> -\"],\"unsupported_languages\":[]}",
        status: @types.Status::Success,
      })
    },
    fn(_) { cleanup_calls = cleanup_calls + 1 },
    1000,
    fn() { 123456789L },
    mutation_worker_alive=fn(_) { false },
  )
  match got {
    Err(e) => {
      let msg = e.validation_detail_or_message()
      assert_true(msg.contains("mutation gate failed"))
      assert_true(msg.contains("src/math.mbt:7 + -> -"))
    }
    Ok(_) => fail("expected queued low-kill report to block file_pr")
  }
  assert_eq(wait_calls, 1)
  assert_eq(cleanup_calls, 1)
}

///|
async fn file_pr_test_run_mutation_gate_with_report(
  report_json : String,
) -> Result[Unit, @types.ChoirError] {
  let project_dir = "/tmp/choir-fpr-mutation-invalid-" +
    @sys.get_pid().to_string()
  let head = "abcdef1234567890abcdef1234567890abcdef12"
  file_pr_run_mutation_gate(
    project_dir,
    project_dir,
    @types.Role::Dev,
    "main.leaf",
    None,
    "feature/leaf-tdd-discipline",
    head,
    ["moon test --target native"],
    0.8,
    async fn(cmd : @workspace.Command) -> (Int, String) {
      @async.sleep(0)
      if cmd.program == "git" &&
        cmd.args == ["rev-parse", "--abbrev-ref", "HEAD"] {
        return (0, "main.leaf\n")
      }
      if cmd.program == "git" &&
        cmd.args ==
        ["diff", "--name-only", "feature/leaf-tdd-discipline..." + head] {
        return (0, "src/math.mbt\nsrc/math_test.mbt\n")
      }
      (0, "")
    },
    async fn(worker_args) {
      @async.sleep(0)
      Ok("main." + worker_args.slug)
    },
    async fn(_worker_id) {
      @async.sleep(0)
      Some({
        message: mutation_gate_report_json_marker + " " + report_json,
        status: @types.Status::Success,
      })
    },
    fn(_) {  },
    1000,
    fn() { 123456789L },
  )
}

///|
async test "file_pr_run_mutation_gate rejects invalid mutant counts" {
  let negative_total = file_pr_test_run_mutation_gate_with_report(
    "{\"kill_rate\":1.0,\"total_mutants\":-1,\"killed_mutants\":0,\"surviving_mutants\":[],\"unsupported_languages\":[]}",
  )
  match negative_total {
    Err(e) => {
      let msg = e.validation_detail_or_message()
      assert_true(msg.contains("invalid mutant counts"))
      assert_true(msg.contains("total_mutants=-1"))
      assert_true(msg.contains("refusing to trust kill rate"))
    }
    Ok(_) => fail("expected negative mutant count to block file_pr")
  }
  let killed_exceeds_total = file_pr_test_run_mutation_gate_with_report(
    "{\"kill_rate\":1.0,\"total_mutants\":2,\"killed_mutants\":3,\"surviving_mutants\":[],\"unsupported_languages\":[]}",
  )
  match killed_exceeds_total {
    Err(e) => {
      let msg = e.validation_detail_or_message()
      assert_true(msg.contains("invalid mutant counts"))
      assert_true(msg.contains("killed_mutants=3"))
      assert_true(msg.contains("must not exceed total_mutants"))
    }
    Ok(_) => fail("expected impossible killed-mutant count to block file_pr")
  }
}

///|
async test "interpret_file_pr degrades gracefully and cleans up on mutation spawn failure" {
  let project_dir = "/tmp/choir-fpr-mutation-spawn-cleanup-" +
    @sys.get_pid().to_string()
  let file_pr_dir = project_dir + "/.choir/worktrees/leaf"
  let head = "abcdef1234567890abcdef1234567890abcdef12"
  ignore(@sys.rm_rf(project_dir))
  let contract = file_pr_test_task_contract(["moon test --target native"])
  file_pr_test_write_verify_config(file_pr_dir, contract.verify)
  let reg = file_pr_test_registry(file_pr_dir)
  let prepared_workers : Array[String] = []
  let cleaned_workers : Array[String] = []
  let cleanup_paths : Array[String] = []
  let mut ensure_pr_called = false
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
    false,
    mock_preflight_ok,
    async fn(cmds : Array[@workspace.Command]) -> Array[Int] {
      @async.sleep(0)
      let statuses = []
      let mut saw_worktree_add = false
      let mut failed_after_worktree_add = false
      for cmd in cmds {
        if cmd.program == "git" &&
          cmd.args.length() == 4 &&
          cmd.args[0] == "worktree" &&
          cmd.args[1] == "remove" &&
          cmd.args[2] == "--force" {
          cleanup_paths.push(cmd.args[3])
        }
        if cmd.program == "git" &&
          cmd.args.length() == 6 &&
          cmd.args[0] == "worktree" &&
          cmd.args[1] == "add" {
          saw_worktree_add = true
          statuses.push(0)
        } else if saw_worktree_add && !failed_after_worktree_add {
          failed_after_worktree_add = true
          statuses.push(1)
        } else {
          statuses.push(0)
        }
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
        ["diff", "--name-only", "feature/leaf-tdd-discipline..." + head] {
        return (0, "src/math.mbt\nsrc/math_test.mbt\n")
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
    caller_role=@types.Role::TL,
    prepare_mutation_gate_report=fn(agent_id) {
      prepared_workers.push(agent_id)
    },
    wait_for_mutation_gate_report=async fn(_agent_id) {
      @async.sleep(0)
      fail("spawn failure must not wait for mutation report")
    },
    cleanup_mutation_gate_report=fn(agent_id) { cleaned_workers.push(agent_id) },
    mutation_gate_now_ms_fn=fn() { 1779000000L },
    record_verify_event=file_pr_test_record_verify_event(project_dir),
    task_contract_reader=file_pr_test_task_contract_reader(contract),
    tdd_phase_reader=file_pr_test_tdd_done,
    sleep_fn=file_pr_test_no_sleep,
  )
  match got {
    @types.Response::Err(msg) => {
      assert_true(msg.contains("[MUTATION GATE INCOMPLETE]"))
      assert_true(msg.contains("mutation gate worker spawn failed"))
      assert_true(msg.contains("failed (exit 1)"))
    }
    @types.Response::Ok(_) =>
      fail("mutation worker spawn failure should block file_pr")
  }
  assert_false(ensure_pr_called)
  assert_eq(prepared_workers.length(), 1)
  assert_eq(cleaned_workers.length(), 1)
  assert_eq(cleaned_workers[0], prepared_workers[0])
  assert_eq(cleanup_paths.length(), 1)
  assert_eq(
    cleanup_paths[0],
    @workspace.worktree_path(
      project_dir,
      @phase.extract_slug(prepared_workers[0]),
    ),
  )
  ignore(@sys.rm_rf(project_dir))
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
    false,
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
    false,
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
    false,
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
    false,
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
    false,
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
    pr_review=false,
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
async test "interpret_file_pr blocks before PR creation when mutation gate fails" {
  let project_dir = "/tmp/choir-fpr-mutation-block-" +
    @sys.get_pid().to_string()
  let file_pr_dir = project_dir + "/.choir/worktrees/leaf"
  let head = "abcdef1234567890abcdef1234567890abcdef12"
  ignore(@sys.rm_rf(project_dir))
  let contract = file_pr_test_task_contract(["moon test --target native"])
  file_pr_test_write_verify_config(file_pr_dir, contract.verify)
  let reg = file_pr_test_registry(file_pr_dir)
  let mut ensure_pr_called = false
  let prepared_workers : Array[String] = []
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
    false,
    mock_preflight_ok,
    mock_runner_all_ok,
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
        ["diff", "--name-only", "feature/leaf-tdd-discipline..." + head] {
        return (0, "src/math.mbt\nsrc/math_test.mbt\n")
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
    prepare_mutation_gate_report=fn(agent_id) {
      prepared_workers.push(agent_id)
    },
    wait_for_mutation_gate_report=async fn(_agent_id) {
      @async.sleep(0)
      Some({
        message: mutation_gate_report_json_marker +
        " {\"kill_rate\":1.0,\"total_mutants\":4,\"killed_mutants\":1,\"surviving_mutants\":[\"src/math.mbt:7 + -> -\"],\"unsupported_languages\":[]}",
        status: @types.Status::Success,
      })
    },
    mutation_gate_now_ms_fn=fn() { 1779000000L },
    record_verify_event=file_pr_test_record_verify_event(project_dir),
    task_contract_reader=file_pr_test_task_contract_reader(contract),
    tdd_phase_reader=file_pr_test_tdd_done,
    sleep_fn=file_pr_test_no_sleep,
  )
  match got {
    @types.Response::Err(msg) => {
      assert_true(msg.contains("mutation gate failed"))
      assert_true(msg.contains("src/math.mbt:7 + -> -"))
      assert_true(msg.contains("re-fix-tests"))
    }
    _ => fail("expected mutation gate failure")
  }
  assert_false(ensure_pr_called)
  assert_eq(prepared_workers.length(), 1)
  assert_true(prepared_workers[0].contains("mutation-gate-abcdef123456-"))
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "interpret_file_pr blocks when mutation gate does not report" {
  let project_dir = "/tmp/choir-fpr-mutation-timeout-gate-" +
    @sys.get_pid().to_string()
  let file_pr_dir = project_dir + "/.choir/worktrees/leaf"
  let head = "abcdef1234567890abcdef1234567890abcdef12"
  ignore(@sys.rm_rf(project_dir))
  let contract = file_pr_test_task_contract(["moon test --target native"])
  file_pr_test_write_verify_config(file_pr_dir, contract.verify)
  let reg = file_pr_test_registry(file_pr_dir)
  let mut ensure_pr_called = false
  let prepared_workers : Array[String] = []
  let cleaned_workers : Array[String] = []
  let spawn_paths : Array[String] = []
  let cleanup_paths : Array[String] = []
  let mut now_ms = 0L
  let mut wait_calls = 0
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
    false,
    mock_preflight_ok,
    async fn(cmds : Array[@workspace.Command]) -> Array[Int] {
      @async.sleep(0)
      let statuses = []
      for cmd in cmds {
        if cmd.program == "git" &&
          cmd.args.length() > 0 &&
          cmd.args[0] == "worktree" {
          if cmd.args.length() == 6 && cmd.args[1] == "add" {
            spawn_paths.push(cmd.args[2])
          }
          if cmd.args.length() == 4 {
            cleanup_paths.push(cmd.args[3])
          }
        }
        statuses.push(0)
      }
      statuses
    },
    async fn(cmd : @workspace.Command) -> (Int, String) {
      @async.sleep(0)
      if cmd.program == "git" && cmd.args == ["rev-parse", "HEAD"] {
        return (0, head + "\n")
      }
      if cmd.program == "git" &&
        cmd.args == ["rev-parse", "--abbrev-ref", "HEAD"] {
        return (0, "main.leaf\n")
      }
      if cmd.program == "git" &&
        cmd.args ==
        ["diff", "--name-only", "feature/leaf-tdd-discipline..." + head] {
        return (0, "src/math.mbt\nsrc/math_test.mbt\n")
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
    prepare_mutation_gate_report=fn(agent_id) {
      prepared_workers.push(agent_id)
    },
    wait_for_mutation_gate_report=async fn(_agent_id) {
      @async.sleep(0)
      wait_calls = wait_calls + 1
      None
    },
    cleanup_mutation_gate_report=fn(agent_id) { cleaned_workers.push(agent_id) },
    mutation_gate_budget_ms=1000,
    mutation_gate_now_ms_fn=fn() {
      now_ms = now_ms + 250L
      now_ms
    },
    record_verify_event=file_pr_test_record_verify_event(project_dir),
    task_contract_reader=file_pr_test_task_contract_reader(contract),
    tdd_phase_reader=file_pr_test_tdd_done,
    sleep_fn=file_pr_test_no_sleep,
  )
  match got {
    @types.Response::Err(msg) => {
      assert_true(msg.contains("[MUTATION GATE INCOMPLETE]"))
      assert_true(msg.contains("mutation gate worker did not report"))
    }
    @types.Response::Ok(_) => fail("mutation timeout should block file_pr")
  }
  assert_false(ensure_pr_called)
  assert_eq(prepared_workers.length(), 1)
  assert_eq(cleaned_workers.length(), 1)
  assert_eq(cleaned_workers[0], prepared_workers[0])
  assert_eq(spawn_paths.length(), 1)
  assert_eq(
    spawn_paths[0],
    @workspace.worktree_path(
      project_dir,
      @phase.extract_slug(prepared_workers[0]),
    ),
  )
  assert_false(spawn_paths[0] == project_dir)
  assert_eq(cleanup_paths.length(), 1)
  assert_true(
    cleanup_paths[0].has_prefix(
      @workspace.worktree_path(
        project_dir,
        @phase.extract_slug(prepared_workers[0]),
      ),
    ),
  )
  assert_true(wait_calls > 0)
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
    false,
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
    false,
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
    true,
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
