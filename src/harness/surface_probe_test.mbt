///|
fn capture(output : String) -> @harness.HarnessProbeCapture {
  { exit_code: 0, output }
}

///|
test "Claude declaration remains Candidate with required isolation flags" {
  let report = @harness.evaluate_surface_declaration({
    surface: @harness.ProviderSurface::ClaudeCli,
    version: capture("2.1.215 (Claude Code)"),
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
    version: capture("2.1.215 (Claude Code)"),
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
    version: capture("codex-cli 0.144.6"),
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
