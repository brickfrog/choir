///|
fn capture(output : String) -> @harness.HarnessProbeCapture {
  { exit_code: 0, output }
}

///|
test "Claude declaration remains Candidate with required isolation flags" {
  let report = @harness.evaluate_surface_declaration({
    surface: @harness.ProviderSurface::ClaudeCli,
    version: capture("2.1.220 (Claude Code)"),
    main_help: capture(
      "--print --output-format stream-json --tools --setting-sources " +
      "--allowedTools --strict-mcp-config",
    ),
    exec_help: None,
  })
  assert_eq(report.support, @harness.ChoirSurfaceSupport::SurfaceCandidate)
  assert_eq(
    report.probe_status,
    @harness.SurfaceProbeStatus::SurfaceProbePassed,
  )
  assert_eq(report.blocking_reasons.length(), 0)
}

///|
test "Claude declaration fails closed when a required flag disappears" {
  let report = @harness.evaluate_surface_declaration({
    surface: @harness.ProviderSurface::ClaudeCli,
    version: capture("2.1.220 (Claude Code)"),
    main_help: capture(
      "--print --output-format stream-json --tools --setting-sources --allowedTools",
    ),
    exec_help: None,
  })
  assert_eq(
    report.support,
    @harness.ChoirSurfaceSupport::SurfaceBlockedByConformance,
  )
  assert_true(
    report.blocking_reasons.contains(
      @harness.SurfaceBlockReason::SurfaceRequiredCapabilityMissing(
        @harness.SurfaceCapability::CapabilityStrictMcpConfiguration,
      ),
    ),
  )
}

///|
test "Codex declaration records native tool isolation as a typed blocker" {
  let report = @harness.evaluate_surface_declaration({
    surface: @harness.ProviderSurface::CodexCli,
    version: capture("codex-cli 0.146.0"),
    main_help: capture("exec --sandbox"),
    exec_help: Some(
      capture("--json --ephemeral --ignore-user-config --ignore-rules"),
    ),
  })
  assert_eq(
    report.support,
    @harness.ChoirSurfaceSupport::SurfaceBlockedByConformance,
  )
  assert_true(
    report.blocking_reasons.contains(
      @harness.SurfaceBlockReason::SurfaceNativeToolRemovalUnproven,
    ),
  )
  assert_true(
    report.blocking_reasons.contains(
      @harness.SurfaceBlockReason::SurfaceSandboxToolFailureUnproven,
    ),
  )
}

///|
test "surface declaration rejects version drift" {
  let report = @harness.evaluate_surface_declaration({
    surface: @harness.ProviderSurface::ClaudeCli,
    version: capture("2.1.999 (Claude Code)"),
    main_help: capture(
      "--print --output-format stream-json --tools --setting-sources " +
      "--allowedTools --strict-mcp-config",
    ),
    exec_help: None,
  })
  assert_true(
    report.blocking_reasons.contains(
      @harness.SurfaceBlockReason::SurfaceVersionMismatch,
    ),
  )
}

///|
fn surface_evidence(label : String) -> @control.Digest {
  @storage.artifact_digest(@utf8.encode(label))
}

///|
test "host surface matrix is ordered and incomplete until every probe passes" {
  let report = @harness.evaluate_host_surface_matrix(
    @harness.ProviderSurface::CodexCli,
    [
      {
        probe: @harness.HostSurfaceProbe::HostSurfaceSubscriptionIdentity,
        outcome: @harness.HostSurfaceProbeOutcome::HostSurfaceProbePassed(
          surface_evidence("subscription"),
        ),
      },
      {
        probe: @harness.HostSurfaceProbe::HostSurfaceRequiredToolStartup,
        outcome: @harness.HostSurfaceProbeOutcome::HostSurfaceProbePassed(
          surface_evidence("startup"),
        ),
      },
    ],
  ).unwrap()
  assert_eq(report.observations.length(), 15)
  assert_eq(report.passed, 2)
  assert_eq(report.failed, 0)
  assert_eq(report.not_run, 13)
  assert_eq(
    report.disposition,
    @harness.HostSurfaceMatrixDisposition::HostSurfaceMatrixIncomplete,
  )
  assert_eq(
    report.observations[0].probe,
    @harness.HostSurfaceProbe::HostSurfaceInitialization,
  )
}

///|
test "host surface matrix rejects duplicate evidence" {
  let observation : @harness.HostSurfaceProbeObservation = {
    probe: @harness.HostSurfaceProbe::HostSurfaceRequiredToolStartup,
    outcome: @harness.HostSurfaceProbeOutcome::HostSurfaceProbePassed(
      surface_evidence("startup"),
    ),
  }
  assert_true(
    @harness.evaluate_host_surface_matrix(@harness.ProviderSurface::CodexCli, [
      observation, observation,
    ])
    is Err(_),
  )
}

///|
test "host surface matrix completes only with all fifteen evidence rows" {
  let observations : Array[@harness.HostSurfaceProbeObservation] = @harness.required_host_surface_probes().map(fn(
      probe,
    ) {
      {
        probe,
        outcome: @harness.HostSurfaceProbeOutcome::HostSurfaceProbePassed(
          surface_evidence(probe.to_json().stringify(indent=0)),
        ),
      }
    },
  )
  let report = @harness.evaluate_host_surface_matrix(
    @harness.ProviderSurface::CodexCli,
    observations,
  ).unwrap()
  assert_eq(report.passed, 15)
  assert_eq(report.failed, 0)
  assert_eq(report.not_run, 0)
  assert_eq(
    report.disposition,
    @harness.HostSurfaceMatrixDisposition::HostSurfaceMatrixComplete,
  )
}

///|
/// Production wrote four spellings for the same provider into durable receipts
/// — codex-cli, codex-subscription-cli, codex-cli-0.146.0 — and hard-coded an
/// exact version that went stale the moment the CLI updated.
test "a receipt identity is one spelling per provider, carrying the pin" {
  let claude = @harness.provider_receipt_identity(
    @control.ProviderSurfaceId::ClaudeSubscriptionCli,
  )
  let codex = @harness.provider_receipt_identity(
    @control.ProviderSurfaceId::CodexSubscriptionCli,
  )
  assert_true(claude != codex)
  // The version is the one the surface probe qualifies against, so bumping the
  // pin moves the receipts with it and a hard-coded stale version cannot recur.
  assert_true(
    claude.has_suffix(
      @harness.expected_surface_version(@harness.ProviderSurface::ClaudeCli),
    ),
  )
  assert_true(
    codex.has_suffix(
      @harness.expected_surface_version(@harness.ProviderSurface::CodexCli),
    ),
  )
  // Stable across calls: a receipt written twice for the same surface records
  // the same identity.
  assert_eq(
    claude,
    @harness.provider_receipt_identity(
      @control.ProviderSurfaceId::ClaudeSubscriptionCli,
    ),
  )
}
