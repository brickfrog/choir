///|
test "PollerState::track and get" {
  let state = PollerState::new()
  state.track(1, "agent1", 100)
  match state.get(1) {
    Some(pr) => {
      assert_eq(pr.pr_number, 1)
      assert_eq(pr.agent_id, "agent1")
      assert_eq(pr.first_seen, 100)
    }
    None => fail("PR not found")
  }
}

///|
test "PollerState::untrack" {
  let state = PollerState::new()
  state.track(1, "agent1", 100)
  state.untrack(1)
  match state.get(1) {
    Some(_) => fail("PR still exists")
    None => ()
  }
}

///|
test "detect_events::approval" {
  let tracked : TrackedPR = {
    pr_number: 1,
    agent_id: "agent1",
    first_seen: 100,
    last_review_state: ReviewState::None_,
    last_sha: "sha1",
    notified_parent: false,
  }
  let events = detect_events(tracked, ReviewState::Approved, "sha1", 110, 1000)
  assert_eq(events, [PollEvent::PRReady(1)])
}

///|
test "detect_events::changes_requested" {
  let tracked : TrackedPR = {
    pr_number: 1,
    agent_id: "agent1",
    first_seen: 100,
    last_review_state: ReviewState::None_,
    last_sha: "sha1",
    notified_parent: false,
  }
  let events = detect_events(
    tracked,
    ReviewState::ChangesRequested,
    "sha1",
    110,
    1000,
  )
  assert_eq(events, [PollEvent::ReviewReceived(1, "")])
}

///|
test "detect_events::fixes_pushed" {
  let tracked : TrackedPR = {
    pr_number: 1,
    agent_id: "agent1",
    first_seen: 100,
    last_review_state: ReviewState::ChangesRequested,
    last_sha: "sha1",
    notified_parent: false,
  }
  let events = detect_events(
    tracked,
    ReviewState::ChangesRequested,
    "sha2",
    110,
    1000,
  )
  assert_eq(events, [PollEvent::FixesPushed(1)])
}

///|
test "detect_events::timeout" {
  let tracked : TrackedPR = {
    pr_number: 1,
    agent_id: "agent1",
    first_seen: 100,
    last_review_state: ReviewState::None_,
    last_sha: "sha1",
    notified_parent: false,
  }
  let events = detect_events(tracked, ReviewState::None_, "sha1", 1200, 1000)
  assert_eq(events, [PollEvent::ReviewTimeout(1)])
}

///|
test "detect_events::no_change" {
  let tracked : TrackedPR = {
    pr_number: 1,
    agent_id: "agent1",
    first_seen: 100,
    last_review_state: ReviewState::Approved,
    last_sha: "sha1",
    notified_parent: false,
  }
  let events = detect_events(tracked, ReviewState::Approved, "sha1", 110, 1000)
  assert_eq(events, [])
}

///|
test "parse_gh_pr_view_output returns last actionable review and head sha" {
  let (review, sha) = parse_gh_pr_view_output(
    "{\"reviews\":[{\"state\":\"COMMENTED\"},{\"state\":\"CHANGES_REQUESTED\"},{\"state\":\"APPROVED\"}],\"headRefOid\":\"abc123\"}",
  )
  assert_eq(review, ReviewState::Approved)
  assert_eq(sha, "abc123")
}

///|
test "parse_gh_pr_view_output falls back on missing fields" {
  let (review, sha) = parse_gh_pr_view_output("{\"reviews\":[]}")
  assert_eq(review, ReviewState::None_)
  assert_eq(sha, "")
}

///|
test "PollerState::tick_with updates tracked state and emits events" {
  @async.with_event_loop(fn(_) {
    let state = PollerState::new()
    state.track(7, "agent7", 100)
    let events = []
    let agent_ids = []
    state.tick_with(
      200,
      900L,
      fn(_pr_number) { (ReviewState::Approved, "sha2") },
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
      }
      None => fail("tracked PR not found")
    }
  })
}
