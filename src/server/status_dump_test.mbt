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
test "server status snapshot serializes registry lifecycle target age and PR" {
  let registry = @registry.AgentRegistry::new()
  ignore(
    registry.upsert(
      status_dump_test_agent(
        "root",
        @types.Role::Root,
        None,
        Some("zellij-pane:s:root"),
      ),
    ),
  )
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
    41, "root.leaf", "root.leaf", "main", "https://example.test/pull/41", 1L,
  )
  poller.track(
    42, "root.leaf", "root.leaf", "main", "https://example.test/pull/42", 1L,
  )
  poller.track(
    43, "root.leaf", "root.leaf", "main", "https://example.test/pull/43", 1L,
  )
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
  let text = build_server_status_snapshot_text(
    registry,
    poller,
    fn(agent_id) { lifecycles.get(agent_id) },
    100L,
  )
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
      "agent_id=root.leaf role=dev agent_type=codex lifecycle=review_owned terminal_target=zellij-pane:s:leaf parent_agent_id=root last_activity_unix=90 last_request_age_sec=10 pr_number=43 unresolved_threads=unknown ci_rollup=unknown attention_needed=unknown\n",
    ),
  )
}
