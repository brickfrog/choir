///|
test "format message" {
  let msg = @message.format_message("main.worker-1", "done with research")
  assert_eq(msg, "[from: main.worker-1] done with research")
}

///|
test "format failure" {
  let msg = @message.format_failure("main.feature-a", "compilation error")
  assert_eq(msg, "[FAILED: main.feature-a] compilation error")
}

///|
test "teams inbox json output" {
  let json = @message.teams_inbox_json("sender", "hello", "Success")
  assert_eq(
    json, "{\"from\":\"sender\",\"content\":\"hello\",\"status\":\"Success\"}",
  )
}

///|
test "teams inbox path format" {
  let path = @message.teams_inbox_path("claude-1")
  assert_eq(path, "~/.claude/teams/claude-1/inboxes/default.json")
}

///|
test "plan delivery for Claude agent -> TeamsInbox" {
  let agent : @types.Agent = {
    agent_id: "agent-claude",
    role: @types.Role::Worker,
    agent_type: @types.AgentType::Claude,
    parent: None,
    workspace: "ws1",
    branch: "main",
    tmux_target: None,
    host: @types.Host::Local,
    state: @types.AgentState::Active,
  }
  let res = @message.plan_delivery(agent, "sender-1", "hi", "Success")
  let expected = @message.DeliveryMethod::TeamsInbox(
    "~/.claude/teams/agent-claude/inboxes/default.json", "{\"from\":\"sender-1\",\"content\":\"hi\",\"status\":\"Success\"}",
  )
  assert_eq(res, expected)
}

///|
test "plan delivery for Gemini agent -> TmuxStdin" {
  let agent : @types.Agent = {
    agent_id: "agent-gemini",
    role: @types.Role::Worker,
    agent_type: @types.AgentType::Gemini,
    parent: None,
    workspace: "ws1",
    branch: "main",
    tmux_target: Some("target-pane"),
    host: @types.Host::Local,
    state: @types.AgentState::Active,
  }
  let res = @message.plan_delivery(agent, "sender-1", "hi", "Success")
  let expected = @message.DeliveryMethod::TmuxStdin(
    "target-pane", "[from: sender-1] hi",
  )
  assert_eq(res, expected)
}

///|
test "plan delivery for MoonPilot agent -> TmuxStdin" {
  let agent : @types.Agent = {
    agent_id: "agent-moonpilot",
    role: @types.Role::Worker,
    agent_type: @types.AgentType::MoonPilot,
    parent: None,
    workspace: "ws1",
    branch: "main",
    tmux_target: Some("choir:moonpilot"),
    host: @types.Host::Local,
    state: @types.AgentState::Active,
  }
  let res = @message.plan_delivery(agent, "sender-1", "hi", "Success")
  let expected = @message.DeliveryMethod::TmuxStdin(
    "choir:moonpilot", "[from: sender-1] hi",
  )
  assert_eq(res, expected)
}

///|
test "plan delivery for Remote agent -> TcpPush" {
  let agent : @types.Agent = {
    agent_id: "agent-remote",
    role: @types.Role::Worker,
    agent_type: @types.AgentType::Gemini,
    parent: None,
    workspace: "ws1",
    branch: "main",
    tmux_target: None,
    host: @types.Host::Remote("192.168.1.1"),
    state: @types.AgentState::Active,
  }
  let res = @message.plan_delivery(agent, "sender-1", "hi", "Success")
  let expected = @message.DeliveryMethod::TcpPush(
    "agent-remote", "[from: sender-1] hi",
  )
  assert_eq(res, expected)
}
