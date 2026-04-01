///|
test "pane_snapshot_path" {
  assert_eq(pane_snapshot_path("abc"), "/tmp/choir-viewport-abc.json")
}

///|
test "pane_subscribe_pid_path" {
  assert_eq(
    pane_subscribe_pid_path("leaf-1"),
    "/tmp/choir-subscribe-leaf-1.pid",
  )
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
