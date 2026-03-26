///|
#borrow(cmd)
extern "C" fn c_system_poller_test(cmd : Bytes) -> Int = "system"

///|
fn string_to_null_terminated_bytes_poller(s : String) -> Bytes {
  let b = @utf8.encode(s)
  let len = b.length()
  let result = FixedArray::make(len + 1, (0 : Byte))
  for i = 0; i < len; i = i + 1 {
    result[i] = b[i]
  }
  result[len] = (0 : Byte)
  result.unsafe_reinterpret_as_bytes()
}

///|
fn run_shell_poller(script : String) -> Unit {
  ignore(
    c_system_poller_test(
      string_to_null_terminated_bytes_poller("sh -c '" + script + "'"),
    ),
  )
}

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
    last_review_bodies: "",
    last_sha: sha,
    notified_parent,
    last_ci_failed,
    last_timeout_at: 0L,
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
test "PollerState::ensure_tracked preserves review memory for existing PR" {
  let state = PollerState::new()
  state.restore({
    pr_number: 1,
    agent_id: "agent1",
    branch: "main.agent1",
    parent_branch: "main",
    pr_url: "https://example.test/pr/1",
    first_seen: 100L,
    last_review_state: ReviewState::ChangesRequested,
    last_review_bodies: "Please fix the flaky test",
    last_sha: "sha1",
    notified_parent: false,
    last_ci_failed: true,
    last_timeout_at: 250L,
  })
  state.ensure_tracked(
    1, "agent1", "main.agent1", "release", "https://example.test/pr/1-updated", 999L,
  )
  match state.get(1) {
    Some(pr) => {
      assert_eq(pr.first_seen, 100L)
      assert_eq(pr.last_review_state, ReviewState::ChangesRequested)
      assert_eq(pr.last_review_bodies, "Please fix the flaky test")
      assert_eq(pr.last_sha, "sha1")
      assert_false(pr.notified_parent)
      assert_true(pr.last_ci_failed)
      assert_eq(pr.last_timeout_at, 250L)
      assert_eq(pr.parent_branch, "release")
      assert_eq(pr.pr_url, "https://example.test/pr/1-updated")
    }
    None => fail("tracked PR not found")
  }
}

///|
test "PollerState::transfer_owner moves tracked PR ownership" {
  let state = PollerState::new()
  state.restore({
    pr_number: 22,
    agent_id: "main.leaf-old",
    branch: "main.leaf-old",
    parent_branch: "main",
    pr_url: "https://example.test/pr/22",
    first_seen: 222L,
    last_review_state: ReviewState::ChangesRequested,
    last_review_bodies: "Need fixes",
    last_sha: "sha-old",
    notified_parent: false,
    last_ci_failed: true,
    last_timeout_at: 333L,
  })
  state.restore({
    pr_number: 23,
    agent_id: "main.other",
    branch: "main.other",
    parent_branch: "main",
    pr_url: "https://example.test/pr/23",
    first_seen: 223L,
    last_review_state: ReviewState::Approved,
    last_review_bodies: "",
    last_sha: "sha-other",
    notified_parent: true,
    last_ci_failed: false,
    last_timeout_at: 0L,
  })
  let transferred = state.transfer_owner(
    "main.leaf-old", "main.leaf-new", "main.leaf-new", "main",
  )
  assert_eq(transferred, 1)
  match state.get(22) {
    Some(tracked) => {
      assert_eq(tracked.agent_id, "main.leaf-new")
      assert_eq(tracked.branch, "main.leaf-new")
      assert_eq(tracked.parent_branch, "main")
      assert_eq(tracked.last_review_state, ReviewState::ChangesRequested)
      assert_eq(tracked.last_review_bodies, "Need fixes")
      assert_eq(tracked.last_sha, "sha-old")
      assert_false(tracked.notified_parent)
      assert_true(tracked.last_ci_failed)
      assert_eq(tracked.last_timeout_at, 333L)
    }
    None => fail("expected transferred tracked PR")
  }
  match state.get(23) {
    Some(tracked) => assert_eq(tracked.agent_id, "main.other")
    None => fail("expected unrelated tracked PR")
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
test "PollerState JSON roundtrip preserves tracked metadata" {
  let state = PollerState::new()
  state.restore(
    tracked_pr(
      11,
      "agent11",
      321L,
      ReviewState::ChangesRequested,
      "sha-roundtrip",
      true,
      true,
    ),
  )
  let parsed = parse_tracked_prs_json(state.to_json())
  assert_eq(parsed.length(), 1)
  assert_eq(parsed[0].pr_number, 11)
  assert_eq(parsed[0].agent_id, "agent11")
  assert_eq(parsed[0].branch, "main.agent11")
  assert_eq(parsed[0].parent_branch, "main")
  assert_eq(parsed[0].pr_url, "https://example.test/pr/agent11")
  assert_eq(parsed[0].first_seen, 321L)
  assert_eq(parsed[0].last_review_state, ReviewState::ChangesRequested)
  assert_eq(parsed[0].last_review_bodies, "")
  assert_eq(parsed[0].last_sha, "sha-roundtrip")
  assert_true(parsed[0].notified_parent)
  assert_true(parsed[0].last_ci_failed)
  assert_eq(parsed[0].last_timeout_at, 0L)
}

///|
test "PollerState JSON roundtrip preserves last_timeout_at" {
  let state = PollerState::new()
  state.restore({
    ..tracked_pr(
      13,
      "agent13",
      400L,
      ReviewState::None_,
      "sha-timeout",
      false,
      false,
    ),
    last_timeout_at: 999L,
  })
  let parsed = parse_tracked_prs_json(state.to_json())
  assert_eq(parsed.length(), 1)
  assert_eq(parsed[0].last_timeout_at, 999L)
}

///|
test "PollerState write_state_file and read_state_file roundtrip" {
  let project_dir = "/tmp/choir-poller-state"
  run_shell_poller(
    "rm -rf /tmp/choir-poller-state && mkdir -p /tmp/choir-poller-state/.choir",
  )
  let state = PollerState::new()
  state.restore(
    tracked_pr(
      12,
      "agent12",
      654L,
      ReviewState::Approved,
      "sha-file",
      true,
      false,
    ),
  )
  assert_true(state.write_state_file(project_dir))
  let parsed = read_state_file(project_dir)
  assert_eq(parsed.length(), 1)
  assert_eq(parsed[0].pr_number, 12)
  assert_eq(parsed[0].last_review_state, ReviewState::Approved)
  assert_eq(parsed[0].last_sha, "sha-file")
  assert_true(parsed[0].notified_parent)
  run_shell_poller("rm -rf /tmp/choir-poller-state")
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
test "detect_events::comment_only_review" {
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
    "Looks good overall, but clarify the docs wording.",
    110,
    1000,
  )
  assert_eq(events, [
    PollEvent::ReviewCommented(
      1, "Looks good overall, but clarify the docs wording.",
    ),
  ])
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
test "detect_events::timeout does not re-fire within same interval" {
  let tracked : TrackedPR = {
    ..tracked_pr(1, "agent1", 100, ReviewState::None_, "sha1", false, false),
    last_timeout_at: 1100L,
  }
  // 30s later (1130) — not enough time since last notification (needs 1000)
  let events = detect_events(
    tracked,
    ReviewState::None_,
    "sha1",
    false,
    "",
    1130,
    1000,
  )
  assert_eq(events, [])
}

///|
test "detect_events::timeout re-fires after full interval" {
  let tracked : TrackedPR = {
    ..tracked_pr(1, "agent1", 100, ReviewState::None_, "sha1", false, false),
    last_timeout_at: 1100L,
  }
  // Another full interval later (2100)
  let events = detect_events(
    tracked,
    ReviewState::None_,
    "sha1",
    false,
    "",
    2100,
    1000,
  )
  assert_eq(events, [PollEvent::ReviewTimeout(1)])
}

///|
test "detect_events::timeout suppressed when review bodies exist" {
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
    "Automated review summary",
    1200,
    1000,
  )
  // Should get ReviewCommented but NOT ReviewTimeout
  assert_eq(events, [PollEvent::ReviewCommented(1, "Automated review summary")])
}

///|
test "detect_events::timeout suppressed when prior review bodies recorded" {
  let tracked : TrackedPR = {
    ..tracked_pr(1, "agent1", 100, ReviewState::None_, "sha1", false, false),
    last_review_bodies: "Previous review content",
  }
  let events = detect_events(
    tracked,
    ReviewState::None_,
    "sha1",
    false,
    "Previous review content",
    1200,
    1000,
  )
  // Same bodies as before — no new ReviewReceived, no timeout
  assert_eq(events, [])
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
  let (review, sha, _, _, _) = parse_gh_pr_view_output(
    "{\"reviews\":[{\"state\":\"COMMENTED\"},{\"state\":\"CHANGES_REQUESTED\"},{\"state\":\"APPROVED\"}],\"headRefOid\":\"abc123\"}",
  )
  assert_eq(review, ReviewState::Approved)
  assert_eq(sha, "abc123")
}

///|
test "parse_gh_pr_view_output falls back on missing fields" {
  let (review, sha, _, _, _) = parse_gh_pr_view_output("{\"reviews\":[]}")
  assert_eq(review, ReviewState::None_)
  assert_eq(sha, "")
}

///|
async test "PollerState::tick_with updates tracked state and emits events" {
  let state = PollerState::new()
  state.track(
    7, "agent7", "main.agent7", "main", "https://example.test/pr/7", 100,
  )
  let events = []
  let agent_ids = []
  state.tick_with(
    200,
    900L,
    fn(_pr_number) { (ReviewState::Approved, "sha2", false, "", true) },
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
}

///|
async test "PollerState::tick_with marks fixes pushed as parent-notified" {
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
    fn(_pr_number) { (ReviewState::ChangesRequested, "sha2", false, "", true) },
    fn(event, _agent_id) { events.push(event) },
  )
  assert_eq(events, [PollEvent::FixesPushed(8)])
  match state.get(8) {
    Some(tracked) => assert_true(tracked.notified_parent)
    None => fail("tracked PR not found")
  }
}

///|
async test "PollerState::tick_with resets parent notification on new review request" {
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
      (ReviewState::ChangesRequested, "sha2", false, "Please fix", true)
    },
    fn(event, _agent_id) { events.push(event) },
  )
  assert_eq(events, [PollEvent::ReviewReceived(9, "Please fix")])
  match state.get(9) {
    Some(tracked) => assert_false(tracked.notified_parent)
    None => fail("tracked PR not found")
  }
}

///|
async test "PollerState::tick_with tracks latest comment-only review bodies" {
  let state = PollerState::new()
  state.track(
    10, "agent10", "main.agent10", "main", "https://example.test/pr/10", 100,
  )
  let events = []
  state.tick_with(
    200,
    900L,
    fn(_pr_number) {
      (
        ReviewState::None_,
        "sha10",
        false,
        "Please tighten the wording in .choir/context/common.md",
        true,
      )
    },
    fn(event, _agent_id) { events.push(event) },
  )
  assert_eq(events, [
    PollEvent::ReviewCommented(
      10, "Please tighten the wording in .choir/context/common.md",
    ),
  ])
  match state.get(10) {
    Some(tracked) => {
      assert_eq(
        tracked.last_review_bodies,
        "Please tighten the wording in .choir/context/common.md",
      )
      assert_false(tracked.notified_parent)
    }
    None => fail("tracked PR not found")
  }
}

///|
async test "PollerState::tick_with records last_timeout_at and throttles re-fire" {
  let state = PollerState::new()
  state.track(
    20, "agent20", "main.agent20", "main", "https://example.test/pr/20", 100,
  )
  let events = []
  // First tick at t=1200 — timeout fires (first_seen=100, timeout=900)
  state.tick_with(
    1200,
    900L,
    fn(_pr_number) { (ReviewState::None_, "sha1", false, "", true) },
    fn(event, _agent_id) { events.push(event) },
  )
  assert_eq(events, [PollEvent::ReviewTimeout(20)])
  match state.get(20) {
    Some(tracked) => assert_eq(tracked.last_timeout_at, 1200L)
    None => fail("tracked PR not found")
  }
  // Second tick 100s later — does NOT re-fire (needs 900s since last)
  let events2 = []
  state.tick_with(
    1300,
    900L,
    fn(_pr_number) { (ReviewState::None_, "sha1", false, "", true) },
    fn(event, _agent_id) { events2.push(event) },
  )
  assert_eq(events2, [])
  // Third tick 900s later — re-fires
  let events3 = []
  state.tick_with(
    2200,
    900L,
    fn(_pr_number) { (ReviewState::None_, "sha1", false, "", true) },
    fn(event, _agent_id) { events3.push(event) },
  )
  assert_eq(events3, [PollEvent::ReviewTimeout(20)])
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
  let (review, sha, ci_failed, _, _) = parse_gh_pr_view_output(
    "{\"reviews\":[],\"headRefOid\":\"abc\",\"statusCheckRollup\":[{\"state\":\"FAILURE\"}]}",
  )
  assert_eq(review, ReviewState::None_)
  assert_eq(sha, "abc")
  assert_true(ci_failed)
}

///|
test "parse_gh_pr_view_output CI passing is not failed" {
  let (review, sha, ci_failed, _, _) = parse_gh_pr_view_output(
    "{\"reviews\":[],\"headRefOid\":\"abc\",\"statusCheckRollup\":[{\"state\":\"SUCCESS\"}]}",
  )
  assert_eq(review, ReviewState::None_)
  assert_eq(sha, "abc")
  assert_false(ci_failed)
}

///|
test "parse_gh_pr_view_output ERROR state is ci_failed" {
  let (_, _, ci_failed, _, _) = parse_gh_pr_view_output(
    "{\"reviews\":[],\"headRefOid\":\"\",\"statusCheckRollup\":[{\"state\":\"ERROR\"}]}",
  )
  assert_true(ci_failed)
}

///|
test "parse_review_bodies extracts non-empty review bodies" {
  let (_, _, _, bodies, _) = parse_gh_pr_view_output(
    "{\"reviews\":[{\"state\":\"CHANGES_REQUESTED\",\"body\":\"Please fix the indentation\"},{\"state\":\"COMMENTED\",\"body\":\"Also update the docs\"}],\"headRefOid\":\"abc\",\"statusCheckRollup\":[]}",
  )
  assert_true(bodies.contains("Please fix the indentation"))
  assert_true(bodies.contains("Also update the docs"))
}

///|
test "parse_review_bodies ignores empty bodies" {
  let (_, _, _, bodies, _) = parse_gh_pr_view_output(
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
