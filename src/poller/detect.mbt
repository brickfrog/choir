///|
pub fn detect_events(
  tracked : TrackedPR,
  current_review : ReviewState,
  current_sha : String,
  ci_failed : Bool,
  review_bodies : String,
  now : Int64,
  timeout : Int64,
) -> Array[PollEvent] {
  let events = []
  let has_new_review_bodies = review_bodies != "" &&
    review_bodies != tracked.last_review_bodies

  // Review state changes
  if current_review != tracked.last_review_state {
    match current_review {
      Approved => events.push(PollEvent::PRReady(tracked.pr_number))
      ChangesRequested | Commented =>
        if has_new_review_bodies || current_review == ChangesRequested {
          events.push(
            PollEvent::ReviewReceived(tracked.pr_number, review_bodies),
          )
        }
      None_ =>
        if has_new_review_bodies {
          events.push(
            PollEvent::ReviewReceived(tracked.pr_number, review_bodies),
          )
        }
    }
  } else if current_review != Approved && has_new_review_bodies {
    events.push(PollEvent::ReviewReceived(tracked.pr_number, review_bodies))
  }

  // Fixes pushed
  if (
      tracked.last_review_state == ChangesRequested ||
      tracked.last_review_state == Commented
    ) &&
    current_sha != tracked.last_sha {
    events.push(PollEvent::FixesPushed(tracked.pr_number))
  }

  // Timeout — fire periodically (every timeout interval), not on every tick.
  // Suppress entirely if any review content has been received.
  let has_any_review_content = review_bodies != "" ||
    tracked.last_review_bodies != ""
  if now - tracked.first_seen > timeout &&
    tracked.last_review_state == None_ &&
    not(has_any_review_content) {
    let since_last = if tracked.last_timeout_at == 0L {
      now - tracked.first_seen
    } else {
      now - tracked.last_timeout_at
    }
    if since_last >= timeout {
      events.push(PollEvent::ReviewTimeout(tracked.pr_number))
    }
  }

  // CI failure — only fire once per failure episode
  if ci_failed && not(tracked.last_ci_failed) {
    events.push(PollEvent::CIFailed(tracked.pr_number))
  }
  events
}
