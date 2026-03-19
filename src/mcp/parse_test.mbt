///|
test "parse valid jsonrpc request with tools/call" {
  let line = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"echo\",\"arguments\":{\"text\":\"hello\"}}}"
  match parse_jsonrpc_request(line) {
    Ok(req) => {
      assert_eq(req.jsonrpc, "2.0")
      assert_eq(req.id, 1)
      assert_eq(req.req_method, "tools/call")
      match req.params {
        Some(params) => {
          assert_eq(params.get("name"), Some("echo"))
          assert_eq(params.get("arguments"), Some("{\"text\":\"hello\"}"))
        }
        None => fail("missing params")
      }
    }
    Err(e) => fail("parse failed: " + e.message)
  }
}

///|
test "parse request with missing id returns notification (id=-1)" {
  let line = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}"
  match parse_jsonrpc_request(line) {
    Ok(rpc) => assert_eq(rpc.id, -1)
    Err(e) => fail("should have succeeded, got: \{e.message}")
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
    id: 1,
    result: Some({ "status": "ok" }),
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
