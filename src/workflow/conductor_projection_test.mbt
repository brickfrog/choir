///|
fn projection_part(
  stage : @workflow.PartWorkflowStage,
  durable_version? : Int = 11,
  effect_receipt_count? : Int = 3,
) -> @workflow.GoalPartStatus {
  {
    workflow_id: "wf-part-a",
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
    integration_receipt_present: false,
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
    maximum_parallel_parts: 1,
    active_policy_revision: {
      id: @control.RevisionId("revision-1"),
      goal_id,
      parent_revision_id: None,
      ordinal: 1,
      change: @workflow.GoalPolicyChange::GoalPolicyInitial,
      maximum_parallel_parts: 1,
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
    pull_request_state: None,
    pull_request_receipt_present: false,
    pull_request_number: None,
    pull_request_url: None,
    finalization_id: None,
    readiness_decision: None,
    readiness_observation_sequence: None,
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
test "park releases only for terminal Goal states" {
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
  assert_true(
    @workflow.conductor_park_for_goal_state(
      Some(@workflow.GoalExecutionState::GoalExecutionCanceling),
    ),
  )
  assert_true(
    @workflow.conductor_park_for_goal_state(
      Some(@workflow.GoalExecutionState::GoalExecutionRunning),
    ),
  )
  // Awaiting a human merge releases the park: no further durable event
  // arrives until someone merges, so the Conductor must not sleep on it.
  assert_false(
    @workflow.conductor_park_for_goal_state(
      Some(@workflow.GoalExecutionState::GoalExecutionAwaitingMerge),
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
    @workflow.conductor_goal_display(
      projection_report(
        state=@workflow.GoalExecutionState::GoalExecutionSucceeded,
      ),
    )
    is None,
  )
  assert_true(
    @workflow.conductor_goal_display(
      projection_report(
        state=@workflow.GoalExecutionState::GoalExecutionCanceled,
      ),
    )
    is None,
  )
  let active = @workflow.conductor_goal_display(projection_report()).unwrap()
  assert_eq(active.total_parts, 1)
  assert_eq(active.implementation_parts, 1)
  assert_eq(active.attention, None)
  assert_eq(active.single_part_id, Some("part-a"))
  let blocked = @workflow.conductor_goal_display(
    projection_report(parts=[
      projection_part(@workflow.PartWorkflowStage::PartBlocked),
    ]),
  ).unwrap()
  assert_eq(
    blocked.attention,
    Some(@workflow.ConductorGoalAttention::ConductorAttentionBlocked),
  )
  assert_eq(blocked.attention_target, Some("part-a"))
  let awaiting = @workflow.conductor_goal_display(
    projection_report(
      state=@workflow.GoalExecutionState::GoalExecutionAwaitingMerge,
      parts=[projection_part(@workflow.PartWorkflowStage::PartIntegrated)],
    ),
  ).unwrap()
  assert_eq(
    awaiting.phase,
    @workflow.ConductorGoalPhase::ConductorPhaseAwaitMerge,
  )
  assert_eq(awaiting.attention, None)
  let paused = @workflow.conductor_goal_display(
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
