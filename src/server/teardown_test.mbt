///|
fn count_remove_worktree(
  effects : Array[TeardownEffect],
  path? : String = "",
) -> Int {
  let mut c = 0
  for e in effects {
    match e {
      RemoveWorktree(p) => if path == "" || p == path { c = c + 1 }
      _ => ()
    }
  }
  c
}

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
    @types.ExitReason::Shutdown,
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
    PersistLifecycle(
      agent_id="main.leaf",
      trigger=@types.LifecycleTrigger::ExitShutdown,
      ..
    ) => ()
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
      status=@types.Status::Success
    ) => ()
    _ => fail("expected NotifyParent")
  }
  match effects[3] {
    FireHook(agent_id="main.leaf", exit_reason=@types.ExitReason::Shutdown, ..) =>
      ()
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
    PersistLifecycle(
      agent_id="main.leaf",
      trigger=@types.LifecycleTrigger::FinalizeComplete,
      ..
    ) => ()
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
    @types.ExitReason::Disconnected,
    Some(parent),
    close_target=true,
  )

  // 1. FireHook
  // 2. RemoveWorktree
  // 3. CloseTerminal
  // 4. PersistLifecycle (Failed)
  // 5. SyncParentLifecycle
  // 6. NotifyParent
  // 7. ParentFailureTerminalEchoIfNeeded (no extra inject: primary delivery is terminal)
  // 8. ClearRuntimeTracking

  assert_eq(effects.length(), 8)
  match effects[0] {
    FireHook(
      agent_id="main.leaf",
      exit_reason=@types.ExitReason::Disconnected,
      ..
    ) => ()
    _ => fail("expected FireHook")
  }
  match effects[1] {
    RemoveWorktree("/tmp/.choir/worktrees/main.leaf") => ()
    _ => fail("expected RemoveWorktree")
  }
  match effects[2] {
    CloseTerminal(_) => ()
    _ => fail("expected CloseTerminal")
  }
  match effects[3] {
    PersistLifecycle(
      agent_id="main.leaf",
      trigger=@types.LifecycleTrigger::ExitDisconnected,
      ..
    ) => ()
    _ => fail("expected PersistLifecycle(Failed)")
  }
  match effects[4] {
    SyncParentLifecycle(agent_id="main.leaf", ..) => ()
    _ => fail("expected SyncParentLifecycle")
  }
  match effects[5] {
    NotifyParent(
      parent_id="parent",
      agent_id="main.leaf",
      message="watchdog timeout",
      status=@types.Status::Failure
    ) => ()
    _ => fail("expected NotifyParent")
  }
  match effects[6] {
    ParentFailureTerminalEchoIfNeeded(
      parent_id="parent",
      agent_id="main.leaf",
      parent_message="watchdog timeout",
      reason=@phase.FailureReason::WatchdogTimeout
    ) => ()
    _ => fail("expected ParentFailureTerminalEchoIfNeeded")
  }
  match effects[7] {
    ClearRuntimeTracking("main.leaf") => ()
    _ => fail("expected ClearRuntimeTracking")
  }
}

///|
test "plan_fail does not remove root checkout worker workspace" {
  let agent : @types.Agent = {
    agent_id: @types.AgentId("main.worker"),
    role: @types.Role::Worker,
    agent_type: @types.AgentType::Claude,
    parent: Some("main.leaf"),
    workspace: "/repo/.",
    branch: "main",
    terminal_target: Some({
      kind: @types.TargetKind::ZellijPane,
      session: "s",
      name: "worker",
    }),
    host: @types.Host::Local,
    state: @types.AgentState::Active,
    spawn_depth: 1,
  }
  let lifecycle = @phase.lifecycle_for_agent(agent)
  let effects = plan_fail(
    agent,
    lifecycle,
    @phase.FailureReason::ParentKilled,
    "parent killed",
    @types.ExitReason::Disconnected,
    None,
    close_target=true,
  )

  assert_false(@types.is_choir_managed_worktree_path("/repo", agent.workspace))
  assert_false(@types.is_choir_managed_worktree_path(".", agent.workspace))
  assert_eq(count_remove_worktree(effects), 0)
}

///|
test "plan_finalize failed early return removes managed worktree" {
  let worktree = "/tmp/.choir/worktrees/main.failed-leaf"
  let agent : @types.Agent = {
    agent_id: @types.AgentId("main.failed-leaf"),
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Gemini,
    parent: Some("main.tl"),
    workspace: worktree,
    branch: "failed-branch",
    terminal_target: None,
    host: @types.Host::Local,
    state: @types.AgentState::Failed,
    spawn_depth: 0,
  }
  let lifecycle : @phase.AgentLifecycle = {
    ..@phase.lifecycle_for_agent(agent),
    process: @phase.ProcessState::Failed(
      reason=@phase.FailureReason::NeverRegistered,
    ),
    workflow: @phase.WorkflowState::Dev(
      @phase.DevLifecycle::Failed(reason=@phase.FailureReason::NeverRegistered),
    ),
  }
  let effects = plan_finalize(
    agent,
    lifecycle,
    @types.ExitReason::Disconnected,
    notify_parent=false,
    close_target=false,
    remove_worktree=true,
  )

  @debug.assert_eq(effects, [
    RemoveWorktree(worktree),
    ClearRuntimeTracking("main.failed-leaf"),
  ])
}

///|
test "plan_finalize merge path emits one managed worktree removal" {
  let worktree = "/tmp/.choir/worktrees/main.merged-leaf"
  let agent : @types.Agent = {
    agent_id: @types.AgentId("main.merged-leaf"),
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Gemini,
    parent: Some("main.tl"),
    workspace: worktree,
    branch: "merged-branch",
    terminal_target: None,
    host: @types.Host::Local,
    state: @types.AgentState::Active,
    spawn_depth: 0,
  }
  let lifecycle = @phase.lifecycle_for_agent(agent)
  let effects = plan_finalize(
    agent,
    lifecycle,
    @types.ExitReason::Merged,
    notify_parent=false,
    close_target=false,
    remove_worktree=true,
  )

  assert_eq(count_remove_worktree(effects, path=worktree), 1)
}
