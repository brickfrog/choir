///|
pub(all) enum ClaudeTakeRole {
  ClaudeImplementationTake
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
  ClaudeAuditPassed
  ClaudeAuditFindings(Int, Int)
} derive(Debug, Eq, ToJson, FromJson)

///|
priv enum ClaudeObservedToolEvent {
  ClaudeToolStarted(String, String)
  ClaudeToolFinished(String, Bool)
}

///|
fn claude_driver_error(message : String) -> @types.ChoirError {
  @types.ChoirError::validation_error("Claude driver: " + message)
}

///|
/// Attribute a rejected Claude trace to the provider run that produced it, so
/// a provider outage is distinguishable from a malformed trace in durable
/// state. See `codex_provider_violation` for the same reasoning.
fn claude_provider_violation(
  capture : ClaudeDriverCapture,
  error : @types.ChoirError,
) -> @types.ChoirError {
  @types.ChoirError::provider_protocol_violation(
    error.message() +
    " (claude exit " +
    capture.exit_code.to_string() +
    ", " +
    @utf8.encode(capture.output).length().to_string() +
    " output bytes)",
  )
}

///|
test "a rejected Claude trace names the provider run that produced it" {
  let detail = claude_provider_violation(
    { exit_code: 2, output: "x", started_at: 1L, finished_at: 2L },
    claude_driver_error("provider terminal result is invalid"),
  ).message()
  assert_true(detail.contains("provider terminal result is invalid"))
  assert_true(detail.contains("claude exit 2"))
  assert_true(detail.contains("1 output bytes"))
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
/// The admitted part of a Claude surface: the fields that decide what the
/// session may do, canonicalized for digesting.
///
/// The client version and the built-in agent roster deliberately do not
/// appear. Both change on an ordinary Claude Code release without changing
/// what the repository under audit can reach, and digesting them meant every
/// auto-update invalidated planned sessions and demanded a requalification
/// commit before any Take could run. What the repository can reach — the tool
/// set, the single MCP server, the permission mode, the credential source, and
/// the absence of project-supplied commands, skills, and plugins — is asserted
/// exactly.
struct ClaudeAdmittedSurface {
  permission_mode : String
  api_key_source : String
  tools : Array[String]
  mcp_servers : Array[McpServerObservation]
  slash_commands : Array[String]
  skills : Array[String]
  plugins : Array[String]
} derive(ToJson)

///|
pub fn claude_effective_surface_manifest_digest(
  manifest : ClaudeInitializationManifest,
) -> @control.Digest {
  let tools = manifest.tools.copy()
  let mcp_servers = manifest.mcp_servers.copy()
  let slash_commands = manifest.slash_commands.copy()
  let skills = manifest.skills.copy()
  let plugins = manifest.plugins.copy()
  tools.sort()
  mcp_servers.sort_by(fn(left, right) { left.name.compare(right.name) })
  slash_commands.sort()
  skills.sort()
  plugins.sort()
  let canonical : ClaudeAdmittedSurface = {
    permission_mode: manifest.permission_mode,
    api_key_source: manifest.api_key_source,
    tools,
    mcp_servers,
    slash_commands,
    skills,
    plugins,
  }
  @storage.artifact_digest(
    @utf8.encode(
      "choir.claude-effective-surface.v2\u{00}" +
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
    client_version: "",
    permission_mode: "dontAsk",
    api_key_source: "none",
    tools,
    mcp_servers: [{ name: mcp_server_name, status: McpConnected }],
    slash_commands: [],
    skills: [],
    plugins: [],
    agents: [],
  })
}

///|
test "an admitted Claude surface is independent of the client release" {
  let surface = fn(version, agents) {
    claude_effective_surface_manifest_digest({
      client_version: version,
      permission_mode: "dontAsk",
      api_key_source: "none",
      tools: ["mcp__choir_sandbox__execute", "StructuredOutput"],
      mcp_servers: [{ name: "choir_sandbox", status: McpConnected }],
      slash_commands: [],
      skills: [],
      plugins: [],
      agents,
    })
  }
  assert_eq(
    surface("2.1.219", ["claude", "Explore"]),
    surface("2.1.220", ["claude", "Explore", "a-new-builtin"]),
  )
  assert_not_eq(
    surface("2.1.219", []),
    claude_effective_surface_manifest_digest({
      client_version: "2.1.219",
      permission_mode: "dontAsk",
      api_key_source: "none",
      tools: ["mcp__choir_sandbox__execute", "StructuredOutput"],
      mcp_servers: [{ name: "choir_sandbox", status: McpConnected }],
      slash_commands: [],
      skills: ["a-project-skill"],
      plugins: [],
      agents: [],
    }),
  )
}

///|
fn claude_driver_trace(
  output : String,
) -> (Array[ClaudeObservedToolEvent], Bool, String, String, @control.TakeUsage?) {
  let tool_events : Array[ClaudeObservedToolEvent] = []
  let mut succeeded = false
  let mut response = ""
  let mut model_identity = ""
  let mut usage : @control.TakeUsage? = None
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
                        startup_json_bool(block_fields, "is_error") ==
                        Some(true),
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
        // What this Take spent against the user's paid subscription
        // allowance, exactly as the provider reported it.
        usage = claude_result_usage(fields)
      }
      _ => ()
    }
  }
  (tool_events, succeeded, response, model_identity, usage)
}

///|
/// A tool name safe to place in a diagnostic. Provider-supplied names are
/// untrusted text, so anything outside the declared-name charset collapses to
/// a fixed marker rather than being copied through.
fn diagnostic_tool_name(name : String) -> String {
  if valid_declared_tool_name(name) {
    name
  } else {
    "<invalid>"
  }
}

///|
test "a tool diagnostic never copies an undeclared name through" {
  assert_eq(
    diagnostic_tool_name("mcp__choir_sandbox__execute"),
    "mcp__choir_sandbox__execute",
  )
  assert_eq(diagnostic_tool_name("Bash; rm -rf /"), "<invalid>")
  assert_eq(diagnostic_tool_name(""), "<invalid>")
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
  let mut successful_sandbox_finishes = 0
  for event in events {
    match event {
      ClaudeToolStarted(id, name) => {
        // Name the exact rejection. One collapsed message made a 20-minute
        // Take unattributable: an undeclared tool, a replayed assistant
        // message, and a malformed block all read the same.
        if id == "" {
          return Err(claude_driver_error("tool use carries no identity"))
        }
        if open.contains(id) {
          return Err(
            claude_driver_error(
              "duplicate tool use id (tool=" + diagnostic_tool_name(name) + ")",
            ),
          )
        }
        if !allowed_tools.contains(name) {
          return Err(
            claude_driver_error(
              "undeclared tool use (tool=" + diagnostic_tool_name(name) + ")",
            ),
          )
        }
        open[id] = name
        starts = starts + 1
        if required_sandbox_tools.contains(name) {
          sandbox_starts = sandbox_starts + 1
        }
      }
      ClaudeToolFinished(id, is_error) =>
        if id == "" || !open.contains(id) {
          return Err(claude_driver_error("unmatched tool result"))
        } else {
          let tool = open[id]
          if !is_error && required_sandbox_tools.contains(tool) {
            successful_sandbox_finishes = successful_sandbox_finishes + 1
          }
          open.remove(id)
        }
    }
  }
  if starts == 0 || sandbox_starts == 0 || open.length() != 0 {
    return Err(claude_driver_error("tool trace is absent or unbalanced"))
  }
  if successful_sandbox_finishes == 0 {
    return Err(claude_driver_error("every declared MCP tool call failed"))
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
fn claude_audit_terminal_response(
  prefix : String,
  fields : Map[String, Json],
) -> String {
  let with_repairs = match fields.get("repair_findings") {
    Some(value) => prefix + ",\"repair_findings\":" + value.stringify(indent=0)
    None => prefix
  }
  match fields.get("migration_findings") {
    Some(value) =>
      with_repairs +
      ",\"migration_findings\":" +
      value.stringify(indent=0) +
      "}"
    None => with_repairs + "}"
  }
}

///|
fn validate_claude_take_response(
  role : ClaudeTakeRole,
  response : String,
) -> Result[(ClaudeTakeOutcome, String), @types.ChoirError] {
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
        Ok((ClaudeImplementationCompleted, "{\"outcome\":\"completed\"}"))
      } else {
        Err(claude_driver_error("implementation outcome is invalid"))
      }
    ClaudeAuditTake => {
      let total = response_int(fields, "total_findings")
      let blocking = response_int(fields, "blocking_findings")
      match (outcome, total, blocking) {
        ("passed", Some(0), Some(0)) =>
          Ok(
            (
              ClaudeAuditPassed,
              claude_audit_terminal_response(
                "{\"outcome\":\"passed\",\"total_findings\":0,\"blocking_findings\":0",
                fields,
              ),
            ),
          )
        ("findings", Some(total), Some(blocking)) if total > 0 &&
          blocking >= 0 &&
          blocking <= total =>
          Ok(
            (
              ClaudeAuditFindings(total, blocking),
              claude_audit_terminal_response(
                "{\"outcome\":\"findings\",\"total_findings\":" +
                total.to_string() +
                ",\"blocking_findings\":" +
                blocking.to_string(),
                fields,
              ),
            ),
          )
        _ => Err(claude_driver_error("audit outcome is invalid"))
      }
    }
  }
}

///|
test "Claude audit response retains repair and migration findings" {
  let response = "{\"outcome\":\"findings\",\"total_findings\":1,\"blocking_findings\":1,\"repair_findings\":[{\"affected_paths\":[\"src/example.mbt\"]}],\"migration_findings\":[{\"class\":\"RuleViolation\"}]}"
  let (_, retained) = validate_claude_take_response(
    ClaudeTakeRole::ClaudeAuditTake,
    response,
  ).unwrap()
  assert_true(retained.contains("\"repair_findings\""))
  assert_true(retained.contains("\"src/example.mbt\""))
  assert_true(retained.contains("\"migration_findings\""))
  assert_true(retained.contains("\"RuleViolation\""))
}

///|
pub fn safe_harness_event_digest(
  kind : @control.HarnessEventKind,
  redaction_state : @control.EventRedactionState,
) -> @control.Digest {
  @storage.artifact_digest(
    @utf8.encode(
      "choir.safe-harness-event.v1\u{00}" +
      kind.to_json().stringify(indent=0) +
      "\u{00}" +
      redaction_state.to_json().stringify(indent=0),
    ),
  )
}

///|
fn claude_event(
  session : @control.HarnessSession,
  sequence : Int64,
  observed_at : Int64,
  kind : @control.HarnessEventKind,
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
    sanitized_payload_digest: safe_harness_event_digest(
      kind,
      @control.EventRedactionState::EventNotSensitive,
    ),
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
  if manifest.permission_mode != "dontAsk" ||
    manifest.api_key_source != "none" ||
    !exact_tool_set(manifest.tools, visible_tools) ||
    !exact_mcp_server(manifest.mcp_servers, request.expected_mcp_server) ||
    manifest.slash_commands.length() != 0 ||
    manifest.skills.length() != 0 ||
    manifest.plugins.length() != 0 {
    return Err(claude_driver_error("effective surface is not admitted"))
  }
  if claude_live_entitlement(request.capture.output) !=
    EntitlementSubscriptionIncluded {
    return Err(claude_driver_error("subscription entitlement is not admitted"))
  }
  let (tool_trace, succeeded, response, model_identity, reported_usage) = claude_driver_trace(
    request.capture.output,
  )
  if !succeeded || response == "" || model_identity == "" {
    return Err(claude_driver_error("provider terminal result is invalid"))
  }
  match
    validate_claude_tool_trace(tool_trace, visible_tools, request.allowed_tools) {
    Ok(_) => ()
    Err(error) => return Err(claude_provider_violation(request.capture, error))
  }
  let (outcome, terminal_response) = match
    validate_claude_take_response(request.role, response) {
    Ok(value) => value
    Err(error) => return Err(claude_provider_violation(request.capture, error))
  }
  let events : Array[@control.HarnessEventEnvelope] = []
  let mut session = match reported_usage {
    Some(usage) if @control.validate_take_usage(usage) =>
      { ..request.session, usage: Some(usage) }
    _ => request.session
  }
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
      ),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  for observed in tool_trace {
    sequence = sequence + 1L
    let kind = match observed {
      ClaudeToolStarted(id, _) =>
        @control.HarnessEventKind::HarnessToolStarted(id)
      ClaudeToolFinished(id, is_error) =>
        @control.HarnessEventKind::HarnessToolFinished(
          id,
          if is_error {
            @control.HarnessToolDisposition::HarnessToolFailed
          } else {
            @control.HarnessToolDisposition::HarnessToolSucceeded
          },
        )
    }
    session = match
      append_claude_event(
        session,
        events,
        claude_event(session, sequence, request.capture.finished_at, kind),
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
    terminal_response,
    outcome,
    started_at: request.capture.started_at,
    finished_at: request.capture.finished_at,
  })
}
