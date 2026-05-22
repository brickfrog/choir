///|
test "AuditLoopExhausted exposes message wire string and Show output" {
  let receipt_path = ".choir/audit-receipts/abcdef123456.json"
  let err = @types.ChoirError::audit_loop_exhausted(3, 2, receipt_path)
  let expected = "audit loop exhausted after 3 cycle(s) with 2 finding(s) remaining; receipt: " +
    receipt_path
  assert_eq(err.to_wire_string(), "audit_loop_exhausted")
  assert_eq(err.message(), expected)
  assert_eq(err.to_string(), expected)
}

///|
test "AuditIncomplete exposes retryable audit detail" {
  let err = @types.ChoirError::audit_incomplete("audit worker did not report")
  assert_eq(err.to_wire_string(), "audit_incomplete")
  assert_eq(err.message(), "audit incomplete: audit worker did not report")
  assert_eq(err.validation_detail_or_message(), "audit worker did not report")
  assert_true(err.is_audit_incomplete())
}
