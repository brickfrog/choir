///|
async fn wait_for_test_file(path : String, attempts : Int) -> Bool {
  for _i = 0; _i < attempts; _i = _i + 1 {
    if @sys.path_exists(path) {
      return true
    }
    @async.sleep(25)
  }
  false
}

///|
async test "real exec integration: kill_tracked_agent_pgroup kills real setsid process and clears pid sidecar" {
  let tmp = "/tmp/choir-pgroup-real-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  let pid_path = tmp + "/pid"
  let sentinel_path = tmp + "/should_not_exist"
  let agent_id = "test-agent"
  ignore(@sys.rm_rf(tmp))
  assert_true(@sys.create_dir_all(tmp + "/.choir/pids"))
  let sidecar_path = @workspace.agent_pid_file_path(tmp, agent_id)
  let script = "printf '%s' \"$$\" > " +
    @sys.shell_quote(pid_path) +
    "; printf '%s' \"$$\" > " +
    @sys.shell_quote(sidecar_path) +
    "; trap 'kill -TERM -- -$$ 2>/dev/null' EXIT HUP TERM INT; sleep 30; touch " +
    @sys.shell_quote(sentinel_path)
  let outer_pid = @process.spawn_orphan("setsid", ["bash", "-c", script]) catch {
    e => {
      ignore(@sys.rm_rf(tmp))
      raise e
    }
  }
  try {
    assert_true(wait_for_test_file(pid_path, 80))
    let pgid = @string.parse_int(@sys.read_file(pid_path).trim().to_owned())
    let state = ServerState::new(
      { ..@types.Config::default(), project_dir: tmp },
      make_hermetic_recovery_provider(),
    )
    state.register_agent_pid(agent_id, pgid)

    state.kill_tracked_agent_pgroup(agent_id, @sys.kill_pgid_best_effort)
    ignore(@process.wait_pid(outer_pid) catch { _ => -1 })

    assert_false(@sys.path_exists(sentinel_path))
    @debug.assert_eq(state.forget_agent_pid(agent_id), None)
    assert_false(@sys.path_exists(sidecar_path))
  } catch {
    e => {
      @sys.kill_pgid_best_effort(
        @string.parse_int(@sys.read_file(pid_path).trim().to_owned()) catch {
          _ => 0
        },
      )
      ignore(@process.wait_pid(outer_pid) catch { _ => -1 })
      ignore(@sys.rm_rf(tmp))
      raise e
    }
  } noraise {
    _ => ignore(@sys.rm_rf(tmp))
  }
}
