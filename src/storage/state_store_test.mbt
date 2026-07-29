///|
let digest_a : @control.Digest = @control.Digest(
  "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
)

///|
let digest_b : @control.Digest = @control.Digest(
  "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
)

///|
test "state record schedule classes have a closed storage encoding" {
  let not_schedulable = @storage.StateRecordScheduleClass::StateRecordNotSchedulable
  let schedulable = @storage.StateRecordScheduleClass::StateRecordSchedulable
  assert_eq(@storage.state_record_schedule_class_code(not_schedulable), 0)
  assert_eq(@storage.state_record_schedule_class_code(schedulable), 1)
  match @storage.state_record_schedule_class_from_code(0) {
    Ok(value) => assert_eq(value, not_schedulable)
    Err(_) => fail("zero schedule class did not decode")
  }
  match @storage.state_record_schedule_class_from_code(1) {
    Ok(value) => assert_eq(value, schedulable)
    Err(_) => fail("one schedule class did not decode")
  }
  assert_true(@storage.state_record_schedule_class_from_code(2) is Err(_))
}

///|
test "state transaction validator enforces version fence keys and digests" {
  let valid : @storage.StateTransactionRequest = {
    state: {
      key: @storage.StateRecordKey("goal:g-1"),
      expected_version: None,
      next_version: 1,
      fencing_epoch: @control.FencingEpoch(1L),
      schedule_class: @storage.StateRecordScheduleClass::StateRecordNotSchedulable,
      value_digest: digest_a,
    },
    outbox: {
      semantic_key: @storage.SemanticEventKey("goal:g-1:started"),
      payload_digest: digest_b,
      owner_goal_id: None,
    },
    fault_point: None,
  }
  assert_true(@storage.validate_state_transaction(valid) is Ok(_))
  assert_true(
    @storage.validate_state_transaction({
      ..valid,
      state: { ..valid.state, next_version: 2 },
    })
    is Err(_),
  )
  assert_true(
    @storage.validate_state_transaction({
      ..valid,
      state: { ..valid.state, key: @storage.StateRecordKey("../escape") },
    })
    is Err(_),
  )
  assert_true(
    @storage.validate_state_transaction({
      ..valid,
      state: { ..valid.state, fencing_epoch: @control.FencingEpoch(0L) },
    })
    is Err(_),
  )
}
