///|
fn capture(code : Int, output : String) -> @sandbox.BoxLiteProbeCapture {
  { exit_code: code, output }
}

///|
fn no_downstream() -> @sandbox.BoxLiteDownstreamEvidence {
  @sandbox.boxlite_downstream_not_run_evidence()
}

///|
fn runtime_bundle_hashes_capture() -> @sandbox.BoxLiteProbeCapture {
  capture(
    0,
    "ENTRIES\n" +
    "f boxlite-guest\n" +
    "f boxlite-shim\n" +
    "f bwrap\n" +
    "f debugfs\n" +
    "f libkrunfw.so.5\n" +
    "f mke2fs\n" +
    "HASHES\n" +
    "8d090705ae2fe424a5d2a501733029a9cadb58f158691957abecc823c638ae40  /runtime/boxlite-guest\n" +
    @sandbox.boxlite_runtime_shim_sha256 +
    "  /runtime/boxlite-shim\n" +
    "3312ccace553fd083a00f4706c5658880113ed79f3fc1ec7bb486ec0797a7523  /runtime/bwrap\n" +
    "cf3e94ba478311991c4dd461a983365529b612293ff82a76ed4b1c1d6adfaf89  /runtime/debugfs\n" +
    "c29492267947a7f40218a9a181fe5aa3e9bcb96efbd0e3fab3d1839f5a0a9eff  /runtime/libkrunfw.so.5\n" +
    "c3bedf42c320212abeb1c6325bd2663d7507a46d0ba06c2a76af1a9222c8ebb1  /runtime/mke2fs\n",
  )
}

///|
test "release report records secure seccomp failure without weakening policy" {
  let report = @sandbox.evaluate_boxlite_live_evidence({
    executable_hash: capture(
      0,
      @sandbox.boxlite_release_executable_sha256 + "  /tmp/boxlite\n",
    ),
    runtime_bundle_hashes: runtime_bundle_hashes_capture(),
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
    runtime_bundle_hashes: runtime_bundle_hashes_capture(),
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
    runtime_bundle_hashes: runtime_bundle_hashes_capture(),
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
test "runtime bundle drift blocks guest startup" {
  let report = @sandbox.evaluate_boxlite_live_evidence({
    executable_hash: capture(
      0,
      @sandbox.boxlite_release_executable_sha256 + "  /tmp/boxlite\n",
    ),
    runtime_bundle_hashes: capture(0, "wrong  /runtime/boxlite-shim\n"),
    version: capture(0, "boxlite 0.9.7\n"),
    info: capture(0, "virtualization: available\n"),
    image_pull: capture(0, "pulled\n"),
    secure_boot: capture(0, "CHOIR_BOXLITE_SECURE_OK\n"),
    insecure_boot_diagnostic: capture(0, "CHOIR_BOXLITE_INSECURE_CONTROL_OK\n"),
    downstream: no_downstream(),
  })
  assert_true(
    report.blocking_reasons.contains(
      @sandbox.BoxLiteBlockReason::BoxLiteRuntimeBundleHashMismatch,
    ),
  )
  assert_eq(report.runtime_bundle_digest, "")
  let valid = runtime_bundle_hashes_capture()
  assert_false(
    @sandbox.boxlite_runtime_bundle_matches({
      exit_code: 0,
      output: valid.output.replace(
        old="HASHES\n",
        new="f undeclared-runtime-file\nHASHES\n",
      ),
    }),
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
    runtime_bundle_hashes: runtime_bundle_hashes_capture(),
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
    runtime_bundle_hashes: runtime_bundle_hashes_capture(),
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
