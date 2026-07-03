///|
async fn mock_refresh_capture(cmd : @workspace.Command) -> (Int, String) {
  @async.sleep(0)
  if cmd.program == "timeout" &&
    cmd.args.length() >= 2 &&
    cmd.args[0] == "30s" &&
    cmd.args[1] == "gh" {
    if cmd.args.contains("repo") && cmd.args.contains("view") {
      return (0, "{\"owner\":{\"login\":\"brickfrog\"},\"name\":\"choir\"}")
    }
    if cmd.args.contains("graphql") {
      return (
        0, "{\"data\":{\"repository\":{\"pullRequest\":{\"reviewThreads\":{\"nodes\":[]}}}}}",
      )
    }
  }
  (1, "")
}

///|
async fn refresh_test_no_sleep(_ms : Int) -> Unit {
  @async.sleep(0)
}

///|
async fn refresh_test_hook_capture(
  _path : String,
  _input_json : String,
  _cwd : String?,
) -> (Int, String) {
  @async.sleep(0)
  (0, "")
}

///|
async test "ServerState::refresh_pr_with triggers poll and updates state" {
  let project_dir = "/tmp/choir-refresh-state-test-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  assert_true(@sys.create_dir_all(project_dir + "/.choir/state/kv"))
  let terminal_session = "test-session"
  let config = { ..@types.Config::default(), project_dir, terminal_session }
  let state = ServerState::new(config, make_hermetic_recovery_provider())

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
      terminal_target: Some(
        @workspace.local_target_for(
          terminal_session,
          "main.dev",
          @types.IsolationMode::Worktree,
        ),
      ),
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
    @poller.Mergeable,
    @poller.MergeStateStatus,
    Int64?,
  ) {
    @async.sleep(0)
    poll_called = true
    (
      true,
      @poller.ReviewState::Approved,
      "sha1",
      @poller.CiRollupStatus::Success,
      "approved!",
      true,
      false,
      @poller.Mergeable::Unknown,
      @poller.MergeStateStatus::Unknown,
      None,
    )
  }

  let mut runner_called = false
  state.refresh_pr_with(
    pr_number,
    200L,
    900L,
    mock_poll,
    refresh_test_hook_capture,
    None,
    "",
    runner=async fn(cmds) {
      @async.sleep(0)
      runner_called = true
      let res = []
      for _ in cmds {
        res.push(0)
      }
      res
    },
    capture=mock_refresh_capture,
    git_capture=async fn(_program, _args) {
      @async.sleep(0)
      ""
    },
    bd_capture=mock_refresh_capture,
    path_exists=fn(_) { false },
    hook_path_exists=fn(_) { false },
    git_pull_capture=mock_refresh_capture,
    automerge_capture=mock_refresh_capture,
    audit_receipt_exists=fn(_) { false },
    audit_receipt_read=fn(_) { "" },
    sleep_fn=refresh_test_no_sleep,
  )

  assert_true(poll_called)
  assert_true(runner_called)
  match state.poller.get(pr_number) {
    Some(t) => assert_eq(t.last_review_state, @poller.ReviewState::Approved)
    None => fail("expected PR to remain tracked")
  }
}

///|
async test "ServerState::refresh_pr_with does not synthesize ReviewThreadsResolved on no-op refresh" {
  let project_dir = "/tmp/choir-refresh-unchanged-test-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  assert_true(@sys.create_dir_all(project_dir + "/.choir/state/kv"))
  let terminal_session = "test-session"
  let config = { ..@types.Config::default(), project_dir, terminal_session }
  let state = ServerState::new(config, make_hermetic_recovery_provider())

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
      terminal_target: Some(
        @workspace.local_target_for(
          terminal_session,
          "main.dev",
          @types.IsolationMode::Worktree,
        ),
      ),
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
        mergeable: @poller.Mergeable::Unknown,
        merge_state_status: @poller.MergeStateStatus::Unknown,
        merged_at_unix: None,
        last_review_bodies: "comment!",
        review_mode: @types.ReviewMode::Iterative,
        unresolved_thread_ids: [],
        unresolved_thread_ids_fetched: true,
        auto_resolve_outdated_pending: true,
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
    @poller.Mergeable,
    @poller.MergeStateStatus,
    Int64?,
  ) {
    @async.sleep(0)
    (
      true,
      @poller.ReviewState::Commented,
      "sha1",
      @poller.CiRollupStatus::Success,
      "comment!",
      true,
      false,
      @poller.Mergeable::Unknown,
      @poller.MergeStateStatus::Unknown,
      None,
    )
  }

  let mut runner_called = false
  let mut graphql_calls = 0
  state.refresh_pr_with(
    pr_number,
    200L,
    900L,
    mock_poll,
    refresh_test_hook_capture,
    None,
    "",
    runner=async fn(_cmds) {
      @async.sleep(0)
      runner_called = true
      let res = []
      for _ in _cmds {
        res.push(0)
      }
      res
    },
    capture=async fn(cmd) {
      @async.sleep(0)
      if cmd.program == "timeout" &&
        cmd.args.length() >= 2 &&
        cmd.args[0] == "30s" &&
        cmd.args[1] == "gh" &&
        cmd.args.contains("graphql") {
        graphql_calls = graphql_calls + 1
      }
      mock_refresh_capture(cmd)
    },
    git_capture=async fn(_program, _args) {
      @async.sleep(0)
      ""
    },
    bd_capture=mock_refresh_capture,
    path_exists=fn(_) { false },
    hook_path_exists=fn(_) { false },
    git_pull_capture=mock_refresh_capture,
    automerge_capture=mock_refresh_capture,
    audit_receipt_exists=fn(_) { false },
    audit_receipt_read=fn(_) { "" },
    sleep_fn=refresh_test_no_sleep,
  )

  assert_eq(graphql_calls, 1)
  assert_false(runner_called)
}
