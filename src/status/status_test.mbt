///|
fn setup_test_env(project_dir : String) -> Unit {
  ignore(@sys.write_file_sync(project_dir + "/.choir/config.toml", ""))
  ignore(@sys.write_file_sync(project_dir + "/.choir/poller_state.json", "[]"))
}

///|
fn cleanup_test_env(project_dir : String) -> Unit {
  ignore(@sys.system("rm -rf '" + project_dir + "'"))
}

///|
test "build_status_snapshot with no agents returns empty snapshot" {
  let project_dir = "/tmp/choir-status-empty"
  setup_test_env(project_dir)
  let registry = @registry.AgentRegistry::new()
  let poller_state = @poller.PollerState::new()
  let snapshot = build_status_snapshot(project_dir, registry, poller_state)
  assert_eq(snapshot.agents.length(), 0)
  cleanup_test_env(project_dir)
}

///|
test "build_status_snapshot includes agent with lifecycle state" {
  let project_dir = "/tmp/choir-status-lifecycle"
  setup_test_env(project_dir)
  let agent_id = "main.test-agent"
  let lifecycle : @phase.AgentLifecycle = {
    agent_id,
    role: @types.Role::Dev,
    process: @phase.ProcessState::Connected,
    workflow: @phase.WorkflowState::Dev(@phase.DevLifecycle::Working),
  }
  ignore(@phase.write_lifecycle(project_dir, lifecycle))
  let registry = @registry.AgentRegistry::new()
  ignore(
    registry.insert({
      agent_id,
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Claude,
      parent: None,
      workspace: "/tmp",
      branch: "main",
      terminal_target: None,
      host: @types.Host::Local,
      state: @types.AgentState::Active,
    }),
  )
  let poller_state = @poller.PollerState::new()
  let snapshot = build_status_snapshot(project_dir, registry, poller_state)
  assert_eq(snapshot.agents.length(), 1)
  let agent_status = snapshot.agents[0]
  assert_eq(agent_status.agent_id, agent_id)
  assert_eq(agent_status.role, "Dev")
  assert_eq(agent_status.workflow_state, "Working")
  cleanup_test_env(project_dir)
}

///|
test "build_status_snapshot includes tracked PR info" {
  let project_dir = "/tmp/choir-status-pr"
  setup_test_env(project_dir)
  let agent_id = "main.pr-agent"
  let lifecycle : @phase.AgentLifecycle = {
    agent_id,
    role: @types.Role::Dev,
    process: @phase.ProcessState::Connected,
    workflow: @phase.WorkflowState::Dev(
      @phase.DevLifecycle::ReviewOwned(
        pr_number=42,
        state=@phase.ReviewOwnership::OpenUnreviewed(
          url="https://github.com/test/repo/pull/42",
        ),
      ),
    ),
  }
  ignore(@phase.write_lifecycle(project_dir, lifecycle))
  let registry = @registry.AgentRegistry::new()
  ignore(
    registry.insert({
      agent_id,
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Claude,
      parent: None,
      workspace: "/tmp",
      branch: "feature-branch",
      terminal_target: None,
      host: @types.Host::Local,
      state: @types.AgentState::Active,
    }),
  )
  let poller_state = @poller.PollerState::new()
  poller_state.track(
    42, agent_id, "feature-branch", "main", "https://github.com/test/repo/pull/42",
    1000L,
  )
  let snapshot = build_status_snapshot(project_dir, registry, poller_state)
  assert_eq(snapshot.agents.length(), 1)
  let agent_status = snapshot.agents[0]
  match agent_status.tracked_pr {
    Some(pr) => {
      assert_eq(pr.pr_number, 42)
      assert_eq(pr.url, "https://github.com/test/repo/pull/42")
      assert_eq(pr.branch, "feature-branch")
      assert_eq(pr.parent_branch, "main")
      assert_eq(pr.review_state, "none")
      assert_false(pr.ci_failed)
    }
    None => fail("expected tracked PR info")
  }
  cleanup_test_env(project_dir)
}

///|
test "build_status_snapshot includes blocked summary for review-owned agent" {
  let project_dir = "/tmp/choir-status-blocked"
  setup_test_env(project_dir)
  let agent_id = "main.blocked-agent"
  let lifecycle : @phase.AgentLifecycle = {
    agent_id,
    role: @types.Role::Dev,
    process: @phase.ProcessState::Connected,
    workflow: @phase.WorkflowState::Dev(
      @phase.DevLifecycle::ReviewOwned(
        pr_number=52,
        state=@phase.ReviewOwnership::OpenUnreviewed(
          url="https://github.com/test/repo/pull/52",
        ),
      ),
    ),
  }
  ignore(@phase.write_lifecycle(project_dir, lifecycle))
  let registry = @registry.AgentRegistry::new()
  ignore(
    registry.insert({
      agent_id,
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Claude,
      parent: None,
      workspace: "/tmp",
      branch: "main",
      terminal_target: None,
      host: @types.Host::Local,
      state: @types.AgentState::Active,
    }),
  )
  let poller_state = @poller.PollerState::new()
  poller_state.track(
    52, agent_id, "feature-branch", "main", "https://github.com/test/repo/pull/52",
    1000L,
  )
  let snapshot = build_status_snapshot(project_dir, registry, poller_state)
  assert_eq(snapshot.agents.length(), 1)
  let agent_status = snapshot.agents[0]
  match agent_status.blocked_summary {
    Some(summary) => {
      assert_true(summary.contains("PR"))
      assert_true(summary.contains("52"))
    }
    None => fail("expected blocked summary for review-owned agent")
  }
  cleanup_test_env(project_dir)
}

///|
test "build_status_snapshot includes CI failed state" {
  let project_dir = "/tmp/choir-status-ci"
  setup_test_env(project_dir)
  let agent_id = "main.ci-agent"
  let lifecycle : @phase.AgentLifecycle = {
    agent_id,
    role: @types.Role::Dev,
    process: @phase.ProcessState::Connected,
    workflow: @phase.WorkflowState::Dev(@phase.DevLifecycle::Working),
  }
  ignore(@phase.write_lifecycle(project_dir, lifecycle))
  let registry = @registry.AgentRegistry::new()
  ignore(
    registry.insert({
      agent_id,
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Claude,
      parent: None,
      workspace: "/tmp",
      branch: "ci-failed-branch",
      terminal_target: None,
      host: @types.Host::Local,
      state: @types.AgentState::Active,
    }),
  )
  let poller_state = @poller.PollerState::new()
  poller_state.track(
    62, agent_id, "ci-failed-branch", "main", "https://github.com/test/repo/pull/62",
    1000L,
  )
  poller_state.tracked.get(62).unwrap().last_ci_failed = true
  let snapshot = build_status_snapshot(project_dir, registry, poller_state)
  assert_eq(snapshot.agents.length(), 1)
  let agent_status = snapshot.agents[0]
  match agent_status.tracked_pr {
    Some(pr) => {
      assert_eq(pr.pr_number, 62)
      assert_true(pr.ci_failed)
    }
    None => fail("expected tracked PR with CI failed")
  }
  cleanup_test_env(project_dir)
}

///|
test "render_json produces valid JSON structure" {
  let project_dir = "/tmp/choir-status-json"
  setup_test_env(project_dir)
  let agent_id = "main.json-agent"
  let lifecycle : @phase.AgentLifecycle = {
    agent_id,
    role: @types.Role::Dev,
    process: @phase.ProcessState::Connected,
    workflow: @phase.WorkflowState::Dev(@phase.DevLifecycle::Working),
  }
  ignore(@phase.write_lifecycle(project_dir, lifecycle))
  let registry = @registry.AgentRegistry::new()
  ignore(
    registry.insert({
      agent_id,
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Claude,
      parent: None,
      workspace: "/tmp",
      branch: "main",
      terminal_target: None,
      host: @types.Host::Local,
      state: @types.AgentState::Active,
    }),
  )
  let poller_state = @poller.PollerState::new()
  let snapshot = build_status_snapshot(project_dir, registry, poller_state)
  let json_str = render_json(snapshot)
  let parsed = @json.parse(json_str) catch { _ => fail("invalid JSON") }
  match parsed {
    Object(obj) => {
      assert_true(obj.contains("timestamp"))
      assert_true(obj.contains("agents"))
      match obj.get("agents") {
        Some(Array(agents)) => {
          assert_eq(agents.length(), 1)
          match agents[0] {
            Object(agent_obj) => {
              assert_true(agent_obj.contains("agent_id"))
              assert_true(agent_obj.contains("role"))
              assert_true(agent_obj.contains("state"))
              assert_true(agent_obj.contains("workflow_state"))
              match agent_obj.get("agent_id") {
                Some(String(id)) => assert_eq(id, agent_id)
                _ => fail("expected agent_id as string")
              }
            }
            _ => fail("expected agent object")
          }
        }
        _ => fail("expected agents array")
      }
    }
    _ => fail("expected JSON object")
  }
  cleanup_test_env(project_dir)
}

///|
test "render_human includes agent details in readable format" {
  let project_dir = "/tmp/choir-status-human"
  setup_test_env(project_dir)
  let agent_id = "main.human-agent"
  let lifecycle : @phase.AgentLifecycle = {
    agent_id,
    role: @types.Role::Dev,
    process: @phase.ProcessState::Connected,
    workflow: @phase.WorkflowState::Dev(@phase.DevLifecycle::Working),
  }
  ignore(@phase.write_lifecycle(project_dir, lifecycle))
  let registry = @registry.AgentRegistry::new()
  ignore(
    registry.insert({
      agent_id,
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Claude,
      parent: None,
      workspace: "/tmp",
      branch: "main",
      terminal_target: None,
      host: @types.Host::Local,
      state: @types.AgentState::Active,
    }),
  )
  let poller_state = @poller.PollerState::new()
  let snapshot = build_status_snapshot(project_dir, registry, poller_state)
  let human_output = render_human(snapshot)
  assert_true(human_output.contains("Choir Status"))
  assert_true(human_output.contains("Agent: " + agent_id))
  assert_true(human_output.contains("Role: Dev"))
  assert_true(human_output.contains("State:"))
  assert_true(human_output.contains("Workflow:"))
  cleanup_test_env(project_dir)
}

///|
test "render_human includes PR info in readable format" {
  let project_dir = "/tmp/choir-status-human-pr"
  setup_test_env(project_dir)
  let agent_id = "main.pr-human-agent"
  let lifecycle : @phase.AgentLifecycle = {
    agent_id,
    role: @types.Role::Dev,
    process: @phase.ProcessState::Connected,
    workflow: @phase.WorkflowState::Dev(
      @phase.DevLifecycle::ReviewOwned(
        pr_number=99,
        state=@phase.ReviewOwnership::ApprovedAwaitingMerge,
      ),
    ),
  }
  ignore(@phase.write_lifecycle(project_dir, lifecycle))
  let registry = @registry.AgentRegistry::new()
  ignore(
    registry.insert({
      agent_id,
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Claude,
      parent: None,
      workspace: "/tmp",
      branch: "ready-branch",
      terminal_target: None,
      host: @types.Host::Local,
      state: @types.AgentState::Active,
    }),
  )
  let poller_state = @poller.PollerState::new()
  poller_state.track(
    99, agent_id, "ready-branch", "main", "https://github.com/test/repo/pull/99",
    1000L,
  )
  poller_state.tracked.get(99).unwrap().last_review_state = @poller.ReviewState::Approved
  let snapshot = build_status_snapshot(project_dir, registry, poller_state)
  let human_output = render_human(snapshot)
  assert_true(human_output.contains("Tracked PR: #99"))
  assert_true(
    human_output.contains("URL: https://github.com/test/repo/pull/99"),
  )
  assert_true(human_output.contains("Branch: ready-branch"))
  assert_true(human_output.contains("Parent: main"))
  assert_true(human_output.contains("Review: approved"))
  cleanup_test_env(project_dir)
}

///|
test "build_status_snapshot with parent-child relationships" {
  let project_dir = "/tmp/choir-status-parent-child"
  setup_test_env(project_dir)
  let parent_id = "root.tl"
  let child_id = "main.dev-1"

  let parent_lifecycle : @phase.AgentLifecycle = {
    agent_id: parent_id,
    role: @types.Role::TL,
    process: @phase.ProcessState::Connected,
    workflow: @phase.WorkflowState::Supervisor(
      @phase.SupervisorLifecycle::Planning,
    ),
  }
  ignore(@phase.write_lifecycle(project_dir, parent_lifecycle))

  let child_lifecycle : @phase.AgentLifecycle = {
    agent_id: child_id,
    role: @types.Role::Dev,
    process: @phase.ProcessState::Connected,
    workflow: @phase.WorkflowState::Dev(@phase.DevLifecycle::Working),
  }
  ignore(@phase.write_lifecycle(project_dir, child_lifecycle))

  let registry = @registry.AgentRegistry::new()
  ignore(
    registry.insert({
      agent_id: parent_id,
      role: @types.Role::TL,
      agent_type: @types.AgentType::Claude,
      parent: None,
      workspace: "/tmp",
      branch: "main",
      terminal_target: None,
      host: @types.Host::Local,
      state: @types.AgentState::Active,
    }),
  )
  ignore(
    registry.insert({
      agent_id: child_id,
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Claude,
      parent: Some(parent_id),
      workspace: "/tmp",
      branch: "main.dev-1",
      terminal_target: None,
      host: @types.Host::Local,
      state: @types.AgentState::Active,
    }),
  )

  let poller_state = @poller.PollerState::new()
  let snapshot = build_status_snapshot(project_dir, registry, poller_state)
  assert_eq(snapshot.agents.length(), 2)

  let mut parent_status : AgentStatus? = None
  let mut child_status : AgentStatus? = None
  for agent in snapshot.agents {
    if agent.agent_id == parent_id {
      parent_status = Some(agent)
    } else if agent.agent_id == child_id {
      child_status = Some(agent)
    }
  }

  match parent_status {
    Some(ps) => {
      assert_eq(ps.children.length(), 1)
      assert_true(ps.children.contains(child_id))
    }
    None => fail("expected parent status")
  }

  match child_status {
    Some(cs) =>
      match cs.parent {
        Some(parent) => assert_eq(parent, parent_id)
        None => fail("expected parent for child")
      }
    None => fail("expected child status")
  }

  cleanup_test_env(project_dir)
}
