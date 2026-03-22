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
fn json_field_string(fields : Map[String, Json], key : String) -> String? {
  match fields.get(key) {
    Some(String(value)) => Some(value)
    _ => None
  }
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
  let agent_id = match json_field_string(fields, "agent_id") {
    Some(value) => value
    None => return None
  }
  let branch = match json_field_string(fields, "branch") {
    Some(value) => value
    None => return None
  }
  let parent_branch = match json_field_string(fields, "parent_branch") {
    Some(value) => value
    None => return None
  }
  let pr_url = match json_field_string(fields, "pr_url") {
    Some(value) => value
    None => return None
  }
  let first_seen = match json_field_int64(fields, "first_seen") {
    Some(value) => value
    None => return None
  }
  let last_review_state = match json_field_string(fields, "last_review_state") {
    Some(value) =>
      match parse_review_state_name(value) {
        Some(parsed) => parsed
        None => return None
      }
    None => return None
  }
  let last_review_bodies = match
    json_field_string(fields, "last_review_bodies") {
    Some(value) => value
    None => return None
  }
  let last_sha = match json_field_string(fields, "last_sha") {
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
  @sys.write_file_sync(poller_state_path(project_dir), self.to_json())
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
pub async fn PollerState::tick_with(
  self : PollerState,
  now : Int64,
  timeout : Int64,
  poll : async (Int) -> (ReviewState, String, Bool, String),
  on_event : (PollEvent, String) -> Unit,
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
    let (review, sha, ci_failed, review_bodies) = poll(pr_number)
    let events = detect_events(
      tracked, review, sha, ci_failed, review_bodies, now, timeout,
    )
    let mut timeout_at = tracked.last_timeout_at
    for event in events {
      on_event(event, tracked.agent_id)
      match event {
        ReviewTimeout(_) => timeout_at = now
        _ => ()
      }
    }
    let notified_parent = next_notified_parent(
      tracked, review, review_bodies, sha,
    )
    let updated = if sha == "" {
      {
        ..tracked,
        last_review_state: review,
        last_review_bodies: review_bodies,
        notified_parent,
        last_ci_failed: ci_failed,
        last_timeout_at: timeout_at,
      }
    } else {
      {
        ..tracked,
        last_review_state: review,
        last_review_bodies: review_bodies,
        last_sha: sha,
        notified_parent,
        last_ci_failed: ci_failed,
        last_timeout_at: timeout_at,
      }
    }
    self.tracked.set(pr_number, updated)
  }
}

///|
pub async fn PollerState::tick(
  self : PollerState,
  now : Int64,
  timeout : Int64,
  on_event : (PollEvent, String) -> Unit,
) -> Unit {
  self.tick_with(now, timeout, gh_poll_pr, on_event)
}
