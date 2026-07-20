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
