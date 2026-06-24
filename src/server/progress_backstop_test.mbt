///|
/// Tests for the long progress backstop (choir-3rp5.2, Leaf 2). The backstop
/// reclaims an alive-but-wedged leaf parked in a thread-owning review state —
/// a leaf the 300s idle watchdog skips (exempt) and the dead-leaf reaper never
/// reaches (still alive). Justified as liveness/teardown independent of any
/// gate (F13); fires only when ALL of the agent's owned PRs are stalled (RA-4).

///|
fn progress_backstop_test_register_dev(
  state : ServerState,
  agent_id : String,
  parent_id : String,
  project_dir : String,
) -> Unit {
  ignore(
    state.register_agent({
      agent_id: @types.AgentId(agent_id),
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Claude,
      parent: Some(parent_id),
      workspace: project_dir + "/.choir/worktrees/" + agent_id,
      branch: agent_id,
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
}

///|
fn progress_backstop_test_review_owned(
  agent_id : String,
  pr_number : Int,
) -> @phase.AgentLifecycle {
  {
    agent_id,
    role: @types.Role::Dev,
    process: @phase.ProcessState::Connected,
    workflow: @phase.WorkflowState::Dev(
      @phase.DevLifecycle::ReviewOwned(
        pr_number~,
        state=@phase.ReviewOwnership::OpenUnreviewed(url="u"),
      ),
    ),
    last_updated_unix_sec: 0L,
  }
}

///|
fn progress_backstop_test_alive_provider() -> @runtime.RecoveryProvider {
  {
    ..make_hermetic_recovery_provider(),
    agent_process_alive: async fn(_d, _a) {
      @async.sleep(0)
      true
    },
  }
}

///|
async test "progress backstop finalizes an alive leaf when ALL owned PRs stalled" {
  let project_dir = "/tmp/choir-backstop-all-stalled-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.create_dir_all(project_dir + "/.choir/state/kv"))
  let state = ServerState::new(
    { ..@types.Config::default(), project_dir, terminal_session: "s" },
    progress_backstop_test_alive_provider(),
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
  progress_backstop_test_register_dev(state, agent_id, parent_id, project_dir)
  ignore(
    @phase.persist_lifecycle(
      project_dir,
      state.registry,
      progress_backstop_test_review_owned(agent_id, 1),
    ),
  )
  // Leaf owns two PRs; both parked (no SHA move, no thread resolution).
  state.poller.track(1, agent_id, agent_id, "main", "https://ex/pr/1", 0L)
  state.poller.track(2, agent_id, agent_id, "main", "https://ex/pr/2", 0L)
  let runner = async fn(_cmds : Array[@workspace.Command]) {
    @async.sleep(0)
    []
  }
  let threshold = 100L
  // First sweep establishes the stall clock; nothing should fire yet.
  state.progress_backstop_sweep_with_runner(1000L, threshold, runner)
  match @phase.read_lifecycle(project_dir, agent_id) {
    Some({ process, .. }) => assert_false(process.is_terminal())
    None => fail("expected leaf lifecycle persisted after first sweep")
  }
  // Second sweep past the threshold with no progress on EITHER PR => finalize.
  state.progress_backstop_sweep_with_runner(1101L, threshold, runner)
  match @phase.read_lifecycle(project_dir, agent_id) {
    Some({ process: @phase.ProcessState::Finalized(..), workflow, .. }) =>
      match workflow {
        @phase.WorkflowState::Dev(@phase.DevLifecycle::Done(..)) => ()
        _ => fail("expected Dev(Done) workflow after backstop")
      }
    _ => fail("expected Finalized lifecycle after backstop")
  }
  ignore(@sys.rm_rf(project_dir))
}

///|
fn progress_backstop_test_exit_requested_deferred(
  agent_id : String,
  pr_number : Int,
) -> @phase.AgentLifecycle {
  {
    agent_id,
    role: @types.Role::Dev,
    process: @phase.ProcessState::Connected,
    workflow: @phase.WorkflowState::Dev(
      @phase.DevLifecycle::ExitRequestedDeferred(
        pr_number~,
        state=@phase.ReviewOwnership::OpenUnreviewed(url="u"),
      ),
    ),
    last_updated_unix_sec: 0L,
  }
}

///|
async test "progress backstop finalizes an alive-wedged ExitRequestedDeferred owner when ALL owned PRs stalled" {
  // Residual F1 gap (choir-3rp5.4): ExitRequestedDeferred owns a PR (carries
  // pr_number + review state), is idle-watchdog-exempt, and is non-terminal — an
  // alive-wedged one is reached by neither the idle watchdog nor the dead-leaf
  // reaper and would orphan its threads, deadlocking Leaf 1's gate. The backstop
  // must cover it.
  let project_dir = "/tmp/choir-backstop-exit-deferred-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.create_dir_all(project_dir + "/.choir/state/kv"))
  let state = ServerState::new(
    { ..@types.Config::default(), project_dir, terminal_session: "s" },
    progress_backstop_test_alive_provider(),
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
  progress_backstop_test_register_dev(state, agent_id, parent_id, project_dir)
  ignore(
    @phase.persist_lifecycle(
      project_dir,
      state.registry,
      progress_backstop_test_exit_requested_deferred(agent_id, 1),
    ),
  )
  // Leaf owns two PRs; both parked (no SHA move, no thread resolution).
  state.poller.track(1, agent_id, agent_id, "main", "https://ex/pr/1", 0L)
  state.poller.track(2, agent_id, agent_id, "main", "https://ex/pr/2", 0L)
  let runner = async fn(_cmds : Array[@workspace.Command]) {
    @async.sleep(0)
    []
  }
  let threshold = 100L
  // First sweep establishes the stall clock; nothing should fire yet.
  state.progress_backstop_sweep_with_runner(1000L, threshold, runner)
  match @phase.read_lifecycle(project_dir, agent_id) {
    Some({ process, .. }) => assert_false(process.is_terminal())
    None => fail("expected leaf lifecycle persisted after first sweep")
  }
  // Second sweep past the threshold with no progress on EITHER PR => finalize.
  state.progress_backstop_sweep_with_runner(1101L, threshold, runner)
  match @phase.read_lifecycle(project_dir, agent_id) {
    Some({ process: @phase.ProcessState::Finalized(..), workflow, .. }) =>
      match workflow {
        @phase.WorkflowState::Dev(@phase.DevLifecycle::Done(..)) => ()
        _ => fail("expected Dev(Done) workflow after backstop")
      }
    _ => fail("expected Finalized lifecycle after backstop")
  }
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "progress backstop spares a leaf advancing ANY owned PR (RA-4)" {
  let project_dir = "/tmp/choir-backstop-one-advancing-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.create_dir_all(project_dir + "/.choir/state/kv"))
  let state = ServerState::new(
    { ..@types.Config::default(), project_dir, terminal_session: "s" },
    progress_backstop_test_alive_provider(),
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
  progress_backstop_test_register_dev(state, agent_id, parent_id, project_dir)
  ignore(
    @phase.persist_lifecycle(
      project_dir,
      state.registry,
      progress_backstop_test_review_owned(agent_id, 1),
    ),
  )
  state.poller.track(1, agent_id, agent_id, "main", "https://ex/pr/1", 0L)
  state.poller.track(2, agent_id, agent_id, "main", "https://ex/pr/2", 0L)
  let runner = async fn(_cmds : Array[@workspace.Command]) {
    @async.sleep(0)
    []
  }
  let threshold = 100L
  state.progress_backstop_sweep_with_runner(1000L, threshold, runner)
  // PR 2 advances (head SHA moves) — the leaf is actively working it. Killing
  // the leaf would orphan PR 2's threads, the exact failure to prevent.
  match state.poller.get(2) {
    Some(t) => state.poller.restore({ ..t, last_sha: "moved-head" })
    None => fail("expected PR 2 tracked")
  }
  state.progress_backstop_sweep_with_runner(1101L, threshold, runner)
  match @phase.read_lifecycle(project_dir, agent_id) {
    Some({ process, .. }) => assert_false(process.is_terminal())
    None => fail("expected leaf lifecycle still persisted")
  }
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "progress backstop ignores a dead leaf (reaper territory, not backstop)" {
  let project_dir = "/tmp/choir-backstop-dead-leaf-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.create_dir_all(project_dir + "/.choir/state/kv"))
  // Hermetic provider reports agent_process_alive=false (dead).
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
  progress_backstop_test_register_dev(state, agent_id, parent_id, project_dir)
  ignore(
    @phase.persist_lifecycle(
      project_dir,
      state.registry,
      progress_backstop_test_review_owned(agent_id, 1),
    ),
  )
  state.poller.track(1, agent_id, agent_id, "main", "https://ex/pr/1", 0L)
  let runner = async fn(_cmds : Array[@workspace.Command]) {
    @async.sleep(0)
    []
  }
  state.progress_backstop_sweep_with_runner(1000L, 100L, runner)
  state.progress_backstop_sweep_with_runner(1101L, 100L, runner)
  // The backstop targets alive-but-wedged leaves; a dead leaf is the reaper's
  // job (it runs off disconnect confirmation). Backstop must NOT finalize here.
  match @phase.read_lifecycle(project_dir, agent_id) {
    Some({ process, .. }) => assert_false(process.is_terminal())
    None => fail("expected leaf lifecycle still persisted")
  }
  ignore(@sys.rm_rf(project_dir))
}
