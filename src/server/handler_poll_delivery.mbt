///|
pub const DEDUP_WINDOW_SEC : Int64 = 60L

///|
pub const HEARTBEAT_WINDOW_SEC : Int64 = 300L

///|
pub const SPAWN_REGISTRATION_TIMEOUT_SEC : Int64 = 180L

///|
pub(all) struct RecentEmission {
  content_hash : String
  emitted_at_unix : Int64
} derive(Debug, Eq)

///|
pub fn poller_event_should_dedup(
  prior : RecentEmission?,
  current_hash : String,
  now : Int64,
  dedup_window : Int64,
  heartbeat_window : Int64,
) -> Bool {
  match prior {
    Some(emission) => {
      let raw_elapsed = now - emission.emitted_at_unix
      let elapsed = if raw_elapsed < 0L { 0L } else { raw_elapsed }
      let suppress_window = if heartbeat_window > 0L {
        heartbeat_window
      } else {
        dedup_window
      }
      emission.content_hash == current_hash && elapsed < suppress_window
    }
    None => false
  }
}

///|
fn render_parent_next_action(
  decision : @poller.PrStateNotificationDecision,
  pr_number : Int,
  parent_branch : String?,
  merge_mode : @poller.MergeOperatorMode,
  reviewer : @types.Reviewer,
) -> String {
  @poller.next_action_line(decision.next_action) +
  "\n" +
  @poller.next_action_detail_line(
    decision.next_action,
    pr_number,
    parent_branch,
    merge_mode,
    reviewer~,
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
  moon_verify_target? : @types.MoonVerifyTarget = @types.Config::default().moon_verify_target,
  audit_receipt_state? : @types.AuditReceiptState = @types.AuditReceiptState::NotRequired,
  reviewer? : @types.Reviewer = @types.Reviewer::None,
  skip_copilot_on_feature_branch? : Bool = false,
  default_branch? : String = "",
) -> @poller.PrStateNotificationDecision {
  let task_contract = @types.task_contract_with_normalized_verify(
    task_contract, moon_verify_target,
  )
  let verify_results = match task_contract {
    Some(contract) =>
      @evidence.verify_results_for_required_at_head_with_ci(
        project_dir,
        tracked.agent_id,
        contract.verify,
        tracked.last_sha,
        @types.task_contract_verify_satisfied_by_ci(contract),
        ci_rollup=@poller.evaluation_ci_rollup_from_snapshot(
          tracked.last_ci_rollup,
        ),
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
    audit_receipt_state~,
    merge_mode~,
    reviewer~,
    skip_copilot_on_feature_branch~,
    default_branch~,
    owner_released=poll_owner_released_for_threads(
      project_dir,
      tracked.agent_id,
    ),
  )
}

///|
/// Cosmetic single-writer suppression input (choir-3rp5): the TL is only handed
/// `ResolveThreadsNow` once the owning leaf has released its contested threads —
/// i.e. it is finalized (waits for `Finalized`/`Failed`, NOT `Finalizing`, per
/// F17), or the PR is TL-direct (owner is a supervisor or has no lifecycle
/// record, F8). Reads the request-time lifecycle snapshot; the server boundary
/// gate remains the actual guarantee (F18).
fn poll_owner_released_for_threads(
  project_dir : String,
  owner_id : String,
) -> Bool {
  owner_released_for_threads_from_lifecycle(
    @phase.read_lifecycle(project_dir, owner_id),
  )
}

///|
/// Pure F17 release mapping (choir-3rp5), split from the lifecycle read so the
/// mapping can be unit-tested without disk I/O. Released ⇔ no lifecycle record
/// (TL-direct/unknown owner, F8), supervisor owner (TL-direct, F8), or the
/// owning leaf is finalized (`Finalized`/`Failed`). `Finalizing` is the handoff
/// instant — terminal for the boundary gate but NOT yet released here, so the
/// cosmetic `ResolveThreadsNow` waits for `Finalized` and never acts while the
/// leaf's last push is in flight.
fn owner_released_for_threads_from_lifecycle(
  lifecycle : @phase.AgentLifecycle?,
) -> Bool {
  match lifecycle {
    None => true
    Some(lc) =>
      if @types.is_supervisor_role(lc.role) {
        true
      } else {
        match lc.process {
          @phase.ProcessState::Finalized(..)
          | @phase.ProcessState::Failed(..) => true
          _ => false
        }
      }
  }
}

///|
test "owner_released_for_threads_from_lifecycle follows the F17 release mapping" {
  let leaf = "main.leaf"
  // Finalizing is the handoff instant — NOT yet released (waits for Finalized).
  let finalizing = {
    ..@phase.lifecycle_for_role(leaf, @types.Role::Dev),
    process: @phase.ProcessState::Finalizing(
      reason=@phase.FinalizeReason::RecoveredDone,
    ),
  }
  assert_false(owner_released_for_threads_from_lifecycle(Some(finalizing)))
  // Finalized: the leaf has released its threads.
  let finalized = {
    ..@phase.lifecycle_for_role(leaf, @types.Role::Dev),
    process: @phase.ProcessState::Finalized(
      reason=@phase.FinalizeReason::RecoveredDone,
    ),
  }
  assert_true(owner_released_for_threads_from_lifecycle(Some(finalized)))
  // Supervisor owner: TL-direct PR, always released (F8).
  let supervisor = {
    ..@phase.lifecycle_for_role("main.tl", @types.Role::TL),
    process: @phase.ProcessState::Connected,
  }
  assert_true(owner_released_for_threads_from_lifecycle(Some(supervisor)))
  // No lifecycle record: TL-direct / unknown owner, always released (F8).
  assert_true(owner_released_for_threads_from_lifecycle(None))
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
  moon_verify_target? : @types.MoonVerifyTarget = @types.Config::default().moon_verify_target,
  audit_receipt_state? : @types.AuditReceiptState = @types.AuditReceiptState::NotRequired,
  precomputed_decision? : @poller.PrStateNotificationDecision? = None,
  reviewer? : @types.Reviewer = @types.Reviewer::None,
  skip_copilot_on_feature_branch? : Bool = false,
  default_branch? : String = "",
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
  let notification_decision = match precomputed_decision {
    Some(decision) => decision
    None =>
      parent_pr_state_notification_decision(
        project_dir,
        tracked,
        event,
        unresolved_threads_for_recheck,
        task_contract~,
        merge_mode~,
        review_mode~,
        moon_verify_target~,
        audit_receipt_state~,
        reviewer~,
        skip_copilot_on_feature_branch~,
        default_branch~,
      )
  }
  let review_required = @policy.review_required_for_branch(
    reviewer,
    skip_copilot_on_feature_branch,
    tracked.parent_branch,
    default_branch,
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
          notification_decision, n, parent_branch, merge_mode, reviewer,
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
          notification_decision, n, parent_branch, merge_mode, reviewer,
        ) +
        parent_poll_tl_decision_suffix(notification_decision, merge_mode)
      Some((message, @types.Status::Info))
    }
    ReviewTimeout(n) => {
      let (summary, status) = if review_required {
        (" — no review after timeout", @types.Status::Failure)
      } else {
        (
          " — review skipped by policy; no review action required",
          @types.Status::Info,
        )
      }
      let message = "[REVIEW TIMEOUT] " +
        agent_id +
        " PR #" +
        n.to_string() +
        summary +
        "\n" +
        "branch: " +
        branch +
        "\n" +
        "parent_branch: " +
        parent_branch.unwrap_or("<unknown>") +
        pr_url +
        "\n" +
        render_parent_next_action(
          notification_decision, n, parent_branch, merge_mode, reviewer,
        ) +
        parent_poll_tl_decision_suffix(notification_decision, merge_mode)
      Some((message, status))
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
              notification_decision, n, parent_branch, merge_mode, reviewer,
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
              notification_decision, n, parent_branch, merge_mode, reviewer,
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
            notification_decision, n, parent_branch, merge_mode, reviewer,
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
        moon_verify_target~,
        audit_receipt_state~,
        reviewer~,
        skip_copilot_on_feature_branch~,
        default_branch~,
      )
      let prefix = parent_poll_ci_escalation_prefix(
        tracked,
        reviewer~,
        review_required~,
      )
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
            notification_decision, n, parent_branch, merge_mode, reviewer,
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
        moon_verify_target~,
        audit_receipt_state~,
        reviewer~,
        skip_copilot_on_feature_branch~,
        default_branch~,
      )
      let prefix = parent_poll_ci_escalation_prefix(
        tracked,
        reviewer~,
        review_required~,
      )
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
            notification_decision, n, parent_branch, merge_mode, reviewer,
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
        moon_verify_target~,
        audit_receipt_state~,
        reviewer~,
        skip_copilot_on_feature_branch~,
        default_branch~,
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
            notification_decision, n, parent_branch, merge_mode, reviewer,
          ) +
          "\n\n" +
          summary +
          parent_poll_tl_decision_suffix(notification_decision, merge_mode),
          @types.Status::Info,
        ),
      )
    }
    PRMerged(_) => None
    PRClosedUnmerged(_) => None
    MergeReady(n) => {
      let readiness_summary = match notification_decision.policy_decision {
        @policy.MergeDecision::MergeNow(reason~) =>
          if reason.contains("review skipped by policy") {
            " — review skipped by policy, CI green, merge gate open\n"
          } else {
            " — reviewed, CI green, merge gate open\n"
          }
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
          notification_decision, n, parent_branch, merge_mode, reviewer,
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
        moon_verify_target~,
        audit_receipt_state~,
        reviewer~,
        skip_copilot_on_feature_branch~,
        default_branch~,
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
          notification_decision, n, parent_branch, merge_mode, reviewer,
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
    PRClosedUnmerged(pr) => pr.pr_number
    MergeReady(n) => n
    ReviewThreadsResolved(n) => n
  }
}

///|
fn poll_events_pr_merged_numbers(
  events : Array[@poller.PollEvent],
) -> Array[Int] {
  let pr_numbers : Array[Int] = []
  for event in events {
    match event {
      PRMerged(pr) => pr_numbers.push(pr.pr_number)
      _ => ()
    }
  }
  pr_numbers
}

///|
fn poll_events_terminal_pr_numbers(
  events : Array[@poller.PollEvent],
) -> Array[Int] {
  let pr_numbers : Array[Int] = []
  for event in events {
    match event {
      PRMerged(pr) | PRClosedUnmerged(pr) => pr_numbers.push(pr.pr_number)
      _ => ()
    }
  }
  pr_numbers
}

///|
fn poll_event_tracked_snapshot(
  event : @poller.PollEvent,
  tracked : @poller.TrackedPR?,
) -> @poller.TrackedPR? {
  match event {
    PRMerged(pr) => Some(pr)
    PRClosedUnmerged(pr) => Some(pr)
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
fn poll_event_is_closed_unmerged(event : @poller.PollEvent) -> Bool {
  match event {
    PRClosedUnmerged(_) => true
    _ => false
  }
}

///|
pub let seen_merge_cache_capacity : Int = 50

///|
pub(all) struct RecentMergedPullRequest {
  pr_number : Int
  branch : String
  parent_branch : String
  pr_url : String
  head_sha : String
  merged_at_unix : Int64
} derive(Debug, Eq)

///|
pub struct ParentWorktreeGitState {
  current_branch : String
  working_tree_clean : Bool
} derive(Debug, Eq)

///|
pub fn parent_worktree_git_state(
  current_branch : String,
  working_tree_clean : Bool,
) -> ParentWorktreeGitState {
  { current_branch, working_tree_clean }
}

///|
pub fn should_auto_pull_parent(
  parent_branch : String,
  default_branch : String,
  current_branch : String,
  working_tree_clean : Bool,
  config_auto_pull_enabled : Bool,
) -> Bool {
  parent_branch == default_branch &&
  current_branch == default_branch &&
  working_tree_clean &&
  config_auto_pull_enabled
}

///|
fn audit_enforcement_log_message(
  default_branch : String,
  head_sha : String,
  outcome : @tools.AuditEnforcementOutcome,
) -> String {
  match outcome {
    @tools.AuditEnforcementOutcome::UnauditedBlocked =>
      if head_sha.trim().to_owned() == "" {
        "audit enforcement blocked: missing merge head sha"
      } else {
        unaudited_integration_merge_log_message(default_branch)
      }
    @tools.AuditEnforcementOutcome::UnauditedWarned =>
      if head_sha.trim().to_owned() == "" {
        "audit enforcement warned: missing merge head sha"
      } else {
        unaudited_integration_merge_log_message(default_branch)
      }
    @tools.AuditEnforcementOutcome::Audited
    | @tools.AuditEnforcementOutcome::NotApplicable => ""
  }
}

///|
test "audit_enforcement_log_message distinguishes missing-head warn from block" {
  assert_eq(
    audit_enforcement_log_message(
      "main",
      "",
      @tools.AuditEnforcementOutcome::UnauditedWarned,
    ),
    "audit enforcement warned: missing merge head sha",
  )
  assert_eq(
    audit_enforcement_log_message(
      "main",
      "",
      @tools.AuditEnforcementOutcome::UnauditedBlocked,
    ),
    "audit enforcement blocked: missing merge head sha",
  )
  assert_eq(
    audit_enforcement_log_message(
      "main",
      "abcdef123456",
      @tools.AuditEnforcementOutcome::UnauditedWarned,
    ),
    "[UNAUDITED MERGE INTO MAIN]",
  )
  assert_eq(
    audit_enforcement_log_message(
      "trunk",
      "abcdef123456",
      @tools.AuditEnforcementOutcome::UnauditedBlocked,
    ),
    "[UNAUDITED MERGE INTO DEFAULT BRANCH]",
  )
  assert_eq(
    audit_enforcement_log_message(
      "main",
      "abcdef123456",
      @tools.AuditEnforcementOutcome::Audited,
    ),
    "",
  )
  assert_eq(
    audit_enforcement_log_message(
      "main",
      "",
      @tools.AuditEnforcementOutcome::NotApplicable,
    ),
    "",
  )
}

///|
fn emit_audit_enforcement_log(
  outcome : @tools.AuditEnforcementOutcome,
  message : () -> String,
  fields : Array[@moontrace.Field],
) -> Unit {
  match outcome {
    @tools.AuditEnforcementOutcome::UnauditedBlocked =>
      @moontrace.error(message(), fields~)
    @tools.AuditEnforcementOutcome::UnauditedWarned =>
      @moontrace.warn(message(), fields~)
    @tools.AuditEnforcementOutcome::Audited
    | @tools.AuditEnforcementOutcome::NotApplicable => ()
  }
}

///|
fn log_unaudited_integration_merge(
  pr : @poller.TrackedPR,
  default_branch : String,
  receipt_path : String,
  outcome : @tools.AuditEnforcementOutcome,
) -> Unit {
  let fields = [
    @moontrace.field("pr", pr.pr_number),
    @moontrace.field("branch", pr.branch),
    @moontrace.field("parent_branch", pr.parent_branch),
    @moontrace.field("default_branch", default_branch),
    @moontrace.field("head_sha", pr.last_sha),
    @moontrace.field("receipt_path", receipt_path),
  ]
  emit_audit_enforcement_log(
    outcome,
    fn() { audit_enforcement_log_message(default_branch, pr.last_sha, outcome) },
    fields,
  )
}

///|
fn unaudited_integration_merge_log_message(default_branch : String) -> String {
  if default_branch == "main" {
    "[UNAUDITED MERGE INTO MAIN]"
  } else {
    "[UNAUDITED MERGE INTO DEFAULT BRANCH]"
  }
}

///|
fn untracked_missing_head_audit_log_message() -> String {
  "untracked merge observed with missing head sha; audit receipt not durably recorded"
}

///|
fn emit_untracked_merge_boundary_persist_failed(
  boundary_unix : Int64,
  project_dir : String,
) -> Unit {
  @moontrace.warn("untracked merge boundary advanced but failed to persist", fields=[
    @moontrace.field("event", "untracked_merge_boundary_persist_failed"),
    @moontrace.field("boundary_unix", boundary_unix.to_string()),
    @moontrace.field("project_dir", project_dir),
  ])
}

///|
pub fn should_emit_untracked_pr_merged(
  tracked : Bool,
  already_seen : Bool,
) -> Bool {
  !tracked && !already_seen
}

///|
fn ServerState::record_seen_merged_pr_number(
  self : ServerState,
  pr_number : Int,
) -> Unit {
  self.poller.mark_merged_observed(pr_number)
}

///|
fn recent_merged_pull_requests_command(
  project_dir : String,
  default_branch : String,
) -> @workspace.Command {
  {
    program: "gh",
    args: [
      "pr",
      "list",
      "--state",
      "merged",
      "--base",
      default_branch,
      "--limit",
      seen_merge_cache_capacity.to_string(),
      "--json",
      "number,url,headRefName,headRefOid,baseRefName,mergedAt",
    ],
    workdir: Some(project_dir),
  }
}

///|
fn parse_recent_merged_pull_requests(
  output : String,
  default_branch : String,
) -> Array[RecentMergedPullRequest] {
  let parsed = @json.parse(output) catch { _ => return [] }
  let result : Array[RecentMergedPullRequest] = []
  guard parsed is Array(items) else { return result }
  for item in items {
    guard item is Object(obj) else { continue }
    let pr_number = match @types.json_field_int(obj, "number") {
      Some(value) => value
      None => continue
    }
    if pr_number <= 0 {
      continue
    }
    let parent_branch = match @types.json_field_string(obj, "baseRefName") {
      Some(value) => if value == "" { default_branch } else { value }
      None => default_branch
    }
    let merged_at_unix = match @types.json_field_string(obj, "mergedAt") {
      Some(raw) => @types.parse_iso8601_to_unix_seconds(raw)
      None => 0L
    }
    result.push({
      pr_number,
      branch: @types.json_field_string(obj, "headRefName").unwrap_or(""),
      parent_branch,
      pr_url: @types.json_field_string(obj, "url").unwrap_or(""),
      head_sha: @types.json_field_string(obj, "headRefOid").unwrap_or(""),
      merged_at_unix,
    })
  }
  result
}

///|
fn synthetic_untracked_merged_pr(
  info : RecentMergedPullRequest,
  now : Int64,
  review_mode : @types.ReviewMode,
  agent_id : String,
) -> @poller.TrackedPR {
  {
    pr_number: info.pr_number,
    agent_id,
    branch: info.branch,
    parent_branch: info.parent_branch,
    pr_url: info.pr_url,
    first_seen: now,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::Approved,
    last_review_bodies: "",
    last_sha: info.head_sha,
    last_automerge_attempt_sha: "",
    notified_parent: true,
    last_ci_rollup: @poller.CiRollupStatus::Success,
    mergeable: @poller.Mergeable::Unknown,
    merge_state_status: @poller.MergeStateStatus::Unknown,
    merged_at_unix: if info.merged_at_unix == 0L {
      None
    } else {
      Some(info.merged_at_unix)
    },
    audit_receipt_state: @types.AuditReceiptState::NotRequired,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: false,
    orphan_notified: false,
    closed_unmerged_notified: false,
    orphan_reconciling: false,
    changes_requested_since: 0L,
    stall_notified: false,
    fixes_pushed_at: 0L,
    review_mode,
    unresolved_thread_ids: [],
    unresolved_thread_ids_fetched: false,
    auto_resolve_outdated_pending: false,
  }
}

///|
fn synthetic_untracked_merge_agent_id(state : ServerState) -> String {
  match state.config.agent_id {
    Some(agent_id) =>
      if @phase.is_root_tl_shaped_agent_id(agent_id) {
        agent_id
      } else {
        "user-0-0"
      }
    None => "user-0-0"
  }
}

///|
pub async fn detect_untracked_pr_merged_events(
  state : ServerState,
  now : Int64,
  capture : async (@workspace.Command) -> (Int, String),
  same_tick_pr_merged_numbers? : Array[Int] = [],
  persist_boundary? : (String, @poller.PollerState) -> Bool = fn(
    project_dir,
    poller,
  ) {
    poller.write_state_file(project_dir)
  },
  boundary_persist_failed? : (Int64, String) -> Unit = emit_untracked_merge_boundary_persist_failed,
) -> Array[@poller.PollEvent] {
  let default_branch = match
    @tools.detect_default_branch_for_wave_complete(
      state.config.project_dir,
      capture,
    ) {
    Some(branch) => branch
    None => return []
  }
  let cmd = recent_merged_pull_requests_command(
    state.config.project_dir,
    default_branch,
  )
  let (exit_code, output) = capture(cmd)
  if exit_code != 0 {
    return []
  }
  let events : Array[@poller.PollEvent] = []
  let boundary_at_start = state.poller.untracked_merge_boundary_unix
  let mut boundary_advanced = false
  for info in parse_recent_merged_pull_requests(output, default_branch) {
    if info.merged_at_unix <= boundary_at_start {
      continue
    }
    if state.poller.advance_untracked_merge_boundary_unix(info.merged_at_unix) {
      boundary_advanced = true
    }
    let tracked = state.poller.get(info.pr_number) is Some(_)
    let observed_this_process = state.poller.merged_observed(info.pr_number)
    let observed_this_tick = same_tick_pr_merged_numbers.contains(
      info.pr_number,
    )
    let already_seen = observed_this_process || observed_this_tick
    if !tracked && !observed_this_process && info.head_sha.trim() == "" {
      let outcome = if state.config.pr_policy.require_integration_audit {
        @tools.AuditEnforcementOutcome::UnauditedBlocked
      } else {
        @tools.AuditEnforcementOutcome::UnauditedWarned
      }
      let fields = [
        @moontrace.field("pr", info.pr_number),
        @moontrace.field("branch", info.branch),
        @moontrace.field("parent_branch", info.parent_branch),
        @moontrace.field("default_branch", default_branch),
        @moontrace.field("head_sha", ""),
        @moontrace.field("pr_url", info.pr_url),
      ]
      emit_audit_enforcement_log(
        outcome, untracked_missing_head_audit_log_message, fields,
      )
    }
    if should_emit_untracked_pr_merged(tracked, already_seen) {
      let pr = synthetic_untracked_merged_pr(
        info,
        now,
        state.config.review_mode,
        synthetic_untracked_merge_agent_id(state),
      )
      events.push(@poller.PollEvent::PRMerged(pr))
    }
  }
  if boundary_advanced {
    let persisted = persist_boundary(state.config.project_dir, state.poller)
    if !persisted {
      boundary_persist_failed(
        state.poller.untracked_merge_boundary_unix,
        state.config.project_dir,
      )
    }
  }
  events
}

///|
async fn capture_parent_worktree_git_state(
  project_dir : String,
  capture : async (@workspace.Command) -> (Int, String),
) -> ParentWorktreeGitState? {
  let branch_cmd : @workspace.Command = {
    program: "git",
    args: ["rev-parse", "--abbrev-ref", "HEAD"],
    workdir: Some(project_dir),
  }
  let (branch_exit, branch_output) = capture(branch_cmd)
  if branch_exit != 0 {
    return None
  }
  let status_cmd : @workspace.Command = {
    program: "git",
    args: ["status", "--porcelain"],
    workdir: Some(project_dir),
  }
  let (status_exit, status_output) = capture(status_cmd)
  if status_exit != 0 {
    return None
  }
  Some({
    current_branch: branch_output.trim().to_owned(),
    working_tree_clean: status_output.trim().to_owned() == "",
  })
}

///|
async fn run_parent_git_pull_ff_only(
  project_dir : String,
  capture : async (@workspace.Command) -> (Int, String),
) -> Bool {
  let (exit_code, _) = capture({
    program: "git",
    args: ["pull", "--ff-only"],
    workdir: Some(project_dir),
  })
  exit_code == 0
}

///|
async test "run_parent_git_pull_ff_only uses capture-based git pull" {
  let captured : Array[@workspace.Command] = []
  let ok = run_parent_git_pull_ff_only("/repo", async fn(
    cmd : @workspace.Command,
  ) -> (Int, String) {
    @async.sleep(0)
    captured.push(cmd)
    (1, "fatal: origin does not appear to be a git repository")
  })
  assert_false(ok)
  assert_eq(captured.length(), 1)
  assert_eq(captured[0].program, "git")
  @debug.assert_eq(captured[0].args, ["pull", "--ff-only"])
  @debug.assert_eq(captured[0].workdir, Some("/repo"))
}

///|
fn ServerState::auto_pull_after_integration_enabled(self : ServerState) -> Bool {
  let local_content = (self.read_file)(
    self.config.project_dir + "/.choir/config.local.toml",
  )
  match @config.parse_local_config(local_content) {
    Ok(local_cfg) =>
      local_cfg.auto_pull_after_integration.unwrap_or(
        self.config.auto_pull_after_integration,
      )
    Err(_) => self.config.auto_pull_after_integration
  }
}

///|
pub async fn maybe_auto_pull_parent_after_pr_merged(
  state : ServerState,
  pr : @poller.TrackedPR,
  capture : async (@workspace.Command) -> (Int, String),
  git_pull_capture : async (@workspace.Command) -> (Int, String),
  git_state_capture : async (
    String,
    async (@workspace.Command) -> (Int, String),
  ) -> ParentWorktreeGitState?,
  git_pull_runner : async (String, async (@workspace.Command) -> (Int, String)) -> Bool,
) -> Unit {
  let default_branch = match
    @tools.detect_default_branch_for_wave_complete(
      state.config.project_dir,
      capture,
    ) {
    Some(branch) => branch
    None => {
      if pr.parent_branch != "" {
        @moontrace.warn("auto-pull skipped: default branch unknown", fields=[
          @moontrace.field("pr", pr.pr_number),
          @moontrace.field("parent_branch", pr.parent_branch),
        ])
      }
      return
    }
  }
  if pr.parent_branch != default_branch {
    return
  }
  let enabled = state.auto_pull_after_integration_enabled()
  if !enabled {
    @moontrace.info("auto-pull skipped", fields=[
      @moontrace.field("pr", pr.pr_number),
      @moontrace.field("reason", "disabled"),
      @moontrace.field("default_branch", default_branch),
    ])
    return
  }
  let git_state = match git_state_capture(state.config.project_dir, capture) {
    Some(value) => value
    None => {
      @moontrace.warn("auto-pull skipped: parent git state unavailable", fields=[
        @moontrace.field("pr", pr.pr_number),
        @moontrace.field("default_branch", default_branch),
      ])
      return
    }
  }
  if !should_auto_pull_parent(
      pr.parent_branch,
      default_branch,
      git_state.current_branch,
      git_state.working_tree_clean,
      enabled,
    ) {
    let reason = if git_state.current_branch != default_branch {
      "wrong_branch"
    } else if !git_state.working_tree_clean {
      "dirty_tree"
    } else {
      "predicate_false"
    }
    @moontrace.warn("auto-pull skipped", fields=[
      @moontrace.field("pr", pr.pr_number),
      @moontrace.field("reason", reason),
      @moontrace.field("default_branch", default_branch),
      @moontrace.field("current_branch", git_state.current_branch),
    ])
    return
  }
  if git_pull_runner(state.config.project_dir, git_pull_capture) {
    @moontrace.info("auto-pull completed", fields=[
      @moontrace.field("pr", pr.pr_number),
      @moontrace.field("default_branch", default_branch),
      @moontrace.field("workdir", state.config.project_dir),
    ])
  } else {
    @moontrace.warn("auto-pull failed", fields=[
      @moontrace.field("pr", pr.pr_number),
      @moontrace.field("default_branch", default_branch),
      @moontrace.field("workdir", state.config.project_dir),
    ])
  }
}

///|
fn poller_event_name(event : @poller.PollEvent) -> String {
  match event {
    ReviewReceived(_, _) => "review_received"
    ReviewCommented(_, _) => "review_commented"
    PRReady(_) => "pr_ready"
    FixesPushed(_) => "fixes_pushed"
    ReviewTimeout(_) => "review_timeout"
    CIFailed(_) => "ci_failed"
    CIFailureCleared(_) => "ci_failure_cleared"
    CILatestHeadRollupSucceeded(_) => "ci_latest_head_rollup_succeeded"
    CopilotIssueCommentSeen(_) => "copilot_issue_comment_seen"
    PRMerged(_) => "pr_merged"
    PRClosedUnmerged(_) => "pr_closed_unmerged"
    MergeReady(_) => "merge_ready"
    ReviewThreadsResolved(_) => "review_threads_resolved"
  }
}

///|
fn poller_event_content_hash(
  event_name : String,
  agent_id : String,
  head_sha : String,
  review_state : @poller.ReviewState,
  ci_rollup : @poller.CiRollupStatus,
  unresolved_thread_count : Int?,
  merge_decision_kind : String,
) -> String {
  let unresolved = match unresolved_thread_count {
    Some(count) => count.to_string()
    None => "unknown"
  }
  let input = "event_name=" +
    event_name +
    "\nagent_id=" +
    agent_id +
    "\nhead_sha=" +
    head_sha +
    "\nreview_state=" +
    review_state.to_wire_string() +
    "\nci_rollup=" +
    ci_rollup.to_wire_string() +
    "\nunresolved_thread_count=" +
    unresolved +
    "\nmerge_decision_kind=" +
    merge_decision_kind
  @runtime.simple_hash(input).to_string()
}

///|
fn poller_parent_event_content_hash(
  tracked : @poller.TrackedPR,
  event : @poller.PollEvent,
  unresolved_threads_for_recheck : Int?,
  merge_decision_kind : String,
) -> (String, String) {
  let event_name = poller_event_name(event)
  (
    event_name,
    poller_event_content_hash(
      event_name,
      tracked.agent_id,
      tracked.last_sha,
      tracked.last_review_state,
      tracked.last_ci_rollup,
      unresolved_threads_for_recheck,
      merge_decision_kind,
    ),
  )
}

///|
fn ServerState::recent_poller_event_emissions_for_agent(
  self : ServerState,
  agent_id : String,
) -> Map[String, RecentEmission] {
  match self.recent_poller_event_emissions.get(agent_id) {
    Some(existing) => existing
    None => {
      let created : Map[String, RecentEmission] = {}
      self.recent_poller_event_emissions.set(agent_id, created)
      created
    }
  }
}

///|
fn ServerState::poller_parent_event_should_dedup_hash(
  self : ServerState,
  agent_id : String,
  event_name : String,
  content_hash : String,
  now : Int64,
) -> Bool {
  let emissions = self.recent_poller_event_emissions_for_agent(agent_id)
  if poller_event_should_dedup(
      emissions.get(event_name),
      content_hash,
      now,
      DEDUP_WINDOW_SEC,
      HEARTBEAT_WINDOW_SEC,
    ) {
    @moontrace.debug("dedup skip", fields=[
      @moontrace.field("agent", agent_id),
      @moontrace.field("event", event_name),
    ])
    true
  } else {
    false
  }
}

///|
fn ServerState::record_poller_parent_event_emission(
  self : ServerState,
  agent_id : String,
  event_name : String,
  content_hash : String,
  now : Int64,
) -> Unit {
  let emissions = self.recent_poller_event_emissions_for_agent(agent_id)
  emissions.set(event_name, { content_hash, emitted_at_unix: now })
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
  reviewer? : @types.Reviewer = @types.Reviewer::None,
  review_required? : Bool = true,
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
          if @poller.tl_tracked_pr_copilot_review_silent_escalation_active(
              pr,
              review_required~,
            ) {
            let reviewer_handle = reviewer.request_handle()
            "[REVIEW] PR #" +
            n.to_string() +
            ": CI cleared but still no review. Run request_review(pr_number: \"" +
            n.to_string() +
            "\", reviewer: \"" +
            reviewer_handle +
            "\")"
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
          if @poller.tl_tracked_pr_copilot_review_silent_escalation_active(
              pr,
              review_required~,
            ) {
            let reviewer_handle = reviewer.request_handle()
            "[REVIEW] PR #" +
            n.to_string() +
            ": CI green but still no review. Run request_review(pr_number: \"" +
            n.to_string() +
            "\", reviewer: \"" +
            reviewer_handle +
            "\")"
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
    PRClosedUnmerged(_) => None
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
  event_name : String
  content_hash : String
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
fn ServerState::record_poller_parent_row_emission(
  self : ServerState,
  row : PendingPollParentRow,
  now : Int64,
) -> Unit {
  self.record_poller_parent_event_emission(
    row.leaf_agent_id,
    row.event_name,
    row.content_hash,
    now,
  )
}

///|
fn ServerState::record_poller_parent_row_emissions(
  self : ServerState,
  rows : Array[PendingPollParentRow],
  now : Int64,
) -> Unit {
  for row in rows {
    self.record_poller_parent_row_emission(row, now)
  }
}

///|
pub fn ServerState::plan_poll_event_deliveries(
  self : ServerState,
  event : @poller.PollEvent,
  agent_id : String,
  unresolved_threads_for_recheck : Int?,
  skip_parent? : Bool = false,
  now? : Int64 = @poller.now_sec(),
  default_branch? : String = "",
  audit_receipt_state? : @types.AuditReceiptState = @types.AuditReceiptState::NotRequired,
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
      Some(pr) => {
        let merge_mode = @poller.merge_operator_mode_from_automerge(
          automerge_enabled_for_agent(self.config, local_cfg),
        )
        let notification_decision = parent_pr_state_notification_decision(
          self.config.project_dir,
          pr,
          event,
          unresolved_threads_for_recheck,
          merge_mode~,
          review_mode~,
          moon_verify_target=self.config.moon_verify_target,
          audit_receipt_state~,
          reviewer=self.config.pr_policy.reviewer,
          skip_copilot_on_feature_branch=self.config.pr_policy.skip_copilot_on_feature_branch,
          default_branch~,
        )
        match
          parent_poll_event_message(
            pr,
            self.config.project_dir,
            event,
            unresolved_threads_for_recheck,
            merge_mode~,
            review_mode~,
            moon_verify_target=self.config.moon_verify_target,
            audit_receipt_state~,
            precomputed_decision=Some(notification_decision),
            reviewer=self.config.pr_policy.reviewer,
            skip_copilot_on_feature_branch=self.config.pr_policy.skip_copilot_on_feature_branch,
            default_branch~,
          ) {
          Some((message, status)) => {
            let (event_name, content_hash) = poller_parent_event_content_hash(
              pr,
              event,
              unresolved_threads_for_recheck,
              notification_decision.policy_decision.label(),
            )
            if self.poller_parent_event_should_dedup_hash(
                pr.agent_id,
                event_name,
                content_hash,
                now,
              ) {
              ()
            } else {
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
            }
          }
          None => ()
        }
      }
      None => ()
    }
  }
  // Owning leaf — direct `[REVIEW] PR #n: …` injection (terminal_target in registry)
  let leaf_review_required = match tracked {
    Some(pr) =>
      @policy.review_required_for_branch(
        self.config.pr_policy.reviewer,
        self.config.pr_policy.skip_copilot_on_feature_branch,
        pr.parent_branch,
        default_branch,
      )
    None => true
  }
  match leaf_owner {
    Some(agent) =>
      match agent.state {
        @types.AgentState::Active | @types.AgentState::Completing =>
          match
            leaf_poll_review_injection_message(
              event,
              tracked,
              reviewer=self.config.pr_policy.reviewer,
              review_required=leaf_review_required,
            ) {
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
  sleep_fn? : async (Int) -> Unit = @async.sleep,
) -> Unit {
  let prs : Array[@poller.TrackedPR] = []
  state.poller.tracked.each(fn(_k, pr) { prs.push(pr) })
  for pr in prs {
    deliver_poller_stall_notification_for(state, pr, now, runner, sleep_fn~)
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
    PRClosedUnmerged(pr) =>
      Some(
        (
          "Choir poller: PR #" +
          pr.pr_number.to_string() +
          " closed without merge; leaf finalized",
          "pr",
          "closed_unmerged",
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
    " keeping prior snapshot if available",
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
      let refreshed = {
        ..tracked,
        unresolved_thread_ids: thread_refs,
        unresolved_thread_ids_fetched: true,
      }
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
  if !tracked.unresolved_thread_ids_fetched {
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
fn tracked_unresolved_thread_count_for_gate(
  tracked : @poller.TrackedPR,
) -> Int? {
  if tracked.unresolved_thread_ids_fetched {
    Some(tracked.unresolved_thread_ids.length())
  } else {
    None
  }
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
) -> Array[(@poller.PollEvent, String)] {
  let events : Array[(@poller.PollEvent, String)] = []
  for tracked in self.poller.tracked.values() {
    if skipped_prs.contains(tracked.pr_number) {
      continue
    }
    if tracked.review_mode != @types.ReviewMode::Iterative ||
      !tracked.auto_resolve_outdated_pending {
      continue
    }
    let prior_thread_snapshot_fetched = tracked.unresolved_thread_ids_fetched
    let prior_unresolved_count = tracked.unresolved_thread_ids.length()
    match
      self.refresh_unresolved_review_thread_refs_snapshot(tracked, capture) {
      Some(refreshed) => {
        let before_count = refreshed.unresolved_thread_ids.length()
        let updated = self.auto_resolve_outdated_review_threads_for_pending(
          refreshed, capture,
        )
        let after_count = updated.unresolved_thread_ids.length()
        if after_count < before_count ||
          (
            prior_thread_snapshot_fetched &&
            before_count < prior_unresolved_count
          ) ||
          (
            !prior_thread_snapshot_fetched &&
            !updated.auto_resolve_outdated_pending
          ) {
          events.push(
            (
              @poller.PollEvent::ReviewThreadsResolved(updated.pr_number),
              updated.agent_id,
            ),
          )
        }
      }
      None => ()
    }
  }
  events
}

///|
async fn ServerState::refresh_tracked_pr_audit_receipt_states(
  self : ServerState,
  capture : async (@workspace.Command) -> (Int, String),
  path_exists : (String) -> Bool,
  read_file : (String) -> String,
  skip_pr_numbers? : Array[Int] = [],
  only_pr_number? : Int? = None,
) -> Unit {
  let tracked_prs : Array[@poller.TrackedPR] = []
  for tracked in self.poller.tracked.values() {
    let matches_target = match only_pr_number {
      Some(pr_number) => tracked.pr_number == pr_number
      None => true
    }
    if !skip_pr_numbers.contains(tracked.pr_number) && matches_target {
      tracked_prs.push(tracked)
    }
  }
  if tracked_prs.length() == 0 {
    return
  }
  let default_branch = @tools.detect_default_branch_with_capture(
    self.config.project_dir,
    capture,
  )
  for tracked in tracked_prs {
    match self.poller.get(tracked.pr_number) {
      Some(current) => {
        let audit_receipt_state = @tools.audit_receipt_advisory_state_for_tracked_pr(
          self.config.project_dir,
          current.parent_branch,
          default_branch,
          current.last_sha,
          current.first_seen,
          capture,
          read_file,
          path_exists,
        )
        self.poller.restore({ ..current, audit_receipt_state, })
      }
      None => ()
    }
  }
}

///|
async fn deliver_pending_poll_events(
  state : ServerState,
  now : Int64,
  pending_events : Array[@poller.PollEvent],
  pending_agent_ids : Array[String],
  runner : async (Array[@workspace.Command]) -> Array[Int],
  hook_xdg_config_home : String?,
  hook_home : String,
  capture~ : async (@workspace.Command) -> (Int, String),
  git_capture~ : async (String, Array[String]) -> String,
  bd_capture~ : async (@workspace.Command) -> (Int, String),
  automerge_capture~ : async (@workspace.Command) -> (Int, String),
  git_pull_capture~ : async (@workspace.Command) -> (Int, String),
  hook_capture~ : async (String, String, String?) -> (Int, String),
  path_exists~ : (String) -> Bool,
  hook_path_exists~ : (String) -> Bool,
  audit_receipt_exists~ : (String) -> Bool,
  audit_receipt_read~ : (String) -> String,
  git_state_capture? : async (
    String,
    async (@workspace.Command) -> (Int, String),
  ) -> ParentWorktreeGitState? = capture_parent_worktree_git_state,
  git_pull_runner? : async (String, async (@workspace.Command) -> (Int, String)) -> Bool = run_parent_git_pull_ff_only,
  sleep_fn? : async (Int) -> Unit = @async.sleep,
) -> Unit {
  let pending_parent_rows : Array[PendingPollParentRow] = []
  let automerge_attempted_prs : Map[Int, Bool] = {}
  let auto_resolve_attempted_prs : Map[Int, Bool] = {}
  for event in pending_events {
    let review_mode = match state.poller.get(poll_event_pr_number(event)) {
      Some(pr) => pr.review_mode
      None => state.config.review_mode
    }
    if poll_event_starts_auto_resolve_outdated_threads(event, review_mode) {
      auto_resolve_attempted_prs.set(poll_event_pr_number(event), true)
    }
  }
  let retried_events = state.retry_auto_resolve_outdated_review_threads(
    capture, auto_resolve_attempted_prs,
  )
  for item in retried_events {
    let (event, agent_id) = item
    pending_events.push(event)
    pending_agent_ids.push(agent_id)
  }
  if retried_events.length() > 0 {
    state.request_goal_judge_tick()
  }
  let default_branch = if pending_events.length() > 0 {
    @tools.detect_default_branch_with_capture(state.config.project_dir, capture)
  } else {
    ""
  }
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
            None => (Some(pr), tracked_unresolved_thread_count_for_gate(pr))
          }
        } else {
          (Some(pr), None)
        }
      None => (None, None)
    }
    let audit_receipt_state_for_delivery = match tracked_for_delivery {
      Some(pr) =>
        if poll_event_is_external_merge(event) ||
          poll_event_is_closed_unmerged(event) {
          @types.AuditReceiptState::NotRequired
        } else {
          @tools.audit_receipt_advisory_state_for_tracked_pr(
            state.config.project_dir,
            pr.parent_branch,
            default_branch,
            pr.last_sha,
            pr.first_seen,
            capture,
            audit_receipt_read,
            audit_receipt_exists,
          )
        }
      None => @types.AuditReceiptState::NotRequired
    }
    match event {
      PRMerged(pr) => {
        let audit_outcome = @tools.detect_pr_merged_audit_enforcement(
          state.config.project_dir,
          state.config.pr_policy.require_integration_audit,
          pr,
          capture,
          audit_receipt_exists,
          audit_receipt_read,
        )
        let allow_auto_pull = @tools.audit_enforcement_allows_auto_pull(
          audit_outcome,
        )
        let pr_head_sha = pr.last_sha.trim().to_owned()
        let audit_receipt_path = if pr_head_sha == "" {
          ""
        } else {
          match
            @tools.audit_receipt_tree_sha_for_head(
              state.config.project_dir,
              pr_head_sha,
              capture,
            ) {
            Some(tree_sha) =>
              @tools.project_relative_path(
                state.config.project_dir,
                @tools.file_pr_audit_receipt_path_for_head(tree_sha),
              )
            None => ""
          }
        }
        log_unaudited_integration_merge(
          pr,
          pr.parent_branch,
          audit_receipt_path,
          audit_outcome,
        )
        if allow_auto_pull {
          @tools.fire_pr_merged_completion_hooks(
            state.config.project_dir,
            pr,
            capture~,
            hook_capture~,
            path_exists=hook_path_exists,
            xdg_config_home=hook_xdg_config_home,
            home=hook_home,
          )
        }
        match tracked_for_delivery {
          Some(_) =>
            state.reconcile_external_merge_with_runner(
              pr.agent_id,
              pr.pr_number,
              pr.branch,
              pr.parent_branch,
              pr.pr_url,
              runner,
              sleep_fn~,
            )
          None => ()
        }
        state.record_seen_merged_pr_number(pr.pr_number)
        if allow_auto_pull {
          maybe_auto_pull_parent_after_pr_merged(
            state, pr, capture, git_pull_capture, git_state_capture, git_pull_runner,
          )
        }
      }
      PRClosedUnmerged(pr) =>
        // Closed without merge: finalize the OWNING leaf to Done(PrClosedUnmerged)
        // and notify the TL — gated per-PR inside the planner (a superseded PR
        // closing while the leaf works its replacement must NOT reap it). NEVER
        // a merge at any layer (choir-56ax AR-2).
        match tracked_for_delivery {
          Some(_) =>
            state.reconcile_closed_unmerged_with_runner(
              pr.agent_id,
              pr.pr_number,
              pr.branch,
              runner,
              sleep_fn~,
            )
          None => ()
        }
      _ =>
        for
          planned in state.plan_poll_event_deliveries(
            event,
            agent_id,
            unresolved_threads,
            skip_parent=true,
            now~,
            default_branch~,
            audit_receipt_state=audit_receipt_state_for_delivery,
          ) {
          ignore(state.durable_dispatch_planned(planned, runner, sleep_fn~))
        }
    }
    match tracked_for_delivery {
      Some(pr) => {
        append_poll_snapshot_evidence(state, pr, event, unresolved_threads)
        mirror_poll_event_to_beads(state, pr, event, runner)
        if poll_event_is_external_merge(event) ||
          poll_event_is_closed_unmerged(event) {
          // Both terminal PR-close paths already finalized the leaf and notified
          // the parent; skip automerge/parent-poll-notify (the close never merges).
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
              git_capture~,
              bd_capture~,
              review_mode=Some(review_mode),
              hook_capture~,
              path_exists~,
              read_file=audit_receipt_read,
              hook_path_exists~,
              hook_xdg_config_home~,
              hook_home~,
              sleep_fn~,
            ) {
            continue
          }
        }
        let task_contract = task_contract_for_agent(state, pr.agent_id)
        let merge_mode = @poller.merge_operator_mode_from_automerge(
          automerge_enabled,
        )
        let notification_decision = parent_pr_state_notification_decision(
          state.config.project_dir,
          pr,
          event,
          unresolved_threads,
          task_contract~,
          merge_mode~,
          review_mode~,
          moon_verify_target=state.config.moon_verify_target,
          audit_receipt_state=audit_receipt_state_for_delivery,
          reviewer=state.config.pr_policy.reviewer,
          skip_copilot_on_feature_branch=state.config.pr_policy.skip_copilot_on_feature_branch,
          default_branch~,
        )
        match
          parent_poll_event_message(
            pr,
            state.config.project_dir,
            event,
            unresolved_threads,
            task_contract~,
            merge_mode~,
            review_mode~,
            moon_verify_target=state.config.moon_verify_target,
            audit_receipt_state=audit_receipt_state_for_delivery,
            precomputed_decision=Some(notification_decision),
            reviewer=state.config.pr_policy.reviewer,
            skip_copilot_on_feature_branch=state.config.pr_policy.skip_copilot_on_feature_branch,
            default_branch~,
          ) {
          Some((message, status)) => {
            let category = notification_decision.category
            let (event_name, content_hash) = poller_parent_event_content_hash(
              pr,
              event,
              unresolved_threads,
              notification_decision.policy_decision.label(),
            )
            if state.poller_parent_event_should_dedup_hash(
                pr.agent_id,
                event_name,
                content_hash,
                now,
              ) {
              ()
            } else {
              pending_parent_rows.push({
                tracked: pr,
                leaf_agent_id: pr.agent_id,
                event_name,
                content_hash,
                message,
                status,
                category,
                merge_mode,
              })
            }
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
        reviewer=state.config.pr_policy.reviewer,
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
        match
          state.durable_deliver_to_agent(
            parent,
            sender,
            body,
            status,
            runner,
            sleep_fn~,
          ) {
          Ok(_) => state.record_poller_parent_row_emissions(matched, now)
          Err(_) => ()
        }
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
        match
          state.durable_deliver_to_agent(
            parent,
            row.leaf_agent_id,
            row.message,
            row.status,
            runner,
            sleep_fn~,
          ) {
          Ok(_) => state.record_poller_parent_row_emission(row, now)
          Err(_) => ()
        }
      } catch {
        _ => ()
      }
    }
  }
  state.sweep_tracked_prs_for_automerge(
    runner,
    capture=automerge_capture,
    git_capture~,
    bd_capture~,
    hook_capture~,
    path_exists~,
    read_file=state.read_file,
    hook_path_exists~,
    hook_xdg_config_home~,
    hook_home~,
    sleep_fn~,
  )
}

///|
async fn ServerState::sweep_tracked_prs_for_automerge(
  self : ServerState,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  capture~ : async (@workspace.Command) -> (Int, String),
  git_capture~ : async (String, Array[String]) -> String,
  bd_capture~ : async (@workspace.Command) -> (Int, String),
  hook_capture~ : async (String, String, String?) -> (Int, String),
  path_exists~ : (String) -> Bool,
  read_file? : (String) -> String = self.read_file,
  hook_path_exists~ : (String) -> Bool,
  hook_xdg_config_home~ : String?,
  hook_home~ : String,
  sleep_fn? : async (Int) -> Unit = @async.sleep,
) -> Unit {
  let tracked_prs : Array[@poller.TrackedPR] = []
  for tracked in self.poller.tracked.values() {
    tracked_prs.push(tracked)
  }
  let default_branch = if tracked_prs.length() > 0 {
    @tools.detect_default_branch_with_capture(self.config.project_dir, capture)
  } else {
    ""
  }
  for tracked in tracked_prs {
    let current = match self.poller.get(tracked.pr_number) {
      Some(pr) => pr
      None => continue
    }
    let local_cfg = local_config_for_agent(
      self.config.project_dir,
      self.registry,
      current.agent_id,
    )
    let automerge_enabled = automerge_enabled_for_agent(self.config, local_cfg)
    let unresolved_threads = tracked_unresolved_thread_count_for_gate(current)
    let review_required = @policy.review_required_for_branch(
      self.config.pr_policy.reviewer,
      self.config.pr_policy.skip_copilot_on_feature_branch,
      current.parent_branch,
      default_branch,
    )
    let audit_receipt_state = @tools.audit_receipt_advisory_state_for_tracked_pr(
      self.config.project_dir,
      current.parent_branch,
      default_branch,
      current.last_sha,
      current.first_seen,
      capture,
      read_file,
      path_exists,
    )
    let gate_ready = @poller.tl_tracked_pr_merge_gate_snapshot_ready(
      current,
      unresolved_threads,
      review_mode=current.review_mode,
      review_required~,
      audit_receipt_state~,
    )
    if !pr_needs_automerge_sweep_attempt(current, gate_ready, automerge_enabled) {
      continue
    }
    append_poller_delivery_line(
      self.append_file,
      self.config.project_dir,
      "automerge sweep attempt pr=" +
      current.pr_number.to_string() +
      " sha=" +
      current.last_sha,
    )
    ignore(
      maybe_trigger_automerge_for_pending_event(
        self,
        @poller.PollEvent::MergeReady(current.pr_number),
        current,
        unresolved_threads,
        runner,
        capture~,
        git_capture~,
        bd_capture~,
        review_mode=Some(current.review_mode),
        hook_capture~,
        path_exists~,
        read_file~,
        hook_path_exists~,
        hook_xdg_config_home~,
        hook_home~,
        sleep_fn~,
      ),
    )
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
  sleep_fn? : async (Int) -> Unit = @async.sleep,
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
          sleep_fn~,
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
  sleep_fn? : async (Int) -> Unit = @async.sleep,
) -> Unit {
  let prs : Array[@poller.TrackedPR] = []
  state.poller.tracked.each(fn(_k, pr) { prs.push(pr) })
  for pr in prs {
    deliver_orphaned_pr_notification_for(state, pr, runner, sleep_fn~)
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
fn ServerState::agent_state_counts_summary(self : ServerState) -> String {
  let mut spawning = 0
  let mut active = 0
  let mut completing = 0
  let mut done = 0
  let mut failed = 0
  let mut suspended = 0
  for agent in self.registry.list() {
    match agent.state {
      @types.AgentState::Spawning => spawning = spawning + 1
      @types.AgentState::Active => active = active + 1
      @types.AgentState::Completing => completing = completing + 1
      @types.AgentState::Done => done = done + 1
      @types.AgentState::Failed => failed = failed + 1
      @types.AgentState::Suspended => suspended = suspended + 1
    }
  }
  "spawning=" +
  spawning.to_string() +
  " active=" +
  active.to_string() +
  " completing=" +
  completing.to_string() +
  " done=" +
  done.to_string() +
  " failed=" +
  failed.to_string() +
  " suspended=" +
  suspended.to_string()
}

///|
fn ServerState::last_poller_delivery_age_sec(
  self : ServerState,
  now : Int64,
) -> Int64? {
  let mut latest = 0L
  for emissions in self.recent_poller_event_emissions.values() {
    for emission in emissions.values() {
      if emission.emitted_at_unix > latest {
        latest = emission.emitted_at_unix
      }
    }
  }
  if latest <= 0L {
    None
  } else {
    let age = now - latest
    Some(if age < 0L { 0L } else { age })
  }
}

///|
pub fn spawn_registration_never_registered(
  state : @types.AgentState,
  last_updated_unix_sec : Int64,
) -> Bool {
  state == @types.AgentState::Spawning && last_updated_unix_sec == 0L
}

///|
pub fn spawn_registration_reap_due(
  state : @types.AgentState,
  never_registered : Bool,
  first_unseen : Int64,
  now : Int64,
  deadline_sec : Int64,
) -> Bool {
  if deadline_sec <= 0L {
    return false
  }
  state == @types.AgentState::Spawning &&
  never_registered &&
  nonnegative_elapsed(now, first_unseen) >= deadline_sec
}

///|
fn spawn_registration_timeout_parent_message(
  agent_id : String,
  first_unseen : Int64,
  now : Int64,
  deadline_sec : Int64,
  diagnostic : @tools.SpawnLaunchDiagnostic?,
) -> String {
  let cause = spawn_registration_timeout_cause_detail(deadline_sec, diagnostic)
  "[SPAWN REGISTRATION TIMEOUT] " +
  agent_id +
  " never registered within " +
  deadline_sec.to_string() +
  "s of first poller observation (first_observed=" +
  first_unseen.to_string() +
  ", now=" +
  now.to_string() +
  "). " +
  cause +
  ". Reaped as Failed(NeverRegistered)."
}

///|
fn spawn_registration_timeout_cause_detail(
  deadline_sec : Int64,
  diagnostic : @tools.SpawnLaunchDiagnostic?,
) -> String {
  match diagnostic {
    Some(
      @tools.SpawnLaunchDiagnostic::SpawnCommandFailed(
        command_index~,
        status~,
        command_summary~,
        stderr_tail~,
        ..
      )
    ) => {
      let tail = @tools.spawn_launch_sanitized_stderr_tail(stderr_tail)
        .replace(old="\n", new=" ")
        .replace(old="\r", new=" ")
      "spawn_class=spawn-command-failed command_index=" +
      command_index.to_string() +
      " command=" +
      command_summary +
      " exit=" +
      status.to_string() +
      " stderr_tail=" +
      tail
    }
    Some(
      @tools.SpawnLaunchDiagnostic::SpawnCommandsSucceeded(launch_count~, ..)
    ) =>
      "spawn_class=launched-but-never-registered launch_count=" +
      launch_count.to_string() +
      " detail=spawn commands succeeded but agent never registered within " +
      deadline_sec.to_string() +
      "s"
    None =>
      "spawn_class=launched-but-never-registered detail=spawn launch diagnostic unavailable; spawn commands succeeded or no launch failure was captured; agent never registered within " +
      deadline_sec.to_string() +
      "s"
  }
}

///|
fn spawn_registration_add_diagnostic_fields(
  fields : Array[@moontrace.Field],
  diagnostic : @tools.SpawnLaunchDiagnostic?,
) -> Unit {
  match diagnostic {
    Some(
      @tools.SpawnLaunchDiagnostic::SpawnCommandFailed(
        command_index~,
        status~,
        command_summary~,
        stderr_tail~,
        ..
      )
    ) => {
      fields.push(@moontrace.field("spawn_class", "spawn-command-failed"))
      fields.push(@moontrace.field("spawn_command_index", command_index))
      fields.push(@moontrace.field("spawn_exit_code", status))
      fields.push(@moontrace.field("spawn_command", command_summary))
      fields.push(
        @moontrace.field(
          "spawn_stderr_tail",
          @tools.spawn_launch_sanitized_stderr_tail(stderr_tail),
        ),
      )
    }
    Some(
      @tools.SpawnLaunchDiagnostic::SpawnCommandsSucceeded(launch_count~, ..)
    ) => {
      fields.push(
        @moontrace.field("spawn_class", "launched-but-never-registered"),
      )
      fields.push(@moontrace.field("spawn_launch_count", launch_count))
    }
    None =>
      fields.push(
        @moontrace.field("spawn_class", "launched-but-never-registered"),
      )
  }
}

///|
fn spawn_registration_reapable_role(role : @types.Role) -> Bool {
  role == @types.Role::Dev || role == @types.Role::Worker
}

///|
async fn ServerState::reap_never_registered_spawn(
  self : ServerState,
  agent : @types.Agent,
  first_unseen : Int64,
  now : Int64,
  deadline_sec : Int64,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  kill_pgid : (Int) -> Unit,
) -> Unit {
  let agent_id = agent.agent_id.to_string()
  let diagnostic = self.spawn_launch_diagnostics.get(agent_id)
  let fields = [
    @moontrace.field("agent_id", agent_id),
    @moontrace.field("role", agent.role.to_wire_string()),
    @moontrace.field("first_unseen", first_unseen),
    @moontrace.field("now", now),
    @moontrace.field("deadline_sec", deadline_sec),
  ]
  spawn_registration_add_diagnostic_fields(fields, diagnostic)
  @moontrace.warn("spawn registration timeout reaping agent", fields~)
  self.kill_tracked_agent_pgroup(agent_id, kill_pgid)
  self.fail_agent_with_runner(
    agent_id,
    @phase.FailureReason::NeverRegistered,
    spawn_registration_timeout_parent_message(
      agent_id, first_unseen, now, deadline_sec, diagnostic,
    ),
    @types.ExitReason::Shutdown,
    runner,
    close_target=true,
  )
}

///|
async fn ServerState::sweep_spawn_registration_timeouts(
  self : ServerState,
  now : Int64,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  deadline_sec? : Int64 = SPAWN_REGISTRATION_TIMEOUT_SEC,
  kill_pgid? : (Int) -> Unit = default_kill_pgid_best_effort,
) -> Unit {
  let agents = self.registry.list()
  let live_ids : Array[String] = []
  for agent in agents {
    let agent_id = agent.agent_id.to_string()
    live_ids.push(agent_id)
    if !spawn_registration_reapable_role(agent.role) {
      self.spawn_registration_first_unseen.remove(agent_id)
      continue
    }
    let lifecycle = self.current_lifecycle(agent_id)
    let never_registered = spawn_registration_never_registered(
      agent.state,
      lifecycle.last_updated_unix_sec,
    )
    if !never_registered {
      self.spawn_registration_first_unseen.remove(agent_id)
      continue
    }
    match self.spawn_registration_first_unseen.get(agent_id) {
      Some(first_unseen) =>
        if spawn_registration_reap_due(
            agent.state,
            never_registered,
            first_unseen,
            now,
            deadline_sec,
          ) {
          self.spawn_registration_first_unseen.remove(agent_id)
          self.reap_never_registered_spawn(
            agent, first_unseen, now, deadline_sec, runner, kill_pgid,
          )
        }
      None => self.spawn_registration_first_unseen.set(agent_id, now)
    }
  }
  let tracked_ids : Array[String] = []
  for agent_id, _first_unseen in self.spawn_registration_first_unseen {
    tracked_ids.push(agent_id)
  }
  for agent_id in tracked_ids {
    if !live_ids.contains(agent_id) {
      self.spawn_registration_first_unseen.remove(agent_id)
    }
  }
}

///|
fn optional_age_sec_to_string(value : Int64?) -> String {
  match value {
    Some(v) => v.to_string()
    None => "unknown"
  }
}

///|
fn emit_tick_summary_line(
  state : ServerState,
  summary : @poller.TickSummary,
  ended_at_ms : Int64,
  now_sec : Int64,
) -> Unit {
  let elapsed_ms = summary.elapsed_ms(ended_at_ms)
  match @poller.build_tick_summary_line(summary, elapsed_ms) {
    Some(line) => {
      let agent_counts = state.agent_state_counts_summary()
      let tracked_prs = state.poller.tracked.length()
      let last_delivered_event_age_sec = state.last_poller_delivery_age_sec(
        now_sec,
      )
      @moontrace.info("poller tick", fields=[
        @moontrace.field("polled", summary.polled),
        @moontrace.field("changes", summary.changes),
        @moontrace.field("errors", summary.errors),
        @moontrace.field("elapsed_ms", elapsed_ms),
        @moontrace.field("agent_counts", agent_counts),
        @moontrace.field("tracked_prs", tracked_prs),
        @moontrace.field(
          "last_delivered_event_age_sec",
          optional_age_sec_to_string(last_delivered_event_age_sec),
        ),
      ])
      append_poller_delivery_line(
        state.append_file,
        state.config.project_dir,
        line +
        " agents=" +
        agent_counts +
        " tracked_prs=" +
        tracked_prs.to_string() +
        " last_delivered_event_age_sec=" +
        optional_age_sec_to_string(last_delivered_event_age_sec),
      )
    }
    None => ()
  }
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
fn config_optional_value(value : String?) -> String {
  match value {
    Some(v) => v
    None => "<unset>"
  }
}

///|
fn config_sensitive_optional_value(value : String?) -> String {
  match value {
    Some(_) => "[redacted]"
    None => "<unset>"
  }
}

///|
fn config_length_prefixed(parts : Array[String]) -> String {
  let encoded : Array[String] = []
  for part in parts {
    encoded.push(part.length().to_string() + ":" + part)
  }
  encoded.join("")
}

///|
fn config_string_array_value(values : Array[String]) -> String {
  "[" + config_length_prefixed(values) + "]"
}

///|
fn config_project_value(project : @types.Project) -> String {
  "verify_cmd=" + config_optional_value(project.verify_cmd)
}

///|
fn config_pr_policy_value(policy : @types.PrPolicy) -> String {
  "require_integration_audit=" +
  policy.require_integration_audit.to_string() +
  ",skip_copilot_on_feature_branch=" +
  policy.skip_copilot_on_feature_branch.to_string() +
  ",reviewer=" +
  policy.reviewer.to_wire_string()
}

///|
fn config_pricing_value(pricing : Map[String, @types.PricingRate]) -> String {
  let parts : Array[String] = []
  for key, rate in pricing {
    parts.push(
      key + ":" + rate.rate_in.to_string() + "/" + rate.rate_out.to_string(),
    )
  }
  parts.sort()
  parts.join(",")
}

///|
fn config_model_value(model : Map[String, @types.AgentModelConfig]) -> String {
  let parts : Array[String] = []
  for key, entry in model {
    let fields : Array[String] = []
    match entry.default {
      Some(value) => fields.push("default=" + value)
      None => ()
    }
    match entry.dev {
      Some(value) => fields.push("dev=" + value)
      None => ()
    }
    match entry.worker {
      Some(value) => fields.push("worker=" + value)
      None => ()
    }
    match entry.tl {
      Some(value) => fields.push("tl=" + value)
      None => ()
    }
    parts.push(key + ":{" + fields.join(",") + "}")
  }
  parts.sort()
  parts.join(",")
}

///|
fn config_worktree_provision_value(
  entries : Array[@types.ProvisionEntry],
) -> String {
  let parts : Array[String] = []
  for entry in entries {
    let strategy = match entry.strategy {
      @types.ProvisionStrategy::Symlink => "symlink"
      @types.ProvisionStrategy::Copy => "copy"
      @types.ProvisionStrategy::Command => "command"
    }
    let command = match entry.command {
      Some(value) => ":command=" + value
      None => ""
    }
    parts.push(entry.path + ":" + strategy + command)
  }
  parts.join(",")
}

///|
fn config_field_value(config : @types.Config, field : String) -> String {
  match field {
    "default_role" => config.default_role.to_wire_string()
    "project_dir" => config.project_dir
    "shell_command" => config_optional_value(config.shell_command)
    "listen_uds" => config.listen_uds
    "listen_tcp" => config_optional_value(config.listen_tcp)
    "tcp_auth_token" => config_sensitive_optional_value(config.tcp_auth_token)
    "otlp_endpoint" => config_optional_value(config.otlp_endpoint)
    "agent_id" => config_optional_value(config.agent_id)
    "extra_mcp_servers_json" =>
      config_optional_value(config.extra_mcp_servers_json)
    "companions_json" => config_optional_value(config.companions_json)
    "plugins_json" => config_optional_value(config.plugins_json)
    "terminal_session" => config.terminal_session
    "automerge" => config.automerge.to_string()
    "review_mode" => config.review_mode.to_wire_string()
    "merge_strategy" => config.merge_strategy.to_wire_string()
    "moon_verify_target" => config.moon_verify_target.to_wire_string()
    "agy_migration_incomplete" => config.agy_migration_incomplete.to_string()
    "hooks_enforcement" => config.hooks_enforcement.to_string()
    "worker_no_handoff_idle_sec" =>
      config.worker_no_handoff_idle_sec.to_string()
    "poller_heartbeat_tick_sec" => config.poller_heartbeat_tick_sec.to_string()
    "prenotify_checks" => config_string_array_value(config.prenotify_checks)
    "worktree_provision" =>
      config_worktree_provision_value(config.worktree_provision)
    "auto_pull_after_integration" =>
      config.auto_pull_after_integration.to_string()
    "project" => config_project_value(config.project)
    "pr_policy" => config_pr_policy_value(config.pr_policy)
    "auto_rebuild_after_pull" => config.auto_rebuild_after_pull.to_string()
    "auto_reload_after_rebuild" => config.auto_reload_after_rebuild.to_string()
    "pricing" => config_pricing_value(config.pricing)
    "model" => config_model_value(config.model)
    _ => "<unknown>"
  }
}

///|
fn config_divergence_details(
  loaded : @types.Config,
  on_disk : @types.Config,
  fields : Array[String],
) -> Array[String] {
  let details : Array[String] = []
  for field in fields {
    details.push(
      field +
      ": loaded=" +
      config_field_value(loaded, field) +
      " disk=" +
      config_field_value(on_disk, field),
    )
  }
  details
}

///|
fn config_divergence_signature(details : Array[String]) -> String {
  config_length_prefixed(details)
}

///|
fn config_disk_path(project_dir : String, basename : String) -> String {
  if project_dir == "" {
    ".choir/" + basename
  } else {
    project_dir + "/.choir/" + basename
  }
}

///|
fn ServerState::warn_on_disk_config_divergence(self : ServerState) -> Unit {
  let config_path = config_disk_path(self.config.project_dir, "config.toml")
  let local_path = config_disk_path(
    self.config.project_dir,
    "config.local.toml",
  )
  let config_content = (self.read_file)(config_path)
  if config_content.trim() == "" {
    return
  }
  let local_content = (self.read_file)(local_path)
  let on_disk = match
    @config.parse_config(config_content, local_content=Some(local_content)) {
    Ok(cfg) => cfg
    Err(_) => return
  }
  self.warn_on_parsed_config_divergence(on_disk, config_path, local_path)
}

///|
fn ServerState::warn_on_parsed_config_divergence(
  self : ServerState,
  on_disk : @types.Config,
  config_path : String,
  local_path : String,
) -> Unit {
  let fields = @config.config_divergence(self.config, on_disk)
  if fields.length() == 0 {
    self.last_config_divergence_signature = None
    return
  }
  let details = config_divergence_details(self.config, on_disk, fields)
  let signature = config_divergence_signature(details)
  match self.last_config_divergence_signature {
    Some(previous) if previous == signature => return
    _ => ()
  }
  self.last_config_divergence_signature = Some(signature)
  @moontrace.warn(
    "config changed on disk after boot (" +
    details.join("; ") +
    "); restart `choir serve` to apply.",
    fields=[
      @moontrace.field("event", "config_divergence_after_boot"),
      @moontrace.field("fields", fields.join(",")),
      @moontrace.field("signature", signature),
      @moontrace.field("config_path", config_path),
      @moontrace.field("local_config_path", local_path),
    ],
  )
}

///|
test "warn_on_parsed_config_divergence rate limits by signature and resets" {
  let project_dir = "/tmp/choir-config-divergence-rate-limit-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.create_dir_all(project_dir + "/.choir/state/kv"))
  let state = ServerState::new(
    {
      ..@types.Config::default(),
      project_dir,
      terminal_session: "test-session",
      merge_strategy: @types.MergeStrategy::Merge,
      automerge: false,
    },
    make_hermetic_recovery_provider(),
  )
  let config_path = project_dir + "/.choir/config.toml"
  let local_path = project_dir + "/.choir/config.local.toml"
  let squash = { ..state.config, merge_strategy: @types.MergeStrategy::Squash }
  let squash_automerge = { ..squash, automerge: true }
  let captured : Array[@moontrace.Event] = []
  @moontrace.set_subscriber(fn(event) { captured.push(event) })
  state.warn_on_parsed_config_divergence(squash, config_path, local_path)
  state.warn_on_parsed_config_divergence(squash, config_path, local_path)
  state.warn_on_parsed_config_divergence(
    squash_automerge, config_path, local_path,
  )
  state.warn_on_parsed_config_divergence(state.config, config_path, local_path)
  state.warn_on_parsed_config_divergence(squash, config_path, local_path)
  @moontrace.clear_subscriber()
  let mut warn_count = 0
  for event in captured {
    if event.level == @moontrace.Level::Warn &&
      event.message.has_prefix("config changed on disk after boot") {
      warn_count = warn_count + 1
    }
  }
  assert_eq(warn_count, 3)
  ignore(@sys.rm_rf(project_dir))
}

///|
fn poll_delivery_moontrace_string_field(
  fields : Array[@moontrace.Field],
  key : String,
) -> String? {
  for field in fields {
    if field.key == key {
      match field.value {
        Json::String(value) => return Some(value)
        _ => return None
      }
    }
  }
  None
}

///|
fn poll_delivery_config_divergence_warn_events(
  events : Array[@moontrace.Event],
) -> Array[@moontrace.Event] {
  let warnings : Array[@moontrace.Event] = []
  for event in events {
    if event.level == @moontrace.Level::Warn {
      match poll_delivery_moontrace_string_field(event.fields, "event") {
        Some("config_divergence_after_boot") => warnings.push(event)
        _ => ()
      }
    }
  }
  warnings
}

///|
fn poll_delivery_config_divergence_test_state(
  label : String,
  config? : @types.Config = @types.Config::default(),
) -> ServerState {
  let project_dir = "/tmp/choir-config-divergence-poll-delivery-" +
    label +
    "-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.create_dir_all(project_dir + "/.choir/state/kv"))
  ServerState::new(
    {
      ..config,
      project_dir,
      terminal_session: "test-session",
      merge_strategy: @types.MergeStrategy::Merge,
      prenotify_checks: ["x"],
    },
    make_hermetic_recovery_provider(),
  )
}

///|
test "warn_on_disk_config_divergence reads cwd-relative config when project_dir is empty" {
  let base_state = poll_delivery_config_divergence_test_state("empty-project")
  let project_dir = base_state.config.project_dir
  let read_paths : Array[String] = []
  let state = { ..base_state, config: { ..base_state.config, project_dir: "" } }.with_read_file(fn(
      path,
    ) {
      read_paths.push(path)
      if path == ".choir/config.toml" {
        "terminal_session = \"test-session\"\nmerge_strategy = \"squash\"\n"
      } else {
        ""
      }
    },
  )
  let captured : Array[@moontrace.Event] = []
  @moontrace.set_subscriber(fn(event) { captured.push(event) })
  state.warn_on_disk_config_divergence()
  @moontrace.clear_subscriber()
  assert_true(read_paths.contains(".choir/config.toml"))
  assert_true(read_paths.contains(".choir/config.local.toml"))
  assert_false(read_paths.contains("/.choir/config.toml"))
  assert_eq(poll_delivery_config_divergence_warn_events(captured).length(), 1)
  ignore(@sys.rm_rf(project_dir))
}

///|
test "warn_on_parsed_config_divergence signatures distinguish prenotify array boundaries" {
  let state = poll_delivery_config_divergence_test_state("signature")
  let project_dir = state.config.project_dir
  let config_path = project_dir + "/.choir/config.toml"
  let local_path = project_dir + "/.choir/config.local.toml"
  let disk_single = { ..state.config, prenotify_checks: ["a|b"] }
  let disk_split = { ..state.config, prenotify_checks: ["a", "b"] }
  let captured : Array[@moontrace.Event] = []
  @moontrace.set_subscriber(fn(event) { captured.push(event) })
  state.warn_on_parsed_config_divergence(disk_single, config_path, local_path)
  state.warn_on_parsed_config_divergence(disk_split, config_path, local_path)
  @moontrace.clear_subscriber()
  let warnings = poll_delivery_config_divergence_warn_events(captured)
  assert_eq(warnings.length(), 2)
  let first_signature = poll_delivery_moontrace_string_field(
    warnings[0].fields,
    "signature",
  )
  let second_signature = poll_delivery_moontrace_string_field(
    warnings[1].fields,
    "signature",
  )
  assert_true(first_signature != second_signature)
  ignore(@sys.rm_rf(project_dir))
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
    @poller.Mergeable,
    @poller.MergeStateStatus,
    Int64?,
  ),
  hook_xdg_config_home : String?,
  hook_home : String,
  runner~ : async (Array[@workspace.Command]) -> Array[Int],
  capture~ : async (@workspace.Command) -> (Int, String),
  git_capture~ : async (String, Array[String]) -> String,
  bd_capture~ : async (@workspace.Command) -> (Int, String),
  automerge_capture~ : async (@workspace.Command) -> (Int, String),
  git_pull_capture~ : async (@workspace.Command) -> (Int, String),
  hook_capture~ : async (String, String, String?) -> (Int, String),
  path_exists~ : (String) -> Bool,
  hook_path_exists~ : (String) -> Bool,
  audit_receipt_exists~ : (String) -> Bool,
  audit_receipt_read~ : (String) -> String,
  git_state_capture? : async (
    String,
    async (@workspace.Command) -> (Int, String),
  ) -> ParentWorktreeGitState? = capture_parent_worktree_git_state,
  git_pull_runner? : async (String, async (@workspace.Command) -> (Int, String)) -> Bool = run_parent_git_pull_ff_only,
  sleep_fn? : async (Int) -> Unit = @async.sleep,
  kill_pgid? : (Int) -> Unit = default_kill_pgid_best_effort,
  read_file? : (String) -> String = self.read_file,
) -> Unit {
  self.mutex_registry.expire(now)
  self.warn_on_disk_config_divergence()
  let pending_events = []
  let pending_agent_ids = []
  let tick_summary = @poller.TickSummary::new(@env.now().reinterpret_as_int64())
  self.poller.tick_with(
    now,
    timeout,
    poll,
    fn(event, agent_id) {
      pending_events.push(event)
      pending_agent_ids.push(agent_id)
    },
    fn(log) {
      if log.polled_network && !log.poll_succeeded {
        tick_summary.errors = tick_summary.errors + 1
      }
      if log.polled_network {
        tick_summary.polled = tick_summary.polled + 1
      }
    },
  )
  let same_tick_pr_merged_numbers = poll_events_pr_merged_numbers(
    pending_events,
  )
  for
    event in detect_untracked_pr_merged_events(
      self,
      now,
      capture,
      same_tick_pr_merged_numbers~,
    ) {
    pending_events.push(event)
    pending_agent_ids.push(synthetic_untracked_merge_agent_id(self))
  }
  tick_summary.changes = pending_events.length()
  if pending_events.length() > 0 {
    self.request_goal_judge_tick()
  }
  deliver_orphaned_pr_notifications(self, runner, sleep_fn~)
  deliver_pending_poll_events(
    self,
    now,
    pending_events,
    pending_agent_ids,
    runner,
    hook_xdg_config_home,
    hook_home,
    capture~,
    git_capture~,
    bd_capture~,
    automerge_capture~,
    git_pull_capture~,
    hook_capture~,
    path_exists~,
    hook_path_exists~,
    audit_receipt_exists~,
    audit_receipt_read~,
    git_state_capture~,
    git_pull_runner~,
    sleep_fn~,
  )
  self.refresh_tracked_pr_audit_receipt_states(
    capture,
    path_exists,
    read_file,
    skip_pr_numbers=poll_events_terminal_pr_numbers(pending_events),
  )
  self.refresh_beads_status_cache_if_due(now, bd_capture, path_exists)
  tick_summary.changes = pending_events.length()
  emit_tick_summary_line(
    self,
    tick_summary,
    @env.now().reinterpret_as_int64(),
    now,
  )
  deliver_poller_stall_notifications(self, now, runner, sleep_fn~)
  self.sweep_spawn_registration_timeouts(now, runner, kill_pgid~)
  self.sweep_outbox(now)
  ignore(self.poller.write_state_file(self.config.project_dir))
}

///|
let beads_status_cache_min_refresh_sec : Int64 = 30L

///|
fn beads_status_command(
  project_dir : String,
  args : Array[String],
) -> @workspace.Command {
  { program: "bd", args, workdir: Some(project_dir) }
}

///|
async fn capture_beads_status_json(
  label : String,
  cmd : @workspace.Command,
  bd_capture : async (@workspace.Command) -> (Int, String),
) -> Result[String, @types.ChoirError] {
  let (code, output) = bd_capture(cmd)
  if code != 0 {
    Err(
      @types.ChoirError::workspace_error(
        label + " failed with exit code " + code.to_string(),
      ),
    )
  } else {
    Ok(output)
  }
}

///|
async fn ServerState::refresh_beads_status_cache_if_due(
  self : ServerState,
  now : Int64,
  bd_capture : async (@workspace.Command) -> (Int, String),
  path_exists : (String) -> Bool,
) -> Unit {
  let project_dir = self.config.project_dir
  if self.last_beads_status_cache_attempt_unix_sec > 0L &&
    now - self.last_beads_status_cache_attempt_unix_sec <
    beads_status_cache_min_refresh_sec {
    return
  }
  match @poller.read_beads_status_cache(project_dir, read_file=self.read_file) {
    Some((_, taken_at)) =>
      if taken_at <= now && now - taken_at < beads_status_cache_min_refresh_sec {
        return
      }
    _ => ()
  }
  if !path_exists(project_dir + "/.beads") {
    return
  }
  self.last_beads_status_cache_attempt_unix_sec = now
  let ready_json = match
    capture_beads_status_json(
      "bd ready --json",
      beads_status_command(project_dir, ["ready", "--json"]),
      bd_capture,
    ) {
    Ok(output) => output
    Err(e) => {
      @moontrace.warn("beads status cache refresh command failed", fields=[
        @moontrace.field("event", "beads_status_cache_refresh_failed"),
        @moontrace.field("command", "bd ready --json"),
        @moontrace.field("error", e.message()),
      ])
      return
    }
  }
  let in_progress_json = match
    capture_beads_status_json(
      "bd list --json --status in_progress",
      beads_status_command(project_dir, [
        "list", "--json", "--status", "in_progress",
      ]),
      bd_capture,
    ) {
    Ok(output) => output
    Err(e) => {
      @moontrace.warn("beads status cache refresh command failed", fields=[
        @moontrace.field("event", "beads_status_cache_refresh_failed"),
        @moontrace.field("command", "bd list --json --status in_progress"),
        @moontrace.field("error", e.message()),
      ])
      return
    }
  }
  let blocked_json = match
    capture_beads_status_json(
      "bd list --json --status blocked",
      beads_status_command(project_dir, [
        "list", "--json", "--status", "blocked",
      ]),
      bd_capture,
    ) {
    Ok(output) => output
    Err(e) => {
      @moontrace.warn("beads status cache refresh command failed", fields=[
        @moontrace.field("event", "beads_status_cache_refresh_failed"),
        @moontrace.field("command", "bd list --json --status blocked"),
        @moontrace.field("error", e.message()),
      ])
      return
    }
  }
  let deferred_json = match
    capture_beads_status_json(
      "bd list --json --status deferred",
      beads_status_command(project_dir, [
        "list", "--json", "--status", "deferred",
      ]),
      bd_capture,
    ) {
    Ok(output) => output
    Err(e) => {
      @moontrace.warn("beads status cache refresh command failed", fields=[
        @moontrace.field("event", "beads_status_cache_refresh_failed"),
        @moontrace.field("command", "bd list --json --status deferred"),
        @moontrace.field("error", e.message()),
      ])
      return
    }
  }
  let counts = match
    @poller.parse_beads_status_counts_from_bd_json(
      ready_json, in_progress_json, blocked_json, deferred_json,
    ) {
    Ok(counts) => counts
    Err(e) => {
      @moontrace.warn("beads status cache refresh parse failed", fields=[
        @moontrace.field("event", "beads_status_cache_refresh_parse_failed"),
        @moontrace.field("error", e.message()),
      ])
      return
    }
  }
  if !@poller.write_beads_status_cache(
      project_dir,
      counts,
      now,
      write_file=self.write_file_atomic,
    ) {
    @moontrace.warn("beads status cache write failed", fields=[
      @moontrace.field("event", "beads_status_cache_write_failed"),
      @moontrace.field("path", @poller.beads_status_cache_path(project_dir)),
    ])
  }
}

///|
pub async fn ServerState::process_poller_tick(
  self : ServerState,
  now : Int64,
  timeout : Int64,
  runner~ : async (Array[@workspace.Command]) -> Array[Int],
  capture~ : async (@workspace.Command) -> (Int, String),
  automerge_capture~ : async (@workspace.Command) -> (Int, String),
  audit_receipt_exists~ : (String) -> Bool,
  audit_receipt_read~ : (String) -> String,
  sleep_fn? : async (Int) -> Unit = @async.sleep,
) -> Unit {
  self.mutex_registry.expire(now)
  self.warn_on_disk_config_divergence()
  let pending_events = []
  let pending_agent_ids = []
  let project_dir = self.config.project_dir
  let append_file = self.append_file
  let tick_summary = @poller.TickSummary::new(@env.now().reinterpret_as_int64())
  self.poller.tick_with(
    now,
    timeout,
    @poller.gh_poll_pr,
    fn(event, agent_id) {
      pending_events.push(event)
      pending_agent_ids.push(agent_id)
    },
    fn(log) {
      if log.polled_network && !log.poll_succeeded {
        tick_summary.errors = tick_summary.errors + 1
      }
      if log.polled_network {
        tick_summary.polled = tick_summary.polled + 1
      }
      log_poller_pr_tick(append_file, project_dir, log)
    },
  )
  let same_tick_pr_merged_numbers = poll_events_pr_merged_numbers(
    pending_events,
  )
  for
    event in detect_untracked_pr_merged_events(
      self,
      now,
      capture,
      same_tick_pr_merged_numbers~,
    ) {
    pending_events.push(event)
    pending_agent_ids.push(synthetic_untracked_merge_agent_id(self))
  }
  tick_summary.changes = pending_events.length()
  if pending_events.length() > 0 {
    self.request_goal_judge_tick()
  }
  deliver_orphaned_pr_notifications(self, runner, sleep_fn~)
  deliver_pending_poll_events(
    self,
    now,
    pending_events,
    pending_agent_ids,
    runner,
    @exec.hook_xdg_config_home(),
    @exec.hook_home(),
    capture~,
    git_capture=@exec.capture_stdout,
    bd_capture=@exec.capture_command_stdout_with_stderr_on_error,
    git_pull_capture=@exec.capture_command_merged,
    automerge_capture~,
    hook_capture=@exec.capture_hook_script_merged,
    path_exists=@exec.path_entry_exists,
    hook_path_exists=@exec.path_entry_exists,
    audit_receipt_exists~,
    audit_receipt_read~,
    sleep_fn~,
  )
  self.refresh_tracked_pr_audit_receipt_states(
    capture,
    @exec.path_entry_exists,
    self.read_file,
    skip_pr_numbers=poll_events_terminal_pr_numbers(pending_events),
  )
  self.refresh_beads_status_cache_if_due(
    now, @exec.capture_command_stdout_with_stderr_on_error, @exec.path_entry_exists,
  )
  tick_summary.changes = pending_events.length()
  emit_tick_summary_line(
    self,
    tick_summary,
    @env.now().reinterpret_as_int64(),
    now,
  )
  deliver_poller_stall_notifications(self, now, runner, sleep_fn~)
  self.sweep_spawn_registration_timeouts(now, runner)
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
    @poller.Mergeable,
    @poller.MergeStateStatus,
    Int64?,
  ),
  hook_capture : async (String, String, String?) -> (Int, String),
  hook_xdg_config_home : String?,
  hook_home : String,
  hook_path_exists~ : (String) -> Bool,
  runner~ : async (Array[@workspace.Command]) -> Array[Int],
  capture~ : async (@workspace.Command) -> (Int, String),
  git_capture~ : async (String, Array[String]) -> String,
  bd_capture~ : async (@workspace.Command) -> (Int, String),
  path_exists~ : (String) -> Bool,
  git_pull_capture~ : async (@workspace.Command) -> (Int, String),
  automerge_capture~ : async (@workspace.Command) -> (Int, String),
  audit_receipt_exists~ : (String) -> Bool,
  audit_receipt_read~ : (String) -> String,
  sleep_fn? : async (Int) -> Unit = @async.sleep,
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
      deliver_orphaned_pr_notification_for(self, pr, runner, sleep_fn~)
      deliver_poller_stall_notification_for(self, pr, now, runner, sleep_fn~)
    }
    None => ()
  }
  let had_pending_events = pending_events.length() > 0
  deliver_pending_poll_events(
    self,
    now,
    pending_events,
    pending_agent_ids,
    runner,
    hook_xdg_config_home,
    hook_home,
    capture~,
    git_capture~,
    bd_capture~,
    git_pull_capture~,
    automerge_capture~,
    hook_capture~,
    path_exists~,
    hook_path_exists~,
    audit_receipt_exists~,
    audit_receipt_read~,
    sleep_fn~,
  )
  self.refresh_tracked_pr_audit_receipt_states(
    capture,
    path_exists,
    self.read_file,
    skip_pr_numbers=poll_events_terminal_pr_numbers(pending_events),
    only_pr_number=Some(pr_number),
  )
  if had_pending_events {
    self.request_goal_judge_tick()
  }
  ignore(self.poller.write_state_file(self.config.project_dir))
}

///|
pub async fn ServerState::refresh_pr_with_runner(
  self : ServerState,
  pr_number : Int,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  capture~ : async (@workspace.Command) -> (Int, String),
  automerge_capture~ : async (@workspace.Command) -> (Int, String),
) -> Unit {
  self.refresh_pr_with(
    pr_number,
    @poller.now_sec(),
    900L,
    @poller.gh_poll_pr,
    @exec.capture_hook_script_merged,
    @exec.hook_xdg_config_home(),
    @exec.hook_home(),
    hook_path_exists=@exec.path_entry_exists,
    runner~,
    capture~,
    git_capture=@exec.capture_stdout,
    bd_capture=@exec.capture_command_stdout_with_stderr_on_error,
    path_exists=@exec.path_entry_exists,
    git_pull_capture=@exec.capture_command_merged,
    automerge_capture~,
    audit_receipt_exists=@exec.path_entry_exists,
    audit_receipt_read=@exec.read_file,
  )
}
