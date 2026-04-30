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

///|
test "Response with_warning injects warning field into Ok response" {
  let resp = @types.Response::ok_values({ "status": "pr_created".to_json() })
  let warned = resp.with_warning("review request failed")
  assert_true(warned.is_ok())
  @debug.assert_eq(warned.ok_field("warning"), Some("review request failed"))
  @debug.assert_eq(warned.ok_field("status"), Some("pr_created"))
}

///|
test "Response with_warning is no-op on Err response" {
  let resp : @types.Response = Err("something broke")
  let warned = resp.with_warning("ignored")
  @debug.assert_eq(warned.error_message(), Some("something broke"))
}
