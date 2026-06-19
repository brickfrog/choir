///|
fn status_bar_test_pane_target(name : String) -> @types.LocalTarget {
  { kind: @types.TargetKind::ZellijPane, session: "status-test", name }
}

///|
fn status_bar_test_tab_target(name : String) -> @types.LocalTarget {
  { kind: @types.TargetKind::ZellijTab, session: "status-test", name }
}

///|
fn[T] status_bar_test_capture(
  body : () -> T raise @types.ChoirError,
) -> Result[T, @types.ChoirError] {
  try body() catch {
    e => Err(e)
  } noraise {
    value => Ok(value)
  }
}

///|
fn status_bar_test_ignore(body : () -> Unit raise @types.ChoirError) -> Unit {
  try body() catch {
    _ => ()
  } noraise {
    _ => ()
  }
}

///|
fn status_bar_test_list_panes_snapshot() -> ZellijListPanesSnapshot {
  {
    entries: [
      { pane_id: 2, tab_name: "TL", pane_name: "root-tl" },
      { pane_id: 7, tab_name: "feature-leaf", pane_name: "leaf-inline" },
      { pane_id: 9, tab_name: "feature-leaf", pane_name: "secondary-pane" },
    ],
  }
}

///|
test "status_bar_state list-panes cache lookup handles fresh stale and missing" {
  let cache : Map[String, CachedListPanesSnapshot] = {}
  let snapshot = status_bar_test_list_panes_snapshot()
  cache.set("status-test", { snapshot, expires_at_unix_ms: 1000L })
  @debug.assert_eq(
    list_panes_cache_lookup(cache, "status-test", 999L),
    Some(snapshot),
  )
  @debug.assert_eq(list_panes_cache_lookup(cache, "status-test", 1000L), None)
  @debug.assert_eq(
    list_panes_cache_lookup(cache, "missing-session", 999L),
    None,
  )
}

///|
fn status_bar_test_agent(
  id : String,
  role : @types.Role,
  parent : String?,
  agent_type : @types.AgentType,
  terminal_target : @types.LocalTarget?,
) -> @types.Agent {
  {
    agent_id: @types.AgentId(id),
    role,
    agent_type,
    parent,
    workspace: "/tmp/status-bar/" + id,
    branch: id,
    terminal_target,
    host: @types.Host::Local,
    state: @types.AgentState::Active,
    spawn_depth: 0,
  }
}

///|
fn status_bar_test_lifecycle(
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
fn status_bar_test_review_open() -> @phase.ReviewOwnership {
  @phase.ReviewOwnership::OpenUnreviewed(url="https://example.test/pr")
}

///|
fn status_bar_test_thread_refs(count : Int) -> Array[@poller.ReviewThreadRef] {
  let refs : Array[@poller.ReviewThreadRef] = []
  for i = 0; i < count; i = i + 1 {
    refs.push({
      id: "thread-" + i.to_string(),
      is_outdated: false,
      author_login: "copilot-pull-request-reviewer",
    })
  }
  refs
}

///|
fn status_bar_test_tracked_pr(
  pr_number : Int,
  agent_id : String,
  ci_rollup : @poller.CiRollupStatus,
  fixes_pushed_at : Int64,
  unresolved_threads : Int,
  threads_fetched? : Bool = true,
) -> @poller.TrackedPR {
  {
    pr_number,
    agent_id,
    branch: agent_id,
    parent_branch: "main",
    pr_url: "https://example.test/pr/" + pr_number.to_string(),
    first_seen: 1L,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::ChangesRequested,
    last_review_bodies: "",
    last_sha: "abc123",
    last_automerge_attempt_sha: "",
    notified_parent: false,
    last_ci_rollup: ci_rollup,
    mergeable: @poller.Mergeable::Unknown,
    merge_state_status: @poller.MergeStateStatus::Unknown,
    merged_at_unix: None,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: true,
    orphan_notified: false,
    orphan_reconciling: false,
    changes_requested_since: 2L,
    stall_notified: false,
    fixes_pushed_at,
    review_mode: @types.ReviewMode::Iterative,
    unresolved_thread_ids: status_bar_test_thread_refs(unresolved_threads),
    unresolved_thread_ids_fetched: threads_fetched,
    auto_resolve_outdated_pending: false,
  }
}

///|
fn status_bar_test_snapshot() -> StatusBarSnapshot {
  let entries : Array[StatusBarRegistryEntry] = [
    {
      agent: status_bar_test_agent(
        "root",
        @types.Role::TL,
        None,
        @types.AgentType::Codex,
        Some(status_bar_test_pane_target("terminal_1")),
      ),
      lifecycle: status_bar_test_lifecycle(
        "root",
        @types.Role::TL,
        @phase.WorkflowState::Supervisor(
          @phase.SupervisorLifecycle::Supervising(children=[], wave=1),
        ),
        100L,
      ),
    },
    {
      agent: status_bar_test_agent(
        "root.leaf",
        @types.Role::Dev,
        Some("root"),
        @types.AgentType::Gemini,
        Some(status_bar_test_pane_target("terminal_42")),
      ),
      lifecycle: status_bar_test_lifecycle(
        "root.leaf",
        @types.Role::Dev,
        @phase.WorkflowState::Dev(
          @phase.DevLifecycle::ChangesRequested(pr_number=17, next_round=2),
        ),
        200L,
      ),
    },
    {
      agent: status_bar_test_agent(
        "root.no-pane",
        @types.Role::Worker,
        Some("root"),
        @types.AgentType::Claude,
        None,
      ),
      lifecycle: status_bar_test_lifecycle(
        "root.no-pane",
        @types.Role::Worker,
        @phase.WorkflowState::Worker(@phase.WorkerLifecycle::Working),
        300L,
      ),
    },
    {
      agent: status_bar_test_agent(
        "root.bad-pane",
        @types.Role::Dev,
        Some("root"),
        @types.AgentType::Codex,
        Some(status_bar_test_tab_target("terminal_99")),
      ),
      lifecycle: status_bar_test_lifecycle(
        "root.bad-pane",
        @types.Role::Dev,
        @phase.WorkflowState::Dev(@phase.DevLifecycle::Working),
        400L,
      ),
    },
  ]
  let tracked : Map[Int, @poller.TrackedPR] = {}
  tracked.set(
    17,
    status_bar_test_tracked_pr(
      17,
      "root.leaf",
      @poller.CiRollupStatus::Success,
      5L,
      1,
    ),
  )
  build_status_bar_snapshot(
    entries,
    tracked,
    empty_zellij_list_panes_snapshot(),
    12_345L,
  )
}

///|
fn assert_exact_keys(
  obj : Map[String, Json],
  keys : Array[String],
) -> Unit raise {
  assert_eq(obj.length(), keys.length())
  for key in keys {
    assert_true(obj.contains(key))
  }
}

///|
fn assert_status_bar_json_has_contract_keys(json : Json) -> Unit raise {
  match json {
    Object(root) => {
      assert_exact_keys(root, ["schema_version", "taken_at_ms", "panes"])
      match root.get("panes") {
        Some(Array(items)) => {
          assert_true(items.length() > 0)
          match items[0] {
            Object(pane) =>
              assert_exact_keys(pane, [
                "zellij_pane_id", "agent_id", "role", "agent_type", "lifecycle",
                "pr_number", "unresolved_threads", "ci_rollup", "attention_needed",
                "parent_agent_id", "last_activity_unix",
              ])
            _ => fail("expected pane object")
          }
        }
        _ => fail("expected panes array")
      }
    }
    _ => fail("expected status bar snapshot object")
  }
}

///|
fn assert_status_bar_json_number_field(
  obj : Map[String, Json],
  key : String,
  expected : Int64,
) -> Unit raise {
  match obj.get(key) {
    Some(Number(n, ..)) => assert_eq(n.to_int64(), expected)
    Some(String(_)) => fail(key + " encoded as JSON string")
    Some(_) => fail(key + " encoded as non-number JSON value")
    None => fail("missing " + key)
  }
}

///|
fn assert_status_bar_timestamp_fields_are_numbers(
  json : Json,
  expected_taken_at_ms : Int64,
  expected_last_activity_unix : Int64,
) -> Unit raise {
  match json {
    Object(root) => {
      assert_status_bar_json_number_field(
        root, "taken_at_ms", expected_taken_at_ms,
      )
      match root.get("panes") {
        Some(Array(items)) => {
          assert_true(items.length() > 0)
          match items[0] {
            Object(pane) =>
              assert_status_bar_json_number_field(
                pane, "last_activity_unix", expected_last_activity_unix,
              )
            _ => fail("expected pane object")
          }
        }
        _ => fail("expected panes array")
      }
    }
    _ => fail("expected status bar snapshot object")
  }
}

///|
test "status_bar_state lifecycle_to_wire_string covers workflow variants" {
  assert_eq(
    lifecycle_to_wire_string(
      @phase.WorkflowState::Dev(@phase.DevLifecycle::Working),
    ),
    "working",
  )
  assert_eq(
    lifecycle_to_wire_string(
      @phase.WorkflowState::Dev(
        @phase.DevLifecycle::ReviewOwned(
          pr_number=1,
          state=status_bar_test_review_open(),
        ),
      ),
    ),
    "review_owned",
  )
  assert_eq(
    lifecycle_to_wire_string(
      @phase.WorkflowState::Dev(
        @phase.DevLifecycle::ChangesRequested(pr_number=1, next_round=2),
      ),
    ),
    "changes_requested",
  )
  assert_eq(
    lifecycle_to_wire_string(
      @phase.WorkflowState::Dev(
        @phase.DevLifecycle::ExitRequestedDeferred(
          pr_number=1,
          state=status_bar_test_review_open(),
        ),
      ),
    ),
    "review_owned",
  )
  assert_eq(
    lifecycle_to_wire_string(
      @phase.WorkflowState::Dev(
        @phase.DevLifecycle::Done(reason=@phase.FinalizeReason::Merged),
      ),
    ),
    "done",
  )
  assert_eq(
    lifecycle_to_wire_string(
      @phase.WorkflowState::Dev(
        @phase.DevLifecycle::Failed(
          reason=@phase.FailureReason::UnexpectedDisconnect,
        ),
      ),
    ),
    "failed",
  )
  assert_eq(
    lifecycle_to_wire_string(
      @phase.WorkflowState::Dev(@phase.DevLifecycle::Exitable),
    ),
    "exitable",
  )
  assert_eq(
    lifecycle_to_wire_string(
      @phase.WorkflowState::Dev(@phase.DevLifecycle::WaitingForRedGate),
    ),
    "waiting_for_red_gate",
  )
  assert_eq(
    lifecycle_to_wire_string(
      @phase.WorkflowState::Worker(@phase.WorkerLifecycle::Working),
    ),
    "working",
  )
  assert_eq(
    lifecycle_to_wire_string(
      @phase.WorkflowState::Worker(@phase.WorkerLifecycle::Exitable),
    ),
    "exitable",
  )
  assert_eq(
    lifecycle_to_wire_string(
      @phase.WorkflowState::Worker(
        @phase.WorkerLifecycle::Done(reason=@phase.FinalizeReason::Shutdown),
      ),
    ),
    "done",
  )
  assert_eq(
    lifecycle_to_wire_string(
      @phase.WorkflowState::Worker(
        @phase.WorkerLifecycle::Failed(
          reason=@phase.FailureReason::WatchdogTimeout,
        ),
      ),
    ),
    "failed",
  )
  assert_eq(
    lifecycle_to_wire_string(
      @phase.WorkflowState::Supervisor(@phase.SupervisorLifecycle::Planning),
    ),
    "working",
  )
  assert_eq(
    lifecycle_to_wire_string(
      @phase.WorkflowState::Supervisor(@phase.SupervisorLifecycle::Dispatching),
    ),
    "working",
  )
  assert_eq(
    lifecycle_to_wire_string(
      @phase.WorkflowState::Supervisor(
        @phase.SupervisorLifecycle::Supervising(children=[], wave=1),
      ),
    ),
    "working",
  )
  assert_eq(
    lifecycle_to_wire_string(
      @phase.WorkflowState::Supervisor(
        @phase.SupervisorLifecycle::WaveComplete(wave=1, children=[]),
      ),
    ),
    "done",
  )
  assert_eq(
    lifecycle_to_wire_string(
      @phase.WorkflowState::Supervisor(
        @phase.SupervisorLifecycle::OwnPRFiled(
          number=7,
          url="https://example.test/pr/7",
        ),
      ),
    ),
    "review_owned",
  )
  assert_eq(
    lifecycle_to_wire_string(
      @phase.WorkflowState::Supervisor(@phase.SupervisorLifecycle::Done),
    ),
    "done",
  )
  assert_eq(
    lifecycle_to_wire_string(
      @phase.WorkflowState::Supervisor(
        @phase.SupervisorLifecycle::Failed(
          reason=@phase.FailureReason::ParentKilled,
        ),
      ),
    ),
    "failed",
  )
}

///|
test "status_bar_state role mapping covers schema roles" {
  assert_eq(role_to_wire_string("root", @types.Role::TL), "root")
  assert_eq(role_to_wire_string("main.tl", @types.Role::TL), "tl")
  assert_eq(role_to_wire_string("main.dev", @types.Role::Dev), "dev")
  assert_eq(role_to_wire_string("main.worker", @types.Role::Worker), "worker")
}

///|
test "status_bar_state agent_type mapping covers schema agent types" {
  @debug.assert_eq(
    agent_type_to_wire_string(@types.AgentType::Codex),
    Some("codex"),
  )
  @debug.assert_eq(
    agent_type_to_wire_string(@types.AgentType::Claude),
    Some("claude"),
  )
  @debug.assert_eq(
    agent_type_to_wire_string(@types.AgentType::MoonPilot),
    Some("moon_pilot"),
  )
  @debug.assert_eq(
    agent_type_to_wire_string(@types.AgentType::Gemini),
    Some("gemini"),
  )
  @debug.assert_eq(
    agent_type_to_wire_string(@types.AgentType::CursorAgent),
    Some("cursor_agent"),
  )
  @debug.assert_eq(agent_type_to_wire_string(@types.AgentType::Unknown), None)
}

///|
test "status_bar_state ci rollup mapping covers schema rollups" {
  assert_eq(
    ci_rollup_to_wire_string(@poller.CiRollupStatus::Success),
    "success",
  )
  assert_eq(
    ci_rollup_to_wire_string(@poller.CiRollupStatus::InProgress),
    "in_progress",
  )
  assert_eq(
    ci_rollup_to_wire_string(@poller.CiRollupStatus::Failure),
    "failure",
  )
  assert_eq(
    ci_rollup_to_wire_string(@poller.CiRollupStatus::Unknown),
    "unknown",
  )
  assert_eq(
    ci_rollup_to_wire_string(@poller.CiRollupStatus::NoChecks),
    "no_checks",
  )
}

///|
test "status_bar_state parses zellij list-panes json snapshot" {
  let json =
    #|[
    #|  {"id":1,"tab_name":"Server","title":"env choir serve","is_plugin":false,"exited":false},
    #|  {"id":2,"tab_name":"TL","title":"root tl","is_plugin":false},
    #|  {"id":3,"tab_name":"TL","title":"zellij:status-bar","is_plugin":true},
    #|  {"id":"12","tab_name":"feature:one","title":"pane \"quoted\" name","extra":"ignored"}
    #|]
  let snapshot = parse_zellij_list_panes_json(json)
  assert_eq(snapshot.entries.length(), 3)
  assert_eq(snapshot.entries[0].pane_id, 1)
  assert_eq(snapshot.entries[0].tab_name, "Server")
  assert_eq(snapshot.entries[0].pane_name, "env choir serve")
  assert_eq(snapshot.entries[1].pane_id, 2)
  assert_eq(snapshot.entries[1].tab_name, "TL")
  assert_eq(snapshot.entries[1].pane_name, "root tl")
  assert_eq(snapshot.entries[2].pane_id, 12)
  assert_eq(snapshot.entries[2].tab_name, "feature:one")
  assert_eq(snapshot.entries[2].pane_name, "pane \"quoted\" name")
}

///|
test "status_bar_state parses nested zellij list-panes json snapshot" {
  let json =
    #|{
    #|  "Server": {
    #|    "serve-pane": {"pane_id": 4, "pane_x": 0},
    #|    "plugin": {"pane_id": 5, "is_plugin": true}
    #|  },
    #|  "TL": {
    #|    "tl-pane": {"id": 6, "extra": "ok"}
    #|  }
    #|}
  let snapshot = parse_zellij_list_panes_json(json)
  assert_eq(snapshot.entries.length(), 2)
  assert_eq(snapshot.entries[0].pane_id, 4)
  assert_eq(snapshot.entries[0].tab_name, "Server")
  assert_eq(snapshot.entries[0].pane_name, "serve-pane")
  assert_eq(snapshot.entries[1].pane_id, 6)
  assert_eq(snapshot.entries[1].tab_name, "TL")
  assert_eq(snapshot.entries[1].pane_name, "tl-pane")
}

///|
async fn status_bar_mock_list_panes_capture_ok(
  cmd : @workspace.Command,
) -> (Int, String) {
  @async.sleep(0)
  assert_eq(cmd.program, "env")
  @debug.assert_eq(cmd.args, [
    "NO_COLOR=1", "zellij", "--session", "status-test", "action", "list-panes", "--json",
    "--tab",
  ])
  let output =
    #|[{"id":8,"tab_name":"TL","title":"root tl","is_plugin":false}]
  (0, output)
}

///|
async test "status_bar_state list-panes capture uses zellij argv and parses output" {
  let snapshot = capture_zellij_list_panes_snapshot(
    "status-test",
    capture=status_bar_mock_list_panes_capture_ok,
  )
  assert_eq(snapshot.entries.length(), 1)
  assert_eq(snapshot.entries[0].pane_id, 8)
  assert_eq(snapshot.entries[0].tab_name, "TL")
  assert_eq(snapshot.entries[0].pane_name, "root tl")
}

///|
async fn status_bar_mock_list_panes_capture_fail(
  _cmd : @workspace.Command,
) -> (Int, String) {
  @async.sleep(0)
  let output =
    #|[{"id":8,"tab_name":"TL","title":"root tl","is_plugin":false}]
  (1, output)
}

///|
async test "status_bar_state list-panes capture degrades to empty snapshot on failure" {
  let snapshot = capture_zellij_list_panes_snapshot(
    "status-test",
    capture=status_bar_mock_list_panes_capture_fail,
  )
  assert_eq(snapshot.entries.length(), 0)
}

///|
test "status_bar_state resolves zellij pane ids from target shapes" {
  let snapshot = status_bar_test_list_panes_snapshot()
  @debug.assert_eq(
    resolve_zellij_pane_id(status_bar_test_pane_target("terminal_42"), snapshot),
    Some(42),
  )
  @debug.assert_eq(
    resolve_zellij_pane_id(status_bar_test_tab_target("TL"), snapshot),
    Some(2),
  )
  @debug.assert_eq(
    resolve_zellij_pane_id(status_bar_test_tab_target("missing"), snapshot),
    None,
  )
  @debug.assert_eq(
    resolve_zellij_pane_id(status_bar_test_pane_target("leaf-inline"), snapshot),
    Some(7),
  )
  @debug.assert_eq(
    resolve_zellij_pane_id(
      status_bar_test_pane_target("missing-pane"),
      snapshot,
    ),
    None,
  )
  @debug.assert_eq(
    resolve_zellij_pane_id(
      status_bar_test_pane_target("leaf-inline"),
      empty_zellij_list_panes_snapshot(),
    ),
    None,
  )
  @debug.assert_eq(
    resolve_zellij_pane_id(status_bar_test_pane_target("terminal_x"), snapshot),
    None,
  )
}

///|
test "status_bar_state pane_needs_attention truth table" {
  @debug.assert_eq(
    pane_needs_attention(
      @phase.WorkflowState::Dev(
        @phase.DevLifecycle::Failed(
          reason=@phase.FailureReason::UnexpectedDisconnect,
        ),
      ),
      0L,
      StatusBarThreadCount::Count(0),
    ),
    PaneAttention::Clear,
  )
  @debug.assert_eq(
    pane_needs_attention(
      @phase.WorkflowState::Worker(
        @phase.WorkerLifecycle::Failed(
          reason=@phase.FailureReason::WatchdogTimeout,
        ),
      ),
      0L,
      StatusBarThreadCount::Count(0),
    ),
    PaneAttention::Clear,
  )
  @debug.assert_eq(
    pane_needs_attention(
      @phase.WorkflowState::Supervisor(
        @phase.SupervisorLifecycle::Failed(
          reason=@phase.FailureReason::ParentKilled,
        ),
      ),
      0L,
      StatusBarThreadCount::Unknown,
    ),
    PaneAttention::Clear,
  )
  @debug.assert_eq(
    pane_needs_attention(
      @phase.WorkflowState::Dev(
        @phase.DevLifecycle::ChangesRequested(pr_number=1, next_round=2),
      ),
      1L,
      StatusBarThreadCount::Count(1),
    ),
    PaneAttention::Needed,
  )
  @debug.assert_eq(
    pane_needs_attention(
      @phase.WorkflowState::Dev(@phase.DevLifecycle::Working),
      1L,
      StatusBarThreadCount::Count(1),
    ),
    PaneAttention::Clear,
  )
  @debug.assert_eq(
    pane_needs_attention(
      @phase.WorkflowState::Dev(
        @phase.DevLifecycle::Done(reason=@phase.FinalizeReason::Merged),
      ),
      1L,
      StatusBarThreadCount::Count(1),
    ),
    PaneAttention::Clear,
  )
  @debug.assert_eq(
    pane_needs_attention(
      @phase.WorkflowState::Dev(
        @phase.DevLifecycle::ChangesRequested(pr_number=1, next_round=2),
      ),
      0L,
      StatusBarThreadCount::Count(1),
    ),
    PaneAttention::Clear,
  )
  @debug.assert_eq(
    pane_needs_attention(
      @phase.WorkflowState::Dev(
        @phase.DevLifecycle::ChangesRequested(pr_number=1, next_round=2),
      ),
      1L,
      StatusBarThreadCount::Count(0),
    ),
    PaneAttention::Clear,
  )
  @debug.assert_eq(
    pane_needs_attention(
      @phase.WorkflowState::Dev(
        @phase.DevLifecycle::ChangesRequested(pr_number=1, next_round=2),
      ),
      1L,
      StatusBarThreadCount::Unknown,
    ),
    PaneAttention::Unknown,
  )
  @debug.assert_eq(
    pane_needs_attention(
      @phase.WorkflowState::Dev(
        @phase.DevLifecycle::ChangesRequested(pr_number=1, next_round=2),
      ),
      0L,
      StatusBarThreadCount::Unknown,
    ),
    PaneAttention::Clear,
  )
}

///|
test "status_bar_state builds snapshot from registry and poller snapshots" {
  let snap = status_bar_test_snapshot()
  assert_eq(snap.schema_version, 2)
  assert_eq(snap.taken_at_ms, 12_345L)
  assert_eq(snap.panes.length(), 2)
  let root = snap.panes[0]
  assert_eq(root.zellij_pane_id, 1)
  assert_eq(root.agent_id, "root")
  assert_eq(root.role, "root")
  assert_eq(root.agent_type, "codex")
  assert_eq(root.lifecycle, "working")
  @debug.assert_eq(root.pr_number, None)
  @debug.assert_eq(root.unresolved_threads, StatusBarThreadCount::NoPR)
  assert_eq(root.ci_rollup, "unknown")
  @debug.assert_eq(root.attention_needed, PaneAttention::Clear)
  @debug.assert_eq(root.parent_agent_id, None)
  assert_eq(root.last_activity_unix, 100L)
  let leaf = snap.panes[1]
  assert_eq(leaf.zellij_pane_id, 42)
  assert_eq(leaf.agent_id, "root.leaf")
  assert_eq(leaf.role, "dev")
  assert_eq(leaf.agent_type, "gemini")
  assert_eq(leaf.lifecycle, "changes_requested")
  @debug.assert_eq(leaf.pr_number, Some(17))
  @debug.assert_eq(leaf.unresolved_threads, StatusBarThreadCount::Count(1))
  assert_eq(leaf.ci_rollup, "success")
  @debug.assert_eq(leaf.attention_needed, PaneAttention::Needed)
  @debug.assert_eq(leaf.parent_agent_id, Some("root"))
  assert_eq(leaf.last_activity_unix, 200L)
}

///|
test "status_bar_state lifecycle PR wins over competing tracked PR" {
  let entries : Array[StatusBarRegistryEntry] = [
    {
      agent: status_bar_test_agent(
        "root.leaf",
        @types.Role::Dev,
        Some("root"),
        @types.AgentType::Codex,
        Some(status_bar_test_pane_target("terminal_42")),
      ),
      lifecycle: status_bar_test_lifecycle(
        "root.leaf",
        @types.Role::Dev,
        @phase.WorkflowState::Dev(
          @phase.DevLifecycle::ReviewOwned(
            pr_number=42,
            state=status_bar_test_review_open(),
          ),
        ),
        200L,
      ),
    },
  ]
  let tracked : Map[Int, @poller.TrackedPR] = {}
  tracked.set(
    42,
    status_bar_test_tracked_pr(
      42,
      "root.leaf",
      @poller.CiRollupStatus::Success,
      0L,
      0,
      threads_fetched=false,
    ),
  )
  tracked.set(
    43,
    status_bar_test_tracked_pr(
      43,
      "root.leaf",
      @poller.CiRollupStatus::Failure,
      5L,
      1,
    ),
  )
  let snap = build_status_bar_snapshot(
    entries,
    tracked,
    empty_zellij_list_panes_snapshot(),
    100L,
  )
  assert_eq(snap.panes.length(), 1)
  let pane = snap.panes[0]
  @debug.assert_eq(pane.pr_number, Some(42))
  @debug.assert_eq(pane.unresolved_threads, StatusBarThreadCount::Unknown)
  assert_eq(pane.ci_rollup, "success")
  @debug.assert_eq(pane.attention_needed, PaneAttention::Clear)
}

///|
test "status_bar_state reports unknown attention when changes-requested threads are unfetched" {
  let entries : Array[StatusBarRegistryEntry] = [
    {
      agent: status_bar_test_agent(
        "root.leaf",
        @types.Role::Dev,
        Some("root"),
        @types.AgentType::Codex,
        Some(status_bar_test_pane_target("terminal_42")),
      ),
      lifecycle: status_bar_test_lifecycle(
        "root.leaf",
        @types.Role::Dev,
        @phase.WorkflowState::Dev(
          @phase.DevLifecycle::ChangesRequested(pr_number=56, next_round=2),
        ),
        200L,
      ),
    },
  ]
  let tracked : Map[Int, @poller.TrackedPR] = {}
  tracked.set(
    56,
    status_bar_test_tracked_pr(
      56,
      "root.leaf",
      @poller.CiRollupStatus::Unknown,
      95L,
      0,
      threads_fetched=false,
    ),
  )
  let snap = build_status_bar_snapshot(
    entries,
    tracked,
    empty_zellij_list_panes_snapshot(),
    100L,
  )
  assert_eq(snap.panes.length(), 1)
  let pane = snap.panes[0]
  @debug.assert_eq(pane.pr_number, Some(56))
  @debug.assert_eq(pane.unresolved_threads, StatusBarThreadCount::Unknown)
  @debug.assert_eq(pane.attention_needed, PaneAttention::Unknown)
}

///|
test "status_bar_state builds snapshot with all zellij target shapes" {
  let entries : Array[StatusBarRegistryEntry] = [
    {
      agent: status_bar_test_agent(
        "root",
        @types.Role::TL,
        None,
        @types.AgentType::Codex,
        Some(status_bar_test_pane_target("terminal_1")),
      ),
      lifecycle: status_bar_test_lifecycle(
        "root",
        @types.Role::TL,
        @phase.WorkflowState::Supervisor(@phase.SupervisorLifecycle::Planning),
        100L,
      ),
    },
    {
      agent: status_bar_test_agent(
        "root.tl",
        @types.Role::TL,
        Some("root"),
        @types.AgentType::Claude,
        Some(status_bar_test_tab_target("TL")),
      ),
      lifecycle: status_bar_test_lifecycle(
        "root.tl",
        @types.Role::TL,
        @phase.WorkflowState::Supervisor(@phase.SupervisorLifecycle::Planning),
        200L,
      ),
    },
    {
      agent: status_bar_test_agent(
        "root.leaf",
        @types.Role::Dev,
        Some("root.tl"),
        @types.AgentType::Codex,
        Some(status_bar_test_pane_target("leaf-inline")),
      ),
      lifecycle: status_bar_test_lifecycle(
        "root.leaf",
        @types.Role::Dev,
        @phase.WorkflowState::Dev(@phase.DevLifecycle::Working),
        300L,
      ),
    },
  ]
  let snapshot = build_status_bar_snapshot(
    entries,
    {},
    status_bar_test_list_panes_snapshot(),
    12_345L,
  )
  assert_eq(snapshot.panes.length(), 3)
  assert_eq(snapshot.panes[0].agent_id, "root")
  assert_eq(snapshot.panes[0].zellij_pane_id, 1)
  assert_eq(snapshot.panes[1].agent_id, "root.tl")
  assert_eq(snapshot.panes[1].zellij_pane_id, 2)
  assert_eq(snapshot.panes[2].agent_id, "root.leaf")
  assert_eq(snapshot.panes[2].zellij_pane_id, 7)
}

///|
test "status_bar_state json round trips without extra fields" {
  let snap = status_bar_test_snapshot()
  let json = @json.parse(snap.to_json().stringify()) catch {
    _ => fail("expected emitted status bar json to parse")
  }
  assert_status_bar_json_has_contract_keys(json)
  assert_status_bar_timestamp_fields_are_numbers(json, 12_345L, 100L)
  let parsed : StatusBarSnapshot = @json.from_json(json)
  @debug.assert_eq(parsed, snap)
  let encoded_again = @json.parse(parsed.to_json().stringify()) catch {
    _ => fail("expected re-encoded status bar json to parse")
  }
  @debug.assert_eq(encoded_again, json)
  assert_status_bar_timestamp_fields_are_numbers(encoded_again, 12_345L, 100L)
}

///|
test "status_bar_state from_json accepts previous string timestamp form" {
  let pane : Map[String, Json] = {
    "zellij_pane_id": (7).to_json(),
    "agent_id": "root.leaf".to_json(),
    "role": "dev".to_json(),
    "agent_type": "codex".to_json(),
    "lifecycle": "working".to_json(),
    "pr_number": Json::null(),
    "unresolved_threads": "none".to_json(),
    "ci_rollup": "unknown".to_json(),
    "attention_needed": "clear".to_json(),
    "parent_agent_id": "root".to_json(),
    "last_activity_unix": "456".to_json(),
  }
  let json : Json = {
    "schema_version": (2).to_json(),
    "taken_at_ms": "12345".to_json(),
    "panes": [pane.to_json()].to_json(),
  }.to_json()
  let parsed : StatusBarSnapshot = @json.from_json(json)
  assert_eq(parsed.taken_at_ms, 12_345L)
  assert_eq(parsed.panes.length(), 1)
  assert_eq(parsed.panes[0].last_activity_unix, 456L)
  let encoded = @json.parse(parsed.to_json().stringify()) catch {
    _ => fail("expected re-encoded status bar json to parse")
  }
  assert_status_bar_timestamp_fields_are_numbers(encoded, 12_345L, 456L)
}

///|
test "status_bar_state from_json rejects unsupported schema version" {
  let panes : Array[Json] = []
  let json : Json = {
    "schema_version": (1).to_json(),
    "taken_at_ms": (12_345).to_json(),
    "panes": panes.to_json(),
  }.to_json()
  let result = try {
    let _parsed : StatusBarSnapshot = @json.from_json(json)
    ()
  } catch {
    err => Err(err)
  } noraise {
    value => Ok(value)
  }
  match result {
    Err(err) =>
      assert_true(err.to_string().contains("expected schema_version 2"))
    Ok(_) => fail("expected unsupported schema_version to fail")
  }
}

///|
async test "interpret_status_bar_state returns direct structured payload" {
  let reg = @registry.AgentRegistry::new()
  ignore(
    status_bar_test_ignore(() => {
      reg.insert(
        status_bar_test_agent(
          "root",
          @types.Role::TL,
          None,
          @types.AgentType::Codex,
          Some(status_bar_test_pane_target("terminal_1")),
        ),
      )
    }),
  )
  let lifecycle = status_bar_test_lifecycle(
    "root",
    @types.Role::TL,
    @phase.WorkflowState::Supervisor(@phase.SupervisorLifecycle::Planning),
    10L,
  )
  let resp = interpret_status_bar_state(
    { unit: () },
    ".",
    Some(reg),
    None,
    lifecycle_reader=Some(fn(_agent_id) { Some(lifecycle) }),
    now_ms=99L,
  )
  assert_true(resp.is_ok())
  match resp.ok_payload() {
    Some(fields) => {
      let body = fields.to_json_map()
      assert_true(body.contains("schema_version"))
      assert_true(body.contains("taken_at_ms"))
      assert_true(body.contains("panes"))
      assert_false(body.contains("snapshot"))
      let parsed : StatusBarSnapshot = @json.from_json(body.to_json())
      assert_eq(parsed.schema_version, 2)
      assert_eq(parsed.taken_at_ms, 99L)
      assert_eq(parsed.panes.length(), 1)
    }
    None => fail("expected ok payload")
  }
}

///|
async test "interpret_status_bar_state uses injected list-panes snapshot" {
  let reg = @registry.AgentRegistry::new()
  ignore(
    status_bar_test_ignore(() => {
      reg.insert(
        status_bar_test_agent(
          "root.tl",
          @types.Role::TL,
          Some("root"),
          @types.AgentType::Codex,
          Some(status_bar_test_tab_target("TL")),
        ),
      )
    }),
  )
  let lifecycle = status_bar_test_lifecycle(
    "root.tl",
    @types.Role::TL,
    @phase.WorkflowState::Supervisor(@phase.SupervisorLifecycle::Planning),
    10L,
  )
  let resp = interpret_status_bar_state(
    { unit: () },
    ".",
    Some(reg),
    None,
    lifecycle_reader=Some(fn(_agent_id) { Some(lifecycle) }),
    list_panes_capture=async fn(
      session,
    ) -> Result[ZellijListPanesSnapshot, @types.ChoirError] {
      @async.sleep(0)
      assert_eq(session, "status-test")
      Ok(status_bar_test_list_panes_snapshot())
    },
    now_ms=99L,
  )
  assert_true(resp.is_ok())
  match resp.ok_payload() {
    Some(fields) => {
      let parsed : StatusBarSnapshot = @json.from_json(
        fields.to_json_map().to_json(),
      )
      assert_eq(parsed.panes.length(), 1)
      assert_eq(parsed.panes[0].agent_id, "root.tl")
      assert_eq(parsed.panes[0].zellij_pane_id, 2)
    }
    None => fail("expected ok payload")
  }
}

///|
async test "interpret_status_bar_state reuses list-panes within ttl and refreshes after ttl" {
  let reg = @registry.AgentRegistry::new()
  ignore(
    status_bar_test_ignore(() => {
      reg.insert(
        status_bar_test_agent(
          "root.tl",
          @types.Role::TL,
          Some("root"),
          @types.AgentType::Codex,
          Some(status_bar_test_tab_target("TL")),
        ),
      )
    }),
  )
  let lifecycle = status_bar_test_lifecycle(
    "root.tl",
    @types.Role::TL,
    @phase.WorkflowState::Supervisor(@phase.SupervisorLifecycle::Planning),
    10L,
  )
  let cache : Map[String, CachedListPanesSnapshot] = {}
  let calls : Ref[Int] = @ref.new(0)
  let capture = async fn(
    session : String,
  ) -> Result[ZellijListPanesSnapshot, @types.ChoirError] {
    @async.sleep(0)
    assert_eq(session, "status-test")
    calls.val += 1
    Ok(status_bar_test_list_panes_snapshot())
  }
  let first = interpret_status_bar_state(
    { unit: () },
    ".",
    Some(reg),
    None,
    lifecycle_reader=Some(fn(_agent_id) { Some(lifecycle) }),
    list_panes_cache=Some(cache),
    list_panes_capture=capture,
    now_ms=1000L,
  )
  assert_true(first.is_ok())
  let second = interpret_status_bar_state(
    { unit: () },
    ".",
    Some(reg),
    None,
    lifecycle_reader=Some(fn(_agent_id) { Some(lifecycle) }),
    list_panes_cache=Some(cache),
    list_panes_capture=capture,
    now_ms=1000L + LIST_PANES_TTL_MS - 1L,
  )
  assert_true(second.is_ok())
  assert_eq(calls.val, 1)
  @debug.assert_eq(
    list_panes_cache_lookup(
      cache,
      "status-test",
      1000L + LIST_PANES_TTL_MS - 1L,
    ),
    Some(status_bar_test_list_panes_snapshot()),
  )
  let third = interpret_status_bar_state(
    { unit: () },
    ".",
    Some(reg),
    None,
    lifecycle_reader=Some(fn(_agent_id) { Some(lifecycle) }),
    list_panes_cache=Some(cache),
    list_panes_capture=capture,
    now_ms=1000L + LIST_PANES_TTL_MS + 1000L,
  )
  assert_true(third.is_ok())
  assert_eq(calls.val, 2)
}

///|
async test "interpret_status_bar_state does not store failed list-panes capture" {
  let reg = @registry.AgentRegistry::new()
  ignore(
    status_bar_test_ignore(() => {
      reg.insert(
        status_bar_test_agent(
          "root.tl",
          @types.Role::TL,
          Some("root"),
          @types.AgentType::Codex,
          Some(status_bar_test_tab_target("TL")),
        ),
      )
    }),
  )
  let lifecycle = status_bar_test_lifecycle(
    "root.tl",
    @types.Role::TL,
    @phase.WorkflowState::Supervisor(@phase.SupervisorLifecycle::Planning),
    10L,
  )
  let cache : Map[String, CachedListPanesSnapshot] = {}
  let calls : Ref[Int] = @ref.new(0)
  let capture = async fn(
    _session : String,
  ) -> Result[ZellijListPanesSnapshot, @types.ChoirError] {
    @async.sleep(0)
    calls.val += 1
    if calls.val == 1 {
      Err(@types.ChoirError::workspace_error("capture failed"))
    } else {
      Ok(status_bar_test_list_panes_snapshot())
    }
  }
  let failed_capture = interpret_status_bar_state(
    { unit: () },
    ".",
    Some(reg),
    None,
    lifecycle_reader=Some(fn(_agent_id) { Some(lifecycle) }),
    list_panes_cache=Some(cache),
    list_panes_capture=capture,
    now_ms=1000L,
  )
  assert_true(failed_capture.is_ok())
  @debug.assert_eq(list_panes_cache_lookup(cache, "status-test", 1001L), None)
  let retry = interpret_status_bar_state(
    { unit: () },
    ".",
    Some(reg),
    None,
    lifecycle_reader=Some(fn(_agent_id) { Some(lifecycle) }),
    list_panes_cache=Some(cache),
    list_panes_capture=capture,
    now_ms=1001L,
  )
  assert_true(retry.is_ok())
  assert_eq(calls.val, 2)
  @debug.assert_eq(
    list_panes_cache_lookup(cache, "status-test", 1001L),
    Some(status_bar_test_list_panes_snapshot()),
  )
}

///|
async test "interpret_status_bar_state fails without registry" {
  let resp = interpret_status_bar_state(
    { unit: () },
    ".",
    None,
    None,
    lifecycle_reader=Some(fn(_agent_id) { None }),
    now_ms=0L,
  )
  assert_false(resp.is_ok())
  assert_true(resp.error_message().unwrap().contains("agent registry"))
}

///|
test "status_bar_state tool registry allows all roles" {
  let tools = @tools.ToolRegistry::new()
  let tl_lookup = status_bar_test_capture(() => {
    tools.lookup(@types.Role::TL, "status_bar_state")
  })
  let dev_lookup = status_bar_test_capture(() => {
    tools.lookup(@types.Role::Dev, "status_bar_state")
  })
  let worker_lookup = status_bar_test_capture(() => {
    tools.lookup(@types.Role::Worker, "status_bar_state")
  })
  assert_true(tl_lookup is Ok(_))
  assert_true(dev_lookup is Ok(_))
  assert_true(worker_lookup is Ok(_))
}

///|
test "handoff_status tool registry allows all roles read-only" {
  let tools = @tools.ToolRegistry::new()
  let tl_lookup = status_bar_test_capture(() => {
    tools.lookup(@types.Role::TL, "handoff_status")
  })
  let dev_lookup = status_bar_test_capture(() => {
    tools.lookup(@types.Role::Dev, "handoff_status")
  })
  let worker_lookup = status_bar_test_capture(() => {
    tools.lookup(@types.Role::Worker, "handoff_status")
  })
  assert_true(tl_lookup is Ok(_))
  assert_true(dev_lookup is Ok(_))
  assert_true(worker_lookup is Ok(_))
  guard tl_lookup is Ok(def) else { return }
  assert_true(def.read_only)
}
