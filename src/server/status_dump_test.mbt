///|
fn status_dump_test_agent(
  id : String,
  role : @types.Role,
  parent : String?,
  target : String?,
) -> @types.Agent {
  {
    agent_id: id,
    role,
    agent_type: @types.AgentType::Codex,
    parent,
    workspace: "/tmp/status-dump/" + id,
    branch: id,
    terminal_target: match target {
      Some(raw) => @types.LocalTarget::parse(raw)
      None => None
    },
    host: @types.Host::Local,
    state: @types.AgentState::Active,
    spawn_depth: 0,
  }
}

///|
fn status_dump_test_lifecycle(
  agent_id : String,
  role : @types.Role,
  workflow : @phase.WorkflowState,
  last_updated_unix_sec : Int64,
) -> @phase.AgentLifecycle {
  {
    agent_id,
    role,
    process: @phase.ProcessState::Connected,
    workflow,
    last_updated_unix_sec,
  }
}

///|
fn status_dump_test_project_dir(label : String) -> String {
  "/tmp/choir-status-dump-" +
  label +
  "-" +
  @sys.get_pid().to_string() +
  "-" +
  @env.now().reinterpret_as_int64().to_string()
}

///|
test "server status snapshot write uses injected lifecycle reader and lifecycle PR" {
  let project_dir = status_dump_test_project_dir("write")
  ignore(@sys.rm_rf(project_dir))
  let state = ServerState::new(
    { ..@types.Config::default(), project_dir, terminal_session: "status" },
    make_hermetic_recovery_provider(),
  )
  ignore(
    state.registry.upsert(
      status_dump_test_agent(
        "root",
        @types.Role::Root,
        None,
        Some("zellij-pane:s:root"),
      ),
    ),
  )
  ignore(
    state.registry.upsert(
      status_dump_test_agent(
        "root.leaf",
        @types.Role::Dev,
        Some("root"),
        Some("zellij-pane:s:leaf"),
      ),
    ),
  )
  state.poller.track(
    41, "root.leaf", "root.leaf", "main", "https://example.test/pull/41", 1L,
  )
  state.poller.track(
    42, "root.leaf", "root.leaf", "main", "https://example.test/pull/42", 1L,
  )
  state.poller.track(
    43, "root.leaf", "root.leaf", "main", "https://example.test/pull/43", 1L,
  )
  match state.poller.get(42) {
    Some(tracked) =>
      state.poller.restore({
        ..tracked,
        last_ci_rollup: @poller.CiRollupStatus::Success,
        unresolved_thread_ids_fetched: false,
      })
    None => fail("expected lifecycle PR to be tracked")
  }
  match state.poller.get(43) {
    Some(tracked) =>
      state.poller.restore({
        ..tracked,
        last_ci_rollup: @poller.CiRollupStatus::Failure,
        unresolved_thread_ids: [
          @poller.ReviewThreadRef::{
            id: "thread-43",
            is_outdated: false,
            author_login: "reviewer",
          },
        ],
        unresolved_thread_ids_fetched: true,
      })
    None => fail("expected competing tracked PR to be tracked")
  }
  let lifecycles : Map[String, @phase.AgentLifecycle] = {}
  lifecycles.set(
    "root",
    status_dump_test_lifecycle(
      "root",
      @types.Role::Root,
      @phase.WorkflowState::Supervisor(
        @phase.SupervisorLifecycle::Supervising(children=[], wave=1),
      ),
      0L,
    ),
  )
  lifecycles.set(
    "root.leaf",
    status_dump_test_lifecycle(
      "root.leaf",
      @types.Role::Dev,
      @phase.WorkflowState::Dev(
        @phase.DevLifecycle::ReviewOwned(
          pr_number=42,
          state=@phase.ReviewOwnership::OpenUnreviewed(
            url="https://example.test/pull/42",
          ),
        ),
      ),
      90L,
    ),
  )
  let ok = state.write_server_status_snapshot(100L, fn(agent_id) {
    lifecycles.get(agent_id)
  })
  assert_true(ok)
  let text = @sys.read_file(server_status_path(project_dir))
  assert_true(text.contains("choir server status\n"))
  assert_true(text.contains("taken_at_unix_sec=100\n"))
  assert_true(text.contains("agents=2\n"))
  assert_true(
    text.contains(
      "agent_id=root role=root agent_type=codex lifecycle=working terminal_target=zellij-pane:s:root parent_agent_id=none last_activity_unix=0 last_request_age_sec=unknown pr_number=none unresolved_threads=none ci_rollup=unknown attention_needed=false\n",
    ),
  )
  assert_true(
    text.contains(
      "agent_id=root.leaf role=dev agent_type=codex lifecycle=review_owned terminal_target=zellij-pane:s:leaf parent_agent_id=root last_activity_unix=90 last_request_age_sec=10 pr_number=42 unresolved_threads=unknown ci_rollup=success attention_needed=false\n",
    ),
  )
  let rows = server_status_snapshot_rows(
    state.registry,
    state.poller,
    fn(agent_id) { lifecycles.get(agent_id) },
    100L,
  )
  @debug.assert_eq(
    rows[1].unresolved_threads,
    @tools.StatusBarThreadCount::Unknown,
  )
  @debug.assert_eq(rows[1].attention_needed, @tools.PaneAttention::Clear)
  ignore(@sys.rm_rf(project_dir))
}

///|
test "server status snapshot keeps thread-independent failed attention explicit" {
  let registry = @registry.AgentRegistry::new()
  ignore(
    registry.upsert(
      status_dump_test_agent(
        "root.leaf",
        @types.Role::Dev,
        Some("root"),
        Some("zellij-pane:s:leaf"),
      ),
    ),
  )
  let poller = @poller.PollerState::new()
  poller.track(
    55, "root.leaf", "root.leaf", "main", "https://example.test/pull/55", 1L,
  )
  let lifecycle = status_dump_test_lifecycle(
    "root.leaf",
    @types.Role::Dev,
    @phase.WorkflowState::Dev(
      @phase.DevLifecycle::Failed(
        reason=@phase.FailureReason::UnexpectedDisconnect,
      ),
    ),
    90L,
  )
  let rows = server_status_snapshot_rows(
    registry,
    poller,
    fn(agent_id) {
      if agent_id == "root.leaf" {
        Some(lifecycle)
      } else {
        None
      }
    },
    100L,
  )
  @debug.assert_eq(rows.length(), 1)
  @debug.assert_eq(rows[0].pr_number, Some(55))
  @debug.assert_eq(
    rows[0].unresolved_threads,
    @tools.StatusBarThreadCount::Unknown,
  )
  @debug.assert_eq(rows[0].attention_needed, @tools.PaneAttention::Needed)
  let text = format_server_status_snapshot(rows, 100L)
  assert_true(
    text.contains(
      "agent_id=root.leaf role=dev agent_type=codex lifecycle=failed terminal_target=zellij-pane:s:leaf parent_agent_id=root last_activity_unix=90 last_request_age_sec=10 pr_number=55 unresolved_threads=unknown ci_rollup=unknown attention_needed=true\n",
    ),
  )
}

///|
test "server status row keeps fixed domains typed until formatting" {
  let row = ServerStatusSnapshotRow::{
    agent_id: "root.leaf",
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Codex,
    lifecycle: @phase.WorkflowState::Dev(@phase.DevLifecycle::Working),
    terminal_target: "zellij-pane:s:leaf",
    parent_agent_id: Some("root"),
    last_activity_unix: 90L,
    last_request_age_sec: Some(10L),
    pr_number: Some(58),
    unresolved_threads: @tools.StatusBarThreadCount::Count(1),
    ci_rollup: Some(@poller.CiRollupStatus::NoChecks),
    attention_needed: @tools.PaneAttention::Clear,
  }
  @debug.assert_eq(row.role, @types.Role::Dev)
  @debug.assert_eq(row.agent_type, @types.AgentType::Codex)
  @debug.assert_eq(
    row.lifecycle,
    @phase.WorkflowState::Dev(@phase.DevLifecycle::Working),
  )
  @debug.assert_eq(row.ci_rollup, Some(@poller.CiRollupStatus::NoChecks))
  let text = format_server_status_snapshot([row], 100L)
  assert_true(
    text.contains(
      "agent_id=root.leaf role=dev agent_type=codex lifecycle=working terminal_target=zellij-pane:s:leaf parent_agent_id=root last_activity_unix=90 last_request_age_sec=10 pr_number=58 unresolved_threads=1 ci_rollup=no_checks attention_needed=false\n",
    ),
  )
}

///|
test "server status snapshot normalizes blank parent like status bar panes" {
  let registry = @registry.AgentRegistry::new()
  ignore(
    registry.upsert(
      status_dump_test_agent(
        "root.leaf",
        @types.Role::Dev,
        Some(""),
        Some("zellij-pane:s:leaf"),
      ),
    ),
  )
  let lifecycle = status_dump_test_lifecycle(
    "root.leaf",
    @types.Role::Dev,
    @phase.WorkflowState::Dev(@phase.DevLifecycle::Working),
    90L,
  )
  let rows = server_status_snapshot_rows(
    registry,
    @poller.PollerState::new(),
    fn(agent_id) {
      if agent_id == "root.leaf" {
        Some(lifecycle)
      } else {
        None
      }
    },
    100L,
  )
  @debug.assert_eq(rows.length(), 1)
  @debug.assert_eq(rows[0].parent_agent_id, None)
  let text = format_server_status_snapshot(rows, 100L)
  assert_true(
    text.contains(
      "agent_id=root.leaf role=dev agent_type=codex lifecycle=working terminal_target=zellij-pane:s:leaf parent_agent_id=none last_activity_unix=90 last_request_age_sec=10 pr_number=none unresolved_threads=none ci_rollup=unknown attention_needed=false\n",
    ),
  )
}

///|
test "server status snapshot reports unknown attention when changes-requested threads are unfetched" {
  let registry = @registry.AgentRegistry::new()
  ignore(
    registry.upsert(
      status_dump_test_agent(
        "root.leaf",
        @types.Role::Dev,
        Some("root"),
        Some("zellij-pane:s:leaf"),
      ),
    ),
  )
  let poller = @poller.PollerState::new()
  poller.track(
    56, "root.leaf", "root.leaf", "main", "https://example.test/pull/56", 1L,
  )
  match poller.get(56) {
    Some(tracked) =>
      poller.restore({
        ..tracked,
        fixes_pushed_at: 95L,
        unresolved_thread_ids_fetched: false,
      })
    None => fail("expected tracked PR")
  }
  let lifecycle = status_dump_test_lifecycle(
    "root.leaf",
    @types.Role::Dev,
    @phase.WorkflowState::Dev(
      @phase.DevLifecycle::ChangesRequested(pr_number=56, next_round=2),
    ),
    90L,
  )
  let rows = server_status_snapshot_rows(
    registry,
    poller,
    fn(agent_id) {
      if agent_id == "root.leaf" {
        Some(lifecycle)
      } else {
        None
      }
    },
    100L,
  )
  @debug.assert_eq(rows.length(), 1)
  @debug.assert_eq(rows[0].pr_number, Some(56))
  @debug.assert_eq(
    rows[0].unresolved_threads,
    @tools.StatusBarThreadCount::Unknown,
  )
  @debug.assert_eq(rows[0].attention_needed, @tools.PaneAttention::Unknown)
  let text = format_server_status_snapshot(rows, 100L)
  assert_true(
    text.contains(
      "agent_id=root.leaf role=dev agent_type=codex lifecycle=changes_requested terminal_target=zellij-pane:s:leaf parent_agent_id=root last_activity_unix=90 last_request_age_sec=10 pr_number=56 unresolved_threads=unknown ci_rollup=unknown attention_needed=unknown\n",
    ),
  )
}

///|
test "server status snapshot clears changes-requested attention before fixes are pushed" {
  let registry = @registry.AgentRegistry::new()
  ignore(
    registry.upsert(
      status_dump_test_agent(
        "root.leaf",
        @types.Role::Dev,
        Some("root"),
        Some("zellij-pane:s:leaf"),
      ),
    ),
  )
  let poller = @poller.PollerState::new()
  poller.track(
    57, "root.leaf", "root.leaf", "main", "https://example.test/pull/57", 1L,
  )
  let lifecycle = status_dump_test_lifecycle(
    "root.leaf",
    @types.Role::Dev,
    @phase.WorkflowState::Dev(
      @phase.DevLifecycle::ChangesRequested(pr_number=57, next_round=2),
    ),
    90L,
  )
  let rows = server_status_snapshot_rows(
    registry,
    poller,
    fn(agent_id) {
      if agent_id == "root.leaf" {
        Some(lifecycle)
      } else {
        None
      }
    },
    100L,
  )
  @debug.assert_eq(rows.length(), 1)
  @debug.assert_eq(
    rows[0].unresolved_threads,
    @tools.StatusBarThreadCount::Unknown,
  )
  @debug.assert_eq(rows[0].attention_needed, @tools.PaneAttention::Clear)
  let text = format_server_status_snapshot(rows, 100L)
  assert_true(
    text.contains(
      "agent_id=root.leaf role=dev agent_type=codex lifecycle=changes_requested terminal_target=zellij-pane:s:leaf parent_agent_id=root last_activity_unix=90 last_request_age_sec=10 pr_number=57 unresolved_threads=unknown ci_rollup=unknown attention_needed=false\n",
    ),
  )
}

///|
test "server status snapshot treats non-positive lifecycle PR as absent" {
  let registry = @registry.AgentRegistry::new()
  ignore(
    registry.upsert(
      status_dump_test_agent(
        "root.leaf",
        @types.Role::Dev,
        Some("root"),
        Some("zellij-pane:s:leaf"),
      ),
    ),
  )
  let lifecycle = status_dump_test_lifecycle(
    "root.leaf",
    @types.Role::Dev,
    @phase.WorkflowState::Dev(
      @phase.DevLifecycle::ReviewOwned(
        pr_number=0,
        state=@phase.ReviewOwnership::OpenUnreviewed(
          url="https://example.test/pull/0",
        ),
      ),
    ),
    90L,
  )
  let rows = server_status_snapshot_rows(
    registry,
    @poller.PollerState::new(),
    fn(agent_id) {
      if agent_id == "root.leaf" {
        Some(lifecycle)
      } else {
        None
      }
    },
    100L,
  )
  @debug.assert_eq(rows.length(), 1)
  @debug.assert_eq(rows[0].pr_number, None)
  @debug.assert_eq(
    rows[0].unresolved_threads,
    @tools.StatusBarThreadCount::NoPR,
  )
  @debug.assert_eq(rows[0].attention_needed, @tools.PaneAttention::Clear)
  let text = format_server_status_snapshot(rows, 100L)
  assert_true(
    text.contains(
      "agent_id=root.leaf role=dev agent_type=codex lifecycle=review_owned terminal_target=zellij-pane:s:leaf parent_agent_id=root last_activity_unix=90 last_request_age_sec=10 pr_number=none unresolved_threads=none ci_rollup=unknown attention_needed=false\n",
    ),
  )
}
