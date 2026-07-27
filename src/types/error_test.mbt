///|
/// Control flow used to branch on `to_wire_string() == "canceled"`, which put
/// the wire vocabulary in the middle of cancellation decisions: renaming a tag
/// would silently change what a Part does on cancel instead of failing to
/// compile.
test "error classification is typed rather than spelled" {
  let canceled = @types.ChoirError::canceled("Take interrupted at the cutoff")
  assert_true(canceled.is_canceled())
  assert_false(canceled.is_validation_error())
  assert_false(canceled.is_transport_error())
  let validation = @types.ChoirError::validation_error("bad request")
  assert_true(validation.is_validation_error())
  assert_false(validation.is_canceled())
  let transport = @types.ChoirError::transport_error("socket closed")
  assert_true(transport.is_transport_error())
  assert_false(transport.is_canceled())
  // A timeout is not a cancellation. The string comparison got that right too,
  // but only by accident of spelling.
  let timeout = @types.ChoirError::timeout("Codex Take")
  assert_false(timeout.is_canceled())
  assert_true(timeout.is_timeout())
}

///|
/// The predicates and the wire vocabulary must agree, or a typed check and the
/// tag it replaced would classify the same error differently.
test "each typed predicate matches its own wire tag" {
  assert_eq(@types.ChoirError::canceled("c").to_wire_string(), "canceled")
  assert_eq(
    @types.ChoirError::validation_error("v").to_wire_string(),
    "validation_error",
  )
  assert_eq(
    @types.ChoirError::transport_error("t").to_wire_string(),
    "transport_error",
  )
  assert_true(@types.ChoirError::canceled("c").is_canceled())
  assert_true(@types.ChoirError::validation_error("v").is_validation_error())
  assert_true(@types.ChoirError::transport_error("t").is_transport_error())
}
