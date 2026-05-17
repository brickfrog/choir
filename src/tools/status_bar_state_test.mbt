///|
fn status_bar_test_pane_target(name : String) -> @types.LocalTarget {
  { kind: @types.TargetKind::ZellijPane, session: "status-test", name }
}

///|
fn status_bar_test_tab_target(name : String) -> @types.LocalTarget {
  { kind: @types.TargetKind::ZellijTab, session: "status-test", name }
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
    last_timeout_at: 0L,
    copilot_issue_comment_seen: true,
    orphan_notified: false,
    orphan_reconciling: false,
    changes_requested_since: 2L,
    stall_notified: false,
    fixes_pushed_at,
    review_mode: @types.ReviewMode::Iterative,
    unresolved_thread_ids: status_bar_test_thread_refs(unresolved_threads),
    unresolved_thread_ids_fetched: true,
    auto_resolve_outdated_pending: false,
  }
}

///|
fn status_bar_test_snapshot() -> StatusBarSnapshot {
  let entries : Array[StatusBarRegistryEntry] = [
    {
      agent: status_bar_test_agent(
        "root",
        @types.Role::Root,
        None,
        @types.AgentType::Codex,
        Some(status_bar_test_pane_target("terminal_1")),
      ),
      lifecycle: status_bar_test_lifecycle(
        "root",
        @types.Role::Root,
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
  build_status_bar_snapshot(entries, tracked, 12_345L)
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
  assert_eq(role_to_wire_string(@types.Role::Root), "root")
  assert_eq(role_to_wire_string(@types.Role::TL), "tl")
  assert_eq(role_to_wire_string(@types.Role::Dev), "dev")
  assert_eq(role_to_wire_string(@types.Role::Worker), "worker")
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
test "status_bar_state parse_zellij_pane_id extracts terminal suffix" {
  @debug.assert_eq(
    parse_zellij_pane_id("zellij-pane:choir-choir:terminal_42"),
    Some(42),
  )
  @debug.assert_eq(parse_zellij_pane_id("terminal_42"), None)
  @debug.assert_eq(parse_zellij_pane_id("zellij-pane:s:terminal_x"), None)
  @debug.assert_eq(parse_zellij_pane_id("zellij-pane:s:not_terminal_42"), None)
  @debug.assert_eq(parse_zellij_pane_id(""), None)
}

///|
test "status_bar_state pane_needs_attention truth table" {
  assert_true(
    pane_needs_attention(
      @phase.WorkflowState::Dev(
        @phase.DevLifecycle::Failed(
          reason=@phase.FailureReason::UnexpectedDisconnect,
        ),
      ),
      0L,
      0,
    ),
  )
  assert_true(
    pane_needs_attention(
      @phase.WorkflowState::Worker(
        @phase.WorkerLifecycle::Failed(
          reason=@phase.FailureReason::WatchdogTimeout,
        ),
      ),
      0L,
      0,
    ),
  )
  assert_true(
    pane_needs_attention(
      @phase.WorkflowState::Supervisor(
        @phase.SupervisorLifecycle::Failed(
          reason=@phase.FailureReason::ParentKilled,
        ),
      ),
      0L,
      0,
    ),
  )
  assert_true(
    pane_needs_attention(
      @phase.WorkflowState::Dev(
        @phase.DevLifecycle::ChangesRequested(pr_number=1, next_round=2),
      ),
      1L,
      1,
    ),
  )
  assert_false(
    pane_needs_attention(
      @phase.WorkflowState::Dev(@phase.DevLifecycle::Working),
      1L,
      1,
    ),
  )
  assert_false(
    pane_needs_attention(
      @phase.WorkflowState::Dev(
        @phase.DevLifecycle::Done(reason=@phase.FinalizeReason::Merged),
      ),
      1L,
      1,
    ),
  )
  assert_false(
    pane_needs_attention(
      @phase.WorkflowState::Dev(
        @phase.DevLifecycle::ChangesRequested(pr_number=1, next_round=2),
      ),
      0L,
      1,
    ),
  )
  assert_false(
    pane_needs_attention(
      @phase.WorkflowState::Dev(
        @phase.DevLifecycle::ChangesRequested(pr_number=1, next_round=2),
      ),
      1L,
      0,
    ),
  )
}

///|
test "status_bar_state builds snapshot from registry and poller snapshots" {
  let snap = status_bar_test_snapshot()
  assert_eq(snap.schema_version, 1)
  assert_eq(snap.taken_at_ms, 12_345L)
  assert_eq(snap.panes.length(), 2)
  let root = snap.panes[0]
  assert_eq(root.zellij_pane_id, 1)
  assert_eq(root.agent_id, "root")
  assert_eq(root.role, "root")
  assert_eq(root.agent_type, "codex")
  assert_eq(root.lifecycle, "working")
  @debug.assert_eq(root.pr_number, None)
  assert_eq(root.unresolved_threads, 0)
  assert_eq(root.ci_rollup, "unknown")
  assert_false(root.attention_needed)
  @debug.assert_eq(root.parent_agent_id, None)
  assert_eq(root.last_activity_unix, 100L)
  let leaf = snap.panes[1]
  assert_eq(leaf.zellij_pane_id, 42)
  assert_eq(leaf.agent_id, "root.leaf")
  assert_eq(leaf.role, "dev")
  assert_eq(leaf.agent_type, "gemini")
  assert_eq(leaf.lifecycle, "changes_requested")
  @debug.assert_eq(leaf.pr_number, Some(17))
  assert_eq(leaf.unresolved_threads, 1)
  assert_eq(leaf.ci_rollup, "success")
  assert_true(leaf.attention_needed)
  @debug.assert_eq(leaf.parent_agent_id, Some("root"))
  assert_eq(leaf.last_activity_unix, 200L)
}

///|
test "status_bar_state json round trips without extra fields" {
  let snap = status_bar_test_snapshot()
  let json = snap.to_json()
  assert_status_bar_json_has_contract_keys(json)
  let parsed : StatusBarSnapshot = @json.from_json(json)
  @debug.assert_eq(parsed, snap)
}

///|
test "interpret_status_bar_state returns direct structured payload" {
  let reg = @registry.AgentRegistry::new()
  ignore(
    try? reg.insert(
      status_bar_test_agent(
        "root",
        @types.Role::Root,
        None,
        @types.AgentType::Codex,
        Some(status_bar_test_pane_target("terminal_1")),
      ),
    ),
  )
  let lifecycle = status_bar_test_lifecycle(
    "root",
    @types.Role::Root,
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
      assert_eq(parsed.schema_version, 1)
      assert_eq(parsed.taken_at_ms, 99L)
      assert_eq(parsed.panes.length(), 1)
    }
    None => fail("expected ok payload")
  }
}

///|
test "interpret_status_bar_state fails without registry" {
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
  let root_lookup = try? tools.lookup(@types.Role::Root, "status_bar_state")
  let tl_lookup = try? tools.lookup(@types.Role::TL, "status_bar_state")
  let dev_lookup = try? tools.lookup(@types.Role::Dev, "status_bar_state")
  let worker_lookup = try? tools.lookup(@types.Role::Worker, "status_bar_state")
  assert_true(root_lookup is Ok(_))
  assert_true(tl_lookup is Ok(_))
  assert_true(dev_lookup is Ok(_))
  assert_true(worker_lookup is Ok(_))
}
