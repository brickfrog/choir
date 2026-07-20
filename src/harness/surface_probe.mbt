///|
pub(all) enum ProviderSurface {
  ClaudeCli
  CodexCli
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum HarnessProbeCommand {
  ProbeVersion
  ProbeMainHelp
  ProbeExecHelp
} derive(Debug, Eq)

///|
pub(all) struct HarnessProbeProcess {
  surface : ProviderSurface
  command : HarnessProbeCommand
} derive(Debug, Eq)

///|
pub(all) struct HarnessProbeCapture {
  exit_code : Int
  output : String
} derive(Debug, Eq)

///|
pub(all) struct SurfaceProbeEvidence {
  surface : ProviderSurface
  version : HarnessProbeCapture
  main_help : HarnessProbeCapture
  exec_help : HarnessProbeCapture?
} derive(Debug, Eq)

///|
pub(all) enum ProviderMaturity {
  ProviderStable
  ProviderBeta
  ProviderPreview
  ProviderExperimental
  ProviderUnderDevelopment
  ProviderDeprecated
  ProviderRemoved
  ProviderUnspecified
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum ChoirSurfaceSupport {
  SurfaceUnprobed
  SurfaceCandidate
  SurfaceSupported
  SurfaceBlockedByPolicy
  SurfaceBlockedByConformance
  SurfaceUnsupported
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum SurfaceProbeStatus {
  SurfaceProbeNotRun
  SurfaceProbePassed
  SurfaceProbeFailed
  SurfaceProbeBlocked
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum HarnessAuthenticationProfile {
  ProviderManagedSubscription
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum RedactedAuthenticationClass {
  AuthenticationProviderManagedSubscription
  AuthenticationNoLogin
  AuthenticationConflictingCredential
  AuthenticationUnknown
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum EntitlementLane {
  EntitlementSubscriptionIncluded
  EntitlementConflictingLane
  EntitlementUnknown
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum SurfaceCapability {
  CapabilityNonInteractive
  CapabilityJsonEventStream
  CapabilityEmptyBuiltInTools
  CapabilityEmptySettingSources
  CapabilityExactAllowedTools
  CapabilityStrictMcpConfiguration
  CapabilityEphemeralSession
  CapabilityIgnoreUserConfiguration
  CapabilityIgnoreRules
  CapabilityRestrictiveSandbox
  CapabilityNativeToolRemoval
  CapabilityRequiredSandboxToolFailClosed
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum CapabilityState {
  CapabilityAdvertised
  CapabilityMissing
  CapabilityUnproven
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct CapabilityProbeResult {
  capability : SurfaceCapability
  state : CapabilityState
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum SurfaceBlockReason {
  SurfaceExecutableFailed
  SurfaceVersionMismatch
  SurfaceHelpFailed
  SurfaceRequiredCapabilityMissing(SurfaceCapability)
  SurfaceNativeToolRemovalUnproven
  SurfaceSandboxToolFailureUnproven
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct SurfaceProbeReport {
  surface : ProviderSurface
  exact_version : String
  expected_version : String
  maturity : ProviderMaturity
  authentication_profile : HarnessAuthenticationProfile
  observed_authentication : RedactedAuthenticationClass
  observed_entitlement : EntitlementLane
  support : ChoirSurfaceSupport
  probe_status : SurfaceProbeStatus
  capabilities : Array[CapabilityProbeResult]
  blocking_reasons : Array[SurfaceBlockReason]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn expected_surface_version(surface : ProviderSurface) -> String {
  match surface {
    ClaudeCli => "2.1.215"
    CodexCli => "0.144.6"
  }
}

///|
pub let expected_claude_executable_sha256 : String = "c1efffaaf370aa187cb6a09dd93d4e511c646899b0078476f83791b664bde7fe"

///|
fn version_matches(surface : ProviderSurface, output : String) -> Bool {
  output.contains(expected_surface_version(surface))
}

///|
fn capability(
  name : SurfaceCapability,
  advertised : Bool,
) -> CapabilityProbeResult {
  {
    capability: name,
    state: if advertised {
      CapabilityAdvertised
    } else {
      CapabilityMissing
    },
  }
}

///|
fn advertised_or_block(
  results : Array[CapabilityProbeResult],
  reasons : Array[SurfaceBlockReason],
  name : SurfaceCapability,
  present : Bool,
) -> Unit {
  results.push(capability(name, present))
  if !present {
    reasons.push(SurfaceRequiredCapabilityMissing(name))
  }
}

///|
fn claude_capabilities(
  help : String,
  reasons : Array[SurfaceBlockReason],
) -> Array[CapabilityProbeResult] {
  let results : Array[CapabilityProbeResult] = []
  advertised_or_block(
    results,
    reasons,
    CapabilityNonInteractive,
    help.contains("--print"),
  )
  advertised_or_block(
    results,
    reasons,
    CapabilityJsonEventStream,
    help.contains("stream-json"),
  )
  advertised_or_block(
    results,
    reasons,
    CapabilityEmptyBuiltInTools,
    help.contains("--tools"),
  )
  advertised_or_block(
    results,
    reasons,
    CapabilityEmptySettingSources,
    help.contains("--setting-sources"),
  )
  advertised_or_block(
    results,
    reasons,
    CapabilityExactAllowedTools,
    help.contains("--allowedTools"),
  )
  advertised_or_block(
    results,
    reasons,
    CapabilityStrictMcpConfiguration,
    help.contains("--strict-mcp-config"),
  )
  results.push({
    capability: CapabilityRequiredSandboxToolFailClosed,
    state: CapabilityUnproven,
  })
  results
}

///|
fn codex_capabilities(
  main_help : String,
  exec_help : String,
  reasons : Array[SurfaceBlockReason],
) -> Array[CapabilityProbeResult] {
  let results : Array[CapabilityProbeResult] = []
  advertised_or_block(
    results,
    reasons,
    CapabilityNonInteractive,
    main_help.contains("exec"),
  )
  advertised_or_block(
    results,
    reasons,
    CapabilityJsonEventStream,
    exec_help.contains("--json"),
  )
  advertised_or_block(
    results,
    reasons,
    CapabilityEphemeralSession,
    exec_help.contains("--ephemeral"),
  )
  advertised_or_block(
    results,
    reasons,
    CapabilityIgnoreUserConfiguration,
    exec_help.contains("--ignore-user-config"),
  )
  advertised_or_block(
    results,
    reasons,
    CapabilityIgnoreRules,
    exec_help.contains("--ignore-rules"),
  )
  advertised_or_block(
    results,
    reasons,
    CapabilityRestrictiveSandbox,
    main_help.contains("--sandbox"),
  )
  results.push({
    capability: CapabilityNativeToolRemoval,
    state: CapabilityUnproven,
  })
  results.push({
    capability: CapabilityRequiredSandboxToolFailClosed,
    state: CapabilityUnproven,
  })
  reasons.push(SurfaceNativeToolRemovalUnproven)
  reasons.push(SurfaceSandboxToolFailureUnproven)
  results
}

///|
/// Evaluate only the local CLI declaration surface. This never reads provider
/// configuration and never claims authentication, entitlement, effective-tool
/// isolation, or startup conformance.
pub fn evaluate_surface_declaration(
  evidence : SurfaceProbeEvidence,
) -> SurfaceProbeReport {
  let reasons : Array[SurfaceBlockReason] = []
  if evidence.version.exit_code != 0 {
    reasons.push(SurfaceExecutableFailed)
  } else if !version_matches(evidence.surface, evidence.version.output) {
    reasons.push(SurfaceVersionMismatch)
  }
  if evidence.main_help.exit_code != 0 {
    reasons.push(SurfaceHelpFailed)
  }
  let capabilities = match evidence.surface {
    ClaudeCli => claude_capabilities(evidence.main_help.output, reasons)
    CodexCli => {
      let exec_help = match evidence.exec_help {
        Some(capture) => {
          if capture.exit_code != 0 {
            reasons.push(SurfaceHelpFailed)
          }
          capture.output
        }
        None => {
          reasons.push(SurfaceHelpFailed)
          ""
        }
      }
      codex_capabilities(evidence.main_help.output, exec_help, reasons)
    }
  }
  let blocked = reasons.length() > 0
  {
    surface: evidence.surface,
    exact_version: evidence.version.output.trim().to_owned(),
    expected_version: expected_surface_version(evidence.surface),
    maturity: ProviderUnspecified,
    authentication_profile: ProviderManagedSubscription,
    observed_authentication: AuthenticationUnknown,
    observed_entitlement: EntitlementUnknown,
    support: if blocked {
      SurfaceBlockedByConformance
    } else {
      SurfaceCandidate
    },
    probe_status: if blocked {
      SurfaceProbeFailed
    } else {
      SurfaceProbePassed
    },
    capabilities,
    blocking_reasons: reasons,
  }
}
