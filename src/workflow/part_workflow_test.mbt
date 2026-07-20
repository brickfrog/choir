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
test "Part reaches a verified audited integration result" {
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
    @workflow.PartEffectObservation::PromotionConflictObserved,
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
  assert_eq(blocked.effect_receipts.length(), 11)
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
