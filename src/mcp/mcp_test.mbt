///|
test "Conductor tools/call preserves arguments and verified caller" {
  let arguments : Map[String, Json] = {
    "goal_id": "goal-a".to_json(),
    "action": "set_concurrency".to_json(),
    "maximum_parallel_parts": "3".to_json(),
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
  match
    @mcp.to_internal_request(
      rpc,
      @types.Role::TL,
      default_caller_id=Some("root"),
    ) {
    Ok(request) => {
      assert_eq(request.name, "goal_steer")
      @debug.assert_eq(request.args.get("goal_id"), Some("goal-a"))
      @debug.assert_eq(request.args.get("maximum_parallel_parts"), Some("3"))
      @debug.assert_eq(request.args.get("caller_id"), Some("root"))
    }
    Err(error) => fail("expected request: " + error.message)
  }
}

///|
test "Conductor translation rejects removed commands and stringified arguments" {
  let empty_arguments : Map[String, Json] = Map([])
  let removed_params : Map[String, Json] = {
    "name": "fork_wave".to_json(),
    "arguments": empty_arguments.to_json(),
  }
  let removed_request : @mcp.JsonRpcRequest = {
    jsonrpc: "2.0",
    id: Some(Number(2)),
    req_method: method_tools_call,
    params: Some(removed_params.to_json()),
  }
  match @mcp.to_internal_request(removed_request, @types.Role::TL) {
    Err(error) => assert_eq(error.code, err_method_not_found)
    Ok(_) => fail("removed command must not translate")
  }
  let stringified_params : Map[String, Json] = {
    "name": "goal_status".to_json(),
    "arguments": "{\"goal_id\":\"goal-a\"}".to_json(),
  }
  let stringified_request : @mcp.JsonRpcRequest = {
    ..removed_request,
    params: Some(stringified_params.to_json()),
  }
  match @mcp.to_internal_request(stringified_request, @types.Role::TL) {
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
  let response = @mcp.tools_list_response(Number(20), @types.Role::TL)
  guard response.result is Some(Object(result)) else {
    fail("expected catalog response")
  }
  guard result.get("tools") is Some(Array(tools)) else {
    fail("expected tools array")
  }
  assert_eq(tools.length(), 10)
  let rendered = tools.to_json().stringify()
  assert_true(rendered.contains("goal_submit"))
  assert_true(rendered.contains("maximum_parallel_parts"))
  assert_true(rendered.contains("task_create"))
  assert_false(rendered.contains("fork_wave"))
  assert_false(rendered.contains("spawn_worker"))
  assert_false(rendered.contains("file_pr"))
  assert_false(rendered.contains("server_reload"))
}

///|
test "non-Conductor roles receive no tool catalog" {
  let response = @mcp.tools_list_response(Number(22), @types.Role::Dev)
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
  assert_false(instructions.contains("fork_wave"))
  assert_false(instructions.contains("merge_pr"))
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
