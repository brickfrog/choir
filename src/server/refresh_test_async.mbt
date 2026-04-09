///|
async test "ServerState::refresh_pr_with triggers poll and updates state" {
  let project_dir = "/tmp/choir-refresh-state-test-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.system("mkdir -p " + project_dir + "/.choir/kv"))
  let terminal_session = "test-session"
  let config = { ..@types.Config::default(), project_dir, terminal_session }
  let state = ServerState::new(config, make_recovery_provider())

  let parent_id = "main"
  ignore(
    state.register_agent({
      agent_id: parent_id,
      role: @types.Role::TL,
      agent_type: @types.AgentType::Claude,
      parent: None,
      workspace: project_dir,
      branch: "main",
      terminal_target: Some(
        @workspace.local_target_for(
          terminal_session,
          "TL",
          @types.IsolationMode::Worktree,
        ),
      ),
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )

  let agent_id = "main.dev"
  ignore(
    state.register_agent({
      agent_id,
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Gemini,
      parent: Some(parent_id),
      workspace: project_dir,
      branch: "work",
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 1,
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

  let mut runner_called = false
  state.refresh_pr_with(pr_number, 200L, 900L, mock_poll, runner=async fn(
    cmds,
  ) {
    runner_called = true
    let res = []
    for _ in cmds {
      res.push(0)
    }
    res
  })

  assert_true(poll_called)
  assert_true(runner_called)
  match state.poller.get(pr_number) {
    Some(t) => assert_eq(t.last_review_state, @poller.ReviewState::Approved)
    None => fail("expected PR to remain tracked")
  }
}

///|
async test "ServerState::refresh_pr_with emits ReviewThreadsResolved when snapshot unchanged" {
  let project_dir = "/tmp/choir-refresh-unchanged-test-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.system("mkdir -p " + project_dir + "/.choir/kv"))
  let terminal_session = "test-session"
  let config = { ..@types.Config::default(), project_dir, terminal_session }
  let state = ServerState::new(config, make_recovery_provider())

  let parent_id = "main"
  ignore(
    state.register_agent({
      agent_id: parent_id,
      role: @types.Role::TL,
      agent_type: @types.AgentType::Claude,
      parent: None,
      workspace: project_dir,
      branch: "main",
      terminal_target: Some(
        @workspace.local_target_for(
          terminal_session,
          "TL",
          @types.IsolationMode::Worktree,
        ),
      ),
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )

  let agent_id = "main.dev"
  ignore(
    state.register_agent({
      agent_id,
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Gemini,
      parent: Some(parent_id),
      workspace: project_dir,
      branch: "work",
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 1,
      state: @types.AgentState::Active,
    }),
  )

  let pr_number = 789
  state.poller.track(pr_number, agent_id, "work", "main", "url", 100L)

  // Set initial state to match exactly what poll will return
  match state.poller.get(pr_number) {
    Some(t) =>
      state.poller.restore({
        ..t,
        last_review_state: @poller.ReviewState::Commented,
        last_sha: "sha1",
        last_ci_rollup: @poller.CiRollupStatus::Success,
        last_review_bodies: "comment!",
      })
    None => fail("expected PR")
  }

  // Poll returns same state (Commented) -> no event from tick_pr_with
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
    (
      true,
      @poller.ReviewState::Commented,
      "sha1",
      @poller.CiRollupStatus::Success,
      "comment!",
      true,
      false,
    )
  }

  let mut runner_called = false
  state.refresh_pr_with(pr_number, 200L, 900L, mock_poll, runner=async fn(
    _cmds,
  ) {
    runner_called = true
    let res = []
    for _ in _cmds {
      res.push(0)
    }
    res
  })

  assert_true(runner_called)
}
