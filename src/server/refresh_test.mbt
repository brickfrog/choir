///|
async test "ServerState::refresh_pr_with triggers poll and deliveries" {
  let project_dir = "/tmp/choir-refresh-state-test-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.system("mkdir -p " + project_dir + "/.choir/kv"))
  let terminal_session = "test-session"
  let config = { ..@types.Config::default(), project_dir, terminal_session }
  let state = ServerState::new(config, make_recovery_provider())

  let agent_id = "main.dev"
  ignore(
    state.register_agent({
      agent_id,
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Gemini,
      parent: None,
      workspace: project_dir,
      branch: "work",
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )

  let pr_number = 456
  state.poller.track(pr_number, agent_id, "work", "main", "url", 100L)

  let mut poll_called = false
  let mock_poll = async fn(
    _n : Int,
    _skip : Bool,
  ) -> (
    Bool,
    @poller.ReviewState,
    String,
    @poller.CiRollupStatus,
    String,
    Bool,
    Bool,
  ) {
    poll_called = true
    (
      true,
      @poller.ReviewState::Approved,
      "sha1",
      @poller.CiRollupStatus::Success,
      "approved!",
      true,
      false,
    )
  }

  state.refresh_pr_with(pr_number, 200L, 900L, mock_poll, runner=async fn(
    _cmds,
  ) {
    []
  })

  assert_true(poll_called)
  match state.poller.get(pr_number) {
    Some(t) => assert_eq(t.last_review_state, @poller.ReviewState::Approved)
    None => fail("expected PR to remain tracked")
  }
}
