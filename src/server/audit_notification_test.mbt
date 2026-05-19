///|
fn audit_notification_agent(
  agent_id : String,
  role : @types.Role,
  parent : String?,
  workspace : String,
  terminal_target? : @types.LocalTarget? = None,
) -> @types.Agent {
  {
    agent_id,
    role,
    agent_type: @types.AgentType::Codex,
    parent,
    workspace,
    branch: agent_id,
    terminal_target,
    host: @types.Host::Local,
    spawn_depth: 0,
    state: @types.AgentState::Active,
  }
}

///|
fn audit_notification_state(
  audit_max_rounds? : Int = @types.Config::default().audit_max_rounds,
) -> ServerState {
  let project_dir = "/tmp/choir-audit-notification-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.create_dir_all(project_dir + "/.choir"))
  ServerState::new(
    { ..@types.Config::default(), project_dir, audit_max_rounds },
    make_hermetic_recovery_provider(),
  )
}

///|
fn audit_notification_seed_leaf(
  state : ServerState,
  parent_id? : String = "main.tl",
  leaf_id? : String = "main.leaf",
  pr_number? : Int = 24,
  branch? : String = "feature/audit",
  sha? : String = "abcdef1234567890abcdef1234567890abcdef12",
) -> Unit {
  ignore(
    state.registry.upsert(
      audit_notification_agent(
        parent_id,
        @types.Role::TL,
        None,
        state.config.project_dir,
      ),
    ),
  )
  ignore(
    state.registry.upsert(
      audit_notification_agent(
        leaf_id,
        @types.Role::Dev,
        Some(parent_id),
        state.config.project_dir,
      ),
    ),
  )
  state.poller.track(
    pr_number,
    leaf_id,
    branch,
    "main",
    "https://example.test/pr/" + pr_number.to_string(),
    10L,
  )
  match state.poller.get(pr_number) {
    Some(tracked) => state.poller.restore({ ..tracked, last_sha: sha })
    None => ()
  }
}

///|
test "audit_digest_body formats normal cycle body with verbatim findings" {
  let body = audit_digest_body(
    {
      leaf_agent_id: "main.leaf",
      parent_id: "main.tl",
      pr_number: 24,
      branch: "feature/audit",
      receipt_path: ".choir/audit-receipts/abcdef123456.json",
      cycle: 2,
      findings_count: 2,
      exhausted: false,
    },
    "Finding 1: alpha\nFinding 2: beta\n",
  )
  assert_eq(
    body, "[AUDIT cycle 2] PR #24 on feature/audit\nfindings_count=2\nreceipt: .choir/audit-receipts/abcdef123456.json\n\nFinding 1: alpha\nFinding 2: beta\n",
  )
}

///|
test "audit_digest_body tags exhausted cycle and TL decision suffix" {
  let body = audit_digest_body(
    {
      leaf_agent_id: "main.leaf",
      parent_id: "main.tl",
      pr_number: 24,
      branch: "feature/audit",
      receipt_path: ".choir/audit-receipts/abcdef123456.json",
      cycle: 3,
      findings_count: 1,
      exhausted: true,
    },
    "Finding 1: alpha\n",
  )
  assert_true(
    body.has_prefix(
      "[AUDIT cycle 3 — LOOP EXHAUSTED] PR #24 on feature/audit — TL decision required\n",
    ),
  )
}

///|
async test "notify_parent_about_audit sends formatted body to leaf parent" {
  let state = audit_notification_state()
  audit_notification_seed_leaf(state)
  ignore(state.record_audit_cycle_for_agent("main.leaf"))
  ignore(state.record_audit_cycle_for_agent("main.leaf"))
  let sent : Array[(String, String, String, @types.Status)] = []
  state.notify_parent_about_audit(
    "main.leaf",
    {
      message: "Finding 1: alpha\nFinding 2: beta\n",
      status: @types.Status::Success,
    },
    send_message=async fn(parent, sender_id, body, status) {
      @async.sleep(0)
      sent.push((parent.agent_id.to_string(), sender_id, body, status))
    },
  )
  assert_eq(sent.length(), 1)
  let (parent_id, sender_id, body, status) = sent[0]
  assert_eq(parent_id, "main.tl")
  assert_eq(sender_id, "main.leaf")
  assert_eq(status, @types.Status::Info)
  assert_eq(
    body, "[AUDIT cycle 2] PR #24 on feature/audit\nfindings_count=2\nreceipt: .choir/audit-receipts/abcdef123456.json\n\nFinding 1: alpha\nFinding 2: beta\n",
  )
}

///|
async test "post_audit_pr_comment posts same audit body to tracked PR" {
  let state = audit_notification_state()
  audit_notification_seed_leaf(state)
  ignore(state.record_audit_cycle_for_agent("main.leaf"))
  let comments : Array[(Int, String)] = []
  state.post_audit_pr_comment(
    "main.leaf",
    { message: "Finding 1: alpha\n", status: @types.Status::Success },
    post_comment=async fn(pr_number, body) {
      @async.sleep(0)
      comments.push((pr_number, body))
      Ok(())
    },
  )
  assert_eq(comments.length(), 1)
  let (pr_number, body) = comments[0]
  assert_eq(pr_number, 24)
  assert_eq(
    body, "[AUDIT cycle 1] PR #24 on feature/audit\nfindings_count=1\nreceipt: .choir/audit-receipts/abcdef123456.json\n\nFinding 1: alpha\n",
  )
}

///|
async test "post_audit_pr_comment absorbs comment failures" {
  let state = audit_notification_state()
  audit_notification_seed_leaf(state)
  ignore(state.record_audit_cycle_for_agent("main.leaf"))
  let mut attempts = 0
  state.post_audit_pr_comment(
    "main.leaf",
    { message: "Finding 1: alpha\n", status: @types.Status::Success },
    post_comment=async fn(_pr_number, _body) {
      @async.sleep(0)
      attempts = attempts + 1
      Err(@types.ChoirError::transport_error("gh down"))
    },
  )
  assert_eq(attempts, 1)
}

///|
async test "capture_audit_on_file_pr_report fires notification and PR comment side effects" {
  let state = audit_notification_state()
  audit_notification_seed_leaf(state)
  let target = @types.LocalTarget::parse("zellij-tab:audit-test:tl").unwrap()
  ignore(
    state.registry.upsert(
      audit_notification_agent(
        "main.tl",
        @types.Role::TL,
        None,
        state.config.project_dir,
        terminal_target=Some(target),
      ),
    ),
  )
  ignore(state.record_audit_cycle_for_agent("main.leaf"))
  state.prepare_audit_on_file_pr_report("main.leaf")
  let delivery_cmds : Array[@workspace.Command] = []
  let comment_cmds : Array[@workspace.Command] = []
  state.capture_audit_on_file_pr_report(
    "main.leaf",
    { message: "Finding 1: alpha\n", status: @types.Status::Success },
    runner=async fn(cmds) {
      @async.sleep(0)
      for cmd in cmds {
        delivery_cmds.push(cmd)
      }
      [0]
    },
    capture=async fn(cmd) {
      @async.sleep(0)
      comment_cmds.push(cmd)
      (0, "")
    },
  )
  assert_eq(delivery_cmds.length(), 1)
  assert_eq(comment_cmds.length(), 1)
  @debug.assert_eq(comment_cmds[0].args, [
    "pr", "comment", "24", "--body", "[AUDIT cycle 1] PR #24 on feature/audit\nfindings_count=1\nreceipt: .choir/audit-receipts/abcdef123456.json\n\nFinding 1: alpha\n",
  ])
  match state.wait_for_audit_on_file_pr_report("main.leaf") {
    Some(report) => assert_eq(report.message, "Finding 1: alpha\n")
    None => fail("expected queued report")
  }
}

///|
test "audit_worker_short_sha extracts production branch-prefixed audit worker id" {
  @debug.assert_eq(
    audit_worker_short_sha("main.audit-on-file-pr-abcdef123-1779000000"),
    Some("abcdef123"),
  )
}

///|
test "audit digest context resolves production worker id through tracked head sha" {
  let state = audit_notification_state()
  let leaf_id = "main.audit-leaf"
  let worker_id = "main.audit-on-file-pr-abcdef123-1779000000"
  audit_notification_seed_leaf(
    state,
    leaf_id~,
    sha="abcdef1234567890abcdef1234567890abcdef12",
  )
  ignore(state.record_audit_cycle_for_agent(leaf_id))
  match
    state.audit_digest_context(worker_id, {
      message: "Finding 1: production resolver failed\n",
      status: @types.Status::Success,
    }) {
    Some(ctx) => {
      assert_eq(ctx.leaf_agent_id, leaf_id)
      assert_eq(ctx.parent_id, "main.tl")
      assert_eq(ctx.pr_number, 24)
      assert_eq(ctx.branch, "feature/audit")
      assert_eq(ctx.receipt_path, ".choir/audit-receipts/abcdef123456.json")
      assert_eq(ctx.cycle, 1)
      assert_eq(ctx.findings_count, 1)
      assert_false(ctx.exhausted)
    }
    None => fail("expected digest context for production audit worker")
  }
}

///|
async test "notify_parent_about_audit uses second recorded cycle for production worker id" {
  let state = audit_notification_state()
  let leaf_id = "main.audit-leaf"
  let worker_id = "main.audit-on-file-pr-abcdef123-1779000000"
  audit_notification_seed_leaf(
    state,
    leaf_id~,
    sha="abcdef1234567890abcdef1234567890abcdef12",
  )
  ignore(state.record_audit_cycle_for_agent(leaf_id))
  ignore(state.record_audit_cycle_for_agent(leaf_id))
  let sent : Array[(String, String, String, @types.Status)] = []
  state.notify_parent_about_audit(
    worker_id,
    { message: "Finding 1: alpha\n", status: @types.Status::Success },
    send_message=async fn(parent, sender_id, body, status) {
      @async.sleep(0)
      sent.push((parent.agent_id.to_string(), sender_id, body, status))
    },
  )
  assert_eq(sent.length(), 1)
  let (parent_id, sender_id, body, status) = sent[0]
  assert_eq(parent_id, "main.tl")
  assert_eq(sender_id, leaf_id)
  assert_eq(status, @types.Status::Info)
  assert_true(body.has_prefix("[AUDIT cycle 2] PR #24 on feature/audit\n"))
  assert_false(body.has_prefix("[AUDIT cycle 1]"))
}

///|
async test "notify_parent_audit_started sends one-line start body to leaf parent" {
  let state = audit_notification_state()
  let leaf_id = "main.audit-leaf"
  audit_notification_seed_leaf(state, leaf_id~)
  let sent : Array[(String, String, String, @types.Status)] = []
  state.notify_parent_audit_started(leaf_id, 3, pr_number=Some(24), send_message=async fn(
    parent,
    sender_id,
    body,
    status,
  ) {
    @async.sleep(0)
    sent.push((parent.agent_id.to_string(), sender_id, body, status))
  })
  assert_eq(sent.length(), 1)
  let (parent_id, sender_id, body, status) = sent[0]
  assert_eq(parent_id, "main.tl")
  assert_eq(sender_id, leaf_id)
  assert_eq(body, "[AUDIT cycle 3 started] PR #24")
  assert_eq(status, @types.Status::Info)
}

///|
test "update_audit_progress exposes exhausted flag when caller sets it" {
  let state = audit_notification_state()
  let leaf_id = "main.audit-leaf"
  state.update_audit_progress(
    leaf_id,
    { message: "Finding 1: still broken\n", status: @types.Status::Success },
    receipt_path=Some(".choir/audit-receipts/abcdef123456.json"),
    exhausted=true,
    now_ms=444L,
  )
  match state.audit_progress_for_agent(leaf_id) {
    Some(progress) => {
      assert_eq(progress.cycles_so_far, 1)
      @debug.assert_eq(progress.last_findings_count, Some(1))
      @debug.assert_eq(
        progress.last_receipt_path,
        Some(".choir/audit-receipts/abcdef123456.json"),
      )
      @debug.assert_eq(progress.last_cycle_at_ms, Some(444L))
      assert_true(progress.exhausted)
    }
    None => fail("expected exhausted audit progress")
  }
}
