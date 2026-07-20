///|
fn claude_driver_manifest(
  tools : Array[String],
) -> @harness.ClaudeInitializationManifest {
  {
    client_version: "2.1.215",
    permission_mode: "dontAsk",
    api_key_source: "none",
    tools,
    mcp_servers: [
      {
        name: "choir_sandbox",
        status: @harness.McpConnectionState::McpConnected,
      },
    ],
    slash_commands: [],
    skills: [],
    plugins: [],
    agents: ["claude", "Explore", "general-purpose", "Plan", "statusline-setup"],
  }
}

///|
fn claude_driver_session(digest : @control.Digest) -> @control.HarnessSession {
  {
    id: @control.HarnessSessionId("session-1"),
    take_id: @control.TakeId("take-1"),
    sandbox_generation_id: @control.SandboxGenerationId("sandbox-1"),
    surface: @control.ProviderSurfaceId::ClaudeSubscriptionCli,
    effective_surface_manifest_digest: digest,
    cursor_class: @control.HarnessCursorClass::HarnessCursorNotResumable,
    provider_cursor: None,
    last_choir_sequence: @control.EventSequence(0L),
    open_tool_execution_ids: [],
    lifecycle: @control.HarnessSessionLifecycle::HarnessSessionPlanned,
  }
}

///|
fn claude_driver_output(tool_name : String) -> String {
  let init =
    #|{"type":"system","subtype":"init","tools":["mcp__choir_sandbox__execute"],"mcp_servers":[{"name":"choir_sandbox","status":"connected"}],"permissionMode":"dontAsk","apiKeySource":"none","claude_code_version":"2.1.215","slash_commands":[],"skills":[],"plugins":[],"agents":["claude","Explore","general-purpose","Plan","statusline-setup"]}
  init +
  "\n" +
  (
    #|{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","rateLimitType":"five_hour","overageStatus":"rejected","isUsingOverage":false}}
    #|{"type":"assistant","message":{"model":"claude-opus-4-8","content":[{"type":"tool_use","id":"tool-1","name":"
  ) +
  tool_name +
  (
    #|"}]}}
    #|{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tool-1","content":"ok"}]}}
    #|{"type":"result","subtype":"success","is_error":false,"result":"{\"outcome\":\"completed\"}"}
  )
}

///|
test "Claude driver normalizes one balanced restricted Take" {
  let tools = ["mcp__choir_sandbox__execute"]
  let digest = @harness.claude_effective_surface_manifest_digest(
    claude_driver_manifest(tools),
  )
  let started = @harness.start_claude_harness_session(
    claude_driver_session(digest),
  ).unwrap()
  let result = @harness.evaluate_claude_driver_capture({
    session: started,
    role: @harness.ClaudeTakeRole::ClaudeImplementationTake,
    allowed_tools: tools,
    expected_mcp_server: "choir_sandbox",
    capture: {
      exit_code: 0,
      output: claude_driver_output("mcp__choir_sandbox__execute"),
      started_at: 10L,
      finished_at: 20L,
    },
  }).unwrap()
  assert_eq(result.model_identity, "claude-opus-4-8")
  assert_eq(result.terminal_response, "{\"outcome\":\"completed\"}")
  assert_eq(
    result.outcome,
    @harness.ClaudeTakeOutcome::ClaudeImplementationCompleted,
  )
  assert_eq(result.events.length(), 4)
  assert_true(
    result.session.lifecycle
    is @control.HarnessSessionLifecycle::HarnessSessionIngestionClosedCleanly(
      @control.HarnessTerminalObservation::HarnessCompleted
    ),
  )
}

///|
test "Claude driver rejects undeclared host tool use" {
  let tools = ["mcp__choir_sandbox__execute"]
  let digest = @harness.claude_effective_surface_manifest_digest(
    claude_driver_manifest(tools),
  )
  let started = @harness.start_claude_harness_session(
    claude_driver_session(digest),
  ).unwrap()
  assert_true(
    @harness.evaluate_claude_driver_capture({
      session: started,
      role: @harness.ClaudeTakeRole::ClaudeImplementationTake,
      allowed_tools: tools,
      expected_mcp_server: "choir_sandbox",
      capture: {
        exit_code: 0,
        output: claude_driver_output("Read"),
        started_at: 10L,
        finished_at: 20L,
      },
    })
    is Err(_),
  )
}

///|
test "Claude driver rejects surface drift before recording events" {
  let tools = ["mcp__choir_sandbox__execute"]
  let started = @harness.start_claude_harness_session(
    claude_driver_session(
      @control.Digest(
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      ),
    ),
  ).unwrap()
  assert_true(
    @harness.evaluate_claude_driver_capture({
      session: started,
      role: @harness.ClaudeTakeRole::ClaudeAuditTake,
      allowed_tools: tools,
      expected_mcp_server: "choir_sandbox",
      capture: {
        exit_code: 0,
        output: claude_driver_output("mcp__choir_sandbox__execute"),
        started_at: 10L,
        finished_at: 20L,
      },
    })
    is Err(_),
  )
}
