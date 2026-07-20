///|
let event_case_digest : @control.Digest = @control.Digest(
  "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
)

///|
fn event_case_session() -> @control.HarnessSession {
  {
    id: @control.HarnessSessionId("event-case-session"),
    take_id: @control.TakeId("event-case-take"),
    sandbox_generation_id: @control.SandboxGenerationId("event-case-generation"),
    surface: @control.ProviderSurfaceId::ClaudeSubscriptionCli,
    effective_surface_manifest_digest: event_case_digest,
    cursor_class: @control.HarnessCursorClass::HarnessCursorProviderEventId,
    provider_cursor: None,
    last_choir_sequence: @control.EventSequence(0L),
    open_tool_execution_ids: [],
    lifecycle: @control.HarnessSessionLifecycle::HarnessSessionPlanned,
  }
}

///|
fn event_case_envelope(
  id : String,
  sequence : Int64,
  kind : @control.HarnessEventKind,
) -> @control.HarnessEventEnvelope {
  {
    id: @control.HarnessEventId(id),
    take_id: @control.TakeId("event-case-take"),
    session_id: @control.HarnessSessionId("event-case-session"),
    source_position: @control.EventSourcePosition::EventProviderId(id),
    choir_sequence: @control.EventSequence(sequence),
    observed_at: sequence,
    kind,
    sanitized_payload_digest: event_case_digest,
    redaction_state: @control.EventRedactionState::EventNotSensitive,
    late: false,
  }
}

///|
fn event_case_error(detail : String) -> @types.ChoirError {
  @types.ChoirError::validation_error("event conformance failed: " + detail)
}

///|
fn event_case_evidence(
  result : @control.HarnessIngestionResult,
) -> ConformanceEvidence {
  ObservedHarnessIngestion(
    result.disposition,
    result.session.lifecycle,
    result.event is Some({ late: true, .. }),
  )
}

///|
fn event_authorized_provider_dispatch_fixture() -> (
  @workflow.PartWorkflowSnapshot,
  @workflow.PartEffectIntent,
) {
  let goal_id = @control.GoalId("event-process-loss-goal")
  let part_id = @control.PartId("event-process-loss-part")
  let revision_id = @control.RevisionId("event-process-loss-revision")
  let epoch = @control.FencingEpoch(9L)
  let implementation_take : @control.Take = {
    id: @control.TakeId("event-process-loss-implementation"),
    goal_id,
    purpose: @control.TakePurpose::Implementation(part_id, revision_id),
    ordinal: 1,
    fencing_epoch: Some(epoch),
    lifecycle: @control.TakeLifecycle::TakeRunning,
  }
  let verification_take : @control.Take = {
    id: @control.TakeId("event-process-loss-verification"),
    goal_id,
    purpose: @control.TakePurpose::PartVerification(
      part_id,
      implementation_take.id,
      event_case_digest,
    ),
    ordinal: 1,
    fencing_epoch: None,
    lifecycle: @control.TakeLifecycle::TakePlanned,
  }
  let audit_take : @control.Take = {
    id: @control.TakeId("event-process-loss-audit"),
    goal_id,
    purpose: @control.TakePurpose::PartAudit(
      part_id,
      implementation_take.id,
      event_case_digest,
    ),
    ordinal: 1,
    fencing_epoch: None,
    lifecycle: @control.TakeLifecycle::TakePlanned,
  }
  let lease = fn(
    id : String,
    take : @control.Take,
    lifecycle : @control.SandboxLeaseLifecycle,
  ) -> @control.SandboxLease {
    {
      id: @control.SandboxLeaseId(id),
      take_id: take.id,
      generation_id: @control.SandboxGenerationId(id + "-generation"),
      capability_profile_digest: event_case_digest,
      runtime_policy_digest: event_case_digest,
      lifecycle,
    }
  }
  let implementation_lease = lease(
    "event-process-loss-implementation-lease",
    implementation_take,
    @control.SandboxLeaseLifecycle::SandboxLeaseActive,
  )
  let verification_lease = lease(
    "event-process-loss-verification-lease",
    verification_take,
    @control.SandboxLeaseLifecycle::SandboxLeasePlanned,
  )
  let audit_lease = lease(
    "event-process-loss-audit-lease",
    audit_take,
    @control.SandboxLeaseLifecycle::SandboxLeasePlanned,
  )
  let session = fn(
    id : String,
    take : @control.Take,
    lease : @control.SandboxLease,
    lifecycle : @control.HarnessSessionLifecycle,
  ) -> @control.HarnessSession {
    {
      id: @control.HarnessSessionId(id),
      take_id: take.id,
      sandbox_generation_id: lease.generation_id,
      surface: @control.ProviderSurfaceId::ClaudeSubscriptionCli,
      effective_surface_manifest_digest: event_case_digest,
      cursor_class: @control.HarnessCursorClass::HarnessCursorNotResumable,
      provider_cursor: None,
      last_choir_sequence: @control.EventSequence(0L),
      open_tool_execution_ids: [],
      lifecycle,
    }
  }
  let implementation_session = session(
    "event-process-loss-implementation-session",
    implementation_take,
    implementation_lease,
    @control.HarnessSessionLifecycle::HarnessSessionAwaitingEvents,
  )
  let verification_session = session(
    "event-process-loss-verification-session",
    verification_take,
    verification_lease,
    @control.HarnessSessionLifecycle::HarnessSessionPlanned,
  )
  let audit_session = session(
    "event-process-loss-audit-session",
    audit_take,
    audit_lease,
    @control.HarnessSessionLifecycle::HarnessSessionPlanned,
  )
  let intent : @workflow.PartEffectIntent = {
    effect_id: "event-process-loss-dispatch",
    kind: @workflow.PartEffectKind::DispatchImplementation(
      implementation_take.id,
      implementation_session.id,
    ),
    request_digest: event_case_digest,
    lifecycle: @workflow.PartEffectLifecycle::PartEffectMayHaveOccurred,
  }
  let snapshot : @workflow.PartWorkflowSnapshot = {
    workflow_id: "event-process-loss-workflow",
    durable_version: 7,
    fencing_epoch: epoch,
    stage: @workflow.PartWorkflowStage::PartImplementationHarnessStarted,
    goal: {
      id: goal_id,
      contract_digest: event_case_digest,
      lifecycle: @control.GoalLifecycle::GoalActive(
        @control.GoalActiveCondition::GoalRunning,
      ),
    },
    part: {
      id: part_id,
      goal_id,
      dependency_ids: [],
      task_contract_revision_id: revision_id,
      lifecycle: @control.PartLifecycle::PartExecuting(implementation_take.id),
    },
    task_contract: {
      id: revision_id,
      goal_id,
      part_id,
      revision: 1,
      digest: event_case_digest,
      instruction_artifact: {
        artifact_id: "event-process-loss-instruction",
        digest: event_case_digest,
      },
      base_commit_oid: @control.GitOid("event-process-loss-base"),
      base_tree_oid: @control.GitOid("event-process-loss-tree"),
      path_mode: @control.RepositoryPathMode::CaseSensitiveNfc,
      mutation_declaration: @control.MutationDeclaration::CompleteMutationDeclaration(
        [],
      ),
      verification_specs: [],
      audit_policy_digest: event_case_digest,
      implementation_capability_profile_digest: event_case_digest,
      verification_capability_profile_digest: event_case_digest,
      audit_capability_profile_digest: event_case_digest,
    },
    identities: {
      implementation_take,
      implementation_sandbox: implementation_lease,
      implementation_session,
      verification_take,
      verification_sandbox: verification_lease,
      verification_session,
      audit_take,
      audit_sandbox: audit_lease,
      audit_session,
    },
    implementation_take,
    verification_take,
    audit_take,
    sandbox_leases: [implementation_lease, verification_lease, audit_lease],
    harness_sessions: [
      implementation_session,
      verification_session,
      audit_session,
    ],
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
    pending_effect: Some(intent),
    effect_receipts: [],
  }
  (snapshot, intent)
}

///|
fn event_provider_uncertainty_holds(
  original : @workflow.PartWorkflowSnapshot,
  restarted : @workflow.PartWorkflowSnapshot,
  reason : @control.TakeUncertaintyReason,
) -> Bool {
  let implementation_session_uncertain = restarted.harness_sessions.any(
    fn(session) {
      session.id == restarted.identities.implementation_session.id &&
      session.lifecycle ==
      @control.HarnessSessionLifecycle::HarnessSessionRecoveryUncertain
    },
  )
  restarted.durable_version == original.durable_version + 1 &&
  restarted.stage == @workflow.PartWorkflowStage::PartRecoveryUncertain &&
  (restarted.part.lifecycle
  is @control.PartLifecycle::PartBlocked(
    @control.PartBlockReason::PartRecoveryUncertain
  )) &&
  restarted.implementation_take.lifecycle ==
  @control.TakeLifecycle::TakeTerminal(
    @control.TakeTerminalDisposition::TakeRecoveryUncertain(reason)
  ) &&
  implementation_session_uncertain &&
  (restarted.pending_effect
  is Some({
    lifecycle: @workflow.PartEffectLifecycle::PartEffectUncertain,
    ..
  })) &&
  restarted.implementation_result is None &&
  restarted.candidate is None &&
  restarted.verification_receipts.length() == 0 &&
  restarted.audit_receipt is None &&
  restarted.integration_receipt is None
}

///|
fn event_resumable_implementation_observation_fixture() -> (
  @workflow.PartWorkflowSnapshot,
  @workflow.PartEffectIntent,
  @workflow.PartEffectObservation,
) {
  let (base, intent) = event_authorized_provider_dispatch_fixture()
  let initial_session = {
    ..base.identities.implementation_session,
    surface: @control.ProviderSurfaceId::CodexSubscriptionCli,
    cursor_class: @control.HarnessCursorClass::HarnessCursorProviderEventId,
  }
  let cursor = "thread-event:turn-event"
  let started : @control.HarnessEventEnvelope = {
    id: @control.HarnessEventId("event-transaction-started"),
    take_id: initial_session.take_id,
    session_id: initial_session.id,
    source_position: @control.EventSourcePosition::EventProviderId(
      cursor + ":started",
    ),
    choir_sequence: @control.EventSequence(1L),
    observed_at: 101L,
    kind: @control.HarnessEventKind::HarnessStarted,
    sanitized_payload_digest: event_case_digest,
    redaction_state: @control.EventRedactionState::EventNotSensitive,
    late: false,
  }
  let terminal : @control.HarnessEventEnvelope = {
    id: @control.HarnessEventId("event-transaction-terminal"),
    take_id: initial_session.take_id,
    session_id: initial_session.id,
    source_position: @control.EventSourcePosition::EventProviderId(
      cursor + ":terminal",
    ),
    choir_sequence: @control.EventSequence(2L),
    observed_at: 102L,
    kind: @control.HarnessEventKind::HarnessTerminal(
      @control.HarnessTerminalObservation::HarnessCompleted,
    ),
    sanitized_payload_digest: event_case_digest,
    redaction_state: @control.EventRedactionState::EventNotSensitive,
    late: false,
  }
  let final_session = {
    ..initial_session,
    provider_cursor: Some(cursor),
    last_choir_sequence: @control.EventSequence(2L),
    lifecycle: @control.HarnessSessionLifecycle::HarnessSessionIngestionClosedCleanly(
      @control.HarnessTerminalObservation::HarnessCompleted,
    ),
  }
  let snapshot = {
    ..base,
    identities: { ..base.identities, implementation_session: initial_session },
    harness_sessions: base.harness_sessions.map(fn(session) {
      if session.id == initial_session.id { initial_session } else { session }
    }),
  }
  let observation = @workflow.PartEffectObservation::ImplementationCompleted(
    {
      take_id: snapshot.implementation_take.id,
      session_id: initial_session.id,
      result_artifact: {
        artifact_id: "event-transaction-result",
        digest: event_case_digest,
      },
      finished_at: 103L,
    },
    final_session,
    [started, terminal],
  )
  (snapshot, intent, observation)
}

///|
fn event_apply_or_reconcile_observation(
  snapshot : @workflow.PartWorkflowSnapshot,
  intent : @workflow.PartEffectIntent,
  observation : @workflow.PartEffectObservation,
) -> Result[@workflow.PartWorkflowSnapshot, @types.ChoirError] {
  @workflow.apply_or_reconcile_part_effect_observation(
    snapshot,
    intent,
    observation,
    104L,
    fn(_) { true },
    fn(_) { true },
  )
}

///|
fn event_committed_observation_holds(
  original : @workflow.PartWorkflowSnapshot,
  committed : @workflow.PartWorkflowSnapshot,
  intent : @workflow.PartEffectIntent,
  observation : @workflow.PartEffectObservation,
) -> Bool {
  let matching_receipts = committed.effect_receipts.filter(fn(receipt) {
    receipt.effect_id == intent.effect_id &&
    receipt.request_digest == intent.request_digest &&
    receipt.observation_digest ==
    @workflow.part_effect_observation_digest(observation)
  })
  let mut committed_session_holds = false
  for session in committed.harness_sessions {
    if session.id == committed.identities.implementation_session.id &&
      session.provider_cursor == Some("thread-event:turn-event") &&
      session.last_choir_sequence == @control.EventSequence(2L) &&
      session.lifecycle ==
      @control.HarnessSessionLifecycle::HarnessSessionIngestionClosedCleanly(
        @control.HarnessTerminalObservation::HarnessCompleted,
      ) {
      committed_session_holds = true
    }
  }
  committed.durable_version == original.durable_version + 1 &&
  committed.stage == @workflow.PartWorkflowStage::PartImplementationCompleted &&
  committed.pending_effect is None &&
  committed.harness_events.length() == 2 &&
  committed.implementation_result is Some(_) &&
  matching_receipts.length() == 1 && committed_session_holds
}

///|
pub fn event_before_ingest_transaction_case() -> HermeticConformanceCase {
  {
    id: ConformanceCaseId("event.before_ingest_tx"),
    run: fn(context) {
      let point = FaultPoint::EventBeforeIngestTransaction
      if !context.fault_enabled(point) {
        return Err(event_case_error("ingest transaction fault was not injected"))
      }
      let (snapshot, intent, observation) =
        event_resumable_implementation_observation_fixture()
      let discarded = match
        event_apply_or_reconcile_observation(snapshot, intent, observation) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if !event_committed_observation_holds(
        snapshot, discarded, intent, observation,
      ) {
        return Err(event_case_error("discarded ingest projection was invalid"))
      }
      let restarted = match
        @workflow.decode_part_snapshot(@workflow.part_snapshot_bytes(snapshot)) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let committed = match
        event_apply_or_reconcile_observation(restarted, intent, observation) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if !event_committed_observation_holds(
        snapshot, committed, intent, observation,
      ) {
        return Err(event_case_error("pre-transaction restart lost the event batch"))
      }
      Ok({
        evidence: [
          ObservedFault(point),
          ObservedEventCase(EventBeforeIngestTransactionRecovery, 2),
        ],
      })
    },
  }
}

///|
pub fn event_after_ingest_transaction_before_source_ack_case(
) -> HermeticConformanceCase {
  {
    id: ConformanceCaseId("event.after_ingest_tx_before_source_ack"),
    run: fn(context) {
      let point = FaultPoint::EventAfterIngestTransactionBeforeSourceAck
      if !context.fault_enabled(point) {
        return Err(event_case_error("post-ingest source-ack fault was not injected"))
      }
      let (snapshot, intent, observation) =
        event_resumable_implementation_observation_fixture()
      let committed = match
        event_apply_or_reconcile_observation(snapshot, intent, observation) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let restarted = match
        @workflow.decode_part_snapshot(@workflow.part_snapshot_bytes(committed)) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let replayed = match
        event_apply_or_reconcile_observation(restarted, intent, observation) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let unrelated = event_apply_or_reconcile_observation(
        restarted,
        { ..intent, effect_id: "event-unrelated-dispatch" },
        observation,
      )
      if replayed != restarted ||
        !(unrelated is Err(_)) ||
        !event_committed_observation_holds(
          snapshot, replayed, intent, observation,
        ) {
        return Err(event_case_error("source replay duplicated the committed batch"))
      }
      Ok({
        evidence: [
          ObservedFault(point),
          ObservedEventCase(
            EventAfterIngestTransactionBeforeSourceAckRecovery,
            replayed.harness_events.length(),
          ),
        ],
      })
    },
  }
}

///|
pub fn event_after_source_ack_before_next_read_case() -> HermeticConformanceCase {
  {
    id: ConformanceCaseId("event.after_source_ack_before_next_read"),
    run: fn(context) {
      let point = FaultPoint::EventAfterSourceAckBeforeNextRead
      if !context.fault_enabled(point) {
        return Err(event_case_error("post-ack next-read fault was not injected"))
      }
      let (snapshot, intent, observation) =
        event_resumable_implementation_observation_fixture()
      let committed = match
        event_apply_or_reconcile_observation(snapshot, intent, observation) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let restarted = match
        @workflow.decode_part_snapshot(@workflow.part_snapshot_bytes(committed)) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let replayed = match
        event_apply_or_reconcile_observation(restarted, intent, observation) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let next = match @workflow.plan_next_part_effect(replayed) {
        Ok(Some(value)) => value
        Ok(None) => return Err(event_case_error("next effect was not planned"))
        Err(error) => return Err(error)
      }
      let next_is_normalization = match next.kind {
        @workflow.PartEffectKind::NormalizeImplementationCandidate(
          take_id,
          _,
        ) => take_id == replayed.implementation_take.id
        _ => false
      }
      if replayed != restarted || !next_is_normalization ||
        !event_committed_observation_holds(
          snapshot, replayed, intent, observation,
        ) {
        return Err(event_case_error("resume did not continue after the durable cursor"))
      }
      Ok({
        evidence: [
          ObservedFault(point),
          ObservedEventCase(
            EventAfterSourceAckBeforeNextReadRecovery,
            replayed.harness_events.length(),
          ),
        ],
      })
    },
  }
}

///|
pub fn event_nonresumable_process_loss_case() -> HermeticConformanceCase {
  {
    id: ConformanceCaseId("event.nonresumable_process_loss"),
    run: fn(_) {
      let (snapshot, intent) = event_authorized_provider_dispatch_fixture()
      let uncertain = match
        @workflow.record_part_provider_process_loss(snapshot, intent) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let restarted = match
        @workflow.decode_part_snapshot(
          @workflow.part_snapshot_bytes(uncertain),
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if restarted != uncertain ||
        !event_provider_uncertainty_holds(
          snapshot,
          restarted,
          @control.TakeUncertaintyReason::TakeEffectUncertain,
        ) {
        return Err(
          event_case_error(
            "nonresumable process loss inferred progress or was not restart-stable",
          ),
        )
      }
      Ok({
        evidence: [
          ObservedEventCase(EventNonresumableProcessLoss, 10),
        ],
      })
    },
  }
}

///|
pub fn event_backpressure_case() -> HermeticConformanceCase {
  {
    id: ConformanceCaseId("event.backpressure"),
    run: fn(_) {
      let capacity = @harness.codex_event_spool_capacity_bytes
      if !(@harness.validate_codex_event_spool_size(capacity) is Ok(_)) {
        return Err(event_case_error("spool rejected its exact capacity"))
      }
      match @harness.validate_codex_event_spool_size(capacity + 1) {
        Err(error) if error.is_event_ingestion_overflow() => ()
        _ => return Err(event_case_error("spool overflow did not fail closed"))
      }
      let (snapshot, intent) = event_authorized_provider_dispatch_fixture()
      let uncertain = match
        @workflow.record_part_event_ingestion_overflow(snapshot, intent) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let restarted = match
        @workflow.decode_part_snapshot(
          @workflow.part_snapshot_bytes(uncertain),
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let cursor_advanced = restarted.harness_sessions.any(fn(session) {
        session.id == restarted.identities.implementation_session.id &&
        session.last_choir_sequence !=
        snapshot.identities.implementation_session.last_choir_sequence
      })
      if restarted != uncertain ||
        !event_provider_uncertainty_holds(
          snapshot,
          restarted,
          @control.TakeUncertaintyReason::TakeCursorGap,
        ) ||
        restarted.harness_events != snapshot.harness_events ||
        cursor_advanced {
        return Err(
          event_case_error(
            "spool overflow advanced the event cursor or inferred progress",
          ),
        )
      }
      Ok({
        evidence: [ObservedEventCase(EventBackpressureBoundary, capacity)],
      })
    },
  }
}

///|
pub fn event_duplicate_conflict_case() -> HermeticConformanceCase {
  {
    id: ConformanceCaseId("event.duplicate_conflict"),
    run: fn(_) {
      let started = event_case_envelope(
        "event-1",
        1L,
        @control.HarnessEventKind::HarnessStarted,
      )
      let appended = @control.ingest_harness_event(
        event_case_session(),
        [],
        started,
      )
      let duplicate = @control.ingest_harness_event(
        appended.session,
        [started],
        started,
      )
      let conflict = @control.ingest_harness_event(
        appended.session,
        [started],
        {
          ..started,
          sanitized_payload_digest: @control.Digest(
            "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
          ),
        },
      )
      if duplicate.disposition !=
        @control.HarnessIngestionDisposition::HarnessEventDuplicate ||
        conflict.disposition !=
        @control.HarnessIngestionDisposition::HarnessEventConflict ||
        conflict.session.last_choir_sequence != @control.EventSequence(2L) ||
        !(conflict.event is Some({
          choir_sequence: @control.EventSequence(2L),
          ..
        })) ||
        !(conflict.session.lifecycle
        is @control.HarnessSessionLifecycle::HarnessSessionProtocolViolated) {
        return Err(event_case_error("duplicate/conflict oracle did not hold"))
      }
      Ok({
        evidence: [
          event_case_evidence(duplicate),
          event_case_evidence(conflict),
        ],
      })
    },
  }
}

///|
pub fn event_cursor_gap_case() -> HermeticConformanceCase {
  {
    id: ConformanceCaseId("event.cursor_gap"),
    run: fn(_) {
      let result = @control.ingest_harness_event(
        event_case_session(),
        [],
        event_case_envelope(
          "event-2",
          2L,
          @control.HarnessEventKind::HarnessStarted,
        ),
      )
      if result.disposition !=
        @control.HarnessIngestionDisposition::HarnessEventCursorGap ||
        !(result.session.lifecycle
        is @control.HarnessSessionLifecycle::HarnessSessionRecoveryUncertain) ||
        result.event is Some(_) {
        return Err(event_case_error("cursor-gap oracle did not hold"))
      }
      Ok({ evidence: [event_case_evidence(result)] })
    },
  }
}

///|
pub fn event_late_terminal_case() -> HermeticConformanceCase {
  {
    id: ConformanceCaseId("event.late_terminal"),
    run: fn(_) {
      let interrupted = {
        ..event_case_session(),
        last_choir_sequence: @control.EventSequence(1L),
        lifecycle: @control.HarnessSessionLifecycle::HarnessSessionTerminalObserved(
          @control.HarnessTerminalObservation::HarnessInterrupted,
        ),
      }
      let result = @control.ingest_harness_event(
        interrupted,
        [],
        event_case_envelope(
          "event-2",
          2L,
          @control.HarnessEventKind::HarnessTerminal(
            @control.HarnessTerminalObservation::HarnessCompleted,
          ),
        ),
      )
      if result.disposition !=
        @control.HarnessIngestionDisposition::HarnessEventLate ||
        !(result.session.lifecycle
        is @control.HarnessSessionLifecycle::HarnessSessionTerminalObserved(
          @control.HarnessTerminalObservation::HarnessInterrupted
        )) ||
        !(result.event is Some({ late: true, .. })) {
        return Err(event_case_error("late-terminal oracle did not hold"))
      }
      Ok({ evidence: [event_case_evidence(result)] })
    },
  }
}

///|
pub fn event_conflicting_terminal_case() -> HermeticConformanceCase {
  {
    id: ConformanceCaseId("event.conflicting_terminal"),
    run: fn(_) {
      let completed = {
        ..event_case_session(),
        last_choir_sequence: @control.EventSequence(1L),
        lifecycle: @control.HarnessSessionLifecycle::HarnessSessionTerminalObserved(
          @control.HarnessTerminalObservation::HarnessCompleted,
        ),
      }
      let result = @control.ingest_harness_event(
        completed,
        [],
        event_case_envelope(
          "event-2",
          2L,
          @control.HarnessEventKind::HarnessTerminal(
            @control.HarnessTerminalObservation::HarnessFailed,
          ),
        ),
      )
      if result.disposition !=
        @control.HarnessIngestionDisposition::HarnessEventConflict ||
        !(result.session.lifecycle
        is @control.HarnessSessionLifecycle::HarnessSessionRecoveryUncertain) ||
        !(result.event is Some({ late: true, .. })) {
        return Err(event_case_error("conflicting-terminal oracle did not hold"))
      }
      Ok({ evidence: [event_case_evidence(result)] })
    },
  }
}

///|
fn event_redaction_session(
  surface : @control.ProviderSurfaceId,
  manifest_digest : @control.Digest,
  cursor_class : @control.HarnessCursorClass,
) -> @control.HarnessSession {
  {
    id: @control.HarnessSessionId("event-redaction-session"),
    take_id: @control.TakeId("event-redaction-take"),
    sandbox_generation_id: @control.SandboxGenerationId(
      "event-redaction-generation",
    ),
    surface,
    effective_surface_manifest_digest: manifest_digest,
    cursor_class,
    provider_cursor: None,
    last_choir_sequence: @control.EventSequence(0L),
    open_tool_execution_ids: [],
    lifecycle: @control.HarnessSessionLifecycle::HarnessSessionPlanned,
  }
}

///|
fn event_redaction_claude(
  secret : String,
) -> Result[(@control.HarnessSession, String, String), @types.ChoirError] {
  let tool = "mcp__choir_sandbox__execute"
  let session = event_redaction_session(
    @control.ProviderSurfaceId::ClaudeSubscriptionCli,
    @harness.expected_claude_take_surface_manifest_digest(
      [tool],
      "choir_sandbox",
    ),
    @control.HarnessCursorClass::HarnessCursorNotResumable,
  )
  let started = match @harness.start_claude_harness_session(session) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let init =
    #|{"type":"system","subtype":"init","tools":["mcp__choir_sandbox__execute","StructuredOutput"],"mcp_servers":[{"name":"choir_sandbox","status":"connected"}],"permissionMode":"dontAsk","apiKeySource":"none","claude_code_version":"2.1.215","slash_commands":[],"skills":[],"plugins":[],"agents":["claude","Explore","general-purpose","Plan","statusline-setup"]}
  let rate =
    #|{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","rateLimitType":"five_hour","overageStatus":"rejected","isUsingOverage":false}}
  let assistant =
    #|{"type":"assistant","authorization":"Bearer SECRET","message":{"model":"claude-opus-4-8","content":[{"type":"tool_use","id":"tool-1","name":"mcp__choir_sandbox__execute"}]}}
  let tool_result =
    #|{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tool-1","content":"SECRET"}]}}
  let structured_start =
    #|{"type":"assistant","message":{"model":"claude-opus-4-8","content":[{"type":"tool_use","id":"tool-2","name":"StructuredOutput"}]}}
  let structured_result =
    #|{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tool-2","content":"ok"}]}}
  let terminal =
    #|{"type":"result","subtype":"success","is_error":false,"result":"{\"outcome\":\"completed\",\"secret\":\"SECRET\"}"}
  let output = [
    init,
    rate,
    assistant.replace_all(old="SECRET", new=secret),
    tool_result.replace_all(old="SECRET", new=secret),
    structured_start,
    structured_result,
    terminal.replace_all(old="SECRET", new=secret),
  ].join("\n")
  let result = match
    @harness.evaluate_claude_driver_capture({
      session: started,
      role: @harness.ClaudeTakeRole::ClaudeImplementationTake,
      allowed_tools: [tool],
      expected_mcp_server: "choir_sandbox",
      capture: { exit_code: 0, output, started_at: 10L, finished_at: 20L },
    }) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok((
    result.session,
    result.events.to_json().stringify(indent=0),
    result.terminal_response,
  ))
}

///|
fn event_redaction_codex(
  secret : String,
) -> Result[(@control.HarnessSession, String, String), @types.ChoirError] {
  let tool = "read_file"
  let session = event_redaction_session(
    @control.ProviderSurfaceId::CodexSubscriptionCli,
    @harness.codex_effective_surface_manifest_digest([tool], "choir_sandbox"),
    @control.HarnessCursorClass::HarnessCursorProviderEventId,
  )
  let started = match @harness.start_codex_harness_session(session) {
    Ok(value) => {
      ..value,
      provider_cursor: Some("redaction-thread:redaction-turn"),
    }
    Err(error) => return Err(error)
  }
  let thread = #|{"type":"thread.started","thread_id":"thread-redaction"}
  let turn = #|{"type":"turn.started"}
  let tool_started =
    #|{"type":"item.started","authorization":"Bearer SECRET","item":{"id":"tool-1","type":"mcp_tool_call","server":"choir_sandbox","tool":"read_file","status":"in_progress"}}
  let tool_finished =
    #|{"type":"item.completed","item":{"id":"tool-1","type":"mcp_tool_call","server":"choir_sandbox","tool":"read_file","status":"completed","output":"SECRET"}}
  let message =
    #|{"type":"item.completed","item":{"id":"message-1","type":"agent_message","text":"{\"outcome\":\"completed\",\"secret\":\"SECRET\"}"}}
  let completed = #|{"type":"turn.completed"}
  let output = [
    thread,
    turn,
    tool_started.replace_all(old="SECRET", new=secret),
    tool_finished.replace_all(old="SECRET", new=secret),
    message.replace_all(old="SECRET", new=secret),
    completed,
  ].join("\n")
  let result = match
    @harness.evaluate_codex_driver_capture({
      session: started,
      role: @harness.CodexTakeRole::CodexImplementationTake,
      allowed_tools: [tool],
      expected_mcp_server: "choir_sandbox",
      capture: { exit_code: 0, output, started_at: 10L, finished_at: 20L },
    }) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok((
    result.session,
    result.events.to_json().stringify(indent=0),
    result.terminal_response,
  ))
}

///|
pub fn event_redaction_case() -> HermeticConformanceCase {
  {
    id: ConformanceCaseId("event.redaction"),
    run: fn(_) {
      let secret = "CHOIR_SYNTHETIC_EVENT_SECRET"
      let claude = match event_redaction_claude(secret) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let codex = match event_redaction_codex(secret) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let retained = [claude.1, claude.2, codex.1, codex.2].join("\n")
      if retained.contains(secret) ||
        !(claude.0.lifecycle
        is @control.HarnessSessionLifecycle::HarnessSessionIngestionClosedCleanly(
          @control.HarnessTerminalObservation::HarnessCompleted
        )) ||
        !(codex.0.lifecycle
        is @control.HarnessSessionLifecycle::HarnessSessionIngestionClosedCleanly(
          @control.HarnessTerminalObservation::HarnessCompleted
        )) {
        return Err(event_case_error("provider bytes crossed redaction boundary"))
      }
      Ok({ evidence: [ObservedEventCase(EventRedactionBoundary, 2)] })
    },
  }
}
