///|
test "parse_logs_cli_args supports default merged tail and filters" {
  let defaults = parse_logs_cli_args(["choir", "logs"]).unwrap()
  assert_true(defaults.source == LogsSource::Merged)
  assert_eq(defaults.tail_n, 100)
  assert_false(defaults.follow)
  @debug.assert_eq(defaults.grep, None)
  @debug.assert_eq(defaults.level, None)
  let got = parse_logs_cli_args([
    "choir", "logs", "--source", "events", "agent-a", "--tail", "12", "--follow",
    "--grep", "poller", "--level", "warn",
  ]).unwrap()
  assert_true(got.source == LogsSource::Events("agent-a"))
  assert_eq(got.tail_n, 12)
  assert_true(got.follow)
  @debug.assert_eq(got.grep, Some("poller"))
  @debug.assert_eq(got.level, Some(LogLevel::Warn))
}

///|
test "parse_logs_cli_args rejects missing source payloads" {
  match parse_logs_cli_args(["choir", "logs", "--source", "wave"]) {
    Err(e) =>
      assert_true(e.message().contains("--source wave requires a wave id"))
    Ok(_) => fail("missing wave id should fail")
  }
  match parse_logs_cli_args(["choir", "logs", "--tail", "0"]) {
    Err(e) => assert_true(e.message().contains("--tail must be positive"))
    Ok(_) => fail("zero tail should fail")
  }
}

///|
test "line_timestamp parses serve and iso prefixes" {
  @debug.assert_eq(
    line_timestamp("09:08:07.123 | INFO | choir - ready"),
    Some("09:08:07.123"),
  )
  @debug.assert_eq(
    line_timestamp("2026-05-12T09:08:07Z [poller] delivered"),
    Some("09:08:07.000"),
  )
  @debug.assert_eq(line_timestamp("[poller] no timestamp"), None)
}

///|
test "merge_log_lines orders timestamped lines and leaves untimestamped last" {
  let got = merge_log_lines(
    [
      "09:00:02.000 | INFO | choir - serve later", "serve untimestamped", "09:00:03.000 | INFO | choir - equal a",
    ],
    [
      "2026-05-12T09:00:01Z [poller] delivery first", "2026-05-12T09:00:03Z [poller] equal b",
      "delivery untimestamped",
    ],
  )
  assert_eq(got, [
    "2026-05-12T09:00:01Z [poller] delivery first", "09:00:02.000 | INFO | choir - serve later",
    "09:00:03.000 | INFO | choir - equal a", "2026-05-12T09:00:03Z [poller] equal b",
    "serve untimestamped", "delivery untimestamped",
  ])
}

///|
test "line_level parses pipe-delimited severity field" {
  @debug.assert_eq(
    line_level("09:00:00.000 | WARN | choir - warning"),
    Some(LogLevel::Warn),
  )
  @debug.assert_eq(
    line_level("09:00:00.000 | TRACE | choir - trace"),
    Some(LogLevel::Trace),
  )
  @debug.assert_eq(line_level("[poller] no level"), None)
}

///|
test "apply_filters applies level grep and tail in order" {
  let opts : LogsCliOptions = {
    source: LogsSource::Merged,
    tail_n: 2,
    follow: false,
    grep: Some("keep"),
    level: Some(LogLevel::Warn),
    help: false,
  }
  let got = apply_filters(
    [
      "09:00:00.000 | INFO | choir - keep but too low", "09:00:01.000 | WARN | choir - keep warning",
      "09:00:02.000 | ERROR | choir - keep error", "[poller] keep delivery without level",
      "09:00:03.000 | DEBUG | choir - other",
    ],
    opts,
  )
  assert_eq(got, [
    "09:00:02.000 | ERROR | choir - keep error", "[poller] keep delivery without level",
  ])
}
