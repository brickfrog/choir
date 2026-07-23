///|
let connected_init =
  #|{"type":"system","subtype":"init","tools":["mcp__choir_probe__probe"],"mcp_servers":[{"name":"choir_probe","status":"connected"}],"permissionMode":"dontAsk","apiKeySource":"none","claude_code_version":"2.1.218","slash_commands":[],"skills":[],"plugins":[],"agents":["claude","Explore","general-purpose","Plan","statusline-setup"],"session_id":"secret-discarded"}
  #|{"type":"result","result":"Not logged in"}

///|
let pending_no_login =
    #|{"type":"system","subtype":"init","tools":[],"mcp_servers":[{"name":"choir_probe","status":"pending"}],"permissionMode":"dontAsk","apiKeySource":"none","claude_code_version":"2.1.218","slash_commands":[],"skills":[],"plugins":[],"agents":["claude","Explore","general-purpose","Plan","statusline-setup"]}
  #|{"is_error":true,"terminal_reason":"api_error","subtype":"success","result":"Not logged in · Please run /login","type":"result"}

///|
test "Claude synthetic startup accepts exact restricted initialization" {
  let report = @harness.evaluate_claude_synthetic_startup({
    exit_code: 1,
    output: connected_init,
  })
  assert_eq(report.support, @harness.ChoirSurfaceSupport::SurfaceCandidate)
  assert_eq(report.blocking_reasons.length(), 0)
  match report.manifest {
    Some(manifest) => {
      assert_eq(manifest.tools, ["mcp__choir_probe__probe"])
      assert_eq(manifest.api_key_source, "none")
    }
    None => fail("initialization manifest missing")
  }
}

///|
test "Claude synthetic startup accepts exact fail-closed no-login initialization" {
  let report = @harness.evaluate_claude_synthetic_startup({
    exit_code: 1,
    output: pending_no_login,
  })
  assert_eq(report.support, @harness.ChoirSurfaceSupport::SurfaceCandidate)
  assert_eq(report.blocking_reasons.length(), 0)
  match report.manifest {
    Some(manifest) => {
      assert_eq(manifest.tools, [])
      assert_eq(
        manifest.mcp_servers[0].status,
        @harness.McpConnectionState::McpPending,
      )
    }
    None => fail("initialization manifest missing")
  }
}

///|
test "Claude synthetic startup does not infer no-login evidence from prose alone" {
  let report = @harness.evaluate_claude_synthetic_startup({
    exit_code: 1,
    output: pending_no_login.replace(
      old="\"terminal_reason\":\"api_error\"",
      new="\"terminal_reason\":\"other\"",
    ),
  })
  assert_true(
    report.blocking_reasons.contains(
      @harness.ClaudeStartupBlockReason::ClaudeStartupRequiredMcpToolMissing,
    ),
  )
  assert_true(
    report.blocking_reasons.contains(
      @harness.ClaudeStartupBlockReason::ClaudeStartupRequiredMcpNotConnected,
    ),
  )
}

///|
test "Claude synthetic startup rejects pending MCP and native tools" {
  let output =
    #|{"type":"system","subtype":"init","tools":["Read"],"mcp_servers":[{"name":"choir_probe","status":"pending"}],"permissionMode":"dontAsk","apiKeySource":"none","claude_code_version":"2.1.218","slash_commands":[],"skills":[],"plugins":[],"agents":["claude","Explore","general-purpose","Plan","statusline-setup"]}
  let report = @harness.evaluate_claude_synthetic_startup({
    exit_code: 1,
    output,
  })
  assert_true(
    report.blocking_reasons.contains(
      @harness.ClaudeStartupBlockReason::ClaudeStartupNativeToolsVisible,
    ),
  )
  assert_true(
    report.blocking_reasons.contains(
      @harness.ClaudeStartupBlockReason::ClaudeStartupRequiredMcpNotConnected,
    ),
  )
}

///|
test "Claude synthetic startup distinguishes missing MCP tool from native tools" {
  let output =
  #|{"type":"system","subtype":"init","tools":[],"mcp_servers":[{"name":"choir_probe","status":"pending"}],"permissionMode":"dontAsk","apiKeySource":"none","claude_code_version":"2.1.218","slash_commands":[],"skills":[],"plugins":[],"agents":["claude","Explore","general-purpose","Plan","statusline-setup"]}
  let report = @harness.evaluate_claude_synthetic_startup({
    exit_code: 1,
    output,
  })
  assert_true(
    report.blocking_reasons.contains(
      @harness.ClaudeStartupBlockReason::ClaudeStartupRequiredMcpToolMissing,
    ),
  )
  assert_false(
    report.blocking_reasons.contains(
      @harness.ClaudeStartupBlockReason::ClaudeStartupNativeToolsVisible,
    ),
  )
}

///|
test "Claude synthetic startup fails when an event precedes initialization" {
  let report = @harness.evaluate_claude_synthetic_startup({
    exit_code: 1,
    output: "{\"type\":\"assistant\"}\n" + connected_init,
  })
  assert_true(
    report.blocking_reasons.contains(
      @harness.ClaudeStartupBlockReason::ClaudeStartupEventBeforeInitialization,
    ),
  )
}

///|
test "Claude live startup classifies subscription lane without retaining quota data" {
  let output = connected_init +
    "\n" +
    (
      #|{"type":"assistant","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"PROBE_OK"}]}}
      #|{"type":"assistant","message":{"model":"claude-opus-4-8","content":[{"type":"tool_use","name":"mcp__choir_probe__probe"}]}}
      #|{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":123456,"rateLimitType":"five_hour","overageStatus":"rejected","isUsingOverage":false}}
      #|{"type":"result","subtype":"success","is_error":false,"result":"PROBE_OK","session_id":"discard-me","total_cost_usd":0.01}
    )
  let report = @harness.evaluate_claude_live_startup({ exit_code: 0, output })
  assert_eq(report.support, @harness.ChoirSurfaceSupport::SurfaceCandidate)
  assert_eq(
    report.observed_authentication,
    @harness.RedactedAuthenticationClass::AuthenticationProviderManagedSubscription,
  )
  assert_eq(
    report.observed_entitlement,
    @harness.EntitlementLane::EntitlementSubscriptionIncluded,
  )
  assert_eq(report.model_identity, "claude-opus-4-8")
  let matrix = @harness.claude_live_startup_host_surface_matrix(report).unwrap()
  assert_eq(matrix.surface, @harness.ProviderSurface::ClaudeCli)
  assert_eq(matrix.passed, 2)
  assert_eq(matrix.failed, 0)
  assert_eq(matrix.not_run, 13)
  assert_eq(
    matrix.disposition,
    @harness.HostSurfaceMatrixDisposition::HostSurfaceMatrixIncomplete,
  )
}

///|
test "Claude live startup requires the sandbox tool and subscription observation" {
  let output = connected_init +
    "\n" +
    (
      #|{"type":"assistant","message":{"model":"claude-opus-4-8","content":[{"type":"tool_use","name":"mcp__choir_probe__probe"}]}}
      #|{"type":"result","subtype":"success","is_error":false,"result":"PROBE_OK"}
    )
  let report = @harness.evaluate_claude_live_startup({ exit_code: 0, output })
  assert_false(
    report.blocking_reasons.contains(
      @harness.ClaudeLiveBlockReason::ClaudeLiveRequiredToolUseMismatch,
    ),
  )
  assert_true(
    report.blocking_reasons.contains(
      @harness.ClaudeLiveBlockReason::ClaudeLiveMissingEntitlementObservation,
    ),
  )
}

///|
test "Claude live startup accepts pending initialization after exact tool use" {
  let output = (
      #|{"type":"system","subtype":"init","tools":[],"mcp_servers":[{"name":"choir_probe","status":"pending"}],"permissionMode":"dontAsk","apiKeySource":"none","claude_code_version":"2.1.218","slash_commands":[],"skills":[],"plugins":[],"agents":["claude","Explore","general-purpose","Plan","statusline-setup"]}
    ) +
    "\n" +
    (
      #|{"type":"assistant","message":{"model":"claude-opus-4-8","content":[{"type":"tool_use","name":"mcp__choir_probe__probe"}]}}
      #|{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","rateLimitType":"five_hour","overageStatus":"rejected","isUsingOverage":false}}
      #|{"type":"result","subtype":"success","is_error":false,"result":"PROBE_OK"}
    )
  let report = @harness.evaluate_claude_live_startup({ exit_code: 0, output })
  assert_eq(report.support, @harness.ChoirSurfaceSupport::SurfaceCandidate)
  assert_eq(report.blocking_reasons.length(), 0)
}

///|
test "Claude live startup rejects any undeclared tool use" {
  let output = connected_init +
    "\n" +
    (
      #|{"type":"assistant","message":{"model":"claude-opus-4-8","content":[{"type":"tool_use","name":"mcp__choir_probe__probe"},{"type":"tool_use","name":"Read"}]}}
      #|{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","rateLimitType":"five_hour","overageStatus":"rejected","isUsingOverage":false}}
      #|{"type":"result","subtype":"success","is_error":false,"result":"PROBE_OK"}
    )
  let report = @harness.evaluate_claude_live_startup({ exit_code: 0, output })
  assert_true(
    report.blocking_reasons.contains(
      @harness.ClaudeLiveBlockReason::ClaudeLiveUnexpectedToolUse,
    ),
  )
  let matrix = @harness.claude_live_startup_host_surface_matrix(report).unwrap()
  assert_eq(matrix.passed, 0)
  assert_eq(matrix.failed, 2)
  assert_eq(matrix.not_run, 13)
  assert_eq(
    matrix.disposition,
    @harness.HostSurfaceMatrixDisposition::HostSurfaceMatrixFailed,
  )
}
