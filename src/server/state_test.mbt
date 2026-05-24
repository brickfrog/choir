///|
test "register_agent_pid + forget_agent_pid" {
  let project_dir = "/tmp/choir-agent-pid-state-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.create_dir_all(project_dir + "/.choir/kv"))
  let state = ServerState::new(
    { ..@types.Config::default(), project_dir, },
    make_hermetic_recovery_provider(),
  )

  state.register_agent_pid("abc", 7777)
  @debug.assert_eq(state.agent_pids.get("abc"), Some(7777))
  @debug.assert_eq(state.forget_agent_pid("abc"), Some(7777))
  @debug.assert_eq(state.agent_pids.get("abc"), None)
  @debug.assert_eq(state.forget_agent_pid("abc"), None)

  ignore(@sys.rm_rf(project_dir))
}
