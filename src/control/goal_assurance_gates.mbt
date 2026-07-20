///|
pub fn authorize_goal_branch_seal(
  goal : Goal,
  intent : GoalBranchSealIntent,
  observed_head_oid : GitOid,
  observed_tree_oid : GitOid,
  integration_receipt_set_digest : Digest,
  assurance_policy_revision : RevisionId,
  assurance_policy_digest : Digest,
) -> Result[GoalBranchSealIntent, GoalBranchSealFailureReason] {
  if goal.id != intent.goal_id || goal.lifecycle != GoalActive(GoalRunning) {
    return Err(GoalBranchSealPolicyChanged)
  }
  if intent.lifecycle != GoalBranchSealPlanned ||
    intent.seal_witness_ref == "" ||
    intent.idempotency_key == "" {
    return Err(GoalBranchSealWitnessConflict)
  }
  if intent.expected_head_oid != observed_head_oid {
    return Err(GoalBranchSealHeadDiverged)
  }
  if intent.expected_tree_oid != observed_tree_oid {
    return Err(GoalBranchSealTreeDiverged)
  }
  if intent.integration_receipt_set_digest != integration_receipt_set_digest {
    return Err(GoalBranchSealReceiptSetChanged)
  }
  if intent.assurance_policy_revision != assurance_policy_revision ||
    intent.assurance_policy_digest != assurance_policy_digest {
    return Err(GoalBranchSealPolicyChanged)
  }
  Ok({ ..intent, lifecycle: GoalBranchSealAuthorized })
}

///|
pub fn reconcile_goal_branch_seal_witness(
  intent : GoalBranchSealIntent,
  witness : GoalBranchSealWitnessObservation,
) -> GoalBranchSealReconciliationOutcome {
  if intent.lifecycle != GoalBranchSealAuthorized {
    return GoalBranchSealReconciliationIntegrityError
  }
  match witness {
    GoalBranchSealWitnessApplied(witness_oid, goal_ref_oid, tree_oid) =>
      if witness_oid == intent.expected_head_oid &&
        goal_ref_oid == intent.expected_head_oid &&
        tree_oid == intent.expected_tree_oid {
        GoalBranchSealWitnessAccepted({
          ..intent,
          lifecycle: GoalBranchSealWitnessed,
        })
      } else {
        GoalBranchSealReconciliationIntegrityError
      }
    GoalBranchSealWitnessNotApplied(goal_ref_oid, tree_oid) =>
      if goal_ref_oid == intent.expected_head_oid &&
        tree_oid == intent.expected_tree_oid {
        GoalBranchSealRetryAuthorized
      } else {
        GoalBranchSealReconciliationDiverged
      }
    GoalBranchSealWitnessDiverged => GoalBranchSealReconciliationDiverged
    GoalBranchSealWitnessIntegrityError =>
      GoalBranchSealReconciliationIntegrityError
  }
}

///|
pub fn commit_goal_branch_seal(
  intent : GoalBranchSealIntent,
  seal : GoalBranchSeal,
) -> Result[GoalBranchSealIntent, GoalBranchSealFailureReason] {
  if intent.lifecycle != GoalBranchSealWitnessed ||
    seal.intent_id != intent.id ||
    seal.goal_id != intent.goal_id ||
    seal.seal_witness_ref != intent.seal_witness_ref ||
    seal.head_oid != intent.expected_head_oid ||
    seal.tree_oid != intent.expected_tree_oid ||
    seal.assurance_policy_revision != intent.assurance_policy_revision ||
    seal.assurance_policy_digest != intent.assurance_policy_digest ||
    seal.integration_receipt_set_digest != intent.integration_receipt_set_digest ||
    seal.goal_ref == "" ||
    seal.sealed_at <= 0L {
    Err(GoalBranchSealWitnessConflict)
  } else {
    Ok({ ..intent, lifecycle: GoalBranchSealed })
  }
}

///|
fn duplicate_goal_verification_receipt(
  receipts : Array[GoalVerificationReceipt],
) -> Bool {
  for index = 0; index < receipts.length(); index = index + 1 {
    for other = index + 1; other < receipts.length(); other = other + 1 {
      if receipts[index].receipt_id == receipts[other].receipt_id ||
        receipts[index].verification_execution_id ==
        receipts[other].verification_execution_id {
        return true
      }
    }
  }
  false
}

///|
pub fn evaluate_goal_verification_gate(
  subject : GoalVerificationSubject,
  specs : Array[VerificationSpec],
  slots : Array[GoalVerificationAuthorizationSlot],
  receipts : Array[GoalVerificationReceipt],
  expected_environment_digest : Digest,
  expected_runtime_digest : Digest,
  evidence_exists : (ArtifactReference) -> Bool,
  take_session_closed_cleanly : (TakeId) -> Bool,
) -> VerificationGateObservation {
  if duplicate_goal_verification_receipt(receipts) {
    return VerificationGateCorrupt(VerificationDuplicateReceipt)
  }
  let selected : Array[ReceiptId] = []
  for spec in specs {
    let matching_slots : Array[GoalVerificationAuthorizationSlot] = []
    for slot in slots {
      if slot.verification_spec.id == spec.id {
        matching_slots.push(slot)
      }
    }
    if matching_slots.length() == 0 {
      return VerificationGateRejected(VerificationMissingSlot)
    }
    if matching_slots.length() > 1 {
      return VerificationGateCorrupt(VerificationDuplicateSlot)
    }
    let slot = matching_slots[0]
    if slot.subject_digest != subject.subject_digest {
      return VerificationGateStale(VerificationStaleSubject)
    }
    if slot.verification_spec != spec {
      return VerificationGateStale(VerificationStaleSpec)
    }
    let receipt_id = match slot.authorizing_receipt_id {
      Some(id) => id
      None => return VerificationGateRejected(VerificationMissingReceipt)
    }
    let matching_receipts : Array[GoalVerificationReceipt] = []
    for receipt in receipts {
      if receipt.receipt_id == receipt_id {
        matching_receipts.push(receipt)
      }
    }
    if matching_receipts.length() == 0 {
      return VerificationGateRejected(VerificationMissingReceipt)
    }
    if matching_receipts.length() > 1 {
      return VerificationGateCorrupt(VerificationDuplicateReceipt)
    }
    let receipt = matching_receipts[0]
    if receipt.subject != subject {
      return VerificationGateStale(VerificationStaleSubject)
    }
    if receipt.verification_spec != spec {
      return VerificationGateStale(VerificationStaleSpec)
    }
    if receipt.prepared_environment_and_image_digest !=
      expected_environment_digest {
      return VerificationGateStale(VerificationStaleEnvironment)
    }
    if receipt.sandbox_runtime_and_policy_digest != expected_runtime_digest {
      return VerificationGateStale(VerificationStaleRuntime)
    }
    if receipt.outcome != VerificationPassed {
      return VerificationGateRejected(VerificationOutcomeNotPassing)
    }
    if receipt.subject_pre_tree_oid != subject.goal_tree_oid ||
      receipt.subject_post_tree_oid != subject.goal_tree_oid {
      return VerificationGateRejected(VerificationTreeChanged)
    }
    if !evidence_exists(receipt.evidence) {
      return VerificationGateCorrupt(VerificationEvidenceMissing)
    }
    if !take_session_closed_cleanly(receipt.verification_take_id) {
      return VerificationGateRejected(VerificationSessionNotCleanlyClosed)
    }
    selected.push(receipt_id)
  }
  VerificationGateValid(selected)
}

///|
fn goal_audit_result_matches_receipt(
  result : GoalAuditResult,
  receipt : GoalAuditReceipt,
) -> Bool {
  result.id == receipt.audit_result_id &&
  result.result_digest == receipt.audit_result_digest &&
  result.subject == receipt.subject &&
  result.audit_take_id == receipt.audit_take_id &&
  result.audit_harness_session_id == receipt.audit_harness_session_id &&
  result.auditor_capability_profile_digest ==
  receipt.auditor_capability_profile_digest &&
  result.provider_conformance_report_digest ==
  receipt.provider_conformance_report_digest &&
  result.audit_policy_digest == receipt.audit_policy_digest &&
  result.findings_artifact == receipt.findings_artifact &&
  result.total_findings_count == receipt.total_findings_count &&
  result.blocking_findings_count == receipt.blocking_findings_count &&
  result.started_at == receipt.started_at &&
  result.finished_at == receipt.finished_at &&
  result.outcome == receipt.outcome
}

///|
pub fn evaluate_goal_audit_gate(
  subject : GoalAuditSubject,
  receipt : GoalAuditReceipt?,
  result : GoalAuditResult?,
  prohibited_take_ids : Array[TakeId],
  prohibited_sandbox_generation_ids : Array[SandboxGenerationId],
  prohibited_session_ids : Array[HarnessSessionId],
  audit_session : HarnessSession?,
  expected_capability_profile_digest : Digest,
  expected_surface_manifest_digest : Digest,
  expected_provider_conformance_digest : Digest,
  expected_audit_policy_digest : Digest,
  artifact_exists : (Digest) -> Bool,
) -> AuditGateObservation {
  let receipt = match receipt {
    Some(value) => value
    None => return AuditGateMissing
  }
  if receipt.subject != subject {
    return AuditGateStale(AuditStaleSubject)
  }
  if receipt.audit_policy_digest != expected_audit_policy_digest {
    return AuditGateStale(AuditStalePolicy)
  }
  if receipt.auditor_capability_profile_digest !=
    expected_capability_profile_digest {
    return AuditGateStale(AuditStaleCapabilityProfile)
  }
  if receipt.provider_conformance_report_digest !=
    expected_provider_conformance_digest {
    return AuditGateStale(AuditStaleProviderConformance)
  }
  if receipt.outcome != AuditPassed {
    return AuditGateRejected(AuditOutcomeNotPassing)
  }
  if receipt.total_findings_count != 0 || receipt.blocking_findings_count != 0 {
    return AuditGateRejected(AuditHasBlockingFindings)
  }
  let result = match result {
    Some(value) => value
    None => return AuditGateCorrupt(AuditResultMismatch)
  }
  if !goal_audit_result_matches_receipt(result, receipt) ||
    result.effective_surface_manifest_digest != expected_surface_manifest_digest {
    return AuditGateCorrupt(AuditResultMismatch)
  }
  if prohibited_take_ids.contains(receipt.audit_take_id) ||
    prohibited_sandbox_generation_ids.contains(
      receipt.audit_sandbox_generation_id,
    ) ||
    prohibited_session_ids.contains(receipt.audit_harness_session_id) {
    return AuditGateRejected(AuditNotIndependent)
  }
  let audit_session = match audit_session {
    Some(value) => value
    None => return AuditGateRejected(AuditSessionNotCleanlyClosed)
  }
  if audit_session.id != receipt.audit_harness_session_id ||
    audit_session.take_id != receipt.audit_take_id ||
    audit_session.sandbox_generation_id != receipt.audit_sandbox_generation_id ||
    !(audit_session.lifecycle
    is HarnessSessionIngestionClosedCleanly(HarnessCompleted)) {
    return AuditGateRejected(AuditSessionNotCleanlyClosed)
  }
  if !artifact_exists(subject.goal_verification_evidence_manifest_digest) {
    return AuditGateCorrupt(AuditArtifactMissing)
  }
  match receipt.findings_artifact {
    Some(findings) if !artifact_exists(findings.digest) =>
      AuditGateCorrupt(AuditArtifactMissing)
    _ => AuditGateValid(receipt.receipt_id)
  }
}
