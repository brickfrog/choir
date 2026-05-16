///|
test "shutdown_missing_caller_response is best-effort ok" {
  let r = shutdown_missing_caller_response()
  match r {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      @debug.assert_eq(map.get("status"), Some(String::to_json("shutdown")))
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
  role? : @types.Role = @types.Role::Dev,
  agent_id? : String = "main.leaf",
) -> @types.Agent {
  {
    agent_id: @types.AgentId(agent_id),
    role,
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
  @debug.assert_eq(kill_agent_pane_close_command(a), None)
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
      @debug.assert_eq(cmd.args, expected.args)
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
      @debug.assert_eq(cmd.args, [
        "worktree", "remove", "--force", "/proj/.choir/worktrees/slug-0",
      ])
    }
    None => fail("expected worktree remove")
  }
  let no_wt = kill_agent_test_agent(None, "/proj")
  @debug.assert_eq(kill_agent_worktree_remove_command(no_wt), None)
  let project_root = kill_agent_test_agent(None, "/proj")
  @debug.assert_eq(
    kill_agent_worktree_remove_command(project_root, project_dir="/proj"),
    None,
  )
}

///|
test "kill_agent_ok_response matches killed envelope" {
  match kill_agent_ok_response("main.topic") {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      @debug.assert_eq(map.get("status"), Some(String::to_json("killed")))
      @debug.assert_eq(map.get("agent_id"), Some(String::to_json("main.topic")))
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
      @debug.assert_eq(map.get("status"), Some(String::to_json("killed")))
      @debug.assert_eq(map.get("agent_id"), Some(String::to_json("main.leaf")))
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
async test "interpret_kill_agent refuses supervisor roles without side effects" {
  let t = match @types.LocalTarget::parse("zellij-tab:choir:TL") {
    Some(v) => v
    None => fail("expected parse")
  }
  for role in [@types.Role::Root, @types.Role::TL] {
    let agent_id = match role {
      @types.Role::Root => "root"
      @types.Role::TL => "main.tl"
      _ => "main.supervisor"
    }
    let reg = @registry.AgentRegistry::new()
    let agent = kill_agent_test_agent(
      Some(t),
      "/proj/.choir/worktrees/supervisor",
      role~,
      agent_id~,
    )
    ignore(reg.upsert(agent))
    let ran : Array[@workspace.Command] = []
    let scanned : Array[String] = []
    let killed : Array[Int] = []
    let spy_runner = async fn(cmds : Array[@workspace.Command]) -> Array[Int] {
      @async.sleep(0)
      for cmd in cmds {
        ran.push(cmd)
      }
      [0]
    }
    let spy_list_pids = fn(prefix : String) -> Array[Int] {
      scanned.push(prefix)
      [99]
    }
    let spy_kill_pid = fn(pid : Int) -> Unit { killed.push(pid) }
    let got = interpret_kill_agent(
      { agent_id, reason: "cleanup" },
      Some(reg),
      spy_runner,
      project_dir="/proj",
      list_pids=spy_list_pids,
      kill_pid=spy_kill_pid,
    )
    match got {
      @types.Response::Err(msg) =>
        assert_eq(msg, "kill_agent refused: target is supervisor")
      _ => fail("expected supervisor refusal")
    }
    @debug.assert_eq(ran, [])
    @debug.assert_eq(scanned, [])
    @debug.assert_eq(killed, [])
    match reg.get(agent_id) {
      a => assert_eq(a.state, @types.AgentState::Active)
    }
  }
}

///|
async test "interpret_kill_agent permits dev and worker targets in lifecycle states" {
  let project_dir = "/tmp/choir-kill-agent-lifecycle-roles-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  assert_true(@sys.create_dir_all(project_dir + "/.choir/kv"))
  let cases : Array[(@types.Role, @types.Role, String)] = [
    (@types.Role::TL, @types.Role::Dev, "main.review-owned-dev"),
    (@types.Role::Worker, @types.Role::Worker, "main.killable-worker"),
  ]
  let stale_parent_target : @types.LocalTarget = {
    kind: @types.TargetKind::ZellijTab,
    session: "choir",
    name: "TL",
  }
  for case in cases {
    let (registry_role, lifecycle_role, agent_id) = case
    let reg = @registry.AgentRegistry::new()
    let stale_supervisor_leaf = registry_role == @types.Role::TL &&
      lifecycle_role == @types.Role::Dev
    let agent = kill_agent_test_agent(
      if stale_supervisor_leaf {
        Some(stale_parent_target)
      } else {
        None
      },
      if stale_supervisor_leaf {
        project_dir
      } else {
        project_dir + "/.choir/worktrees/" + agent_id
      },
      role=registry_role,
      agent_id~,
    )
    ignore(reg.upsert(agent))
    let fallback_workspace = @workspace.worktree_path(
      project_dir,
      @phase.extract_slug(agent_id),
    )
    let workflow = match lifecycle_role {
      @types.Role::Dev =>
        @phase.WorkflowState::Dev(
          @phase.DevLifecycle::ReviewOwned(
            pr_number=44,
            state=@phase.ReviewOwnership::OpenUnreviewed(url="https://ex/pr/44"),
          ),
        )
      @types.Role::Worker =>
        @phase.WorkflowState::Worker(@phase.WorkerLifecycle::Working)
      _ => @phase.default_workflow_state(lifecycle_role)
    }
    assert_true(
      @phase.write_lifecycle(project_dir, {
        agent_id,
        role: lifecycle_role,
        process: @phase.ProcessState::Connected,
        workflow,
        last_updated_unix_sec: 0L,
      }),
    )
    let ran : Array[@workspace.Command] = []
    let scanned : Array[String] = []
    let spy_runner = async fn(cmds : Array[@workspace.Command]) -> Array[Int] {
      @async.sleep(0)
      for cmd in cmds {
        ran.push(cmd)
      }
      [0]
    }
    let got = interpret_kill_agent(
      { agent_id, reason: "cleanup" },
      Some(reg),
      spy_runner,
      project_dir~,
      list_pids=fn(path) {
        scanned.push(path)
        []
      },
      kill_pid=fn(_) {  },
    )
    match got {
      @types.Response::Ok(fields) => {
        let map = fields.to_json_map()
        @debug.assert_eq(map.get("status"), Some(String::to_json("killed")))
        @debug.assert_eq(map.get("agent_id"), Some(String::to_json(agent_id)))
      }
      @types.Response::Err(msg) =>
        fail("expected killable target, got error: " + msg)
    }
    match reg.get(agent_id) {
      a => assert_eq(a.state, @types.AgentState::Failed)
    }
    for cmd in ran {
      if stale_supervisor_leaf {
        match kill_agent_pane_close_command(agent) {
          Some(close_cmd) => assert_false(cmd == close_cmd)
          None => ()
        }
      }
    }
    if stale_supervisor_leaf {
      assert_true(
        ran
        .iter()
        .any(fn(cmd) {
          cmd.program == "git" &&
          cmd.args == ["worktree", "remove", "--force", fallback_workspace]
        }),
      )
      @debug.assert_eq(scanned, [fallback_workspace])
    }
    assert_true(ran.length() <= 1)
  }
  ignore(@sys.rm_rf(project_dir))
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
async test "interpret_kill_agent skips /proc scan for non-choir workspaces" {
  // An agent that `register`ed with an arbitrary workspace (including `""`)
  // must not trigger a system-wide /proc scan — that would match nearly
  // every process and SIGKILL them. The fallback is gated on the same
  // choir-worktree predicate we use for `git worktree remove`.
  for workspace in ["", "/", "/home/user/proj", "/proj/not-a-choir-worktree"] {
    let reg = @registry.AgentRegistry::new()
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
      _ => fail("expected ok for workspace=" + workspace)
    }
    @debug.assert_eq(scanned, [])
    @debug.assert_eq(killed, [])
  }
}

///|
async test "interpret_kill_agent skips /proc scan for project-root workspaces" {
  for workspace in ["", ".", "/proj", "/"] {
    let reg = @registry.AgentRegistry::new()
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
      project_dir="/proj",
      list_pids=spy_list_pids,
      kill_pid=spy_kill_pid,
    )
    match got {
      @types.Response::Ok(_) => ()
      _ => fail("expected ok for workspace=" + workspace)
    }
    @debug.assert_eq(scanned, [])
    @debug.assert_eq(killed, [])
  }
}

///|
async test "interpret_kill_agent runs /proc scan when workspace is a choir worktree" {
  let reg = @registry.AgentRegistry::new()
  let workspace = "/proj/.choir/worktrees/slug-0"
  let agent = kill_agent_test_agent(None, workspace)
  ignore(reg.upsert(agent))
  let scanned : Array[String] = []
  let killed : Array[Int] = []
  let spy_list_pids = fn(prefix : String) -> Array[Int] {
    scanned.push(prefix)
    [7]
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
  @debug.assert_eq(scanned, [workspace])
  @debug.assert_eq(killed, [7])
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
          @debug.assert_eq(
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
          @debug.assert_eq(
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
    last_updated_unix_sec: 0L,
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
    last_updated_unix_sec: 0L,
  }
  let plan = shutdown_exit_plan(lifecycle)
  assert_true(plan.apply_dev_exit_requested)
  assert_false(plan.attempt_worktree_cleanup)
  match plan.response {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      @debug.assert_eq(map.get("status"), Some(String::to_json("deferred")))
      @debug.assert_eq(
        map.get("warning"),
        Some("PR filed (7) at https://ex/7".to_json()),
      )
    }
    _ => fail("expected deferred ok")
  }
}

///|
test "shutdown_exit_plan keeps deferred open PR when poller lacks merge receipt" {
  let lifecycle : @phase.AgentLifecycle = {
    agent_id: "main.l",
    role: @types.Role::Dev,
    process: @phase.ProcessState::Connected,
    workflow: @phase.WorkflowState::Dev(
      @phase.DevLifecycle::ExitRequestedDeferred(
        pr_number=7,
        state=@phase.ReviewOwnership::OpenUnreviewed(url="https://ex/7"),
      ),
    ),
    last_updated_unix_sec: 0L,
  }
  let ps = @poller.PollerState::new()
  let plan = shutdown_exit_plan(lifecycle, poller_state=Some(ps))
  assert_true(plan.apply_dev_exit_requested)
  assert_false(plan.attempt_worktree_cleanup)
  match plan.response {
    @types.Response::Ok(fields) =>
      @debug.assert_eq(
        fields.to_json_map().get("status"),
        Some(String::to_json("deferred")),
      )
    _ => fail("expected deferred ok")
  }
}

///|
test "shutdown_exit_plan releases deferred open PR after explicit merge receipt" {
  let lifecycle : @phase.AgentLifecycle = {
    agent_id: "main.l",
    role: @types.Role::Dev,
    process: @phase.ProcessState::Connected,
    workflow: @phase.WorkflowState::Dev(
      @phase.DevLifecycle::ExitRequestedDeferred(
        pr_number=7,
        state=@phase.ReviewOwnership::OpenUnreviewed(url="https://ex/7"),
      ),
    ),
    last_updated_unix_sec: 0L,
  }
  let ps = @poller.PollerState::new()
  ps.track(7, "main.l", "feature/l", "main", "https://ex/7", 0L)
  match ps.get(7) {
    Some(tracked) => ps.mark_merged_observed(tracked)
    None => fail("expected tracked PR")
  }
  ps.untrack(7)
  let plan = shutdown_exit_plan(lifecycle, poller_state=Some(ps))
  assert_false(plan.apply_dev_exit_requested)
  assert_true(plan.attempt_worktree_cleanup)
  match plan.response {
    @types.Response::Ok(fields) =>
      @debug.assert_eq(
        fields.to_json_map().get("status"),
        Some(String::to_json("shutdown")),
      )
    _ => fail("expected shutdown ok")
  }
}

///|
test "shutdown_exit_plan releases deferred non-open review state" {
  let lifecycle : @phase.AgentLifecycle = {
    agent_id: "main.l",
    role: @types.Role::Dev,
    process: @phase.ProcessState::Connected,
    workflow: @phase.WorkflowState::Dev(
      @phase.DevLifecycle::ExitRequestedDeferred(
        pr_number=8,
        state=@phase.ReviewOwnership::ApprovedAwaitingMerge,
      ),
    ),
    last_updated_unix_sec: 0L,
  }
  let plan = shutdown_exit_plan(lifecycle)
  assert_false(plan.apply_dev_exit_requested)
  assert_true(plan.attempt_worktree_cleanup)
  match plan.response {
    @types.Response::Ok(fields) =>
      @debug.assert_eq(
        fields.to_json_map().get("status"),
        Some(String::to_json("shutdown")),
      )
    _ => fail("expected shutdown ok")
  }
}

///|
test "shutdown_exit_plan allowed dev allows cleanup and exit" {
  let lifecycle : @phase.AgentLifecycle = {
    agent_id: "main.l",
    role: @types.Role::Dev,
    process: @phase.ProcessState::Connected,
    workflow: @phase.WorkflowState::Dev(@phase.DevLifecycle::Working),
    last_updated_unix_sec: 0L,
  }
  let plan = shutdown_exit_plan(lifecycle)
  assert_true(plan.apply_dev_exit_requested)
  assert_true(plan.attempt_worktree_cleanup)
  match plan.response {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      @debug.assert_eq(map.get("status"), Some(String::to_json("shutdown")))
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
    last_updated_unix_sec: 0L,
  }
  let plan = shutdown_exit_plan(lifecycle)
  assert_false(plan.apply_dev_exit_requested)
  assert_true(plan.attempt_worktree_cleanup)
  match plan.response {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      @debug.assert_eq(map.get("status"), Some(String::to_json("shutdown")))
    }
    _ => fail("expected shutdown ok")
  }
}

///|
test "shutdown_adapter_host_steps lists poller through cleanup" {
  let steps = shutdown_adapter_host_steps()
  assert_eq(steps.length(), 6)
  assert_eq(steps[0], ShutdownAdapterHostStep::PollerCriticalPhaseRead)
  assert_eq(steps[1], ShutdownAdapterHostStep::RegistryRoleLookup)
  assert_eq(steps[2], ShutdownAdapterHostStep::LifecycleRead)
  assert_eq(steps[3], ShutdownAdapterHostStep::DevExitEventApply)
  assert_eq(steps[4], ShutdownAdapterHostStep::WorktreeCleanupAttempt)
  assert_eq(steps[5], ShutdownAdapterHostStep::BeadsLifecycleMirror)
}

///|
test "shutdown_poller_block_pr_number is none without poller" {
  @debug.assert_eq(shutdown_poller_block_pr_number(None, "main.leaf"), None)
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
  @debug.assert_eq(
    shutdown_poller_block_pr_number(Some(ps), "main.leaf"),
    Some(77),
  )
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
  @debug.assert_eq(shutdown_poller_block_pr_number(Some(ps), "main.leaf"), None)
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
fn shutdown_beads_registry_fixture(
  workspace : String,
  role : @types.Role,
) -> @registry.AgentRegistry {
  ignore(@sys.create_dir_all(workspace + "/.choir"))
  let target : @types.LocalTarget = {
    kind: ZellijTab,
    session: "choir",
    name: "leaf",
  }
  let spec : @types.SpawnSpec = {
    slug: "leaf",
    role,
    agent_type: @types.AgentType::Codex,
    task: "assigned work",
    task_contract: Some({
      ..@types.TaskContract::empty(),
      goal: "assigned work",
      beads_issue_id: Some("choir-shutdown"),
    }),
    isolation: @types.IsolationMode::Worktree,
    parent_id: "main",
    parent_branch: "main",
    reuse_workspace: false,
    workspace_slug: None,
    reuse_git_branch: None,
    spawn_depth: 0,
    automerge: None,
    review_mode: None,
    wave_id: None,
  }
  ignore(
    @sys.write_file_sync(
      workspace + "/.choir/config.local.toml",
      @workspace.config_local_content(spec, workspace, target),
    ),
  )
  let reg = @registry.AgentRegistry::new()
  ignore(
    reg.upsert({
      agent_id: @types.AgentId("main.leaf"),
      role,
      agent_type: @types.AgentType::Codex,
      parent: Some("main"),
      workspace,
      branch: "main.leaf",
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  reg
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
      @debug.assert_eq(map.get("status"), Some(String::to_json("shutdown")))
    }
    _ => fail("expected missing-caller ok")
  }
}

///|
async test "interpret_shutdown mirrors lifecycle state to Beads on graceful exit" {
  let tmp = "/tmp/choir-shutdown-beads-mirror-" + @sys.get_pid().to_string()
  let workspace = tmp + "/worker"
  ignore(@sys.rm_rf(tmp))
  let reg = shutdown_beads_registry_fixture(workspace, @types.Role::Worker)
  let seen : Array[String] = []
  let args : ShutdownArgs = { caller_id: Some("main.leaf") }
  let got = interpret_shutdown(
    args,
    tmp,
    None,
    Some(reg),
    mock_shutdown_runner_record_worktree,
    capture=async fn(cmd : @workspace.Command) -> (Int, String) {
      @async.sleep(0)
      seen.push(cmd.program + " " + cmd.args.join(" "))
      (0, "")
    },
  )
  match got {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      @debug.assert_eq(map.get("status"), Some(String::to_json("shutdown")))
    }
    _ => fail("expected shutdown ok")
  }
  let rendered = seen.join("\n")
  assert_true(
    rendered.contains(
      "bd set-state choir-shutdown lifecycle=shutdown --reason Choir agent shutdown",
    ),
  )
  assert_true(
    rendered.contains(
      "bd audit record --kind tool_call --tool-name shutdown --response Choir agent shutdown --issue-id choir-shutdown",
    ),
  )
  ignore(@sys.rm_rf(tmp))
}

///|
async test "interpret_shutdown skips Beads shutdown mirror when exit is deferred" {
  let tmp = "/tmp/choir-shutdown-beads-deferred-" + @sys.get_pid().to_string()
  let workspace = tmp + "/worker"
  ignore(@sys.rm_rf(tmp))
  assert_true(@sys.create_dir_all(tmp + "/.choir/kv"))
  let reg = shutdown_beads_registry_fixture(workspace, @types.Role::Dev)
  ignore(
    @phase.write_lifecycle(tmp, {
      agent_id: "main.leaf",
      role: @types.Role::Dev,
      process: @phase.ProcessState::Connected,
      workflow: @phase.WorkflowState::Dev(
        @phase.DevLifecycle::ReviewOwned(
          pr_number=272,
          state=@phase.ReviewOwnership::OpenUnreviewed(url="https://ex/272"),
        ),
      ),
      last_updated_unix_sec: 0L,
    }),
  )
  let seen : Array[String] = []
  let args : ShutdownArgs = { caller_id: Some("main.leaf") }
  let got = interpret_shutdown(
    args,
    tmp,
    None,
    Some(reg),
    mock_shutdown_runner_record_worktree,
    capture=async fn(cmd : @workspace.Command) -> (Int, String) {
      @async.sleep(0)
      seen.push(cmd.program + " " + cmd.args.join(" "))
      (0, "")
    },
  )
  match got {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      @debug.assert_eq(map.get("status"), Some(String::to_json("deferred")))
    }
    _ => fail("expected deferred ok")
  }
  @debug.assert_eq(seen, [])
  ignore(@sys.rm_rf(tmp))
}

///|
test "dev_lifecycle_pr_number extracts from ReviewOwned" {
  let lc = @phase.DevLifecycle::ReviewOwned(
    pr_number=10,
    state=@phase.ReviewOwnership::OpenUnreviewed(url="https://ex/10"),
  )
  @debug.assert_eq(dev_lifecycle_pr_number(lc), Some(10))
}

///|
test "dev_lifecycle_pr_number extracts from ChangesRequested" {
  let lc = @phase.DevLifecycle::ChangesRequested(pr_number=5, next_round=2)
  @debug.assert_eq(dev_lifecycle_pr_number(lc), Some(5))
}

///|
test "dev_lifecycle_pr_number extracts from ExitRequestedDeferred" {
  let lc = @phase.DevLifecycle::ExitRequestedDeferred(
    pr_number=3,
    state=@phase.ReviewOwnership::ApprovedAwaitingMerge,
  )
  @debug.assert_eq(dev_lifecycle_pr_number(lc), Some(3))
}

///|
test "dev_lifecycle_pr_number returns None for Working" {
  @debug.assert_eq(dev_lifecycle_pr_number(@phase.DevLifecycle::Working), None)
}

///|
test "dev_lifecycle_pr_number returns None for Exitable" {
  @debug.assert_eq(dev_lifecycle_pr_number(@phase.DevLifecycle::Exitable), None)
}

///|
test "workflow_state_pr_number extracts from Dev workflow" {
  let ws = @phase.WorkflowState::Dev(
    @phase.DevLifecycle::ReviewOwned(
      pr_number=15,
      state=@phase.ReviewOwnership::OpenUnreviewed(url=""),
    ),
  )
  @debug.assert_eq(workflow_state_pr_number(ws), Some(15))
}

///|
test "workflow_state_pr_number extracts from Supervisor OwnPRFiled" {
  let ws = @phase.WorkflowState::Supervisor(
    @phase.SupervisorLifecycle::OwnPRFiled(number=22, url="https://ex/22"),
  )
  @debug.assert_eq(workflow_state_pr_number(ws), Some(22))
}

///|
test "workflow_state_pr_number returns None for Supervisor Planning" {
  let ws = @phase.WorkflowState::Supervisor(
    @phase.SupervisorLifecycle::Planning,
  )
  @debug.assert_eq(workflow_state_pr_number(ws), None)
}
