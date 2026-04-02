///|
test "plan_post_tool_actions - shutdown without registered agent clears runtime only" {
  let poller = @poller.PollerState::new()
  let registry = @registry.AgentRegistry::new()
  let project_dir = "/tmp/choir-post-tool-shutdown"
  let terminal_session = "s"
  let req : @types.Request = {
    req_method: "tools/call",
    role: @types.Role::Dev,
    name: "shutdown",
    args: @types.RequestArgs::new({ "agent_id": "main.leaf" }),
  }
  let resp = @types.Response::Ok(
    @types.ResponseFields::new({ "status": "shutdown" }),
  )
  let effects = plan_post_tool_actions(
    req,
    resp,
    merged_agent_id=None,
    poller,
    registry,
    project_dir,
    terminal_session,
  )
  assert_eq(effects.length(), 1)
  match effects[0] {
    ClearRuntimeTracking("main.leaf") => ()
    _ => fail("expected ClearRuntimeTracking when agent missing")
  }
}

///|
test "plan_post_tool_actions - shutdown with agent yields finalize teardown" {
  let poller = @poller.PollerState::new()
  let registry = @registry.AgentRegistry::new()
  let project_dir = "/tmp/choir-post-tool-shutdown-reg"
  let terminal_session = "s"
  let agent : @types.Agent = {
    agent_id: @types.AgentId("main.leaf"),
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Gemini,
    parent: Some("parent"),
    workspace: "/tmp/.choir/worktrees/main.leaf",
    branch: "work",
    terminal_target: Some({
      kind: @types.TargetKind::ZellijPane,
      session: "s",
      name: "p",
    }),
    host: @types.Host::Local,
    state: @types.AgentState::Active,
    spawn_depth: 0,
  }
  ignore(registry.upsert(agent))
  let req : @types.Request = {
    req_method: "tools/call",
    role: @types.Role::Dev,
    name: "shutdown",
    args: @types.RequestArgs::new({ "agent_id": "main.leaf" }),
  }
  let resp = @types.Response::Ok(
    @types.ResponseFields::new({ "status": "shutdown" }),
  )
  let effects = plan_post_tool_actions(
    req,
    resp,
    merged_agent_id=None,
    poller,
    registry,
    project_dir,
    terminal_session,
  )
  assert_eq(effects.length(), 9)
  match effects[0] {
    PersistLifecycle(agent_id="main.leaf", trigger="shutdown", ..) => ()
    _ => fail("expected PersistLifecycle(Finalizing)")
  }
  match effects[1] {
    RemoveTeamMember(parent_id="parent", slug="leaf") => ()
    _ => fail("expected RemoveTeamMember")
  }
  match effects[2] {
    NotifyParent(
      parent_id="parent",
      agent_id="main.leaf",
      message="agent shutdown",
      status="success"
    ) => ()
    _ => fail("expected NotifyParent")
  }
  match effects[3] {
    FireHook(agent_id="main.leaf", exit_reason="shutdown", ..) => ()
    _ => fail("expected FireHook")
  }
  match effects[4] {
    RemoveWorktree("/tmp/.choir/worktrees/main.leaf") => ()
    _ => fail("expected RemoveWorktree")
  }
  match effects[5] {
    CloseTerminal(_) => ()
    _ => fail("expected CloseTerminal")
  }
  match effects[6] {
    PersistLifecycle(agent_id="main.leaf", trigger="FinalizeComplete", ..) => ()
    _ => fail("expected PersistLifecycle(Finalized)")
  }
  match effects[7] {
    SyncParentLifecycle(agent_id="main.leaf", ..) => ()
    _ => fail("expected SyncParentLifecycle")
  }
  match effects[8] {
    ClearRuntimeTracking("main.leaf") => ()
    _ => fail("expected ClearRuntimeTracking")
  }
}

///|
test "plan_post_tool_actions - merge_pr" {
  let poller = @poller.PollerState::new()
  let registry = @registry.AgentRegistry::new()
  let project_dir = "/tmp/choir-post-tool-merge"
  let terminal_session = "s"
  let pr_number = 42
  let agent_id = "main.leaf"
  poller.track(pr_number, agent_id, "branch", "main", "url", 0L)
  let agent : @types.Agent = {
    agent_id: @types.AgentId(agent_id),
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Gemini,
    parent: Some("parent"),
    workspace: "dir",
    branch: "branch",
    terminal_target: None,
    host: @types.Host::Local,
    state: @types.AgentState::Active,
    spawn_depth: 0,
  }
  ignore(registry.upsert(agent))
  let req : @types.Request = {
    req_method: "tools/call",
    role: @types.Role::TL,
    name: "merge_pr",
    args: @types.RequestArgs::new({ "pr_number": pr_number.to_string() }),
  }
  let resp = @types.Response::Ok(
    @types.ResponseFields::new({ "status": "merged" }),
  )
  let effects = plan_post_tool_actions(
    req,
    resp,
    merged_agent_id=Some(agent_id),
    poller,
    registry,
    project_dir,
    terminal_session,
  )
  assert_eq(effects.length(), 7)

  match effects[0] {
    UpdateDevLifecycle(
      agent_id=aid,
      event=@phase.DevEvent::MergeObserved(pr_number=n)
    ) => {
      assert_eq(aid, agent_id)
      assert_eq(n, pr_number)
    }
    _ => fail("expected UpdateDevLifecycle")
  }

  match effects[1] {
    DeliverToParentMerged(
      leaf_id=aid,
      pr_number=n,
      branch="branch",
      parent_branch="main",
      url="url"
    ) => {
      assert_eq(aid, agent_id)
      assert_eq(n, pr_number)
    }
    _ => fail("expected DeliverToParentMerged")
  }

  match effects[2] {
    PersistLifecycle(agent_id=aid, trigger="merged", ..) =>
      assert_eq(aid, agent_id)
    _ => fail("expected PersistLifecycle(Finalizing merged)")
  }
  match effects[3] {
    FireHook(agent_id=aid, exit_reason="merged", ..) => assert_eq(aid, agent_id)
    _ => fail("expected FireHook")
  }
  match effects[4] {
    PersistLifecycle(agent_id=aid, trigger="FinalizeComplete", ..) =>
      assert_eq(aid, agent_id)
    _ => fail("expected PersistLifecycle(Finalized)")
  }
  match effects[5] {
    SyncParentLifecycle(agent_id=aid, ..) => assert_eq(aid, agent_id)
    _ => fail("expected SyncParentLifecycle")
  }
  match effects[6] {
    ClearRuntimeTracking(aid) => assert_eq(aid, agent_id)
    _ => fail("expected ClearRuntimeTracking")
  }
}

///|
test "plan_post_tool_actions - kill_agent" {
  let poller = @poller.PollerState::new()
  let registry = @registry.AgentRegistry::new()
  let project_dir = "/tmp/choir-post-tool-kill"
  let terminal_session = "s"
  let parent_id = "parent"
  let parent : @types.Agent = {
    agent_id: @types.AgentId(parent_id),
    role: @types.Role::TL,
    agent_type: @types.AgentType::Claude,
    parent: None,
    workspace: project_dir,
    branch: "main",
    terminal_target: Some({
      kind: @types.TargetKind::ZellijPane,
      session: "s",
      name: "tl",
    }),
    host: @types.Host::Local,
    state: @types.AgentState::Active,
    spawn_depth: 0,
  }
  let agent : @types.Agent = {
    agent_id: @types.AgentId("main.leaf"),
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Gemini,
    parent: Some(parent_id),
    workspace: project_dir,
    branch: "work",
    terminal_target: None,
    host: @types.Host::Local,
    state: @types.AgentState::Active,
    spawn_depth: 0,
  }
  ignore(registry.upsert(parent))
  ignore(registry.upsert(agent))
  let req : @types.Request = {
    req_method: "tools/call",
    role: @types.Role::TL,
    name: "kill_agent",
    args: @types.RequestArgs::new({ "agent_id": "main.leaf" }),
  }
  let resp = @types.Response::Ok(
    @types.ResponseFields::new({ "status": "killed" }),
  )
  let effects = plan_post_tool_actions(
    req,
    resp,
    merged_agent_id=None,
    poller,
    registry,
    project_dir,
    terminal_session,
  )
  assert_eq(effects.length(), 5)
  match effects[0] {
    FireHook(agent_id="main.leaf", exit_reason="killed", ..) => ()
    _ => fail("expected FireHook")
  }
  match effects[1] {
    PersistLifecycle(agent_id="main.leaf", trigger="killed", ..) => ()
    _ => fail("expected PersistLifecycle(Failed)")
  }
  match effects[2] {
    SyncParentLifecycle(agent_id="main.leaf", ..) => ()
    _ => fail("expected SyncParentLifecycle")
  }
  match effects[3] {
    NotifyParent(
      parent_id="parent",
      agent_id="main.leaf",
      message="agent killed by parent",
      status="failure"
    ) => ()
    _ => fail("expected NotifyParent")
  }
  match effects[4] {
    ClearRuntimeTracking("main.leaf") => ()
    _ => fail("expected ClearRuntimeTracking")
  }
}

///|
test "plan_post_tool_actions - kill_agent missing agent clears runtime only" {
  let poller = @poller.PollerState::new()
  let registry = @registry.AgentRegistry::new()
  let project_dir = "/tmp/choir-post-tool-kill-miss"
  let terminal_session = "s"
  let req : @types.Request = {
    req_method: "tools/call",
    role: @types.Role::TL,
    name: "kill_agent",
    args: @types.RequestArgs::new({ "agent_id": "main.leaf" }),
  }
  let resp = @types.Response::Ok(
    @types.ResponseFields::new({ "status": "killed" }),
  )
  let effects = plan_post_tool_actions(
    req,
    resp,
    merged_agent_id=None,
    poller,
    registry,
    project_dir,
    terminal_session,
  )
  assert_eq(effects.length(), 1)
  match effects[0] {
    ClearRuntimeTracking("main.leaf") => ()
    _ => fail("expected ClearRuntimeTracking")
  }
}

///|
test "plan_post_tool_actions - watch pane" {
  let poller = @poller.PollerState::new()
  let registry = @registry.AgentRegistry::new()
  let project_dir = "/tmp/choir-post-tool-watch"
  let terminal_session = "s"
  let req : @types.Request = {
    req_method: "tools/call",
    role: @types.Role::TL,
    name: "fork_wave",
    args: @types.RequestArgs::new({ "tasks": "[\"a\"]" }),
  }
  let resp = @types.Response::Ok(
    @types.ResponseFields::new({ "agent_ids": "leaf-1,leaf-2" }),
  )
  let effects = plan_post_tool_actions(
    req,
    resp,
    merged_agent_id=None,
    poller,
    registry,
    project_dir,
    terminal_session,
  )
  assert_eq(effects.length(), 2)
  match effects[0] {
    WatchPane(agent_id="leaf-1") => ()
    _ => fail("expected WatchPane leaf-1")
  }
  match effects[1] {
    WatchPane(agent_id="leaf-2") => ()
    _ => fail("expected WatchPane leaf-2")
  }
}

///|
test "merged_pr_parent_message is distinct from pre-merge signals" {
  let msg = merged_pr_parent_message(
    42, "main.leaf-z", "feat/z", "main", "https://github.com/o/r/pull/42",
  )
  assert_true(msg.contains("[PR MERGED]"))
  assert_true(msg.contains("merge_pr succeeded"))
  assert_true(msg.contains("PR #42"))
  assert_true(msg.contains("main.leaf-z"))
  assert_true(msg.contains("feat/z"))
  assert_true(msg.contains("parent_branch: main"))
  assert_true(msg.contains("pr_url: https://github.com/o/r/pull/42"))
  assert_true(msg.contains("[PR READY]"))
  assert_true(msg.contains("[FIXES PUSHED]"))
}

///|
test "merged_pr_parent_message uses unknown when branch or parent_branch missing" {
  let msg = merged_pr_parent_message(3, "leaf", "", "", "")
  assert_true(msg.contains("branch: <unknown>"))
  assert_true(msg.contains("parent_branch: <unknown>"))
  assert_false(msg.contains("pr_url:"))
}
