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
  assert_eq(pw.subscribe_pids.length(), 0)
}

///|
test "PaneWatcher::with_host routes subscribe and cleanup through injected host" {
  let killed_pids : Array[Int] = []
  let deleted_paths : Array[String] = []
  let host : PaneWatchHost = {
    spawn_zellij_pane_viewport_subscribe: fn(_session, _name, _path) { 99 },
    kill_pid_best_effort: fn(pid) { killed_pids.push(pid) },
    delete_file_sync: fn(path) { deleted_paths.push(path) },
    read_file: fn(_path) { "{\"event\":\"pane_update\",\"viewport\":[\"hi\"]}" },
  }
  let pw = PaneWatcher::with_host(host)
  let target = @types.LocalTarget::{
    kind: @types.TargetKind::ZellijTab,
    session: "sess",
    name: "tab1",
  }
  pw.watch_pane("agent-x", target, 0L)
  assert_eq(pw.subscribe_pids.get("agent-x"), Some(99))
  // read_viewport routes through the injected host
  assert_eq(
    pw.read_viewport("agent-x"),
    "{\"event\":\"pane_update\",\"viewport\":[\"hi\"]}",
  )
  pw.stop_subscribe("agent-x")
  assert_eq(pw.subscribe_pids.get("agent-x"), None)
  // kill and delete were dispatched through the host
  assert_eq(killed_pids, [99])
  assert_eq(deleted_paths, [pane_snapshot_path("agent-x")])
}

///|
test "extract_viewport_text parses viewport array" {
  let j = "{\"event\":\"pane_update\",\"viewport\":[\"line one\",\"line two\"]}"
  assert_eq(extract_viewport_text(j), "line one\nline two\n")
}
