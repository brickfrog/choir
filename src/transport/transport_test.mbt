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
test "parse_request preserves primitive arg literals as strings" {
  let input = "{\"method\":\"tools/call\",\"role\":\"tl\",\"name\":\"fork_wave\",\"args\":{\"count\":3,\"fork_session\":true,\"empty\":null}}"
  match parse_request(input) {
    Ok(req) => {
      assert_eq(req.args.get("count"), Some("3"))
      assert_eq(req.args.get("fork_session"), Some("true"))
      assert_eq(req.args.get("empty"), Some("null"))
      assert_eq(req.args.get_value("count"), Some(@types.WireValue::Raw("3")))
      assert_eq(
        req.args.get_value("fork_session"),
        Some(@types.WireValue::Raw("true")),
      )
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
  assert_eq(
    output, "{\"ok\": true, \"result\": {\"agent_id\": \"main.feat-a\"}}",
  )
}

///|
test "format_request serializes internal wire request" {
  let req : @types.Request = {
    req_method: "tools/call",
    role: @types.Role::TL,
    name: "fork_wave",
    args: @types.RequestArgs::from_values({
      "slug": @types.WireValue::String("feat-a"),
      "count": @types.WireValue::Raw("3"),
      "fork_session": @types.WireValue::Raw("true"),
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
    tmux_target: Some("choir:leaf-1"),
    agent_type: Some(@types.AgentType::Gemini),
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
  assert_eq(
    output, "{\"ok\": true, \"result\": {\"message\": \"hello \\\"quoted\\\" world\"}}",
  )
}

///|
test "format_response err" {
  let resp = @types.Response::Err("agent not found")
  assert_false(resp.is_ok())
  assert_eq(resp.status_tag(), "error")
  assert_eq(resp.error_message(), Some("agent not found"))
  let output = format_response(resp)
  assert_eq(output, "{\"ok\": false, \"error\": \"agent not found\"}")
}

///|
test "parse_response preserves primitive result values" {
  let input = "{\"ok\": true, \"result\": {\"status\":\"ok\",\"tracked\":true,\"pr_number\":22}}"
  match parse_response(input) {
    Ok(resp) => {
      assert_eq(resp.ok_field("status"), Some("ok"))
      match resp.ok_payload() {
        Some(fields) => {
          assert_eq(
            fields.get_value("tracked"),
            Some(@types.WireValue::Raw("true")),
          )
          assert_eq(
            fields.get_value("pr_number"),
            Some(@types.WireValue::Raw("22")),
          )
        }
        None => fail("expected payload")
      }
    }
    Err(e) => fail("Parse failed: \{e}")
  }
}
