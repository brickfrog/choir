///|
fn duplicate_verification_receipt(
  receipts : Array[VerificationReceipt],
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
pub fn evaluate_part_verification_gate(
  subject : PartVerificationSubject,
  specs : Array[VerificationSpec],
  slots : Array[VerificationAuthorizationSlot],
  receipts : Array[VerificationReceipt],
  expected_environment_digest : Digest,
  expected_runtime_digest : Digest,
  evidence_exists : (ArtifactReference) -> Bool,
  take_session_closed_cleanly : (TakeId) -> Bool,
) -> VerificationGateObservation {
  if duplicate_verification_receipt(receipts) {
    return VerificationGateCorrupt(VerificationDuplicateReceipt)
  }
  let selected : Array[ReceiptId] = []
  for spec in specs {
    let matching_slots : Array[VerificationAuthorizationSlot] = []
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
    let matching_receipts : Array[VerificationReceipt] = []
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
    if receipt.subject_pre_tree_oid != subject.candidate_tree_oid ||
      receipt.subject_post_tree_oid != subject.candidate_tree_oid {
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
fn audit_result_matches_receipt(
  result : AuditResult,
  receipt : AuditReceipt,
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
pub fn evaluate_part_audit_gate(
  subject : PartAuditSubject,
  receipt : AuditReceipt?,
  result : AuditResult?,
  candidate_take_id : TakeId,
  candidate_sandbox_generation_id : SandboxGenerationId,
  candidate_session_ids : Array[HarnessSessionId],
  audit_session : HarnessSession?,
  expected_capability_profile_digest : Digest,
  expected_surface_manifest_digest : Digest,
  expected_provider_conformance_digest : Digest,
  expected_audit_policy_digest : Digest,
  artifact_exists : (Digest) -> Bool,
) -> AuditGateObservation {
  let receipt = match receipt {
    Some(receipt) => receipt
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
    Some(result) => result
    None => return AuditGateCorrupt(AuditResultMismatch)
  }
  if !audit_result_matches_receipt(result, receipt) ||
    result.effective_surface_manifest_digest != expected_surface_manifest_digest {
    return AuditGateCorrupt(AuditResultMismatch)
  }
  if receipt.audit_take_id == candidate_take_id ||
    receipt.audit_sandbox_generation_id == candidate_sandbox_generation_id ||
    candidate_session_ids.contains(receipt.audit_harness_session_id) {
    return AuditGateRejected(AuditNotIndependent)
  }
  let audit_session = match audit_session {
    Some(session) => session
    None => return AuditGateRejected(AuditSessionNotCleanlyClosed)
  }
  if audit_session.id != receipt.audit_harness_session_id ||
    audit_session.take_id != receipt.audit_take_id ||
    audit_session.sandbox_generation_id != receipt.audit_sandbox_generation_id ||
    !(audit_session.lifecycle
    is HarnessSessionIngestionClosedCleanly(HarnessCompleted)) {
    return AuditGateRejected(AuditSessionNotCleanlyClosed)
  }
  if !artifact_exists(subject.verification_evidence_manifest_digest) {
    return AuditGateCorrupt(AuditArtifactMissing)
  }
  match receipt.findings_artifact {
    Some(findings) if !artifact_exists(findings.digest) =>
      AuditGateCorrupt(AuditArtifactMissing)
    _ => AuditGateValid(receipt.receipt_id)
  }
}

///|
pub fn prepare_integration_intent(
  intent : IntegrationIntent,
  promotion : PromotionCommit,
) -> Result[IntegrationIntent, @types.ChoirError] {
  if intent.lifecycle != IntegrationPlanned ||
    promotion.intent_id != intent.id ||
    promotion.first_parent_oid != intent.expected_goal_head_oid ||
    promotion.second_parent_oid != intent.candidate_commit_oid {
    return Err(
      @types.ChoirError::validation_error(
        "promotion commit does not match the planned integration intent",
      ),
    )
  }
  Ok({
    ..intent,
    lifecycle: IntegrationPrepared,
    promotion_commit_oid: Some(promotion.commit_oid),
    promotion_tree_oid: Some(promotion.tree_oid),
  })
}

///|
pub fn authorize_part_integration(
  part : GoalPart,
  candidate : CandidateCommit,
  verification_gate : VerificationGateObservation,
  audit_gate : AuditGateObservation,
  lease : GoalIntegrationLease,
  intent : IntegrationIntent,
) -> Result[IntegrationIntent, IntegrationAuthorizationFailure] {
  match part.lifecycle {
    PartAudited(actual_candidate, _, audit_receipt_id) => {
      if actual_candidate != candidate.id {
        return Err(IntegrationCandidateMismatch)
      }
      match audit_gate {
        AuditGateValid(actual_receipt_id) =>
          if actual_receipt_id != audit_receipt_id {
            return Err(IntegrationAuditInvalid)
          }
        _ => return Err(IntegrationAuditInvalid)
      }
    }
    _ => return Err(IntegrationPartNotAudited)
  }
  if !(verification_gate is VerificationGateValid(_)) {
    return Err(IntegrationVerificationInvalid)
  }
  if intent.candidate_id != candidate.id ||
    intent.candidate_commit_oid != candidate.commit_oid ||
    intent.candidate_tree_oid != candidate.tree_oid ||
    intent.goal_id != candidate.goal_id ||
    intent.part_id != candidate.part_id {
    return Err(IntegrationCandidateMismatch)
  }
  if lease.goal_id != intent.goal_id ||
    lease.fencing_epoch != intent.integration_lease_epoch {
    return Err(IntegrationLeaseMismatch)
  }
  if intent.lifecycle != IntegrationPrepared {
    return Err(IntegrationIntentNotPrepared)
  }
  Ok({ ..intent, lifecycle: IntegrationAuthorized })
}

///|
pub fn reconcile_integration_witness(
  intent : IntegrationIntent,
  promotion : PromotionCommit,
  witness : IntegrationWitnessObservation,
  receipt_id : IntegrationReceiptId,
  observed_at : Int64,
) -> IntegrationReconciliationOutcome {
  if intent.lifecycle != IntegrationAuthorized ||
    intent.promotion_commit_oid != Some(promotion.commit_oid) ||
    intent.promotion_tree_oid != Some(promotion.tree_oid) {
    return IntegrationReconciliationIntegrityError
  }
  match witness {
    IntegrationWitnessApplied(witness_oid, goal_ref_oid) =>
      if witness_oid == promotion.commit_oid &&
        goal_ref_oid == promotion.commit_oid {
        IntegrationApplied({
          id: receipt_id,
          intent_id: intent.id,
          goal_id: intent.goal_id,
          part_id: intent.part_id,
          candidate_id: intent.candidate_id,
          candidate_commit_oid: intent.candidate_commit_oid,
          candidate_tree_oid: intent.candidate_tree_oid,
          from_head_oid: intent.expected_goal_head_oid,
          promotion_commit_oid: promotion.commit_oid,
          promotion_tree_oid: promotion.tree_oid,
          witness_ref: intent.git_witness_ref,
          integrated_at: observed_at,
        })
      } else {
        IntegrationReconciliationIntegrityError
      }
    IntegrationWitnessNotApplied(goal_ref_oid) =>
      if goal_ref_oid == intent.expected_goal_head_oid {
        IntegrationRetryAuthorized
      } else {
        IntegrationReconciliationDiverged
      }
    IntegrationWitnessDiverged => IntegrationReconciliationDiverged
    IntegrationWitnessIntegrityError => IntegrationReconciliationIntegrityError
  }
}
