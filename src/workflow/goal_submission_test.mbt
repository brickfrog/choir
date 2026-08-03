///|
let submission_digest : @control.Digest = @control.Digest(
  "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
)

///|
let submission_process_digest : @control.Digest = @control.Digest(
  "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
)

///|
fn submission_contract(
  goal_id : @control.GoalId,
  part_id : @control.PartId,
  declaration : @control.MutationDeclaration,
) -> @control.TaskContractRevision {
  {
    id: @control.RevisionId("revision-" + part_id.0),
    goal_id,
    part_id,
    revision: 1,
    digest: submission_digest,
    commit_title: @control.SemanticCommitTitle("test: submit Goal"),
    repair_conflict_id: None,
    repair_audit: None,
    repair_verification: None,
    instruction_artifact: {
      artifact_id: "instruction-" + part_id.0,
      digest: submission_digest,
    },
    base_commit_oid: @control.GitOid("base-commit"),
    base_tree_oid: @control.GitOid("base-tree"),
    path_mode: @control.RepositoryPathMode::CaseSensitiveNfc,
    mutation_declaration: declaration,
    verification_specs: [
      {
        id: @control.VerificationSpecId("verify-" + part_id.0),
        version: 1,
        digest: submission_digest,
        process_spec_digest: submission_process_digest,
      },
    ],
    audit_policy_digest: submission_digest,
    implementation_capability_profile_digest: submission_digest,
    verification_capability_profile_digest: submission_digest,
    audit_capability_profile_digest: submission_digest,
  }
}

///|
fn submission_source(
  id : String,
  dependencies : Array[@control.PartId],
  state : @workflow.SelectionSourceState,
) -> @workflow.GoalSelectionSourcePart {
  {
    part_id: @control.PartId(id),
    source_revision_digest: submission_digest,
    source_content_digest: submission_digest,
    dependency_ids: dependencies,
    state,
  }
}

///|
fn submission_part(
  goal_id : @control.GoalId,
  id : String,
  dependencies : Array[@control.PartId],
  surface : @control.ProviderSurfaceId,
) -> @workflow.ConductorPartProposal {
  let part_id = @control.PartId(id)
  {
    part_id,
    source_revision_digest: submission_digest,
    source_content_digest: submission_digest,
    dependency_ids: dependencies,
    task_contract: submission_contract(
      goal_id,
      part_id,
      @control.MutationDeclaration::CompleteMutationDeclaration([
        @control.MutationClaim::ExactPath(
          @control.RepoPath("src/" + id + ".mbt"),
        ),
      ]),
    ),
    provider_surface: surface,
    provider_failover_surfaces: [],
  }
}

///|
fn submission_snapshot(
  parts : Array[@workflow.GoalSelectionSourcePart],
) -> @workflow.GoalSelectionSnapshot {
  {
    repository_id: @workflow.RepositoryId("repository-test"),
    base_commit_oid: @control.GitOid("base-commit"),
    base_tree_oid: @control.GitOid("base-tree"),
    parts,
  }
}

///|
fn submission_proposal(
  goal_id : @control.GoalId,
  parts : Array[@workflow.ConductorPartProposal],
) -> @workflow.GoalProposal {
  {
    id: @workflow.GoalProposalId("proposal-test"),
    goal_id,
    conductor_draft_digest: submission_digest,
    repository_id: @workflow.RepositoryId("repository-test"),
    base_ref: @workflow.GitRefName("refs/heads/main"),
    expected_base_commit_oid: @control.GitOid("base-commit"),
    expected_base_tree_oid: @control.GitOid("base-tree"),
    integration_target_ref: @workflow.GitRefName("refs/heads/main"),
    selection_policy: @workflow.GoalSelectionPolicy::ExactClosure,
    completion_mode: @workflow.GoalCompletionMode::GoalPublishable,
    pull_request_document: Some({
      title: "test: evaluate Goal submission",
      body: "Exercises Goal submission.",
      draft: false,
    }),
    maximum_parallel_parts: 2,
    parts,
    work_order_id: None,
    work_order_planning_round_id: None,
    work_order_objective: None,
    work_order_selection_policy: None,
    work_order_planner: None,
    work_order_primary_target_ids: parts.map(fn(part) { part.part_id }),
    work_order_budget: None,
  }
}

///|
fn dependency_delivery_observation(
  goal_id : String,
  claimed_part_ids : Array[@control.PartId],
  state : @workflow.GoalDependencyDeliveryState,
) -> @workflow.GoalDependencyDeliveryObservation {
  let id = @control.GoalId(goal_id)
  {
    goal_id: id,
    goal_ref: @workflow.goal_execution_ref(id),
    claimed_part_ids,
    state,
  }
}

///|
test "Goal submission stacks only on an open dependency Goal" {
  let dependency_id = @control.PartId("dependency")
  let child_id = @control.PartId("child")
  let snapshot = submission_snapshot([
    submission_source(
      "dependency",
      [],
      @workflow.SelectionSourceState::SelectionSourceClosed,
    ),
    submission_source(
      "child",
      [dependency_id],
      @workflow.SelectionSourceState::SelectionSourceOpen,
    ),
  ])
  let integration_target = @workflow.GitRefName("refs/heads/main")
  let open = dependency_delivery_observation(
    "goal-parent",
    [dependency_id],
    @workflow.GoalDependencyDeliveryState::GoalDependencyPullRequestOpen,
  )
  assert_eq(
    @workflow.select_goal_submission_base(
      snapshot,
      [child_id],
      integration_target,
      [open],
    ),
    @workflow.GoalSubmissionBaseDecision::GoalSubmissionStackOnDependencyGoal(
      open.goal_id,
      open.goal_ref,
    ),
  )
  let merged = {
    ..open,
    state: @workflow.GoalDependencyDeliveryState::GoalDependencyPullRequestMerged,
  }
  assert_eq(
    @workflow.select_goal_submission_base(
      snapshot,
      [child_id],
      integration_target,
      [merged],
    ),
    @workflow.GoalSubmissionBaseDecision::GoalSubmissionUseIntegrationTarget(
      integration_target,
    ),
  )
  assert_eq(
    @workflow.select_goal_submission_base(
      snapshot,
      [child_id],
      integration_target,
      [],
    ),
    @workflow.GoalSubmissionBaseDecision::GoalSubmissionUseIntegrationTarget(
      integration_target,
    ),
  )
}

///|
test "Goal submission rejects conflicting refs for one open dependency Goal" {
  let dependency_id = @control.PartId("dependency")
  let child_id = @control.PartId("child")
  let snapshot = submission_snapshot([
    submission_source(
      "dependency",
      [],
      @workflow.SelectionSourceState::SelectionSourceClosed,
    ),
    submission_source(
      "child",
      [dependency_id],
      @workflow.SelectionSourceState::SelectionSourceOpen,
    ),
  ])
  let integration_target = @workflow.GitRefName("refs/heads/main")
  let open = dependency_delivery_observation(
    "goal-parent",
    [dependency_id],
    @workflow.GoalDependencyDeliveryState::GoalDependencyPullRequestOpen,
  )
  assert_eq(
    @workflow.select_goal_submission_base(
      snapshot,
      [child_id],
      integration_target,
      [open, open],
    ),
    @workflow.GoalSubmissionBaseDecision::GoalSubmissionStackOnDependencyGoal(
      open.goal_id,
      open.goal_ref,
    ),
  )
  let conflicting = {
    ..open,
    goal_ref: @workflow.GitRefName("refs/heads/goal-conflict"),
  }
  let expected = @workflow.GoalSubmissionBaseDecision::GoalSubmissionRejectBase(
    @workflow.GoalSubmissionBaseRejection::GoalSubmissionDependencyObservationUncertain([
        open.goal_id,
      ],
    ),
  )
  assert_eq(
    @workflow.select_goal_submission_base(
      snapshot,
      [child_id],
      integration_target,
      [open, conflicting],
    ),
    expected,
  )
  assert_eq(
    @workflow.select_goal_submission_base(
      snapshot,
      [child_id],
      integration_target,
      [conflicting, open],
    ),
    expected,
  )
}

///|
test "Goal submission rejects non-linear and undelivered dependency Goals" {
  let dependency_a = @control.PartId("dependency-a")
  let dependency_b = @control.PartId("dependency-b")
  let child_id = @control.PartId("child")
  let snapshot = submission_snapshot([
    submission_source(
      "dependency-a",
      [],
      @workflow.SelectionSourceState::SelectionSourceClosed,
    ),
    submission_source(
      "dependency-b",
      [],
      @workflow.SelectionSourceState::SelectionSourceClosed,
    ),
    submission_source(
      "child",
      [dependency_a, dependency_b],
      @workflow.SelectionSourceState::SelectionSourceOpen,
    ),
  ])
  let integration_target = @workflow.GitRefName("refs/heads/main")
  let open_a = dependency_delivery_observation(
    "goal-a",
    [dependency_a],
    @workflow.GoalDependencyDeliveryState::GoalDependencyPullRequestOpen,
  )
  let open_b = dependency_delivery_observation(
    "goal-b",
    [dependency_b],
    @workflow.GoalDependencyDeliveryState::GoalDependencyPullRequestOpen,
  )
  assert_eq(
    @workflow.select_goal_submission_base(
      snapshot,
      [child_id],
      integration_target,
      [open_b, open_a],
    ),
    @workflow.GoalSubmissionBaseDecision::GoalSubmissionRejectBase(
      @workflow.GoalSubmissionBaseRejection::GoalSubmissionDependenciesSpanOpenGoals([
          open_a.goal_id,
          open_b.goal_id,
        ],
      ),
    ),
  )
  let same_parent = dependency_delivery_observation(
    "goal-a",
    [dependency_a, dependency_b],
    @workflow.GoalDependencyDeliveryState::GoalDependencyPullRequestOpen,
  )
  assert_eq(
    @workflow.select_goal_submission_base(
      snapshot,
      [child_id],
      integration_target,
      [same_parent],
    ),
    @workflow.GoalSubmissionBaseDecision::GoalSubmissionStackOnDependencyGoal(
      same_parent.goal_id,
      same_parent.goal_ref,
    ),
  )
  let closed = {
    ..open_a,
    state: @workflow.GoalDependencyDeliveryState::GoalDependencyPullRequestClosed,
  }
  assert_eq(
    @workflow.select_goal_submission_base(
      snapshot,
      [child_id],
      integration_target,
      [closed],
    ),
    @workflow.GoalSubmissionBaseDecision::GoalSubmissionRejectBase(
      @workflow.GoalSubmissionBaseRejection::GoalSubmissionDependencyPullRequestClosed([
          open_a.goal_id,
        ],
      ),
    ),
  )
  let uncertain = {
    ..open_a,
    state: @workflow.GoalDependencyDeliveryState::GoalDependencyPullRequestObservationUncertain,
  }
  assert_eq(
    @workflow.select_goal_submission_base(
      snapshot,
      [child_id],
      integration_target,
      [uncertain],
    ),
    @workflow.GoalSubmissionBaseDecision::GoalSubmissionRejectBase(
      @workflow.GoalSubmissionBaseRejection::GoalSubmissionDependencyObservationUncertain([
          open_a.goal_id,
        ],
      ),
    ),
  )
}

///|
test "acceptance captures every provider surface a Part may run on" {
  let goal_id = @control.GoalId("goal-failover-test")
  let base = submission_part(
    goal_id,
    "failover-part",
    [],
    @control.ProviderSurfaceId::CodexSubscriptionCli,
  )
  let part = {
    ..base,
    provider_failover_surfaces: [
      @control.ProviderSurfaceId::ClaudeSubscriptionCli,
    ],
  }
  let snapshot = submission_snapshot([
    submission_source(
      "failover-part",
      [],
      @workflow.SelectionSourceState::SelectionSourceOpen,
    ),
  ])
  let decision = @workflow.evaluate_goal_proposal(
    submission_proposal(goal_id, [part]),
    snapshot,
    fn(_) { true },
  ).unwrap()
  assert_eq(
    decision.outcome,
    @workflow.GoalSelectionOutcome::GoalSelectionAccepted,
  )
  // The admitted set travels to acceptance intact, so the Part's Takes carry
  // the authority the proposal stated rather than a host default.
  assert_eq(decision.accepted_parts[0].provider_failover_surfaces, [
    @control.ProviderSurfaceId::ClaudeSubscriptionCli,
  ])
  assert_eq(
    @workflow.accepted_part_admitted_surfaces(decision.accepted_parts[0]),
    [
      @control.ProviderSurfaceId::CodexSubscriptionCli,
      @control.ProviderSurfaceId::ClaudeSubscriptionCli,
    ],
  )
  // A Part admitted under one provider is a different contract than the same
  // Part admitted under two, so the proposal digest has to separate them.
  assert_true(
    @workflow.goal_proposal_digest(submission_proposal(goal_id, [part])) !=
    @workflow.goal_proposal_digest(submission_proposal(goal_id, [base])),
  )
  let admitted_once = @workflow.evaluate_goal_proposal(
    submission_proposal(goal_id, [base]),
    snapshot,
    fn(_) { true },
  ).unwrap()
  assert_eq(admitted_once.accepted_parts[0].provider_failover_surfaces, [])
}

///|
fn submission_execution() -> @workflow.GoalExecutionRecord {
  let goal_id = @control.GoalId("goal-policy-test")
  let part = submission_part(
    goal_id,
    "policy-part",
    [],
    @control.ProviderSurfaceId::CodexSubscriptionCli,
  )
  let decision = @workflow.evaluate_goal_proposal(
    submission_proposal(goal_id, [part]),
    submission_snapshot([
      submission_source(
        "policy-part",
        [],
        @workflow.SelectionSourceState::SelectionSourceOpen,
      ),
    ]),
    fn(_) { true },
  ).unwrap()
  @workflow.goal_execution_record_from_selection(
    decision,
    @workflow.goal_selection_decision_digest(decision),
    ["workflow-policy-part"],
  ).unwrap()
}

///|
test "execution records are created with the caller's fencing epoch" {
  let record = submission_execution()
  assert_eq(record.fencing_epoch, @control.FencingEpoch(1L))
  let goal_id = @control.GoalId("goal-epoch-test")
  let part = submission_part(
    goal_id,
    "epoch-part",
    [],
    @control.ProviderSurfaceId::CodexSubscriptionCli,
  )
  let decision = @workflow.evaluate_goal_proposal(
    submission_proposal(goal_id, [part]),
    submission_snapshot([
      submission_source(
        "epoch-part",
        [],
        @workflow.SelectionSourceState::SelectionSourceOpen,
      ),
    ]),
    fn(_) { true },
  ).unwrap()
  let minted = @workflow.goal_execution_record_from_selection(
    decision,
    @workflow.goal_selection_decision_digest(decision),
    ["workflow-epoch-part"],
    fencing_epoch=@control.FencingEpoch(7L),
  ).unwrap()
  assert_eq(minted.fencing_epoch, @control.FencingEpoch(7L))
}

///|
test "fencing adoption raises the epoch and rejects non-increases" {
  let record = submission_execution()
  let adopted = @workflow.adopt_goal_execution_fencing_epoch(
    record,
    @control.FencingEpoch(3L),
  ).unwrap()
  assert_eq(adopted.fencing_epoch, @control.FencingEpoch(3L))
  assert_eq(adopted.durable_version, record.durable_version + 1)
  assert_true(
    @workflow.adopt_goal_execution_fencing_epoch(
      adopted,
      @control.FencingEpoch(3L),
    )
    is Err(_),
  )
  assert_true(
    @workflow.adopt_goal_execution_fencing_epoch(
      record,
      @control.FencingEpoch(1L),
    )
    is Err(_),
  )
}

///|
fn submission_claimed_running(
  running : @workflow.GoalExecutionRecord,
) -> @workflow.GoalExecutionRecord {
  let mut claimed = running
  for claim in running.source_claims {
    claimed = @workflow.authorize_goal_source_claim(claimed, claim.part_id).unwrap()
    claimed = @workflow.reconcile_goal_source_claim(
      claimed,
      claim.part_id,
      @workflow.GoalSourceClaimObservation::GoalSourceClaimedByExpectedActor,
      1L,
    ).unwrap()
  }
  claimed
}

///|
fn submission_initialized_running(
  running : @workflow.GoalExecutionRecord,
) -> @workflow.GoalExecutionRecord raise {
  let claimed = submission_claimed_running(running)
  let authorized = @workflow.authorize_goal_branch_initialization(claimed).unwrap()
  guard @workflow.reconcile_goal_branch_initialization(
      authorized,
      @workflow.GoalBranchInitObservation::GoalBranchInitRefsAtBase,
      1L,
    ).unwrap()
    is @workflow.GoalBranchInitReconciliation::GoalBranchInitObservationRecorded(
      initialized
    ) else {
    fail("Goal branch initialization did not receipt")
  }
  initialized
}

///|
test "source claim must be receipted before branch initialization" {
  let running = @workflow.advance_goal_execution_state(
    submission_execution(),
    @workflow.GoalExecutionState::GoalExecutionRunning,
  ).unwrap()
  assert_true(@workflow.authorize_goal_branch_initialization(running) is Err(_))
  let claim = running.source_claims[0]
  let authorized = @workflow.authorize_goal_source_claim(running, claim.part_id).unwrap()
  let receipted = @workflow.reconcile_goal_source_claim(
    authorized,
    claim.part_id,
    @workflow.GoalSourceClaimObservation::GoalSourceClaimedByExpectedActor,
    10L,
  ).unwrap()
  assert_true(@workflow.goal_source_claims_are_receipted(receipted))
  assert_true(
    @workflow.authorize_goal_branch_initialization(receipted) is Ok(_),
  )
}

///|
test "source drift records a typed conflict without minting a receipt" {
  let running = @workflow.advance_goal_execution_state(
    submission_execution(),
    @workflow.GoalExecutionState::GoalExecutionRunning,
  ).unwrap()
  let claim = running.source_claims[0]
  let authorized = @workflow.authorize_goal_source_claim(running, claim.part_id).unwrap()
  let conflicted = @workflow.reconcile_goal_source_claim(
    authorized,
    claim.part_id,
    @workflow.GoalSourceClaimObservation::GoalSourceContentDrifted,
    10L,
  ).unwrap()
  assert_eq(conflicted.durable_version, authorized.durable_version + 1)
  assert_true(@workflow.goal_source_claims_have_conflict(conflicted))
  assert_eq(conflicted.source_claims[0].receipt, None)
  assert_eq(
    conflicted.source_claims[0].lifecycle,
    @workflow.GoalSourceClaimLifecycle::GoalSourceClaimConflict(
      @workflow.GoalSourceClaimConflictReason::GoalSourceClaimContentDrift,
    ),
  )
  assert_eq(
    conflicted.state,
    @workflow.GoalExecutionState::GoalExecutionCanceling,
  )
  assert_eq(
    conflicted.cancellation_request.map(fn(request) { request.cause }),
    Some(
      @workflow.GoalCancellationCause::GoalCancellationSourceClaimBlocked(
        claim.part_id,
        @workflow.GoalSourceClaimConflictReason::GoalSourceClaimContentDrift,
      ),
    ),
  )
}

///|
test "partial source delivery preserves earlier receipts when a later Part conflicts" {
  let goal_id = @control.GoalId("goal-partial-claims")
  let decision = @workflow.evaluate_goal_proposal(
    submission_proposal(goal_id, [
      submission_part(
        goal_id,
        "a",
        [],
        @control.ProviderSurfaceId::CodexSubscriptionCli,
      ),
      submission_part(
        goal_id,
        "b",
        [],
        @control.ProviderSurfaceId::ClaudeSubscriptionCli,
      ),
    ]),
    submission_snapshot([
      submission_source(
        "a",
        [],
        @workflow.SelectionSourceState::SelectionSourceOpen,
      ),
      submission_source(
        "b",
        [],
        @workflow.SelectionSourceState::SelectionSourceOpen,
      ),
    ]),
    fn(_) { true },
  ).unwrap()
  let queued = @workflow.goal_execution_record_from_selection(
    decision,
    @workflow.goal_selection_decision_digest(decision),
    ["workflow-a", "workflow-b"],
  ).unwrap()
  let running = @workflow.advance_goal_execution_state(
    queued,
    @workflow.GoalExecutionState::GoalExecutionRunning,
  ).unwrap()
  let first = @workflow.authorize_goal_source_claim(
    running,
    @control.PartId("a"),
  ).unwrap()
  let first_receipted = @workflow.reconcile_goal_source_claim(
    first,
    @control.PartId("a"),
    @workflow.GoalSourceClaimObservation::GoalSourceClaimedByExpectedActor,
    10L,
  ).unwrap()
  let second = @workflow.authorize_goal_source_claim(
    first_receipted,
    @control.PartId("b"),
  ).unwrap()
  let conflicted = @workflow.reconcile_goal_source_claim(
    second,
    @control.PartId("b"),
    @workflow.GoalSourceClaimObservation::GoalSourceClaimedByAnotherActor,
    11L,
  ).unwrap()
  assert_eq(
    conflicted.source_claims[0].lifecycle,
    @workflow.GoalSourceClaimLifecycle::GoalSourceClaimReceipted,
  )
  assert_true(conflicted.source_claims[0].receipt is Some(_))
  assert_true(@workflow.goal_source_claims_have_conflict(conflicted))
  assert_eq(
    conflicted.state,
    @workflow.GoalExecutionState::GoalExecutionCanceling,
  )
}

///|
test "cancellation cannot finish until Choir-owned source claims are released" {
  let running = @workflow.advance_goal_execution_state(
    submission_execution(),
    @workflow.GoalExecutionState::GoalExecutionRunning,
  ).unwrap()
  let part_id = running.source_claims[0].part_id
  let authorized = @workflow.authorize_goal_source_claim(running, part_id).unwrap()
  let claimed = @workflow.reconcile_goal_source_claim(
    authorized,
    part_id,
    @workflow.GoalSourceClaimObservation::GoalSourceClaimedByExpectedActor,
    10L,
  ).unwrap()
  guard @workflow.request_goal_execution_cancellation(claimed, 11L).unwrap()
    is @workflow.GoalCancellationDecision::GoalCancellationRequested(canceling) else {
    fail("cancellation was not requested")
  }
  assert_true(@workflow.commit_goal_execution_cancellation(canceling) is Err(_))
  let release = @workflow.authorize_goal_source_release(canceling, part_id).unwrap()
  let released = @workflow.reconcile_goal_source_release(
    release,
    part_id,
    @workflow.GoalSourceClaimObservation::GoalSourceUnclaimedExact,
    12L,
  ).unwrap()
  assert_true(@workflow.goal_source_release_dispositions_are_known(released))
  assert_true(@workflow.commit_goal_execution_cancellation(released) is Ok(_))
}

///|
test "Goal scheduling policy changes form a durable revision chain" {
  let queued = submission_execution()
  assert_eq(queued.policy_revisions.length(), 1)
  assert_eq(
    queued.policy_revisions[0].change,
    @workflow.GoalPolicyChange::GoalPolicyInitial,
  )
  let running = @workflow.advance_goal_execution_state(
    queued,
    @workflow.GoalExecutionState::GoalExecutionRunning,
  ).unwrap()
  guard @workflow.steer_goal_execution(
      running,
      @workflow.GoalPolicyChange::GoalPolicySetMaximumParallelParts(4),
    ).unwrap()
    is @workflow.GoalSteeringDecision::GoalSteeringApplied(
      concurrent,
      concurrency_revision
    ) else {
    fail("concurrency steering did not apply")
  }
  assert_eq(concurrent.maximum_parallel_parts, 4)
  assert_eq(concurrent.policy_revisions.length(), 2)
  assert_eq(concurrency_revision.ordinal, 2)
  assert_eq(
    concurrency_revision.parent_revision_id,
    Some(running.policy_revisions[0].id),
  )
  guard @workflow.steer_goal_execution(
      concurrent,
      @workflow.GoalPolicyChange::GoalPolicyPause,
    ).unwrap()
    is @workflow.GoalSteeringDecision::GoalSteeringApplied(
      paused,
      pause_revision
    ) else {
    fail("pause steering did not apply")
  }
  assert_eq(paused.state, @workflow.GoalExecutionState::GoalExecutionPaused)
  assert_eq(
    paused.pause,
    Some({
      reason: @workflow.GoalPauseReason::GoalPauseRequested,
      resume_state: @workflow.GoalExecutionState::GoalExecutionRunning,
    }),
  )
  assert_eq(
    paused.goal.lifecycle,
    @control.GoalLifecycle::GoalActive(
      @control.GoalActiveCondition::GoalNeedsInput,
    ),
  )
  assert_eq(pause_revision.ordinal, 3)
  guard @workflow.steer_goal_execution(
      paused,
      @workflow.GoalPolicyChange::GoalPolicyResume,
    ).unwrap()
    is @workflow.GoalSteeringDecision::GoalSteeringApplied(
      resumed,
      resume_revision
    ) else {
    fail("resume steering did not apply")
  }
  assert_eq(resumed.state, @workflow.GoalExecutionState::GoalExecutionRunning)
  assert_eq(resumed.pause, None)
  assert_eq(resumed.maximum_parallel_parts, 4)
  assert_eq(resume_revision.ordinal, 4)
  assert_eq(
    @workflow.decode_goal_execution_record(
      @workflow.goal_execution_record_bytes(resumed),
    ).unwrap(),
    resumed,
  )
}

///|
/// A stored execution record with every optional field populated.
///
/// No point of the workflow has all of them at once — a record is not
/// simultaneously paused for input, canceling, and budgeted — so each comes
/// from the constructor that produces it rather than from a literal. It exists
/// so the durable shape manifest can be checked against a record that has every
/// key, which is what makes an option quietly left at `None` in the witness
/// visible.
fn maximal_goal_execution_record() -> @workflow.GoalExecutionRecord raise {
  let running = submission_initialized_running(
    @workflow.advance_goal_execution_state(
      submission_execution(),
      @workflow.GoalExecutionState::GoalExecutionRunning,
    ).unwrap(),
  )
  let assured = @workflow.advance_goal_execution_state(
    @workflow.advance_goal_execution_state(
      running,
      @workflow.GoalExecutionState::GoalExecutionAssuring,
    ).unwrap(),
    @workflow.GoalExecutionState::GoalExecutionAssured,
  ).unwrap()
  guard @workflow.request_goal_execution_input(
      assured,
      @workflow.GoalInputReason::GoalInputFinalizationNeedsUserInput,
    ).unwrap()
    is @workflow.GoalInputRequestDecision::GoalInputRequestCreated(paused, _) else {
    fail("input request was not created")
  }
  guard @workflow.request_goal_execution_cancellation(paused, 100L).unwrap()
    is @workflow.GoalCancellationDecision::GoalCancellationRequested(canceling) else {
    fail("cancellation was not requested")
  }
  {
    ..canceling,
    pause: paused.pause,
    active_input_request: paused.active_input_request,
    work_order_id: Some(@workflow.WorkOrderId("work-order-maximal")),
  }
}

///|
test "Goal policy steering is idempotent and distinguishes recovery pause" {
  let queued = submission_execution()
  guard @workflow.steer_goal_execution(
      queued,
      @workflow.GoalPolicyChange::GoalPolicySetMaximumParallelParts(2),
    ).unwrap()
    is @workflow.GoalSteeringDecision::GoalSteeringUnchanged(_) else {
    fail("equal concurrency was not a no-op")
  }
  let running = @workflow.advance_goal_execution_state(
    queued,
    @workflow.GoalExecutionState::GoalExecutionRunning,
  ).unwrap()
  let recovery = @workflow.advance_goal_execution_state(
    running,
    @workflow.GoalExecutionState::GoalExecutionPaused,
  ).unwrap()
  assert_eq(
    recovery.pause,
    Some({
      reason: @workflow.GoalPauseReason::GoalPauseRecoveryUncertain,
      resume_state: @workflow.GoalExecutionState::GoalExecutionRunning,
    }),
  )
  assert_eq(
    recovery.goal.lifecycle,
    @control.GoalLifecycle::GoalActive(
      @control.GoalActiveCondition::GoalRecoveryUncertain,
    ),
  )
  guard @workflow.steer_goal_execution(
      recovery,
      @workflow.GoalPolicyChange::GoalPolicyResume,
    ).unwrap()
    is @workflow.GoalSteeringDecision::GoalSteeringApplied(resumed, _) else {
    fail("recovery pause did not resume explicitly")
  }
  assert_eq(resumed.state, @workflow.GoalExecutionState::GoalExecutionRunning)
}

///|
test "Goal input requests require their exact durable answer before resuming" {
  let queued = submission_execution()
  let running = submission_initialized_running(
    @workflow.advance_goal_execution_state(
      queued,
      @workflow.GoalExecutionState::GoalExecutionRunning,
    ).unwrap(),
  )
  let assuring = @workflow.advance_goal_execution_state(
    running,
    @workflow.GoalExecutionState::GoalExecutionAssuring,
  ).unwrap()
  let assured = @workflow.advance_goal_execution_state(
    assuring,
    @workflow.GoalExecutionState::GoalExecutionAssured,
  ).unwrap()
  guard @workflow.request_goal_execution_input(
      assured,
      @workflow.GoalInputReason::GoalInputFinalizationNeedsUserInput,
    ).unwrap()
    is @workflow.GoalInputRequestDecision::GoalInputRequestCreated(
      paused,
      request
    ) else {
    fail("input request was not created")
  }
  assert_eq(paused.state, @workflow.GoalExecutionState::GoalExecutionPaused)
  assert_eq(paused.active_input_request, Some(request))
  assert_true(
    @workflow.steer_goal_execution(
      paused,
      @workflow.GoalPolicyChange::GoalPolicyResume,
    )
    is Err(_),
  )
  let answer_digest = @storage.artifact_digest(@utf8.encode("reopened"))
  let answer_artifact : @control.ArtifactReference = {
    artifact_id: "sha256:" + @storage.digest_text(answer_digest),
    digest: answer_digest,
  }
  guard @workflow.answer_goal_execution_input(
      paused,
      request.id,
      answer_artifact,
      10L,
    ).unwrap()
    is @workflow.GoalInputAnswerDecision::GoalInputAnswerApplied(
      resumed,
      answer
    ) else {
    fail("input answer did not apply")
  }
  assert_eq(resumed.state, @workflow.GoalExecutionState::GoalExecutionAssured)
  assert_eq(resumed.active_input_request, None)
  assert_eq(resumed.input_answers, [answer])
  guard @workflow.answer_goal_execution_input(
      resumed,
      request.id,
      answer_artifact,
      11L,
    ).unwrap()
    is @workflow.GoalInputAnswerDecision::GoalInputAnswerReplayed(replayed, _) else {
    fail("input answer did not replay")
  }
  assert_eq(replayed, resumed)
  assert_eq(
    @workflow.decode_goal_execution_record(
      @workflow.goal_execution_record_bytes(resumed),
    ).unwrap(),
    resumed,
  )
}

///|
test "Conductor proposal accepts exact closure in deterministic order" {
  let goal_id = @control.GoalId("goal-submission")
  let part_a = submission_part(
    goal_id,
    "a",
    [],
    @control.ProviderSurfaceId::ClaudeSubscriptionCli,
  )
  let part_b = submission_part(
    goal_id,
    "b",
    [part_a.part_id],
    @control.ProviderSurfaceId::CodexSubscriptionCli,
  )
  let snapshot = submission_snapshot([
    submission_source(
      "b",
      [part_a.part_id],
      @workflow.SelectionSourceState::SelectionSourceOpen,
    ),
    submission_source(
      "a",
      [],
      @workflow.SelectionSourceState::SelectionSourceOpen,
    ),
  ])
  let decision = match
    @workflow.evaluate_goal_proposal(
      submission_proposal(goal_id, [part_b, part_a]),
      snapshot,
      fn(_) { true },
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(
    decision.outcome,
    @workflow.GoalSelectionOutcome::GoalSelectionAccepted,
  )
  assert_eq(decision.accepted_parts.map(fn(part) { part.part.id }), [
    part_a.part_id,
    part_b.part_id,
  ])
  assert_eq(decision.primary_target_ids, [part_a.part_id, part_b.part_id])
  assert_eq(decision.prerequisite_closure_ids, [])
  assert_eq(decision.rejections, [])
  assert_true(decision.goal is Some(_))
  let decoded = match
    @workflow.decode_goal_selection_decision(
      @workflow.goal_selection_decision_bytes(decision),
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(decoded, decision)
  assert_manifest_names_stored_keys(
    "GoalSelectionDecision",
    @workflow.goal_selection_decision_bytes(decision),
  )
  let queued = match
    @workflow.goal_execution_record_from_selection(
      decision,
      @workflow.goal_selection_decision_digest(decision),
      ["workflow-a", "workflow-b"],
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  let running = match
    @workflow.advance_goal_execution_state(
      queued,
      @workflow.GoalExecutionState::GoalExecutionRunning,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  let running = submission_initialized_running(running)
  assert_true(
    @workflow.advance_goal_execution_state(
      running,
      @workflow.GoalExecutionState::GoalExecutionSucceeded,
    )
    is Err(_),
  )
  let assuring = match
    @workflow.advance_goal_execution_state(
      running,
      @workflow.GoalExecutionState::GoalExecutionAssuring,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  let assured = match
    @workflow.advance_goal_execution_state(
      assuring,
      @workflow.GoalExecutionState::GoalExecutionAssured,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  let succeeded = match
    @workflow.advance_goal_execution_state(
      assured,
      @workflow.GoalExecutionState::GoalExecutionSucceeded,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_true(
    succeeded.goal.lifecycle is @control.GoalLifecycle::GoalSucceeded(_),
  )
  assert_eq(succeeded.durable_version, 11)
  let malformed = {
    ..succeeded,
    goal: {
      ..succeeded.goal,
      lifecycle: @control.GoalLifecycle::GoalActive(
        @control.GoalActiveCondition::GoalRunning,
      ),
    },
  }
  assert_true(
    @workflow.decode_goal_execution_record(
      @workflow.goal_execution_record_bytes(malformed),
    )
    is Err(_),
  )
}

///|
test "WorkOrder selection distinguishes primary targets from prerequisite closure" {
  let goal_id = @control.GoalId("goal-work-order-selection")
  let prerequisite = submission_part(
    goal_id,
    "prerequisite",
    [],
    @control.ProviderSurfaceId::CodexSubscriptionCli,
  )
  let primary = submission_part(
    goal_id,
    "primary",
    [prerequisite.part_id],
    @control.ProviderSurfaceId::CodexSubscriptionCli,
  )
  let base = submission_proposal(goal_id, [primary, prerequisite])
  let id = @workflow.WorkOrderId("work-order-selection")
  let proposal = {
    ..base,
    work_order_id: Some(id),
    work_order_planning_round_id: Some(
      @workflow.WorkOrderPlanningRoundId("round-selection"),
    ),
    work_order_objective: Some("Deliver the primary Bead."),
    work_order_selection_policy: Some(
      @workflow.WorkOrderSelectionPolicy::WorkOrderExactBeadClosure,
    ),
    work_order_planner: Some({
      primary_surface: @control.ProviderSurfaceId::CodexSubscriptionCli,
      failover_surfaces: [],
    }),
    work_order_primary_target_ids: [primary.part_id],
    work_order_budget: Some(
      @workflow.accept_work_order_budget(
        @workflow.WorkOrderStopRequest::WorkOrderRequestSafetyCeiling(8),
        @workflow.WorkOrderCutoffPolicy::WorkOrderDrainToSafeBoundary,
        100L,
      ).unwrap(),
    ),
  }
  let decision = @workflow.evaluate_goal_proposal(
    proposal,
    submission_snapshot([
      submission_source(
        "primary",
        [prerequisite.part_id],
        @workflow.SelectionSourceState::SelectionSourceOpen,
      ),
      submission_source(
        "prerequisite",
        [],
        @workflow.SelectionSourceState::SelectionSourceOpen,
      ),
    ]),
    fn(_) { true },
  ).unwrap()
  assert_eq(decision.primary_target_ids, [primary.part_id])
  assert_eq(decision.prerequisite_closure_ids, [prerequisite.part_id])
  assert_eq(decision.accepted_parts.map(fn(part) { part.part.id }), [
    prerequisite.part_id,
    primary.part_id,
  ])
  let execution = @workflow.goal_execution_record_from_selection(
    decision,
    @workflow.goal_selection_decision_digest(decision),
    ["workflow-prerequisite", "workflow-primary"],
  ).unwrap()
  assert_eq(execution.work_order_id, Some(id))
  let json = @workflow.goal_execution_record_bytes(execution)
  assert_false(@utf8.decode_lossy(json).contains("work_order_budget"))
}

///|
test "Goal cancellation installs one durable cutoff and excludes success" {
  let goal_id = @control.GoalId("goal-cancel")
  let part = submission_part(
    goal_id,
    "a",
    [],
    @control.ProviderSurfaceId::CodexSubscriptionCli,
  )
  let decision = match
    @workflow.evaluate_goal_proposal(
      submission_proposal(goal_id, [part]),
      submission_snapshot([
        submission_source(
          "a",
          [],
          @workflow.SelectionSourceState::SelectionSourceOpen,
        ),
      ]),
      fn(_) { true },
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  let queued = match
    @workflow.goal_execution_record_from_selection(
      decision,
      @workflow.goal_selection_decision_digest(decision),
      ["workflow-a"],
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  let canceling = match
    @workflow.request_goal_execution_cancellation(queued, 1000L) {
    Ok(@workflow.GoalCancellationDecision::GoalCancellationRequested(value)) =>
      value
    Ok(_) => fail("first cancellation did not install a cutoff")
    Err(error) => fail(error.message())
  }
  assert_eq(
    canceling.state,
    @workflow.GoalExecutionState::GoalExecutionCanceling,
  )
  assert_eq(
    canceling.goal.lifecycle,
    @control.GoalLifecycle::GoalCanceling(@control.EventSequence(2L)),
  )
  assert_eq(canceling.durable_version, 2)
  assert_eq(
    canceling.branch_initialization.lifecycle,
    @workflow.GoalBranchInitLifecycle::GoalBranchInitAbandonedByCancellation,
  )
  match @workflow.request_goal_execution_cancellation(canceling, 2000L) {
    Ok(
      @workflow.GoalCancellationDecision::GoalCancellationAlreadyCanceling(
        replayed
      )
    ) => assert_eq(replayed, canceling)
    Ok(_) => fail("cancellation replay changed the cutoff")
    Err(error) => fail(error.message())
  }
  assert_true(
    @workflow.advance_goal_execution_state(
      canceling,
      @workflow.GoalExecutionState::GoalExecutionSucceeded,
    )
    is Err(_),
  )
  let released = @workflow.reconcile_goal_source_release(
    @workflow.authorize_goal_source_release(
      canceling,
      canceling.source_claims[0].part_id,
    ).unwrap(),
    canceling.source_claims[0].part_id,
    @workflow.GoalSourceClaimObservation::GoalSourceUnclaimedExact,
    2001L,
  ).unwrap()
  let canceled = match @workflow.commit_goal_execution_cancellation(released) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(canceled.state, @workflow.GoalExecutionState::GoalExecutionCanceled)
  assert_true(
    canceled.goal.lifecycle is @control.GoalLifecycle::GoalCanceled(_),
  )
  assert_eq(canceled.durable_version, 5)
  match @workflow.request_goal_execution_cancellation(canceled, 3000L) {
    Ok(
      @workflow.GoalCancellationDecision::GoalCancellationAlreadyTerminal(state)
    ) => assert_eq(state, @workflow.GoalExecutionState::GoalExecutionCanceled)
    Ok(_) => fail("terminal cancellation was not reported")
    Err(error) => fail(error.message())
  }
}

///|
test "evidence-only Goal binds completion and cancels only after assurance" {
  let goal_id = @control.GoalId("goal-evidence-only")
  let binding = submission_digest
  let assurance_digest = submission_process_digest
  let part = submission_part(
    goal_id,
    "a",
    [],
    @control.ProviderSurfaceId::CodexSubscriptionCli,
  )
  let proposal = {
    ..submission_proposal(goal_id, [part]),
    completion_mode: @workflow.GoalCompletionMode::GoalEvidenceOnly(binding),
    pull_request_document: None,
  }
  let decision = @workflow.evaluate_goal_proposal(
    proposal,
    submission_snapshot([
      submission_source(
        "a",
        [],
        @workflow.SelectionSourceState::SelectionSourceOpen,
      ),
    ]),
    fn(_) { true },
  ).unwrap()
  let queued = @workflow.goal_execution_record_from_selection(
    decision,
    @workflow.goal_selection_decision_digest(decision),
    ["workflow-a"],
  ).unwrap()
  assert_eq(queued.completion_mode, proposal.completion_mode)
  let running = submission_initialized_running(
    @workflow.advance_goal_execution_state(
      queued,
      @workflow.GoalExecutionState::GoalExecutionRunning,
    ).unwrap(),
  )
  let assuring = @workflow.advance_goal_execution_state(
    running,
    @workflow.GoalExecutionState::GoalExecutionAssuring,
  ).unwrap()
  let assured = @workflow.advance_goal_execution_state(
    assuring,
    @workflow.GoalExecutionState::GoalExecutionAssured,
  ).unwrap()
  assert_true(
    @workflow.advance_goal_execution_state(
      assured,
      @workflow.GoalExecutionState::GoalExecutionSucceeded,
    )
    is Err(_),
  )
  assert_true(
    @workflow.request_goal_execution_cancellation(
      assured,
      100L,
      cause=@workflow.GoalCancellationCause::GoalCancellationEvidenceOnlyCompleted(
        submission_process_digest, assurance_digest,
      ),
    )
    is Err(_),
  )
  guard @workflow.request_goal_execution_cancellation(
      assured,
      100L,
      cause=@workflow.GoalCancellationCause::GoalCancellationEvidenceOnlyCompleted(
        binding, assurance_digest,
      ),
    ).unwrap()
    is @workflow.GoalCancellationDecision::GoalCancellationRequested(canceling) else {
    fail("evidence-only cancellation was not requested")
  }
  assert_eq(
    canceling.cancellation_request.map(fn(request) { request.cause }),
    Some(
      @workflow.GoalCancellationCause::GoalCancellationEvidenceOnlyCompleted(
        binding, assurance_digest,
      ),
    ),
  )
  guard @workflow.request_goal_execution_cancellation(assured, 99L).unwrap()
    is @workflow.GoalCancellationDecision::GoalCancellationRequested(
      user_canceling
    ) else {
    fail("user cancellation did not win")
  }
  guard @workflow.request_goal_execution_cancellation(
      user_canceling,
      100L,
      cause=@workflow.GoalCancellationCause::GoalCancellationEvidenceOnlyCompleted(
        binding, assurance_digest,
      ),
    ).unwrap()
    is @workflow.GoalCancellationDecision::GoalCancellationAlreadyCanceling(
      replayed
    ) else {
    fail("terminal compare-and-set was not replayed")
  }
  assert_eq(
    replayed.cancellation_request.map(fn(request) { request.cause }),
    Some(@workflow.GoalCancellationCause::GoalCancellationUserRequested),
  )
}

///|
test "authorized Goal branch initialization is reconciled through cancellation" {
  let running = @workflow.advance_goal_execution_state(
    submission_execution(),
    @workflow.GoalExecutionState::GoalExecutionRunning,
  ).unwrap()
  let running = submission_claimed_running(running)
  let authorized = @workflow.authorize_goal_branch_initialization(running).unwrap()
  guard @workflow.request_goal_execution_cancellation(authorized, 100L).unwrap()
    is @workflow.GoalCancellationDecision::GoalCancellationRequested(canceling) else {
    fail("cancellation did not preserve authorized initialization")
  }
  assert_eq(
    canceling.branch_initialization.lifecycle,
    @workflow.GoalBranchInitLifecycle::GoalBranchInitAuthorized,
  )
  assert_true(@workflow.commit_goal_execution_cancellation(canceling) is Err(_))
  guard @workflow.reconcile_goal_branch_initialization(
      canceling,
      @workflow.GoalBranchInitObservation::GoalBranchInitRefsAbsent,
      101L,
    ).unwrap()
    is @workflow.GoalBranchInitReconciliation::GoalBranchInitExactRetryAuthorized(
      retry
    ) else {
    fail("absent initialization refs did not authorize exact retry")
  }
  assert_eq(retry, canceling)
  guard @workflow.reconcile_goal_branch_initialization(
      canceling,
      @workflow.GoalBranchInitObservation::GoalBranchInitRefsAtBase,
      102L,
    ).unwrap()
    is @workflow.GoalBranchInitReconciliation::GoalBranchInitObservationRecorded(
      receipted
    ) else {
    fail("applied initialization did not produce a receipt")
  }
  assert_eq(
    receipted.branch_initialization.lifecycle,
    @workflow.GoalBranchInitLifecycle::GoalBranchInitReceipted,
  )
  let released = @workflow.reconcile_goal_source_release(
    @workflow.authorize_goal_source_release(
      receipted,
      receipted.source_claims[0].part_id,
    ).unwrap(),
    receipted.source_claims[0].part_id,
    @workflow.GoalSourceClaimObservation::GoalSourceUnclaimedExact,
    103L,
  ).unwrap()
  assert_true(@workflow.commit_goal_execution_cancellation(released) is Ok(_))
}

///|
test "partial and divergent Goal branch initialization fail closed" {
  let running = @workflow.advance_goal_execution_state(
    submission_execution(),
    @workflow.GoalExecutionState::GoalExecutionRunning,
  ).unwrap()
  let running = submission_claimed_running(running)
  let authorized = @workflow.authorize_goal_branch_initialization(running).unwrap()
  guard @workflow.reconcile_goal_branch_initialization(
      authorized,
      @workflow.GoalBranchInitObservation::GoalBranchInitBranchOnly,
      1L,
    ).unwrap()
    is @workflow.GoalBranchInitReconciliation::GoalBranchInitObservationRecorded(
      blocked
    ) else {
    fail("partial initialization was not recorded")
  }
  assert_eq(blocked.state, @workflow.GoalExecutionState::GoalExecutionCanceling)
  assert_eq(blocked.durable_version, authorized.durable_version + 1)
  assert_eq(
    blocked.branch_initialization.lifecycle,
    @workflow.GoalBranchInitLifecycle::GoalBranchInitIntegrityBlocked,
  )
  assert_eq(
    blocked.cancellation_request.map(fn(request) { request.cause }),
    Some(
      @workflow.GoalCancellationCause::GoalCancellationBranchInitializationBlocked(
        @workflow.GoalBranchInitLifecycle::GoalBranchInitIntegrityBlocked,
      ),
    ),
  )
  guard @workflow.reconcile_goal_branch_initialization(
      authorized,
      @workflow.GoalBranchInitObservation::GoalBranchInitRefsDiverged,
      1L,
    ).unwrap()
    is @workflow.GoalBranchInitReconciliation::GoalBranchInitObservationRecorded(
      uncertain
    ) else {
    fail("divergent initialization was not recorded")
  }
  assert_eq(
    uncertain.state,
    @workflow.GoalExecutionState::GoalExecutionCanceling,
  )
  assert_eq(uncertain.durable_version, authorized.durable_version + 1)
  assert_eq(
    uncertain.branch_initialization.lifecycle,
    @workflow.GoalBranchInitLifecycle::GoalBranchInitUncertain,
  )
  assert_eq(
    uncertain.cancellation_request.map(fn(request) { request.cause }),
    Some(
      @workflow.GoalCancellationCause::GoalCancellationBranchInitializationBlocked(
        @workflow.GoalBranchInitLifecycle::GoalBranchInitUncertain,
      ),
    ),
  )
}

///|
test "duplicate Part identity rejects the proposal before acceptance" {
  let goal_id = @control.GoalId("goal-duplicate")
  let part = submission_part(
    goal_id,
    "a",
    [],
    @control.ProviderSurfaceId::ClaudeSubscriptionCli,
  )
  let decision = match
    @workflow.evaluate_goal_proposal(
      submission_proposal(goal_id, [part, part]),
      submission_snapshot([
        submission_source(
          "a",
          [],
          @workflow.SelectionSourceState::SelectionSourceOpen,
        ),
      ]),
      fn(_) { true },
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(
    decision.outcome,
    @workflow.GoalSelectionOutcome::GoalSelectionRejected,
  )
  assert_eq(decision.accepted_parts, [])
  assert_eq(decision.goal, None)
  assert_eq(decision.rejections.length(), 1)
  assert_true(
    decision.rejections[0].reasons.contains(
      @workflow.SelectionRejectionReason::SelectionDuplicate,
    ),
  )
}

///|
test "missing open dependency rejects exact closure" {
  let goal_id = @control.GoalId("goal-missing-dependency")
  let dependency_id = @control.PartId("a")
  let part_b = submission_part(
    goal_id,
    "b",
    [dependency_id],
    @control.ProviderSurfaceId::CodexSubscriptionCli,
  )
  let decision = match
    @workflow.evaluate_goal_proposal(
      submission_proposal(goal_id, [part_b]),
      submission_snapshot([
        submission_source(
          "a",
          [],
          @workflow.SelectionSourceState::SelectionSourceOpen,
        ),
        submission_source(
          "b",
          [dependency_id],
          @workflow.SelectionSourceState::SelectionSourceOpen,
        ),
      ]),
      fn(_) { true },
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(
    decision.outcome,
    @workflow.GoalSelectionOutcome::GoalSelectionRejected,
  )
  assert_true(
    decision.rejections[0].reasons.contains(
      @workflow.SelectionRejectionReason::SelectionMissingOpenDependency,
    ),
  )
}

///|
test "dependency cycle is a typed selection rejection" {
  let goal_id = @control.GoalId("goal-cycle")
  let part_a_id = @control.PartId("a")
  let part_b_id = @control.PartId("b")
  let part_a = submission_part(
    goal_id,
    "a",
    [part_b_id],
    @control.ProviderSurfaceId::ClaudeSubscriptionCli,
  )
  let part_b = submission_part(
    goal_id,
    "b",
    [part_a_id],
    @control.ProviderSurfaceId::CodexSubscriptionCli,
  )
  let decision = match
    @workflow.evaluate_goal_proposal(
      submission_proposal(goal_id, [part_a, part_b]),
      submission_snapshot([
        submission_source(
          "a",
          [part_b_id],
          @workflow.SelectionSourceState::SelectionSourceOpen,
        ),
        submission_source(
          "b",
          [part_a_id],
          @workflow.SelectionSourceState::SelectionSourceOpen,
        ),
      ]),
      fn(_) { true },
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(decision.rejections.length(), 2)
  assert_true(
    decision.rejections.all(fn(rejection) {
      rejection.reasons.contains(
        @workflow.SelectionRejectionReason::SelectionDependencyCycle,
      )
    }),
  )
  match
    @workflow.decode_goal_selection_decision(
      @workflow.goal_selection_decision_bytes(decision),
    ) {
    Ok(decoded) => assert_eq(decoded, decision)
    Err(error) => fail(error.message())
  }
}

///|
test "iterative cycle diagnostics exclude downstream dependents" {
  let goal_id = @control.GoalId("goal-exact-cycles")
  let a = @control.PartId("a")
  let b = @control.PartId("b")
  let parts = [
    submission_part(
      goal_id,
      "a",
      [b],
      @control.ProviderSurfaceId::CodexSubscriptionCli,
    ),
    submission_part(
      goal_id,
      "b",
      [a],
      @control.ProviderSurfaceId::CodexSubscriptionCli,
    ),
    submission_part(
      goal_id,
      "c",
      [b],
      @control.ProviderSurfaceId::CodexSubscriptionCli,
    ),
  ]
  let snapshot = submission_snapshot([
    submission_source(
      "a",
      [b],
      @workflow.SelectionSourceState::SelectionSourceOpen,
    ),
    submission_source(
      "b",
      [a],
      @workflow.SelectionSourceState::SelectionSourceOpen,
    ),
    submission_source(
      "c",
      [b],
      @workflow.SelectionSourceState::SelectionSourceOpen,
    ),
  ])
  let decision = @workflow.evaluate_goal_proposal(
    submission_proposal(goal_id, parts),
    snapshot,
    fn(_) { true },
  ).unwrap()
  assert_eq(decision.rejections.map(fn(rejection) { rejection.part_id }), [a, b])
  assert_true(
    decision.rejections.all(fn(rejection) {
      rejection.reasons ==
      [@workflow.SelectionRejectionReason::SelectionDependencyCycle]
    }),
  )
  let self = submission_part(
    goal_id,
    "self",
    [@control.PartId("self")],
    @control.ProviderSurfaceId::CodexSubscriptionCli,
  )
  let self_decision = @workflow.evaluate_goal_proposal(
    submission_proposal(goal_id, [self]),
    submission_snapshot([
      submission_source(
        "self",
        [@control.PartId("self")],
        @workflow.SelectionSourceState::SelectionSourceOpen,
      ),
    ]),
    fn(_) { true },
  ).unwrap()
  assert_eq(self_decision.rejections[0].reasons, [
    @workflow.SelectionRejectionReason::SelectionDependencyCycle,
  ])
}

///|
test "duplicate declared dependency is a typed selection rejection" {
  let goal_id = @control.GoalId("goal-duplicate-edge")
  let dependency = @control.PartId("dependency")
  let part = submission_part(
    goal_id,
    "dependent",
    [dependency, dependency],
    @control.ProviderSurfaceId::CodexSubscriptionCli,
  )
  let decision = @workflow.evaluate_goal_proposal(
    submission_proposal(goal_id, [part]),
    submission_snapshot([
      submission_source(
        "dependency",
        [],
        @workflow.SelectionSourceState::SelectionSourceClosed,
      ),
      submission_source(
        "dependent",
        [dependency, dependency],
        @workflow.SelectionSourceState::SelectionSourceOpen,
      ),
    ]),
    fn(_) { true },
  ).unwrap()
  assert_eq(decision.rejections[0].reasons, [
    @workflow.SelectionRejectionReason::SelectionDuplicate,
  ])
}

///|
fn submission_dense_graph(
  goal_id : @control.GoalId,
  part_count : Int,
  edge_count : Int,
) -> (
  Array[@workflow.ConductorPartProposal],
  Array[@workflow.GoalSelectionSourcePart],
) {
  let parts : Array[@workflow.ConductorPartProposal] = []
  let sources : Array[@workflow.GoalSelectionSourcePart] = []
  let mut remaining = edge_count
  for dependent = 0; dependent < part_count; dependent = dependent + 1 {
    let dependencies : Array[@control.PartId] = []
    for dependency = 0
        dependency < dependent && remaining > 0
        dependency = dependency + 1 {
      dependencies.push(@control.PartId("dense-" + dependency.to_string()))
      remaining = remaining - 1
    }
    let id = "dense-" + dependent.to_string()
    parts.push(
      submission_part(
        goal_id,
        id,
        dependencies,
        @control.ProviderSurfaceId::CodexSubscriptionCli,
      ),
    )
    sources.push(
      submission_source(
        id,
        dependencies,
        @workflow.SelectionSourceState::SelectionSourceOpen,
      ),
    )
  }
  (parts, sources)
}

///|
test "dense bounded proposal ordering and decision digest are stable" {
  let goal_id = @control.GoalId("goal-dense-bounded")
  let (parts, sources) = submission_dense_graph(goal_id, 256, 2048)
  let snapshot = submission_snapshot(sources)
  let forward = @workflow.evaluate_goal_proposal(
    submission_proposal(goal_id, parts),
    snapshot,
    fn(_) { true },
  ).unwrap()
  let reverse = @workflow.evaluate_goal_proposal(
    submission_proposal(goal_id, parts.rev()),
    { ..snapshot, parts: snapshot.parts.rev() },
    fn(_) { true },
  ).unwrap()
  assert_eq(
    forward.outcome,
    @workflow.GoalSelectionOutcome::GoalSelectionAccepted,
  )
  assert_eq(forward.accepted_parts.length(), 256)
  assert_eq(
    forward.accepted_parts.map(fn(part) { part.part.id }),
    reverse.accepted_parts.map(fn(part) { part.part.id }),
  )
  assert_eq(forward.proposal_digest, reverse.proposal_digest)
  assert_eq(forward.id, reverse.id)
  assert_eq(
    forward.goal.unwrap().contract_digest,
    reverse.goal.unwrap().contract_digest,
  )
  let repeated = @workflow.evaluate_goal_proposal(
    submission_proposal(goal_id, parts),
    snapshot,
    fn(_) { true },
  ).unwrap()
  assert_eq(
    @workflow.goal_selection_decision_digest(forward),
    @workflow.goal_selection_decision_digest(repeated),
  )
}

///|
test "persisted selection decision decoder reapplies graph limits" {
  let goal_id = @control.GoalId("goal-persisted-bounds")
  let base_part = submission_part(
    goal_id,
    "base",
    [],
    @control.ProviderSurfaceId::CodexSubscriptionCli,
  )
  let base = @workflow.evaluate_goal_proposal(
    submission_proposal(goal_id, [base_part]),
    submission_snapshot([
      submission_source(
        "base",
        [],
        @workflow.SelectionSourceState::SelectionSourceOpen,
      ),
    ]),
    fn(_) { true },
  ).unwrap()
  let oversized_parts = Array::makei(257, fn(index) {
    submission_part(
      goal_id,
      "persisted-" + index.to_string(),
      [],
      @control.ProviderSurfaceId::CodexSubscriptionCli,
    )
  })
  let oversized_proposal = { ..base.proposal, parts: oversized_parts }
  let oversized = {
    ..base,
    proposal: oversized_proposal,
    proposal_digest: @workflow.goal_proposal_digest(oversized_proposal),
  }
  match
    @workflow.decode_goal_selection_decision(
      @workflow.goal_selection_decision_bytes(oversized),
    ) {
    Err(error) => assert_true(error.message().contains("exceeds Part limit"))
    Ok(_) => fail("an oversized persisted selection was admitted")
  }
  let chain_parts : Array[@workflow.ConductorPartProposal] = []
  for index = 0; index < 66; index = index + 1 {
    let dependencies = if index == 0 {
      []
    } else {
      [@control.PartId("persisted-chain-" + (index - 1).to_string())]
    }
    chain_parts.push(
      submission_part(
        goal_id,
        "persisted-chain-" + index.to_string(),
        dependencies,
        @control.ProviderSurfaceId::CodexSubscriptionCli,
      ),
    )
  }
  let deep_proposal = { ..base.proposal, parts: chain_parts }
  let deep = {
    ..base,
    proposal: deep_proposal,
    proposal_digest: @workflow.goal_proposal_digest(deep_proposal),
  }
  match
    @workflow.decode_goal_selection_decision(
      @workflow.goal_selection_decision_bytes(deep),
    ) {
    Err(error) =>
      assert_true(error.message().contains("exceeds dependency depth"))
    Ok(_) => fail("an over-depth persisted selection was admitted")
  }
}

///|
/// This identity keys runtime roots, Bead claim reconciliation, and
/// publication. It was copy-pasted at four call sites, so a copy drifting to a
/// different scheme would make cleanup and restart compute a different identity
/// than submission did and orphan everything keyed under the old one.
///
/// The digest format is pinned rather than merely exercised: changing it is a
/// decision about existing on-disk state, not a refactor.
test "a repository identity is derived one way and pinned to its format" {
  let identity = @workflow.repository_id("/mnt/data/Code/choir")
  assert_eq(
    identity,
    @workflow.RepositoryId(
      "sha256:" +
      @storage.digest_text(
        @storage.artifact_digest(
          @utf8.encode("choir.repository.v1\u{00}" + "/mnt/data/Code/choir"),
        ),
      ),
    ),
  )
  // Stable: the same root always derives the same identity, which is what
  // makes a runtime root findable again after a restart.
  assert_eq(identity, @workflow.repository_id("/mnt/data/Code/choir"))
  // Distinct roots are distinct identities, so two checkouts cannot share a
  // runtime root or claim namespace.
  assert_true(identity != @workflow.repository_id("/mnt/data/Code/other"))
  // The domain prefix is load-bearing: the identity is not the bare path
  // digest, so an unprefixed digest computed elsewhere cannot collide with it.
  assert_true(
    identity !=
    @workflow.RepositoryId(
      "sha256:" +
      @storage.digest_text(
        @storage.artifact_digest(@utf8.encode("/mnt/data/Code/choir")),
      ),
    ),
  )
}
