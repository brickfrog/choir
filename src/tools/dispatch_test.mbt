///|
fn mock_runner(cmds : Array[@workspace.Command]) -> Result[Array[Int], String] {
  let res = []
  for _ in cmds {
    res.push(0)
  }
  Ok(res)
}

///|
fn mock_fail_runner(
  cmds : Array[@workspace.Command],
) -> Result[Array[Int], String] {
  let res = []
  for _ in cmds {
    res.push(1)
    break
  }
  Ok(res)
}

///|
test "dispatch fork_wave returns agent_ids with mock" {
  let call : @tools.ToolCall = {
    role: @types.Role::TL,
    name: "fork_wave",
    args: {
      "count": "2",
      "task": "test task",
      "slug_prefix": "wave",
      "parent_branch": "main",
    },
  }
  let res = @tools.dispatch(call, runner=mock_runner)
  match res {
    Ok(m) => {
      assert_eq(m.get("status"), Some("spawned"))
      assert_eq(m.get("count"), Some("2"))
      assert_eq(m.get("agent_ids"), Some("main.wave-0,main.wave-1"))
    }
    Err(e) => {
      println(e)
      assert_true(false)
    }
  }
}

///|
test "dispatch fork_wave handles failure" {
  let call : @tools.ToolCall = {
    role: @types.Role::TL,
    name: "fork_wave",
    args: { "count": "1" },
  }
  let res = @tools.dispatch(call, runner=mock_fail_runner)
  match res {
    Ok(_) => assert_true(false)
    Err(e) => assert_eq(e, "command failed with status 1")
  }
}

///|
test "dispatch fork_wave validates count" {
  let call : @tools.ToolCall = {
    role: @types.Role::TL,
    name: "fork_wave",
    args: { "count": "abc" },
  }
  let res = @tools.dispatch(call, runner=mock_runner)
  match res {
    Ok(_) => assert_true(false)
    Err(e) => assert_eq(e, "invalid count: abc")
  }
}

///|
test "dispatch fork_wave validates slug_prefix" {
  let call : @tools.ToolCall = {
    role: @types.Role::TL,
    name: "fork_wave",
    args: { "count": "1", "slug_prefix": "../bad" },
  }
  let res = @tools.dispatch(call, runner=mock_runner)
  match res {
    Ok(_) => assert_true(false)
    Err(e) => assert_eq(e, "invalid slug_prefix: invalid character in slug: .")
  }
}

///|
test "dispatch spawn_gemini validates slug" {
  let call : @tools.ToolCall = {
    role: @types.Role::TL,
    name: "spawn_gemini",
    args: { "slug": "bad/slug" },
  }
  let res = @tools.dispatch(call, runner=mock_runner)
  match res {
    Ok(_) => assert_true(false)
    Err(e) => assert_eq(e, "invalid slug: invalid character in slug: /")
  }
}
