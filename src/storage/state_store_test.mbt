///|
let digest_a : @control.Digest = @control.Digest(
  "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
)

///|
let digest_b : @control.Digest = @control.Digest(
  "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
)

///|
test "state transaction validator enforces version fence keys and digests" {
  let valid : @storage.StateTransactionRequest = {
    state: {
      key: @storage.StateRecordKey("goal:g-1"),
      expected_version: None,
      next_version: 1,
      fencing_epoch: @control.FencingEpoch(1L),
      value_digest: digest_a,
    },
    outbox: {
      semantic_key: @storage.SemanticEventKey("goal:g-1:started"),
      payload_digest: digest_b,
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
