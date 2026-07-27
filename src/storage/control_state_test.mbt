///|
fn control_observation(
  store_present? : Bool = true,
  store_readable? : Bool = true,
  recorded_generation? : String? = Some("gen-8"),
  residue_present? : Bool = false,
) -> @storage.ControlStateObservation {
  { store_present, store_readable, recorded_generation, residue_present }
}

///|
test "a matching store is used as it stands" {
  assert_eq(
    @storage.decide_control_state(control_observation(), "gen-8"),
    @storage.ControlStateDecision::ControlStateCurrent,
  )
}

///|
test "nothing on disk is created, not reset" {
  // There is nothing to destroy, so the destructive path must not be taken and
  // the resource cleanup it drags along must not run.
  let decision = @storage.decide_control_state(
    control_observation(store_present=false, recorded_generation=None),
    "gen-8",
  )
  assert_eq(decision, @storage.ControlStateDecision::ControlStateInitialize)
  assert_false(@storage.control_state_decision_destroys(decision))
}

///|
/// The reported bug: a missing marker alone authorized deleting the whole
/// control store, releasing claims and purging refs, even though the state
/// decoded perfectly well.
test "a store that recorded no generation is adopted, never destroyed" {
  let decision = @storage.decide_control_state(
    control_observation(recorded_generation=None),
    "gen-8",
  )
  assert_eq(
    decision,
    @storage.ControlStateDecision::ControlStateMigrate(None, "gen-8"),
  )
  assert_false(@storage.control_state_decision_destroys(decision))
}

///|
test "a store from another schema is reset with the mismatch named" {
  let decision = @storage.decide_control_state(
    control_observation(recorded_generation=Some("gen-7")),
    "gen-8",
  )
  assert_eq(
    decision,
    @storage.ControlStateDecision::ControlStateAuthorizedReset(
      @storage.ControlStateResetReason::ControlSchemaIncompatible(
        "gen-7", "gen-8",
      ),
    ),
  )
  assert_true(@storage.control_state_decision_destroys(decision))
}

///|
test "a store that cannot be read is reset before its generation is trusted" {
  // An unreadable store has no trustworthy generation, so the read failure
  // decides rather than whatever happened to be parsed out of it.
  let decision = @storage.decide_control_state(
    control_observation(store_readable=false, recorded_generation=Some("gen-8")),
    "gen-8",
  )
  assert_eq(
    decision,
    @storage.ControlStateDecision::ControlStateAuthorizedReset(
      @storage.ControlStateResetReason::ControlStoreUnreadable,
    ),
  )
}

///|
/// A control root with leftovers but no store is a reset that did not finish.
/// Initializing over it would leave the previous generation's files in place.
test "residue with no store is finished rather than built on" {
  let decision = @storage.decide_control_state(
    control_observation(
      store_present=false,
      recorded_generation=None,
      residue_present=true,
    ),
    "gen-8",
  )
  assert_eq(
    decision,
    @storage.ControlStateDecision::ControlStateAuthorizedReset(
      @storage.ControlStateResetReason::ControlStoreResidue,
    ),
  )
}

///|
/// Restart is the ordinary case: whatever the first decision produced, reading
/// the resulting store again must be a no-op.
test "the state each decision leaves behind reads as current next time" {
  for recorded in [Some("gen-8"), None] {
    let settled = match
      @storage.decide_control_state(
        control_observation(recorded_generation=recorded),
        "gen-8",
      ) {
      @storage.ControlStateDecision::ControlStateCurrent => "gen-8"
      @storage.ControlStateDecision::ControlStateMigrate(_, target) => target
      _ => fail("a readable same-schema store was not kept")
    }
    assert_eq(
      @storage.decide_control_state(
        control_observation(recorded_generation=Some(settled)),
        "gen-8",
      ),
      @storage.ControlStateDecision::ControlStateCurrent,
    )
  }
}
