///|
test "sanitize_agent_id" {
  assert_eq(sanitize_agent_id("agent/1\\2\u00003"), "agent_1_2_3")
  assert_eq(sanitize_agent_id("normal_agent-id"), "normal_agent-id")
}
