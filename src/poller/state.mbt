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
pub async fn PollerState::tick_with(
  self : PollerState,
  now : Int64,
  timeout : Int64,
  poll : async (Int) -> (ReviewState, String),
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
    let (review, sha) = poll(pr_number)
    let events = detect_events(tracked, review, sha, now, timeout)
    for event in events {
      on_event(event, tracked.agent_id)
    }
    let updated = if sha == "" {
      { ..tracked, last_review_state: review }
    } else {
      { ..tracked, last_review_state: review, last_sha: sha }
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
