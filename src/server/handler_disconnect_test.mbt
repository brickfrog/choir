///|
fn pgroup_disconnect_agent(
  agent_id : String,
  project_dir : String,
) -> @types.Agent {
  {
    agent_id,
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Codex,
    parent: None,
    workspace: project_dir + "/.choir/worktrees/pgroup-agent",
    branch: agent_id,
    terminal_target: None,
    host: @types.Host::Local,
    spawn_depth: 0,
    state: @types.AgentState::Active,
  }
}

///|
async test "schedule_disconnect kills tracked agent process group" {
  let project_dir = "/tmp/choir-pgroup-disconnect-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.create_dir_all(project_dir + "/.choir/state/kv"))
  let state = ServerState::new(
    {
      ..@types.Config::default(),
      project_dir,
      terminal_session: "test-session",
    },
    make_hermetic_recovery_provider(),
  )
  let killed : Array[Int] = []
  let agent_id = "abc"
  ignore(state.register_agent(pgroup_disconnect_agent(agent_id, project_dir)))
  state.register_agent_pid(agent_id, 7777)
  state.schedule_disconnect(agent_id, 0L)
  state.process_pending_disconnects_with_runner(
    1L,
    0L,
    runner=async fn(_cmds) {
      @async.sleep(0)
      []
    },
    kill_pgid=fn(pid) { killed.push(pid) },
  )
  @debug.assert_eq(killed, [7777])
  @debug.assert_eq(state.agent_pids.get(agent_id), None)

  let no_pid_agent_id = "abc-no-pid"
  ignore(
    state.register_agent(pgroup_disconnect_agent(no_pid_agent_id, project_dir)),
  )
  state.schedule_disconnect(no_pid_agent_id, 2L)
  state.process_pending_disconnects_with_runner(
    3L,
    0L,
    runner=async fn(_cmds) {
      @async.sleep(0)
      []
    },
    kill_pgid=fn(pid) { killed.push(pid) },
  )
  @debug.assert_eq(killed, [7777])

  ignore(@sys.rm_rf(project_dir))
}

///|
async test "interpret_teardown_effects reaps tracked pgroup on ClearRuntimeTracking" {
  let project_dir = "/tmp/choir-pgroup-clear-runtime-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.create_dir_all(project_dir + "/.choir/state/kv"))
  let state = ServerState::new(
    {
      ..@types.Config::default(),
      project_dir,
      terminal_session: "test-session",
    },
    make_hermetic_recovery_provider(),
  )
  let killed : Array[Int] = []
  let agent_id = "abc-clear-runtime"
  state.register_agent_pid(agent_id, 8888)

  state.interpret_teardown_effects(
    [ClearRuntimeTracking(agent_id)],
    async fn(_cmds) {
      @async.sleep(0)
      []
    },
    kill_pgid=fn(pid) { killed.push(pid) },
  )

  @debug.assert_eq(killed, [8888])
  @debug.assert_eq(state.agent_pids.get(agent_id), None)

  state.interpret_teardown_effects(
    [ClearRuntimeTracking("abc-clear-runtime-no-pid")],
    async fn(_cmds) {
      @async.sleep(0)
      []
    },
    kill_pgid=fn(pid) { killed.push(pid) },
  )
  @debug.assert_eq(killed, [8888])

  ignore(@sys.rm_rf(project_dir))
}

///|
async test "interpret_teardown_effects removes managed worktrees and refuses unsafe paths" {
  let project_dir = "/tmp/choir-rmwt-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.create_dir_all(project_dir + "/.choir/state/kv"))
  let state = ServerState::new(
    {
      ..@types.Config::default(),
      project_dir,
      terminal_session: "test-session",
    },
    make_hermetic_recovery_provider(),
  )
  let ran : Array[@workspace.Command] = []
  let wt = project_dir + "/.choir/worktrees/leaf-x"
  state.interpret_teardown_effects(
    [RemoveWorktree(wt)],
    async fn(cmds) {
      @async.sleep(0)
      for cmd in cmds {
        ran.push(cmd)
      }
      [0]
    },
    is_git_worktree=fn(_p) { true },
  )
  assert_true(
    ran
    .iter()
    .any(fn(cmd) {
      cmd.program == "git" && cmd.args == ["worktree", "remove", "--force", wt]
    }),
  )

  // Unsafe (non-worktree) path: refused — no removal command runs.
  let ran_unsafe : Array[@workspace.Command] = []
  state.interpret_teardown_effects(
    [RemoveWorktree(project_dir + "/src")],
    async fn(cmds) {
      @async.sleep(0)
      for cmd in cmds {
        ran_unsafe.push(cmd)
      }
      [0]
    },
    is_git_worktree=fn(_p) { true },
  )
  @debug.assert_eq(ran_unsafe, [])

  ignore(@sys.rm_rf(project_dir))
}

///|
/// Dead-leaf reaper (choir-3rp5.2, Leaf 3 / F10/F13): a disconnect-confirmed-
/// dead leaf still parked in a thread-owning Dev state (ReviewOwned) would keep
/// its PR's contested threads orphaned forever — `lifecycle_dev_disconnect_policy`
/// PRESERVES ReviewOwned across disconnect. Once the leaf is confirmed dead past
/// grace, the preserve no longer applies: the reaper finalizes it to Done and
/// records the per-owned-PR health determinant (F6). It must NOT call
/// transfer_leaf_ownership (F2); terminal-ness alone opens the TL gate.
async test "dead-leaf reaper finalizes a Disconnected+ReviewOwned leaf to Done" {
  let project_dir = "/tmp/choir-reaper-review-owned-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.create_dir_all(project_dir + "/.choir/state/kv"))
  ignore(@sys.create_dir_all(project_dir + "/.choir/worktrees/main.leaf"))
  // Hermetic provider => agent_process_alive=false => confirmed dead.
  let state = ServerState::new(
    { ..@types.Config::default(), project_dir, terminal_session: "s" },
    make_hermetic_recovery_provider(),
  )
  let parent_id = "main.tl"
  ignore(
    state.register_agent({
      agent_id: @types.AgentId(parent_id),
      role: @types.Role::TL,
      agent_type: @types.AgentType::Claude,
      parent: None,
      workspace: project_dir,
      branch: "main",
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  let agent_id = "main.leaf"
  ignore(
    state.register_agent({
      agent_id: @types.AgentId(agent_id),
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Claude,
      parent: Some(parent_id),
      workspace: project_dir + "/.choir/worktrees/main.leaf",
      branch: agent_id,
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  // Leaf owns PR 7 with a failing CI determinant (recorded, not acted on).
  state.poller.track(7, agent_id, agent_id, "main", "https://ex/pr/7", 0L)
  match state.poller.get(7) {
    Some(t) =>
      state.poller.restore({
        ..t,
        last_ci_rollup: @poller.CiRollupStatus::Failure,
        last_review_state: @poller.ReviewState::ChangesRequested,
      })
    None => fail("expected PR 7 tracked")
  }
  ignore(
    @phase.persist_lifecycle(project_dir, state.registry, {
      agent_id,
      role: @types.Role::Dev,
      process: @phase.ProcessState::Connected,
      workflow: @phase.WorkflowState::Dev(
        @phase.DevLifecycle::ReviewOwned(
          pr_number=7,
          state=@phase.ReviewOwnership::OpenUnreviewed(url="u"),
        ),
      ),
      last_updated_unix_sec: 0L,
    }),
  )
  // Drop the leaf: Disconnected + still ReviewOwned, then confirm dead past grace.
  state.schedule_disconnect(agent_id, 0L)
  let captured : Array[@moontrace.Event] = []
  @moontrace.set_subscriber(fn(event) { captured.push(event) })
  state.process_pending_disconnects_with_runner(61L, 60L, runner=async fn(
    _cmds,
  ) {
    @async.sleep(0)
    []
  })
  @moontrace.clear_subscriber()
  // Leaf is now terminal as Done — the TL gate opens by construction.
  match @phase.read_lifecycle(project_dir, agent_id) {
    Some({ process: @phase.ProcessState::Finalized(..), workflow, .. }) =>
      match workflow {
        @phase.WorkflowState::Dev(@phase.DevLifecycle::Done(..)) => ()
        _ => fail("expected Dev(Done) after reaper")
      }
    _ => fail("expected Finalized(Done) after reaper")
  }
  // The per-owned-PR health determinant was recorded (Unhealthy: failing CI +
  // changes requested, not merged). Done/Fail stays quarantined (F3).
  let mut found_determinant = false
  for event in captured {
    if event.message == "liveness finalize pr health determinant recorded" {
      for f in event.fields {
        if f.key == "health" {
          match f.value {
            Json::String("unhealthy") => found_determinant = true
            _ => ()
          }
        }
      }
    }
  }
  assert_true(found_determinant)
  ignore(@sys.rm_rf(project_dir))
}
