///|
let failover_claude : @control.ProviderSurfaceId = @control.ProviderSurfaceId::ClaudeSubscriptionCli

///|
let failover_codex : @control.ProviderSurfaceId = @control.ProviderSurfaceId::CodexSubscriptionCli

///|
/// A re-check schedule with figures small enough to write deadlines out by
/// hand: the first wait is a minute, it doubles, and it never passes half an
/// hour.
fn failover_policy() -> @control.ProviderRecheckPolicy {
  match
    @control.provider_recheck_policy(
      base_seconds=60L,
      growth=2L,
      ceiling_seconds=1_800L,
    ) {
    Ok(policy) => policy
    Err(_) => abort("the re-check schedule under test is invalid")
  }
}

///|
test "a re-check schedule that would bound nothing is rejected" {
  let rejected = fn(base_seconds, growth, ceiling_seconds) {
    @control.provider_recheck_policy(base_seconds~, growth~, ceiling_seconds~)
    is Err(_)
  }
  // A first interval of zero re-checks a spent surface immediately, which is
  // the same as having no schedule.
  assert_true(rejected(0L, 2L, 1_800L))
  assert_true(rejected(-60L, 2L, 1_800L))
  // Growth below one shrinks the wait instead of backing off.
  assert_true(rejected(60L, 0L, 1_800L))
  // A ceiling under the first interval is not a ceiling.
  assert_true(rejected(60L, 2L, 59L))
  // A flat schedule is still a bounded one.
  assert_true(
    @control.provider_recheck_policy(
      base_seconds=60L,
      growth=1L,
      ceiling_seconds=60L,
    )
    is Ok(_),
  )
}

///|
/// The revision this file exists to pin: trusted reset evidence decides the
/// wait exactly as it always did, and an allowance that reported none is
/// re-checked on a capped schedule instead of deferring at every clock
/// reading for the rest of the Part's life.
test "deferral obeys reported evidence and re-checks what reported none" {
  let policy = failover_policy()
  let admits = fn(availability, prior_deferrals, now) {
    @control.provider_availability_admits_dispatch(
      availability,
      observed_at=1_000L,
      prior_deferrals~,
      policy~,
      now~,
    )
  }
  // Nothing is being waited for: a surface that merely died is retried under
  // the ordinary bounded recovery path.
  assert_true(admits(@control.ProviderAvailability::ProviderAvailable, 0, 0L))
  assert_true(admits(@control.ProviderAvailability::ProviderUnavailable, 0, 0L))
  // A reported reset defers until exactly that instant, whatever the re-check
  // schedule would have said — both nearer than the first interval and past
  // the ceiling.
  let resets_at = fn(instant) {
    @control.ProviderAvailability::ProviderAllowanceExhausted(Some(instant))
  }
  assert_false(admits(resets_at(1_010L), 0, 1_009L))
  assert_true(admits(resets_at(1_010L), 0, 1_010L))
  assert_false(admits(resets_at(9_000L), 0, 8_999L))
  assert_true(admits(resets_at(9_000L), 0, 9_000L))
  // A retry-after is the provider's own instant too.
  assert_false(
    admits(@control.ProviderAvailability::ProviderRetryAfter(100L), 0, 99L),
  )
  assert_true(
    admits(@control.ProviderAvailability::ProviderRetryAfter(100L), 0, 100L),
  )
  // No reset evidence: Choir still invents no reset instant, but the
  // observation ages out a minute after it was made rather than standing
  // forever.
  let spent = @control.ProviderAvailability::ProviderAllowanceExhausted(None)
  assert_false(admits(spent, 0, 1_059L))
  assert_true(admits(spent, 0, 1_060L))
  // The wait doubles per consecutive deferral of the same surface.
  assert_false(admits(spent, 1, 1_119L))
  assert_true(admits(spent, 1, 1_120L))
  assert_false(admits(spent, 2, 1_239L))
  assert_true(admits(spent, 2, 1_240L))
  // And is capped, so a run of deferrals cannot grow the wait into a parking:
  // even the fortieth is over half an hour after the observation.
  assert_false(admits(spent, 40, 2_799L))
  assert_true(admits(spent, 40, 2_800L))
}

///|
test "an alternate surface is chosen only when the contract admits one" {
  // Admitted under a single surface: there is nowhere to move, and inventing
  // a second surface would change provider authority nobody granted.
  assert_eq(
    @control.select_admitted_provider_surface(
      failover_codex,
      [failover_codex],
      [],
      failover_policy(),
      100L,
    ),
    None,
  )
  // Admitted under both: the contract's own order decides.
  assert_eq(
    @control.select_admitted_provider_surface(
      failover_codex,
      [failover_codex, failover_claude],
      [],
      failover_policy(),
      100L,
    ),
    Some(failover_claude),
  )
  // A surface that is not in the admitted set is never reachable, even as the
  // only other surface Choir knows about.
  assert_eq(
    @control.select_admitted_provider_surface(
      failover_claude,
      [failover_claude],
      [],
      failover_policy(),
      100L,
    ),
    None,
  )
}

///|
test "a candidate surface that is itself deferred is not selected" {
  let spent : Array[@control.ProviderSurfaceObservation] = [
    {
      surface: failover_claude,
      availability: @control.ProviderAvailability::ProviderAllowanceExhausted(
        None,
      ),
      observed_at: 100L,
    },
  ]
  // Both admitted surfaces are spent, so the work waits rather than being
  // handed back and forth between them.
  assert_eq(
    @control.select_admitted_provider_surface(
      failover_codex,
      [failover_codex, failover_claude],
      spent,
      failover_policy(),
      100L,
    ),
    None,
  )
  // A candidate whose deferral has expired serves again: the observation is a
  // wait with an instant, not a permanent exclusion.
  let retry_after : Array[@control.ProviderSurfaceObservation] = [
    {
      surface: failover_claude,
      availability: @control.ProviderAvailability::ProviderRetryAfter(100L),
      observed_at: 10L,
    },
  ]
  assert_eq(
    @control.select_admitted_provider_surface(
      failover_codex,
      [failover_codex, failover_claude],
      retry_after,
      failover_policy(),
      99L,
    ),
    None,
  )
  assert_eq(
    @control.select_admitted_provider_surface(
      failover_codex,
      [failover_codex, failover_claude],
      retry_after,
      failover_policy(),
      100L,
    ),
    Some(failover_claude),
  )
  // A surface that merely died is not deferred at all; it is retried under the
  // ordinary bounded recovery path and stays selectable.
  let crashed : Array[@control.ProviderSurfaceObservation] = [
    {
      surface: failover_claude,
      availability: @control.ProviderAvailability::ProviderUnavailable,
      observed_at: 100L,
    },
  ]
  assert_eq(
    @control.select_admitted_provider_surface(
      failover_codex,
      [failover_codex, failover_claude],
      crashed,
      failover_policy(),
      100L,
    ),
    Some(failover_claude),
  )
}

///|
/// A surface left on an allowance that named no reset instant used to be
/// excluded for the rest of the Part's life, because the observation admitted
/// dispatch at no clock reading at all.
test "a surface left on a spent allowance is asked again once it ages out" {
  let left_claude : Array[@control.ProviderSurfaceObservation] = [
    {
      surface: failover_claude,
      availability: @control.ProviderAvailability::ProviderAllowanceExhausted(
        None,
      ),
      observed_at: 1_000L,
    },
  ]
  let selected = fn(now) {
    @control.select_admitted_provider_surface(
      failover_codex,
      [failover_codex, failover_claude],
      left_claude,
      failover_policy(),
      now,
    )
  }
  assert_eq(selected(1_059L), None)
  assert_eq(selected(1_060L), Some(failover_claude))
  // Leaving the same surface twice waits longer the second time, and the
  // second observation is what decides — the first has long since expired.
  let left_claude_twice : Array[@control.ProviderSurfaceObservation] = [
    left_claude[0],
    { ..left_claude[0], observed_at: 2_000L },
  ]
  let selected_twice = fn(now) {
    @control.select_admitted_provider_surface(
      failover_codex,
      [failover_codex, failover_claude],
      left_claude_twice,
      failover_policy(),
      now,
    )
  }
  assert_eq(selected_twice(2_119L), None)
  assert_eq(selected_twice(2_120L), Some(failover_claude))
}
