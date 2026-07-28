///|
let lease_claude : @control.ProviderSurfaceId = @control.ProviderSurfaceId::ClaudeSubscriptionCli

///|
let lease_codex : @control.ProviderSurfaceId = @control.ProviderSurfaceId::CodexSubscriptionCli

///|
fn lease_request(
  goal : String,
  part : String,
  surface : @control.ProviderSurfaceId,
  epoch : Int64,
) -> @workflow.ProviderLeaseRequest {
  let goal_id = @control.GoalId(goal)
  {
    lease_id: @workflow.provider_lease_id(
      goal_id,
      @control.PartId(part),
      surface,
    ),
    take_id: @control.TakeId("take-" + goal + "-" + part),
    goal_id,
    fencing_epoch: @control.FencingEpoch(epoch),
  }
}

///|
fn lease_capacity(
  surface : Int,
  global? : Int? = None,
  other_surfaces? : Array[@workflow.ProviderSurfaceLeaseRecord] = [],
) -> @workflow.ProviderLeaseCapacity {
  { surface, global, other_surfaces, deferral: 5L }
}

///|
fn granted_record(
  decision : @workflow.ProviderLeaseDecision,
) -> @workflow.ProviderSurfaceLeaseRecord raise {
  match decision {
    @workflow.ProviderLeaseDecision::ProviderLeaseGranted(record, _) => record
    @workflow.ProviderLeaseDecision::ProviderLeaseDeferredUntil(_) =>
      fail("expected the lease to be granted")
  }
}

///|
/// The bound that stops two Goals from spending the same subscription slot.
/// Widen the comparison and the second Goal is admitted alongside the first.
test "one surface slot admits one Goal and defers the next" {
  let empty = @workflow.empty_provider_surface_lease_record(
    lease_claude,
    @control.FencingEpoch(7L),
  )
  let first = @workflow.plan_provider_lease_acquisition(
    empty,
    lease_request("goal-a", "part-a", lease_claude, 7L),
    lease_capacity(1),
    100L,
  )
  let held = granted_record(first)
  assert_eq(held.held.length(), 1)
  assert_eq(held.durable_version, empty.durable_version + 1)
  let second = @workflow.plan_provider_lease_acquisition(
    held,
    lease_request("goal-b", "part-b", lease_claude, 7L),
    lease_capacity(1),
    100L,
  )
  assert_eq(
    second,
    @workflow.ProviderLeaseDecision::ProviderLeaseDeferredUntil(105L),
  )
  // Capacity two admits both, so the refusal above is the bound and not the
  // record shape.
  let widened = @workflow.plan_provider_lease_acquisition(
    held,
    lease_request("goal-b", "part-b", lease_claude, 7L),
    lease_capacity(2),
    100L,
  )
  assert_eq(granted_record(widened).held.length(), 2)
}

///|
/// Asking again for a slot this Part already holds must not take a second one,
/// and must not rewrite the record.
test "a held lease is regranted without consuming another slot" {
  let request = lease_request("goal-a", "part-a", lease_claude, 7L)
  let held = granted_record(
    @workflow.plan_provider_lease_acquisition(
      @workflow.empty_provider_surface_lease_record(
        lease_claude,
        @control.FencingEpoch(7L),
      ),
      request,
      lease_capacity(1),
      100L,
    ),
  )
  let again = @workflow.plan_provider_lease_acquisition(
    held,
    request,
    lease_capacity(1),
    140L,
  )
  let regranted = granted_record(again)
  assert_eq(regranted, held)
  assert_eq(regranted.held.length(), 1)
  // The first acquisition's instant survives: nothing was reacquired.
  assert_eq(regranted.held[0].acquired_at, 100L)
}

///|
/// Restart reconciliation. A worker that died still holds its slot in the
/// record; the daemon that replaces it mints a greater epoch, and that alone is
/// what frees the slot. Nothing here is a timeout.
test "a lease from a dead generation is reclaimed, a live one is not" {
  let held = granted_record(
    @workflow.plan_provider_lease_acquisition(
      @workflow.empty_provider_surface_lease_record(
        lease_claude,
        @control.FencingEpoch(7L),
      ),
      lease_request("goal-a", "part-a", lease_claude, 7L),
      lease_capacity(1),
      100L,
    ),
  )
  // Same generation: the slot is still taken, however much later it is asked.
  assert_eq(
    @workflow.plan_provider_lease_acquisition(
      held,
      lease_request("goal-b", "part-b", lease_claude, 7L),
      lease_capacity(1),
      9_000_000L,
    ),
    @workflow.ProviderLeaseDecision::ProviderLeaseDeferredUntil(9_000_005L),
  )
  // A later generation: the dead worker's lease is gone and the slot is free.
  let after_restart = granted_record(
    @workflow.plan_provider_lease_acquisition(
      held,
      lease_request("goal-b", "part-b", lease_claude, 8L),
      lease_capacity(1),
      200L,
    ),
  )
  assert_eq(after_restart.held.length(), 1)
  assert_eq(after_restart.held[0].goal_id, @control.GoalId("goal-b"))
  assert_eq(after_restart.held[0].fencing_epoch, @control.FencingEpoch(8L))
  assert_eq(
    @workflow.reclaim_provider_surface_leases(
      held.held,
      @control.FencingEpoch(8L),
    ).length(),
    0,
  )
  assert_eq(
    @workflow.reclaim_provider_surface_leases(
      held.held,
      @control.FencingEpoch(7L),
    ).length(),
    1,
  )
}

///|
/// Releasing twice must not free two slots. The second release produces no
/// record at all, which is what makes that impossible rather than merely
/// unlikely.
test "releasing an already-released lease changes nothing" {
  let epoch = @control.FencingEpoch(7L)
  let first = lease_request("goal-a", "part-a", lease_claude, 7L)
  let second = lease_request("goal-b", "part-b", lease_claude, 7L)
  let one = granted_record(
    @workflow.plan_provider_lease_acquisition(
      @workflow.empty_provider_surface_lease_record(lease_claude, epoch),
      first,
      lease_capacity(2),
      100L,
    ),
  )
  let two = granted_record(
    @workflow.plan_provider_lease_acquisition(
      one,
      second,
      lease_capacity(2),
      101L,
    ),
  )
  assert_eq(two.held.length(), 2)
  let released = match
    @workflow.plan_provider_lease_release(two, first.lease_id, epoch) {
    @workflow.ProviderLeaseReleaseDecision::ProviderLeaseReleased(value) =>
      value
    @workflow.ProviderLeaseReleaseDecision::ProviderLeaseAlreadyReleased =>
      fail("expected the held lease to be released")
  }
  assert_eq(released.held.length(), 1)
  assert_eq(released.held[0].id, second.lease_id)
  // Second release: no record, so the count cannot move again.
  assert_eq(
    @workflow.plan_provider_lease_release(released, first.lease_id, epoch),
    @workflow.ProviderLeaseReleaseDecision::ProviderLeaseAlreadyReleased,
  )
  // A lease that was never held releases the same way.
  assert_eq(
    @workflow.plan_provider_lease_release(
      released,
      @workflow.provider_lease_id(
        @control.GoalId("goal-z"),
        @control.PartId("part-z"),
        lease_claude,
      ),
      epoch,
    ),
    @workflow.ProviderLeaseReleaseDecision::ProviderLeaseAlreadyReleased,
  )
  // And the surviving slot is still exactly one, so no double decrement
  // happened anywhere above.
  assert_eq(
    granted_record(
      @workflow.plan_provider_lease_acquisition(
        released,
        first,
        lease_capacity(2),
        102L,
      ),
    ).held.length(),
    2,
  )
}

///|
/// The global ceiling binds across surfaces. The Claude record here is empty
/// against a surface bound of four, so its own bound cannot be what refuses:
/// only a lease another surface holds, counted against the ceiling, can.
test "the global ceiling refuses a surface that has room of its own" {
  let epoch = @control.FencingEpoch(7L)
  let codex_held = granted_record(
    @workflow.plan_provider_lease_acquisition(
      @workflow.empty_provider_surface_lease_record(lease_codex, epoch),
      lease_request("goal-a", "part-a", lease_codex, 7L),
      lease_capacity(2),
      100L,
    ),
  )
  let refused = @workflow.plan_provider_lease_acquisition(
    @workflow.empty_provider_surface_lease_record(lease_claude, epoch),
    lease_request("goal-b", "part-b", lease_claude, 7L),
    lease_capacity(4, global=Some(1), other_surfaces=[codex_held]),
    100L,
  )
  assert_eq(
    refused,
    @workflow.ProviderLeaseDecision::ProviderLeaseDeferredUntil(105L),
  )
  // Raise only the ceiling and the same request is admitted.
  assert_eq(
    granted_record(
      @workflow.plan_provider_lease_acquisition(
        @workflow.empty_provider_surface_lease_record(lease_claude, epoch),
        lease_request("goal-b", "part-b", lease_claude, 7L),
        lease_capacity(4, global=Some(2), other_surfaces=[codex_held]),
        100L,
      ),
    ).held.length(),
    1,
  )
  // A lease another surface holds under a dead generation does not count
  // against the ceiling.
  assert_eq(
    granted_record(
      @workflow.plan_provider_lease_acquisition(
        @workflow.empty_provider_surface_lease_record(
          lease_claude,
          @control.FencingEpoch(8L),
        ),
        lease_request("goal-b", "part-b", lease_claude, 8L),
        lease_capacity(4, global=Some(1), other_surfaces=[codex_held]),
        100L,
      ),
    ).held.length(),
    1,
  )
}

///|
/// The lease identity is derived, so a Part that re-enters the gate asks for
/// the slot it already has rather than a new one, and two Parts never collide.
test "lease identity is per Goal, Part, and surface" {
  let goal_a = @control.GoalId("goal-a")
  let part_a = @control.PartId("part-a")
  assert_eq(
    @workflow.provider_lease_id(goal_a, part_a, lease_claude),
    @workflow.provider_lease_id(goal_a, part_a, lease_claude),
  )
  assert_true(
    @workflow.provider_lease_id(goal_a, part_a, lease_claude) !=
    @workflow.provider_lease_id(goal_a, part_a, lease_codex),
  )
  assert_true(
    @workflow.provider_lease_id(goal_a, part_a, lease_claude) !=
    @workflow.provider_lease_id(goal_a, @control.PartId("part-b"), lease_claude),
  )
  assert_true(
    @workflow.provider_lease_id(goal_a, part_a, lease_claude) !=
    @workflow.provider_lease_id(@control.GoalId("goal-b"), part_a, lease_claude),
  )
}

///|
/// The capacity policy is keyed by the surface enum through this match, which
/// is the only thing that pairs a `ProviderSurfaceId` with a configured bound.
test "each provider surface reads its own configured bound" {
  let policy : @types.ProviderCapacityPolicy = {
    claude_subscription_cli: 3,
    codex_subscription_cli: 5,
    global_execution_ceiling: None,
  }
  assert_eq(@workflow.provider_surface_capacity(policy, lease_claude), 3)
  assert_eq(@workflow.provider_surface_capacity(policy, lease_codex), 5)
  assert_true(
    @workflow.provider_surface_lease_tag(lease_claude) !=
    @workflow.provider_surface_lease_tag(lease_codex),
  )
}

///|
/// A stored held set has to survive the round trip, and a record that claims a
/// lease twice must not decode: two entries with one id would let one release
/// free two slots.
test "a held set decodes only when its leases are distinct and complete" {
  let held = granted_record(
    @workflow.plan_provider_lease_acquisition(
      @workflow.empty_provider_surface_lease_record(
        lease_claude,
        @control.FencingEpoch(7L),
      ),
      lease_request("goal-a", "part-a", lease_claude, 7L),
      lease_capacity(1),
      100L,
    ),
  )
  assert_eq(
    @workflow.decode_provider_surface_lease_record(
      @workflow.provider_surface_lease_record_bytes(held),
    ).unwrap(),
    held,
  )
  // This record is what the decision itself produced with every field
  // populated, so the durable-shape witness can be checked against it rather
  // than against a second hand-written list.
  assert_manifest_names_stored_keys(
    "ProviderSurfaceLeaseRecord",
    @workflow.provider_surface_lease_record_bytes(held),
  )
  let duplicated : @workflow.ProviderSurfaceLeaseRecord = {
    ..held,
    held: [held.held[0], held.held[0]],
  }
  assert_true(
    @workflow.decode_provider_surface_lease_record(
      @workflow.provider_surface_lease_record_bytes(duplicated),
    )
    is Err(_),
  )
  let unfenced : @workflow.ProviderSurfaceLeaseRecord = {
    ..held,
    held: [{ ..held.held[0], fencing_epoch: @control.FencingEpoch(0L) }],
  }
  assert_true(
    @workflow.decode_provider_surface_lease_record(
      @workflow.provider_surface_lease_record_bytes(unfenced),
    )
    is Err(_),
  )
}
