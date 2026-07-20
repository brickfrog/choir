///|
pub(all) struct BoxLiteDownstreamEvidence {
  clone_isolation : BoxLiteProbeCapture
  transfer_lifecycle : BoxLiteProbeCapture
  attach_signal_kill : BoxLiteProbeCapture
  restart_recovery : BoxLiteProbeCapture
  read_only_boundary : BoxLiteProbeCapture
  network_disabled : BoxLiteProbeCapture
  network_dns : BoxLiteProbeCapture
  network_tcp : BoxLiteProbeCapture
  network_udp : BoxLiteProbeCapture
  network_quic : BoxLiteProbeCapture
  network_host_aliases : BoxLiteProbeCapture
  network_choir_socket : BoxLiteProbeCapture
  network_runtime_socket : BoxLiteProbeCapture
} derive(Debug, Eq)

///|
pub fn boxlite_downstream_not_run_evidence() -> BoxLiteDownstreamEvidence {
  let not_run : BoxLiteProbeCapture = { exit_code: -3, output: "" }
  {
    clone_isolation: not_run,
    transfer_lifecycle: not_run,
    attach_signal_kill: not_run,
    restart_recovery: not_run,
    read_only_boundary: not_run,
    network_disabled: not_run,
    network_dns: not_run,
    network_tcp: not_run,
    network_udp: not_run,
    network_quic: not_run,
    network_host_aliases: not_run,
    network_choir_socket: not_run,
    network_runtime_socket: not_run,
  }
}

///|
fn boxlite_downstream_cases(
  evidence : BoxLiteDownstreamEvidence,
) -> Array[(BoxLiteProbeCase, BoxLiteProbeCapture, String)] {
  [
    (BoxLiteCloneIsolation, evidence.clone_isolation, "CHOIR_BOXLITE_CLONE_OK"),
    (
      BoxLiteTransferLifecycle,
      evidence.transfer_lifecycle,
      "CHOIR_BOXLITE_TRANSFER_OK",
    ),
    (
      BoxLiteAttachSignalKill,
      evidence.attach_signal_kill,
      "CHOIR_BOXLITE_PROCESS_CONTROL_OK",
    ),
    (
      BoxLiteRestartRecovery,
      evidence.restart_recovery,
      "CHOIR_BOXLITE_RESTART_RECOVERY_OK",
    ),
    (
      BoxLiteReadOnlyBoundary,
      evidence.read_only_boundary,
      "CHOIR_BOXLITE_READ_ONLY_OK",
    ),
    (
      BoxLiteNetworkDisabled,
      evidence.network_disabled,
      "CHOIR_BOXLITE_NETWORK_DISABLED_OK",
    ),
    (BoxLiteNetworkDns, evidence.network_dns, "CHOIR_BOXLITE_DNS_DENIED"),
    (BoxLiteNetworkTcp, evidence.network_tcp, "CHOIR_BOXLITE_TCP_DENIED"),
    (BoxLiteNetworkUdp, evidence.network_udp, "CHOIR_BOXLITE_UDP_DENIED"),
    (BoxLiteNetworkQuic, evidence.network_quic, "CHOIR_BOXLITE_QUIC_DENIED"),
    (
      BoxLiteNetworkHostAliases,
      evidence.network_host_aliases,
      "CHOIR_BOXLITE_HOST_ALIASES_DENIED",
    ),
    (
      BoxLiteNetworkChoirSocket,
      evidence.network_choir_socket,
      "CHOIR_BOXLITE_CHOIR_SOCKET_DENIED",
    ),
    (
      BoxLiteNetworkRuntimeSocket,
      evidence.network_runtime_socket,
      "CHOIR_BOXLITE_RUNTIME_SOCKET_DENIED",
    ),
  ]
}

///|
fn evaluate_boxlite_downstream_evidence(
  evidence : BoxLiteDownstreamEvidence,
) -> (Array[BoxLiteProbeCaseReport], Array[BoxLiteBlockReason]) {
  let reports : Array[BoxLiteProbeCaseReport] = []
  let blockers : Array[BoxLiteBlockReason] = []
  for item in boxlite_downstream_cases(evidence) {
    let (case_id, capture, marker) = item
    if capture.exit_code == 0 && capture.output.contains(marker) {
      reports.push({
        case_id,
        status: BoxLiteCasePassed,
        observed_exit_code: Some(0),
      })
    } else if capture.exit_code == -3 {
      let reason = BoxLiteDownstreamProbeNotRun(case_id)
      blockers.push(reason)
      reports.push({
        case_id,
        status: BoxLiteCaseNotRun(reason),
        observed_exit_code: None,
      })
    } else {
      let reason = BoxLiteDownstreamProbeFailed(case_id, capture.exit_code)
      blockers.push(reason)
      reports.push({
        case_id,
        status: BoxLiteCaseFailed(reason),
        observed_exit_code: Some(capture.exit_code),
      })
    }
  }
  (reports, blockers)
}
