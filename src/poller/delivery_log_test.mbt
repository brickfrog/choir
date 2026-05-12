///|
test "delivery_log_timestamp formats ISO timestamp with milliseconds" {
  let base = @tempo.DateTime::parse("2026-05-10T06:30:00Z").to_unix_seconds() *
    1000L
  assert_eq(delivery_log_timestamp(base + 7L), "2026-05-10T06:30:00.007Z")
  assert_eq(delivery_log_timestamp(base + 42L), "2026-05-10T06:30:00.042Z")
  assert_eq(delivery_log_timestamp(base + 321L), "2026-05-10T06:30:00.321Z")
}

///|
test "delivery_log_line keeps tag after timestamp" {
  let base = @tempo.DateTime::parse("2026-05-10T06:30:00Z").to_unix_seconds() *
    1000L
  assert_eq(
    delivery_log_line("[poller] tick", now_ms=base + 5L),
    "2026-05-10T06:30:00.005Z [poller] tick\n",
  )
}
