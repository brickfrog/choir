///|
/// Canonical TL-facing workflow category for a tracked PR, derived from the
/// poller snapshot (and optional unresolved thread count when fetched).
pub(all) enum TlTrackedPrWorkflowCategory {
  BlockedOnChanges
  /// Review-wait window elapsed; Choir snapshot still shows no review (comment-triggered Copilot is unreliable).
  AttentionRequiredCopilotSilentAfterTimeout
  AttentionRequiredCIFailed
  WaitingOnReviewOrCI
  /// No Copilot issue comment observed yet on the PR issue thread (REST).
  WaitingOnCopilotIssueComment
  /// Copilot issue comment seen; other snapshot gates may still block merge.
  CopilotIssueCommentSeenRecheckRemainingGates
  ReadyForTLRecheck
  MergeGateOpenPendingPolicyConfirmation
  ObservedMergedExternal
  OrphanedPRNeedsManualAction
  StalledOnChangesRequested
} derive(Debug, Eq)

///|
pub(all) struct WaveRollupEntry {
  pr_number : Int
  agent_id : String
  category : TlTrackedPrWorkflowCategory
} derive(Debug, Eq)

///|
pub(all) struct WaveRollup {
  parent_id : String
  wave : Int
  entries : Array[WaveRollupEntry]
} derive(Debug, Eq)

///|
fn distinct_pr_count_in_rollups(entries : Array[WaveRollupEntry]) -> Int {
  let mut n = 0
  for i = 0; i < entries.length(); i = i + 1 {
    let pr = entries[i].pr_number
    let mut seen_before = false
    for j = 0; j < i; j = j + 1 {
      if entries[j].pr_number == pr {
        seen_before = true
        break
      }
    }
    if !seen_before {
      n = n + 1
    }
  }
  n
}

///|
fn wave_group_key(parent_id : String, wave : Int) -> String {
  parent_id + "\u{001F}" + wave.to_string()
}

///|
fn collect_wave_entries(
  pr_categories : Array[WaveRollupEntry],
  agent_wave_map : Map[String, (String, Int)],
  key : String,
) -> Array[WaveRollupEntry] {
  let out : Array[WaveRollupEntry] = []
  for e in pr_categories {
    match agent_wave_map.get(e.agent_id) {
      Some((pid, w)) => if wave_group_key(pid, w) == key { out.push(e) }
      None => ()
    }
  }
  out
}

///|
fn sort_wave_rollups(rs : Array[WaveRollup]) -> Array[WaveRollup] {
  if rs.length() <= 1 {
    return rs
  }
  let mut remaining : Array[WaveRollup] = []
  for r in rs {
    remaining.push(r)
  }
  let sorted : Array[WaveRollup] = []
  while remaining.length() > 0 {
    let mut best_i = 0
    let mut i = 1
    while i < remaining.length() {
      let a = remaining[best_i]
      let b = remaining[i]
      let b_wins = a.parent_id > b.parent_id ||
        (a.parent_id == b.parent_id && a.wave > b.wave)
      if b_wins {
        best_i = i
      }
      i = i + 1
    }
    sorted.push(remaining[best_i])
    let next : Array[WaveRollup] = []
    for k = 0; k < remaining.length(); k = k + 1 {
      if k != best_i {
        next.push(remaining[k])
      }
    }
    remaining = next
  }
  sorted
}

///|
pub fn build_wave_rollups(
  pr_categories : Array[WaveRollupEntry],
  agent_wave_map : Map[String, (String, Int)],
) -> (Array[WaveRollup], Array[WaveRollupEntry]) {
  let seen_keys : Map[String, Bool] = {}
  let keys : Array[String] = []
  for e in pr_categories {
    match agent_wave_map.get(e.agent_id) {
      Some((pid, w)) => {
        let key = wave_group_key(pid, w)
        if !seen_keys.contains(key) {
          seen_keys.set(key, true)
          keys.push(key)
        }
      }
      None => ()
    }
  }
  let multi_wave : Map[String, Bool] = {}
  for key in keys {
    let collected = collect_wave_entries(pr_categories, agent_wave_map, key)
    if distinct_pr_count_in_rollups(collected) >= 2 {
      multi_wave.set(key, true)
    }
  }
  let rollups : Array[WaveRollup] = []
  for key in keys {
    let collected = collect_wave_entries(pr_categories, agent_wave_map, key)
    if distinct_pr_count_in_rollups(collected) < 2 {
      continue
    }
    match agent_wave_map.get(collected[0].agent_id) {
      Some((parent_id, wave)) =>
        rollups.push({ parent_id, wave, entries: collected })
      None => ()
    }
  }
  let fallthrough : Array[WaveRollupEntry] = []
  for e in pr_categories {
    match agent_wave_map.get(e.agent_id) {
      None => fallthrough.push(e)
      Some((pid, w)) => {
        let key = wave_group_key(pid, w)
        match multi_wave.get(key) {
          Some(true) => ()
          _ => fallthrough.push(e)
        }
      }
    }
  }
  (sort_wave_rollups(rollups), fallthrough)
}

///|
fn tl_category_rollup_header_bucket(
  cat : TlTrackedPrWorkflowCategory,
) -> String {
  match cat {
    MergeGateOpenPendingPolicyConfirmation => "merge-ready"
    BlockedOnChanges | StalledOnChangesRequested => "blocked on changes"
    AttentionRequiredCopilotSilentAfterTimeout | AttentionRequiredCIFailed =>
      "attention required"
    WaitingOnReviewOrCI
    | WaitingOnCopilotIssueComment
    | CopilotIssueCommentSeenRecheckRemainingGates
    | ReadyForTLRecheck => "waiting or re-check"
    ObservedMergedExternal => "merged externally"
    OrphanedPRNeedsManualAction => "orphaned"
  }
}

///|
fn tl_category_rollup_pr_line(cat : TlTrackedPrWorkflowCategory) -> String {
  match cat {
    BlockedOnChanges => "Blocked on review changes"
    AttentionRequiredCopilotSilentAfterTimeout =>
      "Attention required: Copilot review silent after timeout"
    AttentionRequiredCIFailed => "Attention required: CI failing"
    WaitingOnReviewOrCI => "Waiting on review or CI"
    WaitingOnCopilotIssueComment => "Waiting on Copilot issue comment"
    CopilotIssueCommentSeenRecheckRemainingGates =>
      "Copilot issue comment seen; re-check gates"
    ReadyForTLRecheck => "Ready for TL re-check"
    MergeGateOpenPendingPolicyConfirmation => "Merge gate open"
    ObservedMergedExternal => "Merged externally"
    OrphanedPRNeedsManualAction => "Orphaned PR needs manual action"
    StalledOnChangesRequested => "Stalled on changes requested"
  }
}

///|
pub fn format_wave_rollup(rollup : WaveRollup, total_in_wave : Int) -> String {
  let by_pr : Map[Int, WaveRollupEntry] = {}
  for e in rollup.entries {
    if !by_pr.contains(e.pr_number) {
      by_pr.set(e.pr_number, e)
    }
  }
  let distinct : Array[WaveRollupEntry] = []
  for e in by_pr.values() {
    distinct.push(e)
  }
  let n_pr = distinct.length()
  for i = 0; i < n_pr; i = i + 1 {
    for j = i + 1; j < n_pr; j = j + 1 {
      let a = distinct[i]
      let b = distinct[j]
      if a.pr_number > b.pr_number {
        distinct[i] = b
        distinct[j] = a
      }
    }
  }
  let bucket_counts : Map[String, Int] = {}
  for e in distinct {
    let b = tl_category_rollup_header_bucket(e.category)
    let prev = match bucket_counts.get(b) {
      Some(v) => v
      None => 0
    }
    bucket_counts.set(b, prev + 1)
  }
  let order : Array[String] = [
    "merge-ready", "blocked on changes", "attention required", "waiting or re-check",
    "merged externally", "orphaned",
  ]
  let summary_parts : Array[String] = []
  for label in order {
    match bucket_counts.get(label) {
      Some(cnt) =>
        if cnt > 0 {
          summary_parts.push(cnt.to_string() + " " + label)
        }
      None => ()
    }
  }
  let summary = summary_parts.join(", ")
  let wave_total = if total_in_wave > 0 { total_in_wave } else { n_pr }
  let header = "[WAVE " +
    rollup.wave.to_string() +
    "] " +
    n_pr.to_string() +
    "/" +
    wave_total.to_string() +
    " PRs with updates: " +
    summary
  let lines : Array[String] = []
  for e in distinct {
    lines.push(
      "  PR #" +
      e.pr_number.to_string() +
      " (" +
      e.agent_id +
      "): " +
      tl_category_rollup_pr_line(e.category),
    )
  }
  header + "\n" + lines.join("\n")
}

///|
/// Pure merge gate: approved + CI rollup success + zero unresolved threads when
/// the GraphQL count is available. `None` threads means the gate is not open
/// (honest: unknown thread state).

///|
/// True after at least one [`PollEvent::ReviewTimeout`] has been recorded for this PR
/// and the GitHub review rollup is still `none` in Choir's snapshot. Used to surface
/// reviewer-request flakiness (accepted but no review posted) vs ordinary waiting.
pub fn tl_tracked_pr_copilot_review_silent_escalation_active(
  tracked : TrackedPR,
) -> Bool {
  tracked.last_timeout_at > 0L && tracked.last_review_state == None_
}

///|
pub fn detect_stalled_on_review(
  tracked_with_liveness : Array[(TrackedPR, Bool)],
  now : Int64,
  stall_threshold_sec : Int64,
) -> Array[TrackedPR] {
  let out : Array[TrackedPR] = []
  for pair in tracked_with_liveness {
    let (pr, agent_is_active) = pair
    if pr.last_review_state != ChangesRequested {
      continue
    }
    if pr.changes_requested_since <= 0L {
      continue
    }
    if now - pr.changes_requested_since < stall_threshold_sec {
      continue
    }
    if pr.stall_notified {
      continue
    }
    if !agent_is_active {
      continue
    }
    out.push(pr)
  }
  out
}

///|
pub fn tl_tracked_pr_merge_gate_snapshot_ready(
  tracked : TrackedPR,
  unresolved_threads : Int?,
) -> Bool {
  let threads_clear = match unresolved_threads {
    Some(n) => n == 0
    None => false
  }
  let review_ok = tracked.last_review_state == Approved
  if !review_ok {
    return false
  }
  if tracked.last_ci_rollup != Success {
    return false
  }
  threads_clear
}

///|
fn evaluation_review_state_from_snapshot(
  review : ReviewState,
) -> @types.EvaluationReviewState {
  match review {
    None_ => @types.EvaluationReviewState::None_
    Commented => @types.EvaluationReviewState::Commented
    Approved => @types.EvaluationReviewState::Approved
    ChangesRequested => @types.EvaluationReviewState::ChangesRequested
  }
}

///|
fn evaluation_ci_rollup_from_snapshot(
  ci : CiRollupStatus,
) -> @types.EvaluationCiRollup {
  match ci {
    Unknown => @types.EvaluationCiRollup::Unknown
    InProgress => @types.EvaluationCiRollup::InProgress
    Success => @types.EvaluationCiRollup::Success
    Failure => @types.EvaluationCiRollup::Failure
  }
}

///|
pub fn advisory_evaluation_bundle_for_tracked_pr(
  tracked : TrackedPR,
  unresolved_threads : Int?,
  task_contract? : @types.TaskContract? = None,
) -> @types.EvaluationBundle {
  let signals : Array[@types.EvaluationSignal] = [
    @types.EvaluationSignal::Review(
      state=evaluation_review_state_from_snapshot(tracked.last_review_state),
      body=tracked.last_review_bodies,
    ),
    @types.EvaluationSignal::Ci(
      status=evaluation_ci_rollup_from_snapshot(tracked.last_ci_rollup),
    ),
  ]
  match unresolved_threads {
    Some(count) =>
      signals.push(@types.EvaluationSignal::ThreadsObserved(count~))
    None => signals.push(@types.EvaluationSignal::ThreadsUnobserved)
  }
  if tracked.copilot_issue_comment_seen {
    signals.push(@types.EvaluationSignal::CopilotIssueCommentObserved)
  } else {
    signals.push(@types.EvaluationSignal::CopilotIssueCommentUnobserved)
  }
  { task_contract, signals }
}

///|
pub fn advisory_evaluation_result_for_tracked_pr(
  tracked : TrackedPR,
  unresolved_threads : Int?,
  task_contract? : @types.TaskContract? = None,
) -> @types.EvaluationResult {
  @types.advisory_evaluation_result(
    advisory_evaluation_bundle_for_tracked_pr(
      tracked,
      unresolved_threads,
      task_contract~,
    ),
  )
}

///|
pub fn advisory_evaluation_summary_line(
  tracked : TrackedPR,
  unresolved_threads : Int?,
  task_contract? : @types.TaskContract? = None,
) -> String {
  let result = advisory_evaluation_result_for_tracked_pr(
    tracked,
    unresolved_threads,
    task_contract~,
  )
  "Advisory evaluation verdict: " +
  result.verdict.label() +
  " (" +
  result.summary +
  ")."
}

///|
pub fn merge_policy_decision_for_tracked_pr(
  tracked : TrackedPR,
  unresolved_threads : Int?,
  task_contract? : @types.TaskContract? = None,
) -> @policy.MergeDecision {
  @policy.decide_merge(
    task_contract,
    advisory_evaluation_bundle_for_tracked_pr(
      tracked,
      unresolved_threads,
      task_contract~,
    ),
  )
}

///|
pub fn merge_policy_summary_line(
  tracked : TrackedPR,
  unresolved_threads : Int?,
  task_contract? : @types.TaskContract? = None,
) -> String {
  let decision = merge_policy_decision_for_tracked_pr(
    tracked,
    unresolved_threads,
    task_contract~,
  )
  "Merge policy decision: " + decision.label() + " (" + decision.reason() + ")."
}

///|
fn tl_snapshot_workflow_category(
  tracked : TrackedPR,
  merge_ready : Bool,
) -> TlTrackedPrWorkflowCategory {
  if tracked.last_review_state == ChangesRequested {
    return BlockedOnChanges
  }
  if merge_ready {
    return MergeGateOpenPendingPolicyConfirmation
  }
  if tl_tracked_pr_copilot_review_silent_escalation_active(tracked) {
    return AttentionRequiredCopilotSilentAfterTimeout
  }
  if !tracked.copilot_issue_comment_seen {
    return WaitingOnCopilotIssueComment
  }
  CopilotIssueCommentSeenRecheckRemainingGates
}

///|
/// Classify the snapshot when no specific poll event lens applies (e.g. generic
/// triage). `ChangesRequested` is always blocked; a satisfied merge gate is a
/// distinct category; otherwise wait on review/CI/thread data.
pub fn tl_classify_tracked_pr_workflow(
  tracked : TrackedPR,
  unresolved_threads : Int?,
) -> TlTrackedPrWorkflowCategory {
  let merge_ready = tl_tracked_pr_merge_gate_snapshot_ready(
    tracked, unresolved_threads,
  )
  tl_snapshot_workflow_category(tracked, merge_ready)
}

///|
/// One stable sentence per category for parent-facing notifications (`TLDecision:` line).
pub fn tl_tracked_pr_workflow_category_sentence(
  cat : TlTrackedPrWorkflowCategory,
) -> String {
  match cat {
    BlockedOnChanges =>
      "BLOCKED: review requested changes. Wait for leaf to push fixes."
    AttentionRequiredCopilotSilentAfterTimeout =>
      "ACTION REQUIRED: no review appeared after timeout. Run: gh pr edit --add-reviewer @copilot"
    AttentionRequiredCIFailed => "BLOCKED: CI failing. Do not merge."
    WaitingOnReviewOrCI => "Waiting on review or CI. No action needed yet."
    WaitingOnCopilotIssueComment =>
      "Waiting on Copilot review. No action needed yet."
    CopilotIssueCommentSeenRecheckRemainingGates =>
      "Copilot reviewed. Check approval/threads, then merge_pr if clear."
    ReadyForTLRecheck =>
      "CI/review changed. Check approval/threads, then merge_pr if clear."
    MergeGateOpenPendingPolicyConfirmation =>
      "MERGE NOW: reviewed, CI green, threads resolved. Run merge_pr."
    ObservedMergedExternal => "PR already merged externally. Kill the leaf."
    OrphanedPRNeedsManualAction =>
      "ORPHANED: leaf is dead, PR still open. Run merge_pr or rescue_leaf."
    StalledOnChangesRequested =>
      "STALLED: changes requested but leaf hasn't pushed. Check leaf or respawn."
  }
}

///|
/// Map a poll event and the current tracked snapshot to the TL decision model.
/// `unresolved_threads` is the GraphQL unresolved count when fetched for this
/// delivery (CI re-check events), else `None`.
pub fn plan_tl_poll_event_parent(
  event : PollEvent,
  tracked : TrackedPR,
  unresolved_threads : Int?,
) -> TlTrackedPrWorkflowCategory {
  let merge_ready = tl_tracked_pr_merge_gate_snapshot_ready(
    tracked, unresolved_threads,
  )
  match event {
    PRMerged(_) => ObservedMergedExternal
    ReviewTimeout(_) => AttentionRequiredCopilotSilentAfterTimeout
    CIFailed(_) => AttentionRequiredCIFailed
    CIFailureCleared(_) | CILatestHeadRollupSucceeded(_) =>
      if merge_ready {
        MergeGateOpenPendingPolicyConfirmation
      } else if tracked.last_review_state == ChangesRequested {
        BlockedOnChanges
      } else if tl_tracked_pr_copilot_review_silent_escalation_active(tracked) {
        AttentionRequiredCopilotSilentAfterTimeout
      } else {
        ReadyForTLRecheck
      }
    PRReady(_) => tl_snapshot_workflow_category(tracked, merge_ready)
    FixesPushed(_) =>
      if merge_ready {
        MergeGateOpenPendingPolicyConfirmation
      } else {
        WaitingOnReviewOrCI
      }
    ReviewReceived(_, _) =>
      if tracked.last_review_state == ChangesRequested {
        BlockedOnChanges
      } else {
        WaitingOnReviewOrCI
      }
    ReviewCommented(_, _) => WaitingOnReviewOrCI
    CopilotIssueCommentSeen(_) =>
      tl_snapshot_workflow_category(tracked, merge_ready)
    MergeReady(_) => MergeGateOpenPendingPolicyConfirmation
    ReviewThreadsResolved(_) => ReadyForTLRecheck
  }
}

///|
/// Gate paragraph for `format_tl_pr_recheck_summary` (shared with tools package).
/// Same strings as the historical inline implementation.
pub fn tl_tracked_pr_recheck_gate_line(
  tracked : TrackedPR,
  unresolved_thread_count : Int?,
) -> String {
  let snapshot_ready = tl_tracked_pr_merge_gate_snapshot_ready(
    tracked, unresolved_thread_count,
  )
  if snapshot_ready {
    if tracked.copilot_issue_comment_seen {
      "Choir snapshot: no tracked blockers (approved, CI success, zero unresolved threads). Copilot issue comment observed. Confirm repo policy, then merge_pr if appropriate. Does not merge."
    } else {
      "Choir snapshot: no tracked blockers (approved, CI success, zero unresolved threads), but no Copilot issue comment observed on this PR yet — confirm policy before merge_pr. Does not merge."
    }
  } else {
    let parts : Array[String] = []
    if tl_tracked_pr_copilot_review_silent_escalation_active(tracked) {
      parts.push(
        "review wait already timed out with no review in Choir snapshot (comment-triggered Copilot may be unreliable)",
      )
    }
    if !tracked.copilot_issue_comment_seen {
      parts.push(
        "no GitHub Copilot issue comment observed (REST issue comments)",
      )
    }
    if tracked.last_review_state == ChangesRequested {
      parts.push("GitHub review requests changes")
    }
    if tracked.last_review_state == None_ {
      parts.push("no approving review in GitHub snapshot")
    }
    if tracked.last_review_state == Commented {
      parts.push("latest review is comment-only (not an approval)")
    }
    match unresolved_thread_count {
      Some(n) =>
        if n > 0 {
          parts.push(n.to_string() + " unresolved inline thread(s) remain")
        }
      None => ()
    }
    if tracked.last_ci_rollup != Success {
      parts.push("latest head CI rollup is not all-success")
    }
    if parts.length() == 0 {
      "TL re-check still needed before merge_pr (policy and GitHub state can differ from this snapshot)."
    } else {
      "TL re-check needed: " + parts.join("; ") + "."
    }
  }
}

///|
pub fn detect_orphaned_prs(
  tracked_with_liveness : Array[(TrackedPR, Bool)],
) -> Array[TrackedPR] {
  let out = []
  for pair in tracked_with_liveness {
    let (pr, agent_is_active) = pair
    if !agent_is_active && !pr.orphan_notified {
      out.push(pr)
    }
  }
  out
}

///|
pub impl Show for TlTrackedPrWorkflowCategory with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for WaveRollupEntry with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}
