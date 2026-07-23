///|
let goal_gate_digest_a : @control.Digest = @control.Digest(
  "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
)

///|
let goal_gate_digest_b : @control.Digest = @control.Digest(
  "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
)

///|
fn goal_gate_spec() -> @control.VerificationSpec {
  {
    id: @control.VerificationSpecId("goal-moon-test"),
    version: 1,
    digest: goal_gate_digest_a,
    process_spec_digest: goal_gate_digest_b,
  }
}

///|
fn goal_gate_seal_intent() -> @control.GoalBranchSealIntent {
  {
    id: @control.GoalBranchSealIntentId("seal-intent-1"),
    goal_id: @control.GoalId("goal-1"),
    expected_head_oid: @control.GitOid("goal-head"),
    expected_tree_oid: @control.GitOid("goal-tree"),
    integration_receipt_set_digest: goal_gate_digest_a,
    assurance_policy_revision: @control.RevisionId("assurance-1"),
    assurance_policy_digest: goal_gate_digest_b,
    seal_witness_ref: "refs/choir/goals/goal-1/sealed/seal-intent-1",
    idempotency_key: "seal-goal-1",
    lifecycle: @control.GoalBranchSealIntentLifecycle::GoalBranchSealPlanned,
  }
}

///|
fn goal_gate_verification_subject() -> @control.GoalVerificationSubject {
  {
    goal_id: @control.GoalId("goal-1"),
    goal_branch_seal_id: @control.GoalBranchSealId("seal-1"),
    goal_branch_seal_digest: goal_gate_digest_a,
    goal_head_oid: @control.GitOid("goal-head"),
    goal_tree_oid: @control.GitOid("goal-tree"),
    goal_contract_digest: goal_gate_digest_b,
    assurance_policy_revision: @control.RevisionId("assurance-1"),
    integration_receipt_set_digest: goal_gate_digest_a,
    subject_digest: goal_gate_digest_b,
  }
}

///|
fn goal_gate_verification_receipt() -> @control.GoalVerificationReceipt {
  {
    receipt_id: @control.ReceiptId("goal-verification-receipt-1"),
    verification_take_id: @control.TakeId("goal-verification-1"),
    verification_execution_id: @control.VerificationExecutionId(
      "goal-verification-execution-1",
    ),
    subject: goal_gate_verification_subject(),
    verification_spec: goal_gate_spec(),
    prepared_environment_and_image_digest: goal_gate_digest_a,
    sandbox_runtime_and_policy_digest: goal_gate_digest_b,
    subject_pre_tree_oid: @control.GitOid("goal-tree"),
    subject_post_tree_oid: @control.GitOid("goal-tree"),
    evidence: { artifact_id: "goal-evidence-1", digest: goal_gate_digest_b },
    started_at: 1L,
    finished_at: 2L,
    outcome: @control.VerificationOutcome::VerificationPassed,
  }
}

///|
fn goal_gate_audit_subject() -> @control.GoalAuditSubject {
  {
    goal_id: @control.GoalId("goal-1"),
    goal_branch_seal_id: @control.GoalBranchSealId("seal-1"),
    goal_branch_seal_digest: goal_gate_digest_a,
    goal_head_oid: @control.GitOid("goal-head"),
    goal_tree_oid: @control.GitOid("goal-tree"),
    goal_contract_digest: goal_gate_digest_b,
    assurance_policy_revision: @control.RevisionId("assurance-1"),
    integration_receipt_set_digest: goal_gate_digest_a,
    goal_verification_receipt_set_digest: goal_gate_digest_b,
    goal_verification_evidence_manifest_digest: goal_gate_digest_a,
    subject_digest: goal_gate_digest_b,
  }
}

///|
fn goal_gate_audit_result() -> @control.GoalAuditResult {
  {
    id: @control.AuditResultId("goal-audit-result-1"),
    audit_take_id: @control.TakeId("goal-audit-1"),
    take_fencing_epoch: @control.FencingEpoch(3L),
    audit_harness_session_id: @control.HarnessSessionId("goal-audit-session-1"),
    subject: goal_gate_audit_subject(),
    auditor_capability_profile_digest: goal_gate_digest_a,
    effective_surface_manifest_digest: goal_gate_digest_b,
    provider_conformance_report_digest: goal_gate_digest_a,
    audit_policy_digest: goal_gate_digest_b,
    findings_artifact: None,
    total_findings_count: 0,
    blocking_findings_count: 0,
    started_at: 3L,
    finished_at: 4L,
    outcome: @control.AuditOutcome::AuditPassed,
    result_digest: goal_gate_digest_a,
  }
}

///|
fn goal_gate_audit_receipt() -> @control.GoalAuditReceipt {
  {
    receipt_id: @control.ReceiptId("goal-audit-receipt-1"),
    audit_result_id: @control.AuditResultId("goal-audit-result-1"),
    audit_result_digest: goal_gate_digest_a,
    subject: goal_gate_audit_subject(),
    audit_take_id: @control.TakeId("goal-audit-1"),
    audit_harness_session_id: @control.HarnessSessionId("goal-audit-session-1"),
    audit_sandbox_generation_id: @control.SandboxGenerationId(
      "goal-audit-generation-1",
    ),
    auditor_capability_profile_digest: goal_gate_digest_a,
    provider_surface_id: @control.ProviderSurfaceId::CodexSubscriptionCli,
    provider_identity: "codex-cli",
    model_identity: @control.ModelIdentity::UnreportedModelIdentity,
    provider_conformance_report_digest: goal_gate_digest_a,
    audit_policy_digest: goal_gate_digest_b,
    findings_artifact: None,
    total_findings_count: 0,
    blocking_findings_count: 0,
    started_at: 3L,
    finished_at: 4L,
    outcome: @control.AuditOutcome::AuditPassed,
  }
}

///|
fn goal_gate_audit_session() -> @control.HarnessSession {
  {
    id: @control.HarnessSessionId("goal-audit-session-1"),
    take_id: @control.TakeId("goal-audit-1"),
    sandbox_generation_id: @control.SandboxGenerationId(
      "goal-audit-generation-1",
    ),
    surface: @control.ProviderSurfaceId::CodexSubscriptionCli,
    effective_surface_manifest_digest: goal_gate_digest_b,
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
test "Goal seal authorization and witness bind the exact combined tree" {
  let goal : @control.Goal = {
    id: @control.GoalId("goal-1"),
    contract_digest: goal_gate_digest_a,
    lifecycle: @control.GoalLifecycle::GoalActive(
      @control.GoalActiveCondition::GoalRunning,
    ),
  }
  let authorized = match
    @control.authorize_goal_branch_seal(
      goal,
      goal_gate_seal_intent(),
      @control.GitOid("goal-head"),
      @control.GitOid("goal-tree"),
      goal_gate_digest_a,
      @control.RevisionId("assurance-1"),
      goal_gate_digest_b,
    ) {
    Ok(value) => value
    Err(_) => fail("valid seal was not authorized")
  }
  let witnessed = match
    @control.reconcile_goal_branch_seal_witness(
      authorized,
      @control.GoalBranchSealWitnessObservation::GoalBranchSealWitnessApplied(
        @control.GitOid("goal-head"),
        @control.GitOid("goal-head"),
        @control.GitOid("goal-tree"),
      ),
    ) {
    @control.GoalBranchSealReconciliationOutcome::GoalBranchSealWitnessAccepted(
      value
    ) => value
    _ => fail("exact seal witness was rejected")
  }
  let seal : @control.GoalBranchSeal = {
    id: @control.GoalBranchSealId("seal-1"),
    intent_id: witnessed.id,
    goal_id: witnessed.goal_id,
    seal_epoch: @control.FencingEpoch(1L),
    goal_ref: "refs/heads/choir/goals/goal-1",
    seal_witness_ref: witnessed.seal_witness_ref,
    head_oid: witnessed.expected_head_oid,
    tree_oid: witnessed.expected_tree_oid,
    goal_contract_digest: goal.contract_digest,
    assurance_policy_revision: witnessed.assurance_policy_revision,
    assurance_policy_digest: witnessed.assurance_policy_digest,
    integration_receipt_set_digest: witnessed.integration_receipt_set_digest,
    sealed_at: 10L,
    seal_digest: goal_gate_digest_a,
  }
  assert_eq(
    @control.commit_goal_branch_seal(witnessed, seal),
    Ok({
      ..witnessed,
      lifecycle: @control.GoalBranchSealIntentLifecycle::GoalBranchSealed,
    }),
  )
  assert_eq(
    @control.authorize_goal_branch_seal(
      goal,
      goal_gate_seal_intent(),
      @control.GitOid("other-head"),
      @control.GitOid("goal-tree"),
      goal_gate_digest_a,
      @control.RevisionId("assurance-1"),
      goal_gate_digest_b,
    ),
    Err(@control.GoalBranchSealFailureReason::GoalBranchSealHeadDiverged),
  )
}

///|
test "Goal verification gate selects only an exact immutable tree receipt" {
  let subject = goal_gate_verification_subject()
  let receipt = goal_gate_verification_receipt()
  let slot : @control.GoalVerificationAuthorizationSlot = {
    subject_digest: subject.subject_digest,
    verification_spec: goal_gate_spec(),
    lowest_admitted_execution_ordinal: 1,
    authorizing_receipt_id: Some(receipt.receipt_id),
  }
  assert_eq(
    @control.evaluate_goal_verification_gate(
      subject,
      [goal_gate_spec()],
      [slot],
      [receipt],
      goal_gate_digest_a,
      goal_gate_digest_b,
      fn(_) { true },
    ),
    @control.VerificationGateObservation::VerificationGateValid([
      @control.ReceiptId("goal-verification-receipt-1"),
    ]),
  )
  assert_eq(
    @control.evaluate_goal_verification_gate(
      subject,
      [goal_gate_spec()],
      [slot],
      [{ ..receipt, subject_post_tree_oid: @control.GitOid("changed-tree") }],
      goal_gate_digest_a,
      goal_gate_digest_b,
      fn(_) { true },
    ),
    @control.VerificationGateObservation::VerificationGateRejected(
      @control.VerificationGateRejectionReason::VerificationTreeChanged,
    ),
  )
}

///|
test "combined audit gate is passive and structurally independent" {
  let artifact_reads : Array[@control.Digest] = []
  assert_eq(
    @control.evaluate_goal_audit_gate(
      goal_gate_audit_subject(),
      None,
      Some(goal_gate_audit_result()),
      [],
      [],
      [],
      Some(goal_gate_audit_session()),
      goal_gate_digest_a,
      goal_gate_digest_b,
      goal_gate_digest_a,
      goal_gate_digest_b,
      fn(digest) {
        artifact_reads.push(digest)
        true
      },
    ),
    @control.AuditGateObservation::AuditGateMissing,
  )
  assert_eq(artifact_reads, [])
  assert_eq(
    @control.evaluate_goal_audit_gate(
      goal_gate_audit_subject(),
      Some(goal_gate_audit_receipt()),
      Some(goal_gate_audit_result()),
      [@control.TakeId("goal-verification-1")],
      [@control.SandboxGenerationId("goal-verification-generation-1")],
      [@control.HarnessSessionId("goal-verification-session-1")],
      Some(goal_gate_audit_session()),
      goal_gate_digest_a,
      goal_gate_digest_b,
      goal_gate_digest_a,
      goal_gate_digest_b,
      fn(_) { true },
    ),
    @control.AuditGateObservation::AuditGateValid(
      @control.ReceiptId("goal-audit-receipt-1"),
    ),
  )
  assert_eq(
    @control.evaluate_goal_audit_gate(
      goal_gate_audit_subject(),
      Some(goal_gate_audit_receipt()),
      Some(goal_gate_audit_result()),
      [@control.TakeId("goal-audit-1")],
      [],
      [],
      Some(goal_gate_audit_session()),
      goal_gate_digest_a,
      goal_gate_digest_b,
      goal_gate_digest_a,
      goal_gate_digest_b,
      fn(_) { true },
    ),
    @control.AuditGateObservation::AuditGateRejected(
      @control.AuditGateRejectionReason::AuditNotIndependent,
    ),
  )
}
