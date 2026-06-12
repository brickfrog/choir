///|
fn wait_for_pgroup_file_for_test(path : String, attempts : Int) -> Bool {
  for i = 0; i < attempts; i = i + 1 {
    if path_exists(path) {
      return true
    }
    sleep_milliseconds(25)
  }
  false
}

///|
/// Hermetic /tmp integration: a setsid'd sleeper (its own pgroup leader) must
/// die from the TERM→pause→KILL pgroup sequence, while guarded inputs
/// (pgid <= 1, negative) must signal nothing.
test "kill_pgid_sequence_best_effort kills a setsid'd /tmp sleeper and guards pgid <= 1" {
  let tmp = "/tmp/choir-pgid-seq-" + get_pid().to_string()
  ignore(rm_rf(tmp))
  assert_true(create_dir_all(tmp))
  let pid_path = tmp + "/pid"
  let sidecar_path = tmp + "/sidecar"
  let sentinel_path = tmp + "/should_not_exist"
  let pgid = spawn_sigterm_unblocked_pgroup_for_test(
    pid_path, sidecar_path, sentinel_path,
  )
  if pgid <= 0 {
    ignore(rm_rf(tmp))
    fail("expected setsid sleeper to spawn")
  }
  assert_true(wait_for_pgroup_file_for_test(pid_path, 80))
  assert_true(pid_is_alive(pgid))
  // Guarded inputs: the sleeper must survive all of these.
  kill_pgid_sequence_best_effort(0)
  kill_pgid_sequence_best_effort(1)
  kill_pgid_sequence_best_effort(-pgid)
  assert_true(pid_is_alive(pgid))
  kill_pgid_sequence_best_effort(pgid)
  ignore(wait_pid_reap_for_test(pgid))
  assert_false(pid_is_alive(pgid))
  assert_false(path_exists(sentinel_path))
  ignore(rm_rf(tmp))
}
