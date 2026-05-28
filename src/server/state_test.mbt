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

///|
test "ServerState::new seeds untracked merge boundary on first boot" {
  let project_dir = "/tmp/choir-untracked-boundary-first-boot-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  let write_paths : Array[String] = []
  let write_contents : Array[String] = []
  let state = ServerState::new(
    { ..@types.Config::default(), project_dir, },
    make_hermetic_recovery_provider(),
    path_exists=fn(path) { path.has_suffix("/.choir/audit-gate.json") },
    write_file_atomic=fn(path, content) {
      write_paths.push(path)
      write_contents.push(content)
      true
    },
    now_unix_sec=fn() { 1779967000L },
  )

  assert_eq(state.poller.untracked_merge_boundary_unix, 1779967000L)
  assert_eq(write_paths.length(), 1)
  assert_eq(write_contents.length(), 1)
  assert_eq(write_paths[0], @poller.poller_state_path(project_dir))
  let persisted = @poller.parse_poller_state_json(write_contents[0])
  assert_eq(persisted.untracked_merge_boundary_unix, 1779967000L)
  assert_eq(persisted.tracked.length(), 0)
  ignore(@sys.rm_rf(project_dir))
}

///|
test "ServerState::new seeds boundary without clobbering persisted tracked PRs" {
  let project_dir = "/tmp/choir-untracked-boundary-preserve-tracked-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  let persisted_before = @poller.PollerState::new()
  persisted_before.track(
    44, "agent-44", "branch-44", "main", "https://example.test/pr/44", 44L,
  )
  let poller_path = @poller.poller_state_path(project_dir)
  let write_paths : Array[String] = []
  let write_contents : Array[String] = []
  let state = ServerState::new(
    { ..@types.Config::default(), project_dir, },
    make_hermetic_recovery_provider(),
    path_exists=fn(path) {
      path.has_suffix("/.choir/audit-gate.json") || path == poller_path
    },
    read_file=fn(path) {
      if path == poller_path {
        persisted_before.to_json()
      } else {
        ""
      }
    },
    write_file_atomic=fn(path, content) {
      write_paths.push(path)
      write_contents.push(content)
      true
    },
    now_unix_sec=fn() { 1779968000L },
  )

  assert_eq(state.poller.untracked_merge_boundary_unix, 1779968000L)
  assert_eq(state.poller.tracked.length(), 0)
  assert_eq(write_paths.length(), 1)
  assert_eq(write_paths[0], poller_path)
  let persisted_after = @poller.parse_poller_state_json(write_contents[0])
  assert_eq(persisted_after.untracked_merge_boundary_unix, 1779968000L)
  @debug.assert_eq(
    persisted_after.get(44).map(fn(pr) { pr.agent_id }),
    Some("agent-44"),
  )
  ignore(@sys.rm_rf(project_dir))
}
