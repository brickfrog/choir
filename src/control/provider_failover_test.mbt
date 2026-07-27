///|
let failover_claude : @control.ProviderSurfaceId = @control.ProviderSurfaceId::ClaudeSubscriptionCli

///|
let failover_codex : @control.ProviderSurfaceId = @control.ProviderSurfaceId::CodexSubscriptionCli

///|
test "an alternate surface is chosen only when the contract admits one" {
  // Admitted under a single surface: there is nowhere to move, and inventing
  // a second surface would change provider authority nobody granted.
  assert_eq(
    @control.select_admitted_provider_surface(
      failover_codex,
      [failover_codex],
      [],
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
    },
  ]
  // Both admitted surfaces are spent, so the work waits rather than being
  // handed back and forth between them.
  assert_eq(
    @control.select_admitted_provider_surface(
      failover_codex,
      [failover_codex, failover_claude],
      spent,
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
    },
  ]
  assert_eq(
    @control.select_admitted_provider_surface(
      failover_codex,
      [failover_codex, failover_claude],
      retry_after,
      99L,
    ),
    None,
  )
  assert_eq(
    @control.select_admitted_provider_surface(
      failover_codex,
      [failover_codex, failover_claude],
      retry_after,
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
    },
  ]
  assert_eq(
    @control.select_admitted_provider_surface(
      failover_codex,
      [failover_codex, failover_claude],
      crashed,
      100L,
    ),
    Some(failover_claude),
  )
}
