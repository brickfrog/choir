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
test "TrackedPR audit receipt state defaults for old JSON and round-trips" {
  let old_json =
    #|[
    #|  {
    #|    "pr_number": 41,
    #|    "agent_id": "main.leaf",
    #|    "branch": "work/leaf",
    #|    "parent_branch": "main",
    #|    "pr_url": "https://example.test/pr/41",
    #|    "first_seen": 1,
    #|    "last_review_state": "approved",
    #|    "last_review_bodies": "",
    #|    "last_sha": "old-head",
    #|    "notified_parent": true,
    #|    "last_ci_rollup": "success",
    #|    "last_timeout_at": 0
    #|  }
    #|]
  let old = @poller.parse_tracked_prs_json(old_json)
  assert_eq(old.length(), 1)
  assert_eq(old[0].audit_receipt_state, @types.AuditReceiptState::NotRequired)

  let pending_json =
    #|[
    #|  {
    #|    "pr_number": 42,
    #|    "agent_id": "main.leaf",
    #|    "branch": "work/leaf",
    #|    "parent_branch": "main",
    #|    "pr_url": "https://example.test/pr/42",
    #|    "first_seen": 1,
    #|    "last_review_state": "approved",
    #|    "last_review_bodies": "",
    #|    "last_sha": "head",
    #|    "notified_parent": true,
    #|    "last_ci_rollup": "success",
    #|    "last_timeout_at": 0,
    #|    "audit_receipt_state": ["Pending",{"head_sha":"abc"}]
    #|  }
    #|]
  let pending = @poller.parse_tracked_prs_json(pending_json)
  assert_eq(
    pending[0].audit_receipt_state,
    @types.AuditReceiptState::Pending(head_sha="abc"),
  )
  let pending_round_trip = @poller.parse_tracked_prs_json(
    "[" + pending[0].to_json() + "]",
  )
  assert_eq(
    pending_round_trip[0].audit_receipt_state,
    @types.AuditReceiptState::Pending(head_sha="abc"),
  )

  let findings_json =
    #|[
    #|  {
    #|    "pr_number": 43,
    #|    "agent_id": "main.leaf",
    #|    "branch": "work/leaf",
    #|    "parent_branch": "main",
    #|    "pr_url": "https://example.test/pr/43",
    #|    "first_seen": 1,
    #|    "last_review_state": "approved",
    #|    "last_review_bodies": "",
    #|    "last_sha": "head",
    #|    "notified_parent": true,
    #|    "last_ci_rollup": "success",
    #|    "last_timeout_at": 0,
    #|    "audit_receipt_state": ["FindingsRemain",{"head_sha":"abc","count":2}]
    #|  }
    #|]
  let findings = @poller.parse_tracked_prs_json(findings_json)
  assert_eq(
    findings[0].audit_receipt_state,
    @types.AuditReceiptState::FindingsRemain(head_sha="abc", count=2),
  )
  let findings_round_trip = @poller.parse_tracked_prs_json(
    "[" + findings[0].to_json() + "]",
  )
  assert_eq(
    findings_round_trip[0].audit_receipt_state,
    @types.AuditReceiptState::FindingsRemain(head_sha="abc", count=2),
  )
}

///|
test "PollerState merge receipts are bounded markers" {
  let ps = @poller.PollerState::new()
  ps.mark_merged_observed(10)
  assert_true(ps.merged_observed(10))
  for i = 0; i < 140; i = i + 1 {
    ps.mark_merged_observed(1000 + i)
  }
  assert_true(ps.merged_observed.length() <= 128)
  assert_true(ps.merged_observed(1139))
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
  @poller.Mergeable,
  @poller.MergeStateStatus,
  Int64?,
) {
  @async.sleep(0)
  (
    false,
    None_,
    "",
    Unknown,
    "",
    true,
    false,
    @poller.Mergeable::Unknown,
    @poller.MergeStateStatus::Unknown,
    None,
  )
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
  @poller.Mergeable,
  @poller.MergeStateStatus,
  Int64?,
) {
  @async.sleep(0)
  (
    true,
    Commented,
    "sha-open",
    Success,
    "body",
    true,
    false,
    @poller.Mergeable::Unknown,
    @poller.MergeStateStatus::Unknown,
    None,
  )
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
  @poller.Mergeable,
  @poller.MergeStateStatus,
  Int64?,
) {
  @async.sleep(0)
  (
    true,
    Approved,
    "sha-closed",
    Success,
    "",
    false,
    false,
    @poller.Mergeable::Mergeable,
    @poller.MergeStateStatus::Clean,
    Some(1779064079L),
  )
}

///|
async fn poller_test_poll_success_closed_unmerged(
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
  @poller.Mergeable,
  @poller.MergeStateStatus,
  Int64?,
) {
  @async.sleep(0)
  (
    true,
    Approved,
    "sha-closed-unmerged",
    Success,
    "",
    false,
    false,
    @poller.Mergeable::Unknown,
    @poller.MergeStateStatus::Unknown,
    None,
  )
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
    if event.level == @moontrace.Level::Warn {
      match field_value(event.fields, "event") {
        Some(Json::String("poller_persist_retry_exhausted")) =>
          return Some(event)
        _ => ()
      }
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
async test "tick_with closed PR event carries mergeability snapshot" {
  let ps = @poller.PollerState::new()
  ps.track(44, "agent-44", "branch-44", "main", "url-44", 1L)
  let events : Array[@poller.PollEvent] = []
  let noop_log = fn(_l : @poller.PollerPrTickLog) -> Unit { () }
  ps.tick_pr_with(
    44,
    100L,
    900L,
    poller_test_poll_success_closed,
    fn(event, _agent_id) { events.push(event) },
    noop_log,
  )
  assert_eq(events.length(), 1)
  match events[0] {
    @poller.PollEvent::PRMerged(pr) => {
      assert_eq(pr.mergeable, @poller.Mergeable::Mergeable)
      assert_eq(pr.merge_state_status, @poller.MergeStateStatus::Clean)
      @debug.assert_eq(pr.merged_at_unix, Some(1779064079L))
    }
    _ => fail("expected PRMerged event")
  }
}

///|
async test "tick_with closed PR suppresses already observed merge event" {
  let ps = @poller.PollerState::new()
  ps.track(45, "agent-45", "branch-45", "main", "url-45", 1L)
  ps.mark_merged_observed(45)
  let events : Array[@poller.PollEvent] = []
  let logs : Array[@poller.PollerPrTickLog] = []
  ps.tick_pr_with(
    45,
    100L,
    900L,
    poller_test_poll_success_closed,
    fn(event, _agent_id) { events.push(event) },
    fn(log) { logs.push(log) },
  )
  assert_eq(events.length(), 0)
  assert_true(ps.get(45) is None)
  assert_eq(logs.length(), 1)
  assert_true(logs[0].untracked_closed)
  assert_eq(logs[0].events.length(), 0)
}

///|
async test "tick_with closed unmerged PR emits PRClosedUnmerged not PRMerged (choir-56ax)" {
  let ps = @poller.PollerState::new()
  ps.track(46, "agent-46", "branch-46", "main", "url-46", 1L)
  let events : Array[@poller.PollEvent] = []
  let logs : Array[@poller.PollerPrTickLog] = []
  ps.tick_pr_with(
    46,
    100L,
    900L,
    poller_test_poll_success_closed_unmerged,
    fn(event, _agent_id) { events.push(event) },
    fn(log) { logs.push(log) },
  )
  // Exactly one PRClosedUnmerged event — NEVER PRMerged for a close.
  assert_eq(events.length(), 1)
  match events[0] {
    @poller.PollEvent::PRClosedUnmerged(pr) => {
      assert_eq(pr.pr_number, 46)
      assert_true(pr.merged_at_unix is None)
      assert_true(pr.closed_unmerged_notified)
    }
    _ => fail("expected PRClosedUnmerged event")
  }
  for e in events {
    match e {
      @poller.PollEvent::PRMerged(_) =>
        fail("must NOT emit PRMerged for a close")
      _ => ()
    }
  }
  // Not a merge: never recorded in the merged-observed receipt cache.
  assert_false(ps.merged_observed(46))
  // Untracked only AFTER the emit (the event carries the TrackedPR by value).
  assert_true(ps.get(46) is None)
  assert_eq(logs.length(), 1)
  assert_true(logs[0].untracked_closed)
  assert_eq(logs[0].events.length(), 1)
}

///|
async test "tick_with closed unmerged PR does not re-emit when already notified (choir-56ax AR-5)" {
  let ps = @poller.PollerState::new()
  ps.track(47, "agent-47", "branch-47", "main", "url-47", 1L)
  // Simulate a re-detect of a PR already flagged as closed-unmerged-notified.
  match ps.get(47) {
    Some(t) => ps.restore({ ..t, closed_unmerged_notified: true })
    None => fail("expected PR 47")
  }
  let events : Array[@poller.PollEvent] = []
  let logs : Array[@poller.PollerPrTickLog] = []
  ps.tick_pr_with(
    47,
    100L,
    900L,
    poller_test_poll_success_closed_unmerged,
    fn(event, _agent_id) { events.push(event) },
    fn(log) { logs.push(log) },
  )
  assert_eq(events.length(), 0)
  assert_true(ps.get(47) is None)
  assert_eq(logs.length(), 1)
  assert_true(logs[0].untracked_closed)
  assert_eq(logs[0].events.length(), 0)
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
  assert_eq(t.review_mode, @types.Config::default().review_mode)
  @debug.assert_eq(t.unresolved_thread_ids, [])
  assert_eq(t.unresolved_thread_ids_fetched, false)
  assert_eq(t.auto_resolve_outdated_pending, false)
  assert_eq(t.last_automerge_attempt_sha, "")
  assert_eq(t.mergeable, @poller.Mergeable::Unknown)
  assert_eq(t.merge_state_status, @poller.MergeStateStatus::Unknown)
  @debug.assert_eq(t.merged_at_unix, None)
}

///|
test "parse_tracked_prs_json defaults unknown review_mode instead of failing" {
  let json =
    #|[
    #|  {
    #|    "pr_number": 2,
    #|    "agent_id": "a",
    #|    "branch": "b",
    #|    "parent_branch": "main",
    #|    "pr_url": "u",
    #|    "first_seen": 1,
    #|    "last_review_state": "approved",
    #|    "last_review_bodies": "",
    #|    "last_sha": "sha",
    #|    "notified_parent": false,
    #|    "last_ci_rollup": "success",
    #|    "last_timeout_at": 0,
    #|    "review_mode": "future_mode"
    #|  }
    #|]
  let parsed = @poller.parse_tracked_prs_json(json)
  assert_eq(parsed.length(), 1)
  assert_eq(parsed[0].review_mode, @types.Config::default().review_mode)
}

///|
test "poller_state json round-trips review mode and unresolved thread refs" {
  let ps = @poller.PollerState::new()
  ps.track(
    8,
    "agent-8",
    "branch-8",
    "main",
    "https://example.test/pr/8",
    80L,
    review_mode=@types.ReviewMode::SinglePass,
  )
  let tracked = match ps.get(8) {
    Some(value) => value
    None => fail("expected tracked PR")
  }
  ps.restore({
    ..tracked,
    unresolved_thread_ids: [
      @poller.ReviewThreadRef::{
        id: "T_old",
        is_outdated: true,
        author_login: "copilot-pull-request-reviewer[bot]",
      },
      @poller.ReviewThreadRef::{
        id: "T_current",
        is_outdated: false,
        author_login: "octocat",
      },
    ],
    unresolved_thread_ids_fetched: true,
    auto_resolve_outdated_pending: true,
    last_automerge_attempt_sha: "attempt-sha",
    mergeable: @poller.Mergeable::Conflicting,
    merge_state_status: @poller.MergeStateStatus::Behind,
    merged_at_unix: Some(1779064079L),
  })
  let parsed = @poller.parse_tracked_prs_json(ps.to_json())
  assert_eq(parsed.length(), 1)
  assert_eq(parsed[0].review_mode, @types.ReviewMode::SinglePass)
  assert_eq(parsed[0].last_automerge_attempt_sha, "attempt-sha")
  assert_eq(parsed[0].mergeable, @poller.Mergeable::Conflicting)
  assert_eq(parsed[0].merge_state_status, @poller.MergeStateStatus::Behind)
  @debug.assert_eq(parsed[0].merged_at_unix, Some(1779064079L))
  @debug.assert_eq(parsed[0].unresolved_thread_ids, [
    @poller.ReviewThreadRef::{
      id: "T_old",
      is_outdated: true,
      author_login: "copilot-pull-request-reviewer[bot]",
    },
    @poller.ReviewThreadRef::{
      id: "T_current",
      is_outdated: false,
      author_login: "octocat",
    },
  ])
  assert_eq(parsed[0].unresolved_thread_ids_fetched, true)
  assert_eq(parsed[0].auto_resolve_outdated_pending, true)
}

///|
test "poller_state json round-trips untracked merge boundary" {
  let ps = @poller.PollerState::new()
  ps.set_untracked_merge_boundary_unix(4102358400L)
  ps.track(9, "agent-9", "branch-9", "main", "https://example.test/pr/9", 90L)

  let parsed = @poller.parse_poller_state_json(ps.to_json())
  assert_eq(parsed.untracked_merge_boundary_unix, 4102358400L)
  assert_eq(parsed.tracked.length(), 1)
  @debug.assert_eq(parsed.get(9).map(fn(pr) { pr.agent_id }), Some("agent-9"))

  let tracked_only = @poller.parse_tracked_prs_json(ps.to_json())
  assert_eq(tracked_only.length(), 1)
  assert_eq(tracked_only[0].pr_number, 9)

  let legacy = @poller.parse_poller_state_json("[]")
  assert_eq(legacy.untracked_merge_boundary_unix, 0L)
  assert_eq(legacy.tracked.length(), 0)
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
