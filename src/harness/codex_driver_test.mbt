///|
fn codex_driver_session(
  tools? : Array[String] = ["read_file", "write_file"],
) -> @control.HarnessSession {
  {
    id: @control.HarnessSessionId("session-codex-driver"),
    take_id: @control.TakeId("take-codex-driver"),
    sandbox_generation_id: @control.SandboxGenerationId("sandbox-codex-driver"),
    surface: @control.ProviderSurfaceId::CodexSubscriptionCli,
    effective_surface_manifest_digest: @harness.codex_effective_surface_manifest_digest(
      tools, "choir_sandbox",
    ),
    cursor_class: @control.HarnessCursorClass::HarnessCursorProviderEventId,
    provider_cursor: None,
    last_choir_sequence: @control.EventSequence(0L),
    open_tool_execution_ids: [],
    lifecycle: @control.HarnessSessionLifecycle::HarnessSessionPlanned,
  }
}

///|
fn codex_driver_started_session(
  tools? : Array[String] = ["read_file", "write_file"],
) -> @control.HarnessSession {
  let started = @harness.start_codex_harness_session(
    codex_driver_session(tools~),
  ).unwrap()
  { ..started, provider_cursor: Some("thread-codex-driver:turn-codex-driver") }
}

///|
fn codex_driver_output(item_type : String, response : String) -> String {
  let tool_started : Map[String, Json] = {
    "id": "tool-1".to_json(),
    "type": item_type.to_json(),
    "server": "choir_sandbox".to_json(),
    "tool": "read_file".to_json(),
    "status": "in_progress".to_json(),
  }
  let tool_completed : Map[String, Json] = {
    "id": "tool-1".to_json(),
    "type": item_type.to_json(),
    "server": "choir_sandbox".to_json(),
    "tool": "read_file".to_json(),
    "status": "completed".to_json(),
  }
  let message : Map[String, Json] = {
    "id": "message-1".to_json(),
    "type": "agent_message".to_json(),
    "text": response.to_json(),
  }
  [
    { "type": "thread.started".to_json(), "thread_id": "thread-1".to_json() }
    .to_json()
    .stringify(),
    { "type": "turn.started".to_json() }.to_json().stringify(),
    { "type": "item.started".to_json(), "item": tool_started.to_json() }
    .to_json()
    .stringify(),
    { "type": "item.completed".to_json(), "item": tool_completed.to_json() }
    .to_json()
    .stringify(),
    { "type": "item.completed".to_json(), "item": message.to_json() }
    .to_json()
    .stringify(),
    { "type": "turn.completed".to_json() }.to_json().stringify(),
  ].join("\n")
}

///|
test "Codex driver accepts a balanced sandbox-only implementation trace" {
  let started = codex_driver_started_session()
  let result = @harness.evaluate_codex_driver_capture({
    session: started,
    role: @harness.CodexTakeRole::CodexImplementationTake,
    allowed_tools: ["read_file", "write_file"],
    expected_mcp_server: "choir_sandbox",
    capture: {
      exit_code: 0,
      output: codex_driver_output(
        "mcp_tool_call", "{\"outcome\":\"completed\"}",
      ),
      started_at: 10L,
      finished_at: 20L,
    },
  }).unwrap()
  assert_eq(
    result.outcome,
    @harness.CodexTakeOutcome::CodexImplementationCompleted,
  )
  assert_eq(
    result.session.lifecycle,
    @control.HarnessSessionLifecycle::HarnessSessionIngestionClosedCleanly(
      @control.HarnessTerminalObservation::HarnessCompleted,
    ),
  )
  assert_eq(result.events.length(), 4)
}

///|
test "Codex durable events exclude tool names and raw trace fields" {
  let first_tool = "first_secret_marker"
  let second_tool = "second_secret_marker"
  let evaluate = fn(tool : String) {
    let started = codex_driver_started_session(tools=[tool])
    @harness.evaluate_codex_driver_capture({
      session: started,
      role: @harness.CodexTakeRole::CodexImplementationTake,
      allowed_tools: [tool],
      expected_mcp_server: "choir_sandbox",
      capture: {
        exit_code: 0,
        output: codex_driver_output(
          "mcp_tool_call", "{\"outcome\":\"completed\"}",
        ).replace_all(old="read_file", new=tool),
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
test "Codex canonicalizes terminal output before durable use" {
  let secret = "CHOIR_SYNTHETIC_SECRET_CODEX"
  let started = codex_driver_started_session()
  let output = codex_driver_output(
    "mcp_tool_call",
    "{\"outcome\":\"completed\",\"secret\":\"" + secret + "\"}",
  ).replace(
    old="\"status\":\"in_progress\"",
    new="\"status\":\"in_progress\",\"authorization\":\"Bearer " + secret + "\"",
  )
  let result = @harness.evaluate_codex_driver_capture({
    session: started,
    role: @harness.CodexTakeRole::CodexImplementationTake,
    allowed_tools: ["read_file", "write_file"],
    expected_mcp_server: "choir_sandbox",
    capture: { exit_code: 0, output, started_at: 10L, finished_at: 20L },
  }).unwrap()
  assert_eq(result.terminal_response, "{\"outcome\":\"completed\"}")
  assert_false(result.terminal_response.contains(secret))
  assert_false(result.events.to_json().stringify(indent=0).contains(secret))
}

///|
test "Codex driver rejects a native effect event disguised as success" {
  let started = codex_driver_started_session()
  let result = @harness.evaluate_codex_driver_capture({
    session: started,
    role: @harness.CodexTakeRole::CodexImplementationTake,
    allowed_tools: ["read_file", "write_file"],
    expected_mcp_server: "choir_sandbox",
    capture: {
      exit_code: 0,
      output: codex_driver_output(
        "command_execution", "{\"outcome\":\"completed\"}",
      ),
      started_at: 10L,
      finished_at: 20L,
    },
  })
  assert_true(result is Err(_))
}

///|
test "Codex driver rejects terminal prose after a failed MCP call" {
  let started = codex_driver_started_session()
  let output = codex_driver_output(
    "mcp_tool_call", "{\"outcome\":\"completed\"}",
  ).replace(old="\"status\":\"completed\"", new="\"status\":\"failed\"")
  let result = @harness.evaluate_codex_driver_capture({
    session: started,
    role: @harness.CodexTakeRole::CodexImplementationTake,
    allowed_tools: ["read_file", "write_file"],
    expected_mcp_server: "choir_sandbox",
    capture: { exit_code: 0, output, started_at: 10L, finished_at: 20L },
  })
  assert_true(result is Err(_))
}

///|
test "Codex driver accepts a failed sandbox call followed by successful recovery" {
  let output =
    #|{"type":"thread.started","thread_id":"thread-1"}
    #|{"type":"turn.started"}
    #|{"type":"item.started","item":{"id":"tool-1","type":"mcp_tool_call","server":"choir_sandbox","tool":"read_file","status":"in_progress"}}
    #|{"type":"item.completed","item":{"id":"tool-1","type":"mcp_tool_call","server":"choir_sandbox","tool":"read_file","status":"failed"}}
    #|{"type":"item.started","item":{"id":"tool-2","type":"mcp_tool_call","server":"choir_sandbox","tool":"write_file","status":"in_progress"}}
    #|{"type":"item.completed","item":{"id":"tool-2","type":"mcp_tool_call","server":"choir_sandbox","tool":"write_file","status":"completed"}}
    #|{"type":"item.completed","item":{"id":"message-1","type":"agent_message","text":"{\"outcome\":\"completed\"}"}}
    #|{"type":"turn.completed"}
  let started = codex_driver_started_session()
  let result = @harness.evaluate_codex_driver_capture({
    session: started,
    role: @harness.CodexTakeRole::CodexImplementationTake,
    allowed_tools: ["read_file", "write_file"],
    expected_mcp_server: "choir_sandbox",
    capture: { exit_code: 0, output, started_at: 10L, finished_at: 20L },
  }).unwrap()
  assert_eq(result.events.length(), 6)
  assert_eq(
    result.outcome,
    @harness.CodexTakeOutcome::CodexImplementationCompleted,
  )
}

///|
test "Codex driver ignores balanced discovery on the declared MCP server" {
  let discovery =
    #|{"type":"item.started","item":{"id":"discovery-1","type":"mcp_tool_call","server":"choir_sandbox","tool":"list_mcp_resources","status":"in_progress"}}
    #|{"type":"item.completed","item":{"id":"discovery-1","type":"mcp_tool_call","server":"choir_sandbox","tool":"list_mcp_resources","status":"completed"}}
  let output = codex_driver_output(
    "mcp_tool_call", "{\"outcome\":\"completed\"}",
  ).replace(
    old="{\"type\":\"turn.started\"}",
    new="{\"type\":\"turn.started\"}\n" + discovery,
  )
  let started = codex_driver_started_session()
  let result = @harness.evaluate_codex_driver_capture({
    session: started,
    role: @harness.CodexTakeRole::CodexImplementationTake,
    allowed_tools: ["read_file", "write_file"],
    expected_mcp_server: "choir_sandbox",
    capture: { exit_code: 0, output, started_at: 10L, finished_at: 20L },
  }).unwrap()
  assert_eq(result.events.length(), 4)
}

///|
test "Codex MCP discovery cannot satisfy the declared tool requirement" {
  let output = codex_driver_output(
    "mcp_tool_call", "{\"outcome\":\"completed\"}",
  ).replace(old="\"tool\":\"read_file\"", new="\"tool\":\"list_mcp_resources\"")
  let started = codex_driver_started_session()
  let result = @harness.evaluate_codex_driver_capture({
    session: started,
    role: @harness.CodexTakeRole::CodexImplementationTake,
    allowed_tools: ["read_file", "write_file"],
    expected_mcp_server: "choir_sandbox",
    capture: { exit_code: 0, output, started_at: 10L, finished_at: 20L },
  })
  assert_true(result is Err(_))
}

///|
test "Codex Conductor accepts a restricted resumable turn" {
  let output =
    #|{"type":"thread.started","thread_id":"019f80a5-df42-7411-9065-e0866506338c"}
    #|{"type":"turn.started"}
    #|{"type":"item.started","item":{"id":"discovery-1","type":"mcp_tool_call","server":"codex","tool":"list_mcp_resources","status":"in_progress"}}
    #|{"type":"item.completed","item":{"id":"discovery-1","type":"mcp_tool_call","server":"codex","tool":"list_mcp_resources","status":"completed"}}
    #|{"type":"item.started","item":{"id":"tool-1","type":"mcp_tool_call","server":"choir","tool":"goal_status","status":"in_progress"}}
    #|{"type":"item.completed","item":{"id":"tool-1","type":"mcp_tool_call","server":"choir","tool":"goal_status","status":"completed"}}
    #|{"type":"item.completed","item":{"id":"message-1","type":"agent_message","text":"The Goal is queued."}}
    #|{"type":"turn.completed"}
  let turn = @harness.evaluate_codex_conductor_capture(
    { exit_code: 0, output },
    Some("019f80a5-df42-7411-9065-e0866506338c"),
    "choir",
    ["goal_status"],
  ).unwrap()
  assert_eq(turn.response, "The Goal is queued.")
  assert_eq(turn.tool_call_count, 1)
}

///|
test "Codex Conductor rejects native host-tool events and thread drift" {
  let base =
    #|{"type":"thread.started","thread_id":"019f80a5-df42-7411-9065-e0866506338c"}
    #|{"type":"turn.started"}
    #|{"type":"item.completed","item":{"id":"message-1","type":"agent_message","text":"done"}}
    #|{"type":"turn.completed"}
  assert_true(
    @harness.evaluate_codex_conductor_capture(
      { exit_code: 0, output: base },
      Some("019f80a5-df42-7411-9065-e0866506338d"),
      "choir",
      ["goal_status"],
    )
    is Err(_),
  )
  let native = base.replace(
    old="{\"type\":\"item.completed\",\"item\":{\"id\":\"message-1\",\"type\":\"agent_message\",\"text\":\"done\"}}",
    new="{\"type\":\"item.completed\",\"item\":{\"id\":\"command-1\",\"type\":\"command_execution\",\"status\":\"completed\"}}",
  )
  assert_true(
    @harness.evaluate_codex_conductor_capture(
      { exit_code: 0, output: native },
      None,
      "choir",
      ["goal_status"],
    )
    is Err(_),
  )
  let foreign_discovery = base.replace(
    old="{\"type\":\"item.completed\",\"item\":{\"id\":\"message-1\",\"type\":\"agent_message\",\"text\":\"done\"}}",
    new="{\"type\":\"item.started\",\"item\":{\"id\":\"discovery-1\",\"type\":\"mcp_tool_call\",\"server\":\"foreign\",\"tool\":\"list_mcp_resources\",\"status\":\"in_progress\"}}\n" +
      "{\"type\":\"item.completed\",\"item\":{\"id\":\"discovery-1\",\"type\":\"mcp_tool_call\",\"server\":\"foreign\",\"tool\":\"list_mcp_resources\",\"status\":\"completed\"}}\n" +
      "{\"type\":\"item.completed\",\"item\":{\"id\":\"message-1\",\"type\":\"agent_message\",\"text\":\"done\"}}",
  )
  assert_true(
    @harness.evaluate_codex_conductor_capture(
      { exit_code: 0, output: foreign_discovery },
      None,
      "choir",
      ["goal_status"],
    )
    is Err(_),
  )
}
