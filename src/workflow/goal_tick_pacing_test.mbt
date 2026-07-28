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
let pacing_claude : @control.ProviderSurfaceId = @control.ProviderSurfaceId::ClaudeSubscriptionCli

///|
let pacing_codex : @control.ProviderSurfaceId = @control.ProviderSurfaceId::CodexSubscriptionCli

///|
fn pacing_admitted(
  surface : @control.ProviderSurfaceId,
) -> @workflow.ProviderSurfaceTickReport {
  {
    surface,
    disposition: @workflow.ProviderSurfaceTickDisposition::ProviderSurfaceAdmitted,
  }
}

///|
fn pacing_deferred(
  surface : @control.ProviderSurfaceId,
  instant : Int64,
) -> @workflow.ProviderSurfaceTickReport {
  {
    surface,
    disposition: @workflow.ProviderSurfaceTickDisposition::ProviderSurfaceDeferredUntil(
      instant,
    ),
  }
}

///|
/// Fold a tick's gate answers together in the order they arrived, the way the
/// execution tick does.
fn pacing_reports(
  answers : Array[@workflow.ProviderSurfaceTickReport],
) -> Array[@workflow.ProviderSurfaceTickReport] {
  let mut reports : Array[@workflow.ProviderSurfaceTickReport] = []
  for answer in answers {
    reports = @workflow.record_provider_surface_tick_report(reports, answer)
  }
  reports
}

///|
/// A tick that got work onto a surface has more to do immediately, whatever
/// else it was refused. Waiting on the refused Part's instant would park the
/// Parts that were admitted alongside it.
test "a tick that advanced work keeps the base delay" {
  // Four Parts in, a fifth refused, on both surfaces: every surface carries a
  // refusal, and every surface is nonetheless running work.
  let reports = pacing_reports([
    pacing_admitted(pacing_claude),
    pacing_admitted(pacing_codex),
    pacing_deferred(pacing_claude, 105L),
    pacing_deferred(pacing_codex, 130L),
  ])
  assert_eq(
    @workflow.goal_execution_tick_delay_ms_with_deferral(0, reports, 100L),
    1000,
  )
  // Order does not decide it: the refusal arriving first is still overtaken by
  // the admission.
  let reversed = pacing_reports([
    pacing_deferred(pacing_claude, 105L),
    pacing_deferred(pacing_codex, 130L),
    pacing_admitted(pacing_claude),
    pacing_admitted(pacing_codex),
  ])
  assert_eq(
    @workflow.goal_execution_tick_delay_ms_with_deferral(0, reversed, 100L),
    1000,
  )
  // A failing tick still backs off; the admissions do not shorten that.
  assert_eq(
    @workflow.goal_execution_tick_delay_ms_with_deferral(2, reports, 100L),
    4000,
  )
}

///|
/// One surface at capacity says nothing about the other. Raising the sleep for
/// it holds every Goal that would have run on the other surface behind one
/// surface's queue, which is the opposite of what the refusal asked for.
test "a deferral on one surface leaves the other one runnable" {
  // Claude refused five seconds out, Codex never asked for.
  assert_eq(
    @workflow.goal_execution_tick_delay_ms_with_deferral(
      0,
      pacing_reports([pacing_deferred(pacing_claude, 105L)]),
      100L,
    ),
    1000,
  )
  // Claude refused, Codex admitted.
  assert_eq(
    @workflow.goal_execution_tick_delay_ms_with_deferral(
      0,
      pacing_reports([
        pacing_deferred(pacing_claude, 105L),
        pacing_admitted(pacing_codex),
      ]),
      100L,
    ),
    1000,
  )
  // Nothing observed at all: the ordinary backoff, untouched.
  assert_eq(
    @workflow.goal_execution_tick_delay_ms_with_deferral(0, [], 100L),
    1000,
  )
  assert_eq(
    @workflow.goal_execution_tick_delay_ms_with_deferral(2, [], 100L),
    4000,
  )
}

///|
/// A capacity refusal names when a slot could free. Once nothing else can run,
/// waking earlier than that is a poll: no provider slot frees because the
/// scheduler asked again.
test "a tick with every surface refused waits for the nearest instant" {
  // Five seconds out on the nearer surface: waited for, rather than polled five
  // times.
  assert_eq(
    @workflow.goal_execution_tick_delay_ms_with_deferral(
      0,
      pacing_reports([
        pacing_deferred(pacing_claude, 130L),
        pacing_deferred(pacing_codex, 105L),
      ]),
      100L,
    ),
    5000,
  )
  // The nearest instant wins whichever surface carries it, and repeated
  // refusals on one surface keep the earliest of them.
  assert_eq(
    @workflow.goal_execution_tick_delay_ms_with_deferral(
      0,
      pacing_reports([
        pacing_deferred(pacing_claude, 105L),
        pacing_deferred(pacing_claude, 102L),
        pacing_deferred(pacing_codex, 130L),
      ]),
      100L,
    ),
    2000,
  )
  // A refusal closer than the failure backoff does not shorten it.
  assert_eq(
    @workflow.goal_execution_tick_delay_ms_with_deferral(
      3,
      pacing_reports([
        pacing_deferred(pacing_claude, 102L),
        pacing_deferred(pacing_codex, 102L),
      ]),
      100L,
    ),
    8000,
  )
  // The nearest instant being already past, or exactly now, adds no wait: a
  // tick that outlasted the refusal it was given has nothing left to wait for.
  assert_eq(
    @workflow.goal_execution_tick_delay_ms_with_deferral(
      0,
      pacing_reports([
        pacing_deferred(pacing_claude, 100L),
        pacing_deferred(pacing_codex, 130L),
      ]),
      100L,
    ),
    1000,
  )
  assert_eq(
    @workflow.goal_execution_tick_delay_ms_with_deferral(
      0,
      pacing_reports([
        pacing_deferred(pacing_claude, 40L),
        pacing_deferred(pacing_codex, 130L),
      ]),
      100L,
    ),
    1000,
  )
  // A Goal that becomes runnable while every surface is spent must still be
  // noticed, so the wait is capped however far out the refusal reaches.
  assert_eq(
    @workflow.goal_execution_tick_delay_ms_with_deferral(
      0,
      pacing_reports([
        pacing_deferred(pacing_claude, 100_000L),
        pacing_deferred(pacing_codex, 200_000L),
      ]),
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
