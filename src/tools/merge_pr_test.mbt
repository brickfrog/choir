///|
test "interpret_track_pr returns poller unavailable without poller_state" {
  let args : TrackPrArgs = {
    pr_number: 42,
    agent_id: "main.leaf",
    branch: "main.topic",
    parent_branch: "main",
    pr_url: "https://example.test/pr/42",
  }
  let got = interpret_track_pr(args, "/tmp", None, 0L)
  match got {
    @types.Response::Err(msg) => assert_eq(msg, "poller unavailable")
    _ => fail("expected err")
  }
}

///|
test "interpret_track_pr ensure_tracked writes state and returns tracked envelope" {
  let project_dir = "/tmp/choir-track-pr-" + @sys.get_pid().to_string()
  assert_true(@sys.create_dir_all(project_dir + "/.choir"))
  let args : TrackPrArgs = {
    pr_number: 99,
    agent_id: "main.agent",
    branch: "feat-x",
    parent_branch: "develop",
    pr_url: "https://gh/pr/99",
  }
  let ps = @poller.PollerState::new()
  let got = interpret_track_pr(args, project_dir, Some(ps), 12345L)
  match got {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      @debug.assert_eq(map.get("status"), Some(String::to_json("tracked")))
      @debug.assert_eq(map.get("branch"), Some(String::to_json("feat-x")))
      @debug.assert_eq(
        map.get("parent_branch"),
        Some(String::to_json("develop")),
      )
      @debug.assert_eq(
        map.get("pr_url"),
        Some(String::to_json("https://gh/pr/99")),
      )
    }
    _ => fail("expected ok")
  }
  match ps.get(99) {
    Some(t) => {
      assert_eq(t.agent_id, "main.agent")
      assert_eq(t.branch, "feat-x")
      assert_eq(t.parent_branch, "develop")
      assert_eq(t.pr_url, "https://gh/pr/99")
      assert_eq(t.first_seen, 12345L)
      assert_eq(t.review_mode, @types.Config::default().review_mode)
    }
    None => fail("expected tracked PR in poller state")
  }
}

///|
test "interpret_track_pr resolves inline review mode before global fallback" {
  let project_dir = "/tmp/choir-track-pr-review-mode-" +
    @sys.get_pid().to_string()
  let agent_id = "main.inline-track"
  let inline_dir = @workspace.inline_agent_metadata_dir(project_dir, agent_id)
  ignore(@sys.rm_rf(project_dir))
  assert_true(@sys.create_dir_all(inline_dir + "/.choir"))
  assert_true(
    @sys.write_file_sync(
      inline_dir + "/.choir/config.local.toml",
      "review_mode = \"single_pass\"\n",
    ),
  )
  let ps = @poller.PollerState::new()
  let got = interpret_track_pr(
    {
      pr_number: 100,
      agent_id,
      branch: "main.inline-track",
      parent_branch: "main",
      pr_url: "https://gh/pr/100",
    },
    project_dir,
    Some(ps),
    12345L,
    global_review_mode=@types.ReviewMode::Iterative,
  )
  assert_true(got.is_ok())
  match ps.get(100) {
    Some(t) => assert_eq(t.review_mode, @types.ReviewMode::SinglePass)
    None => fail("expected tracked PR")
  }
  ignore(@sys.rm_rf(project_dir))
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
    last_automerge_attempt_sha: "",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Unknown,
    mergeable: @poller.Mergeable::Unknown,
    merge_state_status: @poller.MergeStateStatus::Unknown,
    merged_at_unix: None,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: false,
    orphan_notified: false,
    orphan_reconciling: false,
    changes_requested_since: 0L,
    stall_notified: false,
    fixes_pushed_at: 0L,
    review_mode: @types.ReviewMode::Iterative,
    unresolved_thread_ids: [],
    unresolved_thread_ids_fetched: false,
    auto_resolve_outdated_pending: false,
  }
}

///|
fn merge_pr_test_audit_receipt_with_findings(
  sha : String,
  findings_count : Int,
) -> String {
  let receipt : @types.AuditReceipt = {
    sha,
    branch: "feature/audit-gate",
    audited_at: 1L,
    agent_id: "audit-on-file-pr",
    findings_count,
  }
  receipt.to_json().stringify() + "\n"
}

///|
fn merge_pr_test_audit_receipt(sha : String) -> String {
  merge_pr_test_audit_receipt_with_findings(sha, 0)
}

///|
fn merge_pr_test_audit_child(
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
fn merge_pr_test_gate_state_reader(
  enabled_at_unix : Int64,
) -> (String) -> String {
  fn(path : String) -> String {
    if path.has_suffix("/.choir/audit-gate.json") {
      "{\"enabled_at_unix\":" + enabled_at_unix.to_string() + "}\n"
    } else {
      ""
    }
  }
}

///|
test "merge_pr_audit_gate_required grandfathers PRs first seen before gate timestamp" {
  let state : MergeGateState = { enabled_at_unix: 100L }
  assert_false(merge_pr_audit_gate_required(state, 99L))
  assert_true(merge_pr_audit_gate_required(state, 100L))
  assert_true(merge_pr_audit_gate_required(state, 101L))
}

///|
test "load_or_initialize_gate_state fails closed when timestamp cannot persist" {
  match
    load_or_initialize_gate_state("/repo", fn() { 123L }, fn(_) { "" }, fn(
      _,
      _,
    ) {
      false
    }) {
    Err(e) => {
      assert_true(e.message().contains("audit receipt gate"))
      assert_true(e.message().contains("not durable"))
    }
    Ok(_) => fail("expected gate state persistence failure")
  }
}

///|
test "merge_pr_audit_receipt_validation distinguishes valid stale missing invalid" {
  let head = "abcdef1234567890abcdef1234567890abcdef12"
  let other = "1111111111112222222222223333333333334444"
  match
    merge_pr_audit_receipt_validation(
      "main",
      head,
      Some(merge_pr_test_audit_receipt(head)),
    ) {
    MergeAuditReceiptValid => ()
    _ => fail("expected valid receipt")
  }
  match
    merge_pr_audit_receipt_validation(
      "main",
      head,
      Some(merge_pr_test_audit_receipt(other)),
    ) {
    MergeAuditReceiptStale(audited, current) => {
      assert_eq(audited, other)
      assert_eq(current, head)
    }
    _ => fail("expected stale receipt")
  }
  match merge_pr_audit_receipt_validation("main", head, None) {
    MergeAuditReceiptMissing(short_sha) =>
      assert_eq(short_sha, file_pr_short_sha(head))
    _ => fail("expected missing receipt")
  }
  match merge_pr_audit_receipt_validation("main", head, Some("{not json")) {
    MergeAuditReceiptInvalid(short_sha) =>
      assert_eq(short_sha, file_pr_short_sha(head))
    _ => fail("expected invalid receipt")
  }
}

///|
async test "merge_pr_require_audit_receipt auto-audit writes receipt and clears gate" {
  let project_dir = "/tmp/choir-mpr-audit-ok-" + @sys.get_pid().to_string()
  let head = "abcdef1234567890abcdef1234567890abcdef12"
  let mut receipt_body : String? = None
  let mut spawned = false
  let mut waited_worker = ""
  let mut write_sha = ""
  let got = merge_pr_require_audit_receipt(
    "main",
    project_dir,
    project_dir,
    "main.leaf",
    91,
    head,
    { enabled_at_unix: 100L },
    200L,
    async fn(cmd : @workspace.Command) -> (Int, String) {
      @async.sleep(0)
      if cmd.program == "git" &&
        cmd.args == ["rev-parse", "--abbrev-ref", "HEAD"] {
        return (0, "feature/audit-gate\n")
      }
      if cmd.program == "cat" {
        match receipt_body {
          Some(body) => return (0, body)
          None => return (1, "")
        }
      }
      (0, "")
    },
    spawn_audit_worker=async fn(_) {
      @async.sleep(0)
      spawned = true
      Ok("audit-worker-1")
    },
    wait_for_audit_report=async fn(worker_id) {
      @async.sleep(0)
      waited_worker = worker_id
      Some({ message: "No findings.", status: @types.Status::Success })
    },
    write_audit_receipt=fn(args) {
      write_sha = args.sha
      receipt_body = Some(merge_pr_test_audit_receipt(args.sha))
      @types.Response::ok_values({ "status": "ok".to_json() })
    },
    audit_heartbeat_sec=0,
  )
  match got {
    Ok(_) => ()
    Err(e) => fail("expected audit gate to clear: " + e.message())
  }
  assert_true(spawned)
  assert_eq(waited_worker, "audit-worker-1")
  assert_eq(write_sha, head)
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "merge_pr_require_audit_receipt awaits in-flight audit worker without spawning" {
  let project_dir = "/tmp/choir-mpr-audit-in-flight-" +
    @sys.get_pid().to_string()
  let head = "abcdef1234567890abcdef1234567890abcdef12"
  let prefix = audit_on_file_pr_slug_prefix(head)
  let existing = merge_pr_test_audit_child(
    prefix + "111",
    @phase.ChildLifecycleSummary::Working,
  )
  let mut receipt_body : String? = None
  let mut spawn_calls = 0
  let mut waited_worker = ""
  let mut write_sha = ""
  let got = merge_pr_require_audit_receipt(
    "main",
    project_dir,
    project_dir,
    "main.leaf",
    94,
    head,
    { enabled_at_unix: 100L },
    200L,
    async fn(cmd : @workspace.Command) -> (Int, String) {
      @async.sleep(0)
      if cmd.program == "git" &&
        cmd.args == ["rev-parse", "--abbrev-ref", "HEAD"] {
        return (0, "feature/audit-gate\n")
      }
      if cmd.program == "cat" {
        match receipt_body {
          Some(body) => return (0, body)
          None => return (1, "")
        }
      }
      (0, "")
    },
    spawn_audit_worker=async fn(_) {
      @async.sleep(0)
      spawn_calls = spawn_calls + 1
      Err(@types.ChoirError::validation_error("unexpected spawn"))
    },
    wait_for_audit_report=async fn(worker_id) {
      @async.sleep(0)
      waited_worker = worker_id
      Some({ message: "No findings.", status: @types.Status::Success })
    },
    write_audit_receipt=fn(args) {
      write_sha = args.sha
      receipt_body = Some(merge_pr_test_audit_receipt(args.sha))
      @types.Response::ok_values({ "status": "ok".to_json() })
    },
    audit_heartbeat_sec=0,
    list_audit_workers=fn() { [existing] },
  )
  match got {
    Ok(_) => ()
    Err(e) => fail("expected in-flight audit gate to clear: " + e.message())
  }
  assert_eq(spawn_calls, 0)
  assert_eq(waited_worker, existing.child_id)
  assert_eq(write_sha, head)
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "merge_pr_require_audit_receipt refuses fresh spawn after timeout cycles exhaust cap" {
  let project_dir = "/tmp/choir-mpr-audit-cycle-cap-" +
    @sys.get_pid().to_string()
  let head = "abcdef1234567890abcdef1234567890abcdef12"
  let mut spawn_calls = 0
  let mut wait_calls = 0
  let mut record_calls = 0
  let got = merge_pr_require_audit_receipt(
    "main",
    project_dir,
    project_dir,
    "main.leaf",
    95,
    head,
    { enabled_at_unix: 100L },
    200L,
    async fn(cmd : @workspace.Command) -> (Int, String) {
      @async.sleep(0)
      if cmd.program == "git" &&
        cmd.args == ["rev-parse", "--abbrev-ref", "HEAD"] {
        return (0, "feature/audit-gate\n")
      }
      if cmd.program == "cat" {
        return (1, "")
      }
      (0, "")
    },
    spawn_audit_worker=async fn(_) {
      @async.sleep(0)
      spawn_calls = spawn_calls + 1
      Err(@types.ChoirError::validation_error("unexpected spawn"))
    },
    wait_for_audit_report=async fn(_) {
      @async.sleep(0)
      wait_calls = wait_calls + 1
      None
    },
    audit_heartbeat_sec=0,
    audit_max_rounds=2,
    record_audit_cycle_for_agent=fn(_) {
      record_calls = record_calls + 1
      99
    },
    audit_cycle_count_for_agent=fn(_) { 2 },
  )
  match got {
    Err(e) => {
      let msg = e.message()
      assert_true(
        msg.contains("policy blocked: audit receipt gate blocked PR #95"),
      )
      assert_true(msg.contains("auto-audit failed"))
      assert_true(msg.contains("audit loop exhausted after 2 cycle(s)"))
    }
    Ok(_) => fail("expected exhausted audit loop block")
  }
  assert_eq(spawn_calls, 0)
  assert_eq(wait_calls, 0)
  assert_eq(record_calls, 0)
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "merge_pr_require_audit_receipt timeout returns audit budget block" {
  let project_dir = "/tmp/choir-mpr-audit-timeout-" + @sys.get_pid().to_string()
  let head = "abcdef1234567890abcdef1234567890abcdef12"
  let mut cleaned_worker = ""
  let got = merge_pr_require_audit_receipt(
    "main",
    project_dir,
    project_dir,
    "main.leaf",
    92,
    head,
    { enabled_at_unix: 100L },
    200L,
    async fn(cmd : @workspace.Command) -> (Int, String) {
      @async.sleep(0)
      if cmd.program == "git" &&
        cmd.args == ["rev-parse", "--abbrev-ref", "HEAD"] {
        return (0, "feature/audit-gate\n")
      }
      if cmd.program == "cat" {
        return (1, "")
      }
      (0, "")
    },
    spawn_audit_worker=async fn(_) {
      @async.sleep(0)
      Ok("audit-worker-timeout")
    },
    wait_for_audit_report=async fn(_) {
      @async.sleep(50)
      None
    },
    cleanup_audit_report=fn(worker_id) { cleaned_worker = worker_id },
    audit_budget_ms=1,
    audit_heartbeat_sec=0,
  )
  match got {
    Err(e) => {
      let msg = e.message()
      assert_true(
        msg.contains("policy blocked: audit receipt gate blocked PR #92"),
      )
      assert_true(msg.contains("audit budget 1ms"))
    }
    Ok(_) => fail("expected audit timeout block")
  }
  assert_eq(cleaned_worker, "audit-worker-timeout")
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "interpret_merge_pr wires audit cycle cap into merge audit gate" {
  let project_dir = "/tmp/choir-mpr-audit-cap-wiring-" +
    @sys.get_pid().to_string()
  let head = "abcdef1234567890abcdef1234567890abcdef12"
  let ps = @poller.PollerState::new()
  ps.track_recovered(
    96,
    "main.leaf",
    "feature/audit-gate",
    "main",
    "https://github.com/o/r/pull/96",
    200L,
    @poller.ReviewState::Approved,
    "",
    head,
    @poller.CiRollupStatus::Success,
    true,
  )
  let mut runner_called = false
  let mut record_calls = 0
  let resp = interpret_merge_pr(
    {
      pr_number: 96,
      parent_branch: "main",
      caller_id: "main.tl",
      review_mode: Some(@types.ReviewMode::SinglePass),
    },
    project_dir,
    Some(ps),
    None,
    None,
    async fn(cmds : Array[@workspace.Command]) -> Array[Int] {
      @async.sleep(0)
      runner_called = true
      let statuses = []
      for _ in cmds {
        statuses.push(0)
      }
      statuses
    },
    async fn(cmd : @workspace.Command) -> (Int, String) {
      @async.sleep(0)
      if cmd.program == "gh" &&
        cmd.args.length() >= 2 &&
        cmd.args[0] == "api" &&
        cmd.args[1].has_suffix("/reviews") {
        return (0, "[{\"state\":\"APPROVED\"}]")
      }
      if cmd.program == "timeout" && cmd.args.contains("repo") {
        return (0, "{\"owner\":{\"login\":\"o\"},\"name\":\"r\"}")
      }
      if cmd.program == "timeout" && cmd.args.contains("graphql") {
        return (
          0, "{\"data\":{\"repository\":{\"pullRequest\":{\"reviewThreads\":{\"nodes\":[]}}}}}",
        )
      }
      if cmd.program == "git" &&
        cmd.args == ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"] {
        return (0, "origin/main\n")
      }
      if cmd.program == "git" &&
        cmd.args == ["rev-parse", "--abbrev-ref", "HEAD"] {
        return (0, "feature/audit-gate\n")
      }
      if cmd.program == "cat" {
        return (1, "")
      }
      (0, "")
    },
    fn(_, _) { true },
    fn(_) { false },
    read_file=fn(path) {
      if path.has_suffix("/.choir/audit-gate.json") {
        "{\"enabled_at_unix\":100}\n"
      } else {
        ""
      }
    },
    write_file_atomic=fn(_, _) { false },
    create_dir_all=fn(_) { true },
    audit_max_rounds=2,
    record_audit_cycle_for_agent=fn(_) {
      record_calls = record_calls + 1
      99
    },
    audit_cycle_count_for_agent=fn(_) { 2 },
    task_contract_reader=merge_pr_test_empty_contract_reader,
  )
  match resp {
    @types.Response::Err(msg) => {
      assert_true(
        msg.contains("policy blocked: audit receipt gate blocked PR #96"),
      )
      assert_true(msg.contains("audit loop exhausted after 2 cycle(s)"))
    }
    @types.Response::Ok(_) => fail("expected exhausted audit loop block")
  }
  assert_false(runner_called)
  assert_eq(record_calls, 0)
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "interpret_merge_pr audit spawn failure blocks before merge and logs audit_block" {
  let project_dir = "/tmp/choir-mpr-audit-spawn-fail-" +
    @sys.get_pid().to_string()
  let head = "abcdef1234567890abcdef1234567890abcdef12"
  let ps = @poller.PollerState::new()
  ps.track_recovered(
    93,
    "main.leaf",
    "feature/audit-gate",
    "main",
    "https://github.com/o/r/pull/93",
    200L,
    @poller.ReviewState::Approved,
    "",
    head,
    @poller.CiRollupStatus::Success,
    true,
  )
  let logs : Array[String] = []
  let mut runner_called = false
  let resp = interpret_merge_pr(
    {
      pr_number: 93,
      parent_branch: "main",
      caller_id: "main.tl",
      review_mode: Some(@types.ReviewMode::SinglePass),
    },
    project_dir,
    Some(ps),
    None,
    None,
    async fn(cmds : Array[@workspace.Command]) -> Array[Int] {
      @async.sleep(0)
      runner_called = true
      let statuses = []
      for _ in cmds {
        statuses.push(1)
      }
      statuses
    },
    async fn(cmd : @workspace.Command) -> (Int, String) {
      @async.sleep(0)
      if cmd.program == "gh" &&
        cmd.args.length() >= 2 &&
        cmd.args[0] == "api" &&
        cmd.args[1].has_suffix("/reviews") {
        return (0, "[{\"state\":\"APPROVED\"}]")
      }
      if cmd.program == "timeout" && cmd.args.contains("repo") {
        return (0, "{\"owner\":{\"login\":\"o\"},\"name\":\"r\"}")
      }
      if cmd.program == "timeout" && cmd.args.contains("graphql") {
        return (
          0, "{\"data\":{\"repository\":{\"pullRequest\":{\"reviewThreads\":{\"nodes\":[]}}}}}",
        )
      }
      if cmd.program == "git" &&
        cmd.args == ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"] {
        return (0, "origin/main\n")
      }
      if cmd.program == "git" &&
        cmd.args == ["rev-parse", "--abbrev-ref", "HEAD"] {
        return (0, "feature/audit-gate\n")
      }
      if cmd.program == "cat" {
        return (1, "")
      }
      (1, "spawn failed")
    },
    fn(_path, content) {
      logs.push(content)
      true
    },
    fn(_) { false },
    read_file=fn(path) {
      if path.has_suffix("/.choir/audit-gate.json") {
        "{\"enabled_at_unix\":100}\n"
      } else {
        ""
      }
    },
    write_file_atomic=fn(_, _) { false },
    create_dir_all=fn(_) { true },
    task_contract_reader=merge_pr_test_empty_contract_reader,
  )
  match resp {
    @types.Response::Err(msg) => {
      if !msg.contains("policy blocked: audit receipt gate blocked PR #93") {
        fail("unexpected merge_pr error: " + msg)
      }
      assert_true(msg.contains("could not start auto-audit"))
      assert_true(msg.contains("Run `/audit` manually"))
    }
    @types.Response::Ok(_) => fail("expected audit spawn failure block")
  }
  assert_true(runner_called)
  assert_true(
    logs.iter().any(fn(line) { line.contains("outcome=audit_block") }),
  )
  assert_true(
    logs
    .iter()
    .any(fn(line) { line.contains("audit_gate=auto_audit_spawn_failed") }),
  )
  ignore(@sys.rm_rf(project_dir))
}

///|
fn merge_pr_test_verify_contract(
  verify : Array[String],
  verify_satisfied_by_ci? : Bool = true,
) -> @types.TaskContract {
  {
    ..@types.TaskContract::empty(),
    goal: "merge verified work",
    verify,
    verify_satisfied_by_ci,
  }
}

///|
fn merge_pr_test_contract_reader(
  contract : @types.TaskContract,
) -> (String) -> @types.TaskContract? {
  fn(_agent_id : String) -> @types.TaskContract? { Some(contract) }
}

///|
fn merge_pr_test_empty_contract_reader(
  _agent_id : String,
) -> @types.TaskContract? {
  Some(merge_pr_test_verify_contract([]))
}

///|
fn merge_pr_test_write_beads_contract(
  project_dir : String,
  parent_branch : String,
  slug : String,
  issue_id : String?,
) -> String {
  let worktree = project_dir + "/.choir/worktrees/" + slug
  ignore(@sys.create_dir_all(worktree + "/.choir"))
  let target : @types.LocalTarget = {
    kind: ZellijTab,
    session: "choir",
    name: slug,
  }
  let spec : @types.SpawnSpec = {
    slug,
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Codex,
    task: "assigned leaf",
    task_contract: Some({
      ..@types.TaskContract::empty(),
      goal: "assigned leaf",
      beads_issue_id: issue_id,
    }),
    isolation: @types.IsolationMode::Worktree,
    parent_id: "main.tl",
    parent_branch,
    reuse_workspace: false,
    workspace_slug: None,
    reuse_git_branch: None,
    spawn_depth: 0,
    automerge: None,
    review_mode: None,
    wave_id: Some("wv-feature"),
  }
  ignore(
    @sys.write_file_sync(
      worktree + "/.choir/config.local.toml",
      @workspace.config_local_content(spec, worktree, target),
    ),
  )
  worktree
}

///|
fn merge_pr_test_registry_for_feature(
  project_dir : String,
  feature_branch : String,
  leaves : Array[(String, String)],
) -> @registry.AgentRegistry {
  let reg = @registry.AgentRegistry::new()
  ignore(
    reg.upsert({
      agent_id: @types.AgentId("main.tl"),
      role: @types.Role::TL,
      agent_type: @types.AgentType::Codex,
      parent: None,
      workspace: project_dir,
      branch: feature_branch,
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  for leaf in leaves {
    let (slug, worktree) = leaf
    let branch = feature_branch + "." + slug
    ignore(
      reg.upsert({
        agent_id: @types.AgentId(branch),
        role: @types.Role::Dev,
        agent_type: @types.AgentType::Codex,
        parent: Some("main.tl"),
        workspace: worktree,
        branch,
        terminal_target: None,
        host: @types.Host::Local,
        spawn_depth: 0,
        state: @types.AgentState::Active,
      }),
    )
  }
  reg
}

///|
async fn merge_pr_test_runner_record_ok(
  cmds : Array[@workspace.Command],
  seen : Array[@workspace.Command],
) -> Array[Int] {
  @async.sleep(0)
  let statuses = []
  for cmd in cmds {
    seen.push(cmd)
    statuses.push(0)
  }
  statuses
}

///|
test "merge_pr_preflight_host_steps is poller snapshot then thread fetch" {
  let steps = merge_pr_preflight_host_steps()
  assert_eq(steps.length(), 2)
  assert_eq(steps[0], MergePrPreflightHostStep::PollerSnapshot)
  assert_eq(steps[1], MergePrPreflightHostStep::FetchUnresolvedReviewThreads)
}

///|
test "parse_github_owner_repo_from_url accepts pr and git remotes" {
  @debug.assert_eq(
    parse_github_owner_repo_from_url("https://github.com/o/r/pull/7"),
    Some(("o", "r")),
  )
  @debug.assert_eq(
    parse_github_owner_repo_from_url("git@github.com:o/r.git\n"),
    Some(("o", "r")),
  )
}

///|
test "merge_pr_review_gate_block_message allows empty reviews" {
  match merge_pr_review_gate_block_message(4, "[]") {
    Ok(None) => ()
    Ok(Some(msg)) => fail("expected empty reviews to pass: " + msg)
    Err(e) => fail(e.message())
  }
}

///|
test "merge_pr_review_gate_block_message allows commented reviews" {
  match
    merge_pr_review_gate_block_message(
      4, "[{\"state\":\"COMMENTED\",\"user\":{\"login\":\"copilot\"},\"submitted_at\":\"2026-01-01T00:00:00Z\"}]",
    ) {
    Ok(None) => ()
    Ok(Some(msg)) => fail("expected commented reviews to pass: " + msg)
    Err(e) => fail(e.message())
  }
}

///|
test "merge_pr_review_gate_block_message blocks changes requested" {
  match
    merge_pr_review_gate_block_message(
      4,
      (
        #|[{"state":"APPROVED","user":{"login":"a"},"submitted_at":"2026-01-01T00:00:00Z"},{"state":"CHANGES_REQUESTED","user":{"login":"b"},"submitted_at":"2026-01-02T00:00:00Z"}]
      ),
    ) {
    Ok(Some(msg)) => assert_true(msg.contains("requesting changes"))
    _ => fail("expected changes requested block")
  }
}

///|
test "merge_pr_review_gate_block_message ignores stale changes requested after same reviewer approves" {
  let reviews =
    #|[
    #|  {"state":"CHANGES_REQUESTED","user":{"login":"reviewer"},"submitted_at":"2026-01-01T00:00:00Z"},
    #|  {"state":"APPROVED","user":{"login":"reviewer"},"submitted_at":"2026-01-02T00:00:00Z"}
    #|]
  match merge_pr_review_gate_block_message(4, reviews) {
    Ok(None) => ()
    Ok(Some(msg)) => fail("expected stale changes requested to clear: " + msg)
    Err(e) => fail(e.message())
  }
}

///|
test "merge_pr_review_gate_block_message uses submitted_at over array order" {
  let reviews =
    #|[
    #|  {"state":"APPROVED","user":{"login":"reviewer"},"submitted_at":"2026-01-02T00:00:00Z"},
    #|  {"state":"CHANGES_REQUESTED","user":{"login":"reviewer"},"submitted_at":"2026-01-01T00:00:00Z"}
    #|]
  match merge_pr_review_gate_block_message(4, reviews) {
    Ok(None) => ()
    Ok(Some(msg)) =>
      fail("expected older changes requested to be ignored: " + msg)
    Err(e) => fail(e.message())
  }
}

///|
/// When both `submitted_at` values fail to parse, fall back to array order
/// (last-in-response wins) so the gate stays operational against format
/// regressions instead of silently preferring the first entry.
test "merge_pr_review_gate_block_message falls back to array order on unparseable submitted_at" {
  let reviews =
    #|[
    #|  {"state":"APPROVED","user":{"login":"reviewer"},"submitted_at":"not-a-date"},
    #|  {"state":"CHANGES_REQUESTED","user":{"login":"reviewer"},"submitted_at":"also-not-a-date"}
    #|]
  match merge_pr_review_gate_block_message(4, reviews) {
    Ok(Some(_)) => ()
    Ok(None) =>
      fail("expected later CHANGES_REQUESTED to win via array-order fallback")
    Err(e) => fail(e.message())
  }
}

///|
async fn mock_preflight_capture_changes_requested_reviews(
  cmd : @workspace.Command,
) -> (Int, String) {
  @async.sleep(0)
  if cmd.program == "git" && cmd.args == ["remote", "get-url", "origin"] {
    return (0, "https://github.com/o/r.git\n")
  }
  if cmd.program == "gh" &&
    cmd.args.length() >= 2 &&
    cmd.args[0] == "api" &&
    cmd.args[1].has_suffix("/reviews") {
    return (0, "[{\"state\":\"CHANGES_REQUESTED\"}]")
  }
  (0, "")
}

///|
async fn mock_preflight_capture_empty_reviews(
  cmd : @workspace.Command,
) -> (Int, String) {
  @async.sleep(0)
  if cmd.program == "git" && cmd.args == ["remote", "get-url", "origin"] {
    return (0, "https://github.com/o/r.git\n")
  }
  if cmd.program == "gh" &&
    cmd.args.length() >= 2 &&
    cmd.args[0] == "api" &&
    cmd.args[1].has_suffix("/reviews") {
    return (0, "[]")
  }
  if cmd.args.contains("repo") {
    return (0, "{\"owner\":{\"login\":\"o\"},\"name\":\"r\"}")
  }
  if cmd.args.contains("graphql") {
    return (
      0, "{\"data\":{\"repository\":{\"pullRequest\":{\"reviewThreads\":{\"nodes\":[]}}}}}",
    )
  }
  (0, "")
}

///|
async test "interpret_merge_pr_preflight review gate blocks changes requested" {
  let got = interpret_merge_pr_preflight(
    42,
    None,
    "/tmp",
    "main.tl",
    mock_preflight_capture_changes_requested_reviews,
  )
  match got {
    Err(e) => assert_true(e.message().contains("requesting changes"))
    Ok(_) => fail("expected Err: changes requested must block merge")
  }
}

///|
async test "interpret_merge_pr_preflight review gate passes without approval" {
  let got = interpret_merge_pr_preflight(
    42,
    None,
    "/tmp",
    "main.tl",
    mock_preflight_capture_empty_reviews,
  )
  match got {
    Ok(_) => ()
    Err(e) => fail(e.message())
  }
}

///|
async fn mock_preflight_capture_no_unresolved_threads(
  cmd : @workspace.Command,
) -> (Int, String) {
  @async.sleep(0)
  if cmd.program == "git" && cmd.args == ["remote", "get-url", "origin"] {
    return (0, "https://github.com/o/r.git\n")
  }
  if cmd.program == "gh" &&
    cmd.args.length() >= 2 &&
    cmd.args[0] == "api" &&
    cmd.args[1].has_suffix("/reviews") {
    return (0, "[{\"state\":\"APPROVED\"}]")
  }
  if cmd.args.contains("repo") {
    return (0, "{\"owner\":{\"login\":\"o\"},\"name\":\"r\"}")
  }
  if cmd.args.contains("graphql") {
    return (
      0, "{\"data\":{\"repository\":{\"pullRequest\":{\"reviewThreads\":{\"nodes\":[]}}}}}",
    )
  }
  (0, "")
}

///|
async test "interpret_merge_pr_preflight ok when no poller block and no threads" {
  let project_dir = "/tmp/choir-mpf-ok-" + @sys.get_pid().to_string()
  let got = interpret_merge_pr_preflight(
    7,
    None,
    project_dir,
    "main.tl",
    mock_preflight_capture_no_unresolved_threads,
  )
  match got {
    Ok(_) => ()
    Err(e) => fail(e.message())
  }
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "interpret_merge_pr_preflight fails closed when server contract missing" {
  let project_dir = "/tmp/choir-mpf-missing-contract-" +
    @sys.get_pid().to_string()
  ignore(@sys.rm_rf(project_dir))
  let ps = @poller.PollerState::new()
  ps.tracked.set(7, {
    ..merge_pr_test_tracked(@poller.ReviewState::Approved, "main.leaf"),
    pr_number: 7,
    last_ci_rollup: @poller.CiRollupStatus::Success,
    mergeable: @poller.Mergeable::Unknown,
    merge_state_status: @poller.MergeStateStatus::Unknown,
    merged_at_unix: None,
  })
  let got = interpret_merge_pr_preflight(
    7,
    Some(ps),
    project_dir,
    "main.tl",
    mock_preflight_capture_no_unresolved_threads,
  )
  match got {
    Err(e) => {
      let msg = e.message()
      assert_true(msg.contains("server task contract unavailable"))
      assert_true(msg.contains("main.leaf"))
      assert_true(msg.contains("refusing to evaluate merge verify gate"))
    }
    Ok(_) => fail("expected missing server contract to block merge_pr")
  }
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "interpret_merge_pr_preflight accepts required verify evidence" {
  let project_dir = "/tmp/choir-mpf-verify-evidence-" +
    @sys.get_pid().to_string()
  ignore(@sys.rm_rf(project_dir))
  let contract = merge_pr_test_verify_contract(["moon test --target native"])
  ignore(
    @evidence.append_agent_evidence_event(
      @sys.append_file_sync,
      project_dir,
      "main.leaf",
      1L,
      @evidence.EvidenceEvent::VerifyResultObserved(
        name="moon test --target native",
        ok=true,
        details=Some("exit: 0"),
      ),
    ),
  )
  let ps = @poller.PollerState::new()
  ps.tracked.set(7, {
    ..merge_pr_test_tracked(@poller.ReviewState::Approved, "main.leaf"),
    pr_number: 7,
    last_ci_rollup: @poller.CiRollupStatus::Success,
    mergeable: @poller.Mergeable::Unknown,
    merge_state_status: @poller.MergeStateStatus::Unknown,
    merged_at_unix: None,
  })
  let got = interpret_merge_pr_preflight(
    7,
    Some(ps),
    project_dir,
    "main.tl",
    mock_preflight_capture_no_unresolved_threads,
    task_contract_reader=merge_pr_test_contract_reader(contract),
  )
  match got {
    Ok(_) => ()
    Err(e) => fail("expected verify evidence to satisfy policy: " + e.message())
  }
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "interpret_merge_pr_preflight matches normalized moon verify evidence" {
  let project_dir = "/tmp/choir-mpf-normalized-verify-" +
    @sys.get_pid().to_string()
  ignore(@sys.rm_rf(project_dir))
  let contract = merge_pr_test_verify_contract(["moon check"])
  ignore(
    @evidence.append_agent_evidence_event(
      @sys.append_file_sync,
      project_dir,
      "main.leaf",
      1L,
      @evidence.EvidenceEvent::VerifyResultObserved(
        name="moon check --target native",
        ok=true,
        details=Some("exit: 0"),
      ),
    ),
  )
  let ps = @poller.PollerState::new()
  ps.tracked.set(7, {
    ..merge_pr_test_tracked(@poller.ReviewState::Approved, "main.leaf"),
    pr_number: 7,
    last_ci_rollup: @poller.CiRollupStatus::Success,
    mergeable: @poller.Mergeable::Unknown,
    merge_state_status: @poller.MergeStateStatus::Unknown,
    merged_at_unix: None,
  })
  let got = interpret_merge_pr_preflight(
    7,
    Some(ps),
    project_dir,
    "main.tl",
    mock_preflight_capture_no_unresolved_threads,
    task_contract_reader=merge_pr_test_contract_reader(contract),
  )
  match got {
    Ok(_) => ()
    Err(e) =>
      fail(
        "expected normalized verify evidence to satisfy policy: " + e.message(),
      )
  }
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "interpret_merge_pr_preflight rejects stale verify evidence" {
  let project_dir = "/tmp/choir-mpf-stale-verify-" + @sys.get_pid().to_string()
  ignore(@sys.rm_rf(project_dir))
  let contract = merge_pr_test_verify_contract(["moon test --target native"])
  ignore(
    @evidence.append_agent_evidence_event(
      @sys.append_file_sync,
      project_dir,
      "main.leaf",
      1L,
      @evidence.EvidenceEvent::VerifyResultObserved(
        name="moon test --target native",
        ok=true,
        details=Some("cwd: /wt\nexit: 0\nhead: old-sha"),
      ),
    ),
  )
  let ps = @poller.PollerState::new()
  ps.tracked.set(7, {
    ..merge_pr_test_tracked(@poller.ReviewState::Approved, "main.leaf"),
    pr_number: 7,
    last_sha: "new-sha",
    last_ci_rollup: @poller.CiRollupStatus::Success,
    mergeable: @poller.Mergeable::Unknown,
    merge_state_status: @poller.MergeStateStatus::Unknown,
    merged_at_unix: None,
  })
  let got = interpret_merge_pr_preflight(
    7,
    Some(ps),
    project_dir,
    "main.tl",
    mock_preflight_capture_no_unresolved_threads,
    task_contract_reader=merge_pr_test_contract_reader(contract),
  )
  match got {
    Err(e) => assert_true(e.message().contains("local verify not observed"))
    Ok(_) => fail("expected stale verify evidence to block")
  }
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "interpret_merge_pr_preflight accepts CI-satisfied verify at head" {
  let project_dir = "/tmp/choir-mpf-ci-verify-" + @sys.get_pid().to_string()
  ignore(@sys.rm_rf(project_dir))
  let contract = merge_pr_test_verify_contract(["moon test --target native"])
  ignore(
    @evidence.append_agent_evidence_event(
      @sys.append_file_sync,
      project_dir,
      "main.leaf",
      1L,
      @evidence.EvidenceEvent::CiObserved(
        status=@evidence.EvidenceCiStatus::Success,
        head_sha=Some("head-x"),
      ),
    ),
  )
  let ps = @poller.PollerState::new()
  ps.tracked.set(7, {
    ..merge_pr_test_tracked(@poller.ReviewState::Approved, "main.leaf"),
    pr_number: 7,
    last_sha: "head-x",
    last_ci_rollup: @poller.CiRollupStatus::Success,
    mergeable: @poller.Mergeable::Unknown,
    merge_state_status: @poller.MergeStateStatus::Unknown,
    merged_at_unix: None,
  })
  let got = interpret_merge_pr_preflight(
    7,
    Some(ps),
    project_dir,
    "main.tl",
    mock_preflight_capture_no_unresolved_threads,
    task_contract_reader=merge_pr_test_contract_reader(contract),
  )
  match got {
    Ok(_) => ()
    Err(e) =>
      fail("expected CI evidence to satisfy verify policy: " + e.message())
  }
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "interpret_merge_pr_preflight rejects CI-only verify for non-native moon target" {
  let project_dir = "/tmp/choir-mpf-ci-verify-nonnative-" +
    @sys.get_pid().to_string()
  ignore(@sys.rm_rf(project_dir))
  let contract = merge_pr_test_verify_contract(["moon check"])
  ignore(
    @evidence.append_agent_evidence_event(
      @sys.append_file_sync,
      project_dir,
      "main.leaf",
      1L,
      @evidence.EvidenceEvent::CiObserved(
        status=@evidence.EvidenceCiStatus::Success,
        head_sha=Some("head-x"),
      ),
    ),
  )
  let ps = @poller.PollerState::new()
  ps.tracked.set(7, {
    ..merge_pr_test_tracked(@poller.ReviewState::Approved, "main.leaf"),
    pr_number: 7,
    last_sha: "head-x",
    last_ci_rollup: @poller.CiRollupStatus::Success,
    mergeable: @poller.Mergeable::Unknown,
    merge_state_status: @poller.MergeStateStatus::Unknown,
    merged_at_unix: None,
  })
  let got = interpret_merge_pr_preflight(
    7,
    Some(ps),
    project_dir,
    "main.tl",
    mock_preflight_capture_no_unresolved_threads,
    task_contract_reader=merge_pr_test_contract_reader(contract),
    moon_verify_target=@types.MoonVerifyTarget::WasmGc,
  )
  match got {
    Err(e) => assert_true(e.message().contains("local verify not observed"))
    Ok(_) => fail("expected non-native target to require local verify evidence")
  }
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "interpret_merge_pr_preflight rejects CI-only verify when disabled or stale" {
  let strict_dir = "/tmp/choir-mpf-ci-verify-strict-" +
    @sys.get_pid().to_string()
  ignore(@sys.rm_rf(strict_dir))
  let strict_contract = merge_pr_test_verify_contract(
    ["moon test --target native"],
    verify_satisfied_by_ci=false,
  )
  ignore(
    @evidence.append_agent_evidence_event(
      @sys.append_file_sync,
      strict_dir,
      "main.leaf",
      1L,
      @evidence.EvidenceEvent::CiObserved(
        status=@evidence.EvidenceCiStatus::Success,
        head_sha=Some("head-x"),
      ),
    ),
  )
  let strict_ps = @poller.PollerState::new()
  strict_ps.tracked.set(7, {
    ..merge_pr_test_tracked(@poller.ReviewState::Approved, "main.leaf"),
    pr_number: 7,
    last_sha: "head-x",
    last_ci_rollup: @poller.CiRollupStatus::Success,
    mergeable: @poller.Mergeable::Unknown,
    merge_state_status: @poller.MergeStateStatus::Unknown,
    merged_at_unix: None,
  })
  let strict = interpret_merge_pr_preflight(
    7,
    Some(strict_ps),
    strict_dir,
    "main.tl",
    mock_preflight_capture_no_unresolved_threads,
    task_contract_reader=merge_pr_test_contract_reader(strict_contract),
  )
  match strict {
    Err(e) => assert_true(e.message().contains("local verify not observed"))
    Ok(_) => fail("expected strict verify policy to require local evidence")
  }
  let stale_dir = "/tmp/choir-mpf-ci-verify-stale-" + @sys.get_pid().to_string()
  ignore(@sys.rm_rf(stale_dir))
  let stale_contract = merge_pr_test_verify_contract([
    "moon test --target native",
  ])
  ignore(
    @evidence.append_agent_evidence_event(
      @sys.append_file_sync,
      stale_dir,
      "main.leaf",
      1L,
      @evidence.EvidenceEvent::CiObserved(
        status=@evidence.EvidenceCiStatus::Success,
        head_sha=Some("head-x"),
      ),
    ),
  )
  let stale_ps = @poller.PollerState::new()
  stale_ps.tracked.set(7, {
    ..merge_pr_test_tracked(@poller.ReviewState::Approved, "main.leaf"),
    pr_number: 7,
    last_sha: "head-y",
    last_ci_rollup: @poller.CiRollupStatus::Success,
    mergeable: @poller.Mergeable::Unknown,
    merge_state_status: @poller.MergeStateStatus::Unknown,
    merged_at_unix: None,
  })
  let stale = interpret_merge_pr_preflight(
    7,
    Some(stale_ps),
    stale_dir,
    "main.tl",
    mock_preflight_capture_no_unresolved_threads,
    task_contract_reader=merge_pr_test_contract_reader(stale_contract),
  )
  match stale {
    Err(e) => assert_true(e.message().contains("local verify not observed"))
    Ok(_) => fail("expected stale CI head to require local evidence")
  }
  ignore(@sys.rm_rf(strict_dir))
  ignore(@sys.rm_rf(stale_dir))
}

///|
async fn mock_preflight_capture_one_unresolved_thread(
  cmd : @workspace.Command,
) -> (Int, String) {
  @async.sleep(0)
  if cmd.program == "git" && cmd.args == ["remote", "get-url", "origin"] {
    return (0, "https://github.com/o/r.git\n")
  }
  if cmd.program == "gh" &&
    cmd.args.length() >= 2 &&
    cmd.args[0] == "api" &&
    cmd.args[1].has_suffix("/reviews") {
    return (0, "[{\"state\":\"APPROVED\"}]")
  }
  if cmd.args.contains("repo") {
    return (0, "{\"owner\":{\"login\":\"o\"},\"name\":\"r\"}")
  }
  if cmd.args.contains("graphql") {
    let body =
      #|{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"PRRT_abc","isResolved":false,"path":"src/x.mbt","comments":{"nodes":[{"body":"fix it"}]}}]}}}}}
    return (0, body)
  }
  (0, "")
}

///|
async test "interpret_merge_pr_preflight err when review threads unresolved" {
  let project_dir = "/tmp/choir-mpf-threads-" + @sys.get_pid().to_string()
  let got = interpret_merge_pr_preflight(
    3,
    None,
    project_dir,
    "main.tl",
    mock_preflight_capture_one_unresolved_thread,
  )
  match got {
    Err(e) => {
      let msg = e.message()
      assert_true(msg.contains("PR #3"))
      assert_true(msg.contains("unresolved review thread"))
      assert_true(msg.contains("fix it"))
    }
    Ok(_) => fail("expected Err")
  }
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "interpret_merge_pr_preflight err when poller ChangesRequested" {
  let ps = @poller.PollerState::new()
  ps.track_recovered(
    9,
    "main.leaf",
    "main.topic",
    "main",
    "https://github.com/o/r/pull/9",
    0L,
    @poller.ReviewState::ChangesRequested,
    "",
    "",
    @poller.CiRollupStatus::Unknown,
    false,
  )
  let project_dir = "/tmp/choir-mpf-cr-" + @sys.get_pid().to_string()
  let got = interpret_merge_pr_preflight(
    9,
    Some(ps),
    project_dir,
    "main.tl",
    mock_preflight_capture_no_unresolved_threads,
    task_contract_reader=merge_pr_test_empty_contract_reader,
  )
  match got {
    Err(e) => assert_true(e.message().contains("ChangesRequested"))
    Ok(_) => fail("expected Err from poller gate")
  }
  ignore(@sys.rm_rf(project_dir))
}

///|
test "merge_pr_preflight_block_message prefers ChangesRequested over thread gate" {
  let t = merge_pr_test_tracked(
    @poller.ReviewState::ChangesRequested,
    "main.leaf",
  )
  match merge_pr_preflight_block_message(9, Some(t), 2, "threads", None) {
    Some(msg) => {
      assert_true(msg.contains("ChangesRequested"))
      assert_false(msg.contains("unresolved review thread"))
    }
    None => fail("expected block")
  }
}

///|
test "merge_pr_preflight_block_message blocks on unresolved threads" {
  match merge_pr_preflight_block_message(3, None, 1, "body", None) {
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
test "merge_pr_preflight_block_message gh thread fetch failed marker" {
  match
    merge_pr_preflight_block_message(
      5,
      None,
      1,
      review_thread_fetch_failed_marker,
      None,
    ) {
    Some(msg) => {
      assert_true(msg.contains("merge blocked: gh unavailable"))
      assert_true(msg.contains("could not fetch review thread state"))
      assert_true(msg.contains("manually advance lifecycle"))
      assert_false(msg.contains("resolve_review_thread"))
    }
    None => fail("expected block")
  }
}

///|
test "merge_pr_preflight_block_message allows Approved with no threads" {
  let t = merge_pr_test_tracked(@poller.ReviewState::Approved, "main.leaf")
  @debug.assert_eq(
    merge_pr_preflight_block_message(9, Some(t), 0, "", None),
    None,
  )
}

///|
test "merge_pr_preflight_block_message policy Blocked" {
  let policy_decision = Some(
    @policy.MergeDecision::Blocked(reason="insufficient evidence"),
  )
  match merge_pr_preflight_block_message(9, None, 0, "", policy_decision) {
    Some(msg) => {
      assert_true(msg.contains("policy blocked: insufficient evidence"))
      assert_false(msg.contains("force=true"))
    }
    None => fail("expected block")
  }
}

///|
test "merge_pr_preflight_block_message policy Wait" {
  let policy_decision = Some(@policy.MergeDecision::Wait(reason="pending CI"))
  match merge_pr_preflight_block_message(9, None, 0, "", policy_decision) {
    Some(msg) => {
      assert_true(msg.contains("policy wait: pending CI"))
      assert_false(msg.contains("force=true"))
    }
    None => fail("expected wait")
  }
}

///|
test "merge_pr_preflight_block_message policy NeedsHuman" {
  let policy_decision = Some(
    @policy.MergeDecision::NeedsHuman(reason="manual check"),
  )
  match merge_pr_preflight_block_message(9, None, 0, "", policy_decision) {
    Some(msg) => {
      assert_true(msg.contains("policy requires human check: manual check"))
      assert_false(msg.contains("force=true"))
    }
    None => fail("expected needs human")
  }
}

///|
test "format_tl_pr_recheck_summary ready snapshot when approved success zero threads" {
  let t : @poller.TrackedPR = {
    ..merge_pr_test_tracked(@poller.ReviewState::Approved, "main.leaf"),
    last_ci_rollup: @poller.CiRollupStatus::Success,
    mergeable: @poller.Mergeable::Unknown,
    merge_state_status: @poller.MergeStateStatus::Unknown,
    merged_at_unix: None,
  }
  let s = format_tl_pr_recheck_summary(t, "/repo", Some(0))
  assert_true(s.contains("no tracked blockers"))
  assert_true(s.contains("Does not merge"))
  assert_true(s.contains("success"))
  assert_true(s.contains("GitHub Copilot issue comment (REST): not seen"))
  assert_true(s.contains("Advisory evaluation verdict: ready"))
  assert_true(s.contains("Merge policy decision: merge_now"))
}

///|
test "format_tl_pr_recheck_summary lists blockers for changes requested" {
  let t : @poller.TrackedPR = {
    ..merge_pr_test_tracked(@poller.ReviewState::ChangesRequested, "main.leaf"),
    last_ci_rollup: @poller.CiRollupStatus::Success,
    mergeable: @poller.Mergeable::Unknown,
    merge_state_status: @poller.MergeStateStatus::Unknown,
    merged_at_unix: None,
  }
  let s = format_tl_pr_recheck_summary(t, "/repo", Some(0))
  assert_true(s.contains("GitHub review requests changes"))
  assert_false(s.contains("no tracked blockers"))
  assert_true(s.contains("Advisory evaluation verdict: blocked"))
  assert_true(s.contains("Merge policy decision: blocked"))
}

///|
test "format_tl_pr_recheck_summary uses tracked SinglePass mode consistently after fixes" {
  let t : @poller.TrackedPR = {
    ..merge_pr_test_tracked(@poller.ReviewState::ChangesRequested, "main.leaf"),
    last_ci_rollup: @poller.CiRollupStatus::Success,
    mergeable: @poller.Mergeable::Unknown,
    merge_state_status: @poller.MergeStateStatus::Unknown,
    merged_at_unix: None,
    fixes_pushed_at: 1_700_000_000L,
    last_sha: "fixed-sha",
    review_mode: @types.ReviewMode::SinglePass,
  }
  let s = format_tl_pr_recheck_summary(t, "/repo", Some(0))
  assert_true(s.contains("no tracked blockers"))
  assert_true(s.contains("Advisory evaluation verdict: ready"))
  assert_true(s.contains("Merge policy decision: merge_now"))
  assert_false(s.contains("Advisory evaluation verdict: blocked"))
  assert_false(s.contains("Merge policy decision: blocked"))
}

///|
test "format_tl_pr_recheck_summary does not claim ready when thread count not fetched" {
  let t : @poller.TrackedPR = {
    ..merge_pr_test_tracked(@poller.ReviewState::Approved, "main.leaf"),
    last_ci_rollup: @poller.CiRollupStatus::Success,
    mergeable: @poller.Mergeable::Unknown,
    merge_state_status: @poller.MergeStateStatus::Unknown,
    merged_at_unix: None,
  }
  let s = format_tl_pr_recheck_summary(t, "/repo", None)
  assert_true(s.contains("not fetched"))
  assert_false(s.contains("no tracked blockers"))
  assert_true(s.contains("Advisory evaluation verdict: needs_human"))
  assert_true(s.contains("Merge policy decision: needs_human"))
}

///|
test "format_tl_pr_recheck_summary notes Copilot issue comment when seen on merge-ready snapshot" {
  let t : @poller.TrackedPR = {
    ..merge_pr_test_tracked(@poller.ReviewState::Approved, "main.leaf"),
    last_ci_rollup: @poller.CiRollupStatus::Success,
    mergeable: @poller.Mergeable::Unknown,
    merge_state_status: @poller.MergeStateStatus::Unknown,
    merged_at_unix: None,
    copilot_issue_comment_seen: true,
  }
  let s = format_tl_pr_recheck_summary(t, "/repo", Some(0))
  assert_true(s.contains("GitHub Copilot issue comment (REST): seen"))
  assert_true(s.contains("Copilot issue comment observed"))
  assert_true(s.contains("Advisory evaluation verdict: ready"))
  assert_true(s.contains("Merge policy decision: merge_now"))
}

///|
test "format_tl_pr_recheck_summary policy needs human when required verify is missing" {
  let t : @poller.TrackedPR = {
    ..merge_pr_test_tracked(@poller.ReviewState::Approved, "main.leaf"),
    last_ci_rollup: @poller.CiRollupStatus::Success,
    mergeable: @poller.Mergeable::Unknown,
    merge_state_status: @poller.MergeStateStatus::Unknown,
    merged_at_unix: None,
  }
  let contract = {
    ..@types.TaskContract::empty(),
    goal: "ship feature",
    verify: ["moon test --target native"],
  }
  let s = format_tl_pr_recheck_summary(
    t,
    "/repo",
    Some(0),
    task_contract=Some(contract),
  )
  assert_true(s.contains("Advisory evaluation verdict: needs_human"))
  assert_true(s.contains("Merge policy decision: needs_human"))
  assert_true(s.contains("local verify not observed"))
}

///|
test "format_tl_pr_recheck_summary treats matching CI evidence as verify when enabled" {
  let project_dir = "/tmp/choir-recheck-ci-verify-" + @sys.get_pid().to_string()
  ignore(@sys.rm_rf(project_dir))
  let t : @poller.TrackedPR = {
    ..merge_pr_test_tracked(@poller.ReviewState::Approved, "main.leaf"),
    last_sha: "head-x",
    last_ci_rollup: @poller.CiRollupStatus::Success,
    mergeable: @poller.Mergeable::Unknown,
    merge_state_status: @poller.MergeStateStatus::Unknown,
    merged_at_unix: None,
    copilot_issue_comment_seen: true,
  }
  let contract = {
    ..@types.TaskContract::empty(),
    goal: "ship feature",
    verify: ["moon test --target native"],
    verify_satisfied_by_ci: true,
  }
  ignore(
    @evidence.append_agent_evidence_event(
      @sys.append_file_sync,
      project_dir,
      "main.leaf",
      1L,
      @evidence.EvidenceEvent::CiObserved(
        status=@evidence.EvidenceCiStatus::Success,
        head_sha=Some("head-x"),
      ),
    ),
  )
  let ready = format_tl_pr_recheck_summary(
    t,
    project_dir,
    Some(0),
    task_contract=Some(contract),
  )
  assert_true(ready.contains("Advisory evaluation verdict: ready"))
  assert_true(ready.contains("Merge policy decision: merge_now"))
  let strict = format_tl_pr_recheck_summary(
    t,
    project_dir,
    Some(0),
    task_contract=Some({ ..contract, verify_satisfied_by_ci: false }),
  )
  assert_true(strict.contains("Advisory evaluation verdict: needs_human"))
  assert_true(strict.contains("local verify not observed"))
  let stale = format_tl_pr_recheck_summary(
    { ..t, last_sha: "head-y" },
    project_dir,
    Some(0),
    task_contract=Some(contract),
  )
  assert_true(stale.contains("Advisory evaluation verdict: needs_human"))
  assert_true(stale.contains("local verify not observed"))
  let non_native_config = format_tl_pr_recheck_summary(
    t,
    project_dir,
    Some(0),
    task_contract=Some({ ..contract, verify: ["moon test"] }),
    moon_verify_target=@types.MoonVerifyTarget::WasmGc,
  )
  assert_true(
    non_native_config.contains("Advisory evaluation verdict: needs_human"),
  )
  assert_true(non_native_config.contains("local verify not observed"))
  let explicit_non_native = format_tl_pr_recheck_summary(
    t,
    project_dir,
    Some(0),
    task_contract=Some({ ..contract, verify: ["moon test --target wasm-gc"] }),
  )
  assert_true(
    explicit_non_native.contains("Advisory evaluation verdict: needs_human"),
  )
  assert_true(explicit_non_native.contains("local verify not observed"))
  ignore(@sys.rm_rf(project_dir))
}

///|
test "format_tl_pr_recheck_summary reads verify evidence from ledger" {
  let project_dir = "/tmp/choir-recheck-verify-evidence-" +
    @sys.get_pid().to_string()
  ignore(@sys.rm_rf(project_dir))
  let t : @poller.TrackedPR = {
    ..merge_pr_test_tracked(@poller.ReviewState::Approved, "main.leaf"),
    last_ci_rollup: @poller.CiRollupStatus::Success,
    mergeable: @poller.Mergeable::Unknown,
    merge_state_status: @poller.MergeStateStatus::Unknown,
    merged_at_unix: None,
  }
  let contract = {
    ..@types.TaskContract::empty(),
    goal: "ship feature",
    verify: ["moon test --target native"],
  }
  ignore(
    @evidence.append_agent_evidence_event(
      @sys.append_file_sync,
      project_dir,
      "main.leaf",
      1L,
      @evidence.EvidenceEvent::VerifyResultObserved(
        name="moon test --target native",
        ok=true,
        details=Some("exit: 0"),
      ),
    ),
  )
  let s = format_tl_pr_recheck_summary(
    t,
    project_dir,
    Some(0),
    task_contract=Some(contract),
  )
  assert_true(s.contains("Advisory evaluation verdict: ready"))
  assert_true(s.contains("Merge policy decision: merge_now"))
  assert_true(s.contains("local verify passed"))
  ignore(@sys.rm_rf(project_dir))
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
      @debug.assert_eq(map.get("status"), Some(String::to_json("merged")))
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
test "merge_pr_serialization_busy_message_with_position annotates only for >= 2" {
  let base = merge_pr_serialization_busy_message()
  assert_eq(merge_pr_serialization_busy_message_with_position(0), base)
  assert_eq(merge_pr_serialization_busy_message_with_position(1), base)
  assert_eq(
    merge_pr_serialization_busy_message_with_position(3),
    base + " (position 3 in queue)",
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
  if cmd.program == "git" && cmd.args == ["remote", "get-url", "origin"] {
    return (0, "https://github.com/o/r.git\n")
  }
  if cmd.program == "gh" &&
    cmd.args.length() >= 2 &&
    cmd.args[0] == "api" &&
    cmd.args[1].has_suffix("/reviews") {
    return (0, "[{\"state\":\"APPROVED\"}]")
  }
  if cmd.args.contains("repo") {
    return (0, "{\"owner\":{\"login\":\"o\"},\"name\":\"r\"}")
  }
  if cmd.args.contains("graphql") {
    return (
      0, "{\"data\":{\"repository\":{\"pullRequest\":{\"reviewThreads\":{\"nodes\":[]}}}}}",
    )
  }
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
    Err(e) => fail("expected Ok got " + e.message())
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
    Err(e) =>
      assert_eq(
        e.message(),
        @types.ChoirError::git_error(
          merge_pr_merge_failure_message(4, "permission denied"),
        ).message(),
      )
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
    Err(e) =>
      assert_eq(
        e.message(),
        @types.ChoirError::validation_error(
          merge_pr_serialization_busy_message(),
        ).message(),
      )
    Ok(_) => fail("expected busy Err")
  }
}

///|
async test "interpret_merge_pr_merge_host holds mutex across failure capture" {
  let reg = @registry.MutexRegistry::new()
  let name = merge_pr_mutex_name("main")
  let events : Array[String] = []
  let capture_count : Ref[Int] = @ref.new(0)
  let failure_capture_saw_holder : Ref[Bool] = @ref.new(false)
  let runner = async fn(cmds : Array[@workspace.Command]) -> Array[Int] {
    @async.sleep(0)
    let (holder, _) = reg.status(name)
    @debug.assert_eq(holder, Some("main.tl"))
    events.push("mutex_acquire")
    events.push("merge")
    let statuses = []
    for i = 0; i < cmds.length(); i = i + 1 {
      statuses.push(if i == 0 { 1 } else { 0 })
    }
    statuses
  }
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    if cmd.program == "gh" && cmd.args == ["pr", "merge", "4", "--merge"] {
      capture_count.val += 1
      let (holder, _) = reg.status(name)
      @debug.assert_eq(holder, Some("main.tl"))
      if capture_count.val == 1 {
        events.push("strict_failure_capture")
      } else if capture_count.val == 2 {
        failure_capture_saw_holder.val = holder == Some("main.tl")
        events.push("failure_capture")
      } else {
        fail("unexpected extra merge capture")
      }
      return (1, "permission denied\n")
    }
    (0, "")
  }
  let got = interpret_merge_pr_merge_host(
    "main",
    4,
    "main.tl",
    Some(reg),
    50L,
    runner,
    capture,
  )
  match got {
    Err(e) =>
      assert_eq(
        e.message(),
        @types.ChoirError::git_error(
          merge_pr_merge_failure_message(4, "permission denied"),
        ).message(),
      )
    Ok(_) => fail("expected Err")
  }
  let (holder, queue) = reg.status(name)
  @debug.assert_eq(holder, None)
  assert_eq(queue.length(), 0)
  events.push("mutex_release")
  assert_eq(capture_count.val, 2)
  assert_true(failure_capture_saw_holder.val)
  assert_eq(events.length(), 5)
  assert_eq(events[0], "mutex_acquire")
  assert_eq(events[1], "merge")
  assert_eq(events[2], "strict_failure_capture")
  assert_eq(events[3], "failure_capture")
  assert_eq(events[4], "mutex_release")
}

///|
async test "interpret_merge_pr_merge_host returns busy for overlapping failure-capture merge" {
  let reg = @registry.MutexRegistry::new()
  let name = merge_pr_mutex_name("main")
  let capture_count : Ref[Int] = @ref.new(0)
  let second_runner_calls : Ref[Int] = @ref.new(0)
  let second_message : Ref[String] = @ref.new("")
  let second_runner = async fn(
    _cmds : Array[@workspace.Command],
  ) -> Array[Int] {
    @async.sleep(0)
    second_runner_calls.val += 1
    fail(
      "second merge should not run while the first merge is inspecting failure",
    )
    []
  }
  let second_capture = async fn(_cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    (0, "")
  }
  let first_runner = async fn(cmds : Array[@workspace.Command]) -> Array[Int] {
    @async.sleep(0)
    let statuses = []
    for i = 0; i < cmds.length(); i = i + 1 {
      statuses.push(if i == 0 { 1 } else { 0 })
    }
    statuses
  }
  let first_capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    if cmd.program == "gh" && cmd.args == ["pr", "merge", "4", "--merge"] {
      capture_count.val += 1
      if capture_count.val == 2 {
        let second = interpret_merge_pr_merge_host(
          "main",
          5,
          "second",
          Some(reg),
          50L,
          second_runner,
          second_capture,
        )
        match second {
          Err(e) => second_message.val = e.message()
          Ok(_) => fail("expected second merge to be busy")
        }
      }
      return (1, "permission denied\n")
    }
    (0, "")
  }
  let first = interpret_merge_pr_merge_host(
    "main",
    4,
    "first",
    Some(reg),
    50L,
    first_runner,
    first_capture,
  )
  match first {
    Err(e) =>
      assert_eq(
        e.message(),
        @types.ChoirError::git_error(
          merge_pr_merge_failure_message(4, "permission denied"),
        ).message(),
      )
    Ok(_) => fail("expected first merge Err")
  }
  assert_eq(
    second_message.val,
    @types.ChoirError::validation_error(
      merge_pr_serialization_busy_message_with_position(1),
    ).message(),
  )
  assert_eq(second_runner_calls.val, 0)
  let (holder, queue) = reg.status(name)
  @debug.assert_eq(holder, None)
  assert_eq(queue.length(), 0)
}

///|
async fn mock_runner_merge_pr_must_not_run(
  _cmds : Array[@workspace.Command],
) -> Array[Int] {
  @async.sleep(0)
  fail("merge host should not run after preflight Err")
  []
}

///|
async test "interpret_merge_pr returns preflight err without merge host" {
  let ps = @poller.PollerState::new()
  ps.track_recovered(
    9,
    "main.leaf",
    "main.topic",
    "main",
    "https://github.com/o/r/pull/9",
    0L,
    @poller.ReviewState::ChangesRequested,
    "",
    "",
    @poller.CiRollupStatus::Unknown,
    false,
  )
  let args : MergePrArgs = {
    pr_number: 9,
    parent_branch: "main",
    caller_id: "main.tl",
    review_mode: Some(@types.ReviewMode::SinglePass),
  }
  let project_dir = "/tmp/choir-mpr-preflight-" + @sys.get_pid().to_string()
  let got = interpret_merge_pr(
    args,
    project_dir,
    Some(ps),
    None,
    None,
    mock_runner_merge_pr_must_not_run,
    mock_preflight_capture_no_unresolved_threads,
    @sys.append_file_sync,
    @sys.path_entry_exists,
    task_contract_reader=merge_pr_test_empty_contract_reader,
  )
  match got {
    @types.Response::Err(msg) => assert_true(msg.contains("ChangesRequested"))
    _ => fail("expected preflight Err")
  }
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "interpret_merge_pr returns merge host err after passing preflight" {
  let args : MergePrArgs = {
    pr_number: 4,
    parent_branch: "main",
    caller_id: "main.tl",
    review_mode: Some(@types.ReviewMode::SinglePass),
  }
  let project_dir = "/tmp/choir-mpr-host-err-" + @sys.get_pid().to_string()
  let got = interpret_merge_pr(
    args,
    project_dir,
    None,
    None,
    None,
    mock_merge_host_runner_gh_fails,
    mock_merge_host_capture_for_merge,
    @sys.append_file_sync,
    @sys.path_entry_exists,
  )
  match got {
    @types.Response::Err(msg) =>
      assert_eq(
        msg,
        @types.ChoirError::git_error(
          merge_pr_merge_failure_message(4, "permission denied"),
        ).message(),
      )
    _ => fail("expected merge host Err")
  }
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "interpret_merge_pr ok response matches merged envelope" {
  let project_dir = "/tmp/choir-mpr-interpret-" + @sys.get_pid().to_string()
  let args : MergePrArgs = {
    pr_number: 77,
    parent_branch: "main",
    caller_id: "main.tl",
    review_mode: Some(@types.ReviewMode::SinglePass),
  }
  let got = interpret_merge_pr(
    args,
    project_dir,
    None,
    None,
    None,
    mock_merge_host_runner_ok,
    mock_preflight_capture_no_unresolved_threads,
    @sys.append_file_sync,
    @sys.path_entry_exists,
  )
  match got {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      @debug.assert_eq(map.get("status"), Some(String::to_json("merged")))
    }
    _ => fail("expected ok merged")
  }
  ignore(@sys.rm_rf(project_dir))
}

///|
test "merge_pr_closes_issue_ids_from_body matches literal closes regex" {
  let ids = merge_pr_closes_issue_ids_from_body(
    "prefix Closes choir-a.1\ncloses\tchoir-b-2\nCLOSES choir-nope\nCloses not-choir\n",
  )
  assert_eq(ids.length(), 2)
  assert_true(ids.contains("choir-a.1"))
  assert_true(ids.contains("choir-b-2"))
}

///|
test "merge_pr_closes_issue_ids_from_body captures all ids on a comma- or space-separated Closes line" {
  // PR descriptions often list multiple beads after a single `Closes` keyword.
  // The previous parser stopped after the first id, leaving the rest open.
  let ids = merge_pr_closes_issue_ids_from_body(
    "Closes choir-aaa, choir-bbb,choir-ccc choir-ddd\nThen prose continues choir-not-counted\n",
  )
  assert_eq(ids.length(), 4)
  assert_true(ids.contains("choir-aaa"))
  assert_true(ids.contains("choir-bbb"))
  assert_true(ids.contains("choir-ccc"))
  assert_true(ids.contains("choir-ddd"))
  assert_false(ids.contains("choir-not-counted"))
}

///|
test "merge_pr_beads_show_status_and_open_children detects epic children" {
  let show =
    #|[{"id":"choir-parent","status":"open","epic_closeable":false,"dependents":[{"id":"choir-child","status":"open"}]}]
  match merge_pr_beads_show_status_and_open_children(show) {
    Ok((status, has_open_children)) => {
      assert_eq(status, "open")
      assert_true(has_open_children)
    }
    Err(e) => fail(e.message())
  }
}

///|
async test "interpret_merge_pr feature main closes wave and body beads then deletes feature branch" {
  let project_dir = "/tmp/choir-mpr-feature-beads-" + @sys.get_pid().to_string()
  ignore(@sys.rm_rf(project_dir))
  let feature_branch = "feature/demo"
  let leaf_a = merge_pr_test_write_beads_contract(
    project_dir,
    feature_branch,
    "leaf-a",
    Some("choir-a"),
  )
  let leaf_b = merge_pr_test_write_beads_contract(
    project_dir,
    feature_branch,
    "leaf-b",
    Some("choir-b"),
  )
  match
    save_wave_index(
      project_dir,
      WaveIndex::new("wv-feature", feature_branch, 1L, [
        feature_branch + ".leaf-a",
        feature_branch + ".leaf-b",
      ]),
    ) {
    Ok(_) => ()
    Err(e) => fail(e.message())
  }
  let reg = merge_pr_test_registry_for_feature(project_dir, feature_branch, [
    ("leaf-a", leaf_a),
    ("leaf-b", leaf_b),
  ])
  let task_contracts : Map[String, @types.TaskContract] = {}
  task_contracts.set("main.tl", {
    ..@types.TaskContract::empty(),
    goal: "feature integration",
  })
  task_contracts.set(feature_branch + ".leaf-a", {
    ..@types.TaskContract::empty(),
    goal: "assigned leaf",
    beads_issue_id: Some("choir-a"),
  })
  task_contracts.set(feature_branch + ".leaf-b", {
    ..@types.TaskContract::empty(),
    goal: "assigned leaf",
    beads_issue_id: Some("choir-b"),
  })
  let ps = @poller.PollerState::new()
  ps.track_recovered(
    77,
    "main.tl",
    feature_branch,
    "main",
    "https://github.com/o/r/pull/77",
    0L,
    @poller.ReviewState::Approved,
    "",
    "",
    @poller.CiRollupStatus::Success,
    true,
  )
  let closed : Array[String] = []
  let audited : Array[String] = []
  let ran : Array[@workspace.Command] = []
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    if cmd.program == "gh" &&
      cmd.args.length() >= 2 &&
      cmd.args[0] == "api" &&
      cmd.args[1].has_suffix("/reviews") {
      return (0, "[{\"state\":\"APPROVED\"}]")
    }
    if cmd.args.contains("repo") {
      return (0, "{\"owner\":{\"login\":\"o\"},\"name\":\"r\"}")
    }
    if cmd.args.contains("graphql") {
      return (
        0, "{\"data\":{\"repository\":{\"pullRequest\":{\"reviewThreads\":{\"nodes\":[]}}}}}",
      )
    }
    if cmd.program == "timeout" &&
      cmd.args == ["30s", "gh", "pr", "view", "77", "--json", "body"] {
      return (0, "{\"body\":\"Closes choir-body\\ncloses choir-a\\n\"}")
    }
    if cmd.program == "bd" &&
      cmd.args.length() == 4 &&
      cmd.args[0] == "--readonly" &&
      cmd.args[1] == "show" {
      let id = cmd.args[2]
      return (
        0,
        "[{\"id\":\"" + id + "\",\"title\":\"t\",\"status\":\"open\"}]",
      )
    }
    if cmd.program == "bd" && cmd.args.length() == 4 && cmd.args[0] == "close" {
      closed.push(cmd.args[1])
      assert_eq(cmd.args[2], "--reason")
      assert_eq(cmd.args[3], "completed via PR #77")
      return (0, "")
    }
    if cmd.program == "bd" &&
      cmd.args.length() >= 10 &&
      cmd.args[0] == "audit" &&
      cmd.args[1] == "record" {
      assert_true(cmd.args.contains("--tool-name"))
      assert_true(cmd.args.contains("merge_pr"))
      assert_true(cmd.args.contains("--response"))
      assert_true(cmd.args.contains("closed via PR #77"))
      assert_true(cmd.args.contains("--issue-id"))
      let mut issue_index = -1
      for i = 0; i < cmd.args.length(); i = i + 1 {
        if cmd.args[i] == "--issue-id" {
          issue_index = i
        }
      }
      assert_true(issue_index >= 0 && issue_index + 1 < cmd.args.length())
      audited.push(cmd.args[issue_index + 1])
      return (0, "")
    }
    (0, "")
  }
  let runner = async fn(cmds : Array[@workspace.Command]) -> Array[Int] {
    merge_pr_test_runner_record_ok(cmds, ran)
  }
  let logs : Array[String] = []
  let append_file = fn(_path : String, content : String) -> Bool {
    logs.push(content)
    true
  }
  let args : MergePrArgs = {
    pr_number: 77,
    parent_branch: "main",
    caller_id: "main.tl",
    review_mode: Some(@types.ReviewMode::SinglePass),
  }
  let got = interpret_merge_pr(
    args,
    project_dir,
    Some(ps),
    None,
    Some(reg),
    runner,
    capture,
    append_file,
    fn(_path) { false },
    read_file=merge_pr_test_gate_state_reader(1L),
    task_contract_reader=fn(agent_id) { task_contracts.get(agent_id) },
  )
  match got {
    @types.Response::Ok(_) => ()
    @types.Response::Err(msg) => fail(msg)
  }
  assert_eq(closed.length(), 3)
  assert_true(closed.contains("choir-a"))
  assert_true(closed.contains("choir-b"))
  assert_true(closed.contains("choir-body"))
  assert_eq(audited.length(), 3)
  assert_true(audited.contains("choir-a"))
  assert_true(audited.contains("choir-b"))
  assert_true(audited.contains("choir-body"))
  assert_true(
    ran
    .iter()
    .any(fn(cmd) {
      cmd.program == "git" &&
      cmd.args == ["checkout", "main"] &&
      cmd.workdir == Some(project_dir)
    }),
  )
  assert_true(
    ran
    .iter()
    .any(fn(cmd) {
      cmd.program == "git" &&
      cmd.args == ["branch", "-D", feature_branch] &&
      cmd.workdir == Some(project_dir)
    }),
  )
  assert_true(logs.length() > 0)
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "interpret_merge_pr feature main with no issue ids does not call bd close" {
  let project_dir = "/tmp/choir-mpr-feature-no-beads-" +
    @sys.get_pid().to_string()
  ignore(@sys.rm_rf(project_dir))
  let feature_branch = "feature/no-beads"
  let leaf = merge_pr_test_write_beads_contract(
    project_dir,
    feature_branch,
    "leaf-a",
    None,
  )
  match
    save_wave_index(
      project_dir,
      WaveIndex::new("wv-feature", feature_branch, 1L, [
        feature_branch + ".leaf-a",
      ]),
    ) {
    Ok(_) => ()
    Err(e) => fail(e.message())
  }
  let reg = merge_pr_test_registry_for_feature(project_dir, feature_branch, [
    ("leaf-a", leaf),
  ])
  let ps = @poller.PollerState::new()
  ps.track_recovered(
    78,
    "main.tl",
    feature_branch,
    "main",
    "https://github.com/o/r/pull/78",
    0L,
    @poller.ReviewState::Approved,
    "",
    "",
    @poller.CiRollupStatus::Success,
    true,
  )
  let closed : Array[String] = []
  let ran : Array[@workspace.Command] = []
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    if cmd.program == "gh" &&
      cmd.args.length() >= 2 &&
      cmd.args[0] == "api" &&
      cmd.args[1].has_suffix("/reviews") {
      return (0, "[{\"state\":\"APPROVED\"}]")
    }
    if cmd.args.contains("repo") {
      return (0, "{\"owner\":{\"login\":\"o\"},\"name\":\"r\"}")
    }
    if cmd.args.contains("graphql") {
      return (
        0, "{\"data\":{\"repository\":{\"pullRequest\":{\"reviewThreads\":{\"nodes\":[]}}}}}",
      )
    }
    if cmd.program == "gh" && cmd.args == ["pr", "view", "78", "--json", "body"] {
      return (0, "{\"body\":\"No closing lines here.\"}")
    }
    if cmd.program == "bd" && cmd.args.length() > 0 && cmd.args[0] == "close" {
      closed.push(cmd.args[1])
    }
    (0, "")
  }
  let runner = async fn(cmds : Array[@workspace.Command]) -> Array[Int] {
    merge_pr_test_runner_record_ok(cmds, ran)
  }
  let args : MergePrArgs = {
    pr_number: 78,
    parent_branch: "main",
    caller_id: "main.tl",
    review_mode: Some(@types.ReviewMode::SinglePass),
  }
  let got = interpret_merge_pr(
    args,
    project_dir,
    Some(ps),
    None,
    Some(reg),
    runner,
    capture,
    fn(_path, _content) { true },
    fn(_path) { false },
    read_file=merge_pr_test_gate_state_reader(1L),
    task_contract_reader=merge_pr_test_empty_contract_reader,
  )
  match got {
    @types.Response::Ok(_) => ()
    @types.Response::Err(msg) => fail(msg)
  }
  assert_eq(closed.length(), 0)
  assert_true(
    ran
    .iter()
    .any(fn(cmd) {
      cmd.program == "git" &&
      cmd.args == ["branch", "-D", feature_branch] &&
      cmd.workdir == Some(project_dir)
    }),
  )
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "interpret_merge_pr leaf merge removes worktree and deletes local branch" {
  let project_dir = "/tmp/choir-mpr-leaf-cleanup-" + @sys.get_pid().to_string()
  ignore(@sys.rm_rf(project_dir))
  let feature_branch = "feature/demo"
  let leaf_branch = feature_branch + ".leaf-a"
  let leaf = merge_pr_test_write_beads_contract(
    project_dir,
    feature_branch,
    "leaf-a",
    Some("choir-a"),
  )
  let reg = merge_pr_test_registry_for_feature(project_dir, feature_branch, [
    ("leaf-a", leaf),
  ])
  let ps = @poller.PollerState::new()
  ps.track_recovered(
    79,
    leaf_branch,
    leaf_branch,
    feature_branch,
    "https://github.com/o/r/pull/79",
    0L,
    @poller.ReviewState::Approved,
    "",
    "",
    @poller.CiRollupStatus::Success,
    true,
  )
  let ran : Array[@workspace.Command] = []
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    if cmd.program == "gh" &&
      cmd.args.length() >= 2 &&
      cmd.args[0] == "api" &&
      cmd.args[1].has_suffix("/reviews") {
      return (0, "[{\"state\":\"APPROVED\"}]")
    }
    if cmd.args.contains("repo") {
      return (0, "{\"owner\":{\"login\":\"o\"},\"name\":\"r\"}")
    }
    if cmd.args.contains("graphql") {
      return (
        0, "{\"data\":{\"repository\":{\"pullRequest\":{\"reviewThreads\":{\"nodes\":[]}}}}}",
      )
    }
    if cmd.program == "bd" && cmd.args.length() > 0 && cmd.args[0] == "close" {
      fail("leaf PR merge must not close beads")
    }
    (0, "")
  }
  let runner = async fn(cmds : Array[@workspace.Command]) -> Array[Int] {
    merge_pr_test_runner_record_ok(cmds, ran)
  }
  let args : MergePrArgs = {
    pr_number: 79,
    parent_branch: feature_branch,
    caller_id: "main.tl",
    review_mode: Some(@types.ReviewMode::SinglePass),
  }
  let got = interpret_merge_pr(
    args,
    project_dir,
    Some(ps),
    None,
    Some(reg),
    runner,
    capture,
    fn(_path, _content) { true },
    fn(path) { path == leaf },
    task_contract_reader=merge_pr_test_empty_contract_reader,
  )
  match got {
    @types.Response::Ok(_) => ()
    @types.Response::Err(msg) => fail(msg)
  }
  assert_true(
    ran
    .iter()
    .any(fn(cmd) {
      cmd.program == "git" &&
      cmd.args == ["worktree", "remove", "--force", leaf]
    }),
  )
  assert_true(
    ran
    .iter()
    .any(fn(cmd) {
      cmd.program == "git" &&
      cmd.args == ["branch", "-D", leaf_branch] &&
      cmd.workdir == Some(project_dir)
    }),
  )
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "dispatch merge_pr routes injected append_file and path_exists" {
  let project_dir = "/tmp/choir-mpr-dispatch-inject-" +
    @sys.get_pid().to_string()
  ignore(@sys.rm_rf(project_dir))
  let feature_branch = "feature/dispatch-cleanup"
  let leaf_branch = feature_branch + ".leaf-a"
  let leaf = merge_pr_test_write_beads_contract(
    project_dir,
    feature_branch,
    "leaf-a",
    Some("choir-a"),
  )
  let reg = merge_pr_test_registry_for_feature(project_dir, feature_branch, [
    ("leaf-a", leaf),
  ])
  let ps = @poller.PollerState::new()
  ps.track_recovered(
    81,
    leaf_branch,
    leaf_branch,
    feature_branch,
    "https://github.com/o/r/pull/81",
    0L,
    @poller.ReviewState::Approved,
    "",
    "",
    @poller.CiRollupStatus::Success,
    true,
  )
  let logs : Array[String] = []
  let path_checks : Array[String] = []
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    if cmd.program == "gh" &&
      cmd.args.length() >= 2 &&
      cmd.args[0] == "api" &&
      cmd.args[1].has_suffix("/reviews") {
      return (0, "[{\"state\":\"APPROVED\"}]")
    }
    if cmd.args.contains("repo") {
      return (0, "{\"owner\":{\"login\":\"o\"},\"name\":\"r\"}")
    }
    if cmd.args.contains("graphql") {
      return (
        0, "{\"data\":{\"repository\":{\"pullRequest\":{\"reviewThreads\":{\"nodes\":[]}}}}}",
      )
    }
    (0, "")
  }
  let resp = dispatch(
    ToolRequest::MergePr({
      pr_number: 81,
      parent_branch: feature_branch,
      caller_id: "main.tl",
      review_mode: Some(@types.ReviewMode::SinglePass),
    }),
    project_dir~,
    poller_state=Some(ps),
    registry=Some(reg),
    runner=mock_merge_host_runner_ok,
    capture~,
    append_file=fn(_path, content) {
      logs.push(content)
      true
    },
    path_exists=fn(path) {
      path_checks.push(path)
      path == leaf
    },
    task_contract_reader=merge_pr_test_empty_contract_reader,
  )
  match resp {
    @types.Response::Ok(_) => ()
    @types.Response::Err(msg) => fail("expected dispatch merge success: " + msg)
  }
  assert_true(path_checks.contains(leaf))
  assert_true(logs.length() > 0)
  assert_true(logs.iter().any(fn(line) { line.contains("merge_pr cleanup") }))
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "interpret_merge_pr leaf merge skips missing worktree and still deletes branch" {
  let project_dir = "/tmp/choir-mpr-leaf-no-worktree-" +
    @sys.get_pid().to_string()
  ignore(@sys.rm_rf(project_dir))
  let feature_branch = "feature/no-worktree"
  let leaf_branch = feature_branch + ".leaf-a"
  let ps = @poller.PollerState::new()
  ps.track_recovered(
    80,
    leaf_branch,
    leaf_branch,
    feature_branch,
    "https://github.com/o/r/pull/80",
    0L,
    @poller.ReviewState::Approved,
    "",
    "",
    @poller.CiRollupStatus::Success,
    true,
  )
  let ran : Array[@workspace.Command] = []
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    if cmd.program == "gh" &&
      cmd.args.length() >= 2 &&
      cmd.args[0] == "api" &&
      cmd.args[1].has_suffix("/reviews") {
      return (0, "[{\"state\":\"APPROVED\"}]")
    }
    if cmd.args.contains("repo") {
      return (0, "{\"owner\":{\"login\":\"o\"},\"name\":\"r\"}")
    }
    if cmd.args.contains("graphql") {
      return (
        0, "{\"data\":{\"repository\":{\"pullRequest\":{\"reviewThreads\":{\"nodes\":[]}}}}}",
      )
    }
    (0, "")
  }
  let runner = async fn(cmds : Array[@workspace.Command]) -> Array[Int] {
    merge_pr_test_runner_record_ok(cmds, ran)
  }
  let args : MergePrArgs = {
    pr_number: 80,
    parent_branch: feature_branch,
    caller_id: "main.tl",
    review_mode: Some(@types.ReviewMode::SinglePass),
  }
  let got = interpret_merge_pr(
    args,
    project_dir,
    Some(ps),
    None,
    None,
    runner,
    capture,
    fn(_path, _content) { true },
    fn(_path) { false },
    task_contract_reader=merge_pr_test_empty_contract_reader,
  )
  match got {
    @types.Response::Ok(_) => ()
    @types.Response::Err(msg) => fail(msg)
  }
  assert_false(
    ran
    .iter()
    .any(fn(cmd) {
      cmd.program == "git" &&
      cmd.args.length() >= 2 &&
      cmd.args[0] == "worktree" &&
      cmd.args[1] == "remove"
    }),
  )
  assert_true(
    ran
    .iter()
    .any(fn(cmd) {
      cmd.program == "git" &&
      cmd.args == ["branch", "-D", leaf_branch] &&
      cmd.workdir == Some(project_dir)
    }),
  )
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "interpret_merge_pr leaf cleanup refuses supervisor tracked agent" {
  let project_dir = "/tmp/choir-mpr-supervisor-cleanup-" +
    @sys.get_pid().to_string()
  ignore(@sys.rm_rf(project_dir))
  let feature_branch = "feature/supervisor-cleanup"
  let leaf_branch = feature_branch + ".root"
  let reg = @registry.AgentRegistry::new()
  ignore(
    reg.upsert({
      agent_id: @types.AgentId("root"),
      role: @types.Role::TL,
      agent_type: @types.AgentType::Claude,
      parent: None,
      workspace: project_dir,
      branch: feature_branch,
      terminal_target: Some({
        kind: @types.TargetKind::ZellijTab,
        session: "s",
        name: "TL",
      }),
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  let ps = @poller.PollerState::new()
  ps.track_recovered(
    82,
    "root",
    leaf_branch,
    feature_branch,
    "https://github.com/o/r/pull/82",
    0L,
    @poller.ReviewState::Approved,
    "",
    "",
    @poller.CiRollupStatus::Success,
    true,
  )
  let ran : Array[@workspace.Command] = []
  let logs : Array[String] = []
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    if cmd.program == "gh" &&
      cmd.args.length() >= 2 &&
      cmd.args[0] == "api" &&
      cmd.args[1].has_suffix("/reviews") {
      return (0, "[{\"state\":\"APPROVED\"}]")
    }
    if cmd.args.contains("repo") {
      return (0, "{\"owner\":{\"login\":\"o\"},\"name\":\"r\"}")
    }
    if cmd.args.contains("graphql") {
      return (
        0, "{\"data\":{\"repository\":{\"pullRequest\":{\"reviewThreads\":{\"nodes\":[]}}}}}",
      )
    }
    (0, "")
  }
  let runner = async fn(cmds : Array[@workspace.Command]) -> Array[Int] {
    merge_pr_test_runner_record_ok(cmds, ran)
  }
  let got = interpret_merge_pr(
    {
      pr_number: 82,
      parent_branch: feature_branch,
      caller_id: "main.tl",
      review_mode: Some(@types.ReviewMode::SinglePass),
    },
    project_dir,
    Some(ps),
    None,
    Some(reg),
    runner,
    capture,
    fn(_path, content) {
      logs.push(content)
      true
    },
    fn(path) { path == project_dir },
    task_contract_reader=merge_pr_test_empty_contract_reader,
  )
  match got {
    @types.Response::Ok(_) => ()
    @types.Response::Err(msg) => fail(msg)
  }
  assert_false(
    ran
    .iter()
    .any(fn(cmd) {
      cmd.program == "git" &&
      cmd.args.length() >= 2 &&
      cmd.args[0] == "worktree" &&
      cmd.args[1] == "remove"
    }),
  )
  assert_false(
    ran
    .iter()
    .any(fn(cmd) {
      cmd.program == "git" &&
      cmd.args.length() >= 2 &&
      cmd.args[0] == "branch" &&
      cmd.args[1] == "-D"
    }),
  )
  assert_true(
    logs.iter().any(fn(line) { line.contains("outcome=supervisor_agent") }),
  )
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "interpret_merge_pr leaf cleanup trusts dev lifecycle over stale supervisor role" {
  let project_dir = "/tmp/choir-mpr-stale-role-cleanup-" +
    @sys.get_pid().to_string()
  ignore(@sys.rm_rf(project_dir))
  assert_true(@sys.create_dir_all(project_dir + "/.choir/kv"))
  let feature_branch = "feature/stale-role-cleanup"
  let leaf_branch = feature_branch + ".leaf"
  let leaf_id = "main.stale-role-leaf"
  let leaf_worktree = project_dir + "/.choir/worktrees/stale-role-leaf"
  let reg = @registry.AgentRegistry::new()
  ignore(
    reg.upsert({
      agent_id: @types.AgentId(leaf_id),
      role: @types.Role::TL,
      agent_type: @types.AgentType::Codex,
      parent: Some("main.tl"),
      workspace: leaf_worktree,
      branch: leaf_branch,
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  let lifecycle : @phase.AgentLifecycle = {
    agent_id: leaf_id,
    role: @types.Role::Dev,
    process: @phase.ProcessState::Connected,
    workflow: @phase.WorkflowState::Dev(
      @phase.DevLifecycle::ReviewOwned(
        pr_number=83,
        state=@phase.ReviewOwnership::ApprovedAwaitingMerge,
      ),
    ),
    last_updated_unix_sec: 0L,
  }
  let ps = @poller.PollerState::new()
  ps.track_recovered(
    83,
    leaf_id,
    leaf_branch,
    feature_branch,
    "https://github.com/o/r/pull/83",
    0L,
    @poller.ReviewState::Approved,
    "",
    "",
    @poller.CiRollupStatus::Success,
    true,
  )
  let ran : Array[@workspace.Command] = []
  let logs : Array[String] = []
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    if cmd.program == "gh" &&
      cmd.args.length() >= 2 &&
      cmd.args[0] == "api" &&
      cmd.args[1].has_suffix("/reviews") {
      return (0, "[{\"state\":\"APPROVED\"}]")
    }
    if cmd.args.contains("repo") {
      return (0, "{\"owner\":{\"login\":\"o\"},\"name\":\"r\"}")
    }
    if cmd.args.contains("graphql") {
      return (
        0, "{\"data\":{\"repository\":{\"pullRequest\":{\"reviewThreads\":{\"nodes\":[]}}}}}",
      )
    }
    (0, "")
  }
  let runner = async fn(cmds : Array[@workspace.Command]) -> Array[Int] {
    merge_pr_test_runner_record_ok(cmds, ran)
  }
  let got = interpret_merge_pr(
    {
      pr_number: 83,
      parent_branch: feature_branch,
      caller_id: "main.tl",
      review_mode: Some(@types.ReviewMode::SinglePass),
    },
    project_dir,
    Some(ps),
    None,
    Some(reg),
    runner,
    capture,
    fn(_path, content) {
      logs.push(content)
      true
    },
    fn(path) { path == leaf_worktree },
    read_lifecycle=fn(_project_dir, agent_id) {
      if agent_id == leaf_id {
        Some(lifecycle)
      } else {
        None
      }
    },
    task_contract_reader=merge_pr_test_empty_contract_reader,
  )
  match got {
    @types.Response::Ok(_) => ()
    @types.Response::Err(msg) => fail(msg)
  }
  assert_true(
    ran
    .iter()
    .any(fn(cmd) {
      cmd.program == "git" &&
      cmd.args == ["worktree", "remove", "--force", leaf_worktree]
    }),
  )
  assert_true(
    ran
    .iter()
    .any(fn(cmd) {
      cmd.program == "git" &&
      cmd.args == ["branch", "-D", leaf_branch] &&
      cmd.workdir == Some(project_dir)
    }),
  )
  assert_false(
    logs.iter().any(fn(line) { line.contains("outcome=supervisor_agent") }),
  )
  ignore(@sys.rm_rf(project_dir))
}

///|
test "merge_pr_tracked_branch_for_post_success is None without poller" {
  @debug.assert_eq(merge_pr_tracked_branch_for_post_success(None, 1), None)
}

///|
test "merge_pr_tracked_branch_for_post_success is None when PR not tracked" {
  let ps = @poller.PollerState::new()
  @debug.assert_eq(merge_pr_tracked_branch_for_post_success(Some(ps), 7), None)
}

///|
test "merge_pr_tracked_branch_for_post_success returns branch when tracked" {
  let ps = @poller.PollerState::new()
  ps.track(4, "main.leaf", "main.topic", "main", "https://ex/4", 0L)
  @debug.assert_eq(
    merge_pr_tracked_branch_for_post_success(Some(ps), 4),
    Some("main.topic"),
  )
}

///|
test "resolve_review_thread_gh_command matches graphql argv and workdir" {
  let cmd = resolve_review_thread_gh_command("/repo/root", "PRRT_kwDOabc")
  assert_eq(cmd.program, "timeout")
  @debug.assert_eq(cmd.workdir, Some("/repo/root"))
  @debug.assert_eq(cmd.args, [
    "30s",
    "gh",
    "api",
    "graphql",
    "-f",
    "query=" + resolve_review_thread_graphql_mutation(),
    "-F",
    "threadId=PRRT_kwDOabc",
  ])
}

///|
test "interpret_resolve_review_thread_result maps non-zero exit with stderr" {
  let r = interpret_resolve_review_thread_result(1, "permission denied\n", "T1")
  match r {
    @types.Response::Err(msg) =>
      assert_eq(msg, "resolve_review_thread failed: permission denied")
    _ => fail("expected Err")
  }
}

///|
test "interpret_resolve_review_thread_result maps non-zero exit without output" {
  let r = interpret_resolve_review_thread_result(2, "   \n", "T1")
  match r {
    @types.Response::Err(msg) =>
      assert_eq(msg, "resolve_review_thread failed (exit 2)")
    _ => fail("expected Err")
  }
}

///|
test "interpret_resolve_review_thread_result empty body on success exit" {
  let r = interpret_resolve_review_thread_result(0, "", "T1")
  match r {
    @types.Response::Err(msg) =>
      assert_eq(msg, "resolve_review_thread failed: empty response from gh")
    _ => fail("expected Err")
  }
}

///|
test "interpret_resolve_review_thread_result invalid json" {
  let r = interpret_resolve_review_thread_result(0, "not json", "T1")
  match r {
    @types.Response::Err(msg) =>
      assert_eq(msg, "resolve_review_thread: invalid JSON in gh response")
    _ => fail("expected Err")
  }
}

///|
test "interpret_resolve_review_thread_result unexpected top-level shape" {
  let r = interpret_resolve_review_thread_result(0, "[]", "T1")
  match r {
    @types.Response::Err(msg) =>
      assert_eq(msg, "resolve_review_thread: unexpected response shape")
    _ => fail("expected Err")
  }
}

///|
test "interpret_resolve_review_thread_result graphql errors array first message" {
  let body = "{\"errors\":[{\"message\":\"Thread not found\"}],\"data\":null}"
  let r = interpret_resolve_review_thread_result(0, body, "T1")
  match r {
    @types.Response::Err(msg) =>
      assert_eq(msg, "resolve_review_thread failed: Thread not found")
    _ => fail("expected Err")
  }
}

///|
test "interpret_resolve_review_thread_result graphql error without message field" {
  let body = "{\"errors\":[{}]}"
  let r = interpret_resolve_review_thread_result(0, body, "T1")
  match r {
    @types.Response::Err(msg) =>
      assert_eq(msg, "resolve_review_thread failed: GraphQL error")
    _ => fail("expected Err")
  }
}

///|
test "interpret_resolve_review_thread_result not resolved path" {
  let body = "{\"data\":{\"resolveReviewThread\":{\"thread\":{\"isResolved\":false}}}}"
  let r = interpret_resolve_review_thread_result(0, body, "PRRT_x")
  match r {
    @types.Response::Err(msg) =>
      assert_eq(
        msg, "resolve_review_thread: thread was not marked resolved (check permissions)",
      )
    _ => fail("expected Err")
  }
}

///|
test "interpret_resolve_review_thread_result success envelope" {
  let body = "{\"data\":{\"resolveReviewThread\":{\"thread\":{\"isResolved\":true}}}}"
  let r = interpret_resolve_review_thread_result(0, body, "PRRT_ok")
  match r {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      @debug.assert_eq(map.get("status"), Some(String::to_json("ok")))
      @debug.assert_eq(map.get("thread_id"), Some(String::to_json("PRRT_ok")))
      @debug.assert_eq(map.get("resolved"), Some(Bool::to_json(true)))
    }
    _ => fail("expected Ok")
  }
}

///|
test "should_synthesize_tick_on_resolve truth table" {
  assert_true(should_synthesize_tick_on_resolve(1, 0))
  assert_false(should_synthesize_tick_on_resolve(1, 1))
  assert_false(should_synthesize_tick_on_resolve(5, 5))
  assert_true(should_synthesize_tick_on_resolve(5, 4))
}

///|
async test "dispatch resolve_review_thread triggers pulse for unresolved count drop 1->0" {
  let project_dir = "/tmp/choir-dispatch-resolve-drop-" +
    @sys.get_pid().to_string()
  let ps = @poller.PollerState::new()
  ps.track_recovered(
    111,
    "main.leaf",
    "main.leaf",
    "main",
    "https://github.com/brickfrog/choir/pull/111",
    0L,
    @poller.ReviewState::Approved,
    "",
    "",
    @poller.CiRollupStatus::Success,
    true,
  )
  match ps.get(111) {
    Some(current) =>
      ps.restore({
        ..current,
        unresolved_thread_ids: [
          @poller.ReviewThreadRef::{
            id: "thread-1",
            is_outdated: false,
            author_login: "user-1",
          },
        ],
        unresolved_thread_ids_fetched: true,
      })
    None => fail("expected tracked PR")
  }
  let seen : Array[Int] = []
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    let repo_view_json =
      #|{"owner":{"login":"brickfrog"},"name":"choir"}
    let is_graphql = cmd.args.contains("api") && cmd.args.contains("graphql")
    let is_repo_view = cmd.args.contains("repo") &&
      cmd.args.contains("view") &&
      cmd.args.contains("owner,name")
    let is_resolve = cmd.args
      .iter()
      .any(fn(arg) {
        arg.contains("resolveReviewThread") || arg.contains("query=mutation")
      })
    if (cmd.program == "gh" && is_repo_view) ||
      (
        cmd.program == "timeout" &&
        cmd.args.length() >= 2 &&
        cmd.args == ["30s", "gh", "repo", "view", "--json", "owner,name"]
      ) {
      return (0, repo_view_json)
    }
    if cmd.program == "gh" && is_graphql && is_resolve {
      return (
        0, "{\"data\":{\"resolveReviewThread\":{\"thread\":{\"isResolved\":true}}}}",
      )
    }
    if cmd.program == "timeout" &&
      cmd.args.length() >= 3 &&
      cmd.args[0] == "30s" &&
      cmd.args[1] == "gh" &&
      is_graphql &&
      is_resolve {
      return (
        0, "{\"data\":{\"resolveReviewThread\":{\"thread\":{\"isResolved\":true}}}}",
      )
    }
    if cmd.program == "gh" &&
      is_graphql &&
      cmd.args.iter().any(fn(arg) { arg.contains("reviewThreads") }) {
      return (
        0, "{\"data\":{\"repository\":{\"pullRequest\":{\"reviewThreads\":{\"nodes\":[]}}}}}",
      )
    }
    if cmd.program == "timeout" &&
      cmd.args.length() >= 3 &&
      cmd.args[0] == "30s" &&
      cmd.args[1] == "gh" &&
      is_graphql &&
      cmd.args.iter().any(fn(arg) { arg.contains("reviewThreads") }) {
      return (
        0, "{\"data\":{\"repository\":{\"pullRequest\":{\"reviewThreads\":{\"nodes\":[]}}}}}",
      )
    }
    if is_graphql {
      if is_resolve {
        return (
          0, "{\"data\":{\"resolveReviewThread\":{\"thread\":{\"isResolved\":true}}}}",
        )
      }
      return (
        0, "{\"data\":{\"repository\":{\"pullRequest\":{\"reviewThreads\":{\"nodes\":[]}}}}}",
      )
    }
    (0, "")
  }
  let got = dispatch(
    ToolRequest::ResolveReviewThread({
      thread_id: "PRRT_drop",
      caller_id: "main.leaf",
    }),
    project_dir~,
    poller_state=Some(ps),
    capture~,
    on_resolve_review_thread=fn(pr_numbers : Array[Int]) {
      for n in pr_numbers {
        seen.push(n)
      }
    },
  )
  match got {
    @types.Response::Ok(_) => ()
    _ => fail("expected Ok")
  }
  @debug.assert_eq(seen, [111])
}

///|
async test "dispatch resolve_review_thread triggers pulse for unresolved drop 5->4 (implemented behavior)" {
  let project_dir = "/tmp/choir-dispatch-resolve-drop-5-" +
    @sys.get_pid().to_string()
  let ps = @poller.PollerState::new()
  ps.track_recovered(
    222,
    "main.leaf",
    "main.leaf",
    "main",
    "https://github.com/brickfrog/choir/pull/222",
    0L,
    @poller.ReviewState::Approved,
    "",
    "",
    @poller.CiRollupStatus::Success,
    true,
  )
  match ps.get(222) {
    Some(current) =>
      ps.restore({
        ..current,
        unresolved_thread_ids: [
          @poller.ReviewThreadRef::{
            id: "thread-1",
            is_outdated: false,
            author_login: "user-1",
          },
          @poller.ReviewThreadRef::{
            id: "thread-2",
            is_outdated: false,
            author_login: "user-1",
          },
          @poller.ReviewThreadRef::{
            id: "thread-3",
            is_outdated: false,
            author_login: "user-1",
          },
          @poller.ReviewThreadRef::{
            id: "thread-4",
            is_outdated: false,
            author_login: "user-1",
          },
          @poller.ReviewThreadRef::{
            id: "thread-5",
            is_outdated: false,
            author_login: "user-1",
          },
        ],
        unresolved_thread_ids_fetched: true,
      })
    None => fail("expected tracked PR")
  }
  let seen : Array[Int] = []
  let four_threads = "{\"data\":{\"repository\":{\"pullRequest\":{\"reviewThreads\":{\"nodes\":[{\"id\":\"a\",\"isResolved\":false,\"isOutdated\":false,\"path\":\"src/a\",\"comments\":{\"nodes\":[{\"body\":\"a\",\"author\":{\"login\":\"user-1\"}}]}},{\"id\":\"b\",\"isResolved\":false,\"isOutdated\":false,\"path\":\"src/b\",\"comments\":{\"nodes\":[{\"body\":\"b\",\"author\":{\"login\":\"user-1\"}}]}},{\"id\":\"c\",\"isResolved\":false,\"isOutdated\":false,\"path\":\"src/c\",\"comments\":{\"nodes\":[{\"body\":\"c\",\"author\":{\"login\":\"user-1\"}}]}},{\"id\":\"d\",\"isResolved\":false,\"isOutdated\":false,\"path\":\"src/d\",\"comments\":{\"nodes\":[{\"body\":\"d\",\"author\":{\"login\":\"user-1\"}}]}}]}}}}}"
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    let repo_view_json =
      #|{"owner":{"login":"brickfrog"},"name":"choir"}
    let is_graphql = cmd.args.contains("api") && cmd.args.contains("graphql")
    let is_repo_view = cmd.args.contains("repo") &&
      cmd.args.contains("view") &&
      cmd.args.contains("owner,name")
    let is_resolve = cmd.args
      .iter()
      .any(fn(arg) {
        arg.contains("resolveReviewThread") || arg.contains("query=mutation")
      })
    if (cmd.program == "gh" && is_repo_view) ||
      (
        cmd.program == "timeout" &&
        cmd.args.length() >= 2 &&
        cmd.args[0] == "30s" &&
        cmd.args[1] == "gh" &&
        is_repo_view
      ) {
      return (0, repo_view_json)
    }
    if cmd.program == "gh" && is_graphql && is_resolve {
      return (
        0, "{\"data\":{\"resolveReviewThread\":{\"thread\":{\"isResolved\":true}}}}",
      )
    }
    if cmd.program == "timeout" &&
      cmd.args.length() >= 3 &&
      cmd.args[0] == "30s" &&
      cmd.args[1] == "gh" &&
      is_graphql &&
      is_resolve {
      return (
        0, "{\"data\":{\"resolveReviewThread\":{\"thread\":{\"isResolved\":true}}}}",
      )
    }
    if cmd.program == "gh" &&
      is_graphql &&
      cmd.args.iter().any(fn(arg) { arg.contains("reviewThreads") }) {
      return (0, four_threads)
    }
    if cmd.program == "timeout" &&
      cmd.args.length() >= 3 &&
      cmd.args[0] == "30s" &&
      cmd.args[1] == "gh" &&
      cmd.args.iter().any(fn(arg) { arg.contains("reviewThreads") }) {
      return (0, four_threads)
    }
    if is_graphql {
      if is_resolve {
        return (
          0, "{\"data\":{\"resolveReviewThread\":{\"thread\":{\"isResolved\":true}}}}",
        )
      }
      return (0, four_threads)
    }
    (0, "")
  }
  let got = dispatch(
    ToolRequest::ResolveReviewThread({
      thread_id: "PRRT_drop_many",
      caller_id: "main.leaf",
    }),
    project_dir~,
    poller_state=Some(ps),
    capture~,
    on_resolve_review_thread=fn(pr_numbers : Array[Int]) {
      for n in pr_numbers {
        seen.push(n)
      }
    },
  )
  match got {
    @types.Response::Ok(_) => ()
    _ => fail("expected Ok")
  }
  @debug.assert_eq(seen, [222])
  match ps.get(222) {
    Some(current) => assert_eq(current.unresolved_thread_ids.length(), 4)
    None => fail("expected tracked PR")
  }
}

///|
async test "dispatch resolve_review_thread skips pulse when after-count fetch fails" {
  let project_dir = "/tmp/choir-dispatch-resolve-fetch-fail-" +
    @sys.get_pid().to_string()
  let ps = @poller.PollerState::new()
  ps.track_recovered(
    333,
    "main.leaf",
    "main.leaf",
    "main",
    "https://github.com/brickfrog/choir/pull/333",
    0L,
    @poller.ReviewState::Approved,
    "",
    "",
    @poller.CiRollupStatus::Success,
    true,
  )
  match ps.get(333) {
    Some(current) =>
      ps.restore({
        ..current,
        unresolved_thread_ids: [
          @poller.ReviewThreadRef::{
            id: "thread-1",
            is_outdated: false,
            author_login: "user-1",
          },
          @poller.ReviewThreadRef::{
            id: "thread-2",
            is_outdated: false,
            author_login: "user-1",
          },
        ],
        unresolved_thread_ids_fetched: true,
      })
    None => fail("expected tracked PR")
  }
  let seen : Array[Int] = []
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    let is_graphql = cmd.args.contains("api") && cmd.args.contains("graphql")
    let is_repo_view = cmd.args.contains("repo") &&
      cmd.args.contains("view") &&
      cmd.args.contains("owner,name")
    let is_resolve = cmd.args
      .iter()
      .any(fn(arg) {
        arg.contains("resolveReviewThread") || arg.contains("query=mutation")
      })
    if is_repo_view {
      return (0, "{\"owner\":{\"login\":\"brickfrog\"},\"name\":\"choir\"}")
    }
    if is_graphql && is_resolve {
      return (
        0, "{\"data\":{\"resolveReviewThread\":{\"thread\":{\"isResolved\":true}}}}",
      )
    }
    if is_graphql {
      return (0, "{\"data\":{\"repository\":{\"pullRequest\":null}}}")
    }
    (0, "")
  }
  let got = dispatch(
    ToolRequest::ResolveReviewThread({
      thread_id: "PRRT_fetch_fail",
      caller_id: "main.leaf",
    }),
    project_dir~,
    poller_state=Some(ps),
    capture~,
    on_resolve_review_thread=fn(pr_numbers : Array[Int]) {
      for n in pr_numbers {
        seen.push(n)
      }
    },
  )
  match got {
    @types.Response::Ok(_) => ()
    _ => fail("expected Ok")
  }
  @debug.assert_eq(seen, [])
  match ps.get(333) {
    Some(current) => assert_eq(current.unresolved_thread_ids.length(), 2)
    None => fail("expected tracked PR")
  }
}

///|
