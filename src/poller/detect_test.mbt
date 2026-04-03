///|
fn detect_test_tracked(
  pr_number : Int,
  first_seen : Int64,
  last_review_state : ReviewState,
  last_review_bodies : String,
  last_sha : String,
  last_ci_rollup : CiRollupStatus,
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
    last_ci_rollup,
    last_timeout_at,
    copilot_issue_comment_seen: false,
    orphan_notified: false,
    changes_requested_since: 0L,
    stall_notified: false,
  }
}

///|
test "detect_events ReviewReceived when transitioning None_ to ChangesRequested with body" {
  let tracked = detect_test_tracked(42, 0L, None_, "", "sha0", Success, 0L)
  let ev = detect_events(
    tracked,
    ChangesRequested,
    "sha0",
    Success,
    "please address",
    100L,
    900L,
    false,
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
  let tracked = detect_test_tracked(7, 0L, None_, "", "abc", Success, 0L)
  let ev = detect_events(tracked, Approved, "abc", Success, "", 1L, 900L, false)
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
    Success,
    0L,
  )
  let ev = detect_events(
    tracked,
    ChangesRequested,
    "newsha",
    Success,
    "",
    10L,
    900L,
    false,
  )
  assert_eq(ev.length(), 1)
  match ev[0] {
    FixesPushed(n) => assert_eq(n, 3)
    _ => fail("expected FixesPushed")
  }
}

///|
test "detect_events CIFailed when CI flips from non-failure to failure" {
  let tracked = detect_test_tracked(9, 0L, Approved, "", "sha", Success, 0L)
  let ev = detect_events(tracked, Approved, "sha", Failure, "", 5L, 900L, false)
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
    Failure,
    0L,
  )
  let ev = detect_events(
    tracked,
    ChangesRequested,
    "sha1",
    Success,
    "",
    10L,
    900L,
    false,
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
    Failure,
    0L,
  )
  let ev = detect_events(
    tracked,
    ChangesRequested,
    "newsha",
    Success,
    "",
    10L,
    900L,
    false,
  )
  assert_eq(ev.length(), 1)
  match ev[0] {
    FixesPushed(n) => assert_eq(n, 12)
    _ => fail("expected FixesPushed only")
  }
}

///|
test "detect_events suppresses CIFailureCleared when SHA changes regardless of review state" {
  // Approved state: FixesPushed does not fire, but CIFailureCleared must also
  // be suppressed because the new head may still have pending CI.
  let tracked = detect_test_tracked(13, 0L, Approved, "", "oldsha", Failure, 0L)
  let ev = detect_events(
    tracked,
    Approved,
    "newsha",
    Success,
    "",
    10L,
    900L,
    false,
  )
  assert_eq(ev.length(), 0)
}

///|
test "detect_events no CIFailureCleared when CI stays failed across SHA change" {
  // Even if SHA changes, CIFailureCleared cannot fire when rollup remains failure.
  let tracked = detect_test_tracked(14, 0L, Approved, "", "oldsha", Failure, 0L)
  let ev = detect_events(
    tracked,
    Approved,
    "newsha",
    Failure,
    "",
    10L,
    900L,
    false,
  )
  assert_eq(ev.length(), 0)
}

///|
test "detect_events CILatestHeadRollupSucceeded when InProgress becomes Success on same head" {
  let tracked = detect_test_tracked(
    20,
    0L,
    Approved,
    "",
    "sha-ci",
    InProgress,
    0L,
  )
  let ev = detect_events(
    tracked,
    Approved,
    "sha-ci",
    Success,
    "",
    10L,
    900L,
    false,
  )
  assert_eq(ev.length(), 1)
  match ev[0] {
    CILatestHeadRollupSucceeded(n) => assert_eq(n, 20)
    _ => fail("expected CILatestHeadRollupSucceeded")
  }
}

///|
test "detect_events CILatestHeadRollupSucceeded when Unknown becomes Success on same head" {
  let tracked = detect_test_tracked(21, 0L, Approved, "", "sha-u", Unknown, 0L)
  let ev = detect_events(
    tracked,
    Approved,
    "sha-u",
    Success,
    "",
    11L,
    900L,
    false,
  )
  assert_eq(ev.length(), 1)
  match ev[0] {
    CILatestHeadRollupSucceeded(n) => assert_eq(n, 21)
    _ => fail("expected CILatestHeadRollupSucceeded")
  }
}

///|
test "detect_events no duplicate rollup success when already Success on same head" {
  let tracked = detect_test_tracked(22, 0L, Approved, "", "sha-s", Success, 0L)
  let ev = detect_events(
    tracked,
    Approved,
    "sha-s",
    Success,
    "",
    12L,
    900L,
    false,
  )
  assert_eq(ev.length(), 0)
}

///|
test "detect_events ReviewTimeout when idle past timeout with no review content" {
  let tracked = detect_test_tracked(2, 0L, None_, "", "sha", Success, 0L)
  let timeout = 100L
  let now = 250L
  let ev = detect_events(
    tracked,
    None_,
    "sha",
    Success,
    "",
    now,
    timeout,
    false,
  )
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
    Failure,
    0L,
  )
  let ev = detect_events(
    tracked,
    Commented,
    "deadbeef",
    Failure,
    "same body",
    50L,
    900L,
    false,
  )
  assert_eq(ev.length(), 0)
}

///|
test "detect_events suppresses ReviewTimeout when Copilot issue comment effective without review bodies" {
  let tracked = detect_test_tracked(30, 0L, None_, "", "sha", Success, 0L)
  let timeout = 100L
  let now = 250L
  let ev = detect_events(tracked, None_, "sha", Success, "", now, timeout, true)
  assert_eq(ev.length(), 0)
}
