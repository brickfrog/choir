///|
test "parse_flat_json_object extracts string key-value pairs" {
  let m = parse_flat_json_object(
    "{\"key\":\"test\",\"value\":\"hello from claude\"}",
  )
  @debug.assert_eq(m.get("key"), Some("test"))
  @debug.assert_eq(m.get("value"), Some("hello from claude"))
}

///|
test "parse_flat_json_object unescapes newlines and quotes" {
  let m = parse_flat_json_object(
    "{\"task\":\"line one\\nline two\",\"note\":\"say \\\"hi\\\"\"}",
  )
  @debug.assert_eq(m.get("task"), Some("line one\nline two"))
  @debug.assert_eq(m.get("note"), Some("say \"hi\""))
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
  @debug.assert_eq(m.get("count"), Some("3"))
  @debug.assert_eq(m.get("enabled"), Some("true"))
  @debug.assert_eq(m.get("empty"), Some("null"))
}

///|
test "parse valid jsonrpc request with tools/call" {
  let line = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"echo\",\"arguments\":{\"text\":\"hello\"}}}"
  match parse_jsonrpc_request(line) {
    Ok(req) => {
      assert_eq(req.jsonrpc, "2.0")
      @debug.assert_eq(req.id, Some(Number(1)))
      assert_eq(req.req_method, "tools/call")
      match req.params {
        Some(Object(params)) =>
          match (params.get("name"), params.get("arguments")) {
            (Some(String(name)), Some(Object(arguments))) => {
              assert_eq(name, "echo")
              match arguments.get("text") {
                Some(String(text)) => assert_eq(text, "hello")
                _ => fail("missing text in arguments")
              }
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
    Ok(rpc) => @debug.assert_eq(rpc.id, None)
    Err(e) => fail("should have succeeded, got: \{e.message}")
  }
}

///|
test "parse request with string id" {
  let line = "{\"jsonrpc\":\"2.0\",\"id\":\"abc123\",\"method\":\"tools/call\",\"params\":{\"name\":\"echo\",\"arguments\":{\"text\":\"hello\"}}}"
  match parse_jsonrpc_request(line) {
    Ok(rpc) => @debug.assert_eq(rpc.id, Some(String("abc123")))
    Err(e) => fail("should have succeeded, got: \{e.message}")
  }
}

///|
test "translate numeric and boolean MCP arguments into internal string args" {
  let args : Map[String, Json] = {
    "task": "build feature".to_json(),
    "count": 3.0.to_json(),
    "fork_session": true.to_json(),
  }
  let params : Map[String, Json] = {
    "name": "fork_wave".to_json(),
    "arguments": args.to_json(),
  }
  let rpc : @mcp.JsonRpcRequest = {
    jsonrpc: "2.0",
    id: Some(Number(12)),
    req_method: method_tools_call,
    params: Some(params.to_json()),
  }
  let result = @mcp.to_internal_request(rpc, @types.Role::TL)
  match result {
    Ok(req) => {
      @debug.assert_eq(req.args.get("task"), Some("build feature"))
      @debug.assert_eq(req.args.get("count"), Some("3"))
      @debug.assert_eq(req.args.get("fork_session"), Some("true"))
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
test "response_to_bytes produces Content-Length framed result" {
  let resp : JsonRpcResponse = {
    jsonrpc: "2.0",
    id: Number(1),
    result: Some({ "status": "ok".to_json() }.to_json()),
    error: None,
  }
  let bytes = response_to_bytes(resp)
  let s = @utf8.decode_lossy(bytes)
  assert_true(s.has_prefix("Content-Length: "))
  assert_true(
    s.contains("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"status\":\"ok\"}}"),
  )
}
