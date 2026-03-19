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
async fn run_shell(script : String) -> Unit {
  let statuses = @exec.run_sequence([
    { program: "sh", args: ["-c", script], workdir: None },
  ])
  assert_eq(statuses.length(), 1)
  assert_eq(statuses[0], 0)
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
test "dispatch task_list reads task files" {
  @async.with_event_loop(fn(_) {
    let project_dir = "/tmp/choir-dispatch-task-list"
    run_shell(
      "rm -rf /tmp/choir-dispatch-task-list && mkdir -p /tmp/choir-dispatch-task-list/.exo/tasks && " +
      "printf '%s' '{\"id\":\"1\",\"title\":\"First\",\"status\":\"todo\",\"assignee\":\"alice\",\"notes\":\"one\"}' > /tmp/choir-dispatch-task-list/.exo/tasks/1.json && " +
      "printf '%s' '{\"id\":\"2\",\"title\":\"Second\",\"status\":\"in_progress\",\"assignee\":\"bob\",\"notes\":\"two\"}' > /tmp/choir-dispatch-task-list/.exo/tasks/2.json",
    )
    let call : @tools.ToolCall = {
      role: @types.Role::Dev,
      name: "task_list",
      args: {},
    }
    let res = @tools.dispatch(call, project_dir~, runner=@exec.run_sequence)
    match res {
      Ok(m) => {
        assert_eq(m.get("status"), Some("ok"))
        assert_eq(
          m.get("tasks"),
          Some(
            "[{\"id\":\"1\",\"title\":\"First\",\"status\":\"todo\",\"assignee\":\"alice\",\"notes\":\"one\"},{\"id\":\"2\",\"title\":\"Second\",\"status\":\"in_progress\",\"assignee\":\"bob\",\"notes\":\"two\"}]",
          ),
        )
      }
      Err(e) => {
        println(e)
        assert_true(false)
      }
    }
    run_shell("rm -rf /tmp/choir-dispatch-task-list")
  })
}

///|
test "dispatch task_get reads one task" {
  @async.with_event_loop(fn(_) {
    let project_dir = "/tmp/choir-dispatch-task-get"
    run_shell(
      "rm -rf /tmp/choir-dispatch-task-get && mkdir -p /tmp/choir-dispatch-task-get/.exo/tasks && " +
      "printf '%s' '{\"id\":\"1\",\"title\":\"First\",\"status\":\"todo\",\"assignee\":\"alice\",\"notes\":\"one\"}' > /tmp/choir-dispatch-task-get/.exo/tasks/1.json",
    )
    let call : @tools.ToolCall = {
      role: @types.Role::Dev,
      name: "task_get",
      args: { "id": "1" },
    }
    let res = @tools.dispatch(call, project_dir~, runner=@exec.run_sequence)
    match res {
      Ok(m) => {
        assert_eq(m.get("status"), Some("ok"))
        assert_eq(
          m.get("task"),
          Some(
            "{\"id\":\"1\",\"title\":\"First\",\"status\":\"todo\",\"assignee\":\"alice\",\"notes\":\"one\"}",
          ),
        )
      }
      Err(e) => {
        println(e)
        assert_true(false)
      }
    }
    run_shell("rm -rf /tmp/choir-dispatch-task-get")
  })
}

///|
test "dispatch task_update merges and writes task file" {
  @async.with_event_loop(fn(_) {
    let project_dir = "/tmp/choir-dispatch-task-update"
    run_shell(
      "rm -rf /tmp/choir-dispatch-task-update && mkdir -p /tmp/choir-dispatch-task-update/.exo/tasks && " +
      "printf '%s' '{\"id\":\"1\",\"title\":\"First\",\"status\":\"todo\",\"assignee\":\"alice\",\"notes\":\"one\"}' > /tmp/choir-dispatch-task-update/.exo/tasks/1.json",
    )
    let call : @tools.ToolCall = {
      role: @types.Role::Dev,
      name: "task_update",
      args: {
        "id": "1",
        "status": "done",
        "assignee": "carol",
        "notes": "finished",
      },
    }
    let res = @tools.dispatch(call, project_dir~, runner=@exec.run_sequence)
    match res {
      Ok(m) => {
        assert_eq(m.get("status"), Some("ok"))
        assert_eq(
          m.get("task"),
          Some(
            "{\"id\":\"1\",\"title\":\"First\",\"status\":\"done\",\"assignee\":\"carol\",\"notes\":\"finished\"}",
          ),
        )
      }
      Err(e) => {
        println(e)
        assert_true(false)
      }
    }
    let written = @io.read_file(project_dir + "/.exo/tasks/1.json")
    assert_eq(
      written, "{\"id\":\"1\",\"title\":\"First\",\"status\":\"done\",\"assignee\":\"carol\",\"notes\":\"finished\"}",
    )
    run_shell("rm -rf /tmp/choir-dispatch-task-update")
  })
}

///|
test "dispatch task_update validates status" {
  @async.with_event_loop(fn(_) {
    let project_dir = "/tmp/choir-dispatch-task-status"
    run_shell(
      "rm -rf /tmp/choir-dispatch-task-status && mkdir -p /tmp/choir-dispatch-task-status/.exo/tasks && " +
      "printf '%s' '{\"id\":\"1\",\"title\":\"First\",\"status\":\"todo\",\"assignee\":\"alice\",\"notes\":\"one\"}' > /tmp/choir-dispatch-task-status/.exo/tasks/1.json",
    )
    let call : @tools.ToolCall = {
      role: @types.Role::Dev,
      name: "task_update",
      args: { "id": "1", "status": "blocked" },
    }
    let res = @tools.dispatch(call, project_dir~, runner=@exec.run_sequence)
    match res {
      Ok(_) => assert_true(false)
      Err(e) => assert_eq(e, "invalid status: blocked")
    }
    run_shell("rm -rf /tmp/choir-dispatch-task-status")
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
test "dispatch spawn_worker validates agent type" {
  @async.with_event_loop(fn(_) {
    let call : @tools.ToolCall = {
      role: @types.Role::TL,
      name: "spawn_worker",
      args: { "agent_type": "moon" },
    }
    let res = @tools.dispatch(call, runner=mock_runner)
    match res {
      Ok(_) => assert_true(false)
      Err(e) => assert_eq(e, "invalid agent_type: moon")
    }
  })
}

///|
test "dispatch spawn_worker succeeds with inline worker" {
  @async.with_event_loop(fn(_) {
    let call : @tools.ToolCall = {
      role: @types.Role::TL,
      name: "spawn_worker",
      args: { "slug": "worker-a", "task": "investigate" },
    }
    let res = @tools.dispatch(call, runner=mock_runner)
    match res {
      Ok(m) => assert_eq(m.get("status"), Some("spawned"))
      Err(e) => {
        println(e)
        assert_true(false)
      }
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

///|
test "dispatch shutdown blocks during critical review phase" {
  @async.with_event_loop(fn(_) {
    let poller = @poller.PollerState::new()
    poller.track(42, "leaf-2", 100L)
    poller.tick_with(
      200L,
      900L,
      fn(_) { (@poller.ReviewState::ChangesRequested, "sha1") },
      fn(_, _) { () },
    )
    let call : @tools.ToolCall = {
      role: @types.Role::Dev,
      name: "shutdown",
      args: { "caller_id": "leaf-2" },
    }
    let res = @tools.dispatch(
      call,
      runner=mock_runner,
      poller_state=Some(poller),
    )
    match res {
      Ok(_) => assert_true(false)
      Err(e) =>
        assert_eq(
          e, "cannot shutdown: PR #42 has changes requested — push fixes first",
        )
    }
  })
}

///|
test "dispatch kv_set, kv_get, and kv_delete use shared storage" {
  @async.with_event_loop(fn(_) {
    let project_dir = "/tmp/choir-dispatch-kv"
    run_shell(
      "rm -rf /tmp/choir-dispatch-kv && mkdir -p /tmp/choir-dispatch-kv",
    )

    let set_call : @tools.ToolCall = {
      role: @types.Role::Dev,
      name: "kv_set",
      args: { "key": "build/status", "value": "green" },
    }
    let set_res = @tools.dispatch(
      set_call,
      project_dir~,
      runner=@exec.run_sequence,
    )
    match set_res {
      Ok(m) => assert_eq(m.get("status"), Some("ok"))
      Err(e) => {
        println(e)
        assert_true(false)
      }
    }

    let get_call : @tools.ToolCall = {
      role: @types.Role::Dev,
      name: "kv_get",
      args: { "key": "build/status" },
    }
    let get_res = @tools.dispatch(
      get_call,
      project_dir~,
      runner=@exec.run_sequence,
    )
    match get_res {
      Ok(m) => assert_eq(m.get("value"), Some("green"))
      Err(e) => {
        println(e)
        assert_true(false)
      }
    }

    let delete_call : @tools.ToolCall = {
      role: @types.Role::Dev,
      name: "kv_delete",
      args: { "key": "build/status" },
    }
    let delete_res = @tools.dispatch(
      delete_call,
      project_dir~,
      runner=@exec.run_sequence,
    )
    match delete_res {
      Ok(m) => assert_eq(m.get("status"), Some("ok"))
      Err(e) => {
        println(e)
        assert_true(false)
      }
    }

    let after_delete = @tools.dispatch(
      get_call,
      project_dir~,
      runner=@exec.run_sequence,
    )
    match after_delete {
      Ok(m) => assert_eq(m.get("value"), Some("null"))
      Err(e) => {
        println(e)
        assert_true(false)
      }
    }

    run_shell("rm -rf /tmp/choir-dispatch-kv")
  })
}
