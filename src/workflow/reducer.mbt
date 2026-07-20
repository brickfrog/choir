///|
fn authorized_effect(
  snapshot : PartWorkflowSnapshot,
) -> Result[PartEffectIntent, @types.ChoirError] {
  match snapshot.pending_effect {
    Some({ lifecycle: PartEffectMayHaveOccurred, .. } as intent) => Ok(intent)
    Some(_) => Err(workflow_error("pending effect is not authorized"))
    None => Err(workflow_error("effect observation has no durable intent"))
  }
}

///|
fn finish_effect_observation(
  before : PartWorkflowSnapshot,
  after : PartWorkflowSnapshot,
  observation : PartEffectObservation,
  observed_at : Int64,
) -> Result[PartWorkflowSnapshot, @types.ChoirError] {
  let intent = match authorized_effect(before) {
    Ok(intent) => intent
    Err(error) => return Err(error)
  }
  let receipts = before.effect_receipts.copy()
  receipts.push({
    effect_id: intent.effect_id,
    request_digest: intent.request_digest,
    observation_digest: part_effect_observation_digest(observation),
    observed_at,
  })
  Ok({
    ..after,
    durable_version: before.durable_version + 1,
    pending_effect: None,
    effect_receipts: receipts,
  })
}

///|
fn add_sandbox_lease(
  leases : Array[@control.SandboxLease],
  lease : @control.SandboxLease,
) -> Result[Array[@control.SandboxLease], @types.ChoirError] {
  for existing in leases {
    if existing.id == lease.id {
      return if existing == lease {
        Ok(leases)
      } else {
        Err(workflow_error("sandbox lease identity was reused"))
      }
    }
  }
  let updated = leases.copy()
  updated.push(lease)
  Ok(updated)
}

///|
fn add_harness_session(
  sessions : Array[@control.HarnessSession],
  session : @control.HarnessSession,
) -> Result[Array[@control.HarnessSession], @types.ChoirError] {
  for existing in sessions {
    if existing.id == session.id {
      return if existing == session {
        Ok(sessions)
      } else {
        Err(workflow_error("harness session identity was reused"))
      }
    }
  }
  let updated = sessions.copy()
  updated.push(session)
  Ok(updated)
}

///|
fn replace_harness_session(
  sessions : Array[@control.HarnessSession],
  session : @control.HarnessSession,
) -> Result[Array[@control.HarnessSession], @types.ChoirError] {
  let updated : Array[@control.HarnessSession] = []
  let mut found = false
  for existing in sessions {
    if existing.id == session.id {
      if found {
        return Err(workflow_error("duplicate durable harness session"))
      }
      updated.push(session)
      found = true
    } else {
      updated.push(existing)
    }
  }
  if found {
    Ok(updated)
  } else {
    Err(workflow_error("harness session was not started"))
  }
}

///|
fn find_harness_session(
  sessions : Array[@control.HarnessSession],
  id : @control.HarnessSessionId,
) -> @control.HarnessSession? {
  for session in sessions {
    if session.id == id {
      return Some(session)
    }
  }
  None
}

///|
fn validate_closed_trace(
  initial : @control.HarnessSession,
  incoming_events : Array[@control.HarnessEventEnvelope],
  observed_final : @control.HarnessSession,
) -> Result[
  (@control.HarnessSession, Array[@control.HarnessEventEnvelope]),
  @types.ChoirError,
] {
  let durable : Array[@control.HarnessEventEnvelope] = []
  let projected_cursor = match initial.cursor_class {
    @control.HarnessCursorClass::HarnessCursorNotResumable =>
      if initial.provider_cursor is None &&
        observed_final.provider_cursor is None {
        None
      } else {
        return Err(workflow_error("non-resumable session reported a cursor"))
      }
    @control.HarnessCursorClass::HarnessCursorProviderEventId
    | @control.HarnessCursorClass::HarnessCursorTransition =>
      match observed_final.provider_cursor {
        Some(cursor) if cursor != "" && cursor.length() <= 512 =>
          match initial.provider_cursor {
            Some(existing) if existing != cursor =>
              return Err(
                workflow_error("provider cursor changed during replay"),
              )
            _ => Some(cursor)
          }
        _ => return Err(workflow_error("resumable session omitted its cursor"))
      }
  }
  let mut projected = { ..initial, provider_cursor: projected_cursor }
  for incoming in incoming_events {
    let result = @control.ingest_harness_event(projected, durable, incoming)
    match result.disposition {
      @control.HarnessIngestionDisposition::HarnessEventAppended =>
        match result.event {
          Some(event) => durable.push(event)
          None => return Err(workflow_error("appended event was not retained"))
        }
      @control.HarnessIngestionDisposition::HarnessEventDuplicate => ()
      _ => return Err(workflow_error("harness trace is not authorizing"))
    }
    projected = result.session
  }
  let closed = match @control.close_harness_ingestion(projected) {
    Ok(session) => session
    Err(error) => return Err(error)
  }
  if closed != observed_final {
    Err(workflow_error("adapter session projection disagrees with Choir"))
  } else {
    Ok((closed, durable))
  }
}

///|
test "closed trace adopts one bounded resumable provider cursor" {
  let initial : @control.HarnessSession = {
    id: @control.HarnessSessionId("session-resumable"),
    take_id: @control.TakeId("take-resumable"),
    sandbox_generation_id: @control.SandboxGenerationId("generation-resumable"),
    surface: @control.ProviderSurfaceId::CodexSubscriptionCli,
    effective_surface_manifest_digest: @control.Digest("surface-resumable"),
    cursor_class: @control.HarnessCursorClass::HarnessCursorProviderEventId,
    provider_cursor: None,
    last_choir_sequence: @control.EventSequence(0L),
    open_tool_execution_ids: [],
    lifecycle: @control.HarnessSessionLifecycle::HarnessSessionAwaitingEvents,
  }
  let cursor = "thread-resumable:turn-resumable"
  let events : Array[@control.HarnessEventEnvelope] = [
    {
      id: @control.HarnessEventId("event-resumable-1"),
      take_id: initial.take_id,
      session_id: initial.id,
      source_position: @control.EventSourcePosition::EventProviderId(
        cursor + ":started",
      ),
      choir_sequence: @control.EventSequence(1L),
      observed_at: 1L,
      kind: @control.HarnessEventKind::HarnessStarted,
      sanitized_payload_digest: @control.Digest("event-resumable-started"),
      redaction_state: @control.EventRedactionState::EventNotSensitive,
      late: false,
    },
    {
      id: @control.HarnessEventId("event-resumable-2"),
      take_id: initial.take_id,
      session_id: initial.id,
      source_position: @control.EventSourcePosition::EventProviderId(
        cursor + ":terminal",
      ),
      choir_sequence: @control.EventSequence(2L),
      observed_at: 2L,
      kind: @control.HarnessEventKind::HarnessTerminal(
        @control.HarnessTerminalObservation::HarnessCompleted,
      ),
      sanitized_payload_digest: @control.Digest("event-resumable-terminal"),
      redaction_state: @control.EventRedactionState::EventNotSensitive,
      late: false,
    },
  ]
  let observed = {
    ..initial,
    provider_cursor: Some(cursor),
    last_choir_sequence: @control.EventSequence(2L),
    lifecycle: @control.HarnessSessionLifecycle::HarnessSessionIngestionClosedCleanly(
      @control.HarnessTerminalObservation::HarnessCompleted,
    ),
  }
  assert_eq(
    validate_closed_trace(initial, events, observed).unwrap().0,
    observed,
  )
  assert_true(
    validate_closed_trace(
      { ..initial, provider_cursor: Some("different-thread:different-turn") },
      events,
      observed,
    )
    is Err(_),
  )
}

///|
fn append_events(
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
fn active_sandbox_matches(
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
fn started_session_matches(
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
fn take_success_after_result(
  take : @control.Take,
  fence : @control.FencingEpoch,
  result_digest : @control.Digest,
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
      @control.TakeTerminalDisposition::TakeSucceeded,
    ),
  )
}

///|
fn take_terminal_after_verification(
  take : @control.Take,
  fence : @control.FencingEpoch,
  result_digest : @control.Digest,
  outcome : @control.VerificationOutcome,
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
    @control.VerificationOutcome::VerificationPassed =>
      @control.TakeTerminalDisposition::TakeSucceeded
    @control.VerificationOutcome::VerificationFailed =>
      @control.TakeTerminalDisposition::TakeFailed(
        @control.TakeFailureReason::TakeVerificationFailed,
      )
    @control.VerificationOutcome::VerificationErrored =>
      @control.TakeTerminalDisposition::TakeFailed(
        @control.TakeFailureReason::TakeProviderFailed,
      )
    @control.VerificationOutcome::VerificationInterrupted =>
      @control.TakeTerminalDisposition::TakeInterrupted
  }
  @control.transition_take(
    recorded,
    @control.TakeTransition::FinishTake(fence, disposition),
  )
}

///|
fn take_terminal_after_audit(
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
priv enum PartTakeRole {
  WorkflowImplementationTake
  WorkflowVerificationTake
  WorkflowAuditTake
}

///|
fn record_sandbox_prepared(
  snapshot : PartWorkflowSnapshot,
  observation : PartEffectObservation,
  lease : @control.SandboxLease,
  expected : @control.SandboxLease,
  expected_kind : (PartEffectKind) -> Bool,
  stage : PartWorkflowStage,
  take_role : PartTakeRole,
  observed_at : Int64,
) -> Result[PartWorkflowSnapshot, @types.ChoirError] {
  let intent = match authorized_effect(snapshot) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if !expected_kind(intent.kind) || !active_sandbox_matches(expected, lease) {
    return Err(workflow_error("sandbox observation does not match its intent"))
  }
  let leases = match add_sandbox_lease(snapshot.sandbox_leases, lease) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let after = match take_role {
    WorkflowVerificationTake => {
      let take = match
        @control.transition_take(
          snapshot.verification_take,
          @control.TakeTransition::LeaseTake(snapshot.fencing_epoch),
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      { ..snapshot, stage, sandbox_leases: leases, verification_take: take }
    }
    WorkflowAuditTake => {
      let take = match
        @control.transition_take(
          snapshot.audit_take,
          @control.TakeTransition::LeaseTake(snapshot.fencing_epoch),
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      { ..snapshot, stage, sandbox_leases: leases, audit_take: take }
    }
    WorkflowImplementationTake => { ..snapshot, stage, sandbox_leases: leases }
  }
  finish_effect_observation(snapshot, after, observation, observed_at)
}

///|
fn record_harness_started(
  snapshot : PartWorkflowSnapshot,
  observation : PartEffectObservation,
  session : @control.HarnessSession,
  expected : @control.HarnessSession,
  expected_kind : (PartEffectKind) -> Bool,
  stage : PartWorkflowStage,
  take_role : PartTakeRole,
  observed_at : Int64,
) -> Result[PartWorkflowSnapshot, @types.ChoirError] {
  let intent = match authorized_effect(snapshot) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if !expected_kind(intent.kind) || !started_session_matches(expected, session) {
    return Err(workflow_error("harness start does not match its intent"))
  }
  let sessions = match add_harness_session(snapshot.harness_sessions, session) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let after = match take_role {
    WorkflowImplementationTake => {
      let take = match
        @control.transition_take(
          snapshot.implementation_take,
          @control.TakeTransition::StartTake(snapshot.fencing_epoch),
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      {
        ..snapshot,
        stage,
        harness_sessions: sessions,
        implementation_take: take,
      }
    }
    WorkflowVerificationTake => {
      let take = match
        @control.transition_take(
          snapshot.verification_take,
          @control.TakeTransition::StartTake(snapshot.fencing_epoch),
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      { ..snapshot, stage, harness_sessions: sessions, verification_take: take }
    }
    WorkflowAuditTake => {
      let take = match
        @control.transition_take(
          snapshot.audit_take,
          @control.TakeTransition::StartTake(snapshot.fencing_epoch),
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      { ..snapshot, stage, harness_sessions: sessions, audit_take: take }
    }
  }
  finish_effect_observation(snapshot, after, observation, observed_at)
}

///|
pub fn apply_part_effect_observation(
  snapshot : PartWorkflowSnapshot,
  observation : PartEffectObservation,
  observed_at : Int64,
  artifact_exists : (@control.ArtifactReference) -> Bool,
  is_nfc : (String) -> Bool,
) -> Result[PartWorkflowSnapshot, @types.ChoirError] {
  match observation {
    ImplementationSandboxPrepared(lease) =>
      record_sandbox_prepared(
        snapshot,
        observation,
        lease,
        snapshot.identities.implementation_sandbox,
        fn(kind) { kind is PrepareImplementationSandbox(_) },
        PartImplementationSandboxPrepared,
        WorkflowImplementationTake,
        observed_at,
      )
    VerificationSandboxPrepared(lease) =>
      record_sandbox_prepared(
        snapshot,
        observation,
        lease,
        snapshot.identities.verification_sandbox,
        fn(kind) { kind is PrepareVerificationSandbox(_) },
        PartVerificationSandboxPrepared,
        WorkflowVerificationTake,
        observed_at,
      )
    AuditSandboxPrepared(lease) =>
      record_sandbox_prepared(
        snapshot,
        observation,
        lease,
        snapshot.identities.audit_sandbox,
        fn(kind) { kind is PrepareAuditSandbox(_) },
        PartAuditSandboxPrepared,
        WorkflowAuditTake,
        observed_at,
      )
    ImplementationHarnessStarted(session) =>
      record_harness_started(
        snapshot,
        observation,
        session,
        snapshot.identities.implementation_session,
        fn(kind) { kind is StartImplementationHarness(_) },
        PartImplementationHarnessStarted,
        WorkflowImplementationTake,
        observed_at,
      )
    VerificationHarnessStarted(session) =>
      record_harness_started(
        snapshot,
        observation,
        session,
        snapshot.identities.verification_session,
        fn(kind) { kind is StartVerificationHarness(_) },
        PartVerificationHarnessStarted,
        WorkflowVerificationTake,
        observed_at,
      )
    AuditHarnessStarted(session) =>
      record_harness_started(
        snapshot,
        observation,
        session,
        snapshot.identities.audit_session,
        fn(kind) { kind is StartAuditHarness(_) },
        PartAuditHarnessStarted,
        WorkflowAuditTake,
        observed_at,
      )
    ImplementationCompleted(result, final_session, events) => {
      let intent = match authorized_effect(snapshot) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if !(intent.kind is DispatchImplementation(take_id, session_id) &&
        take_id == result.take_id &&
        session_id == result.session_id) ||
        result.take_id != snapshot.implementation_take.id ||
        !artifact_exists(result.result_artifact) {
        return Err(
          workflow_error("implementation result does not match intent"),
        )
      }
      let initial = match
        find_harness_session(snapshot.harness_sessions, result.session_id) {
        Some(value) => value
        None => return Err(workflow_error("implementation session is missing"))
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
      let take = match
        take_success_after_result(
          snapshot.implementation_take,
          snapshot.fencing_epoch,
          result.result_artifact.digest,
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      finish_effect_observation(
        snapshot,
        {
          ..snapshot,
          stage: PartImplementationCompleted,
          implementation_take: take,
          harness_sessions: sessions,
          harness_events: append_events(snapshot.harness_events, durable_events),
          implementation_result: Some(result),
        },
        observation,
        observed_at,
      )
    }
    CandidateNormalized(candidate, path_evidence) => {
      let intent = match authorized_effect(snapshot) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if !(intent.kind is NormalizeImplementationCandidate(take_id, _) &&
        take_id == snapshot.implementation_take.id) {
        return Err(
          workflow_error("candidate does not match normalization intent"),
        )
      }
      match
        @control.validate_candidate_commit(
          snapshot.task_contract,
          snapshot.implementation_take,
          candidate,
          path_evidence,
          is_nfc,
        ) {
        Ok(_) => ()
        Err(_) => return Err(workflow_error("candidate failed normalization"))
      }
      let part = match
        @control.transition_part(
          snapshot.part,
          @control.PartTransition::RecordPartCandidate(
            snapshot.implementation_take.id,
            candidate.id,
          ),
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let subject = verification_subject(candidate, snapshot.task_contract)
      let verification_take = {
        ..snapshot.verification_take,
        purpose: @control.TakePurpose::PartVerification(
          snapshot.part.id,
          snapshot.implementation_take.id,
          subject.subject_digest,
        ),
      }
      finish_effect_observation(
        snapshot,
        {
          ..snapshot,
          stage: PartCandidateRecorded,
          part,
          candidate: Some(candidate),
          verification_subject: Some(subject),
          verification_take,
        },
        observation,
        observed_at,
      )
    }
    VerificationCompleted(result, final_session, events) =>
      record_verification_completion(
        snapshot, observation, result, final_session, events, observed_at, artifact_exists,
      )
    AuditCompleted(submission, final_session, events) =>
      record_audit_completion(
        snapshot, observation, submission, final_session, events, observed_at, artifact_exists,
      )
    PromotionGenerated(promotion) =>
      record_promotion_generation(snapshot, observation, promotion, observed_at)
    PromotionConflictObserved(_) =>
      record_promotion_conflict(snapshot, observation, observed_at, is_nfc)
    IntegrationWitnessObserved(witness) =>
      record_integration_witness(snapshot, observation, witness, observed_at)
  }
}

///|
pub fn apply_or_reconcile_part_effect_observation(
  snapshot : PartWorkflowSnapshot,
  intent : PartEffectIntent,
  observation : PartEffectObservation,
  observed_at : Int64,
  artifact_exists : (@control.ArtifactReference) -> Bool,
  is_nfc : (String) -> Bool,
) -> Result[PartWorkflowSnapshot, @types.ChoirError] {
  if snapshot.pending_effect is None {
    let observation_digest = part_effect_observation_digest(observation)
    if snapshot.effect_receipts.any(fn(receipt) {
        receipt.effect_id == intent.effect_id &&
        receipt.request_digest == intent.request_digest &&
        receipt.observation_digest == observation_digest
      }) {
      return Ok(snapshot)
    }
  }
  apply_part_effect_observation(
    snapshot, observation, observed_at, artifact_exists, is_nfc,
  )
}
