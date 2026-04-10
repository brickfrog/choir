///|
test "tool registry lookup chainlink_list allowed for TL" {
  let reg = @tools.ToolRegistry::new()
  let result = try? reg.lookup(@types.Role::TL, "chainlink_list")
  assert_true(result is Ok(_))
}

///|
test "tool registry lookup chainlink_list forbidden for Dev" {
  let reg = @tools.ToolRegistry::new()
  let result = try? reg.lookup(@types.Role::Dev, "chainlink_list")
  assert_true(result is Err(_))
}

///|
test "tool registry lookup chainlink_show allowed for TL" {
  let reg = @tools.ToolRegistry::new()
  let result = try? reg.lookup(@types.Role::TL, "chainlink_show")
  assert_true(result is Ok(_))
}

///|
test "tool registry lookup chainlink_ready allowed for TL" {
  let reg = @tools.ToolRegistry::new()
  let result = try? reg.lookup(@types.Role::TL, "chainlink_ready")
  assert_true(result is Ok(_))
}

///|
test "parse_chainlink_show_args returns error on missing id" {
  let args = @tools.tool_args_from_map({})
  let res = @tools.parse_chainlink_show_args(args)
  assert_true(res is Err(_))
}

///|
test "parse_chainlink_list_args defaults status to open when absent" {
  let args = @tools.tool_args_from_map({})
  let res = @tools.parse_chainlink_list_args(args)
  match res {
    Ok(status) => assert_eq(status, "open")
    Err(_) => fail("expected Ok")
  }
}

///|
test "parse_chainlink_list_args uses provided status" {
  let args = @tools.tool_args_from_map({ "status": "closed" })
  let res = @tools.parse_chainlink_list_args(args)
  match res {
    Ok(status) => assert_eq(status, "closed")
    Err(_) => fail("expected Ok")
  }
}
