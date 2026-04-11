///|
let handler_test_subscribers : Ref[Array[(@moontrace.Event) -> Unit]] = {
  val: [],
}

///|
fn handler_setup_test_moontrace() -> Unit {
  @moontrace.set_subscriber(fn(event) {
    for sub in handler_test_subscribers.val {
      sub(event)
    }
  })
}

///|
async fn handler_with_moontrace_capture(
  captured : Array[@moontrace.Event],
  f : async () -> Unit,
) -> Unit {
  let sub = fn(event : @moontrace.Event) { captured.push(event) }
  handler_test_subscribers.val.push(sub)
  f() catch {
    err => {
      let _ = handler_test_subscribers.val.pop()
      raise err
    }
  }
  let _ = handler_test_subscribers.val.pop()
}

///|
fn handler_auto_close_test_state(label : String) -> ServerState {
  let project_dir = "/tmp/choir-handler-auto-close-" +
    label +
    "-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.system("mkdir -p " + project_dir + "/.choir/kv"))
  let config = {
    ..@types.Config::default(),
    project_dir,
    terminal_session: "test-session",
  }
  ServerState::new(config, make_recovery_provider())
}

///|
fn handler_auto_close_target(label : String) -> @types.LocalTarget {
  { kind: @types.TargetKind::ZellijPane, session: "test-session", name: label }
}

///|
fn handler_close_terminal_warn_count(events : Array[@moontrace.Event]) -> Int {
  let mut count = 0
  for event in events {
    if event.level == @moontrace.Level::Warn &&
      event.message == "CloseTerminal failed" {
      count = count + 1
    }
  }
  count
}

///|
async test "test_close_terminal_warns_on_nonzero_exit" {
  handler_setup_test_moontrace()
  let state = handler_auto_close_test_state("close-warn")
  let target = handler_auto_close_target("leaf-pane")
  let captured : Array[@moontrace.Event] = []
  handler_with_moontrace_capture(captured, async fn() {
    state.interpret_teardown_effects([CloseTerminal(target)], _cmds => [1])
  })
  assert_eq(handler_close_terminal_warn_count(captured), 1)
}

///|
async test "test_close_terminal_no_warn_on_zero_exit" {
  handler_setup_test_moontrace()
  let state = handler_auto_close_test_state("close-ok")
  let target = handler_auto_close_target("leaf-pane")
  let captured : Array[@moontrace.Event] = []
  handler_with_moontrace_capture(captured, async fn() {
    state.interpret_teardown_effects([CloseTerminal(target)], _cmds => [0])
  })
  assert_eq(handler_close_terminal_warn_count(captured), 0)
}

///|
async test "test_close_terminal_warns_on_error" {
  handler_setup_test_moontrace()
  let state = handler_auto_close_test_state("close-error")
  let target = handler_auto_close_target("leaf-pane")
  let captured : Array[@moontrace.Event] = []
  handler_with_moontrace_capture(captured, async fn() {
    state.interpret_teardown_effects([CloseTerminal(target)], _cmds => {
      raise @types.ChoirError::agent_not_found("test error")
    })
  })
  assert_eq(handler_close_terminal_warn_count(captured), 1)
}

///|
fn handler_auto_close_agent(
  agent_id : String,
  state : @types.AgentState,
  target : @types.LocalTarget?,
) -> @types.Agent {
  {
    agent_id: @types.AgentId(agent_id),
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Claude,
    parent: Some("main.parent"),
    workspace: "/tmp/choir-handler-auto-close-workspace",
    branch: agent_id,
    terminal_target: target,
    host: @types.Host::Local,
    spawn_depth: 0,
    state,
  }
}

///|
async test "test_disconnect_done_agent_closes_pane" {
  let state = handler_auto_close_test_state("disconnect-done")
  let agent_id = "main.done-leaf"
  let target = handler_auto_close_target("done-pane")
  ignore(
    state.register_agent(handler_auto_close_agent(agent_id, Done, Some(target))),
  )
  let expected = @workspace.local_close_target(target)
  let calls : Array[@workspace.Command] = []
  state.handle_disconnect_with_runner(agent_id, runner=async fn(cmds) {
    @async.sleep(0)
    for cmd in cmds {
      calls.push(cmd)
    }
    [0]
  })
  assert_eq(calls.length(), 1)
  assert_eq(calls[0], expected)
}

///|
async test "test_disconnect_failed_agent_closes_pane" {
  let state = handler_auto_close_test_state("disconnect-failed")
  let agent_id = "main.failed-leaf"
  let target = handler_auto_close_target("failed-pane")
  ignore(
    state.register_agent(
      handler_auto_close_agent(agent_id, Failed, Some(target)),
    ),
  )
  let expected = @workspace.local_close_target(target)
  let calls : Array[@workspace.Command] = []
  state.handle_disconnect_with_runner(agent_id, runner=async fn(cmds) {
    @async.sleep(0)
    for cmd in cmds {
      calls.push(cmd)
    }
    [0]
  })
  assert_eq(calls.length(), 1)
  assert_eq(calls[0], expected)
}

///|
async test "test_disconnect_done_agent_no_target_no_call" {
  let state = handler_auto_close_test_state("disconnect-done-no-target")
  let agent_id = "main.done-leaf-no-target"
  ignore(state.register_agent(handler_auto_close_agent(agent_id, Done, None)))
  let calls : Array[@workspace.Command] = []
  state.handle_disconnect_with_runner(agent_id, runner=async fn(cmds) {
    @async.sleep(0)
    for cmd in cmds {
      calls.push(cmd)
    }
    [0]
  })
  assert_eq(calls.length(), 0)
}

///|
async test "test_disconnect_completing_agent_no_close" {
  let state = handler_auto_close_test_state("disconnect-completing")
  let agent_id = "main.completing-leaf"
  let target = handler_auto_close_target("completing-pane")
  ignore(
    state.register_agent(
      handler_auto_close_agent(agent_id, Completing, Some(target)),
    ),
  )
  let close_cmd = @workspace.local_close_target(target)
  let calls : Array[@workspace.Command] = []
  state.handle_disconnect_with_runner(agent_id, runner=async fn(cmds) {
    @async.sleep(0)
    for cmd in cmds {
      calls.push(cmd)
    }
    [0]
  })

  let agent = state.registry.get(agent_id) catch {
    _ => fail("agent not found")
  }
  assert_eq(agent.state, Done)

  for cmd in calls {
    assert_false(cmd == close_cmd)
  }
}
