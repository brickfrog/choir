///|
fn codex_probe_capture(
  exit_code : Int,
  output : String,
) -> @harness.HarnessProbeCapture {
  { exit_code, output }
}

///|
fn passing_codex_events() -> String {
  (
    #|{"type":"thread.started","thread_id":"discarded"}
    #|{"type":"turn.started"}
    #|{"type":"item.started","item":{"id":"item-1","type":"mcp_tool_call","server":"choir_probe","tool":"probe","status":"in_progress"}}
    #|{"type":"item.completed","item":{"id":"item-1","type":"mcp_tool_call","server":"choir_probe","tool":"probe","status":"completed","error":null}}
    #|{"type":"item.completed","item":{"id":"item-2","type":"agent_message","text":"CHOIR_CODEX_PROBE_OK"}}
    #|{"type":"turn.completed"}
    #|writing is blocked by read-only sandbox
    #|unable to locate image at `/repo/canary`: No such file or directory (os error 2)
  )
}

///|
test "Codex live startup admits exact subscription and isolation evidence" {
  let report = @harness.evaluate_codex_live_startup({
    login_status: codex_probe_capture(0, "Logged in using ChatGPT\n"),
    admitted_run: codex_probe_capture(0, passing_codex_events()),
    required_mcp_failure: codex_probe_capture(
      1, "required MCP servers failed to initialize: choir_probe",
    ),
    write_canary_present: false,
  })
  assert_eq(report.support, @harness.ChoirSurfaceSupport::SurfaceCandidate)
  assert_eq(
    report.probe_status,
    @harness.SurfaceProbeStatus::SurfaceProbePassed,
  )
  assert_eq(
    report.observed_authentication,
    @harness.RedactedAuthenticationClass::AuthenticationProviderManagedSubscription,
  )
  assert_eq(
    report.observed_entitlement,
    @harness.EntitlementLane::EntitlementSubscriptionIncluded,
  )
  assert_eq(report.required_tool_use_count, 1)
  assert_true(report.native_write_denied)
  assert_true(report.native_read_denied)
  assert_true(report.required_mcp_failed_closed)
  assert_eq(report.blocking_reasons.length(), 0)
}

///|
test "Codex live startup rejects terminal prose without a completed tool" {
  let completed =
    #|{"type":"item.completed","item":{"id":"item-1","type":"mcp_tool_call","server":"choir_probe","tool":"probe","status":"completed","error":null}}
  let failed =
    #|{"type":"item.completed","item":{"id":"item-1","type":"mcp_tool_call","server":"choir_probe","tool":"probe","status":"failed","error":{"message":"cancelled"}}}
  let events = passing_codex_events().replace(old=completed, new=failed)
  let report = @harness.evaluate_codex_live_startup({
    login_status: codex_probe_capture(0, "Logged in using ChatGPT\n"),
    admitted_run: codex_probe_capture(0, events),
    required_mcp_failure: codex_probe_capture(
      1, "required MCP servers failed to initialize: choir_probe",
    ),
    write_canary_present: false,
  })
  assert_eq(
    report.support,
    @harness.ChoirSurfaceSupport::SurfaceBlockedByConformance,
  )
  assert_true(
    report.blocking_reasons.contains(
      @harness.CodexLiveBlockReason::CodexLiveRequiredToolUseMismatch,
    ),
  )
  assert_true(
    report.blocking_reasons.contains(
      @harness.CodexLiveBlockReason::CodexLiveRequiredToolFailed,
    ),
  )
}

///|
test "Codex live startup rejects a missing-server fallback turn" {
  let fallback =
    #|{"type":"thread.started","thread_id":"fallback"}
    #|{"type":"turn.started"}
    #|{"type":"turn.completed"}
  let report = @harness.evaluate_codex_live_startup({
    login_status: codex_probe_capture(0, "Logged in using ChatGPT\n"),
    admitted_run: codex_probe_capture(0, passing_codex_events()),
    required_mcp_failure: codex_probe_capture(0, fallback),
    write_canary_present: false,
  })
  assert_true(
    report.blocking_reasons.contains(
      @harness.CodexLiveBlockReason::CodexLiveRequiredMcpDidNotFailClosed,
    ),
  )
  assert_true(
    report.blocking_reasons.contains(
      @harness.CodexLiveBlockReason::CodexLiveMissingMcpReachedModelTurn,
    ),
  )
}

///|
test "Codex live startup rejects effectful native events and write residue" {
  let effect =
    #|{"type":"item.completed","item":{"id":"item-3","type":"file_change","status":"completed"}}
  let events = passing_codex_events() + "\n" + effect
  let report = @harness.evaluate_codex_live_startup({
    login_status: codex_probe_capture(0, "Logged in using ChatGPT\n"),
    admitted_run: codex_probe_capture(0, events),
    required_mcp_failure: codex_probe_capture(
      1, "required MCP servers failed to initialize: choir_probe",
    ),
    write_canary_present: true,
  })
  assert_true(
    report.blocking_reasons.contains(
      @harness.CodexLiveBlockReason::CodexLiveUnexpectedEffectfulToolEvent,
    ),
  )
  assert_true(
    report.blocking_reasons.contains(
      @harness.CodexLiveBlockReason::CodexLiveWriteCanaryPresent,
    ),
  )
}
