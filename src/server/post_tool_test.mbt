///|
test "plan_post_tool_actions - shutdown" {
  let poller = @poller.PollerState::new()
  let registry = @registry.AgentRegistry::new()
  let req : @types.Request = {
    req_method: "tools/call",
    role: @types.Role::Dev,
    name: "shutdown",
    args: @types.RequestArgs::new({ "agent_id": "main.leaf" }),
  }
  let resp = @types.Response::Ok(
    @types.ResponseFields::new({ "status": "shutdown" }),
  )
  let actions = plan_post_tool_actions(
    req,
    resp,
    merged_agent_id=None,
    poller,
    registry,
  )
  assert_eq(actions.length(), 1)
  match actions[0] {
    FinalizeAgent(
      agent_id="main.leaf",
      exit_reason="shutdown",
      notify_parent=true
    ) => ()
    _ => fail("expected FinalizeAgent")
  }
}

///|
test "plan_post_tool_actions - merge_pr" {
  let poller = @poller.PollerState::new()
  let registry = @registry.AgentRegistry::new()
  let pr_number = 42
  let agent_id = "main.leaf"
  poller.track(pr_number, agent_id, "branch", "main", "url", 0L)
  let agent : @types.Agent = {
    agent_id,
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
  let actions = plan_post_tool_actions(
    req,
    resp,
    merged_agent_id=Some(agent_id),
    poller,
    registry,
  )
  assert_eq(actions.length(), 3)

  // UpdateDevLifecycle
  match actions[0] {
    UpdateDevLifecycle(
      agent_id=aid,
      event=@phase.DevEvent::MergeObserved(pr_number=n)
    ) => {
      assert_eq(aid, agent_id)
      assert_eq(n, pr_number)
    }
    _ => fail("expected UpdateDevLifecycle")
  }

  // DeliverToParentMerged
  match actions[1] {
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

  // FinalizeAgent
  match actions[2] {
    FinalizeAgent(agent_id=aid, exit_reason="merged", notify_parent=false) => {
      assert_eq(aid, agent_id)
      assert_eq(aid, "main.leaf")
    }
    _ => fail("expected FinalizeAgent")
  }
}

///|
test "plan_post_tool_actions - kill_agent" {
  let poller = @poller.PollerState::new()
  let registry = @registry.AgentRegistry::new()
  let req : @types.Request = {
    req_method: "tools/call",
    role: @types.Role::TL,
    name: "kill_agent",
    args: @types.RequestArgs::new({ "agent_id": "main.leaf" }),
  }
  let resp = @types.Response::Ok(
    @types.ResponseFields::new({ "status": "killed" }),
  )
  let actions = plan_post_tool_actions(
    req,
    resp,
    merged_agent_id=None,
    poller,
    registry,
  )
  assert_eq(actions.length(), 1)
  match actions[0] {
    FailAgent(
      agent_id="main.leaf",
      reason=@phase.FailureReason::ParentKilled,
      parent_message="agent killed by parent",
      exit_reason="killed",
      close_target=false
    ) => ()
    _ => fail("expected FailAgent")
  }
}

///|
test "plan_post_tool_actions - watch pane" {
  let poller = @poller.PollerState::new()
  let registry = @registry.AgentRegistry::new()
  let req : @types.Request = {
    req_method: "tools/call",
    role: @types.Role::TL,
    name: "fork_wave",
    args: @types.RequestArgs::new({ "tasks": "[\"a\"]" }),
  }
  let resp = @types.Response::Ok(
    @types.ResponseFields::new({ "agent_ids": "leaf-1,leaf-2" }),
  )
  let actions = plan_post_tool_actions(
    req,
    resp,
    merged_agent_id=None,
    poller,
    registry,
  )
  assert_eq(actions.length(), 2)
  match actions[0] {
    WatchPane(agent_id="leaf-1") => ()
    _ => fail("expected WatchPane leaf-1")
  }
  match actions[1] {
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
