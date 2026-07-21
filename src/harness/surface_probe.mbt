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
pub(all) enum HostSurfaceProbe {
  HostSurfaceInitialization
  HostSurfaceAmbientConfiguration
  HostSurfaceRequiredToolStartup
  HostSurfaceReadIsolation
  HostSurfaceWriteIsolation
  HostSurfacePathIdentity
  HostSurfaceCredentialIsolation
  HostSurfaceCapabilityDeath
  HostSurfaceChildIsolation
  HostSurfaceResumeAttestation
  HostSurfaceMutationBoundary
  HostSurfaceNetworkBoundary
  HostSurfaceSubscriptionIdentity
  HostSurfaceCancellation
  HostSurfaceToolSearch
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum HostSurfaceProbeOutcome {
  HostSurfaceProbePassed(@control.Digest)
  HostSurfaceProbeFailed(@control.Digest)
  HostSurfaceProbeNotRun
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct HostSurfaceProbeObservation {
  probe : HostSurfaceProbe
  outcome : HostSurfaceProbeOutcome
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum HostSurfaceMatrixDisposition {
  HostSurfaceMatrixComplete
  HostSurfaceMatrixIncomplete
  HostSurfaceMatrixFailed
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct HostSurfaceMatrixReport {
  surface : ProviderSurface
  observations : Array[HostSurfaceProbeObservation]
  passed : Int
  failed : Int
  not_run : Int
  disposition : HostSurfaceMatrixDisposition
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn required_host_surface_probes() -> Array[HostSurfaceProbe] {
  [
    HostSurfaceInitialization,
    HostSurfaceAmbientConfiguration,
    HostSurfaceRequiredToolStartup,
    HostSurfaceReadIsolation,
    HostSurfaceWriteIsolation,
    HostSurfacePathIdentity,
    HostSurfaceCredentialIsolation,
    HostSurfaceCapabilityDeath,
    HostSurfaceChildIsolation,
    HostSurfaceResumeAttestation,
    HostSurfaceMutationBoundary,
    HostSurfaceNetworkBoundary,
    HostSurfaceSubscriptionIdentity,
    HostSurfaceCancellation,
    HostSurfaceToolSearch,
  ]
}

///|
pub fn evaluate_host_surface_matrix(
  surface : ProviderSurface,
  supplied : Array[HostSurfaceProbeObservation],
) -> Result[HostSurfaceMatrixReport, @types.ChoirError] {
  let required = required_host_surface_probes()
  let seen : Array[HostSurfaceProbe] = []
  for observation in supplied {
    if !required.contains(observation.probe) {
      return Err(
        @types.ChoirError::validation_error("unknown host-surface probe"),
      )
    }
    if seen.contains(observation.probe) {
      return Err(
        @types.ChoirError::validation_error("duplicate host-surface probe"),
      )
    }
    seen.push(observation.probe)
    match observation.outcome {
      HostSurfaceProbePassed(digest) | HostSurfaceProbeFailed(digest) =>
        if @storage.validate_digest(digest) is Err(_) {
          return Err(
            @types.ChoirError::validation_error(
              "host-surface evidence digest is invalid",
            ),
          )
        }
      HostSurfaceProbeNotRun => ()
    }
  }
  let observations : Array[HostSurfaceProbeObservation] = []
  let mut passed = 0
  let mut failed = 0
  let mut not_run = 0
  for probe in required {
    let mut observation : HostSurfaceProbeObservation = {
      probe,
      outcome: HostSurfaceProbeNotRun,
    }
    for item in supplied {
      if item.probe == probe {
        observation = item
        break
      }
    }
    match observation.outcome {
      HostSurfaceProbePassed(_) => passed = passed + 1
      HostSurfaceProbeFailed(_) => failed = failed + 1
      HostSurfaceProbeNotRun => not_run = not_run + 1
    }
    observations.push(observation)
  }
  Ok({
    surface,
    observations,
    passed,
    failed,
    not_run,
    disposition: if failed > 0 {
      HostSurfaceMatrixFailed
    } else if not_run > 0 {
      HostSurfaceMatrixIncomplete
    } else {
      HostSurfaceMatrixComplete
    },
  })
}

///|
pub fn expected_surface_version(surface : ProviderSurface) -> String {
  match surface {
    ClaudeCli => "2.1.216"
    CodexCli => "0.144.6"
  }
}

///|
pub let expected_claude_executable_sha256 : String = "74deca45220b8080ec75ab099bd5a5980e41a2b5879846a008fb115d436de085"

///|
pub let expected_codex_executable_sha256 : String = "134063e133f0b4244fa3b251acf973d4fe4b4aeeacbdc135211bf480f59f1477"

///|
pub let expected_codex_native_executable_sha256 : String = "a31ae9450a26216eb1e7c53102fd42123dd675974310b0e2ca3aa4cb622a2c15"

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
