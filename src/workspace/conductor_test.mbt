///|
test "Claude Conductor launch exposes only Choir MCP" {
  let command = @workspace.conductor_launch_command("/repo")
  assert_eq(command.program, "claude")
  assert_eq(command.workdir, None)
  assert_true(command.args.contains("--tools"))
  assert_true(command.args.contains("--strict-mcp-config"))
  assert_true(command.args.contains("/repo/.choir/plugin"))
  let joined = command.args.join("\n")
  assert_true(joined.contains("mcp-stdio"))
  assert_false(joined.contains("semble"))
  assert_false(joined.contains("zellij"))
}
