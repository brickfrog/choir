///|
test "MutationGateIncomplete exposes retryable mutation gate detail" {
  let err = @types.ChoirError::mutation_gate_incomplete(
    "mutation gate worker did not report",
  )
  assert_eq(err.to_wire_string(), "mutation_gate_incomplete")
  assert_eq(
    err.message(),
    "mutation gate incomplete: mutation gate worker did not report",
  )
  assert_eq(
    err.validation_detail_or_message(),
    "mutation gate worker did not report",
  )
  assert_true(err.is_mutation_gate_incomplete())
}
