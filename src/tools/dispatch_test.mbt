///|
async fn mock_runner(cmds : Array[@workspace.Command]) -> Array[Int] {
  let res = []
  for _ in cmds {
    res.push(0)
  }
  res
}

///|
async fn mock_fail_runner(cmds : Array[@workspace.Command]) -> Array[Int] {
  let res = []
  for _ in cmds {
    res.push(1)
    break
  }
  res
}

///|
test "dispatch fork_wave returns agent_ids with mock" {
  @async.with_event_loop(fn(_) {
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
  })
}

///|
test "dispatch fork_wave handles failure" {
  @async.with_event_loop(fn(_) {
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
  })
}

///|
test "dispatch fork_wave validates count" {
  @async.with_event_loop(fn(_) {
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
  })
}

///|
test "dispatch fork_wave validates slug_prefix" {
  @async.with_event_loop(fn(_) {
    let call : @tools.ToolCall = {
      role: @types.Role::TL,
      name: "fork_wave",
      args: { "count": "1", "slug_prefix": "../bad" },
    }
    let res = @tools.dispatch(call, runner=mock_runner)
    match res {
      Ok(_) => assert_true(false)
      Err(e) =>
        assert_eq(e, "invalid slug_prefix: invalid character in slug: .")
    }
  })
}

///|
test "dispatch spawn_gemini validates slug" {
  @async.with_event_loop(fn(_) {
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
  })
}

///|
test "dispatch register inserts agent into registry" {
  @async.with_event_loop(fn(_) {
    let reg = @registry.AgentRegistry::new()
    let call : @tools.ToolCall = {
      role: @types.Role::Dev,
      name: "register",
      args: { "agent_id": "leaf-0" },
    }
    let res = @tools.dispatch(call, runner=mock_runner, registry=Some(reg))
    match res {
      Ok(m) => {
        assert_eq(m.get("status"), Some("registered"))
        assert_eq(m.get("agent_id"), Some("leaf-0"))
        assert_true(reg.get("leaf-0") is Ok(_))
      }
      Err(e) => {
        println(e)
        assert_true(false)
      }
    }
  })
}

///|
test "dispatch register requires agent_id arg" {
  @async.with_event_loop(fn(_) {
    let reg = @registry.AgentRegistry::new()
    let call : @tools.ToolCall = {
      role: @types.Role::Dev,
      name: "register",
      args: {},
    }
    let res = @tools.dispatch(call, runner=mock_runner, registry=Some(reg))
    assert_true(res is Err(_))
  })
}

///|
test "dispatch shutdown removes agent from registry" {
  @async.with_event_loop(fn(_) {
    let reg = @registry.AgentRegistry::new()
    let agent = @types.Agent::{
      agent_id: "leaf-1",
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Claude,
      state: @types.AgentState::Active,
      parent: None,
      tmux_target: None,
      host: @types.Host::Local,
      workspace: "",
      branch: "",
    }
    let _ = reg.insert(agent)
    let call : @tools.ToolCall = {
      role: @types.Role::Dev,
      name: "shutdown",
      args: { "caller_id": "leaf-1" },
    }
    let res = @tools.dispatch(call, runner=mock_runner, registry=Some(reg))
    assert_true(res is Ok(_))
    assert_true(reg.get("leaf-1") is Err(_))
  })
}
