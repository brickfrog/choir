///|
test "tick backoff grows geometrically and settles at a ceiling" {
  // A first failure retries promptly; a wedged runtime slows to a poll instead
  // of a log line per second.
  assert_eq(@workflow.goal_execution_tick_delay_ms(0), 1000)
  assert_eq(@workflow.goal_execution_tick_delay_ms(1), 2000)
  assert_eq(@workflow.goal_execution_tick_delay_ms(2), 4000)
  assert_eq(@workflow.goal_execution_tick_delay_ms(3), 8000)
  assert_eq(@workflow.goal_execution_tick_delay_ms(4), 16000)
  assert_eq(@workflow.goal_execution_tick_delay_ms(5), 30000)
  assert_eq(@workflow.goal_execution_tick_delay_ms(50), 30000)
  // A negative count cannot arise from the loop, but must not invert the delay.
  assert_eq(@workflow.goal_execution_tick_delay_ms(-1), 1000)
}

///|
test "persistent tick failure is distinguished from a passing one" {
  assert_false(@workflow.goal_execution_tick_failure_is_persistent(0))
  assert_false(@workflow.goal_execution_tick_failure_is_persistent(4))
  assert_true(@workflow.goal_execution_tick_failure_is_persistent(5))
  assert_true(@workflow.goal_execution_tick_failure_is_persistent(100))
}

///|
test "a run of ticks that changes nothing is reported periodically" {
  // A slow Take spans many ticks without changing durable state, so the first
  // quiet ticks say nothing.
  assert_false(@workflow.goal_execution_tick_stall_is_reportable(0))
  assert_false(@workflow.goal_execution_tick_stall_is_reportable(1))
  assert_false(@workflow.goal_execution_tick_stall_is_reportable(59))
  // A run this long is a stall worth naming, and it keeps saying so rather than
  // reporting once and going quiet again.
  assert_true(@workflow.goal_execution_tick_stall_is_reportable(60))
  assert_false(@workflow.goal_execution_tick_stall_is_reportable(61))
  assert_true(@workflow.goal_execution_tick_stall_is_reportable(120))
}
