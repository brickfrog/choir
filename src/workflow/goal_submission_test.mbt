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
    maximum_parallel_parts: 2,
    parts,
  }
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
  let running = @workflow.advance_goal_execution_state(
    queued,
    @workflow.GoalExecutionState::GoalExecutionRunning,
  ).unwrap()
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
  assert_eq(succeeded.durable_version, 5)
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
  let canceled = match @workflow.commit_goal_execution_cancellation(canceling) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(canceled.state, @workflow.GoalExecutionState::GoalExecutionCanceled)
  assert_true(
    canceled.goal.lifecycle is @control.GoalLifecycle::GoalCanceled(_),
  )
  assert_eq(canceled.durable_version, 3)
  match @workflow.request_goal_execution_cancellation(canceled, 3000L) {
    Ok(
      @workflow.GoalCancellationDecision::GoalCancellationAlreadyTerminal(state)
    ) => assert_eq(state, @workflow.GoalExecutionState::GoalExecutionCanceled)
    Ok(_) => fail("terminal cancellation was not reported")
    Err(error) => fail(error.message())
  }
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
