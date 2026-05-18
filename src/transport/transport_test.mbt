///|
test "parse_request success" {
  let input = "{\"method\": \"tools/call\", \"role\": \"tl\", \"name\": \"fork_wave\", \"args\": {\"slug\": \"feat-a\", \"count\": \"3\"}}"
  match parse_request(input) {
    Ok(req) => {
      assert_eq(req.req_method, "tools/call")
      assert_eq(req.role, @types.Role::TL)
      assert_eq(req.name, "fork_wave")
      @debug.assert_eq(req.args.get("slug"), Some("feat-a"))
      @debug.assert_eq(req.args.get("count"), Some("3"))
    }
    Err(e) => fail("Parse failed: \{e}")
  }
}

///|
test "parse_request accepts server_reload tool call shape" {
  let input = "{\"method\":\"tools/call\",\"role\":\"root\",\"name\":\"server_reload\",\"args\":{\"binary_path\":\"/tmp/choir.exe\"}}"
  match parse_request(input) {
    Ok(req) => {
      assert_eq(req.req_method, "tools/call")
      assert_eq(req.role, @types.Role::Root)
      assert_eq(req.name, "server_reload")
      @debug.assert_eq(req.args.get("binary_path"), Some("/tmp/choir.exe"))
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
      @debug.assert_eq(req.args.get("k"), Some("v"))
    }
    Err(e) => fail("Parse failed: \{e}")
  }
}

///|
test "parse_args with commas and colons in values" {
  let input = "{\"method\":\"call\",\"role\":\"tl\",\"name\":\"test\",\"args\":{\"msg\":\"hello, world: how are you?\",\"key\":\"val\"}}"
  match parse_request(input) {
    Ok(req) => {
      @debug.assert_eq(req.args.get("msg"), Some("hello, world: how are you?"))
      @debug.assert_eq(req.args.get("key"), Some("val"))
    }
    Err(e) => fail("Parse failed: \{e}")
  }
}

///|
test "parse_request preserves primitive arg literals" {
  let input = "{\"method\":\"tools/call\",\"role\":\"tl\",\"name\":\"fork_wave\",\"args\":{\"count\":3,\"fork_session\":true,\"empty\":null}}"
  match parse_request(input) {
    Ok(req) => {
      @debug.assert_eq(req.args.get("count"), Some("3"))
      @debug.assert_eq(req.args.get("fork_session"), Some("true"))
      @debug.assert_eq(req.args.get("empty"), Some("null"))
      @debug.assert_eq(req.args.get_json("count"), Some((3).to_json()))
      @debug.assert_eq(req.args.get_json("fork_session"), Some(true.to_json()))
    }
    Err(e) => fail("Parse failed: \{e}")
  }
}

///|
test "is_jsonrpc_request detects JSON-RPC envelope only" {
  assert_true(
    is_jsonrpc_request(
      "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}",
    ),
  )
  assert_true(
    is_jsonrpc_request(
      "{ \"jsonrpc\" : \"2.0\", \"id\": 1, \"method\": \"initialize\" }",
    ),
  )
  assert_false(
    is_jsonrpc_request(
      "{\"method\":\"tools/call\",\"role\":\"root\",\"name\":\"status_bar_state\",\"args\":{}}",
    ),
  )
  assert_false(
    is_jsonrpc_request(
      "{\"method\":\"tools/call\",\"role\":\"root\",\"name\":\"send_message\",\"args\":{\"payload\":{\"jsonrpc\":\"2.0\",\"method\":\"initialize\"}}}",
    ),
  )
  assert_false(
    is_jsonrpc_request("{\"jsonrpc\":2,\"id\":1,\"method\":\"initialize\"}"),
  )
  assert_false(is_jsonrpc_request("not jsonrpc"))
  assert_false(is_jsonrpc_request("{\"jsonrpc\":\"2.0\","))
  assert_false(is_jsonrpc_request("{\"jsonrpc\"}"))
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
  let result = Map([], capacity=0)
  result.set("agent_id", "main.feat-a")
  let resp = @types.Response::ok(result)
  assert_true(resp.is_ok())
  assert_eq(resp.status_tag(), "ok")
  @debug.assert_eq(resp.ok_field("agent_id"), Some("main.feat-a"))
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
  @debug.assert_eq(obj.get("ok"), Some(true.to_json()))
  guard obj.get("result") is Some(Object(res)) else {
    fail("expected result")
    return
  }
  @debug.assert_eq(res.get("agent_id"), Some("main.feat-a".to_json()))
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
    task_contract: None,
    automerge: None,
    review_mode: None,
    auto_pull_after_integration: None,
    auto_rebuild_after_pull: None,
    auto_reload_after_rebuild: None,
    wave_id: None,
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
  assert_true(output.contains("\"connection_lifetime\":\"session\""))
}

///|
test "format_registration_request can mark one-shot clients" {
  let output = format_registration_request(
    @types.Role::Dev,
    "leaf-1",
    @types.LocalConfig::default(),
    connection_lifetime=ConnectionLifetime::OneShot,
  )
  assert_true(output.contains("\"connection_lifetime\":\"oneshot\""))
}

///|
test "parse_connection_lifetime recognizes wire values" {
  @debug.assert_eq(
    parse_connection_lifetime("session"),
    Some(ConnectionLifetime::Session),
  )
  @debug.assert_eq(
    parse_connection_lifetime("one-shot"),
    Some(ConnectionLifetime::OneShot),
  )
  @debug.assert_eq(
    parse_connection_lifetime("tool_call"),
    Some(ConnectionLifetime::OneShot),
  )
  @debug.assert_eq(parse_connection_lifetime("bogus"), None)
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
  let result = Map([], capacity=0)
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
  @debug.assert_eq(resp.error_message(), Some("agent not found"))
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
  @debug.assert_eq(obj.get("ok"), Some(false.to_json()))
  @debug.assert_eq(obj.get("error"), Some("agent not found".to_json()))
}

///|
test "parse_response preserves primitive result values" {
  let input = "{\"ok\": true, \"result\": {\"status\":\"ok\",\"tracked\":true,\"pr_number\":22}}"
  match parse_response(input) {
    Ok(resp) => {
      @debug.assert_eq(resp.ok_field("status"), Some("ok"))
      match resp.ok_payload() {
        Some(fields) => {
          @debug.assert_eq(fields.get_json("tracked"), Some(true.to_json()))
          @debug.assert_eq(fields.get_json("pr_number"), Some((22).to_json()))
        }
        None => fail("expected payload")
      }
    }
    Err(e) => fail("Parse failed: \{e}")
  }
}
