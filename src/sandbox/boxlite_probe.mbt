///|
pub let boxlite_release_tag : String = "v0.9.7"

///|
pub let boxlite_release_sha : String = "8803834036205cf2cac5cfca98bb3875812c897a"

///|
pub let boxlite_release_archive_sha256 : String = "c80eef9dae1e3443a6817095a5c9e38b90b5bb84a50fb87a732e067f867b5e7e"

///|
pub let boxlite_release_executable_sha256 : String = "81354f87e715113fb47303eb37663514af8ce4f350077a60b4e9ff7b093f0549"

///|
pub let boxlite_seccomp_patch_sha256 : String = "f5b6c5dfab0200d73e5bba9f7c44dd27c1acc8f3cbf9a059b80faf68a05e4c13"

///|
pub let boxlite_runtime_shim_sha256 : String = "29ceaa8e4530ae71408828a1e9067933c38d49f34b70b6efe2e82e6827a6ae70"

///|
pub let boxlite_runtime_bundle_digest : String = "66364c9b629315a2f3c0f5ab341fa16e21d41b43873866125a110051e8c142cc"

///|
pub fn boxlite_runtime_bundle_files() -> Array[String] {
  [
    "boxlite-guest", "boxlite-shim", "bwrap", "debugfs", "libkrunfw.so.5", "mke2fs",
  ]
}

///|
fn boxlite_runtime_bundle_entries() -> Array[(String, String)] {
  [
    (
      "boxlite-guest", "8d090705ae2fe424a5d2a501733029a9cadb58f158691957abecc823c638ae40",
    ),
    ("boxlite-shim", boxlite_runtime_shim_sha256),
    (
      "bwrap", "3312ccace553fd083a00f4706c5658880113ed79f3fc1ec7bb486ec0797a7523",
    ),
    (
      "debugfs", "cf3e94ba478311991c4dd461a983365529b612293ff82a76ed4b1c1d6adfaf89",
    ),
    (
      "libkrunfw.so.5", "c29492267947a7f40218a9a181fe5aa3e9bcb96efbd0e3fab3d1839f5a0a9eff",
    ),
    (
      "mke2fs", "c3bedf42c320212abeb1c6325bd2663d7507a46d0ba06c2a76af1a9222c8ebb1",
    ),
  ]
}

///|
/// OCI platform-manifest digest, not the image-config digest printed by `pull --quiet`.
pub let boxlite_probe_image : String = "alpine@sha256:7c8cb692ae09657cbc4a3f3cbd0e8d5a2690ba38386aaaf252dbb060bf5eb2e6"

///|
pub let boxlite_probe_image_digest : String = "sha256:7c8cb692ae09657cbc4a3f3cbd0e8d5a2690ba38386aaaf252dbb060bf5eb2e6"

///|
pub let boxlite_policy_id : String = "boxlite-v0.9.7-seccomp-time-kvm-network-disabled-v1"

///|
/// SHA-256 of the checked-in canonical policy tuple documented by the adapter.
pub let boxlite_policy_digest : String = "c01dfb40d7588eff477bd0723939e237e8da03183894c368ed1e6d8f50cdfc86"

///|
pub(all) enum BoxLiteProbeOperation {
  BoxLiteHashExecutable
  BoxLiteVersion
  BoxLiteInfo
  BoxLitePullPinnedImage
  BoxLiteSecureBoot
  BoxLiteInsecureBootDiagnostic
} derive(Debug, Eq)

///|
pub(all) struct BoxLiteProbeCapture {
  exit_code : Int
  output : String
} derive(Debug, Eq)

///|
pub(all) struct BoxLiteLiveEvidence {
  executable_hash : BoxLiteProbeCapture
  runtime_bundle_hashes : BoxLiteProbeCapture
  version : BoxLiteProbeCapture
  info : BoxLiteProbeCapture
  image_pull : BoxLiteProbeCapture
  secure_boot : BoxLiteProbeCapture
  insecure_boot_diagnostic : BoxLiteProbeCapture
  downstream : BoxLiteDownstreamEvidence
} derive(Debug, Eq)

///|
pub(all) enum BoxLiteProbeCase {
  BoxLiteRuntimeIdentity
  BoxLiteKvmAvailability
  BoxLitePinnedImagePreparation
  BoxLiteSecureGuestBoot
  BoxLiteInsecureDiagnosticControl
  BoxLiteCloneIsolation
  BoxLiteTransferLifecycle
  BoxLiteAttachSignalKill
  BoxLiteRestartRecovery
  BoxLiteReadOnlyBoundary
  BoxLiteNetworkDisabled
  BoxLiteNetworkDns
  BoxLiteNetworkTcp
  BoxLiteNetworkUdp
  BoxLiteNetworkQuic
  BoxLiteNetworkHostAliases
  BoxLiteNetworkChoirSocket
  BoxLiteNetworkRuntimeSocket
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum BoxLiteBlockReason {
  BoxLiteExecutableHashMismatch
  BoxLiteRuntimeBundleOverrideMissing
  BoxLiteRuntimeBundleHashMismatch
  BoxLiteVersionMismatch
  BoxLiteKvmUnavailable
  BoxLiteImagePreparationFailed
  BoxLiteSecureBootTimedOut
  BoxLiteSecureBootSeccompKilled
  BoxLiteSecureBootFailed(Int)
  BoxLiteInsecureDiagnosticFailed(Int)
  BoxLitePrerequisiteFailed
  BoxLiteDownstreamProbeNotRun(BoxLiteProbeCase)
  BoxLiteDownstreamProbeFailed(BoxLiteProbeCase, Int)
  BoxLiteNotRunAfterSecureBootFailure
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum BoxLiteProbeCaseStatus {
  BoxLiteCasePassed
  BoxLiteCaseFailed(BoxLiteBlockReason)
  BoxLiteCaseDiagnosticPassed
  BoxLiteCaseDiagnosticFailed(BoxLiteBlockReason)
  BoxLiteCaseNotRun(BoxLiteBlockReason)
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct BoxLiteProbeCaseReport {
  case_id : BoxLiteProbeCase
  status : BoxLiteProbeCaseStatus
  observed_exit_code : Int?
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum SandboxRuntimeSupport {
  SandboxRuntimeCandidate
  SandboxRuntimeSupported
  SandboxRuntimeBlockedByConformance
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum SandboxSecurityProfile {
  SandboxSecurityEnabled
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct BoxLiteConformanceReport {
  release_tag : String
  release_sha : String
  release_archive_sha256 : String
  executable_sha256 : String
  seccomp_patch_sha256 : String
  runtime_bundle_digest : String
  image_digest : String
  policy_id : String
  policy_digest : String
  security_profile : SandboxSecurityProfile
  network_profile : SandboxNetworkProfile
  support : SandboxRuntimeSupport
  cases : Array[BoxLiteProbeCaseReport]
  blocking_reasons : Array[BoxLiteBlockReason]
} derive(Debug, Eq, ToJson, FromJson)

///|
fn capture_passed(capture : BoxLiteProbeCapture) -> Bool {
  capture.exit_code == 0
}

///|
fn executable_hash(capture : BoxLiteProbeCapture) -> String {
  let output = capture.output.trim().to_owned()
  if output.length() < 64 {
    ""
  } else {
    output[:64].to_owned()
  }
}

///|
pub fn boxlite_runtime_bundle_matches(capture : BoxLiteProbeCapture) -> Bool {
  if !capture_passed(capture) {
    return false
  }
  let mut reading_entries = false
  let mut entry_count = 0
  let mut saw_hashes = false
  for line in capture.output.split("\n") {
    if line == "ENTRIES" {
      reading_entries = true
    } else if line == "HASHES" {
      reading_entries = false
      saw_hashes = true
    } else if reading_entries && line != "" {
      entry_count = entry_count + 1
      let mut declared = false
      for name in boxlite_runtime_bundle_files() {
        if line == "f " + name {
          declared = true
        }
      }
      if !declared {
        return false
      }
    }
  }
  if entry_count != boxlite_runtime_bundle_files().length() || !saw_hashes {
    return false
  }
  for entry in boxlite_runtime_bundle_entries() {
    let (name, expected_hash) = entry
    let mut matched = false
    let mut file_entry_matched = false
    for line in capture.output.split("\n") {
      if line == "f " + name {
        file_entry_matched = true
      }
      if line.length() >= 64 &&
        line[:64].to_owned() == expected_hash &&
        line.has_suffix("/" + name) {
        matched = true
      }
    }
    if !matched || !file_entry_matched {
      return false
    }
  }
  true
}

///|
fn not_run_after_secure_failure(
  case_id : BoxLiteProbeCase,
) -> BoxLiteProbeCaseReport {
  {
    case_id,
    status: BoxLiteCaseNotRun(BoxLiteNotRunAfterSecureBootFailure),
    observed_exit_code: None,
  }
}

///|
pub fn evaluate_boxlite_live_evidence(
  evidence : BoxLiteLiveEvidence,
) -> BoxLiteConformanceReport {
  let cases : Array[BoxLiteProbeCaseReport] = []
  let blockers : Array[BoxLiteBlockReason] = []
  let observed_hash = executable_hash(evidence.executable_hash)
  let runtime_bundle_ok = boxlite_runtime_bundle_matches(
    evidence.runtime_bundle_hashes,
  )
  let identity_ok = capture_passed(evidence.executable_hash) &&
    observed_hash == boxlite_release_executable_sha256 &&
    runtime_bundle_ok &&
    capture_passed(evidence.version) &&
    evidence.version.output.trim().to_owned() == "boxlite 0.9.7"
  if identity_ok {
    cases.push({
      case_id: BoxLiteRuntimeIdentity,
      status: BoxLiteCasePassed,
      observed_exit_code: Some(0),
    })
  } else {
    let reason = if observed_hash != boxlite_release_executable_sha256 {
      BoxLiteExecutableHashMismatch
    } else if evidence.runtime_bundle_hashes.exit_code == -3 {
      BoxLiteRuntimeBundleOverrideMissing
    } else if !runtime_bundle_ok {
      BoxLiteRuntimeBundleHashMismatch
    } else {
      BoxLiteVersionMismatch
    }
    blockers.push(reason)
    cases.push({
      case_id: BoxLiteRuntimeIdentity,
      status: BoxLiteCaseFailed(reason),
      observed_exit_code: Some(evidence.version.exit_code),
    })
  }
  let kvm_ok = identity_ok &&
    capture_passed(evidence.info) &&
    evidence.info.output.contains("virtualization: available")
  if !identity_ok {
    cases.push({
      case_id: BoxLiteKvmAvailability,
      status: BoxLiteCaseNotRun(BoxLitePrerequisiteFailed),
      observed_exit_code: None,
    })
  } else if kvm_ok {
    cases.push({
      case_id: BoxLiteKvmAvailability,
      status: BoxLiteCasePassed,
      observed_exit_code: Some(0),
    })
  } else {
    blockers.push(BoxLiteKvmUnavailable)
    cases.push({
      case_id: BoxLiteKvmAvailability,
      status: BoxLiteCaseFailed(BoxLiteKvmUnavailable),
      observed_exit_code: Some(evidence.info.exit_code),
    })
  }
  let image_ok = identity_ok && capture_passed(evidence.image_pull)
  if !identity_ok || !kvm_ok {
    cases.push({
      case_id: BoxLitePinnedImagePreparation,
      status: BoxLiteCaseNotRun(BoxLitePrerequisiteFailed),
      observed_exit_code: None,
    })
  } else if image_ok {
    cases.push({
      case_id: BoxLitePinnedImagePreparation,
      status: BoxLiteCasePassed,
      observed_exit_code: Some(0),
    })
  } else {
    blockers.push(BoxLiteImagePreparationFailed)
    cases.push({
      case_id: BoxLitePinnedImagePreparation,
      status: BoxLiteCaseFailed(BoxLiteImagePreparationFailed),
      observed_exit_code: Some(evidence.image_pull.exit_code),
    })
  }
  let prerequisites_ok = identity_ok && kvm_ok && image_ok
  let secure_ok = prerequisites_ok &&
    capture_passed(evidence.secure_boot) &&
    evidence.secure_boot.output.contains("CHOIR_BOXLITE_SECURE_OK")
  if !prerequisites_ok {
    cases.push({
      case_id: BoxLiteSecureGuestBoot,
      status: BoxLiteCaseNotRun(BoxLitePrerequisiteFailed),
      observed_exit_code: None,
    })
  } else if secure_ok {
    cases.push({
      case_id: BoxLiteSecureGuestBoot,
      status: BoxLiteCasePassed,
      observed_exit_code: Some(0),
    })
  } else {
    let reason = if evidence.secure_boot.exit_code == -2 {
      BoxLiteSecureBootTimedOut
    } else if evidence.secure_boot.exit_code == 159 ||
      evidence.secure_boot.output.contains("Exit code: 159") {
      BoxLiteSecureBootSeccompKilled
    } else {
      BoxLiteSecureBootFailed(evidence.secure_boot.exit_code)
    }
    blockers.push(reason)
    cases.push({
      case_id: BoxLiteSecureGuestBoot,
      status: BoxLiteCaseFailed(reason),
      observed_exit_code: Some(evidence.secure_boot.exit_code),
    })
  }
  if evidence.insecure_boot_diagnostic.exit_code == -3 {
    cases.push({
      case_id: BoxLiteInsecureDiagnosticControl,
      status: BoxLiteCaseNotRun(BoxLitePrerequisiteFailed),
      observed_exit_code: None,
    })
  } else if capture_passed(evidence.insecure_boot_diagnostic) &&
    evidence.insecure_boot_diagnostic.output.contains(
      "CHOIR_BOXLITE_INSECURE_CONTROL_OK",
    ) {
    cases.push({
      case_id: BoxLiteInsecureDiagnosticControl,
      status: BoxLiteCaseDiagnosticPassed,
      observed_exit_code: Some(0),
    })
  } else {
    cases.push({
      case_id: BoxLiteInsecureDiagnosticControl,
      status: BoxLiteCaseFailed(
        BoxLiteInsecureDiagnosticFailed(
          evidence.insecure_boot_diagnostic.exit_code,
        ),
      ),
      observed_exit_code: Some(evidence.insecure_boot_diagnostic.exit_code),
    })
  }
  if !secure_ok {
    for item in boxlite_downstream_cases(evidence.downstream) {
      let (case_id, capture, marker) = item
      if capture.exit_code == 0 && capture.output.contains(marker) {
        cases.push({
          case_id,
          status: BoxLiteCaseDiagnosticPassed,
          observed_exit_code: Some(0),
        })
      } else if capture.exit_code != -3 {
        let reason = BoxLiteDownstreamProbeFailed(case_id, capture.exit_code)
        cases.push({
          case_id,
          status: BoxLiteCaseDiagnosticFailed(reason),
          observed_exit_code: Some(capture.exit_code),
        })
      } else {
        cases.push(not_run_after_secure_failure(case_id))
      }
    }
  } else {
    let (downstream_reports, downstream_blockers) = evaluate_boxlite_downstream_evidence(
      evidence.downstream,
    )
    for report in downstream_reports {
      cases.push(report)
    }
    for blocker in downstream_blockers {
      blockers.push(blocker)
    }
  }
  let support = if secure_ok && blockers.length() == 0 {
    SandboxRuntimeSupported
  } else {
    SandboxRuntimeBlockedByConformance
  }
  {
    release_tag: boxlite_release_tag,
    release_sha: boxlite_release_sha,
    release_archive_sha256: boxlite_release_archive_sha256,
    executable_sha256: observed_hash,
    seccomp_patch_sha256: boxlite_seccomp_patch_sha256,
    runtime_bundle_digest: if runtime_bundle_ok {
      boxlite_runtime_bundle_digest
    } else {
      ""
    },
    image_digest: boxlite_probe_image_digest,
    policy_id: boxlite_policy_id,
    policy_digest: boxlite_policy_digest,
    security_profile: SandboxSecurityEnabled,
    network_profile: NetworkDisabled,
    support,
    cases,
    blocking_reasons: blockers,
  }
}
