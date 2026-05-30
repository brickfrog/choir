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
  ignore(@sys.create_dir_all(project_dir + "/.choir/kv"))
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
  ignore(@sys.create_dir_all(project_dir + "/.choir/kv"))
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
