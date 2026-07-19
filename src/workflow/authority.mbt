///|
fn record_verification_completion(
  snapshot : OnePartWorkflowSnapshot,
  observation : OnePartEffectObservation,
  result : VerificationExecutionResult,
  final_session : @control.HarnessSession,
  events : Array[@control.HarnessEventEnvelope],
  observed_at : Int64,
  artifact_exists : (@control.ArtifactReference) -> Bool,
) -> Result[OnePartWorkflowSnapshot, @types.ChoirError] {
  let intent = match authorized_effect(snapshot) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match intent.kind {
    DispatchVerification(take_id, session_id, subject) =>
      if take_id != result.take_id ||
        session_id != result.session_id ||
        subject != result.subject {
        return Err(workflow_error("verification result does not match intent"))
      }
    _ => return Err(workflow_error("verification result has the wrong effect"))
  }
  let subject = match snapshot.verification_subject {
    Some(value) => value
    None => return Err(workflow_error("verification subject is missing"))
  }
  if result.take_id != snapshot.verification_take.id ||
    result.subject != subject ||
    result.verification_spec != snapshot.task_contract.verification_specs[0] ||
    !artifact_exists(result.evidence) {
    return Err(workflow_error("verification result is stale or incomplete"))
  }
  let initial = match
    find_harness_session(snapshot.harness_sessions, result.session_id) {
    Some(value) => value
    None => return Err(workflow_error("verification session is missing"))
  }
  let (closed, durable_events) = match
    validate_closed_trace(initial, events, final_session) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let sessions = match
    replace_harness_session(snapshot.harness_sessions, closed) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let receipt_id = @control.ReceiptId(
    snapshot.workflow_id + ":verification-receipt-1",
  )
  let receipt : @control.VerificationReceipt = {
    receipt_id,
    verification_take_id: result.take_id,
    verification_execution_id: result.verification_execution_id,
    subject,
    verification_spec: result.verification_spec,
    prepared_environment_and_image_digest: result.environment_and_image_digest,
    sandbox_runtime_and_policy_digest: result.runtime_and_policy_digest,
    subject_pre_tree_oid: result.subject_pre_tree_oid,
    subject_post_tree_oid: result.subject_post_tree_oid,
    evidence: result.evidence,
    started_at: result.started_at,
    finished_at: result.finished_at,
    outcome: result.outcome,
  }
  let slot : @control.VerificationAuthorizationSlot = {
    subject_digest: subject.subject_digest,
    verification_spec: result.verification_spec,
    lowest_admitted_execution_ordinal: 1,
    authorizing_receipt_id: if result.outcome ==
      @control.VerificationOutcome::VerificationPassed {
      Some(receipt_id)
    } else {
      None
    },
  }
  let receipts = [receipt]
  let slots = [slot]
  let gate = @control.evaluate_part_verification_gate(
    subject,
    snapshot.task_contract.verification_specs,
    slots,
    receipts,
    result.environment_and_image_digest,
    result.runtime_and_policy_digest,
    fn(evidence) { artifact_exists(evidence) },
    fn(take_id) {
      take_id == result.take_id &&
      closed.lifecycle
      is @control.HarnessSessionLifecycle::HarnessSessionIngestionClosedCleanly(
        @control.HarnessTerminalObservation::HarnessCompleted
      )
    },
  )
  let result_digest = domain_digest(
    "choir.verification-execution-result.v1",
    result.to_json(),
  )
  let take = match
    take_terminal_after_verification(
      snapshot.verification_take,
      snapshot.fencing_epoch,
      result_digest,
      result.outcome,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match gate {
    @control.VerificationGateObservation::VerificationGateValid(receipt_ids) => {
      let authorization : @control.VerificationAuthorizationSet = {
        subject_digest: subject.subject_digest,
        receipt_ids,
        receipt_set_digest: domain_digest(
          "choir.verification-authorization-set.v1",
          receipts.to_json(),
        ),
        evidence_manifest_digest: domain_digest(
          "choir.verification-evidence-manifest.v1",
          [result.evidence].to_json(),
        ),
      }
      let candidate = match snapshot.candidate {
        Some(value) => value
        None => return Err(workflow_error("candidate is missing"))
      }
      let part = match
        @control.transition_part(
          snapshot.part,
          @control.PartTransition::RecordPartVerification(
            candidate.id,
            authorization.receipt_set_digest,
          ),
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let audit_subject = audit_subject(subject, authorization)
      let audit_take = {
        ..snapshot.audit_take,
        purpose: @control.TakePurpose::PartAudit(
          snapshot.part.id,
          snapshot.implementation_take.id,
          audit_subject.subject_digest,
        ),
      }
      finish_effect_observation(
        snapshot,
        {
          ..snapshot,
          stage: OnePartVerified,
          part,
          verification_take: take,
          audit_take,
          harness_sessions: sessions,
          harness_events: append_events(snapshot.harness_events, durable_events),
          verification_slots: slots,
          verification_receipts: receipts,
          verification_authorization: Some(authorization),
          audit_subject: Some(audit_subject),
        },
        observation,
        observed_at,
      )
    }
    _ => {
      let part = match
        @control.transition_part(
          snapshot.part,
          @control.PartTransition::BlockPart(
            @control.PartBlockReason::PartVerificationFailed,
          ),
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      finish_effect_observation(
        snapshot,
        {
          ..snapshot,
          stage: OnePartBlocked,
          part,
          verification_take: take,
          harness_sessions: sessions,
          harness_events: append_events(snapshot.harness_events, durable_events),
          verification_slots: slots,
          verification_receipts: receipts,
        },
        observation,
        observed_at,
      )
    }
  }
}

///|
fn audit_submission_valid(submission : AuditSubmission) -> Bool {
  if submission.total_findings_count < 0 ||
    submission.blocking_findings_count < 0 ||
    submission.blocking_findings_count > submission.total_findings_count ||
    submission.finished_at < submission.started_at {
    return false
  }
  match submission.outcome {
    @control.AuditOutcome::AuditPassed =>
      submission.total_findings_count == 0 &&
      submission.blocking_findings_count == 0 &&
      submission.findings_artifact is None
    @control.AuditOutcome::AuditFindings =>
      submission.total_findings_count > 0 &&
      submission.findings_artifact is Some(_)
    @control.AuditOutcome::AuditFailed
    | @control.AuditOutcome::AuditInterrupted => true
  }
}

///|
fn record_audit_completion(
  snapshot : OnePartWorkflowSnapshot,
  observation : OnePartEffectObservation,
  submission : AuditSubmission,
  final_session : @control.HarnessSession,
  events : Array[@control.HarnessEventEnvelope],
  observed_at : Int64,
  artifact_exists : (@control.ArtifactReference) -> Bool,
) -> Result[OnePartWorkflowSnapshot, @types.ChoirError] {
  let intent = match authorized_effect(snapshot) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match intent.kind {
    DispatchAudit(take_id, session_id, subject) =>
      if take_id != submission.audit_take_id ||
        session_id != submission.audit_harness_session_id ||
        subject != submission.subject {
        return Err(workflow_error("audit submission does not match intent"))
      }
    _ => return Err(workflow_error("audit submission has the wrong effect"))
  }
  let subject = match snapshot.audit_subject {
    Some(value) => value
    None => return Err(workflow_error("audit subject is missing"))
  }
  if submission.audit_take_id != snapshot.audit_take.id ||
    submission.take_fencing_epoch != snapshot.fencing_epoch ||
    submission.subject != subject ||
    !audit_submission_valid(submission) {
    return Err(workflow_error("audit submission is stale or invalid"))
  }
  match submission.findings_artifact {
    Some(findings) if !artifact_exists(findings) =>
      return Err(workflow_error("audit findings artifact is missing"))
    _ => ()
  }
  let initial = match
    find_harness_session(
      snapshot.harness_sessions,
      submission.audit_harness_session_id,
    ) {
    Some(value) => value
    None => return Err(workflow_error("audit session is missing"))
  }
  let (closed, durable_events) = match
    validate_closed_trace(initial, events, final_session) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let sessions = match
    replace_harness_session(snapshot.harness_sessions, closed) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let result_id = @control.AuditResultId(snapshot.workflow_id + ":audit-result")
  let result_identity = [
    result_id.to_json(),
    submission.to_json(),
    snapshot.task_contract.audit_capability_profile_digest.to_json(),
    closed.effective_surface_manifest_digest.to_json(),
    snapshot.task_contract.audit_policy_digest.to_json(),
  ].to_json()
  let result_digest = domain_digest("choir.audit-result.v1", result_identity)
  let result : @control.AuditResult = {
    id: result_id,
    audit_take_id: submission.audit_take_id,
    take_fencing_epoch: submission.take_fencing_epoch,
    audit_harness_session_id: submission.audit_harness_session_id,
    subject,
    auditor_capability_profile_digest: snapshot.task_contract.audit_capability_profile_digest,
    effective_surface_manifest_digest: closed.effective_surface_manifest_digest,
    provider_conformance_report_digest: submission.provider_conformance_report_digest,
    audit_policy_digest: snapshot.task_contract.audit_policy_digest,
    findings_artifact: submission.findings_artifact,
    total_findings_count: submission.total_findings_count,
    blocking_findings_count: submission.blocking_findings_count,
    started_at: submission.started_at,
    finished_at: submission.finished_at,
    outcome: submission.outcome,
    result_digest,
  }
  let take = match
    take_terminal_after_audit(
      snapshot.audit_take,
      snapshot.fencing_epoch,
      result_digest,
      submission.outcome,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  finish_effect_observation(
    snapshot,
    {
      ..snapshot,
      stage: OnePartAuditResultRecorded,
      audit_take: take,
      harness_sessions: sessions,
      harness_events: append_events(snapshot.harness_events, durable_events),
      audit_result: Some(result),
    },
    observation,
    observed_at,
  )
}

///|
pub fn mint_one_part_audit_receipt(
  snapshot : OnePartWorkflowSnapshot,
  metadata : AuditReceiptMetadata,
  artifact_exists : (@control.Digest) -> Bool,
) -> Result[OnePartWorkflowSnapshot, @types.ChoirError] {
  if snapshot.stage != OnePartAuditResultRecorded ||
    snapshot.pending_effect is Some(_) ||
    snapshot.audit_receipt is Some(_) {
    return Err(workflow_error("audit receipt is not ready to reconcile"))
  }
  let result = match snapshot.audit_result {
    Some(value) => value
    None => return Err(workflow_error("durable audit result is missing"))
  }
  let session = match
    find_harness_session(
      snapshot.harness_sessions,
      result.audit_harness_session_id,
    ) {
    Some(value) => value
    None => return Err(workflow_error("durable audit session is missing"))
  }
  let receipt : @control.AuditReceipt = {
    receipt_id: metadata.receipt_id,
    audit_result_id: result.id,
    audit_result_digest: result.result_digest,
    subject: result.subject,
    audit_take_id: result.audit_take_id,
    audit_harness_session_id: result.audit_harness_session_id,
    audit_sandbox_generation_id: session.sandbox_generation_id,
    auditor_capability_profile_digest: result.auditor_capability_profile_digest,
    provider_surface_id: metadata.provider_surface_id,
    provider_identity: metadata.provider_identity,
    model_identity: metadata.model_identity,
    provider_conformance_report_digest: result.provider_conformance_report_digest,
    audit_policy_digest: result.audit_policy_digest,
    findings_artifact: result.findings_artifact,
    total_findings_count: result.total_findings_count,
    blocking_findings_count: result.blocking_findings_count,
    started_at: result.started_at,
    finished_at: result.finished_at,
    outcome: result.outcome,
  }
  let candidate_generation = snapshot.identities.implementation_sandbox.generation_id
  let candidate_sessions : Array[@control.HarnessSessionId] = []
  for candidate_session in snapshot.harness_sessions {
    if candidate_session.take_id == snapshot.implementation_take.id {
      candidate_sessions.push(candidate_session.id)
    }
  }
  let gate = @control.evaluate_part_audit_gate(
    result.subject,
    Some(receipt),
    Some(result),
    snapshot.implementation_take.id,
    candidate_generation,
    candidate_sessions,
    Some(session),
    snapshot.task_contract.audit_capability_profile_digest,
    session.effective_surface_manifest_digest,
    result.provider_conformance_report_digest,
    snapshot.task_contract.audit_policy_digest,
    artifact_exists,
  )
  match gate {
    @control.AuditGateObservation::AuditGateValid(receipt_id) => {
      let candidate = match snapshot.candidate {
        Some(value) => value
        None => return Err(workflow_error("candidate is missing"))
      }
      let part = match
        @control.transition_part(
          snapshot.part,
          @control.PartTransition::RecordPartAudit(candidate.id, receipt_id),
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      Ok({
        ..snapshot,
        durable_version: snapshot.durable_version + 1,
        stage: OnePartAudited,
        part,
        audit_receipt: Some(receipt),
      })
    }
    @control.AuditGateObservation::AuditGateRejected(_) => {
      let part = match
        @control.transition_part(
          snapshot.part,
          @control.PartTransition::BlockPart(
            @control.PartBlockReason::PartAuditFindings,
          ),
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      Ok({
        ..snapshot,
        durable_version: snapshot.durable_version + 1,
        stage: OnePartBlocked,
        part,
        audit_receipt: Some(receipt),
      })
    }
    _ => Err(workflow_error("audit receipt failed authority validation"))
  }
}

///|
pub fn plan_one_part_integration(
  snapshot : OnePartWorkflowSnapshot,
  input : IntegrationPlanInput,
) -> Result[OnePartWorkflowSnapshot, @types.ChoirError] {
  if snapshot.stage != OnePartAudited ||
    snapshot.pending_effect is Some(_) ||
    snapshot.integration_intent is Some(_) ||
    input.lease.goal_id != snapshot.goal.id ||
    input.lease.fencing_epoch != snapshot.fencing_epoch {
    return Err(workflow_error("integration plan is not admissible"))
  }
  let candidate = match snapshot.candidate {
    Some(value) => value
    None => return Err(workflow_error("audited candidate is missing"))
  }
  let intent : @control.IntegrationIntent = {
    id: input.intent_id,
    goal_id: snapshot.goal.id,
    part_id: snapshot.part.id,
    candidate_id: candidate.id,
    candidate_commit_oid: candidate.commit_oid,
    candidate_tree_oid: candidate.tree_oid,
    expected_goal_head_oid: input.expected_goal_head_oid,
    strategy: @control.PromotionStrategy::NoFastForwardThreeWayV1,
    promotion_metadata_digest: input.promotion_metadata_digest,
    integration_lease_epoch: input.lease.fencing_epoch,
    lifecycle: @control.IntegrationIntentLifecycle::IntegrationPlanned,
    promotion_commit_oid: None,
    promotion_tree_oid: None,
    git_witness_ref: input.git_witness_ref,
  }
  Ok({
    ..snapshot,
    durable_version: snapshot.durable_version + 1,
    stage: OnePartIntegrationPlanned,
    integration_lease: Some(input.lease),
    integration_intent: Some(intent),
  })
}

///|
fn record_promotion_generation(
  snapshot : OnePartWorkflowSnapshot,
  observation : OnePartEffectObservation,
  promotion : @control.PromotionCommit,
  observed_at : Int64,
) -> Result[OnePartWorkflowSnapshot, @types.ChoirError] {
  let effect = match authorized_effect(snapshot) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let intent = match snapshot.integration_intent {
    Some(value) => value
    None => return Err(workflow_error("integration intent is missing"))
  }
  match effect.kind {
    GeneratePromotion(expected) if expected == intent => ()
    _ => return Err(workflow_error("promotion does not match its intent"))
  }
  let prepared = match @control.prepare_integration_intent(intent, promotion) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  finish_effect_observation(
    snapshot,
    {
      ..snapshot,
      stage: OnePartPromotionPrepared,
      integration_intent: Some(prepared),
      promotion_commit: Some(promotion),
    },
    observation,
    observed_at,
  )
}

///|
pub fn authorize_one_part_integration(
  snapshot : OnePartWorkflowSnapshot,
  expected_verification_environment_digest : @control.Digest,
  expected_verification_runtime_digest : @control.Digest,
  evidence_exists : (@control.ArtifactReference) -> Bool,
  artifact_digest_exists : (@control.Digest) -> Bool,
) -> Result[OnePartWorkflowSnapshot, @types.ChoirError] {
  if snapshot.stage != OnePartPromotionPrepared ||
    snapshot.pending_effect is Some(_) {
    return Err(workflow_error("promotion is not ready for authorization"))
  }
  let subject = match snapshot.verification_subject {
    Some(value) => value
    None => return Err(workflow_error("verification subject is missing"))
  }
  let verification_gate = @control.evaluate_part_verification_gate(
    subject,
    snapshot.task_contract.verification_specs,
    snapshot.verification_slots,
    snapshot.verification_receipts,
    expected_verification_environment_digest,
    expected_verification_runtime_digest,
    evidence_exists,
    fn(take_id) {
      snapshot.harness_sessions.any(fn(session) {
        session.take_id == take_id &&
        session.lifecycle
        is @control.HarnessSessionLifecycle::HarnessSessionIngestionClosedCleanly(
          @control.HarnessTerminalObservation::HarnessCompleted
        )
      })
    },
  )
  let audit_subject = match snapshot.audit_subject {
    Some(value) => value
    None => return Err(workflow_error("audit subject is missing"))
  }
  let audit_result = match snapshot.audit_result {
    Some(value) => value
    None => return Err(workflow_error("audit result is missing"))
  }
  let audit_session = find_harness_session(
    snapshot.harness_sessions,
    audit_result.audit_harness_session_id,
  )
  let candidate_sessions : Array[@control.HarnessSessionId] = []
  for session in snapshot.harness_sessions {
    if session.take_id == snapshot.implementation_take.id {
      candidate_sessions.push(session.id)
    }
  }
  let audit_gate = @control.evaluate_part_audit_gate(
    audit_subject,
    snapshot.audit_receipt,
    snapshot.audit_result,
    snapshot.implementation_take.id,
    snapshot.identities.implementation_sandbox.generation_id,
    candidate_sessions,
    audit_session,
    snapshot.task_contract.audit_capability_profile_digest,
    audit_result.effective_surface_manifest_digest,
    audit_result.provider_conformance_report_digest,
    snapshot.task_contract.audit_policy_digest,
    artifact_digest_exists,
  )
  let candidate = match snapshot.candidate {
    Some(value) => value
    None => return Err(workflow_error("candidate is missing"))
  }
  let lease = match snapshot.integration_lease {
    Some(value) => value
    None => return Err(workflow_error("integration lease is missing"))
  }
  let intent = match snapshot.integration_intent {
    Some(value) => value
    None => return Err(workflow_error("integration intent is missing"))
  }
  let authorized = match
    @control.authorize_part_integration(
      snapshot.part,
      candidate,
      verification_gate,
      audit_gate,
      lease,
      intent,
    ) {
    Ok(value) => value
    Err(_) => return Err(workflow_error("assurance gates refused integration"))
  }
  let part = match
    @control.transition_part(
      snapshot.part,
      @control.PartTransition::BeginPartPromotion(candidate.id),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    ..snapshot,
    durable_version: snapshot.durable_version + 1,
    stage: OnePartIntegrationAuthorized,
    part,
    integration_intent: Some(authorized),
  })
}

///|
fn record_integration_witness(
  snapshot : OnePartWorkflowSnapshot,
  observation : OnePartEffectObservation,
  witness : @control.IntegrationWitnessObservation,
  observed_at : Int64,
) -> Result[OnePartWorkflowSnapshot, @types.ChoirError] {
  let effect = match authorized_effect(snapshot) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let intent = match snapshot.integration_intent {
    Some(value) => value
    None => return Err(workflow_error("integration intent is missing"))
  }
  let promotion = match snapshot.promotion_commit {
    Some(value) => value
    None => return Err(workflow_error("promotion commit is missing"))
  }
  match effect.kind {
    ApplyIntegration(intent_id, expected_promotion) =>
      if intent_id != intent.id || expected_promotion != promotion {
        return Err(workflow_error("integration witness has the wrong intent"))
      }
    _ => return Err(workflow_error("integration witness has the wrong intent"))
  }
  let receipt_key = snapshot.workflow_id + ":integration-receipt"
  let outcome = @control.reconcile_integration_witness(
    intent,
    promotion,
    witness,
    @control.IntegrationReceiptId(receipt_key),
    observed_at,
  )
  match outcome {
    @control.IntegrationReconciliationOutcome::IntegrationApplied(receipt) => {
      let part = match
        @control.transition_part(
          snapshot.part,
          @control.PartTransition::RecordPartIntegration(
            receipt.candidate_id,
            @control.ReceiptId(receipt_key),
          ),
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      finish_effect_observation(
        snapshot,
        {
          ..snapshot,
          stage: OnePartIntegrated,
          part,
          integration_intent: Some({
            ..intent,
            lifecycle: @control.IntegrationIntentLifecycle::IntegrationReceipted,
          }),
          integration_receipt: Some(receipt),
        },
        observation,
        observed_at,
      )
    }
    @control.IntegrationReconciliationOutcome::IntegrationRetryAuthorized =>
      finish_effect_observation(
        snapshot,
        { ..snapshot, stage: OnePartIntegrationAuthorized },
        observation,
        observed_at,
      )
    @control.IntegrationReconciliationOutcome::IntegrationReconciliationDiverged => {
      let part = match
        @control.transition_part(
          snapshot.part,
          @control.PartTransition::BlockPart(
            @control.PartBlockReason::PartIntegrationConflict,
          ),
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      finish_effect_observation(
        snapshot,
        { ..snapshot, stage: OnePartBlocked, part },
        observation,
        observed_at,
      )
    }
    @control.IntegrationReconciliationOutcome::IntegrationReconciliationIntegrityError => {
      let part = match
        @control.transition_part(
          snapshot.part,
          @control.PartTransition::BlockPart(
            @control.PartBlockReason::PartIntegrityBlocked,
          ),
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      finish_effect_observation(
        snapshot,
        { ..snapshot, stage: OnePartRecoveryUncertain, part },
        observation,
        observed_at,
      )
    }
  }
}
