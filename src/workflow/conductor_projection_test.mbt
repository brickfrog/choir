///|
/// The display is asserted at one fixed instant: every test in this file is
/// about the shape of a display rather than about time passing, and the two
/// things that do age — a surface deferral and a provider observation — have
/// their own tests that name their own instants.
fn goal_display(
  report : @workflow.GoalStatusReport,
  now? : Int64 = 1_000L,
) -> @workflow.ConductorGoalDisplay? {
  @workflow.conductor_goal_display(report, now)
}

///|
fn projection_part(
  stage : @workflow.PartWorkflowStage,
  durable_version? : Int = 11,
  effect_receipt_count? : Int = 3,
  provider_failovers? : Array[@workflow.PartProviderFailover] = [],
  admitted_provider_surfaces? : Array[@control.ProviderSurfaceId] = [
    @control.ProviderSurfaceId::CodexSubscriptionCli,
  ],
  leased_provider_surface? : @control.ProviderSurfaceId? = None,
) -> @workflow.GoalPartStatus {
  {
    workflow_id: @control.WorkflowId("wf-part-a"),
    part_id: @control.PartId("part-a"),
    provider_surface: @control.ProviderSurfaceId::CodexSubscriptionCli,
    implementation_take_id: @control.TakeId("take-impl"),
    implementation_take_lifecycle: @control.TakeLifecycle::TakeRunning,
    implementation_session_lifecycle: None,
    verification_take_id: @control.TakeId("take-verify"),
    verification_take_lifecycle: @control.TakeLifecycle::TakePlanned,
    verification_session_lifecycle: None,
    audit_take_id: @control.TakeId("take-audit"),
    audit_take_lifecycle: @control.TakeLifecycle::TakePlanned,
    audit_session_lifecycle: None,
    lifecycle: @control.PartLifecycle::PartReady,
    stage,
    durable_version,
    harness_session_count: 0,
    effect_receipt_count,
    verification_receipt_count: 0,
    audit_receipt_present: false,
    audit_total_findings_count: 0,
    audit_blocking_findings_count: 0,
    integration_receipt_present: false,
    dispatch_diagnostic: None,
    provider_failovers,
    admitted_provider_surfaces,
    leased_provider_surface,
    usage: @control.empty_take_usage(),
  }
}

///|
fn projection_report(
  state? : @workflow.GoalExecutionState = @workflow.GoalExecutionState::GoalExecutionRunning,
  parts? : Array[@workflow.GoalPartStatus] = [
    projection_part(
      @workflow.PartWorkflowStage::PartImplementationHarnessStarted,
    ),
  ],
  durable_version? : Int = 7,
  assurance_effect_receipt_count? : Int = 2,
  pause_reason? : @workflow.GoalPauseReason? = None,
  work_order? : @workflow.WorkOrderBudget? = None,
  pull_request_state? : @workflow.PullRequestIntentState? = None,
  readiness_decision? : @workflow.PullRequestReadinessDecision? = None,
  maximum_parallel_parts? : Int = 1,
  provider_capacity? : Array[@workflow.ProviderSurfaceCapacityStatus] = [],
) -> @workflow.GoalStatusReport {
  let goal_id = @control.GoalId("goal-a")
  {
    goal_id,
    state,
    lifecycle: @control.GoalLifecycle::GoalActive(
      @control.GoalActiveCondition::GoalRunning,
    ),
    goal_ref: @workflow.GitRefName("refs/heads/choir/goals/goal-a"),
    integration_target_ref: @workflow.GitRefName("refs/heads/main"),
    durable_version,
    maximum_parallel_parts,
    active_policy_revision: {
      id: @control.RevisionId("revision-1"),
      goal_id,
      parent_revision_id: None,
      ordinal: 1,
      change: @workflow.GoalPolicyChange::GoalPolicyInitial,
      maximum_parallel_parts,
      digest: @control.Digest(
        "0000000000000000000000000000000000000000000000000000000000000000",
      ),
    },
    policy_revision_count: 1,
    pause_reason,
    resume_state: None,
    active_input_request: None,
    input_answer_count: 0,
    assurance_stage: None,
    assurance_block_reason: None,
    goal_verification_take_id: None,
    goal_audit_take_id: None,
    goal_branch_seal: None,
    assurance_sandbox_count: 0,
    assurance_harness_session_count: 0,
    assurance_effect_receipt_count,
    goal_verification_receipt_count: 0,
    goal_audit_receipt_present: false,
    publication_state: None,
    publication_remote_repository_id: None,
    publication_remote_head_ref: None,
    publication_receipt_present: false,
    published_oid: None,
    pull_request_state,
    pull_request_delivery_policy: None,
    pull_request_draft: None,
    readiness_observed_draft: None,
    usage: @control.empty_take_usage(),
    provider_capacity,
    pull_request_merge_state: None,
    pull_request_receipt_present: false,
    pull_request_number: None,
    pull_request_url: None,
    finalization_id: None,
    readiness_decision,
    readiness_observation_sequence: None,
    work_order,
    cancellation_cause: None,
    cancellation_cutoff_sequence: None,
    semantic_run_projection: None,
    parts,
  }
}

///|
test "material fingerprint ignores counter churn but tracks stage movement" {
  let running = projection_report()
  let count_only = projection_report(
    durable_version=8,
    assurance_effect_receipt_count=9,
    parts=[
      projection_part(
        @workflow.PartWorkflowStage::PartImplementationHarnessStarted,
        durable_version=12,
        effect_receipt_count=8,
      ),
    ],
  )
  assert_eq(
    @workflow.goal_report_material_fingerprint(running),
    @workflow.goal_report_material_fingerprint(count_only),
  )
  let stage_moved = projection_report(parts=[
    projection_part(
      @workflow.PartWorkflowStage::PartVerificationSandboxPrepared,
    ),
  ])
  assert_true(
    @workflow.goal_report_material_fingerprint(running) !=
    @workflow.goal_report_material_fingerprint(stage_moved),
  )
}

///|
test "a Part that changed provider surface is a material change" {
  let running = projection_report()
  // The two reports differ in nothing but the recorded failover: same stage,
  // same lifecycles, same counters. A fingerprint that dropped it would leave
  // the Conductor unable to see that a Part started spending a different
  // provider's allowance, and therefore unable to explain it.
  let failed_over = projection_report(parts=[
    projection_part(
      @workflow.PartWorkflowStage::PartImplementationHarnessStarted,
      provider_failovers=[
        {
          from_surface: @control.ProviderSurfaceId::ClaudeSubscriptionCli,
          to_surface: @control.ProviderSurfaceId::CodexSubscriptionCli,
          cause: @control.ProviderAvailability::ProviderAllowanceExhausted(None),
          retry_ordinal: 1,
          decided_at: 500L,
        },
      ],
    ),
  ])
  assert_true(
    @workflow.goal_report_material_fingerprint(running) !=
    @workflow.goal_report_material_fingerprint(failed_over),
  )
}

///|
test "park releases for terminal states and a durable cancellation cutoff" {
  assert_false(
    @workflow.conductor_park_for_goal_state(
      Some(@workflow.GoalExecutionState::GoalExecutionSucceeded),
    ),
  )
  assert_false(
    @workflow.conductor_park_for_goal_state(
      Some(@workflow.GoalExecutionState::GoalExecutionCanceled),
    ),
  )
  assert_false(
    @workflow.conductor_park_for_goal_state(
      Some(@workflow.GoalExecutionState::GoalExecutionCanceling),
    ),
  )
  assert_true(
    @workflow.conductor_park_for_goal_state(
      Some(@workflow.GoalExecutionState::GoalExecutionRunning),
    ),
  )
  assert_true(@workflow.conductor_park_for_goal_state(None))
  assert_eq(
    @workflow.parse_goal_execution_state("GoalExecutionRunning"),
    Some(@workflow.GoalExecutionState::GoalExecutionRunning),
  )
  assert_eq(@workflow.parse_goal_execution_state("NotAState"), None)
}

///|
test "display projection hides terminal Goals and classifies attention" {
  assert_true(
    goal_display(
      projection_report(
        state=@workflow.GoalExecutionState::GoalExecutionSucceeded,
      ),
    )
    is None,
  )
  assert_true(
    goal_display(
      projection_report(
        state=@workflow.GoalExecutionState::GoalExecutionCanceled,
      ),
    )
    is None,
  )
  let active = goal_display(projection_report()).unwrap()
  assert_eq(active.total_parts, 1)
  assert_eq(active.implementation_parts, 1)
  assert_eq(active.attention, None)
  assert_eq(active.single_part_id, Some("part-a"))
  let blocked = goal_display(
    projection_report(parts=[
      projection_part(@workflow.PartWorkflowStage::PartBlocked),
    ]),
  ).unwrap()
  assert_eq(
    blocked.attention,
    Some(@workflow.ConductorGoalAttention::ConductorAttentionBlocked),
  )
  assert_eq(blocked.attention_target, Some("part-a"))
  let paused = goal_display(
    projection_report(
      state=@workflow.GoalExecutionState::GoalExecutionPaused,
      pause_reason=Some(@workflow.GoalPauseReason::GoalPauseRecoveryUncertain),
    ),
  ).unwrap()
  assert_eq(
    paused.attention,
    Some(@workflow.ConductorGoalAttention::ConductorAttentionRecoveryUncertain),
  )
}

///|
test "an attention summary names the durable cause, not the counters" {
  assert_eq(@workflow.goal_report_attention_summary(projection_report()), None)
  let uncertain = {
    ..projection_part(@workflow.PartWorkflowStage::PartRecoveryUncertain),
    lifecycle: @control.PartLifecycle::PartBlocked(
      @control.PartBlockReason::PartRecoveryUncertain,
    ),
    dispatch_diagnostic: Some({
      take_id: @control.TakeId("take-impl"),
      session_id: Some(@control.HarnessSessionId("session-impl")),
      reason: Some(@control.TakeUncertaintyReason::TakeProtocolViolation),
      recovery: None,
      detail: "Codex driver: provider lifecycle is incomplete (codex exit 1, 0 output bytes)",
      availability: @control.ProviderAvailability::ProviderAvailable,
      observed_at: 12L,
    }),
  }
  let summary = match
    @workflow.goal_report_attention_summary(
      projection_report(
        state=@workflow.GoalExecutionState::GoalExecutionBlocked,
        parts=[uncertain],
      ),
    ) {
    Some(value) => value
    None => fail("a blocked Goal reported no cause")
  }
  assert_true(summary.contains("part-a"))
  assert_true(summary.contains("PartRecoveryUncertain"))
  assert_true(summary.contains("codex exit 1"))
}

///|
test "a running Goal reports the stage its Parts reached, not queued" {
  let phase_for = fn(stage) {
    goal_display(projection_report(parts=[projection_part(stage)])).unwrap().phase
  }
  assert_eq(
    phase_for(@workflow.PartWorkflowStage::PartImplementationHarnessStarted),
    @workflow.ConductorGoalPhase::ConductorPhaseImplement,
  )
  assert_eq(
    phase_for(@workflow.PartWorkflowStage::PartCandidateRecorded),
    @workflow.ConductorGoalPhase::ConductorPhaseVerify,
  )
  assert_eq(
    phase_for(@workflow.PartWorkflowStage::PartAuditHarnessStarted),
    @workflow.ConductorGoalPhase::ConductorPhaseAudit,
  )
  assert_eq(
    phase_for(@workflow.PartWorkflowStage::PartIntegrationPlanned),
    @workflow.ConductorGoalPhase::ConductorPhaseIntegrate,
  )
  assert_eq(
    phase_for(@workflow.PartWorkflowStage::PartIntegrated),
    @workflow.ConductorGoalPhase::ConductorPhaseAssure,
  )
  assert_eq(
    phase_for(@workflow.PartWorkflowStage::PartAccepted),
    @workflow.ConductorGoalPhase::ConductorPhaseQueued,
  )
}

///|
test "an assured automatic-delivery Goal reports merge phase" {
  let report = projection_report(
    state=@workflow.GoalExecutionState::GoalExecutionAssured,
  )
  let merging = {
    ..report,
    publication_state: Some(
      @workflow.BranchPublicationState::BranchPublicationReceipted,
    ),
    pull_request_state: Some(
      @workflow.PullRequestIntentState::PullRequestReceipted,
    ),
    pull_request_delivery_policy: Some({
      mode: @types.PullRequestDeliveryMode::PullRequestAutoMerge,
      merge_method: @types.PullRequestMergeMethod::PullRequestSquashMerge,
    }),
    pull_request_merge_state: Some(
      @workflow.PullRequestMergeState::PullRequestMergeEnabled,
    ),
  }
  assert_eq(
    goal_display(merging).unwrap().phase,
    @workflow.ConductorGoalPhase::ConductorPhaseMerge,
  )
}

///|
test "a spent-token figure stays short enough for a status line" {
  assert_eq(@workflow.compact_token_count(0), "0")
  assert_eq(@workflow.compact_token_count(999), "999")
  assert_eq(@workflow.compact_token_count(1000), "1k")
  assert_eq(@workflow.compact_token_count(45_600), "45k")
  assert_eq(@workflow.compact_token_count(999_999), "999k")
  assert_eq(@workflow.compact_token_count(1_000_000), "1.0M")
  assert_eq(@workflow.compact_token_count(2_450_000), "2.4M")
  assert_eq(@workflow.compact_token_count(12_000_000), "12.0M")
}

///|
fn portfolio_part(
  stage : @workflow.PartWorkflowStage,
  part_id : String,
  availability? : @control.ProviderAvailability? = None,
  observed_at? : Int64 = 1_000L,
  provider_failovers? : Array[@workflow.PartProviderFailover] = [],
  admitted_provider_surfaces? : Array[@control.ProviderSurfaceId] = [
    @control.ProviderSurfaceId::CodexSubscriptionCli,
  ],
  leased_provider_surface? : @control.ProviderSurfaceId? = None,
) -> @workflow.GoalPartStatus {
  {
    ..projection_part(
      stage,
      provider_failovers~,
      admitted_provider_surfaces~,
      leased_provider_surface~,
    ),
    part_id: @control.PartId(part_id),
    dispatch_diagnostic: availability.map(fn(value) {
      {
        take_id: @control.TakeId("take-" + part_id),
        session_id: None,
        reason: None,
        detail: "provider reported its state",
        recovery: None,
        availability: value,
        observed_at,
      }
    }),
  }
}

///|
test "the WorkOrder portfolio counts every Part disposition once" {
  let report = projection_report(parts=[
    portfolio_part(@workflow.PartWorkflowStage::PartIntegrated, "delivered"),
    portfolio_part(@workflow.PartWorkflowStage::PartAccepted, "eligible"),
    portfolio_part(
      @workflow.PartWorkflowStage::PartImplementationHarnessStarted,
      "active",
    ),
    portfolio_part(@workflow.PartWorkflowStage::PartBlocked, "failed"),
    portfolio_part(
      @workflow.PartWorkflowStage::PartRecoveryUncertain,
      "quarantined",
    ),
    portfolio_part(@workflow.PartWorkflowStage::PartCanceled, "skipped"),
  ])
  let portfolio = @workflow.work_order_portfolio(report, 1_000L)
  // No pull request was intended, so integration alone is delivery.
  assert_eq(portfolio.delivered, 1)
  assert_eq(portfolio.awaiting_merge, 0)
  assert_eq(portfolio.eligible, 1)
  assert_eq(portfolio.active, 1)
  assert_eq(portfolio.failed, 1)
  assert_eq(portfolio.quarantined, 1)
  assert_eq(portfolio.skipped, 1)
  assert_eq(portfolio.provider_deferred, 0)
  // No budget, so nothing to measure against and no terminal reason.
  assert_eq(portfolio.target, None)
  assert_eq(portfolio.deadline, None)
  assert_eq(portfolio.terminal_reason, None)
}

///|
/// Delivery is the merge. A Part integrated into the Goal branch whose pull
/// request has not landed is awaiting merge, and counting it as delivered
/// would report work as finished that nobody can see.
test "an unmerged pull request leaves its Parts awaiting merge" {
  let integrated = [
    portfolio_part(@workflow.PartWorkflowStage::PartIntegrated, "one"),
    portfolio_part(@workflow.PartWorkflowStage::PartIntegrated, "two"),
  ]
  let awaiting = @workflow.work_order_portfolio(
    projection_report(
      parts=integrated,
      pull_request_state=Some(
        @workflow.PullRequestIntentState::PullRequestReceipted,
      ),
      readiness_decision=Some(
        @workflow.PullRequestReadinessDecision::PullRequestAwaitingMerge,
      ),
    ),
    1_000L,
  )
  assert_eq(awaiting.delivered, 0)
  assert_eq(awaiting.awaiting_merge, 2)
  let landed = @workflow.work_order_portfolio(
    projection_report(
      parts=integrated,
      pull_request_state=Some(
        @workflow.PullRequestIntentState::PullRequestReceipted,
      ),
      readiness_decision=Some(
        @workflow.PullRequestReadinessDecision::PullRequestReady,
      ),
    ),
    1_000L,
  )
  assert_eq(landed.delivered, 2)
  assert_eq(landed.awaiting_merge, 0)
}

///|
/// A Part waiting on a spent provider surface is not a failed Part. Counting
/// it as failed would report a healthy Goal as broken for as long as the
/// surface is down.
test "a Part deferred on its provider is counted apart from a failed one" {
  let parts = [
    portfolio_part(
      @workflow.PartWorkflowStage::PartRecoveryUncertain,
      "waiting",
      availability=Some(
        @control.ProviderAvailability::ProviderAllowanceExhausted(Some(2_000L)),
      ),
    ),
  ]
  let before = @workflow.work_order_portfolio(projection_report(parts~), 1_999L)
  assert_eq(before.provider_deferred, 1)
  // Past the reported reset the surface admits work again, so the Part is no
  // longer deferred even though it is still quarantined.
  let after = @workflow.work_order_portfolio(projection_report(parts~), 2_000L)
  assert_eq(after.provider_deferred, 0)
  assert_eq(after.quarantined, 1)
  // A surface that reported no reset instant is deferred too, and stops being
  // deferred when the observation ages out. The report reads the same schedule
  // the recovery decision does, so a Part shown as waiting is one that would
  // actually be made to wait.
  let deferred_at = fn(now, provider_failovers) {
    @workflow.work_order_portfolio(
      projection_report(parts=[
        portfolio_part(
          @workflow.PartWorkflowStage::PartRecoveryUncertain,
          "spent",
          availability=Some(
            @control.ProviderAvailability::ProviderAllowanceExhausted(None),
          ),
          observed_at=1_000L,
          provider_failovers~,
        ),
      ]),
      now,
    ).provider_deferred
  }
  assert_eq(deferred_at(1_059L, []), 1)
  assert_eq(deferred_at(1_060L, []), 0)
  // A Part that already left this surface once and came back waits longer the
  // second time, because each deferral of the same surface backs off.
  let returned : Array[@workflow.PartProviderFailover] = [
    {
      from_surface: @control.ProviderSurfaceId::CodexSubscriptionCli,
      to_surface: @control.ProviderSurfaceId::ClaudeSubscriptionCli,
      cause: @control.ProviderAvailability::ProviderAllowanceExhausted(None),
      retry_ordinal: 1,
      decided_at: 500L,
    },
  ]
  assert_eq(deferred_at(1_060L, returned), 1)
  assert_eq(deferred_at(1_119L, returned), 1)
  assert_eq(deferred_at(1_120L, returned), 0)
}

///|
/// A Part the machine would move is not a Part that is waiting.
///
/// `plan_part_recovery_retry` fails a Part whose surface reported a spent
/// allowance over to another admitted surface, so counting it as waiting would
/// report a Goal as blocked on a provider it is about to stop using. The
/// report asks `select_admitted_provider_surface` the same question the
/// recovery decision does.
test "a Part with somewhere else to run is not counted as waiting" {
  let claude = @control.ProviderSurfaceId::ClaudeSubscriptionCli
  let codex = @control.ProviderSurfaceId::CodexSubscriptionCli
  let spent = @control.ProviderAvailability::ProviderAllowanceExhausted(None)
  let deferred_with = fn(
    admitted : Array[@control.ProviderSurfaceId],
    provider_failovers : Array[@workflow.PartProviderFailover],
  ) {
    @workflow.work_order_portfolio(
      projection_report(parts=[
        portfolio_part(
          @workflow.PartWorkflowStage::PartRecoveryUncertain,
          "moving",
          availability=Some(spent),
          observed_at=1_000L,
          admitted_provider_surfaces=admitted,
          provider_failovers~,
        ),
      ]),
      1_010L,
    ).provider_deferred
  }
  // Its own surface is the only one it may run on, so it waits.
  assert_eq(deferred_with([codex], []), 1)
  // Claude is admitted and has said nothing, so the retry moves there instead.
  assert_eq(deferred_with([codex, claude], []), 0)
  // Claude said the same thing when this Part left it, and that memory is
  // still inside its own re-check interval: there is nowhere to go after all.
  let left_claude : Array[@workflow.PartProviderFailover] = [
    {
      from_surface: claude,
      to_surface: codex,
      cause: spent,
      retry_ordinal: 1,
      decided_at: 1_000L,
    },
  ]
  assert_eq(deferred_with([codex, claude], left_claude), 1)
}

///|
/// Waiting on a provider is one count with two causes, and the Goal's own
/// ceiling bounds the capacity one.
///
/// The lease record is the authority on who is dispatching: a Part holding a
/// slot is being served by the full surface rather than starved by it. And
/// `maximum_parallel_parts` is what decides how many of a Goal's Parts may
/// dispatch at once, so Parts queued behind that ceiling are waiting on the
/// Goal rather than on the surface.
test "capacity waiting is bounded by the Goal's own parallelism ceiling" {
  let codex = @control.ProviderSurfaceId::CodexSubscriptionCli
  let full : Array[@workflow.ProviderSurfaceCapacityStatus] = [
    { surface: codex, held: 2, capacity: 2, deferred_until: None },
  ]
  let pending = fn(id) {
    portfolio_part(@workflow.PartWorkflowStage::PartAccepted, id)
  }
  let waiting_with = fn(maximum_parallel_parts, parts) {
    @workflow.work_order_portfolio(
      projection_report(parts~, maximum_parallel_parts~, provider_capacity=full),
      1_000L,
    ).provider_deferred
  }
  // Three Parts want the surface and the Goal may run two at once, so one of
  // them is queued behind the Goal rather than behind Claude.
  assert_eq(waiting_with(2, [pending("a"), pending("b"), pending("c")]), 2)
  assert_eq(waiting_with(1, [pending("a"), pending("b"), pending("c")]), 1)
  // One of the held slots is this Goal's: that Part is running, and it also
  // spends one of the Goal's own two slots.
  assert_eq(
    waiting_with(2, [
      { ..pending("a"), leased_provider_surface: Some(codex) },
      pending("b"),
      pending("c"),
    ]),
    1,
  )
  // With room to spare in the Goal's ceiling, the lease is the only thing
  // separating the Part that is running on the full surface from the one
  // waiting for it.
  assert_eq(
    waiting_with(4, [
      { ..pending("a"), leased_provider_surface: Some(codex) },
      pending("b"),
    ]),
    1,
  )
  // A finished Part is not waiting for anything.
  assert_eq(
    waiting_with(2, [
      portfolio_part(@workflow.PartWorkflowStage::PartIntegrated, "done"),
      pending("b"),
    ]),
    1,
  )
  // Room on the surface is the difference: same Parts, nothing to wait for.
  assert_eq(
    @workflow.work_order_portfolio(
      projection_report(
        parts=[pending("a"), pending("b")],
        maximum_parallel_parts=2,
        provider_capacity=[
          { surface: codex, held: 1, capacity: 2, deferred_until: None },
        ],
      ),
      1_000L,
    ).provider_deferred,
    0,
  )
}

///|
test "the portfolio reports the target and deadline it is measured against" {
  let budget = @workflow.accept_work_order_budget(
    @workflow.WorkOrderStopRequest::WorkOrderRequestFirstOf([
      @workflow.WorkOrderStopRequest::WorkOrderRequestRelativeSeconds(3_600L),
      @workflow.WorkOrderStopRequest::WorkOrderRequestDeliveredQuota(
        @workflow.WorkOrderQuotaBasis::WorkOrderPrimaryTargets,
        5,
      ),
    ]),
    @workflow.WorkOrderCutoffPolicy::WorkOrderDrainToSafeBoundary,
    1_000L,
  ).unwrap()
  // Both are read out of a compound policy, not just whichever came first.
  let portfolio = @workflow.work_order_portfolio(
    projection_report(work_order=Some(budget)),
    1_000L,
  )
  assert_eq(portfolio.target, Some(5))
  assert_eq(portfolio.deadline, Some(4_600L))
  assert_eq(portfolio.terminal_reason, None)
  // Once stopped, the reason is typed rather than inferred from the counts.
  let stopped = @workflow.work_order_portfolio(
    projection_report(
      work_order=Some(@workflow.record_work_order_stop(budget, 4_600L)),
    ),
    4_600L,
  )
  assert_eq(
    stopped.terminal_reason,
    Some(@workflow.WorkOrderStopReason::WorkOrderDeadlineReached),
  )
}
