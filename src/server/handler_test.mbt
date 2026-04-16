///|
test "poll_events_delivery_summary escapes newlines and truncates long events" {
  let tail = "b".repeat(220)
  let ev = @poller.PollEvent::ReviewReceived(3, "alpha\nbeta\n" + tail)
  let s = poll_events_delivery_summary([ev])
  assert_false(s.contains("\n"))
  assert_true(s.contains("\\n"))
  assert_eq(s.length(), 203)
}

///|
test "merge_execution_mode_for_request distinguishes manual automerge and force" {
  let manual_req : @types.Request = {
    req_method: "tools/call",
    role: @types.Role::TL,
    name: "merge_pr",
    args: @types.RequestArgs::new({ "pr_number": "5" }),
  }
  assert_eq(
    merge_execution_mode_for_request(manual_req),
    @evidence.MergeExecutionMode::Manual,
  )
  let automerge_args : Map[String, Json] = {
    "pr_number": Int::to_json(5),
    "automerge": Bool::to_json(true),
  }
  let automerge_req : @types.Request = {
    req_method: "tools/call",
    role: @types.Role::TL,
    name: "merge_pr",
    args: @types.RequestArgs::from_values(automerge_args),
  }
  assert_eq(
    merge_execution_mode_for_request(automerge_req),
    @evidence.MergeExecutionMode::ServerAutomerge,
  )
  let force_args : Map[String, Json] = {
    "pr_number": Int::to_json(5),
    "automerge": Bool::to_json(true),
    "force": Bool::to_json(true),
  }
  let force_req : @types.Request = {
    req_method: "tools/call",
    role: @types.Role::TL,
    name: "merge_pr",
    args: @types.RequestArgs::from_values(force_args),
  }
  assert_eq(
    merge_execution_mode_for_request(force_req),
    @evidence.MergeExecutionMode::ForceOverride,
  )
}

///|
test "should_fetch_unresolved_threads_for_pending_event widens for automerge" {
  assert_false(
    should_fetch_unresolved_threads_for_pending_event(
      @poller.PollEvent::MergeReady(7),
      false,
    ),
  )
  assert_true(
    should_fetch_unresolved_threads_for_pending_event(
      @poller.PollEvent::MergeReady(7),
      true,
    ),
  )
  assert_true(
    should_fetch_unresolved_threads_for_pending_event(
      @poller.PollEvent::CILatestHeadRollupSucceeded(7),
      false,
    ),
  )
}

///|
test "automerge_enabled_for_agent respects local override" {
  let global_true = { ..@types.Config::default(), automerge: true }
  assert_true(automerge_enabled_for_agent(global_true, None))
  assert_false(
    automerge_enabled_for_agent(
      global_true,
      Some({ ..@types.LocalConfig::default(), automerge: Some(false) }),
    ),
  )
  assert_true(
    automerge_enabled_for_agent(
      { ..@types.Config::default(), automerge: false },
      Some({ ..@types.LocalConfig::default(), automerge: Some(true) }),
    ),
  )
}

///|
test "review_mode_for_agent respects local override" {
  let global_iterative = {
    ..@types.Config::default(),
    review_mode: @types.ReviewMode::Iterative,
  }
  assert_eq(
    review_mode_for_agent(global_iterative, None),
    @types.ReviewMode::Iterative,
  )
  assert_eq(
    review_mode_for_agent(
      global_iterative,
      Some({
        ..@types.LocalConfig::default(),
        review_mode: Some(@types.ReviewMode::SinglePass),
      }),
    ),
    @types.ReviewMode::SinglePass,
  )
}

///|
async test "maybe_trigger_automerge_for_pending_event reuses merge_pr path" {
  let project_dir = "/tmp/choir-automerge-handler-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.system("mkdir -p " + project_dir + "/.choir/kv"))
  let terminal_session = "test-session"
  let config = {
    ..@types.Config::default(),
    project_dir,
    terminal_session,
    automerge: true,
  }
  let state = ServerState::new(config, make_recovery_provider())
  let parent_id = "main.tl"
  let child_id = "main.auto-leaf"
  let pr_number = 90
  ignore(
    state.register_agent({
      agent_id: parent_id,
      role: @types.Role::TL,
      agent_type: @types.AgentType::Claude,
      parent: None,
      workspace: project_dir,
      branch: "main",
      terminal_target: Some(
        @workspace.local_target_for(
          terminal_session,
          "TL",
          @types.IsolationMode::Worktree,
        ),
      ),
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  ignore(
    state.register_agent({
      agent_id: child_id,
      role: @types.Role::Dev,
      agent_type: @types.AgentType::MoonPilot,
      parent: Some(parent_id),
      workspace: project_dir + "/.choir/worktrees/auto-leaf",
      branch: child_id,
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  let parent_child : @phase.ChildLifecycle = {
    child_id,
    slug: @phase.extract_slug(child_id),
    branch: child_id,
    agent_type: @types.AgentType::MoonPilot,
    summary: @phase.ChildLifecycleSummary::ReviewOwned(
      pr_number~,
      state=@phase.ReviewOwnership::ApprovedAwaitingMerge,
    ),
  }
  assert_true(
    @phase.write_lifecycle(project_dir, {
      agent_id: parent_id,
      role: @types.Role::TL,
      process: @phase.ProcessState::Connected,
      workflow: @phase.WorkflowState::Supervisor(
        @phase.SupervisorLifecycle::Supervising(children=[parent_child], wave=1),
      ),
    }),
  )
  assert_true(
    @phase.write_lifecycle(project_dir, {
      agent_id: child_id,
      role: @types.Role::Dev,
      process: @phase.ProcessState::Connected,
      workflow: @phase.WorkflowState::Dev(
        @phase.DevLifecycle::ReviewOwned(
          pr_number~,
          state=@phase.ReviewOwnership::ApprovedAwaitingMerge,
        ),
      ),
    }),
  )
  state.poller.track(
    pr_number, child_id, child_id, "main", "https://github.com/brickfrog/choir/pull/90",
    100L,
  )
  match state.poller.get(pr_number) {
    Some(tracked) =>
      state.poller.restore({
        ..tracked,
        last_review_state: @poller.ReviewState::Approved,
        last_ci_rollup: @poller.CiRollupStatus::Success,
      })
    None => fail("expected tracked PR")
  }
  let tracked = match state.poller.get(pr_number) {
    Some(value) => value
    None => fail("expected tracked PR")
  }
  let mut merge_seen = false
  let runner = async fn(cmds : Array[@workspace.Command]) {
    @async.sleep(0)
    let statuses = []
    for cmd in cmds {
      if cmd.program == "gh" &&
        cmd.args.length() >= 3 &&
        cmd.args[0] == "pr" &&
        cmd.args[1] == "merge" {
        merge_seen = true
      }
      statuses.push(0)
    }
    statuses
  }
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    let repo_view_json =
      #|{"owner":{"login":"brickfrog"},"name":"choir"}
    let review_threads_json =
      #|{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}
    if cmd.program == "gh" &&
      cmd.args.length() >= 2 &&
      cmd.args[0] == "api" &&
      cmd.args[1].has_suffix("/reviews") {
      return (0, "[{\"state\":\"APPROVED\"}]")
    }
    if cmd.program == "gh" &&
      cmd.args == ["repo", "view", "--json", "owner,name"] {
      return (0, repo_view_json)
    }
    if cmd.program == "gh" &&
      cmd.args.length() >= 2 &&
      cmd.args[0] == "api" &&
      cmd.args[1] == "graphql" {
      return (0, review_threads_json)
    }
    (0, "")
  }
  let merged = maybe_trigger_automerge_for_pending_event(
    state,
    @poller.PollEvent::ReviewThreadsResolved(pr_number),
    tracked,
    Some(0),
    runner,
    capture~,
  )
  assert_true(merged)
  assert_true(merge_seen)
  assert_true(state.poller.get(pr_number) == None)
  match @phase.read_lifecycle(project_dir, child_id) {
    Some(lifecycle) =>
      assert_eq(
        lifecycle.process,
        @phase.ProcessState::Finalized(reason=@phase.FinalizeReason::Merged),
      )
    None => fail("expected merged child lifecycle")
  }
}

///|
fn kill_agent_reconciliation_fixture(
  label : String,
  pr_number : Int,
) -> (ServerState, String, String) {
  let project_dir = "/tmp/choir-kill-reconcile-" +
    label +
    "-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.system("mkdir -p " + project_dir + "/.choir/kv"))
  let terminal_session = "test-session"
  let config = { ..@types.Config::default(), project_dir, terminal_session }
  let state = ServerState::new(config, make_recovery_provider())
  let parent_id = "main.parent"
  let child_id = "main.child"
  let live_target = match
    @types.LocalTarget::parse("zellij-tab:" + terminal_session + ":live-parent") {
    Some(t) => t
    None => panic()
  }
  ignore(
    state.register_agent({
      agent_id: parent_id,
      role: @types.Role::TL,
      agent_type: @types.AgentType::Claude,
      parent: None,
      workspace: project_dir,
      branch: "main",
      terminal_target: Some(live_target),
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  ignore(
    state.register_agent({
      agent_id: child_id,
      role: @types.Role::Dev,
      agent_type: @types.AgentType::MoonPilot,
      parent: Some(parent_id),
      workspace: project_dir + "/child",
      branch: child_id,
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  state.poller.track(
    pr_number,
    child_id,
    child_id,
    "main",
    "https://example.test/pr/" + pr_number.to_string(),
    100L,
  )
  (state, parent_id, child_id)
}

///|
async test "kill_agent auto-closes tracked stale PR and untracks it" {
  let pr_number = 208
  let (state, _parent_id, child_id) = kill_agent_reconciliation_fixture(
    "ok", pr_number,
  )
  let mut close_seen = false
  let mut stale_closed_delivered = false
  let runner = async fn(cmds : Array[@workspace.Command]) {
    @async.sleep(0)
    let statuses = []
    for cmd in cmds {
      if cmd.program == "choir" &&
        cmd.args.contains("zellij-action") &&
        cmd.args.contains("send") {
        let text = cmd.args[cmd.args.length() - 1]
        if text.contains("[STALE PR CLOSED]") &&
          text.contains("PR #" + pr_number.to_string()) {
          stale_closed_delivered = true
        }
      }
      statuses.push(0)
    }
    statuses
  }
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    if cmd.program == "gh" &&
      cmd.args.length() >= 3 &&
      cmd.args[0] == "pr" &&
      cmd.args[1] == "close" &&
      cmd.args[2] == pr_number.to_string() {
      close_seen = true
      return (0, "closed")
    }
    (0, "")
  }
  let req : @types.Request = {
    req_method: "tools/call",
    role: @types.Role::TL,
    name: "kill_agent",
    args: @types.RequestArgs::new({
      "agent_id": child_id,
      "caller_id": _parent_id,
    }),
  }
  let resp = state.handle_with_runner_and_capture(req, runner~, capture~)
  assert_true(resp.is_ok())
  assert_true(close_seen)
  assert_true(stale_closed_delivered)
  assert_true(state.poller.get(pr_number) == None)
}

///|
async test "kill_agent close failure sends one explicit stale PR failure and suppresses generic orphan notification" {
  let pr_number = 209
  let (state, _parent_id, child_id) = kill_agent_reconciliation_fixture(
    "fail", pr_number,
  )
  let mut stale_failed_delivered = false
  let runner = async fn(cmds : Array[@workspace.Command]) {
    @async.sleep(0)
    let statuses = []
    for cmd in cmds {
      if cmd.program == "choir" &&
        cmd.args.contains("zellij-action") &&
        cmd.args.contains("send") {
        let text = cmd.args[cmd.args.length() - 1]
        if text.contains("[STALE PR CLOSE FAILED]") &&
          text.contains("PR #" + pr_number.to_string()) {
          stale_failed_delivered = true
        }
      }
      statuses.push(0)
    }
    statuses
  }
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    if cmd.program == "gh" &&
      cmd.args.length() >= 3 &&
      cmd.args[0] == "pr" &&
      cmd.args[1] == "close" &&
      cmd.args[2] == pr_number.to_string() {
      return (1, "permission denied")
    }
    (0, "")
  }
  let req : @types.Request = {
    req_method: "tools/call",
    role: @types.Role::TL,
    name: "kill_agent",
    args: @types.RequestArgs::new({
      "agent_id": child_id,
      "caller_id": _parent_id,
    }),
  }
  let resp = state.handle_with_runner_and_capture(req, runner~, capture~)
  assert_true(resp.is_ok())
  assert_true(stale_failed_delivered)
  match state.poller.get(pr_number) {
    Some(tracked) => {
      assert_true(tracked.orphan_notified)
      assert_false(tracked.orphan_reconciling)
      assert_eq(@poller.detect_orphaned_prs([(tracked, false)]).length(), 0)
    }
    None => fail("expected tracked PR to remain after close failure")
  }
}

///|
test "parent_poll_event_message PR READY stresses not merged" {
  let tracked : @poller.TrackedPR = {
    pr_number: 7,
    agent_id: "main.dev-a",
    branch: "work/a",
    parent_branch: "main",
    pr_url: "https://ex/pr/7",
    first_seen: 0,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::Approved,
    last_review_bodies: "",
    last_sha: "",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Unknown,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: false,
    orphan_notified: false,
    orphan_reconciling: false,
    changes_requested_since: 0L,
    stall_notified: false,
    fixes_pushed_at: 0L,
  }
  match
    parent_poll_event_message(
      tracked,
      "/repo",
      @poller.PollEvent::PRReady(7),
      None,
    ) {
    Some((message, status)) => {
      assert_eq(status, @types.Status::Success)
      assert_true(message.contains("[PR READY]"))
      assert_true(message.contains("(not merged yet)"))
      assert_true(message.contains("merge_mode: manual"))
      assert_true(message.contains("Pre-merge:"))
      assert_true(message.contains("[PR MERGED]"))
      assert_true(message.contains("TLDecision:"))
      assert_true(message.contains("Waiting on Copilot review"))
    }
    None => fail("expected PRReady message")
  }
}

///|
test "parent_poll_event_message PR READY shows merge gate when snapshot allows" {
  let tracked : @poller.TrackedPR = {
    pr_number: 70,
    agent_id: "main.dev-a",
    branch: "work/a",
    parent_branch: "main",
    pr_url: "https://ex/pr/70",
    first_seen: 0,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::Approved,
    last_review_bodies: "",
    last_sha: "",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Success,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: false,
    orphan_notified: false,
    orphan_reconciling: false,
    changes_requested_since: 0L,
    stall_notified: false,
    fixes_pushed_at: 0L,
  }
  match
    parent_poll_event_message(
      tracked,
      "/repo",
      @poller.PollEvent::PRReady(70),
      Some(0),
    ) {
    Some((message, status)) => {
      assert_eq(status, @types.Status::Success)
      assert_true(message.contains("TLDecision:"))
      assert_true(message.contains("MERGE NOW"))
    }
    None => fail("expected merge-gate-open PRReady message")
  }
}

///|
test "parent_poll_event_message MergeReady is actionable in manual mode" {
  let tracked : @poller.TrackedPR = {
    pr_number: 71,
    agent_id: "main.dev-manual",
    branch: "work/manual",
    parent_branch: "main",
    pr_url: "https://ex/pr/71",
    first_seen: 0,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::Approved,
    last_review_bodies: "",
    last_sha: "",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Success,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: true,
    orphan_notified: false,
    orphan_reconciling: false,
    changes_requested_since: 0L,
    stall_notified: false,
    fixes_pushed_at: 0L,
  }
  match
    parent_poll_event_message(
      tracked,
      "/repo",
      @poller.PollEvent::MergeReady(71),
      Some(0),
      merge_mode=@poller.MergeOperatorMode::Manual,
    ) {
    Some((message, status)) => {
      assert_eq(status, @types.Status::Success)
      assert_true(message.contains("[MERGE READY]"))
      assert_true(message.contains("merge_mode: manual"))
      assert_true(message.contains("Merge policy decision: merge_now"))
      assert_true(message.contains("merge_pr("))
      assert_true(message.contains("MERGE NOW"))
    }
    None => fail("expected manual MergeReady message")
  }
}

///|
test "parent_poll_event_message MergeReady is informational in automerge mode" {
  let tracked : @poller.TrackedPR = {
    pr_number: 72,
    agent_id: "main.dev-auto",
    branch: "work/auto",
    parent_branch: "main",
    pr_url: "https://ex/pr/72",
    first_seen: 0,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::Approved,
    last_review_bodies: "",
    last_sha: "",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Success,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: true,
    orphan_notified: false,
    orphan_reconciling: false,
    changes_requested_since: 0L,
    stall_notified: false,
    fixes_pushed_at: 0L,
  }
  match
    parent_poll_event_message(
      tracked,
      "/repo",
      @poller.PollEvent::MergeReady(72),
      Some(0),
      merge_mode=@poller.MergeOperatorMode::Automerge,
    ) {
    Some((message, status)) => {
      assert_eq(status, @types.Status::Info)
      assert_true(message.contains("merge_mode: automerge"))
      assert_true(message.contains("server will attempt merge automatically"))
      assert_true(message.contains("AUTO-MERGE READY"))
      assert_false(message.contains("`merge_pr("))
    }
    None => fail("expected automerge MergeReady message")
  }
}

///|
test "parent_poll_event_message FixesPushed stresses not merged" {
  let tracked : @poller.TrackedPR = {
    pr_number: 8,
    agent_id: "main.dev-b",
    branch: "work/b",
    parent_branch: "main",
    pr_url: "",
    first_seen: 0,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::Approved,
    last_review_bodies: "",
    last_sha: "abc",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Unknown,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: false,
    orphan_notified: false,
    orphan_reconciling: false,
    changes_requested_since: 0L,
    stall_notified: false,
    fixes_pushed_at: 0L,
  }
  match
    parent_poll_event_message(
      tracked,
      "/repo",
      @poller.PollEvent::FixesPushed(8),
      None,
    ) {
    Some((message, status)) => {
      assert_eq(status, @types.Status::Info)
      assert_true(message.contains("[FIXES PUSHED]"))
      assert_true(message.contains("(not merged yet)"))
      assert_true(message.contains("Pre-merge:"))
      assert_true(message.contains("TLDecision:"))
      assert_true(message.contains("Waiting on review or CI"))
    }
    None => fail("expected FixesPushed message")
  }
}

///|
test "parent_poll_event_message FixesPushed single_pass avoids re-review wording" {
  let tracked : @poller.TrackedPR = {
    pr_number: 9,
    agent_id: "main.dev-c",
    branch: "work/c",
    parent_branch: "main",
    pr_url: "",
    first_seen: 0,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::ChangesRequested,
    last_review_bodies: "",
    last_sha: "abc",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Success,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: false,
    orphan_notified: false,
    orphan_reconciling: false,
    changes_requested_since: 0L,
    stall_notified: false,
    fixes_pushed_at: 1L,
  }
  match
    parent_poll_event_message(
      tracked,
      "/repo",
      @poller.PollEvent::FixesPushed(9),
      Some(0),
      review_mode=@types.ReviewMode::SinglePass,
    ) {
    Some((message, status)) => {
      assert_eq(status, @types.Status::Info)
      assert_true(message.contains("resolving threads and checking gates"))
      assert_true(message.contains("MERGE NOW"))
      assert_false(message.contains("awaiting re-review"))
    }
    None => fail("expected FixesPushed message")
  }
  match
    pr_comment_body(
      @poller.PollEvent::FixesPushed(9),
      "main.dev-c",
      review_mode=@types.ReviewMode::SinglePass,
    ) {
    Some((_, body)) => {
      assert_true(body.contains("resolving threads and checking gates"))
      assert_false(body.contains("awaiting re-review"))
    }
    None => fail("expected FixesPushed comment")
  }
}

///|
test "parent_poll_event_message CIFailureCleared stresses re-check not merge" {
  let tracked : @poller.TrackedPR = {
    pr_number: 10,
    agent_id: "main.dev-x",
    branch: "work/x",
    parent_branch: "main",
    pr_url: "https://ex/pr/10",
    first_seen: 0,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::ChangesRequested,
    last_review_bodies: "",
    last_sha: "abc",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Unknown,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: false,
    orphan_notified: false,
    orphan_reconciling: false,
    changes_requested_since: 0L,
    stall_notified: false,
    fixes_pushed_at: 0L,
  }
  match
    parent_poll_event_message(
      tracked,
      "/repo",
      @poller.PollEvent::CIFailureCleared(10),
      Some(0),
    ) {
    Some((message, status)) => {
      assert_eq(status, @types.Status::Info)
      assert_true(message.contains("[CI FAILURE CLEARED]"))
      assert_true(message.contains("not a merge/review verdict"))
      assert_true(message.contains("pending"))
      assert_true(message.contains("re-check"))
      assert_false(message.contains("CI PASSED"))
      assert_false(message.to_lower().contains("green"))
      assert_true(message.contains("PR re-check summary"))
      assert_true(message.contains("changes_requested"))
      assert_true(message.contains("GitHub review requests changes"))
      assert_true(message.contains("TLDecision:"))
      assert_true(message.contains("BLOCKED: review requested changes"))
    }
    None => fail("expected CIFailureCleared message")
  }
}

///|
test "leaf_poll_review_injection_message CIFailureCleared is honest about scope" {
  match
    leaf_poll_review_injection_message(
      @poller.PollEvent::CIFailureCleared(44),
      None,
    ) {
    Some((message, status)) => {
      assert_eq(status, @types.Status::Info)
      assert_true(message.contains("no longer reports failure"))
      assert_true(message.contains("GitHub"))
      assert_true(message.contains("not merge"))
      assert_false(message.to_lower().contains("green"))
    }
    None => fail("expected leaf CIFailureCleared injection")
  }
}

///|
test "pr_comment_body CIFailureCleared contains pending caveat and no merge signal" {
  match pr_comment_body(@poller.PollEvent::CIFailureCleared(55), "main.dev-x") {
    Some((pr_number, body)) => {
      assert_eq(pr_number, 55)
      assert_true(body.contains("pending"))
      assert_true(body.contains("not a merge signal"))
      assert_false(body.to_lower().contains("passed"))
      assert_false(body.to_lower().contains("green"))
    }
    None => fail("expected pr_comment_body for CIFailureCleared")
  }
}

///|
test "parent_poll_event_message CILatestHeadRollupSucceeded stresses not merge or approval" {
  let tracked : @poller.TrackedPR = {
    pr_number: 171,
    agent_id: "main.dev-z",
    branch: "work/z",
    parent_branch: "main",
    pr_url: "https://ex/pr/171",
    first_seen: 0,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::Approved,
    last_review_bodies: "",
    last_sha: "abc",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Success,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: false,
    orphan_notified: false,
    orphan_reconciling: false,
    changes_requested_since: 0L,
    stall_notified: false,
    fixes_pushed_at: 0L,
  }
  match
    parent_poll_event_message(
      tracked,
      "/repo",
      @poller.PollEvent::CILatestHeadRollupSucceeded(171),
      Some(0),
    ) {
    Some((message, status)) => {
      assert_eq(status, @types.Status::Info)
      assert_true(message.contains("[CI LATEST HEAD]"))
      assert_true(message.contains("not merge approval"))
      assert_true(message.contains("re-check"))
      assert_false(message.to_lower().contains("mergeable"))
      assert_true(message.contains("PR re-check summary"))
      assert_true(message.contains("approved"))
      assert_true(message.contains("success"))
      assert_true(message.contains("no tracked blockers"))
      assert_true(message.contains("Does not merge"))
      assert_true(message.contains("TLDecision:"))
      assert_true(message.contains("MERGE NOW"))
    }
    None => fail("expected CILatestHeadRollupSucceeded message")
  }
}

///|
test "leaf_poll_review_injection_message CILatestHeadRollupSucceeded is scoped" {
  match
    leaf_poll_review_injection_message(
      @poller.PollEvent::CILatestHeadRollupSucceeded(171),
      None,
    ) {
    Some((message, status)) => {
      assert_eq(status, @types.Status::Info)
      assert_true(message.contains("all checks successful"))
      assert_true(message.contains("not merge"))
    }
    None => fail("expected leaf CILatestHeadRollupSucceeded injection")
  }
}

///|
test "leaf_poll_review_injection_message CILatestHeadRollupSucceeded escalates when review timed out with no snapshot review" {
  let tracked : @poller.TrackedPR = {
    pr_number: 178,
    agent_id: "main.dev-leaf",
    branch: "work/leaf",
    parent_branch: "main",
    pr_url: "https://ex/pr/178",
    first_seen: 0,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::None_,
    last_review_bodies: "",
    last_sha: "abc",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Success,
    last_timeout_at: 100L,
    copilot_issue_comment_seen: false,
    orphan_notified: false,
    orphan_reconciling: false,
    changes_requested_since: 0L,
    stall_notified: false,
    fixes_pushed_at: 0L,
  }
  match
    leaf_poll_review_injection_message(
      @poller.PollEvent::CILatestHeadRollupSucceeded(178),
      Some(tracked),
    ) {
    Some((message, status)) => {
      assert_eq(status, @types.Status::Info)
      assert_true(message.contains("no review"))
      assert_true(message.contains("add-reviewer"))
      assert_false(message.contains("re-check review thread and policy"))
    }
    None => fail("expected leaf CI escalation injection")
  }
}

///|
test "pr_comment_body CILatestHeadRollupSucceeded avoids approval language" {
  match
    pr_comment_body(
      @poller.PollEvent::CILatestHeadRollupSucceeded(60),
      "main.dev-z",
    ) {
    Some((pr_number, body)) => {
      assert_eq(pr_number, 60)
      assert_true(body.contains("successful"))
      assert_true(body.contains("not an approval"))
      assert_false(body.to_lower().contains("approved"))
    }
    None => fail("expected pr_comment_body for CILatestHeadRollupSucceeded")
  }
}

///|
test "parent_poll_event_message suppresses non-blocking review comments" {
  let tracked : @poller.TrackedPR = {
    pr_number: 9,
    agent_id: "main.dev-c",
    branch: "work/c",
    parent_branch: "main",
    pr_url: "https://ex/pr/9",
    first_seen: 0,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::Commented,
    last_review_bodies: "note",
    last_sha: "abc",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Unknown,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: false,
    orphan_notified: false,
    orphan_reconciling: false,
    changes_requested_since: 0L,
    stall_notified: false,
    fixes_pushed_at: 0L,
  }
  assert_eq(
    parent_poll_event_message(
      tracked,
      "/repo",
      @poller.PollEvent::ReviewCommented(9, "minor suggestion"),
      None,
    ),
    None,
  )
}

///|
test "clamp_review_summary_for_pane leaves short text unchanged" {
  let s = "fix the typo in handler"
  assert_eq(clamp_review_summary_for_pane(s), s)
}

///|
test "clamp_review_summary_for_pane truncates long Copilot-style bodies" {
  let long = "x".repeat(review_summary_pane_max_chars + 500)
  let out = clamp_review_summary_for_pane(long)
  assert_true(out.contains("[truncated"))
  assert_true(out.length() < long.length())
}

///|
test "disconnect PR recovery only applies to branch-owning dev agents" {
  let mk = fn(role : @types.Role, branch : String) {
    @types.Agent::{
      agent_id: "agent",
      role,
      agent_type: @types.AgentType::Claude,
      parent: Some("root"),
      workspace: "/proj",
      branch,
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }
  }
  assert_true(
    disconnect_pr_recovery_candidate(mk(@types.Role::Dev, "main.leaf")),
  )
  assert_false(disconnect_pr_recovery_candidate(mk(@types.Role::Dev, "")))
  assert_false(
    disconnect_pr_recovery_candidate(mk(@types.Role::Worker, "main.worker")),
  )
  assert_false(disconnect_pr_recovery_candidate(mk(@types.Role::TL, "main")))
}

///|
async test "fail_agent_with_runner injects failure to parent terminal" {
  let project_dir = "/tmp/choir-watchdog-test-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.system("mkdir -p " + project_dir + "/.choir/kv"))

  let terminal_session = "test-session"
  let config = { ..@types.Config::default(), project_dir, terminal_session }
  let state = ServerState::new(config, make_recovery_provider())

  let parent_id = "main.parent"
  let live_target = match
    @types.LocalTarget::parse("zellij-tab:" + terminal_session + ":live-parent") {
    Some(t) => t
    None => fail("expected parseable local target")
  }

  ignore(
    state.register_agent({
      agent_id: parent_id,
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Claude,
      parent: None,
      workspace: project_dir,
      branch: parent_id,
      terminal_target: Some(live_target),
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )

  let caller_id = "main.child"
  ignore(
    state.register_agent({
      agent_id: caller_id,
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Claude,
      parent: Some(parent_id),
      workspace: project_dir,
      branch: caller_id,
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )

  ignore(
    @phase.write_lifecycle(
      project_dir,
      @phase.lifecycle_for_role(caller_id, @types.Role::Dev),
    ),
  )

  @async.sleep(0)

  let mut injected_failure_msg = false
  let runner = async fn(cmds : Array[@workspace.Command]) {
    @async.sleep(0)
    for cmd in cmds {
      if cmd.program == "choir" &&
        cmd.args.contains("zellij-action") &&
        cmd.args.contains("send") {
        let text = cmd.args[cmd.args.length() - 1]
        if text.contains("[from: " + caller_id + "]") &&
          text.contains("watchdog timeout") {
          injected_failure_msg = true
        }
      }
    }
    [0]
  }

  state.fail_agent_with_runner(
    caller_id,
    @phase.FailureReason::WatchdogTimeout,
    "watchdog timeout",
    @types.ExitReason::Shutdown,
    runner,
  )

  assert_true(injected_failure_msg)
}

///|
test "parent_poll_event_message REVIEW TIMEOUT uses attention-required decision" {
  let tracked : @poller.TrackedPR = {
    pr_number: 61,
    agent_id: "main.dev-timeout",
    branch: "work/timeout",
    parent_branch: "main",
    pr_url: "https://ex/pr/61",
    first_seen: 0,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::Approved,
    last_review_bodies: "",
    last_sha: "sha",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Success,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: false,
    orphan_notified: false,
    orphan_reconciling: false,
    changes_requested_since: 0L,
    stall_notified: false,
    fixes_pushed_at: 0L,
  }
  match
    parent_poll_event_message(
      tracked,
      "/repo",
      @poller.PollEvent::ReviewTimeout(61),
      None,
    ) {
    Some((message, status)) => {
      assert_eq(status, @types.Status::Failure)
      assert_true(message.contains("TLDecision:"))
      assert_true(message.contains("ACTION REQUIRED: no review"))
      assert_true(message.contains("add-reviewer"))
      assert_true(message.contains("add-reviewer"))
      assert_false(message.contains("15min"))
    }
    None => fail("expected ReviewTimeout message")
  }
}

///|
test "parent_poll_event_message CI LATEST HEAD adds escalation when review timeout already fired" {
  let tracked : @poller.TrackedPR = {
    pr_number: 171,
    agent_id: "main.dev-z",
    branch: "work/z",
    parent_branch: "main",
    pr_url: "https://ex/pr/171",
    first_seen: 0,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::None_,
    last_review_bodies: "",
    last_sha: "abc",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Success,
    last_timeout_at: 999L,
    copilot_issue_comment_seen: false,
    orphan_notified: false,
    orphan_reconciling: false,
    changes_requested_since: 0L,
    stall_notified: false,
    fixes_pushed_at: 0L,
  }
  match
    parent_poll_event_message(
      tracked,
      "/repo",
      @poller.PollEvent::CILatestHeadRollupSucceeded(171),
      Some(0),
    ) {
    Some((message, status)) => {
      assert_eq(status, @types.Status::Info)
      assert_true(message.contains("Review timeout already fired"))
      assert_true(message.contains("TLDecision:"))
      assert_true(message.contains("ACTION REQUIRED: no review"))
    }
    None => fail("expected CILatestHeadRollupSucceeded escalation message")
  }
}

///|
test "parent_poll_event_message CI FAILED uses attention-required decision" {
  let tracked : @poller.TrackedPR = {
    pr_number: 62,
    agent_id: "main.dev-ci",
    branch: "work/ci",
    parent_branch: "main",
    pr_url: "https://ex/pr/62",
    first_seen: 0,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::Approved,
    last_review_bodies: "",
    last_sha: "sha",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Failure,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: false,
    orphan_notified: false,
    orphan_reconciling: false,
    changes_requested_since: 0L,
    stall_notified: false,
    fixes_pushed_at: 0L,
  }
  match
    parent_poll_event_message(
      tracked,
      "/repo",
      @poller.PollEvent::CIFailed(62),
      None,
    ) {
    Some((message, status)) => {
      assert_eq(status, @types.Status::Failure)
      assert_true(message.contains("TLDecision:"))
      assert_true(message.contains("BLOCKED: CI failing"))
    }
    None => fail("expected CIFailed message")
  }
}

///|
test "parent_poll_event_message PRMerged is handled by canonical teardown delivery" {
  let tracked : @poller.TrackedPR = {
    pr_number: 63,
    agent_id: "main.dev-merged",
    branch: "work/merged",
    parent_branch: "main",
    pr_url: "https://ex/pr/63",
    first_seen: 0,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::Approved,
    last_review_bodies: "",
    last_sha: "sha",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Success,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: false,
    orphan_notified: false,
    orphan_reconciling: false,
    changes_requested_since: 0L,
    stall_notified: false,
    fixes_pushed_at: 0L,
  }
  assert_eq(
    parent_poll_event_message(
      tracked,
      "/repo",
      @poller.PollEvent::PRMerged(tracked),
      Some(0),
    ),
    None,
  )
}

///|
test "evidence_events_for_poll_snapshot emits normalized snapshot events" {
  let tracked : @poller.TrackedPR = {
    pr_number: 64,
    agent_id: "main.dev-evidence",
    branch: "work/evidence",
    parent_branch: "main",
    pr_url: "https://ex/pr/64",
    first_seen: 0,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::Approved,
    last_review_bodies: "looks good",
    last_sha: "sha64",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Success,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: true,
    orphan_notified: false,
    orphan_reconciling: false,
    changes_requested_since: 0L,
    stall_notified: false,
    fixes_pushed_at: 0L,
  }
  let events = evidence_events_for_poll_snapshot(
    tracked,
    @poller.PollEvent::CILatestHeadRollupSucceeded(64),
    Some(0),
  )
  assert_eq(events.length(), 4)
  match events[0] {
    @evidence.EvidenceEvent::ReviewObserved(state~, body~) => {
      assert_eq(state, @evidence.EvidenceReviewState::Approved)
      assert_eq(body, Some("looks good"))
    }
    _ => fail("expected review evidence")
  }
  match events[1] {
    @evidence.EvidenceEvent::CiObserved(status~, head_sha~) => {
      assert_eq(status, @evidence.EvidenceCiStatus::Success)
      assert_eq(head_sha, Some("sha64"))
    }
    _ => fail("expected ci evidence")
  }
  match events[2] {
    @evidence.EvidenceEvent::ThreadsObserved(count~) => assert_eq(count, 0)
    _ => fail("expected threads evidence")
  }
  match events[3] {
    @evidence.EvidenceEvent::CopilotIssueCommentObserved => ()
    _ => fail("expected copilot evidence")
  }
}

///|
test "evidence_events_for_poll_snapshot includes merge observed on PRMerged" {
  let tracked : @poller.TrackedPR = {
    pr_number: 65,
    agent_id: "main.dev-evidence-merged",
    branch: "work/evidence-merged",
    parent_branch: "main",
    pr_url: "https://ex/pr/65",
    first_seen: 0,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::Approved,
    last_review_bodies: "",
    last_sha: "sha65",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Success,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: false,
    orphan_notified: false,
    orphan_reconciling: false,
    changes_requested_since: 0L,
    stall_notified: false,
    fixes_pushed_at: 0L,
  }
  let events = evidence_events_for_poll_snapshot(
    tracked,
    @poller.PollEvent::PRMerged(tracked),
    None,
  )
  assert_eq(events.length(), 5)
  match events[4] {
    @evidence.EvidenceEvent::MergeObserved(pr_number~, pr_url~) => {
      assert_eq(pr_number, 65)
      assert_eq(pr_url, Some("https://ex/pr/65"))
    }
    _ => fail("expected merge evidence")
  }
}

///|
async test "deliver_orphaned_pr_notification_for skips finalized merged lifecycle" {
  let project_dir = "/tmp/choir-handler-orphan-skip-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.system("mkdir -p " + project_dir + "/.choir/kv"))
  let config = {
    ..@types.Config::default(),
    project_dir,
    terminal_session: "test-session",
  }
  let state = ServerState::new(config, make_recovery_provider())
  let agent_id = "main.dev-finalized"
  assert_true(
    @phase.write_lifecycle(project_dir, {
      ..@phase.lifecycle_for_role(agent_id, @types.Role::Dev),
      process: @phase.ProcessState::Finalized(
        reason=@phase.FinalizeReason::Merged,
      ),
      workflow: @phase.WorkflowState::Dev(
        @phase.DevLifecycle::Done(reason=@phase.FinalizeReason::Merged),
      ),
    }),
  )
  let pr : @poller.TrackedPR = {
    pr_number: 88,
    agent_id,
    branch: "feat/finalized",
    parent_branch: "main",
    pr_url: "https://gh.test/88",
    first_seen: 0L,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::Approved,
    last_review_bodies: "",
    last_sha: "sha",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Success,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: false,
    orphan_notified: false,
    orphan_reconciling: false,
    changes_requested_since: 0L,
    stall_notified: false,
    fixes_pushed_at: 0L,
  }
  let mut runner_calls = 0
  deliver_orphaned_pr_notification_for(state, pr, async fn(cmds) {
    @async.sleep(0)
    runner_calls = runner_calls + cmds.length()
    []
  })
  assert_eq(runner_calls, 0)
}

///|
async test "deliver_poller_stall_notification_for skips finalized merged lifecycle" {
  let project_dir = "/tmp/choir-handler-stall-skip-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.system("mkdir -p " + project_dir + "/.choir/kv"))
  let config = {
    ..@types.Config::default(),
    project_dir,
    terminal_session: "test-session",
  }
  let state = ServerState::new(config, make_recovery_provider())
  let agent_id = "main.dev-finalized"
  assert_true(
    @phase.write_lifecycle(project_dir, {
      ..@phase.lifecycle_for_role(agent_id, @types.Role::Dev),
      process: @phase.ProcessState::Finalized(
        reason=@phase.FinalizeReason::Merged,
      ),
      workflow: @phase.WorkflowState::Dev(
        @phase.DevLifecycle::Done(reason=@phase.FinalizeReason::Merged),
      ),
    }),
  )
  let pr : @poller.TrackedPR = {
    pr_number: 89,
    agent_id,
    branch: "feat/finalized",
    parent_branch: "main",
    pr_url: "https://gh.test/89",
    first_seen: 0L,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::ChangesRequested,
    last_review_bodies: "",
    last_sha: "sha",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Success,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: false,
    orphan_notified: false,
    orphan_reconciling: false,
    changes_requested_since: 1L,
    stall_notified: false,
    fixes_pushed_at: 0L,
  }
  let mut runner_calls = 0
  deliver_poller_stall_notification_for(state, pr, 1000L, async fn(cmds) {
    @async.sleep(0)
    runner_calls = runner_calls + cmds.length()
    []
  })
  assert_eq(runner_calls, 0)
}

///|
async fn handler_with_moontrace_capture(
  captured : Array[@moontrace.Event],
  f : async () -> Unit,
) -> Unit {
  @moontrace.set_subscriber(fn(event) { captured.push(event) })
  f() catch {
    err => {
      @moontrace.clear_subscriber()
      raise err
    }
  }
  @moontrace.clear_subscriber()
}

///|
fn handler_auto_close_test_state(label : String) -> ServerState {
  let project_dir = "/tmp/choir-handler-auto-close-" +
    label +
    "-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.system("mkdir -p " + project_dir + "/.choir/kv"))
  let config = {
    ..@types.Config::default(),
    project_dir,
    terminal_session: "test-session",
  }
  ServerState::new(config, make_recovery_provider())
}

///|
fn handler_auto_close_target(label : String) -> @types.LocalTarget {
  { kind: @types.TargetKind::ZellijPane, session: "test-session", name: label }
}

///|
fn handler_close_terminal_warn_count(events : Array[@moontrace.Event]) -> Int {
  let mut count = 0
  for event in events {
    if event.level == @moontrace.Level::Warn &&
      event.message == "CloseTerminal failed" {
      count = count + 1
    }
  }
  count
}

///|
async test "test_close_terminal_warns_on_nonzero_exit" {
  let state = handler_auto_close_test_state("close-warn")
  let target = handler_auto_close_target("leaf-pane")
  let captured : Array[@moontrace.Event] = []
  handler_with_moontrace_capture(captured, async fn() {
    state.interpret_teardown_effects([CloseTerminal(target)], _cmds => [1])
  })
  assert_eq(handler_close_terminal_warn_count(captured), 1)
}

///|
async test "test_close_terminal_no_warn_on_zero_exit" {
  let state = handler_auto_close_test_state("close-ok")
  let target = handler_auto_close_target("leaf-pane")
  let captured : Array[@moontrace.Event] = []
  handler_with_moontrace_capture(captured, async fn() {
    state.interpret_teardown_effects([CloseTerminal(target)], _cmds => [0])
  })
  assert_eq(handler_close_terminal_warn_count(captured), 0)
}

///|
async test "test_close_terminal_warns_on_error" {
  let state = handler_auto_close_test_state("close-error")
  let target = handler_auto_close_target("leaf-pane")
  let captured : Array[@moontrace.Event] = []
  handler_with_moontrace_capture(captured, async fn() {
    state.interpret_teardown_effects([CloseTerminal(target)], _cmds => {
      raise @types.ChoirError::agent_not_found("test error")
    })
  })
  assert_eq(handler_close_terminal_warn_count(captured), 1)
}

///|
fn handler_auto_close_agent(
  agent_id : String,
  state : @types.AgentState,
  target : @types.LocalTarget?,
) -> @types.Agent {
  {
    agent_id: @types.AgentId(agent_id),
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Claude,
    parent: Some("main.parent"),
    workspace: "/tmp/choir-handler-auto-close-workspace",
    branch: agent_id,
    terminal_target: target,
    host: @types.Host::Local,
    spawn_depth: 0,
    state,
  }
}

///|
async test "test_disconnect_done_agent_closes_pane" {
  let state = handler_auto_close_test_state("disconnect-done")
  let agent_id = "main.done-leaf"
  let target = handler_auto_close_target("done-pane")
  ignore(
    state.register_agent(handler_auto_close_agent(agent_id, Done, Some(target))),
  )
  let expected = @workspace.local_close_target(target)
  let calls : Array[@workspace.Command] = []
  state.handle_disconnect_with_runner(agent_id, runner=async fn(cmds) {
    @async.sleep(0)
    for cmd in cmds {
      calls.push(cmd)
    }
    [0]
  })
  assert_eq(calls.length(), 1)
  assert_eq(calls[0], expected)
}

///|
async test "test_disconnect_failed_agent_closes_pane" {
  let state = handler_auto_close_test_state("disconnect-failed")
  let agent_id = "main.failed-leaf"
  let target = handler_auto_close_target("failed-pane")
  ignore(
    state.register_agent(
      handler_auto_close_agent(agent_id, Failed, Some(target)),
    ),
  )
  let expected = @workspace.local_close_target(target)
  let calls : Array[@workspace.Command] = []
  state.handle_disconnect_with_runner(agent_id, runner=async fn(cmds) {
    @async.sleep(0)
    for cmd in cmds {
      calls.push(cmd)
    }
    [0]
  })
  assert_eq(calls.length(), 1)
  assert_eq(calls[0], expected)
}

///|
async test "test_disconnect_done_agent_no_target_no_call" {
  let state = handler_auto_close_test_state("disconnect-done-no-target")
  let agent_id = "main.done-leaf-no-target"
  ignore(state.register_agent(handler_auto_close_agent(agent_id, Done, None)))
  let calls : Array[@workspace.Command] = []
  state.handle_disconnect_with_runner(agent_id, runner=async fn(cmds) {
    @async.sleep(0)
    for cmd in cmds {
      calls.push(cmd)
    }
    [0]
  })
  assert_eq(calls.length(), 0)
}

///|
async test "test_disconnect_completing_agent_no_close" {
  let state = handler_auto_close_test_state("disconnect-completing")
  let agent_id = "main.completing-leaf"
  let target = handler_auto_close_target("completing-pane")
  ignore(
    state.register_agent(
      handler_auto_close_agent(agent_id, Completing, Some(target)),
    ),
  )
  let calls : Array[@workspace.Command] = []
  state.handle_disconnect_with_runner(agent_id, runner=async fn(cmds) {
    @async.sleep(0)
    for cmd in cmds {
      calls.push(cmd)
    }
    [0]
  })

  // Completing agents finalize state (PersistLifecycle) then transition to Done.
  // finalize_agent_with_runner is called with close_target=false and remove_worktree=false,
  // so plan_finalize emits no CloseTerminal or RemoveWorktree effects — the only effects
  // that invoke the runner. The assertion confirms no premature pane close occurs.
  assert_true(calls.is_empty())

  let agent = state.registry.get(agent_id) catch {
    _ => fail("agent not found")
  }
  assert_eq(agent.state, Done)
}
