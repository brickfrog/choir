///|
pub(all) enum ClaudeTakeRole {
  ClaudeImplementationTake
  ClaudeVerificationTake
  ClaudeAuditTake
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct ClaudeDriverCapture {
  exit_code : Int
  output : String
  started_at : Int64
  finished_at : Int64
} derive(Debug, Eq)

///|
pub(all) struct ClaudeDriverEvaluationRequest {
  session : @control.HarnessSession
  role : ClaudeTakeRole
  allowed_tools : Array[String]
  expected_mcp_server : String
  capture : ClaudeDriverCapture
} derive(Debug, Eq)

///|
pub(all) struct ClaudeDriverResult {
  session : @control.HarnessSession
  events : Array[@control.HarnessEventEnvelope]
  effective_surface_manifest_digest : @control.Digest
  model_identity : String
  terminal_response : String
  outcome : ClaudeTakeOutcome
  started_at : Int64
  finished_at : Int64
} derive(Debug, Eq)

///|
pub(all) enum ClaudeTakeOutcome {
  ClaudeImplementationCompleted
  ClaudeVerificationPassed
  ClaudeVerificationFailed
  ClaudeAuditPassed
  ClaudeAuditFindings(Int, Int)
} derive(Debug, Eq, ToJson, FromJson)

///|
priv enum ClaudeObservedToolEvent {
  ClaudeToolStarted(String, String)
  ClaudeToolFinished(String)
}

///|
fn claude_driver_error(message : String) -> @types.ChoirError {
  @types.ChoirError::validation_error("Claude driver: " + message)
}

///|
fn valid_declared_tool_name(tool : String) -> Bool {
  if tool == "StructuredOutput" {
    return true
  }
  if !tool.has_prefix("mcp__") || tool.length() > 180 {
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
fn exact_tool_set(actual : Array[String], expected : Array[String]) -> Bool {
  if actual.length() != expected.length() {
    return false
  }
  for index, tool in expected {
    if !valid_declared_tool_name(tool) ||
      expected[:index].contains(tool) ||
      !actual.contains(tool) {
      return false
    }
  }
  true
}

///|
fn exact_mcp_server(
  actual : Array[McpServerObservation],
  expected : String,
) -> Bool {
  actual.length() == 1 &&
  actual[0].name == expected &&
  actual[0].status == McpConnected
}

///|
pub fn claude_effective_surface_manifest_digest(
  manifest : ClaudeInitializationManifest,
) -> @control.Digest {
  let tools = manifest.tools.copy()
  let mcp_servers = manifest.mcp_servers.copy()
  let slash_commands = manifest.slash_commands.copy()
  let skills = manifest.skills.copy()
  let plugins = manifest.plugins.copy()
  let agents = manifest.agents.copy()
  tools.sort()
  mcp_servers.sort_by(fn(left, right) { left.name.compare(right.name) })
  slash_commands.sort()
  skills.sort()
  plugins.sort()
  agents.sort()
  let canonical : ClaudeInitializationManifest = {
    ..manifest,
    tools,
    mcp_servers,
    slash_commands,
    skills,
    plugins,
    agents,
  }
  @storage.artifact_digest(
    @utf8.encode(
      "choir.claude-effective-surface.v1\u{00}" +
      canonical.to_json().stringify(indent=0),
    ),
  )
}

///|
pub fn expected_claude_take_surface_manifest_digest(
  allowed_tools : Array[String],
  mcp_server_name : String,
) -> @control.Digest {
  let tools = allowed_tools.copy()
  tools.push("StructuredOutput")
  claude_effective_surface_manifest_digest({
    client_version: expected_surface_version(ClaudeCli),
    permission_mode: "dontAsk",
    api_key_source: "none",
    tools,
    mcp_servers: [{ name: mcp_server_name, status: McpConnected }],
    slash_commands: [],
    skills: [],
    plugins: [],
    agents: ["claude", "Explore", "general-purpose", "Plan", "statusline-setup"],
  })
}

///|
fn claude_driver_trace(
  output : String,
) -> (Array[ClaudeObservedToolEvent], Bool, String, String) {
  let tool_events : Array[ClaudeObservedToolEvent] = []
  let mut succeeded = false
  let mut response = ""
  let mut model_identity = ""
  for raw in output.split("\n") {
    let json = @json.parse(raw.trim().to_owned()) catch { _ => continue }
    guard json is Object(fields) else { continue }
    match startup_json_string(fields, "type") {
      "assistant" =>
        match fields.get("message") {
          Some(Object(message)) => {
            let observed_model = startup_json_string(message, "model")
            if observed_model != "" {
              model_identity = observed_model
            }
            match message.get("content") {
              Some(Array(content)) =>
                for block in content {
                  guard block is Object(block_fields) else { continue }
                  if startup_json_string(block_fields, "type") == "tool_use" {
                    tool_events.push(
                      ClaudeToolStarted(
                        startup_json_string(block_fields, "id"),
                        startup_json_string(block_fields, "name"),
                      ),
                    )
                  }
                }
              _ => ()
            }
          }
          _ => ()
        }
      "user" =>
        match fields.get("message") {
          Some(Object(message)) =>
            match message.get("content") {
              Some(Array(content)) =>
                for block in content {
                  guard block is Object(block_fields) else { continue }
                  if startup_json_string(block_fields, "type") == "tool_result" {
                    tool_events.push(
                      ClaudeToolFinished(
                        startup_json_string(block_fields, "tool_use_id"),
                      ),
                    )
                  }
                }
              _ => ()
            }
          _ => ()
        }
      "result" => {
        succeeded = startup_json_bool(fields, "is_error") == Some(false) &&
          startup_json_string(fields, "subtype") == "success"
        response = startup_json_string(fields, "result")
      }
      _ => ()
    }
  }
  (tool_events, succeeded, response, model_identity)
}

///|
fn validate_claude_tool_trace(
  events : Array[ClaudeObservedToolEvent],
  allowed_tools : Array[String],
  required_sandbox_tools : Array[String],
) -> Result[Unit, @types.ChoirError] {
  let open : Map[String, String] = Map([])
  let mut starts = 0
  let mut sandbox_starts = 0
  for event in events {
    match event {
      ClaudeToolStarted(id, name) => {
        if id == "" || !allowed_tools.contains(name) || open.contains(id) {
          return Err(claude_driver_error("undeclared or duplicate tool use"))
        }
        open[id] = name
        starts = starts + 1
        if required_sandbox_tools.contains(name) {
          sandbox_starts = sandbox_starts + 1
        }
      }
      ClaudeToolFinished(id) =>
        if id == "" || !open.contains(id) {
          return Err(claude_driver_error("unmatched tool result"))
        } else {
          open.remove(id)
        }
    }
  }
  if starts == 0 || sandbox_starts == 0 || open.length() != 0 {
    return Err(claude_driver_error("tool trace is absent or unbalanced"))
  }
  Ok(())
}

///|
fn response_int(fields : Map[String, Json], key : String) -> Int? {
  match fields.get(key) {
    Some(Number(value, ..)) => Some(value.to_int())
    _ => None
  }
}

///|
fn validate_claude_take_response(
  role : ClaudeTakeRole,
  response : String,
) -> Result[ClaudeTakeOutcome, @types.ChoirError] {
  let json = @json.parse(response) catch {
    _ => return Err(claude_driver_error("terminal response is not JSON"))
  }
  guard json is Object(fields) else {
    return Err(claude_driver_error("terminal response is not an object"))
  }
  let outcome = startup_json_string(fields, "outcome")
  match role {
    ClaudeImplementationTake =>
      if outcome == "completed" {
        Ok(ClaudeImplementationCompleted)
      } else {
        Err(claude_driver_error("implementation outcome is invalid"))
      }
    ClaudeVerificationTake =>
      match outcome {
        "passed" => Ok(ClaudeVerificationPassed)
        "failed" => Ok(ClaudeVerificationFailed)
        _ => Err(claude_driver_error("verification outcome is invalid"))
      }
    ClaudeAuditTake => {
      let total = response_int(fields, "total_findings")
      let blocking = response_int(fields, "blocking_findings")
      match (outcome, total, blocking) {
        ("passed", Some(0), Some(0)) => Ok(ClaudeAuditPassed)
        ("findings", Some(total), Some(blocking)) if total > 0 &&
          blocking >= 0 &&
          blocking <= total => Ok(ClaudeAuditFindings(total, blocking))
        _ => Err(claude_driver_error("audit outcome is invalid"))
      }
    }
  }
}

///|
fn event_digest(value : String) -> @control.Digest {
  @storage.artifact_digest(@utf8.encode("choir.harness-event.v1\u{00}" + value))
}

///|
fn claude_event(
  session : @control.HarnessSession,
  sequence : Int64,
  observed_at : Int64,
  kind : @control.HarnessEventKind,
  digest_value : String,
) -> @control.HarnessEventEnvelope {
  {
    id: @control.HarnessEventId(session.id.0 + ":event:" + sequence.to_string()),
    take_id: session.take_id,
    session_id: session.id,
    source_position: @control.EventSourcePosition::EventNonResumableOrdinal(
      session.id.0,
      sequence.to_int(),
    ),
    choir_sequence: @control.EventSequence(sequence),
    observed_at,
    kind,
    sanitized_payload_digest: event_digest(digest_value),
    redaction_state: @control.EventRedactionState::EventNotSensitive,
    late: false,
  }
}

///|
fn append_claude_event(
  session : @control.HarnessSession,
  events : Array[@control.HarnessEventEnvelope],
  event : @control.HarnessEventEnvelope,
) -> Result[@control.HarnessSession, @types.ChoirError] {
  let result = @control.ingest_harness_event(session, events, event)
  match result.disposition {
    @control.HarnessIngestionDisposition::HarnessEventAppended => {
      match result.event {
        Some(value) => events.push(value)
        None => return Err(claude_driver_error("event append was not durable"))
      }
      Ok(result.session)
    }
    _ => Err(claude_driver_error("event trace violated the harness protocol"))
  }
}

///|
pub fn start_claude_harness_session(
  session : @control.HarnessSession,
) -> Result[@control.HarnessSession, @types.ChoirError] {
  if session.surface != @control.ProviderSurfaceId::ClaudeSubscriptionCli ||
    session.lifecycle != @control.HarnessSessionLifecycle::HarnessSessionPlanned ||
    session.cursor_class !=
    @control.HarnessCursorClass::HarnessCursorNotResumable ||
    session.provider_cursor is Some(_) ||
    session.last_choir_sequence != @control.EventSequence(0L) ||
    session.open_tool_execution_ids.length() != 0 {
    Err(claude_driver_error("session start capability is invalid"))
  } else {
    Ok({
      ..session,
      lifecycle: @control.HarnessSessionLifecycle::HarnessSessionAwaitingEvents,
    })
  }
}

///|
pub fn evaluate_claude_driver_capture(
  request : ClaudeDriverEvaluationRequest,
) -> Result[ClaudeDriverResult, @types.ChoirError] {
  if request.capture.exit_code != 0 ||
    request.capture.started_at <= 0L ||
    request.capture.finished_at < request.capture.started_at ||
    request.expected_mcp_server == "" {
    return Err(claude_driver_error("process capture is incomplete"))
  }
  if request.session.lifecycle !=
    @control.HarnessSessionLifecycle::HarnessSessionAwaitingEvents {
    return Err(claude_driver_error("session is not awaiting provider events"))
  }
  let (manifest, early_event) = parse_claude_initialization(
    request.capture.output,
  )
  let manifest = match manifest {
    Some(value) if !early_event => value
    _ => return Err(claude_driver_error("initialization manifest is invalid"))
  }
  let visible_tools = request.allowed_tools.copy()
  visible_tools.push("StructuredOutput")
  if manifest.client_version != expected_surface_version(ClaudeCli) ||
    manifest.permission_mode != "dontAsk" ||
    manifest.api_key_source != "none" ||
    !exact_tool_set(manifest.tools, visible_tools) ||
    !exact_mcp_server(manifest.mcp_servers, request.expected_mcp_server) ||
    manifest.slash_commands.length() != 0 ||
    manifest.skills.length() != 0 ||
    manifest.plugins.length() != 0 ||
    !claude_builtin_agents_match(manifest.agents) {
    return Err(claude_driver_error("effective surface is not admitted"))
  }
  if claude_live_entitlement(request.capture.output) !=
    EntitlementSubscriptionIncluded {
    return Err(claude_driver_error("subscription entitlement is not admitted"))
  }
  let (tool_trace, succeeded, response, model_identity) = claude_driver_trace(
    request.capture.output,
  )
  if !succeeded || response == "" || model_identity == "" {
    return Err(claude_driver_error("provider terminal result is invalid"))
  }
  match
    validate_claude_tool_trace(tool_trace, visible_tools, request.allowed_tools) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let outcome = match validate_claude_take_response(request.role, response) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let events : Array[@control.HarnessEventEnvelope] = []
  let mut session = request.session
  let mut sequence = 1L
  session = match
    append_claude_event(
      session,
      events,
      claude_event(
        session,
        sequence,
        request.capture.started_at,
        @control.HarnessEventKind::HarnessStarted,
        "started:" + request.role.to_json().stringify(indent=0),
      ),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  for observed in tool_trace {
    sequence = sequence + 1L
    let (kind, digest_value) = match observed {
      ClaudeToolStarted(id, name) =>
        (
          @control.HarnessEventKind::HarnessToolStarted(id),
          "tool-started:" + id + ":" + name,
        )
      ClaudeToolFinished(id) =>
        (
          @control.HarnessEventKind::HarnessToolFinished(id),
          "tool-finished:" + id,
        )
    }
    session = match
      append_claude_event(
        session,
        events,
        claude_event(
          session,
          sequence,
          request.capture.finished_at,
          kind,
          digest_value,
        ),
      ) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
  }
  sequence = sequence + 1L
  session = match
    append_claude_event(
      session,
      events,
      claude_event(
        session,
        sequence,
        request.capture.finished_at,
        @control.HarnessEventKind::HarnessTerminal(
          @control.HarnessTerminalObservation::HarnessCompleted,
        ),
        "terminal:completed",
      ),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  session = match @control.close_harness_ingestion(session) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let digest = claude_effective_surface_manifest_digest(manifest)
  if request.session.effective_surface_manifest_digest != digest {
    return Err(claude_driver_error("surface manifest digest changed"))
  }
  Ok({
    session,
    events,
    effective_surface_manifest_digest: digest,
    model_identity,
    terminal_response: response,
    outcome,
    started_at: request.capture.started_at,
    finished_at: request.capture.finished_at,
  })
}
