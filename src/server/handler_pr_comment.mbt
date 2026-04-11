///|
pub fn pr_comment_body(
  event : @poller.PollEvent,
  agent_id : String,
  review_mode? : @types.ReviewMode = @types.ReviewMode::Iterative,
) -> (Int, String)? {
  match event {
    ReviewReceived(n, _) =>
      Some(
        (
          n,
          "**Choir:** review received — routed to `" +
          agent_id +
          "` and parent for triage.",
        ),
      )
    ReviewCommented(n, _) =>
      Some(
        (
          n,
          "**Choir:** comment-only review received — routed to `" +
          agent_id +
          "` (leaf pane).",
        ),
      )
    PRReady(n) =>
      Some(
        (
          n, "**Choir:** PR approved — parent notified. PR is not merged until merge_pr succeeds.",
        ),
      )
    CIFailed(n) =>
      Some(
        (
          n,
          "**Choir:** CI checks failing — routed to `" +
          agent_id +
          "` for fixes.",
        ),
      )
    CIFailureCleared(n) =>
      Some(
        (
          n, "**Choir:** CI rollup no longer shows FAILURE/ERROR on the latest head (may still be pending) — re-check the PR on GitHub (not a merge signal).",
        ),
      )
    CILatestHeadRollupSucceeded(n) =>
      Some(
        (
          n, "**Choir:** GitHub Actions rollup reports all checks successful on the latest head — re-check review/merge policy on GitHub (not an approval or merge signal by itself).",
        ),
      )
    FixesPushed(n) =>
      Some(
        (
          n,
          "**Choir:** fixes pushed by `" +
          agent_id +
          (match review_mode {
            @types.ReviewMode::SinglePass =>
              "` — resolving threads and checking gates (not merged yet)."
            @types.ReviewMode::Iterative =>
              "` — awaiting re-review (not merged yet)."
          }),
        ),
      )
    ReviewTimeout(_) => None
    CopilotIssueCommentSeen(n) =>
      Some(
        (
          n, "**Choir:** GitHub Copilot issue-thread comment observed on PR — parent notified with updated gate snapshot (not merge approval).",
        ),
      )
    PRMerged(_) => None
    MergeReady(_) => None
    ReviewThreadsResolved(n) =>
      Some(
        (
          n, "**Choir:** review threads marked resolved — re-checking PR state (not a merge signal).",
        ),
      )
  }
}

///|
pub async fn deliver_poller_stall_notification_for(
  state : ServerState,
  pr : @poller.TrackedPR,
  now : Int64,
  runner : async (Array[@workspace.Command]) -> Array[Int],
) -> Unit {
  if lifecycle_suppresses_poller_followups(state.current_lifecycle(pr.agent_id)) {
    return
  }
  let active = try state.registry.get(pr.agent_id) catch {
    _ => false
  } noraise {
    agent =>
      match agent.state {
        @types.AgentState::Active | @types.AgentState::Completing => true
        _ => false
      }
  }
  let stall_threshold_seconds : Int64 = 600L
  let stalled = @poller.detect_stalled_on_review(
    [(pr, active)],
    now,
    stall_threshold_seconds,
  )
  for p in stalled {
    let mins = (now - p.changes_requested_since) / 60L
    let msg = "[STALLED] PR #" +
      p.pr_number.to_string() +
      " (" +
      p.agent_id +
      ") — changes requested " +
      mins.to_string() +
      "m ago, no new commits from leaf"
    try {
      let parent = state.resolve_parent_for_delivery(p.agent_id)
      ignore(
        (state.append_file)(
          state.config.project_dir + "/.choir/delivery.log",
          "[poller-parent] agent=" +
          p.agent_id +
          " parent=" +
          parent.agent_id.to_string() +
          " terminal_target=" +
          parent.terminal_target
          .map(@types.LocalTarget::to_string)
          .unwrap_or("NONE") +
          "\n",
        ),
      )
      let delivery = @message.plan_delivery(
        parent,
        p.agent_id,
        msg,
        @types.Status::Info,
      )
      ignore(delivery)
      match
        state.durable_deliver_to_agent(
          parent,
          p.agent_id,
          msg,
          @types.Status::Info,
          runner,
        ) {
        Ok(_) =>
          match state.poller.get(p.pr_number) {
            Some(cur) => state.poller.restore({ ..cur, stall_notified: true })
            None => ()
          }
        Err(_) => ()
      }
    } catch {
      _ => ()
    }
  }
}
