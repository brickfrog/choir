///|
test "parse_request success" {
  let input = "{\"method\": \"tools/call\", \"role\": \"tl\", \"name\": \"fork_wave\", \"args\": {\"slug\": \"feat-a\", \"count\": \"3\"}}"
  match parse_request(input) {
    Ok(req) => {
      assert_eq(req.req_method, "tools/call")
      assert_eq(req.role, @types.Role::TL)
      assert_eq(req.name, "fork_wave")
      assert_eq(req.args.get("slug"), Some("feat-a"))
      assert_eq(req.args.get("count"), Some("3"))
    }
    Err(e) => fail("Parse failed: \{e}")
  }
}

///|
test "parse_request whitespace tolerance" {
  let input = " {  \"method\"  :  \"tools/call\" , \"role\":\"dev\" , \"name\" : \"test\" , \"args\" : { \"k\" : \"v\" } } "
  match parse_request(input) {
    Ok(req) => {
      assert_eq(req.req_method, "tools/call")
      assert_eq(req.role, @types.Role::Dev)
      assert_eq(req.name, "test")
      assert_eq(req.args.get("k"), Some("v"))
    }
    Err(e) => fail("Parse failed: \{e}")
  }
}

///|
test "parse_args with commas and colons in values" {
  let input = "{\"method\":\"call\",\"role\":\"tl\",\"name\":\"test\",\"args\":{\"msg\":\"hello, world: how are you?\",\"key\":\"val\"}}"
  match parse_request(input) {
    Ok(req) => {
      assert_eq(req.args.get("msg"), Some("hello, world: how are you?"))
      assert_eq(req.args.get("key"), Some("val"))
    }
    Err(e) => fail("Parse failed: \{e}")
  }
}

///|
test "parse_request missing field" {
  let input = "{\"role\": \"tl\", \"name\": \"fork_wave\", \"args\": {}}"
  match parse_request(input) {
    Ok(_) => fail("Should have failed")
    Err(e) => assert_eq(e, "missing field: method")
  }
}

///|
test "parse_request invalid role" {
  let input = "{\"method\": \"tools/call\", \"role\": \"invalid\", \"name\": \"fork_wave\", \"args\": {}}"
  match parse_request(input) {
    Ok(_) => fail("Should have failed")
    Err(e) => assert_eq(e, "invalid role: invalid")
  }
}

///|
test "format_response ok" {
  let result = Map::new()
  result.set("agent_id", "main.feat-a")
  let resp = @types.Response::Ok(result)
  let output = format_response(resp)
  assert_eq(
    output, "{\"ok\": true, \"result\": {\"agent_id\": \"main.feat-a\"}}",
  )
}

///|
test "format_response escaping" {
  let result = Map::new()
  result.set("message", "hello \"quoted\" world")
  let resp = @types.Response::Ok(result)
  let output = format_response(resp)
  assert_eq(
    output, "{\"ok\": true, \"result\": {\"message\": \"hello \\\"quoted\\\" world\"}}",
  )
}

///|
test "format_response err" {
  let resp = @types.Response::Err("agent not found")
  let output = format_response(resp)
  assert_eq(output, "{\"ok\": false, \"error\": \"agent not found\"}")
}
