///|
let control_schema : @storage.ControlStoreSchema = {
  generation: "gen-8",
  ddl_version: 3,
}

///|
fn control_observation(
  store_present? : Bool = true,
  store_readable? : Bool = true,
  recorded_generation? : String? = Some("gen-8"),
  recorded_ddl_version? : Int = 3,
  residue_present? : Bool = false,
) -> @storage.ControlStateObservation {
  {
    store_present,
    store_readable,
    recorded_generation,
    recorded_ddl_version,
    residue_present,
  }
}

///|
fn control_plan(
  observation : @storage.ControlStateObservation,
) -> @storage.ControlStatePlan raise {
  match @storage.decide_control_state(observation, control_schema) {
    @storage.ControlStateDecision::ControlStatePlanned(plan) => plan
    @storage.ControlStateDecision::ControlStateProveRecordsDecodable(_, _, _) =>
      fail("the decision needed the records read")
  }
}

///|
test "a matching store is used as it stands" {
  assert_eq(
    control_plan(control_observation()),
    @storage.ControlStatePlan::ControlStateCurrent,
  )
}

///|
test "nothing on disk is created, not reset" {
  // There is nothing to destroy, so the destructive path must not be taken and
  // the resource cleanup it drags along must not run.
  assert_eq(
    control_plan(
      control_observation(
        store_present=false,
        recorded_generation=None,
        recorded_ddl_version=0,
      ),
    ),
    @storage.ControlStatePlan::ControlStateInitialize,
  )
}

///|
/// The originally reported bug: a missing marker alone authorized deleting the
/// whole control store, releasing claims and purging refs, even though the
/// state decoded perfectly well.
test "a store that recorded no generation is adopted, never destroyed" {
  assert_eq(
    control_plan(control_observation(recorded_generation=None)),
    @storage.ControlStatePlan::ControlStateMigrate(None, control_schema),
  )
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
      control_schema,
    ),
    @storage.ControlStateDecision::ControlStateProveRecordsDecodable(
      "gen-7",
      "gen-8",
      None,
    ),
  )
}

///|
test "records that still decode under a moved generation are adopted" {
  assert_eq(
    @storage.decide_control_state_from_records("gen-7", control_schema, None),
    @storage.ControlStatePlan::ControlStateMigrate(
      Some("gen-7"),
      control_schema,
    ),
  )
}

///|
test "a record this build cannot decode is what authorizes the reset" {
  assert_eq(
    @storage.decide_control_state_from_records(
      "gen-7",
      control_schema,
      Some(@storage.StateRecordKey("workflow:w-1")),
    ),
    @storage.ControlStatePlan::ControlStateAuthorizedReset(
      @storage.ControlStateResetReason::ControlRecordUndecodable(
        @storage.StateRecordKey("workflow:w-1"),
        "gen-7",
        "gen-8",
      ),
    ),
  )
}

///|
test "a store that cannot be read is reset before its generation is trusted" {
  // An unreadable store has no trustworthy generation, so the read failure
  // decides rather than whatever happened to be parsed out of it.
  assert_eq(
    control_plan(
      control_observation(
        store_readable=false,
        recorded_generation=Some("gen-8"),
      ),
    ),
    @storage.ControlStatePlan::ControlStateAuthorizedReset(
      @storage.ControlStateResetReason::ControlStoreUnreadable,
    ),
  )
}

///|
/// A control root with leftovers but no store is a reset that did not finish.
/// Initializing over it would leave the previous generation's files in place.
test "residue with no store is finished rather than built on" {
  assert_eq(
    control_plan(
      control_observation(
        store_present=false,
        recorded_generation=None,
        recorded_ddl_version=0,
        residue_present=true,
      ),
    ),
    @storage.ControlStatePlan::ControlStateAuthorizedReset(
      @storage.ControlStateResetReason::ControlStoreResidue,
    ),
  )
}

///|
/// The failure the DDL version exists for: the tables on disk were built by an
/// older `CREATE TABLE`, so a query naming a column they do not have fails
/// before any record is read. The generation cannot see it — it digests record
/// values, not table shape — so a matching generation must not rescue it.
test "tables built by a superseded DDL are reset, matching generation or not" {
  for generation in [Some("gen-8"), Some("gen-7"), None] {
    assert_eq(
      control_plan(
        control_observation(
          recorded_generation=generation,
          recorded_ddl_version=2,
        ),
      ),
      @storage.ControlStatePlan::ControlStateAuthorizedReset(
        @storage.ControlStateResetReason::ControlStoreDdlSuperseded(2, 3),
      ),
    )
  }
}

///|
test "the additive outbox-owner DDL is migrated without resetting state" {
  let expected : @storage.ControlStoreSchema = {
    generation: "gen-8",
    ddl_version: 2,
  }
  assert_eq(
    @storage.decide_control_state(
      control_observation(recorded_ddl_version=1),
      expected,
    ),
    @storage.ControlStateDecision::ControlStatePlanned(
      @storage.ControlStatePlan::ControlStateMigrateDdl(1, expected),
    ),
  )
  assert_eq(
    @storage.decide_control_state(
      control_observation(
        recorded_generation=Some("gen-7"),
        recorded_ddl_version=1,
      ),
      expected,
    ),
    @storage.ControlStateDecision::ControlStateProveRecordsDecodable(
      "gen-7",
      "gen-8",
      Some(1),
    ),
  )
  assert_eq(
    @storage.decide_control_state_from_records(
      "gen-7",
      expected,
      None,
      ddl_migration_from=Some(1),
    ),
    @storage.ControlStatePlan::ControlStateMigrateDdl(1, expected),
  )
}

///|
/// A store running ahead of this build is the same failure seen from the other
/// side: its tables are not the ones this build's SQL names.
test "tables built by a newer DDL are reset too" {
  assert_eq(
    control_plan(control_observation(recorded_ddl_version=4)),
    @storage.ControlStatePlan::ControlStateAuthorizedReset(
      @storage.ControlStateResetReason::ControlStoreDdlSuperseded(4, 3),
    ),
  )
}

///|
/// Every store that predates the stamp was created by the DDL the stamp was
/// introduced with, so it is adopted rather than destroyed — but it must be
/// stamped, or the version stays 0 forever and never becomes load-bearing for
/// it. That makes it a migration, not Current.
test "an unstamped store is stamped rather than destroyed or waved through" {
  assert_eq(
    control_plan(control_observation(recorded_ddl_version=0)),
    @storage.ControlStatePlan::ControlStateMigrate(
      Some("gen-8"),
      control_schema,
    ),
  )
}

///|
/// Restart is the ordinary case: whatever the first decision produced, reading
/// the resulting store again must be a no-op. The moved-generation and
/// unstamped-DDL cases are included because adoption is what they settle on,
/// and adopting twice would be a loop that rewrites the store on every start.
/// A moved generation on an unstamped store is the one that has to travel the
/// whole route — out through `ProveRecordsDecodable` and back in through
/// `decide_control_state_from_records` — and land on a schema carrying both the
/// new generation and the stamp.
test "the state each decision leaves behind reads as current next time" {
  for
    observed in [
      control_observation(),
      control_observation(recorded_generation=None),
      control_observation(recorded_generation=Some("gen-7")),
      control_observation(recorded_ddl_version=0),
      control_observation(recorded_generation=None, recorded_ddl_version=0),
      control_observation(
        recorded_generation=Some("gen-7"),
        recorded_ddl_version=0,
      ),
    ] {
    let plan = match @storage.decide_control_state(observed, control_schema) {
      @storage.ControlStateDecision::ControlStatePlanned(planned) => planned
      @storage.ControlStateDecision::ControlStateProveRecordsDecodable(
        from,
        _,
        ddl_migration_from
      ) =>
        @storage.decide_control_state_from_records(
          from,
          control_schema,
          None,
          ddl_migration_from~,
        )
    }
    let settled = match plan {
      @storage.ControlStatePlan::ControlStateCurrent =>
        (observed.recorded_generation, observed.recorded_ddl_version)
      @storage.ControlStatePlan::ControlStateMigrate(_, recorded) =>
        (Some(recorded.generation), recorded.ddl_version)
      @storage.ControlStatePlan::ControlStateMigrateDdl(_, recorded) =>
        (Some(recorded.generation), recorded.ddl_version)
      _ => fail("a readable store whose records decode was not kept")
    }
    assert_eq(
      control_plan(
        control_observation(
          recorded_generation=settled.0,
          recorded_ddl_version=settled.1,
        ),
      ),
      @storage.ControlStatePlan::ControlStateCurrent,
    )
  }
}
