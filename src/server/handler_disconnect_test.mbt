///|
fn progress_watchdog_test_project_dir(slug : String) -> String {
  "/tmp/choir-progress-watchdog-" +
  slug +
  "-" +
  @sys.get_pid().to_string() +
  "-" +
  @env.now().reinterpret_as_int64().to_string()
}

///|
fn progress_watchdog_test_state(slug : String) -> ServerState {
  let project_dir = progress_watchdog_test_project_dir(slug)
  ServerState::new(
    { ..@types.Config::default(), project_dir, terminal_session: "s" },
    make_recovery_provider(),
  )
}

///|
fn progress_watchdog_parent(
  parent_id : String,
  project_dir : String,
) -> @types.Agent {
  {
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
  }
}

///|
fn progress_watchdog_dev(
  agent_id : String,
  parent_id : String,
  project_dir : String,
) -> @types.Agent {
  let slug = @phase.extract_slug(agent_id)
  {
    agent_id: @types.AgentId(agent_id),
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Codex,
    parent: Some(parent_id),
    workspace: @workspace.worktree_path(project_dir, slug),
    branch: agent_id,
    terminal_target: None,
    host: @types.Host::Local,
    spawn_depth: 1,
    state: @types.AgentState::Active,
  }
}

///|
async fn progress_watchdog_empty_capture(
  _cmd : @workspace.Command,
) -> (Int, String) {
  @async.sleep(0)
  (0, "")
}

///|
async test "check_leaf_progress rescues stale ChangesRequested leaf after fixes" {
  let state = progress_watchdog_test_state("rescues")
  let parent_id = "main.parent"
  let fresh_agent_id = "main.fresh"
  let agent_id = "main.leaf"
  let fresh_agent = progress_watchdog_dev(
    fresh_agent_id,
    parent_id,
    state.config.project_dir,
  )
  let agent = progress_watchdog_dev(
    agent_id,
    parent_id,
    state.config.project_dir,
  )
  ignore(
    state.register_agent(
      progress_watchdog_parent(parent_id, state.config.project_dir),
    ),
  )
  ignore(state.register_agent(fresh_agent))
  ignore(state.register_agent(agent))
  let now = 2000L
  state.last_commit_observed_at.set(fresh_agent_id, now - 10L)
  state.last_commit_observed_sha.set(fresh_agent_id, "sha-fresh")
  state.last_commit_observed_at.set(agent_id, now - PROGRESS_STALL_SEC)
  state.last_commit_observed_sha.set(agent_id, "sha-old")
  let invoked : Array[@tools.RescueLeafArgs] = []
  let invoker = async fn(args : @tools.RescueLeafArgs) -> @types.Response {
    @async.sleep(0)
    invoked.push(args)
    @types.Response::ok_values({
      "status": "spawned".to_json(),
      "agent_id": "main.leaf-r1".to_json(),
      "from_agent_id": args.from_agent_id.to_json(),
      "slug": args.new_slug.to_json(),
    })
  }
  let lifecycle : @phase.AgentLifecycle = {
    agent_id,
    role: @types.Role::Dev,
    process: @phase.ProcessState::Connected,
    workflow: @phase.WorkflowState::Dev(
      @phase.DevLifecycle::ChangesRequested(pr_number=7, next_round=2),
    ),
    last_updated_unix_sec: 0L,
  }
  let fresh_lifecycle : @phase.AgentLifecycle = {
    agent_id: fresh_agent_id,
    role: @types.Role::Dev,
    process: @phase.ProcessState::Connected,
    workflow: @phase.WorkflowState::Dev(@phase.DevLifecycle::Working),
    last_updated_unix_sec: 0L,
  }
  state.check_leaf_progress(
    fresh_agent, fresh_lifecycle, 0L, now, progress_watchdog_empty_capture, invoker,
  )
  state.check_leaf_progress(
    agent, lifecycle, 1L, now, progress_watchdog_empty_capture, invoker,
  )
  assert_eq(invoked.length(), 1)
  assert_eq(invoked[0].from_agent_id, agent_id)
  assert_eq(invoked[0].new_slug, "leaf-r1")
  assert_eq(invoked[0].agent_type, @types.AgentType::Claude)
  @debug.assert_eq(state.last_commit_observed_at.get(agent_id), None)
  let delivery_log = @sys.read_file(
    state.config.project_dir + "/.choir/delivery.log",
  )
  assert_true(
    delivery_log.contains(
      "progress_watchdog outcome=rescued from=main.leaf to=main.leaf-r1 agent_type=claude",
    ),
  )
  assert_false(delivery_log.contains("from=main.fresh"))
  ignore(@sys.rm_rf(state.config.project_dir))
}

///|
async test "check_leaf_progress does not rescue fresh ReviewOwned leaf" {
  let state = progress_watchdog_test_state("review-owned")
  let parent_id = "main.parent"
  let agent_id = "main.leaf"
  let agent = progress_watchdog_dev(
    agent_id,
    parent_id,
    state.config.project_dir,
  )
  ignore(
    state.register_agent(
      progress_watchdog_parent(parent_id, state.config.project_dir),
    ),
  )
  ignore(state.register_agent(agent))
  let now = 2000L
  state.last_commit_observed_at.set(agent_id, now - PROGRESS_STALL_SEC)
  state.last_commit_observed_sha.set(agent_id, "sha-old")
  let invoked : Array[@tools.RescueLeafArgs] = []
  let invoker = async fn(args : @tools.RescueLeafArgs) -> @types.Response {
    @async.sleep(0)
    invoked.push(args)
    @types.Response::ok_values({ "agent_id": "main.leaf-r1".to_json() })
  }
  let lifecycle : @phase.AgentLifecycle = {
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
  }
  state.check_leaf_progress(
    agent, lifecycle, 0L, now, progress_watchdog_empty_capture, invoker,
  )
  assert_eq(invoked.length(), 0)
  @debug.assert_eq(
    state.last_commit_observed_at.get(agent_id),
    Some(now - PROGRESS_STALL_SEC),
  )
  ignore(@sys.rm_rf(state.config.project_dir))
}

///|
async test "check_leaf_progress preserves commit observation when rescue fails" {
  let state = progress_watchdog_test_state("rescue-fails")
  let parent_id = "main.parent"
  let agent_id = "main.leaf"
  let agent = progress_watchdog_dev(
    agent_id,
    parent_id,
    state.config.project_dir,
  )
  ignore(
    state.register_agent(
      progress_watchdog_parent(parent_id, state.config.project_dir),
    ),
  )
  ignore(state.register_agent(agent))
  let now = 4000L
  let observed_at = now - PROGRESS_STALL_SEC
  state.last_commit_observed_at.set(agent_id, observed_at)
  state.last_commit_observed_sha.set(agent_id, "sha-old")
  state.last_commit_probe_at.set(agent_id, now - 1L)
  let invoked : Array[@tools.RescueLeafArgs] = []
  let invoker = async fn(args : @tools.RescueLeafArgs) -> @types.Response {
    @async.sleep(0)
    invoked.push(args)
    @types.Response::Err("spawn failed")
  }
  let lifecycle : @phase.AgentLifecycle = {
    agent_id,
    role: @types.Role::Dev,
    process: @phase.ProcessState::Connected,
    workflow: @phase.WorkflowState::Dev(
      @phase.DevLifecycle::ChangesRequested(pr_number=7, next_round=2),
    ),
    last_updated_unix_sec: 0L,
  }
  state.check_leaf_progress(
    agent, lifecycle, 1L, now, progress_watchdog_empty_capture, invoker,
  )
  assert_eq(invoked.length(), 1)
  @debug.assert_eq(
    state.last_commit_observed_at.get(agent_id),
    Some(observed_at),
  )
  @debug.assert_eq(
    state.last_commit_observed_sha.get(agent_id),
    Some("sha-old"),
  )
  @debug.assert_eq(state.last_commit_probe_at.get(agent_id), Some(now - 1L))
  ignore(@sys.rm_rf(state.config.project_dir))
}

///|
async test "check_leaf_progress bounds and throttles pre-PR ls-remote probes" {
  let state = progress_watchdog_test_state("ls-remote")
  let parent_id = "main.parent"
  let agent_id = "main.leaf"
  let agent = progress_watchdog_dev(
    agent_id,
    parent_id,
    state.config.project_dir,
  )
  ignore(
    state.register_agent(
      progress_watchdog_parent(parent_id, state.config.project_dir),
    ),
  )
  ignore(state.register_agent(agent))
  let captured : Array[@workspace.Command] = []
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    captured.push(cmd)
    (0, "sha-new\trefs/heads/main.leaf\n")
  }
  let invoked : Array[@tools.RescueLeafArgs] = []
  let invoker = async fn(args : @tools.RescueLeafArgs) -> @types.Response {
    @async.sleep(0)
    invoked.push(args)
    @types.Response::ok_values({ "agent_id": "main.leaf-r1".to_json() })
  }
  let lifecycle : @phase.AgentLifecycle = {
    agent_id,
    role: @types.Role::Dev,
    process: @phase.ProcessState::Connected,
    workflow: @phase.WorkflowState::Dev(@phase.DevLifecycle::Working),
    last_updated_unix_sec: 0L,
  }
  state.check_leaf_progress(agent, lifecycle, 0L, 1000L, capture, invoker)
  state.check_leaf_progress(agent, lifecycle, 0L, 1030L, capture, invoker)
  assert_eq(captured.length(), 1)
  assert_eq(captured[0].program, "timeout")
  assert_eq(captured[0].args[0], "30s")
  assert_eq(captured[0].args[1], "git")
  assert_eq(captured[0].args[2], "ls-remote")
  assert_eq(captured[0].args[5], agent_id)
  assert_eq(invoked.length(), 0)
  @debug.assert_eq(state.last_commit_observed_at.get(agent_id), Some(1000L))
  @debug.assert_eq(
    state.last_commit_observed_sha.get(agent_id),
    Some("sha-new"),
  )
  @debug.assert_eq(state.last_commit_probe_at.get(agent_id), Some(1000L))
  ignore(@sys.rm_rf(state.config.project_dir))
}
