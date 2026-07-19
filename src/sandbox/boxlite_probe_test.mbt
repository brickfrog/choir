///|
fn capture(code : Int, output : String) -> @sandbox.BoxLiteProbeCapture {
  { exit_code: code, output }
}

///|
test "release report records secure seccomp failure without weakening policy" {
  let report = @sandbox.evaluate_boxlite_live_evidence({
    executable_hash: capture(
      0,
      @sandbox.boxlite_release_executable_sha256 + "  /tmp/boxlite\n",
    ),
    version: capture(0, "boxlite 0.9.7\n"),
    info: capture(0, "virtualization: available\n"),
    image_pull: capture(0, "pulled\n"),
    secure_boot: capture(1, "Exit code: 159 (unknown signal)\n"),
    insecure_boot_diagnostic: capture(0, "CHOIR_BOXLITE_INSECURE_CONTROL_OK\n"),
  })
  assert_eq(
    report.support,
    @sandbox.SandboxRuntimeSupport::SandboxRuntimeBlockedByConformance,
  )
  assert_true(
    report.blocking_reasons.contains(
      @sandbox.BoxLiteBlockReason::BoxLiteSecureBootSeccompKilled,
    ),
  )
  assert_eq(
    report.network_profile,
    @sandbox.SandboxNetworkProfile::NetworkDisabled,
  )
  let secure = report.cases[3]
  assert_eq(
    secure.status,
    @sandbox.BoxLiteProbeCaseStatus::BoxLiteCaseFailed(
      @sandbox.BoxLiteBlockReason::BoxLiteSecureBootSeccompKilled,
    ),
  )
  assert_eq(
    report.cases[5].status,
    @sandbox.BoxLiteProbeCaseStatus::BoxLiteCaseNotRun(
      @sandbox.BoxLiteBlockReason::BoxLiteNotRunAfterSecureBootFailure,
    ),
  )
}

///|
test "identity drift blocks the runtime before it can be admitted" {
  let report = @sandbox.evaluate_boxlite_live_evidence({
    executable_hash: capture(0, "wrong  /tmp/boxlite\n"),
    version: capture(0, "boxlite 0.9.7\n"),
    info: capture(0, "virtualization: available\n"),
    image_pull: capture(0, "pulled\n"),
    secure_boot: capture(0, "CHOIR_BOXLITE_SECURE_OK\n"),
    insecure_boot_diagnostic: capture(0, "CHOIR_BOXLITE_INSECURE_CONTROL_OK\n"),
  })
  assert_true(
    report.blocking_reasons.contains(
      @sandbox.BoxLiteBlockReason::BoxLiteExecutableHashMismatch,
    ),
  )
  assert_eq(
    report.support,
    @sandbox.SandboxRuntimeSupport::SandboxRuntimeBlockedByConformance,
  )
}
