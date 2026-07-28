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
/// A capacity refusal names when a slot could free. Waking earlier than that is
/// a poll: nothing releases a provider slot because the scheduler asked again.
test "a provider deferral raises the tick delay to its instant" {
  // No deferral: the ordinary backoff is untouched.
  assert_eq(
    @workflow.goal_execution_tick_delay_ms_with_deferral(0, None, 100L),
    1000,
  )
  assert_eq(
    @workflow.goal_execution_tick_delay_ms_with_deferral(2, None, 100L),
    4000,
  )
  // Five seconds out: waited for, rather than polled five times.
  assert_eq(
    @workflow.goal_execution_tick_delay_ms_with_deferral(0, Some(105L), 100L),
    5000,
  )
  // A deferral closer than the failure backoff does not shorten it.
  assert_eq(
    @workflow.goal_execution_tick_delay_ms_with_deferral(3, Some(102L), 100L),
    8000,
  )
  // An instant already past, or exactly now, adds no wait at all.
  assert_eq(
    @workflow.goal_execution_tick_delay_ms_with_deferral(0, Some(100L), 100L),
    1000,
  )
  assert_eq(
    @workflow.goal_execution_tick_delay_ms_with_deferral(0, Some(40L), 100L),
    1000,
  )
  // Other Goals on other surfaces stay runnable, so one surface's queue cannot
  // hold the loop past the ordinary ceiling.
  assert_eq(
    @workflow.goal_execution_tick_delay_ms_with_deferral(
      0,
      Some(100_000L),
      100L,
    ),
    30000,
  )
}

///|
test "persistent tick failure is distinguished from a passing one" {
  assert_false(@workflow.goal_execution_tick_failure_is_persistent(0))
  assert_false(@workflow.goal_execution_tick_failure_is_persistent(4))
  assert_true(@workflow.goal_execution_tick_failure_is_persistent(5))
  assert_true(@workflow.goal_execution_tick_failure_is_persistent(100))
  assert_false(@workflow.goal_execution_tick_failure_should_notify(4))
  assert_true(@workflow.goal_execution_tick_failure_should_notify(5))
  assert_false(@workflow.goal_execution_tick_failure_should_notify(6))
  // A failure run that never ends keeps saying so instead of reporting once
  // and leaving the Conductor to assume the Goal is merely slow.
  assert_false(@workflow.goal_execution_tick_failure_should_notify(19))
  assert_true(@workflow.goal_execution_tick_failure_should_notify(20))
  assert_false(@workflow.goal_execution_tick_failure_should_notify(21))
  assert_true(@workflow.goal_execution_tick_failure_should_notify(100))
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
