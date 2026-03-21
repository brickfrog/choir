///|
pub(all) struct PollerState {
  tracked : Map[Int, TrackedPR]
}

///|
fn parse_int_value(s : String) -> Int? {
  if s == "" {
    return None
  }
  let mut res = 0
  for c in s {
    if c >= '0' && c <= '9' {
      res = res * 10 + (c.to_int() - '0'.to_int())
    } else {
      return None
    }
  }
  Some(res)
}

///|
fn parse_bool_value(s : String) -> Bool? {
  match s {
    "true" => Some(true)
    "false" => Some(false)
    _ => None
  }
}

///|
fn review_state_name(review : ReviewState) -> String {
  match review {
    None_ => "none"
    Approved => "approved"
    ChangesRequested => "changes_requested"
  }
}

///|
fn parse_review_state_name(s : String) -> ReviewState? {
  match s {
    "none" => Some(None_)
    "approved" => Some(Approved)
    "changes_requested" => Some(ChangesRequested)
    _ => None
  }
}

///|
fn escape_json_string(s : String) -> String {
  let buf = StringBuilder::new()
  for c in s {
    match c {
      '"' => buf.write_string("\\\"")
      '\\' => buf.write_string("\\\\")
      '\n' => buf.write_string("\\n")
      '\r' => buf.write_string("\\r")
      '\t' => buf.write_string("\\t")
      _ => buf.write_char(c)
    }
  }
  buf.to_string()
}

///|
fn tracked_pr_json(tracked : TrackedPR) -> String {
  let notified_parent = if tracked.notified_parent { "true" } else { "false" }
  let last_ci_failed = if tracked.last_ci_failed { "true" } else { "false" }
  "{\"pr_number\":" +
  tracked.pr_number.to_string() +
  ",\"agent_id\":\"" +
  escape_json_string(tracked.agent_id) +
  "\",\"branch\":\"" +
  escape_json_string(tracked.branch) +
  "\",\"parent_branch\":\"" +
  escape_json_string(tracked.parent_branch) +
  "\",\"pr_url\":\"" +
  escape_json_string(tracked.pr_url) +
  "\",\"first_seen\":" +
  tracked.first_seen.to_string() +
  ",\"last_review_state\":\"" +
  review_state_name(tracked.last_review_state) +
  "\",\"last_review_bodies\":\"" +
  escape_json_string(tracked.last_review_bodies) +
  "\",\"last_sha\":\"" +
  escape_json_string(tracked.last_sha) +
  "\",\"notified_parent\":" +
  notified_parent +
  ",\"last_ci_failed\":" +
  last_ci_failed +
  ",\"last_timeout_at\":" +
  tracked.last_timeout_at.to_string() +
  "}"
}

///|
fn json_text_value(
  fields : Map[String, @jsonutil.JsonValueText],
  key : String,
) -> String? {
  match fields.get(key) {
    Some(@jsonutil.JsonValueText::String(value)) => Some(value)
    Some(@jsonutil.JsonValueText::Raw(value)) => Some(value)
    None => None
  }
}

///|
fn parse_tracked_pr(
  fields : Map[String, @jsonutil.JsonValueText],
) -> TrackedPR? {
  let pr_number = match json_text_value(fields, "pr_number") {
    Some(value) =>
      match parse_int_value(value) {
        Some(parsed) => parsed
        None => return None
      }
    None => return None
  }
  let agent_id = match json_text_value(fields, "agent_id") {
    Some(value) => value
    None => return None
  }
  let branch = match json_text_value(fields, "branch") {
    Some(value) => value
    None => return None
  }
  let parent_branch = match json_text_value(fields, "parent_branch") {
    Some(value) => value
    None => return None
  }
  let pr_url = match json_text_value(fields, "pr_url") {
    Some(value) => value
    None => return None
  }
  let first_seen = match json_text_value(fields, "first_seen") {
    Some(value) =>
      match parse_int_value(value) {
        Some(parsed) => parsed.to_int64()
        None => return None
      }
    None => return None
  }
  let last_review_state = match json_text_value(fields, "last_review_state") {
    Some(value) =>
      match parse_review_state_name(value) {
        Some(parsed) => parsed
        None => return None
      }
    None => return None
  }
  let last_review_bodies = match json_text_value(fields, "last_review_bodies") {
    Some(value) => value
    None => return None
  }
  let last_sha = match json_text_value(fields, "last_sha") {
    Some(value) => value
    None => return None
  }
  let notified_parent = match json_text_value(fields, "notified_parent") {
    Some(value) =>
      match parse_bool_value(value) {
        Some(parsed) => parsed
        None => return None
      }
    None => return None
  }
  let last_ci_failed = match json_text_value(fields, "last_ci_failed") {
    Some(value) =>
      match parse_bool_value(value) {
        Some(parsed) => parsed
        None => return None
      }
    None => return None
  }
  let last_timeout_at = match json_text_value(fields, "last_timeout_at") {
    Some(value) =>
      match parse_int_value(value) {
        Some(parsed) => parsed.to_int64()
        None => 0L
      }
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
    ChangesRequested => false
    None_ => false
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
  for fields in @jsonutil.parse_json_object_array_text(content) {
    match parse_tracked_pr(fields) {
      Some(parsed) => tracked.push(parsed)
      None => ()
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
  @io.write_file_sync(poller_state_path(project_dir), self.to_json())
}

///|
pub fn read_state_file(project_dir : String) -> Array[TrackedPR] {
  parse_tracked_prs_json(@io.read_file(poller_state_path(project_dir)))
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
      ChangesRequested => notified_parent = false
      Approved => notified_parent = true
      None_ => notified_parent = false
    }
  }
  if review != Approved &&
    review_bodies != "" &&
    review_bodies != tracked.last_review_bodies {
    notified_parent = false
  }
  if tracked.last_review_state == ChangesRequested &&
    sha != "" &&
    sha != tracked.last_sha {
    notified_parent = true
  }
  notified_parent
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
