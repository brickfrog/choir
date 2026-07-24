///|
let submission_digest : @control.Digest = @control.Digest(
  "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
)

///|
let submission_process_digest : @control.Digest = @control.Digest(
  "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
)

///|
fn submission_migration_admission(
  reference : @control.MigrationContractRef,
) -> @migration.MigrationProductionAdmissionRef {
  {
    migration_contract_ref: reference,
    contract_acceptance_digest: submission_digest,
    judge_definition_digest: submission_digest,
    judge_qualification_report_digest: submission_digest,
    judge_qualification_evidence_ref_digest: submission_digest,
    rehearsal_evidence_ref_digest: None,
    migration_continuation_ref_digest: None,
  }
}

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
    repair_conflict_id: None,
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
    migration_contract_ref: None,
    migration_continuation_ref_digest: None,
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
    part_context_manifest: None,
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
    }),
    migration_production_admission: None,
    maximum_parallel_parts: 2,
    parts,
  }
}

///|
test "accepted migration Part retains its exact context manifest" {
  let goal_id = @control.GoalId("goal-migration-context")
  let base = submission_part(
    goal_id,
    "migration-part",
    [],
    @control.ProviderSurfaceId::CodexSubscriptionCli,
  )
  let reference : @control.MigrationContractRef = {
    contract_id: @control.MigrationContractId("migration-contract-1"),
    migration_lineage_id: @control.MigrationLineageId("migration-lineage-1"),
    revision: 1,
    contract_artifact_digest: submission_digest,
  }
  let contract = {
    ..base.task_contract,
    migration_contract_ref: Some(reference),
  }
  let manifest : @migration.PartContextManifest = {
    migration_contract_ref: reference,
    part_task_contract_revision_id: contract.id,
    part_task_contract_digest: contract.digest,
    context_assembly_policy_digest: submission_digest,
    rulebook_section_digests: [submission_digest],
    dependency_neighborhood_digest: submission_digest,
    applicable_gap_entry_digests: [],
    source_path_manifest_digest: submission_digest,
    prior_take_context_digest: None,
  }
  let proposal = {
    ..submission_proposal(goal_id, [
      { ..base, task_contract: contract, part_context_manifest: Some(manifest) },
    ]),
    migration_production_admission: Some(
      submission_migration_admission(reference),
    ),
  }
  let decision = @workflow.evaluate_goal_proposal(
    proposal,
    submission_snapshot([
      submission_source(
        "migration-part",
        [],
        @workflow.SelectionSourceState::SelectionSourceOpen,
      ),
    ]),
    fn(_) { true },
  ).unwrap()
  assert_eq(
    decision.outcome,
    @workflow.GoalSelectionOutcome::GoalSelectionAccepted,
  )
  assert_eq(decision.accepted_parts[0].part_context_manifest, Some(manifest))
  assert_eq(
    decision.proposal.migration_production_admission,
    proposal.migration_production_admission,
  )
  let execution = @workflow.goal_execution_record_from_selection(
    decision,
    @workflow.goal_selection_decision_digest(decision),
    ["migration-workflow"],
  ).unwrap()
  assert_eq(
    execution.migration_production_admission,
    proposal.migration_production_admission,
  )
  assert_true(
    @workflow.evaluate_goal_proposal(
      { ..proposal, migration_production_admission: None },
      submission_snapshot([
        submission_source(
          "migration-part",
          [],
          @workflow.SelectionSourceState::SelectionSourceOpen,
        ),
      ]),
      fn(_) { true },
    ).unwrap().outcome ==
    @workflow.GoalSelectionOutcome::GoalSelectionRejected,
  )
  let continued_contract = {
    ..contract,
    migration_continuation_ref_digest: Some(submission_process_digest),
  }
  let continued_part = {
    ..proposal.parts[0],
    task_contract: continued_contract,
    part_context_manifest: Some({
      ..manifest,
      part_task_contract_revision_id: continued_contract.id,
      part_task_contract_digest: continued_contract.digest,
    }),
  }
  let unbound_continuation = { ..proposal, parts: [continued_part] }
  assert_true(
    @workflow.evaluate_goal_proposal(
      unbound_continuation,
      submission_snapshot([
        submission_source(
          "migration-part",
          [],
          @workflow.SelectionSourceState::SelectionSourceOpen,
        ),
      ]),
      fn(_) { true },
    ).unwrap().outcome ==
    @workflow.GoalSelectionOutcome::GoalSelectionRejected,
  )
  let bound_continuation = {
    ..unbound_continuation,
    migration_production_admission: proposal.migration_production_admission.map(fn(
        admission,
      ) {
        {
          ..admission,
          migration_continuation_ref_digest: Some(submission_process_digest),
        }
      },
    ),
  }
  assert_true(
    @workflow.evaluate_goal_proposal(
      bound_continuation,
      submission_snapshot([
        submission_source(
          "migration-part",
          [],
          @workflow.SelectionSourceState::SelectionSourceOpen,
        ),
      ]),
      fn(_) { true },
    ).unwrap().outcome ==
    @workflow.GoalSelectionOutcome::GoalSelectionAccepted,
  )
  assert_true(
    @workflow.evaluate_goal_proposal(
      {
        ..proposal,
        migration_production_admission: Some({
          ..submission_migration_admission(reference),
          migration_contract_ref: { ..reference, revision: 2 },
        }),
      },
      submission_snapshot([
        submission_source(
          "migration-part",
          [],
          @workflow.SelectionSourceState::SelectionSourceOpen,
        ),
      ]),
      fn(_) { true },
    ).unwrap().outcome ==
    @workflow.GoalSelectionOutcome::GoalSelectionRejected,
  )
  assert_true(
    @workflow.evaluate_goal_proposal(
      {
        ..proposal,
        parts: [{ ..proposal.parts[0], part_context_manifest: None }],
      },
      submission_snapshot([
        submission_source(
          "migration-part",
          [],
          @workflow.SelectionSourceState::SelectionSourceOpen,
        ),
      ]),
      fn(_) { true },
    ).unwrap().outcome ==
    @workflow.GoalSelectionOutcome::GoalSelectionRejected,
  )
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
  assert_true(@workflow.goal_source_claims_have_conflict(conflicted))
  assert_eq(conflicted.source_claims[0].receipt, None)
  assert_eq(
    conflicted.source_claims[0].lifecycle,
    @workflow.GoalSourceClaimLifecycle::GoalSourceClaimConflict(
      @workflow.GoalSourceClaimConflictReason::GoalSourceClaimContentDrift,
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
  let awaiting = match
    @workflow.advance_goal_execution_state(
      assured,
      @workflow.GoalExecutionState::GoalExecutionAwaitingMerge,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  let succeeded = match
    @workflow.advance_goal_execution_state(
      awaiting,
      @workflow.GoalExecutionState::GoalExecutionSucceeded,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_true(
    succeeded.goal.lifecycle is @control.GoalLifecycle::GoalSucceeded(_),
  )
  assert_eq(succeeded.durable_version, 12)
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
  let previous_contract_ref : @control.MigrationContractRef = {
    contract_id: @control.MigrationContractId("supersession-contract"),
    migration_lineage_id: @control.MigrationLineageId("supersession-lineage"),
    revision: 1,
    contract_artifact_digest: submission_digest,
  }
  let next_contract_ref = {
    ..previous_contract_ref,
    revision: 2,
    contract_artifact_digest: submission_process_digest,
  }
  let impact_set = @migration.compute_migration_contract_revision_impact_set(
    previous_contract_ref,
    next_contract_ref,
    [
      {
        kind: @migration.MigrationChangedArtifactKind::ChangedRulebook,
        previous_digest: submission_digest,
        next_digest: submission_process_digest,
      },
    ],
    [
      {
        part_id: @control.PartId("a"),
        effective_task_contract_revision_id: @control.RevisionId("revision-a"),
        dependency_artifact_digests: [submission_digest],
        integrated: true,
        dependency_complete: true,
      },
    ],
  ).unwrap()
  let supersession = @workflow.authorize_migration_goal_supersession(
    assured,
    impact_set,
    [@control.PartId("a")],
    @control.GitOid("supersession-observed-head"),
    101L,
  ).unwrap()
  let publishable_assured = {
    ..assured,
    completion_mode: @workflow.GoalCompletionMode::GoalPublishable,
  }
  let succeeded_before_supersession = @workflow.advance_goal_execution_state(
    @workflow.advance_goal_execution_state(
      publishable_assured,
      @workflow.GoalExecutionState::GoalExecutionAwaitingMerge,
    ).unwrap(),
    @workflow.GoalExecutionState::GoalExecutionSucceeded,
  ).unwrap()
  assert_true(
    @workflow.authorize_migration_goal_supersession(
      succeeded_before_supersession,
      impact_set,
      [@control.PartId("a")],
      @control.GitOid("supersession-observed-head"),
      101L,
    )
    is Err(_),
  )
  assert_true(
    @workflow.advance_goal_execution_state(
      supersession.canceling_record,
      @workflow.GoalExecutionState::GoalExecutionSucceeded,
    )
    is Err(_),
  )
  assert_eq(
    supersession.canceling_record.cancellation_request.map(fn(request) {
      request.cause
    }),
    Some(
      @workflow.GoalCancellationCause::GoalCancellationSupersededByContractRevision(
        supersession.supersession_artifact_digest,
      ),
    ),
  )
  let released_supersession = @workflow.reconcile_goal_source_release(
    @workflow.authorize_goal_source_release(
      supersession.canceling_record,
      supersession.canceling_record.source_claims[0].part_id,
    ).unwrap(),
    supersession.canceling_record.source_claims[0].part_id,
    @workflow.GoalSourceClaimObservation::GoalSourceUnclaimedExact,
    102L,
  ).unwrap()
  let canceled_supersession = @workflow.commit_goal_execution_cancellation(
    released_supersession,
  ).unwrap()
  guard canceled_supersession.goal.lifecycle
    is @control.GoalLifecycle::GoalCanceled(summary_id) else {
    fail("superseded Goal did not reach ordinary cancellation")
  }
  let terminal_head = @control.GitOid("supersession-terminal-head")
  let continuation : @migration.MigrationContinuationRef = {
    prior_goal_id: assured.goal.id,
    supersession_artifact_digest: supersession.supersession_artifact_digest,
    cancellation_summary_id: summary_id,
    terminal_preserved_head: terminal_head,
    next_contract_ref,
  }
  assert_true(
    @workflow.validate_migration_continuation_terminal(
      continuation,
      supersession.supersession,
      canceled_supersession,
      terminal_head,
      terminal_head,
    )
    is Ok(_),
  )
  assert_true(
    @workflow.validate_migration_continuation_terminal(
      continuation,
      supersession.supersession,
      canceled_supersession,
      @control.GitOid("supersession-observed-head"),
      @control.GitOid("supersession-observed-head"),
    )
    is Err(_),
  )
  let continuation_digest = @migration.migration_continuation_ref_digest(
    continuation,
  )
  let continuation_contract = {
    ..submission_contract(
      @control.GoalId("continued-goal"),
      @control.PartId("continued-part"),
      @control.MutationDeclaration::CompleteMutationDeclaration([
        @control.MutationClaim::ExactPath(
          @control.RepoPath("src/continued.mbt"),
        ),
      ]),
    ),
    base_commit_oid: terminal_head,
    migration_contract_ref: Some(next_contract_ref),
    migration_continuation_ref_digest: Some(continuation_digest),
  }
  let continuation_admission = @workflow.validate_migration_continuation_selection(
    submission_migration_admission(next_contract_ref),
    continuation,
    supersession.supersession,
    canceled_supersession,
    terminal_head,
    terminal_head,
    [continuation_contract],
  ).unwrap()
  assert_eq(
    continuation_admission.migration_continuation_ref_digest,
    Some(continuation_digest),
  )
  assert_true(
    @workflow.validate_migration_continuation_selection(
      submission_migration_admission(next_contract_ref),
      continuation,
      supersession.supersession,
      supersession.canceling_record,
      terminal_head,
      terminal_head,
      [continuation_contract],
    )
    is Err(_),
  )
  assert_true(
    @workflow.validate_migration_continuation_selection(
      submission_migration_admission(next_contract_ref),
      continuation,
      supersession.supersession,
      canceled_supersession,
      terminal_head,
      terminal_head,
      [{ ..continuation_contract, migration_continuation_ref_digest: None }],
    )
    is Err(_),
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
  assert_eq(blocked.state, @workflow.GoalExecutionState::GoalExecutionBlocked)
  assert_eq(
    blocked.branch_initialization.lifecycle,
    @workflow.GoalBranchInitLifecycle::GoalBranchInitIntegrityBlocked,
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
  assert_eq(uncertain.state, @workflow.GoalExecutionState::GoalExecutionPaused)
  assert_eq(
    uncertain.branch_initialization.lifecycle,
    @workflow.GoalBranchInitLifecycle::GoalBranchInitUncertain,
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
}
