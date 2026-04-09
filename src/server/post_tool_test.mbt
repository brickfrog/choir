///|
fn isolated_post_tool_project_dir(slug : String) -> String {
  "/tmp/choir-post-tool-" +
  slug +
  "-" +
  @sys.get_pid().to_string() +
  "-" +
  @env.now().reinterpret_as_int64().to_string()
}

///|
fn last_is_clear_runtime_for(
  effects : Array[TeardownEffect],
  agent_id : String,
) -> Bool {
  let n = effects.length()
  if n == 0 {
    return false
  }
  match effects[n - 1] {
    ClearRuntimeTracking(aid) => aid == agent_id
    _ => false
  }
}

///|
fn count_persist_with_trigger(
  effects : Array[TeardownEffect],
  trigger : @types.LifecycleTrigger,
) -> Int {
  let mut c = 0
  for e in effects {
    match e {
      PersistLifecycle(trigger=t, ..) => if t == trigger { c = c + 1 }
      _ => ()
    }
  }
  c
}

///|
fn has_fire_hook_exit(
  effects : Array[TeardownEffect],
  agent_id : String,
  exit_reason : @types.ExitReason,
) -> Bool {
  for e in effects {
    match e {
      FireHook(agent_id=aid, exit_reason=er, ..) =>
        if aid == agent_id && er == exit_reason {
          return true
        }
      _ => ()
    }
  }
  false
}

///|
test "plan_post_tool_actions - shutdown without registered agent clears runtime only" {
  let poller = @poller.PollerState::new()
  let registry = @registry.AgentRegistry::new()
  let project_dir = isolated_post_tool_project_dir("sd-miss")
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
  assert_true(last_is_clear_runtime_for(effects, "main.leaf"))
  assert_eq(effects.length(), 1)
}

///|
test "plan_post_tool_actions - shutdown with agent yields finalize teardown shape" {
  let poller = @poller.PollerState::new()
  let registry = @registry.AgentRegistry::new()
  let project_dir = isolated_post_tool_project_dir("sd-reg")
  let terminal_session = "s"
  let worktree_path = project_dir + "/.choir/worktrees/main.leaf"
  let agent : @types.Agent = {
    agent_id: @types.AgentId("main.leaf"),
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Gemini,
    parent: Some("parent"),
    workspace: worktree_path,
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
  assert_true(last_is_clear_runtime_for(effects, "main.leaf"))
  assert_eq(
    count_persist_with_trigger(effects, @types.LifecycleTrigger::ExitShutdown),
    1,
  )
  assert_eq(
    count_persist_with_trigger(
      effects,
      @types.LifecycleTrigger::FinalizeComplete,
    ),
    1,
  )
  assert_true(
    has_fire_hook_exit(effects, "main.leaf", @types.ExitReason::Shutdown),
  )
  let mut saw_remove_worktree = false
  for e in effects {
    match e {
      RemoveWorktree(path) =>
        if path == worktree_path {
          saw_remove_worktree = true
        }
      _ => ()
    }
  }
  assert_true(saw_remove_worktree)
  assert_true(effects.length() >= 7)
}

///|
test "plan_post_tool_actions - merge_pr effect shape and ordering" {
  let poller = @poller.PollerState::new()
  let registry = @registry.AgentRegistry::new()
  let project_dir = isolated_post_tool_project_dir("merge")
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
  assert_true(last_is_clear_runtime_for(effects, agent_id))
  assert_true(effects.length() >= 3)
  match effects[0] {
    UpdateDevLifecycle(
      agent_id=aid,
      event=@phase.DevEvent::MergeObserved(pr_number=n)
    ) => {
      assert_eq(aid, agent_id)
      assert_eq(n, pr_number)
    }
    _ => fail("first effect must be UpdateDevLifecycle(MergeObserved)")
  }
  let mut merge_deliver_idx : Int? = None
  let mut i = 0
  for e in effects {
    match e {
      DeliverToParentMerged(
        leaf_id=aid,
        pr_number=n,
        branch="branch",
        parent_branch="main",
        url="url",
        parent_id=Some("parent")
      ) => {
        assert_eq(aid, agent_id)
        assert_eq(n, pr_number)
        merge_deliver_idx = Some(i)
      }
      _ => ()
    }
    i = i + 1
  }
  match merge_deliver_idx {
    Some(idx) => {
      assert_true(idx > 0)
      assert_true(idx < effects.length() - 1)
    }
    None => fail("expected DeliverToParentMerged")
  }
  assert_eq(
    count_persist_with_trigger(effects, @types.LifecycleTrigger::ExitMerged),
    1,
  )
  assert_eq(
    count_persist_with_trigger(
      effects,
      @types.LifecycleTrigger::FinalizeComplete,
    ),
    1,
  )
  assert_true(has_fire_hook_exit(effects, agent_id, @types.ExitReason::Merged))
}

///|
test "plan_post_tool_actions - kill_agent failure chain" {
  let poller = @poller.PollerState::new()
  let registry = @registry.AgentRegistry::new()
  let project_dir = isolated_post_tool_project_dir("kill")
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
  assert_true(last_is_clear_runtime_for(effects, "main.leaf"))
  assert_true(
    has_fire_hook_exit(effects, "main.leaf", @types.ExitReason::Shutdown),
  )
  assert_eq(
    count_persist_with_trigger(effects, @types.LifecycleTrigger::ExitShutdown),
    1,
  )
  let mut saw_notify = false
  let mut saw_echo_slot = false
  for e in effects {
    match e {
      NotifyParent(
        parent_id="parent",
        agent_id="main.leaf",
        message="agent killed by parent",
        status=@types.Status::Failure
      ) => saw_notify = true
      ParentFailureTerminalEchoIfNeeded(
        parent_id="parent",
        agent_id="main.leaf",
        parent_message="agent killed by parent",
        reason=@phase.FailureReason::ParentKilled
      ) => saw_echo_slot = true
      _ => ()
    }
  }
  assert_true(saw_notify)
  assert_true(saw_echo_slot)
}

///|
test "plan_post_tool_actions - kill_agent missing agent clears runtime only" {
  let poller = @poller.PollerState::new()
  let registry = @registry.AgentRegistry::new()
  let project_dir = isolated_post_tool_project_dir("kill-miss")
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
  assert_true(last_is_clear_runtime_for(effects, "main.leaf"))
  assert_eq(effects.length(), 1)
}

///|
test "plan_post_tool_actions - watch pane ids from response" {
  let poller = @poller.PollerState::new()
  let registry = @registry.AgentRegistry::new()
  let project_dir = isolated_post_tool_project_dir("watch")
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

///|
test "plan_post_tool_actions includes RefreshPR for resolve_review_thread success" {
  let project_dir = isolated_post_tool_project_dir("resolve-refresh")
  let terminal_session = "test-session"
  let poller = @poller.PollerState::new()
  let registry = @registry.AgentRegistry::new()

  let agent_id = "main.dev"
  let pr_number = 123
  poller.track(
    pr_number, agent_id, "work", "main", "https://github.com/o/r/pull/123", 100L,
  )

  let req = @types.Request::{
    req_method: "tools/call",
    role: @types.Role::Dev,
    name: "resolve_review_thread",
    args: @types.RequestArgs::new({ "thread_id": "T1", "caller_id": agent_id }),
  }
  let resp = @types.Response::ok_values({})

  let effects = plan_post_tool_actions(
    req,
    resp,
    merged_agent_id=None,
    poller,
    registry,
    project_dir,
    terminal_session,
  )

  let mut found_refresh = false
  for effect in effects {
    match effect {
      RefreshPR(n) => if n == pr_number { found_refresh = true }
      _ => ()
    }
  }
  assert_true(found_refresh)
}

///|
test "plan_post_tool_actions includes all RefreshPR for resolve_review_thread success" {
  let project_dir = isolated_post_tool_project_dir("resolve-refresh-multi")
  let terminal_session = "test-session"
  let poller = @poller.PollerState::new()
  let registry = @registry.AgentRegistry::new()

  let agent_id = "main.dev"
  poller.track(123, agent_id, "work", "main", "url1", 100L)
  poller.track(456, agent_id, "work", "main", "url2", 100L)

  let req = @types.Request::{
    req_method: "tools/call",
    role: @types.Role::Dev,
    name: "resolve_review_thread",
    args: @types.RequestArgs::new({ "thread_id": "T1", "caller_id": agent_id }),
  }
  let resp = @types.Response::ok_values({})

  let effects = plan_post_tool_actions(
    req,
    resp,
    merged_agent_id=None,
    poller,
    registry,
    project_dir,
    terminal_session,
  )

  let refreshed = []
  for effect in effects {
    match effect {
      RefreshPR(n) => refreshed.push(n)
      _ => ()
    }
  }
  assert_eq(refreshed.length(), 2)
  assert_true(refreshed.contains(123))
  assert_true(refreshed.contains(456))
}
