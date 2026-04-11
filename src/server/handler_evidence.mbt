///|
fn evidence_review_state_from_snapshot(
  review : @poller.ReviewState,
) -> @evidence.EvidenceReviewState {
  match review {
    @poller.ReviewState::None_ => @evidence.EvidenceReviewState::None_
    @poller.ReviewState::Commented => @evidence.EvidenceReviewState::Commented
    @poller.ReviewState::Approved => @evidence.EvidenceReviewState::Approved
    @poller.ReviewState::ChangesRequested =>
      @evidence.EvidenceReviewState::ChangesRequested
  }
}

///|
fn evidence_ci_status_from_snapshot(
  ci : @poller.CiRollupStatus,
) -> @evidence.EvidenceCiStatus {
  match ci {
    @poller.CiRollupStatus::Unknown => @evidence.EvidenceCiStatus::Unknown
    @poller.CiRollupStatus::InProgress => @evidence.EvidenceCiStatus::InProgress
    @poller.CiRollupStatus::Success => @evidence.EvidenceCiStatus::Success
    @poller.CiRollupStatus::Failure => @evidence.EvidenceCiStatus::Failure
  }
}

///|
fn evidence_optional_string(value : String) -> String? {
  if value == "" {
    None
  } else {
    Some(value)
  }
}

///|
pub fn evidence_events_for_poll_snapshot(
  tracked : @poller.TrackedPR,
  event : @poller.PollEvent,
  unresolved_threads_for_recheck : Int?,
) -> Array[@evidence.EvidenceEvent] {
  let events : Array[@evidence.EvidenceEvent] = [
    @evidence.EvidenceEvent::ReviewObserved(
      state=evidence_review_state_from_snapshot(tracked.last_review_state),
      body=evidence_optional_string(tracked.last_review_bodies),
    ),
    @evidence.EvidenceEvent::CiObserved(
      status=evidence_ci_status_from_snapshot(tracked.last_ci_rollup),
      head_sha=evidence_optional_string(tracked.last_sha),
    ),
  ]
  match unresolved_threads_for_recheck {
    Some(count) => events.push(@evidence.EvidenceEvent::ThreadsObserved(count~))
    None => events.push(@evidence.EvidenceEvent::ThreadsUnobserved)
  }
  if tracked.copilot_issue_comment_seen {
    events.push(@evidence.EvidenceEvent::CopilotIssueCommentObserved)
  } else {
    events.push(@evidence.EvidenceEvent::CopilotIssueCommentUnobserved)
  }
  match event {
    @poller.PollEvent::PRMerged(merged_pr) =>
      events.push(
        @evidence.EvidenceEvent::MergeObserved(
          pr_number=merged_pr.pr_number,
          pr_url=evidence_optional_string(merged_pr.pr_url),
        ),
      )
    @poller.PollEvent::ReviewThreadsResolved(_) =>
      events.push(@evidence.EvidenceEvent::ReviewThreadsResolved)
    _ => ()
  }
  events
}

///|
fn append_poll_snapshot_evidence(
  state : ServerState,
  tracked : @poller.TrackedPR,
  event : @poller.PollEvent,
  unresolved_threads_for_recheck : Int?,
) -> Unit {
  for
    evidence_event in evidence_events_for_poll_snapshot(
      tracked, event, unresolved_threads_for_recheck,
    ) {
    ignore(
      append_evidence_event(
        state.append_file,
        state.config.project_dir,
        tracked.agent_id,
        evidence_event,
      ),
    )
  }
}

///|
fn append_merge_pr_evidence_if_needed(
  state : ServerState,
  req : @types.Request,
  resp : @types.Response,
  merged_agent_id : String?,
  merged_pr_url : String?,
) -> Unit {
  guard req.name == "merge_pr" else { return }
  let pr_number = match request_int_arg(req, "pr_number") {
    Some(value) => value
    None => return
  }
  let force = request_bool_arg(req, "force").unwrap_or(false)
  let merge_mode = merge_execution_mode_for_request(req)
  match merged_agent_id {
    Some(agent_id) => {
      ignore(
        append_evidence_event(
          state.append_file,
          state.config.project_dir,
          agent_id,
          @evidence.EvidenceEvent::MergeExecutionRequested(mode=merge_mode),
        ),
      )
      if force {
        ignore(
          append_evidence_event(
            state.append_file,
            state.config.project_dir,
            agent_id,
            @evidence.EvidenceEvent::UserOverrideObserved(
              scope="merge_pr.force",
              reason=Some("merge_pr invoked with force=true"),
            ),
          ),
        )
      }
      if resp.is_ok() {
        ignore(
          append_evidence_event(
            state.append_file,
            state.config.project_dir,
            agent_id,
            @evidence.EvidenceEvent::MergeObserved(
              pr_number~,
              pr_url=merged_pr_url,
            ),
          ),
        )
      }
    }
    None => ()
  }
}

///|
/// Canonical TL decision line for parent delivery (see `@poller.plan_tl_poll_event_parent`).
