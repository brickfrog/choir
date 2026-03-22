///|
/// Review state for a tracked PR.
pub(all) enum ReviewState {
  None_
  Approved
  ChangesRequested
  Commented
} derive(Show, Eq)

///|
/// Tracked state for a single PR in the poller.
pub(all) struct TrackedPR {
  pr_number : Int
  agent_id : String
  branch : String
  parent_branch : String
  pr_url : String
  first_seen : Int64
  mut last_review_state : ReviewState
  mut last_review_bodies : String
  mut last_sha : String
  mut notified_parent : Bool
  mut last_ci_failed : Bool
  mut last_timeout_at : Int64
} derive(Show, Eq)

///|
/// Events emitted by the poller on each tick.
pub(all) enum PollEvent {
  ReviewReceived(Int, String)
  PRReady(Int)
  FixesPushed(Int)
  ReviewTimeout(Int)
  CIFailed(Int)
} derive(Show, Eq)
