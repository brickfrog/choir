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
test "poller_event_should_dedup covers hash and window branches" {
  let prior : RecentEmission = { content_hash: "same", emitted_at_unix: 100L }
  assert_true(
    poller_event_should_dedup(
      Some(prior),
      "same",
      159L,
      DEDUP_WINDOW_SEC,
      HEARTBEAT_WINDOW_SEC,
    ),
  )
  assert_true(
    poller_event_should_dedup(
      Some(prior),
      "same",
      161L,
      DEDUP_WINDOW_SEC,
      HEARTBEAT_WINDOW_SEC,
    ),
  )
  assert_false(
    poller_event_should_dedup(
      Some(prior),
      "same",
      451L,
      600L,
      HEARTBEAT_WINDOW_SEC,
    ),
  )
  assert_false(
    poller_event_should_dedup(
      Some(prior),
      "different",
      159L,
      DEDUP_WINDOW_SEC,
      HEARTBEAT_WINDOW_SEC,
    ),
  )
  assert_false(
    poller_event_should_dedup(
      None,
      "same",
      159L,
      DEDUP_WINDOW_SEC,
      HEARTBEAT_WINDOW_SEC,
    ),
  )
  assert_true(
    poller_event_should_dedup(
      Some(prior),
      "same",
      90L,
      DEDUP_WINDOW_SEC,
      HEARTBEAT_WINDOW_SEC,
    ),
  )
}

///|
fn parent_delivery_count(
  deliveries : Array[PlannedDelivery],
  parent_id : String,
  marker : String,
) -> Int {
  let mut count = 0
  for delivery in deliveries {
    if delivery.recipient_id == parent_id && delivery.body.contains(marker) {
      count = count + 1
    }
  }
  count
}

///|
test "poller parent planner does not commit dedup state before delivery" {
  let pr_number = 1700
  let label = "dedup-parent-planner"
  let (state, child_id, project_dir) = blocked_gh_automerge_fixture(
    label,
    pr_number,
    review_mode=@types.ReviewMode::Iterative,
  )
  let parent_id = "main.tl-" + label
  let event = @poller.PollEvent::MergeReady(pr_number)
  let first = state.plan_poll_event_deliveries(
    event,
    child_id,
    Some(0),
    now=100L,
  )
  let duplicate = state.plan_poll_event_deliveries(
    event,
    child_id,
    Some(0),
    now=120L,
  )
  let transition = state.plan_poll_event_deliveries(
    event,
    child_id,
    Some(1),
    now=130L,
  )
  let heartbeat = state.plan_poll_event_deliveries(
    event,
    child_id,
    Some(1),
    now=491L,
  )
  assert_eq(parent_delivery_count(first, parent_id, "[MERGE READY]"), 1)
  assert_eq(parent_delivery_count(duplicate, parent_id, "[MERGE READY]"), 1)
  assert_eq(parent_delivery_count(transition, parent_id, "[MERGE READY]"), 1)
  assert_eq(parent_delivery_count(heartbeat, parent_id, "[MERGE READY]"), 1)
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "deliver_pending_poll_events commits dedup only after durable parent delivery succeeds" {
  let pr_number = 1702
  let label = "dedup-parent-durable"
  let (state, _, project_dir) = blocked_gh_automerge_fixture(
    label,
    pr_number,
    review_mode=@types.ReviewMode::Iterative,
    automerge=false,
  )
  let parent_target = @workspace.local_target_for(
    "test-session",
    "TL",
    @types.IsolationMode::Worktree,
  ).to_string()
  let parent_messages : Array[String] = []
  let mut fail_parent_delivery = true
  let mut unresolved_threads = 0
  let runner = async fn(cmds : Array[@workspace.Command]) {
    @async.sleep(0)
    let statuses = []
    for cmd in cmds {
      if cmd.program == "choir" &&
        cmd.args.length() >= 4 &&
        cmd.args[0] == "zellij-action" &&
        cmd.args[1] == "send" &&
        cmd.args[2] == parent_target {
        parent_messages.push(cmd.args[3])
        statuses.push(if fail_parent_delivery { 1 } else { 0 })
      } else {
        statuses.push(0)
      }
    }
    statuses
  }
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    if (
        cmd.program == "gh" &&
        cmd.args == ["repo", "view", "--json", "owner,name"]
      ) ||
      (
        cmd.program == "timeout" &&
        cmd.args == ["30s", "gh", "repo", "view", "--json", "owner,name"]
      ) {
      return (0, "{\"owner\":{\"login\":\"brickfrog\"},\"name\":\"choir\"}")
    }
    if cmd.args.contains("graphql") {
      if unresolved_threads == 0 {
        return (
          0, "{\"data\":{\"repository\":{\"pullRequest\":{\"reviewThreads\":{\"nodes\":[]}}}}}",
        )
      }
      return (
        0, "{\"data\":{\"repository\":{\"pullRequest\":{\"reviewThreads\":{\"nodes\":[{\"id\":\"PRRT_one\",\"isResolved\":false,\"isOutdated\":false,\"comments\":{\"nodes\":[{\"author\":{\"login\":\"copilot-pull-request-reviewer[bot]\"}}]}}]}}}}}",
      )
    }
    (0, "")
  }
  let refresh_ci_success = async fn(now : Int64) {
    match state.poller.get(pr_number) {
      Some(tracked) =>
        state.poller.restore({
          ..tracked,
          last_review_state: @poller.ReviewState::Approved,
          last_ci_rollup: @poller.CiRollupStatus::InProgress,
          mergeable: @poller.Mergeable::Unknown,
          merge_state_status: @poller.MergeStateStatus::Unknown,
          merged_at_unix: None,
          last_sha: "sha-" + label,
          copilot_issue_comment_seen: true,
        })
      None => fail("expected tracked PR")
    }
    state.refresh_pr_with_test(
      pr_number,
      now,
      900L,
      async fn(_pr_number, _skip_issue_comment_fetch) {
        @async.sleep(0)
        (
          true,
          @poller.ReviewState::Approved,
          "sha-" + label,
          @poller.CiRollupStatus::Success,
          "looks good",
          true,
          true,
          @poller.Mergeable::Unknown,
          @poller.MergeStateStatus::Unknown,
          None,
        )
      },
      runner~,
      capture~,
      automerge_capture=capture,
    )
  }
  refresh_ci_success(100L)
  assert_eq(parent_messages.length(), 4)
  fail_parent_delivery = false
  refresh_ci_success(120L)
  assert_eq(parent_messages.length(), 5)
  refresh_ci_success(121L)
  assert_eq(parent_messages.length(), 5)
  unresolved_threads = 1
  refresh_ci_success(130L)
  assert_eq(parent_messages.length(), 6)
  refresh_ci_success(491L)
  assert_eq(parent_messages.length(), 7)
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "process_poller_tick_with emits tick summary when an event is produced" {
  let project_dir = "/tmp/choir-poller-tick-summary-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.create_dir_all(project_dir + "/.choir/kv"))
  let state = ServerState::new(
    { ..@types.Config::default(), project_dir, terminal_session: "s" },
    make_hermetic_recovery_provider(),
  )
  state.poller.track(
    3, "main.leaf", "main.leaf", "main", "https://example.test/pr/3", 1L,
  )
  let captured : Array[@moontrace.Event] = []
  handler_with_moontrace_capture(captured, async fn() {
    state.process_poller_tick_with_test(
      1000L,
      900L,
      async fn(_pr_number, _skip_issue_comment_fetch) {
        @async.sleep(0)
        (
          true,
          @poller.ReviewState::ChangesRequested,
          "sha-1",
          @poller.CiRollupStatus::Unknown,
          "please fix",
          true,
          false,
          @poller.Mergeable::Unknown,
          @poller.MergeStateStatus::Unknown,
          None,
        )
      },
      runner=async fn(_cmds) {
        @async.sleep(0)
        []
      },
      capture=async fn(_cmd) {
        @async.sleep(0)
        (0, "")
      },
      automerge_capture=async fn(_cmd) {
        @async.sleep(0)
        (0, "")
      },
    )
  })
  let summary = match handler_tick_summary_event(captured) {
    Some(event) => event
    None =>
      fail(
        "expected poller tick, captured: " +
        handler_moontrace_event_summary(captured),
      )
  }
  match handler_moontrace_field_value(summary.fields, "polled") {
    Some(Number(value, ..)) => assert_eq(value.to_int(), 1)
    _ => fail("polled field")
  }
  match handler_moontrace_field_value(summary.fields, "changes") {
    Some(Number(value, ..)) => assert_eq(value.to_int(), 1)
    _ => fail("changes field")
  }
  match handler_moontrace_field_value(summary.fields, "errors") {
    Some(Number(value, ..)) => assert_eq(value.to_int(), 0)
    _ => fail("errors field")
  }
  match handler_moontrace_field_value(summary.fields, "elapsed_ms") {
    Some(_) => ()
    _ => fail("elapsed_ms field")
  }
  match handler_moontrace_field_value(summary.fields, "agent_counts") {
    Some(String(value)) => assert_true(value.contains("active=0"))
    _ => fail("agent_counts field")
  }
  match handler_moontrace_field_value(summary.fields, "tracked_prs") {
    Some(Number(value, ..)) => assert_eq(value.to_int(), 1)
    _ => fail("tracked_prs field")
  }
  match
    handler_moontrace_field_value(
      summary.fields,
      "previous_delivered_event_age_sec",
    ) {
    Some(String(value)) => assert_eq(value, "unknown")
    _ => fail("previous_delivered_event_age_sec field")
  }
  ignore(@sys.rm_rf(project_dir))
}

///|
test "merge_execution_mode_for_request distinguishes manual and automerge" {
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
  assert_true(
    should_fetch_unresolved_threads_for_pending_event(
      @poller.PollEvent::FixesPushed(7),
      false,
    ),
  )
}

///|
test "poll_event_beads_note_and_state maps review and ci events" {
  match poll_event_beads_note_and_state(@poller.PollEvent::CIFailed(12)) {
    Some((note, dimension, value)) => {
      assert_true(note.contains("PR #12"))
      assert_eq(dimension, "ci")
      assert_eq(value, "failing")
    }
    None => fail("expected ci state")
  }
  match poll_event_beads_note_and_state(@poller.PollEvent::PRReady(13)) {
    Some((note, dimension, value)) => {
      assert_true(note.contains("review gate ready"))
      assert_eq(dimension, "review")
      assert_eq(value, "ready")
    }
    None => fail("expected review state")
  }
  match
    poll_event_beads_note_and_state(
      @poller.PollEvent::PRMerged({
        pr_number: 14,
        agent_id: "main.leaf",
        branch: "main.leaf",
        parent_branch: "main",
        pr_url: "https://example.test/pr/14",
        first_seen: 0L,
        consecutive_failures: 0,
        backoff_until: 0L,
        last_review_state: @poller.ReviewState::Approved,
        last_review_bodies: "",
        last_sha: "sha",
        last_automerge_attempt_sha: "",
        notified_parent: false,
        last_ci_rollup: @poller.CiRollupStatus::Success,
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
      }),
    ) {
    Some((note, dimension, value)) => {
      assert_true(note.contains("merged externally"))
      assert_eq(dimension, "merge")
      assert_eq(value, "merged")
    }
    None => fail("expected merge state")
  }
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
test "pr_needs_automerge_sweep_attempt truth table" {
  let ps = @poller.PollerState::new()
  ps.track(
    41, "main.leaf", "main.leaf", "main", "https://example.test/pr/41", 0L,
  )
  let base = match ps.get(41) {
    Some(pr) => pr
    None => fail("expected tracked PR")
  }
  for iterative in [true, false] {
    for gate_ready in [true, false] {
      for automerge_enabled in [true, false] {
        for new_head in [true, false] {
          let pr = {
            ..base,
            review_mode: if iterative {
              @types.ReviewMode::Iterative
            } else {
              @types.ReviewMode::SinglePass
            },
            last_sha: "head-sha",
            last_automerge_attempt_sha: if new_head {
              "old-sha"
            } else {
              "head-sha"
            },
          }
          assert_eq(
            pr_needs_automerge_sweep_attempt(pr, gate_ready, automerge_enabled),
            iterative && gate_ready && automerge_enabled && new_head,
          )
        }
      }
    }
  }
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
  assert_true(@sys.create_dir_all(project_dir + "/.choir/kv"))
  let terminal_session = "test-session"
  let config = {
    ..@types.Config::default(),
    project_dir,
    terminal_session,
    automerge: true,
  }
  let state = ServerState::new(config, make_hermetic_recovery_provider())
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
      last_updated_unix_sec: 0L,
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
      last_updated_unix_sec: 0L,
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
        mergeable: @poller.Mergeable::Unknown,
        merge_state_status: @poller.MergeStateStatus::Unknown,
        merged_at_unix: None,
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
    if cmd.args.contains("repo") && cmd.args.contains("view") {
      return (0, repo_view_json)
    }
    if cmd.args.contains("graphql") {
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
async test "refresh_pr_with pending events fires automerge after fixes and CI clear" {
  let project_dir = "/tmp/choir-automerge-fixes-pushed-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  assert_true(@sys.create_dir_all(project_dir + "/.choir/kv"))
  let terminal_session = "test-session"
  let config = {
    ..@types.Config::default(),
    project_dir,
    terminal_session,
    automerge: true,
    review_mode: @types.ReviewMode::Iterative,
    pr_policy: { require_integration_audit: false },
  }
  let state = ServerState::new(config, make_hermetic_recovery_provider())
  let parent_id = "main.tl"
  let child_id = "main.auto-leaf"
  let pr_number = 91
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
      terminal_target: Some(
        @workspace.local_target_for(
          terminal_session,
          "auto-leaf",
          @types.IsolationMode::Worktree,
        ),
      ),
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
      last_updated_unix_sec: 0L,
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
      last_updated_unix_sec: 0L,
    }),
  )
  state.poller.track(
    pr_number, child_id, child_id, "main", "https://github.com/brickfrog/choir/pull/91",
    100L,
  )
  match state.poller.get(pr_number) {
    Some(tracked) =>
      state.poller.restore({
        ..tracked,
        last_review_state: @poller.ReviewState::Commented,
        last_ci_rollup: @poller.CiRollupStatus::Success,
        mergeable: @poller.Mergeable::Unknown,
        merge_state_status: @poller.MergeStateStatus::Unknown,
        merged_at_unix: None,
        last_sha: "old-sha",
        last_review_bodies: "comment!",
        copilot_issue_comment_seen: true,
      })
    None => fail("expected tracked PR")
  }
  let parent_target = @workspace.local_target_for(
    terminal_session,
    "TL",
    @types.IsolationMode::Worktree,
  ).to_string()
  let parent_messages : Array[String] = []
  let mut merge_seen_count = 0
  let runner = async fn(cmds : Array[@workspace.Command]) {
    @async.sleep(0)
    let statuses = []
    for cmd in cmds {
      if cmd.program == "gh" &&
        cmd.args.length() >= 3 &&
        cmd.args[0] == "pr" &&
        cmd.args[1] == "merge" {
        merge_seen_count = merge_seen_count + 1
      }
      if cmd.program == "choir" &&
        cmd.args.length() >= 4 &&
        cmd.args[0] == "zellij-action" &&
        cmd.args[1] == "send" &&
        cmd.args[2] == parent_target {
        parent_messages.push(cmd.args[3])
      }
      statuses.push(0)
    }
    statuses
  }
  let mut graphql_calls = 0
  let mut review_gate_calls = 0
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    let repo_view_json =
      #|{"owner":{"login":"brickfrog"},"name":"choir"}
    let blocked_threads_json =
      #|{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"PRRT_blocked","isResolved":false,"isOutdated":false,"author":{"login":"copilot-pull-request-reviewer[bot]"},"path":"src/x.mbt","comments":{"nodes":[{"body":"fix it"}]}}]}}}}}
    let review_threads_json =
      #|{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}
    if cmd.program == "gh" &&
      cmd.args.length() >= 2 &&
      cmd.args[0] == "api" &&
      cmd.args[1].has_suffix("/reviews") {
      review_gate_calls = review_gate_calls + 1
      return (0, "[{\"state\":\"APPROVED\"}]")
    }
    if (
        cmd.program == "gh" &&
        cmd.args == ["repo", "view", "--json", "owner,name"]
      ) ||
      (
        cmd.program == "timeout" &&
        cmd.args == ["30s", "gh", "repo", "view", "--json", "owner,name"]
      ) {
      return (0, repo_view_json)
    }
    if cmd.args.contains("graphql") {
      graphql_calls = graphql_calls + 1
      if graphql_calls == 1 {
        return (0, blocked_threads_json)
      }
      return (0, review_threads_json)
    }
    (0, "")
  }

  state.refresh_pr_with_test(
    pr_number,
    200L,
    900L,
    async fn(_pr_number, _skip_issue_comment_fetch) {
      @async.sleep(0)
      (
        true,
        @poller.ReviewState::Commented,
        "old-sha",
        @poller.CiRollupStatus::Success,
        "comment!",
        true,
        false,
        @poller.Mergeable::Unknown,
        @poller.MergeStateStatus::Unknown,
        None,
      )
    },
    runner~,
    capture~,
    automerge_capture=capture,
  )
  assert_eq(merge_seen_count, 0)
  assert_eq(graphql_calls, 1)
  assert_eq(parent_messages.length(), 1)
  assert_true(parent_messages[0].contains("[MERGE READY]"))
  assert_true(parent_messages[0].contains("Merge policy decision: blocked"))

  state.refresh_pr_with_test(
    pr_number,
    300L,
    900L,
    async fn(_pr_number, _skip_issue_comment_fetch) {
      @async.sleep(0)
      (
        true,
        @poller.ReviewState::Commented,
        "fix-sha",
        @poller.CiRollupStatus::InProgress,
        "comment!",
        true,
        false,
        @poller.Mergeable::Unknown,
        @poller.MergeStateStatus::Unknown,
        None,
      )
    },
    runner~,
    capture~,
    automerge_capture=capture,
  )
  assert_eq(merge_seen_count, 0)
  assert_eq(graphql_calls, 2)
  assert_eq(parent_messages.length(), 2)
  assert_true(parent_messages[1].contains("[FIXES PUSHED]"))

  state.refresh_pr_with_test(
    pr_number,
    400L,
    900L,
    async fn(_pr_number, _skip_issue_comment_fetch) {
      @async.sleep(0)
      (
        true,
        @poller.ReviewState::Commented,
        "fix-sha",
        @poller.CiRollupStatus::Success,
        "comment!",
        true,
        false,
        @poller.Mergeable::Unknown,
        @poller.MergeStateStatus::Unknown,
        None,
      )
    },
    runner~,
    capture~,
    automerge_capture=capture,
  )
  assert_eq(merge_seen_count, 1)
  // The earlier [FIXES PUSHED] dispatch already raised graphql_calls to 2
  // (assert_eq above at the first refresh). Asserting > 0 here would pass
  // even if the third pending-event pass never touched GraphQL. Assert the
  // counter actually advanced past 2 so the merge-ready dispatch is proven
  // to have re-fetched unresolved threads through the production path.
  assert_true(graphql_calls > 2)
  assert_true(review_gate_calls > 0)
  assert_eq(parent_messages.length(), 3)
  assert_true(parent_messages[2].contains("[PR MERGED]"))
  assert_false(parent_messages.join("\n").contains("[CI LATEST HEAD]"))
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
fn blocked_gh_automerge_fixture(
  label : String,
  pr_number : Int,
  review_mode? : @types.ReviewMode = @types.ReviewMode::SinglePass,
  automerge? : Bool = true,
) -> (ServerState, String, String) raise {
  let project_dir = "/tmp/choir-blocked-gh-automerge-" +
    label +
    "-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  assert_true(@sys.create_dir_all(project_dir + "/.choir/kv"))
  let terminal_session = "test-session"
  let config = {
    ..@types.Config::default(),
    project_dir,
    terminal_session,
    automerge,
    review_mode,
  }
  let state = ServerState::new(config, make_hermetic_recovery_provider())
  let parent_id = "main.tl-" + label
  let child_id = "main.blocked-gh-" + label
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
      agent_type: @types.AgentType::Codex,
      parent: Some(parent_id),
      workspace: project_dir + "/.choir/worktrees/" + label,
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
    agent_type: @types.AgentType::Codex,
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
      last_updated_unix_sec: 0L,
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
      last_updated_unix_sec: 0L,
    }),
  )
  state.poller.track(
    pr_number,
    child_id,
    child_id,
    "main",
    "https://github.com/brickfrog/choir/pull/" + pr_number.to_string(),
    100L,
    review_mode~,
  )
  match state.poller.get(pr_number) {
    Some(tracked) =>
      state.poller.restore({
        ..tracked,
        last_review_state: @poller.ReviewState::Approved,
        last_ci_rollup: @poller.CiRollupStatus::Success,
        mergeable: @poller.Mergeable::Unknown,
        merge_state_status: @poller.MergeStateStatus::Unknown,
        merged_at_unix: None,
        last_sha: "sha-" + label,
        copilot_issue_comment_seen: true,
      })
    None => fail("expected tracked PR")
  }
  match state.poller.get(pr_number) {
    Some(_) => {
      ignore(
        @evidence.append_agent_evidence_event(
          @sys.append_file_sync,
          project_dir,
          child_id,
          @poller.now_sec(),
          @evidence.EvidenceEvent::ReviewObserved(
            state=@evidence.EvidenceReviewState::Approved,
            body=Some("looks good"),
          ),
        ),
      )
      ignore(
        @evidence.append_agent_evidence_event(
          @sys.append_file_sync,
          project_dir,
          child_id,
          @poller.now_sec(),
          @evidence.EvidenceEvent::CiObserved(
            status=@evidence.EvidenceCiStatus::Success,
            head_sha=Some("sha-" + label),
          ),
        ),
      )
      ignore(
        @evidence.append_agent_evidence_event(
          @sys.append_file_sync,
          project_dir,
          child_id,
          @poller.now_sec(),
          @evidence.EvidenceEvent::ThreadsObserved(count=0),
        ),
      )
      ignore(
        @evidence.append_agent_evidence_event(
          @sys.append_file_sync,
          project_dir,
          child_id,
          @poller.now_sec(),
          @evidence.EvidenceEvent::CopilotIssueCommentObserved,
        ),
      )
    }
    None => fail("expected tracked PR")
  }
  (state, child_id, project_dir)
}

///|
fn blocked_gh_notify_request(
  caller_id : String,
  message : String,
) -> @types.Request {
  let args : Map[String, Json] = {
    "caller_id": caller_id.to_json(),
    "message": message.to_json(),
    "status": "failure".to_json(),
  }
  {
    req_method: "tools/call",
    role: @types.Role::Dev,
    name: "notify_parent",
    args: @types.RequestArgs::from_values(args),
  }
}

///|
async test "quiet poller tick automerge sweep records attempted head on success" {
  let pr_number = 96
  let (state, _, _) = blocked_gh_automerge_fixture(
    "sweep-success",
    pr_number,
    review_mode=@types.ReviewMode::Iterative,
  )
  match state.poller.get(pr_number) {
    Some(tracked) =>
      state.poller.restore({
        ..tracked,
        unresolved_thread_ids: [],
        unresolved_thread_ids_fetched: true,
      })
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
        match state.poller.get(pr_number) {
          Some(current) =>
            assert_eq(current.last_automerge_attempt_sha, "sha-sweep-success")
          None => fail("expected tracked PR during merge attempt")
        }
      }
      statuses.push(0)
    }
    statuses
  }
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    let repo_view_json =
      #|{"owner":{"login":"brickfrog"},"name":"choir"}
    if (
        cmd.program == "gh" &&
        cmd.args == ["repo", "view", "--json", "owner,name"]
      ) ||
      (
        cmd.program == "timeout" &&
        cmd.args == ["30s", "gh", "repo", "view", "--json", "owner,name"]
      ) {
      return (0, repo_view_json)
    }
    if cmd.program == "gh" &&
      cmd.args.length() >= 2 &&
      cmd.args[0] == "api" &&
      cmd.args[1].has_suffix("/reviews") {
      return (
        0, "[{\"state\":\"APPROVED\",\"user\":{\"login\":\"copilot-pull-request-reviewer[bot]\"},\"submitted_at\":\"2026-05-10T00:00:00Z\"}]",
      )
    }
    if cmd.args.contains("graphql") {
      return (
        0, "{\"data\":{\"repository\":{\"pullRequest\":{\"reviewThreads\":{\"nodes\":[]}}}}}",
      )
    }
    (0, "")
  }
  state.process_poller_tick_with_test(
    500L,
    900L,
    async fn(_pr_number, _skip_issue_comment_fetch) {
      @async.sleep(0)
      (
        true,
        @poller.ReviewState::Approved,
        "sha-sweep-success",
        @poller.CiRollupStatus::Success,
        "",
        true,
        false,
        @poller.Mergeable::Unknown,
        @poller.MergeStateStatus::Unknown,
        None,
      )
    },
    runner~,
    capture~,
    automerge_capture=capture,
  )
  assert_true(merge_seen)
  assert_true(state.poller.get(pr_number) == None)
}

///|
async test "quiet poller tick automerge sweep finalizes stale-role tracked leaf on success" {
  let pr_number = 99
  let (state, child_id, project_dir) = blocked_gh_automerge_fixture(
    "sweep-finalize",
    pr_number,
    review_mode=@types.ReviewMode::Iterative,
  )
  match state.poller.get(pr_number) {
    Some(tracked) =>
      state.poller.restore({
        ..tracked,
        unresolved_thread_ids: [],
        unresolved_thread_ids_fetched: true,
      })
    None => fail("expected tracked PR")
  }
  let child_target = @workspace.local_target_for(
    "test-session",
    "leaf-finalize",
    @types.IsolationMode::Worktree,
  )
  let child_close = @workspace.local_close_target(child_target)
  match state.registry.get(child_id) {
    child =>
      state.register_agent({ ..child, terminal_target: Some(child_target) })
  }
  match state.registry.get(child_id) {
    child => ignore(state.registry.upsert({ ..child, role: @types.Role::TL }))
  }
  state.pending_disconnects.set(child_id, 1L)
  state.worker_no_handoff_prodded_at.set(child_id, 2L)
  let parent_target = @workspace.local_target_for(
    "test-session",
    "TL",
    @types.IsolationMode::Worktree,
  ).to_string()
  let parent_messages : Array[String] = []
  let mut merge_seen = false
  let mut close_seen = false
  let runner = async fn(cmds : Array[@workspace.Command]) {
    @async.sleep(0)
    let statuses = []
    for cmd in cmds {
      if cmd.program == "gh" &&
        cmd.args.length() >= 3 &&
        cmd.args[0] == "pr" &&
        cmd.args[1] == "merge" {
        merge_seen = true
        match state.poller.get(pr_number) {
          Some(current) =>
            assert_eq(current.last_automerge_attempt_sha, "sha-sweep-finalize")
          None => fail("expected tracked PR during merge attempt")
        }
      }
      if cmd.program == child_close.program && cmd.args == child_close.args {
        close_seen = true
      }
      if cmd.program == "choir" &&
        cmd.args.length() >= 4 &&
        cmd.args[0] == "zellij-action" &&
        cmd.args[1] == "send" &&
        cmd.args[2] == parent_target {
        parent_messages.push(cmd.args[3])
      }
      statuses.push(0)
    }
    statuses
  }
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    let repo_view_json =
      #|{"owner":{"login":"brickfrog"},"name":"choir"}
    if (
        cmd.program == "gh" &&
        cmd.args == ["repo", "view", "--json", "owner,name"]
      ) ||
      (
        cmd.program == "timeout" &&
        cmd.args == ["30s", "gh", "repo", "view", "--json", "owner,name"]
      ) {
      return (0, repo_view_json)
    }
    if cmd.program == "gh" &&
      cmd.args.length() >= 2 &&
      cmd.args[0] == "api" &&
      cmd.args[1].has_suffix("/reviews") {
      return (
        0, "[{\"state\":\"APPROVED\",\"user\":{\"login\":\"copilot-pull-request-reviewer[bot]\"},\"submitted_at\":\"2026-05-10T00:00:00Z\"}]",
      )
    }
    if cmd.args.contains("graphql") {
      return (
        0, "{\"data\":{\"repository\":{\"pullRequest\":{\"reviewThreads\":{\"nodes\":[]}}}}}",
      )
    }
    (0, "")
  }
  state.process_poller_tick_with_test(
    500L,
    900L,
    async fn(_pr_number, _skip_issue_comment_fetch) {
      @async.sleep(0)
      (
        true,
        @poller.ReviewState::Approved,
        "sha-sweep-finalize",
        @poller.CiRollupStatus::Success,
        "",
        true,
        false,
        @poller.Mergeable::Unknown,
        @poller.MergeStateStatus::Unknown,
        None,
      )
    },
    runner~,
    capture~,
    automerge_capture=capture,
  )
  assert_true(merge_seen)
  assert_true(close_seen)
  let mut delivered_merged = false
  for message in parent_messages {
    if message.contains(
        "[PR MERGED] " +
        child_id +
        " PR #" +
        pr_number.to_string() +
        " is merged",
      ) {
      assert_true(message.contains("parent_branch: main"))
      assert_true(
        message.contains(
          "pr_url: https://github.com/brickfrog/choir/pull/" +
          pr_number.to_string(),
        ),
      )
      delivered_merged = true
    }
  }
  assert_true(delivered_merged)
  assert_true(state.poller.get(pr_number) == None)
  @debug.assert_eq(state.pending_disconnects.get(child_id), None)
  @debug.assert_eq(state.worker_no_handoff_prodded_at.get(child_id), None)
  match @phase.read_lifecycle(project_dir, child_id) {
    Some(lifecycle) => {
      assert_eq(
        lifecycle.process,
        @phase.ProcessState::Finalized(reason=@phase.FinalizeReason::Merged),
      )
      match lifecycle.workflow {
        @phase.WorkflowState::Dev(@phase.DevLifecycle::Done(reason~)) =>
          assert_eq(reason, @phase.FinalizeReason::Merged)
        other => fail("expected Done(Merged), got: " + other.to_string())
      }
    }
    None => fail("expected leaf lifecycle")
  }
}

///|
async test "quiet poller tick automerge sweep records attempted head on failure" {
  let pr_number = 97
  let (state, child_id, project_dir) = blocked_gh_automerge_fixture(
    "sweep-failure",
    pr_number,
    review_mode=@types.ReviewMode::Iterative,
  )
  match state.poller.get(pr_number) {
    Some(tracked) =>
      state.poller.restore({
        ..tracked,
        unresolved_thread_ids: [],
        unresolved_thread_ids_fetched: true,
      })
    None => fail("expected tracked PR")
  }
  let child_target = @workspace.local_target_for(
    "test-session",
    "leaf-failure",
    @types.IsolationMode::Worktree,
  )
  let child_close = @workspace.local_close_target(child_target)
  match state.registry.get(child_id) {
    child =>
      ignore(
        state.registry.upsert({ ..child, terminal_target: Some(child_target) }),
      )
  }
  state.pending_disconnects.set(child_id, 1L)
  let parent_target = @workspace.local_target_for(
    "test-session",
    "TL",
    @types.IsolationMode::Worktree,
  ).to_string()
  let parent_messages : Array[String] = []
  let mut close_seen = false
  let mut merge_seen_count = 0
  let runner = async fn(cmds : Array[@workspace.Command]) {
    @async.sleep(0)
    let statuses = []
    for cmd in cmds {
      if cmd.program == "gh" &&
        cmd.args.length() >= 3 &&
        cmd.args[0] == "pr" &&
        cmd.args[1] == "merge" {
        merge_seen_count = merge_seen_count + 1
        statuses.push(1)
      } else {
        if cmd.program == child_close.program && cmd.args == child_close.args {
          close_seen = true
        }
        if cmd.program == "choir" &&
          cmd.args.length() >= 4 &&
          cmd.args[0] == "zellij-action" &&
          cmd.args[1] == "send" &&
          cmd.args[2] == parent_target {
          parent_messages.push(cmd.args[3])
        }
        statuses.push(0)
      }
    }
    statuses
  }
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    let repo_view_json =
      #|{"owner":{"login":"brickfrog"},"name":"choir"}
    if (
        cmd.program == "gh" &&
        cmd.args == ["repo", "view", "--json", "owner,name"]
      ) ||
      (
        cmd.program == "timeout" &&
        cmd.args == ["30s", "gh", "repo", "view", "--json", "owner,name"]
      ) {
      return (0, repo_view_json)
    }
    if cmd.program == "gh" &&
      cmd.args.length() >= 2 &&
      cmd.args[0] == "api" &&
      cmd.args[1].has_suffix("/reviews") {
      return (
        0, "[{\"state\":\"APPROVED\",\"user\":{\"login\":\"copilot-pull-request-reviewer[bot]\"},\"submitted_at\":\"2026-05-10T00:00:00Z\"}]",
      )
    }
    if cmd.args.contains("graphql") {
      return (
        0, "{\"data\":{\"repository\":{\"pullRequest\":{\"reviewThreads\":{\"nodes\":[]}}}}}",
      )
    }
    if cmd.program == "gh" &&
      cmd.args.length() >= 3 &&
      cmd.args[0] == "pr" &&
      cmd.args[1] == "merge" {
      return (1, "transient gh failure")
    }
    (0, "")
  }
  let poll_same_head = async fn(_pr_number, _skip_issue_comment_fetch) {
    @async.sleep(0)
    (
      true,
      @poller.ReviewState::Approved,
      "sha-sweep-failure",
      @poller.CiRollupStatus::Success,
      "",
      true,
      false,
      @poller.Mergeable::Unknown,
      @poller.MergeStateStatus::Unknown,
      None,
    )
  }
  state.process_poller_tick_with_test(
    500L,
    900L,
    poll_same_head,
    runner~,
    capture~,
    automerge_capture=capture,
  )
  assert_eq(merge_seen_count, 1)
  match state.poller.get(pr_number) {
    Some(current) =>
      assert_eq(current.last_automerge_attempt_sha, "sha-sweep-failure")
    None => fail("failed merge must remain tracked")
  }
  assert_false(close_seen)
  for message in parent_messages {
    assert_false(
      message.contains(
        "[PR MERGED] " +
        child_id +
        " PR #" +
        pr_number.to_string() +
        " is merged",
      ),
    )
  }
  @debug.assert_eq(state.pending_disconnects.get(child_id), Some(1L))
  match @phase.read_lifecycle(project_dir, child_id) {
    Some(lifecycle) =>
      match lifecycle.workflow {
        @phase.WorkflowState::Dev(
          @phase.DevLifecycle::ReviewOwned(pr_number=n, ..)
        ) => assert_eq(n, pr_number)
        other =>
          fail("expected leaf to stay ReviewOwned, got: " + other.to_string())
      }
    None => fail("expected leaf lifecycle")
  }
  state.process_poller_tick_with_test(
    600L,
    900L,
    poll_same_head,
    runner~,
    capture~,
    automerge_capture=capture,
  )
  assert_eq(merge_seen_count, 1)
}

///|
async test "automerge sweep runs after queued parent rows are delivered" {
  let pr_number = 98
  let (state, _, _) = blocked_gh_automerge_fixture(
    "sweep-after-parent",
    pr_number,
    review_mode=@types.ReviewMode::Iterative,
  )
  match state.poller.get(pr_number) {
    Some(tracked) =>
      state.poller.restore({
        ..tracked,
        last_ci_rollup: @poller.CiRollupStatus::InProgress,
        mergeable: @poller.Mergeable::Unknown,
        merge_state_status: @poller.MergeStateStatus::Unknown,
        merged_at_unix: None,
        copilot_issue_comment_seen: false,
      })
    None => fail("expected tracked PR")
  }
  let parent_target = @workspace.local_target_for(
    "test-session",
    "TL",
    @types.IsolationMode::Worktree,
  ).to_string()
  let parent_messages : Array[String] = []
  let runner = async fn(cmds : Array[@workspace.Command]) {
    @async.sleep(0)
    let statuses = []
    for cmd in cmds {
      if cmd.program == "choir" &&
        cmd.args.length() >= 4 &&
        cmd.args[0] == "zellij-action" &&
        cmd.args[1] == "send" &&
        cmd.args[2] == parent_target {
        parent_messages.push(cmd.args[3])
      }
      statuses.push(0)
    }
    statuses
  }
  let mut graphql_calls = 0
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    let repo_view_json =
      #|{"owner":{"login":"brickfrog"},"name":"choir"}
    if (
        cmd.program == "gh" &&
        cmd.args == ["repo", "view", "--json", "owner,name"]
      ) ||
      (
        cmd.program == "timeout" &&
        cmd.args == ["30s", "gh", "repo", "view", "--json", "owner,name"]
      ) {
      return (0, repo_view_json)
    }
    if cmd.program == "gh" &&
      cmd.args.length() >= 2 &&
      cmd.args[0] == "api" &&
      cmd.args[1].has_suffix("/reviews") {
      return (
        0, "[{\"state\":\"APPROVED\",\"user\":{\"login\":\"copilot-pull-request-reviewer[bot]\"},\"submitted_at\":\"2026-05-10T00:00:00Z\"}]",
      )
    }
    if cmd.args.contains("graphql") {
      graphql_calls = graphql_calls + 1
      if graphql_calls == 1 {
        return (
          0,
          (
            #|{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"PRRT_blocked","isResolved":false,"isOutdated":false,"author":{"login":"copilot-pull-request-reviewer[bot]"},"path":"src/x.mbt","comments":{"nodes":[{"body":"fix it"}]}}]}}}}}
          ),
        )
      }
      return (
        0, "{\"data\":{\"repository\":{\"pullRequest\":{\"reviewThreads\":{\"nodes\":[]}}}}}",
      )
    }
    (0, "")
  }
  state.process_poller_tick_with_test(
    500L,
    900L,
    async fn(_pr_number, _skip_issue_comment_fetch) {
      @async.sleep(0)
      (
        true,
        @poller.ReviewState::Approved,
        "sha-sweep-after-parent",
        @poller.CiRollupStatus::Success,
        "looks good",
        true,
        true,
        @poller.Mergeable::Unknown,
        @poller.MergeStateStatus::Unknown,
        None,
      )
    },
    runner~,
    capture~,
    automerge_capture=capture,
  )
  assert_eq(parent_messages.length(), 3)
  assert_true(parent_messages[0].contains("[CI LATEST HEAD]"))
  assert_true(parent_messages[1].contains("[COPILOT ISSUE COMMENT]"))
  assert_true(parent_messages[2].contains("[PR MERGED]"))
  assert_true(state.poller.get(pr_number) == None)
}

///|
async test "blocked gh notify auto-merges when latest poller snapshot is clear" {
  let pr_number = 92
  let (state, child_id, _) = blocked_gh_automerge_fixture(
    "fires",
    pr_number,
    review_mode=@types.ReviewMode::Iterative,
  )
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
    if cmd.args.contains("repo") && cmd.args.contains("view") {
      return (0, repo_view_json)
    }
    if cmd.args.contains("graphql") {
      return (0, review_threads_json)
    }
    if cmd.program == "gh" &&
      cmd.args.length() >= 2 &&
      cmd.args[0] == "api" &&
      cmd.args[1].has_suffix("/reviews") {
      let reviews_json =
        #|[{"state":"APPROVED","user":{"login":"copilot-pull-request-reviewer[bot]"},"submitted_at":"2026-05-10T00:00:00Z"}]
      return (0, reviews_json)
    }
    (0, "")
  }
  let resp = state.handle_with_runner_and_capture(
    blocked_gh_notify_request(
      child_id, "[BLOCKED] bounded GraphQL review-thread check timed out (exit 124). I cannot confirm zero unresolved review threads, so I am not reporting review-complete.",
    ),
    runner~,
    capture~,
  )
  assert_true(resp.is_ok())
  assert_true(merge_seen)
  assert_true(state.poller.get(pr_number) == None)
}

///|
async test "blocked gh notify honors single-pass review mode for fixes pushed" {
  let pr_number = 94
  let (state, child_id, _) = blocked_gh_automerge_fixture(
    "singlepass",
    pr_number,
    review_mode=@types.ReviewMode::SinglePass,
  )
  match state.poller.get(pr_number) {
    Some(tracked) =>
      state.poller.restore({
        ..tracked,
        last_review_state: @poller.ReviewState::ChangesRequested,
        last_sha: "fix-sha-singlepass",
        changes_requested_since: 0L,
        fixes_pushed_at: 999L,
        review_mode: @types.ReviewMode::SinglePass,
        unresolved_thread_ids: [],
        unresolved_thread_ids_fetched: false,
        auto_resolve_outdated_pending: false,
      })
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
    if cmd.args.contains("repo") && cmd.args.contains("view") {
      return (0, repo_view_json)
    }
    if cmd.args.contains("graphql") {
      return (0, review_threads_json)
    }
    if cmd.program == "gh" &&
      cmd.args.length() >= 2 &&
      cmd.args[0] == "api" &&
      cmd.args[1].has_suffix("/reviews") {
      let reviews_json =
        #|[{"state":"APPROVED","user":{"login":"copilot-pull-request-reviewer[bot]"},"submitted_at":"2026-05-10T00:00:00Z"}]
      return (0, reviews_json)
    }
    (0, "")
  }
  let resp = state.handle_with_runner_and_capture(
    blocked_gh_notify_request(
      child_id, "[BLOCKED] bounded GraphQL review-thread check timed out (exit 124). I cannot confirm zero unresolved review threads, so I am not reporting review-complete.",
    ),
    runner~,
    capture~,
  )
  assert_true(resp.is_ok())
  assert_true(merge_seen)
  assert_true(state.poller.get(pr_number) == None)
}

///|
async test "blocked gh notify uses tracked review mode over global config" {
  let pr_number = 95
  let (state, child_id, _) = blocked_gh_automerge_fixture(
    "tracked-singlepass",
    pr_number,
    review_mode=@types.ReviewMode::Iterative,
  )
  match state.poller.get(pr_number) {
    Some(tracked) =>
      state.poller.restore({
        ..tracked,
        last_review_state: @poller.ReviewState::ChangesRequested,
        last_sha: "fix-sha-tracked-singlepass",
        changes_requested_since: 0L,
        fixes_pushed_at: 999L,
        review_mode: @types.ReviewMode::SinglePass,
      })
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
    if cmd.args.contains("repo") && cmd.args.contains("view") {
      return (0, "{\"owner\":{\"login\":\"brickfrog\"},\"name\":\"choir\"}")
    }
    if cmd.args.contains("graphql") {
      return (
        0, "{\"data\":{\"repository\":{\"pullRequest\":{\"reviewThreads\":{\"nodes\":[]}}}}}",
      )
    }
    if cmd.program == "gh" &&
      cmd.args.length() >= 2 &&
      cmd.args[0] == "api" &&
      cmd.args[1].has_suffix("/reviews") {
      return (
        0, "[{\"state\":\"APPROVED\",\"user\":{\"login\":\"copilot-pull-request-reviewer[bot]\"},\"submitted_at\":\"2026-05-10T00:00:00Z\"}]",
      )
    }
    (0, "")
  }
  let resp = state.handle_with_runner_and_capture(
    blocked_gh_notify_request(
      child_id, "[BLOCKED] bounded GraphQL review-thread check timed out (exit 124). I cannot confirm zero unresolved review threads, so I am not reporting review-complete.",
    ),
    runner~,
    capture~,
  )
  assert_true(resp.is_ok())
  assert_true(merge_seen)
  assert_true(state.poller.get(pr_number) == None)
}

///|
async test "blocked gh notify does not auto-merge unrelated blocked reasons" {
  let pr_number = 93
  let (state, child_id, _) = blocked_gh_automerge_fixture(
    "nofire",
    pr_number,
    review_mode=@types.ReviewMode::Iterative,
  )
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
    if cmd.args.contains("repo") && cmd.args.contains("view") {
      return (0, repo_view_json)
    }
    if cmd.args.contains("graphql") {
      return (0, review_threads_json)
    }
    (0, "")
  }
  let resp = state.handle_with_runner_and_capture(
    blocked_gh_notify_request(
      child_id, "[BLOCKED] compile error in src/server/handler_test.mbt",
    ),
    runner~,
    capture~,
  )
  assert_true(resp.is_ok())
  assert_false(merge_seen)
  match state.poller.get(pr_number) {
    Some(_) => ()
    None => fail("unrelated BLOCKED reason must not untrack or merge the PR")
  }
  // Adversarial reason: hits three of the four matcher gates but is missing
  // the `bounded` discipline keyword — it's a real CI/network failure, not a
  // bounded-gh-discipline timeout. Must not auto-merge.
  let resp_partial = state.handle_with_runner_and_capture(
    blocked_gh_notify_request(
      child_id, "[BLOCKED] github action runner timed out fetching a sibling review thread; see actions log",
    ),
    runner~,
    capture~,
  )
  assert_true(resp_partial.is_ok())
  assert_false(merge_seen)
  match state.poller.get(pr_number) {
    Some(_) => ()
    None =>
      fail(
        "BLOCKED reason missing the `bounded` discipline keyword must not auto-merge",
      )
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
  ignore(@sys.create_dir_all(project_dir + "/.choir/kv"))
  let terminal_session = "test-session"
  let config = { ..@types.Config::default(), project_dir, terminal_session }
  let state = ServerState::new(config, make_hermetic_recovery_provider())
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
/// Regression: an empty caller_id used to reach
/// `reconcile_killed_agent_tracked_prs`, where the branch guard
/// short-circuited on an empty caller_branch and auto-closed every
/// tracked PR. The boundary in `handler.mbt` now rejects empty
/// caller_id before dispatching reconciliation.
async test "kill_agent with empty caller_id does not auto-close tracked PRs" {
  let pr_number = 312
  let (state, _parent_id, child_id) = kill_agent_reconciliation_fixture(
    "empty-caller", pr_number,
  )
  let mut close_seen = false
  let runner = async fn(cmds : Array[@workspace.Command]) {
    @async.sleep(0)
    let statuses = []
    for _ in cmds {
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
    args: @types.RequestArgs::new({ "agent_id": child_id, "caller_id": "" }),
  }
  let resp = state.handle_with_runner_and_capture(req, runner~, capture~)
  assert_true(resp.is_ok())
  assert_false(close_seen)
  assert_true(state.poller.get(pr_number) is Some(_))
}

///|
fn parent_poll_test_ready_tracked(pr_number : Int) -> @poller.TrackedPR {
  {
    pr_number,
    agent_id: "main.dev-ready",
    branch: "work/ready",
    parent_branch: "main",
    pr_url: "https://ex/pr/" + pr_number.to_string(),
    first_seen: 0,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::Approved,
    last_review_bodies: "",
    last_sha: "sha",
    last_automerge_attempt_sha: "",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Success,
    mergeable: @poller.Mergeable::Unknown,
    merge_state_status: @poller.MergeStateStatus::Unknown,
    merged_at_unix: None,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: true,
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
async test "PRMerged completion hook fires only PrMerged for feature parent" {
  let pr = {
    ..parent_poll_test_ready_tracked(501),
    agent_id: "feature/base.leaf",
    branch: "feature/base.leaf",
    parent_branch: "feature/base",
    pr_url: "https://example.test/pull/501",
  }
  let fired_paths : Array[String] = []
  let fired_inputs : Array[@hooks.HookInput] = []
  let mut default_branch_checks = 0
  let capture = async fn(_cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    default_branch_checks = default_branch_checks + 1
    (0, "origin/main\n")
  }
  let hook_capture = async fn(
    path : String,
    input_json : String,
    cwd : String?,
  ) -> (Int, String) {
    @async.sleep(0)
    fired_paths.push(path)
    @debug.assert_eq(cwd, Some("/repo"))
    match @hooks.HookInput::from_json_string(input_json) {
      Some(input) => fired_inputs.push(input)
      None => fail("expected completion hook input JSON")
    }
    (0, "hook stdout")
  }
  let path_exists = fn(path : String) -> Bool {
    path.has_suffix("/pr_merged.sh") || path.has_suffix("/wave_complete.sh")
  }
  fire_pr_merged_completion_hooks(
    "/repo",
    pr,
    capture~,
    hook_capture~,
    path_exists~,
  )

  assert_eq(default_branch_checks, 1)
  assert_eq(fired_inputs.length(), 1)
  assert_eq(fired_paths[0], "/repo/.choir/hooks/pr_merged.sh")
  let input = fired_inputs[0]
  assert_eq(input.event, @hooks.HookEvent::PrMerged)
  @debug.assert_eq(input.pr_number, Some(501))
  @debug.assert_eq(input.pr_url, Some("https://example.test/pull/501"))
  @debug.assert_eq(input.branch, Some("feature/base.leaf"))
  @debug.assert_eq(input.parent_branch, Some("feature/base"))
  @debug.assert_eq(input.merge_provenance, Some("external_observation"))
  @debug.assert_eq(input.agent_id, Some("feature/base.leaf"))
}

///|
async test "PRMerged completion hook uses global hook when project hook is absent" {
  let pr = {
    ..parent_poll_test_ready_tracked(511),
    agent_id: "feature/base.leaf",
    branch: "feature/base.leaf",
    parent_branch: "feature/base",
    pr_url: "https://example.test/pull/511",
  }
  let fired_paths : Array[String] = []
  let mut default_branch_checks = 0
  let capture = async fn(_cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    default_branch_checks = default_branch_checks + 1
    (0, "origin/main\n")
  }
  let hook_capture = async fn(
    path : String,
    _input_json : String,
    cwd : String?,
  ) -> (Int, String) {
    @async.sleep(0)
    fired_paths.push(path)
    @debug.assert_eq(cwd, Some("/repo"))
    (0, "hook stdout")
  }
  fire_pr_merged_completion_hooks(
    "/repo",
    pr,
    capture~,
    hook_capture~,
    path_exists=fn(path) { path == "/home/me/.config/choir/hooks/pr_merged.sh" },
    xdg_config_home=None,
    home="/home/me",
  )

  assert_eq(default_branch_checks, 0)
  @debug.assert_eq(fired_paths, ["/home/me/.config/choir/hooks/pr_merged.sh"])
}

///|
async test "PRMerged completion hook fires PrMerged and WaveComplete for main parent" {
  let pr = {
    ..parent_poll_test_ready_tracked(502),
    agent_id: "feature/base.integration",
    branch: "feature/base",
    parent_branch: "main",
    pr_url: "https://example.test/pull/502",
  }
  let fired_inputs : Array[@hooks.HookInput] = []
  let capture = async fn(_cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    (0, "origin/main\n")
  }
  let hook_capture = async fn(
    _path : String,
    input_json : String,
    _cwd : String?,
  ) -> (Int, String) {
    @async.sleep(0)
    match @hooks.HookInput::from_json_string(input_json) {
      Some(input) => fired_inputs.push(input)
      None => fail("expected completion hook input JSON")
    }
    (0, "hook stdout")
  }
  let path_exists = fn(path : String) -> Bool {
    path.has_suffix("/pr_merged.sh") || path.has_suffix("/wave_complete.sh")
  }
  fire_pr_merged_completion_hooks(
    "/repo",
    pr,
    capture~,
    hook_capture~,
    path_exists~,
  )

  assert_eq(fired_inputs.length(), 2)
  assert_eq(fired_inputs[0].event, @hooks.HookEvent::PrMerged)
  assert_eq(fired_inputs[1].event, @hooks.HookEvent::WaveComplete)
  @debug.assert_eq(fired_inputs[1].pr_number, Some(502))
  @debug.assert_eq(fired_inputs[1].parent_branch, Some("main"))
  @debug.assert_eq(
    fired_inputs[1].merge_provenance,
    Some("external_observation"),
  )
  @debug.assert_eq(fired_inputs[1].agent_id, Some("feature/base.integration"))
}

///|
async test "PRMerged completion hook does not fire WaveComplete for non-default main parent" {
  let pr = {
    ..parent_poll_test_ready_tracked(503),
    agent_id: "trunk.leaf",
    branch: "feature/main-is-not-default",
    parent_branch: "main",
    pr_url: "https://example.test/pull/503",
  }
  let fired_inputs : Array[@hooks.HookInput] = []
  let capture = async fn(_cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    (0, "origin/trunk\n")
  }
  let hook_capture = async fn(
    _path : String,
    input_json : String,
    _cwd : String?,
  ) -> (Int, String) {
    @async.sleep(0)
    match @hooks.HookInput::from_json_string(input_json) {
      Some(input) => fired_inputs.push(input)
      None => fail("expected completion hook input JSON")
    }
    (0, "hook stdout")
  }
  let path_exists = fn(path : String) -> Bool {
    path.has_suffix("/pr_merged.sh") || path.has_suffix("/wave_complete.sh")
  }
  fire_pr_merged_completion_hooks(
    "/repo",
    pr,
    capture~,
    hook_capture~,
    path_exists~,
  )

  assert_eq(fired_inputs.length(), 1)
  assert_eq(fired_inputs[0].event, @hooks.HookEvent::PrMerged)
  @debug.assert_eq(fired_inputs[0].parent_branch, Some("main"))
}

///|
async test "deliver_pending_poll_events fires PRMerged hook whether tracked or swept" {
  let run_case = async fn(
    label : String,
    tracked : Bool,
    pr_number : Int,
  ) -> Int {
    let project_dir = "/tmp/choir-deliver-pr-merged-hook-" +
      label +
      "-" +
      @sys.get_pid().to_string() +
      "-" +
      @env.now().reinterpret_as_int64().to_string()
    ignore(@sys.create_dir_all(project_dir + "/.choir/kv"))
    ignore(@sys.create_dir_all(project_dir + "/.choir/hooks"))
    ignore(@sys.write_file_sync(project_dir + "/.choir/hooks/pr_merged.sh", ""))
    let state = ServerState::new(
      {
        ..@types.Config::default(),
        project_dir,
        auto_pull_after_integration: false,
        pr_policy: { require_integration_audit: false },
      },
      make_hermetic_recovery_provider(),
    )
    let parent_id = "main.parent"
    let child_id = "main.child"
    ignore(
      state.register_agent({
        agent_id: parent_id,
        role: @types.Role::TL,
        agent_type: @types.AgentType::Claude,
        parent: None,
        workspace: project_dir,
        branch: "main",
        terminal_target: None,
        host: @types.Host::Local,
        spawn_depth: 0,
        state: @types.AgentState::Active,
      }),
    )
    ignore(
      state.register_agent({
        agent_id: child_id,
        role: @types.Role::Dev,
        agent_type: @types.AgentType::Codex,
        parent: Some(parent_id),
        workspace: project_dir + "/.choir/worktrees/child",
        branch: child_id,
        terminal_target: None,
        host: @types.Host::Local,
        spawn_depth: 1,
        state: @types.AgentState::Active,
      }),
    )
    let pr = {
      ..parent_poll_test_ready_tracked(pr_number),
      agent_id: child_id,
      branch: child_id,
      parent_branch: if tracked {
        "feature/base"
      } else {
        "main"
      },
      pr_url: "https://example.test/pull/" + pr_number.to_string(),
    }
    if tracked {
      state.poller.restore(pr)
    }
    let fired_inputs : Array[@hooks.HookInput] = []
    state.process_poller_tick_with_test(
      1000L,
      900L,
      async fn(_pr_number, _skip_issue_comment_fetch) {
        @async.sleep(0)
        (
          true,
          @poller.ReviewState::Approved,
          "sha-merged",
          @poller.CiRollupStatus::Success,
          "",
          false,
          true,
          @poller.Mergeable::Unknown,
          @poller.MergeStateStatus::Unknown,
          None,
        )
      },
      runner=async fn(cmds : Array[@workspace.Command]) {
        @async.sleep(0)
        cmds.map(fn(_) { 0 })
      },
      capture=async fn(cmd : @workspace.Command) {
        @async.sleep(0)
        if cmd.program == "git" &&
          cmd.args == ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"] {
          return (0, "origin/main\n")
        }
        if cmd.program == "gh" && cmd.args.contains("list") {
          if tracked {
            return (0, "[]")
          }
          return (
            0,
            "[{\"number\":" +
            pr_number.to_string() +
            ",\"url\":\"https://example.test/pull/" +
            pr_number.to_string() +
            "\",\"headRefName\":\"" +
            child_id +
            "\",\"baseRefName\":\"main\",\"mergedAt\":\"2099-12-31T00:00:00Z\"}]",
          )
        }
        (0, "")
      },
      automerge_capture=async fn(_cmd : @workspace.Command) {
        @async.sleep(0)
        (0, "")
      },
      hook_capture=async fn(
        _path : String,
        input_json : String,
        _cwd : String?,
      ) {
        @async.sleep(0)
        match @hooks.HookInput::from_json_string(input_json) {
          Some(input) => fired_inputs.push(input)
          None => fail("expected hook JSON")
        }
        (0, "hook")
      },
    )
    let fired_count = fired_inputs.length()
    if fired_count > 0 {
      assert_eq(fired_inputs[0].event, @hooks.HookEvent::PrMerged)
      @debug.assert_eq(fired_inputs[0].pr_number, Some(pr_number))
    }
    assert_true(
      @sys.read_file(project_dir + "/.choir/seen_merged_prs.json").contains(
        pr_number.to_string(),
      ),
    )
    ignore(@sys.rm_rf(project_dir))
    fired_count
  }
  assert_eq(run_case("tracked", true, 620), 1)
  assert_eq(run_case("swept", false, 621), 1)
}

///|
test "seen merge cache predicate and capacity" {
  assert_true(should_emit_untracked_pr_merged(false, false))
  assert_false(should_emit_untracked_pr_merged(true, false))
  assert_false(should_emit_untracked_pr_merged(false, true))
  let cache = update_seen_merge_cache([1, 2, 3], 2, capacity=3)
  @debug.assert_eq(cache, [1, 3, 2])
  let bounded = update_seen_merge_cache(cache, 4, capacity=3)
  @debug.assert_eq(bounded, [3, 2, 4])
}

///|
test "should_auto_pull_parent truth table" {
  assert_true(should_auto_pull_parent("main", "main", "main", true, true))
  assert_false(
    should_auto_pull_parent("feature/base", "main", "main", true, true),
  )
  assert_false(
    should_auto_pull_parent("main", "main", "feature/work", true, true),
  )
  assert_false(should_auto_pull_parent("main", "main", "main", false, true))
  assert_false(should_auto_pull_parent("main", "main", "main", true, false))
}

///|
test "detect_unaudited_integration_merge returns typed outcome for each path" {
  let receipt = "/repo/.choir/audit-receipts/abcdef123456.json"
  let valid_receipt_exists = fn(path : String) -> Bool { path == receipt }
  @debug.assert_eq(
    detect_unaudited_integration_merge(receipt, valid_receipt_exists, true),
    AuditEnforcementOutcome::Audited,
  )
  @debug.assert_eq(
    detect_unaudited_integration_merge(receipt, fn(_) { false }, true),
    AuditEnforcementOutcome::UnauditedBlocked,
  )
  @debug.assert_eq(
    detect_unaudited_integration_merge(receipt, fn(_) { false }, false),
    AuditEnforcementOutcome::UnauditedWarned,
  )
  @debug.assert_eq(
    detect_unaudited_integration_merge("", valid_receipt_exists, true),
    AuditEnforcementOutcome::NotApplicable,
  )
}

///|
test "valid_merge_audit_receipt_exists rejects invalid receipts for non-main default branch" {
  let head = "abcdef1234567890abcdef1234567890abcdef12"
  let other_head = "0000000000000000000000000000000000000000"
  let receipt_path = "/repo/.choir/audit-receipts/abcdef123456.json"
  let mut body = handler_test_audit_receipt(head, "feature/t92", 0)
  let exists = fn(path : String) -> Bool { path == receipt_path }
  let read_paths : Array[String] = []
  let read = fn(path : String) -> String {
    read_paths.push(path)
    body
  }
  assert_true(
    valid_merge_audit_receipt_exists(receipt_path, "trunk", head, exists, read),
  )
  body = handler_test_audit_receipt(other_head, "feature/t92", 0)
  assert_false(
    valid_merge_audit_receipt_exists(receipt_path, "trunk", head, exists, read),
  )
  body = handler_test_audit_receipt(head, "feature/t92", 2)
  assert_false(
    valid_merge_audit_receipt_exists(receipt_path, "trunk", head, exists, read),
  )
  body = "{not json"
  assert_false(
    valid_merge_audit_receipt_exists(receipt_path, "trunk", head, exists, read),
  )
  assert_false(
    valid_merge_audit_receipt_exists(
      receipt_path,
      "trunk",
      head,
      fn(_) { false },
      read,
    ),
  )
  for path in read_paths {
    assert_eq(path, receipt_path)
  }
}

///|
fn handler_test_audit_receipt(
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
async test "untracked merge detection emits synthetic PRMerged and fires hooks" {
  let project_dir = "/tmp/choir-synthetic-untracked-merge-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.create_dir_all(project_dir + "/.choir/kv"))
  let state = ServerState::new(
    {
      ..@types.Config::default(),
      project_dir,
      auto_pull_after_integration: false,
    },
    make_hermetic_recovery_provider(),
  )
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    if cmd.program == "git" &&
      cmd.args == ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"] {
      return (0, "origin/main\n")
    }
    if cmd.program == "gh" && cmd.args.contains("list") {
      return (
        0, "[{\"number\":612,\"url\":\"https://example.test/pull/612\",\"headRefName\":\"feature/integration\",\"headRefOid\":\"abcdef1234567890\",\"baseRefName\":\"main\",\"mergedAt\":\"2099-12-31T00:00:00Z\"}]",
      )
    }
    (0, "")
  }
  let events = detect_untracked_pr_merged_events(state, 1000L, capture)
  assert_eq(events.length(), 1)
  let pr = match events[0] {
    @poller.PollEvent::PRMerged(pr) => pr
    _ => fail("expected synthetic PRMerged")
  }
  assert_eq(pr.last_sha, "abcdef1234567890")
  @debug.assert_eq(pr.merged_at_unix, Some(4102358400L))
  let fired_inputs : Array[@hooks.HookInput] = []
  fire_pr_merged_completion_hooks(
    project_dir,
    pr,
    capture~,
    hook_capture=async fn(
      _path : String,
      input_json : String,
      _cwd : String?,
    ) -> (Int, String) {
      @async.sleep(0)
      match @hooks.HookInput::from_json_string(input_json) {
        Some(input) => fired_inputs.push(input)
        None => fail("expected hook JSON")
      }
      (0, "hook")
    },
    path_exists=fn(path) {
      path.has_suffix("/pr_merged.sh") || path.has_suffix("/wave_complete.sh")
    },
  )
  assert_eq(fired_inputs.length(), 2)
  assert_eq(fired_inputs[0].event, @hooks.HookEvent::PrMerged)
  assert_eq(fired_inputs[1].event, @hooks.HookEvent::WaveComplete)
  @debug.assert_eq(fired_inputs[0].pr_number, Some(612))
  @debug.assert_eq(fired_inputs[0].branch, Some("feature/integration"))
  @debug.assert_eq(fired_inputs[0].parent_branch, Some("main"))
  assert_false(state.poller.merged_observed(612))
  assert_false(@sys.path_exists(project_dir + "/.choir/seen_merged_prs.json"))
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "PRMerged into default branch without audit receipt fires hooks and stays re-checkable while skipping auto-pull" {
  let run_case = async fn(
    label : String,
    pr_number : Int,
    default_branch_lookup_ok : Bool,
  ) -> Unit {
    let project_dir = "/tmp/choir-unaudited-integration-merge-" +
      label +
      "-" +
      @sys.get_pid().to_string() +
      "-" +
      @env.now().reinterpret_as_int64().to_string()
    ignore(@sys.create_dir_all(project_dir + "/.choir/kv"))
    ignore(@sys.create_dir_all(project_dir + "/.choir/hooks"))
    ignore(@sys.write_file_sync(project_dir + "/.choir/hooks/pr_merged.sh", ""))
    ignore(
      @sys.write_file_sync(project_dir + "/.choir/hooks/wave_complete.sh", ""),
    )
    let state = ServerState::new(
      { ..@types.Config::default(), project_dir, },
      make_hermetic_recovery_provider(),
    )
    let parent_id = "main.t92-parent-" + label
    let child_id = "main.t92-leaf-" + label
    ignore(
      state.register_agent({
        agent_id: parent_id,
        role: @types.Role::TL,
        agent_type: @types.AgentType::Codex,
        parent: None,
        workspace: project_dir,
        branch: "main",
        terminal_target: None,
        host: @types.Host::Local,
        spawn_depth: 0,
        state: @types.AgentState::Active,
      }),
    )
    ignore(
      state.register_agent({
        agent_id: child_id,
        role: @types.Role::Dev,
        agent_type: @types.AgentType::Codex,
        parent: Some(parent_id),
        workspace: project_dir + "/.choir/worktrees/" + child_id,
        branch: "feature/t92-integration",
        terminal_target: None,
        host: @types.Host::Local,
        spawn_depth: 1,
        state: @types.AgentState::Active,
      }),
    )
    let head = "abcdef1234567890abcdef1234567890abcdef12"
    assert_true(state.config.pr_policy.require_integration_audit)
    let pr = {
      ..parent_poll_test_ready_tracked(pr_number),
      agent_id: child_id,
      branch: "feature/t92-integration",
      parent_branch: "main",
      pr_url: "https://example.test/pull/" + pr_number.to_string(),
      last_sha: "old-sha",
    }
    state.poller.restore(pr)
    let mut pull_calls = 0
    let mut hook_calls = 0
    let mut receipt_read_calls = 0
    let mut receipt_available = false
    let mut gh_list_enabled = false
    let checked_receipts : Array[String] = []
    state.process_poller_tick_with_test(
      1000L,
      900L,
      async fn(_pr_number, _skip_issue_comment_fetch) {
        @async.sleep(0)
        (
          true,
          @poller.ReviewState::Approved,
          head,
          @poller.CiRollupStatus::Success,
          "",
          false,
          false,
          @poller.Mergeable::Unknown,
          @poller.MergeStateStatus::Unknown,
          Some(4102358400L),
        )
      },
      runner=async fn(cmds : Array[@workspace.Command]) {
        @async.sleep(0)
        cmds.map(fn(_) { 0 })
      },
      capture=async fn(cmd : @workspace.Command) {
        @async.sleep(0)
        if cmd.program == "git" &&
          cmd.args == ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"] {
          if !default_branch_lookup_ok {
            return (1, "")
          }
          return (0, "origin/main\n")
        }
        if cmd.program == "gh" && cmd.args.contains("list") {
          if gh_list_enabled {
            return (
              0,
              "[{\"number\":" +
              pr_number.to_string() +
              ",\"url\":\"https://example.test/pull/" +
              pr_number.to_string() +
              "\",\"headRefName\":\"feature/t92-integration\",\"headRefOid\":\"" +
              head +
              "\",\"baseRefName\":\"main\",\"mergedAt\":\"2099-12-31T00:00:00Z\"}]",
            )
          }
          return (0, "[]")
        }
        (0, "")
      },
      automerge_capture=async fn(_cmd : @workspace.Command) {
        @async.sleep(0)
        (0, "")
      },
      hook_capture=async fn(
        _path : String,
        _input_json : String,
        _cwd : String?,
      ) -> (Int, String) {
        @async.sleep(0)
        hook_calls = hook_calls + 1
        (0, "hook")
      },
      git_state_capture=async fn(
        _workdir : String,
        _capture : async (@workspace.Command) -> (Int, String),
      ) -> ParentWorktreeGitState? {
        @async.sleep(0)
        Some(parent_worktree_git_state("main", true))
      },
      git_pull_runner=async fn(
        _workdir : String,
        _capture : async (@workspace.Command) -> (Int, String),
      ) -> Bool {
        @async.sleep(0)
        pull_calls = pull_calls + 1
        true
      },
      audit_receipt_exists=fn(path) {
        checked_receipts.push(path)
        receipt_available
      },
      audit_receipt_read=fn(_) {
        receipt_read_calls = receipt_read_calls + 1
        handler_test_audit_receipt(head, "main", 0)
      },
    )
    assert_eq(pull_calls, 0)
    assert_eq(hook_calls, 2)
    assert_eq(receipt_read_calls, 0)
    assert_eq(checked_receipts.length(), 1)
    assert_true(checked_receipts[0].contains("abcdef123456"))
    @debug.assert_eq(checked_receipts, [
      project_dir + "/.choir/audit-receipts/abcdef123456.json",
    ])
    assert_false(
      @sys.path_exists(project_dir + "/.choir/seen_merged_prs.json") &&
      @sys.read_file(project_dir + "/.choir/seen_merged_prs.json").contains(
        pr_number.to_string(),
      ),
    )
    receipt_available = true
    gh_list_enabled = true
    state.process_poller_tick_with_test(
      1100L,
      900L,
      async fn(_pr_number, _skip_issue_comment_fetch) {
        @async.sleep(0)
        fail("no tracked PR should remain before the re-check tick")
      },
      runner=async fn(cmds : Array[@workspace.Command]) {
        @async.sleep(0)
        cmds.map(fn(_) { 0 })
      },
      capture=async fn(cmd : @workspace.Command) {
        @async.sleep(0)
        if cmd.program == "git" &&
          cmd.args == ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"] {
          return (0, "origin/main\n")
        }
        if cmd.program == "gh" && cmd.args.contains("list") {
          return (
            0,
            "[{\"number\":" +
            pr_number.to_string() +
            ",\"url\":\"https://example.test/pull/" +
            pr_number.to_string() +
            "\",\"headRefName\":\"feature/t92-integration\",\"headRefOid\":\"" +
            head +
            "\",\"baseRefName\":\"main\",\"mergedAt\":\"2099-12-31T00:00:00Z\"}]",
          )
        }
        (0, "")
      },
      automerge_capture=async fn(_cmd : @workspace.Command) {
        @async.sleep(0)
        (0, "")
      },
      hook_capture=async fn(
        _path : String,
        _input_json : String,
        _cwd : String?,
      ) -> (Int, String) {
        @async.sleep(0)
        hook_calls = hook_calls + 1
        (0, "hook")
      },
      git_state_capture=async fn(
        _workdir : String,
        _capture : async (@workspace.Command) -> (Int, String),
      ) -> ParentWorktreeGitState? {
        @async.sleep(0)
        Some(parent_worktree_git_state("main", true))
      },
      git_pull_runner=async fn(
        _workdir : String,
        _capture : async (@workspace.Command) -> (Int, String),
      ) -> Bool {
        @async.sleep(0)
        pull_calls = pull_calls + 1
        true
      },
      audit_receipt_exists=fn(path) {
        checked_receipts.push(path)
        receipt_available
      },
      audit_receipt_read=fn(_) {
        receipt_read_calls = receipt_read_calls + 1
        handler_test_audit_receipt(head, "main", 0)
      },
    )
    assert_eq(hook_calls, 4)
    assert_eq(pull_calls, 1)
    assert_eq(receipt_read_calls, 2)
    assert_true(
      @sys.read_file(project_dir + "/.choir/seen_merged_prs.json").contains(
        pr_number.to_string(),
      ),
    )
    ignore(@sys.rm_rf(project_dir))
  }
  run_case("missing", 615, true)
  run_case("default-lookup-fails", 616, false)
}

///|
async test "PRMerged into default branch triggers injected parent auto-pull" {
  let project_dir = "/tmp/choir-auto-pull-parent-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.create_dir_all(project_dir + "/.choir/kv"))
  let state = ServerState::new(
    { ..@types.Config::default(), project_dir, },
    make_hermetic_recovery_provider(),
  )
  let pr = {
    ..parent_poll_test_ready_tracked(613),
    agent_id: "user-0-0",
    branch: "feature/integration",
    parent_branch: "main",
    pr_url: "https://example.test/pull/613",
  }
  let pulled_workdirs : Array[String] = []
  maybe_auto_pull_parent_after_pr_merged(
    state,
    pr,
    async fn(cmd : @workspace.Command) {
      @async.sleep(0)
      if cmd.program == "git" &&
        cmd.args == ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"] {
        return (0, "origin/main\n")
      }
      (0, "")
    },
    async fn(_cmd : @workspace.Command) {
      @async.sleep(0)
      (1, "unused")
    },
    async fn(
      workdir : String,
      _capture : async (@workspace.Command) -> (Int, String),
    ) -> ParentWorktreeGitState? {
      @async.sleep(0)
      @debug.assert_eq(workdir, project_dir)
      Some(parent_worktree_git_state("main", true))
    },
    async fn(
      workdir : String,
      _capture : async (@workspace.Command) -> (Int, String),
    ) -> Bool {
      @async.sleep(0)
      pulled_workdirs.push(workdir)
      true
    },
  )
  @debug.assert_eq(pulled_workdirs, [project_dir])
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "PRMerged auto-pull skips dirty parent tree" {
  let project_dir = "/tmp/choir-auto-pull-dirty-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.create_dir_all(project_dir + "/.choir/kv"))
  let state = ServerState::new(
    { ..@types.Config::default(), project_dir, },
    make_hermetic_recovery_provider(),
  )
  let pr = {
    ..parent_poll_test_ready_tracked(614),
    agent_id: "user-0-0",
    branch: "feature/integration",
    parent_branch: "main",
    pr_url: "https://example.test/pull/614",
  }
  let mut pull_calls = 0
  maybe_auto_pull_parent_after_pr_merged(
    state,
    pr,
    async fn(cmd : @workspace.Command) {
      @async.sleep(0)
      if cmd.program == "git" &&
        cmd.args == ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"] {
        return (0, "origin/main\n")
      }
      (0, "")
    },
    async fn(_cmd : @workspace.Command) {
      @async.sleep(0)
      (1, "unused")
    },
    async fn(
      _workdir : String,
      _capture : async (@workspace.Command) -> (Int, String),
    ) -> ParentWorktreeGitState? {
      @async.sleep(0)
      Some(parent_worktree_git_state("main", false))
    },
    async fn(
      _workdir : String,
      _capture : async (@workspace.Command) -> (Int, String),
    ) -> Bool {
      @async.sleep(0)
      pull_calls = pull_calls + 1
      true
    },
  )
  assert_eq(pull_calls, 0)
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "auto_resolve_outdated_review_threads_for_event resolves only iterative FixesPushed outdated threads" {
  let project_dir = "/tmp/choir-auto-resolve-threads-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  assert_true(@sys.create_dir_all(project_dir + "/.choir"))
  let state = ServerState::new(
    { ..@types.Config::default(), project_dir, },
    make_hermetic_recovery_provider(),
  )
  let tracked = {
    ..parent_poll_test_ready_tracked(701),
    review_mode: @types.ReviewMode::Iterative,
    unresolved_thread_ids: [
      @poller.ReviewThreadRef::{
        id: "T_old",
        is_outdated: true,
        author_login: "copilot-pull-request-reviewer[bot]",
      },
      @poller.ReviewThreadRef::{
        id: "T_current",
        is_outdated: false,
        author_login: "copilot-pull-request-reviewer[bot]",
      },
    ],
    unresolved_thread_ids_fetched: true,
  }
  let seen : Array[String] = []
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    for arg in cmd.args {
      if arg.has_prefix("threadId=") {
        seen.push(arg)
      }
    }
    (
      0, "{\"data\":{\"resolveReviewThread\":{\"thread\":{\"isResolved\":true}}}}",
    )
  }
  let updated = state.auto_resolve_outdated_review_threads_for_event(
    @poller.PollEvent::FixesPushed(701),
    tracked,
    capture,
  )
  @debug.assert_eq(seen, ["threadId=T_old"])
  @debug.assert_eq(updated.unresolved_thread_ids, [
    @poller.ReviewThreadRef::{
      id: "T_current",
      is_outdated: false,
      author_login: "copilot-pull-request-reviewer[bot]",
    },
  ])
  assert_false(updated.auto_resolve_outdated_pending)
  let log = @sys.read_file(project_dir + "/.choir/delivery.log")
  assert_true(
    log.contains("poller auto-resolved 1 outdated review thread(s) pr=701"),
  )
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "auto_resolve_outdated_review_threads_for_event skips single pass and non FixesPushed" {
  let project_dir = "/tmp/choir-auto-resolve-skip-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  assert_true(@sys.create_dir_all(project_dir + "/.choir"))
  let state = ServerState::new(
    { ..@types.Config::default(), project_dir, },
    make_hermetic_recovery_provider(),
  )
  let tracked = {
    ..parent_poll_test_ready_tracked(702),
    review_mode: @types.ReviewMode::SinglePass,
    unresolved_thread_ids: [
      @poller.ReviewThreadRef::{
        id: "T_old",
        is_outdated: true,
        author_login: "copilot-pull-request-reviewer[bot]",
      },
    ],
    unresolved_thread_ids_fetched: true,
  }
  let mut calls = 0
  let capture = async fn(_cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    calls = calls + 1
    (
      0, "{\"data\":{\"resolveReviewThread\":{\"thread\":{\"isResolved\":true}}}}",
    )
  }
  ignore(
    state.auto_resolve_outdated_review_threads_for_event(
      @poller.PollEvent::FixesPushed(702),
      tracked,
      capture,
    ),
  )
  let iterative = { ..tracked, review_mode: @types.ReviewMode::Iterative }
  ignore(
    state.auto_resolve_outdated_review_threads_for_event(
      @poller.PollEvent::PRReady(702),
      iterative,
      capture,
    ),
  )
  assert_eq(calls, 0)
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "auto_resolve_outdated_review_threads_for_pending keeps retry pending after gh failure" {
  let project_dir = "/tmp/choir-auto-resolve-retry-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  assert_true(@sys.create_dir_all(project_dir + "/.choir"))
  let state = ServerState::new(
    { ..@types.Config::default(), project_dir, },
    make_hermetic_recovery_provider(),
  )
  let tracked = {
    ..parent_poll_test_ready_tracked(703),
    review_mode: @types.ReviewMode::Iterative,
    auto_resolve_outdated_pending: true,
    unresolved_thread_ids: [
      @poller.ReviewThreadRef::{
        id: "T_old",
        is_outdated: true,
        author_login: "copilot-pull-request-reviewer[bot]",
      },
    ],
    unresolved_thread_ids_fetched: true,
  }
  let failing_capture = async fn(_cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    (1, "temporary gh failure")
  }
  let still_pending = state.auto_resolve_outdated_review_threads_for_pending(
    tracked, failing_capture,
  )
  assert_true(still_pending.auto_resolve_outdated_pending)
  assert_eq(still_pending.unresolved_thread_ids.length(), 1)
  let success_capture = async fn(_cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    (
      0, "{\"data\":{\"resolveReviewThread\":{\"thread\":{\"isResolved\":true}}}}",
    )
  }
  let cleared = state.auto_resolve_outdated_review_threads_for_pending(
    still_pending, success_capture,
  )
  assert_false(cleared.auto_resolve_outdated_pending)
  @debug.assert_eq(cleared.unresolved_thread_ids, [])
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "quiet poller tick successful auto resolve retry re-enters automerge pipeline" {
  let pr_number = 704
  let (state, _, _) = blocked_gh_automerge_fixture(
    "quiet-retry",
    pr_number,
    review_mode=@types.ReviewMode::Iterative,
  )
  match state.poller.get(pr_number) {
    Some(tracked) =>
      state.poller.restore({
        ..tracked,
        last_review_state: @poller.ReviewState::Approved,
        last_ci_rollup: @poller.CiRollupStatus::Success,
        mergeable: @poller.Mergeable::Unknown,
        merge_state_status: @poller.MergeStateStatus::Unknown,
        merged_at_unix: None,
        last_sha: "stable-sha",
        notified_parent: true,
        copilot_issue_comment_seen: true,
        auto_resolve_outdated_pending: true,
        unresolved_thread_ids: [
          @poller.ReviewThreadRef::{
            id: "PRRT_retry",
            is_outdated: true,
            author_login: "copilot-pull-request-reviewer[bot]",
          },
        ],
        unresolved_thread_ids_fetched: true,
      })
    None => fail("expected tracked PR")
  }
  let parent_target = @workspace.local_target_for(
    "test-session",
    "TL",
    @types.IsolationMode::Worktree,
  ).to_string()
  let parent_messages : Array[String] = []
  let runner = async fn(cmds : Array[@workspace.Command]) {
    @async.sleep(0)
    let statuses = []
    for cmd in cmds {
      if cmd.program == "choir" &&
        cmd.args.length() >= 4 &&
        cmd.args[0] == "zellij-action" &&
        cmd.args[1] == "send" &&
        cmd.args[2] == parent_target {
        parent_messages.push(cmd.args[3])
      }
      statuses.push(0)
    }
    statuses
  }
  let mut thread_fetches = 0
  let mut resolve_calls = 0
  let mut review_gate_calls = 0
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    let repo_view_json =
      #|{"owner":{"login":"brickfrog"},"name":"choir"}
    let unresolved_thread_json =
      #|{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"PRRT_retry","isResolved":false,"isOutdated":true,"comments":{"nodes":[{"author":{"login":"copilot-pull-request-reviewer[bot]"}}]}}]}}}}}
    let clear_threads_json =
      #|{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}
    if (
        cmd.program == "gh" &&
        cmd.args == ["repo", "view", "--json", "owner,name"]
      ) ||
      (
        cmd.program == "timeout" &&
        cmd.args == ["30s", "gh", "repo", "view", "--json", "owner,name"]
      ) {
      return (0, repo_view_json)
    }
    if cmd.args.contains("threadId=PRRT_retry") {
      resolve_calls = resolve_calls + 1
      return (
        0, "{\"data\":{\"resolveReviewThread\":{\"thread\":{\"isResolved\":true}}}}",
      )
    }
    if cmd.args.contains("graphql") {
      thread_fetches = thread_fetches + 1
      if thread_fetches == 1 {
        return (0, unresolved_thread_json)
      }
      return (0, clear_threads_json)
    }
    if cmd.program == "gh" &&
      cmd.args.length() >= 2 &&
      cmd.args[0] == "api" &&
      cmd.args[1].has_suffix("/reviews") {
      review_gate_calls = review_gate_calls + 1
      return (
        0, "[{\"state\":\"APPROVED\",\"user\":{\"login\":\"copilot-pull-request-reviewer[bot]\"},\"submitted_at\":\"2026-05-10T00:00:00Z\"}]",
      )
    }
    (0, "")
  }
  state.process_poller_tick_with_test(
    500L,
    900L,
    async fn(_pr_number, _skip_issue_comment_fetch) {
      @async.sleep(0)
      (
        true,
        @poller.ReviewState::Approved,
        "stable-sha",
        @poller.CiRollupStatus::Success,
        "",
        true,
        false,
        @poller.Mergeable::Unknown,
        @poller.MergeStateStatus::Unknown,
        None,
      )
    },
    runner~,
    capture~,
    automerge_capture=capture,
  )
  assert_eq(resolve_calls, 1)
  assert_true(thread_fetches >= 2)
  assert_true(review_gate_calls > 0)
  let parent_text = parent_messages.join("\n")
  assert_true(
    state.poller.get(pr_number) == None ||
    parent_text.contains("[THREADS RESOLVED]"),
  )
}

///|
async test "quiet poller tick refetch count drop re-enters review-thread pipeline" {
  let pr_number = 706
  let (state, _, project_dir) = blocked_gh_automerge_fixture(
    "quiet-refetch-drop",
    pr_number,
    review_mode=@types.ReviewMode::Iterative,
  )
  match state.poller.get(pr_number) {
    Some(tracked) =>
      state.poller.restore({
        ..tracked,
        last_review_state: @poller.ReviewState::Approved,
        last_ci_rollup: @poller.CiRollupStatus::Success,
        mergeable: @poller.Mergeable::Unknown,
        merge_state_status: @poller.MergeStateStatus::Unknown,
        merged_at_unix: None,
        last_sha: "stable-sha",
        notified_parent: true,
        copilot_issue_comment_seen: true,
        auto_resolve_outdated_pending: true,
        unresolved_thread_ids: [
          @poller.ReviewThreadRef::{
            id: "PRRT_prior_1",
            is_outdated: true,
            author_login: "copilot-pull-request-reviewer[bot]",
          },
          @poller.ReviewThreadRef::{
            id: "PRRT_prior_2",
            is_outdated: true,
            author_login: "copilot-pull-request-reviewer[bot]",
          },
          @poller.ReviewThreadRef::{
            id: "PRRT_prior_3",
            is_outdated: true,
            author_login: "copilot-pull-request-reviewer[bot]",
          },
        ],
        unresolved_thread_ids_fetched: true,
      })
    None => fail("expected tracked PR")
  }
  let parent_target = @workspace.local_target_for(
    "test-session",
    "TL",
    @types.IsolationMode::Worktree,
  ).to_string()
  let parent_messages : Array[String] = []
  let runner = async fn(cmds : Array[@workspace.Command]) {
    @async.sleep(0)
    let statuses = []
    for cmd in cmds {
      if cmd.program == "choir" &&
        cmd.args.length() >= 4 &&
        cmd.args[0] == "zellij-action" &&
        cmd.args[1] == "send" &&
        cmd.args[2] == parent_target {
        parent_messages.push(cmd.args[3])
      }
      statuses.push(0)
    }
    statuses
  }
  let mut thread_fetches = 0
  let mut resolve_calls = 0
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    let repo_view_json =
      #|{"owner":{"login":"brickfrog"},"name":"choir"}
    let two_threads_json =
      #|{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"PRRT_remaining_1","isResolved":false,"isOutdated":false,"comments":{"nodes":[{"author":{"login":"copilot-pull-request-reviewer[bot]"}}]}},{"id":"PRRT_remaining_2","isResolved":false,"isOutdated":true,"comments":{"nodes":[{"author":{"login":"octocat"}}]}}]}}}}}
    if (
        cmd.program == "gh" &&
        cmd.args == ["repo", "view", "--json", "owner,name"]
      ) ||
      (
        cmd.program == "timeout" &&
        cmd.args == ["30s", "gh", "repo", "view", "--json", "owner,name"]
      ) {
      return (0, repo_view_json)
    }
    if cmd.args.join(" ").contains("threadId=") {
      resolve_calls = resolve_calls + 1
      return (
        0, "{\"data\":{\"resolveReviewThread\":{\"thread\":{\"isResolved\":true}}}}",
      )
    }
    if cmd.args.contains("graphql") {
      thread_fetches = thread_fetches + 1
      return (0, two_threads_json)
    }
    (0, "")
  }
  state.process_poller_tick_with_test(
    500L,
    900L,
    async fn(_pr_number, _skip_issue_comment_fetch) {
      @async.sleep(0)
      (
        true,
        @poller.ReviewState::Approved,
        "stable-sha",
        @poller.CiRollupStatus::Success,
        "",
        true,
        false,
        @poller.Mergeable::Unknown,
        @poller.MergeStateStatus::Unknown,
        None,
      )
    },
    runner~,
    capture~,
    automerge_capture=capture,
  )
  assert_eq(resolve_calls, 0)
  assert_eq(thread_fetches, 2)
  let delivery_log = @sys.read_file(project_dir + "/.choir/delivery.log")
  assert_true(
    delivery_log.contains(
      "automerge gate recheck pr=706 event=review_threads_resolved",
    ),
  )
  let parent_text = parent_messages.join("\n")
  assert_true(parent_text.contains("[THREADS RESOLVED]"))
  assert_true(
    parent_text.contains("Unresolved inline review threads (GraphQL): 2"),
  )
  match state.poller.get(pr_number) {
    Some(tracked) => {
      assert_eq(tracked.unresolved_thread_ids.length(), 2)
      assert_false(tracked.auto_resolve_outdated_pending)
    }
    None => fail("expected PR to remain tracked")
  }
}

///|
async test "quiet poller tick never-fetched retry clear re-enters automerge pipeline" {
  let pr_number = 707
  let (state, _, _) = blocked_gh_automerge_fixture(
    "quiet-never-fetched-clear",
    pr_number,
    review_mode=@types.ReviewMode::Iterative,
  )
  match state.poller.get(pr_number) {
    Some(tracked) =>
      state.poller.restore({
        ..tracked,
        last_review_state: @poller.ReviewState::Approved,
        last_ci_rollup: @poller.CiRollupStatus::Success,
        mergeable: @poller.Mergeable::Unknown,
        merge_state_status: @poller.MergeStateStatus::Unknown,
        merged_at_unix: None,
        last_sha: "stable-sha",
        notified_parent: true,
        copilot_issue_comment_seen: true,
        auto_resolve_outdated_pending: true,
        unresolved_thread_ids: [],
        unresolved_thread_ids_fetched: false,
      })
    None => fail("expected tracked PR")
  }
  let parent_target = @workspace.local_target_for(
    "test-session",
    "TL",
    @types.IsolationMode::Worktree,
  ).to_string()
  let parent_messages : Array[String] = []
  let mut merge_seen = false
  let runner = async fn(cmds : Array[@workspace.Command]) {
    @async.sleep(0)
    let statuses = []
    for cmd in cmds {
      if cmd.program == "gh" &&
        cmd.args == ["pr", "merge", pr_number.to_string(), "--merge"] {
        merge_seen = true
      }
      if cmd.program == "choir" &&
        cmd.args.length() >= 4 &&
        cmd.args[0] == "zellij-action" &&
        cmd.args[1] == "send" &&
        cmd.args[2] == parent_target {
        parent_messages.push(cmd.args[3])
      }
      statuses.push(0)
    }
    statuses
  }
  let mut thread_fetches = 0
  let mut review_gate_calls = 0
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    let repo_view_json =
      #|{"owner":{"login":"brickfrog"},"name":"choir"}
    let clear_threads_json =
      #|{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}
    if (
        cmd.program == "gh" &&
        cmd.args == ["repo", "view", "--json", "owner,name"]
      ) ||
      (
        cmd.program == "timeout" &&
        cmd.args == ["30s", "gh", "repo", "view", "--json", "owner,name"]
      ) {
      return (0, repo_view_json)
    }
    if cmd.program == "gh" &&
      cmd.args.length() >= 2 &&
      cmd.args[0] == "api" &&
      cmd.args[1].has_suffix("/reviews") {
      review_gate_calls = review_gate_calls + 1
      return (
        0, "[{\"state\":\"APPROVED\",\"user\":{\"login\":\"copilot-pull-request-reviewer[bot]\"},\"submitted_at\":\"2026-05-10T00:00:00Z\"}]",
      )
    }
    if cmd.args.contains("graphql") {
      thread_fetches = thread_fetches + 1
      return (0, clear_threads_json)
    }
    (0, "")
  }
  state.process_poller_tick_with_test(
    500L,
    900L,
    async fn(_pr_number, _skip_issue_comment_fetch) {
      @async.sleep(0)
      (
        true,
        @poller.ReviewState::Approved,
        "stable-sha",
        @poller.CiRollupStatus::Success,
        "",
        true,
        false,
        @poller.Mergeable::Unknown,
        @poller.MergeStateStatus::Unknown,
        None,
      )
    },
    runner~,
    capture~,
    automerge_capture=capture,
  )
  assert_true(thread_fetches >= 3)
  assert_true(review_gate_calls > 0)
  assert_true(merge_seen)
  let parent_text = parent_messages.join("\n")
  assert_false(parent_text.contains("[THREADS RESOLVED]"))
  match state.poller.get(pr_number) {
    Some(tracked) => {
      assert_true(tracked.unresolved_thread_ids_fetched)
      assert_false(tracked.auto_resolve_outdated_pending)
    }
    None => ()
  }
}

///|
async test "fresh PR first thread refs fetch failure leaves merge gate unknown" {
  let pr_number = 705
  let (state, child_id, project_dir) = blocked_gh_automerge_fixture(
    "first-fetch-fails",
    pr_number,
    review_mode=@types.ReviewMode::Iterative,
  )
  let parent_target = @workspace.local_target_for(
    "test-session",
    "TL",
    @types.IsolationMode::Worktree,
  ).to_string()
  let parent_messages : Array[String] = []
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
      if cmd.program == "choir" &&
        cmd.args.length() >= 4 &&
        cmd.args[0] == "zellij-action" &&
        cmd.args[1] == "send" &&
        cmd.args[2] == parent_target {
        parent_messages.push(cmd.args[3])
      }
      statuses.push(0)
    }
    statuses
  }
  let mut graphql_calls = 0
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    if cmd.args.contains("repo") && cmd.args.contains("view") {
      return (0, "{\"owner\":{\"login\":\"brickfrog\"},\"name\":\"choir\"}")
    }
    if cmd.args.contains("graphql") {
      graphql_calls = graphql_calls + 1
      return (0, "not json")
    }
    if cmd.args.length() >= 2 &&
      cmd.args[0] == "api" &&
      cmd.args[1].has_suffix("/reviews") {
      return (
        0, "[{\"state\":\"APPROVED\",\"user\":{\"login\":\"copilot-pull-request-reviewer[bot]\"}}]",
      )
    }
    (0, "")
  }
  state.process_poller_tick_with_test(
    500L,
    900L,
    async fn(_pr_number, _skip_issue_comment_fetch) {
      @async.sleep(0)
      (
        true,
        @poller.ReviewState::Approved,
        "sha-first-fetch-fails",
        @poller.CiRollupStatus::Success,
        "",
        true,
        false,
        @poller.Mergeable::Unknown,
        @poller.MergeStateStatus::Unknown,
        None,
      )
    },
    runner~,
    capture~,
    automerge_capture=capture,
  )
  assert_eq(graphql_calls, 1)
  assert_false(merge_seen)
  let parent_text = parent_messages.join("\n")
  assert_true(parent_text.contains("[MERGE READY]"))
  let records = @evidence.load_agent_evidence_records(project_dir, child_id)
  let mut saw_threads_unobserved = false
  for record in records {
    match record.event {
      @evidence.EvidenceEvent::ThreadsUnobserved =>
        saw_threads_unobserved = true
      _ => ()
    }
  }
  assert_true(saw_threads_unobserved)
  match state.poller.get(pr_number) {
    Some(tracked) => {
      @debug.assert_eq(tracked.unresolved_thread_ids, [])
      assert_false(tracked.unresolved_thread_ids_fetched)
    }
    None => fail("expected PR to remain tracked")
  }
}

///|
fn assert_next_action_line(
  message : String,
  action : @poller.NextAction,
) -> Unit raise {
  assert_true(message.contains("next_action: " + action.to_wire_string()))
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
    last_automerge_attempt_sha: "",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Success,
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
    last_automerge_attempt_sha: "",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Success,
    mergeable: @poller.Mergeable::Unknown,
    merge_state_status: @poller.MergeStateStatus::Unknown,
    merged_at_unix: None,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: true,
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
    last_automerge_attempt_sha: "",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Success,
    mergeable: @poller.Mergeable::Unknown,
    merge_state_status: @poller.MergeStateStatus::Unknown,
    merged_at_unix: None,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: true,
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
test "parent PR-state notifications emit typed next_action" {
  let tracked = parent_poll_test_ready_tracked(73)
  let events = [
    @poller.PollEvent::PRReady(73),
    @poller.PollEvent::FixesPushed(73),
    @poller.PollEvent::CILatestHeadRollupSucceeded(73),
    @poller.PollEvent::CopilotIssueCommentSeen(73),
    @poller.PollEvent::MergeReady(73),
  ]
  for event in events {
    match
      parent_poll_event_message(
        tracked,
        "/repo",
        event,
        Some(0),
        merge_mode=@poller.MergeOperatorMode::Manual,
      ) {
      Some((message, _)) =>
        assert_next_action_line(message, @poller.NextAction::MergeNow)
      None => fail("expected parent PR-state notification")
    }
  }
  let merged = merged_pr_parent_message(
    73,
    "main.dev-ready",
    "work/ready",
    "main",
    "https://ex/pr/73",
    MergedDeliverySource::MergePrTool,
    merge_execution_mode=Some(@evidence.MergeExecutionMode::Manual),
  )
  assert_true(merged.contains("[PR MERGED]"))
  assert_next_action_line(merged, @poller.NextAction::Wait)
}

///|
test "parent PR-state notifications also emit next_action for ReviewTimeout / ReviewReceived / CIFailed / ReviewThreadsResolved" {
  let tracked = parent_poll_test_ready_tracked(75)
  let events = [
    @poller.PollEvent::ReviewTimeout(75),
    @poller.PollEvent::ReviewReceived(75, ""),
    @poller.PollEvent::ReviewReceived(75, "looks fine"),
    @poller.PollEvent::CIFailed(75),
    @poller.PollEvent::ReviewThreadsResolved(75),
  ]
  for event in events {
    match
      parent_poll_event_message(
        tracked,
        "/repo",
        event,
        Some(0),
        merge_mode=@poller.MergeOperatorMode::Manual,
      ) {
      Some((message, _)) => assert_true(message.contains("\nnext_action: "))
      None => fail("expected parent PR-state notification for event")
    }
  }
}

///|
test "parent_poll_event_message MergeReady never says auto ready when policy is blocked" {
  let tracked = parent_poll_test_ready_tracked(74)
  let modes = [
    @poller.MergeOperatorMode::Manual,
    @poller.MergeOperatorMode::Automerge,
    @poller.MergeOperatorMode::Mixed,
  ]
  for mode in modes {
    match
      parent_poll_event_message(
        tracked,
        "/repo",
        @poller.PollEvent::MergeReady(74),
        Some(2),
        merge_mode=mode,
      ) {
      Some((message, _)) => {
        assert_true(message.contains("[MERGE READY]"))
        assert_true(
          message.contains(
            "Merge policy decision: blocked (2 unresolved inline review thread(s))",
          ),
        )
        assert_next_action_line(message, @poller.NextAction::AddressThreads)
        assert_false(message.contains("AUTO-MERGE READY"))
        assert_false(message.contains("MERGE NOW:"))
      }
      None => fail("expected MergeReady message")
    }
  }
}

///|
test "parent_poll_event_message MergeReady on Mixed mode says MERGE READY (not MERGE NOW) and emits cross_check_merge_mode" {
  let tracked = parent_poll_test_ready_tracked(76)
  match
    parent_poll_event_message(
      tracked,
      "/repo",
      @poller.PollEvent::MergeReady(76),
      Some(0),
      merge_mode=@poller.MergeOperatorMode::Mixed,
    ) {
    Some((message, _)) => {
      assert_true(message.contains("[MERGE READY]"))
      // Mixed must NOT collapse to a Manual-style 'MERGE NOW: Run merge_pr.'
      assert_false(message.contains("MERGE NOW: reviewed"))
      assert_true(message.contains("MERGE READY: reviewed"))
      assert_true(message.contains("Check per-leaf merge mode"))
      assert_next_action_line(message, @poller.NextAction::CrossCheckMergeMode)
    }
    None => fail("expected MergeReady message for Mixed mode")
  }
}

///|
test "parent_poll_event_message ReviewTimeout emits EscalateReview next_action with reviewer-add detail" {
  let tracked = parent_poll_test_ready_tracked(77)
  match
    parent_poll_event_message(
      tracked,
      "/repo",
      @poller.PollEvent::ReviewTimeout(77),
      Some(0),
      merge_mode=@poller.MergeOperatorMode::Manual,
    ) {
    Some((message, _)) => {
      assert_next_action_line(message, @poller.NextAction::EscalateReview)
      assert_true(message.contains("gh pr edit --add-reviewer @copilot"))
    }
    None => fail("expected ReviewTimeout message")
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
      assert_true(message.contains("Unresolved inline review threads"))
      assert_true(message.contains("Pre-merge:"))
      assert_true(message.contains("TLDecision:"))
      assert_true(message.contains("FIXES PUSHED: Copilot does not re-review"))
      assert_false(message.contains("Waiting on review or CI"))
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
    last_automerge_attempt_sha: "",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Success,
    mergeable: @poller.Mergeable::Unknown,
    merge_state_status: @poller.MergeStateStatus::Unknown,
    merged_at_unix: None,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: false,
    orphan_notified: false,
    orphan_reconciling: false,
    changes_requested_since: 0L,
    stall_notified: false,
    fixes_pushed_at: 1L,
    review_mode: @types.ReviewMode::Iterative,
    unresolved_thread_ids: [],
    unresolved_thread_ids_fetched: false,
    auto_resolve_outdated_pending: false,
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
      assert_true(
        message.contains("Unresolved inline review threads (GraphQL): 0"),
      )
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
    last_automerge_attempt_sha: "",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Success,
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
    last_automerge_attempt_sha: "",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Success,
    mergeable: @poller.Mergeable::Unknown,
    merge_state_status: @poller.MergeStateStatus::Unknown,
    merged_at_unix: None,
    last_timeout_at: 100L,
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
  @debug.assert_eq(
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
async test "disconnect PR recovery uses inline review mode when tracking recovered PR" {
  let project_dir = "/tmp/choir-disconnect-review-mode-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.rm_rf(project_dir))
  assert_true(@sys.create_dir_all(project_dir + "/.choir/kv"))
  let parent_id = "main.tl"
  let agent_id = "main.inline-leaf"
  let pr_number = 812
  let provider = {
    ..disconnect_confirmation_provider([], []),
    find_prs_by_head: async fn(_dir, branch) {
      @async.sleep(0)
      if branch == agent_id {
        [
          @runtime.OpenPR::{
            pr_number,
            branch: agent_id,
            base: "main",
            url: "https://gh.test/812",
            created_sec: Some(1000L),
          },
        ]
      } else {
        []
      }
    },
  }
  let state = ServerState::new(
    {
      ..@types.Config::default(),
      project_dir,
      terminal_session: "test-session",
      review_mode: @types.ReviewMode::Iterative,
    },
    provider,
  )
  let inline_dir = @workspace.inline_agent_metadata_dir(project_dir, agent_id)
  assert_true(@sys.create_dir_all(inline_dir + "/.choir"))
  assert_true(
    @sys.write_file_sync(
      inline_dir + "/.choir/config.local.toml",
      "review_mode = \"single_pass\"\n",
    ),
  )
  ignore(state.register_agent(disconnect_confirmation_parent(parent_id)))
  ignore(
    state.register_agent({
      agent_id,
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Codex,
      parent: Some(parent_id),
      workspace: project_dir,
      branch: agent_id,
      terminal_target: Some(handler_auto_close_target("inline-leaf")),
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  state.schedule_disconnect(agent_id, 0L)
  let runner = async fn(cmds : Array[@workspace.Command]) {
    @async.sleep(0)
    let statuses = []
    for _ in cmds {
      statuses.push(0)
    }
    statuses
  }
  state.process_pending_disconnects_with_runner(91L, 60L, runner~)
  match state.poller.get(pr_number) {
    Some(tracked) => {
      assert_eq(tracked.agent_id, agent_id)
      assert_eq(tracked.review_mode, @types.ReviewMode::SinglePass)
    }
    None => fail("expected recovered PR to be tracked")
  }
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "fail_agent_with_runner injects failure to parent terminal" {
  let project_dir = "/tmp/choir-watchdog-test-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  assert_true(@sys.create_dir_all(project_dir + "/.choir/kv"))

  let terminal_session = "test-session"
  let config = { ..@types.Config::default(), project_dir, terminal_session }
  let state = ServerState::new(config, make_hermetic_recovery_provider())

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
    last_automerge_attempt_sha: "",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Success,
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
    last_automerge_attempt_sha: "",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Success,
    mergeable: @poller.Mergeable::Unknown,
    merge_state_status: @poller.MergeStateStatus::Unknown,
    merged_at_unix: None,
    last_timeout_at: 999L,
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
    last_automerge_attempt_sha: "",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Failure,
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
    last_automerge_attempt_sha: "",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Success,
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
  @debug.assert_eq(
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
    last_automerge_attempt_sha: "",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Success,
    mergeable: @poller.Mergeable::Unknown,
    merge_state_status: @poller.MergeStateStatus::Unknown,
    merged_at_unix: None,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: true,
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
  let events = evidence_events_for_poll_snapshot(
    tracked,
    @poller.PollEvent::CILatestHeadRollupSucceeded(64),
    Some(0),
  )
  assert_eq(events.length(), 4)
  match events[0] {
    @evidence.EvidenceEvent::ReviewObserved(state~, body~) => {
      assert_eq(state, @evidence.EvidenceReviewState::Approved)
      @debug.assert_eq(body, Some("looks good"))
    }
    _ => fail("expected review evidence")
  }
  match events[1] {
    @evidence.EvidenceEvent::CiObserved(status~, head_sha~) => {
      assert_eq(status, @evidence.EvidenceCiStatus::Success)
      @debug.assert_eq(head_sha, Some("sha64"))
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
    last_automerge_attempt_sha: "",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Success,
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
  let events = evidence_events_for_poll_snapshot(
    tracked,
    @poller.PollEvent::PRMerged(tracked),
    None,
  )
  assert_eq(events.length(), 5)
  match events[4] {
    @evidence.EvidenceEvent::MergeObserved(pr_number~, pr_url~) => {
      assert_eq(pr_number, 65)
      @debug.assert_eq(pr_url, Some("https://ex/pr/65"))
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
  assert_true(@sys.create_dir_all(project_dir + "/.choir/kv"))
  let config = {
    ..@types.Config::default(),
    project_dir,
    terminal_session: "test-session",
  }
  let state = ServerState::new(config, make_hermetic_recovery_provider())
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
    last_automerge_attempt_sha: "",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Success,
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
  assert_true(@sys.create_dir_all(project_dir + "/.choir/kv"))
  let config = {
    ..@types.Config::default(),
    project_dir,
    terminal_session: "test-session",
  }
  let state = ServerState::new(config, make_hermetic_recovery_provider())
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
    last_automerge_attempt_sha: "",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Success,
    mergeable: @poller.Mergeable::Unknown,
    merge_state_status: @poller.MergeStateStatus::Unknown,
    merged_at_unix: None,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: false,
    orphan_notified: false,
    orphan_reconciling: false,
    changes_requested_since: 1L,
    stall_notified: false,
    fixes_pushed_at: 0L,
    review_mode: @types.ReviewMode::Iterative,
    unresolved_thread_ids: [],
    unresolved_thread_ids_fetched: false,
    auto_resolve_outdated_pending: false,
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
fn handler_moontrace_field_value(
  fields : Array[@moontrace.Field],
  key : String,
) -> Json? {
  for field in fields {
    if field.key == key {
      return Some(field.value)
    }
  }
  None
}

///|
fn handler_tick_summary_event(
  events : Array[@moontrace.Event],
) -> @moontrace.Event? {
  let mut fallback : @moontrace.Event? = None
  for event in events {
    if event.level == @moontrace.Level::Info && event.message == "poller tick" {
      if fallback is None {
        fallback = Some(event)
      }
      let agent_counts_matches = match
        handler_moontrace_field_value(event.fields, "agent_counts") {
        Some(String(value)) => value.contains("active=0")
        _ => false
      }
      let tracked_prs_matches = match
        handler_moontrace_field_value(event.fields, "tracked_prs") {
        Some(Number(value, ..)) => value.to_int() == 1
        _ => false
      }
      if agent_counts_matches && tracked_prs_matches {
        return Some(event)
      }
    }
  }
  fallback
}

///|
fn handler_moontrace_event_summary(events : Array[@moontrace.Event]) -> String {
  let parts : Array[String] = []
  for event in events {
    parts.push(event.message)
  }
  parts.join("; ")
}

///|
fn handler_auto_close_test_state(label : String) -> ServerState {
  let project_dir = "/tmp/choir-handler-auto-close-" +
    label +
    "-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.create_dir_all(project_dir + "/.choir/kv"))
  let config = {
    ..@types.Config::default(),
    project_dir,
    terminal_session: "test-session",
  }
  ServerState::new(config, make_hermetic_recovery_provider())
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
/// Post-merge teardown may close a zellij tab that already self-closed; the
/// close helper exits 0 idempotently, so the runner reports success and no WARN.
async test "test_close_terminal_no_warn_idempotent_absent_zellij_tab" {
  let state = handler_auto_close_test_state("close-tab-idempotent")
  let target : @types.LocalTarget = {
    kind: @types.TargetKind::ZellijTab,
    session: "test-session",
    name: "already-closed-tab",
  }
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
fn worker_handoff_test_state(label : String, snapshot : String) -> ServerState {
  worker_handoff_test_state_with_read_log(label, snapshot, [])
}

///|
fn worker_handoff_test_state_with_read_log(
  label : String,
  snapshot : String,
  reads : Array[String],
) -> ServerState {
  let base = handler_auto_close_test_state(label)
  let host : @runtime.PaneWatchHost = {
    spawn_zellij_pane_viewport_subscribe: fn(_session, _name, _path) { 101 },
    kill_pid_best_effort: fn(_pid) {  },
    delete_file_sync: fn(_path) {  },
    read_file: fn(path) {
      reads.push(path)
      snapshot
    },
  }
  base.with_pane_watcher(@runtime.PaneWatcher::with_host(host))
}

///|
fn worker_handoff_test_state_with_snapshots(
  label : String,
  snapshots : Array[String],
) -> ServerState {
  let base = handler_auto_close_test_state(label)
  let mut read_count = 0
  let host : @runtime.PaneWatchHost = {
    spawn_zellij_pane_viewport_subscribe: fn(_session, _name, _path) { 101 },
    kill_pid_best_effort: fn(_pid) {  },
    delete_file_sync: fn(_path) {  },
    read_file: fn(_path) {
      if snapshots.length() == 0 {
        ""
      } else {
        let idx = if read_count < snapshots.length() {
          read_count
        } else {
          snapshots.length() - 1
        }
        read_count = read_count + 1
        snapshots[idx]
      }
    },
  }
  base.with_pane_watcher(@runtime.PaneWatcher::with_host(host))
}

///|
fn worker_handoff_parent(parent_id : String) -> @types.Agent {
  {
    agent_id: @types.AgentId(parent_id),
    role: @types.Role::TL,
    agent_type: @types.AgentType::Claude,
    parent: None,
    workspace: "/tmp/choir-worker-handoff-parent",
    branch: "main",
    terminal_target: Some(handler_auto_close_target("worker-parent-pane")),
    host: @types.Host::Local,
    spawn_depth: 0,
    state: @types.AgentState::Active,
  }
}

///|
fn worker_handoff_worker(
  agent_id : String,
  parent_id : String,
  state : @types.AgentState,
) -> @types.Agent {
  {
    agent_id: @types.AgentId(agent_id),
    role: @types.Role::Worker,
    agent_type: @types.AgentType::Codex,
    parent: Some(parent_id),
    workspace: "/tmp/choir-worker-handoff-worker",
    branch: "",
    terminal_target: Some(handler_auto_close_target("worker-pane")),
    host: @types.Host::Local,
    spawn_depth: 1,
    state,
  }
}

///|
fn worker_handoff_dev(
  agent_id : String,
  parent_id : String,
  state : @types.AgentState,
) -> @types.Agent {
  {
    agent_id: @types.AgentId(agent_id),
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Codex,
    parent: Some(parent_id),
    workspace: "/tmp/choir-leaf-handoff-dev",
    branch: agent_id,
    terminal_target: Some(handler_auto_close_target("leaf-pane")),
    host: @types.Host::Local,
    spawn_depth: 1,
    state,
  }
}

///|
async fn worker_handoff_capture_runner(
  sent : Array[String],
  cmds : Array[@workspace.Command],
) -> Array[Int] {
  @async.sleep(0)
  let statuses : Array[Int] = []
  for cmd in cmds {
    if cmd.program == "choir" &&
      cmd.args.length() >= 4 &&
      cmd.args[0] == "zellij-action" &&
      cmd.args[1] == "send" {
      sent.push(cmd.args[3])
    }
    statuses.push(0)
  }
  statuses
}

///|
fn worker_handoff_count_sent(sent : Array[String], needle : String) -> Int {
  let mut count = 0
  for text in sent {
    if text.contains(needle) {
      count = count + 1
    }
  }
  count
}

///|
fn handler_idle_warning_count(events : Array[@moontrace.Event]) -> Int {
  let mut count = 0
  for event in events {
    if event.level == @moontrace.Level::Warn &&
      event.message == "idle agent approaching kill threshold" {
      count = count + 1
    }
  }
  count
}

///|
async test "check_idle_agents warns once at seventy percent before idle kill" {
  let snapshot = "{\"event\":\"pane_update\",\"viewport\":[\"still working\"]}"
  let state = worker_handoff_test_state("idle-warning", snapshot)
  let parent_id = "main.parent"
  let worker_id = "main.idle-worker"
  ignore(state.register_agent(worker_handoff_parent(parent_id)))
  ignore(
    state.register_agent(
      worker_handoff_worker(worker_id, parent_id, @types.AgentState::Active),
    ),
  )
  state.watch_pane(worker_id)

  let sent : Array[String] = []
  let captured : Array[@moontrace.Event] = []
  let start = @poller.now_sec()
  handler_with_moontrace_capture(captured, async fn() {
    state.check_idle_agents(
      start,
      100L,
      async fn(cmds) { worker_handoff_capture_runner(sent, cmds) },
      worker_no_handoff_prod_sec=0L,
      worker_no_handoff_escalate_sec=0L,
    )
    state.check_idle_agents(
      start + 70L,
      100L,
      async fn(cmds) { worker_handoff_capture_runner(sent, cmds) },
      worker_no_handoff_prod_sec=0L,
      worker_no_handoff_escalate_sec=0L,
    )
    state.check_idle_agents(
      start + 80L,
      100L,
      async fn(cmds) { worker_handoff_capture_runner(sent, cmds) },
      worker_no_handoff_prod_sec=0L,
      worker_no_handoff_escalate_sec=0L,
    )
  })
  assert_eq(handler_idle_warning_count(captured), 1)
  assert_true(state.idle_agent_warned_at_70.contains(worker_id))
  ignore(@sys.rm_rf(state.config.project_dir))
}

///|
async test "check_idle_agents emits stalled parent event for merge-ready ReviewOwned dev leaf" {
  let snapshot = "{\"event\":\"pane_update\",\"viewport\":[\"fixes pushed\",\"waiting\"]}"
  let state = worker_handoff_test_state("leaf-no-handoff-stall", snapshot)
  let parent_id = "main.parent"
  let leaf_id = "main.dev-ready"
  ignore(state.register_agent(worker_handoff_parent(parent_id)))
  ignore(
    state.register_agent(
      worker_handoff_dev(leaf_id, parent_id, @types.AgentState::Active),
    ),
  )
  ignore(
    @phase.write_lifecycle(
      state.config.project_dir,
      {
        agent_id: leaf_id,
        role: @types.Role::Dev,
        process: @phase.ProcessState::Connected,
        workflow: @phase.WorkflowState::Dev(
          @phase.DevLifecycle::ReviewOwned(
            pr_number=77,
            state=@phase.ReviewOwnership::ApprovedAwaitingMerge,
          ),
        ),
        last_updated_unix_sec: 0L,
      },
      now_sec=0L,
    ),
  )
  state.poller.restore({
    ..parent_poll_test_ready_tracked(77),
    agent_id: leaf_id,
    branch: leaf_id,
    unresolved_thread_ids_fetched: true,
  })
  state.watch_pane(leaf_id)

  let sent : Array[String] = []
  let start = @poller.now_sec()
  state.check_idle_agents(
    start,
    180L,
    async fn(cmds) { worker_handoff_capture_runner(sent, cmds) },
    worker_no_handoff_prod_sec=120L,
    worker_no_handoff_escalate_sec=120L,
  )
  state.check_idle_agents(
    start + 120L,
    180L,
    async fn(cmds) { worker_handoff_capture_runner(sent, cmds) },
    worker_no_handoff_prod_sec=120L,
    worker_no_handoff_escalate_sec=120L,
  )
  state.check_idle_agents(
    start + 121L,
    180L,
    async fn(cmds) { worker_handoff_capture_runner(sent, cmds) },
    worker_no_handoff_prod_sec=120L,
    worker_no_handoff_escalate_sec=120L,
  )
  assert_eq(
    worker_handoff_count_sent(sent, "[LEAF STALLED AFTER FIX-PUSH] dev-ready"),
    0,
  )
  state.check_idle_agents(
    start + 240L,
    180L,
    async fn(cmds) { worker_handoff_capture_runner(sent, cmds) },
    worker_no_handoff_prod_sec=120L,
    worker_no_handoff_escalate_sec=120L,
  )
  assert_eq(
    worker_handoff_count_sent(sent, "[LEAF POST-FIX-PUSH HANDOFF] dev-ready"),
    1,
  )
  assert_eq(
    worker_handoff_count_sent(sent, "[LEAF STALLED AFTER FIX-PUSH] dev-ready"),
    1,
  )
  assert_eq(worker_handoff_count_sent(sent, "[WATCHDOG] agent"), 0)
}

///|
async test "check_idle_agents does not stall prodded leaf after fresh pane output" {
  let idle_snapshot = "{\"event\":\"pane_update\",\"viewport\":[\"fixes pushed\",\"waiting\"]}"
  let active_snapshot = "{\"event\":\"pane_update\",\"viewport\":[\"fixes pushed\",\"working after prod\"]}"
  let state = worker_handoff_test_state_with_snapshots(
    "leaf-no-handoff-active-after-prod",
    [idle_snapshot, idle_snapshot, active_snapshot, active_snapshot],
  )
  let parent_id = "main.parent"
  let leaf_id = "main.dev-active"
  ignore(state.register_agent(worker_handoff_parent(parent_id)))
  ignore(
    state.register_agent(
      worker_handoff_dev(leaf_id, parent_id, @types.AgentState::Active),
    ),
  )
  ignore(
    @phase.write_lifecycle(
      state.config.project_dir,
      {
        agent_id: leaf_id,
        role: @types.Role::Dev,
        process: @phase.ProcessState::Connected,
        workflow: @phase.WorkflowState::Dev(
          @phase.DevLifecycle::ReviewOwned(
            pr_number=78,
            state=@phase.ReviewOwnership::ApprovedAwaitingMerge,
          ),
        ),
        last_updated_unix_sec: 0L,
      },
      now_sec=0L,
    ),
  )
  state.poller.restore({
    ..parent_poll_test_ready_tracked(78),
    agent_id: leaf_id,
    branch: leaf_id,
    unresolved_thread_ids_fetched: true,
  })
  state.watch_pane(leaf_id)

  let sent : Array[String] = []
  let start = @poller.now_sec()
  state.check_idle_agents(
    start,
    999L,
    async fn(cmds) { worker_handoff_capture_runner(sent, cmds) },
    worker_no_handoff_prod_sec=120L,
    worker_no_handoff_escalate_sec=120L,
  )
  state.check_idle_agents(
    start + 120L,
    999L,
    async fn(cmds) { worker_handoff_capture_runner(sent, cmds) },
    worker_no_handoff_prod_sec=120L,
    worker_no_handoff_escalate_sec=120L,
  )
  state.check_idle_agents(
    start + 230L,
    999L,
    async fn(cmds) { worker_handoff_capture_runner(sent, cmds) },
    worker_no_handoff_prod_sec=120L,
    worker_no_handoff_escalate_sec=120L,
  )
  state.check_idle_agents(
    start + 241L,
    999L,
    async fn(cmds) { worker_handoff_capture_runner(sent, cmds) },
    worker_no_handoff_prod_sec=120L,
    worker_no_handoff_escalate_sec=120L,
  )
  assert_eq(
    worker_handoff_count_sent(sent, "[LEAF POST-FIX-PUSH HANDOFF] dev-active"),
    1,
  )
  assert_eq(
    worker_handoff_count_sent(sent, "[LEAF STALLED AFTER FIX-PUSH] dev-active"),
    0,
  )
}

///|
async test "check_idle_agents does not prod non-ReviewOwned dev leaf" {
  let snapshot = "{\"event\":\"pane_update\",\"viewport\":[\"still implementing\"]}"
  let state = worker_handoff_test_state("leaf-no-handoff-working", snapshot)
  let parent_id = "main.parent"
  let leaf_id = "main.dev-working"
  ignore(state.register_agent(worker_handoff_parent(parent_id)))
  ignore(
    state.register_agent(
      worker_handoff_dev(leaf_id, parent_id, @types.AgentState::Active),
    ),
  )
  state.poller.restore({
    ..parent_poll_test_ready_tracked(88),
    agent_id: leaf_id,
    branch: leaf_id,
    unresolved_thread_ids_fetched: true,
  })
  state.watch_pane(leaf_id)

  let sent : Array[String] = []
  let start = @poller.now_sec()
  state.check_idle_agents(
    start,
    999L,
    async fn(cmds) { worker_handoff_capture_runner(sent, cmds) },
    worker_no_handoff_prod_sec=120L,
    worker_no_handoff_escalate_sec=120L,
  )
  state.check_idle_agents(
    start + 240L,
    999L,
    async fn(cmds) { worker_handoff_capture_runner(sent, cmds) },
    worker_no_handoff_prod_sec=120L,
    worker_no_handoff_escalate_sec=120L,
  )
  assert_eq(worker_handoff_count_sent(sent, "[LEAF POST-FIX-PUSH HANDOFF]"), 0)
  assert_eq(worker_handoff_count_sent(sent, "[LEAF STALLED AFTER FIX-PUSH]"), 0)
}

///|
async test "check_idle_agents prods worker then emits one stalled no-handoff event" {
  let snapshot = "{\"event\":\"pane_update\",\"viewport\":[\"audit complete\",\"Finding 1\"]}"
  let state = worker_handoff_test_state("worker-no-handoff-stall", snapshot)
  let parent_id = "main.parent"
  let worker_id = "main.sarcasmotron"
  ignore(state.register_agent(worker_handoff_parent(parent_id)))
  ignore(
    state.register_agent(
      worker_handoff_worker(worker_id, parent_id, @types.AgentState::Active),
    ),
  )
  state.watch_pane(worker_id)

  let sent : Array[String] = []
  let start = @poller.now_sec()
  state.check_idle_agents(
    start,
    300L,
    async fn(cmds) { worker_handoff_capture_runner(sent, cmds) },
    worker_no_handoff_prod_sec=120L,
    worker_no_handoff_escalate_sec=120L,
  )
  state.check_idle_agents(
    start + 121L,
    300L,
    async fn(cmds) { worker_handoff_capture_runner(sent, cmds) },
    worker_no_handoff_prod_sec=120L,
    worker_no_handoff_escalate_sec=120L,
  )
  assert_eq(
    worker_handoff_count_sent(sent, "printed output is not the handoff"),
    1,
  )
  assert_true(state.worker_no_handoff_prodded_at.contains(worker_id))

  state.check_idle_agents(
    start + 242L,
    300L,
    async fn(cmds) { worker_handoff_capture_runner(sent, cmds) },
    worker_no_handoff_prod_sec=120L,
    worker_no_handoff_escalate_sec=120L,
  )
  state.check_idle_agents(
    start + 250L,
    300L,
    async fn(cmds) { worker_handoff_capture_runner(sent, cmds) },
    worker_no_handoff_prod_sec=120L,
    worker_no_handoff_escalate_sec=120L,
  )
  assert_eq(
    worker_handoff_count_sent(
      sent, "[WORKER STALLED — no handoff] sarcasmotron",
    ),
    1,
  )
}

///|
async test "check_idle_agents reuses one pane snapshot for handoff and watchdog checks" {
  let snapshot = "{\"event\":\"pane_update\",\"viewport\":[\"done\",\"tail\"]}"
  let reads : Array[String] = []
  let state = worker_handoff_test_state_with_read_log(
    "worker-handoff-single-read", snapshot, reads,
  )
  let parent_id = "main.parent"
  let worker_id = "main.single-read"
  ignore(state.register_agent(worker_handoff_parent(parent_id)))
  ignore(
    state.register_agent(
      worker_handoff_worker(worker_id, parent_id, @types.AgentState::Active),
    ),
  )
  state.watch_pane(worker_id)

  let sent : Array[String] = []
  let start = @poller.now_sec()
  state.check_idle_agents(
    start,
    300L,
    async fn(cmds) { worker_handoff_capture_runner(sent, cmds) },
    worker_no_handoff_prod_sec=120L,
    worker_no_handoff_escalate_sec=120L,
  )
  state.check_idle_agents(
    start + 301L,
    300L,
    async fn(cmds) { worker_handoff_capture_runner(sent, cmds) },
    worker_no_handoff_prod_sec=120L,
    worker_no_handoff_escalate_sec=120L,
  )

  @debug.assert_eq(reads, [
    @runtime.pane_snapshot_path(worker_id),
    @runtime.pane_snapshot_path(worker_id),
  ])
}

///|
async test "notify_parent marks handoff delivered and suppresses worker prod" {
  let snapshot = "{\"event\":\"pane_update\",\"viewport\":[\"finished report\",\"tail\"]}"
  let state = worker_handoff_test_state("worker-handoff-delivered", snapshot)
  let parent_id = "main.parent"
  let worker_id = "main.reviewer"
  ignore(state.register_agent(worker_handoff_parent(parent_id)))
  ignore(
    state.register_agent(
      worker_handoff_worker(worker_id, parent_id, @types.AgentState::Active),
    ),
  )
  state.watch_pane(worker_id)

  let sent : Array[String] = []
  let req : @types.Request = {
    req_method: "tools/call",
    role: @types.Role::Worker,
    name: "notify_parent",
    args: @types.RequestArgs::new({
      "caller_id": worker_id,
      "message": "review complete",
      "status": "success",
    }),
  }
  let resp = state.handle_with_runner(req, runner=async fn(cmds) {
    worker_handoff_capture_runner(sent, cmds)
  })
  assert_true(resp.is_ok())
  assert_true(state.handoff_delivered.contains(worker_id))

  let start = @poller.now_sec()
  state.check_idle_agents(
    start,
    300L,
    async fn(cmds) { worker_handoff_capture_runner(sent, cmds) },
    worker_no_handoff_prod_sec=120L,
    worker_no_handoff_escalate_sec=120L,
  )
  state.check_idle_agents(
    start + 121L,
    300L,
    async fn(cmds) { worker_handoff_capture_runner(sent, cmds) },
    worker_no_handoff_prod_sec=120L,
    worker_no_handoff_escalate_sec=120L,
  )
  assert_eq(
    worker_handoff_count_sent(sent, "printed output is not the handoff"),
    0,
  )
}

///|
async test "watchdog kill emits worker exited without notify only before handoff" {
  let snapshot = "{\"event\":\"pane_update\",\"viewport\":[\"full report\",\"last line\"]}"
  let parent_id = "main.parent"
  let worker_id = "main.worker-a"
  let state = worker_handoff_test_state("worker-exit-no-notify", snapshot)
  ignore(state.register_agent(worker_handoff_parent(parent_id)))
  ignore(
    state.register_agent(
      worker_handoff_worker(worker_id, parent_id, @types.AgentState::Active),
    ),
  )
  state.watch_pane(worker_id)

  let sent : Array[String] = []
  let start = @poller.now_sec()
  state.check_idle_agents(
    start,
    300L,
    async fn(cmds) { worker_handoff_capture_runner(sent, cmds) },
    worker_no_handoff_prod_sec=0L,
    worker_no_handoff_escalate_sec=0L,
  )
  state.check_idle_agents(
    start + 301L,
    300L,
    async fn(cmds) { worker_handoff_capture_runner(sent, cmds) },
    worker_no_handoff_prod_sec=0L,
    worker_no_handoff_escalate_sec=0L,
  )
  assert_eq(
    worker_handoff_count_sent(sent, "[WORKER EXITED WITHOUT NOTIFY] worker-a"),
    1,
  )

  let delivered_worker_id = "main.worker-b"
  let delivered = worker_handoff_test_state("worker-exit-delivered", snapshot)
  ignore(delivered.register_agent(worker_handoff_parent(parent_id)))
  ignore(
    delivered.register_agent(
      worker_handoff_worker(
        delivered_worker_id,
        parent_id,
        @types.AgentState::Active,
      ),
    ),
  )
  delivered.mark_handoff_delivered(delivered_worker_id)
  delivered.watch_pane(delivered_worker_id)
  let delivered_sent : Array[String] = []
  let delivered_start = @poller.now_sec()
  delivered.check_idle_agents(
    delivered_start,
    300L,
    async fn(cmds) { worker_handoff_capture_runner(delivered_sent, cmds) },
    worker_no_handoff_prod_sec=0L,
    worker_no_handoff_escalate_sec=0L,
  )
  delivered.check_idle_agents(
    delivered_start + 301L,
    300L,
    async fn(cmds) { worker_handoff_capture_runner(delivered_sent, cmds) },
    worker_no_handoff_prod_sec=0L,
    worker_no_handoff_escalate_sec=0L,
  )
  assert_eq(
    worker_handoff_count_sent(delivered_sent, "[WORKER EXITED WITHOUT NOTIFY]"),
    0,
  )
}

///|
async test "disconnect completing worker emits exited without notify once" {
  let snapshot = "{\"event\":\"pane_update\",\"viewport\":[\"worker report\",\"tail\"]}"
  let state = worker_handoff_test_state("worker-disconnect-no-notify", snapshot)
  let parent_id = "main.parent"
  let worker_id = "main.worker-disconnect"
  ignore(state.register_agent(worker_handoff_parent(parent_id)))
  ignore(
    state.register_agent(
      worker_handoff_worker(worker_id, parent_id, @types.AgentState::Completing),
    ),
  )

  let sent : Array[String] = []
  state.handle_disconnect_with_runner(worker_id, runner=async fn(cmds) {
    worker_handoff_capture_runner(sent, cmds)
  })
  state.handle_disconnect_with_runner(worker_id, runner=async fn(cmds) {
    worker_handoff_capture_runner(sent, cmds)
  })
  assert_eq(
    worker_handoff_count_sent(
      sent, "[WORKER EXITED WITHOUT NOTIFY] worker-disconnect",
    ),
    1,
  )

  let delivered = worker_handoff_test_state(
    "worker-disconnect-delivered", snapshot,
  )
  let delivered_worker_id = "main.worker-disconnect-delivered"
  ignore(delivered.register_agent(worker_handoff_parent(parent_id)))
  ignore(
    delivered.register_agent(
      worker_handoff_worker(
        delivered_worker_id,
        parent_id,
        @types.AgentState::Completing,
      ),
    ),
  )
  delivered.mark_handoff_delivered(delivered_worker_id)
  let delivered_sent : Array[String] = []
  delivered.handle_disconnect_with_runner(delivered_worker_id, runner=async fn(
    cmds,
  ) {
    worker_handoff_capture_runner(delivered_sent, cmds)
  })
  assert_eq(
    worker_handoff_count_sent(delivered_sent, "[WORKER EXITED WITHOUT NOTIFY]"),
    0,
  )
}

///|
fn handler_supervisor_agent(
  agent_id : String,
  role : @types.Role,
  state : @types.AgentState,
  target : @types.LocalTarget?,
  workspace : String,
) -> @types.Agent {
  {
    agent_id: @types.AgentId(agent_id),
    role,
    agent_type: @types.AgentType::Claude,
    parent: None,
    workspace,
    branch: "main",
    terminal_target: target,
    host: @types.Host::Local,
    spawn_depth: 0,
    state,
  }
}

///|
async test "test_disconnect_supervisor_agent_no_fail_or_close" {
  let state = handler_auto_close_test_state("disconnect-supervisor")
  for role in [@types.Role::Root, @types.Role::TL] {
    let agent_id = match role {
      @types.Role::Root => "root"
      @types.Role::TL => "main.tl"
      _ => "main.supervisor"
    }
    let target = handler_auto_close_target(agent_id)
    ignore(
      state.register_agent(
        handler_supervisor_agent(
          agent_id,
          role,
          @types.AgentState::Active,
          Some(target),
          state.config.project_dir,
        ),
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
    @debug.assert_eq(calls, [])
    let agent = state.registry.get(agent_id) catch {
      _ => fail("expected supervisor agent")
    }
    assert_eq(agent.state, @types.AgentState::Active)
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

///|
fn disconnect_confirmation_provider(
  live_tabs : Array[String],
  live_panes : Array[String],
) -> @runtime.RecoveryProvider {
  {
    ..make_hermetic_recovery_provider(),
    zellij_live: async fn(_, _) {
      @async.sleep(0)
      { tabs: live_tabs, panes: live_panes }
    },
    find_prs_by_head: async fn(_, _) {
      @async.sleep(0)
      []
    },
  }
}

///|
fn disconnect_confirmation_parent(parent_id : String) -> @types.Agent {
  {
    agent_id: @types.AgentId(parent_id),
    role: @types.Role::TL,
    agent_type: @types.AgentType::Claude,
    parent: None,
    workspace: "/tmp/choir-disconnect-confirm-parent",
    branch: "main",
    terminal_target: Some(handler_auto_close_target("parent-pane")),
    host: @types.Host::Local,
    spawn_depth: 0,
    state: @types.AgentState::Active,
  }
}

///|
test "pr_merged_predates_seen_cache grandfathers older merges" {
  // 2026-05-17 18:00:00 UTC == 1779056400
  assert_true(pr_merged_predates_seen_cache(1779056400L, 1779058800L))
  assert_false(pr_merged_predates_seen_cache(1779058800L, 1779056400L))
  // Equal timestamps: NOT grandfathered (the merge is at the moment of enable).
  assert_false(pr_merged_predates_seen_cache(1779058800L, 1779058800L))
  // Parse-failed merge time (0) fails closed -> grandfathered.
  assert_true(pr_merged_predates_seen_cache(0L, 1L))
  assert_true(pr_merged_predates_seen_cache(0L, 0L))
}

///|
