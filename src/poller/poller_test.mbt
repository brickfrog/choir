///|
test "transfer_owner reassigns all tracked PRs to replacement leaf" {
  let ps = @poller.PollerState::new()
  let now = @poller.now_sec()
  ps.track(7, "main.leaf-a", "main.leaf-a", "main", "https://ex/pr/7", now)
  ps.track(8, "main.leaf-a", "main.leaf-a", "main", "https://ex/pr/8", now)
  let transferred = ps.transfer_owner(
    "main.leaf-a", "main.leaf-b", "main.leaf-a", "main",
  )
  assert_eq(transferred, 2)
  match ps.get(7) {
    Some(t) => {
      assert_eq(t.agent_id, "main.leaf-b")
      assert_eq(t.branch, "main.leaf-a")
      assert_eq(t.parent_branch, "main")
    }
    None => fail("expected PR 7 after transfer")
  }
  match ps.get(8) {
    Some(t) => assert_eq(t.agent_id, "main.leaf-b")
    None => fail("expected PR 8 after transfer")
  }
}

///|
test "transfer_owner keeps prior branch metadata when new branch fields empty" {
  let ps = @poller.PollerState::new()
  let now = 42L
  ps.track(3, "main.from", "main.feat", "main", "u", now)
  let transferred = ps.transfer_owner("main.from", "main.to", "", "")
  assert_eq(transferred, 1)
  match ps.get(3) {
    Some(t) => {
      assert_eq(t.agent_id, "main.to")
      assert_eq(t.branch, "main.feat")
      assert_eq(t.parent_branch, "main")
    }
    None => fail("expected PR 3")
  }
}

///|
test "transfer_owner overwrites branch when replacement publishes new head name" {
  let ps = @poller.PollerState::new()
  let now = 1L
  ps.track(5, "main.v0", "main.v0", "main", "u", now)
  ignore(
    ps.transfer_owner("main.v0", "main.v1", "main.shared-topic", "develop"),
  )
  match ps.get(5) {
    Some(t) => {
      assert_eq(t.agent_id, "main.v1")
      assert_eq(t.branch, "main.shared-topic")
      assert_eq(t.parent_branch, "develop")
    }
    None => fail("expected PR 5")
  }
}

///|
async fn mock_poll_failure_sentinel(
  _pr_number : Int,
) -> (@poller.ReviewState, String, Bool, String, Bool) {
  @async.sleep(0)
  (@poller.ReviewState::None_, "", false, "", true)
}

///|
async fn mock_poll_success_open(
  _pr_number : Int,
) -> (@poller.ReviewState, String, Bool, String, Bool) {
  @async.sleep(0)
  (@poller.ReviewState::Commented, "sha-1", false, "body", true)
}

///|
async test "tick_with applies exponential backoff after gh failure sentinel" {
  let ps = @poller.PollerState::new()
  ps.track(11, "main.leaf", "main.leaf", "main", "u", 100L)
  ps.tick_with(200L, 3600L, mock_poll_failure_sentinel, fn(_, _) { () })
  match ps.get(11) {
    Some(t) => {
      assert_eq(t.consecutive_failures, 1)
      // 2^1 * 30 = 60 seconds
      assert_eq(t.backoff_until, 260L)
    }
    None => fail("expected PR 11")
  }
}

///|
async test "tick_with skips polling while within backoff window" {
  let ps = @poller.PollerState::new()
  ps.track(12, "main.leaf", "main.leaf", "main", "u", 100L)
  ps.tick_with(200L, 3600L, mock_poll_failure_sentinel, fn(_, _) { () })
  ps.tick_with(220L, 3600L, mock_poll_success_open, fn(_, _) { () })
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
  ps.tick_with(200L, 3600L, mock_poll_failure_sentinel, fn(_, _) { () })
  ps.tick_with(300L, 3600L, mock_poll_success_open, fn(_, _) { () })
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
test "parse_tracked_prs_json defaults missing backoff fields to zero" {
  let json =
    #|[
    #|  {
    #|    "pr_number": 1,
    #|    "agent_id": "a",
    #|    "branch": "b",
    #|    "parent_branch": "main",
    #|    "pr_url": "u",
    #|    "first_seen": 1,
    #|    "last_review_state": "none",
    #|    "last_review_bodies": "",
    #|    "last_sha": "",
    #|    "notified_parent": false,
    #|    "last_ci_failed": false,
    #|    "last_timeout_at": 0
    #|  }
    #|]
  let parsed = @poller.parse_tracked_prs_json(json)
  assert_eq(parsed.length(), 1)
  let t = parsed[0]
  assert_eq(t.consecutive_failures, 0)
  assert_eq(t.backoff_until, 0L)
}
