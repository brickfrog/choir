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
  let res = handle_request(reg, req, runner=mock_runner)
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
    ("fork_wave", "spawned", { "count": "1" }),
    ("file_pr", "pr_created", { "branch": "test" }),
    ("merge_pr", "merged", { "pr_number": "1" }),
    ("notify_parent", "notified", Map::new()),
    ("send_message", "sent", Map::new()),
    ("shutdown", "shutdown", Map::new()),
    ("task_list", "ok", Map::new()),
    ("task_get", "ok", Map::new()),
    ("task_update", "ok", Map::new()),
    ("spawn_gemini", "spawned", Map::new()),
  ]
  for c in cases {
    let (name, expected_status, args) = c
    let call = ToolCall::{ role: @types.Role::Dev, name, args }
    let res = @tools.dispatch(call, runner=mock_runner)
    match res {
      Ok(map) => assert_eq(map.get("status"), Some(expected_status))
      Err(msg) => {
        println(name + ": " + msg)
        assert_true(false) // should not be Err
      }
    }
  }
}
