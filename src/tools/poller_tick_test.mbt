///|
async fn mock_poll_failure_sentinel(
  _pr_number : Int,
) -> (Bool, @poller.ReviewState, String, Bool, String, Bool) {
  @async.sleep(0)
  (false, @poller.ReviewState::None_, "", false, "", true)
}

///|
async fn mock_poll_success_open(
  _pr_number : Int,
) -> (Bool, @poller.ReviewState, String, Bool, String, Bool) {
  @async.sleep(0)
  (true, @poller.ReviewState::Commented, "sha-1", false, "body", true)
}

///|
async test "tick_with applies exponential backoff after gh failure sentinel" {
  let ps = @poller.PollerState::new()
  ps.track(11, "main.leaf", "main.leaf", "main", "u", 100L)
  let _ = ps.tick_with(
    200L,
    3600L,
    mock_poll_failure_sentinel,
    fn(_e : @poller.PollEvent, _a : String) -> Unit { () },
    fn(_l : @poller.PollerPrTickLog) -> Unit { () },
  )
  match ps.get(11) {
    Some(t) => {
      assert_eq(t.consecutive_failures, 1)
      assert_eq(t.backoff_until, 260L)
    }
    None => fail("expected PR 11")
  }
}

///|
async test "tick_with skips polling while within backoff window" {
  let ps = @poller.PollerState::new()
  ps.track(12, "main.leaf", "main.leaf", "main", "u", 100L)
  let noop_ev = fn(_e : @poller.PollEvent, _a : String) -> Unit { () }
  let noop_log = fn(_l : @poller.PollerPrTickLog) -> Unit { () }
  let _ = ps.tick_with(
    200L, 3600L, mock_poll_failure_sentinel, noop_ev, noop_log,
  )
  let _ = ps.tick_with(220L, 3600L, mock_poll_success_open, noop_ev, noop_log)
  match ps.get(12) {
    Some(t) => {
      assert_eq(t.consecutive_failures, 1)
      assert_eq(t.backoff_until, 260L)
      assert_eq(t.last_sha, "")
    }
    None => fail("expected PR 12")
  }
}

///|
async test "tick_with resets failure counters after successful poll" {
  let ps = @poller.PollerState::new()
  ps.track(13, "main.leaf", "main.leaf", "main", "u", 100L)
  let noop_ev = fn(_e : @poller.PollEvent, _a : String) -> Unit { () }
  let noop_log = fn(_l : @poller.PollerPrTickLog) -> Unit { () }
  let _ = ps.tick_with(
    200L, 3600L, mock_poll_failure_sentinel, noop_ev, noop_log,
  )
  let _ = ps.tick_with(300L, 3600L, mock_poll_success_open, noop_ev, noop_log)
  match ps.get(13) {
    Some(t) => {
      assert_eq(t.consecutive_failures, 0)
      assert_eq(t.backoff_until, 0L)
      assert_eq(t.last_sha, "sha-1")
    }
    None => fail("expected PR 13")
  }
}

///|
async test "tick_with clamps failure counter at max bound" {
  let ps = @poller.PollerState::new()
  ps.track(14, "main.leaf", "main.leaf", "main", "u", 100L)
  let mut now = 200L
  for i = 0; i < 12; i = i + 1 {
    let _ = ps.tick_with(
      now,
      3600L,
      mock_poll_failure_sentinel,
      fn(_e : @poller.PollEvent, _a : String) -> Unit { () },
      fn(_l : @poller.PollerPrTickLog) -> Unit { () },
    )
    now = now + 300L
  }
  match ps.get(14) {
    Some(t) => assert_eq(t.consecutive_failures, 10)
    None => fail("expected PR 14")
  }
}
