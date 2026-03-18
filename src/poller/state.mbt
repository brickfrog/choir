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
