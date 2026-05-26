///|
test "AuditIncomplete exposes retryable audit detail" {
  let err = @types.ChoirError::audit_incomplete("audit worker did not report")
  assert_eq(err.to_wire_string(), "audit_incomplete")
  assert_eq(err.message(), "audit incomplete: audit worker did not report")
  assert_eq(err.validation_detail_or_message(), "audit worker did not report")
  assert_true(err.is_audit_incomplete())
}
