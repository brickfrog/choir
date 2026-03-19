///|
pub(all) struct PollerState {
  tracked : Map[Int, TrackedPR]
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
  now : Int64,
) -> Unit {
  let pr = {
    pr_number,
    agent_id,
    first_seen: now,
    last_review_state: None_,
    last_sha: "",
    notified_parent: false,
    last_ci_failed: false,
  }
  self.tracked.set(pr_number, pr)
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
  poll : async (Int) -> (ReviewState, String, Bool),
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
    let (review, sha, ci_failed) = poll(pr_number)
    let events = detect_events(tracked, review, sha, ci_failed, now, timeout)
    for event in events {
      on_event(event, tracked.agent_id)
    }
    let updated = if sha == "" {
      { ..tracked, last_review_state: review, last_ci_failed: ci_failed }
    } else {
      {
        ..tracked,
        last_review_state: review,
        last_sha: sha,
        last_ci_failed: ci_failed,
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
