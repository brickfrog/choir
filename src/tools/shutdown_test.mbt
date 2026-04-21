///|
test "shutdown_missing_caller_response is best-effort ok" {
  let r = shutdown_missing_caller_response()
  match r {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      assert_eq(map.get("status"), Some(String::to_json("shutdown")))
    }
    _ => fail("expected ok")
  }
}

///|
test "shutdown_poller_block_message matches dispatch wording" {
  assert_eq(
    shutdown_poller_block_message(42),
    "cannot shutdown: PR #42 has changes requested — push fixes first",
  )
}

///|
test "shutdown_intent_remove_choir_worktree matches choir worktree paths" {
  assert_true(
    shutdown_intent_remove_choir_worktree("/repo/.choir/worktrees/foo"),
  )
  assert_false(shutdown_intent_remove_choir_worktree("/repo"))
}

///|
fn kill_agent_test_agent(
  terminal_target : @types.LocalTarget?,
  workspace : String,
) -> @types.Agent {
  {
    agent_id: @types.AgentId("main.leaf"),
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Claude,
    parent: None,
    workspace,
    branch: "main.leaf",
    terminal_target,
    host: @types.Host::Local,
    spawn_depth: 0,
    state: @types.AgentState::Active,
  }
}

///|
test "kill_agent_pane_close_command is none without terminal_target" {
  let a = kill_agent_test_agent(None, "/repo")
  assert_eq(kill_agent_pane_close_command(a), None)
}

///|
test "kill_agent_pane_close_command matches local_close_target" {
  let t = match @types.LocalTarget::parse("zellij-tab:choir:leaf") {
    Some(v) => v
    None => fail("expected parse")
  }
  let a = kill_agent_test_agent(Some(t), "/repo")
  let expected = @workspace.local_close_target(t)
  match kill_agent_pane_close_command(a) {
    Some(cmd) => {
      assert_eq(cmd.program, expected.program)
      assert_eq(cmd.args, expected.args)
    }
    None => fail("expected close command")
  }
}

///|
test "kill_agent_worktree_remove_command follows choir worktree path rule" {
  let a = kill_agent_test_agent(None, "/proj/.choir/worktrees/slug-0")
  match kill_agent_worktree_remove_command(a) {
    Some(cmd) => {
      assert_eq(cmd.program, "git")
      assert_eq(cmd.args, [
        "worktree", "remove", "--force", "/proj/.choir/worktrees/slug-0",
      ])
    }
    None => fail("expected worktree remove")
  }
  let no_wt = kill_agent_test_agent(None, "/proj")
  assert_eq(kill_agent_worktree_remove_command(no_wt), None)
}

///|
test "kill_agent_ok_response matches killed envelope" {
  match kill_agent_ok_response("main.topic") {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      assert_eq(map.get("status"), Some(String::to_json("killed")))
      assert_eq(map.get("agent_id"), Some(String::to_json("main.topic")))
    }
    _ => fail("expected ok")
  }
}

///|
test "kill_agent_adapter_host_steps is pane close, worktree remove, process-kill fallback" {
  let steps = kill_agent_adapter_host_steps()
  assert_eq(steps.length(), 3)
  assert_eq(steps[0], KillAgentAdapterHostStep::PaneClose)
  assert_eq(steps[1], KillAgentAdapterHostStep::WorktreeRemove)
  assert_eq(steps[2], KillAgentAdapterHostStep::ProcessKillFallback)
}

///|
async test "interpret_kill_agent err when no registry" {
  let args : KillAgentArgs = { agent_id: "main.x", reason: "r" }
  let got = interpret_kill_agent(args, None, mock_runner_all_ok)
  match got {
    @types.Response::Err(msg) => assert_eq(msg, "no agent registry available")
    _ => fail("expected no-registry err")
  }
}

///|
async test "interpret_kill_agent err when agent missing" {
  let reg = @registry.AgentRegistry::new()
  let args : KillAgentArgs = { agent_id: "main.missing", reason: "r" }
  let got = interpret_kill_agent(args, Some(reg), mock_runner_all_ok)
  match got {
    @types.Response::Err(msg) => assert_eq(msg, "agent not found: main.missing")
    _ => fail("expected not-found err")
  }
}

///|
async test "interpret_kill_agent closes pane, removes worktree, marks failed, returns killed" {
  let t = match @types.LocalTarget::parse("zellij-tab:choir:leaf") {
    Some(v) => v
    None => fail("expected parse")
  }
  let reg = @registry.AgentRegistry::new()
  let agent = kill_agent_test_agent(Some(t), "/proj/.choir/worktrees/slug-0")
  ignore(reg.upsert(agent))
  let args : KillAgentArgs = { agent_id: "main.leaf", reason: "cleanup" }
  let got = interpret_kill_agent(args, Some(reg), mock_runner_all_ok)
  match got {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      assert_eq(map.get("status"), Some(String::to_json("killed")))
      assert_eq(map.get("agent_id"), Some(String::to_json("main.leaf")))
    }
    _ => fail("expected ok")
  }
  try reg.get("main.leaf") catch {
    _ => fail("expected agent in registry")
  } noraise {
    a => assert_eq(a.state, @types.AgentState::Failed)
  }
}

///|
async test "interpret_kill_agent runs process-kill fallback after pane close and worktree remove" {
  let t = match @types.LocalTarget::parse("zellij-tab:choir:leaf") {
    Some(v) => v
    None => fail("expected parse")
  }
  let reg = @registry.AgentRegistry::new()
  let workspace = "/proj/.choir/worktrees/slug-0"
  let agent = kill_agent_test_agent(Some(t), workspace)
  ignore(reg.upsert(agent))
  let events : Array[String] = []
  let spy_runner = async fn(cmds : Array[@workspace.Command]) -> Array[Int] {
    @async.sleep(0)
    let statuses = []
    for cmd in cmds {
      let program = cmd.program
      let first_arg = if cmd.args.length() > 0 { cmd.args[0] } else { "" }
      events.push("run:" + program + " " + first_arg)
      statuses.push(0)
    }
    statuses
  }
  let spy_list_pids = fn(prefix : String) -> Array[Int] {
    events.push("list_pids:" + prefix)
    [4242, 4243]
  }
  let spy_kill_pid = fn(pid : Int) -> Unit {
    events.push("kill_pid:" + pid.to_string())
  }
  let args : KillAgentArgs = { agent_id: "main.leaf", reason: "cleanup" }
  let got = interpret_kill_agent(
    args,
    Some(reg),
    spy_runner,
    list_pids=spy_list_pids,
    kill_pid=spy_kill_pid,
  )
  match got {
    @types.Response::Ok(_) => ()
    _ => fail("expected ok")
  }
  // Expected sequence: close-target pane → git worktree remove → /proc scan → kill each victim.
  assert_eq(events.length(), 5)
  // Step 1: pane close (program is the choir exe, first arg is "zellij-action").
  assert_true(events[0].has_prefix("run:"))
  assert_true(events[0].contains("zellij-action"))
  // Step 2: git worktree remove.
  assert_eq(events[1], "run:git worktree")
  // Step 3: /proc scan with the agent's workspace.
  assert_eq(events[2], "list_pids:" + workspace)
  // Step 4/5: SIGTERM-SIGKILL sequence per PID, in scan order.
  assert_eq(events[3], "kill_pid:4242")
  assert_eq(events[4], "kill_pid:4243")
}

///|
async test "interpret_kill_agent still scans /proc when pane/worktree are absent" {
  let reg = @registry.AgentRegistry::new()
  let workspace = "/proj/not-a-choir-worktree"
  let agent = kill_agent_test_agent(None, workspace)
  ignore(reg.upsert(agent))
  let scanned : Array[String] = []
  let killed : Array[Int] = []
  let spy_list_pids = fn(prefix : String) -> Array[Int] {
    scanned.push(prefix)
    [99]
  }
  let spy_kill_pid = fn(pid : Int) -> Unit { killed.push(pid) }
  let args : KillAgentArgs = { agent_id: "main.leaf", reason: "cleanup" }
  let got = interpret_kill_agent(
    args,
    Some(reg),
    mock_runner_all_ok,
    list_pids=spy_list_pids,
    kill_pid=spy_kill_pid,
  )
  match got {
    @types.Response::Ok(_) => ()
    _ => fail("expected ok")
  }
  assert_eq(scanned, [workspace])
  assert_eq(killed, [99])
}

///|
async test "interpret_kill_agent pane-close warning reflects kill outcome" {
  let t = match @types.LocalTarget::parse("zellij-tab:choir:leaf") {
    Some(v) => v
    None => fail("expected parse")
  }
  let pane_close_fails = async fn(
    cmds : Array[@workspace.Command],
  ) -> Array[Int] {
    @async.sleep(0)
    let statuses = []
    for _ in cmds {
      statuses.push(1)
    }
    statuses
  }
  // Case A: pane close failed, no victims found → legacy warning.
  let reg_a = @registry.AgentRegistry::new()
  let agent_a = kill_agent_test_agent(Some(t), "/proj/.choir/worktrees/slug-0")
  ignore(reg_a.upsert(agent_a))
  let no_pids = fn(_p : String) -> Array[Int] { [] }
  let noop_kill = fn(_pid : Int) -> Unit {  }
  let args : KillAgentArgs = { agent_id: "main.leaf", reason: "r" }
  let got_a = interpret_kill_agent(
    args,
    Some(reg_a),
    pane_close_fails,
    list_pids=no_pids,
    kill_pid=noop_kill,
  )
  match got_a {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      match map.get("warning") {
        Some(w) =>
          assert_eq(
            w,
            String::to_json(
              "pane close failed — zellij tab/pane may still be open",
            ),
          )
        None => fail("expected warning on failed pane close")
      }
    }
    _ => fail("expected ok")
  }
  // Case B: pane close failed, but /proc fallback killed the process.
  let reg_b = @registry.AgentRegistry::new()
  let agent_b = kill_agent_test_agent(Some(t), "/proj/.choir/worktrees/slug-1")
  ignore(reg_b.upsert(agent_b))
  let some_pids = fn(_p : String) -> Array[Int] { [1234] }
  let got_b = interpret_kill_agent(
    args,
    Some(reg_b),
    pane_close_fails,
    list_pids=some_pids,
    kill_pid=noop_kill,
  )
  match got_b {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      match map.get("warning") {
        Some(w) =>
          assert_eq(
            w,
            String::to_json(
              "pane close failed — zellij tab/pane may still linger, but the agent process was killed",
            ),
          )
        None => fail("expected warning when pane close failed")
      }
    }
    _ => fail("expected ok")
  }
}

///|
test "shutdown_exit_plan blocked dev changes requested" {
  let lifecycle : @phase.AgentLifecycle = {
    agent_id: "main.l",
    role: @types.Role::Dev,
    process: @phase.ProcessState::Connected,
    workflow: @phase.WorkflowState::Dev(
      @phase.DevLifecycle::ChangesRequested(pr_number=3, next_round=1),
    ),
  }
  let plan = shutdown_exit_plan(lifecycle)
  assert_false(plan.apply_dev_exit_requested)
  assert_false(plan.attempt_worktree_cleanup)
  match plan.response {
    @types.Response::Err(msg) => assert_eq(msg, "Changes requested")
    _ => fail("expected Err")
  }
}

///|
test "shutdown_exit_plan deferred dev applies exit and skips cleanup" {
  let lifecycle : @phase.AgentLifecycle = {
    agent_id: "main.l",
    role: @types.Role::Dev,
    process: @phase.ProcessState::Connected,
    workflow: @phase.WorkflowState::Dev(
      @phase.DevLifecycle::ReviewOwned(
        pr_number=7,
        state=@phase.ReviewOwnership::OpenUnreviewed(url="https://ex/7"),
      ),
    ),
  }
  let plan = shutdown_exit_plan(lifecycle)
  assert_true(plan.apply_dev_exit_requested)
  assert_false(plan.attempt_worktree_cleanup)
  match plan.response {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      assert_eq(map.get("status"), Some(String::to_json("deferred")))
      assert_eq(
        map.get("warning"),
        Some("PR filed (7) at https://ex/7".to_json()),
      )
    }
    _ => fail("expected deferred ok")
  }
}

///|
test "shutdown_exit_plan allowed dev allows cleanup and exit" {
  let lifecycle : @phase.AgentLifecycle = {
    agent_id: "main.l",
    role: @types.Role::Dev,
    process: @phase.ProcessState::Connected,
    workflow: @phase.WorkflowState::Dev(@phase.DevLifecycle::Working),
  }
  let plan = shutdown_exit_plan(lifecycle)
  assert_true(plan.apply_dev_exit_requested)
  assert_true(plan.attempt_worktree_cleanup)
  match plan.response {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      assert_eq(map.get("status"), Some(String::to_json("shutdown")))
    }
    _ => fail("expected shutdown ok")
  }
}

///|
test "shutdown_exit_plan allowed tl skips dev exit but may cleanup worktree" {
  let lifecycle : @phase.AgentLifecycle = {
    agent_id: "main.tl",
    role: @types.Role::TL,
    process: @phase.ProcessState::Connected,
    workflow: @phase.WorkflowState::Supervisor(
      @phase.SupervisorLifecycle::Planning,
    ),
  }
  let plan = shutdown_exit_plan(lifecycle)
  assert_false(plan.apply_dev_exit_requested)
  assert_true(plan.attempt_worktree_cleanup)
  match plan.response {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      assert_eq(map.get("status"), Some(String::to_json("shutdown")))
    }
    _ => fail("expected shutdown ok")
  }
}

///|
test "shutdown_adapter_host_steps lists poller through cleanup" {
  let steps = shutdown_adapter_host_steps()
  assert_eq(steps.length(), 5)
  assert_eq(steps[0], ShutdownAdapterHostStep::PollerCriticalPhaseRead)
  assert_eq(steps[1], ShutdownAdapterHostStep::RegistryRoleLookup)
  assert_eq(steps[2], ShutdownAdapterHostStep::LifecycleRead)
  assert_eq(steps[3], ShutdownAdapterHostStep::DevExitEventApply)
  assert_eq(steps[4], ShutdownAdapterHostStep::WorktreeCleanupAttempt)
}

///|
test "shutdown_poller_block_pr_number is none without poller" {
  assert_eq(shutdown_poller_block_pr_number(None, "main.leaf"), None)
}

///|
test "shutdown_poller_block_pr_number matches critical phase" {
  let ps = @poller.PollerState::new()
  ps.track_recovered(
    77,
    "main.leaf",
    "main.topic",
    "main",
    "https://ex/77",
    0L,
    @poller.ReviewState::ChangesRequested,
    "",
    "",
    @poller.CiRollupStatus::Unknown,
    false,
  )
  assert_eq(shutdown_poller_block_pr_number(Some(ps), "main.leaf"), Some(77))
}

///|
test "shutdown_poller_block_pr_number is none when agent not in critical phase" {
  let ps = @poller.PollerState::new()
  ps.track_recovered(
    77,
    "other.leaf",
    "main.topic",
    "main",
    "https://ex/77",
    0L,
    @poller.ReviewState::ChangesRequested,
    "",
    "",
    @poller.CiRollupStatus::Unknown,
    false,
  )
  assert_eq(shutdown_poller_block_pr_number(Some(ps), "main.leaf"), None)
}

///|
test "shutdown_registry_role_for_caller falls back to dev" {
  assert_eq(shutdown_registry_role_for_caller(None, "main.x"), @types.Role::Dev)
  let reg = @registry.AgentRegistry::new()
  assert_eq(
    shutdown_registry_role_for_caller(Some(reg), "main.x"),
    @types.Role::Dev,
  )
}

///|
test "shutdown_registry_role_for_caller uses registry role" {
  let reg = @registry.AgentRegistry::new()
  ignore(
    reg.upsert({
      agent_id: "main.leaf",
      role: @types.Role::TL,
      agent_type: @types.AgentType::Claude,
      parent: None,
      workspace: "/tmp",
      branch: "main.leaf",
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  assert_eq(
    shutdown_registry_role_for_caller(Some(reg), "main.leaf"),
    @types.Role::TL,
  )
}

///|
async fn mock_shutdown_runner_record_worktree(
  cmds : Array[@workspace.Command],
) -> Array[Int] {
  @async.sleep(0)
  let statuses = []
  for _ in cmds {
    statuses.push(0)
  }
  statuses
}

///|
async test "interpret_shutdown blocks poller critical phase before plan" {
  let ps = @poller.PollerState::new()
  ps.track_recovered(
    5,
    "main.leaf",
    "b",
    "main",
    "https://ex/5",
    0L,
    @poller.ReviewState::ChangesRequested,
    "",
    "",
    @poller.CiRollupStatus::Unknown,
    false,
  )
  let args : ShutdownArgs = { caller_id: Some("main.leaf") }
  let got = interpret_shutdown(
    args,
    "/tmp",
    Some(ps),
    None,
    mock_shutdown_runner_record_worktree,
  )
  match got {
    @types.Response::Err(msg) =>
      assert_eq(msg, shutdown_poller_block_message(5))
    _ => fail("expected poller block")
  }
}

///|
async test "interpret_shutdown ok when caller missing uses best-effort" {
  let args : ShutdownArgs = { caller_id: None }
  let got = interpret_shutdown(
    args,
    "/tmp",
    None,
    None,
    mock_shutdown_runner_record_worktree,
  )
  match got {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      assert_eq(map.get("status"), Some(String::to_json("shutdown")))
    }
    _ => fail("expected missing-caller ok")
  }
}

///|
test "dev_lifecycle_pr_number extracts from ReviewOwned" {
  let lc = @phase.DevLifecycle::ReviewOwned(
    pr_number=10,
    state=@phase.ReviewOwnership::OpenUnreviewed(url="https://ex/10"),
  )
  assert_eq(dev_lifecycle_pr_number(lc), Some(10))
}

///|
test "dev_lifecycle_pr_number extracts from ChangesRequested" {
  let lc = @phase.DevLifecycle::ChangesRequested(pr_number=5, next_round=2)
  assert_eq(dev_lifecycle_pr_number(lc), Some(5))
}

///|
test "dev_lifecycle_pr_number extracts from ExitRequestedDeferred" {
  let lc = @phase.DevLifecycle::ExitRequestedDeferred(
    pr_number=3,
    state=@phase.ReviewOwnership::ApprovedAwaitingMerge,
  )
  assert_eq(dev_lifecycle_pr_number(lc), Some(3))
}

///|
test "dev_lifecycle_pr_number returns None for Working" {
  assert_eq(dev_lifecycle_pr_number(@phase.DevLifecycle::Working), None)
}

///|
test "dev_lifecycle_pr_number returns None for Exitable" {
  assert_eq(dev_lifecycle_pr_number(@phase.DevLifecycle::Exitable), None)
}

///|
test "workflow_state_pr_number extracts from Dev workflow" {
  let ws = @phase.WorkflowState::Dev(
    @phase.DevLifecycle::ReviewOwned(
      pr_number=15,
      state=@phase.ReviewOwnership::OpenUnreviewed(url=""),
    ),
  )
  assert_eq(workflow_state_pr_number(ws), Some(15))
}

///|
test "workflow_state_pr_number extracts from Supervisor OwnPRFiled" {
  let ws = @phase.WorkflowState::Supervisor(
    @phase.SupervisorLifecycle::OwnPRFiled(number=22, url="https://ex/22"),
  )
  assert_eq(workflow_state_pr_number(ws), Some(22))
}

///|
test "workflow_state_pr_number returns None for Supervisor Planning" {
  let ws = @phase.WorkflowState::Supervisor(
    @phase.SupervisorLifecycle::Planning,
  )
  assert_eq(workflow_state_pr_number(ws), None)
}
