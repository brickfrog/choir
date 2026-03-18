///|
test "HookResponse::allow produces correct JSON" {
  let res = HookResponse::allow()
  assert_eq(res.to_json_string(), "{\"continue\":true}")
}

///|
test "HookResponse::block produces correct JSON" {
  let res = HookResponse::block("not allowed")
  assert_eq(
    res.to_json_string(),
    "{\"continue\":false,\"message\":\"not allowed\"}",
  )
}

///|
test "HookResponse::fail_open equals allow" {
  let res_fail = HookResponse::fail_open()
  let res_allow = HookResponse::allow()
  assert_eq(res_fail, res_allow)
  assert_eq(res_fail.to_json_string(), "{\"continue\":true}")
}

///|
test "HookInput::from_json_string parses valid SessionStart" {
  let json = "{\"event\":\"SessionStart\",\"agent_id\":\"agent-123\",\"role\":\"dev\"}"
  match HookInput::from_json_string(json) {
    Some(input) => {
      assert_eq(input.event, HookEvent::SessionStart)
      assert_eq(input.agent_id, Some("agent-123"))
      assert_eq(input.role, Some(@types.Role::Dev))
    }
    None => panic()
  }
}

///|
test "HookInput::from_json_string parses valid PreToolUse" {
  let json = "{\"event\":\"PreToolUse\",\"tool_name\":\"read_file\"}"
  match HookInput::from_json_string(json) {
    Some(input) => {
      assert_eq(input.event, HookEvent::PreToolUse)
      assert_eq(input.tool_name, Some("read_file"))
    }
    None => panic()
  }
}

///|
test "HookInput::from_json_string fails on invalid event" {
  let json = "{\"event\":\"InvalidEvent\"}"
  match HookInput::from_json_string(json) {
    Some(_) => panic()
    None => ()
  }
}

///|
test "HookInput construction with all fields" {
  let input = HookInput::{
    event: HookEvent::PreToolUse,
    agent_id: Some("agent-1"),
    role: Some(@types.Role::Dev),
    tool_name: Some("test_tool"),
    tool_args: Some(Map::of([("key", "value")])),
  }
  assert_eq(input.event, HookEvent::PreToolUse)
}

///|
test "HookInput construction with minimal fields" {
  let input = HookInput::{
    event: HookEvent::SessionStart,
    agent_id: None,
    role: None,
    tool_name: None,
    tool_args: None,
  }
  assert_eq(input.event, HookEvent::SessionStart)
}
