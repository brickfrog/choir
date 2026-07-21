///|
pub(all) enum CodexTakeRole {
  CodexImplementationTake
  CodexVerificationTake
  CodexAuditTake
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum CodexTakeOutcome {
  CodexImplementationCompleted
  CodexVerificationPassed
  CodexVerificationFailed
  CodexAuditPassed
  CodexAuditFindings(Int, Int)
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct CodexDriverCapture {
  exit_code : Int
  output : String
  started_at : Int64
  finished_at : Int64
} derive(Debug, Eq)

///|
pub(all) struct CodexDriverEvaluationRequest {
  session : @control.HarnessSession
  role : CodexTakeRole
  allowed_tools : Array[String]
  expected_mcp_server : String
  capture : CodexDriverCapture
} derive(Debug, Eq)

///|
pub(all) struct CodexDriverResult {
  session : @control.HarnessSession
  events : Array[@control.HarnessEventEnvelope]
  effective_surface_manifest_digest : @control.Digest
  terminal_response : String
  outcome : CodexTakeOutcome
  started_at : Int64
  finished_at : Int64
} derive(Debug, Eq)

///|
pub(all) struct CodexConductorCapture {
  exit_code : Int
  output : String
} derive(Debug, Eq)

///|
pub(all) struct CodexConductorTurn {
  thread_id : String
  response : String
  tool_call_count : Int
} derive(Debug, Eq, ToJson)

///|
priv enum CodexObservedToolEvent {
  CodexToolStarted(String, String)
  CodexToolFinished(String, Bool)
}

///|
fn codex_driver_error(message : String) -> @types.ChoirError {
  @types.ChoirError::validation_error("Codex driver: " + message)
}

///|
pub let codex_event_spool_capacity_bytes : Int = 16 * 1024 * 1024

///|
pub fn validate_codex_event_spool_size(
  size : Int,
) -> Result[Unit, @types.ChoirError] {
  if size < 0 || size > codex_event_spool_capacity_bytes {
    Err(
      @types.ChoirError::event_ingestion_overflow(
        "Codex app-server event spool exceeded 16 MiB",
      ),
    )
  } else {
    Ok(())
  }
}

///|
pub fn codex_take_disabled_features() -> Array[String] {
  [
    "multi_agent", "multi_agent_v2", "enable_fanout", "browser_use", "browser_use_external",
    "browser_use_full_cdp_access", "computer_use", "in_app_browser", "apps", "enable_mcp_apps",
    "plugins", "plugin_sharing", "hooks", "memories", "code_mode_host", "shell_tool",
    "unified_exec", "image_generation", "tool_suggest", "workspace_dependencies",
    "goals", "auth_elicitation", "tool_call_mcp_elicitation",
  ]
}

///|
fn valid_codex_tool_name(tool : String) -> Bool {
  if tool == "" || tool.length() > 120 {
    return false
  }
  for index = 0; index < tool.length(); index = index + 1 {
    let code = tool[index].to_int()
    let valid = (code >= 'a'.to_int() && code <= 'z'.to_int()) ||
      (code >= 'A'.to_int() && code <= 'Z'.to_int()) ||
      (code >= '0'.to_int() && code <= '9'.to_int()) ||
      code == '_'.to_int() ||
      code == '-'.to_int()
    if !valid {
      return false
    }
  }
  true
}

///|
fn valid_codex_thread_id(value : String) -> Bool {
  if value.length() < 16 || value.length() > 120 {
    return false
  }
  for index = 0; index < value.length(); index = index + 1 {
    let code = value[index].to_int()
    let valid = (code >= 'a'.to_int() && code <= 'z'.to_int()) ||
      (code >= 'A'.to_int() && code <= 'Z'.to_int()) ||
      (code >= '0'.to_int() && code <= '9'.to_int()) ||
      code == '-'.to_int() ||
      code == '_'.to_int()
    if !valid {
      return false
    }
  }
  true
}

///|
pub fn evaluate_codex_conductor_capture(
  capture : CodexConductorCapture,
  expected_thread_id : String?,
  expected_mcp_server : String,
  allowed_tools : Array[String],
) -> Result[CodexConductorTurn, @types.ChoirError] {
  if capture.exit_code != 0 ||
    expected_mcp_server == "" ||
    allowed_tools.length() == 0 {
    return Err(codex_driver_error("Conductor process capture is invalid"))
  }
  for index, tool in allowed_tools {
    if !valid_codex_tool_name(tool) || allowed_tools[:index].contains(tool) {
      return Err(codex_driver_error("Conductor tool declaration is invalid"))
    }
  }
  let mut thread_id = ""
  let mut turn_started = 0
  let mut turn_completed = 0
  let mut response = ""
  let mut tool_call_count = 0
  let open : Map[String, String] = Map([])
  let discovery_open : Map[String, Unit] = Map([])
  for raw in capture.output.split("\n") {
    let line = raw.trim().to_owned()
    if line == "" || line == "Reading additional input from stdin..." {
      continue
    }
    let json = @json.parse(line) catch {
      _ => return Err(codex_driver_error("Conductor emitted non-JSON output"))
    }
    guard json is Object(fields) else {
      return Err(codex_driver_error("Conductor event is not an object"))
    }
    match codex_json_string(fields, "type") {
      "thread.started" => {
        if thread_id != "" {
          return Err(codex_driver_error("Conductor started multiple threads"))
        }
        thread_id = codex_json_string(fields, "thread_id")
      }
      "turn.started" => turn_started = turn_started + 1
      "turn.completed" => turn_completed = turn_completed + 1
      "turn.failed" | "error" =>
        return Err(codex_driver_error("Conductor turn failed"))
      "item.started" | "item.completed" => {
        guard codex_json_object(fields, "item") is Some(item) else {
          return Err(codex_driver_error("Conductor item is malformed"))
        }
        match codex_json_string(item, "type") {
          "reasoning" => ()
          "agent_message" =>
            if codex_json_string(fields, "type") == "item.completed" {
              response = codex_json_string(item, "text")
            }
          "mcp_tool_call" => {
            let event_type = codex_json_string(fields, "type")
            let id = codex_json_string(item, "id")
            let server = codex_json_string(item, "server")
            let tool = codex_json_string(item, "tool")
            let discovery = tool == "list_mcp_resources" ||
              tool == "list_mcp_resource_templates"
            let discovery_server = server == expected_mcp_server ||
              server == "codex"
            if id == "" ||
              (discovery && !discovery_server) ||
              (!discovery && server != expected_mcp_server) ||
              (!discovery && !allowed_tools.contains(tool)) {
              return Err(
                codex_driver_error("Conductor observed an undeclared tool"),
              )
            }
            if event_type == "item.started" {
              if open.contains(id) || discovery_open.contains(id) {
                return Err(codex_driver_error("duplicate Conductor tool start"))
              }
              if discovery {
                discovery_open[id] = ()
              } else {
                open[id] = tool
                tool_call_count = tool_call_count + 1
              }
            } else {
              let status = codex_json_string(item, "status")
              if status != "completed" && status != "failed" {
                return Err(
                  codex_driver_error("Conductor tool status is invalid"),
                )
              }
              if discovery {
                if !discovery_open.contains(id) {
                  return Err(
                    codex_driver_error("unmatched Conductor discovery"),
                  )
                }
                discovery_open.remove(id)
              } else {
                match open.get(id) {
                  Some(open_tool) if open_tool == tool => open.remove(id)
                  _ =>
                    return Err(
                      codex_driver_error("unmatched Conductor tool result"),
                    )
                }
              }
            }
          }
          _ =>
            return Err(
              codex_driver_error("Conductor emitted a native host-tool event"),
            )
        }
      }
      _ => ()
    }
  }
  if !valid_codex_thread_id(thread_id) ||
    turn_started != 1 ||
    turn_completed != 1 ||
    response == "" ||
    open.length() != 0 ||
    discovery_open.length() != 0 {
    return Err(codex_driver_error("Conductor lifecycle is incomplete"))
  }
  match expected_thread_id {
    Some(expected) if thread_id != expected =>
      Err(codex_driver_error("Conductor resumed a different thread"))
    _ => Ok({ thread_id, response, tool_call_count })
  }
}

///|
pub fn codex_effective_surface_manifest_digest(
  allowed_tools : Array[String],
  mcp_server_name : String,
) -> @control.Digest {
  let tools = allowed_tools.copy()
  let disabled = codex_take_disabled_features()
  tools.sort()
  disabled.sort()
  @storage.artifact_digest(
    @utf8.encode(
      "choir.codex-effective-surface.v1\u{00}" +
      "client=" +
      expected_surface_version(CodexCli) +
      "\u{00}auth=chatgpt\u{00}approval=never\u{00}" +
      "filesystem=:minimal:read\u{00}network=false\u{00}" +
      "server=" +
      mcp_server_name +
      "\u{00}tools=" +
      tools.join(",") +
      "\u{00}transport=app-server-stdio-spool" +
      "\u{00}response_schema=choir.codex-take-output.v1" +
      "\u{00}disabled=" +
      disabled.join(","),
    ),
  )
}

///|
fn codex_response_int(fields : Map[String, Json], key : String) -> Int? {
  match fields.get(key) {
    Some(Number(value, ..)) => Some(value.to_int())
    _ => None
  }
}

///|
fn validate_codex_response(
  role : CodexTakeRole,
  response : String,
) -> Result[(CodexTakeOutcome, String), @types.ChoirError] {
  let json = @json.parse(response) catch {
    _ => return Err(codex_driver_error("terminal response is not JSON"))
  }
  guard json is Object(fields) else {
    return Err(codex_driver_error("terminal response is not an object"))
  }
  let outcome = codex_json_string(fields, "outcome")
  match role {
    CodexImplementationTake =>
      if outcome == "completed" {
        Ok((CodexImplementationCompleted, "{\"outcome\":\"completed\"}"))
      } else {
        Err(codex_driver_error("implementation outcome is invalid"))
      }
    CodexVerificationTake =>
      match outcome {
        "passed" => Ok((CodexVerificationPassed, "{\"outcome\":\"passed\"}"))
        "failed" => Ok((CodexVerificationFailed, "{\"outcome\":\"failed\"}"))
        _ => Err(codex_driver_error("verification outcome is invalid"))
      }
    CodexAuditTake => {
      let total = codex_response_int(fields, "total_findings")
      let blocking = codex_response_int(fields, "blocking_findings")
      match (outcome, total, blocking) {
        ("passed", Some(0), Some(0)) =>
          Ok(
            (
              CodexAuditPassed,
              "{\"outcome\":\"passed\",\"total_findings\":0,\"blocking_findings\":0}",
            ),
          )
        ("findings", Some(total), Some(blocking)) if total > 0 &&
          blocking >= 0 &&
          blocking <= total =>
          Ok(
            (
              CodexAuditFindings(total, blocking),
              "{\"outcome\":\"findings\",\"total_findings\":" +
              total.to_string() +
              ",\"blocking_findings\":" +
              blocking.to_string() +
              "}",
            ),
          )
        _ => Err(codex_driver_error("audit outcome is invalid"))
      }
    }
  }
}

///|
fn codex_driver_trace(
  output : String,
  expected_server : String,
  allowed_tools : Array[String],
) -> Result[(Array[CodexObservedToolEvent], String), @types.ChoirError] {
  let events : Array[CodexObservedToolEvent] = []
  let mut thread_started = 0
  let mut turn_started = 0
  let mut turn_completed = 0
  let mut response = ""
  let discovery_open : Map[String, Unit] = Map([])
  for raw in output.split("\n") {
    let json = @json.parse(raw.trim().to_owned()) catch { _ => continue }
    guard json is Object(fields) else { continue }
    let event_type = codex_json_string(fields, "type")
    match event_type {
      "thread.started" => thread_started = thread_started + 1
      "turn.started" => turn_started = turn_started + 1
      "turn.completed" => turn_completed = turn_completed + 1
      "turn.failed" => return Err(codex_driver_error("provider turn failed"))
      "item.started" | "item.completed" => {
        guard codex_json_object(fields, "item") is Some(item) else {
          return Err(codex_driver_error("provider item is malformed"))
        }
        let item_type = codex_json_string(item, "type")
        match item_type {
          "reasoning" => ()
          "agent_message" =>
            if event_type == "item.completed" {
              response = codex_json_string(item, "text")
            }
          "mcp_tool_call" => {
            let id = codex_json_string(item, "id")
            let server = codex_json_string(item, "server")
            let tool = codex_json_string(item, "tool")
            let diagnostic_tool = if valid_codex_tool_name(tool) {
              tool
            } else {
              "<invalid>"
            }
            if id == "" || server != expected_server {
              return Err(
                codex_driver_error(
                  "undeclared MCP tool event (server_matches=" +
                  (server == expected_server).to_string() +
                  ", tool=" +
                  diagnostic_tool +
                  ", id_present=" +
                  (id != "").to_string() +
                  ")",
                ),
              )
            }
            let discovery = tool == "list_mcp_resources" ||
              tool == "list_mcp_resource_templates"
            if !discovery && !allowed_tools.contains(tool) {
              return Err(
                codex_driver_error(
                  "undeclared MCP tool event (server=" +
                  expected_server +
                  ", tool=" +
                  diagnostic_tool +
                  ", id_present=true)",
                ),
              )
            }
            if event_type == "item.started" {
              if discovery {
                if discovery_open.contains(id) {
                  return Err(
                    codex_driver_error("duplicate MCP discovery start"),
                  )
                }
                discovery_open[id] = ()
              } else {
                events.push(CodexToolStarted(id, tool))
              }
            } else {
              match codex_json_string(item, "status") {
                "completed" =>
                  if discovery {
                    if !discovery_open.contains(id) {
                      return Err(
                        codex_driver_error("unmatched MCP discovery result"),
                      )
                    }
                    discovery_open.remove(id)
                  } else {
                    events.push(CodexToolFinished(id, true))
                  }
                "failed" =>
                  if discovery {
                    if !discovery_open.contains(id) {
                      return Err(
                        codex_driver_error("unmatched MCP discovery result"),
                      )
                    }
                    discovery_open.remove(id)
                  } else {
                    events.push(CodexToolFinished(id, false))
                  }
                _ =>
                  return Err(
                    codex_driver_error("MCP tool result status is invalid"),
                  )
              }
            }
          }
          _ => return Err(codex_driver_error("unexpected native tool event"))
        }
      }
      _ => ()
    }
  }
  if thread_started != 1 || turn_started != 1 || turn_completed != 1 {
    return Err(codex_driver_error("provider lifecycle is incomplete"))
  }
  if discovery_open.length() != 0 {
    return Err(codex_driver_error("MCP discovery trace is incomplete"))
  }
  let open : Map[String, String] = Map([])
  let mut starts = 0
  let mut successful_finishes = 0
  for event in events {
    match event {
      CodexToolStarted(id, tool) => {
        if open.contains(id) {
          return Err(codex_driver_error("duplicate MCP tool start"))
        }
        open[id] = tool
        starts = starts + 1
      }
      CodexToolFinished(id, succeeded) =>
        if !open.contains(id) {
          return Err(codex_driver_error("unmatched MCP tool result"))
        } else {
          open.remove(id)
          if succeeded {
            successful_finishes = successful_finishes + 1
          }
        }
    }
  }
  if starts == 0 {
    return Err(codex_driver_error("declared MCP tool was not called"))
  }
  if successful_finishes == 0 {
    return Err(codex_driver_error("every declared MCP tool call failed"))
  }
  if open.length() != 0 {
    return Err(codex_driver_error("MCP tool trace is incomplete"))
  }
  if response == "" {
    return Err(codex_driver_error("terminal response is absent"))
  }
  Ok((events, response))
}

///|
fn codex_take_event(
  session : @control.HarnessSession,
  sequence : Int64,
  observed_at : Int64,
  kind : @control.HarnessEventKind,
) -> @control.HarnessEventEnvelope {
  let provider_cursor = match session.provider_cursor {
    Some(cursor) => cursor
    None => "missing-provider-cursor"
  }
  {
    id: @control.HarnessEventId(session.id.0 + ":event:" + sequence.to_string()),
    take_id: session.take_id,
    session_id: session.id,
    source_position: @control.EventSourcePosition::EventProviderId(
      provider_cursor + ":event:" + sequence.to_string(),
    ),
    choir_sequence: @control.EventSequence(sequence),
    observed_at,
    kind,
    sanitized_payload_digest: safe_harness_event_digest(
      kind,
      @control.EventRedactionState::EventNotSensitive,
    ),
    redaction_state: @control.EventRedactionState::EventNotSensitive,
    late: false,
  }
}

///|
fn append_codex_take_event(
  session : @control.HarnessSession,
  events : Array[@control.HarnessEventEnvelope],
  event : @control.HarnessEventEnvelope,
) -> Result[@control.HarnessSession, @types.ChoirError] {
  let result = @control.ingest_harness_event(session, events, event)
  match result.disposition {
    @control.HarnessIngestionDisposition::HarnessEventAppended =>
      match result.event {
        Some(value) => {
          events.push(value)
          Ok(result.session)
        }
        None => Err(codex_driver_error("event append was not durable"))
      }
    _ => Err(codex_driver_error("event trace violated the harness protocol"))
  }
}

///|
pub fn start_codex_harness_session(
  session : @control.HarnessSession,
) -> Result[@control.HarnessSession, @types.ChoirError] {
  if session.surface != @control.ProviderSurfaceId::CodexSubscriptionCli ||
    session.lifecycle != @control.HarnessSessionLifecycle::HarnessSessionPlanned ||
    session.cursor_class !=
    @control.HarnessCursorClass::HarnessCursorProviderEventId ||
    session.provider_cursor is Some(_) ||
    session.last_choir_sequence != @control.EventSequence(0L) ||
    session.open_tool_execution_ids.length() != 0 {
    Err(codex_driver_error("session start capability is invalid"))
  } else {
    Ok({
      ..session,
      lifecycle: @control.HarnessSessionLifecycle::HarnessSessionAwaitingEvents,
    })
  }
}

///|
pub fn evaluate_codex_driver_capture(
  request : CodexDriverEvaluationRequest,
) -> Result[CodexDriverResult, @types.ChoirError] {
  if request.capture.exit_code != 0 {
    return Err(
      @types.ChoirError::provider_process_lost(
        "provider process exited with status " +
        request.capture.exit_code.to_string(),
      ),
    )
  }
  if request.capture.started_at <= 0L ||
    request.capture.finished_at < request.capture.started_at ||
    request.expected_mcp_server == "" ||
    request.allowed_tools.length() == 0 {
    return Err(codex_driver_error("process capture metadata is incomplete"))
  }
  for index, tool in request.allowed_tools {
    if !valid_codex_tool_name(tool) ||
      request.allowed_tools[:index].contains(tool) {
      return Err(codex_driver_error("allowed MCP tool set is invalid"))
    }
  }
  if request.session.lifecycle !=
    @control.HarnessSessionLifecycle::HarnessSessionAwaitingEvents {
    return Err(codex_driver_error("session is not awaiting provider events"))
  }
  match request.session.provider_cursor {
    Some(cursor) if cursor != "" && cursor.length() <= 512 => ()
    _ => return Err(codex_driver_error("provider cursor is unavailable"))
  }
  let expected_digest = codex_effective_surface_manifest_digest(
    request.allowed_tools,
    request.expected_mcp_server,
  )
  if request.session.effective_surface_manifest_digest != expected_digest {
    return Err(codex_driver_error("surface manifest digest changed"))
  }
  let (observed, response) = match
    codex_driver_trace(
      request.capture.output,
      request.expected_mcp_server,
      request.allowed_tools,
    ) {
    Ok(value) => value
    Err(error) =>
      return Err(
        @types.ChoirError::provider_protocol_violation(error.message()),
      )
  }
  let (outcome, terminal_response) = match
    validate_codex_response(request.role, response) {
    Ok(value) => value
    Err(error) =>
      return Err(
        @types.ChoirError::provider_protocol_violation(error.message()),
      )
  }
  let events : Array[@control.HarnessEventEnvelope] = []
  let mut session = request.session
  let mut sequence = 1L
  session = match
    append_codex_take_event(
      session,
      events,
      codex_take_event(
        session,
        sequence,
        request.capture.started_at,
        @control.HarnessEventKind::HarnessStarted,
      ),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  for event in observed {
    sequence = sequence + 1L
    let kind = match event {
      CodexToolStarted(id, _) =>
        @control.HarnessEventKind::HarnessToolStarted(id)
      CodexToolFinished(id, succeeded) =>
        @control.HarnessEventKind::HarnessToolFinished(
          id,
          if succeeded {
            @control.HarnessToolDisposition::HarnessToolSucceeded
          } else {
            @control.HarnessToolDisposition::HarnessToolFailed
          },
        )
    }
    session = match
      append_codex_take_event(
        session,
        events,
        codex_take_event(session, sequence, request.capture.finished_at, kind),
      ) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
  }
  sequence = sequence + 1L
  session = match
    append_codex_take_event(
      session,
      events,
      codex_take_event(
        session,
        sequence,
        request.capture.finished_at,
        @control.HarnessEventKind::HarnessTerminal(
          @control.HarnessTerminalObservation::HarnessCompleted,
        ),
      ),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  session = match @control.close_harness_ingestion(session) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    session,
    events,
    effective_surface_manifest_digest: expected_digest,
    terminal_response,
    outcome,
    started_at: request.capture.started_at,
    finished_at: request.capture.finished_at,
  })
}
