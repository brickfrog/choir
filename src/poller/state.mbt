///|
pub(all) struct PollerState {
  tracked : Map[Int, TrackedPR]
}

///|
fn review_state_name(review : ReviewState) -> String {
  match review {
    None_ => "none"
    Approved => "approved"
    ChangesRequested => "changes_requested"
    Commented => "commented"
  }
}

///|
fn parse_review_state_name(s : String) -> ReviewState? {
  match s {
    "none" => Some(None_)
    "approved" => Some(Approved)
    "changes_requested" => Some(ChangesRequested)
    "commented" => Some(Commented)
    _ => None
  }
}

///|
fn tracked_pr_json(tracked : TrackedPR) -> String {
  {
    "pr_number": tracked.pr_number.to_json(),
    "agent_id": tracked.agent_id.to_json(),
    "branch": tracked.branch.to_json(),
    "parent_branch": tracked.parent_branch.to_json(),
    "pr_url": tracked.pr_url.to_json(),
    "first_seen": tracked.first_seen.to_json(),
    "consecutive_failures": tracked.consecutive_failures.to_json(),
    "backoff_until": tracked.backoff_until.to_json(),
    "last_review_state": review_state_name(tracked.last_review_state).to_json(),
    "last_review_bodies": tracked.last_review_bodies.to_json(),
    "last_sha": tracked.last_sha.to_json(),
    "notified_parent": tracked.notified_parent.to_json(),
    "last_ci_failed": tracked.last_ci_failed.to_json(),
    "last_timeout_at": tracked.last_timeout_at.to_json(),
  }
  .to_json()
  .stringify()
}

///|
fn json_field_int(fields : Map[String, Json], key : String) -> Int? {
  match fields.get(key) {
    Some(Number(n, ..)) => Some(n.to_int())
    _ => None
  }
}

///|
fn json_field_int64(fields : Map[String, Json], key : String) -> Int64? {
  match fields.get(key) {
    Some(Number(n, ..)) => Some(n.to_int64())
    Some(String(s)) => {
      let mut res = 0L
      let mut valid = s != ""
      for c in s {
        if c >= '0' && c <= '9' {
          res = res * 10L + (c.to_int() - '0'.to_int()).to_int64()
        } else {
          valid = false
        }
      }
      if valid {
        Some(res)
      } else {
        None
      }
    }
    _ => None
  }
}

///|
fn json_field_bool(fields : Map[String, Json], key : String) -> Bool? {
  match fields.get(key) {
    Some(True) => Some(true)
    Some(False) => Some(false)
    _ => None
  }
}

///|
fn parse_tracked_pr(fields : Map[String, Json]) -> TrackedPR? {
  let pr_number = match json_field_int(fields, "pr_number") {
    Some(value) => value
    None => return None
  }
  let agent_id = match @types.json_field_string(fields, "agent_id") {
    Some(value) => value
    None => return None
  }
  let branch = match @types.json_field_string(fields, "branch") {
    Some(value) => value
    None => return None
  }
  let parent_branch = match @types.json_field_string(fields, "parent_branch") {
    Some(value) => value
    None => return None
  }
  let pr_url = match @types.json_field_string(fields, "pr_url") {
    Some(value) => value
    None => return None
  }
  let first_seen = match json_field_int64(fields, "first_seen") {
    Some(value) => value
    None => return None
  }
  let consecutive_failures = match
    json_field_int(fields, "consecutive_failures") {
    Some(value) => value
    None => 0
  }
  let backoff_until = match json_field_int64(fields, "backoff_until") {
    Some(value) => value
    None => 0L
  }
  let last_review_state = match
    @types.json_field_string(fields, "last_review_state") {
    Some(value) =>
      match parse_review_state_name(value) {
        Some(parsed) => parsed
        None => return None
      }
    None => return None
  }
  let last_review_bodies = match
    @types.json_field_string(fields, "last_review_bodies") {
    Some(value) => value
    None => return None
  }
  let last_sha = match @types.json_field_string(fields, "last_sha") {
    Some(value) => value
    None => return None
  }
  let notified_parent = match json_field_bool(fields, "notified_parent") {
    Some(value) => value
    None => return None
  }
  let last_ci_failed = match json_field_bool(fields, "last_ci_failed") {
    Some(value) => value
    None => return None
  }
  let last_timeout_at = match json_field_int64(fields, "last_timeout_at") {
    Some(value) => value
    None => 0L
  }
  Some({
    pr_number,
    agent_id,
    branch,
    parent_branch,
    pr_url,
    first_seen,
    consecutive_failures,
    backoff_until,
    last_review_state,
    last_review_bodies,
    last_sha,
    notified_parent,
    last_ci_failed,
    last_timeout_at,
  })
}

///|
pub fn PollerState::new() -> PollerState {
  { tracked: Map::new() }
}

///|
pub fn PollerState::track(
  self : PollerState,
  pr_number : Int,
  agent_id : String,
  branch : String,
  parent_branch : String,
  pr_url : String,
  now : Int64,
) -> Unit {
  let pr = {
    pr_number,
    agent_id,
    branch,
    parent_branch,
    pr_url,
    first_seen: now,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: None_,
    last_review_bodies: "",
    last_sha: "",
    notified_parent: false,
    last_ci_failed: false,
    last_timeout_at: 0L,
  }
  self.tracked.set(pr_number, pr)
}

///|
pub fn PollerState::ensure_tracked(
  self : PollerState,
  pr_number : Int,
  agent_id : String,
  branch : String,
  parent_branch : String,
  pr_url : String,
  now : Int64,
) -> Unit {
  match self.tracked.get(pr_number) {
    Some(existing) =>
      self.tracked.set(pr_number, {
        ..existing,
        agent_id,
        branch,
        parent_branch,
        pr_url,
      })
    None => self.track(pr_number, agent_id, branch, parent_branch, pr_url, now)
  }
}

///|
pub fn PollerState::transfer_owner(
  self : PollerState,
  from_agent_id : String,
  to_agent_id : String,
  to_branch : String,
  to_parent_branch : String,
) -> Int {
  let pr_numbers = []
  for tracked in self.tracked.values() {
    if tracked.agent_id == from_agent_id {
      pr_numbers.push(tracked.pr_number)
    }
  }
  for pr_number in pr_numbers {
    match self.tracked.get(pr_number) {
      Some(tracked) =>
        self.tracked.set(pr_number, {
          ..tracked,
          agent_id: to_agent_id,
          branch: if to_branch == "" {
            tracked.branch
          } else {
            to_branch
          },
          parent_branch: if to_parent_branch == "" {
            tracked.parent_branch
          } else {
            to_parent_branch
          },
        })
      None => ()
    }
  }
  pr_numbers.length()
}

///|
fn recovered_notified_parent(review : ReviewState) -> Bool {
  match review {
    Approved => true
    ChangesRequested | Commented | None_ => false
  }
}

///|
pub fn PollerState::track_recovered(
  self : PollerState,
  pr_number : Int,
  agent_id : String,
  branch : String,
  parent_branch : String,
  pr_url : String,
  first_seen : Int64,
  review : ReviewState,
  review_bodies : String,
  sha : String,
  ci_failed : Bool,
) -> Unit {
  let pr = {
    pr_number,
    agent_id,
    branch,
    parent_branch,
    pr_url,
    first_seen,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: review,
    last_review_bodies: review_bodies,
    last_sha: sha,
    notified_parent: recovered_notified_parent(review),
    last_ci_failed: ci_failed,
    last_timeout_at: 0L,
  }
  self.tracked.set(pr_number, pr)
}

///|
pub fn PollerState::restore(self : PollerState, tracked : TrackedPR) -> Unit {
  self.tracked.set(tracked.pr_number, tracked)
}

///|
pub fn PollerState::to_json(self : PollerState) -> String {
  let buf = StringBuilder::new()
  buf.write_char('[')
  let entries = []
  for tracked in self.tracked.values() {
    entries.push(tracked_pr_json(tracked))
  }
  buf.write_string(entries.join(","))
  buf.write_char(']')
  buf.to_string()
}

///|
pub fn parse_tracked_prs_json(content : String) -> Array[TrackedPR] {
  let tracked = []
  let json = @json.parse(content) catch { _ => return tracked }
  let arr = match json {
    Json::Array(items) => items
    _ => return tracked
  }
  for item in arr {
    match item {
      Json::Object(fields) =>
        match parse_tracked_pr(fields) {
          Some(parsed) => tracked.push(parsed)
          None => ()
        }
      _ => ()
    }
  }
  tracked
}

///|
pub fn poller_state_path(project_dir : String) -> String {
  project_dir + "/.choir/poller_state.json"
}

///|
pub fn PollerState::write_state_file(
  self : PollerState,
  project_dir : String,
) -> Bool {
  @sys.write_file_atomic(poller_state_path(project_dir), self.to_json())
}

///|
pub fn read_state_file(project_dir : String) -> Array[TrackedPR] {
  parse_tracked_prs_json(@sys.read_file(poller_state_path(project_dir)))
}

///|
pub fn PollerState::untrack(self : PollerState, pr_number : Int) -> Unit {
  self.tracked.remove(pr_number)
}

///|
pub fn PollerState::get(self : PollerState, pr_number : Int) -> TrackedPR? {
  self.tracked.get(pr_number)
}

///|
fn next_notified_parent(
  tracked : TrackedPR,
  review : ReviewState,
  review_bodies : String,
  sha : String,
) -> Bool {
  let mut notified_parent = tracked.notified_parent
  if review != tracked.last_review_state {
    match review {
      ChangesRequested | Commented => notified_parent = false
      Approved => notified_parent = true
      None_ => notified_parent = false
    }
  }
  if review != Approved &&
    review_bodies != "" &&
    review_bodies != tracked.last_review_bodies {
    notified_parent = false
  }
  if (
      tracked.last_review_state == ChangesRequested ||
      tracked.last_review_state == Commented
    ) &&
    sha != "" &&
    sha != tracked.last_sha {
    notified_parent = true
  }
  notified_parent
}

///|
fn backoff_delay_seconds(consecutive_failures : Int) -> Int64 {
  let mut delay = 30L
  let mut i = 0
  while i < consecutive_failures {
    if delay >= 300L {
      return 300L
    }
    delay = delay * 2L
    i = i + 1
  }
  if delay > 300L {
    300L
  } else {
    delay
  }
}

///|
fn clamp_consecutive_failures(consecutive_failures : Int) -> Int {
  if consecutive_failures > 10 {
    10
  } else {
    consecutive_failures
  }
}

///|
/// Same backoff delays as after a failed GH poll (for tests and tooling).
pub fn poller_backoff_delay_after_failure(consecutive_failures : Int) -> Int64 {
  backoff_delay_seconds(consecutive_failures)
}

///|
/// Check if an agent has any tracked PRs.
pub fn PollerState::has_tracked_pr(
  self : PollerState,
  agent_id : String,
) -> Bool {
  for tracked in self.tracked.values() {
    if tracked.agent_id == agent_id {
      return true
    }
  }
  false
}

///|
pub fn PollerState::in_critical_phase(
  self : PollerState,
  agent_id : String,
) -> Bool {
  self.critical_phase_pr_number(agent_id) is Some(_)
}

///|
pub fn PollerState::critical_phase_pr_number(
  self : PollerState,
  agent_id : String,
) -> Int? {
  for tracked in self.tracked.values() {
    if tracked.agent_id == agent_id &&
      tracked.last_review_state == ChangesRequested &&
      not(tracked.notified_parent) {
      return Some(tracked.pr_number)
    }
  }
  None
}

///|
pub fn PollerState::untrack_by_agent_id(
  self : PollerState,
  agent_id : String,
) -> Int {
  let to_untrack = []
  for pr in self.tracked.values() {
    if pr.agent_id == agent_id {
      to_untrack.push(pr.pr_number)
    }
  }
  for pr_number in to_untrack {
    self.untrack(pr_number)
  }
  to_untrack.length()
}

///|
pub async fn PollerState::tick_with(
  self : PollerState,
  now : Int64,
  timeout : Int64,
  poll : async (Int) -> (Bool, ReviewState, String, Bool, String, Bool),
  on_event : (PollEvent, String) -> Unit,
  log_pr : (PollerPrTickLog) -> Unit,
) -> Unit {
  let pr_numbers = []
  for tracked in self.tracked.values() {
    pr_numbers.push(tracked.pr_number)
  }
  for pr_number in pr_numbers {
    let tracked = match self.tracked.get(pr_number) {
      Some(value) => value
      None => continue
    }
    let agent_id = tracked.agent_id
    let prev_failures = tracked.consecutive_failures
    let prior_state = tracked.last_review_state
    if now < tracked.backoff_until {
      log_pr({
        pr_number,
        agent_id,
        skipped_backoff: true,
        polled_network: false,
        poll_succeeded: false,
        untracked_closed: false,
        backoff_until: tracked.backoff_until,
        prior_review_state: prior_state,
        detected_review_state: prior_state,
        events: [],
        consecutive_failures: prev_failures,
        previous_consecutive_failures: prev_failures,
      })
      continue
    }
    let (poll_ok, review, sha, ci_failed, review_bodies, is_open) = poll(
      pr_number,
    )
    if not(poll_ok) {
      let failures = clamp_consecutive_failures(
        tracked.consecutive_failures + 1,
      )
      let delay = backoff_delay_seconds(failures)
      let until = now + delay
      self.tracked.set(pr_number, {
        ..tracked,
        consecutive_failures: failures,
        backoff_until: until,
      })
      log_pr({
        pr_number,
        agent_id,
        skipped_backoff: false,
        polled_network: true,
        poll_succeeded: false,
        untracked_closed: false,
        backoff_until: until,
        prior_review_state: prior_state,
        detected_review_state: prior_state,
        events: [],
        consecutive_failures: failures,
        previous_consecutive_failures: prev_failures,
      })
      continue
    }
    let tracked_ok = { ..tracked, consecutive_failures: 0, backoff_until: 0L }
    if not(is_open) {
      log_pr({
        pr_number,
        agent_id,
        skipped_backoff: false,
        polled_network: true,
        poll_succeeded: true,
        untracked_closed: true,
        backoff_until: 0L,
        prior_review_state: prior_state,
        detected_review_state: review,
        events: [],
        consecutive_failures: 0,
        previous_consecutive_failures: prev_failures,
      })
      self.tracked.remove(pr_number)
      continue
    }
    let events = detect_events(
      tracked_ok, review, sha, ci_failed, review_bodies, now, timeout,
    )
    let mut timeout_at = tracked_ok.last_timeout_at
    for event in events {
      on_event(event, tracked_ok.agent_id)
      match event {
        ReviewTimeout(_) => timeout_at = now
        _ => ()
      }
    }
    let notified_parent = next_notified_parent(
      tracked_ok, review, review_bodies, sha,
    )
    let updated = if sha == "" {
      {
        ..tracked_ok,
        last_review_state: review,
        last_review_bodies: review_bodies,
        notified_parent,
        last_ci_failed: ci_failed,
        last_timeout_at: timeout_at,
      }
    } else {
      {
        ..tracked_ok,
        last_review_state: review,
        last_review_bodies: review_bodies,
        last_sha: sha,
        notified_parent,
        last_ci_failed: ci_failed,
        last_timeout_at: timeout_at,
      }
    }
    self.tracked.set(pr_number, updated)
    log_pr({
      pr_number,
      agent_id,
      skipped_backoff: false,
      polled_network: true,
      poll_succeeded: true,
      untracked_closed: false,
      backoff_until: 0L,
      prior_review_state: prior_state,
      detected_review_state: review,
      events,
      consecutive_failures: 0,
      previous_consecutive_failures: prev_failures,
    })
  }
}

///|
pub async fn PollerState::tick(
  self : PollerState,
  now : Int64,
  timeout : Int64,
  on_event : (PollEvent, String) -> Unit,
) -> Unit {
  self.tick_with(now, timeout, gh_poll_pr, on_event, fn(_) { () })
}

///|
async fn state_tick_backoff_mock_failure(
  _pr_number : Int,
) -> (Bool, ReviewState, String, Bool, String, Bool) {
  @async.sleep(0)
  (false, None_, "", false, "", true)
}

///|
async fn state_tick_backoff_mock_success(
  _pr_number : Int,
) -> (Bool, ReviewState, String, Bool, String, Bool) {
  @async.sleep(0)
  (true, Commented, "sha-1", false, "body", true)
}

///|
async test "tick_with failed poll increments consecutive_failures and backoff_until" {
  let ps = PollerState::new()
  ps.track(101, "main.leaf", "main.leaf", "main", "u", 100L)
  let _ = ps.tick_with(
    200L,
    3600L,
    state_tick_backoff_mock_failure,
    fn(_e : PollEvent, _a : String) -> Unit { () },
    fn(_l : PollerPrTickLog) -> Unit { () },
  )
  match ps.get(101) {
    Some(t) => {
      assert_eq(t.consecutive_failures, 1)
      assert_eq(t.backoff_until, 200L + poller_backoff_delay_after_failure(1))
    }
    None => fail("expected PR 101")
  }
}

///|
async test "tick_with skips poll while now is before backoff_until" {
  let ps = PollerState::new()
  ps.track(102, "main.leaf", "main.leaf", "main", "u", 100L)
  let noop_ev = fn(_e : PollEvent, _a : String) -> Unit { () }
  let noop_log = fn(_l : PollerPrTickLog) -> Unit { () }
  let _ = ps.tick_with(
    200L, 3600L, state_tick_backoff_mock_failure, noop_ev, noop_log,
  )
  let until = match ps.get(102) {
    Some(t) => t.backoff_until
    None => fail("expected PR 102")
  }
  let mid = 200L + (until - 200L) / 2L
  let _ = ps.tick_with(
    mid, 3600L, state_tick_backoff_mock_success, noop_ev, noop_log,
  )
  match ps.get(102) {
    Some(t) => {
      assert_eq(t.consecutive_failures, 1)
      assert_eq(t.backoff_until, until)
      assert_eq(t.last_sha, "")
    }
    None => fail("expected PR 102 after mid tick")
  }
}

///|
async test "tick_with successful poll resets consecutive_failures and backoff_until" {
  let ps = PollerState::new()
  ps.track(103, "main.leaf", "main.leaf", "main", "u", 100L)
  let noop_ev = fn(_e : PollEvent, _a : String) -> Unit { () }
  let noop_log = fn(_l : PollerPrTickLog) -> Unit { () }
  let _ = ps.tick_with(
    200L, 3600L, state_tick_backoff_mock_failure, noop_ev, noop_log,
  )
  let until = match ps.get(103) {
    Some(t) => t.backoff_until
    None => fail("expected PR 103")
  }
  let _ = ps.tick_with(
    until, 3600L, state_tick_backoff_mock_success, noop_ev, noop_log,
  )
  match ps.get(103) {
    Some(t) => {
      assert_eq(t.consecutive_failures, 0)
      assert_eq(t.backoff_until, 0L)
      assert_eq(t.last_sha, "sha-1")
    }
    None => fail("expected PR 103 after success")
  }
}
