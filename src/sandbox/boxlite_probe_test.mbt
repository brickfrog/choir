///|
fn capture(code : Int, output : String) -> @sandbox.BoxLiteProbeCapture {
  { exit_code: code, output }
}

///|
fn no_downstream() -> @sandbox.BoxLiteDownstreamEvidence {
  @sandbox.boxlite_downstream_not_run_evidence()
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
    downstream: no_downstream(),
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
test "downstream diagnostic failures remain visible after secure boot failure" {
  let downstream = no_downstream()
  let report = @sandbox.evaluate_boxlite_live_evidence({
    executable_hash: capture(
      0,
      @sandbox.boxlite_release_executable_sha256 + "  /tmp/boxlite\n",
    ),
    version: capture(0, "boxlite 0.9.7\n"),
    info: capture(0, "virtualization: available\n"),
    image_pull: capture(0, "pulled\n"),
    secure_boot: capture(159, "Exit code: 159\n"),
    insecure_boot_diagnostic: capture(0, "CHOIR_BOXLITE_INSECURE_CONTROL_OK\n"),
    downstream: {
      ..downstream,
      transfer_lifecycle: capture(73, "transfer failed"),
    },
  })
  assert_eq(
    report.cases[6].status,
    @sandbox.BoxLiteProbeCaseStatus::BoxLiteCaseDiagnosticFailed(
      @sandbox.BoxLiteBlockReason::BoxLiteDownstreamProbeFailed(
        @sandbox.BoxLiteProbeCase::BoxLiteTransferLifecycle,
        73,
      ),
    ),
  )
  assert_eq(report.blocking_reasons.length(), 1)
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
    downstream: no_downstream(),
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

///|
test "all downstream evidence admits the pinned runtime" {
  let passed = fn(marker : String) { capture(0, marker + "\n") }
  let report = @sandbox.evaluate_boxlite_live_evidence({
    executable_hash: capture(
      0,
      @sandbox.boxlite_release_executable_sha256 + "  /tmp/boxlite\n",
    ),
    version: capture(0, "boxlite 0.9.7\n"),
    info: capture(0, "virtualization: available\n"),
    image_pull: capture(0, "pulled\n"),
    secure_boot: capture(0, "CHOIR_BOXLITE_SECURE_OK\n"),
    insecure_boot_diagnostic: capture(0, "CHOIR_BOXLITE_INSECURE_CONTROL_OK\n"),
    downstream: {
      clone_isolation: passed("CHOIR_BOXLITE_CLONE_OK"),
      transfer_lifecycle: passed("CHOIR_BOXLITE_TRANSFER_OK"),
      attach_signal_kill: passed("CHOIR_BOXLITE_PROCESS_CONTROL_OK"),
      restart_recovery: passed("CHOIR_BOXLITE_RESTART_RECOVERY_OK"),
      read_only_boundary: passed("CHOIR_BOXLITE_READ_ONLY_OK"),
      network_disabled: passed("CHOIR_BOXLITE_NETWORK_DISABLED_OK"),
      network_dns: passed("CHOIR_BOXLITE_DNS_DENIED"),
      network_tcp: passed("CHOIR_BOXLITE_TCP_DENIED"),
      network_udp: passed("CHOIR_BOXLITE_UDP_DENIED"),
      network_quic: passed("CHOIR_BOXLITE_QUIC_DENIED"),
      network_host_aliases: passed("CHOIR_BOXLITE_HOST_ALIASES_DENIED"),
      network_choir_socket: passed("CHOIR_BOXLITE_CHOIR_SOCKET_DENIED"),
      network_runtime_socket: passed("CHOIR_BOXLITE_RUNTIME_SOCKET_DENIED"),
    },
  })
  assert_eq(
    report.support,
    @sandbox.SandboxRuntimeSupport::SandboxRuntimeSupported,
  )
  assert_eq(report.blocking_reasons.length(), 0)
  assert_eq(report.cases.length(), 18)
}

///|
test "one failed downstream case blocks otherwise passing evidence" {
  let passed = fn(marker : String) { capture(0, marker + "\n") }
  let report = @sandbox.evaluate_boxlite_live_evidence({
    executable_hash: capture(
      0,
      @sandbox.boxlite_release_executable_sha256 + "  /tmp/boxlite\n",
    ),
    version: capture(0, "boxlite 0.9.7\n"),
    info: capture(0, "virtualization: available\n"),
    image_pull: capture(0, "pulled\n"),
    secure_boot: capture(0, "CHOIR_BOXLITE_SECURE_OK\n"),
    insecure_boot_diagnostic: capture(0, "CHOIR_BOXLITE_INSECURE_CONTROL_OK\n"),
    downstream: {
      clone_isolation: capture(9, "clone leaked mutable state"),
      transfer_lifecycle: passed("CHOIR_BOXLITE_TRANSFER_OK"),
      attach_signal_kill: passed("CHOIR_BOXLITE_PROCESS_CONTROL_OK"),
      restart_recovery: passed("CHOIR_BOXLITE_RESTART_RECOVERY_OK"),
      read_only_boundary: passed("CHOIR_BOXLITE_READ_ONLY_OK"),
      network_disabled: passed("CHOIR_BOXLITE_NETWORK_DISABLED_OK"),
      network_dns: passed("CHOIR_BOXLITE_DNS_DENIED"),
      network_tcp: passed("CHOIR_BOXLITE_TCP_DENIED"),
      network_udp: passed("CHOIR_BOXLITE_UDP_DENIED"),
      network_quic: passed("CHOIR_BOXLITE_QUIC_DENIED"),
      network_host_aliases: passed("CHOIR_BOXLITE_HOST_ALIASES_DENIED"),
      network_choir_socket: passed("CHOIR_BOXLITE_CHOIR_SOCKET_DENIED"),
      network_runtime_socket: passed("CHOIR_BOXLITE_RUNTIME_SOCKET_DENIED"),
    },
  })
  assert_eq(
    report.support,
    @sandbox.SandboxRuntimeSupport::SandboxRuntimeBlockedByConformance,
  )
  assert_true(
    report.blocking_reasons.contains(
      @sandbox.BoxLiteBlockReason::BoxLiteDownstreamProbeFailed(
        @sandbox.BoxLiteProbeCase::BoxLiteCloneIsolation,
        9,
      ),
    ),
  )
}
