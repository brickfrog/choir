///|
fn workflow_error(detail : String) -> @types.ChoirError {
  @types.ChoirError::validation_error("Part workflow: " + detail)
}

///|
fn domain_digest(domain : String, json : Json) -> @control.Digest {
  @storage.artifact_digest(
    @utf8.encode(domain + "\u{00}" + json.stringify(indent=0)),
  )
}

///|
pub fn part_snapshot_bytes(snapshot : PartWorkflowSnapshot) -> Bytes {
  @utf8.encode(snapshot.to_json().stringify(indent=0))
}

///|
pub fn part_snapshot_digest(snapshot : PartWorkflowSnapshot) -> @control.Digest {
  @storage.artifact_digest(part_snapshot_bytes(snapshot))
}

///|
pub fn decode_part_snapshot(
  content : Bytes,
) -> Result[PartWorkflowSnapshot, @types.ChoirError] {
  let json = @json.parse(@utf8.decode_lossy(content)) catch {
    _ => return Err(workflow_error("durable snapshot is not valid JSON"))
  }
  let snapshot : PartWorkflowSnapshot = @json.from_json(json) catch {
    _ =>
      return Err(workflow_error("durable snapshot does not match the schema"))
  }
  Ok(snapshot)
}

///|
pub fn part_effect_observation_digest(
  observation : PartEffectObservation,
) -> @control.Digest {
  domain_digest("choir.part-effect-observation.v1", observation.to_json())
}

///|
pub fn part_effect_witness_bytes(witness : PartEffectWitness) -> Bytes {
  @utf8.encode(witness.to_json().stringify(indent=0))
}

///|
pub fn decode_part_effect_witness(
  content : Bytes,
) -> Result[PartEffectWitness, @types.ChoirError] {
  let json = @json.parse(@utf8.decode_lossy(content)) catch {
    _ => return Err(workflow_error("effect witness is not valid JSON"))
  }
  let witness : PartEffectWitness = @json.from_json(json) catch {
    _ => return Err(workflow_error("effect witness does not match the schema"))
  }
  if witness.effect_id == "" ||
    witness.observed_at <= 0L ||
    witness.observation_digest !=
    part_effect_observation_digest(witness.observation) {
    return Err(workflow_error("effect witness identity is invalid"))
  }
  Ok(witness)
}

///|
fn verification_subject(
  candidate : @control.CandidateCommit,
  contract : @control.TaskContractRevision,
) -> @control.PartVerificationSubject {
  let identity = [
    candidate.part_id.to_json(),
    candidate.take_id.to_json(),
    candidate.commit_oid.to_json(),
    candidate.tree_oid.to_json(),
    contract.id.to_json(),
    contract.digest.to_json(),
  ].to_json()
  {
    part_id: candidate.part_id,
    candidate_take_id: candidate.take_id,
    candidate_commit_oid: candidate.commit_oid,
    candidate_tree_oid: candidate.tree_oid,
    task_contract_revision_id: contract.id,
    task_contract_digest: contract.digest,
    subject_digest: domain_digest(
      "choir.part-verification-subject.v1", identity,
    ),
  }
}

///|
fn audit_subject(
  subject : @control.PartVerificationSubject,
  authorization : @control.VerificationAuthorizationSet,
) -> @control.PartAuditSubject {
  let identity = [
    subject.part_id.to_json(),
    subject.candidate_take_id.to_json(),
    subject.candidate_commit_oid.to_json(),
    subject.candidate_tree_oid.to_json(),
    subject.task_contract_revision_id.to_json(),
    subject.task_contract_digest.to_json(),
    authorization.receipt_set_digest.to_json(),
    authorization.evidence_manifest_digest.to_json(),
  ].to_json()
  {
    part_id: subject.part_id,
    candidate_take_id: subject.candidate_take_id,
    candidate_commit_oid: subject.candidate_commit_oid,
    candidate_tree_oid: subject.candidate_tree_oid,
    task_contract_revision_id: subject.task_contract_revision_id,
    task_contract_digest: subject.task_contract_digest,
    verification_receipt_set_digest: authorization.receipt_set_digest,
    verification_evidence_manifest_digest: authorization.evidence_manifest_digest,
    subject_digest: domain_digest("choir.part-audit-subject.v1", identity),
  }
}

///|
fn validate_planned_sandbox(
  lease : @control.SandboxLease,
  take : @control.Take,
) -> Bool {
  lease.take_id == take.id &&
  lease.lifecycle == @control.SandboxLeaseLifecycle::SandboxLeasePlanned
}

///|
fn validate_planned_session(
  session : @control.HarnessSession,
  take : @control.Take,
  lease : @control.SandboxLease,
) -> Bool {
  session.take_id == take.id &&
  session.sandbox_generation_id == lease.generation_id &&
  session.lifecycle == @control.HarnessSessionLifecycle::HarnessSessionPlanned &&
  session.last_choir_sequence == @control.EventSequence(0L) &&
  session.open_tool_execution_ids.length() == 0
}

///|
pub fn initialize_part_workflow(
  workflow_id : String,
  goal : @control.Goal,
  part : @control.GoalPart,
  contract : @control.TaskContractRevision,
  identities : PartIdentityPlan,
  fencing_epoch : @control.FencingEpoch,
  is_nfc : (String) -> Bool,
) -> Result[PartWorkflowSnapshot, @types.ChoirError] {
  if workflow_id == "" || workflow_id.contains("\u{00}") {
    return Err(workflow_error("workflow identity is empty or invalid"))
  }
  if goal.lifecycle !=
    @control.GoalLifecycle::GoalActive(
      @control.GoalActiveCondition::GoalRunning,
    ) ||
    part.goal_id != goal.id ||
    contract.goal_id != goal.id ||
    contract.part_id != part.id ||
    part.task_contract_revision_id != contract.id ||
    contract.verification_specs.length() != 1 {
    return Err(workflow_error("goal, Part, and contract identities disagree"))
  }
  match @control.validate_task_contract_revision(contract, is_nfc) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if identities.implementation_take.lifecycle !=
    @control.TakeLifecycle::TakePlanned ||
    identities.verification_take.lifecycle !=
    @control.TakeLifecycle::TakePlanned ||
    identities.audit_take.lifecycle != @control.TakeLifecycle::TakePlanned ||
    !validate_planned_sandbox(
      identities.implementation_sandbox,
      identities.implementation_take,
    ) ||
    !validate_planned_sandbox(
      identities.verification_sandbox,
      identities.verification_take,
    ) ||
    !validate_planned_sandbox(identities.audit_sandbox, identities.audit_take) ||
    !validate_planned_session(
      identities.implementation_session,
      identities.implementation_take,
      identities.implementation_sandbox,
    ) ||
    !validate_planned_session(
      identities.verification_session,
      identities.verification_take,
      identities.verification_sandbox,
    ) ||
    !validate_planned_session(
      identities.audit_session,
      identities.audit_take,
      identities.audit_sandbox,
    ) {
    return Err(workflow_error("Take resource identity plan is inconsistent"))
  }
  match identities.implementation_take.purpose {
    @control.TakePurpose::Implementation(part_id, revision_id) =>
      if part_id != part.id || revision_id != contract.id {
        return Err(workflow_error("implementation Take purpose is invalid"))
      }
    _ => return Err(workflow_error("implementation Take purpose is invalid"))
  }
  match identities.verification_take.purpose {
    @control.TakePurpose::PartVerification(part_id, candidate_take_id, _) =>
      if part_id != part.id ||
        candidate_take_id != identities.implementation_take.id {
        return Err(workflow_error("verification Take purpose is invalid"))
      }
    _ => return Err(workflow_error("verification Take purpose is invalid"))
  }
  match identities.audit_take.purpose {
    @control.TakePurpose::PartAudit(part_id, candidate_take_id, _) =>
      if part_id != part.id ||
        candidate_take_id != identities.implementation_take.id {
        return Err(workflow_error("audit Take purpose is invalid"))
      }
    _ => return Err(workflow_error("audit Take purpose is invalid"))
  }
  let ready = match
    @control.transition_part(part, @control.PartTransition::MarkPartReady) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let executing = match
    @control.transition_part(
      ready,
      @control.PartTransition::StartPartTake(identities.implementation_take.id),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let implementation_take = match
    @control.transition_take(
      identities.implementation_take,
      @control.TakeTransition::LeaseTake(fencing_epoch),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    workflow_id,
    durable_version: 0,
    fencing_epoch,
    stage: PartAccepted,
    goal,
    part: executing,
    task_contract: contract,
    identities,
    implementation_take,
    verification_take: identities.verification_take,
    audit_take: identities.audit_take,
    sandbox_leases: [],
    harness_sessions: [],
    harness_events: [],
    implementation_result: None,
    candidate: None,
    verification_subject: None,
    verification_slots: [],
    verification_receipts: [],
    verification_authorization: None,
    audit_subject: None,
    audit_result: None,
    audit_receipt: None,
    integration_lease: None,
    integration_intent: None,
    promotion_commit: None,
    integration_receipt: None,
    pending_effect: None,
    effect_receipts: [],
  })
}

///|
fn stage_effect_suffix(stage : PartWorkflowStage) -> String {
  match stage {
    PartAccepted => "implementation-sandbox"
    PartImplementationSandboxPrepared => "implementation-harness"
    PartImplementationHarnessStarted => "implementation-dispatch"
    PartImplementationCompleted => "candidate-normalization"
    PartCandidateRecorded => "verification-sandbox"
    PartVerificationSandboxPrepared => "verification-harness"
    PartVerificationHarnessStarted => "verification-dispatch"
    PartVerified => "audit-sandbox"
    PartAuditSandboxPrepared => "audit-harness"
    PartAuditHarnessStarted => "audit-dispatch"
    PartIntegrationPlanned => "promotion-generation"
    PartIntegrationAuthorized => "integration-apply"
    _ => "none"
  }
}

///|
fn next_effect_kind(
  snapshot : PartWorkflowSnapshot,
) -> Result[PartEffectKind?, @types.ChoirError] {
  match snapshot.stage {
    PartAccepted =>
      Ok(
        Some(
          PrepareImplementationSandbox(
            snapshot.identities.implementation_sandbox,
          ),
        ),
      )
    PartImplementationSandboxPrepared =>
      Ok(
        Some(
          StartImplementationHarness(snapshot.identities.implementation_session),
        ),
      )
    PartImplementationHarnessStarted =>
      Ok(
        Some(
          DispatchImplementation(
            snapshot.implementation_take.id,
            snapshot.identities.implementation_session.id,
          ),
        ),
      )
    PartImplementationCompleted =>
      match snapshot.implementation_result {
        Some(result) =>
          Ok(
            Some(
              NormalizeImplementationCandidate(
                snapshot.implementation_take.id,
                result.result_artifact.digest,
              ),
            ),
          )
        None => Err(workflow_error("implementation result is missing"))
      }
    PartCandidateRecorded =>
      Ok(
        Some(
          PrepareVerificationSandbox(snapshot.identities.verification_sandbox),
        ),
      )
    PartVerificationSandboxPrepared =>
      Ok(
        Some(StartVerificationHarness(snapshot.identities.verification_session)),
      )
    PartVerificationHarnessStarted =>
      match snapshot.verification_subject {
        Some(subject) =>
          Ok(
            Some(
              DispatchVerification(
                snapshot.verification_take.id,
                snapshot.identities.verification_session.id,
                subject,
              ),
            ),
          )
        None => Err(workflow_error("verification subject is missing"))
      }
    PartVerified =>
      Ok(Some(PrepareAuditSandbox(snapshot.identities.audit_sandbox)))
    PartAuditSandboxPrepared =>
      Ok(Some(StartAuditHarness(snapshot.identities.audit_session)))
    PartAuditHarnessStarted =>
      match snapshot.audit_subject {
        Some(subject) =>
          Ok(
            Some(
              DispatchAudit(
                snapshot.audit_take.id,
                snapshot.identities.audit_session.id,
                subject,
              ),
            ),
          )
        None => Err(workflow_error("audit subject is missing"))
      }
    PartIntegrationPlanned =>
      match snapshot.integration_intent {
        Some(intent) => Ok(Some(GeneratePromotion(intent)))
        None => Err(workflow_error("integration intent is missing"))
      }
    PartIntegrationAuthorized =>
      match (snapshot.integration_intent, snapshot.promotion_commit) {
        (Some(intent), Some(promotion)) =>
          Ok(Some(ApplyIntegration(intent.id, promotion)))
        _ => Err(workflow_error("authorized integration is incomplete"))
      }
    _ => Ok(None)
  }
}

///|
pub fn plan_next_part_effect(
  snapshot : PartWorkflowSnapshot,
) -> Result[PartEffectIntent?, @types.ChoirError] {
  match snapshot.pending_effect {
    Some(intent) => Ok(Some(intent))
    None =>
      match next_effect_kind(snapshot) {
        Ok(None) => Ok(None)
        Ok(Some(kind)) => {
          let effect_id = snapshot.workflow_id +
            ":" +
            stage_effect_suffix(snapshot.stage)
          Ok(
            Some({
              effect_id,
              request_digest: domain_digest(
                "choir.part-effect-request.v1",
                kind.to_json(),
              ),
              kind,
              lifecycle: PartEffectPlanned,
            }),
          )
        }
        Err(error) => Err(error)
      }
  }
}

///|
pub fn persist_planned_part_effect(
  snapshot : PartWorkflowSnapshot,
  intent : PartEffectIntent,
) -> Result[PartWorkflowSnapshot, @types.ChoirError] {
  if snapshot.pending_effect is Some(_) {
    return Err(workflow_error("another external effect is unresolved"))
  }
  match plan_next_part_effect(snapshot) {
    Ok(Some(expected)) if expected == intent =>
      Ok({
        ..snapshot,
        durable_version: snapshot.durable_version + 1,
        pending_effect: Some(intent),
      })
    Ok(_) => Err(workflow_error("effect is not the deterministic next effect"))
    Err(error) => Err(error)
  }
}

///|
pub fn authorize_pending_part_effect(
  snapshot : PartWorkflowSnapshot,
) -> Result[PartWorkflowSnapshot, @types.ChoirError] {
  match snapshot.pending_effect {
    Some({ lifecycle: PartEffectPlanned, .. } as intent) =>
      Ok({
        ..snapshot,
        durable_version: snapshot.durable_version + 1,
        pending_effect: Some({ ..intent, lifecycle: PartEffectMayHaveOccurred }),
      })
    Some(_) => Err(workflow_error("external effect is not planned"))
    None => Err(workflow_error("no external effect is pending"))
  }
}

///|
pub fn record_part_provider_protocol_violation(
  snapshot : PartWorkflowSnapshot,
  intent : PartEffectIntent,
) -> Result[PartWorkflowSnapshot, @types.ChoirError] {
  if snapshot.pending_effect != Some(intent) ||
    intent.lifecycle != PartEffectMayHaveOccurred {
    return Err(workflow_error("protocol violation has no authorized effect"))
  }
  let (take, session_id) = match intent.kind {
    DispatchImplementation(take_id, session_id)
    | DispatchVerification(take_id, session_id, _)
    | DispatchAudit(take_id, session_id, _) => {
      let take = if take_id == snapshot.implementation_take.id {
        snapshot.implementation_take
      } else if take_id == snapshot.verification_take.id {
        snapshot.verification_take
      } else if take_id == snapshot.audit_take.id {
        snapshot.audit_take
      } else {
        return Err(workflow_error("protocol violation named an unknown Take"))
      }
      (take, session_id)
    }
    _ =>
      return Err(
        workflow_error(
          "protocol violation did not arise from a provider dispatch",
        ),
      )
  }
  let terminal_take = match
    @control.transition_take(
      take,
      @control.TakeTransition::FinishTake(
        snapshot.fencing_epoch,
        @control.TakeTerminalDisposition::TakeRecoveryUncertain(
          @control.TakeUncertaintyReason::TakeProtocolViolation,
        ),
      ),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let mut found_session = false
  let sessions = snapshot.harness_sessions.map(fn(session) {
    if session.id == session_id && session.take_id == take.id {
      found_session = true
      {
        ..session,
        lifecycle: @control.HarnessSessionLifecycle::HarnessSessionProtocolViolated,
      }
    } else {
      session
    }
  })
  if !found_session {
    return Err(workflow_error("protocol violation session is missing"))
  }
  let part = match
    @control.transition_part(
      snapshot.part,
      @control.PartTransition::BlockPart(
        @control.PartBlockReason::PartRecoveryUncertain,
      ),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    ..snapshot,
    durable_version: snapshot.durable_version + 1,
    stage: PartRecoveryUncertain,
    part,
    implementation_take: if take.id == snapshot.implementation_take.id {
      terminal_take
    } else {
      snapshot.implementation_take
    },
    verification_take: if take.id == snapshot.verification_take.id {
      terminal_take
    } else {
      snapshot.verification_take
    },
    audit_take: if take.id == snapshot.audit_take.id {
      terminal_take
    } else {
      snapshot.audit_take
    },
    harness_sessions: sessions,
    pending_effect: Some({ ..intent, lifecycle: PartEffectUncertain }),
  })
}
