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
test "extract_viewport_text parses viewport array" {
  let j = "{\"event\":\"pane_update\",\"viewport\":[\"line one\",\"line two\"]}"
  assert_eq(extract_viewport_text(j), "line one\nline two\n")
}
