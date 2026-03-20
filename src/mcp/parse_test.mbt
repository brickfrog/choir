///|
test "parse_flat_json_object extracts string key-value pairs" {
  let m = parse_flat_json_object(
    "{\"key\":\"test\",\"value\":\"hello from claude\"}",
  )
  assert_eq(m.get("key"), Some("test"))
  assert_eq(m.get("value"), Some("hello from claude"))
}

///|
test "parse_flat_json_object unescapes newlines and quotes" {
  let m = parse_flat_json_object(
    "{\"task\":\"line one\\nline two\",\"note\":\"say \\\"hi\\\"\"}",
  )
  assert_eq(m.get("task"), Some("line one\nline two"))
  assert_eq(m.get("note"), Some("say \"hi\""))
}

///|
test "parse_flat_json_object empty object" {
  let m = parse_flat_json_object("{}")
  assert_eq(m.length(), 0)
}

///|
test "parse_flat_json_object preserves primitive literals as strings" {
  let m = parse_flat_json_object(
    "{\"count\":3,\"enabled\":true,\"empty\":null}",
  )
  assert_eq(m.get("count"), Some("3"))
  assert_eq(m.get("enabled"), Some("true"))
  assert_eq(m.get("empty"), Some("null"))
}

///|
test "parse valid jsonrpc request with tools/call" {
  let line = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"echo\",\"arguments\":{\"text\":\"hello\"}}}"
  match parse_jsonrpc_request(line) {
    Ok(req) => {
      assert_eq(req.jsonrpc, "2.0")
      assert_eq(req.id, Some(Number(1)))
      assert_eq(req.req_method, "tools/call")
      match req.params {
        Some(@mcp.JsonValue::Object(params)) =>
          match (params.get("name"), params.get("arguments")) {
            (
              Some(@mcp.JsonValue::String(name)),
              Some(@mcp.JsonValue::Raw(arguments)),
            ) => {
              assert_eq(name, "echo")
              assert_eq(arguments, "{\"text\":\"hello\"}")
            }
            _ => fail("missing params")
          }
        None => fail("missing params")
        Some(_) => fail("expected object params")
      }
    }
    Err(e) => fail("parse failed: " + e.message)
  }
}

///|
test "parse request with missing id returns notification (id=-1)" {
  let line = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}"
  match parse_jsonrpc_request(line) {
    Ok(rpc) => assert_eq(rpc.id, None)
    Err(e) => fail("should have succeeded, got: \{e.message}")
  }
}

///|
test "parse request with string id" {
  let line = "{\"jsonrpc\":\"2.0\",\"id\":\"abc123\",\"method\":\"tools/call\",\"params\":{\"name\":\"echo\",\"arguments\":{\"text\":\"hello\"}}}"
  match parse_jsonrpc_request(line) {
    Ok(rpc) => assert_eq(rpc.id, Some(String("abc123")))
    Err(e) => fail("should have succeeded, got: \{e.message}")
  }
}

///|
test "translate numeric and boolean MCP arguments into internal string args" {
  let rpc : @mcp.JsonRpcRequest = {
    jsonrpc: "2.0",
    id: Some(Number(12)),
    req_method: method_tools_call,
    params: Some(
      @mcp.JsonValue::Object({
        "name": @mcp.JsonValue::String("fork_wave"),
        "arguments": @mcp.JsonValue::Raw(
          "{\"task\":\"build feature\",\"count\":3,\"fork_session\":true}",
        ),
      }),
    ),
  }
  let result = @mcp.to_internal_request(rpc, @types.Role::TL)
  match result {
    Ok(req) => {
      assert_eq(req.args.get("task"), Some("build feature"))
      assert_eq(req.args.get("count"), Some("3"))
      assert_eq(req.args.get("fork_session"), Some("true"))
    }
    Err(e) => fail("expected Ok, got: " + e.message)
  }
}

///|
test "parse request with missing method returns error" {
  let line = "{\"jsonrpc\":\"2.0\",\"id\":1}"
  match parse_jsonrpc_request(line) {
    Ok(_) => fail("should have failed")
    Err(e) => assert_eq(e.code, err_invalid_params)
  }
}

///|
test "read_line_from_bytes with complete line" {
  let s = "line1\nline2"
  let buf = @utf8.encode(s)
  match read_line_from_bytes(buf, 0) {
    Some((line, offset)) => {
      assert_eq(line, "line1")
      // offset might be different depending on UTF-8/UTF-16
      match read_line_from_bytes(buf, offset) {
        Some((line2, _)) => assert_eq(line2, "line2")
        None => () // ok for this test
      }
    }
    None => fail("should have read line1")
  }
}

///|
test "read_line_from_bytes with incomplete line returns None" {
  let s = "incomplete"
  let buf = @utf8.encode(s)
  match read_line_from_bytes(buf, 0) {
    Some(_) => fail("should be None")
    None => ()
  }
}

///|
test "read_line_from_bytes with multiple lines returns first" {
  let s = "line1\nline2\n"
  let buf = @utf8.encode(s)
  match read_line_from_bytes(buf, 0) {
    Some((line, offset)) => {
      assert_eq(line, "line1")
      match read_line_from_bytes(buf, offset) {
        Some((line2, _)) => assert_eq(line2, "line2")
        None => fail("should have read line2")
      }
    }
    None => fail("should have read line1")
  }
}

///|
test "response_to_bytes produces valid result" {
  let resp : JsonRpcResponse = {
    jsonrpc: "2.0",
    id: Number(1),
    result: Some(
      @mcp.JsonValue::Object({ "status": @mcp.JsonValue::String("ok") }),
    ),
    error: None,
  }
  let bytes = response_to_bytes(resp)
  match read_line_from_bytes(bytes, 0) {
    Some((line, _)) =>
      assert_eq(
        line, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"status\":\"ok\"}}",
      )
    None => fail("should have read line")
  }
}
