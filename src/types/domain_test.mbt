///|
test "role equality" {
  assert_eq(@types.Role::TL, @types.Role::TL)
  assert_not_eq(@types.Role::Root, @types.Role::Dev)
}

///|
test "agent construction" {
  let agent : @types.Agent = {
    agent_id: "main.feature-a",
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Gemini,
    parent: Some("root"),
    workspace: ".exo/worktrees/feature-a",
    branch: "main.feature-a",
    tmux_target: Some("choir:feature-a"),
    host: @types.Host::Local,
    state: @types.AgentState::Spawning,
  }
  assert_eq(agent.state, @types.AgentState::Spawning)
  assert_eq(agent.role, @types.Role::Dev)
}

///|
test "default config" {
  let config = @types.Config::default()
  assert_eq(config.default_role, @types.Role::TL)
  assert_eq(config.listen_uds, ".exo/server.sock")
  assert_eq(config.listen_tcp, None)
  assert_eq(config.extra_mcp_servers_json, None)
}
