///|
fn rescue_leaf_base_args() -> RescueLeafArgs {
  {
    task: "continue",
    task_contract: { ..@types.TaskContract::empty(), goal: "continue" },
    caller_id: "main.tl",
    from_agent_id: "main.old-leaf",
    new_slug: "new-leaf",
    agent_type: @types.AgentType::MoonPilot,
    parent_session_id: None,
  }
}

///|
fn rescue_leaf_ok_dev(
  from_agent_id : String,
  workspace : String,
  branch : String,
) -> @types.Agent {
  {
    agent_id: @types.AgentId(from_agent_id),
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Claude,
    parent: Some("main.tl"),
    workspace,
    branch,
    terminal_target: None,
    host: @types.Host::Local,
    spawn_depth: 0,
    state: @types.AgentState::Active,
  }
}

///|
test "rescue_leaf_spawn_plan builds reuse spec and ids" {
  let args = rescue_leaf_base_args()
  let from_agent = rescue_leaf_ok_dev(
    "main.old-leaf", "/proj/.choir/worktrees/old-leaf-0", "main.old-leaf",
  )
  let got = rescue_leaf_spawn_plan(args, from_agent)
  match got {
    Ok(plan) => {
      assert_eq(plan.from_agent_id, "main.old-leaf")
      assert_eq(plan.to_id, "main.new-leaf")
      assert_eq(plan.salvage_slug, "old-leaf")
      assert_eq(plan.git_branch, "main.old-leaf")
      assert_eq(plan.spec.slug, "new-leaf")
      assert_eq(plan.spec.parent_branch, "main")
      assert_eq(plan.spec.parent_id, "main.tl")
      assert_eq(plan.spec.reuse_workspace, true)
      @debug.assert_eq(plan.spec.workspace_slug, Some("old-leaf"))
      @debug.assert_eq(plan.spec.reuse_git_branch, Some("main.old-leaf"))
      assert_eq(plan.spec.agent_type, @types.AgentType::MoonPilot)
      assert_eq(plan.spec.spawn_depth, 0)
    }
    Err(e) => fail("expected Ok got " + e.message())
  }
}

///|
test "rescue_leaf_spawn_plan uses from_agent_id when branch empty" {
  let args = rescue_leaf_base_args()
  let from_agent = rescue_leaf_ok_dev(
    "main.old-leaf", "/proj/.choir/worktrees/old-leaf-0", "",
  )
  match rescue_leaf_spawn_plan(args, from_agent) {
    Ok(plan) => assert_eq(plan.git_branch, "main.old-leaf")
    Err(e) => fail(e.message())
  }
}

///|
test "rescue_leaf_spawn_plan err non-dev role" {
  let args = rescue_leaf_base_args()
  let dev = rescue_leaf_ok_dev("main.old-leaf", "/proj/.choir/worktrees/x", "b")
  let non_dev = { ..dev, role: @types.Role::TL }
  match rescue_leaf_spawn_plan(args, non_dev) {
    Err(e) =>
      assert_eq(
        e.message(),
        @types.ChoirError::validation_error(
          "rescue_leaf only supports dev leaves",
        ).message(),
      )
    Ok(_) => fail("expected Err")
  }
}

///|
test "rescue_leaf_spawn_plan err parent mismatch" {
  let args = rescue_leaf_base_args()
  let from_agent = rescue_leaf_ok_dev(
    "main.old-leaf", "/proj/.choir/worktrees/x", "b",
  )
  match rescue_leaf_spawn_plan(args, { ..from_agent, parent: Some("other") }) {
    Err(e) =>
      assert_eq(
        e.message(),
        @types.ChoirError::validation_error(
          "caller_id must match the salvaged leaf parent",
        ).message(),
      )
    Ok(_) => fail("expected Err")
  }
}

///|
test "rescue_leaf_spawn_plan err no parent" {
  let args = rescue_leaf_base_args()
  let from_agent = rescue_leaf_ok_dev(
    "main.old-leaf", "/proj/.choir/worktrees/x", "b",
  )
  match rescue_leaf_spawn_plan(args, { ..from_agent, parent: None }) {
    Err(e) =>
      assert_eq(
        e.message(),
        @types.ChoirError::validation_error(
          "salvaged leaf has no parent in registry",
        ).message(),
      )
    Ok(_) => fail("expected Err")
  }
}

///|
test "rescue_leaf_spawn_plan err no choir worktree path" {
  let args = rescue_leaf_base_args()
  let from_agent = rescue_leaf_ok_dev("main.old-leaf", "/proj/other", "b")
  match rescue_leaf_spawn_plan(args, from_agent) {
    Err(e) =>
      assert_eq(
        e.message(),
        @types.ChoirError::validation_error(
          "salvaged leaf has no choir worktree path to reuse",
        ).message(),
      )
    Ok(_) => fail("expected Err")
  }
}

///|
test "rescue_leaf_spawn_plan err invalid from_agent_id" {
  let args = { ..rescue_leaf_base_args(), from_agent_id: "mainleaf" }
  let from_agent = rescue_leaf_ok_dev(
    "mainleaf", "/proj/.choir/worktrees/x", "b",
  )
  match rescue_leaf_spawn_plan(args, from_agent) {
    Err(e) =>
      assert_eq(
        e.message(),
        @types.ChoirError::validation_error(
          "invalid from_agent_id (expected nested branch like parent.child)",
        ).message(),
      )
    Ok(_) => fail("expected Err")
  }
}

///|
test "rescue_leaf_remove_supervisor_alias matches slug inequality" {
  assert_true(rescue_leaf_remove_supervisor_alias("a", "main.a"))
  assert_false(rescue_leaf_remove_supervisor_alias("main.leaf", "main.leaf"))
}

///|
test "rescue_leaf_ok_response matches spawned envelope" {
  match rescue_leaf_ok_response("main.new", "main.old", "new") {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      @debug.assert_eq(map.get("status"), Some(String::to_json("spawned")))
      @debug.assert_eq(map.get("agent_id"), Some(String::to_json("main.new")))
      @debug.assert_eq(
        map.get("from_agent_id"),
        Some(String::to_json("main.old")),
      )
      @debug.assert_eq(map.get("slug"), Some(String::to_json("new")))
    }
    _ => fail("expected ok")
  }
}

///|
test "rescue_leaf_handoff_failure_message matches dispatch wording" {
  assert_eq(
    rescue_leaf_handoff_failure_message("e"),
    "rescue_leaf: replacement spawned but lifecycle handoff failed — manual repair may be needed: e",
  )
}

///|
test "rescue_leaf_superseded_persist_failure_message matches dispatch wording" {
  assert_eq(
    rescue_leaf_superseded_persist_failure_message("main.old"),
    "failed to persist superseded lifecycle for main.old",
  )
}

///|
test "rescue_leaf_post_spawn_host_steps ordering" {
  let steps = rescue_leaf_post_spawn_host_steps()
  assert_eq(steps.length(), 9)
  assert_eq(steps[0], RescueLeafPostSpawnHostStep::LifecycleHandoff)
  assert_eq(
    steps[1],
    RescueLeafPostSpawnHostStep::PollerTransferOwnerAndWriteState,
  )
  assert_eq(steps[2], RescueLeafPostSpawnHostStep::MarkSuperseded)
  assert_eq(steps[3], RescueLeafPostSpawnHostStep::RegistryRemoveOld)
  assert_eq(
    steps[4],
    RescueLeafPostSpawnHostStep::SupervisorRemoveChildFromAgent,
  )
  assert_eq(
    steps[5],
    RescueLeafPostSpawnHostStep::SupervisorRemoveChildAliasIfNeeded,
  )
  assert_eq(steps[6], RescueLeafPostSpawnHostStep::TeamRegisterMember)
  assert_eq(steps[7], RescueLeafPostSpawnHostStep::TlEventChildSpawned)
  assert_eq(steps[8], RescueLeafPostSpawnHostStep::PaneResolveAndUpsertTerminal)
}

///|
async test "interpret_rescue_leaf err when no registry" {
  let args = rescue_leaf_base_args()
  let got = interpret_rescue_leaf(
    args,
    "/tmp",
    "choir",
    mock_runner_all_ok,
    mock_capture_empty,
    None,
    None,
  )
  match got {
    @types.Response::Err(msg) =>
      assert_eq(msg, "agent registry unavailable for rescue_leaf")
    _ => fail("expected no-registry err")
  }
}

///|
async test "interpret_rescue_leaf err when no poller" {
  let reg = @registry.AgentRegistry::new()
  let args = rescue_leaf_base_args()
  let got = interpret_rescue_leaf(
    args,
    "/tmp",
    "choir",
    mock_runner_all_ok,
    mock_capture_empty,
    Some(reg),
    None,
  )
  match got {
    @types.Response::Err(msg) =>
      assert_eq(msg, "poller unavailable for rescue_leaf")
    _ => fail("expected no-poller err")
  }
}

///|
async test "interpret_rescue_leaf err when from_agent missing" {
  let reg = @registry.AgentRegistry::new()
  let ps = @poller.PollerState::new()
  let args = rescue_leaf_base_args()
  let got = interpret_rescue_leaf(
    args,
    "/tmp",
    "choir",
    mock_runner_all_ok,
    mock_capture_empty,
    Some(reg),
    Some(ps),
  )
  match got {
    @types.Response::Err(msg) =>
      assert_eq(msg, "agent not found: main.old-leaf")
    _ => fail("expected not-found err")
  }
}

///|
async test "interpret_rescue_leaf err when spawn plan rejects role" {
  let reg = @registry.AgentRegistry::new()
  let ps = @poller.PollerState::new()
  let tl = {
    ..rescue_leaf_ok_dev("main.old-leaf", "/proj/.choir/worktrees/x", "b"),
    role: @types.Role::TL,
  }
  ignore(reg.upsert(tl))
  let args = rescue_leaf_base_args()
  let got = interpret_rescue_leaf(
    args,
    "/tmp",
    "choir",
    mock_runner_all_ok,
    mock_capture_empty,
    Some(reg),
    Some(ps),
  )
  match got {
    @types.Response::Err(msg) =>
      assert_eq(
        msg,
        @types.ChoirError::validation_error(
          "rescue_leaf only supports dev leaves",
        ).message(),
      )
    _ => fail("expected spawn-plan err")
  }
}

///|
async test "interpret_rescue_leaf err when run_strict fails" {
  let reg = @registry.AgentRegistry::new()
  let ps = @poller.PollerState::new()
  let from_agent = rescue_leaf_ok_dev(
    "main.old-leaf", "/proj/.choir/worktrees/old-leaf-0", "main.old-leaf",
  )
  ignore(reg.upsert(from_agent))
  let args = rescue_leaf_base_args()
  let got = interpret_rescue_leaf(
    args,
    "/tmp",
    "choir",
    mock_runner_first_fails,
    mock_capture_empty,
    Some(reg),
    Some(ps),
  )
  match got {
    @types.Response::Err(msg) =>
      assert_true(msg.contains("failed") || msg.contains("status"))
    _ => fail("expected run_strict err")
  }
}

// ──────────────────────────────────────────────────────────────────
// fork_wave_spawn_plan enrichment tests
// ──────────────────────────────────────────────────────────────────

///|
