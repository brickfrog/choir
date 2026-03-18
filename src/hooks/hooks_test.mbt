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
