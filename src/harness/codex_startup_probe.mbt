///|
pub(all) struct CodexLiveProbeEvidence {
  login_status : HarnessProbeCapture
  admitted_run : HarnessProbeCapture
  required_mcp_failure : HarnessProbeCapture
  write_canary_present : Bool
} derive(Debug, Eq)

///|
pub(all) enum CodexLiveBlockReason {
  CodexLiveLoginStatusFailed
  CodexLiveAuthenticationMismatch
  CodexLiveRunFailed
  CodexLiveThreadLifecycleMismatch
  CodexLiveRequiredToolUseMismatch
  CodexLiveRequiredToolFailed
  CodexLiveUnexpectedEffectfulToolEvent
  CodexLiveWriteWasNotDenied
  CodexLiveReadWasNotDenied
  CodexLiveWriteCanaryPresent
  CodexLiveUnexpectedResponse
  CodexLiveRequiredMcpDidNotFailClosed
  CodexLiveMissingMcpReachedModelTurn
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct CodexLiveStartupReport {
  observed_authentication : RedactedAuthenticationClass
  observed_entitlement : EntitlementLane
  required_tool_use_count : Int
  native_write_denied : Bool
  native_read_denied : Bool
  required_mcp_failed_closed : Bool
  response_matched : Bool
  support : ChoirSurfaceSupport
  probe_status : SurfaceProbeStatus
  blocking_reasons : Array[CodexLiveBlockReason]
} derive(Debug, Eq, ToJson, FromJson)

///|
priv struct CodexLiveTrace {
  thread_started_count : Int
  turn_started_count : Int
  turn_completed_count : Int
  required_tool_started_count : Int
  required_tool_completed_count : Int
  required_tool_failed : Bool
  unexpected_effectful_tool_event : Bool
  terminal_response : String
}

///|
fn codex_json_string(fields : Map[String, Json], key : String) -> String {
  match fields.get(key) {
    Some(String(value)) => value
    _ => ""
  }
}

///|
fn codex_json_object(
  fields : Map[String, Json],
  key : String,
) -> Map[String, Json]? {
  match fields.get(key) {
    Some(Object(value)) => Some(value)
    _ => None
  }
}

///|
fn codex_unexpected_item(item_type : String) -> Bool {
  match item_type {
    "agent_message" | "reasoning" | "mcp_tool_call" => false
    _ => true
  }
}

///|
fn parse_codex_live_trace(output : String) -> CodexLiveTrace {
  let mut thread_started_count = 0
  let mut turn_started_count = 0
  let mut turn_completed_count = 0
  let mut required_tool_started_count = 0
  let mut required_tool_completed_count = 0
  let mut required_tool_failed = false
  let mut unexpected_effectful_tool_event = false
  let mut terminal_response = ""
  for raw in output.split("\n") {
    let json = @json.parse(raw.trim().to_owned()) catch { _ => continue }
    guard json is Object(fields) else { continue }
    let event_type = codex_json_string(fields, "type")
    match event_type {
      "thread.started" => thread_started_count = thread_started_count + 1
      "turn.started" => turn_started_count = turn_started_count + 1
      "turn.completed" => turn_completed_count = turn_completed_count + 1
      "item.started" | "item.completed" => {
        guard codex_json_object(fields, "item") is Some(item) else { continue }
        let item_type = codex_json_string(item, "type")
        if codex_unexpected_item(item_type) {
          unexpected_effectful_tool_event = true
        }
        if item_type == "mcp_tool_call" {
          let is_required = codex_json_string(item, "server") == "choir_probe" &&
            codex_json_string(item, "tool") == "probe"
          if !is_required {
            unexpected_effectful_tool_event = true
          } else if event_type == "item.started" {
            required_tool_started_count = required_tool_started_count + 1
          } else if codex_json_string(item, "status") == "completed" {
            required_tool_completed_count = required_tool_completed_count + 1
          } else {
            required_tool_failed = true
          }
        } else if item_type == "agent_message" && event_type == "item.completed" {
          terminal_response = codex_json_string(item, "text")
        }
      }
      _ => ()
    }
  }
  {
    thread_started_count,
    turn_started_count,
    turn_completed_count,
    required_tool_started_count,
    required_tool_completed_count,
    required_tool_failed,
    unexpected_effectful_tool_event,
    terminal_response,
  }
}

///|
fn codex_output_has_model_turn(output : String) -> Bool {
  for raw in output.split("\n") {
    let json = @json.parse(raw.trim().to_owned()) catch { _ => continue }
    guard json is Object(fields) else { continue }
    match codex_json_string(fields, "type") {
      "thread.started" | "turn.started" | "turn.completed" => return true
      _ => ()
    }
  }
  false
}

///|
pub fn evaluate_codex_live_startup(
  evidence : CodexLiveProbeEvidence,
) -> CodexLiveStartupReport {
  let reasons : Array[CodexLiveBlockReason] = []
  let login_succeeded = evidence.login_status.exit_code == 0
  let subscription_login = evidence.login_status.output.trim().to_owned() ==
    "Logged in using ChatGPT"
  if !login_succeeded {
    reasons.push(CodexLiveLoginStatusFailed)
  }
  if !subscription_login {
    reasons.push(CodexLiveAuthenticationMismatch)
  }
  let trace = parse_codex_live_trace(evidence.admitted_run.output)
  if evidence.admitted_run.exit_code != 0 {
    reasons.push(CodexLiveRunFailed)
  }
  if trace.thread_started_count != 1 ||
    trace.turn_started_count != 1 ||
    trace.turn_completed_count != 1 {
    reasons.push(CodexLiveThreadLifecycleMismatch)
  }
  if trace.required_tool_started_count != 1 ||
    trace.required_tool_completed_count != 1 {
    reasons.push(CodexLiveRequiredToolUseMismatch)
  }
  if trace.required_tool_failed {
    reasons.push(CodexLiveRequiredToolFailed)
  }
  if trace.unexpected_effectful_tool_event {
    reasons.push(CodexLiveUnexpectedEffectfulToolEvent)
  }
  let native_write_denied = evidence.admitted_run.output.contains(
    "writing is blocked by read-only sandbox",
  )
  if !native_write_denied {
    reasons.push(CodexLiveWriteWasNotDenied)
  }
  let native_read_denied = evidence.admitted_run.output.contains(
      "unable to locate image at",
    ) &&
    evidence.admitted_run.output.contains("No such file or directory")
  if !native_read_denied {
    reasons.push(CodexLiveReadWasNotDenied)
  }
  if evidence.write_canary_present {
    reasons.push(CodexLiveWriteCanaryPresent)
  }
  let response_matched = trace.terminal_response == "CHOIR_CODEX_PROBE_OK"
  if !response_matched {
    reasons.push(CodexLiveUnexpectedResponse)
  }
  let required_mcp_failed_closed = evidence.required_mcp_failure.exit_code != 0 &&
    evidence.required_mcp_failure.output.contains(
      "required MCP servers failed to initialize",
    )
  if !required_mcp_failed_closed {
    reasons.push(CodexLiveRequiredMcpDidNotFailClosed)
  }
  if codex_output_has_model_turn(evidence.required_mcp_failure.output) {
    reasons.push(CodexLiveMissingMcpReachedModelTurn)
  }
  let passed = reasons.length() == 0
  {
    observed_authentication: if subscription_login {
      AuthenticationProviderManagedSubscription
    } else {
      AuthenticationUnknown
    },
    observed_entitlement: if passed {
      EntitlementSubscriptionIncluded
    } else {
      EntitlementUnknown
    },
    required_tool_use_count: trace.required_tool_completed_count,
    native_write_denied,
    native_read_denied,
    required_mcp_failed_closed,
    response_matched,
    support: if passed {
      SurfaceCandidate
    } else {
      SurfaceBlockedByConformance
    },
    probe_status: if passed {
      SurfaceProbePassed
    } else {
      SurfaceProbeFailed
    },
    blocking_reasons: reasons,
  }
}

///|
pub fn codex_live_startup_host_surface_matrix(
  report : CodexLiveStartupReport,
) -> Result[HostSurfaceMatrixReport, @types.ChoirError] {
  let digest = fn(label : String, value : Json) {
    @storage.artifact_digest(
      @utf8.encode(
        "choir.codex-host-surface-observation.v1\u{00}" +
        label +
        "\u{00}" +
        value.stringify(indent=0),
      ),
    )
  }
  let startup_digest = digest(
    "STARTUP-003",
    report.required_mcp_failed_closed.to_json(),
  )
  let subscription_exact = report.observed_authentication ==
    AuthenticationProviderManagedSubscription &&
    report.observed_entitlement == EntitlementSubscriptionIncluded
  let subscription_digest = digest(
    "SUBSCRIPTION-013",
    [
      report.observed_authentication.to_json(),
      report.observed_entitlement.to_json(),
    ].to_json(),
  )
  evaluate_host_surface_matrix(
    ProviderSurface::CodexCli,
    [
      {
        probe: HostSurfaceProbe::HostSurfaceRequiredToolStartup,
        outcome: if report.required_mcp_failed_closed {
          HostSurfaceProbeOutcome::HostSurfaceProbePassed(startup_digest)
        } else {
          HostSurfaceProbeOutcome::HostSurfaceProbeFailed(startup_digest)
        },
      },
      {
        probe: HostSurfaceProbe::HostSurfaceSubscriptionIdentity,
        outcome: if subscription_exact {
          HostSurfaceProbeOutcome::HostSurfaceProbePassed(subscription_digest)
        } else {
          HostSurfaceProbeOutcome::HostSurfaceProbeFailed(subscription_digest)
        },
      },
    ],
  )
}
