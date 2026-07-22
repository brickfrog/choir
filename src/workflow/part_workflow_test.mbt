///|
let workflow_digest_a : @control.Digest = @control.Digest(
  "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
)

///|
let workflow_digest_b : @control.Digest = @control.Digest(
  "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
)

///|
let workflow_digest_c : @control.Digest = @control.Digest(
  "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
)

///|
let workflow_digest_d : @control.Digest = @control.Digest(
  "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
)

///|
let workflow_digest_e : @control.Digest = @control.Digest(
  "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
)

///|
fn workflow_take(id : String, purpose : @control.TakePurpose) -> @control.Take {
  {
    id: @control.TakeId(id),
    goal_id: @control.GoalId("goal-1"),
    purpose,
    ordinal: 1,
    fencing_epoch: None,
    lifecycle: @control.TakeLifecycle::TakePlanned,
  }
}

///|
fn workflow_sandbox(
  id : String,
  generation : String,
  take_id : @control.TakeId,
  capability : @control.Digest,
  runtime : @control.Digest,
) -> @control.SandboxLease {
  {
    id: @control.SandboxLeaseId(id),
    take_id,
    generation_id: @control.SandboxGenerationId(generation),
    capability_profile_digest: capability,
    runtime_policy_digest: runtime,
    lifecycle: @control.SandboxLeaseLifecycle::SandboxLeasePlanned,
  }
}

///|
fn workflow_session(
  id : String,
  take_id : @control.TakeId,
  generation : @control.SandboxGenerationId,
  surface : @control.ProviderSurfaceId,
  manifest : @control.Digest,
) -> @control.HarnessSession {
  {
    id: @control.HarnessSessionId(id),
    take_id,
    sandbox_generation_id: generation,
    surface,
    effective_surface_manifest_digest: manifest,
    cursor_class: @control.HarnessCursorClass::HarnessCursorNotResumable,
    provider_cursor: None,
    last_choir_sequence: @control.EventSequence(0L),
    open_tool_execution_ids: [],
    lifecycle: @control.HarnessSessionLifecycle::HarnessSessionPlanned,
  }
}

///|
fn workflow_goal_assurance_identities(
  goal : @control.Goal,
  head_oid : @control.GitOid,
) -> @workflow.GoalAssuranceIdentityPlan {
  let verification = workflow_take(
    "goal-verification-take-1",
    @control.TakePurpose::GoalVerification(
      goal.id,
      head_oid,
      goal.contract_digest,
    ),
  )
  let audit = workflow_take(
    "goal-audit-take-1",
    @control.TakePurpose::GoalAudit(goal.id, goal.contract_digest),
  )
  let verification_sandbox = workflow_sandbox(
    "goal-verification-sandbox-1",
    "goal-verification-generation-1",
    verification.id,
    workflow_digest_b,
    workflow_digest_c,
  )
  let audit_sandbox = workflow_sandbox(
    "goal-audit-sandbox-1",
    "goal-audit-generation-1",
    audit.id,
    workflow_digest_c,
    workflow_digest_c,
  )
  {
    verification_take: verification,
    verification_sandbox,
    verification_session: workflow_session(
      "goal-verification-session-1",
      verification.id,
      verification_sandbox.generation_id,
      @control.ProviderSurfaceId::CodexSubscriptionCli,
      workflow_digest_d,
    ),
    audit_take: audit,
    audit_sandbox,
    audit_session: workflow_session(
      "goal-audit-session-1",
      audit.id,
      audit_sandbox.generation_id,
      @control.ProviderSurfaceId::CodexSubscriptionCli,
      workflow_digest_e,
    ),
  }
}

///|
fn workflow_fixture() -> @workflow.PartWorkflowSnapshot raise {
  let goal : @control.Goal = {
    id: @control.GoalId("goal-1"),
    contract_digest: workflow_digest_a,
    lifecycle: @control.GoalLifecycle::GoalActive(
      @control.GoalActiveCondition::GoalRunning,
    ),
  }
  let part : @control.GoalPart = {
    id: @control.PartId("part-1"),
    goal_id: goal.id,
    dependency_ids: [],
    task_contract_revision_id: @control.RevisionId("revision-1"),
    lifecycle: @control.PartLifecycle::PartPending,
  }
  let spec : @control.VerificationSpec = {
    id: @control.VerificationSpecId("moon-test"),
    version: 1,
    digest: workflow_digest_b,
    process_spec_digest: workflow_digest_c,
  }
  let contract : @control.TaskContractRevision = {
    id: part.task_contract_revision_id,
    goal_id: goal.id,
    part_id: part.id,
    revision: 1,
    digest: workflow_digest_a,
    repair_conflict_id: None,
    instruction_artifact: {
      artifact_id: "instruction-workflow",
      digest: workflow_digest_a,
    },
    base_commit_oid: @control.GitOid("base-commit"),
    base_tree_oid: @control.GitOid("base-tree"),
    path_mode: @control.RepositoryPathMode::CaseSensitiveNfc,
    mutation_declaration: @control.MutationDeclaration::CompleteMutationDeclaration([
        @control.MutationClaim::ExactPath(@control.RepoPath("src/feature.mbt")),
      ],
    ),
    verification_specs: [spec],
    audit_policy_digest: workflow_digest_b,
    migration_contract_ref: None,
    implementation_capability_profile_digest: workflow_digest_a,
    verification_capability_profile_digest: workflow_digest_b,
    audit_capability_profile_digest: workflow_digest_c,
  }
  let implementation = workflow_take(
    "implementation-take-1",
    @control.TakePurpose::Implementation(part.id, contract.id),
  )
  let verification = workflow_take(
    "verification-take-1",
    @control.TakePurpose::PartVerification(
      part.id,
      implementation.id,
      workflow_digest_a,
    ),
  )
  let audit = workflow_take(
    "audit-take-1",
    @control.TakePurpose::PartAudit(
      part.id,
      implementation.id,
      workflow_digest_a,
    ),
  )
  let implementation_sandbox = workflow_sandbox(
    "implementation-sandbox-1",
    "implementation-generation-1",
    implementation.id,
    contract.implementation_capability_profile_digest,
    workflow_digest_a,
  )
  let verification_sandbox = workflow_sandbox(
    "verification-sandbox-1",
    "verification-generation-1",
    verification.id,
    contract.verification_capability_profile_digest,
    workflow_digest_d,
  )
  let audit_sandbox = workflow_sandbox(
    "audit-sandbox-1",
    "audit-generation-1",
    audit.id,
    contract.audit_capability_profile_digest,
    workflow_digest_e,
  )
  let identities : @workflow.PartIdentityPlan = {
    implementation_take: implementation,
    implementation_sandbox,
    implementation_session: workflow_session(
      "implementation-session-1",
      implementation.id,
      implementation_sandbox.generation_id,
      @control.ProviderSurfaceId::ClaudeSubscriptionCli,
      workflow_digest_a,
    ),
    verification_take: verification,
    verification_sandbox,
    verification_session: workflow_session(
      "verification-session-1",
      verification.id,
      verification_sandbox.generation_id,
      @control.ProviderSurfaceId::CodexSubscriptionCli,
      workflow_digest_b,
    ),
    audit_take: audit,
    audit_sandbox,
    audit_session: workflow_session(
      "audit-session-1",
      audit.id,
      audit_sandbox.generation_id,
      @control.ProviderSurfaceId::ClaudeSubscriptionCli,
      workflow_digest_c,
    ),
  }
  match
    @workflow.initialize_part_workflow(
      "workflow-1",
      goal,
      part,
      contract,
      identities,
      @control.FencingEpoch(7L),
      fn(_) { true },
    ) {
    Ok(snapshot) => snapshot
    Err(error) => fail(error.message())
  }
}

///|
fn active_sandbox(lease : @control.SandboxLease) -> @control.SandboxLease {
  { ..lease, lifecycle: @control.SandboxLeaseLifecycle::SandboxLeaseActive }
}

///|
fn started_session(
  session : @control.HarnessSession,
) -> @control.HarnessSession {
  {
    ..session,
    lifecycle: @control.HarnessSessionLifecycle::HarnessSessionAwaitingEvents,
  }
}

///|
fn successful_trace(
  session : @control.HarnessSession,
  prefix : String,
  first_observed_at : Int64,
) -> (@control.HarnessSession, Array[@control.HarnessEventEnvelope]) {
  let started : @control.HarnessEventEnvelope = {
    id: @control.HarnessEventId(prefix + "-started"),
    take_id: session.take_id,
    session_id: session.id,
    source_position: @control.EventSourcePosition::EventNonResumableOrdinal(
      prefix, 1,
    ),
    choir_sequence: @control.EventSequence(1L),
    observed_at: first_observed_at,
    kind: @control.HarnessEventKind::HarnessStarted,
    sanitized_payload_digest: workflow_digest_a,
    redaction_state: @control.EventRedactionState::EventNotSensitive,
    late: false,
  }
  let terminal : @control.HarnessEventEnvelope = {
    id: @control.HarnessEventId(prefix + "-terminal"),
    take_id: session.take_id,
    session_id: session.id,
    source_position: @control.EventSourcePosition::EventNonResumableOrdinal(
      prefix, 2,
    ),
    choir_sequence: @control.EventSequence(2L),
    observed_at: first_observed_at + 1L,
    kind: @control.HarnessEventKind::HarnessTerminal(
      @control.HarnessTerminalObservation::HarnessCompleted,
    ),
    sanitized_payload_digest: workflow_digest_b,
    redaction_state: @control.EventRedactionState::EventNotSensitive,
    late: false,
  }
  (
    {
      ..session,
      last_choir_sequence: @control.EventSequence(2L),
      lifecycle: @control.HarnessSessionLifecycle::HarnessSessionIngestionClosedCleanly(
        @control.HarnessTerminalObservation::HarnessCompleted,
      ),
    },
    [started, terminal],
  )
}

///|
fn authorize_next(
  snapshot : @workflow.PartWorkflowSnapshot,
) -> @workflow.PartWorkflowSnapshot raise {
  let intent = match @workflow.plan_next_part_effect(snapshot) {
    Ok(Some(value)) => value
    Ok(None) => fail("expected another workflow effect")
    Err(error) => fail(error.message())
  }
  let planned = match @workflow.persist_planned_part_effect(snapshot, intent) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  match @workflow.authorize_pending_part_effect(planned) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
}

///|
fn apply_observation(
  snapshot : @workflow.PartWorkflowSnapshot,
  observation : @workflow.PartEffectObservation,
  observed_at : Int64,
) -> @workflow.PartWorkflowSnapshot raise {
  let authorized = authorize_next(snapshot)
  match
    @workflow.apply_part_effect_observation(
      authorized,
      observation,
      observed_at,
      fn(_) { true },
      fn(_) { true },
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
}

///|
fn authorize_next_goal_assurance(
  record : @workflow.GoalAssuranceRecord,
) -> @workflow.GoalAssuranceRecord raise {
  let intent = match @workflow.plan_next_goal_assurance_effect(record) {
    Ok(Some(value)) => value
    Ok(None) => fail("expected another Goal assurance effect")
    Err(error) => fail(error.message())
  }
  let planned = match
    @workflow.persist_planned_goal_assurance_effect(record, intent) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  match @workflow.authorize_pending_goal_assurance_effect(planned) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
}

///|
fn apply_goal_assurance_observation(
  record : @workflow.GoalAssuranceRecord,
  observation : @workflow.GoalAssuranceEffectObservation,
  observed_at : Int64,
) -> @workflow.GoalAssuranceRecord raise {
  match
    @workflow.apply_goal_assurance_effect_observation(
      authorize_next_goal_assurance(record),
      observation,
      observed_at,
      fn(_) { true },
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
}

///|
fn round_trip(
  snapshot : @workflow.PartWorkflowSnapshot,
) -> @workflow.PartWorkflowSnapshot raise {
  let encoded = @workflow.part_snapshot_bytes(snapshot)
  let decoded = match @workflow.decode_part_snapshot(encoded) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(decoded, snapshot)
  assert_eq(
    @workflow.part_snapshot_digest(decoded),
    @workflow.part_snapshot_digest(snapshot),
  )
  decoded
}

///|
fn workflow_initialized_branch(
  goal_id : @control.GoalId,
  repository_id : @workflow.RepositoryId,
  goal_ref : @workflow.GitRefName,
  base_oid : @control.GitOid,
) -> @workflow.GoalBranchInitialization {
  let planned = @workflow.initial_goal_branch_initialization(
    goal_id, repository_id, goal_ref, base_oid,
  )
  {
    ..planned,
    lifecycle: @workflow.GoalBranchInitLifecycle::GoalBranchInitReceipted,
    receipt: Some({
      intent_id: planned.intent_id,
      idempotency_key: planned.idempotency_key,
      repository_id,
      goal_ref,
      initialized_oid: base_oid,
      initialization_witness_ref: planned.initialization_witness_ref,
      observed_at: 1L,
    }),
  }
}

///|
fn workflow_execution_for_attach(
  snapshot : @workflow.PartWorkflowSnapshot,
) -> @workflow.GoalExecutionRecord {
  let repository_id = @workflow.RepositoryId("repository-attach")
  let goal_ref = @workflow.goal_execution_ref(snapshot.goal.id)
  let base_oid = @control.GitOid("base-commit")
  {
    goal: snapshot.goal,
    repository_id,
    selection_decision_digest: workflow_digest_a,
    base_ref: @workflow.GitRefName("refs/heads/main"),
    base_commit_oid: base_oid,
    base_tree_oid: @control.GitOid("base-tree"),
    integration_target_ref: @workflow.GitRefName("refs/heads/main"),
    goal_ref,
    branch_initialization: workflow_initialized_branch(
      snapshot.goal.id,
      repository_id,
      goal_ref,
      base_oid,
    ),
    source_claims: [
      receipted_goal_source_claim(
        snapshot.goal.id,
        snapshot.part.id,
        workflow_digest_a,
        workflow_digest_a,
        1L,
      ),
    ],
    maximum_parallel_parts: 1,
    policy_revisions: [
      @workflow.initial_goal_policy_revision(snapshot.goal.id, 1),
    ],
    part_workflow_ids: [snapshot.workflow_id],
    state: @workflow.GoalExecutionState::GoalExecutionRunning,
    pause: None,
    active_input_request: None,
    input_answers: [],
    cancellation_request: None,
    durable_version: 2,
    fencing_epoch: snapshot.fencing_epoch,
  }
}

///|
test "Goal attach projects one Take's durable events without changing state" {
  let initial = workflow_fixture()
  let (closed, trace) = successful_trace(
    started_session(initial.identities.implementation_session),
    "attach",
    10L,
  )
  let reversed = [trace[1], trace[0]]
  let snapshot = {
    ..initial,
    harness_sessions: [closed],
    harness_events: reversed,
  }
  let execution = workflow_execution_for_attach(snapshot)
  let report = @workflow.goal_attach_report(
      execution,
      [snapshot],
      None,
      initial.implementation_take.id,
    )
    .unwrap()
    .unwrap()
  assert_eq(report.goal_id, initial.goal.id)
  assert_eq(report.take, initial.implementation_take)
  assert_eq(
    report.origin,
    @workflow.GoalTakeOrigin::GoalTakeFromPart(initial.part.id),
  )
  assert_eq(report.sessions.length(), 1)
  assert_eq(report.sessions[0].session, closed)
  assert_eq(report.sessions[0].events, trace)
  assert_eq(execution, workflow_execution_for_attach(snapshot))
}

///|
test "Goal attach rejects a cursor that outruns the durable event journal" {
  let initial = workflow_fixture()
  let (closed, trace) = successful_trace(
    started_session(initial.identities.implementation_session),
    "attach-gap",
    10L,
  )
  let snapshot = {
    ..initial,
    harness_sessions: [closed],
    harness_events: [trace[0]],
  }
  assert_true(
    @workflow.goal_attach_report(
      workflow_execution_for_attach(snapshot),
      [snapshot],
      None,
      initial.implementation_take.id,
    )
    is Err(_),
  )
}

///|
test "Goal cancellation records a clean Part that never ran" {
  let initial = workflow_fixture()
  let canceled = match @workflow.record_part_goal_cancellation(initial) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(canceled.stage, @workflow.PartWorkflowStage::PartCanceled)
  assert_eq(canceled.part.lifecycle, @control.PartLifecycle::PartCanceledNotRun)
  assert_eq(
    canceled.implementation_take.lifecycle,
    @control.TakeLifecycle::TakeTerminal(
      @control.TakeTerminalDisposition::TakeCanceled,
    ),
  )
  assert_true(@workflow.part_cancellation_disposition_is_known(canceled))
  assert_eq(
    @workflow.record_part_goal_cancellation(canceled).unwrap(),
    canceled,
  )
}

///|
test "Goal cancellation records an authorized provider effect as uncertain" {
  let initial = workflow_fixture()
  let sandbox = active_sandbox(initial.identities.implementation_sandbox)
  let prepared = apply_observation(
    initial,
    @workflow.PartEffectObservation::ImplementationSandboxPrepared(sandbox),
    10L,
  )
  let session = started_session(initial.identities.implementation_session)
  let started = apply_observation(
    prepared,
    @workflow.PartEffectObservation::ImplementationHarnessStarted(session),
    11L,
  )
  let authorized = authorize_next(started)
  let canceled = match @workflow.record_part_goal_cancellation(authorized) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(canceled.stage, @workflow.PartWorkflowStage::PartBlocked)
  assert_eq(
    canceled.part.lifecycle,
    @control.PartLifecycle::PartBlocked(
      @control.PartBlockReason::PartRecoveryUncertain,
    ),
  )
  assert_eq(
    canceled.implementation_take.lifecycle,
    @control.TakeLifecycle::TakeTerminal(
      @control.TakeTerminalDisposition::TakeInterrupted,
    ),
  )
  assert_true(
    canceled.pending_effect
    is Some(
      { lifecycle: @workflow.PartEffectLifecycle::PartEffectUncertain, .. }
    ),
  )
  assert_true(
    canceled.sandbox_leases.all(fn(lease) {
      lease.lifecycle == @control.SandboxLeaseLifecycle::SandboxLeaseUncertain
    }),
  )
  assert_true(
    canceled.harness_sessions.all(fn(observed) {
      observed.lifecycle ==
      @control.HarnessSessionLifecycle::HarnessSessionRecoveryUncertain
    }),
  )
  assert_true(@workflow.part_cancellation_disposition_is_known(canceled))
}

///|
test "provider protocol violation terminally fences its Take and Part" {
  let initial = workflow_fixture()
  let implementation_session = started_session(
    initial.identities.implementation_session,
  )
  let prepared = apply_observation(
    initial,
    @workflow.PartEffectObservation::ImplementationSandboxPrepared(
      active_sandbox(initial.identities.implementation_sandbox),
    ),
    10L,
  )
  let running = apply_observation(
    prepared,
    @workflow.PartEffectObservation::ImplementationHarnessStarted(
      implementation_session,
    ),
    11L,
  )
  let authorized = authorize_next(running)
  let intent = match authorized.pending_effect {
    Some(value) => value
    None => fail("implementation dispatch was not authorized")
  }
  let violated = @workflow.record_part_provider_protocol_violation(
    authorized, intent,
  ).unwrap()
  assert_eq(violated.stage, @workflow.PartWorkflowStage::PartRecoveryUncertain)
  assert_eq(
    violated.part.lifecycle,
    @control.PartLifecycle::PartBlocked(
      @control.PartBlockReason::PartRecoveryUncertain,
    ),
  )
  assert_eq(
    violated.implementation_take.lifecycle,
    @control.TakeLifecycle::TakeTerminal(
      @control.TakeTerminalDisposition::TakeRecoveryUncertain(
        @control.TakeUncertaintyReason::TakeProtocolViolation,
      ),
    ),
  )
  assert_true(
    violated.harness_sessions.any(fn(session) {
      session.id == implementation_session.id &&
      session.lifecycle ==
      @control.HarnessSessionLifecycle::HarnessSessionProtocolViolated
    }),
  )
  assert_true(
    violated.pending_effect
    is Some(
      { lifecycle: @workflow.PartEffectLifecycle::PartEffectUncertain, .. }
    ),
  )
}

///|
fn drive_to_verified() -> @workflow.PartWorkflowSnapshot raise {
  let initial = workflow_fixture()
  let implementation_session = started_session(
    initial.identities.implementation_session,
  )
  let mut snapshot = apply_observation(
    initial,
    @workflow.PartEffectObservation::ImplementationSandboxPrepared(
      active_sandbox(initial.identities.implementation_sandbox),
    ),
    10L,
  )
  snapshot = apply_observation(
    snapshot,
    @workflow.PartEffectObservation::ImplementationHarnessStarted(
      implementation_session,
    ),
    11L,
  )
  let (implementation_final, implementation_events) = successful_trace(
    implementation_session, "implementation", 12L,
  )
  snapshot = apply_observation(
    snapshot,
    @workflow.PartEffectObservation::ImplementationCompleted(
      {
        take_id: snapshot.implementation_take.id,
        session_id: implementation_session.id,
        result_artifact: {
          artifact_id: "implementation-result-1",
          digest: workflow_digest_c,
        },
        finished_at: 13L,
      },
      implementation_final,
      implementation_events,
    ),
    14L,
  )
  let candidate : @control.CandidateCommit = {
    id: @control.CandidateId("candidate-1"),
    goal_id: snapshot.goal.id,
    part_id: snapshot.part.id,
    take_id: snapshot.implementation_take.id,
    base_commit_oid: snapshot.task_contract.base_commit_oid,
    commit_oid: @control.GitOid("candidate-commit"),
    tree_oid: @control.GitOid("candidate-tree"),
    canonical_change_digest: workflow_digest_d,
    changed_paths: [@control.RepoPath("src/feature.mbt")],
  }
  snapshot = apply_observation(
    snapshot,
    @workflow.PartEffectObservation::CandidateNormalized(candidate, {
      candidate_tree_paths: [@control.RepoPath("src/feature.mbt")],
      symlink_prefix_paths: [],
      normalization_collision_paths: [],
    }),
    15L,
  )
  let verification_session = started_session(
    snapshot.identities.verification_session,
  )
  snapshot = apply_observation(
    snapshot,
    @workflow.PartEffectObservation::VerificationSandboxPrepared(
      active_sandbox(snapshot.identities.verification_sandbox),
    ),
    16L,
  )
  snapshot = apply_observation(
    snapshot,
    @workflow.PartEffectObservation::VerificationHarnessStarted(
      verification_session,
    ),
    17L,
  )
  let (verification_final, verification_events) = successful_trace(
    verification_session, "verification", 18L,
  )
  let subject = match snapshot.verification_subject {
    Some(value) => value
    None => fail("verification subject was not created")
  }
  snapshot = apply_observation(
    snapshot,
    @workflow.PartEffectObservation::VerificationCompleted(
      {
        take_id: snapshot.verification_take.id,
        session_id: verification_session.id,
        verification_execution_id: @control.VerificationExecutionId(
          "verification-execution-1",
        ),
        subject,
        verification_spec: snapshot.task_contract.verification_specs[0],
        environment_and_image_digest: workflow_digest_e,
        runtime_and_policy_digest: snapshot.identities.verification_sandbox.runtime_policy_digest,
        subject_pre_tree_oid: candidate.tree_oid,
        subject_post_tree_oid: candidate.tree_oid,
        evidence: {
          artifact_id: "verification-evidence-1",
          digest: workflow_digest_e,
        },
        started_at: 18L,
        finished_at: 19L,
        outcome: @control.VerificationOutcome::VerificationPassed,
      },
      verification_final,
      verification_events,
    ),
    20L,
  )
  round_trip(snapshot)
}

///|
fn drive_to_audited() -> @workflow.PartWorkflowSnapshot raise {
  let mut snapshot = drive_to_verified()
  let audit_session = started_session(snapshot.identities.audit_session)
  snapshot = apply_observation(
    snapshot,
    @workflow.PartEffectObservation::AuditSandboxPrepared(
      active_sandbox(snapshot.identities.audit_sandbox),
    ),
    21L,
  )
  snapshot = apply_observation(
    snapshot,
    @workflow.PartEffectObservation::AuditHarnessStarted(audit_session),
    22L,
  )
  let (audit_final, audit_events) = successful_trace(
    audit_session, "audit", 23L,
  )
  let subject = match snapshot.audit_subject {
    Some(value) => value
    None => fail("audit subject was not created")
  }
  snapshot = apply_observation(
    snapshot,
    @workflow.PartEffectObservation::AuditCompleted(
      {
        audit_take_id: snapshot.audit_take.id,
        take_fencing_epoch: snapshot.fencing_epoch,
        audit_harness_session_id: audit_session.id,
        subject,
        provider_conformance_report_digest: workflow_digest_d,
        findings_artifact: None,
        total_findings_count: 0,
        blocking_findings_count: 0,
        started_at: 23L,
        finished_at: 24L,
        outcome: @control.AuditOutcome::AuditPassed,
      },
      audit_final,
      audit_events,
    ),
    25L,
  )
  snapshot = round_trip(snapshot)
  snapshot = match
    @workflow.mint_part_audit_receipt(
      snapshot,
      {
        receipt_id: @control.ReceiptId("audit-receipt-1"),
        provider_surface_id: @control.ProviderSurfaceId::ClaudeSubscriptionCli,
        provider_identity: "claude-code-test",
        model_identity: @control.ModelIdentity::ReportedModelIdentity(
          "claude-test",
        ),
      },
      fn(_) { true },
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  round_trip(snapshot)
}

///|
fn drive_to_integration_authorized() -> @workflow.PartWorkflowSnapshot raise {
  let mut snapshot = drive_to_audited()
  snapshot = match
    @workflow.plan_part_integration(snapshot, {
      lease: {
        id: @control.IntegrationLeaseId("integration-lease-1"),
        goal_id: snapshot.goal.id,
        fencing_epoch: snapshot.fencing_epoch,
        holder: "choird-test",
      },
      intent_id: @control.IntegrationIntentId("integration-intent-1"),
      expected_goal_head_oid: @control.GitOid("goal-head"),
      promotion_metadata_digest: workflow_digest_c,
      git_witness_ref: "refs/choir/witness/integration-intent-1",
    }) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  let promotion : @control.PromotionCommit = {
    intent_id: @control.IntegrationIntentId("integration-intent-1"),
    commit_oid: @control.GitOid("promotion-commit"),
    tree_oid: @control.GitOid("promotion-tree"),
    first_parent_oid: @control.GitOid("goal-head"),
    second_parent_oid: @control.GitOid("candidate-commit"),
  }
  snapshot = apply_observation(
    snapshot,
    @workflow.PartEffectObservation::PromotionGenerated(promotion),
    26L,
  )
  snapshot = match
    @workflow.authorize_part_integration(
      snapshot,
      workflow_digest_e,
      snapshot.identities.verification_sandbox.runtime_policy_digest,
      fn(_) { true },
      fn(_) { true },
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  snapshot
}

///|
test "Part reaches a verified audited integration result" {
  let mut snapshot = drive_to_integration_authorized()
  guard snapshot.promotion_commit is Some(promotion) else {
    fail("authorized integration has no promotion commit")
  }
  snapshot = apply_observation(
    snapshot,
    @workflow.PartEffectObservation::IntegrationWitnessObserved(
      @control.IntegrationWitnessObservation::IntegrationWitnessApplied(
        promotion.commit_oid,
        promotion.commit_oid,
      ),
    ),
    27L,
  )
  snapshot = round_trip(snapshot)
  assert_eq(snapshot.stage, @workflow.PartWorkflowStage::PartIntegrated)
  assert_eq(snapshot.verification_receipts.length(), 1)
  assert_true(snapshot.audit_receipt is Some(_))
  assert_true(snapshot.integration_receipt is Some(_))
  assert_eq(snapshot.effect_receipts.length(), 12)
  assert_true(
    snapshot.identities.implementation_sandbox.generation_id !=
    snapshot.identities.audit_sandbox.generation_id,
  )
  assert_true(
    snapshot.identities.implementation_session.id !=
    snapshot.identities.audit_session.id,
  )
}

///|
test "integrated Parts authorize one immutable Goal branch seal" {
  let mut integrated = drive_to_integration_authorized()
  guard integrated.promotion_commit is Some(promotion) else {
    fail("authorized integration has no promotion commit")
  }
  integrated = apply_observation(
    integrated,
    @workflow.PartEffectObservation::IntegrationWitnessObserved(
      @control.IntegrationWitnessObservation::IntegrationWitnessApplied(
        promotion.commit_oid,
        promotion.commit_oid,
      ),
    ),
    27L,
  )
  let execution : @workflow.GoalExecutionRecord = {
    goal: integrated.goal,
    repository_id: @workflow.RepositoryId("repository-assurance"),
    selection_decision_digest: workflow_digest_a,
    base_ref: @workflow.GitRefName("refs/heads/main"),
    base_commit_oid: @control.GitOid("goal-head"),
    base_tree_oid: @control.GitOid("goal-tree-before"),
    integration_target_ref: @workflow.GitRefName("refs/heads/main"),
    goal_ref: @workflow.goal_execution_ref(integrated.goal.id),
    branch_initialization: workflow_initialized_branch(
      integrated.goal.id,
      @workflow.RepositoryId("repository-assurance"),
      @workflow.goal_execution_ref(integrated.goal.id),
      @control.GitOid("goal-head"),
    ),
    source_claims: [
      receipted_goal_source_claim(
        integrated.goal.id,
        integrated.part.id,
        workflow_digest_a,
        workflow_digest_a,
        1L,
      ),
    ],
    maximum_parallel_parts: 1,
    policy_revisions: [
      @workflow.initial_goal_policy_revision(integrated.goal.id, 1),
    ],
    part_workflow_ids: [integrated.workflow_id],
    state: @workflow.GoalExecutionState::GoalExecutionAssuring,
    pause: None,
    active_input_request: None,
    input_answers: [],
    cancellation_request: None,
    durable_version: 3,
    fencing_epoch: integrated.fencing_epoch,
  }
  let planned = match
    @workflow.initialize_goal_assurance(
      execution,
      [integrated],
      promotion.commit_oid,
      promotion.tree_oid,
      integrated.task_contract.verification_specs,
      workflow_goal_assurance_identities(execution.goal, promotion.commit_oid),
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(planned.stage, @workflow.GoalAssuranceStage::GoalSealPlanned)
  assert_eq(planned.integration_receipts.length(), 1)
  assert_eq(
    planned.verification_specs,
    integrated.task_contract.verification_specs,
  )
  let canceled_planned = @workflow.record_goal_assurance_cancellation(planned).unwrap()
  assert_eq(
    canceled_planned.stage,
    @workflow.GoalAssuranceStage::GoalAssuranceCanceled,
  )
  assert_eq(
    canceled_planned.seal_intent.lifecycle,
    @control.GoalBranchSealIntentLifecycle::GoalBranchSealAbandonedByCancellation,
  )
  assert_true(
    @workflow.goal_assurance_cancellation_disposition_is_known(canceled_planned),
  )
  assert_eq(
    @workflow.decode_goal_assurance_record(
      @workflow.goal_assurance_record_bytes(canceled_planned),
    ).unwrap(),
    canceled_planned,
  )
  let authorized = match
    @workflow.authorize_goal_assurance_seal(
      planned,
      execution.goal,
      promotion.commit_oid,
      promotion.tree_oid,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(
    @workflow.record_goal_assurance_cancellation(authorized).unwrap(),
    authorized,
  )
  assert_false(
    @workflow.goal_assurance_cancellation_disposition_is_known(authorized),
  )
  let witnessed = match
    @workflow.record_goal_assurance_seal_witness(
      authorized,
      @control.GoalBranchSealWitnessObservation::GoalBranchSealWitnessApplied(
        promotion.commit_oid,
        promotion.commit_oid,
        promotion.tree_oid,
      ),
      28L,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  let canceled_witnessed = @workflow.record_goal_assurance_cancellation(
    witnessed,
  ).unwrap()
  assert_eq(
    canceled_witnessed.stage,
    @workflow.GoalAssuranceStage::GoalAssuranceCanceled,
  )
  assert_eq(
    canceled_witnessed.seal_intent.lifecycle,
    @control.GoalBranchSealIntentLifecycle::GoalBranchSealWitnessed,
  )
  assert_true(
    @workflow.goal_assurance_cancellation_disposition_is_known(
      canceled_witnessed,
    ),
  )
  let completed_seal = match
    @workflow.commit_goal_assurance_seal(
      witnessed,
      @control.GoalBranchSealId("seal-goal-1"),
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(completed_seal.stage, @workflow.GoalAssuranceStage::GoalSealed)
  assert_eq(completed_seal.durable_version, 4)
  let canceled_sealed = @workflow.record_goal_assurance_cancellation(
    completed_seal,
  ).unwrap()
  assert_eq(
    canceled_sealed.stage,
    @workflow.GoalAssuranceStage::GoalAssuranceCanceled,
  )
  assert_true(canceled_sealed.seal is Some(_))
  assert_true(
    @workflow.goal_assurance_cancellation_disposition_is_known(canceled_sealed),
  )
  let planned_effect = @workflow.persist_planned_goal_assurance_effect(
    completed_seal,
    @workflow.plan_next_goal_assurance_effect(completed_seal).unwrap().unwrap(),
  ).unwrap()
  let canceled_planned_effect = @workflow.record_goal_assurance_cancellation(
    planned_effect,
  ).unwrap()
  assert_true(
    canceled_planned_effect.pending_effect
    is Some(
      {
        lifecycle: @workflow.GoalAssuranceEffectLifecycle::GoalAssuranceEffectAbandonedByCancellation,
        ..,
      }
    ),
  )
  let authorized_effect = @workflow.authorize_pending_goal_assurance_effect(
    planned_effect,
  ).unwrap()
  let canceled_authorized_effect = @workflow.record_goal_assurance_cancellation(
    authorized_effect,
  ).unwrap()
  assert_true(
    canceled_authorized_effect.pending_effect
    is Some(
      {
        lifecycle: @workflow.GoalAssuranceEffectLifecycle::GoalAssuranceEffectUncertain,
        ..,
      }
    ),
  )
  assert_true(
    @workflow.goal_assurance_cancellation_disposition_is_known(
      canceled_authorized_effect,
    ),
  )
  let mut assured = apply_goal_assurance_observation(
    completed_seal,
    @workflow.GoalAssuranceEffectObservation::GoalVerificationSandboxPrepared(
      active_sandbox(completed_seal.identities.verification_sandbox),
    ),
    29L,
  )
  let verification_session = started_session(
    assured.identities.verification_session,
  )
  assured = apply_goal_assurance_observation(
    assured,
    @workflow.GoalAssuranceEffectObservation::GoalVerificationHarnessStarted(
      verification_session,
    ),
    30L,
  )
  let verification_subject = match assured.verification_subject {
    Some(value) => value
    None => fail("combined verification subject is absent")
  }
  let (verification_final, verification_events) = successful_trace(
    verification_session, "goal-verification", 31L,
  )
  assured = apply_goal_assurance_observation(
    assured,
    @workflow.GoalAssuranceEffectObservation::GoalVerificationCompleted(
      {
        take_id: assured.verification_take.id,
        session_id: verification_session.id,
        subject: verification_subject,
        executions: [
          {
            verification_execution_id: @control.VerificationExecutionId(
              "goal-verification-execution-1",
            ),
            verification_spec: assured.verification_specs[0],
            environment_and_image_digest: workflow_digest_d,
            runtime_and_policy_digest: assured.identities.verification_sandbox.runtime_policy_digest,
            subject_pre_tree_oid: promotion.tree_oid,
            subject_post_tree_oid: promotion.tree_oid,
            evidence: {
              artifact_id: "goal-verification-evidence-1",
              digest: workflow_digest_e,
            },
            started_at: 31L,
            finished_at: 32L,
            outcome: @control.VerificationOutcome::VerificationPassed,
          },
        ],
        evidence_manifest: {
          artifact_id: "goal-verification-manifest-1",
          digest: workflow_digest_c,
        },
      },
      verification_final,
      verification_events,
    ),
    33L,
  )
  assert_eq(assured.stage, @workflow.GoalAssuranceStage::GoalVerified)
  assert_eq(assured.verification_receipts.length(), 1)
  assert_true(assured.verification_authorization is Some(_))
  assured = apply_goal_assurance_observation(
    assured,
    @workflow.GoalAssuranceEffectObservation::GoalAuditSandboxPrepared(
      active_sandbox(assured.identities.audit_sandbox),
    ),
    34L,
  )
  let audit_session = started_session(assured.identities.audit_session)
  assured = apply_goal_assurance_observation(
    assured,
    @workflow.GoalAssuranceEffectObservation::GoalAuditHarnessStarted(
      audit_session,
    ),
    35L,
  )
  let audit_subject = match assured.audit_subject {
    Some(value) => value
    None => fail("combined audit subject is absent")
  }
  let (audit_final, audit_events) = successful_trace(
    audit_session, "goal-audit", 36L,
  )
  assured = apply_goal_assurance_observation(
    assured,
    @workflow.GoalAssuranceEffectObservation::GoalAuditCompleted(
      {
        audit_take_id: assured.audit_take.id,
        take_fencing_epoch: assured.fencing_epoch,
        audit_harness_session_id: audit_session.id,
        subject: audit_subject,
        provider_conformance_report_digest: workflow_digest_b,
        findings_artifact: None,
        total_findings_count: 0,
        blocking_findings_count: 0,
        started_at: 36L,
        finished_at: 37L,
        outcome: @control.AuditOutcome::AuditPassed,
      },
      audit_final,
      audit_events,
    ),
    38L,
  )
  assured = match
    @workflow.mint_goal_audit_receipt(
      assured,
      {
        receipt_id: @control.ReceiptId("goal-audit-receipt-1"),
        provider_surface_id: @control.ProviderSurfaceId::CodexSubscriptionCli,
        provider_identity: "codex-cli",
        model_identity: @control.ModelIdentity::ReportedModelIdentity("codex"),
      },
      fn(_) { true },
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(assured.stage, @workflow.GoalAssuranceStage::GoalAudited)
  assert_true(assured.audit_receipt is Some(_))
  assert_true(
    assured.identities.verification_sandbox.generation_id !=
    assured.identities.audit_sandbox.generation_id,
  )
  assert_eq(assured.effect_receipts.length(), 6)
  let status = match
    @workflow.goal_status_report(
      execution,
      [integrated],
      Some(assured),
      None,
      None,
      None,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(
    status.assurance_stage,
    Some(@workflow.GoalAssuranceStage::GoalAudited),
  )
  assert_true(status.goal_branch_seal is Some(_))
  assert_eq(status.assurance_sandbox_count, 2)
  assert_eq(status.assurance_harness_session_count, 2)
  assert_eq(status.assurance_effect_receipt_count, 6)
  assert_eq(status.goal_verification_receipt_count, 1)
  assert_true(status.goal_audit_receipt_present)
  let assured_execution = {
    ..execution,
    state: @workflow.GoalExecutionState::GoalExecutionAssured,
    durable_version: execution.durable_version + 1,
  }
  let publication = match
    @workflow.initialize_goal_publication(
      assured_execution,
      assured,
      @workflow.RemoteRepositoryId("remote-repository-assurance"),
      @workflow.RemoteName("origin"),
      @workflow.GitRefName("refs/heads/choir/goals/assurance"),
      None,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(
    publication.intent.state,
    @workflow.BranchPublicationState::BranchPublicationPlanned,
  )
  let authorized_publication = match
    @workflow.authorize_goal_publication(
      publication,
      assured_execution,
      assured,
      promotion.commit_oid,
      @workflow.RemoteBranchObservation::RemoteBranchAbsent,
      false,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  let published = match
    @workflow.record_goal_publication_observation(
      authorized_publication,
      @workflow.RemoteBranchObservation::RemoteBranchAt(promotion.commit_oid),
      @workflow.BranchPublicationReceiptOrigin::BranchPublicationMutationApplied,
      None,
      39L,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(
    published.intent.state,
    @workflow.BranchPublicationState::BranchPublicationReceipted,
  )
  guard published.receipt is Some(publication_receipt) else {
    fail("publication receipt is absent")
  }
  assert_eq(publication_receipt.published_oid, promotion.commit_oid)
  let published_status = match
    @workflow.goal_status_report(
      assured_execution,
      [integrated],
      Some(assured),
      Some(published),
      None,
      None,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(
    published_status.publication_state,
    Some(@workflow.BranchPublicationState::BranchPublicationReceipted),
  )
  assert_true(published_status.publication_receipt_present)
  assert_eq(published_status.published_oid, Some(promotion.commit_oid))
  match
    @workflow.decode_goal_publication_record(
      @workflow.goal_publication_record_bytes(published),
    ) {
    Ok(decoded) => assert_eq(decoded, published)
    Err(error) => fail(error.message())
  }
  let drifted = match
    @workflow.authorize_goal_publication(
      publication,
      assured_execution,
      assured,
      promotion.commit_oid,
      @workflow.RemoteBranchObservation::RemoteBranchAt(
        @control.GitOid("other-remote-head"),
      ),
      false,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(
    drifted.intent.state,
    @workflow.BranchPublicationState::BranchPublicationDrift,
  )
  let abandoned_publication = @workflow.record_goal_publication_cancellation(
    publication,
    @workflow.RemoteBranchObservation::RemoteBranchAbsent,
    39L,
  ).unwrap()
  assert_eq(
    abandoned_publication.intent.state,
    @workflow.BranchPublicationState::BranchPublicationAbandonedByCancellation,
  )
  assert_true(
    @workflow.goal_publication_cancellation_disposition_is_known(
      abandoned_publication,
    ),
  )
  let cancellation_witnessed_publication = @workflow.record_goal_publication_cancellation(
    authorized_publication,
    @workflow.RemoteBranchObservation::RemoteBranchAt(promotion.commit_oid),
    40L,
  ).unwrap()
  assert_eq(
    cancellation_witnessed_publication.intent.state,
    @workflow.BranchPublicationState::BranchPublicationReceipted,
  )
  assert_true(
    @workflow.goal_publication_cancellation_disposition_is_known(
      cancellation_witnessed_publication,
    ),
  )
  let preflight_uncertain = @workflow.authorize_goal_publication(
    publication,
    assured_execution,
    assured,
    promotion.commit_oid,
    @workflow.RemoteBranchObservation::RemoteBranchObservationUncertain,
    false,
  ).unwrap()
  assert_eq(
    preflight_uncertain.intent.state,
    @workflow.BranchPublicationState::BranchPublicationPreflightUncertain,
  )
  let preflight_recovered = @workflow.authorize_goal_publication(
    preflight_uncertain,
    assured_execution,
    assured,
    promotion.commit_oid,
    @workflow.RemoteBranchObservation::RemoteBranchAbsent,
    false,
  ).unwrap()
  assert_eq(
    preflight_recovered.intent.state,
    @workflow.BranchPublicationState::BranchPublicationAuthorized,
  )
  let mutation_uncertain = @workflow.record_goal_publication_observation(
    authorized_publication,
    @workflow.RemoteBranchObservation::RemoteBranchObservationUncertain,
    @workflow.BranchPublicationReceiptOrigin::BranchPublicationMutationApplied,
    None,
    40L,
  ).unwrap()
  assert_eq(
    mutation_uncertain.intent.state,
    @workflow.BranchPublicationState::BranchPublicationMutationUncertain,
  )
  let mutation_recovered = @workflow.record_goal_publication_observation(
    mutation_uncertain,
    @workflow.RemoteBranchObservation::RemoteBranchAt(promotion.commit_oid),
    @workflow.BranchPublicationReceiptOrigin::BranchPublicationAdopted,
    None,
    41L,
  ).unwrap()
  assert_eq(
    mutation_recovered.intent.state,
    @workflow.BranchPublicationState::BranchPublicationReceipted,
  )
  let pr_marker = match
    @workflow.goal_pull_request_identity_marker(
      assured_execution,
      published,
      @workflow.RemoteRepositoryId("remote-repository-assurance"),
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  let pr_document : @workflow.PullRequestDocument = {
    title: "feat: complete assurance Goal",
    body: "Goal evidence\n\n" + pr_marker.0,
  }
  let pull_request = match
    @workflow.initialize_goal_pull_request(
      assured_execution,
      assured,
      published,
      @workflow.PullRequestProvider::GitHubPullRequestProvider,
      @workflow.RemoteRepositoryId("remote-repository-assurance"),
      pr_document,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(
    pull_request.intent.state,
    @workflow.PullRequestIntentState::PullRequestPlanned,
  )
  let remote_pull_request : @workflow.RemotePullRequestSnapshot = {
    remote_id: @workflow.RemotePullRequestId("PR_kwDO_assurance"),
    number: @workflow.PullRequestNumber(42),
    url: @workflow.PullRequestUrl("https://example.invalid/choir/pull/42"),
    provider_repository_id: published.intent.canonical_repository_id,
    head_repository_id: published.intent.canonical_repository_id,
    head_ref: published.intent.remote_head_ref,
    base_repository_id: @workflow.RemoteRepositoryId(
      "remote-repository-assurance",
    ),
    base_ref: assured_execution.integration_target_ref,
    observed_head_oid: promotion.commit_oid,
    state: @workflow.RemotePullRequestState::RemotePullRequestOpen,
    marker_state: @workflow.PullRequestMarkerState::PullRequestMarkerExact,
    title_digest: @storage.artifact_digest(@utf8.encode(pr_document.title)),
    body_digest: @storage.artifact_digest(@utf8.encode(pr_document.body)),
    goal_contract_link_present: true,
    evidence_manifest_link_present: true,
  }
  let authorized_pull_request = match
    @workflow.authorize_goal_pull_request(
      pull_request,
      assured_execution,
      assured,
      published,
      promotion.commit_oid,
      @workflow.PullRequestLookupObservation::PullRequestNoMatch,
      40L,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(
    authorized_pull_request.intent.state,
    @workflow.PullRequestIntentState::PullRequestAuthorized,
  )
  let issued_pull_request = match
    @workflow.mark_goal_pull_request_create_may_have_been_issued(
      authorized_pull_request, assured_execution, assured, published,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  let uncertain_pull_request = match
    @workflow.reconcile_goal_pull_request_after_create(
      issued_pull_request,
      @workflow.PullRequestLookupObservation::PullRequestNoMatch,
      41L,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(
    uncertain_pull_request.intent.state,
    @workflow.PullRequestIntentState::PullRequestRemoteCreateUncertain,
  )
  assert_true(
    @workflow.goal_pull_request_cancellation_disposition_is_known(
      uncertain_pull_request,
    ),
  )
  let cancellation_witnessed_pull_request = @workflow.record_goal_pull_request_cancellation(
    uncertain_pull_request,
    @workflow.PullRequestLookupObservation::PullRequestUniqueMarkerMatch(
      remote_pull_request,
    ),
    42L,
  ).unwrap()
  assert_eq(
    cancellation_witnessed_pull_request.intent.state,
    @workflow.PullRequestIntentState::PullRequestReceipted,
  )
  let abandoned_pull_request = @workflow.record_goal_pull_request_cancellation(
    authorized_pull_request,
    @workflow.PullRequestLookupObservation::PullRequestNoMatch,
    42L,
  ).unwrap()
  assert_eq(
    abandoned_pull_request.intent.state,
    @workflow.PullRequestIntentState::PullRequestAbandonedByCancellation,
  )
  let adopted_pull_request = match
    @workflow.authorize_goal_pull_request(
      pull_request,
      assured_execution,
      assured,
      published,
      promotion.commit_oid,
      @workflow.PullRequestLookupObservation::PullRequestUniqueMarkerMatch(
        remote_pull_request,
      ),
      42L,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(
    adopted_pull_request.intent.state,
    @workflow.PullRequestIntentState::PullRequestReceipted,
  )
  guard adopted_pull_request.receipt is Some(pull_request_receipt) else {
    fail("pull request receipt is absent")
  }
  assert_eq(pull_request_receipt.number, @workflow.PullRequestNumber(42))
  assert_eq(
    pull_request_receipt.origin,
    @workflow.PullRequestReceiptOrigin::PullRequestAdopted,
  )
  let pull_request_status = match
    @workflow.goal_status_report(
      assured_execution,
      [integrated],
      Some(assured),
      Some(published),
      Some(adopted_pull_request),
      None,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(
    pull_request_status.pull_request_state,
    Some(@workflow.PullRequestIntentState::PullRequestReceipted),
  )
  assert_true(pull_request_status.pull_request_receipt_present)
  assert_eq(
    pull_request_status.pull_request_number,
    Some(@workflow.PullRequestNumber(42)),
  )
  let finalization = match
    @workflow.observe_goal_pull_request_readiness(
      assured_execution,
      assured,
      published,
      adopted_pull_request,
      @workflow.PullRequestLookupObservation::PullRequestStoredIdMatch(
        remote_pull_request,
      ),
      Some("remote-version-42"),
      1L,
      46L,
      47L,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(
    finalization.readiness.decision,
    @workflow.PullRequestReadinessDecision::PullRequestReady,
  )
  let final_status = match
    @workflow.goal_status_report(
      assured_execution,
      [integrated],
      Some(assured),
      Some(published),
      Some(adopted_pull_request),
      Some(finalization),
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(
    final_status.readiness_decision,
    Some(@workflow.PullRequestReadinessDecision::PullRequestReady),
  )
  assert_true(final_status.semantic_run_projection is None)
  match
    @workflow.decode_goal_finalization_record(
      @workflow.goal_finalization_record_bytes(finalization),
    ) {
    Ok(decoded) => assert_eq(decoded, finalization)
    Err(error) => fail(error.message())
  }
  let succeeded = match
    @workflow.authorize_goal_execution_success(
      assured_execution, assured, published, adopted_pull_request, finalization,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(
    succeeded.state,
    @workflow.GoalExecutionState::GoalExecutionSucceeded,
  )
  let succeeded_status = match
    @workflow.goal_status_report(
      succeeded,
      [integrated],
      Some(assured),
      Some(published),
      Some(adopted_pull_request),
      Some(finalization),
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  guard succeeded_status.semantic_run_projection is Some(projection) else {
    fail("successful Goal semantic projection is absent")
  }
  assert_eq(projection.accepted_part_ids, [integrated.part.id])
  assert_eq(projection.dependency_edges, [])
  assert_eq(projection.ordered_parts.length(), 1)
  assert_eq(projection.ordered_parts[0].part_id, integrated.part.id)
  assert_eq(
    projection.ordered_parts[0].task_contract_digest,
    integrated.task_contract.digest,
  )
  assert_eq(
    projection.ordered_parts[0].candidate_change_digest,
    integrated.candidate.unwrap().canonical_change_digest,
  )
  assert_eq(projection.ordered_parts[0].verification_results.length(), 1)
  assert_eq(
    projection.ordered_parts[0].audit_outcome,
    @control.AuditOutcome::AuditPassed,
  )
  assert_eq(projection.promotions, [
    {
      part_id: integrated.part.id,
      rank: 1,
      resulting_tree_oid: promotion.tree_oid,
    },
  ])
  assert_eq(projection.final_tree_oid, promotion.tree_oid)
  assert_eq(projection.goal_verification_results.length(), 1)
  assert_eq(
    projection.combined_audit_outcome,
    @control.AuditOutcome::AuditPassed,
  )
  assert_eq(projection.receipt_cardinalities, {
    part_verification: 1,
    part_audit: 1,
    integration: 1,
    goal_verification: 1,
    goal_audit: 1,
    publication: 1,
    pull_request: 1,
  })
  assert_eq(
    projection.terminal_goal_outcome,
    @workflow.GoalExecutionState::GoalExecutionSucceeded,
  )
  let semantic_json = projection.to_json().stringify(indent=0)
  assert_false(semantic_json.contains(integrated.implementation_take.id.0))
  assert_false(semantic_json.contains(integrated.verification_take.id.0))
  assert_false(semantic_json.contains(integrated.audit_take.id.0))
  assert_false(
    semantic_json.contains(integrated.audit_receipt.unwrap().receipt_id.0),
  )
  assert_false(semantic_json.contains(publication_receipt.receipt_id.0))
  assert_false(semantic_json.contains(pull_request_receipt.receipt_id.0))
  assert_false(semantic_json.contains(pull_request_receipt.url.0))
  assert_false(
    semantic_json.contains(integrated.candidate.unwrap().commit_oid.0),
  )
  assert_false(semantic_json.contains(promotion.commit_oid.0))
  assert_false(semantic_json.contains("codex-cli"))
  let other_concurrency_status = @workflow.goal_status_report(
    { ..succeeded, maximum_parallel_parts: 4 },
    [integrated],
    Some(assured),
    Some(published),
    Some(adopted_pull_request),
    Some(finalization),
  ).unwrap()
  assert_eq(other_concurrency_status.semantic_run_projection, Some(projection))
  let missing_evidence = match
    @workflow.observe_goal_pull_request_readiness(
      assured_execution,
      assured,
      published,
      adopted_pull_request,
      @workflow.PullRequestLookupObservation::PullRequestStoredIdMatch({
        ..remote_pull_request,
        evidence_manifest_link_present: false,
      }),
      None,
      2L,
      48L,
      49L,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(
    missing_evidence.readiness.decision,
    @workflow.PullRequestReadinessDecision::PullRequestReadinessNeedsInput(
      @workflow.PullRequestReadinessNeedsInputReason::PullRequestEvidenceLinksMissing,
    ),
  )
  assert_true(
    @workflow.authorize_goal_execution_success(
      assured_execution, assured, published, adopted_pull_request, missing_evidence,
    )
    is Err(_),
  )
  match
    @workflow.decode_goal_pull_request_record(
      @workflow.goal_pull_request_record_bytes(adopted_pull_request),
    ) {
    Ok(decoded) => assert_eq(decoded, adopted_pull_request)
    Err(error) => fail(error.message())
  }
  let ambiguous_pull_request = match
    @workflow.authorize_goal_pull_request(
      pull_request,
      assured_execution,
      assured,
      published,
      promotion.commit_oid,
      @workflow.PullRequestLookupObservation::PullRequestMultipleMarkerMatches,
      43L,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(
    ambiguous_pull_request.intent.state,
    @workflow.PullRequestIntentState::PullRequestNeedsInput(
      @workflow.PullRequestNeedsInputReason::PullRequestAmbiguousIdentity,
    ),
  )
  let drifted_pull_request = match
    @workflow.authorize_goal_pull_request(
      pull_request,
      assured_execution,
      assured,
      published,
      promotion.commit_oid,
      @workflow.PullRequestLookupObservation::PullRequestUniqueMarkerMatch({
        ..remote_pull_request,
        observed_head_oid: @control.GitOid("other-pr-head"),
      }),
      44L,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(
    drifted_pull_request.intent.state,
    @workflow.PullRequestIntentState::PullRequestNeedsInput(
      @workflow.PullRequestNeedsInputReason::PullRequestRemoteDrift,
    ),
  )
  let edited_title_pull_request = @workflow.authorize_goal_pull_request(
    pull_request,
    assured_execution,
    assured,
    published,
    promotion.commit_oid,
    @workflow.PullRequestLookupObservation::PullRequestUniqueMarkerMatch({
      ..remote_pull_request,
      title_digest: @storage.artifact_digest(@utf8.encode("edited title")),
    }),
    44L,
  ).unwrap()
  assert_eq(
    edited_title_pull_request.intent.state,
    @workflow.PullRequestIntentState::PullRequestReceipted,
  )
  guard edited_title_pull_request.receipt is Some(edited_title_receipt) else {
    fail("edited-title pull request receipt is absent")
  }
  assert_eq(
    edited_title_receipt.observed_title_digest,
    @storage.artifact_digest(@utf8.encode("edited title")),
  )
  let edited_body_pull_request = @workflow.authorize_goal_pull_request(
    pull_request,
    assured_execution,
    assured,
    published,
    promotion.commit_oid,
    @workflow.PullRequestLookupObservation::PullRequestUniqueMarkerMatch({
      ..remote_pull_request,
      body_digest: @storage.artifact_digest(
        @utf8.encode("edited body\n" + pr_marker.0),
      ),
    }),
    44L,
  ).unwrap()
  assert_eq(
    edited_body_pull_request.intent.state,
    @workflow.PullRequestIntentState::PullRequestReceipted,
  )
  guard edited_body_pull_request.receipt is Some(edited_body_receipt) else {
    fail("edited-body pull request receipt is absent")
  }
  assert_eq(
    edited_body_receipt.observed_body_digest,
    @storage.artifact_digest(@utf8.encode("edited body\n" + pr_marker.0)),
  )
  let retargeted_pull_request = @workflow.authorize_goal_pull_request(
    pull_request,
    assured_execution,
    assured,
    published,
    promotion.commit_oid,
    @workflow.PullRequestLookupObservation::PullRequestUniqueMarkerMatch({
      ..remote_pull_request,
      base_ref: @workflow.GitRefName("refs/heads/release"),
    }),
    44L,
  ).unwrap()
  assert_eq(
    retargeted_pull_request.intent.state,
    @workflow.PullRequestIntentState::PullRequestNeedsInput(
      @workflow.PullRequestNeedsInputReason::PullRequestRemoteDrift,
    ),
  )
  let closed_pull_request = match
    @workflow.authorize_goal_pull_request(
      pull_request,
      assured_execution,
      assured,
      published,
      promotion.commit_oid,
      @workflow.PullRequestLookupObservation::PullRequestUniqueMarkerMatch({
        ..remote_pull_request,
        state: @workflow.RemotePullRequestState::RemotePullRequestClosed,
      }),
      45L,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(
    closed_pull_request.intent.state,
    @workflow.PullRequestIntentState::PullRequestNeedsInput(
      @workflow.PullRequestNeedsInputReason::PullRequestRemoteClosed,
    ),
  )
  assert_true(closed_pull_request.receipt is Some(_))
  match
    @workflow.decode_goal_assurance_record(
      @workflow.goal_assurance_record_bytes(assured),
    ) {
    Ok(decoded) => assert_eq(decoded, assured)
    Err(error) => fail(error.message())
  }
  let corrupted = { ..assured, base_commit_oid: @control.GitOid("other-base") }
  assert_true(
    @workflow.decode_goal_assurance_record(
      @workflow.goal_assurance_record_bytes(corrupted),
    )
    is Err(_),
  )
}

///|
test "cancellation preserves an authorized integration for reconciliation" {
  let authorized = authorize_next(drive_to_integration_authorized())
  guard authorized.pending_effect is Some(effect) else {
    fail("authorized integration has no pending effect")
  }
  assert_true(effect.kind is @workflow.PartEffectKind::ApplyIntegration(_, _))
  assert_eq(
    effect.lifecycle,
    @workflow.PartEffectLifecycle::PartEffectMayHaveOccurred,
  )
  let canceled = match @workflow.record_part_goal_cancellation(authorized) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  guard canceled.pending_effect is Some(pending) else {
    fail("cancellation discarded the unresolved integration")
  }
  assert_eq(pending, effect)
  assert_false(@workflow.part_cancellation_disposition_is_known(canceled))
  let repeated = match @workflow.record_part_goal_cancellation(canceled) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(repeated, canceled)
}

///|
test "verified Part cannot plan or authorize integration without audit" {
  let snapshot = drive_to_verified()
  match @workflow.plan_next_part_effect(snapshot) {
    Ok(Some({ kind: @workflow.PartEffectKind::PrepareAuditSandbox(_), .. })) =>
      ()
    _ => fail("verified Part did not require the audit Take")
  }
  let reads = @ref.new(0)
  assert_true(
    @workflow.authorize_part_integration(
      snapshot,
      workflow_digest_e,
      snapshot.identities.verification_sandbox.runtime_policy_digest,
      fn(_) {
        reads.val = reads.val + 1
        true
      },
      fn(_) {
        reads.val = reads.val + 1
        true
      },
    )
    is Err(_),
  )
  assert_eq(reads.val, 0)
  assert_true(
    @workflow.plan_part_integration(snapshot, {
      lease: {
        id: @control.IntegrationLeaseId("lease-invalid"),
        goal_id: snapshot.goal.id,
        fencing_epoch: snapshot.fencing_epoch,
        holder: "choird-test",
      },
      intent_id: @control.IntegrationIntentId("intent-invalid"),
      expected_goal_head_oid: @control.GitOid("goal-head"),
      promotion_metadata_digest: workflow_digest_a,
      git_witness_ref: "refs/choir/witness/intent-invalid",
    })
    is Err(_),
  )
}

///|
test "promotion conflict blocks the Part without minting integration evidence" {
  let audited = drive_to_audited()
  let planned = match
    @workflow.plan_part_integration(audited, {
      lease: {
        id: @control.IntegrationLeaseId("integration-lease-conflict"),
        goal_id: audited.goal.id,
        fencing_epoch: audited.fencing_epoch,
        holder: "choird-test",
      },
      intent_id: @control.IntegrationIntentId("integration-intent-conflict"),
      expected_goal_head_oid: @control.GitOid("goal-head"),
      promotion_metadata_digest: workflow_digest_c,
      git_witness_ref: "refs/choir/witness/integration-intent-conflict",
    }) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  let blocked = apply_observation(
    planned,
    @workflow.PartEffectObservation::PromotionConflictObserved({
      id: @control.IntegrationConflictId("conflict-1"),
      intent_id: @control.IntegrationIntentId("integration-intent-conflict"),
      candidate_id: planned.candidate.unwrap().id,
      candidate_commit_oid: planned.candidate.unwrap().commit_oid,
      expected_goal_head_oid: @control.GitOid("goal-head"),
      expected_goal_head_tree_oid: @control.GitOid("goal-head-tree"),
      merge_base_oid: planned.candidate.unwrap().base_commit_oid,
      conflicting_paths: [@control.RepoPath("src/feature.mbt")],
      evidence_digest: workflow_digest_a,
    }),
    26L,
  )
  assert_eq(blocked.stage, @workflow.PartWorkflowStage::PartBlocked)
  assert_true(
    blocked.part.lifecycle
    is @control.PartLifecycle::PartBlocked(
      @control.PartBlockReason::PartIntegrationConflict
    ),
  )
  guard blocked.integration_intent is Some(intent) else {
    fail("conflicted integration intent is absent")
  }
  assert_eq(
    intent.lifecycle,
    @control.IntegrationIntentLifecycle::IntegrationConflict,
  )
  assert_true(blocked.integration_receipt is None)
  assert_eq(blocked.integration_conflicts.length(), 1)
  assert_eq(blocked.effect_receipts.length(), 11)
  let conflict = blocked.integration_conflicts[0]
  let repair_contract : @control.TaskContractRevision = {
    ..blocked.task_contract,
    id: @control.RevisionId("revision-2"),
    revision: 2,
    digest: workflow_digest_d,
    repair_conflict_id: Some(conflict.id),
    base_commit_oid: conflict.expected_goal_head_oid,
    base_tree_oid: conflict.expected_goal_head_tree_oid,
  }
  let implementation = {
    ..workflow_take(
      "implementation-take-2",
      @control.TakePurpose::Implementation(blocked.part.id, repair_contract.id),
    ),
    ordinal: 2,
  }
  let verification = {
    ..workflow_take(
      "verification-take-2",
      @control.TakePurpose::PartVerification(
        blocked.part.id,
        implementation.id,
        workflow_digest_d,
      ),
    ),
    ordinal: 2,
  }
  let audit = {
    ..workflow_take(
      "audit-take-2",
      @control.TakePurpose::PartAudit(
        blocked.part.id,
        implementation.id,
        repair_contract.audit_policy_digest,
      ),
    ),
    ordinal: 2,
  }
  let implementation_sandbox = workflow_sandbox(
    "implementation-sandbox-2",
    "implementation-generation-2",
    implementation.id,
    repair_contract.implementation_capability_profile_digest,
    workflow_digest_a,
  )
  let verification_sandbox = workflow_sandbox(
    "verification-sandbox-2",
    "verification-generation-2",
    verification.id,
    repair_contract.verification_capability_profile_digest,
    workflow_digest_d,
  )
  let audit_sandbox = workflow_sandbox(
    "audit-sandbox-2",
    "audit-generation-2",
    audit.id,
    repair_contract.audit_capability_profile_digest,
    workflow_digest_e,
  )
  let repair = match
    @workflow.plan_part_conflict_repair(
      blocked,
      repair_contract,
      {
        implementation_take: implementation,
        implementation_sandbox,
        implementation_session: workflow_session(
          "implementation-session-2",
          implementation.id,
          implementation_sandbox.generation_id,
          @control.ProviderSurfaceId::ClaudeSubscriptionCli,
          workflow_digest_a,
        ),
        verification_take: verification,
        verification_sandbox,
        verification_session: workflow_session(
          "verification-session-2",
          verification.id,
          verification_sandbox.generation_id,
          @control.ProviderSurfaceId::CodexSubscriptionCli,
          workflow_digest_b,
        ),
        audit_take: audit,
        audit_sandbox,
        audit_session: workflow_session(
          "audit-session-2",
          audit.id,
          audit_sandbox.generation_id,
          @control.ProviderSurfaceId::CodexSubscriptionCli,
          workflow_digest_c,
        ),
      },
      fn(_) { true },
    ) {
    Ok(@workflow.PartConflictRepairDecision::PartConflictRepairPlanned(value)) =>
      value
    Ok(_) => fail("first conflict repair reached the retry limit")
    Err(error) => fail(error.message())
  }
  assert_eq(repair.stage, @workflow.PartWorkflowStage::PartAccepted)
  assert_eq(repair.task_contract, repair_contract)
  assert_eq(repair.task_contract_history.length(), 2)
  assert_eq(repair.prior_takes.length(), 3)
  assert_eq(repair.prior_take_evidence.length(), 1)
  assert_eq(repair.prior_take_evidence[0].candidate, blocked.candidate)
  assert_eq(repair.prior_take_evidence[0].audit_receipt, blocked.audit_receipt)
  assert_eq(repair.integration_conflicts, [conflict])
  assert_true(repair.candidate is None)
  assert_true(repair.verification_receipts.length() == 0)
  assert_true(repair.audit_receipt is None)
  assert_true(repair.integration_intent is None)
  assert_eq(
    repair.part.lifecycle,
    @control.PartLifecycle::PartExecuting(implementation.id),
  )
}

///|
test "planned and authorized effects survive snapshot restart exactly once" {
  let initial = workflow_fixture()
  let intent = match @workflow.plan_next_part_effect(initial) {
    Ok(Some(value)) => value
    _ => fail("expected initial sandbox effect")
  }
  let planned = match @workflow.persist_planned_part_effect(initial, intent) {
    Ok(value) => round_trip(value)
    Err(error) => fail(error.message())
  }
  match @workflow.plan_next_part_effect(planned) {
    Ok(Some(recovered)) => assert_eq(recovered, intent)
    _ => fail("planned effect did not survive restart")
  }
  let authorized = match @workflow.authorize_pending_part_effect(planned) {
    Ok(value) => round_trip(value)
    Err(error) => fail(error.message())
  }
  match @workflow.plan_next_part_effect(authorized) {
    Ok(Some(recovered)) => {
      assert_eq(recovered.effect_id, intent.effect_id)
      assert_eq(recovered.request_digest, intent.request_digest)
      assert_eq(
        recovered.lifecycle,
        @workflow.PartEffectLifecycle::PartEffectMayHaveOccurred,
      )
    }
    _ => fail("authorized effect was not recoverable")
  }
  let observed = match
    @workflow.apply_part_effect_observation(
      authorized,
      @workflow.PartEffectObservation::ImplementationSandboxPrepared(
        active_sandbox(initial.identities.implementation_sandbox),
      ),
      10L,
      fn(_) { true },
      fn(_) { true },
    ) {
    Ok(value) => round_trip(value)
    Err(error) => fail(error.message())
  }
  assert_eq(observed.effect_receipts.length(), 1)
  assert_true(observed.pending_effect is None)
  match @workflow.plan_next_part_effect(observed) {
    Ok(Some(next)) => assert_true(next.effect_id != intent.effect_id)
    _ => fail("workflow did not advance after receipting the observation")
  }
}
