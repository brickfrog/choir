///|
test "scheduler backoff grows geometrically and settles at a ceiling" {
  // A first infrastructure failure retries promptly; a wedged scheduler slows
  // to a poll instead of a log line per second. Goal adapter failures use the
  // same shape independently in each durable job.
  assert_eq(@workflow.goal_execution_tick_delay_ms(0), 1000)
  assert_eq(@workflow.goal_execution_tick_delay_ms(1), 2000)
  assert_eq(@workflow.goal_execution_tick_delay_ms(2), 4000)
  assert_eq(@workflow.goal_execution_tick_delay_ms(3), 8000)
  assert_eq(@workflow.goal_execution_tick_delay_ms(4), 16000)
  assert_eq(@workflow.goal_execution_tick_delay_ms(5), 30000)
  assert_eq(@workflow.goal_execution_tick_delay_ms(50), 30000)
  assert_eq(@workflow.goal_execution_tick_delay_ms(-1), 1000)
}

///|
test "persistent scheduler failure is distinguished from a passing one" {
  assert_false(@workflow.goal_execution_tick_failure_is_persistent(0))
  assert_false(@workflow.goal_execution_tick_failure_is_persistent(4))
  assert_true(@workflow.goal_execution_tick_failure_is_persistent(5))
  assert_true(@workflow.goal_execution_tick_failure_is_persistent(100))
  assert_false(@workflow.goal_execution_tick_failure_should_notify(4))
  assert_true(@workflow.goal_execution_tick_failure_should_notify(5))
  assert_false(@workflow.goal_execution_tick_failure_should_notify(6))
  assert_false(@workflow.goal_execution_tick_failure_should_notify(19))
  assert_true(@workflow.goal_execution_tick_failure_should_notify(20))
  assert_false(@workflow.goal_execution_tick_failure_should_notify(21))
  assert_true(@workflow.goal_execution_tick_failure_should_notify(100))
}

///|
test "one Goal's run of unchanged jobs is reported periodically" {
  assert_false(@workflow.goal_execution_tick_stall_is_reportable(0))
  assert_false(@workflow.goal_execution_tick_stall_is_reportable(1))
  assert_false(@workflow.goal_execution_tick_stall_is_reportable(59))
  assert_true(@workflow.goal_execution_tick_stall_is_reportable(60))
  assert_false(@workflow.goal_execution_tick_stall_is_reportable(61))
  assert_true(@workflow.goal_execution_tick_stall_is_reportable(120))
}
