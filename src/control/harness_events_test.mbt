///|
let event_digest : @control.Digest = @control.Digest(
  "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
)

///|
fn event_session() -> @control.HarnessSession {
  {
    id: @control.HarnessSessionId("session-1"),
    take_id: @control.TakeId("take-1"),
    sandbox_generation_id: @control.SandboxGenerationId("generation-1"),
    surface: @control.ProviderSurfaceId::ClaudeSubscriptionCli,
    effective_surface_manifest_digest: event_digest,
    cursor_class: @control.HarnessCursorClass::HarnessCursorProviderEventId,
    provider_cursor: None,
    last_choir_sequence: @control.EventSequence(0L),
    open_tool_execution_ids: [],
    lifecycle: @control.HarnessSessionLifecycle::HarnessSessionPlanned,
  }
}

///|
fn harness_event(
  id : String,
  sequence : Int64,
  kind : @control.HarnessEventKind,
) -> @control.HarnessEventEnvelope {
  {
    id: @control.HarnessEventId(id),
    take_id: @control.TakeId("take-1"),
    session_id: @control.HarnessSessionId("session-1"),
    source_position: @control.EventSourcePosition::EventProviderId(id),
    choir_sequence: @control.EventSequence(sequence),
    observed_at: sequence,
    kind,
    sanitized_payload_digest: event_digest,
    redaction_state: @control.EventRedactionState::EventNotSensitive,
    late: false,
  }
}

///|
test "harness ingestion persists one balanced terminal trace" {
  let durable : Array[@control.HarnessEventEnvelope] = []
  let started = harness_event(
    "event-1",
    1L,
    @control.HarnessEventKind::HarnessStarted,
  )
  let start_result = @control.ingest_harness_event(
    event_session(),
    durable,
    started,
  )
  assert_eq(
    start_result.disposition,
    @control.HarnessIngestionDisposition::HarnessEventAppended,
  )
  durable.push(started)
  let tool_started = harness_event(
    "event-2",
    2L,
    @control.HarnessEventKind::HarnessToolStarted("process-1"),
  )
  let tool_start_result = @control.ingest_harness_event(
    start_result.session,
    durable,
    tool_started,
  )
  durable.push(tool_started)
  assert_eq(tool_start_result.session.open_tool_execution_ids, ["process-1"])
  let tool_finished = harness_event(
    "event-3",
    3L,
    @control.HarnessEventKind::HarnessToolFinished(
      "process-1",
      @control.HarnessToolDisposition::HarnessToolSucceeded,
    ),
  )
  let tool_finish_result = @control.ingest_harness_event(
    tool_start_result.session,
    durable,
    tool_finished,
  )
  durable.push(tool_finished)
  assert_eq(tool_finish_result.session.open_tool_execution_ids, [])
  let terminal = harness_event(
    "event-4",
    4L,
    @control.HarnessEventKind::HarnessTerminal(
      @control.HarnessTerminalObservation::HarnessCompleted,
    ),
  )
  let terminal_result = @control.ingest_harness_event(
    tool_finish_result.session,
    durable,
    terminal,
  )
  match @control.close_harness_ingestion(terminal_result.session) {
    Ok(
      {
        lifecycle: @control.HarnessSessionLifecycle::HarnessSessionIngestionClosedCleanly(
          @control.HarnessTerminalObservation::HarnessCompleted
        ),
        ..,
      }
    ) => ()
    _ => fail("expected clean terminal ingestion closure")
  }
}

///|
test "harness ingestion deduplicates and rejects source conflicts" {
  let started = harness_event(
    "event-1",
    1L,
    @control.HarnessEventKind::HarnessStarted,
  )
  let first = @control.ingest_harness_event(event_session(), [], started)
  assert_eq(
    @control.ingest_harness_event(first.session, [started], started).disposition,
    @control.HarnessIngestionDisposition::HarnessEventDuplicate,
  )
  let conflict = {
    ..started,
    sanitized_payload_digest: @control.Digest(
      "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
    ),
  }
  let conflict_result = @control.ingest_harness_event(
    first.session,
    [started],
    conflict,
  )
  assert_eq(
    conflict_result.disposition,
    @control.HarnessIngestionDisposition::HarnessEventConflict,
  )
  assert_true(
    conflict_result.session.lifecycle
    is @control.HarnessSessionLifecycle::HarnessSessionProtocolViolated,
  )
}

///|
test "harness ingestion makes cursor gaps uncertain and late events inert" {
  let gap = @control.ingest_harness_event(
    event_session(),
    [],
    harness_event("event-2", 2L, @control.HarnessEventKind::HarnessStarted),
  )
  assert_eq(
    gap.disposition,
    @control.HarnessIngestionDisposition::HarnessEventCursorGap,
  )
  assert_true(
    gap.session.lifecycle
    is @control.HarnessSessionLifecycle::HarnessSessionRecoveryUncertain,
  )
  let terminal_session = {
    ..event_session(),
    last_choir_sequence: @control.EventSequence(2L),
    lifecycle: @control.HarnessSessionLifecycle::HarnessSessionTerminalObserved(
      @control.HarnessTerminalObservation::HarnessCompleted,
    ),
  }
  let late = @control.ingest_harness_event(
    terminal_session,
    [],
    harness_event(
      "event-3",
      3L,
      @control.HarnessEventKind::HarnessToolStarted("late-tool"),
    ),
  )
  assert_eq(
    late.disposition,
    @control.HarnessIngestionDisposition::HarnessEventLate,
  )
  match late.event {
    Some({ late: true, .. }) => ()
    _ => fail("expected late event to be retained and marked")
  }
}

///|
test "completion after interruption is late and interruption stays authoritative" {
  let interrupted = {
    ..event_session(),
    last_choir_sequence: @control.EventSequence(1L),
    lifecycle: @control.HarnessSessionLifecycle::HarnessSessionTerminalObserved(
      @control.HarnessTerminalObservation::HarnessInterrupted,
    ),
  }
  let completion = @control.ingest_harness_event(
    interrupted,
    [],
    harness_event(
      "event-2",
      2L,
      @control.HarnessEventKind::HarnessTerminal(
        @control.HarnessTerminalObservation::HarnessCompleted,
      ),
    ),
  )
  assert_eq(
    completion.disposition,
    @control.HarnessIngestionDisposition::HarnessEventLate,
  )
  assert_true(
    completion.session.lifecycle
    is @control.HarnessSessionLifecycle::HarnessSessionTerminalObserved(
      @control.HarnessTerminalObservation::HarnessInterrupted
    ),
  )
  assert_true(completion.event is Some({ late: true, .. }))
}

///|
test "conflicting success and failure terminals make recovery uncertain" {
  let completed = {
    ..event_session(),
    last_choir_sequence: @control.EventSequence(1L),
    lifecycle: @control.HarnessSessionLifecycle::HarnessSessionTerminalObserved(
      @control.HarnessTerminalObservation::HarnessCompleted,
    ),
  }
  let failure = @control.ingest_harness_event(
    completed,
    [],
    harness_event(
      "event-2",
      2L,
      @control.HarnessEventKind::HarnessTerminal(
        @control.HarnessTerminalObservation::HarnessFailed,
      ),
    ),
  )
  assert_eq(
    failure.disposition,
    @control.HarnessIngestionDisposition::HarnessEventConflict,
  )
  assert_true(
    failure.session.lifecycle
    is @control.HarnessSessionLifecycle::HarnessSessionRecoveryUncertain,
  )
  assert_true(failure.event is Some({ late: true, .. }))
}
