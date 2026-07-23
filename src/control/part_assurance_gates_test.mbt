///|
let gate_digest_a : @control.Digest = @control.Digest(
  "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
)

///|
let gate_digest_b : @control.Digest = @control.Digest(
  "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
)

///|
fn gate_spec() -> @control.VerificationSpec {
  {
    id: @control.VerificationSpecId("moon-test"),
    version: 1,
    digest: gate_digest_a,
    process_spec_digest: gate_digest_b,
  }
}

///|
fn gate_verification_subject() -> @control.PartVerificationSubject {
  {
    part_id: @control.PartId("part-1"),
    candidate_take_id: @control.TakeId("implementation-1"),
    candidate_commit_oid: @control.GitOid("candidate-oid"),
    candidate_tree_oid: @control.GitOid("candidate-tree"),
    task_contract_revision_id: @control.RevisionId("revision-1"),
    task_contract_digest: gate_digest_a,
    subject_digest: gate_digest_b,
  }
}

///|
fn gate_verification_receipt() -> @control.VerificationReceipt {
  {
    receipt_id: @control.ReceiptId("verification-receipt-1"),
    verification_take_id: @control.TakeId("verification-1"),
    verification_execution_id: @control.VerificationExecutionId(
      "verification-execution-1",
    ),
    subject: gate_verification_subject(),
    verification_spec: gate_spec(),
    prepared_environment_and_image_digest: gate_digest_a,
    sandbox_runtime_and_policy_digest: gate_digest_b,
    subject_pre_tree_oid: @control.GitOid("candidate-tree"),
    subject_post_tree_oid: @control.GitOid("candidate-tree"),
    evidence: { artifact_id: "evidence-1", digest: gate_digest_b },
    started_at: 1L,
    finished_at: 2L,
    outcome: @control.VerificationOutcome::VerificationPassed,
  }
}

///|
fn gate_audit_subject() -> @control.PartAuditSubject {
  {
    part_id: @control.PartId("part-1"),
    candidate_take_id: @control.TakeId("implementation-1"),
    candidate_commit_oid: @control.GitOid("candidate-oid"),
    candidate_tree_oid: @control.GitOid("candidate-tree"),
    task_contract_revision_id: @control.RevisionId("revision-1"),
    task_contract_digest: gate_digest_a,
    verification_receipt_set_digest: gate_digest_a,
    verification_evidence_manifest_digest: gate_digest_b,
    subject_digest: gate_digest_a,
  }
}

///|
fn gate_audit_result() -> @control.AuditResult {
  {
    id: @control.AuditResultId("audit-result-1"),
    audit_take_id: @control.TakeId("audit-1"),
    take_fencing_epoch: @control.FencingEpoch(3L),
    audit_harness_session_id: @control.HarnessSessionId("audit-session-1"),
    subject: gate_audit_subject(),
    auditor_capability_profile_digest: gate_digest_a,
    effective_surface_manifest_digest: gate_digest_b,
    provider_conformance_report_digest: gate_digest_a,
    audit_policy_digest: gate_digest_b,
    findings_artifact: None,
    total_findings_count: 0,
    blocking_findings_count: 0,
    started_at: 3L,
    finished_at: 4L,
    outcome: @control.AuditOutcome::AuditPassed,
    result_digest: gate_digest_a,
  }
}

///|
fn gate_audit_receipt() -> @control.AuditReceipt {
  {
    receipt_id: @control.ReceiptId("audit-receipt-1"),
    audit_result_id: @control.AuditResultId("audit-result-1"),
    audit_result_digest: gate_digest_a,
    subject: gate_audit_subject(),
    audit_take_id: @control.TakeId("audit-1"),
    audit_harness_session_id: @control.HarnessSessionId("audit-session-1"),
    audit_sandbox_generation_id: @control.SandboxGenerationId(
      "audit-generation-1",
    ),
    auditor_capability_profile_digest: gate_digest_a,
    provider_surface_id: @control.ProviderSurfaceId::ClaudeSubscriptionCli,
    provider_identity: "claude-code-2.1.217",
    model_identity: @control.ModelIdentity::ReportedModelIdentity("claude-opus"),
    provider_conformance_report_digest: gate_digest_a,
    audit_policy_digest: gate_digest_b,
    findings_artifact: None,
    total_findings_count: 0,
    blocking_findings_count: 0,
    started_at: 3L,
    finished_at: 4L,
    outcome: @control.AuditOutcome::AuditPassed,
  }
}

///|
fn gate_audit_session() -> @control.HarnessSession {
  {
    id: @control.HarnessSessionId("audit-session-1"),
    take_id: @control.TakeId("audit-1"),
    sandbox_generation_id: @control.SandboxGenerationId("audit-generation-1"),
    surface: @control.ProviderSurfaceId::ClaudeSubscriptionCli,
    effective_surface_manifest_digest: gate_digest_b,
    cursor_class: @control.HarnessCursorClass::HarnessCursorNotResumable,
    provider_cursor: None,
    last_choir_sequence: @control.EventSequence(2L),
    open_tool_execution_ids: [],
    lifecycle: @control.HarnessSessionLifecycle::HarnessSessionIngestionClosedCleanly(
      @control.HarnessTerminalObservation::HarnessCompleted,
    ),
  }
}

///|
test "verification gate selects the exact passing immutable receipt" {
  let subject = gate_verification_subject()
  let receipt = gate_verification_receipt()
  let slot : @control.VerificationAuthorizationSlot = {
    subject_digest: subject.subject_digest,
    verification_spec: gate_spec(),
    lowest_admitted_execution_ordinal: 1,
    authorizing_receipt_id: Some(receipt.receipt_id),
  }
  assert_eq(
    @control.evaluate_part_verification_gate(
      subject,
      [gate_spec()],
      [slot],
      [receipt],
      gate_digest_a,
      gate_digest_b,
      fn(_) { true },
    ),
    @control.VerificationGateObservation::VerificationGateValid([
      @control.ReceiptId("verification-receipt-1"),
    ]),
  )
  assert_eq(
    @control.evaluate_part_verification_gate(
      subject,
      [gate_spec()],
      [slot],
      [{ ..receipt, subject_post_tree_oid: @control.GitOid("changed-tree") }],
      gate_digest_a,
      gate_digest_b,
      fn(_) { true },
    ),
    @control.VerificationGateObservation::VerificationGateRejected(
      @control.VerificationGateRejectionReason::VerificationTreeChanged,
    ),
  )
}

///|
test "missing audit gate is passive and emits no artifact read" {
  let artifact_reads : Array[@control.Digest] = []
  let observation = @control.evaluate_part_audit_gate(
    gate_audit_subject(),
    None,
    Some(gate_audit_result()),
    @control.TakeId("implementation-1"),
    @control.SandboxGenerationId("implementation-generation-1"),
    [@control.HarnessSessionId("implementation-session-1")],
    Some(gate_audit_session()),
    gate_digest_a,
    gate_digest_b,
    gate_digest_a,
    gate_digest_b,
    fn(digest) {
      artifact_reads.push(digest)
      true
    },
  )
  assert_eq(observation, @control.AuditGateObservation::AuditGateMissing)
  assert_eq(artifact_reads, [])
}

///|
test "audit gate requires fresh sandbox session and exact result" {
  let valid = @control.evaluate_part_audit_gate(
    gate_audit_subject(),
    Some(gate_audit_receipt()),
    Some(gate_audit_result()),
    @control.TakeId("implementation-1"),
    @control.SandboxGenerationId("implementation-generation-1"),
    [@control.HarnessSessionId("implementation-session-1")],
    Some(gate_audit_session()),
    gate_digest_a,
    gate_digest_b,
    gate_digest_a,
    gate_digest_b,
    fn(_) { true },
  )
  assert_eq(
    valid,
    @control.AuditGateObservation::AuditGateValid(
      @control.ReceiptId("audit-receipt-1"),
    ),
  )
  let non_independent = {
    ..gate_audit_receipt(),
    audit_sandbox_generation_id: @control.SandboxGenerationId(
      "implementation-generation-1",
    ),
  }
  assert_eq(
    @control.evaluate_part_audit_gate(
      gate_audit_subject(),
      Some(non_independent),
      Some(gate_audit_result()),
      @control.TakeId("implementation-1"),
      @control.SandboxGenerationId("implementation-generation-1"),
      [@control.HarnessSessionId("implementation-session-1")],
      Some(gate_audit_session()),
      gate_digest_a,
      gate_digest_b,
      gate_digest_a,
      gate_digest_b,
      fn(_) { true },
    ),
    @control.AuditGateObservation::AuditGateRejected(
      @control.AuditGateRejectionReason::AuditNotIndependent,
    ),
  )
}

///|
test "integration authorization and witness bind the audited candidate" {
  let candidate = assurance_candidate([@control.RepoPath("src/a.mbt")])
  let part : @control.GoalPart = {
    id: @control.PartId("part-1"),
    goal_id: @control.GoalId("goal-1"),
    dependency_ids: [],
    task_contract_revision_id: @control.RevisionId("revision-1"),
    lifecycle: @control.PartLifecycle::PartAudited(
      candidate.id,
      gate_digest_a,
      @control.ReceiptId("audit-receipt-1"),
    ),
  }
  let planned : @control.IntegrationIntent = {
    id: @control.IntegrationIntentId("intent-1"),
    goal_id: @control.GoalId("goal-1"),
    part_id: @control.PartId("part-1"),
    candidate_id: candidate.id,
    candidate_commit_oid: candidate.commit_oid,
    candidate_tree_oid: candidate.tree_oid,
    expected_goal_head_oid: @control.GitOid("goal-head"),
    strategy: @control.PromotionStrategy::NoFastForwardThreeWayV1,
    promotion_metadata_digest: gate_digest_b,
    integration_lease_epoch: @control.FencingEpoch(7L),
    lifecycle: @control.IntegrationIntentLifecycle::IntegrationPlanned,
    promotion_commit_oid: None,
    promotion_tree_oid: None,
    git_witness_ref: "refs/choir/witness/intent-1",
  }
  let promotion : @control.PromotionCommit = {
    intent_id: planned.id,
    commit_oid: @control.GitOid("promotion-oid"),
    tree_oid: @control.GitOid("promotion-tree"),
    first_parent_oid: @control.GitOid("goal-head"),
    second_parent_oid: candidate.commit_oid,
  }
  let prepared = match @control.prepare_integration_intent(planned, promotion) {
    Ok(intent) => intent
    Err(error) => fail(error.message())
  }
  let lease : @control.GoalIntegrationLease = {
    id: @control.IntegrationLeaseId("lease-1"),
    goal_id: @control.GoalId("goal-1"),
    fencing_epoch: @control.FencingEpoch(7L),
    holder: "choird-1",
  }
  let authorized = match
    @control.authorize_part_integration(
      part,
      candidate,
      @control.VerificationGateObservation::VerificationGateValid([
        @control.ReceiptId("verification-receipt-1"),
      ]),
      @control.AuditGateObservation::AuditGateValid(
        @control.ReceiptId("audit-receipt-1"),
      ),
      lease,
      prepared,
    ) {
    Ok(intent) => intent
    Err(_) => fail("expected integration authorization")
  }
  match
    @control.reconcile_integration_witness(
      authorized,
      promotion,
      @control.IntegrationWitnessObservation::IntegrationWitnessApplied(
        promotion.commit_oid,
        promotion.commit_oid,
      ),
      @control.IntegrationReceiptId("integration-receipt-1"),
      10L,
    ) {
    @control.IntegrationReconciliationOutcome::IntegrationApplied(receipt) => {
      assert_eq(receipt.candidate_id, candidate.id)
      assert_eq(receipt.from_head_oid, @control.GitOid("goal-head"))
      assert_eq(receipt.promotion_commit_oid, promotion.commit_oid)
    }
    _ => fail("expected applied integration receipt")
  }
}
