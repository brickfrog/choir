///|
fn render_parent_next_action(
  decision : @poller.PrStateNotificationDecision,
  pr_number : Int,
  parent_branch : String?,
  merge_mode : @poller.MergeOperatorMode,
) -> String {
  @poller.next_action_line(decision.next_action) +
  "\n" +
  @poller.next_action_detail_line(
    decision.next_action,
    pr_number,
    parent_branch,
    merge_mode,
  )
}

///|
fn parent_pr_state_notification_decision(
  project_dir : String,
  tracked : @poller.TrackedPR,
  event : @poller.PollEvent,
  unresolved_threads_for_recheck : Int?,
  task_contract? : @types.TaskContract? = None,
  merge_mode? : @poller.MergeOperatorMode = @poller.MergeOperatorMode::Manual,
  review_mode? : @types.ReviewMode = @types.ReviewMode::Iterative,
) -> @poller.PrStateNotificationDecision {
  let verify_results = match task_contract {
    Some(contract) =>
      @evidence.verify_results_for_required_at_head_with_ci(
        project_dir,
        tracked.agent_id,
        contract.verify,
        tracked.last_sha,
        @types.task_contract_verify_satisfied_by_ci(contract),
      )
    None => []
  }
  @poller.pr_state_notification_decision_for_tracked_pr(
    event,
    tracked,
    unresolved_threads_for_recheck,
    task_contract~,
    review_mode~,
    verify_results~,
    merge_mode~,
  )
}

///|
fn parent_poll_tl_decision_suffix(
  decision : @poller.PrStateNotificationDecision,
  merge_mode : @poller.MergeOperatorMode,
) -> String {
  "\nTLDecision: " +
  @poller.tl_pr_state_notification_sentence(decision, merge_mode)
}

///|
fn parent_merge_policy_line(
  decision : @poller.PrStateNotificationDecision,
) -> String {
  "\n" +
  @poller.merge_policy_summary_line_for_decision(decision.policy_decision)
}

///|
fn parent_thread_recheck_line(unresolved_threads_for_recheck : Int?) -> String {
  match unresolved_threads_for_recheck {
    Some(count) =>
      "Unresolved inline review threads (GraphQL): " + count.to_string() + "\n"
    None => "Unresolved inline review threads (GraphQL): not fetched\n"
  }
}

///|
pub fn parent_poll_event_message(
  tracked : @poller.TrackedPR,
  project_dir : String,
  event : @poller.PollEvent,
  unresolved_threads_for_recheck : Int?,
  task_contract? : @types.TaskContract? = None,
  merge_mode? : @poller.MergeOperatorMode = @poller.MergeOperatorMode::Manual,
  review_mode? : @types.ReviewMode = @types.ReviewMode::Iterative,
) -> (String, @types.Status)? {
  let agent_id = tracked.agent_id
  let branch = tracked.branch
  let parent_branch = if tracked.parent_branch == "" {
    None
  } else {
    Some(tracked.parent_branch)
  }
  let pr_url = if tracked.pr_url == "" {
    ""
  } else {
    "\npr_url: " + tracked.pr_url
  }
  match event {
    ReviewCommented(_, _) | PRMerged(_) => return None
    _ => ()
  }
  let notification_decision = parent_pr_state_notification_decision(
    project_dir,
    tracked,
    event,
    unresolved_threads_for_recheck,
    task_contract~,
    merge_mode~,
    review_mode~,
  )
  match event {
    PRReady(n) => {
      let message = "[PR READY] " +
        agent_id +
        " PR #" +
        n.to_string() +
        " approved (not merged yet)\n" +
        "branch: " +
        branch +
        "\n" +
        "parent_branch: " +
        parent_branch.unwrap_or("<unknown>") +
        pr_url +
        "\n" +
        @poller.merge_mode_line(merge_mode) +
        "\n" +
        @poller.premerge_wait_line(merge_mode) +
        "\n" +
        render_parent_next_action(
          notification_decision, n, parent_branch, merge_mode,
        ) +
        parent_poll_tl_decision_suffix(notification_decision, merge_mode)
      Some((message, @types.Status::Success))
    }
    FixesPushed(n) => {
      let premerge_line = match review_mode {
        @types.ReviewMode::SinglePass =>
          "Pre-merge: resolving threads and checking gates; merge only after threads are resolved, CI is green, and merge_pr succeeds.\n"
        @types.ReviewMode::Iterative =>
          "Pre-merge: re-check the PR; merge only after review is clear and merge_pr succeeds.\n"
      }
      let message = "[FIXES PUSHED] " +
        agent_id +
        " PR #" +
        n.to_string() +
        " has new commits after review (not merged yet)\n" +
        "branch: " +
        branch +
        "\n" +
        "parent_branch: " +
        parent_branch.unwrap_or("<unknown>") +
        pr_url +
        "\n" +
        parent_thread_recheck_line(unresolved_threads_for_recheck) +
        premerge_line +
        render_parent_next_action(
          notification_decision, n, parent_branch, merge_mode,
        ) +
        parent_poll_tl_decision_suffix(notification_decision, merge_mode)
      Some((message, @types.Status::Info))
    }
    ReviewTimeout(n) => {
      let message = "[REVIEW TIMEOUT] " +
        agent_id +
        " PR #" +
        n.to_string() +
        " — no review after timeout\n" +
        "branch: " +
        branch +
        "\n" +
        "parent_branch: " +
        parent_branch.unwrap_or("<unknown>") +
        pr_url +
        "\n" +
        render_parent_next_action(
          notification_decision, n, parent_branch, merge_mode,
        ) +
        parent_poll_tl_decision_suffix(notification_decision, merge_mode)
      Some((message, @types.Status::Failure))
    }
    ReviewReceived(n, comments) =>
      if comments == "" {
        Some(
          (
            "[REVIEW] " +
            agent_id +
            " PR #" +
            n.to_string() +
            " has review comments\n" +
            "branch: " +
            branch +
            "\n" +
            "parent_branch: " +
            parent_branch.unwrap_or("<unknown>") +
            pr_url +
            "\n" +
            render_parent_next_action(
              notification_decision, n, parent_branch, merge_mode,
            ) +
            parent_poll_tl_decision_suffix(notification_decision, merge_mode),
            @types.Status::Info,
          ),
        )
      } else {
        Some(
          (
            "[REVIEW] " +
            agent_id +
            " PR #" +
            n.to_string() +
            " has review comments:\n" +
            comments +
            "\n" +
            render_parent_next_action(
              notification_decision, n, parent_branch, merge_mode,
            ) +
            parent_poll_tl_decision_suffix(notification_decision, merge_mode),
            @types.Status::Info,
          ),
        )
      }
    ReviewCommented(_, _) => None
    CIFailed(n) =>
      Some(
        (
          "[CI FAILED] " +
          agent_id +
          " PR #" +
          n.to_string() +
          " CI checks failing\n" +
          "branch: " +
          branch +
          "\n" +
          "parent_branch: " +
          parent_branch.unwrap_or("<unknown>") +
          pr_url +
          "\n" +
          render_parent_next_action(
            notification_decision, n, parent_branch, merge_mode,
          ) +
          parent_poll_tl_decision_suffix(notification_decision, merge_mode),
          @types.Status::Failure,
        ),
      )
    CIFailureCleared(n) => {
      let summary = @tools.format_tl_pr_recheck_summary(
        tracked,
        project_dir,
        unresolved_threads_for_recheck,
        task_contract~,
      )
      let prefix = parent_poll_ci_escalation_prefix(tracked)
      Some(
        (
          "[CI FAILURE CLEARED] " +
          agent_id +
          " PR #" +
          n.to_string() +
          " latest head: rollup no longer reports FAILURE/ERROR (may still be pending or incomplete; not a merge/review verdict)\n" +
          "branch: " +
          branch +
          "\n" +
          "parent_branch: " +
          parent_branch.unwrap_or("<unknown>") +
          pr_url +
          "\n" +
          prefix +
          render_parent_next_action(
            notification_decision, n, parent_branch, merge_mode,
          ) +
          "\n\n" +
          summary +
          parent_poll_tl_decision_suffix(notification_decision, merge_mode),
          @types.Status::Info,
        ),
      )
    }
    CILatestHeadRollupSucceeded(n) => {
      let summary = @tools.format_tl_pr_recheck_summary(
        tracked,
        project_dir,
        unresolved_threads_for_recheck,
        task_contract~,
      )
      let prefix = parent_poll_ci_escalation_prefix(tracked)
      Some(
        (
          "[CI LATEST HEAD] " +
          agent_id +
          " PR #" +
          n.to_string() +
          " GitHub Actions rollup reports all checks successful on the current head (not merge approval, mergeability, or review verdict).\n" +
          "branch: " +
          branch +
          "\n" +
          "parent_branch: " +
          parent_branch.unwrap_or("<unknown>") +
          pr_url +
          "\n" +
          prefix +
          render_parent_next_action(
            notification_decision, n, parent_branch, merge_mode,
          ) +
          "\n\n" +
          summary +
          parent_poll_tl_decision_suffix(notification_decision, merge_mode),
          @types.Status::Info,
        ),
      )
    }
    CopilotIssueCommentSeen(n) => {
      let summary = @tools.format_tl_pr_recheck_summary(
        tracked,
        project_dir,
        unresolved_threads_for_recheck,
        task_contract~,
      )
      Some(
        (
          "[COPILOT ISSUE COMMENT] " +
          agent_id +
          " PR #" +
          n.to_string() +
          " — GitHub Copilot issue-thread comment observed (REST). Re-check remaining review/CI/thread gates and policy.\n" +
          "branch: " +
          branch +
          "\n" +
          "parent_branch: " +
          parent_branch.unwrap_or("<unknown>") +
          pr_url +
          "\n" +
          render_parent_next_action(
            notification_decision, n, parent_branch, merge_mode,
          ) +
          "\n\n" +
          summary +
          parent_poll_tl_decision_suffix(notification_decision, merge_mode),
          @types.Status::Info,
        ),
      )
    }
    PRMerged(_) => None
    MergeReady(n) => {
      let readiness_summary = match notification_decision.policy_decision {
        @policy.MergeDecision::MergeNow(_) =>
          " — reviewed, CI green, merge gate open\n"
        _ => " — merge readiness re-check required\n"
      }
      let message = "[MERGE READY] " +
        agent_id +
        " PR #" +
        n.to_string() +
        readiness_summary +
        "branch: " +
        branch +
        "\n" +
        "parent_branch: " +
        parent_branch.unwrap_or("<unknown>") +
        pr_url +
        "\n" +
        @poller.merge_mode_line(merge_mode) +
        parent_merge_policy_line(notification_decision) +
        "\n" +
        render_parent_next_action(
          notification_decision, n, parent_branch, merge_mode,
        ) +
        parent_poll_tl_decision_suffix(notification_decision, merge_mode)
      Some((message, @poller.merge_ready_status(merge_mode)))
    }
    ReviewThreadsResolved(n) => {
      let summary = @tools.format_tl_pr_recheck_summary(
        tracked,
        project_dir,
        unresolved_threads_for_recheck,
        task_contract~,
      )
      let message = "[THREADS RESOLVED] " +
        agent_id +
        " PR #" +
        n.to_string() +
        " review threads were marked resolved (not a merge/review verdict).\n" +
        "branch: " +
        branch +
        "\n" +
        "parent_branch: " +
        parent_branch.unwrap_or("<unknown>") +
        pr_url +
        "\n" +
        render_parent_next_action(
          notification_decision, n, parent_branch, merge_mode,
        ) +
        "\n\n" +
        summary +
        parent_poll_tl_decision_suffix(notification_decision, merge_mode)
      Some((message, @types.Status::Info))
    }
  }
}

///|
fn poll_event_pr_number(event : @poller.PollEvent) -> Int {
  match event {
    PRReady(n) => n
    ReviewReceived(n, _) => n
    ReviewCommented(n, _) => n
    FixesPushed(n) => n
    ReviewTimeout(n) => n
    CIFailed(n) => n
    CIFailureCleared(n) => n
    CILatestHeadRollupSucceeded(n) => n
    CopilotIssueCommentSeen(n) => n
    PRMerged(pr) => pr.pr_number
    MergeReady(n) => n
    ReviewThreadsResolved(n) => n
  }
}

///|
fn poll_event_tracked_snapshot(
  event : @poller.PollEvent,
  tracked : @poller.TrackedPR?,
) -> @poller.TrackedPR? {
  match event {
    PRMerged(pr) => Some(pr)
    _ => tracked
  }
}

///|
fn poll_event_is_external_merge(event : @poller.PollEvent) -> Bool {
  match event {
    PRMerged(_) => true
    _ => false
  }
}

///|
fn lifecycle_suppresses_poller_followups(
  lifecycle : @phase.AgentLifecycle,
) -> Bool {
  match lifecycle.process {
    @phase.ProcessState::Finalized(..) | @phase.ProcessState::Failed(..) => true
    @phase.ProcessState::Finalizing(reason=@phase.FinalizeReason::Merged) =>
      true
    _ => false
  }
}

///|
/// Cap API review bodies for terminal injection (Copilot/GitHub can return full PR markdown).
pub let review_summary_pane_max_chars : Int = 2500

///|
pub fn clamp_review_summary_for_pane(body : String) -> String {
  let suffix = "\n... [truncated; open PR on GitHub for full review text]"
  if body.length() <= review_summary_pane_max_chars {
    body
  } else {
    body[0:review_summary_pane_max_chars].to_owned() + suffix
  }
}

///|
/// Direct review/CI injection for the owning leaf pane (`plan_delivery` adds `[from: …]`).
/// Parent still receives `parent_poll_event_message` for triage/merge except
/// `ReviewCommented` (non-blocking thread goes to the leaf only).
/// `tracked` supplies poller snapshot for CI lines when review-wait timeout escalation applies.
pub fn leaf_poll_review_injection_message(
  event : @poller.PollEvent,
  tracked : @poller.TrackedPR?,
) -> (String, @types.Status)? {
  match event {
    ReviewReceived(n, body) =>
      Some(
        (
          if body == "" {
            "[REVIEW] PR #" + n.to_string() + ": changes requested"
          } else {
            "[REVIEW] PR #" +
            n.to_string() +
            ": " +
            clamp_review_summary_for_pane(body)
          },
          @types.Status::Info,
        ),
      )
    ReviewCommented(n, body) =>
      Some(
        (
          if body == "" {
            "[REVIEW] PR #" + n.to_string() + ": non-blocking review comments"
          } else {
            "[REVIEW] PR #" +
            n.to_string() +
            ": " +
            clamp_review_summary_for_pane(body)
          },
          @types.Status::Info,
        ),
      )
    CIFailed(n) =>
      Some(
        (
          "[REVIEW] PR #" + n.to_string() + ": CI checks failing",
          @types.Status::Failure,
        ),
      )
    CIFailureCleared(n) => {
      let base = "[REVIEW] PR #" +
        n.to_string() +
        ": CI no longer reports failure on latest head — verify full status on GitHub (not merge or approval)"
      let msg = match tracked {
        Some(pr) =>
          if @poller.tl_tracked_pr_copilot_review_silent_escalation_active(pr) {
            "[REVIEW] PR #" +
            n.to_string() +
            ": CI cleared but still no review. Run: gh pr edit --add-reviewer @copilot"
          } else {
            base
          }
        None => base
      }
      Some((msg, @types.Status::Info))
    }
    CILatestHeadRollupSucceeded(n) => {
      let base = "[REVIEW] PR #" +
        n.to_string() +
        ": Actions rollup: all checks successful on latest head — re-check review thread and policy (not merge or approval by itself)"
      let msg = match tracked {
        Some(pr) =>
          if @poller.tl_tracked_pr_copilot_review_silent_escalation_active(pr) {
            "[REVIEW] PR #" +
            n.to_string() +
            ": CI green but still no review. Run: gh pr edit --add-reviewer @copilot"
          } else {
            base
          }
        None => base
      }
      Some((msg, @types.Status::Info))
    }
    CopilotIssueCommentSeen(n) =>
      Some(
        (
          "[REVIEW] PR #" +
          n.to_string() +
          ": GitHub Copilot issue-thread comment observed — re-check remaining gates (not merge or approval by itself)",
          @types.Status::Info,
        ),
      )
    PRReady(n) =>
      Some(
        (
          "[REVIEW] PR #" +
          n.to_string() +
          ": approved (not merged until merge_pr succeeds)",
          @types.Status::Success,
        ),
      )
    FixesPushed(_) => None
    ReviewTimeout(_) => None
    PRMerged(_) => None
    MergeReady(_) => None
    ReviewThreadsResolved(n) =>
      Some(
        (
          "[REVIEW] PR #" +
          n.to_string() +
          ": review threads marked resolved (re-check state)",
          @types.Status::Info,
        ),
      )
  }
}

///|
priv struct PendingPollParentRow {
  tracked : @poller.TrackedPR
  leaf_agent_id : String
  message : String
  status : @types.Status
  category : @poller.TlTrackedPrWorkflowCategory
  merge_mode : @poller.MergeOperatorMode
}

///|
fn supervisor_children_len_for_parent(
  project_dir : String,
  parent_id : String,
) -> Int {
  match @phase.read_lifecycle(project_dir, parent_id) {
    Some(lc) =>
      match lc.workflow {
        @phase.WorkflowState::Supervisor(
          @phase.SupervisorLifecycle::Supervising(children~, ..)
        ) => children.length()
        @phase.WorkflowState::Supervisor(
          @phase.SupervisorLifecycle::WaveComplete(children~, ..)
        ) => children.length()
        _ => 0
      }
    None => 0
  }
}

///|
fn build_agent_wave_map(
  poller : @poller.PollerState,
  registry : @registry.AgentRegistry,
  project_dir : String,
) -> Map[String, (String, Int)] {
  let m : Map[String, (String, Int)] = {}
  for tracked in poller.tracked.values() {
    try {
      let parent = registry.get_parent(tracked.agent_id)
      let parent_id = parent.agent_id.to_string()
      match @phase.read_lifecycle(project_dir, parent_id) {
        Some(plc) =>
          match plc.workflow {
            @phase.WorkflowState::Supervisor(
              @phase.SupervisorLifecycle::Supervising(wave~, ..)
            ) => m.set(tracked.agent_id, (parent_id, wave))
            @phase.WorkflowState::Supervisor(
              @phase.SupervisorLifecycle::WaveComplete(wave~, ..)
            ) => m.set(tracked.agent_id, (parent_id, wave))
            _ => ()
          }
        None => ()
      }
    } catch {
      _ => ()
    }
  }
  m
}

///|
fn rollup_contains_entry(
  rollup : @poller.WaveRollup,
  t : @poller.WaveRollupEntry,
) -> Bool {
  for e in rollup.entries {
    if e == t {
      return true
    }
  }
  false
}

///|
fn row_in_any_multi_rollup(
  row : PendingPollParentRow,
  rollups : Array[@poller.WaveRollup],
) -> Bool {
  let t : @poller.WaveRollupEntry = {
    pr_number: row.tracked.pr_number,
    agent_id: row.leaf_agent_id,
    category: row.category,
  }
  for r in rollups {
    if rollup_contains_entry(r, t) {
      return true
    }
  }
  false
}

///|
fn rollup_rows_for(
  rows : Array[PendingPollParentRow],
  rollup : @poller.WaveRollup,
) -> Array[PendingPollParentRow] {
  let matched : Array[PendingPollParentRow] = []
  for row in rows {
    let t : @poller.WaveRollupEntry = {
      pr_number: row.tracked.pr_number,
      agent_id: row.leaf_agent_id,
      category: row.category,
    }
    if rollup_contains_entry(rollup, t) {
      matched.push(row)
    }
  }
  matched
}

///|
fn rollup_delivery_status(rows : Array[PendingPollParentRow]) -> @types.Status {
  let mut has_failure = false
  let mut has_success = false
  for row in rows {
    if row.status == @types.Status::Failure {
      has_failure = true
    }
    if row.status == @types.Status::Success {
      has_success = true
    }
  }
  if has_failure {
    @types.Status::Failure
  } else if has_success {
    @types.Status::Success
  } else {
    @types.Status::Info
  }
}

///|
fn rollup_merge_mode(
  rows : Array[PendingPollParentRow],
) -> @poller.MergeOperatorMode? {
  if rows.length() == 0 {
    return None
  }
  let mut has_manual = false
  let mut has_automerge = false
  for row in rows {
    match row.merge_mode {
      @poller.MergeOperatorMode::Manual => has_manual = true
      @poller.MergeOperatorMode::Automerge => has_automerge = true
      @poller.MergeOperatorMode::Mixed => {
        has_manual = true
        has_automerge = true
      }
    }
  }
  Some(
    if has_manual && has_automerge {
      @poller.MergeOperatorMode::Mixed
    } else if has_automerge {
      @poller.MergeOperatorMode::Automerge
    } else {
      @poller.MergeOperatorMode::Manual
    },
  )
}

///|
pub fn ServerState::plan_poll_event_deliveries(
  self : ServerState,
  event : @poller.PollEvent,
  agent_id : String,
  unresolved_threads_for_recheck : Int?,
  skip_parent? : Bool = false,
) -> Array[PlannedDelivery] {
  let deliveries : Array[PlannedDelivery] = []
  let tracked = self.poller.get(poll_event_pr_number(event))
  let leaf_agent_id = match tracked {
    Some(pr) => pr.agent_id
    None => agent_id
  }
  let leaf_owner = self.registry.get_opt(leaf_agent_id)
  let local_cfg = match tracked {
    Some(pr) =>
      local_config_for_agent(
        self.config.project_dir,
        self.registry,
        pr.agent_id,
      )
    None => None
  }
  let review_mode = match tracked {
    Some(pr) => pr.review_mode
    None => review_mode_for_agent(self.config, local_cfg)
  }
  match (tracked, event) {
    (Some(_), ReviewReceived(n, body)) =>
      @tools.apply_dev_event(
        self.config.project_dir,
        leaf_agent_id,
        @phase.DevEvent::ReviewReceivedEv(pr_number=n, body~),
        registry=Some(self.registry),
      )
    (Some(_), ReviewCommented(_, _)) => ()
    (Some(_), PRReady(n)) =>
      @tools.apply_dev_event(
        self.config.project_dir,
        leaf_agent_id,
        @phase.DevEvent::ReviewApprovedEv(pr_number=n),
        registry=Some(self.registry),
      )
    (Some(pr), FixesPushed(n)) =>
      @tools.apply_dev_event(
        self.config.project_dir,
        leaf_agent_id,
        @phase.DevEvent::FixesPushedEv(pr_number=n, sha=pr.last_sha),
        registry=Some(self.registry),
        review_mode~,
      )
    _ => ()
  }
  @phase.sync_parent_child_lifecycle(
    self.config.project_dir,
    self.config.terminal_session,
    self.registry,
    leaf_agent_id,
    self.current_lifecycle(leaf_agent_id),
  )
  // Parent notification — TL triage / merge signals (comment-only reviews: leaf only)
  if !skip_parent {
    match tracked {
      Some(pr) =>
        match
          parent_poll_event_message(
            pr,
            self.config.project_dir,
            event,
            unresolved_threads_for_recheck,
            merge_mode=@poller.merge_operator_mode_from_automerge(
              automerge_enabled_for_agent(self.config, local_cfg),
            ),
            review_mode~,
          ) {
          Some((message, status)) =>
            try {
              let parent = self.resolve_parent_for_delivery(leaf_agent_id)
              ignore(
                @poller.append_delivery_log_line(
                  self.append_file,
                  self.config.project_dir,
                  "[poller-parent] agent=" +
                  leaf_agent_id +
                  " parent=" +
                  parent.agent_id.to_string() +
                  " terminal_target=" +
                  parent.terminal_target
                  .map(@types.LocalTarget::to_string)
                  .unwrap_or("NONE"),
                ),
              )
              deliveries.push({
                recipient_id: parent.agent_id.to_string(),
                sender_id: leaf_agent_id,
                body: message,
                status,
                delivery: @message.plan_delivery(
                  parent, leaf_agent_id, message, status,
                ),
              })
            } catch {
              _ => ()
            }
          None => ()
        }
      None => ()
    }
  }
  // Owning leaf — direct `[REVIEW] PR #n: …` injection (terminal_target in registry)
  match leaf_owner {
    Some(agent) =>
      match agent.state {
        @types.AgentState::Active | @types.AgentState::Completing =>
          match leaf_poll_review_injection_message(event, tracked) {
            Some((message, status)) =>
              deliveries.push({
                recipient_id: agent.agent_id.to_string(),
                sender_id: "poller",
                body: message,
                status,
                delivery: @message.plan_delivery(
                  agent, "poller", message, status,
                ),
              })
            None => ()
          }
        _ => () // Done/Failed/Spawning — skip leaf delivery
      }
    None => ()
  }
  deliveries
}

///|
/// Generate a PR comment body for a poll event, if it warrants one.

///|
async fn deliver_poller_stall_notifications(
  state : ServerState,
  now : Int64,
  runner : async (Array[@workspace.Command]) -> Array[Int],
) -> Unit {
  let prs : Array[@poller.TrackedPR] = []
  state.poller.tracked.each(fn(_k, pr) { prs.push(pr) })
  for pr in prs {
    deliver_poller_stall_notification_for(state, pr, now, runner)
  }
}

///|
pub fn poll_event_beads_note_and_state(
  event : @poller.PollEvent,
) -> (String, String, String)? {
  match event {
    ReviewReceived(n, _) =>
      Some(
        (
          "Choir poller: PR #" + n.to_string() + " review requested changes",
          "review",
          "changes_requested",
        ),
      )
    ReviewCommented(n, _) =>
      Some(
        (
          "Choir poller: PR #" + n.to_string() + " received review comments",
          "review",
          "commented",
        ),
      )
    PRReady(n) =>
      Some(
        (
          "Choir poller: PR #" + n.to_string() + " review gate ready",
          "review",
          "ready",
        ),
      )
    FixesPushed(n) =>
      Some(
        (
          "Choir poller: PR #" + n.to_string() + " fixes pushed after review",
          "review",
          "fixes_pushed",
        ),
      )
    ReviewTimeout(n) =>
      Some(
        (
          "Choir poller: PR #" + n.to_string() + " review timeout",
          "review",
          "timeout",
        ),
      )
    CIFailed(n) =>
      Some(
        ("Choir poller: PR #" + n.to_string() + " CI failing", "ci", "failing"),
      )
    CIFailureCleared(n) =>
      Some(
        (
          "Choir poller: PR #" + n.to_string() + " CI failure cleared",
          "ci",
          "cleared",
        ),
      )
    CILatestHeadRollupSucceeded(n) =>
      Some(
        (
          "Choir poller: PR #" + n.to_string() + " CI latest head succeeded",
          "ci",
          "success",
        ),
      )
    CopilotIssueCommentSeen(n) =>
      Some(
        (
          "Choir poller: PR #" + n.to_string() + " Copilot issue comment seen",
          "review",
          "copilot_seen",
        ),
      )
    MergeReady(n) =>
      Some(
        (
          "Choir poller: PR #" + n.to_string() + " merge gate open",
          "merge",
          "ready",
        ),
      )
    ReviewThreadsResolved(n) =>
      Some(
        (
          "Choir poller: PR #" + n.to_string() + " review threads resolved",
          "review",
          "threads_resolved",
        ),
      )
    PRMerged(pr) =>
      Some(
        (
          "Choir poller: PR #" +
          pr.pr_number.to_string() +
          " observed merged externally",
          "merge",
          "merged",
        ),
      )
  }
}

///|
async fn mirror_poll_event_to_beads(
  state : ServerState,
  tracked : @poller.TrackedPR,
  event : @poller.PollEvent,
  runner : async (Array[@workspace.Command]) -> Array[Int],
) -> Unit {
  let issue_id = match
    @tools.beads_issue_id_for_agent(
      state.config.project_dir,
      Some(state.registry),
      tracked.agent_id,
    ) {
    Some(id) => id
    None => return
  }
  match event {
    PRMerged(pr) =>
      ignore(
        runner([
          @tools.beads_close_merged_command(
            state.config.project_dir,
            issue_id,
            pr.pr_number,
          ),
          @tools.beads_audit_record_command(
            state.config.project_dir,
            Some(issue_id),
            "tool_call",
            "poller",
            "observed merged PR #" + pr.pr_number.to_string(),
          ),
        ]),
      )
    _ =>
      match poll_event_beads_note_and_state(event) {
        Some((note, dimension, value)) =>
          ignore(
            runner([
              @tools.beads_note_command(
                state.config.project_dir,
                issue_id,
                note,
              ),
              @tools.beads_set_state_command(
                state.config.project_dir,
                issue_id,
                dimension,
                value,
                note,
              ),
              @tools.beads_audit_record_command(
                state.config.project_dir,
                Some(issue_id),
                "tool_call",
                "poller",
                note,
              ),
            ]),
          )
        None => ()
      }
  }
}

///|
fn poll_event_starts_auto_resolve_outdated_threads(
  event : @poller.PollEvent,
  review_mode : @types.ReviewMode,
) -> Bool {
  match event {
    @poller.PollEvent::FixesPushed(_) =>
      review_mode == @types.ReviewMode::Iterative
    _ => false
  }
}

///|
fn ServerState::log_review_thread_ref_fetch_failed(
  self : ServerState,
  pr_number : Int,
) -> Unit {
  @moontrace.warn("poller review thread ref fetch failed", fields=[
    @moontrace.field("pr", pr_number),
  ])
  append_poller_delivery_line(
    self.append_file,
    self.config.project_dir,
    "review thread ref fetch failed pr=" +
    pr_number.to_string() +
    " keeping prior snapshot",
  )
}

///|
pub async fn ServerState::refresh_unresolved_review_thread_refs_snapshot(
  self : ServerState,
  tracked : @poller.TrackedPR,
  capture : async (@workspace.Command) -> (Int, String),
) -> @poller.TrackedPR? {
  match
    @tools.fetch_unresolved_review_thread_refs(
      tracked.pr_number,
      self.config.project_dir,
      capture,
    ) {
    Some(thread_refs) => {
      let refreshed = { ..tracked, unresolved_thread_ids: thread_refs }
      self.poller.restore(refreshed)
      Some(refreshed)
    }
    None => {
      self.log_review_thread_ref_fetch_failed(tracked.pr_number)
      None
    }
  }
}

///|
pub async fn ServerState::auto_resolve_outdated_review_threads_for_pending(
  self : ServerState,
  tracked : @poller.TrackedPR,
  capture : async (@workspace.Command) -> (Int, String),
) -> @poller.TrackedPR {
  if tracked.review_mode != @types.ReviewMode::Iterative ||
    !tracked.auto_resolve_outdated_pending {
    return tracked
  }
  let ids = @poller.review_thread_ids_to_auto_resolve_for_pending(
    tracked.review_mode,
    tracked.unresolved_thread_ids,
  )
  if ids.length() == 0 {
    append_poller_delivery_line(
      self.append_file,
      self.config.project_dir,
      "poller auto-resolved 0 outdated review thread(s) pr=" +
      tracked.pr_number.to_string(),
    )
    let updated = { ..tracked, auto_resolve_outdated_pending: false }
    self.poller.restore(updated)
    return updated
  }
  let resolved : Array[String] = []
  for thread_id in ids {
    let cmd = @tools.resolve_review_thread_gh_command(
      self.config.project_dir,
      thread_id,
    )
    let (exit_code, output) = capture(cmd)
    let response = @tools.interpret_resolve_review_thread_result(
      exit_code, output, thread_id,
    )
    if response.is_ok() {
      resolved.push(thread_id)
    } else {
      let message = response.error_message().unwrap_or("unknown error")
      @moontrace.warn("poller auto-resolve review thread failed", fields=[
        @moontrace.field("pr", tracked.pr_number),
        @moontrace.field("thread_id", thread_id),
        @moontrace.field("error", message),
      ])
      append_poller_delivery_line(
        self.append_file,
        self.config.project_dir,
        "auto-resolve failed pr=" +
        tracked.pr_number.to_string() +
        " thread=" +
        thread_id +
        " error=" +
        message,
      )
    }
  }
  append_poller_delivery_line(
    self.append_file,
    self.config.project_dir,
    "poller auto-resolved " +
    resolved.length().to_string() +
    " outdated review thread(s) pr=" +
    tracked.pr_number.to_string(),
  )
  if resolved.length() == 0 {
    return tracked
  }
  let remaining : Array[@poller.ReviewThreadRef] = []
  for thread in tracked.unresolved_thread_ids {
    if !resolved.contains(thread.id) {
      remaining.push(thread)
    }
  }
  let still_pending = @poller.review_thread_ids_to_auto_resolve_for_pending(
      tracked.review_mode,
      remaining,
    ).length() >
    0
  let updated = {
    ..tracked,
    unresolved_thread_ids: remaining,
    auto_resolve_outdated_pending: still_pending,
  }
  self.poller.restore(updated)
  updated
}

///|
pub async fn ServerState::auto_resolve_outdated_review_threads_for_event(
  self : ServerState,
  event : @poller.PollEvent,
  tracked : @poller.TrackedPR,
  capture : async (@workspace.Command) -> (Int, String),
) -> @poller.TrackedPR {
  if !poll_event_starts_auto_resolve_outdated_threads(
      event,
      tracked.review_mode,
    ) {
    return tracked
  }
  let pending = { ..tracked, auto_resolve_outdated_pending: true }
  self.poller.restore(pending)
  self.auto_resolve_outdated_review_threads_for_pending(pending, capture)
}

///|
async fn ServerState::retry_auto_resolve_outdated_review_threads(
  self : ServerState,
  capture : async (@workspace.Command) -> (Int, String),
  skipped_prs : Map[Int, Bool],
) -> Unit {
  for tracked in self.poller.tracked.values() {
    if skipped_prs.contains(tracked.pr_number) {
      continue
    }
    if tracked.review_mode != @types.ReviewMode::Iterative ||
      !tracked.auto_resolve_outdated_pending {
      continue
    }
    match
      self.refresh_unresolved_review_thread_refs_snapshot(tracked, capture) {
      Some(refreshed) =>
        ignore(
          self.auto_resolve_outdated_review_threads_for_pending(
            refreshed, capture,
          ),
        )
      None => ()
    }
  }
}

///|
async fn deliver_pending_poll_events(
  state : ServerState,
  pending_events : Array[@poller.PollEvent],
  pending_agent_ids : Array[String],
  runner : async (Array[@workspace.Command]) -> Array[Int],
  capture? : async (@workspace.Command) -> (Int, String) = @exec.capture_command_stdout,
  automerge_capture? : async (@workspace.Command) -> (Int, String) = @exec.capture_command_merged,
) -> Unit {
  let pending_parent_rows : Array[PendingPollParentRow] = []
  let automerge_attempted_prs : Map[Int, Bool] = {}
  let auto_resolve_attempted_prs : Map[Int, Bool] = {}
  for i = 0; i < pending_events.length(); i = i + 1 {
    let event = pending_events[i]
    let agent_id = pending_agent_ids[i]
    // Skip suspended agents — the human is actively editing the worktree
    // and the daemon must not race against them. `resume` RPC flips
    // the agent back to Active and unblocks delivery.
    if state.registry.get_opt(agent_id) is Some(agent) &&
      agent.state == @types.AgentState::Suspended {
      continue
    }
    let tracked_before_delivery = poll_event_tracked_snapshot(
      event,
      state.poller.get(poll_event_pr_number(event)),
    )
    let automerge_enabled = match tracked_before_delivery {
      Some(pr) =>
        automerge_enabled_for_agent(
          state.config,
          local_config_for_agent(
            state.config.project_dir,
            state.registry,
            pr.agent_id,
          ),
        )
      None => false
    }
    let review_mode = match tracked_before_delivery {
      Some(pr) => pr.review_mode
      None => state.config.review_mode
    }
    let should_fetch_threads = should_fetch_unresolved_threads_for_pending_event(
      event,
      automerge_enabled,
      review_mode~,
    )
    if poll_event_starts_auto_resolve_outdated_threads(event, review_mode) {
      auto_resolve_attempted_prs.set(poll_event_pr_number(event), true)
    }
    let (tracked_for_delivery, unresolved_threads) = match
      tracked_before_delivery {
      Some(pr) =>
        if should_fetch_threads {
          match
            state.refresh_unresolved_review_thread_refs_snapshot(pr, capture) {
            Some(refreshed) => {
              let after_resolve = state.auto_resolve_outdated_review_threads_for_event(
                event, refreshed, capture,
              )
              (
                Some(after_resolve),
                Some(after_resolve.unresolved_thread_ids.length()),
              )
            }
            None => (Some(pr), Some(pr.unresolved_thread_ids.length()))
          }
        } else {
          (Some(pr), None)
        }
      None => (None, None)
    }
    match (event, tracked_for_delivery) {
      (PRMerged(pr), Some(_)) =>
        state.reconcile_external_merge_with_runner(
          pr.agent_id,
          pr.pr_number,
          pr.branch,
          pr.parent_branch,
          pr.pr_url,
          runner,
        )
      _ =>
        for
          planned in state.plan_poll_event_deliveries(
            event,
            agent_id,
            unresolved_threads,
            skip_parent=true,
          ) {
          ignore(state.durable_dispatch_planned(planned, runner))
        }
    }
    match tracked_for_delivery {
      Some(pr) => {
        append_poll_snapshot_evidence(state, pr, event, unresolved_threads)
        mirror_poll_event_to_beads(state, pr, event, runner)
        if poll_event_is_external_merge(event) {
          continue
        }
        if !automerge_attempted_prs.contains(pr.pr_number) {
          automerge_attempted_prs.set(pr.pr_number, true)
          if maybe_trigger_automerge_for_pending_event(
              state,
              event,
              pr,
              unresolved_threads,
              runner,
              capture=automerge_capture,
              review_mode~,
            ) {
            continue
          }
        }
        match
          parent_poll_event_message(
            pr,
            state.config.project_dir,
            event,
            unresolved_threads,
            task_contract=task_contract_for_agent(
              state.config.project_dir,
              state.registry,
              pr.agent_id,
            ),
            merge_mode=@poller.merge_operator_mode_from_automerge(
              automerge_enabled,
            ),
            review_mode~,
          ) {
          Some((message, status)) => {
            let category = @poller.plan_tl_poll_event_parent(
              event,
              pr,
              unresolved_threads,
              review_mode~,
            )
            pending_parent_rows.push({
              tracked: pr,
              leaf_agent_id: pr.agent_id,
              message,
              status,
              category,
              merge_mode: @poller.merge_operator_mode_from_automerge(
                automerge_enabled,
              ),
            })
          }
          None => ()
        }
      }
      None => ()
    }
    match pr_comment_body(event, agent_id, review_mode~) {
      Some((pr_number, body)) =>
        ignore(
          runner([
            @workspace.gh_pr_comment(pr_number, body, state.config.project_dir),
          ]),
        )
      None => ()
    }
  }
  state.retry_auto_resolve_outdated_review_threads(
    capture, auto_resolve_attempted_prs,
  )
  if pending_parent_rows.length() > 0 {
    let rollup_entries : Array[@poller.WaveRollupEntry] = []
    for row in pending_parent_rows {
      rollup_entries.push({
        pr_number: row.tracked.pr_number,
        agent_id: row.leaf_agent_id,
        category: row.category,
      })
    }
    let wave_map = build_agent_wave_map(
      state.poller,
      state.registry,
      state.config.project_dir,
    )
    let (rollups, _) = @poller.build_wave_rollups(rollup_entries, wave_map)
    for rollup in rollups {
      let total_in_wave = supervisor_children_len_for_parent(
        state.config.project_dir,
        rollup.parent_id,
      )
      let matched = rollup_rows_for(pending_parent_rows, rollup)
      let body = @poller.format_wave_rollup(
        rollup,
        total_in_wave,
        merge_mode=rollup_merge_mode(matched),
      )
      let status = rollup_delivery_status(matched)
      let sender = "poller"
      try {
        let parent = state.resolve_parent_by_id(rollup.parent_id)
        ignore(
          @poller.append_delivery_log_line(
            state.append_file,
            state.config.project_dir,
            "[poller-parent-wave] parent=" +
            rollup.parent_id +
            " wave=" +
            rollup.wave.to_string(),
          ),
        )
        ignore(
          state.durable_deliver_to_agent(parent, sender, body, status, runner),
        )
      } catch {
        _ => ()
      }
    }
    for row in pending_parent_rows {
      if row_in_any_multi_rollup(row, rollups) {
        continue
      }
      try {
        let parent = state.resolve_parent_for_delivery(row.leaf_agent_id)
        ignore(
          @poller.append_delivery_log_line(
            state.append_file,
            state.config.project_dir,
            "[poller-parent] agent=" +
            row.leaf_agent_id +
            " parent=" +
            parent.agent_id.to_string() +
            " terminal_target=" +
            parent.terminal_target
            .map(@types.LocalTarget::to_string)
            .unwrap_or("NONE"),
          ),
        )
        ignore(
          state.durable_deliver_to_agent(
            parent,
            row.leaf_agent_id,
            row.message,
            row.status,
            runner,
          ),
        )
      } catch {
        _ => ()
      }
    }
  }
}

///|
fn append_poller_delivery_line(
  append_file : (String, String) -> Bool,
  project_dir : String,
  line : String,
) -> Unit {
  ignore(
    @poller.append_delivery_log_line(
      append_file,
      project_dir,
      "[poller] " + line,
    ),
  )
}

///|
fn poller_sanitize_event_for_log(raw : String) -> String {
  let buf = StringBuilder::new()
  for c in raw {
    if c == '\n' {
      buf.write_string("\\n")
    } else if c == '\r' {
      buf.write_string("\\r")
    } else {
      buf.write_char(c)
    }
  }
  let escaped = buf.to_string()
  let max_len = 200
  if escaped.length() <= max_len {
    escaped
  } else {
    escaped[0:max_len].to_owned() + "..."
  }
}

///|
pub async fn deliver_orphaned_pr_notification_for(
  state : ServerState,
  pr : @poller.TrackedPR,
  runner : async (Array[@workspace.Command]) -> Array[Int],
) -> Unit {
  // Poll delivery's stale-registry read emits `[ORPHANED PR]` only. The hard
  // `[FAILED: ...] disconnected unexpectedly` banner is gated in
  // `handler_disconnect.mbt`.
  if lifecycle_suppresses_poller_followups(state.current_lifecycle(pr.agent_id)) {
    return
  }
  let agent_opt = state.registry.get_opt(pr.agent_id)
  let agent_is_active = match agent_opt {
    Some(agent) =>
      agent.state == @types.AgentState::Active ||
      agent.state == @types.AgentState::Completing
    None => false
  }
  let orphans = @poller.detect_orphaned_prs([(pr, agent_is_active)])
  let append_file = state.append_file
  let project_dir = state.config.project_dir
  for p in orphans {
    let message = "[ORPHANED PR] PR #" +
      p.pr_number.to_string() +
      " (" +
      p.agent_id +
      ") — owning agent is no longer active; merge manually via merge_pr or respawn via rescue_leaf"
    try {
      let parent = state.resolve_parent_for_delivery(p.agent_id)
      ignore(
        @poller.append_delivery_log_line(
          append_file,
          project_dir,
          "[poller-parent] agent=" +
          p.agent_id +
          " parent=" +
          parent.agent_id.to_string() +
          " terminal_target=" +
          parent.terminal_target
          .map(@types.LocalTarget::to_string)
          .unwrap_or("NONE"),
        ),
      )
      match
        state.durable_deliver_to_agent(
          parent,
          p.agent_id,
          message,
          @types.Status::Failure,
          runner,
        ) {
        Ok(_) =>
          match state.poller.get(p.pr_number) {
            Some(current) =>
              state.poller.restore({ ..current, orphan_notified: true })
            None => ()
          }
        Err(_) => ()
      }
    } catch {
      _ => ()
    }
  }
}

///|
async fn deliver_orphaned_pr_notifications(
  state : ServerState,
  runner : async (Array[@workspace.Command]) -> Array[Int],
) -> Unit {
  let prs : Array[@poller.TrackedPR] = []
  state.poller.tracked.each(fn(_k, pr) { prs.push(pr) })
  for pr in prs {
    deliver_orphaned_pr_notification_for(state, pr, runner)
  }
}

///|
pub fn poll_events_delivery_summary(
  events : Array[@poller.PollEvent],
) -> String {
  if events.length() == 0 {
    return "no change"
  }
  let parts : Array[String] = []
  for e in events {
    parts.push(poller_sanitize_event_for_log(e.to_string()))
  }
  parts.join("; ")
}

///|
fn log_poller_pr_tick(
  append_file : (String, String) -> Bool,
  project_dir : String,
  log : @poller.PollerPrTickLog,
) -> Unit {
  let action = if log.skipped_backoff {
    "skipped_backoff"
  } else if log.untracked_closed {
    "untracked_closed"
  } else if log.polled_network && !log.poll_succeeded {
    "poll_failed"
  } else {
    "polled"
  }
  let events_summary = poll_events_delivery_summary(log.events)
  let skip_reason = if log.skipped_backoff {
    "backoff_until=" + log.backoff_until.to_string()
  } else {
    ""
  }
  // Per-PR per-tick: log at INFO only when something actually changed (an
  // event, a review-state change, a failure-count change, or a non-`polled`
  // action). The steady-state "polled, nothing changed" line — once per
  // tracked PR every tick — goes to TRACE so the INFO log isn't flooded.
  let pr_fields = [
    @moontrace.field("pr", log.pr_number),
    @moontrace.field("agent", log.agent_id),
    @moontrace.field("action", action),
    @moontrace.field("skip_reason", skip_reason),
    @moontrace.field("prior_review", log.prior_review_state.to_wire_string()),
    @moontrace.field(
      "detected_review",
      log.detected_review_state.to_wire_string(),
    ),
    @moontrace.field("events", events_summary),
    @moontrace.field("failures", log.consecutive_failures),
    @moontrace.field("prev_failures", log.previous_consecutive_failures),
  ]
  let pr_tick_interesting = action != "polled" ||
    log.events.length() > 0 ||
    log.detected_review_state.to_wire_string() !=
    log.prior_review_state.to_wire_string() ||
    log.consecutive_failures != log.previous_consecutive_failures
  if pr_tick_interesting {
    @moontrace.info("poller pr", fields=pr_fields)
  } else {
    @moontrace.trace("poller pr", fields=pr_fields)
  }
  let line = "pr=" +
    log.pr_number.to_string() +
    " agent=" +
    log.agent_id +
    " action=" +
    action +
    (if skip_reason != "" { " " + skip_reason } else { "" }) +
    " prior=" +
    log.prior_review_state.to_wire_string() +
    " detected=" +
    log.detected_review_state.to_wire_string() +
    " events=" +
    events_summary +
    " failures=" +
    log.consecutive_failures.to_string()
  append_poller_delivery_line(append_file, project_dir, line)
  if log.consecutive_failures > log.previous_consecutive_failures {
    @moontrace.info("poller backoff", fields=[
      @moontrace.field("pr", log.pr_number),
      @moontrace.field("agent", log.agent_id),
      @moontrace.field("consecutive_failures", log.consecutive_failures),
      @moontrace.field("backoff_until", log.backoff_until),
    ])
    append_poller_delivery_line(
      append_file,
      project_dir,
      "backoff pr=" +
      log.pr_number.to_string() +
      " consecutive_failures=" +
      log.consecutive_failures.to_string() +
      " backoff_until=" +
      log.backoff_until.to_string(),
    )
  }
}

///|
pub async fn ServerState::process_poller_tick_with(
  self : ServerState,
  now : Int64,
  timeout : Int64,
  poll : async (Int, Bool) -> (
    Bool,
    @poller.ReviewState,
    String,
    @poller.CiRollupStatus,
    String,
    Bool,
    Bool,
  ),
  runner? : async (Array[@workspace.Command]) -> Array[Int] = @exec.run_sequence,
) -> Unit {
  self.mutex_registry.expire(now)
  let pending_events = []
  let pending_agent_ids = []
  self.poller.tick_with(
    now,
    timeout,
    poll,
    fn(event, agent_id) {
      pending_events.push(event)
      pending_agent_ids.push(agent_id)
    },
    fn(_) { () },
  )
  if pending_events.length() > 0 {
    self.request_goal_judge_tick()
  }
  deliver_orphaned_pr_notifications(self, runner)
  deliver_pending_poll_events(self, pending_events, pending_agent_ids, runner)
  deliver_poller_stall_notifications(self, now, runner)
  self.sweep_outbox(now)
  ignore(self.poller.write_state_file(self.config.project_dir))
}

///|
pub async fn ServerState::process_poller_tick(
  self : ServerState,
  now : Int64,
  timeout : Int64,
  runner? : async (Array[@workspace.Command]) -> Array[Int] = @exec.run_sequence,
) -> Unit {
  self.mutex_registry.expire(now)
  let tracked_before = self.poller.tracked.length()
  let pending_events = []
  let pending_agent_ids = []
  let mut tick_event_total = 0
  let project_dir = self.config.project_dir
  let append_file = self.append_file
  self.poller.tick_with(
    now,
    timeout,
    @poller.gh_poll_pr,
    fn(event, agent_id) {
      pending_events.push(event)
      pending_agent_ids.push(agent_id)
    },
    fn(log) {
      tick_event_total = tick_event_total + log.events.length()
      log_poller_pr_tick(append_file, project_dir, log)
    },
  )
  if pending_events.length() > 0 {
    self.request_goal_judge_tick()
  }
  let tracked_after = self.poller.tracked.length()
  // Only log a tick that actually did something — no two-line start/end
  // heartbeat per tick (the steady state with nothing tracked produced two
  // INFO lines every interval that said nothing). Empty ticks are silent;
  // a tick that generated events or changed the tracked-PR set logs one line.
  if tick_event_total > 0 || tracked_after != tracked_before {
    @moontrace.info("poller tick", fields=[
      @moontrace.field("events_generated", tick_event_total),
      @moontrace.field("tracked_before", tracked_before),
      @moontrace.field("tracked_after", tracked_after),
    ])
    append_poller_delivery_line(
      append_file,
      project_dir,
      "tick events_generated=" +
      tick_event_total.to_string() +
      " tracked_before=" +
      tracked_before.to_string() +
      " tracked_after=" +
      tracked_after.to_string(),
    )
  }
  deliver_orphaned_pr_notifications(self, runner)
  deliver_pending_poll_events(self, pending_events, pending_agent_ids, runner)
  deliver_poller_stall_notifications(self, now, runner)
  self.sweep_outbox(now)
  ignore(self.poller.write_state_file(self.config.project_dir))
}

///|
pub async fn ServerState::refresh_pr_with(
  self : ServerState,
  pr_number : Int,
  now : Int64,
  timeout : Int64,
  poll : async (Int, Bool) -> (
    Bool,
    @poller.ReviewState,
    String,
    @poller.CiRollupStatus,
    String,
    Bool,
    Bool,
  ),
  runner? : async (Array[@workspace.Command]) -> Array[Int] = @exec.run_sequence,
  capture? : async (@workspace.Command) -> (Int, String) = @exec.capture_command_stdout,
  automerge_capture? : async (@workspace.Command) -> (Int, String) = @exec.capture_command_merged,
) -> Unit {
  let pending_events : Array[@poller.PollEvent] = []
  let pending_agent_ids : Array[String] = []
  self.poller.tick_pr_with(
    pr_number,
    now,
    timeout,
    poll,
    fn(event, agent_id) {
      pending_events.push(event)
      pending_agent_ids.push(agent_id)
    },
    fn(_) { () },
    force_refresh=true,
  )
  match self.poller.get(pr_number) {
    Some(pr) => {
      if pending_events.length() == 0 {
        pending_events.push(@poller.PollEvent::ReviewThreadsResolved(pr_number))
        pending_agent_ids.push(pr.agent_id)
      }
      deliver_orphaned_pr_notification_for(self, pr, runner)
      deliver_poller_stall_notification_for(self, pr, now, runner)
    }
    None => ()
  }
  if pending_events.length() > 0 {
    deliver_pending_poll_events(
      self,
      pending_events,
      pending_agent_ids,
      runner,
      capture~,
      automerge_capture~,
    )
    self.request_goal_judge_tick()
  }
  ignore(self.poller.write_state_file(self.config.project_dir))
}

///|
pub async fn ServerState::refresh_pr_with_runner(
  self : ServerState,
  pr_number : Int,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  capture? : async (@workspace.Command) -> (Int, String) = @exec.capture_command_stdout,
  automerge_capture? : async (@workspace.Command) -> (Int, String) = @exec.capture_command_merged,
) -> Unit {
  self.refresh_pr_with(
    pr_number,
    @poller.now_sec(),
    900L,
    @poller.gh_poll_pr,
    runner~,
    capture~,
    automerge_capture~,
  )
}
