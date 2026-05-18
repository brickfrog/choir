///|
test "parse_iso8601_to_unix_seconds parses canonical Z-suffixed timestamps" {
  // 2026-05-18T00:27:59Z = 1779064079 (matches gh's mergedAt format)
  assert_eq(parse_iso8601_to_unix_seconds("2026-05-18T00:27:59Z"), 1779064079L)
  assert_eq(parse_iso8601_to_unix_seconds("1970-01-01T00:00:00Z"), 0L)
  assert_eq(parse_iso8601_to_unix_seconds(""), 0L)
  assert_eq(parse_iso8601_to_unix_seconds("not-a-timestamp"), 0L)
  assert_eq(parse_iso8601_to_unix_seconds("2026-13-01T00:00:00Z"), 0L)
}
