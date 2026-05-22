///|
test "tick summary builder suppresses empty ticks" {
  let summary = TickSummary::new(100L)
  @debug.assert_eq(build_tick_summary_line(summary, 5L), None)
}

///|
test "tick summary builder formats counts and elapsed milliseconds" {
  let summary = TickSummary::new(100L)
  summary.polled = 2
  summary.changes = 1
  summary.errors = 1
  @debug.assert_eq(
    build_tick_summary_line(summary, 17L),
    Some("tick poll=2 changes=1 errors=1 elapsed=17ms"),
  )
  @debug.assert_eq(summary.elapsed_ms(94L), 0L)
}

///|
test "tick summary builder clamps negative elapsed milliseconds" {
  let summary = TickSummary::new(100L)
  summary.changes = 1
  @debug.assert_eq(
    build_tick_summary_line(summary, -1L),
    Some("tick poll=0 changes=1 errors=0 elapsed=0ms"),
  )
}

///|
test "tick summary builder suppresses polled-only steady-state ticks" {
  let summary = TickSummary::new(100L)
  summary.polled = 1
  @debug.assert_eq(build_tick_summary_line(summary, 8L), None)
}
