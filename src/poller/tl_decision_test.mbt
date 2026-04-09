///|
fn sample_tracked(
  review : ReviewState,
  ci : CiRollupStatus,
  pr_number : Int,
) -> TrackedPR {
  {
    pr_number,
    agent_id: "main.dev",
    branch: "work/x",
    parent_branch: "main",
    pr_url: "https://ex/pr/" + pr_number.to_string(),
    first_seen: 0L,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: review,
    last_review_bodies: "",
    last_sha: "sha",
    notified_parent: false,
    last_ci_rollup: ci,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: false,
    orphan_notified: false,
    orphan_reconciling: false,
    changes_requested_since: 0L,
    stall_notified: false,
  }
}

///|
test "tl_tracked_pr_merge_gate_snapshot_ready requires threads when approved and CI green" {
  let t = sample_tracked(Approved, Success, 1)
  assert_true(tl_tracked_pr_merge_gate_snapshot_ready(t, Some(0)))
  assert_false(tl_tracked_pr_merge_gate_snapshot_ready(t, None))
  assert_false(tl_tracked_pr_merge_gate_snapshot_ready(t, Some(2)))
}

///|
test "tl_classify_tracked_pr_workflow distinguishes blocked, waiting, and merge-gate-open" {
  assert_eq(
    tl_classify_tracked_pr_workflow(
      sample_tracked(ChangesRequested, Success, 2),
      Some(0),
    ),
    BlockedOnChanges,
  )
  assert_eq(
    tl_classify_tracked_pr_workflow(
      sample_tracked(Approved, InProgress, 3),
      None,
    ),
    WaitingOnCopilotIssueComment,
  )
  assert_eq(
    tl_classify_tracked_pr_workflow(
      sample_tracked(Approved, Success, 4),
      Some(0),
    ),
    MergeGateOpenPendingPolicyConfirmation,
  )
}

///|
test "tl_classify_tracked_pr_workflow escalates when review timeout fired and snapshot still has no review" {
  let t_escalated = {
    ..sample_tracked(None_, Success, 40),
    last_timeout_at: 1L,
  }
  assert_eq(
    tl_classify_tracked_pr_workflow(t_escalated, Some(0)),
    AttentionRequiredCopilotSilentAfterTimeout,
  )
}

///|
test "tl_tracked_pr_workflow_category_sentence covers alert categories" {
  assert_true(
    tl_tracked_pr_workflow_category_sentence(
      AttentionRequiredCopilotSilentAfterTimeout,
    ).contains("ACTION REQUIRED"),
  )
  assert_true(
    tl_tracked_pr_workflow_category_sentence(AttentionRequiredCIFailed).contains(
      "CI failing",
    ),
  )
  assert_true(
    tl_tracked_pr_workflow_category_sentence(ObservedMergedExternal).contains(
      "merged externally",
    ),
  )
  assert_true(
    tl_tracked_pr_workflow_category_sentence(
      MergeGateOpenPendingPolicyConfirmation,
    ).contains("MERGE NOW"),
  )
}

///|
test "plan_tl_poll_event_parent PRReady waits when snapshot is not merge-ready" {
  let t = sample_tracked(Approved, InProgress, 5)
  let cat = plan_tl_poll_event_parent(PRReady(5), t, None)
  assert_eq(cat, WaitingOnCopilotIssueComment)
}

///|
test "plan_tl_poll_event_parent PRReady uses merge gate category when snapshot allows" {
  let t = sample_tracked(Approved, Success, 6)
  let cat = plan_tl_poll_event_parent(PRReady(6), t, Some(0))
  assert_eq(cat, MergeGateOpenPendingPolicyConfirmation)
}

///|
test "plan_tl_poll_event_parent PRReady merge-ready with Copilot issue comment seen" {
  let t = {
    ..sample_tracked(Approved, Success, 61),
    copilot_issue_comment_seen: true,
  }
  assert_eq(
    plan_tl_poll_event_parent(PRReady(61), t, Some(0)),
    MergeGateOpenPendingPolicyConfirmation,
  )
}

///|
test "plan_tl_poll_event_parent CI actionable events can open merge gate" {
  let t = sample_tracked(Approved, Success, 7)
  let cat = plan_tl_poll_event_parent(
    CILatestHeadRollupSucceeded(7),
    t,
    Some(0),
  )
  assert_eq(cat, MergeGateOpenPendingPolicyConfirmation)
}

///|
test "plan_tl_poll_event_parent CI actionable events merge gate when Copilot seen" {
  let t = {
    ..sample_tracked(Approved, Success, 71),
    copilot_issue_comment_seen: true,
  }
  let cat = plan_tl_poll_event_parent(
    CILatestHeadRollupSucceeded(71),
    t,
    Some(0),
  )
  assert_eq(cat, MergeGateOpenPendingPolicyConfirmation)
}

///|
test "plan_tl_poll_event_parent CI actionable events stay blocked on changes" {
  let t = sample_tracked(ChangesRequested, Success, 8)
  let cat = plan_tl_poll_event_parent(CIFailureCleared(8), t, Some(0))
  assert_eq(cat, BlockedOnChanges)
}

///|
test "plan_tl_poll_event_parent timeout and CI failure are attention states" {
  let t = sample_tracked(Approved, Failure, 9)
  assert_eq(
    plan_tl_poll_event_parent(ReviewTimeout(9), t, None),
    AttentionRequiredCopilotSilentAfterTimeout,
  )
  assert_eq(
    plan_tl_poll_event_parent(CIFailed(9), t, None),
    AttentionRequiredCIFailed,
  )
}

///|
test "plan_tl_poll_event_parent CI rollup success uses escalation when review timeout already fired" {
  let t = { ..sample_tracked(None_, Success, 41), last_timeout_at: 100L }
  assert_eq(
    plan_tl_poll_event_parent(CILatestHeadRollupSucceeded(41), t, Some(0)),
    AttentionRequiredCopilotSilentAfterTimeout,
  )
}

///|
test "plan_tl_poll_event_parent observed merged external" {
  let t = sample_tracked(Approved, Success, 10)
  assert_eq(
    plan_tl_poll_event_parent(PRMerged(10), t, Some(0)),
    ObservedMergedExternal,
  )
}

///|
test "tl_tracked_pr_recheck_gate_line matches no blocked snapshot" {
  let t = sample_tracked(Approved, Success, 11)
  let line = tl_tracked_pr_recheck_gate_line(t, Some(0))
  assert_true(line.contains("no tracked blockers"))
  assert_true(line.contains("Does not merge"))
  assert_true(line.contains("no Copilot issue comment observed"))
}

///|
test "merge_policy_decision_for_tracked_pr returns merge_now for approved success zero threads" {
  let t = sample_tracked(Approved, Success, 12)
  let decision = merge_policy_decision_for_tracked_pr(t, Some(0))
  assert_eq(decision.label(), "merge_now")
}

///|
test "merge_policy_summary_line reflects missing verify evidence" {
  let t = sample_tracked(Approved, Success, 13)
  let contract = {
    ..@types.TaskContract::empty(),
    goal: "ship feature",
    verify: ["moon test --target native"],
  }
  let line = merge_policy_summary_line(t, Some(0), task_contract=Some(contract))
  assert_true(line.contains("needs_human"))
  assert_true(line.contains("local verify not observed"))
}

///|
test "detect_stalled_on_review fires when threshold exceeded and agent active" {
  let t = {
    ..sample_tracked(ChangesRequested, Success, 50),
    changes_requested_since: 100L,
    stall_notified: false,
  }
  let got = detect_stalled_on_review([(t, true)], 800L, 600L)
  assert_eq(got.length(), 1)
  assert_eq(got[0].pr_number, 50)
}

///|
test "detect_stalled_on_review does not fire before threshold" {
  let t = {
    ..sample_tracked(ChangesRequested, Success, 51),
    changes_requested_since: 100L,
    stall_notified: false,
  }
  let got = detect_stalled_on_review([(t, true)], 500L, 600L)
  assert_eq(got.length(), 0)
}

///|
test "detect_stalled_on_review does not fire when agent inactive" {
  let t = {
    ..sample_tracked(ChangesRequested, Success, 52),
    changes_requested_since: 100L,
    stall_notified: false,
  }
  let got = detect_stalled_on_review([(t, false)], 800L, 600L)
  assert_eq(got.length(), 0)
}

///|
test "detect_stalled_on_review does not fire when stall_notified" {
  let t = {
    ..sample_tracked(ChangesRequested, Success, 53),
    changes_requested_since: 100L,
    stall_notified: true,
  }
  let got = detect_stalled_on_review([(t, true)], 800L, 600L)
  assert_eq(got.length(), 0)
}

///|
test "detect_stalled_on_review skips when review is not ChangesRequested" {
  let t = {
    ..sample_tracked(Approved, Success, 54),
    changes_requested_since: 100L,
    stall_notified: false,
  }
  let got = detect_stalled_on_review([(t, true)], 800L, 600L)
  assert_eq(got.length(), 0)
}

///|
test "detect_stalled_on_review skips when changes_requested_since is zero" {
  let t = {
    ..sample_tracked(ChangesRequested, Success, 55),
    changes_requested_since: 0L,
    stall_notified: false,
  }
  let got = detect_stalled_on_review([(t, true)], 800L, 600L)
  assert_eq(got.length(), 0)
}

///|
test "plan_tl_poll_event_parent CopilotIssueCommentSeen uses post-detection snapshot" {
  let t = {
    ..sample_tracked(Approved, Success, 99),
    copilot_issue_comment_seen: true,
  }
  assert_eq(
    plan_tl_poll_event_parent(CopilotIssueCommentSeen(99), t, Some(0)),
    MergeGateOpenPendingPolicyConfirmation,
  )
}

///|
test "tl_tracked_pr_recheck_gate_line merge-ready snapshot notes Copilot when seen" {
  let t = {
    ..sample_tracked(Approved, Success, 12),
    copilot_issue_comment_seen: true,
  }
  let line = tl_tracked_pr_recheck_gate_line(t, Some(0))
  assert_true(line.contains("Copilot issue comment observed"))
}

///|
test "tl_tracked_pr_recheck_gate_line mentions escalation when copilot silent after timeout" {
  let t = { ..sample_tracked(None_, Success, 42), last_timeout_at: 50L }
  let line = tl_tracked_pr_recheck_gate_line(t, Some(0))
  assert_true(line.contains("timed out"))
  assert_true(line.contains("Copilot"))
}

///|
test "detect_orphaned_prs returns PR when agent inactive and not yet notified" {
  let pr = sample_tracked(None_, Unknown, 501)
  let got = detect_orphaned_prs([(pr, false)])
  assert_eq(got.length(), 1)
  assert_eq(got[0].pr_number, 501)
}

///|
test "detect_orphaned_prs skips when orphan_notified" {
  let pr = { ..sample_tracked(None_, Unknown, 502), orphan_notified: true }
  let got = detect_orphaned_prs([(pr, false)])
  assert_eq(got.length(), 0)
}

///|
test "detect_orphaned_prs skips while stale PR reconciliation is in progress" {
  let pr = { ..sample_tracked(None_, Unknown, 504), orphan_reconciling: true }
  let got = detect_orphaned_prs([(pr, false)])
  assert_eq(got.length(), 0)
}

///|
test "detect_orphaned_prs skips when agent is active" {
  let pr = sample_tracked(None_, Unknown, 503)
  let got = detect_orphaned_prs([(pr, true)])
  assert_eq(got.length(), 0)
}

///|
test "detect_orphaned_prs empty input returns empty" {
  let got : Array[(TrackedPR, Bool)] = []
  assert_eq(detect_orphaned_prs(got).length(), 0)
}

///|
test "build_wave_rollups groups three PRs in same wave into one rollup" {
  let es = [
    WaveRollupEntry::{
      pr_number: 10,
      agent_id: "main.leaf-a",
      category: BlockedOnChanges,
    },
    WaveRollupEntry::{
      pr_number: 11,
      agent_id: "main.leaf-b",
      category: MergeGateOpenPendingPolicyConfirmation,
    },
    WaveRollupEntry::{
      pr_number: 12,
      agent_id: "main.leaf-c",
      category: WaitingOnReviewOrCI,
    },
  ]
  let m : Map[String, (String, Int)] = {
    "main.leaf-a": ("main.tl", 1),
    "main.leaf-b": ("main.tl", 1),
    "main.leaf-c": ("main.tl", 1),
  }
  let (rollups, ft) = build_wave_rollups(es, m)
  assert_eq(rollups.length(), 1)
  assert_eq(ft.length(), 0)
  assert_eq(rollups[0].parent_id, "main.tl")
  assert_eq(rollups[0].wave, 1)
  assert_eq(rollups[0].entries.length(), 3)
}

///|
test "build_wave_rollups single-PR wave falls through" {
  let es = [
    WaveRollupEntry::{
      pr_number: 20,
      agent_id: "main.solo",
      category: BlockedOnChanges,
    },
  ]
  let m : Map[String, (String, Int)] = { "main.solo": ("main.tl", 1) }
  let (rollups, ft) = build_wave_rollups(es, m)
  assert_eq(rollups.length(), 0)
  assert_eq(ft.length(), 1)
  assert_eq(ft[0].pr_number, 20)
}

///|
test "build_wave_rollups unmapped agent falls through" {
  let es = [
    WaveRollupEntry::{
      pr_number: 21,
      agent_id: "orphan.leaf",
      category: AttentionRequiredCIFailed,
    },
  ]
  let m : Map[String, (String, Int)] = {}
  let (rollups, ft) = build_wave_rollups(es, m)
  assert_eq(rollups.length(), 0)
  assert_eq(ft.length(), 1)
  assert_eq(ft[0].agent_id, "orphan.leaf")
}

///|
test "build_wave_rollups different waves produce separate rollups" {
  let es = [
    WaveRollupEntry::{
      pr_number: 30,
      agent_id: "main.w1a",
      category: BlockedOnChanges,
    },
    WaveRollupEntry::{
      pr_number: 31,
      agent_id: "main.w1b",
      category: BlockedOnChanges,
    },
    WaveRollupEntry::{
      pr_number: 40,
      agent_id: "main.w2a",
      category: BlockedOnChanges,
    },
    WaveRollupEntry::{
      pr_number: 41,
      agent_id: "main.w2b",
      category: BlockedOnChanges,
    },
  ]
  let m : Map[String, (String, Int)] = {
    "main.w1a": ("main.tl", 1),
    "main.w1b": ("main.tl", 1),
    "main.w2a": ("main.tl", 2),
    "main.w2b": ("main.tl", 2),
  }
  let (rollups, ft) = build_wave_rollups(es, m)
  assert_eq(rollups.length(), 2)
  assert_eq(ft.length(), 0)
  assert_eq(rollups[0].wave, 1)
  assert_eq(rollups[1].wave, 2)
}

///|
test "format_wave_rollup matches expected header and PR lines" {
  let rollup : WaveRollup = {
    parent_id: "main",
    wave: 1,
    entries: [
      WaveRollupEntry::{
        pr_number: 42,
        agent_id: "main.leaf-a",
        category: MergeGateOpenPendingPolicyConfirmation,
      },
      WaveRollupEntry::{
        pr_number: 45,
        agent_id: "main.leaf-c",
        category: BlockedOnChanges,
      },
    ],
  }
  let expected =
    #|[WAVE 1] 2/4 PRs with updates: 1 merge-ready, 1 blocked on changes
    #|  PR #42 (main.leaf-a): Merge gate open
    #|  PR #45 (main.leaf-c): Blocked on review changes
  assert_eq(format_wave_rollup(rollup, 4), expected)
}

///|
test "format_wave_rollup uses PR count as denominator when wave size unknown" {
  let rollup : WaveRollup = {
    parent_id: "main",
    wave: 1,
    entries: [
      WaveRollupEntry::{
        pr_number: 42,
        agent_id: "main.leaf-a",
        category: MergeGateOpenPendingPolicyConfirmation,
      },
      WaveRollupEntry::{
        pr_number: 45,
        agent_id: "main.leaf-c",
        category: BlockedOnChanges,
      },
    ],
  }
  let out = format_wave_rollup(rollup, 0)
  assert_true(out.contains("[WAVE 1] 2/2 PRs with updates:"))
}

///|
test "tl_tracked_pr_merge_gate_snapshot_ready waits for Copilot comment on comment-only review" {
  let t = sample_tracked(Commented, Success, 100)
  assert_false(tl_tracked_pr_merge_gate_snapshot_ready(t, Some(0)))
}

///|
test "tl_tracked_pr_merge_gate_snapshot_ready accepts comment-only review after Copilot comment is seen" {
  let t = {
    ..sample_tracked(Commented, Success, 101),
    copilot_issue_comment_seen: true,
  }
  assert_true(tl_tracked_pr_merge_gate_snapshot_ready(t, Some(0)))
}

///|
test "tl_classify_tracked_pr_workflow waits for Copilot comment on comment-only review" {
  let t = sample_tracked(Commented, Success, 200)
  let cat = tl_classify_tracked_pr_workflow(t, Some(0))
  assert_eq(cat, WaitingOnCopilotIssueComment)
}

///|
test "tl_classify_tracked_pr_workflow treats comment-only review as merge-ready after Copilot comment is seen" {
  let t = {
    ..sample_tracked(Commented, Success, 201),
    copilot_issue_comment_seen: true,
  }
  let cat = tl_classify_tracked_pr_workflow(t, Some(0))
  assert_eq(cat, MergeGateOpenPendingPolicyConfirmation)
}

///|
test "merge_policy_decision_for_tracked_pr waits for comment-only review until Copilot comment is seen" {
  let t = sample_tracked(Commented, Success, 202)
  let decision = merge_policy_decision_for_tracked_pr(t, Some(0))
  assert_eq(decision.label(), "wait")
}

///|
test "merge_policy_decision_for_tracked_pr returns merge_now for comment-only review after Copilot comment is seen" {
  let t = {
    ..sample_tracked(Commented, Success, 203),
    copilot_issue_comment_seen: true,
  }
  let decision = merge_policy_decision_for_tracked_pr(t, Some(0))
  assert_eq(decision.label(), "merge_now")
}
