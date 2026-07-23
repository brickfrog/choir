///|
fn claude_driver_manifest(
  tools : Array[String],
) -> @harness.ClaudeInitializationManifest {
  {
    client_version: "2.1.218",
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
    #|{"type":"system","subtype":"init","tools":["mcp__choir_sandbox__execute","StructuredOutput"],"mcp_servers":[{"name":"choir_sandbox","status":"connected"}],"permissionMode":"dontAsk","apiKeySource":"none","claude_code_version":"2.1.218","slash_commands":[],"skills":[],"plugins":[],"agents":["claude","Explore","general-purpose","Plan","statusline-setup"]}
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
    #|{"type":"assistant","message":{"model":"claude-opus-4-8","content":[{"type":"tool_use","id":"tool-2","name":"StructuredOutput"}]}}
    #|{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tool-2","content":"Structured output provided successfully"}]}}
    #|{"type":"result","subtype":"success","is_error":false,"result":"{\"outcome\":\"completed\"}"}
  )
}

///|
test "Claude driver normalizes one balanced restricted Take" {
  let tools = ["mcp__choir_sandbox__execute"]
  let digest = @harness.claude_effective_surface_manifest_digest(
    claude_driver_manifest([..tools, "StructuredOutput"]),
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
  assert_eq(result.events.length(), 6)
  assert_true(
    result.session.lifecycle
    is @control.HarnessSessionLifecycle::HarnessSessionIngestionClosedCleanly(
      @control.HarnessTerminalObservation::HarnessCompleted
    ),
  )
}

///|
test "Claude driver rejects a failed declared MCP tool result" {
  let tools = ["mcp__choir_sandbox__execute"]
  let digest = @harness.claude_effective_surface_manifest_digest(
    claude_driver_manifest([..tools, "StructuredOutput"]),
  )
  let started = @harness.start_claude_harness_session(
    claude_driver_session(digest),
  ).unwrap()
  let output = claude_driver_output("mcp__choir_sandbox__execute").replace(
    old=(
      #|"tool_use_id":"tool-1","content":"ok"
    ),
    new=(
      #|"tool_use_id":"tool-1","content":"capability dead","is_error":true
    ),
  )
  let result = @harness.evaluate_claude_driver_capture({
    session: started,
    role: @harness.ClaudeTakeRole::ClaudeImplementationTake,
    allowed_tools: tools,
    expected_mcp_server: "choir_sandbox",
    capture: { exit_code: 0, output, started_at: 10L, finished_at: 20L },
  })
  assert_true(result is Err(_))
  guard result is Err(error) else { fail("failed tool result was accepted") }
  assert_true(error.message().contains("declared MCP tool call failed"))
}

///|
test "Claude durable events exclude tool names and raw trace fields" {
  let first_tool = "mcp__choir_sandbox__first_secret_marker"
  let second_tool = "mcp__choir_sandbox__second_secret_marker"
  let evaluate = fn(tool : String) {
    let digest = @harness.claude_effective_surface_manifest_digest(
      claude_driver_manifest([tool, "StructuredOutput"]),
    )
    let started = @harness.start_claude_harness_session(
      claude_driver_session(digest),
    ).unwrap()
    @harness.evaluate_claude_driver_capture({
      session: started,
      role: @harness.ClaudeTakeRole::ClaudeImplementationTake,
      allowed_tools: [tool],
      expected_mcp_server: "choir_sandbox",
      capture: {
        exit_code: 0,
        output: claude_driver_output(tool).replace_all(
          old="mcp__choir_sandbox__execute",
          new=tool,
        ),
        started_at: 10L,
        finished_at: 20L,
      },
    }).unwrap()
  }
  let first = evaluate(first_tool)
  let second = evaluate(second_tool)
  assert_eq(
    first.events.map(fn(event) { event.sanitized_payload_digest }),
    second.events.map(fn(event) { event.sanitized_payload_digest }),
  )
  let durable_json = first.events.to_json().stringify(indent=0)
  assert_false(durable_json.contains(first_tool))
  assert_false(durable_json.contains("first_secret_marker"))
}

///|
test "Claude canonicalizes terminal output before durable use" {
  let secret = "CHOIR_SYNTHETIC_SECRET_CLAUDE"
  let tool = "mcp__choir_sandbox__execute"
  let digest = @harness.claude_effective_surface_manifest_digest(
    claude_driver_manifest([tool, "StructuredOutput"]),
  )
  let started = @harness.start_claude_harness_session(
    claude_driver_session(digest),
  ).unwrap()
  let output = claude_driver_output(tool)
    .replace(
      old="\"model\":\"claude-opus-4-8\"",
      new="\"model\":\"claude-opus-4-8\",\"authorization\":\"Bearer " +
        secret +
        "\"",
    )
    .replace(old="\"content\":\"ok\"", new="\"content\":\"" + secret + "\"")
    .replace(
      old="{\\\"outcome\\\":\\\"completed\\\"}",
      new="{\\\"outcome\\\":\\\"completed\\\",\\\"secret\\\":\\\"" +
        secret +
        "\\\"}",
    )
  let result = @harness.evaluate_claude_driver_capture({
    session: started,
    role: @harness.ClaudeTakeRole::ClaudeImplementationTake,
    allowed_tools: [tool],
    expected_mcp_server: "choir_sandbox",
    capture: { exit_code: 0, output, started_at: 10L, finished_at: 20L },
  }).unwrap()
  assert_eq(result.terminal_response, "{\"outcome\":\"completed\"}")
  assert_false(result.terminal_response.contains(secret))
  assert_false(result.events.to_json().stringify(indent=0).contains(secret))
}

///|
test "safe event digest binds typed tool disposition and redaction" {
  let succeeded = @control.HarnessEventKind::HarnessToolFinished(
    "tool-1",
    @control.HarnessToolDisposition::HarnessToolSucceeded,
  )
  let failed = @control.HarnessEventKind::HarnessToolFinished(
    "tool-1",
    @control.HarnessToolDisposition::HarnessToolFailed,
  )
  let succeeded_digest = @harness.safe_harness_event_digest(
    succeeded,
    @control.EventRedactionState::EventNotSensitive,
  )
  assert_false(
    succeeded_digest ==
    @harness.safe_harness_event_digest(
      failed,
      @control.EventRedactionState::EventNotSensitive,
    ),
  )
  assert_false(
    succeeded_digest ==
    @harness.safe_harness_event_digest(
      succeeded,
      @control.EventRedactionState::EventWithheld,
    ),
  )
}

///|
test "Claude driver rejects undeclared host tool use" {
  let tools = ["mcp__choir_sandbox__execute"]
  let digest = @harness.claude_effective_surface_manifest_digest(
    claude_driver_manifest([..tools, "StructuredOutput"]),
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
