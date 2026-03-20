///|
fn tracked_pr(
  pr_number : Int,
  agent_id : String,
  first_seen : Int64,
  review_state : ReviewState,
  sha : String,
  notified_parent : Bool,
  last_ci_failed : Bool,
) -> TrackedPR {
  {
    pr_number,
    agent_id,
    branch: "main." + agent_id,
    parent_branch: "main",
    pr_url: "https://example.test/pr/" + agent_id,
    first_seen,
    last_review_state: review_state,
    last_sha: sha,
    notified_parent,
    last_ci_failed,
  }
}

///|
test "PollerState::track and get" {
  let state = PollerState::new()
  state.track(
    1, "agent1", "main.agent1", "main", "https://example.test/pr/1", 100,
  )
  match state.get(1) {
    Some(pr) => {
      assert_eq(pr.pr_number, 1)
      assert_eq(pr.agent_id, "agent1")
      assert_eq(pr.branch, "main.agent1")
      assert_eq(pr.parent_branch, "main")
      assert_eq(pr.pr_url, "https://example.test/pr/1")
      assert_eq(pr.first_seen, 100)
    }
    None => fail("PR not found")
  }
}

///|
test "PollerState::untrack" {
  let state = PollerState::new()
  state.track(
    1, "agent1", "main.agent1", "main", "https://example.test/pr/1", 100,
  )
  state.untrack(1)
  match state.get(1) {
    Some(_) => fail("PR still exists")
    None => ()
  }
}

///|
test "PollerState::in_critical_phase detects pending changes requested" {
  let state = PollerState::new()
  state.tracked.set(
    9,
    tracked_pr(
      9,
      "agent9",
      100L,
      ReviewState::ChangesRequested,
      "sha1",
      false,
      false,
    ),
  )
  assert_true(state.in_critical_phase("agent9"))
  assert_false(state.in_critical_phase("other-agent"))
}

///|
test "PollerState::in_critical_phase ignores pushed fixes" {
  let state = PollerState::new()
  state.tracked.set(
    10,
    tracked_pr(
      10,
      "agent10",
      100L,
      ReviewState::ChangesRequested,
      "sha2",
      true,
      false,
    ),
  )
  assert_false(state.in_critical_phase("agent10"))
}

///|
test "detect_events::approval" {
  let tracked : TrackedPR = tracked_pr(
    1,
    "agent1",
    100,
    ReviewState::None_,
    "sha1",
    false,
    false,
  )
  let events = detect_events(
    tracked,
    ReviewState::Approved,
    "sha1",
    false,
    "",
    110,
    1000,
  )
  assert_eq(events, [PollEvent::PRReady(1)])
}

///|
test "detect_events::changes_requested" {
  let tracked : TrackedPR = tracked_pr(
    1,
    "agent1",
    100,
    ReviewState::None_,
    "sha1",
    false,
    false,
  )
  let events = detect_events(
    tracked,
    ReviewState::ChangesRequested,
    "sha1",
    false,
    "",
    110,
    1000,
  )
  assert_eq(events, [PollEvent::ReviewReceived(1, "")])
}

///|
test "detect_events::fixes_pushed" {
  let tracked : TrackedPR = tracked_pr(
    1,
    "agent1",
    100,
    ReviewState::ChangesRequested,
    "sha1",
    false,
    false,
  )
  let events = detect_events(
    tracked,
    ReviewState::ChangesRequested,
    "sha2",
    false,
    "",
    110,
    1000,
  )
  assert_eq(events, [PollEvent::FixesPushed(1)])
}

///|
test "detect_events::timeout" {
  let tracked : TrackedPR = tracked_pr(
    1,
    "agent1",
    100,
    ReviewState::None_,
    "sha1",
    false,
    false,
  )
  let events = detect_events(
    tracked,
    ReviewState::None_,
    "sha1",
    false,
    "",
    1200,
    1000,
  )
  assert_eq(events, [PollEvent::ReviewTimeout(1)])
}

///|
test "detect_events::no_change" {
  let tracked : TrackedPR = tracked_pr(
    1,
    "agent1",
    100,
    ReviewState::Approved,
    "sha1",
    false,
    false,
  )
  let events = detect_events(
    tracked,
    ReviewState::Approved,
    "sha1",
    false,
    "",
    110,
    1000,
  )
  assert_eq(events, [])
}

///|
test "parse_gh_pr_view_output returns last actionable review and head sha" {
  let (review, sha, _, _) = parse_gh_pr_view_output(
    "{\"reviews\":[{\"state\":\"COMMENTED\"},{\"state\":\"CHANGES_REQUESTED\"},{\"state\":\"APPROVED\"}],\"headRefOid\":\"abc123\"}",
  )
  assert_eq(review, ReviewState::Approved)
  assert_eq(sha, "abc123")
}

///|
test "parse_gh_pr_view_output falls back on missing fields" {
  let (review, sha, _, _) = parse_gh_pr_view_output("{\"reviews\":[]}")
  assert_eq(review, ReviewState::None_)
  assert_eq(sha, "")
}

///|
test "PollerState::tick_with updates tracked state and emits events" {
  @async.with_event_loop(_ => {
    let state = PollerState::new()
    state.track(
      7, "agent7", "main.agent7", "main", "https://example.test/pr/7", 100,
    )
    let events = []
    let agent_ids = []
    state.tick_with(
      200,
      900L,
      fn(_pr_number) { (ReviewState::Approved, "sha2", false, "") },
      fn(event, agent_id) {
        events.push(event)
        agent_ids.push(agent_id)
      },
    )
    assert_eq(events, [PollEvent::PRReady(7)])
    assert_eq(agent_ids, ["agent7"])
    match state.get(7) {
      Some(tracked) => {
        assert_eq(tracked.last_review_state, ReviewState::Approved)
        assert_eq(tracked.last_sha, "sha2")
        assert_true(tracked.notified_parent)
        assert_false(tracked.last_ci_failed)
      }
      None => fail("tracked PR not found")
    }
  })
}

///|
test "PollerState::tick_with marks fixes pushed as parent-notified" {
  @async.with_event_loop(_ => {
    let state = PollerState::new()
    state.tracked.set(
      8,
      tracked_pr(
        8,
        "agent8",
        100L,
        ReviewState::ChangesRequested,
        "sha1",
        false,
        false,
      ),
    )
    let events = []
    state.tick_with(
      200,
      900L,
      fn(_pr_number) { (ReviewState::ChangesRequested, "sha2", false, "") },
      fn(event, _agent_id) { events.push(event) },
    )
    assert_eq(events, [PollEvent::FixesPushed(8)])
    match state.get(8) {
      Some(tracked) => assert_true(tracked.notified_parent)
      None => fail("tracked PR not found")
    }
  })
}

///|
test "PollerState::tick_with resets parent notification on new review request" {
  @async.with_event_loop(_ => {
    let state = PollerState::new()
    state.tracked.set(
      9,
      tracked_pr(9, "agent9", 100L, ReviewState::Approved, "sha2", true, false),
    )
    let events = []
    state.tick_with(
      200,
      900L,
      fn(_pr_number) {
        (ReviewState::ChangesRequested, "sha2", false, "Please fix")
      },
      fn(event, _agent_id) { events.push(event) },
    )
    assert_eq(events, [PollEvent::ReviewReceived(9, "Please fix")])
    match state.get(9) {
      Some(tracked) => assert_false(tracked.notified_parent)
      None => fail("tracked PR not found")
    }
  })
}

///|
test "detect_events::ci_failed fires once" {
  let tracked : TrackedPR = tracked_pr(
    1,
    "agent1",
    100,
    ReviewState::None_,
    "sha1",
    false,
    false,
  )
  let events = detect_events(
    tracked,
    ReviewState::None_,
    "sha1",
    true,
    "",
    110,
    1000,
  )
  assert_eq(events, [PollEvent::CIFailed(1)])
}

///|
test "detect_events::ci_failed does not re-fire if already failed" {
  let tracked : TrackedPR = tracked_pr(
    1,
    "agent1",
    100,
    ReviewState::None_,
    "sha1",
    false,
    true,
  )
  let events = detect_events(
    tracked,
    ReviewState::None_,
    "sha1",
    true,
    "",
    110,
    1000,
  )
  assert_eq(events, [])
}

///|
test "parse_gh_pr_view_output detects CI failure" {
  let (review, sha, ci_failed, _) = parse_gh_pr_view_output(
    "{\"reviews\":[],\"headRefOid\":\"abc\",\"statusCheckRollup\":[{\"state\":\"FAILURE\"}]}",
  )
  assert_eq(review, ReviewState::None_)
  assert_eq(sha, "abc")
  assert_true(ci_failed)
}

///|
test "parse_gh_pr_view_output CI passing is not failed" {
  let (review, sha, ci_failed, _) = parse_gh_pr_view_output(
    "{\"reviews\":[],\"headRefOid\":\"abc\",\"statusCheckRollup\":[{\"state\":\"SUCCESS\"}]}",
  )
  assert_eq(review, ReviewState::None_)
  assert_eq(sha, "abc")
  assert_false(ci_failed)
}

///|
test "parse_gh_pr_view_output ERROR state is ci_failed" {
  let (_, _, ci_failed, _) = parse_gh_pr_view_output(
    "{\"reviews\":[],\"headRefOid\":\"\",\"statusCheckRollup\":[{\"state\":\"ERROR\"}]}",
  )
  assert_true(ci_failed)
}

///|
test "parse_review_bodies extracts non-empty review bodies" {
  let (_, _, _, bodies) = parse_gh_pr_view_output(
    "{\"reviews\":[{\"state\":\"CHANGES_REQUESTED\",\"body\":\"Please fix the indentation\"},{\"state\":\"COMMENTED\",\"body\":\"Also update the docs\"}],\"headRefOid\":\"abc\",\"statusCheckRollup\":[]}",
  )
  assert_true(bodies.contains("Please fix the indentation"))
  assert_true(bodies.contains("Also update the docs"))
}

///|
test "parse_review_bodies ignores empty bodies" {
  let (_, _, _, bodies) = parse_gh_pr_view_output(
    "{\"reviews\":[{\"state\":\"APPROVED\",\"body\":\"\"}],\"headRefOid\":\"abc\",\"statusCheckRollup\":[]}",
  )
  assert_eq(bodies, "")
}

///|
test "detect_events::changes_requested carries review bodies" {
  let tracked : TrackedPR = tracked_pr(
    1,
    "agent1",
    100,
    ReviewState::None_,
    "sha1",
    false,
    false,
  )
  let events = detect_events(
    tracked,
    ReviewState::ChangesRequested,
    "sha1",
    false,
    "Fix the type error on line 42",
    110,
    1000,
  )
  assert_eq(events, [
    PollEvent::ReviewReceived(1, "Fix the type error on line 42"),
  ])
}
