///|
test "translate tools/call to internal request" {
  let rpc : @mcp.JsonRpcRequest = {
    jsonrpc: "2.0",
    id: Some(Number(1)),
    req_method: method_tools_call,
    params: Some(
      @mcp.JsonValue::Object({
        "name": @mcp.JsonValue::String("fork_wave"),
        "arguments": @mcp.JsonValue::Raw("{\"task\":\"build feature\"}"),
      }),
    ),
  }
  let result = @mcp.to_internal_request(rpc, @types.Role::TL)
  match result {
    Ok(req) => {
      assert_eq(req.name, "fork_wave")
      assert_eq(req.role, @types.Role::TL)
      assert_eq(req.args.get("task"), Some("build feature"))
    }
    Err(_) => fail("expected Ok")
  }
}

///|
test "translate tools/list to internal request" {
  let rpc : @mcp.JsonRpcRequest = {
    jsonrpc: "2.0",
    id: Some(Number(2)),
    req_method: method_tools_list,
    params: None,
  }
  let result = @mcp.to_internal_request(rpc, @types.Role::TL)
  match result {
    Ok(req) => {
      assert_eq(req.req_method, "tools/list")
      assert_eq(req.name, "tools_list")
      assert_eq(req.role, @types.Role::TL)
    }
    Err(_) => fail("expected Ok")
  }
}

///|
test "translate unknown method returns error" {
  let rpc : @mcp.JsonRpcRequest = {
    jsonrpc: "2.0",
    id: Some(Number(4)),
    req_method: "unknown/method",
    params: None,
  }
  let result = @mcp.to_internal_request(rpc, @types.Role::TL)
  assert_true(result is Err(_))
}

///|
test "tools_list_response" {
  let rpc = @mcp.tools_list_response(Number(20))
  assert_eq(rpc.id, Number(20))
  match rpc.result {
    Some(@mcp.JsonValue::Object(res)) =>
      match res.get("tools") {
        Some(@mcp.JsonValue::Raw(t)) => {
          assert_true(t.contains("fork_wave"))
          assert_true(t.contains("file_pr"))
          assert_true(t.contains("merge_pr"))
          assert_true(t.contains("track_pr"))
          assert_true(t.contains("notify_parent"))
          assert_true(t.contains("send_message"))
          assert_true(t.contains("spawn_gemini"))
          assert_true(t.contains("spawn_moon_pilot"))
          assert_true(t.contains("spawn_worker"))
          assert_true(t.contains("read_first"))
          assert_true(t.contains("done_criteria"))
          assert_true(t.contains("key_decisions"))
          assert_true(t.contains("agent_id"))
          assert_true(t.contains("pr_url"))
          assert_true(t.contains("parent_branch"))
          assert_true(t.contains("kv_get"))
          assert_true(t.contains("kv_set"))
          assert_true(t.contains("kv_delete"))
          assert_true(t.contains("mutex_acquire"))
          assert_true(t.contains("mutex_release"))
          assert_true(t.contains("mutex_status"))
          assert_true(t.contains("task_list"))
          assert_true(t.contains("task_get"))
          assert_true(t.contains("task_update"))
          assert_true(t.contains("\"id\",\"title\""))
          assert_true(t.contains("\"id\""))
          assert_true(t.contains("caller_id"))
          assert_true(t.contains("shutdown"))
        }
        _ => fail("expected raw tools json")
      }
    None => fail("expected result")
    Some(_) => fail("expected object result")
  }
}

///|
test "translate missing name returns error" {
  let rpc : @mcp.JsonRpcRequest = {
    jsonrpc: "2.0",
    id: Some(Number(3)),
    req_method: method_tools_call,
    params: Some(
      @mcp.JsonValue::Object({ "task": @mcp.JsonValue::String("something") }),
    ),
  }
  let result = @mcp.to_internal_request(rpc, @types.Role::Dev)
  assert_true(result is Err(_))
}

///|
test "from_internal_response Ok" {
  let resp = @types.Response::ok({ "url": "https://github.com/pr/1" })
  assert_eq(resp.ok_field("url"), Some("https://github.com/pr/1"))
  let rpc = @mcp.from_internal_response(Number(5), resp)
  assert_eq(rpc.jsonrpc, "2.0")
  assert_eq(rpc.id, Number(5))
  assert_true(rpc.result is Some(_))
  assert_true(rpc.error is None)
}

///|
test "from_internal_response preserves raw primitives" {
  let resp = @types.Response::ok_values({
    "tracked": @types.WireValue::Raw("true"),
    "pr_number": @types.WireValue::Raw("22"),
  })
  let rpc = @mcp.from_internal_response(Number(55), resp)
  match rpc.result {
    Some(@mcp.JsonValue::Object(result)) =>
      match result.get("content") {
        Some(@mcp.JsonValue::Raw(content)) => {
          assert_true(content.contains("\\\"tracked\\\":true"))
          assert_true(content.contains("\\\"pr_number\\\":22"))
        }
        _ => fail("expected raw content")
      }
    _ => fail("expected object result")
  }
}

///|
test "from_internal_response Err" {
  let resp = @types.Response::Err("tool not found")
  assert_eq(resp.error_message(), Some("tool not found"))
  let rpc = @mcp.from_internal_response(Number(6), resp)
  assert_eq(rpc.id, Number(6))
  assert_true(rpc.error is None)
  match rpc.result {
    Some(@mcp.JsonValue::Object(result)) => {
      match result.get("isError") {
        Some(@mcp.JsonValue::Raw(value)) => assert_eq(value, "true")
        _ => fail("expected isError raw bool")
      }
      match result.get("content") {
        Some(@mcp.JsonValue::Raw(content)) =>
          assert_true(content.contains("tool not found"))
        _ => fail("expected content")
      }
    }
    None => fail("expected result")
    Some(_) => fail("expected object result")
  }
}

///|
test "error_response" {
  let rpc = @mcp.error_response(
    Number(7),
    @mcp.err_method_not_found,
    "no such method",
  )
  assert_eq(rpc.id, Number(7))
  match rpc.error {
    Some(e) => {
      assert_eq(e.code, -32601)
      assert_eq(e.message, "no such method")
    }
    None => fail("expected error")
  }
}

///|
test "serialize successful response" {
  let resp = @types.Response::ok({ "status": "ok" })
  let rpc = @mcp.from_internal_response(Number(10), resp)
  let json = rpc.to_json_string()
  assert_true(json.contains("\"jsonrpc\":\"2.0\""))
  assert_true(json.contains("\"id\":10"))
  assert_true(json.contains("\"result\":{"))
  assert_true(json.contains("\"content\""))
  assert_true(json.contains("status"))
  assert_true(json.contains("isError"))
}

///|
test "serialize error response" {
  let rpc = @mcp.error_response(Number(11), -32603, "internal error")
  let json = rpc.to_json_string()
  assert_true(json.contains("\"jsonrpc\":\"2.0\""))
  assert_true(json.contains("\"id\":11"))
  assert_true(json.contains("\"error\":{"))
  assert_true(json.contains("\"code\":-32603"))
  assert_true(json.contains("\"message\":\"internal error\""))
}
