///|
test "audit context coverage requires consecutive success through EOF" {
  let digest = @control.Digest("a".repeat(64))
  let reads : Array[@control.AuditContextReadObservation] = [
    {
      digest,
      cursor: 0,
      total: 200000,
      next_cursor: Some(131072),
      eof: false,
      succeeded: true,
    },
    {
      digest,
      cursor: 131072,
      total: 200000,
      next_cursor: None,
      eof: true,
      succeeded: true,
    },
  ]
  assert_eq(
    @control.validate_audit_context_read_coverage(digest, reads).unwrap(),
    200000,
  )
  assert_true(
    @control.validate_audit_context_read_coverage(digest, reads[:1].to_owned())
    is Err(_),
  )
  assert_true(
    @control.validate_audit_context_read_coverage(digest, [
      reads[0],
      { ..reads[1], cursor: 131071 },
    ])
    is Err(_),
  )
  assert_true(
    @control.validate_audit_context_read_coverage(digest, [
      { ..reads[0], digest: @control.Digest("b".repeat(64)) },
      reads[1],
    ])
    is Err(_),
  )
  assert_true(
    @control.validate_audit_context_read_coverage(digest, [
      { ..reads[0], succeeded: false },
      reads[1],
    ])
    is Err(_),
  )
}

///|
test "empty audit context still requires an observed EOF read" {
  let digest = @control.Digest("c".repeat(64))
  assert_eq(
    @control.validate_audit_context_read_coverage(digest, [
      {
        digest,
        cursor: 0,
        total: 0,
        next_cursor: None,
        eof: true,
        succeeded: true,
      },
    ]).unwrap(),
    0,
  )
  assert_true(
    @control.validate_audit_context_read_coverage(digest, []) is Err(_),
  )
}
