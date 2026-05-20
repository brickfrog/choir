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
fn audit_notification_seed_worker(
  state : ServerState,
  worker_id : String,
  leaf_id : String,
) -> Unit {
  ignore(
    state.registry.upsert(
      audit_notification_agent(
        worker_id,
        @types.Role::Worker,
        Some(leaf_id),
        state.config.project_dir,
      ),
    ),
  )
}

///|
async fn audit_notification_wait_until(
  ready : () -> Bool,
  label : String,
) -> Unit {
  for _i = 0; _i < 50; _i = _i + 1 {
    if ready() {
      return
    }
    @async.pause()
  }
  fail("timed out waiting for " + label)
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
test "TL exhaustion notification uses [AUDIT LOOP EXHAUSTED] per spec L18" {
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
      "[AUDIT LOOP EXHAUSTED] 3 cycles, 1 findings remain on PR #24 — TL decision required\nbranch: feature/audit\nreceipt: .choir/audit-receipts/abcdef123456.json\n\n",
    ),
  )
  assert_true(body.contains("Finding 1: alpha\n"))
}

///|
test "PR comment exhaustion uses [AUDIT cycle N — LOOP EXHAUSTED] per spec L21" {
  let body = audit_pr_comment_body(
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
  assert_true(body.contains("receipt: .choir/audit-receipts/abcdef123456.json"))
  assert_true(body.contains("Finding 1: alpha\n"))
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
  assert_true(state.run_next_audit_pr_comment_task())
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
  assert_true(state.run_next_audit_pr_comment_task())
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
  assert_true(state.run_next_audit_pr_comment_task())
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
test "audit_digest_context tags configured max cycle exhausted" {
  let state = audit_notification_state(audit_max_rounds=2)
  audit_notification_seed_leaf(state)
  ignore(state.record_audit_cycle_for_agent("main.leaf"))
  match
    state.audit_digest_context("main.leaf", {
      message: "Finding 1: alpha\n",
      status: @types.Status::Success,
    }) {
    Some(ctx) => {
      assert_eq(ctx.cycle, 1)
      assert_false(ctx.exhausted)
      assert_true(
        audit_digest_body(ctx, "Finding 1: alpha\n").has_prefix(
          "[AUDIT cycle 1] PR #24 on feature/audit\n",
        ),
      )
    }
    None => fail("expected digest context before max cycle")
  }
  ignore(state.record_audit_cycle_for_agent("main.leaf"))
  match
    state.audit_digest_context("main.leaf", {
      message: "Finding 1: alpha\n",
      status: @types.Status::Success,
    }) {
    Some(ctx) => {
      assert_eq(ctx.cycle, 2)
      assert_true(ctx.exhausted)
      assert_true(
        audit_digest_body(ctx, "Finding 1: alpha\n").has_prefix(
          "[AUDIT LOOP EXHAUSTED] 2 cycles, 1 findings remain on PR #24 — TL decision required\nbranch: feature/audit\nreceipt: .choir/audit-receipts/abcdef123456.json\n\n",
        ),
      )
    }
    None => fail("expected digest context at max cycle")
  }
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

///|
async test "capture_audit_on_file_pr_report returns before slow PR comment capture resolves" {
  let state = audit_notification_state()
  let parent_id = "feature/audit-tl-visibility.tl"
  let leaf_id = "feature/audit-tl-visibility.leaf-y"
  let worker_id = "feature/audit-tl-visibility.audit-on-file-pr-abcdef123456-1779000000"
  audit_notification_seed_leaf(
    state,
    parent_id~,
    leaf_id~,
    pr_number=42,
    branch="feature/audit-tl-visibility",
    sha="abcdef1234567890abcdef1234567890abcdef12",
  )
  audit_notification_seed_worker(state, worker_id, leaf_id)
  let comment_started = @aqueue.Queue::new(kind=@aqueue.Kind::Unbounded)
  let release_comment = @aqueue.Queue::new(kind=@aqueue.Kind::Unbounded)
  let mut capture_completed = false
  state.capture_audit_on_file_pr_report(
    worker_id,
    { message: "Finding 1: alpha\n", status: @types.Status::Success },
    runner=async fn(_cmds) {
      @async.sleep(0)
      [0]
    },
    capture=async fn(cmd) {
      ignore(comment_started.try_put(cmd) catch { _ => false })
      ignore(release_comment.get())
      capture_completed = true
      (0, "")
    },
  )
  assert_false(capture_completed)
  let mut drain_done = false
  @async.with_task_group(group => {
    group.spawn_bg(async fn() {
      ignore(state.run_next_audit_pr_comment_task())
      drain_done = true
    })
    let started = @async.with_timeout_opt(1000, () => comment_started.get())
    let cmd = match started {
      Some(value) => value
      None => fail("timed out waiting for slow gh capture to start")
    }
    assert_eq(cmd.program, "gh")
    assert_false(capture_completed)
    assert_false(drain_done)
    ignore(release_comment.try_put(()) catch { _ => false })
    audit_notification_wait_until(
      fn() { capture_completed && drain_done },
      "slow audit PR comment capture completion",
    )
  })
}

///|
async test "capture_audit_on_file_pr_report tags exhausted notification and PR comment" {
  let state = audit_notification_state(audit_max_rounds=1)
  let parent_id = "feature/audit-tl-visibility.tl"
  let leaf_id = "feature/audit-tl-visibility.leaf-y"
  let worker_id = "feature/audit-tl-visibility.audit-on-file-pr-abcdef123456-1779000000"
  audit_notification_seed_leaf(
    state,
    parent_id~,
    leaf_id~,
    branch="feature/audit-tl-visibility",
    sha="abcdef1234567890abcdef1234567890abcdef12",
  )
  audit_notification_seed_worker(state, worker_id, leaf_id)
  let target = @types.LocalTarget::parse("zellij-tab:audit-test:tl").unwrap()
  ignore(
    state.registry.upsert(
      audit_notification_agent(
        parent_id,
        @types.Role::TL,
        None,
        state.config.project_dir,
        terminal_target=Some(target),
      ),
    ),
  )
  ignore(state.record_audit_cycle_for_agent(leaf_id))
  let delivery_cmds : Array[@workspace.Command] = []
  let comment_cmds : Array[@workspace.Command] = []
  state.capture_audit_on_file_pr_report(
    worker_id,
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
  assert_true(delivery_cmds[0].args[3].contains("[AUDIT LOOP EXHAUSTED]"))
  assert_true(
    delivery_cmds[0].args[3].contains(
      "1 cycles, 1 findings remain on PR #24 — TL decision required",
    ),
  )
  assert_true(state.run_next_audit_pr_comment_task())
  assert_eq(comment_cmds.length(), 1)
  assert_true(
    comment_cmds[0].args[4].contains("[AUDIT cycle 1 — LOOP EXHAUSTED]"),
  )
}

///|
async test "audit_max_rounds=1 returns AuditLoopExhausted after one cycle per spec L93" {
  let state = audit_notification_state(audit_max_rounds=1)
  let parent_id = "feature/audit-tl-visibility.tl"
  let leaf_id = "feature/audit-tl-visibility.leaf-spec-l93"
  let head = "abcdef1234567890abcdef1234567890abcdef12"
  let branch = "feature/audit-tl-visibility"
  audit_notification_seed_leaf(
    state,
    parent_id~,
    leaf_id~,
    pr_number=42,
    branch~,
    sha=head,
  )
  let target = @types.LocalTarget::parse("zellij-tab:audit-test:tl").unwrap()
  ignore(
    state.registry.upsert(
      audit_notification_agent(
        parent_id,
        @types.Role::TL,
        None,
        state.config.project_dir,
        terminal_target=Some(target),
      ),
    ),
  )
  let delivery_cmds : Array[@workspace.Command] = []
  let comment_cmds : Array[@workspace.Command] = []
  let recorded_agents : Array[String] = []
  let findings_report : @tools.AuditOnFilePrReport = {
    message: "Finding 1: still broken\nreceipt: .choir/audit-receipts/abcdef123456.json\n",
    status: @types.Status::Success,
  }
  let got = @tools.file_pr_auto_audit_for_missing_receipt(
    state.config.project_dir,
    state.config.project_dir,
    leaf_id,
    "main",
    head,
    async fn(cmd : @workspace.Command) -> (Int, String) {
      @async.sleep(0)
      if cmd.program == "git" && cmd.args == ["rev-parse", "HEAD"] {
        return (0, head + "\n")
      }
      if cmd.program == "git" &&
        cmd.args == ["rev-parse", "--abbrev-ref", "HEAD"] {
        return (0, branch + "\n")
      }
      if cmd.program == "git" &&
        cmd.args == ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"] {
        return (0, "origin/main\n")
      }
      if cmd.program == "cat" || cmd.program == "find" {
        return (1, "")
      }
      (0, "")
    },
    async fn(worker_args) {
      @async.sleep(0)
      let worker_id = "feature/audit-tl-visibility." + worker_args.slug
      state.prepare_audit_on_file_pr_report(worker_id)
      Ok(worker_id)
    },
    async fn(worker_id) {
      @async.sleep(0)
      state.capture_audit_on_file_pr_report(
        worker_id,
        findings_report,
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
      state.wait_for_audit_on_file_pr_report(worker_id)
    },
    fn(_) {  },
    fn(_) { @types.Response::ok_values({ "status": String::to_json("ok") }) },
    1000,
    0,
    fn(_, _) { true },
    async fn(_) { @async.sleep(0) },
    fn() { 1779000000L },
    fn(_) { true },
    audit_max_rounds=1,
    record_audit_cycle_for_agent=fn(agent_id) {
      recorded_agents.push(agent_id)
      state.record_audit_cycle_for_agent(agent_id)
    },
    audit_cycle_count_for_agent=fn(agent_id) {
      state.audit_cycle_count_for_agent(agent_id)
    },
  )
  match got {
    Err(e) => {
      assert_eq(e.to_wire_string(), "audit_loop_exhausted")
      assert_true(e.message().contains("audit loop exhausted after 1 cycle(s)"))
    }
    Ok(_) => fail("expected spec L93 one-cycle exhaustion")
  }
  assert_true(state.run_next_audit_pr_comment_task())
  @debug.assert_eq(recorded_agents, [leaf_id])
  assert_eq(delivery_cmds.length(), 1)
  assert_true(
    delivery_cmds[0].args[3].contains(
      "[AUDIT LOOP EXHAUSTED] 1 cycles, 1 findings remain on PR #42 — TL decision required\nbranch: feature/audit-tl-visibility\nreceipt: .choir/audit-receipts/abcdef123456.json\n\n",
    ),
  )
  assert_eq(comment_cmds.length(), 1)
  assert_true(
    comment_cmds[0].args[4].has_prefix(
      "[AUDIT cycle 1 — LOOP EXHAUSTED] PR #42 on feature/audit-tl-visibility — TL decision required\n",
    ),
  )
}

///|
async test "file_pr exhaustion drives real ServerState audit visibility pipeline" {
  let state = audit_notification_state(audit_max_rounds=2)
  let parent_id = "feature/audit-tl-visibility.tl"
  let leaf_id = "feature/audit-tl-visibility.leaf-y"
  let head = "abcdef1234567890abcdef1234567890abcdef12"
  audit_notification_seed_leaf(
    state,
    parent_id~,
    leaf_id~,
    pr_number=42,
    branch="feature/audit-tl-visibility",
    sha=head,
  )
  let target = @types.LocalTarget::parse("zellij-tab:audit-test:tl").unwrap()
  ignore(
    state.registry.upsert(
      audit_notification_agent(
        parent_id,
        @types.Role::TL,
        None,
        state.config.project_dir,
        terminal_target=Some(target),
      ),
    ),
  )
  let delivery_cmds : Array[@workspace.Command] = []
  let comment_cmds : Array[@workspace.Command] = []
  let recorded_agents : Array[String] = []
  let worker_ids : Array[String] = []
  let findings_report : @tools.AuditOnFilePrReport = {
    message: "Finding 1: still broken\nreceipt: .choir/audit-receipts/abcdef123456.json\n",
    status: @types.Status::Success,
  }
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    if cmd.program == "git" && cmd.args == ["rev-parse", "HEAD"] {
      return (0, head + "\n")
    }
    if cmd.program == "git" && cmd.args == ["rev-parse", "--abbrev-ref", "HEAD"] {
      return (0, "feature/audit-tl-visibility\n")
    }
    if cmd.program == "git" &&
      cmd.args == ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"] {
      return (0, "origin/main\n")
    }
    if cmd.program == "cat" {
      return (1, "")
    }
    if cmd.program == "find" {
      return (1, "")
    }
    (0, "")
  }
  let run_cycle = async fn(now_ms : Int64) -> Result[Unit, @types.ChoirError] {
    @tools.file_pr_auto_audit_for_missing_receipt(
      state.config.project_dir,
      state.config.project_dir,
      leaf_id,
      "main",
      head,
      capture,
      async fn(worker_args) {
        @async.sleep(0)
        let worker_id = "feature/audit-tl-visibility." + worker_args.slug
        worker_ids.push(worker_id)
        state.prepare_audit_on_file_pr_report(worker_id)
        Ok(worker_id)
      },
      async fn(worker_id) {
        @async.sleep(0)
        state.capture_audit_on_file_pr_report(
          worker_id,
          findings_report,
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
        state.wait_for_audit_on_file_pr_report(worker_id)
      },
      fn(_) {  },
      fn(_) { @types.Response::ok_values({ "status": String::to_json("ok") }) },
      1000,
      0,
      fn(_, _) { true },
      async fn(_) { @async.sleep(0) },
      fn() { now_ms },
      fn(_) { true },
      audit_max_rounds=2,
      record_audit_cycle_for_agent=fn(agent_id) {
        recorded_agents.push(agent_id)
        state.record_audit_cycle_for_agent(agent_id)
      },
      audit_cycle_count_for_agent=fn(agent_id) {
        state.audit_cycle_count_for_agent(agent_id)
      },
    )
  }
  match run_cycle(1779000000L) {
    Err(e) => assert_true(e.message().contains("audit found 1 findings"))
    Ok(_) => fail("expected first cycle findings")
  }
  assert_true(state.run_next_audit_pr_comment_task())
  match run_cycle(1779000001L) {
    Err(e) => {
      assert_eq(e.to_wire_string(), "audit_loop_exhausted")
      assert_true(e.message().contains("audit loop exhausted after 2 cycle(s)"))
    }
    Ok(_) => fail("expected second cycle exhaustion")
  }
  assert_true(state.run_next_audit_pr_comment_task())
  assert_false(state.run_next_audit_pr_comment_task())
  assert_eq(worker_ids.length(), 2)
  @debug.assert_eq(recorded_agents, [leaf_id, leaf_id])
  assert_eq(delivery_cmds.length(), 2)
  assert_eq(comment_cmds.length(), 2)
  let notification_1 = delivery_cmds[0].args[3]
  let notification_2 = delivery_cmds[1].args[3]
  assert_true(
    notification_1.contains(
      "[AUDIT cycle 1] PR #42 on feature/audit-tl-visibility\n",
    ),
  )
  assert_true(
    notification_2.contains(
      "[AUDIT LOOP EXHAUSTED] 2 cycles, 1 findings remain on PR #42 — TL decision required\nbranch: feature/audit-tl-visibility\n",
    ),
  )
  assert_false(notification_1.contains("LOOP EXHAUSTED"))
  assert_true(
    comment_cmds[0].args[4].has_prefix(
      "[AUDIT cycle 1] PR #42 on feature/audit-tl-visibility\n",
    ),
  )
  assert_true(
    comment_cmds[1].args[4].has_prefix(
      "[AUDIT cycle 2 — LOOP EXHAUSTED] PR #42 on feature/audit-tl-visibility — TL decision required\n",
    ),
  )
  match state.audit_progress_for_agent(leaf_id) {
    Some(progress) => {
      assert_eq(progress.cycles_so_far, 2)
      @debug.assert_eq(progress.last_findings_count, Some(1))
      assert_true(progress.exhausted)
    }
    None => fail("expected exhausted audit progress")
  }
}

///|
async test "clean audit resets cycle counter before next consecutive findings run" {
  let state = audit_notification_state(audit_max_rounds=2)
  let parent_id = "feature/audit-tl-visibility.tl"
  let leaf_id = "feature/audit-tl-visibility.leaf-reset"
  let head_a = "abcdef1234567890abcdef1234567890abcdef12"
  let head_b = "bbbbbb1234567890abcdef1234567890abcdef12"
  let branch = "feature/audit-tl-visibility"
  audit_notification_seed_leaf(
    state,
    parent_id~,
    leaf_id~,
    pr_number=42,
    branch~,
    sha=head_a,
  )
  let target = @types.LocalTarget::parse("zellij-tab:audit-test:tl").unwrap()
  ignore(
    state.registry.upsert(
      audit_notification_agent(
        parent_id,
        @types.Role::TL,
        None,
        state.config.project_dir,
        terminal_target=Some(target),
      ),
    ),
  )
  let delivery_cmds : Array[@workspace.Command] = []
  let comment_cmds : Array[@workspace.Command] = []
  let recorded_agents : Array[String] = []
  let cleared_agents : Array[String] = []
  let findings_report : @tools.AuditOnFilePrReport = {
    message: "Finding 1: still broken\n",
    status: @types.Status::Success,
  }
  let clean_report : @tools.AuditOnFilePrReport = {
    message: "No findings.\n",
    status: @types.Status::Success,
  }
  let set_tracked_head = fn(head : String) -> Unit {
    match state.poller.get(42) {
      Some(tracked) => state.poller.restore({ ..tracked, last_sha: head })
      None => ()
    }
  }
  let run_cycle = async fn(
    head : String,
    report : @tools.AuditOnFilePrReport,
    now_ms : Int64,
  ) -> Result[Unit, @types.ChoirError] {
    set_tracked_head(head)
    @tools.file_pr_auto_audit_for_missing_receipt(
      state.config.project_dir,
      state.config.project_dir,
      leaf_id,
      "main",
      head,
      async fn(cmd : @workspace.Command) -> (Int, String) {
        @async.sleep(0)
        if cmd.program == "git" && cmd.args == ["rev-parse", "HEAD"] {
          return (0, head + "\n")
        }
        if cmd.program == "git" &&
          cmd.args == ["rev-parse", "--abbrev-ref", "HEAD"] {
          return (0, branch + "\n")
        }
        if cmd.program == "git" &&
          cmd.args == ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"] {
          return (0, "origin/main\n")
        }
        if cmd.program == "cat" || cmd.program == "find" {
          return (1, "")
        }
        (0, "")
      },
      async fn(worker_args) {
        @async.sleep(0)
        let worker_id = "feature/audit-tl-visibility." + worker_args.slug
        state.prepare_audit_on_file_pr_report(worker_id)
        Ok(worker_id)
      },
      async fn(worker_id) {
        @async.sleep(0)
        state.capture_audit_on_file_pr_report(
          worker_id,
          report,
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
        state.wait_for_audit_on_file_pr_report(worker_id)
      },
      fn(_) {  },
      fn(_) { @types.Response::ok_values({ "status": String::to_json("ok") }) },
      1000,
      0,
      fn(_, _) { true },
      async fn(_) { @async.sleep(0) },
      fn() { now_ms },
      fn(_) { true },
      audit_max_rounds=2,
      record_audit_cycle_for_agent=fn(agent_id) {
        recorded_agents.push(agent_id)
        state.record_audit_cycle_for_agent(agent_id)
      },
      audit_cycle_count_for_agent=fn(agent_id) {
        state.audit_cycle_count_for_agent(agent_id)
      },
      clear_audit_cycle_for_agent=fn(agent_id) {
        cleared_agents.push(agent_id)
        state.clear_audit_cycle_count_for_agent(agent_id)
      },
    )
  }

  match run_cycle(head_a, findings_report, 1779000100L) {
    Err(e) => assert_true(e.message().contains("audit found 1 findings"))
    Ok(_) => fail("expected first noisy cycle to fail")
  }
  assert_true(state.run_next_audit_pr_comment_task())
  assert_eq(state.audit_cycle_count_for_agent(leaf_id), 1)

  match run_cycle(head_a, clean_report, 1779000101L) {
    Ok(_) => ()
    Err(e) => fail("expected clean audit to pass: " + e.message())
  }
  assert_true(state.run_next_audit_pr_comment_task())
  assert_eq(state.audit_cycle_count_for_agent(leaf_id), 0)
  @debug.assert_eq(cleared_agents, [leaf_id])

  match run_cycle(head_b, findings_report, 1779000102L) {
    Err(e) => {
      assert_true(e.message().contains("audit found 1 findings"))
      assert_false(e.to_wire_string() == "audit_loop_exhausted")
    }
    Ok(_) => fail("expected fresh noisy cycle to fail without exhaustion")
  }
  assert_true(state.run_next_audit_pr_comment_task())
  assert_eq(state.audit_cycle_count_for_agent(leaf_id), 1)
  let fresh_notification = delivery_cmds[2].args[3]
  assert_true(
    fresh_notification.contains(
      "[AUDIT cycle 1] PR #42 on feature/audit-tl-visibility\n",
    ),
  )
  assert_false(fresh_notification.contains("[AUDIT cycle 4"))

  match run_cycle(head_b, findings_report, 1779000103L) {
    Err(e) => {
      assert_eq(e.to_wire_string(), "audit_loop_exhausted")
      assert_true(e.message().contains("audit loop exhausted after 2 cycle(s)"))
    }
    Ok(_) => fail("expected second fresh noisy cycle to exhaust")
  }
  assert_true(state.run_next_audit_pr_comment_task())
  @debug.assert_eq(recorded_agents, [leaf_id, leaf_id, leaf_id, leaf_id])
  assert_eq(state.audit_cycle_count_for_agent(leaf_id), 2)
  assert_eq(delivery_cmds.length(), 4)
  assert_true(
    delivery_cmds[3].args[3].contains(
      "[AUDIT LOOP EXHAUSTED] 2 cycles, 1 findings remain on PR #42",
    ),
  )
  assert_eq(comment_cmds.length(), 4)
}

///|
async test "clear audit cycle count preserves last audit progress snapshot" {
  let state = audit_notification_state(audit_max_rounds=2)
  let parent_id = "feature/audit-tl-visibility.tl"
  let leaf_id = "feature/audit-tl-visibility.leaf-clean-progress"
  let head = "abcdef1234567890abcdef1234567890abcdef12"
  let worker_id = "feature/audit-tl-visibility.audit-on-file-pr-abcdef123456-1779000300"
  audit_notification_seed_leaf(
    state,
    parent_id~,
    leaf_id~,
    pr_number=42,
    branch="feature/audit-tl-visibility",
    sha=head,
  )
  audit_notification_seed_worker(state, worker_id, leaf_id)
  ignore(state.record_audit_cycle_for_agent(leaf_id))
  state.capture_audit_on_file_pr_report(
    worker_id,
    { message: "No findings.\n", status: @types.Status::Success },
    runner=async fn(_cmds) {
      @async.sleep(0)
      [0]
    },
    capture=async fn(_) {
      @async.sleep(0)
      (0, "")
    },
  )
  assert_true(state.run_next_audit_pr_comment_task())
  state.clear_audit_cycle_count_for_agent(leaf_id)
  assert_eq(state.audit_cycle_count_for_agent(leaf_id), 0)
  match state.audit_progress_for_agent(leaf_id) {
    Some(progress) => {
      assert_eq(progress.cycles_so_far, 1)
      @debug.assert_eq(progress.last_findings_count, Some(0))
      assert_false(progress.exhausted)
    }
    None => fail("expected clean audit progress to survive cycle clear")
  }
}

///|
async test "existing valid audit receipt resets stale cycle counter through file_pr receipt gate" {
  let state = audit_notification_state(audit_max_rounds=2)
  let leaf_id = "feature/audit-tl-visibility.leaf-existing-receipt"
  let head = "abcdef1234567890abcdef1234567890abcdef12"
  let branch = "feature/audit-tl-visibility"
  ignore(state.record_audit_cycle_for_agent(leaf_id))
  ignore(state.record_audit_cycle_for_agent(leaf_id))
  assert_eq(state.audit_cycle_count_for_agent(leaf_id), 2)
  let receipt : @types.AuditReceipt = {
    sha: head,
    branch,
    audited_at: 1779000200L,
    agent_id: "main.audit",
    findings_count: 0,
  }
  let mut waited_for_audit = false
  let mut recorded_audit_cycle = false
  let mut ensured_pr = false
  let cleared_agents : Array[String] = []
  let got = @tools.interpret_file_pr(
    {
      branch,
      parent_branch: Some("main"),
      tracked_agent_id: leaf_id,
      title: None,
      body: None,
      review_context: None,
    },
    state.config.project_dir,
    "choir",
    None,
    None,
    false,
    async fn(_branch, _parent_branch, _dir) {
      @async.sleep(0)
      Ok(())
    },
    async fn(cmds) {
      @async.sleep(0)
      let statuses = []
      for _cmd in cmds {
        statuses.push(0)
      }
      statuses
    },
    async fn(cmd : @workspace.Command) -> (Int, String) {
      @async.sleep(0)
      if cmd.program == "git" && cmd.args == ["rev-parse", "HEAD"] {
        return (0, head + "\n")
      }
      if cmd.program == "cat" {
        return (0, receipt.to_json().stringify() + "\n")
      }
      (0, "")
    },
    async fn(_branch, _parent_branch, _dir, _title, _body) {
      @async.sleep(0)
      ensured_pr = true
      Ok({ number: 42, url: "https://example.test/pr/42", state: "OPEN" })
    },
    caller_role=@types.Role::Dev,
    wait_for_audit_report=async fn(_) {
      @async.sleep(0)
      waited_for_audit = true
      Some({ message: "unexpected wait", status: @types.Status::Failure })
    },
    audit_max_rounds=2,
    record_audit_cycle_for_agent=fn(agent_id) {
      recorded_audit_cycle = true
      state.record_audit_cycle_for_agent(agent_id)
    },
    audit_cycle_count_for_agent=fn(agent_id) {
      state.audit_cycle_count_for_agent(agent_id)
    },
    clear_audit_cycle_for_agent=fn(agent_id) {
      cleared_agents.push(agent_id)
      state.clear_audit_cycle_count_for_agent(agent_id)
    },
  )
  match got {
    @types.Response::Ok(_) => ()
    @types.Response::Err(msg) => fail("expected valid receipt to pass: " + msg)
  }
  assert_true(ensured_pr)
  assert_false(waited_for_audit)
  assert_false(recorded_audit_cycle)
  assert_eq(state.audit_cycle_count_for_agent(leaf_id), 0)
  @debug.assert_eq(cleared_agents, [leaf_id])
}

///|
async test "dispatch_call routes audit max rounds and cycle callbacks into file_pr" {
  let project_dir = "/tmp/choir-audit-dispatch-call-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.create_dir_all(project_dir + "/.choir"))
  let head = "cccccc1234567890abcdef1234567890abcdef12"
  let leaf_id = "feature/audit-tl-visibility.dispatch-leaf"
  let branch = "feature/audit-dispatch-call"
  let mut cycles = 0
  let recorded_agents : Array[String] = []
  let cleared_agents : Array[String] = []
  let call = @tools.ToolCall::{
    role: @types.Role::Dev,
    name: "file_pr",
    args: { "caller_id": leaf_id, "branch": branch, "parent_branch": "main" },
  }
  let run = async fn() -> @types.Response {
    @tools.dispatch_call(
      call,
      project_dir~,
      runner=async fn(cmds) {
        @async.sleep(0)
        let statuses = []
        for _ in cmds {
          statuses.push(0)
        }
        statuses
      },
      capture=async fn(cmd : @workspace.Command) -> (Int, String) {
        @async.sleep(0)
        if cmd.program == "git" && cmd.args == ["rev-parse", "HEAD"] {
          return (0, head + "\n")
        }
        if cmd.program == "git" &&
          cmd.args == ["rev-parse", "--abbrev-ref", "HEAD"] {
          return (0, branch + "\n")
        }
        if cmd.program == "git" &&
          cmd.args == ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"] {
          return (0, "origin/main\n")
        }
        if cmd.program == "cat" || cmd.program == "find" {
          return (1, "")
        }
        (0, "")
      },
      ensure_branch_ready=Some(async fn(_branch, _parent_branch, _dir) {
        @async.sleep(0)
        Ok(())
      }),
      audit_max_rounds=2,
      record_audit_cycle_for_agent=fn(agent_id) {
        recorded_agents.push(agent_id)
        cycles = cycles + 1
        cycles
      },
      audit_cycle_count_for_agent=fn(_) { cycles },
      clear_audit_cycle_for_agent=fn(agent_id) {
        cleared_agents.push(agent_id)
        cycles = 0
      },
      wait_for_audit_report=async fn(_) {
        @async.sleep(0)
        Some({
          message: "Finding 1: still broken\n",
          status: @types.Status::Success,
        })
      },
      pr_review=false,
    )
  }
  match run() {
    @types.Response::Err(msg) =>
      assert_true(msg.contains("audit found 1 findings"))
    @types.Response::Ok(_) =>
      fail("expected first dispatch_call audit findings")
  }
  match run() {
    @types.Response::Err(msg) => {
      assert_true(msg.contains("audit loop exhausted after 2 cycle(s)"))
      assert_true(msg.contains("1 finding(s) remaining"))
      assert_false(msg.contains("audit found 1 findings"))
    }
    @types.Response::Ok(_) => fail("expected dispatch_call audit exhaustion")
  }
  assert_eq(cycles, 2)
  @debug.assert_eq(recorded_agents, [leaf_id, leaf_id])
  @debug.assert_eq(cleared_agents, [])
}
