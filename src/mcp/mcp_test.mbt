///|
test "Conductor tools/call preserves structured arguments" {
  let arguments : Map[String, Json] = {
    "goal_id": "goal-a".to_json(),
    "action": "set_concurrency".to_json(),
    "maximum_parallel_parts": (3).to_json(),
  }
  let params : Map[String, Json] = {
    "name": "goal_steer".to_json(),
    "arguments": arguments.to_json(),
  }
  let rpc : @mcp.JsonRpcRequest = {
    jsonrpc: "2.0",
    id: Some(Number(1)),
    req_method: method_tools_call,
    params: Some(params.to_json()),
  }
  match @mcp.to_internal_request(rpc) {
    Ok(request) => {
      assert_eq(request.name, "goal_steer")
      @debug.assert_eq(request.args.get("goal_id"), Some("goal-a"))
      @debug.assert_eq(request.args.get_int("maximum_parallel_parts"), Some(3))
      @debug.assert_eq(request.args.get("caller_id"), None)
    }
    Err(error) => fail("expected request: " + error.message)
  }
}

///|
test "Conductor translation rejects stringified arguments" {
  let stringified_params : Map[String, Json] = {
    "name": "goal_status".to_json(),
    "arguments": "{\"goal_id\":\"goal-a\"}".to_json(),
  }
  let stringified_request : @mcp.JsonRpcRequest = {
    jsonrpc: "2.0",
    id: Some(Number(2)),
    req_method: method_tools_call,
    params: Some(stringified_params.to_json()),
  }
  match @mcp.to_internal_request(stringified_request) {
    Err(error) => assert_eq(error.code, err_invalid_params)
    Ok(_) => fail("stringified arguments must not translate")
  }
}

///|
test "Conductor catalog exposes only Goal and Beads operations" {
  assert_eq(@mcp.conductor_tool_names(), [
    "goal_submit", "goal_status", "goal_cancel", "goal_steer", "goal_attach", "goal_answer",
    "task_list", "task_get", "task_create", "task_update",
  ])
  let response = @mcp.tools_list_response(Number(20), true)
  guard response.result is Some(Object(result)) else {
    fail("expected catalog response")
  }
  guard result.get("tools") is Some(Array(tools)) else {
    fail("expected tools array")
  }
  assert_eq(tools.length(), 10)
  let mut goal_submit_schema : Json? = None
  for tool in tools {
    guard tool is Object(fields) else { continue }
    if fields.get("name") == Some("goal_submit".to_json()) {
      goal_submit_schema = fields.get("inputSchema")
    }
  }
  guard goal_submit_schema is Some(Object(goal_submit)) else {
    fail("expected goal_submit schema")
  }
  guard goal_submit.get("properties") is Some(Object(goal_properties)) else {
    fail("expected goal_submit properties")
  }
  assert_eq(goal_properties.get("goal_id"), None)
  assert_eq(
    goal_submit.get("required"),
    Some([
      "proposal_id", "maximum_parallel_parts", "parts",
    ].to_json()),
  )
  let rendered = tools.to_json().stringify()
  assert_true(rendered.contains("goal_submit"))
  assert_true(rendered.contains("maximum_parallel_parts"))
  assert_true(rendered.contains("\"parts\""))
  assert_true(rendered.contains("\"moon_args\""))
  assert_true(rendered.contains("\"provider\""))
  assert_true(rendered.contains("\"enum\":[\"codex\",\"claude\"]"))
  assert_true(rendered.contains("\"default\":\"codex\""))
  assert_true(rendered.contains("never authorizes an automatic retry"))
  assert_true(rendered.contains("consumes the request's one mutation allowance"))
  assert_true(rendered.contains("never call goal_submit a second time"))
  assert_true(rendered.contains("diagnose a rejection with Bash or the CLI"))
  assert_true(rendered.contains("selected Part IDs are Bead IDs"))
  assert_true(rendered.contains("securely mints and returns"))
  assert_true(rendered.contains("pushes later durable state transitions"))
  assert_true(
    rendered.contains("Background transitions arrive through the Choir channel"),
  )
  assert_false(rendered.contains("automatic_polling_allowed"))
  assert_false(rendered.contains("conductor_objective_complete"))
  assert_true(rendered.contains("Never create a defect Bead"))
  assert_true(rendered.contains("task_create"))
  assert_true(rendered.contains("goal_answer"))
  assert_false(rendered.contains("draft_json"))
}

///|
test "Conductor can relay one explicit Goal input answer" {
  let arguments : Map[String, Json] = {
    "request_id": "request-a".to_json(),
    "answer": "invented by the Conductor".to_json(),
  }
  let params : Map[String, Json] = {
    "name": "goal_answer".to_json(),
    "arguments": arguments.to_json(),
  }
  let rpc : @mcp.JsonRpcRequest = {
    jsonrpc: "2.0",
    id: Some(Number(23)),
    req_method: method_tools_call,
    params: Some(params.to_json()),
  }
  match @mcp.to_internal_request(rpc) {
    Ok(request) => {
      assert_eq(request.name, "goal_answer")
      @debug.assert_eq(request.args.get("request_id"), Some("request-a"))
      @debug.assert_eq(
        request.args.get("answer"),
        Some("invented by the Conductor"),
      )
    }
    Err(error) => fail("expected Goal answer request: " + error.message)
  }
}

///|
test "unauthenticated clients receive no tool catalog" {
  let response = @mcp.tools_list_response(Number(22), false)
  guard response.result is Some(Object(result)) else {
    fail("expected catalog response")
  }
  let empty_tools : Array[Json] = []
  @debug.assert_eq(result.get("tools"), Some(empty_tools.to_json()))
}

///|
test "initialize response reserves workflow authority for choird" {
  let response = @mcp.initialize_response(Number(21))
  guard response.result is Some(Object(result)) else {
    fail("expected initialize result")
  }
  guard result.get("instructions") is Some(String(instructions)) else {
    fail("expected instructions")
  }
  assert_true(instructions.contains("Choir's Conductor"))
  assert_true(
    instructions.contains("choird remains the sole workflow authority"),
  )
  assert_true(instructions.contains("use Beads to preserve intended work"))
  assert_true(instructions.contains("Do not execute a Part yourself"))
}

///|
test "channel initialize response declares Claude inbound push capability" {
  let response = @mcp.initialize_response(Number(22), channel=true)
  guard response.result is Some(Object(result)) else {
    fail("expected initialize result")
  }
  guard result.get("capabilities") is Some(Object(capabilities)) else {
    fail("expected capabilities")
  }
  assert_eq(
    capabilities.get("experimental"),
    Some({ "claude/channel": Json::empty_object() }.to_json()),
  )
  let notification = @mcp.channel_notification("Goal advanced", {
    "goal_id": "goal-a",
  })
  assert_true(
    notification.contains("\"method\":\"notifications/claude/channel\""),
  )
  assert_true(notification.contains("\"goal_id\":\"goal-a\""))
}

///|
test "internal responses preserve structured content" {
  let response = @mcp.from_internal_response(
    Number(3),
    @types.Response::ok_values({ "goal_id": "goal-a".to_json() }),
  )
  guard response.result is Some(Object(result)) else {
    fail("expected response result")
  }
  assert_eq(result.get("isError"), Some(false.to_json()))
  guard result.get("structuredContent") is Some(Object(content)) else {
    fail("expected structured content")
  }
  assert_eq(content.get("goal_id"), Some("goal-a".to_json()))
}
