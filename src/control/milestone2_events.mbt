///|
fn event_sequence_value(sequence : EventSequence) -> Int64 {
  guard sequence is EventSequence(value) else { return 0L }
  value
}

///|
fn event_identity_matches(
  left : HarnessEventEnvelope,
  right : HarnessEventEnvelope,
) -> Bool {
  left.id == right.id || left.source_position == right.source_position
}

///|
fn event_semantics_match(
  left : HarnessEventEnvelope,
  right : HarnessEventEnvelope,
) -> Bool {
  left.take_id == right.take_id &&
  left.session_id == right.session_id &&
  left.source_position == right.source_position &&
  left.kind == right.kind &&
  left.sanitized_payload_digest == right.sanitized_payload_digest &&
  left.redaction_state == right.redaction_state
}

///|
fn protocol_violated_ingestion(
  session : HarnessSession,
  event : HarnessEventEnvelope,
) -> HarnessIngestionResult {
  {
    session: {
      ..session,
      last_choir_sequence: event.choir_sequence,
      lifecycle: HarnessSessionProtocolViolated,
    },
    event: Some(event),
    disposition: HarnessEventConflict,
  }
}

///|
fn remove_open_tool(
  open_tools : Array[String],
  execution_id : String,
) -> Array[String] {
  let remaining : Array[String] = []
  let mut removed = false
  for current in open_tools {
    if !removed && current == execution_id {
      removed = true
    } else {
      remaining.push(current)
    }
  }
  remaining
}

///|
fn terminal_from_lifecycle(
  lifecycle : HarnessSessionLifecycle,
) -> HarnessTerminalObservation? {
  match lifecycle {
    HarnessSessionTerminalObserved(terminal)
    | HarnessSessionIngestionClosedCleanly(terminal) => Some(terminal)
    _ => None
  }
}

///|
pub fn ingest_harness_event(
  session : HarnessSession,
  durable_events : Array[HarnessEventEnvelope],
  incoming : HarnessEventEnvelope,
) -> HarnessIngestionResult {
  for existing in durable_events {
    if event_identity_matches(existing, incoming) {
      if event_semantics_match(existing, incoming) {
        return { session, event: None, disposition: HarnessEventDuplicate }
      }
      return protocol_violated_ingestion(session, incoming)
    }
  }
  if incoming.take_id != session.take_id || incoming.session_id != session.id {
    return protocol_violated_ingestion(session, incoming)
  }
  let expected_sequence = event_sequence_value(session.last_choir_sequence) + 1L
  if event_sequence_value(incoming.choir_sequence) != expected_sequence {
    return {
      session: { ..session, lifecycle: HarnessSessionRecoveryUncertain },
      event: None,
      disposition: HarnessEventCursorGap,
    }
  }
  match terminal_from_lifecycle(session.lifecycle) {
    Some(existing_terminal) => {
      let late = { ..incoming, late: true }
      match incoming.kind {
        HarnessTerminal(later_terminal) if later_terminal != existing_terminal =>
          protocol_violated_ingestion(session, late)
        _ =>
          {
            session: { ..session, last_choir_sequence: incoming.choir_sequence },
            event: Some(late),
            disposition: HarnessEventLate,
          }
      }
    }
    None =>
      match (session.lifecycle, incoming.kind) {
        (HarnessSessionPlanned, HarnessStarted) =>
          {
            session: {
              ..session,
              last_choir_sequence: incoming.choir_sequence,
              lifecycle: HarnessSessionRunning,
            },
            event: Some(incoming),
            disposition: HarnessEventAppended,
          }
        (HarnessSessionRunning, HarnessToolStarted(execution_id)) =>
          if session.open_tool_execution_ids.contains(execution_id) {
            protocol_violated_ingestion(session, incoming)
          } else {
            let open_tools = session.open_tool_execution_ids.copy()
            open_tools.push(execution_id)
            {
              session: {
                ..session,
                last_choir_sequence: incoming.choir_sequence,
                open_tool_execution_ids: open_tools,
              },
              event: Some(incoming),
              disposition: HarnessEventAppended,
            }
          }
        (HarnessSessionRunning, HarnessToolFinished(execution_id)) =>
          if !session.open_tool_execution_ids.contains(execution_id) {
            protocol_violated_ingestion(session, incoming)
          } else {
            {
              session: {
                ..session,
                last_choir_sequence: incoming.choir_sequence,
                open_tool_execution_ids: remove_open_tool(
                  session.open_tool_execution_ids,
                  execution_id,
                ),
              },
              event: Some(incoming),
              disposition: HarnessEventAppended,
            }
          }
        (HarnessSessionRunning, HarnessTerminal(terminal)) =>
          if session.open_tool_execution_ids.length() != 0 {
            protocol_violated_ingestion(session, incoming)
          } else {
            {
              session: {
                ..session,
                last_choir_sequence: incoming.choir_sequence,
                lifecycle: HarnessSessionTerminalObserved(terminal),
              },
              event: Some(incoming),
              disposition: HarnessEventAppended,
            }
          }
        _ => protocol_violated_ingestion(session, incoming)
      }
  }
}

///|
pub fn close_harness_ingestion(
  session : HarnessSession,
) -> Result[HarnessSession, @types.ChoirError] {
  match session.lifecycle {
    HarnessSessionTerminalObserved(terminal) =>
      if session.open_tool_execution_ids.length() == 0 {
        Ok({
          ..session,
          lifecycle: HarnessSessionIngestionClosedCleanly(terminal),
        })
      } else {
        Err(
          @types.ChoirError::validation_error(
            "harness ingestion cannot close with an open tool execution",
          ),
        )
      }
    _ =>
      Err(
        @types.ChoirError::validation_error(
          "harness ingestion cannot close without one balanced terminal trace",
        ),
      )
  }
}
