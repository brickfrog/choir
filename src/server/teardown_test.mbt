///|
test "plan_finalize - basic success" {
  let agent_id = "main.leaf"
  let agent : @types.Agent = {
    agent_id: @types.AgentId(agent_id),
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
  let lifecycle = @phase.lifecycle_for_agent(agent)
  let effects = plan_finalize(
    agent,
    lifecycle,
    "shutdown",
    notify_parent=true,
    close_target=true,
    remove_worktree=true,
  )

  // Verify effects:
  // 1. PersistLifecycle (Finalizing)
  // 2. RemoveTeamMember
  // 3. NotifyParent
  // 4. FireHook
  // 5. RemoveWorktree
  // 6. CloseTerminal
  // 7. PersistLifecycle (Finalized)
  // 8. SyncParentLifecycle
  // 9. ClearRuntimeTracking

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
test "plan_fail - basic failure" {
  let agent_id = "main.leaf"
  let parent_id = "parent"
  let agent : @types.Agent = {
    agent_id: @types.AgentId(agent_id),
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Gemini,
    parent: Some(parent_id),
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
  let parent : @types.Agent = {
    agent_id: @types.AgentId(parent_id),
    role: @types.Role::TL,
    agent_type: @types.AgentType::Claude,
    parent: None,
    workspace: "/tmp/.choir",
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
  let lifecycle = @phase.lifecycle_for_agent(agent)
  let effects = plan_fail(
    agent,
    lifecycle,
    @phase.FailureReason::WatchdogTimeout,
    "watchdog timeout",
    "disconnect",
    Some(parent),
    close_target=true,
  )

  // 1. FireHook
  // 2. CloseTerminal
  // 3. PersistLifecycle (Failed)
  // 4. SyncParentLifecycle
  // 5. NotifyParent
  // 6. ParentFailureTerminalEchoIfNeeded (no extra inject: primary delivery is terminal)
  // 7. ClearRuntimeTracking

  assert_eq(effects.length(), 7)
  match effects[0] {
    FireHook(agent_id="main.leaf", exit_reason="disconnect", ..) => ()
    _ => fail("expected FireHook")
  }
  match effects[1] {
    CloseTerminal(_) => ()
    _ => fail("expected CloseTerminal")
  }
  match effects[2] {
    PersistLifecycle(agent_id="main.leaf", trigger="disconnect", ..) => ()
    _ => fail("expected PersistLifecycle(Failed)")
  }
  match effects[3] {
    SyncParentLifecycle(agent_id="main.leaf", ..) => ()
    _ => fail("expected SyncParentLifecycle")
  }
  match effects[4] {
    NotifyParent(
      parent_id="parent",
      agent_id="main.leaf",
      message="watchdog timeout",
      status="failure"
    ) => ()
    _ => fail("expected NotifyParent")
  }
  match effects[5] {
    ParentFailureTerminalEchoIfNeeded(
      parent_id="parent",
      agent_id="main.leaf",
      parent_message="watchdog timeout",
      reason=@phase.FailureReason::WatchdogTimeout
    ) => ()
    _ => fail("expected ParentFailureTerminalEchoIfNeeded")
  }
  match effects[6] {
    ClearRuntimeTracking("main.leaf") => ()
    _ => fail("expected ClearRuntimeTracking")
  }
}
