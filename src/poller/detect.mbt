///|
pub fn detect_events(
  tracked : TrackedPR,
  current_review : ReviewState,
  current_sha : String,
  ci_rollup : CiRollupStatus,
  review_bodies : String,
  now : Int64,
  timeout : Int64,
  copilot_issue_comment_effective : Bool,
) -> Array[PollEvent] {
  let ci_failed = ci_rollup == Failure
  let events = []
  let has_new_review_bodies = review_bodies != "" &&
    review_bodies != tracked.last_review_bodies

  // Review state changes
  if current_review != tracked.last_review_state {
    match current_review {
      Approved => events.push(PollEvent::PRReady(tracked.pr_number))
      ChangesRequested =>
        if has_new_review_bodies || current_review == ChangesRequested {
          events.push(
            PollEvent::ReviewReceived(tracked.pr_number, review_bodies),
          )
        }
      Commented =>
        if has_new_review_bodies {
          events.push(
            PollEvent::ReviewCommented(tracked.pr_number, review_bodies),
          )
        }
      None_ =>
        if has_new_review_bodies {
          events.push(
            PollEvent::ReviewCommented(tracked.pr_number, review_bodies),
          )
        }
    }
  } else if current_review != Approved && has_new_review_bodies {
    match current_review {
      ChangesRequested =>
        events.push(PollEvent::ReviewReceived(tracked.pr_number, review_bodies))
      _ =>
        events.push(
          PollEvent::ReviewCommented(tracked.pr_number, review_bodies),
        )
    }
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
  // Suppress entirely if any review content has been received, including a
  // Copilot issue comment (review objects alone may be empty).
  let has_any_review_content = review_bodies != "" ||
    tracked.last_review_bodies != "" ||
    copilot_issue_comment_effective
  if now - tracked.first_seen > timeout &&
    tracked.last_review_state == None_ &&
    !has_any_review_content {
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
  if ci_failed && tracked.last_ci_rollup != Failure {
    events.push(PollEvent::CIFailed(tracked.pr_number))
  }
  // CI recovered on the same head — do not fire when SHA just changed (new head may still be pending).
  if !ci_failed &&
    tracked.last_ci_rollup == Failure &&
    current_sha != "" &&
    current_sha == tracked.last_sha {
    events.push(PollEvent::CIFailureCleared(tracked.pr_number))
  }
  // Rollup reports all checks successful after a prior non-success on the same head (e.g. CI finished green).
  // Excludes Failure→Success (handled by CIFailureCleared). Not a merge/review verdict.
  if ci_rollup == Success &&
    tracked.last_ci_rollup != Success &&
    tracked.last_ci_rollup != Failure &&
    current_sha != "" &&
    current_sha == tracked.last_sha {
    events.push(PollEvent::CILatestHeadRollupSucceeded(tracked.pr_number))
  }
  events
}
