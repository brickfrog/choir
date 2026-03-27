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
test "parse_request preserves primitive arg literals" {
  let input = "{\"method\":\"tools/call\",\"role\":\"tl\",\"name\":\"fork_wave\",\"args\":{\"count\":3,\"fork_session\":true,\"empty\":null}}"
  match parse_request(input) {
    Ok(req) => {
      assert_eq(req.args.get("count"), Some("3"))
      assert_eq(req.args.get("fork_session"), Some("true"))
      assert_eq(req.args.get("empty"), Some("null"))
      assert_eq(req.args.get_json("count"), Some((3).to_json()))
      assert_eq(req.args.get_json("fork_session"), Some(true.to_json()))
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
  let resp = @types.Response::ok(result)
  assert_true(resp.is_ok())
  assert_eq(resp.status_tag(), "ok")
  assert_eq(resp.ok_field("agent_id"), Some("main.feat-a"))
  let output = format_response(resp)
  // Json key order may vary, so check fields individually
  let json = @json.parse(output) catch {
    _ => {
      fail("invalid json")
      return
    }
  }
  guard json is Object(obj) else {
    fail("expected object")
    return
  }
  assert_eq(obj.get("ok"), Some(true.to_json()))
  guard obj.get("result") is Some(Object(res)) else {
    fail("expected result")
    return
  }
  assert_eq(res.get("agent_id"), Some("main.feat-a".to_json()))
}

///|
test "format_request serializes internal wire request" {
  let req : @types.Request = {
    req_method: "tools/call",
    role: @types.Role::TL,
    name: "fork_wave",
    args: @types.RequestArgs::from_values({
      "slug": "feat-a".to_json(),
      "count": (3).to_json(),
      "fork_session": true.to_json(),
    }),
  }
  let output = format_request(req)
  assert_true(output.contains("\"method\":\"tools/call\""))
  assert_true(output.contains("\"role\":\"tl\""))
  assert_true(output.contains("\"name\":\"fork_wave\""))
  assert_true(output.contains("\"slug\":\"feat-a\""))
  assert_true(output.contains("\"count\":3"))
  assert_true(output.contains("\"fork_session\":true"))
}

///|
test "format_registration_request includes local config metadata" {
  let local_cfg = @types.LocalConfig::{
    role: None,
    agent_id: None,
    parent_id: Some("root"),
    branch: Some("main.leaf-1"),
    parent_branch: Some("main"),
    workspace: Some("/tmp/leaf-1"),
    terminal_target: @types.LocalTarget::parse("zellij-tab:choir:leaf-1"),
    agent_type: Some(@types.AgentType::Gemini),
    spawn_depth: Some(1),
  }
  let output = format_registration_request(
    @types.Role::Dev,
    "leaf-1",
    local_cfg,
  )
  assert_true(output.contains("\"name\":\"register\""))
  assert_true(output.contains("\"agent_id\":\"leaf-1\""))
  assert_true(output.contains("\"parent_id\":\"root\""))
  assert_true(output.contains("\"branch\":\"main.leaf-1\""))
  assert_true(output.contains("\"agent_type\":\"gemini\""))
  assert_true(
    output.contains("\"terminal_target\":\"zellij-tab:choir:leaf-1\""),
  )
  assert_true(output.contains("\"spawn_depth\":\"1\""))
}

///|
test "format_augmented_request adds caller and sender defaults" {
  let req : @types.Request = {
    req_method: "tools/call",
    role: @types.Role::Dev,
    name: "send_message",
    args: @types.RequestArgs::new({ "target_id": "leaf-2", "message": "hello" }),
  }
  let local_cfg = @types.LocalConfig::default()
  let output = format_augmented_request(req, "leaf-1", local_cfg)
  assert_true(output.contains("\"caller_id\":\"leaf-1\""))
  assert_true(output.contains("\"sender_id\":\"leaf-1\""))
}

///|
test "format_response escaping" {
  let result = Map::new()
  result.set("message", "hello \"quoted\" world")
  let resp = @types.Response::ok(result)
  let output = format_response(resp)
  assert_true(output.contains("hello \\\"quoted\\\" world"))
}

///|
test "format_response err" {
  let resp = @types.Response::Err("agent not found")
  assert_false(resp.is_ok())
  assert_eq(resp.status_tag(), "error")
  assert_eq(resp.error_message(), Some("agent not found"))
  let output = format_response(resp)
  let json = @json.parse(output) catch {
    _ => {
      fail("invalid json")
      return
    }
  }
  guard json is Object(obj) else {
    fail("expected object")
    return
  }
  assert_eq(obj.get("ok"), Some(false.to_json()))
  assert_eq(obj.get("error"), Some("agent not found".to_json()))
}

///|
test "parse_response preserves primitive result values" {
  let input = "{\"ok\": true, \"result\": {\"status\":\"ok\",\"tracked\":true,\"pr_number\":22}}"
  match parse_response(input) {
    Ok(resp) => {
      assert_eq(resp.ok_field("status"), Some("ok"))
      match resp.ok_payload() {
        Some(fields) => {
          assert_eq(fields.get_json("tracked"), Some(true.to_json()))
          assert_eq(fields.get_json("pr_number"), Some((22).to_json()))
        }
        None => fail("expected payload")
      }
    }
    Err(e) => fail("Parse failed: \{e}")
  }
}
