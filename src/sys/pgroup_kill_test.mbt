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
fn wait_for_pgroup_dead_for_test(pgid : Int, attempts : Int) -> Bool {
  for i = 0; i < attempts; i = i + 1 {
    if !pgid_is_alive(pgid) {
      return true
    }
    sleep_milliseconds(25)
  }
  false
}

///|
fn parse_pid_file_for_test(path : String) -> Int {
  @string.parse_int(read_file(path).trim().to_owned()) catch {
    _ => -1
  }
}

///|
test "read_file_prefix reads zero-sized proc files with a hard bound" {
  let command = read_file_prefix("/proc/self/cmdline", 4096)
  assert_true(command.length() > 0)
  assert_true(command.length() <= 4096)
  assert_eq(read_file_prefix("/proc/self/cmdline", 0), "")
  assert_eq(read_file_prefix("/proc/self/cmdline", 65537), "")
}

///|
test "list_dir_all includes hidden entries without dot traversal" {
  let tmp = "/tmp/choir-list-dir-all-" + get_pid().to_string()
  ignore(rm_rf(tmp))
  assert_true(create_dir_all(tmp))
  assert_true(write_file_sync(tmp + "/.hidden", "hidden"))
  assert_true(write_file_sync(tmp + "/visible", "visible"))
  let entries = list_dir_all(tmp)
  entries.sort()
  assert_eq(entries, [".hidden", "visible"])
  ignore(rm_rf(tmp))
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
  assert_true(pgid_has_non_zombie_process(pgid))
  let home = match getenv("HOME") {
    Some(value) => value
    None => {
      kill_pgid_sequence_best_effort(pgid)
      ignore(wait_pid_reap_for_test(pgid))
      ignore(rm_rf(tmp))
      fail("expected HOME for process identity fixture")
    }
  }
  let command = read_file_prefix(
    "/proc/" + pgid.to_string() + "/cmdline",
    4096,
  ).split("\u{00}").to_array()[0].to_owned()
  assert_true(pgid_has_process_identity(pgid, "HOME=" + home, command))
  assert_false(pgid_has_process_identity(pgid, "HOME=/not-the-fixture", command))
  // Guarded inputs: the sleeper must survive all of these.
  kill_pgid_sequence_best_effort(0)
  kill_pgid_sequence_best_effort(1)
  kill_pgid_sequence_best_effort(-pgid)
  assert_true(pid_is_alive(pgid))
  kill_pgid_sequence_best_effort(pgid)
  ignore(wait_pid_reap_for_test(pgid))
  assert_false(pid_is_alive(pgid))
  assert_false(pgid_has_non_zombie_process(pgid))
  assert_false(path_exists(sentinel_path))
  ignore(rm_rf(tmp))
}

///|
test "pgid_is_alive detects a surviving child after the setsid leader exits" {
  let tmp = "/tmp/choir-pgid-child-" + get_pid().to_string()
  ignore(rm_rf(tmp))
  assert_true(create_dir_all(tmp))
  let pgid_path = tmp + "/pgid"
  let child_path = tmp + "/child"
  let sentinel_path = tmp + "/should_not_exist"
  let pgid = spawn_leader_exited_pgroup_for_test(
    pgid_path, child_path, sentinel_path,
  )
  if pgid <= 1 {
    ignore(rm_rf(tmp))
    fail("expected leader-exited pgroup to spawn")
  }
  assert_true(wait_for_pgroup_file_for_test(pgid_path, 80))
  assert_true(wait_for_pgroup_file_for_test(child_path, 80))
  ignore(wait_pid_reap_for_test(pgid))
  let recorded_pgid = parse_pid_file_for_test(pgid_path)
  let child_pid = parse_pid_file_for_test(child_path)
  assert_eq(recorded_pgid, pgid)
  assert_true(child_pid > 1)
  assert_false(pid_is_alive(pgid))
  if !pgid_is_alive(pgid) {
    kill_pgid_sequence_best_effort(pgid)
    ignore(rm_rf(tmp))
    fail("expected process-group liveness after leader exit")
  }
  kill_pgid_sequence_best_effort(0)
  kill_pgid_sequence_best_effort(1)
  kill_pgid_sequence_best_effort(-pgid)
  if !pgid_is_alive(pgid) {
    kill_pgid_sequence_best_effort(pgid)
    ignore(rm_rf(tmp))
    fail("guarded pgid inputs must not kill the surviving child")
  }
  kill_pgid_sequence_best_effort(pgid)
  assert_true(wait_for_pgroup_dead_for_test(pgid, 80))
  assert_false(path_exists(sentinel_path))
  ignore(rm_rf(tmp))
}
