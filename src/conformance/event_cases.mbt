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
