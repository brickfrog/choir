///|
async fn mock_runner(cmds : Array[@workspace.Command]) -> Array[Int] {
  @async.sleep(0)
  let res = []
  for _ in cmds {
    res.push(0)
  }
  res
}

///|
async fn mock_fail_runner(cmds : Array[@workspace.Command]) -> Array[Int] {
  @async.sleep(0)
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
  @async.with_event_loop(_ => {
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
  @async.with_event_loop(_ => {
    let project_dir = "/tmp/choir-dispatch-task-list"
    run_shell(
      "rm -rf /tmp/choir-dispatch-task-list && mkdir -p /tmp/choir-dispatch-task-list/.choir/tasks && " +
      "printf '%s' '{\"id\":\"1\",\"title\":\"First\",\"status\":\"todo\",\"assignee\":\"alice\",\"notes\":\"one\"}' > /tmp/choir-dispatch-task-list/.choir/tasks/1.json && " +
      "printf '%s' '{\"id\":\"2\",\"title\":\"Second\",\"status\":\"in_progress\",\"assignee\":\"bob\",\"notes\":\"two\"}' > /tmp/choir-dispatch-task-list/.choir/tasks/2.json",
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
  @async.with_event_loop(_ => {
    let project_dir = "/tmp/choir-dispatch-task-get"
    run_shell(
      "rm -rf /tmp/choir-dispatch-task-get && mkdir -p /tmp/choir-dispatch-task-get/.choir/tasks && " +
      "printf '%s' '{\"id\":\"1\",\"title\":\"First\",\"status\":\"todo\",\"assignee\":\"alice\",\"notes\":\"one\"}' > /tmp/choir-dispatch-task-get/.choir/tasks/1.json",
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
  @async.with_event_loop(_ => {
    let project_dir = "/tmp/choir-dispatch-task-update"
    run_shell(
      "rm -rf /tmp/choir-dispatch-task-update && mkdir -p /tmp/choir-dispatch-task-update/.choir/tasks && " +
      "printf '%s' '{\"id\":\"1\",\"title\":\"First\",\"status\":\"todo\",\"assignee\":\"alice\",\"notes\":\"one\"}' > /tmp/choir-dispatch-task-update/.choir/tasks/1.json",
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
    let written = @io.read_file(project_dir + "/.choir/tasks/1.json")
    assert_eq(
      written, "{\"id\":\"1\",\"title\":\"First\",\"status\":\"done\",\"assignee\":\"carol\",\"notes\":\"finished\"}",
    )
    run_shell("rm -rf /tmp/choir-dispatch-task-update")
  })
}

///|
test "dispatch task_update validates status" {
  @async.with_event_loop(_ => {
    let project_dir = "/tmp/choir-dispatch-task-status"
    run_shell(
      "rm -rf /tmp/choir-dispatch-task-status && mkdir -p /tmp/choir-dispatch-task-status/.choir/tasks && " +
      "printf '%s' '{\"id\":\"1\",\"title\":\"First\",\"status\":\"todo\",\"assignee\":\"alice\",\"notes\":\"one\"}' > /tmp/choir-dispatch-task-status/.choir/tasks/1.json",
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
test "dispatch reply stores payload in reply kv path" {
  @async.with_event_loop(_ => {
    let project_dir = "/tmp/choir-dispatch-reply"
    run_shell(
      "rm -rf /tmp/choir-dispatch-reply && mkdir -p /tmp/choir-dispatch-reply/.choir",
    )
    let call : @tools.ToolCall = {
      role: @types.Role::Root,
      name: "reply",
      args: { "id": "req-1", "payload": "{\"ok\":true}" },
    }
    let res = @tools.dispatch(call, project_dir~, runner=@exec.run_sequence)
    match res {
      Ok(m) => {
        assert_eq(m.get("status"), Some("ok"))
        assert_eq(m.get("id"), Some("req-1"))
      }
      Err(e) => {
        println(e)
        assert_true(false)
      }
    }
    let written = @io.read_file(project_dir + "/.choir/kv/reply/req-1")
    assert_eq(written, "{\"ok\":true}")
    run_shell("rm -rf /tmp/choir-dispatch-reply")
  })
}

///|
test "dispatch reply cancel stores cancel marker" {
  @async.with_event_loop(_ => {
    let project_dir = "/tmp/choir-dispatch-reply-cancel"
    run_shell(
      "rm -rf /tmp/choir-dispatch-reply-cancel && mkdir -p /tmp/choir-dispatch-reply-cancel/.choir",
    )
    let call : @tools.ToolCall = {
      role: @types.Role::Root,
      name: "reply",
      args: { "id": "req-2", "payload": "ignored", "cancel": "true" },
    }
    let res = @tools.dispatch(call, project_dir~, runner=@exec.run_sequence)
    match res {
      Ok(m) => assert_eq(m.get("status"), Some("ok"))
      Err(e) => {
        println(e)
        assert_true(false)
      }
    }
    let written = @io.read_file(project_dir + "/.choir/kv/reply/req-2")
    assert_eq(written, "cancel")
    run_shell("rm -rf /tmp/choir-dispatch-reply-cancel")
  })
}

///|
test "dispatch fork_wave handles failure" {
  @async.with_event_loop(_ => {
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
  @async.with_event_loop(_ => {
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
  @async.with_event_loop(_ => {
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
  @async.with_event_loop(_ => {
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
test "dispatch spawn_gemini returns agent_id and renders leaf protocol" {
  @async.with_event_loop(_ => {
    let call : @tools.ToolCall = {
      role: @types.Role::TL,
      name: "spawn_gemini",
      args: {
        "task": "Implement feature X",
        "slug": "gem-feat",
        "parent_branch": "main",
        "read_first": "AGENTS.md\nsrc/tools/dispatch.mbt",
      },
    }
    let res = @tools.dispatch(call, runner=mock_runner)
    match res {
      Ok(m) => {
        assert_eq(m.get("status"), Some("spawned"))
        assert_eq(m.get("agent_id"), Some("main.gem-feat"))
        assert_eq(m.get("slug"), Some("gem-feat"))
      }
      Err(e) => {
        println(e)
        assert_true(false)
      }
    }
  })
}

///|
test "dispatch spawn_gemini accepts branch alias for slug" {
  @async.with_event_loop(_ => {
    let call : @tools.ToolCall = {
      role: @types.Role::TL,
      name: "spawn_gemini",
      args: { "task": "Implement feature X", "branch": "gem-alias" },
    }
    let res = @tools.dispatch(call, runner=mock_runner)
    match res {
      Ok(m) => {
        assert_eq(m.get("agent_id"), Some("main.gem-alias"))
        assert_eq(m.get("slug"), Some("gem-alias"))
      }
      Err(e) => {
        println(e)
        assert_true(false)
      }
    }
  })
}

///|
test "dispatch spawn_moon_pilot returns agent_id with mock" {
  @async.with_event_loop(_ => {
    let call : @tools.ToolCall = {
      role: @types.Role::TL,
      name: "spawn_moon_pilot",
      args: {
        "task": "implement feature X",
        "slug": "mp-feat",
        "parent_branch": "main",
      },
    }
    let res = @tools.dispatch(call, runner=mock_runner)
    match res {
      Ok(m) => {
        assert_eq(m.get("status"), Some("spawned"))
        assert_eq(m.get("agent_id"), Some("main.mp-feat"))
        assert_eq(m.get("slug"), Some("mp-feat"))
      }
      Err(e) => {
        println(e)
        assert_true(false)
      }
    }
  })
}

///|
test "dispatch spawn_remote returns agent_id with mock" {
  @async.with_event_loop(_ => {
    let call : @tools.ToolCall = {
      role: @types.Role::TL,
      name: "spawn_remote",
      args: {
        "task": "implement feature Z",
        "slug": "remote-1",
        "parent_branch": "main",
        "ssh_target": "user@10.0.0.2",
        "repo_url": "git@github.com:org/repo.git",
        "tcp_addr": "10.0.0.1:9100",
      },
    }
    let res = @tools.dispatch(call, runner=mock_runner)
    match res {
      Ok(m) => {
        assert_eq(m.get("status"), Some("spawned"))
        assert_eq(m.get("agent_id"), Some("main.remote-1"))
        assert_eq(m.get("host"), Some("user@10.0.0.2"))
      }
      Err(e) => {
        println(e)
        assert_true(false)
      }
    }
  })
}

///|
test "dispatch spawn_remote requires ssh_target" {
  @async.with_event_loop(_ => {
    let call : @tools.ToolCall = {
      role: @types.Role::TL,
      name: "spawn_remote",
      args: {
        "slug": "r1",
        "repo_url": "git@github.com:org/repo.git",
        "tcp_addr": "10.0.0.1:9100",
      },
    }
    let res = @tools.dispatch(call, runner=mock_runner)
    match res {
      Err(e) => assert_true(e.contains("ssh_target"))
      Ok(_) => assert_true(false)
    }
  })
}

///|
test "dispatch spawn_remote denied for Dev role" {
  @async.with_event_loop(_ => {
    let call : @tools.ToolCall = {
      role: @types.Role::Dev,
      name: "spawn_remote",
      args: {
        "ssh_target": "user@host",
        "repo_url": "git@github.com:org/repo.git",
        "tcp_addr": "10.0.0.1:9100",
      },
    }
    let res = @tools.handle_request(
      @tools.ToolRegistry::new(),
      @types.Request::{
        req_method: "tools/call",
        role: call.role,
        name: call.name,
        args: call.args,
      },
      runner=mock_runner,
    )
    match res {
      Err(e) => assert_true(e.contains("cannot call"))
      Ok(_) => assert_true(false)
    }
  })
}

///|
test "handle_request spawn_moon_pilot denied for Dev role" {
  @async.with_event_loop(_ => {
    let reg = @tools.ToolRegistry::new()
    let req = @types.Request::{
      req_method: "tools/call",
      role: @types.Role::Dev,
      name: "spawn_moon_pilot",
      args: { "slug": "mp-1", "task": "do stuff" },
    }
    let res = handle_request(reg, req, runner=mock_runner)
    match res {
      Err(e) => assert_true(e.contains("cannot call"))
      Ok(_) => assert_true(false)
    }
  })
}

///|
test "dispatch spawn_worker validates agent type" {
  @async.with_event_loop(_ => {
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
  @async.with_event_loop(_ => {
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
test "dispatch spawn_worker accepts agent_id alias" {
  @async.with_event_loop(_ => {
    let call : @tools.ToolCall = {
      role: @types.Role::TL,
      name: "spawn_worker",
      args: { "agent_id": "worker-a", "task": "investigate" },
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
  @async.with_event_loop(_ => {
    let reg = @registry.AgentRegistry::new()
    let call : @tools.ToolCall = {
      role: @types.Role::Dev,
      name: "register",
      args: {
        "agent_id": "leaf-0",
        "parent_id": "root",
        "branch": "main.leaf-0",
        "workspace": "/tmp/leaf-0",
        "tmux_target": "choir:leaf-0",
        "agent_type": "gemini",
      },
    }
    let res = @tools.dispatch(call, runner=mock_runner, registry=Some(reg))
    match res {
      Ok(m) => {
        assert_eq(m.get("status"), Some("registered"))
        assert_eq(m.get("agent_id"), Some("leaf-0"))
        match reg.get("leaf-0") {
          Ok(agent) => {
            assert_eq(agent.parent, Some("root"))
            assert_eq(agent.branch, "main.leaf-0")
            assert_eq(agent.workspace, "/tmp/leaf-0")
            assert_eq(agent.tmux_target, Some("choir:leaf-0"))
            assert_eq(agent.agent_type, @types.AgentType::Gemini)
          }
          Err(_) => assert_true(false)
        }
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
  @async.with_event_loop(_ => {
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
  @async.with_event_loop(_ => {
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
test "dispatch shutdown allowed for TL role" {
  @async.with_event_loop(_ => {
    let call : @tools.ToolCall = {
      role: @types.Role::TL,
      name: "shutdown",
      args: { "caller_id": "main.tl-1" },
    }
    let res = @tools.dispatch(call, runner=mock_runner)
    match res {
      Ok(m) => assert_eq(m.get("status"), Some("shutdown"))
      Err(e) => {
        println(e)
        assert_true(false)
      }
    }
  })
}

///|
test "dispatch shutdown blocks during critical review phase" {
  @async.with_event_loop(_ => {
    let poller = @poller.PollerState::new()
    poller.track(42, "leaf-2", 100L)
    poller.tick_with(
      200L,
      900L,
      fn(_) { (@poller.ReviewState::ChangesRequested, "sha1", false, "") },
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
  @async.with_event_loop(_ => {
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

///|
test "dispatch kv_list returns keys" {
  @async.with_event_loop(_ => {
    let project_dir = "/tmp/choir-dispatch-kv-list"
    run_shell(
      "rm -rf /tmp/choir-dispatch-kv-list && mkdir -p /tmp/choir-dispatch-kv-list/.choir/kv/shared && " +
      "printf '%s' 'hello' > /tmp/choir-dispatch-kv-list/.choir/kv/shared/foo && " +
      "printf '%s' 'world' > /tmp/choir-dispatch-kv-list/.choir/kv/shared/bar",
    )
    let call : @tools.ToolCall = {
      role: @types.Role::TL,
      name: "kv_list",
      args: {},
    }
    let res = @tools.dispatch(call, project_dir~, runner=@exec.run_sequence)
    match res {
      Ok(m) => {
        assert_eq(m.get("status"), Some("ok"))
        let keys = m.get("keys").unwrap_or("")
        assert_true(keys.contains("shared/bar"))
        assert_true(keys.contains("shared/foo"))
      }
      Err(e) => {
        println(e)
        assert_true(false)
      }
    }
    run_shell("rm -rf /tmp/choir-dispatch-kv-list")
  })
}

///|
test "dispatch kv_list empty dir returns empty array" {
  @async.with_event_loop(_ => {
    let call : @tools.ToolCall = {
      role: @types.Role::TL,
      name: "kv_list",
      args: {},
    }
    let res = @tools.dispatch(
      call,
      project_dir="/tmp/choir-kv-list-nonexistent-dir-xyz",
      runner=@exec.run_sequence,
    )
    match res {
      Ok(m) => assert_eq(m.get("keys"), Some("[]"))
      Err(e) => {
        println(e)
        assert_true(false)
      }
    }
  })
}

///|
test "dispatch task_create creates task" {
  @async.with_event_loop(_ => {
    let project_dir = "/tmp/choir-dispatch-task-create"
    run_shell("rm -rf /tmp/choir-dispatch-task-create")
    let call : @tools.ToolCall = {
      role: @types.Role::TL,
      name: "task_create",
      args: {
        "id": "task-1",
        "title": "Build the thing",
        "status": "todo",
        "assignee": "dev-1",
        "notes": "initial",
      },
    }
    let res = @tools.dispatch(call, project_dir~, runner=@exec.run_sequence)
    match res {
      Ok(m) => {
        assert_eq(m.get("status"), Some("ok"))
        let task_json = m.get("task").unwrap_or("")
        assert_true(task_json.contains("\"id\":\"task-1\""))
        assert_true(task_json.contains("\"title\":\"Build the thing\""))
        assert_true(task_json.contains("\"status\":\"todo\""))
      }
      Err(e) => {
        println(e)
        assert_true(false)
      }
    }
    run_shell("rm -rf /tmp/choir-dispatch-task-create")
  })
}

///|
test "dispatch task_create fails if already exists" {
  @async.with_event_loop(_ => {
    let project_dir = "/tmp/choir-dispatch-task-create-dup"
    run_shell(
      "rm -rf /tmp/choir-dispatch-task-create-dup && mkdir -p /tmp/choir-dispatch-task-create-dup/.choir/tasks && " +
      "printf '%s' '{\"id\":\"dup\",\"title\":\"Dup\",\"status\":\"todo\",\"assignee\":\"\",\"notes\":\"\"}' > /tmp/choir-dispatch-task-create-dup/.choir/tasks/dup.json",
    )
    let call : @tools.ToolCall = {
      role: @types.Role::TL,
      name: "task_create",
      args: { "id": "dup", "title": "Duplicate" },
    }
    let res = @tools.dispatch(call, project_dir~, runner=@exec.run_sequence)
    match res {
      Err(e) => assert_true(e.contains("already exists"))
      Ok(_) => assert_true(false)
    }
    run_shell("rm -rf /tmp/choir-dispatch-task-create-dup")
  })
}

///|
test "dispatch mutex_acquire, mutex_status, and mutex_release use shared registry" {
  @async.with_event_loop(_ => {
    let mutex_registry = @registry.MutexRegistry::new()

    let acquire_first : @tools.ToolCall = {
      role: @types.Role::Dev,
      name: "mutex_acquire",
      args: { "name": "README", "agent_id": "agent-a", "ttl_sec": "30" },
    }
    let acquire_first_res = @tools.dispatch(
      acquire_first,
      runner=mock_runner,
      mutex_registry=Some(mutex_registry),
    )
    match acquire_first_res {
      Ok(m) => {
        assert_eq(m.get("acquired"), Some("true"))
        assert_eq(m.get("queue_position"), Some("0"))
      }
      Err(e) => {
        println(e)
        assert_true(false)
      }
    }

    let acquire_second : @tools.ToolCall = {
      role: @types.Role::Dev,
      name: "mutex_acquire",
      args: { "name": "README", "agent_id": "agent-b", "ttl_sec": "30" },
    }
    let acquire_second_res = @tools.dispatch(
      acquire_second,
      runner=mock_runner,
      mutex_registry=Some(mutex_registry),
    )
    match acquire_second_res {
      Ok(m) => {
        assert_eq(m.get("acquired"), Some("false"))
        assert_eq(m.get("queue_position"), Some("1"))
      }
      Err(e) => {
        println(e)
        assert_true(false)
      }
    }

    let status_call : @tools.ToolCall = {
      role: @types.Role::Dev,
      name: "mutex_status",
      args: { "name": "README" },
    }
    let status_res = @tools.dispatch(
      status_call,
      runner=mock_runner,
      mutex_registry=Some(mutex_registry),
    )
    match status_res {
      Ok(m) => {
        assert_eq(m.get("holder"), Some("agent-a"))
        assert_eq(m.get("queue_length"), Some("1"))
      }
      Err(e) => {
        println(e)
        assert_true(false)
      }
    }

    let release_call : @tools.ToolCall = {
      role: @types.Role::Dev,
      name: "mutex_release",
      args: { "name": "README", "agent_id": "agent-a" },
    }
    let release_res = @tools.dispatch(
      release_call,
      runner=mock_runner,
      mutex_registry=Some(mutex_registry),
    )
    match release_res {
      Ok(m) => {
        assert_eq(m.get("released"), Some("true"))
        assert_eq(m.get("next_waiter"), Some("agent-b"))
      }
      Err(e) => {
        println(e)
        assert_true(false)
      }
    }
  })
}

///|
test "dispatch mutex_release returns false when agent does not hold or wait" {
  @async.with_event_loop(_ => {
    let mutex_registry = @registry.MutexRegistry::new()
    ignore(mutex_registry.acquire("README", "agent-a", 30L, 10L))

    let release_call : @tools.ToolCall = {
      role: @types.Role::Dev,
      name: "mutex_release",
      args: { "name": "README", "agent_id": "agent-z" },
    }
    let release_res = @tools.dispatch(
      release_call,
      runner=mock_runner,
      mutex_registry=Some(mutex_registry),
    )
    match release_res {
      Ok(m) => {
        assert_eq(m.get("released"), Some("false"))
        assert_eq(m.get("next_waiter"), Some(""))
      }
      Err(e) => {
        println(e)
        assert_true(false)
      }
    }
  })
}

///|
test "dispatch merge_pr blocks concurrent merges on the same parent_branch" {
  @async.with_event_loop(_ => {
    let mutex_registry = @registry.MutexRegistry::new()
    let nested_results : Array[@types.Response] = []
    let runner = async fn(cmds : Array[@workspace.Command]) -> Array[Int] {
      let nested_call : @tools.ToolCall = {
        role: @types.Role::TL,
        name: "merge_pr",
        args: {
          "pr_number": "102",
          "parent_branch": "release",
          "caller_id": "agent-b",
        },
      }
      nested_results.push(
        @tools.dispatch(
          nested_call,
          runner=mock_runner,
          mutex_registry=Some(mutex_registry),
        ),
      )
      let statuses = []
      for _ in cmds {
        statuses.push(0)
      }
      statuses
    }
    let first_call : @tools.ToolCall = {
      role: @types.Role::TL,
      name: "merge_pr",
      args: {
        "pr_number": "101",
        "parent_branch": "release",
        "caller_id": "agent-a",
      },
    }
    let first_res = @tools.dispatch(
      first_call,
      runner~,
      mutex_registry=Some(mutex_registry),
    )
    match first_res {
      Ok(m) => assert_eq(m.get("status"), Some("merged"))
      Err(e) => {
        println(e)
        assert_true(false)
      }
    }
    assert_eq(nested_results.length(), 1)
    match nested_results[0] {
      Ok(_) => assert_true(false)
      Err(e) =>
        assert_eq(
          e, "merge serialization lock held by another agent, retry shortly",
        )
    }
    let (holder, queue) = mutex_registry.status("branch:release")
    assert_eq(holder, None)
    assert_eq(queue.length(), 0)
  })
}

///|
test "dispatch fork_session creates session dir" {
  @async.with_event_loop(_ => {
    let project_dir = "/tmp/choir-dispatch-fork-session"
    run_shell("rm -rf /tmp/choir-dispatch-fork-session")
    let call : @tools.ToolCall = {
      role: @types.Role::TL,
      name: "fork_session",
      args: { "name": "sub-team-1" },
    }
    let res = @tools.dispatch(call, project_dir~, runner=@exec.run_sequence)
    match res {
      Ok(m) => {
        assert_eq(m.get("status"), Some("ok"))
        assert_eq(m.get("name"), Some("sub-team-1"))
        let session_dir = m.get("session_dir").unwrap_or("")
        assert_true(session_dir.contains("sub-team-1"))
        run_shell(
          "test -d /tmp/choir-dispatch-fork-session/.choir/sessions/sub-team-1",
        )
      }
      Err(e) => {
        println(e)
        assert_true(false)
      }
    }
    let context_json = @io.read_file(
      project_dir + "/.choir/sessions/sub-team-1/context.json",
    )
    assert_true(context_json.contains("\"name\":\"sub-team-1\""))
    assert_true(context_json.contains("\"created_sec\":\""))
    run_shell("rm -rf /tmp/choir-dispatch-fork-session")
  })
}

///|
test "dispatch fork_session rejects invalid name" {
  @async.with_event_loop(_ => {
    let call : @tools.ToolCall = {
      role: @types.Role::TL,
      name: "fork_session",
      args: { "name": "../evil" },
    }
    let res = @tools.dispatch(call, runner=mock_runner)
    match res {
      Err(e) => assert_true(e.contains("invalid name"))
      Ok(_) => assert_true(false)
    }
  })
}

///|
test "handle_request fork_session denied for Dev role" {
  @async.with_event_loop(_ => {
    let reg = @tools.ToolRegistry::new()
    let req = @types.Request::{
      req_method: "tools/call",
      role: @types.Role::Dev,
      name: "fork_session",
      args: { "name": "sub-team-1" },
    }
    let res = handle_request(reg, req, runner=mock_runner)
    match res {
      Err(e) => assert_true(e.contains("cannot call"))
      Ok(_) => assert_true(false)
    }
  })
}
