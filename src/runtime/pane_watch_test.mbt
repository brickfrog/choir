///|
test "pane_snapshot_path" {
  assert_eq(pane_snapshot_path("abc"), "/tmp/choir-viewport-abc.json")
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
  @debug.assert_eq(pw.watches.get("agent-x").map(fn(w) { w.pid }), Some(99))
  @debug.assert_eq(spawn_args, ["sess", "tab1", snap])
  assert_eq(
    pw.read_viewport("agent-x"),
    "{\"event\":\"pane_update\",\"viewport\":[\"hi\"]}",
  )
  @debug.assert_eq(read_paths, [snap])
  pw.stop_subscribe("agent-x")
  @debug.assert_eq(pw.watches.get("agent-x").map(fn(w) { w.pid }), None)
  @debug.assert_eq(killed_pids, [99])
  @debug.assert_eq(deleted_paths, [snap])
}

///|
test "PaneWatcher::stop_subscribe followed by check_idle does not double-kill or false-idle" {
  let killed_pids : Array[Int] = []
  let deleted_paths : Array[String] = []
  let read_paths : Array[String] = []
  let host : PaneWatchHost = {
    spawn_zellij_pane_viewport_subscribe: fn(_, _, _) { 123 },
    kill_pid_best_effort: fn(pid) { killed_pids.push(pid) },
    delete_file_sync: fn(path) { deleted_paths.push(path) },
    read_file: fn(path) {
      read_paths.push(path)
      "{\"event\":\"pane_update\",\"viewport\":[\"stale\"]}"
    },
  }
  let pw = PaneWatcher::with_host(host)
  let target = @types.LocalTarget::{
    kind: @types.TargetKind::ZellijTab,
    session: "sess",
    name: "tab1",
  }
  pw.watch_pane("agent-stop", target, 0L)
  pw.stop_subscribe("agent-stop")

  @debug.assert_eq(pw.check_idle("agent-stop", 999L, 0L), None)
  @debug.assert_eq(pw.watches.get("agent-stop").map(fn(w) { w.pid }), None)
  @debug.assert_eq(killed_pids, [123])
  @debug.assert_eq(deleted_paths, [pane_snapshot_path("agent-stop")])
  @debug.assert_eq(read_paths, [])
}

///|
test "PaneWatcher::record_observation updates all fields atomically" {
  let read_paths : Array[String] = []
  let host : PaneWatchHost = {
    spawn_zellij_pane_viewport_subscribe: fn(_, _, _) { 456 },
    kill_pid_best_effort: fn(_) { () },
    delete_file_sync: fn(_) { () },
    read_file: fn(path) {
      read_paths.push(path)
      "{\"event\":\"pane_update\",\"viewport\":[\"ready\"]}"
    },
  }
  let pw = PaneWatcher::with_host(host)
  let target = @types.LocalTarget::{
    kind: @types.TargetKind::ZellijTab,
    session: "sess",
    name: "tab1",
  }
  pw.watch_pane("agent-observe", target, 10L)

  @debug.assert_eq(pw.check_idle("agent-observe", 42L, 300L), None)

  let screen = "ready\n"
  let watch = match pw.watches.get("agent-observe") {
    Some(watch) => watch
    None => fail("expected pane watch")
  }
  let observation = watch.observation
  assert_eq(observation.last_change_at, 42L)
  assert_eq(observation.last_hash, simple_hash(screen))
  assert_eq(observation.last_len, screen.length())
  @debug.assert_eq(read_paths, [pane_snapshot_path("agent-observe")])
}

///|
test "extract_viewport_text parses viewport array" {
  let j = "{\"event\":\"pane_update\",\"viewport\":[\"line one\",\"line two\"]}"
  assert_eq(extract_viewport_text(j), "line one\nline two\n")
}
