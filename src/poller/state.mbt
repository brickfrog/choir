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
fn ci_rollup_name(rollup : CiRollupStatus) -> String {
  match rollup {
    Unknown => "unknown"
    InProgress => "in_progress"
    Success => "success"
    Failure => "failure"
  }
}

///|
fn parse_ci_rollup_name(s : String) -> CiRollupStatus? {
  match s {
    "unknown" => Some(Unknown)
    "in_progress" => Some(InProgress)
    "success" => Some(Success)
    "failure" => Some(Failure)
    _ => None
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
pub fn TrackedPR::to_json(self : TrackedPR) -> String {
  {
    "pr_number": self.pr_number.to_json(),
    "agent_id": self.agent_id.to_json(),
    "branch": self.branch.to_json(),
    "parent_branch": self.parent_branch.to_json(),
    "pr_url": self.pr_url.to_json(),
    "first_seen": self.first_seen.to_json(),
    "consecutive_failures": self.consecutive_failures.to_json(),
    "backoff_until": self.backoff_until.to_json(),
    "last_review_state": review_state_name(self.last_review_state).to_json(),
    "last_review_bodies": self.last_review_bodies.to_json(),
    "last_sha": self.last_sha.to_json(),
    "notified_parent": self.notified_parent.to_json(),
    "last_ci_rollup": ci_rollup_name(self.last_ci_rollup).to_json(),
    "last_timeout_at": self.last_timeout_at.to_json(),
    "copilot_issue_comment_seen": self.copilot_issue_comment_seen.to_json(),
    "orphan_notified": self.orphan_notified.to_json(),
    "orphan_reconciling": self.orphan_reconciling.to_json(),
    "changes_requested_since": self.changes_requested_since.to_json(),
    "stall_notified": self.stall_notified.to_json(),
    "fixes_pushed_at": self.fixes_pushed_at.to_json(),
  }
  .to_json()
  .stringify()
}

///|
fn parse_tracked_pr(fields : Map[String, Json]) -> TrackedPR? {
  let pr_number = match @types.json_field_int(fields, "pr_number") {
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
  let first_seen = match @types.json_field_int64(fields, "first_seen") {
    Some(value) => value
    None => return None
  }
  let consecutive_failures = match
    @types.json_field_int(fields, "consecutive_failures") {
    Some(value) => value
    None => 0
  }
  let backoff_until = match @types.json_field_int64(fields, "backoff_until") {
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
  let notified_parent = match
    @types.json_field_bool(fields, "notified_parent") {
    Some(value) => value
    None => return None
  }
  let last_ci_rollup = match
    @types.json_field_string(fields, "last_ci_rollup") {
    Some(value) =>
      match parse_ci_rollup_name(value) {
        Some(parsed) => parsed
        None => return None
      }
    None =>
      match @types.json_field_bool(fields, "last_ci_failed") {
        Some(true) => Failure
        Some(false) => Unknown
        None => return None
      }
  }
  let last_timeout_at = match
    @types.json_field_int64(fields, "last_timeout_at") {
    Some(value) => value
    None => 0L
  }
  let copilot_issue_comment_seen = match
    @types.json_field_bool(fields, "copilot_issue_comment_seen") {
    Some(value) => value
    None => false
  }
  let orphan_notified = match
    @types.json_field_bool(fields, "orphan_notified") {
    Some(value) => value
    None => false
  }
  let orphan_reconciling = match
    @types.json_field_bool(fields, "orphan_reconciling") {
    Some(value) => value
    None => false
  }
  let changes_requested_since = match
    @types.json_field_int64(fields, "changes_requested_since") {
    Some(value) => value
    None => 0L
  }
  let stall_notified = match @types.json_field_bool(fields, "stall_notified") {
    Some(value) => value
    None => false
  }
  let fixes_pushed_at = match
    @types.json_field_int64(fields, "fixes_pushed_at") {
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
    last_ci_rollup,
    last_timeout_at,
    copilot_issue_comment_seen,
    orphan_notified,
    orphan_reconciling,
    changes_requested_since,
    stall_notified,
    fixes_pushed_at,
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
    last_ci_rollup: Unknown,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: false,
    orphan_notified: false,
    orphan_reconciling: false,
    changes_requested_since: 0L,
    stall_notified: false,
    fixes_pushed_at: 0L,
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
  ci_rollup : CiRollupStatus,
  copilot_issue_comment_seen : Bool,
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
    last_ci_rollup: ci_rollup,
    last_timeout_at: 0L,
    copilot_issue_comment_seen,
    orphan_notified: false,
    orphan_reconciling: false,
    changes_requested_since: 0L,
    stall_notified: false,
    fixes_pushed_at: 0L,
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
    entries.push(tracked.to_json())
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
  let max_delay = 900L // 15-min ceiling
  let mut delay = 30L
  let mut i = 0
  while i < consecutive_failures && delay < max_delay {
    delay = delay * 2L
    i = i + 1
  }
  if delay > max_delay {
    max_delay
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
  self.tracked.values().any(fn(t) { t.agent_id == agent_id })
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
      !tracked.notified_parent {
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
pub async fn PollerState::tick_pr_with(
  self : PollerState,
  pr_number : Int,
  now : Int64,
  timeout : Int64,
  poll : async (Int, Bool) -> (
    Bool,
    ReviewState,
    String,
    CiRollupStatus,
    String,
    Bool,
    Bool,
  ),
  on_event : (PollEvent, String) -> Unit,
  log_pr : (PollerPrTickLog) -> Unit,
  force_refresh? : Bool = false,
) -> Unit {
  let tracked = match self.tracked.get(pr_number) {
    Some(value) => value
    None => return
  }
  let agent_id = tracked.agent_id
  let prev_failures = tracked.consecutive_failures
  let prior_state = tracked.last_review_state
  if !force_refresh && now < tracked.backoff_until {
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
    return
  }
  let (poll_ok, review, sha, ci_rollup, review_bodies, is_open, copilot_now) = poll(
    pr_number,
    tracked.copilot_issue_comment_seen,
  )
  if !poll_ok {
    let failures = clamp_consecutive_failures(tracked.consecutive_failures + 1)
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
    return
  }
  let tracked_ok = { ..tracked, consecutive_failures: 0, backoff_until: 0L }
  if !is_open {
    on_event(PRMerged(tracked_ok), tracked_ok.agent_id)
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
      events: [PRMerged(tracked_ok)],
      consecutive_failures: 0,
      previous_consecutive_failures: prev_failures,
    })
    self.tracked.remove(pr_number)
    return
  }
  let copilot_effective = tracked_ok.copilot_issue_comment_seen || copilot_now
  let base_events = detect_events(
    tracked_ok, review, sha, ci_rollup, review_bodies, now, timeout, copilot_effective,
  )
  let events = if !tracked_ok.copilot_issue_comment_seen && copilot_now {
    let merged : Array[PollEvent] = []
    for e in base_events {
      merged.push(e)
    }
    merged.push(PollEvent::CopilotIssueCommentSeen(pr_number))
    merged
  } else {
    base_events
  }
  let merge_snapshot_ready = (
      review == Approved || (review == Commented && copilot_effective)
    ) &&
    ci_rollup == Success
  let needs_merge_nudge = events.length() == 0 &&
    merge_snapshot_ready &&
    !tracked_ok.notified_parent
  let all_events = if needs_merge_nudge {
    let merged : Array[PollEvent] = []
    for e in events {
      merged.push(e)
    }
    merged.push(PollEvent::MergeReady(pr_number))
    merged
  } else {
    events
  }
  let mut timeout_at = tracked_ok.last_timeout_at
  for event in all_events {
    on_event(event, tracked_ok.agent_id)
    match event {
      ReviewTimeout(_) => timeout_at = now
      _ => ()
    }
  }
  let notified_parent = if needs_merge_nudge {
    true
  } else {
    next_notified_parent(tracked_ok, review, review_bodies, sha)
  }
  let copilot_sticky = tracked_ok.copilot_issue_comment_seen || copilot_now
  let mut crs = tracked_ok.changes_requested_since
  let mut sn = tracked_ok.stall_notified
  let mut fpa = tracked_ok.fixes_pushed_at
  let sha_moved = tracked_ok.last_sha != "" &&
    sha != "" &&
    sha != tracked_ok.last_sha
  if sha_moved {
    crs = 0L
    sn = false
    // Record when the SHA moved out of ChangesRequested so SinglePass merge
    // mode can distinguish "fixes pushed" from "fresh PR that never got reviewed".
    if tracked_ok.last_review_state == ChangesRequested {
      fpa = now
    }
  }
  if review != ChangesRequested {
    crs = 0L
    sn = false
  } else if prior_state != ChangesRequested {
    crs = now
    sn = false
  }
  let updated = if sha == "" {
    {
      ..tracked_ok,
      last_review_state: review,
      last_review_bodies: review_bodies,
      notified_parent,
      last_ci_rollup: ci_rollup,
      last_timeout_at: timeout_at,
      copilot_issue_comment_seen: copilot_sticky,
      changes_requested_since: crs,
      stall_notified: sn,
      fixes_pushed_at: fpa,
    }
  } else {
    {
      ..tracked_ok,
      last_review_state: review,
      last_review_bodies: review_bodies,
      last_sha: sha,
      notified_parent,
      last_ci_rollup: ci_rollup,
      last_timeout_at: timeout_at,
      copilot_issue_comment_seen: copilot_sticky,
      changes_requested_since: crs,
      stall_notified: sn,
      fixes_pushed_at: fpa,
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

///|
pub async fn PollerState::tick_with(
  self : PollerState,
  now : Int64,
  timeout : Int64,
  poll : async (Int, Bool) -> (
    Bool,
    ReviewState,
    String,
    CiRollupStatus,
    String,
    Bool,
    Bool,
  ),
  on_event : (PollEvent, String) -> Unit,
  log_pr : (PollerPrTickLog) -> Unit,
) -> Unit {
  let pr_numbers = []
  for tracked in self.tracked.values() {
    pr_numbers.push(tracked.pr_number)
  }
  for pr_number in pr_numbers {
    self.tick_pr_with(pr_number, now, timeout, poll, on_event, log_pr)
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
  _skip_issue : Bool,
) -> (Bool, ReviewState, String, CiRollupStatus, String, Bool, Bool) {
  @async.sleep(0)
  (false, None_, "", Unknown, "", true, false)
}

///|
async fn state_tick_backoff_mock_success(
  _pr_number : Int,
  _skip_issue : Bool,
) -> (Bool, ReviewState, String, CiRollupStatus, String, Bool, Bool) {
  @async.sleep(0)
  (true, Commented, "sha-1", Success, "body", true, false)
}

///|
async fn state_tick_sha_change_under_changes_requested(
  _pr_number : Int,
  _skip_issue : Bool,
) -> (Bool, ReviewState, String, CiRollupStatus, String, Bool, Bool) {
  @async.sleep(0)
  (true, ChangesRequested, "sha-new", Success, "", true, false)
}

///|
async fn state_tick_none_to_changes_requested(
  _pr_number : Int,
  _skip_issue : Bool,
) -> (Bool, ReviewState, String, CiRollupStatus, String, Bool, Bool) {
  @async.sleep(0)
  (true, ChangesRequested, "head1", Success, "fix it", true, false)
}

///|
async fn state_tick_changes_requested_to_approved(
  _pr_number : Int,
  _skip_issue : Bool,
) -> (Bool, ReviewState, String, CiRollupStatus, String, Bool, Bool) {
  @async.sleep(0)
  (true, Approved, "head1", Success, "", true, false)
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

///|
async test "tick_with resets stall fields when SHA changes under ChangesRequested" {
  let ps = PollerState::new()
  ps.track(201, "main.leaf", "main.leaf", "main", "u", 10L)
  let base = match ps.get(201) {
    Some(t) => t
    None => fail("expected PR 201")
  }
  ps.restore({
    ..base,
    last_review_state: ChangesRequested,
    last_sha: "sha-old",
    changes_requested_since: 999L,
    stall_notified: true,
  })
  let noop_ev = fn(_e : PollEvent, _a : String) -> Unit { () }
  let noop_log = fn(_l : PollerPrTickLog) -> Unit { () }
  let _ = ps.tick_with(
    50L, 3600L, state_tick_sha_change_under_changes_requested, noop_ev, noop_log,
  )
  match ps.get(201) {
    Some(t) => {
      assert_eq(t.changes_requested_since, 0L)
      assert_eq(t.stall_notified, false)
      assert_eq(t.last_sha, "sha-new")
    }
    None => fail("expected PR 201 after tick")
  }
}

///|
async test "tick_with sets changes_requested_since when entering ChangesRequested" {
  let ps = PollerState::new()
  ps.track(202, "main.leaf", "main.leaf", "main", "u", 1L)
  let noop_ev = fn(_e : PollEvent, _a : String) -> Unit { () }
  let noop_log = fn(_l : PollerPrTickLog) -> Unit { () }
  let now = 77L
  let _ = ps.tick_with(
    now, 3600L, state_tick_none_to_changes_requested, noop_ev, noop_log,
  )
  match ps.get(202) {
    Some(t) => {
      assert_eq(t.changes_requested_since, now)
      assert_eq(t.stall_notified, false)
      assert_eq(t.last_review_state, ChangesRequested)
    }
    None => fail("expected PR 202 after tick")
  }
}

///|
async test "tick_with clears stall fields when leaving ChangesRequested" {
  let ps = PollerState::new()
  ps.track(203, "main.leaf", "main.leaf", "main", "u", 1L)
  let base = match ps.get(203) {
    Some(t) => t
    None => fail("expected PR 203")
  }
  ps.restore({
    ..base,
    last_review_state: ChangesRequested,
    last_sha: "head1",
    changes_requested_since: 500L,
    stall_notified: true,
  })
  let noop_ev = fn(_e : PollEvent, _a : String) -> Unit { () }
  let noop_log = fn(_l : PollerPrTickLog) -> Unit { () }
  let _ = ps.tick_with(
    88L, 3600L, state_tick_changes_requested_to_approved, noop_ev, noop_log,
  )
  match ps.get(203) {
    Some(t) => {
      assert_eq(t.changes_requested_since, 0L)
      assert_eq(t.stall_notified, false)
      assert_eq(t.last_review_state, Approved)
    }
    None => fail("expected PR 203 after tick")
  }
}

///|
async test "tick_pr_with with force_refresh=true bypasses backoff" {
  let ps = PollerState::new()
  let pr_number = 301
  ps.track(pr_number, "main.leaf", "main.leaf", "main", "u", 100L)
  let noop_ev = fn(_e : PollEvent, _a : String) -> Unit { () }
  let noop_log = fn(_l : PollerPrTickLog) -> Unit { () }

  // 1. Force a failure to enter backoff
  ps.tick_pr_with(
    pr_number, 200L, 3600L, state_tick_backoff_mock_failure, noop_ev, noop_log,
  )
  let until = match ps.get(pr_number) {
    Some(t) => {
      assert_eq(t.consecutive_failures, 1)
      t.backoff_until
    }
    None => fail("expected PR 301")
  }

  // 2. Poll during backoff window WITHOUT force_refresh (should skip)
  let mid = 200L + (until - 200L) / 2L
  ps.tick_pr_with(
    pr_number, mid, 3600L, state_tick_backoff_mock_success, noop_ev, noop_log,
  )
  match ps.get(pr_number) {
    Some(t) => {
      assert_eq(t.last_sha, "") // No update
      assert_eq(t.consecutive_failures, 1)
    }
    None => fail("expected PR 301")
  }

  // 3. Poll during backoff window WITH force_refresh=true (should poll)
  ps.tick_pr_with(
    pr_number,
    mid,
    3600L,
    state_tick_backoff_mock_success,
    noop_ev,
    noop_log,
    force_refresh=true,
  )
  match ps.get(pr_number) {
    Some(t) => {
      assert_eq(t.last_sha, "sha-1") // Updated!
      assert_eq(t.consecutive_failures, 0)
    }
    None => fail("expected PR 301")
  }
}
