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

///|
test "Conductor process group parser rejects unsafe identities" {
  assert_eq(@workspace.parse_agent_pgid("42\n"), Some(42))
  assert_eq(@workspace.parse_agent_pgid(""), None)
  assert_eq(@workspace.parse_agent_pgid("1"), None)
  assert_eq(@workspace.parse_agent_pgid("nope"), None)
}
