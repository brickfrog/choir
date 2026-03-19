///|
test "translate tools/call to internal request" {
  let rpc : @mcp.JsonRpcRequest = {
    jsonrpc: "2.0",
    id: 1,
    req_method: method_tools_call,
    params: Some({ "name": "fork_wave", "task": "build feature" }),
  }
  let result = @mcp.to_internal_request(rpc, @types.Role::TL)
  match result {
    Ok(req) => {
      assert_eq(req.name, "fork_wave")
      assert_eq(req.role, @types.Role::TL)
    }
    Err(_) => fail("expected Ok")
  }
}

///|
test "translate tools/list to internal request" {
  let rpc : @mcp.JsonRpcRequest = {
    jsonrpc: "2.0",
    id: 2,
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
    id: 4,
    req_method: "unknown/method",
    params: None,
  }
  let result = @mcp.to_internal_request(rpc, @types.Role::TL)
  assert_true(result is Err(_))
}

///|
test "tools_list_response" {
  let rpc = @mcp.tools_list_response(20)
  assert_eq(rpc.id, 20)
  match rpc.result {
    Some(res) => {
      let tools = res.get("tools")
      assert_true(tools is Some(_))
      match tools {
        Some(t) => {
          assert_true(t.contains("fork_wave"))
          assert_true(t.contains("file_pr"))
          assert_true(t.contains("merge_pr"))
          assert_true(t.contains("notify_parent"))
          assert_true(t.contains("send_message"))
          assert_true(t.contains("spawn_gemini"))
          assert_true(t.contains("spawn_worker"))
          assert_true(t.contains("task_list"))
          assert_true(t.contains("task_get"))
          assert_true(t.contains("task_update"))
          assert_true(t.contains("shutdown"))
        }
        None => fail("expected tools")
      }
    }
    None => fail("expected result")
  }
}

///|
test "translate missing name returns error" {
  let rpc : @mcp.JsonRpcRequest = {
    jsonrpc: "2.0",
    id: 3,
    req_method: method_tools_call,
    params: Some({ "task": "something" }),
  }
  let result = @mcp.to_internal_request(rpc, @types.Role::Dev)
  assert_true(result is Err(_))
}

///|
test "from_internal_response Ok" {
  let resp = @types.Response::Ok({ "url": "https://github.com/pr/1" })
  let rpc = @mcp.from_internal_response(5, resp)
  assert_eq(rpc.jsonrpc, "2.0")
  assert_eq(rpc.id, 5)
  assert_true(rpc.result is Some(_))
  assert_true(rpc.error is None)
}

///|
test "from_internal_response Err" {
  let resp = @types.Response::Err("tool not found")
  let rpc = @mcp.from_internal_response(6, resp)
  assert_eq(rpc.id, 6)
  assert_true(rpc.result is None)
  match rpc.error {
    Some(e) => assert_eq(e.code, @mcp.err_internal)
    None => fail("expected error")
  }
}

///|
test "error_response" {
  let rpc = @mcp.error_response(7, @mcp.err_method_not_found, "no such method")
  assert_eq(rpc.id, 7)
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
  let resp = @types.Response::Ok({ "status": "ok" })
  let rpc = @mcp.from_internal_response(10, resp)
  let json = rpc.to_json_string()
  assert_true(json.contains("\"jsonrpc\":\"2.0\""))
  assert_true(json.contains("\"id\":10"))
  assert_true(json.contains("\"result\":{"))
  assert_true(json.contains("\"status\":\"ok\""))
}

///|
test "serialize error response" {
  let rpc = @mcp.error_response(11, -32603, "internal error")
  let json = rpc.to_json_string()
  assert_true(json.contains("\"jsonrpc\":\"2.0\""))
  assert_true(json.contains("\"id\":11"))
  assert_true(json.contains("\"error\":{"))
  assert_true(json.contains("\"code\":-32603"))
  assert_true(json.contains("\"message\":\"internal error\""))
}
