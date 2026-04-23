///|
test "translate tools/call to internal request" {
  let params : Map[String, Json] = {
    "name": "fork_wave".to_json(),
    "arguments": { "task": "build feature".to_json() }.to_json(),
  }
  let rpc : @mcp.JsonRpcRequest = {
    jsonrpc: "2.0",
    id: Some(Number(1)),
    req_method: method_tools_call,
    params: Some(params.to_json()),
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
test "translate tools/list returns unsupported method error" {
  // mcp_mode.mbt handles tools/list before calling to_internal_request;
  // if it somehow falls through, to_internal_request returns an error.
  let rpc : @mcp.JsonRpcRequest = {
    jsonrpc: "2.0",
    id: Some(Number(2)),
    req_method: method_tools_list,
    params: None,
  }
  let result = @mcp.to_internal_request(rpc, @types.Role::TL)
  match result {
    Err(e) => assert_true(e.message.contains("unsupported method"))
    Ok(_) => fail("expected Err")
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
  let rpc = @mcp.tools_list_response(Number(20), @types.Role::TL)
  assert_eq(rpc.id, Number(20))
  match rpc.result {
    Some(Object(res)) =>
      match res.get("tools") {
        Some(Array(tools)) => {
          let t = tools.to_json().stringify()
          assert_true(t.contains("fork_wave"))
          assert_true(t.contains("file_pr"))
          assert_true(t.contains("merge_pr"))
          assert_true(t.contains("track_pr"))
          assert_true(t.contains("notify_parent"))
          assert_true(t.contains("send_message"))
          assert_true(t.contains("fork_wave"))
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
          assert_true(t.contains("\"id\""))
          assert_true(t.contains("\"id\""))
          assert_true(t.contains("caller_id"))
          assert_true(t.contains("shutdown"))
          assert_true(t.contains("dev leaves") || t.contains("sub-team-lead"))
          assert_true(t.contains("agent_type"))
          assert_true(t.contains("tasks"))
          assert_true(t.contains("per-leaf task"))
          assert_true(t.contains("research/review"))
          assert_true(t.contains("automerge"))
          assert_true(t.contains("wave_state"))
          assert_true(t.contains("merge_gate_ready"))
        }
        _ => fail("expected tools array")
      }
    None => fail("expected result")
    Some(_) => fail("expected object result")
  }
}

///|
test "tools_list_response dev role includes file_pr" {
  let rpc = @mcp.tools_list_response(Number(22), @types.Role::Dev)
  match rpc.result {
    Some(Object(res)) =>
      match res.get("tools") {
        Some(Array(tools)) => {
          let t = tools.to_json().stringify()
          assert_true(t.contains("file_pr"))
        }
        _ => fail("expected tools array")
      }
    None => fail("expected result")
    Some(_) => fail("expected object result")
  }
}

///|
test "initialize_response instructions forbid parent branch implementation during leaf mode" {
  let rpc = @mcp.initialize_response(Number(21))
  match rpc.result {
    Some(Object(result)) =>
      match result.get("instructions") {
        Some(String(instructions)) => {
          assert_true(
            instructions.contains(
              "do not implement the feature directly on the parent branch",
            ),
          )
          assert_true(instructions.contains("choir tl-parent-override on"))
          assert_true(
            instructions.contains(
              "kill that leaf immediately and close or abandon its PR",
            ),
          )
        }
        _ => fail("expected instructions string")
      }
    _ => fail("expected initialize result object")
  }
}

///|
test "translate missing name returns error" {
  let rpc : @mcp.JsonRpcRequest = {
    jsonrpc: "2.0",
    id: Some(Number(3)),
    req_method: method_tools_call,
    params: Some({ "task": "something".to_json() }.to_json()),
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
  match rpc.result {
    Some(Object(result)) =>
      match result.get("structuredContent") {
        Some(Object(structured)) =>
          match structured.get("url") {
            Some(String(url)) => assert_eq(url, "https://github.com/pr/1")
            _ => fail("expected structured url")
          }
        _ => fail("expected structuredContent object")
      }
    _ => fail("expected object result")
  }
  assert_true(rpc.error is None)
}

///|
test "from_internal_response preserves raw primitives" {
  let resp = @types.Response::ok_values({
    "tracked": true.to_json(),
    "pr_number": 22.0.to_json(),
  })
  let rpc = @mcp.from_internal_response(Number(55), resp)
  match rpc.result {
    Some(Object(result)) => {
      match result.get("content") {
        Some(Array(content_arr)) => {
          let content = content_arr.to_json().stringify()
          assert_true(content.contains("tracked"))
          assert_true(content.contains("true"))
          assert_true(content.contains("pr_number"))
          assert_true(content.contains("22"))
        }
        _ => fail("expected content array")
      }
      match result.get("structuredContent") {
        Some(Object(structured)) => {
          match structured.get("tracked") {
            Some(True) => ()
            _ => fail("expected structured tracked true")
          }
          match structured.get("pr_number") {
            Some(Number(n, ..)) => assert_eq(n.to_int(), 22)
            _ => fail("expected structured pr_number 22")
          }
        }
        _ => fail("expected structuredContent")
      }
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
    Some(Object(result)) => {
      match result.get("isError") {
        Some(True) => ()
        _ => fail("expected isError true")
      }
      match result.get("content") {
        Some(Array(content_arr)) => {
          let content = content_arr.to_json().stringify()
          assert_true(content.contains("tool not found"))
        }
        _ => fail("expected content")
      }
      match result.get("structuredContent") {
        Some(Object(structured)) =>
          match structured.get("error") {
            Some(String(msg)) => assert_eq(msg, "tool not found")
            _ => fail("expected structured error message")
          }
        _ => fail("expected structuredContent")
      }
    }
    None => fail("expected result")
    Some(_) => fail("expected object result")
  }
}

///|
test "initialize MCP instructions forbid premature merge claims" {
  let rpc = @mcp.initialize_response(Number(21))
  match rpc.result {
    Some(Object(res)) =>
      match res.get("instructions") {
        Some(String(s)) => {
          assert_true(s.contains("[PR READY]"))
          assert_true(s.contains("[FIXES PUSHED]"))
          assert_true(s.contains("merge_pr"))
          assert_true(s.contains("[PR MERGED]"))
          assert_true(s.contains("directly verified"))
        }
        _ => fail("expected instructions string")
      }
    _ => fail("expected initialize result")
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
  assert_true(json.contains("\"structuredContent\""))
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
