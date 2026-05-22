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
test "file_pr_plan formats audit incomplete notify once" {
  let args : FilePrArgs = {
    branch: "main.task-leaf",
    parent_branch: Some("main"),
    tracked_agent_id: "main.task-leaf",
    title: None,
    body: None,
    review_context: None,
  }
  let pr : PullRequestInfo = {
    number: 10,
    url: "https://example.test/pr/10",
    state: "OPEN",
  }
  let plan = file_pr_plan(
    args,
    "main",
    pr,
    true,
    audit_incomplete=Some({ error: "audit budget exceeded" }),
  )
  assert_eq(
    plan.notify_message,
    "[PR READY] PR #10 filed: https://example.test/pr/10\n[AUDIT INCOMPLETE] audit budget exceeded; PR filed; run `/audit` on this branch, then retry the audit receipt gate.",
  )
  assert_false(plan.notify_message.contains("audit incomplete:"))
  match plan.response {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      @debug.assert_eq(
        map.get("warning"),
        Some(
          String::to_json(
            "audit budget exceeded; PR filed; run `/audit` on this branch, then retry the audit receipt gate.",
          ),
        ),
      )
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
fn file_pr_test_audit_receipt(sha : String) -> String {
  file_pr_test_audit_receipt_with_findings(sha, 0)
}

///|
fn file_pr_test_audit_receipt_with_findings(
  sha : String,
  findings_count : Int,
) -> String {
  file_pr_test_audit_receipt_for_branch(
    sha, "feature/discipline-gates", findings_count,
  )
}

///|
fn file_pr_test_audit_receipt_for_branch(
  sha : String,
  branch : String,
  findings_count : Int,
) -> String {
  let receipt : @types.AuditReceipt = {
    sha,
    branch,
    audited_at: 1770000000L,
    agent_id: "main.tl",
    findings_count,
  }
  receipt.to_json().stringify() + "\n"
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
test "parse_findings_count counts finding markers" {
  assert_eq(parse_findings_count("Finding 1: bad\n\nFinding 12: also bad\n"), 2)
  assert_eq(parse_findings_count("No findings."), 0)
  assert_eq(parse_findings_count("findings_count=0"), 0)
  assert_eq(parse_findings_count(""), 0)
}

///|
test "audit worker task pins review surface to audited head" {
  let head = "abcdef1234567890abcdef1234567890abcdef12"
  let task = build_audit_on_file_pr_task("/repo", "main.leaf", head)
  assert_true(task.contains("Review surface: `git diff main..." + head + "`"))
  assert_false(task.contains("git diff main...HEAD"))
}

///|
test "audit worker task can scope retry to prior audited delta" {
  let prior = "1111111111111111111111111111111111111111"
  let head = "abcdef1234567890abcdef1234567890abcdef12"
  let task = build_audit_on_file_pr_task(
    "/repo",
    "main.leaf",
    head,
    prior_sha=Some(prior),
  )
  assert_true(
    task.contains("Review surface: `git diff " + prior + "..." + head + "`"),
  )
  assert_true(
    task.contains("audit only the changes between prior_sha and current_head"),
  )
  assert_false(task.contains("Review surface: `git diff main..." + head + "`"))
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
async test "file_pr_run_mutation_gate computes kill rate from mutant counts" {
  let project_dir = "/tmp/choir-fpr-mutation-low-" + @sys.get_pid().to_string()
  let head = "abcdef1234567890abcdef1234567890abcdef12"
  let mut spawned_slug = ""
  let mut waited_worker = ""
  let mut cleanup_calls = 0
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
    fn(_) { cleanup_calls = cleanup_calls + 1 },
    1000,
    fn() { 123456789L },
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
  assert_eq(cleanup_calls, 0)
  assert_eq(spawned_slug, mutation_gate_worker_slug(head, 123456789L))
  assert_eq(waited_worker, "main." + spawned_slug)
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
    fn(_) { () },
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
async test "interpret_file_pr cleans prepared mutation report on spawn failure" {
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
      for _ in cmds {
        statuses.push(1)
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
    @types.Response::Err(msg) => assert_true(msg.contains("failed (exit 1)"))
    @types.Response::Ok(_) => fail("expected mutation worker spawn failure")
  }
  assert_false(ensure_pr_called)
  assert_eq(prepared_workers.length(), 1)
  assert_eq(cleaned_workers.length(), 1)
  assert_eq(cleaned_workers[0], prepared_workers[0])
  ignore(@sys.rm_rf(project_dir))
}

///|
test "find_prior_branch_audit_receipt returns none for empty dir" {
  @debug.assert_eq(
    find_prior_branch_audit_receipt("/receipts", "feature/a", fn(_) { [] }),
    None,
  )
}

///|
test "find_prior_branch_audit_receipt returns one receipt for branch" {
  @debug.assert_eq(
    find_prior_branch_audit_receipt("/receipts", "feature/a", fn(_) {
      ["100\tsha-one\tfeature/a"]
    }),
    Some("sha-one"),
  )
}

///|
test "find_prior_branch_audit_receipt picks newest mtime" {
  @debug.assert_eq(
    find_prior_branch_audit_receipt("/receipts", "feature/a", fn(_) {
      [
        "100\tsha-old\tfeature/a", "300\tsha-new\tfeature/a", "200\tsha-mid\tfeature/a",
      ]
    }),
    Some("sha-new"),
  )
}

///|
test "find_prior_branch_audit_receipt uses subsecond mtime" {
  @debug.assert_eq(
    find_prior_branch_audit_receipt("/receipts", "feature/a", fn(_) {
      [
        "300.1000000000\tsha-old\tfeature/a", "300.9000000000\tsha-new\tfeature/a",
        "299.9999999999\tsha-prev\tfeature/a",
      ]
    }),
    Some("sha-new"),
  )
}

///|
test "find_prior_branch_audit_receipt breaks equal mtime ties by sha" {
  @debug.assert_eq(
    find_prior_branch_audit_receipt("/receipts", "feature/a", fn(_) {
      [
        "300.9000000000\tbbbb\tfeature/a", "300.9000000000\taaaa\tfeature/a", "300.9000000000\tcccc\tfeature/a",
      ]
    }),
    Some("cccc"),
  )
}

///|
test "find_prior_branch_audit_receipt ignores different branch" {
  @debug.assert_eq(
    find_prior_branch_audit_receipt("/receipts", "feature/a", fn(_) {
      ["400\tsha-other\tfeature/b"]
    }),
    None,
  )
}

///|
test "audit_delta_numstat_lines sums additions and deletions" {
  @debug.assert_eq(
    audit_delta_numstat_lines("3\t2\tsrc/a.mbt\n0\t4\tsrc/b.mbt\n"),
    Some(9),
  )
  @debug.assert_eq(audit_delta_numstat_lines("-\t-\tasset.bin\n"), None)
}

///|
test "audit_on_file_pr_worker_slug appends supplied now_ms" {
  let head = "abcdef1234567890abcdef1234567890abcdef12"
  let first = audit_on_file_pr_worker_slug(head, 1L)
  let second = audit_on_file_pr_worker_slug(head, 2L)
  assert_eq(first, "audit-on-file-pr-abcdef123456-1")
  assert_eq(second, "audit-on-file-pr-abcdef123456-2")
  assert_true(first != second)
  assert_true(first.has_prefix(audit_on_file_pr_slug_prefix(head)))
  assert_true(second.has_prefix(audit_on_file_pr_slug_prefix(head)))
}

///|
test "audit_on_file_pr_slug_prefix omits timestamp suffix" {
  let head = "abcdef1234567890abcdef1234567890abcdef12"
  assert_eq(
    audit_on_file_pr_slug_prefix(head),
    "audit-on-file-pr-abcdef123456-",
  )
}

///|
fn file_pr_test_tdd_done(_agent_id : String) -> @types.LeafTddPhase? {
  Some(@types.LeafTddPhase::Done)
}

///|
test "file_pr TDD guard fails closed for dev leaves" {
  match
    file_pr_require_tdd_done(@types.Role::Dev, "main.leaf", None, fn(_) { None }) {
    Err(e) =>
      assert_true(e.message().contains("no TDD phase has been recorded"))
    Ok(_) => fail("expected missing TDD phase to block file_pr")
  }
  match
    file_pr_require_tdd_done(@types.Role::Dev, "main.leaf", None, fn(_) {
      Some(@types.LeafTddPhase::Done)
    }) {
    Ok(_) => ()
    Err(e) => fail("expected done TDD phase to allow file_pr: " + e.message())
  }
  let reg = file_pr_test_registry("/tmp/choir-file-pr-tdd-registry")
  match
    file_pr_require_tdd_done(@types.Role::TL, "main.leaf", Some(reg), fn(_) {
      Some(@types.LeafTddPhase::Green)
    }) {
    Err(e) => assert_true(e.message().contains("current phase is green"))
    Ok(_) => fail("expected tracked Dev leaf to block even for TL caller")
  }
  match
    file_pr_require_tdd_done(@types.Role::TL, "main.tl", Some(reg), fn(_) {
      None
    }) {
    Ok(_) => ()
    Err(e) =>
      fail("expected TL file_pr to bypass leaf TDD gate: " + e.message())
  }
}

///|
fn file_pr_test_audit_child(
  slug : String,
  summary : @phase.ChildLifecycleSummary,
) -> @phase.ChildLifecycle {
  {
    child_id: "main." + slug,
    slug,
    branch: "main." + slug,
    agent_type: @types.AgentType::Codex,
    summary,
  }
}

///|
test "find_in_flight_audit_worker returns first non-terminal prefix match" {
  let prefix = audit_on_file_pr_slug_prefix("abcdef1234567890")
  let matching = file_pr_test_audit_child(
    prefix + "111",
    @phase.ChildLifecycleSummary::Working,
  )
  let later = file_pr_test_audit_child(
    prefix + "222",
    @phase.ChildLifecycleSummary::ReviewOwned(
      pr_number=7,
      state=@phase.ReviewOwnership::OpenUnreviewed(url="https://example/pr/7"),
    ),
  )
  match find_in_flight_audit_worker([matching, later], prefix) {
    Some(entry) => assert_eq(entry.child_id, matching.child_id)
    None => fail("expected in-flight audit worker")
  }
}

///|
test "find_in_flight_audit_worker ignores terminal prefix matches" {
  let prefix = audit_on_file_pr_slug_prefix("abcdef1234567890")
  let done = file_pr_test_audit_child(
    prefix + "111",
    @phase.ChildLifecycleSummary::Done,
  )
  let failed = file_pr_test_audit_child(
    prefix + "222",
    @phase.ChildLifecycleSummary::Failed(
      reason=@phase.FailureReason::RecoveredFailed,
    ),
  )
  let exitable = file_pr_test_audit_child(
    prefix + "333",
    @phase.ChildLifecycleSummary::Exitable,
  )
  match find_in_flight_audit_worker([done, failed, exitable], prefix) {
    None => ()
    Some(entry) => fail("expected terminal entries ignored: " + entry.child_id)
  }
}

///|
test "find_in_flight_audit_worker returns none without prefix match" {
  let prefix = audit_on_file_pr_slug_prefix("abcdef1234567890")
  let other = file_pr_test_audit_child(
    "audit-on-file-pr-fedcba654321-111",
    @phase.ChildLifecycleSummary::Working,
  )
  match find_in_flight_audit_worker([other], prefix) {
    None => ()
    Some(entry) => fail("expected no prefix match: " + entry.child_id)
  }
}

///|
test "audit_heartbeat_log_line formats status variants" {
  assert_eq(
    audit_heartbeat_log_line(42, "main.leaf", 60L),
    "audit-on-file-pr pr=42 agent=main.leaf elapsed_s=60 status=running",
  )
  assert_eq(
    audit_heartbeat_log_line(0, "main.leaf", 60L, branch=Some("main.leaf")),
    "audit-on-file-pr pr=pending agent=main.leaf branch=main.leaf elapsed_s=60 status=running",
  )
  assert_eq(
    audit_heartbeat_log_line(
      42,
      "main.leaf",
      180L,
      status=HeartbeatOk,
      findings_count=Some(2),
    ),
    "audit-on-file-pr pr=42 agent=main.leaf elapsed_s=180 status=ok findings_count=2",
  )
  assert_eq(
    audit_heartbeat_log_line(
      42,
      "main.leaf",
      180L,
      status=HeartbeatError,
      reason=Some("timeout"),
    ),
    "audit-on-file-pr pr=42 agent=main.leaf elapsed_s=180 status=error reason=timeout",
  )
}

///|
test "audit_heartbeat_log_line strips terminal responses but preserves SGR" {
  let line = audit_heartbeat_log_line(
    42,
    "main.leaf\u{1b}[?62;4;52c",
    180L,
    status=HeartbeatError,
    reason=Some(
      "bad \u{1b}]11;rgb:0a0a/0f0f/1414\u{1b}\\\u{1b}[31mred\u{1b}[0m",
    ),
    branch=Some("feature\u{1b}[61;1R"),
  )
  assert_eq(
    line, "audit-on-file-pr pr=42 agent=main.leaf branch=feature elapsed_s=180 status=error reason=bad \u{1b}[31mred\u{1b}[0m",
  )
}

///|
async test "dispatch shutdown from audit worker completes audit wait queue" {
  let reg = @registry.AgentRegistry::new()
  ignore(
    reg.upsert({
      agent_id: @types.AgentId("main.audit-on-file-pr-shutdown"),
      role: @types.Role::Worker,
      agent_type: @types.AgentType::Codex,
      parent: Some(audit_on_file_pr_internal_caller_id),
      workspace: "/tmp/choir-audit-worker",
      branch: "main.audit-worker",
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  let reports : Array[(String, AuditOnFilePrReport)] = []
  let resp = dispatch(
    ToolRequest::Shutdown({ caller_id: Some("main.audit-on-file-pr-shutdown") }),
    project_dir="/tmp/choir-audit-shutdown",
    registry=Some(reg),
    runner=mock_runner_all_ok,
    bd_capture=mock_capture_empty,
    capture_audit_on_file_pr_report=async fn(agent_id, report) {
      @async.sleep(0)
      reports.push((agent_id, report))
    },
  )
  assert_true(resp.is_ok())
  assert_eq(reports.length(), 1)
  let (agent_id, report) = reports[0]
  assert_eq(agent_id, "main.audit-on-file-pr-shutdown")
  assert_eq(report.status, @types.Status::Failure)
  assert_true(report.message.contains("shutdown"))
}

///|
async test "dispatch notify_parent from failed audit worker does not capture stale report" {
  let reg = @registry.AgentRegistry::new()
  let worker_id = "main.audit-on-file-pr-timeout"
  ignore(
    reg.upsert({
      agent_id: @types.AgentId(worker_id),
      role: @types.Role::Worker,
      agent_type: @types.AgentType::Codex,
      parent: Some(audit_on_file_pr_internal_caller_id),
      workspace: "/tmp/choir-audit-worker",
      branch: "main.audit-worker",
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Failed,
    }),
  )
  ignore(reg.set_alive(worker_id, false))
  let reports : Array[(String, AuditOnFilePrReport)] = []
  let resp = dispatch(
    ToolRequest::NotifyParent({
      caller_id: worker_id,
      message: "No findings.",
      status: @types.Status::Success,
    }),
    project_dir="/tmp/choir-audit-timeout-stale-report",
    registry=Some(reg),
    runner=mock_runner_all_ok,
    capture_audit_on_file_pr_report=async fn(agent_id, report) {
      @async.sleep(0)
      reports.push((agent_id, report))
    },
  )
  match resp {
    @types.Response::Err(_) => ()
    @types.Response::Ok(_) => fail("stale failed worker report must not notify")
  }
  assert_eq(reports.length(), 0)
}

///|
fn file_pr_auto_audit_capture(
  head : String,
  receipt_body : String?,
) -> async (@workspace.Command) -> (Int, String) {
  async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    if cmd.program == "git" && cmd.args == ["rev-parse", "HEAD"] {
      return (0, head + "\n")
    }
    if cmd.program == "git" && cmd.args == ["rev-parse", "--abbrev-ref", "HEAD"] {
      return (0, "feature/auto-audit\n")
    }
    if cmd.program == "git" &&
      cmd.args == ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"] {
      return (0, "origin/main\n")
    }
    if cmd.program == "cat" {
      match receipt_body {
        Some(body) => return (0, body)
        None => return (1, "")
      }
    }
    (0, "")
  }
}

///|
fn file_pr_audit_heartbeat_log_count(log : String, needle : String) -> Int {
  let mut count = 0
  for line in log.split("\n") {
    if line.contains(needle) {
      count = count + 1
    }
  }
  count
}

///|
fn assert_file_pr_audit_incomplete_response(
  resp : @types.Response,
  detail : String,
) -> Unit raise {
  match resp {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      @debug.assert_eq(
        map.get("audit_status"),
        Some(String::to_json("incomplete")),
      )
      @debug.assert_eq(map.get("audit_retryable"), Some(Bool::to_json(true)))
      match map.get("audit_error") {
        Some(Json::String(msg)) => assert_true(msg.contains(detail))
        _ => fail("expected audit_error")
      }
    }
    @types.Response::Err(msg) =>
      fail("audit incomplete must not hard-abort file_pr: " + msg)
  }
}

///|
fn file_pr_test_write_audit_receipt_ok(
  _args : WriteAuditReceiptArgs,
) -> @types.Response {
  @types.Response::ok_values({ "status": String::to_json("ok") })
}

///|
async test "file_pr_auto_audit short-circuits valid receipt without spawn or wait" {
  let project_dir = "/tmp/choir-fpr-auto-audit-short-circuit-" +
    @sys.get_pid().to_string()
  let head = "abcdef1234567890abcdef1234567890abcdef12"
  let appended : Array[String] = []
  let mut spawn_calls = 0
  let mut wait_calls = 0
  let mut cleanup_calls = 0
  let mut receipt_write_calls = 0
  let got = file_pr_auto_audit_for_missing_receipt(
    project_dir,
    project_dir,
    "feature/auto-audit",
    "main",
    head,
    file_pr_auto_audit_capture(head, Some(file_pr_test_audit_receipt(head))),
    async fn(_) {
      @async.sleep(0)
      spawn_calls = spawn_calls + 1
      Err(@types.ChoirError::validation_error("unexpected spawn"))
    },
    async fn(_) {
      @async.sleep(0)
      wait_calls = wait_calls + 1
      None
    },
    fn(_) { cleanup_calls = cleanup_calls + 1 },
    fn(_) {
      receipt_write_calls = receipt_write_calls + 1
      @types.Response::Err("unexpected write")
    },
    1000,
    0,
    fn(_path, content) {
      appended.push(content)
      true
    },
    async fn(_) { @async.sleep(0) },
    fn() { 1234L },
    fn(_) { true },
  )
  match got {
    Ok(_) => ()
    Err(e) => fail("expected valid receipt short-circuit: " + e.message())
  }
  assert_eq(spawn_calls, 0)
  assert_eq(wait_calls, 0)
  assert_eq(cleanup_calls, 0)
  assert_eq(receipt_write_calls, 0)
  let log = appended.join("")
  assert_true(log.contains("file_pr_auto_audit outcome=receipt_present"))
}

///|
async test "file_pr_auto_audit awaits existing in-flight worker without spawning" {
  let project_dir = "/tmp/choir-fpr-auto-audit-in-flight-" +
    @sys.get_pid().to_string()
  let head = "abcdef1234567890abcdef1234567890abcdef12"
  let prefix = audit_on_file_pr_slug_prefix(head)
  let existing = file_pr_test_audit_child(
    prefix + "111",
    @phase.ChildLifecycleSummary::Working,
  )
  let appended : Array[String] = []
  let mut spawn_calls = 0
  let mut waited_worker = ""
  let mut cleanup_calls = 0
  let got = file_pr_auto_audit_for_missing_receipt(
    project_dir,
    project_dir,
    "feature/auto-audit",
    "main",
    head,
    file_pr_auto_audit_capture(head, None),
    async fn(_) {
      @async.sleep(0)
      spawn_calls = spawn_calls + 1
      Err(@types.ChoirError::validation_error("unexpected spawn"))
    },
    async fn(worker_id) {
      @async.sleep(0)
      waited_worker = worker_id
      Some({ message: "No findings.", status: @types.Status::Success })
    },
    fn(_) { cleanup_calls = cleanup_calls + 1 },
    file_pr_test_write_audit_receipt_ok,
    1000,
    0,
    fn(_path, content) {
      appended.push(content)
      true
    },
    async fn(_) { @async.sleep(0) },
    fn() { 5678L },
    fn(_) { true },
    list_audit_workers=fn() { [existing] },
  )
  match got {
    Ok(_) => ()
    Err(e) => fail("expected in-flight audit success: " + e.message())
  }
  assert_eq(spawn_calls, 0)
  assert_eq(cleanup_calls, 0)
  assert_eq(waited_worker, existing.child_id)
  let log = appended.join("")
  assert_true(
    log.contains(
      "file_pr_auto_audit outcome=awaiting_in_flight worker=" +
      existing.child_id,
    ),
  )
}

///|
async test "file_pr_auto_audit does not record a new cycle when awaiting in-flight worker" {
  let project_dir = "/tmp/choir-fpr-auto-audit-in-flight-cycle-" +
    @sys.get_pid().to_string()
  let head = "abcdef1234567890abcdef1234567890abcdef12"
  let prefix = audit_on_file_pr_slug_prefix(head)
  let existing = file_pr_test_audit_child(
    prefix + "111",
    @phase.ChildLifecycleSummary::Working,
  )
  let mut cycles = 0
  let recorded_agents : Array[String] = []
  let waited_workers : Array[String] = []
  let mut spawn_calls = 0
  let run_cycle = async fn(in_flight : Bool) -> Unit {
    let got = file_pr_auto_audit_for_missing_receipt(
      project_dir,
      project_dir,
      "feature/auto-audit",
      "main",
      head,
      file_pr_auto_audit_capture(head, None),
      async fn(worker_args) {
        @async.sleep(0)
        spawn_calls = spawn_calls + 1
        Ok("main." + worker_args.slug)
      },
      async fn(worker_id) {
        @async.sleep(0)
        waited_workers.push(worker_id)
        Some({ message: "No findings.", status: @types.Status::Success })
      },
      fn(_) {  },
      file_pr_test_write_audit_receipt_ok,
      1000,
      0,
      fn(_, _) { true },
      async fn(_) { @async.sleep(0) },
      fn() { 1779000000L },
      fn(_) { true },
      list_audit_workers=fn() { if in_flight { [existing] } else { [] } },
      record_audit_cycle_for_agent=fn(agent_id) {
        recorded_agents.push(agent_id)
        cycles = cycles + 1
        cycles
      },
      audit_cycle_count_for_agent=fn(_) { cycles },
    )
    match got {
      Ok(_) => ()
      Err(e) => fail("expected audit success: " + e.message())
    }
  }
  run_cycle(false)
  run_cycle(true)
  assert_eq(spawn_calls, 1)
  assert_eq(cycles, 1)
  @debug.assert_eq(recorded_agents, ["feature/auto-audit"])
  assert_eq(waited_workers.length(), 2)
  assert_eq(waited_workers[1], existing.child_id)
}

///|
async test "in-flight reuse with stale cycle counter persists clamp to ServerState" {
  let project_dir = "/tmp/choir-fpr-auto-audit-in-flight-zero-cycle-" +
    @sys.get_pid().to_string()
  let head = "abcdef1234567890abcdef1234567890abcdef12"
  let prefix = audit_on_file_pr_slug_prefix(head)
  let existing = file_pr_test_audit_child(
    prefix + "111",
    @phase.ChildLifecycleSummary::Working,
  )
  let mut spawn_calls = 0
  let mut record_calls = 0
  let mut server_state_cycles = 0
  let cycle_reads : Array[Int] = []
  let recorded_agents : Array[String] = []
  let got = file_pr_auto_audit_for_missing_receipt(
    project_dir,
    project_dir,
    "feature/auto-audit",
    "main",
    head,
    file_pr_auto_audit_capture(head, None),
    async fn(_) {
      @async.sleep(0)
      spawn_calls = spawn_calls + 1
      Err(@types.ChoirError::validation_error("unexpected spawn"))
    },
    async fn(worker_id) {
      @async.sleep(0)
      assert_eq(worker_id, existing.child_id)
      Some({
        message: "Finding 1: still broken\n",
        status: @types.Status::Success,
      })
    },
    fn(_) {  },
    file_pr_test_write_audit_receipt_ok,
    1000,
    0,
    fn(_, _) { true },
    async fn(_) { @async.sleep(0) },
    fn() { 1779000000L },
    fn(_) { true },
    list_audit_workers=fn() { [existing] },
    audit_max_rounds=1,
    record_audit_cycle_for_agent=fn(agent_id) {
      recorded_agents.push(agent_id)
      record_calls = record_calls + 1
      server_state_cycles = server_state_cycles + 1
      server_state_cycles
    },
    audit_cycle_count_for_agent=fn(_) {
      cycle_reads.push(server_state_cycles)
      server_state_cycles
    },
  )
  match got {
    Err(e) => {
      assert_eq(e.to_wire_string(), "audit_loop_exhausted")
      assert_true(e.message().contains("audit loop exhausted after 1 cycle(s)"))
      assert_false(e.message().contains("after 0 cycle(s)"))
    }
    Ok(_) => fail("expected in-flight audit exhaustion")
  }
  assert_eq(spawn_calls, 0)
  assert_eq(record_calls, 1)
  assert_eq(server_state_cycles, 1)
  @debug.assert_eq(cycle_reads, [0])
  @debug.assert_eq(recorded_agents, ["feature/auto-audit"])
}

///|
async test "file_pr_auto_audit records one cycle for each fresh audit spawn" {
  let project_dir = "/tmp/choir-fpr-auto-audit-fresh-cycle-" +
    @sys.get_pid().to_string()
  let head = "abcdef1234567890abcdef1234567890abcdef12"
  let mut cycles = 0
  let recorded_agents : Array[String] = []
  let spawned_workers : Array[String] = []
  let run_cycle = async fn(now_ms : Int64) -> Unit {
    let got = file_pr_auto_audit_for_missing_receipt(
      project_dir,
      project_dir,
      "feature/auto-audit",
      "main",
      head,
      file_pr_auto_audit_capture(head, None),
      async fn(worker_args) {
        @async.sleep(0)
        let worker_id = "main." + worker_args.slug
        spawned_workers.push(worker_id)
        Ok(worker_id)
      },
      async fn(_) {
        @async.sleep(0)
        Some({ message: "No findings.", status: @types.Status::Success })
      },
      fn(_) {  },
      file_pr_test_write_audit_receipt_ok,
      1000,
      0,
      fn(_, _) { true },
      async fn(_) { @async.sleep(0) },
      fn() { now_ms },
      fn(_) { true },
      list_audit_workers=fn() { [] },
      record_audit_cycle_for_agent=fn(agent_id) {
        recorded_agents.push(agent_id)
        cycles = cycles + 1
        cycles
      },
      audit_cycle_count_for_agent=fn(_) { cycles },
    )
    match got {
      Ok(_) => ()
      Err(e) => fail("expected audit success: " + e.message())
    }
  }
  run_cycle(1779000000L)
  run_cycle(1779000001L)
  assert_eq(cycles, 2)
  assert_eq(spawned_workers.length(), 2)
  assert_true(spawned_workers[0] != spawned_workers[1])
  @debug.assert_eq(recorded_agents, ["feature/auto-audit", "feature/auto-audit"])
}

///|
async test "file_pr_auto_audit cap without report fails without fabricated zero findings" {
  let project_dir = "/tmp/choir-fpr-auto-audit-timeout-cap-" +
    @sys.get_pid().to_string()
  let head = "abcdef1234567890abcdef1234567890abcdef12"
  let mut spawn_calls = 0
  let mut wait_calls = 0
  let mut record_calls = 0
  let got = file_pr_auto_audit_for_missing_receipt(
    project_dir,
    project_dir,
    "feature/auto-audit",
    "main",
    head,
    file_pr_auto_audit_capture(head, None),
    async fn(worker_args) {
      @async.sleep(0)
      spawn_calls = spawn_calls + 1
      Ok("main." + worker_args.slug)
    },
    async fn(_) {
      @async.sleep(0)
      wait_calls = wait_calls + 1
      None
    },
    fn(_) {  },
    file_pr_test_write_audit_receipt_ok,
    1000,
    0,
    fn(_, _) { true },
    async fn(_) { @async.sleep(0) },
    fn() { 1779000000L },
    fn(_) { true },
    list_audit_workers=fn() { [] },
    audit_max_rounds=3,
    record_audit_cycle_for_agent=fn(_) {
      record_calls = record_calls + 1
      99
    },
    audit_cycle_count_for_agent=fn(_) { 3 },
  )
  match got {
    Err(e) => {
      assert_eq(e.to_wire_string(), "audit_incomplete")
      assert_true(e.message().contains("audit worker did not report"))
      assert_false(e.message().contains("0 finding(s) remaining"))
    }
    Ok(_) => fail("expected missing audit report failure")
  }
  assert_eq(spawn_calls, 1)
  assert_eq(wait_calls, 1)
  assert_eq(record_calls, 0)
}

///|
async test "file_pr_auto_audit cap hit with zero findings writes receipt" {
  let project_dir = "/tmp/choir-fpr-auto-audit-cap-clean-" +
    @sys.get_pid().to_string()
  let head = "abcdef1234567890abcdef1234567890abcdef12"
  let mut spawn_calls = 0
  let mut wait_calls = 0
  let mut record_calls = 0
  let mut clear_calls = 0
  let mut cleared_agent = ""
  let mut receipt_dir = ""
  let mut receipt_path = ""
  let mut receipt_content = ""
  let got = file_pr_auto_audit_for_missing_receipt(
    project_dir,
    project_dir,
    "feature/auto-audit",
    "main",
    head,
    file_pr_auto_audit_capture(head, None),
    async fn(worker_args) {
      @async.sleep(0)
      spawn_calls = spawn_calls + 1
      Ok("main." + worker_args.slug)
    },
    async fn(worker_id) {
      @async.sleep(0)
      wait_calls = wait_calls + 1
      assert_true(worker_id.contains(audit_on_file_pr_internal_caller_id))
      Some({
        message: "No findings. The audit converged cleanly.\n",
        status: @types.Status::Success,
      })
    },
    fn(_) {  },
    fn(args) {
      interpret_write_audit_receipt(
        args,
        project_dir,
        fn(path) {
          receipt_dir = path
          true
        },
        fn(path, content) {
          receipt_path = path
          receipt_content = content
          true
        },
        now_sec=fn() { 1770000000L },
      )
    },
    1000,
    0,
    fn(_, _) { true },
    async fn(_) { @async.sleep(0) },
    fn() { 1779000000L },
    fn(_) { true },
    audit_max_rounds=3,
    record_audit_cycle_for_agent=fn(_) {
      record_calls = record_calls + 1
      99
    },
    audit_cycle_count_for_agent=fn(_) { 3 },
    clear_audit_cycle_for_agent=fn(agent_id) {
      cleared_agent = agent_id
      clear_calls = clear_calls + 1
    },
  )
  match got {
    Ok(_) => ()
    Err(e) => fail("expected clean cap-hit audit to pass: " + e.message())
  }
  assert_eq(spawn_calls, 1)
  assert_eq(wait_calls, 1)
  assert_eq(record_calls, 0)
  assert_eq(clear_calls, 1)
  assert_eq(cleared_agent, "feature/auto-audit")
  assert_true(receipt_dir.has_suffix("/.choir/audit-receipts"))
  assert_true(
    receipt_path.has_suffix("/.choir/audit-receipts/abcdef123456.json"),
  )
  let parsed_receipt = @json.parse(receipt_content) catch {
    _ => fail("receipt did not parse")
  }
  let decoded : @types.AuditReceipt = @json.from_json(parsed_receipt) catch {
    _ => fail("receipt did not decode")
  }
  assert_eq(decoded.sha, head)
  assert_eq(decoded.branch, "feature/auto-audit")
  assert_eq(decoded.agent_id, audit_on_file_pr_internal_caller_id)
  assert_eq(decoded.findings_count, 0)
}

///|
async test "file_pr_auto_audit cap hit with findings stays blocked" {
  let project_dir = "/tmp/choir-fpr-auto-audit-cap-findings-" +
    @sys.get_pid().to_string()
  let head = "abcdef1234567890abcdef1234567890abcdef12"
  let mut spawn_calls = 0
  let mut wait_calls = 0
  let mut receipt_write_calls = 0
  let got = file_pr_auto_audit_for_missing_receipt(
    project_dir,
    project_dir,
    "feature/auto-audit",
    "main",
    head,
    file_pr_auto_audit_capture(head, None),
    async fn(worker_args) {
      @async.sleep(0)
      spawn_calls = spawn_calls + 1
      Ok("main." + worker_args.slug)
    },
    async fn(worker_id) {
      @async.sleep(0)
      wait_calls = wait_calls + 1
      assert_true(worker_id.contains(audit_on_file_pr_internal_caller_id))
      Some({
        message: "Finding 1: still broken at the cap\n",
        status: @types.Status::Success,
      })
    },
    fn(_) {  },
    fn(_) {
      receipt_write_calls = receipt_write_calls + 1
      @types.Response::Err("unexpected receipt write")
    },
    1000,
    0,
    fn(_, _) { true },
    async fn(_) { @async.sleep(0) },
    fn() { 1779000000L },
    fn(_) { true },
    audit_max_rounds=3,
    record_audit_cycle_for_agent=fn(_) { 99 },
    audit_cycle_count_for_agent=fn(_) { 3 },
  )
  match got {
    Err(e) => {
      assert_eq(e.to_wire_string(), "audit_loop_exhausted")
      assert_true(e.message().contains("after 3 cycle(s)"))
      assert_true(e.message().contains("1 finding(s) remaining"))
      assert_true(
        e.message().contains(".choir/audit-receipts/abcdef123456.json"),
      )
    }
    Ok(_) => fail("expected cap-hit findings to block")
  }
  assert_eq(spawn_calls, 1)
  assert_eq(wait_calls, 1)
  assert_eq(receipt_write_calls, 0)
}

///|
async test "file_pr_auto_audit spawns fresh worker with now_ms suffix" {
  let project_dir = "/tmp/choir-fpr-auto-audit-fresh-spawn-" +
    @sys.get_pid().to_string()
  let head = "abcdef1234567890abcdef1234567890abcdef12"
  let now_ms = 123456789L
  let mut spawn_calls = 0
  let mut spawned_slug = ""
  let mut spawned_task = ""
  let mut waited_worker = ""
  let mut cleanup_calls = 0
  let got = file_pr_auto_audit_for_missing_receipt(
    project_dir,
    project_dir,
    "feature/auto-audit",
    "main",
    head,
    file_pr_auto_audit_capture(head, None),
    async fn(worker_args) {
      @async.sleep(0)
      spawn_calls = spawn_calls + 1
      spawned_slug = worker_args.slug
      spawned_task = worker_args.task
      Ok("main." + worker_args.slug)
    },
    async fn(worker_id) {
      @async.sleep(0)
      waited_worker = worker_id
      Some({ message: "No findings.", status: @types.Status::Success })
    },
    fn(_) { cleanup_calls = cleanup_calls + 1 },
    file_pr_test_write_audit_receipt_ok,
    1000,
    0,
    fn(_, _) { true },
    async fn(_) { @async.sleep(0) },
    fn() { now_ms },
    fn(_) { true },
  )
  match got {
    Ok(_) => ()
    Err(e) => fail("expected fresh audit success: " + e.message())
  }
  assert_eq(spawn_calls, 1)
  assert_eq(cleanup_calls, 0)
  assert_eq(spawned_slug, audit_on_file_pr_worker_slug(head, now_ms))
  assert_true(
    spawned_task.contains("Review surface: `git diff main..." + head + "`"),
  )
  assert_false(spawned_task.contains("Prior audited HEAD"))
  assert_true(spawned_slug.has_suffix("-" + now_ms.to_string()))
  assert_eq(waited_worker, "main." + spawned_slug)
}

///|
async test "file_pr_auto_audit sends one start notification before each fresh audit spawn" {
  let project_dir = "/tmp/choir-fpr-auto-audit-start-notify-" +
    @sys.get_pid().to_string()
  let head = "abcdef1234567890abcdef1234567890abcdef12"
  let mut cycles = 0
  let events : Array[String] = []
  let recorded_agents : Array[String] = []
  let started_agents : Array[String] = []
  let run_cycle = async fn() -> Unit {
    let got = file_pr_auto_audit_for_missing_receipt(
      project_dir,
      project_dir,
      "feature/auto-audit",
      "main",
      head,
      file_pr_auto_audit_capture(head, None),
      async fn(worker_args) {
        @async.sleep(0)
        events.push("spawn:" + worker_args.slug)
        Ok("main." + worker_args.slug)
      },
      async fn(_) {
        @async.sleep(0)
        Some({
          message: "Finding 1: still broken\n",
          status: @types.Status::Success,
        })
      },
      fn(_) {  },
      file_pr_test_write_audit_receipt_ok,
      1000,
      0,
      fn(_, _) { true },
      async fn(_) { @async.sleep(0) },
      fn() { 1779000000L + cycles.to_int64() },
      fn(_) { true },
      audit_max_rounds=3,
      record_audit_cycle_for_agent=fn(agent_id) {
        recorded_agents.push(agent_id)
        cycles = cycles + 1
        cycles
      },
      notify_audit_started=async fn(agent_id, pr_number, cycle_number) {
        @async.sleep(0)
        started_agents.push(agent_id)
        events.push(
          "start:" + audit_started_notification_body(cycle_number, pr_number~),
        )
      },
    )
    match got {
      Err(e) => assert_true(e.message().contains("audit found 1 findings"))
      Ok(_) => fail("expected findings error")
    }
  }
  run_cycle()
  run_cycle()
  assert_eq(cycles, 2)
  @debug.assert_eq(recorded_agents, ["feature/auto-audit", "feature/auto-audit"])
  @debug.assert_eq(started_agents, ["feature/auto-audit", "feature/auto-audit"])
  assert_eq(events.length(), 4)
  assert_eq(events[0], "start:[AUDIT cycle 1 started] PR #pending")
  assert_true(events[1].has_prefix("spawn:audit-on-file-pr-abcdef123456-"))
  assert_eq(events[2], "start:[AUDIT cycle 2 started] PR #pending")
  assert_true(events[3].has_prefix("spawn:audit-on-file-pr-abcdef123456-"))
}

///|
async test "file_pr_auto_audit scopes worker to prior receipt delta under max lines" {
  let project_dir = "/tmp/choir-fpr-auto-audit-delta-" +
    @sys.get_pid().to_string()
  let prior = "1111111111111111111111111111111111111111"
  let head = "abcdef1234567890abcdef1234567890abcdef12"
  let now_ms = 123456789L
  let mut spawned_task = ""
  let got = file_pr_auto_audit_for_missing_receipt(
    project_dir,
    project_dir,
    "feature/auto-audit",
    "main",
    head,
    async fn(cmd : @workspace.Command) -> (Int, String) {
      @async.sleep(0)
      if cmd.program == "git" &&
        cmd.args == ["rev-parse", "--abbrev-ref", "HEAD"] {
        return (0, "feature/auto-audit\n")
      }
      if cmd.program == "cat" &&
        cmd.args == [file_pr_audit_receipt_path_for_head(head)] {
        return (1, "")
      }
      if cmd.program == "find" {
        return (0, "1000.000000\t111111111111.json\n")
      }
      if cmd.program == "cat" &&
        cmd.args == [".choir/audit-receipts/111111111111.json"] {
        return (
          0,
          file_pr_test_audit_receipt_for_branch(prior, "feature/auto-audit", 0),
        )
      }
      if cmd.program == "git" &&
        cmd.args == ["diff", "--numstat", prior + "..." + head] {
        return (0, "3\t2\tsrc/a.mbt\n")
      }
      (0, "")
    },
    async fn(worker_args) {
      @async.sleep(0)
      spawned_task = worker_args.task
      Ok("main." + worker_args.slug)
    },
    async fn(_) {
      @async.sleep(0)
      Some({ message: "No findings.", status: @types.Status::Success })
    },
    fn(_) {  },
    file_pr_test_write_audit_receipt_ok,
    1000,
    0,
    fn(_, _) { true },
    async fn(_) { @async.sleep(0) },
    fn() { now_ms },
    fn(_) { true },
  )
  match got {
    Ok(_) => ()
    Err(e) => fail("expected delta audit success: " + e.message())
  }
  assert_true(
    spawned_task.contains(
      "Review surface: `git diff " + prior + "..." + head + "`",
    ),
  )
  assert_true(spawned_task.contains("Prior audited HEAD: " + prior))
}

///|
async test "file_pr_auto_audit ignores prior receipt with findings" {
  let project_dir = "/tmp/choir-fpr-auto-audit-delta-findings-" +
    @sys.get_pid().to_string()
  let prior = "1111111111111111111111111111111111111111"
  let head = "abcdef1234567890abcdef1234567890abcdef12"
  let mut spawned_task = ""
  let got = file_pr_auto_audit_for_missing_receipt(
    project_dir,
    project_dir,
    "feature/auto-audit",
    "main",
    head,
    async fn(cmd : @workspace.Command) -> (Int, String) {
      @async.sleep(0)
      if cmd.program == "git" &&
        cmd.args == ["rev-parse", "--abbrev-ref", "HEAD"] {
        return (0, "feature/auto-audit\n")
      }
      if cmd.program == "cat" &&
        cmd.args == [file_pr_audit_receipt_path_for_head(head)] {
        return (1, "")
      }
      if cmd.program == "find" {
        return (0, "1000.000000\t111111111111.json\n")
      }
      if cmd.program == "cat" &&
        cmd.args == [".choir/audit-receipts/111111111111.json"] {
        return (
          0,
          file_pr_test_audit_receipt_for_branch(prior, "feature/auto-audit", 2),
        )
      }
      if cmd.program == "git" &&
        cmd.args == ["diff", "--numstat", prior + "..." + head] {
        fail("dirty prior receipt should not be used for delta audit")
      }
      (0, "")
    },
    async fn(worker_args) {
      @async.sleep(0)
      spawned_task = worker_args.task
      Ok("main." + worker_args.slug)
    },
    async fn(_) {
      @async.sleep(0)
      Some({ message: "No findings.", status: @types.Status::Success })
    },
    fn(_) {  },
    file_pr_test_write_audit_receipt_ok,
    1000,
    0,
    fn(_, _) { true },
    async fn(_) { @async.sleep(0) },
    fn() { 1234L },
    fn(_) { true },
  )
  match got {
    Ok(_) => ()
    Err(e) => fail("expected full audit fallback success: " + e.message())
  }
  assert_true(
    spawned_task.contains("Review surface: `git diff main..." + head + "`"),
  )
  assert_false(spawned_task.contains("Prior audited HEAD"))
}

///|
async test "file_pr_auto_audit falls back to full audit when delta is over max lines" {
  let project_dir = "/tmp/choir-fpr-auto-audit-delta-large-" +
    @sys.get_pid().to_string()
  let prior = "1111111111111111111111111111111111111111"
  let head = "abcdef1234567890abcdef1234567890abcdef12"
  let mut spawned_task = ""
  let got = file_pr_auto_audit_for_missing_receipt(
    project_dir,
    project_dir,
    "feature/auto-audit",
    "main",
    head,
    async fn(cmd : @workspace.Command) -> (Int, String) {
      @async.sleep(0)
      if cmd.program == "git" &&
        cmd.args == ["rev-parse", "--abbrev-ref", "HEAD"] {
        return (0, "feature/auto-audit\n")
      }
      if cmd.program == "cat" &&
        cmd.args == [file_pr_audit_receipt_path_for_head(head)] {
        return (1, "")
      }
      if cmd.program == "find" {
        return (0, "1000.000000\t111111111111.json\n")
      }
      if cmd.program == "cat" &&
        cmd.args == [".choir/audit-receipts/111111111111.json"] {
        return (
          0,
          file_pr_test_audit_receipt_for_branch(prior, "feature/auto-audit", 0),
        )
      }
      if cmd.program == "git" &&
        cmd.args == ["diff", "--numstat", prior + "..." + head] {
        return (0, "501\t0\tsrc/a.mbt\n")
      }
      (0, "")
    },
    async fn(worker_args) {
      @async.sleep(0)
      spawned_task = worker_args.task
      Ok("main." + worker_args.slug)
    },
    async fn(_) {
      @async.sleep(0)
      Some({ message: "No findings.", status: @types.Status::Success })
    },
    fn(_) {  },
    file_pr_test_write_audit_receipt_ok,
    1000,
    0,
    fn(_, _) { true },
    async fn(_) { @async.sleep(0) },
    fn() { 1234L },
    fn(_) { true },
  )
  match got {
    Ok(_) => ()
    Err(e) => fail("expected full audit fallback success: " + e.message())
  }
  assert_true(
    spawned_task.contains("Review surface: `git diff main..." + head + "`"),
  )
  assert_false(spawned_task.contains("Prior audited HEAD"))
}

///|
async test "interpret_file_pr audit wait emits heartbeats and final findings line" {
  let project_dir = "/tmp/choir-fpr-auto-audit-heartbeat-" +
    @sys.get_pid().to_string()
  let head = "abcdef1234567890abcdef1234567890abcdef12"
  let appended : Array[String] = []
  let mut now_ms = 0L
  let fake_sleep = async fn(ms : Int) -> Unit {
    if ms == 60000 && now_ms < 180000L {
      now_ms = now_ms + ms.to_int64()
    }
    @async.pause()
  }
  let got = interpret_file_pr(
    {
      branch: "feature/auto-audit",
      parent_branch: Some("main"),
      tracked_agent_id: "feature/auto-audit",
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
    file_pr_auto_audit_capture(head, None),
    mock_ensure_pr_ok,
    caller_role=@types.Role::Dev,
    task_contract_reader=file_pr_test_empty_task_contract_reader,
    tdd_phase_reader=file_pr_test_tdd_done,
    audit_heartbeat_sec=60,
    append_file=fn(_path, content) {
      appended.push(content)
      true
    },
    audit_sleep_fn=fake_sleep,
    audit_now_ms_fn=fn() { now_ms },
    wait_for_audit_report=async fn(_) {
      while now_ms < 180000L {
        @async.pause()
      }
      Some({
        message: "Finding 1: one\nFinding 2: two\n",
        status: @types.Status::Success,
      })
    },
  )
  match got {
    @types.Response::Err(msg) =>
      assert_true(msg.contains("audit found 2 findings"))
    @types.Response::Ok(_) => fail("expected findings error")
  }
  let log = appended.join("")
  assert_true(file_pr_audit_heartbeat_log_count(log, "status=running") >= 2)
  assert_true(log.contains("elapsed_s=60 status=running"))
  assert_true(log.contains("elapsed_s=120 status=running"))
  if !log.contains("elapsed_s=180 status=ok findings_count=2") {
    fail("missing final heartbeat line: " + log)
  }
}

///|
async test "interpret_file_pr stops running heartbeats when audit worker is not alive" {
  let project_dir = "/tmp/choir-fpr-auto-audit-heartbeat-dead-" +
    @sys.get_pid().to_string()
  let head = "abcdef1234567890abcdef1234567890abcdef12"
  let appended : Array[String] = []
  let mut now_ms = 0L
  let fake_sleep = async fn(ms : Int) -> Unit {
    if ms == 60000 && now_ms < 120000L {
      now_ms = now_ms + ms.to_int64()
    }
    @async.pause()
  }
  let got = interpret_file_pr(
    {
      branch: "feature/auto-audit",
      parent_branch: Some("main"),
      tracked_agent_id: "feature/auto-audit",
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
    file_pr_auto_audit_capture(head, None),
    mock_ensure_pr_ok,
    caller_role=@types.Role::Dev,
    task_contract_reader=file_pr_test_empty_task_contract_reader,
    tdd_phase_reader=file_pr_test_tdd_done,
    audit_heartbeat_sec=60,
    append_file=fn(_path, content) {
      appended.push(content)
      true
    },
    audit_sleep_fn=fake_sleep,
    audit_now_ms_fn=fn() { now_ms },
    audit_worker_alive=fn(_) { now_ms < 120000L },
    wait_for_audit_report=async fn(_) {
      while now_ms < 120000L {
        @async.pause()
      }
      now_ms = 180000L
      @async.pause()
      None
    },
  )
  assert_file_pr_audit_incomplete_response(got, "audit worker did not report")
  let log = appended.join("")
  assert_true(log.contains("elapsed_s=60 status=running"))
  assert_false(log.contains("elapsed_s=120 status=running"))
  assert_true(log.contains("elapsed_s=180 status=error reason=missing_report"))
}

///|
async test "interpret_file_pr audit heartbeat zero disables running lines only" {
  let project_dir = "/tmp/choir-fpr-auto-audit-heartbeat-off-" +
    @sys.get_pid().to_string()
  let head = "abcdef1234567890abcdef1234567890abcdef12"
  let appended : Array[String] = []
  let mut now_ms = 0L
  let got = interpret_file_pr(
    {
      branch: "feature/auto-audit",
      parent_branch: Some("main"),
      tracked_agent_id: "feature/auto-audit",
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
    file_pr_auto_audit_capture(head, None),
    mock_ensure_pr_ok,
    caller_role=@types.Role::Dev,
    task_contract_reader=file_pr_test_empty_task_contract_reader,
    tdd_phase_reader=file_pr_test_tdd_done,
    audit_heartbeat_sec=0,
    append_file=fn(_path, content) {
      appended.push(content)
      true
    },
    audit_now_ms_fn=fn() { now_ms },
    wait_for_audit_report=async fn(_) {
      now_ms = 180000L
      @async.pause()
      Some({ message: "No findings.", status: @types.Status::Success })
    },
    create_dir_all=fn(_) { true },
    write_file_atomic=fn(_, _) { true },
  )
  assert_true(got.is_ok())
  let log = appended.join("")
  assert_eq(file_pr_audit_heartbeat_log_count(log, "audit-on-file-pr"), 1)
  assert_eq(file_pr_audit_heartbeat_log_count(log, "status=running"), 0)
  assert_true(log.contains("elapsed_s=180 status=ok findings_count=0"))
}

///|
async test "interpret_file_pr audit final line records worker failure elapsed" {
  let project_dir = "/tmp/choir-fpr-auto-audit-heartbeat-error-" +
    @sys.get_pid().to_string()
  let head = "abcdef1234567890abcdef1234567890abcdef12"
  let appended : Array[String] = []
  let mut now_ms = 0L
  let got = interpret_file_pr(
    {
      branch: "feature/auto-audit",
      parent_branch: Some("main"),
      tracked_agent_id: "feature/auto-audit",
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
    file_pr_auto_audit_capture(head, None),
    mock_ensure_pr_ok,
    caller_role=@types.Role::Dev,
    task_contract_reader=file_pr_test_empty_task_contract_reader,
    tdd_phase_reader=file_pr_test_tdd_done,
    audit_heartbeat_sec=0,
    append_file=fn(_path, content) {
      appended.push(content)
      true
    },
    audit_now_ms_fn=fn() { now_ms },
    wait_for_audit_report=async fn(_) {
      now_ms = 180000L
      @async.pause()
      Some({
        message: "worker failed before report body",
        status: @types.Status::Failure,
      })
    },
  )
  assert_file_pr_audit_incomplete_response(got, "audit worker reported failure")
  let log = appended.join("")
  assert_eq(file_pr_audit_heartbeat_log_count(log, "audit-on-file-pr"), 1)
  assert_true(log.contains("elapsed_s=180 status=error reason=worker_failure"))
}

///|
async test "interpret_file_pr audit final line records worker shutdown elapsed" {
  let project_dir = "/tmp/choir-fpr-auto-audit-heartbeat-shutdown-" +
    @sys.get_pid().to_string()
  let head = "abcdef1234567890abcdef1234567890abcdef12"
  let appended : Array[String] = []
  let mut now_ms = 0L
  let got = interpret_file_pr(
    {
      branch: "feature/auto-audit",
      parent_branch: Some("main"),
      tracked_agent_id: "feature/auto-audit",
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
    file_pr_auto_audit_capture(head, None),
    mock_ensure_pr_ok,
    caller_role=@types.Role::Dev,
    task_contract_reader=file_pr_test_empty_task_contract_reader,
    tdd_phase_reader=file_pr_test_tdd_done,
    audit_heartbeat_sec=0,
    append_file=fn(_path, content) {
      appended.push(content)
      true
    },
    audit_now_ms_fn=fn() { now_ms },
    wait_for_audit_report=async fn(_) {
      now_ms = 180000L
      @async.pause()
      Some({
        message: "audit worker shutdown without notify_parent report",
        status: @types.Status::Failure,
      })
    },
  )
  assert_file_pr_audit_incomplete_response(got, "audit worker reported failure")
  let log = appended.join("")
  assert_eq(file_pr_audit_heartbeat_log_count(log, "audit-on-file-pr"), 1)
  assert_true(log.contains("elapsed_s=180 status=error reason=worker_shutdown"))
}

///|
async test "interpret_file_pr Dev missing audit auto-spawns writes receipt and returns PR" {
  let project_dir = "/tmp/choir-fpr-auto-audit-ok-" + @sys.get_pid().to_string()
  let head = "abcdef1234567890abcdef1234567890abcdef12"
  let mut runner_calls = 0
  let mut prepared_worker = ""
  let mut waited_worker = ""
  let mut receipt_dir = ""
  let mut receipt_path = ""
  let mut receipt_content = ""
  let got = interpret_file_pr(
    {
      branch: "feature/auto-audit",
      parent_branch: Some("main"),
      tracked_agent_id: "feature/auto-audit",
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
    async fn(cmds : Array[@workspace.Command]) -> Array[Int] {
      @async.sleep(0)
      runner_calls = runner_calls + 1
      let statuses = []
      for _ in cmds {
        statuses.push(0)
      }
      statuses
    },
    file_pr_auto_audit_capture(head, None),
    mock_ensure_pr_ok,
    caller_role=@types.Role::Dev,
    task_contract_reader=file_pr_test_empty_task_contract_reader,
    tdd_phase_reader=file_pr_test_tdd_done,
    prepare_audit_report=fn(worker_id) { prepared_worker = worker_id },
    create_dir_all=fn(path) {
      receipt_dir = path
      true
    },
    write_file_atomic=fn(path, content) {
      receipt_path = path
      receipt_content = content
      true
    },
    wait_for_audit_report=async fn(worker_id) {
      @async.sleep(0)
      waited_worker = worker_id
      assert_eq(prepared_worker, worker_id)
      Some({
        message: "No findings. The code is acceptable.",
        status: @types.Status::Success,
      })
    },
  )
  match got {
    @types.Response::Ok(fields) =>
      assert_eq(
        fields.get("pr_url").unwrap_or(""),
        "https://example.test/pr/42",
      )
    @types.Response::Err(msg) => fail("expected PR response: " + msg)
  }
  // The auto-audit path runs the spawned worker, then the normal file_pr push.
  assert_eq(runner_calls, 2)
  assert_true(waited_worker.contains(audit_on_file_pr_internal_caller_id))
  assert_true(prepared_worker.contains(file_pr_short_sha(head)))
  assert_true(receipt_dir.contains(".choir/audit-receipts"))
  assert_true(receipt_path.contains(".choir/audit-receipts/abcdef123456.json"))
  let parsed_receipt = @json.parse(receipt_content) catch {
    _ => fail("receipt did not parse")
  }
  let decoded : @types.AuditReceipt = @json.from_json(parsed_receipt) catch {
    _ => fail("receipt did not decode")
  }
  assert_eq(decoded.sha, head)
  assert_eq(decoded.branch, "feature/auto-audit")
  assert_eq(decoded.agent_id, audit_on_file_pr_internal_caller_id)
  assert_eq(decoded.findings_count, 0)
}

///|
async test "interpret_file_pr Dev missing audit returns findings error" {
  let project_dir = "/tmp/choir-fpr-auto-audit-findings-" +
    @sys.get_pid().to_string()
  let head = "abcdef1234567890abcdef1234567890abcdef12"
  let mut receipt_written = false
  let got = interpret_file_pr(
    {
      branch: "feature/auto-audit",
      parent_branch: Some("main"),
      tracked_agent_id: "feature/auto-audit",
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
    file_pr_auto_audit_capture(head, None),
    mock_ensure_pr_ok,
    caller_role=@types.Role::Dev,
    task_contract_reader=file_pr_test_empty_task_contract_reader,
    tdd_phase_reader=file_pr_test_tdd_done,
    create_dir_all=fn(_) { true },
    write_file_atomic=fn(_, _) {
      receipt_written = true
      true
    },
    wait_for_audit_report=async fn(_) {
      @async.sleep(0)
      Some({
        message: "Finding 1: one\nFinding 2: two\nFinding 3: three\n",
        status: @types.Status::Success,
      })
    },
  )
  match got {
    @types.Response::Err(msg) => {
      assert_true(msg.contains("audit found 3 findings"))
      assert_true(msg.contains("Finding 1: one"))
    }
    @types.Response::Ok(_) => fail("expected findings error")
  }
  assert_false(receipt_written)
}

///|
async test "interpret_file_pr Dev audit max rounds returns typed exhaustion on configured cycle" {
  let project_dir = "/tmp/choir-fpr-auto-audit-exhausted-" +
    @sys.get_pid().to_string()
  let head = "abcdef1234567890abcdef1234567890abcdef12"
  let mut cycles = 0
  let mut wait_count = 0
  let recorded_agents : Array[String] = []
  let got = interpret_file_pr(
    {
      branch: "feature/auto-audit",
      parent_branch: Some("main"),
      tracked_agent_id: "feature/auto-audit",
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
    file_pr_auto_audit_capture(head, None),
    mock_ensure_pr_ok,
    caller_role=@types.Role::Dev,
    task_contract_reader=file_pr_test_empty_task_contract_reader,
    tdd_phase_reader=file_pr_test_tdd_done,
    audit_max_rounds=1,
    record_audit_cycle_for_agent=fn(agent_id) {
      recorded_agents.push(agent_id)
      cycles = cycles + 1
      cycles
    },
    wait_for_audit_report=async fn(_) {
      @async.sleep(0)
      wait_count = wait_count + 1
      Some({
        message: "Finding 1: still broken\n",
        status: @types.Status::Success,
      })
    },
  )
  match got {
    @types.Response::Err(msg) => {
      assert_true(msg.contains("audit loop exhausted after 1 cycle(s)"))
      assert_true(msg.contains("1 finding(s) remaining"))
      assert_true(msg.contains(".choir/audit-receipts/abcdef123456.json"))
      assert_false(msg.contains("audit found 1 findings"))
    }
    @types.Response::Ok(_) => fail("expected audit loop exhaustion")
  }
  assert_eq(cycles, 1)
  assert_eq(wait_count, 1)
  @debug.assert_eq(recorded_agents, ["feature/auto-audit"])
}

///|
async test "interpret_file_pr Dev existing receipt skips auto audit" {
  let project_dir = "/tmp/choir-fpr-auto-audit-existing-" +
    @sys.get_pid().to_string()
  let head = "abcdef1234567890abcdef1234567890abcdef12"
  let mut waited = false
  let got = interpret_file_pr(
    {
      branch: "feature/auto-audit",
      parent_branch: Some("main"),
      tracked_agent_id: "feature/auto-audit",
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
    file_pr_auto_audit_capture(head, Some(file_pr_test_audit_receipt(head))),
    mock_ensure_pr_ok,
    caller_role=@types.Role::Dev,
    task_contract_reader=file_pr_test_empty_task_contract_reader,
    tdd_phase_reader=file_pr_test_tdd_done,
    wait_for_audit_report=async fn(_) {
      @async.sleep(0)
      waited = true
      None
    },
  )
  assert_true(got.is_ok())
  assert_false(waited)
}

///|
async test "interpret_file_pr Dev audit outer budget files PR with retryable audit incomplete state" {
  let project_dir = "/tmp/choir-fpr-auto-audit-timeout-" +
    @sys.get_pid().to_string()
  let head = "abcdef1234567890abcdef1234567890abcdef12"
  let mut cleaned_worker = ""
  let mut ensure_pr_called = false
  let got = interpret_file_pr(
    {
      branch: "feature/auto-audit",
      parent_branch: Some("main"),
      tracked_agent_id: "feature/auto-audit",
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
    file_pr_auto_audit_capture(head, None),
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
    task_contract_reader=file_pr_test_empty_task_contract_reader,
    tdd_phase_reader=file_pr_test_tdd_done,
    audit_budget_ms=1,
    cleanup_audit_report=async fn(worker_id) {
      @async.sleep(0)
      cleaned_worker = worker_id
    },
    wait_for_audit_report=async fn(_) {
      @async.sleep(50)
      None
    },
  )
  match got {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      @debug.assert_eq(map.get("status"), Some(String::to_json("pr_created")))
      @debug.assert_eq(
        map.get("pr_url"),
        Some(String::to_json("https://example.test/pr/42")),
      )
    }
    @types.Response::Err(msg) =>
      fail("timeout must not hard-abort file_pr: " + msg)
  }
  assert_file_pr_audit_incomplete_response(got, "audit budget exceeded")
  assert_true(ensure_pr_called)
  assert_true(cleaned_worker.contains(audit_on_file_pr_internal_caller_id))
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
async test "interpret_file_pr feature main fails without audit receipt" {
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
    @types.Response::Err(msg) =>
      assert_eq(
        msg,
        "file_pr: PRs targeting main require a recent audit on HEAD " +
        file_pr_short_sha(head) +
        "; run `/audit` (choir:audit skill) on this branch first, then retry.",
      )
    _ => fail("expected audit receipt gate failure")
  }
  assert_false(ensure_pr_called)
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "interpret_file_pr feature main succeeds with fresh audit receipt" {
  let project_dir = "/tmp/choir-fpr-audit-fresh-" + @sys.get_pid().to_string()
  let head = "abcdef1234567890abcdef1234567890abcdef12"
  ignore(@sys.rm_rf(project_dir))
  assert_true(@sys.create_dir_all(project_dir + "/.choir"))
  let mut receipt_path_seen = ""
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
        if cmd.args.length() > 0 {
          receipt_path_seen = cmd.args[0]
        }
        (0, file_pr_test_audit_receipt(head))
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
    @types.Response::Ok(_) => ()
    @types.Response::Err(msg) => fail("expected fresh audit receipt: " + msg)
  }
  assert_eq(receipt_path_seen, ".choir/audit-receipts/abcdef123456.json")
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
async test "interpret_file_pr feature main fails with stale audit receipt" {
  let project_dir = "/tmp/choir-fpr-audit-stale-" + @sys.get_pid().to_string()
  let current = "fedcba654321fedcba654321fedcba654321fedc"
  let audited = "1111111111112222222222223333333333334444"
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
        (0, current + "\n")
      } else if cmd.program == "cat" {
        (0, file_pr_test_audit_receipt(audited))
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
    @types.Response::Err(msg) =>
      assert_eq(
        msg,
        "file_pr: audit receipt is stale (audit ran on " +
        audited +
        ", current HEAD is " +
        current +
        "); re-run /audit",
      )
    _ => fail("expected stale audit receipt gate failure")
  }
  assert_false(ensure_pr_called)
  ignore(@sys.rm_rf(project_dir))
}

///|
test "file_pr_validate_audit_receipt distinguishes stale vs malformed receipts" {
  let head = "fedcba654321fedcba654321fedcba654321fedc"
  let short = file_pr_short_sha(head)
  // Stale: well-formed receipt JSON pointing at a different audited sha.
  // All typed receipt fields present.
  let other_sha = "1111111111112222222222223333333333334444"
  match
    file_pr_validate_audit_receipt(
      "main",
      head,
      Some(file_pr_test_audit_receipt(other_sha)),
    ) {
    Err(e) => {
      assert_true(e.message().contains("audit receipt is stale"))
      assert_true(e.message().contains(other_sha))
      assert_false(e.message().contains("malformed"))
    }
    Ok(_) => fail("expected stale audit receipt error")
  }
  // Malformed: receipt JSON has only the `sha` field, missing `branch` and
  // `audited_at`. Must NOT pass the gate just because sha matches HEAD —
  // a partial payload is not a valid audit record.
  match
    file_pr_validate_audit_receipt(
      "main",
      head,
      Some("{\"sha\":\"" + head + "\"}"),
    ) {
    Err(e) => {
      assert_true(e.message().contains("malformed"))
      assert_true(e.message().contains(short))
      assert_false(e.message().contains("audit receipt is stale"))
    }
    Ok(_) =>
      fail("expected malformed receipt error for missing branch/audited_at")
  }
  // Malformed: receipt JSON missing the `sha` field entirely.
  match
    file_pr_validate_audit_receipt(
      "main",
      head,
      Some(
        "{\"branch\":\"x\",\"audited_at\":\"1\",\"agent_id\":\"main.tl\",\"findings_count\":0}",
      ),
    ) {
    Err(e) => {
      assert_true(e.message().contains("malformed"))
      assert_true(e.message().contains(short))
      assert_false(e.message().contains("<missing>"))
      assert_false(e.message().contains("audit receipt is stale"))
    }
    Ok(_) => fail("expected malformed receipt error")
  }
  // Malformed: receipt body is not valid JSON at all.
  match file_pr_validate_audit_receipt("main", head, Some("{not json")) {
    Err(e) => {
      assert_true(e.message().contains("malformed"))
      assert_false(e.message().contains("<missing>"))
    }
    Ok(_) => fail("expected malformed receipt error")
  }
  // Happy path: all typed fields present, findings_count is zero, and sha matches HEAD.
  match
    file_pr_validate_audit_receipt(
      "main",
      head,
      Some(file_pr_test_audit_receipt(head)),
    ) {
    Ok(_) => ()
    Err(e) => fail("expected validation to pass: " + e.message())
  }
}

///|
test "file_pr_validate_audit_receipt rejects findings_count above zero" {
  let head = "fedcba654321fedcba654321fedcba654321fedc"
  match
    file_pr_validate_audit_receipt(
      "main",
      head,
      Some(file_pr_test_audit_receipt_with_findings(head, 3)),
    ) {
    Err(e) =>
      assert_eq(
        e.message(),
        "validation error: file_pr: audit on HEAD " +
        file_pr_short_sha(head) +
        " reported 3 finding(s); re-run /audit until findings_count == 0 before filing.",
      )
    Ok(_) => fail("expected findings_count gate failure")
  }
}

///|
test "file_pr_validate_audit_receipt rejects legacy receipts as malformed" {
  let head = "fedcba654321fedcba654321fedcba654321fedc"
  match
    file_pr_validate_audit_receipt(
      "main",
      head,
      Some(
        "{\"sha\":\"" +
        head +
        "\",\"branch\":\"feature/x\",\"audited_at\":1700000000,\"agent_id\":\"main.tl\"}",
      ),
    ) {
    Err(e) => {
      assert_true(e.message().contains("malformed"))
      assert_true(e.message().contains("findings_count"))
      assert_false(e.message().contains("audit receipt is stale"))
    }
    Ok(_) => fail("expected legacy receipt to be rejected")
  }
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
async test "interpret_file_pr requests reviewer after audit verify push and ensure_pr" {
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
    fn(cmd : @workspace.Command) -> (Int, String) {
      if cmd.program == "git" && cmd.args == ["rev-parse", "HEAD"] {
        events.push("head")
        return (0, head + "\n")
      }
      if cmd.program == "cat" {
        events.push("audit")
        return (0, file_pr_test_audit_receipt(head))
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
  @debug.assert_eq(events, [
    "head", "audit", "head", "verify", "push", "ensure_pr", "reviewer",
  ])
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
