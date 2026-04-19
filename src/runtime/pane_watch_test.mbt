///|
test "pane_snapshot_path" {
  assert_eq(pane_snapshot_path("abc"), "/tmp/choir-viewport-abc.json")
}

///|
test "parse_int_simple" {
  assert_eq(parse_int_simple("123"), 123)
  assert_eq(parse_int_simple("0"), 0)
  assert_eq(parse_int_simple("abc123def456"), 123456)
}

///|
test "PaneWatcher::new" {
  let pw = PaneWatcher::new()
  assert_eq(pw.watches.length(), 0)
}

///|
test "PaneWatcher::with_host routes subscribe and cleanup through injected host (spies)" {
  let spawn_args : Array[String] = []
  let killed_pids : Array[Int] = []
  let deleted_paths : Array[String] = []
  let read_paths : Array[String] = []
  let host : PaneWatchHost = {
    spawn_zellij_pane_viewport_subscribe: fn(session, name, path) {
      spawn_args.push(session)
      spawn_args.push(name)
      spawn_args.push(path)
      99
    },
    kill_pid_best_effort: fn(pid) { killed_pids.push(pid) },
    delete_file_sync: fn(path) { deleted_paths.push(path) },
    read_file: fn(path) {
      read_paths.push(path)
      "{\"event\":\"pane_update\",\"viewport\":[\"hi\"]}"
    },
  }
  let pw = PaneWatcher::with_host(host)
  let target = @types.LocalTarget::{
    kind: @types.TargetKind::ZellijTab,
    session: "sess",
    name: "tab1",
  }
  let snap = pane_snapshot_path("agent-x")
  pw.watch_pane("agent-x", target, 0L)
  assert_eq(pw.watches.get("agent-x").map(fn(w) { w.pid }), Some(99))
  assert_eq(spawn_args, ["sess", "tab1", snap])
  assert_eq(
    pw.read_viewport("agent-x"),
    "{\"event\":\"pane_update\",\"viewport\":[\"hi\"]}",
  )
  assert_eq(read_paths, [snap])
  pw.stop_subscribe("agent-x")
  assert_eq(pw.watches.get("agent-x").map(fn(w) { w.pid }), None)
  assert_eq(killed_pids, [99])
  assert_eq(deleted_paths, [snap])
}

///|
test "extract_viewport_text parses viewport array" {
  let j = "{\"event\":\"pane_update\",\"viewport\":[\"line one\",\"line two\"]}"
  assert_eq(extract_viewport_text(j), "line one\nline two\n")
}
