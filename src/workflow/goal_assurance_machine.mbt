///|
pub fn goal_assurance_observation_digest(
  observation : GoalAssuranceEffectObservation,
) -> @control.Digest {
  goal_assurance_domain_digest(
    "choir.goal-assurance-effect-observation.v1",
    observation.to_json(),
  )
}

///|
pub fn goal_assurance_effect_witness_bytes(
  witness : GoalAssuranceEffectWitness,
) -> Bytes {
  @utf8.encode(witness.to_json().stringify(indent=0))
}

///|
pub fn decode_goal_assurance_effect_witness(
  content : Bytes,
) -> Result[GoalAssuranceEffectWitness, @types.ChoirError] {
  let json = @json.parse(@utf8.decode_lossy(content)) catch {
    _ => return Err(goal_assurance_error("effect witness is not JSON"))
  }
  let witness : GoalAssuranceEffectWitness = @json.from_json(json) catch {
    _ => return Err(goal_assurance_error("effect witness schema is invalid"))
  }
  if witness.effect_id == "" ||
    witness.observed_at <= 0L ||
    witness.observation_digest !=
    goal_assurance_observation_digest(witness.observation) {
    Err(goal_assurance_error("effect witness identity is invalid"))
  } else {
    Ok(witness)
  }
}

///|
fn goal_assurance_effect_suffix(record : GoalAssuranceRecord) -> String {
  match record.stage {
    GoalSealed => "prepare-verification-sandbox"
    GoalVerificationPending =>
      if !record.sandbox_leases.any(fn(lease) {
          lease.id == record.identities.verification_sandbox.id
        }) {
        "prepare-verification-sandbox"
      } else if !record.harness_sessions.any(fn(session) {
          session.id == record.identities.verification_session.id
        }) {
        "start-verification-harness"
      } else {
        "dispatch-verification"
      }
    GoalVerified => "prepare-audit-sandbox"
    GoalAuditPending =>
      if !record.sandbox_leases.any(fn(lease) {
          lease.id == record.identities.audit_sandbox.id
        }) {
        "prepare-audit-sandbox"
      } else if !record.harness_sessions.any(fn(session) {
          session.id == record.identities.audit_session.id
        }) {
        "start-audit-harness"
      } else {
        "dispatch-audit"
      }
    _ => "none"
  }
}

///|
fn next_goal_assurance_effect_kind(
  record : GoalAssuranceRecord,
) -> Result[GoalAssuranceEffectKind?, @types.ChoirError] {
  match record.stage {
    GoalSealed =>
      Ok(
        Some(
          PrepareGoalVerificationSandbox(record.identities.verification_sandbox),
        ),
      )
    GoalVerificationPending => {
      let has_sandbox = record.sandbox_leases.any(fn(lease) {
        lease.id == record.identities.verification_sandbox.id
      })
      let has_session = record.harness_sessions.any(fn(session) {
        session.id == record.identities.verification_session.id
      })
      if !has_sandbox {
        Ok(
          Some(
            PrepareGoalVerificationSandbox(
              record.identities.verification_sandbox,
            ),
          ),
        )
      } else if !has_session {
        Ok(
          Some(
            StartGoalVerificationHarness(record.identities.verification_session),
          ),
        )
      } else {
        match record.verification_subject {
          Some(subject) =>
            Ok(
              Some(
                DispatchGoalVerification(
                  record.verification_take.id,
                  record.identities.verification_session.id,
                  subject,
                ),
              ),
            )
          None => Err(goal_assurance_error("verification subject is missing"))
        }
      }
    }
    GoalVerified =>
      Ok(Some(PrepareGoalAuditSandbox(record.identities.audit_sandbox)))
    GoalAuditPending => {
      if record.audit_result is Some(_) {
        return Ok(None)
      }
      let has_sandbox = record.sandbox_leases.any(fn(lease) {
        lease.id == record.identities.audit_sandbox.id
      })
      let has_session = record.harness_sessions.any(fn(session) {
        session.id == record.identities.audit_session.id
      })
      if !has_sandbox {
        Ok(Some(PrepareGoalAuditSandbox(record.identities.audit_sandbox)))
      } else if !has_session {
        Ok(Some(StartGoalAuditHarness(record.identities.audit_session)))
      } else {
        match record.audit_subject {
          Some(subject) =>
            Ok(
              Some(
                DispatchGoalAudit(
                  record.audit_take.id,
                  record.identities.audit_session.id,
                  subject,
                ),
              ),
            )
          None => Err(goal_assurance_error("audit subject is missing"))
        }
      }
    }
    GoalAudited | GoalAssuranceBlocked | GoalAssuranceRecoveryUncertain =>
      Ok(None)
    _ => Err(goal_assurance_error("seal is not ready for assurance work"))
  }
}

///|
pub fn plan_next_goal_assurance_effect(
  record : GoalAssuranceRecord,
) -> Result[GoalAssuranceEffectIntent?, @types.ChoirError] {
  match record.pending_effect {
    Some(intent) => Ok(Some(intent))
    None =>
      match next_goal_assurance_effect_kind(record) {
        Ok(Some(kind)) => {
          let request_digest = goal_assurance_domain_digest(
            "choir.goal-assurance-effect-request.v1",
            kind.to_json(),
          )
          Ok(
            Some({
              effect_id: record.goal_id.0 +
              ":assurance:" +
              goal_assurance_effect_suffix(record),
              kind,
              request_digest,
              lifecycle: GoalAssuranceEffectPlanned,
            }),
          )
        }
        Ok(None) => Ok(None)
        Err(error) => Err(error)
      }
  }
}

///|
pub fn persist_planned_goal_assurance_effect(
  record : GoalAssuranceRecord,
  intent : GoalAssuranceEffectIntent,
) -> Result[GoalAssuranceRecord, @types.ChoirError] {
  if record.pending_effect is Some(_) {
    return Err(goal_assurance_error("another effect is unresolved"))
  }
  match plan_next_goal_assurance_effect(record) {
    Ok(Some(expected)) if expected == intent =>
      Ok({
        ..record,
        pending_effect: Some(intent),
        durable_version: record.durable_version + 1,
      })
    Ok(_) =>
      Err(goal_assurance_error("effect is not the deterministic next effect"))
    Err(error) => Err(error)
  }
}

///|
pub fn authorize_pending_goal_assurance_effect(
  record : GoalAssuranceRecord,
) -> Result[GoalAssuranceRecord, @types.ChoirError] {
  match record.pending_effect {
    Some({ lifecycle: GoalAssuranceEffectPlanned, .. } as intent) =>
      Ok({
        ..record,
        pending_effect: Some({
          ..intent,
          lifecycle: GoalAssuranceEffectMayHaveOccurred,
        }),
        durable_version: record.durable_version + 1,
      })
    Some(_) => Err(goal_assurance_error("pending effect is not planned"))
    None => Err(goal_assurance_error("no effect is pending"))
  }
}

///|
pub fn record_goal_assurance_recovery_uncertain(
  record : GoalAssuranceRecord,
) -> Result[GoalAssuranceRecord, @types.ChoirError] {
  match record.pending_effect {
    Some({ lifecycle: GoalAssuranceEffectMayHaveOccurred, .. } as intent) =>
      Ok({
        ..record,
        pending_effect: Some({
          ..intent,
          lifecycle: GoalAssuranceEffectUncertain,
        }),
        stage: GoalAssuranceRecoveryUncertain,
        durable_version: record.durable_version + 1,
      })
    _ => Err(goal_assurance_error("no uncertain external effect exists"))
  }
}

///|
fn authorized_goal_assurance_effect(
  record : GoalAssuranceRecord,
) -> Result[GoalAssuranceEffectIntent, @types.ChoirError] {
  match record.pending_effect {
    Some({ lifecycle: GoalAssuranceEffectMayHaveOccurred, .. } as intent) =>
      Ok(intent)
    Some(_) => Err(goal_assurance_error("pending effect is not authorized"))
    None => Err(goal_assurance_error("effect observation has no intent"))
  }
}

///|
fn finish_goal_assurance_observation(
  before : GoalAssuranceRecord,
  after : GoalAssuranceRecord,
  observation : GoalAssuranceEffectObservation,
  observed_at : Int64,
) -> Result[GoalAssuranceRecord, @types.ChoirError] {
  if observed_at <= 0L {
    return Err(goal_assurance_error("effect observation time is invalid"))
  }
  let intent = match authorized_goal_assurance_effect(before) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let receipts = before.effect_receipts.copy()
  receipts.push({
    effect_id: intent.effect_id,
    request_digest: intent.request_digest,
    observation_digest: goal_assurance_observation_digest(observation),
    observed_at,
  })
  Ok({
    ..after,
    pending_effect: None,
    effect_receipts: receipts,
    durable_version: before.durable_version + 1,
  })
}

///|
fn active_goal_assurance_sandbox_matches(
  expected : @control.SandboxLease,
  actual : @control.SandboxLease,
) -> Bool {
  actual.id == expected.id &&
  actual.take_id == expected.take_id &&
  actual.generation_id == expected.generation_id &&
  actual.capability_profile_digest == expected.capability_profile_digest &&
  actual.runtime_policy_digest == expected.runtime_policy_digest &&
  actual.lifecycle == @control.SandboxLeaseLifecycle::SandboxLeaseActive
}

///|
fn started_goal_assurance_session_matches(
  expected : @control.HarnessSession,
  actual : @control.HarnessSession,
) -> Bool {
  actual.id == expected.id &&
  actual.take_id == expected.take_id &&
  actual.sandbox_generation_id == expected.sandbox_generation_id &&
  actual.surface == expected.surface &&
  actual.effective_surface_manifest_digest ==
  expected.effective_surface_manifest_digest &&
  actual.cursor_class == expected.cursor_class &&
  actual.provider_cursor == expected.provider_cursor &&
  actual.last_choir_sequence == @control.EventSequence(0L) &&
  actual.open_tool_execution_ids.length() == 0 &&
  actual.lifecycle ==
  @control.HarnessSessionLifecycle::HarnessSessionAwaitingEvents
}

///|
fn goal_assurance_verification_subject(
  record : GoalAssuranceRecord,
) -> Result[@control.GoalVerificationSubject, @types.ChoirError] {
  let seal = match record.seal {
    Some(value) => value
    None => return Err(goal_assurance_error("Goal seal is absent"))
  }
  let seal_digest = goal_branch_seal_digest(seal)
  let subject_digest = goal_assurance_domain_digest(
    "choir.goal-verification-subject.v1",
    [
      record.goal_id.to_json(),
      seal.id.to_json(),
      seal_digest.to_json(),
      seal.head_oid.to_json(),
      seal.tree_oid.to_json(),
      record.goal_contract_digest.to_json(),
      record.assurance_policy_revision.to_json(),
      record.integration_receipt_set_digest.to_json(),
    ].to_json(),
  )
  Ok({
    goal_id: record.goal_id,
    goal_branch_seal_id: seal.id,
    goal_branch_seal_digest: seal_digest,
    goal_head_oid: seal.head_oid,
    goal_tree_oid: seal.tree_oid,
    goal_contract_digest: record.goal_contract_digest,
    assurance_policy_revision: record.assurance_policy_revision,
    integration_receipt_set_digest: record.integration_receipt_set_digest,
    subject_digest,
  })
}

///|
fn goal_assurance_audit_subject(
  verification : @control.GoalVerificationSubject,
  authorization : @control.GoalVerificationAuthorizationSet,
) -> @control.GoalAuditSubject {
  let subject_digest = goal_assurance_domain_digest(
    "choir.goal-audit-subject.v1",
    [
      verification.to_json(),
      authorization.receipt_set_digest.to_json(),
      authorization.evidence_manifest_digest.to_json(),
    ].to_json(),
  )
  {
    goal_id: verification.goal_id,
    goal_branch_seal_id: verification.goal_branch_seal_id,
    goal_branch_seal_digest: verification.goal_branch_seal_digest,
    goal_head_oid: verification.goal_head_oid,
    goal_tree_oid: verification.goal_tree_oid,
    goal_contract_digest: verification.goal_contract_digest,
    assurance_policy_revision: verification.assurance_policy_revision,
    integration_receipt_set_digest: verification.integration_receipt_set_digest,
    goal_verification_receipt_set_digest: authorization.receipt_set_digest,
    goal_verification_evidence_manifest_digest: authorization.evidence_manifest_digest,
    subject_digest,
  }
}

///|
fn replace_goal_assurance_session(
  sessions : Array[@control.HarnessSession],
  session : @control.HarnessSession,
) -> Result[Array[@control.HarnessSession], @types.ChoirError] {
  let result : Array[@control.HarnessSession] = []
  let mut found = false
  for existing in sessions {
    if existing.id == session.id {
      if found {
        return Err(goal_assurance_error("duplicate harness session"))
      }
      result.push(session)
      found = true
    } else {
      result.push(existing)
    }
  }
  if found {
    Ok(result)
  } else {
    Err(goal_assurance_error("harness session is missing"))
  }
}

///|
fn find_goal_assurance_session(
  sessions : Array[@control.HarnessSession],
  session_id : @control.HarnessSessionId,
) -> @control.HarnessSession? {
  for session in sessions {
    if session.id == session_id {
      return Some(session)
    }
  }
  None
}

///|
fn close_goal_assurance_trace(
  initial : @control.HarnessSession,
  events : Array[@control.HarnessEventEnvelope],
  observed_final : @control.HarnessSession,
) -> Result[
  (@control.HarnessSession, Array[@control.HarnessEventEnvelope]),
  @types.ChoirError,
] {
  let durable : Array[@control.HarnessEventEnvelope] = []
  let mut projected = initial
  for event in events {
    let ingestion = @control.ingest_harness_event(projected, durable, event)
    match ingestion.disposition {
      @control.HarnessIngestionDisposition::HarnessEventAppended =>
        match ingestion.event {
          Some(value) => durable.push(value)
          None => return Err(goal_assurance_error("event was not retained"))
        }
      @control.HarnessIngestionDisposition::HarnessEventDuplicate => ()
      _ => return Err(goal_assurance_error("harness trace is not authorizing"))
    }
    projected = ingestion.session
  }
  let closed = match @control.close_harness_ingestion(projected) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if closed == observed_final {
    Ok((closed, durable))
  } else {
    Err(goal_assurance_error("adapter session projection disagrees"))
  }
}

///|
fn append_goal_assurance_events(
  existing : Array[@control.HarnessEventEnvelope],
  incoming : Array[@control.HarnessEventEnvelope],
) -> Array[@control.HarnessEventEnvelope] {
  let result = existing.copy()
  for event in incoming {
    result.push(event)
  }
  result
}

///|
fn finish_goal_verification_take(
  take : @control.Take,
  fence : @control.FencingEpoch,
  result_digest : @control.Digest,
  passed : Bool,
) -> Result[@control.Take, @types.ChoirError] {
  let recorded = match
    @control.transition_take(
      take,
      @control.TakeTransition::RecordTakeResult(fence, result_digest),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  @control.transition_take(
    recorded,
    @control.TakeTransition::FinishTake(
      fence,
      if passed {
        @control.TakeTerminalDisposition::TakeSucceeded
      } else {
        @control.TakeTerminalDisposition::TakeFailed(
          @control.TakeFailureReason::TakeVerificationFailed,
        )
      },
    ),
  )
}

///|
fn finish_goal_audit_take(
  take : @control.Take,
  fence : @control.FencingEpoch,
  result_digest : @control.Digest,
  outcome : @control.AuditOutcome,
) -> Result[@control.Take, @types.ChoirError] {
  let recorded = match
    @control.transition_take(
      take,
      @control.TakeTransition::RecordTakeResult(fence, result_digest),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let disposition = match outcome {
    @control.AuditOutcome::AuditPassed =>
      @control.TakeTerminalDisposition::TakeSucceeded
    @control.AuditOutcome::AuditFindings =>
      @control.TakeTerminalDisposition::TakeFailed(
        @control.TakeFailureReason::TakeAuditFindings,
      )
    @control.AuditOutcome::AuditFailed =>
      @control.TakeTerminalDisposition::TakeFailed(
        @control.TakeFailureReason::TakeProviderFailed,
      )
    @control.AuditOutcome::AuditInterrupted =>
      @control.TakeTerminalDisposition::TakeInterrupted
  }
  @control.transition_take(
    recorded,
    @control.TakeTransition::FinishTake(fence, disposition),
  )
}

///|
fn apply_goal_verification_completion(
  record : GoalAssuranceRecord,
  observation : GoalAssuranceEffectObservation,
  result : GoalVerificationExecutionResult,
  final_session : @control.HarnessSession,
  events : Array[@control.HarnessEventEnvelope],
  observed_at : Int64,
  artifact_exists : (@control.ArtifactReference) -> Bool,
) -> Result[GoalAssuranceRecord, @types.ChoirError] {
  let intent = match authorized_goal_assurance_effect(record) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match intent.kind {
    DispatchGoalVerification(take_id, session_id, subject) =>
      if take_id != result.take_id ||
        session_id != result.session_id ||
        subject != result.subject {
        return Err(goal_assurance_error("verification result is misbound"))
      }
    _ => return Err(goal_assurance_error("verification effect is wrong"))
  }
  let subject = match record.verification_subject {
    Some(value) => value
    None => return Err(goal_assurance_error("verification subject is absent"))
  }
  if result.take_id != record.verification_take.id ||
    result.subject != subject ||
    result.executions.length() != record.verification_specs.length() ||
    !artifact_exists(result.evidence_manifest) {
    return Err(goal_assurance_error("verification result is stale"))
  }
  let initial = match
    find_goal_assurance_session(record.harness_sessions, result.session_id) {
    Some(value) => value
    None => return Err(goal_assurance_error("verification session is absent"))
  }
  let (closed, durable_events) = match
    close_goal_assurance_trace(initial, events, final_session) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let sessions = match
    replace_goal_assurance_session(record.harness_sessions, closed) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let slots : Array[@control.GoalVerificationAuthorizationSlot] = []
  let receipts : Array[@control.GoalVerificationReceipt] = []
  let mut expected_environment : @control.Digest? = None
  let mut expected_runtime : @control.Digest? = None
  for spec in record.verification_specs {
    let matching = result.executions.filter(fn(value) {
      value.verification_spec.id == spec.id
    })
    if matching.length() != 1 ||
      matching[0].verification_spec != spec ||
      !artifact_exists(matching[0].evidence) {
      return Err(goal_assurance_error("verification execution set is invalid"))
    }
    let execution = matching[0]
    match expected_environment {
      None =>
        expected_environment = Some(execution.environment_and_image_digest)
      Some(value) if value != execution.environment_and_image_digest =>
        return Err(goal_assurance_error("verification environment changed"))
      _ => ()
    }
    match expected_runtime {
      None => expected_runtime = Some(execution.runtime_and_policy_digest)
      Some(value) if value != execution.runtime_and_policy_digest =>
        return Err(goal_assurance_error("verification runtime changed"))
      _ => ()
    }
    let receipt_id = @control.ReceiptId(
      record.goal_id.0 + ":goal-verification:" + spec.id.0,
    )
    receipts.push({
      receipt_id,
      verification_take_id: result.take_id,
      verification_execution_id: execution.verification_execution_id,
      subject,
      verification_spec: spec,
      prepared_environment_and_image_digest: execution.environment_and_image_digest,
      sandbox_runtime_and_policy_digest: execution.runtime_and_policy_digest,
      subject_pre_tree_oid: execution.subject_pre_tree_oid,
      subject_post_tree_oid: execution.subject_post_tree_oid,
      evidence: execution.evidence,
      started_at: execution.started_at,
      finished_at: execution.finished_at,
      outcome: execution.outcome,
    })
    slots.push({
      subject_digest: subject.subject_digest,
      verification_spec: spec,
      lowest_admitted_execution_ordinal: 1,
      authorizing_receipt_id: if execution.outcome ==
        @control.VerificationOutcome::VerificationPassed {
        Some(receipt_id)
      } else {
        None
      },
    })
  }
  let environment = match expected_environment {
    Some(value) => value
    None =>
      return Err(goal_assurance_error("verification environment is absent"))
  }
  let runtime = match expected_runtime {
    Some(value) => value
    None => return Err(goal_assurance_error("verification runtime is absent"))
  }
  let gate = @control.evaluate_goal_verification_gate(
    subject,
    record.verification_specs,
    slots,
    receipts,
    environment,
    runtime,
    artifact_exists,
    fn(take_id) {
      take_id == result.take_id &&
      closed.lifecycle
      is @control.HarnessSessionLifecycle::HarnessSessionIngestionClosedCleanly(
        @control.HarnessTerminalObservation::HarnessCompleted
      )
    },
  )
  let result_digest = goal_assurance_domain_digest(
    "choir.goal-verification-execution-result.v1",
    result.to_json(),
  )
  let passed = gate
    is @control.VerificationGateObservation::VerificationGateValid(_)
  let take = match
    finish_goal_verification_take(
      record.verification_take,
      record.fencing_epoch,
      result_digest,
      passed,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match gate {
    @control.VerificationGateObservation::VerificationGateValid(receipt_ids) => {
      let authorization : @control.GoalVerificationAuthorizationSet = {
        subject_digest: subject.subject_digest,
        receipt_ids,
        receipt_set_digest: goal_assurance_domain_digest(
          "choir.goal-verification-authorization-set.v1",
          receipts.to_json(),
        ),
        evidence_manifest_digest: result.evidence_manifest.digest,
      }
      let audit_subject = goal_assurance_audit_subject(subject, authorization)
      finish_goal_assurance_observation(
        record,
        {
          ..record,
          verification_take: take,
          audit_take: {
            ..record.audit_take,
            purpose: @control.TakePurpose::GoalAudit(
              record.goal_id,
              audit_subject.subject_digest,
            ),
          },
          harness_sessions: sessions,
          harness_events: append_goal_assurance_events(
            record.harness_events,
            durable_events,
          ),
          verification_slots: slots,
          verification_receipts: receipts,
          verification_authorization: Some(authorization),
          audit_subject: Some(audit_subject),
          stage: GoalVerified,
        },
        observation,
        observed_at,
      )
    }
    _ =>
      finish_goal_assurance_observation(
        record,
        {
          ..record,
          verification_take: take,
          harness_sessions: sessions,
          harness_events: append_goal_assurance_events(
            record.harness_events,
            durable_events,
          ),
          verification_slots: slots,
          verification_receipts: receipts,
          stage: GoalAssuranceBlocked,
        },
        observation,
        observed_at,
      )
  }
}

///|
fn valid_goal_audit_submission(submission : GoalAuditSubmission) -> Bool {
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
fn apply_goal_audit_completion(
  record : GoalAssuranceRecord,
  observation : GoalAssuranceEffectObservation,
  submission : GoalAuditSubmission,
  final_session : @control.HarnessSession,
  events : Array[@control.HarnessEventEnvelope],
  observed_at : Int64,
  artifact_exists : (@control.ArtifactReference) -> Bool,
) -> Result[GoalAssuranceRecord, @types.ChoirError] {
  let intent = match authorized_goal_assurance_effect(record) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match intent.kind {
    DispatchGoalAudit(take_id, session_id, subject) =>
      if take_id != submission.audit_take_id ||
        session_id != submission.audit_harness_session_id ||
        subject != submission.subject {
        return Err(goal_assurance_error("audit result is misbound"))
      }
    _ => return Err(goal_assurance_error("audit effect is wrong"))
  }
  let subject = match record.audit_subject {
    Some(value) => value
    None => return Err(goal_assurance_error("audit subject is absent"))
  }
  if submission.audit_take_id != record.audit_take.id ||
    submission.take_fencing_epoch != record.fencing_epoch ||
    submission.subject != subject ||
    !valid_goal_audit_submission(submission) {
    return Err(goal_assurance_error("audit submission is stale"))
  }
  match submission.findings_artifact {
    Some(value) if !artifact_exists(value) =>
      return Err(goal_assurance_error("audit findings are absent"))
    _ => ()
  }
  let initial = match
    find_goal_assurance_session(
      record.harness_sessions,
      submission.audit_harness_session_id,
    ) {
    Some(value) => value
    None => return Err(goal_assurance_error("audit session is absent"))
  }
  let (closed, durable_events) = match
    close_goal_assurance_trace(initial, events, final_session) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let sessions = match
    replace_goal_assurance_session(record.harness_sessions, closed) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let result_id = @control.AuditResultId(
    record.goal_id.0 + ":goal-audit-result",
  )
  let unfinished : @control.GoalAuditResult = {
    id: result_id,
    audit_take_id: submission.audit_take_id,
    take_fencing_epoch: submission.take_fencing_epoch,
    audit_harness_session_id: submission.audit_harness_session_id,
    subject,
    auditor_capability_profile_digest: record.identities.audit_sandbox.capability_profile_digest,
    effective_surface_manifest_digest: closed.effective_surface_manifest_digest,
    provider_conformance_report_digest: submission.provider_conformance_report_digest,
    audit_policy_digest: record.assurance_policy_digest,
    findings_artifact: submission.findings_artifact,
    total_findings_count: submission.total_findings_count,
    blocking_findings_count: submission.blocking_findings_count,
    started_at: submission.started_at,
    finished_at: submission.finished_at,
    outcome: submission.outcome,
    result_digest: @control.Digest(""),
  }
  let result = {
    ..unfinished,
    result_digest: goal_assurance_domain_digest(
      "choir.goal-audit-result.v1",
      unfinished.to_json(),
    ),
  }
  let take = match
    finish_goal_audit_take(
      record.audit_take,
      record.fencing_epoch,
      result.result_digest,
      result.outcome,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  finish_goal_assurance_observation(
    record,
    {
      ..record,
      audit_take: take,
      harness_sessions: sessions,
      harness_events: append_goal_assurance_events(
        record.harness_events,
        durable_events,
      ),
      audit_result: Some(result),
      stage: GoalAuditPending,
    },
    observation,
    observed_at,
  )
}

///|
pub fn apply_goal_assurance_effect_observation(
  record : GoalAssuranceRecord,
  observation : GoalAssuranceEffectObservation,
  observed_at : Int64,
  artifact_exists : (@control.ArtifactReference) -> Bool,
) -> Result[GoalAssuranceRecord, @types.ChoirError] {
  match observation {
    GoalVerificationSandboxPrepared(lease) => {
      let intent = match authorized_goal_assurance_effect(record) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if !(intent.kind is PrepareGoalVerificationSandbox(_)) ||
        !active_goal_assurance_sandbox_matches(
          record.identities.verification_sandbox,
          lease,
        ) {
        return Err(goal_assurance_error("verification sandbox is misbound"))
      }
      let subject = match goal_assurance_verification_subject(record) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let leased_take = match
        @control.transition_take(
          record.verification_take,
          @control.TakeTransition::LeaseTake(record.fencing_epoch),
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let take = {
        ..leased_take,
        purpose: @control.TakePurpose::GoalVerification(
          record.goal_id,
          subject.goal_head_oid,
          subject.subject_digest,
        ),
      }
      finish_goal_assurance_observation(
        record,
        {
          ..record,
          verification_take: take,
          sandbox_leases: [lease],
          verification_subject: Some(subject),
          stage: GoalVerificationPending,
        },
        observation,
        observed_at,
      )
    }
    GoalVerificationHarnessStarted(session) => {
      let intent = match authorized_goal_assurance_effect(record) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if !(intent.kind is StartGoalVerificationHarness(_)) ||
        !started_goal_assurance_session_matches(
          record.identities.verification_session,
          session,
        ) {
        return Err(goal_assurance_error("verification session is misbound"))
      }
      let take = match
        @control.transition_take(
          record.verification_take,
          @control.TakeTransition::StartTake(record.fencing_epoch),
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      finish_goal_assurance_observation(
        record,
        { ..record, verification_take: take, harness_sessions: [session] },
        observation,
        observed_at,
      )
    }
    GoalVerificationCompleted(result, final_session, events) =>
      apply_goal_verification_completion(
        record, observation, result, final_session, events, observed_at, artifact_exists,
      )
    GoalAuditSandboxPrepared(lease) => {
      let intent = match authorized_goal_assurance_effect(record) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if !(intent.kind is PrepareGoalAuditSandbox(_)) ||
        !active_goal_assurance_sandbox_matches(
          record.identities.audit_sandbox,
          lease,
        ) {
        return Err(goal_assurance_error("audit sandbox is misbound"))
      }
      let take = match
        @control.transition_take(
          record.audit_take,
          @control.TakeTransition::LeaseTake(record.fencing_epoch),
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let leases = record.sandbox_leases.copy()
      leases.push(lease)
      finish_goal_assurance_observation(
        record,
        {
          ..record,
          audit_take: take,
          sandbox_leases: leases,
          stage: GoalAuditPending,
        },
        observation,
        observed_at,
      )
    }
    GoalAuditHarnessStarted(session) => {
      let intent = match authorized_goal_assurance_effect(record) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if !(intent.kind is StartGoalAuditHarness(_)) ||
        !started_goal_assurance_session_matches(
          record.identities.audit_session,
          session,
        ) {
        return Err(goal_assurance_error("audit session is misbound"))
      }
      let take = match
        @control.transition_take(
          record.audit_take,
          @control.TakeTransition::StartTake(record.fencing_epoch),
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let sessions = record.harness_sessions.copy()
      sessions.push(session)
      finish_goal_assurance_observation(
        record,
        { ..record, audit_take: take, harness_sessions: sessions },
        observation,
        observed_at,
      )
    }
    GoalAuditCompleted(submission, final_session, events) =>
      apply_goal_audit_completion(
        record, observation, submission, final_session, events, observed_at, artifact_exists,
      )
  }
}

///|
pub fn mint_goal_audit_receipt(
  record : GoalAssuranceRecord,
  metadata : GoalAuditReceiptMetadata,
  artifact_digest_exists : (@control.Digest) -> Bool,
) -> Result[GoalAssuranceRecord, @types.ChoirError] {
  if record.stage != GoalAuditPending ||
    record.pending_effect is Some(_) ||
    record.audit_receipt is Some(_) {
    return Err(goal_assurance_error("audit result is not ready for a receipt"))
  }
  let subject = match record.audit_subject {
    Some(value) => value
    None => return Err(goal_assurance_error("audit subject is absent"))
  }
  let result = match record.audit_result {
    Some(value) => value
    None => return Err(goal_assurance_error("audit result is absent"))
  }
  let receipt : @control.GoalAuditReceipt = {
    receipt_id: metadata.receipt_id,
    audit_result_id: result.id,
    audit_result_digest: result.result_digest,
    subject,
    audit_take_id: result.audit_take_id,
    audit_harness_session_id: result.audit_harness_session_id,
    audit_sandbox_generation_id: record.identities.audit_sandbox.generation_id,
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
  let audit_session = find_goal_assurance_session(
    record.harness_sessions,
    result.audit_harness_session_id,
  )
  let gate = @control.evaluate_goal_audit_gate(
    subject,
    Some(receipt),
    Some(result),
    [record.verification_take.id],
    [record.identities.verification_sandbox.generation_id],
    [record.identities.verification_session.id],
    audit_session,
    record.identities.audit_sandbox.capability_profile_digest,
    record.identities.audit_session.effective_surface_manifest_digest,
    result.provider_conformance_report_digest,
    record.assurance_policy_digest,
    artifact_digest_exists,
  )
  match gate {
    @control.AuditGateObservation::AuditGateValid(_) =>
      Ok({
        ..record,
        audit_receipt: Some(receipt),
        stage: GoalAudited,
        durable_version: record.durable_version + 1,
      })
    _ => Err(goal_assurance_error("audit gate did not authorize the receipt"))
  }
}
