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
fn control_plan(
  observation : @storage.ControlStateObservation,
  expected : String,
) -> @storage.ControlStatePlan raise {
  match @storage.decide_control_state(observation, expected) {
    @storage.ControlStateDecision::ControlStatePlanned(plan) => plan
    @storage.ControlStateDecision::ControlStateProveRecordsDecodable(_, _) =>
      fail("the decision needed the records read")
  }
}

///|
test "a matching store is used as it stands" {
  assert_eq(
    control_plan(control_observation(), "gen-8"),
    @storage.ControlStatePlan::ControlStateCurrent,
  )
}

///|
test "nothing on disk is created, not reset" {
  // There is nothing to destroy, so the destructive path must not be taken and
  // the resource cleanup it drags along must not run.
  let plan = control_plan(
    control_observation(store_present=false, recorded_generation=None),
    "gen-8",
  )
  assert_eq(plan, @storage.ControlStatePlan::ControlStateInitialize)
  assert_false(@storage.control_state_plan_destroys(plan))
}

///|
/// The originally reported bug: a missing marker alone authorized deleting the
/// whole control store, releasing claims and purging refs, even though the
/// state decoded perfectly well.
test "a store that recorded no generation is adopted, never destroyed" {
  let plan = control_plan(
    control_observation(recorded_generation=None),
    "gen-8",
  )
  assert_eq(plan, @storage.ControlStatePlan::ControlStateMigrate(None, "gen-8"))
  assert_false(@storage.control_state_plan_destroys(plan))
}

///|
/// The generation is a digest, and a digest reports only "not equal". Deciding
/// to destroy on that alone would wipe healthy state every time a shape changed
/// in a way its own encoding tolerates — an added optional field, a new enum
/// variant — which is a broader version of the harm above.
test "a store from another generation is not judged before it is read" {
  assert_eq(
    @storage.decide_control_state(
      control_observation(recorded_generation=Some("gen-7")),
      "gen-8",
    ),
    @storage.ControlStateDecision::ControlStateProveRecordsDecodable(
      "gen-7", "gen-8",
    ),
  )
}

///|
test "records that still decode under a moved generation are adopted" {
  let plan = @storage.decide_control_state_from_records("gen-7", "gen-8", None)
  assert_eq(
    plan,
    @storage.ControlStatePlan::ControlStateMigrate(Some("gen-7"), "gen-8"),
  )
  assert_false(@storage.control_state_plan_destroys(plan))
}

///|
test "a record this build cannot decode is what authorizes the reset" {
  let plan = @storage.decide_control_state_from_records(
    "gen-7",
    "gen-8",
    Some(@storage.StateRecordKey("workflow:w-1")),
  )
  assert_eq(
    plan,
    @storage.ControlStatePlan::ControlStateAuthorizedReset(
      @storage.ControlStateResetReason::ControlRecordUndecodable(
        @storage.StateRecordKey("workflow:w-1"),
        "gen-7",
        "gen-8",
      ),
    ),
  )
  assert_true(@storage.control_state_plan_destroys(plan))
}

///|
test "a store that cannot be read is reset before its generation is trusted" {
  // An unreadable store has no trustworthy generation, so the read failure
  // decides rather than whatever happened to be parsed out of it.
  let plan = control_plan(
    control_observation(store_readable=false, recorded_generation=Some("gen-8")),
    "gen-8",
  )
  assert_eq(
    plan,
    @storage.ControlStatePlan::ControlStateAuthorizedReset(
      @storage.ControlStateResetReason::ControlStoreUnreadable,
    ),
  )
}

///|
/// A control root with leftovers but no store is a reset that did not finish.
/// Initializing over it would leave the previous generation's files in place.
test "residue with no store is finished rather than built on" {
  let plan = control_plan(
    control_observation(
      store_present=false,
      recorded_generation=None,
      residue_present=true,
    ),
    "gen-8",
  )
  assert_eq(
    plan,
    @storage.ControlStatePlan::ControlStateAuthorizedReset(
      @storage.ControlStateResetReason::ControlStoreResidue,
    ),
  )
}

///|
/// Restart is the ordinary case: whatever the first decision produced, reading
/// the resulting store again must be a no-op. The moved-generation case is
/// included because adoption is what it settles on, and adopting twice would be
/// a loop that rewrites the store on every start.
test "the state each decision leaves behind reads as current next time" {
  for recorded in [Some("gen-8"), None, Some("gen-7")] {
    let plan = match
      @storage.decide_control_state(
        control_observation(recorded_generation=recorded),
        "gen-8",
      ) {
      @storage.ControlStateDecision::ControlStatePlanned(planned) => planned
      @storage.ControlStateDecision::ControlStateProveRecordsDecodable(from, to) =>
        @storage.decide_control_state_from_records(from, to, None)
    }
    let settled = match plan {
      @storage.ControlStatePlan::ControlStateCurrent => "gen-8"
      @storage.ControlStatePlan::ControlStateMigrate(_, target) => target
      _ => fail("a readable store whose records decode was not kept")
    }
    assert_eq(
      control_plan(
        control_observation(recorded_generation=Some(settled)),
        "gen-8",
      ),
      @storage.ControlStatePlan::ControlStateCurrent,
    )
  }
}
