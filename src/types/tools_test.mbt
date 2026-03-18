///|
test "tool role check" {
  let tool : @types.ToolDef = {
    name: "fork_wave",
    description: "Spawn parallel agents",
    allowed_roles: [@types.Role::Root, @types.Role::TL],
  }
  assert_true(tool.is_role_allowed(@types.Role::TL))
  assert_false(tool.is_role_allowed(@types.Role::Dev))
}
