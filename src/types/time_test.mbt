///|
test "non_negative_i64 clamps negative values and preserves zero positive values" {
  assert_eq(non_negative_i64(-1L), 0L)
  assert_eq(non_negative_i64(0L), 0L)
  assert_eq(non_negative_i64(42L), 42L)
}

///|
test "parse_iso8601_to_unix_seconds_opt parses canonical Z-suffixed timestamps" {
  // 2026-05-18T00:27:59Z = 1779064079 (matches gh's mergedAt format)
  @debug.assert_eq(
    parse_iso8601_to_unix_seconds_opt("2026-05-18T00:27:59Z"),
    Some(1779064079L),
  )
  @debug.assert_eq(
    parse_iso8601_to_unix_seconds_opt("1970-01-01T00:00:00Z"),
    Some(0L),
  )
}

///|
test "parse_iso8601_to_unix_seconds_opt rejects non-canonical timestamps" {
  @debug.assert_eq(parse_iso8601_to_unix_seconds_opt(""), None)
  @debug.assert_eq(parse_iso8601_to_unix_seconds_opt("not-a-timestamp"), None)
  @debug.assert_eq(
    parse_iso8601_to_unix_seconds_opt("2026-13-01T00:00:00Z"),
    None,
  )
  @debug.assert_eq(
    parse_iso8601_to_unix_seconds_opt("2026-02-29T00:00:00Z"),
    None,
  )
  @debug.assert_eq(
    parse_iso8601_to_unix_seconds_opt("2028-02-29T00:00:00Z"),
    Some(1835395200L),
  )
  @debug.assert_eq(
    parse_iso8601_to_unix_seconds_opt("2026-05-18T00:27:59+02:00"),
    None,
  )
  @debug.assert_eq(
    parse_iso8601_to_unix_seconds_opt("2026-05-18T00:27:59.000Z"),
    None,
  )
  @debug.assert_eq(
    parse_iso8601_to_unix_seconds_opt("2026/05/18T00:27:59Z"),
    None,
  )
}

///|
test "parse_iso8601_to_unix_seconds preserves zero sentinel wrapper" {
  assert_eq(parse_iso8601_to_unix_seconds("2026-05-18T00:27:59Z"), 1779064079L)
  assert_eq(parse_iso8601_to_unix_seconds("1970-01-01T00:00:00Z"), 0L)
  assert_eq(parse_iso8601_to_unix_seconds(""), 0L)
  assert_eq(parse_iso8601_to_unix_seconds("not-a-timestamp"), 0L)
  assert_eq(parse_iso8601_to_unix_seconds("2026-13-01T00:00:00Z"), 0L)
}
