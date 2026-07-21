///|
pub(all) enum McpConnectionState {
  McpConnected
  McpPending
  McpFailed
  McpUnknown
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct McpServerObservation {
  name : String
  status : McpConnectionState
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct ClaudeInitializationManifest {
  client_version : String
  permission_mode : String
  api_key_source : String
  tools : Array[String]
  mcp_servers : Array[McpServerObservation]
  slash_commands : Array[String]
  skills : Array[String]
  plugins : Array[String]
  agents : Array[String]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum ClaudeStartupBlockReason {
  ClaudeStartupTimedOut
  ClaudeStartupMissingInitialization
  ClaudeStartupEventBeforeInitialization
  ClaudeStartupVersionMismatch
  ClaudeStartupPermissionModeMismatch
  ClaudeStartupUnexpectedCredentialSource
  ClaudeStartupNativeToolsVisible
  ClaudeStartupRequiredMcpToolMissing
  ClaudeStartupUnexpectedMcpServer
  ClaudeStartupRequiredMcpNotConnected
  ClaudeStartupSlashCommandsVisible
  ClaudeStartupSkillsVisible
  ClaudeStartupPluginsVisible
  ClaudeStartupAgentSurfaceDrift
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct ClaudeSyntheticStartupReport {
  manifest : ClaudeInitializationManifest?
  support : ChoirSurfaceSupport
  probe_status : SurfaceProbeStatus
  blocking_reasons : Array[ClaudeStartupBlockReason]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum ClaudeLiveBlockReason {
  ClaudeLiveSurfaceBlocked
  ClaudeLiveMissingEntitlementObservation
  ClaudeLiveConflictingEntitlement
  ClaudeLiveTerminalFailure
  ClaudeLiveUnexpectedResponse
  ClaudeLiveRequiredToolUseMismatch
  ClaudeLiveUnexpectedToolUse
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct ClaudeLiveStartupReport {
  manifest : ClaudeInitializationManifest?
  observed_authentication : RedactedAuthenticationClass
  observed_entitlement : EntitlementLane
  model_identity : String
  response_matched : Bool
  support : ChoirSurfaceSupport
  probe_status : SurfaceProbeStatus
  blocking_reasons : Array[ClaudeLiveBlockReason]
} derive(Debug, Eq, ToJson, FromJson)

///|
fn startup_json_string(fields : Map[String, Json], key : String) -> String {
  match fields.get(key) {
    Some(String(value)) => value
    _ => ""
  }
}

///|
fn startup_json_string_array(
  fields : Map[String, Json],
  key : String,
) -> Array[String] {
  let result : Array[String] = []
  match fields.get(key) {
    Some(Array(values)) =>
      for value in values {
        match value {
          String(text) => result.push(text)
          _ => ()
        }
      }
    _ => ()
  }
  result
}

///|
fn startup_mcp_servers(
  fields : Map[String, Json],
) -> Array[McpServerObservation] {
  let result : Array[McpServerObservation] = []
  match fields.get("mcp_servers") {
    Some(Array(values)) =>
      for value in values {
        match value {
          Object(server) =>
            result.push({
              name: startup_json_string(server, "name"),
              status: match startup_json_string(server, "status") {
                "connected" => McpConnected
                "pending" => McpPending
                "failed" => McpFailed
                _ => McpUnknown
              },
            })
          _ => ()
        }
      }
    _ => ()
  }
  result
}

///|
fn parse_claude_initialization(
  output : String,
) -> (ClaudeInitializationManifest?, Bool) {
  let mut saw_event_before_init = false
  for raw in output.split("\n") {
    let line = raw.trim().to_owned()
    if line == "" {
      continue
    }
    let json = @json.parse(line) catch { _ => continue }
    guard json is Object(fields) else { continue }
    let event_type = startup_json_string(fields, "type")
    let subtype = startup_json_string(fields, "subtype")
    if event_type == "system" && subtype == "init" {
      return (
        Some({
          client_version: startup_json_string(fields, "claude_code_version"),
          permission_mode: startup_json_string(fields, "permissionMode"),
          api_key_source: startup_json_string(fields, "apiKeySource"),
          tools: startup_json_string_array(fields, "tools"),
          mcp_servers: startup_mcp_servers(fields),
          slash_commands: startup_json_string_array(fields, "slash_commands"),
          skills: startup_json_string_array(fields, "skills"),
          plugins: startup_json_string_array(fields, "plugins"),
          agents: startup_json_string_array(fields, "agents"),
        }),
        saw_event_before_init,
      )
    }
    saw_event_before_init = true
  }
  (None, saw_event_before_init)
}

///|
fn startup_json_bool(fields : Map[String, Json], key : String) -> Bool? {
  match fields.get(key) {
    Some(True) => Some(true)
    Some(False) => Some(false)
    _ => None
  }
}

///|
fn claude_live_entitlement(output : String) -> EntitlementLane {
  for raw in output.split("\n") {
    let json = @json.parse(raw.trim().to_owned()) catch { _ => continue }
    guard json is Object(fields) else { continue }
    if startup_json_string(fields, "type") != "rate_limit_event" {
      continue
    }
    guard fields.get("rate_limit_info") is Some(Object(info)) else { continue }
    let status = startup_json_string(info, "status")
    let rate_limit_type = startup_json_string(info, "rateLimitType")
    let overage_status = startup_json_string(info, "overageStatus")
    let using_overage = startup_json_bool(info, "isUsingOverage")
    if status == "allowed" &&
      rate_limit_type != "" &&
      using_overage == Some(false) &&
      overage_status != "allowed" {
      return EntitlementSubscriptionIncluded
    }
    return EntitlementConflictingLane
  }
  EntitlementUnknown
}

///|
fn claude_live_terminal(output : String) -> (Bool, Bool, String, Int, Bool) {
  let mut succeeded = false
  let mut response_matched = false
  let mut model_identity = ""
  let mut required_tool_use_count = 0
  let mut unexpected_tool_use = false
  for raw in output.split("\n") {
    let json = @json.parse(raw.trim().to_owned()) catch { _ => continue }
    guard json is Object(fields) else { continue }
    match startup_json_string(fields, "type") {
      "assistant" =>
        match fields.get("message") {
          Some(Object(message)) => {
            model_identity = startup_json_string(message, "model")
            match message.get("content") {
              Some(Array(content)) =>
                for block in content {
                  match block {
                    Object(block_fields) =>
                      if startup_json_string(block_fields, "type") == "tool_use" {
                        if startup_json_string(block_fields, "name") ==
                          "mcp__choir_probe__probe" {
                          required_tool_use_count = required_tool_use_count + 1
                        } else {
                          unexpected_tool_use = true
                        }
                      }
                    _ => ()
                  }
                }
              _ => ()
            }
          }
          _ => ()
        }
      "result" => {
        succeeded = startup_json_bool(fields, "is_error") == Some(false) &&
          startup_json_string(fields, "subtype") == "success"
        response_matched = startup_json_string(fields, "result") == "PROBE_OK"
      }
      _ => ()
    }
  }
  (
    succeeded, response_matched, model_identity, required_tool_use_count, unexpected_tool_use,
  )
}

///|
fn claude_live_surface_blocked(
  reasons : Array[ClaudeStartupBlockReason],
  required_tool_use_count : Int,
) -> Bool {
  for reason in reasons {
    match reason {
      ClaudeStartupRequiredMcpToolMissing
      | ClaudeStartupRequiredMcpNotConnected if required_tool_use_count == 1 =>
        ()
      _ => return true
    }
  }
  false
}

///|
fn claude_builtin_agents_match(actual : Array[String]) -> Bool {
  let expected = [
    "claude", "Explore", "general-purpose", "Plan", "statusline-setup",
  ]
  actual == expected
}

///|
/// Evaluate a no-login synthetic-home startup. The report retains only
/// allowlisted initialization fields; later error/prose events are discarded.
pub fn evaluate_claude_synthetic_startup(
  capture : HarnessProbeCapture,
) -> ClaudeSyntheticStartupReport {
  let reasons : Array[ClaudeStartupBlockReason] = []
  if capture.exit_code == -2 {
    reasons.push(ClaudeStartupTimedOut)
  }
  let (manifest, early_event) = parse_claude_initialization(capture.output)
  if early_event {
    reasons.push(ClaudeStartupEventBeforeInitialization)
  }
  match manifest {
    None => reasons.push(ClaudeStartupMissingInitialization)
    Some(manifest) => {
      if manifest.client_version != expected_surface_version(ClaudeCli) {
        reasons.push(ClaudeStartupVersionMismatch)
      }
      if manifest.permission_mode != "dontAsk" {
        reasons.push(ClaudeStartupPermissionModeMismatch)
      }
      if manifest.api_key_source != "none" {
        reasons.push(ClaudeStartupUnexpectedCredentialSource)
      }
      if manifest.tools.any(fn(tool) { tool != "mcp__choir_probe__probe" }) {
        reasons.push(ClaudeStartupNativeToolsVisible)
      }
      if !manifest.tools.contains("mcp__choir_probe__probe") {
        reasons.push(ClaudeStartupRequiredMcpToolMissing)
      }
      if manifest.mcp_servers.length() != 1 ||
        manifest.mcp_servers[0].name != "choir_probe" {
        reasons.push(ClaudeStartupUnexpectedMcpServer)
      } else if manifest.mcp_servers[0].status != McpConnected {
        reasons.push(ClaudeStartupRequiredMcpNotConnected)
      }
      if manifest.slash_commands.length() != 0 {
        reasons.push(ClaudeStartupSlashCommandsVisible)
      }
      if manifest.skills.length() != 0 {
        reasons.push(ClaudeStartupSkillsVisible)
      }
      if manifest.plugins.length() != 0 {
        reasons.push(ClaudeStartupPluginsVisible)
      }
      if !claude_builtin_agents_match(manifest.agents) {
        reasons.push(ClaudeStartupAgentSurfaceDrift)
      }
    }
  }
  let passed = reasons.length() == 0
  {
    manifest,
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
/// Evaluate the official client's real provider-owned login without retaining
/// transcripts, account identity, session IDs, reset timestamps, or raw quota
/// details. This can keep a surface Candidate; it cannot make it Supported
/// without the remaining host-isolation oracle.
pub fn evaluate_claude_live_startup(
  capture : HarnessProbeCapture,
) -> ClaudeLiveStartupReport {
  let reasons : Array[ClaudeLiveBlockReason] = []
  let surface = evaluate_claude_synthetic_startup(capture)
  let entitlement = claude_live_entitlement(capture.output)
  match entitlement {
    EntitlementUnknown => reasons.push(ClaudeLiveMissingEntitlementObservation)
    EntitlementConflictingLane => reasons.push(ClaudeLiveConflictingEntitlement)
    EntitlementSubscriptionIncluded => ()
  }
  let (
    succeeded,
    response_matched,
    model_identity,
    required_tool_use_count,
    unexpected_tool_use,
  ) = claude_live_terminal(capture.output)
  if claude_live_surface_blocked(
      surface.blocking_reasons,
      required_tool_use_count,
    ) {
    reasons.push(ClaudeLiveSurfaceBlocked)
  }
  if !succeeded {
    reasons.push(ClaudeLiveTerminalFailure)
  }
  if !response_matched {
    reasons.push(ClaudeLiveUnexpectedResponse)
  }
  if required_tool_use_count != 1 {
    reasons.push(ClaudeLiveRequiredToolUseMismatch)
  }
  if unexpected_tool_use {
    reasons.push(ClaudeLiveUnexpectedToolUse)
  }
  let passed = reasons.length() == 0
  {
    manifest: surface.manifest,
    observed_authentication: if passed {
      AuthenticationProviderManagedSubscription
    } else {
      AuthenticationUnknown
    },
    observed_entitlement: entitlement,
    model_identity,
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
pub fn claude_live_startup_host_surface_matrix(
  report : ClaudeLiveStartupReport,
) -> Result[HostSurfaceMatrixReport, @types.ChoirError] {
  let digest = fn(label : String, value : Json) {
    @storage.artifact_digest(
      @utf8.encode(
        "choir.claude-host-surface-observation.v1\u{00}" +
        label +
        "\u{00}" +
        value.stringify(indent=0),
      ),
    )
  }
  let surface_exact = report.probe_status == SurfaceProbePassed &&
    report.blocking_reasons.length() == 0 &&
    report.manifest is Some(_)
  let surface_digest = digest(
    "SURFACE-001",
    [
      report.manifest.to_json(),
      report.probe_status.to_json(),
      report.blocking_reasons.to_json(),
    ].to_json(),
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
  evaluate_host_surface_matrix(ProviderSurface::ClaudeCli, [
    {
      probe: HostSurfaceProbe::HostSurfaceInitialization,
      outcome: if surface_exact {
        HostSurfaceProbeOutcome::HostSurfaceProbePassed(surface_digest)
      } else {
        HostSurfaceProbeOutcome::HostSurfaceProbeFailed(surface_digest)
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
  ])
}
