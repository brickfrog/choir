///|
test "poller_backoff_delay_after_failure exponential ladder capped at 900s" {
  assert_eq(@poller.poller_backoff_delay_after_failure(0), 30L)
  assert_eq(@poller.poller_backoff_delay_after_failure(1), 60L)
  assert_eq(@poller.poller_backoff_delay_after_failure(2), 120L)
  assert_eq(@poller.poller_backoff_delay_after_failure(3), 240L)
  assert_eq(@poller.poller_backoff_delay_after_failure(4), 480L)
  assert_eq(@poller.poller_backoff_delay_after_failure(5), 900L)
  assert_eq(@poller.poller_backoff_delay_after_failure(6), 900L)
  assert_eq(@poller.poller_backoff_delay_after_failure(50), 900L)
}

///|
fn assert_generation_increased(
  ps : @poller.PollerState,
  before : Int,
  label : String,
) -> Int raise {
  let after = ps.write_generation
  if after <= before {
    fail(label + " did not bump write_generation")
  }
  after
}

///|
async fn poller_test_poll_failure(
  _pr_number : Int,
  _skip_issue : Bool,
) -> (
  Bool,
  @poller.ReviewState,
  String,
  @poller.CiRollupStatus,
  String,
  Bool,
  Bool,
) {
  @async.sleep(0)
  (false, None_, "", Unknown, "", true, false)
}

///|
async fn poller_test_poll_success_open(
  _pr_number : Int,
  _skip_issue : Bool,
) -> (
  Bool,
  @poller.ReviewState,
  String,
  @poller.CiRollupStatus,
  String,
  Bool,
  Bool,
) {
  @async.sleep(0)
  (true, Commented, "sha-open", Success, "body", true, false)
}

///|
async fn poller_test_poll_success_closed(
  _pr_number : Int,
  _skip_issue : Bool,
) -> (
  Bool,
  @poller.ReviewState,
  String,
  @poller.CiRollupStatus,
  String,
  Bool,
  Bool,
) {
  @async.sleep(0)
  (true, Approved, "sha-closed", Success, "", false, false)
}

///|
fn parsed_state_has_pr(content : String, pr_number : Int) -> Bool raise {
  @poller.parse_tracked_prs_json(content).any(fn(pr) {
    pr.pr_number == pr_number
  })
}

///|
fn field_value(fields : Array[@moontrace.Field], key : String) -> Json? {
  for field in fields {
    if field.key == key {
      return Some(field.value)
    }
  }
  None
}

///|
fn retry_exhausted_warn_event(
  events : Array[@moontrace.Event],
) -> @moontrace.Event? {
  for event in events {
    if event.level == @moontrace.Level::Warn &&
      event.message ==
      "poller state persist exhausted retries; on-disk state may be stale, in-memory state retained" {
      return Some(event)
    }
  }
  None
}

///|
fn assert_string_field(
  fields : Array[@moontrace.Field],
  key : String,
  expected : String,
) -> Unit raise {
  match field_value(fields, key) {
    Some(Json::String(value)) => assert_eq(value, expected)
    _ => fail("expected string moontrace field " + key)
  }
}

///|
fn assert_number_field(
  fields : Array[@moontrace.Field],
  key : String,
  expected : Double,
) -> Unit raise {
  match field_value(fields, key) {
    Some(Json::Number(value, ..)) => assert_eq(value, expected)
    _ => fail("expected number moontrace field " + key)
  }
}

///|
async test "PollerState mutations bump write_generation" {
  let ps = @poller.PollerState::new()
  let mut generation = ps.write_generation

  ps.track(1, "agent-1", "branch-1", "main", "url-1", 10L)
  generation = assert_generation_increased(ps, generation, "track")

  ps.ensure_tracked(1, "agent-1b", "branch-1b", "main", "url-1b", 11L)
  generation = assert_generation_increased(
    ps, generation, "ensure_tracked update",
  )

  ps.ensure_tracked(2, "agent-2", "branch-2", "main", "url-2", 12L)
  generation = assert_generation_increased(
    ps, generation, "ensure_tracked insert",
  )

  ignore(ps.transfer_owner("agent-2", "agent-2b", "branch-2b", "main"))
  generation = assert_generation_increased(ps, generation, "transfer_owner")

  ps.track_recovered(
    3,
    "agent-3",
    "branch-3",
    "main",
    "url-3",
    13L,
    Approved,
    "",
    "sha-3",
    Success,
    true,
  )
  generation = assert_generation_increased(ps, generation, "track_recovered")

  let recovered = match ps.get(3) {
    Some(value) => value
    None => fail("expected recovered PR 3")
  }
  ps.restore({ ..recovered, last_review_state: ChangesRequested })
  generation = assert_generation_increased(ps, generation, "restore")

  ignore(ps.untrack_by_agent_id("agent-2b"))
  generation = assert_generation_increased(
    ps, generation, "untrack_by_agent_id",
  )

  ps.untrack(1)
  generation = assert_generation_increased(ps, generation, "untrack")

  ps.track(4, "agent-4", "branch-4", "main", "url-4", 14L)
  generation = assert_generation_increased(ps, generation, "track before tick")

  let noop_ev = fn(_e : @poller.PollEvent, _a : String) -> Unit { () }
  let noop_log = fn(_l : @poller.PollerPrTickLog) -> Unit { () }
  ps.tick_pr_with(4, 100L, 900L, poller_test_poll_failure, noop_ev, noop_log)
  generation = assert_generation_increased(
    ps, generation, "tick failure update",
  )

  ps.tick_pr_with(
    4, 200L, 900L, poller_test_poll_success_open, noop_ev, noop_log,
  )
  generation = assert_generation_increased(
    ps, generation, "tick success update",
  )

  ps.tick_pr_with(
    4, 300L, 900L, poller_test_poll_success_closed, noop_ev, noop_log,
  )
  ignore(assert_generation_increased(ps, generation, "tick closed untrack"))
}

///|
test "Persist sees mutation between read and write and retries" {
  let ps = @poller.PollerState::new()
  ps.track(10, "agent-a", "branch-a", "main", "url-a", 1L)
  let writes : Array[String] = []
  let mut injected = false
  let writer = fn(_path : String, content : String) -> Bool {
    writes.push(content)
    if !injected {
      injected = true
      ps.ensure_tracked(11, "agent-b", "branch-b", "main", "url-b", 2L)
    }
    true
  }

  assert_true(ps.write_state_file("/project", write_file=writer))
  assert_eq(writes.length(), 2)
  assert_true(parsed_state_has_pr(writes[0], 10))
  assert_false(parsed_state_has_pr(writes[0], 11))
  assert_true(parsed_state_has_pr(writes[1], 10))
  assert_true(parsed_state_has_pr(writes[1], 11))
}

///|
test "write_state_file returns false after bounded stale retries" {
  let ps = @poller.PollerState::new()
  ps.track(20, "agent-a", "branch-a", "main", "url-a", 1L)
  let writes : Array[String] = []
  let writer = fn(_path : String, content : String) -> Bool {
    writes.push(content)
    // Unlike the prior one-shot interleaving test, this mutates on every write
    // attempt so `write_state_file` must stop at its bounded retry limit.
    let n = 20 + writes.length()
    ps.ensure_tracked(n, "agent-" + n.to_string(), "branch", "main", "url", 2L)
    true
  }

  assert_false(
    ps.write_state_file("/project", write_file=writer, max_attempts=3),
  )
  assert_eq(writes.length(), 3)
}

///|
test "write_state_file logs warn on retry exhaustion" {
  let ps = @poller.PollerState::new()
  ps.track(30, "agent-a", "branch-a", "main", "url-a", 1L)
  let writer = fn(_path : String, _content : String) -> Bool {
    let n = 30 + ps.write_generation
    ps.ensure_tracked(n, "agent-" + n.to_string(), "branch", "main", "url", 2L)
    true
  }
  let captured : Array[@moontrace.Event] = []

  @moontrace.set_subscriber(fn(event) { captured.push(event) })
  let result = ps.write_state_file(
    "/project",
    write_file=writer,
    max_attempts=2,
  )
  @moontrace.clear_subscriber()

  assert_false(result)
  let warn_event = match retry_exhausted_warn_event(captured) {
    Some(event) => event
    None => fail("expected retry exhaustion warning")
  }
  assert_string_field(
    warn_event.fields,
    "event",
    "poller_persist_retry_exhausted",
  )
  assert_number_field(warn_event.fields, "tracked_count", 3.0)
  assert_number_field(warn_event.fields, "attempts", 2.0)
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
