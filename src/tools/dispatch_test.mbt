///|
test "dispatch fork_wave returns agent_ids" {
  let call : @tools.ToolCall = {
    role: @types.Role::TL,
    name: "fork_wave",
    args: { "count": "2", "task": "test task", "slug_prefix": "wave", "parent_branch": "main" },
  }
  let res = @tools.dispatch(call)
  match res {
    Ok(m) => {
      assert_eq(m.get("status"), Some("spawned"))
      assert_eq(m.get("count"), Some("2"))
      assert_eq(m.get("agent_ids"), Some("main.wave-0,main.wave-1"))
    }
    Err(_) => assert_true(false)
  }
}
