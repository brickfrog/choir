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
test "checked process-group signals reject unsafe group ids" {
  for pgid in [-42, -1, 0, 1] {
    assert_false(terminate_pgid_checked(pgid))
    assert_false(force_kill_pgid_checked(pgid))
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
test "checked directory listing distinguishes empty and unavailable paths" {
  let tmp = "/tmp/choir-list-dir-checked-" + get_pid().to_string()
  ignore(rm_rf(tmp))
  assert_true(create_dir_all(tmp))
  assert_eq(list_dir_all_complete(tmp), Some([]))
  assert_true(write_file_atomic(tmp + "/entry", "owned"))
  assert_eq(list_dir_all_complete(tmp), Some(["entry"]))
  ignore(rm_rf(tmp))
  assert_eq(list_dir_all_complete(tmp), None)
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
  let command = read_file_prefix("/proc/" + pgid.to_string() + "/cmdline", 4096)
  .split("\u{00}")
  .to_array()[0].to_owned()
  assert_true(pgid_has_process_identity(pgid, "HOME=" + home, command))
  assert_false(
    pgid_has_process_identity(pgid, "HOME=/not-the-fixture", command),
  )
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

///|
test "server tree cleanup kills a provider child in a separate session" {
  let tmp = "/tmp/choir-server-tree-" + get_pid().to_string()
  ignore(rm_rf(tmp))
  assert_true(create_dir_all(tmp))
  let root_path = tmp + "/root"
  let child_path = tmp + "/child"
  let sentinel_path = tmp + "/should_not_exist"
  let root = spawn_nested_sessions_for_test(
    root_path, child_path, sentinel_path,
  )
  if root <= 1 {
    ignore(rm_rf(tmp))
    fail("expected server tree fixture to spawn")
  }
  assert_true(wait_for_pgroup_file_for_test(root_path, 80))
  assert_true(wait_for_pgroup_file_for_test(child_path, 80))
  let child = parse_pid_file_for_test(child_path)
  assert_true(child > 1)
  assert_true(pgid_has_non_zombie_process(root))
  assert_true(pgid_has_non_zombie_process(child))
  kill_server_tree_sequence_best_effort(root)
  ignore(wait_pid_reap_for_test(root))
  assert_false(pgid_has_non_zombie_process(root))
  assert_false(pgid_has_non_zombie_process(child))
  assert_false(path_exists(sentinel_path))
  ignore(rm_rf(tmp))
}

///|
/// Following an append-only file must cost what it grew by, and must never
/// consume a line the writer has not finished.
test "read_file_from follows appended bytes without losing a partial line" {
  let path = "/tmp/choir-read-file-from-test.jsonl"
  ignore(write_file_sync(path, "{\"id\":\"a\"}\n{\"id\":\"b\"}\n"))
  let (first, offset) = read_file_from(path, 0)
  assert_eq(first, "{\"id\":\"a\"}\n{\"id\":\"b\"}\n")
  assert_eq(offset, first.length())
  // Nothing appended: nothing read, and the position is unchanged.
  assert_eq(read_file_from(path, offset), ("", offset))
  ignore(
    write_file_sync(path, "{\"id\":\"a\"}\n{\"id\":\"b\"}\n{\"id\":\"c\"}\n"),
  )
  let (appended, next) = read_file_from(path, offset)
  assert_eq(appended, "{\"id\":\"c\"}\n")
  assert_eq(next, offset + appended.length())
  // A truncated or replaced file rereads from the start rather than skipping
  // content that now sits before an offset that no longer means anything.
  ignore(write_file_sync(path, "{\"id\":\"z\"}\n"))
  let (rewound, rewound_offset) = read_file_from(path, next)
  assert_eq(rewound, "{\"id\":\"z\"}\n")
  assert_eq(rewound_offset, rewound.length())
  assert_eq(read_file_from("/tmp/choir-read-file-from-missing", 0), ("", 0))
  ignore(delete_file_sync(path))
}

///|
/// Control-plane state, PID witnesses, and git diagnostics all go through this
/// writer. It used to inherit 0666&umask from fopen — world-readable — and
/// follow a symlink at the final component.
test "written files are owner-only and do not follow a symlink" {
  let path = "/tmp/choir-write-mode-test.txt"
  ignore(delete_file_sync(path))
  assert_true(write_file_sync(path, "secret"))
  assert_eq(file_mode(path), 0o600)
  // An existing file keeps its mode through O_TRUNC, so one created before this
  // hardening must be narrowed rather than left readable forever.
  assert_true(write_file_sync(path, "secret again"))
  assert_eq(file_mode(path), 0o600)
  assert_eq(read_file(path), "secret again")
  ignore(delete_file_sync(path))
  // A symlink at the final component must not redirect the write.
  let target = "/tmp/choir-write-mode-target.txt"
  let link = "/tmp/choir-write-mode-link.txt"
  ignore(delete_file_sync(target))
  ignore(delete_file_sync(link))
  assert_true(write_file_sync(target, "original"))
  if symlink_force(target, link) {
    assert_false(write_file_sync(link, "redirected"))
    assert_eq(read_file(target), "original")
  }
  ignore(delete_file_sync(link))
  ignore(delete_file_sync(target))
}
