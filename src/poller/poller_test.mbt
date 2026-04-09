///|
test "poller_backoff_delay_after_failure matches internal ladder" {
  assert_eq(@poller.poller_backoff_delay_after_failure(0), 30L)
  assert_eq(@poller.poller_backoff_delay_after_failure(1), 60L)
  assert_eq(@poller.poller_backoff_delay_after_failure(2), 120L)
  assert_eq(@poller.poller_backoff_delay_after_failure(3), 240L)
  assert_eq(@poller.poller_backoff_delay_after_failure(6), 300L)
  assert_eq(@poller.poller_backoff_delay_after_failure(50), 300L)
}

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
    #|    "last_ci_rollup": "unknown",
    #|    "last_timeout_at": 0
    #|  }
    #|]
  let parsed = @poller.parse_tracked_prs_json(json)
  assert_eq(parsed.length(), 1)
  let t = parsed[0]
  assert_eq(t.consecutive_failures, 0)
  assert_eq(t.backoff_until, 0L)
  assert_eq(t.orphan_reconciling, false)
}

///|
test "parse_tracked_prs_json maps legacy last_ci_failed to CiRollupStatus" {
  let json_legacy_failure =
    #|[
    #|  {
    #|    "pr_number": 2,
    #|    "agent_id": "a",
    #|    "branch": "b",
    #|    "parent_branch": "main",
    #|    "pr_url": "u",
    #|    "first_seen": 1,
    #|    "last_review_state": "none",
    #|    "last_review_bodies": "",
    #|    "last_sha": "",
    #|    "notified_parent": false,
    #|    "last_ci_failed": true,
    #|    "last_timeout_at": 0
    #|  }
    #|]
  let parsed_failure = @poller.parse_tracked_prs_json(json_legacy_failure)
  assert_eq(parsed_failure.length(), 1)
  assert_eq(parsed_failure[0].last_ci_rollup, Failure)
  assert_eq(parsed_failure[0].orphan_reconciling, false)

  let json_legacy_unknown =
    #|[
    #|  {
    #|    "pr_number": 3,
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
  let parsed_unknown = @poller.parse_tracked_prs_json(json_legacy_unknown)
  assert_eq(parsed_unknown.length(), 1)
  assert_eq(parsed_unknown[0].last_ci_rollup, Unknown)
  assert_eq(parsed_unknown[0].orphan_reconciling, false)
}
