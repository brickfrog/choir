///|
test "tool registry lookup success" {
  let reg = @tools.ToolRegistry::new()
  let result = reg.lookup(@types.Role::TL, "fork_wave")
  assert_true(result is Ok(_))
}

///|
test "tool registry lookup wrong role" {
  let reg = @tools.ToolRegistry::new()
  let result = reg.lookup(@types.Role::Worker, "fork_wave")
  assert_true(result is Err(_))
}

///|
test "tool registry lookup unknown tool" {
  let reg = @tools.ToolRegistry::new()
  let result = reg.lookup(@types.Role::TL, "nonexistent")
  assert_true(result is Err(_))
}

///|
test "send_message allowed for all roles" {
  let reg = @tools.ToolRegistry::new()
  let roles : Array[@types.Role] = [
    @types.Role::Root,
    @types.Role::TL,
    @types.Role::Dev,
    @types.Role::Worker,
  ]
  for role in roles {
    let result = reg.lookup(role, "send_message")
    assert_true(result is Ok(_))
  }
}

///|
test "handle_request with valid tool returns Ok" {
  let reg = @tools.ToolRegistry::new()
  let req = @types.Request::{
    req_method: "tools/call",
    role: @types.Role::TL,
    name: "fork_wave",
    args: { "count": "3" },
  }
  let res = handle_request(reg, req)
  assert_true(res is Ok(_))
}

///|
test "handle_request with wrong role returns Err" {
  let reg = @tools.ToolRegistry::new()
  let req = @types.Request::{
    req_method: "tools/call",
    role: @types.Role::Worker,
    name: "fork_wave",
    args: {},
  }
  let res = handle_request(reg, req)
  assert_true(res is Err(_))
}

///|
test "handle_request with unknown tool returns Err" {
  let reg = @tools.ToolRegistry::new()
  let req = @types.Request::{
    req_method: "tools/call",
    role: @types.Role::TL,
    name: "nonexistent",
    args: {},
  }
  let res = handle_request(reg, req)
  assert_true(res is Err(_))
}

///|
test "dispatch returns correct stub for each tool name" {
  let cases = [
    ("fork_wave", "spawned"),
    ("file_pr", "pr_created"),
    ("merge_pr", "merged"),
    ("notify_parent", "notified"),
    ("send_message", "sent"),
    ("shutdown", "shutdown"),
    ("task_list", "ok"),
    ("task_get", "ok"),
    ("task_update", "ok"),
    ("spawn_gemini", "spawned"),
  ]
  for c in cases {
    let (name, expected_status) = c
    let call = ToolCall::{ role: @types.Role::Dev, name, args: {} }
    let res = @tools.dispatch(call)
    match res {
      Ok(map) => assert_eq(map.get("status"), Some(expected_status))
      Err(_) => assert_true(false) // should not be Err
    }
  }
}
