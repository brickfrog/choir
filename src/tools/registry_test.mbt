///|
test "tool registry lookup success" {
  let reg = @tools.ToolRegistry::new()
  let result = reg.lookup(@types.Role::TL, "fork_wave")
  assert_true(result is Ok(_))
}

///|
test "tool registry lookup wrong role" {
  let reg = @tools.ToolRegistry::new()
  let result = reg.lookup(@types.Role::Worker, "fork_wave")
  assert_true(result is Err(_))
}

///|
test "tool registry lookup unknown tool" {
  let reg = @tools.ToolRegistry::new()
  let result = reg.lookup(@types.Role::TL, "nonexistent")
  assert_true(result is Err(_))
}

///|
test "send_message allowed for all roles" {
  let reg = @tools.ToolRegistry::new()
  let roles : Array[@types.Role] = [
    @types.Role::Root,
    @types.Role::TL,
    @types.Role::Dev,
    @types.Role::Worker,
  ]
  for role in roles {
    let result = reg.lookup(role, "send_message")
    assert_true(result is Ok(_))
  }
}

///|
test "reply allowed for all roles" {
  let reg = @tools.ToolRegistry::new()
  let roles : Array[@types.Role] = [
    @types.Role::Root,
    @types.Role::TL,
    @types.Role::Dev,
    @types.Role::Worker,
  ]
  for role in roles {
    let result = reg.lookup(role, "reply")
    assert_true(result is Ok(_))
  }
}

///|
test "kv tools allowed for all roles" {
  let reg = @tools.ToolRegistry::new()
  let roles : Array[@types.Role] = [
    @types.Role::Root,
    @types.Role::TL,
    @types.Role::Dev,
    @types.Role::Worker,
  ]
  let names = [
    "kv_get", "kv_set", "kv_delete", "kv_list", "mutex_acquire", "mutex_release",
    "mutex_status",
  ]
  for role in roles {
    for name in names {
      let result = reg.lookup(role, name)
      assert_true(result is Ok(_))
    }
  }
}

///|
test "handle_request with valid tool returns Ok" {
  @async.with_event_loop(_ => {
    let reg = @tools.ToolRegistry::new()
    let req = @types.Request::{
      req_method: "tools/call",
      role: @types.Role::TL,
      name: "fork_wave",
      args: { "count": "3" },
    }
    let res = handle_request(reg, req, runner=mock_runner)
    assert_true(res is Ok(_))
  })
}

///|
test "handle_request with wrong role returns Err" {
  @async.with_event_loop(_ => {
    let reg = @tools.ToolRegistry::new()
    let req = @types.Request::{
      req_method: "tools/call",
      role: @types.Role::Worker,
      name: "fork_wave",
      args: {},
    }
    let res = handle_request(reg, req)
    assert_true(res is Err(_))
  })
}

///|
test "handle_request with unknown tool returns Err" {
  @async.with_event_loop(_ => {
    let reg = @tools.ToolRegistry::new()
    let req = @types.Request::{
      req_method: "tools/call",
      role: @types.Role::TL,
      name: "nonexistent",
      args: {},
    }
    let res = handle_request(reg, req)
    assert_true(res is Err(_))
  })
}

///|
test "dispatch returns correct stub for each tool name" {
  @async.with_event_loop(_ => {
    let cases = [
      ("fork_wave", "spawned", { "count": "1" }),
      ("fork_session", "ok", { "name": "nested-team" }),
      ("file_pr", "pr_created", { "branch": "test" }),
      ("merge_pr", "merged", { "pr_number": "1" }),
      ("track_pr", "tracked", { "pr_number": "1", "agent_id": "agent-1" }),
      ("notify_parent", "notified", { "caller_id": "test-agent" }),
      ("send_message", "sent", { "target_id": "test-agent" }),
      ("reply", "ok", { "id": "req-1" }),
      ("kv_get", "", { "key": "missing" }),
      ("mutex_status", "", { "name": "readme" }),
      ("shutdown", "shutdown", Map::new()),
      ("task_list", "ok", Map::new()),
      ("spawn_gemini", "spawned", Map::new()),
      ("spawn_moon_pilot", "spawned", Map::new()),
      ("spawn_worker", "spawned", Map::new()),
    ]
    for c in cases {
      let (name, expected_status, args) = c
      let call = ToolCall::{ role: @types.Role::Dev, name, args }
      let res = @tools.dispatch(
        call,
        runner=mock_runner,
        mutex_registry=Some(@registry.MutexRegistry::new()),
        poller_state=Some(@poller.PollerState::new()),
      )
      match res {
        Ok(map) =>
          if name == "kv_get" {
            assert_eq(map.get("value"), Some("null"))
          } else if name == "mutex_status" {
            assert_eq(map.get("holder"), Some(""))
            assert_eq(map.get("queue_length"), Some("0"))
          } else {
            assert_eq(map.get("status"), Some(expected_status))
          }
        Err(msg) => {
          println(name + ": " + msg)
          assert_true(false)
        }
      }
    }
  })
}

///|
test "tool registry lookup spawn_worker allowed for TL" {
  let reg = @tools.ToolRegistry::new()
  let result = reg.lookup(@types.Role::TL, "spawn_worker")
  assert_true(result is Ok(_))
}

///|
test "tool registry lookup fork_session allowed for TL" {
  let reg = @tools.ToolRegistry::new()
  let result = reg.lookup(@types.Role::TL, "fork_session")
  assert_true(result is Ok(_))
}

///|
test "tool registry lookup spawn_moon_pilot allowed for TL" {
  let reg = @tools.ToolRegistry::new()
  let result = reg.lookup(@types.Role::TL, "spawn_moon_pilot")
  assert_true(result is Ok(_))
}
