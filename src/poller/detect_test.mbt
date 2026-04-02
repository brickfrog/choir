///|
fn detect_test_tracked(
  pr_number : Int,
  first_seen : Int64,
  last_review_state : ReviewState,
  last_review_bodies : String,
  last_sha : String,
  last_ci_failed : Bool,
  last_timeout_at : Int64,
) -> TrackedPR {
  {
    pr_number,
    agent_id: "agent",
    branch: "br",
    parent_branch: "main",
    pr_url: "https://ex/pr",
    first_seen,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state,
    last_review_bodies,
    last_sha,
    notified_parent: false,
    last_ci_failed,
    last_timeout_at,
  }
}

///|
test "detect_events ReviewReceived when transitioning None_ to ChangesRequested with body" {
  let tracked = detect_test_tracked(42, 0L, None_, "", "sha0", false, 0L)
  let ev = detect_events(
    tracked,
    ChangesRequested,
    "sha0",
    false,
    "please address",
    100L,
    900L,
  )
  assert_eq(ev.length(), 1)
  match ev[0] {
    ReviewReceived(n, body) => {
      assert_eq(n, 42)
      assert_eq(body, "please address")
    }
    _ => fail("expected ReviewReceived")
  }
}

///|
test "detect_events PRReady when transitioning None_ to Approved" {
  let tracked = detect_test_tracked(7, 0L, None_, "", "abc", false, 0L)
  let ev = detect_events(tracked, Approved, "abc", false, "", 1L, 900L)
  assert_eq(ev.length(), 1)
  match ev[0] {
    PRReady(n) => assert_eq(n, 7)
    _ => fail("expected PRReady")
  }
}

///|
test "detect_events FixesPushed when SHA changes after ChangesRequested" {
  let tracked = detect_test_tracked(
    3,
    0L,
    ChangesRequested,
    "",
    "oldsha",
    false,
    0L,
  )
  let ev = detect_events(
    tracked,
    ChangesRequested,
    "newsha",
    false,
    "",
    10L,
    900L,
  )
  assert_eq(ev.length(), 1)
  match ev[0] {
    FixesPushed(n) => assert_eq(n, 3)
    _ => fail("expected FixesPushed")
  }
}

///|
test "detect_events CIFailed when CI flips from false to true" {
  let tracked = detect_test_tracked(9, 0L, Approved, "", "sha", false, 0L)
  let ev = detect_events(tracked, Approved, "sha", true, "", 5L, 900L)
  assert_eq(ev.length(), 1)
  match ev[0] {
    CIFailed(n) => assert_eq(n, 9)
    _ => fail("expected CIFailed")
  }
}

///|
test "detect_events CIFailureCleared when CI recovers on same head after failure" {
  let tracked = detect_test_tracked(
    11,
    0L,
    ChangesRequested,
    "",
    "sha1",
    true,
    0L,
  )
  let ev = detect_events(
    tracked,
    ChangesRequested,
    "sha1",
    false,
    "",
    10L,
    900L,
  )
  assert_eq(ev.length(), 1)
  match ev[0] {
    CIFailureCleared(n) => assert_eq(n, 11)
    _ => fail("expected CIFailureCleared")
  }
}

///|
test "detect_events suppresses CIFailureCleared when head just changed (FixesPushed tick)" {
  let tracked = detect_test_tracked(
    12,
    0L,
    ChangesRequested,
    "",
    "oldsha",
    true,
    0L,
  )
  let ev = detect_events(
    tracked,
    ChangesRequested,
    "newsha",
    false,
    "",
    10L,
    900L,
  )
  assert_eq(ev.length(), 1)
  match ev[0] {
    FixesPushed(n) => assert_eq(n, 12)
    _ => fail("expected FixesPushed only")
  }
}

///|
test "detect_events ReviewTimeout when idle past timeout with no review content" {
  let tracked = detect_test_tracked(2, 0L, None_, "", "sha", false, 0L)
  let timeout = 100L
  let now = 250L
  let ev = detect_events(tracked, None_, "sha", false, "", now, timeout)
  assert_eq(ev.length(), 1)
  match ev[0] {
    ReviewTimeout(n) => assert_eq(n, 2)
    _ => fail("expected ReviewTimeout")
  }
}

///|
test "detect_events emits nothing when state SHA and CI unchanged" {
  let tracked = detect_test_tracked(
    1,
    0L,
    Commented,
    "same body",
    "deadbeef",
    true,
    0L,
  )
  let ev = detect_events(
    tracked,
    Commented,
    "deadbeef",
    true,
    "same body",
    50L,
    900L,
  )
  assert_eq(ev.length(), 0)
}
