///|
fn inbox_test_state(label : String) -> @server.ServerState {
  let project_dir = "/tmp/choir-inbox-" +
    label +
    "-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  @server.ServerState::new(
    { ..@types.Config::default(), project_dir, },
    @server.make_hermetic_recovery_provider(),
    path_exists=fn(path) { path.has_suffix("/.choir/audit-gate.json") },
    boot_read_file=fn(_path) { "" },
    write_file_atomic=fn(_path, _content) { true },
    now_unix_sec=fn() { 1779970000L },
  )
}

///|
test "queue then drain delivers in order and acks via the pull" {
  let state = inbox_test_state("drain")
  assert_eq(
    state.queue_inbox_message(
      "main.tl",
      "main.leaf-a",
      "[PR READY: main.leaf-a]",
      @types.Status::Success,
    ),
    1,
  )
  assert_eq(
    state.queue_inbox_message(
      "main.tl",
      "poller",
      "[REVIEW] PR #561: changes requested",
      @types.Status::Info,
    ),
    2,
  )
  assert_eq(state.pending_inbox_count("main.tl"), 2)
  let drained = state.drain_inbox("main.tl")
  assert_eq(drained.length(), 2)
  assert_eq(drained[0].sender_id, "main.leaf-a")
  assert_eq(drained[0].body, "[PR READY: main.leaf-a]")
  assert_eq(drained[1].sender_id, "poller")
  assert_eq(state.pending_inbox_count("main.tl"), 0)
  assert_eq(state.drain_inbox("main.tl").length(), 0)
  // Journal observability: queued and delivered events exist for each.
  match @server.TuiJournal::events_since(state.journal, 0L) {
    @server.TuiEventsSinceResult::Events(events) => {
      let mut queued = 0
      let mut delivered = 0
      for envelope in events {
        match envelope.event {
          @types.TuiEvent::MessageQueued(_, ..) => queued = queued + 1
          @types.TuiEvent::MessageDelivered(_, ..) => delivered = delivered + 1
          _ => ()
        }
      }
      assert_eq(queued, 2)
      assert_eq(delivered, 2)
    }
    _ => fail("expected journal events")
  }
}

///|
test "check_inbox handler drains the caller's queue only" {
  let state = inbox_test_state("handler")
  ignore(
    state.queue_inbox_message(
      "main.leaf-a",
      "main.tl",
      "steer left",
      @types.Status::Info,
    ),
  )
  ignore(
    state.queue_inbox_message(
      "main.leaf-b",
      "main.tl",
      "steer right",
      @types.Status::Info,
    ),
  )
  let req : @types.Request = {
    req_method: "tools/call",
    role: @types.Role::Dev,
    name: "check_inbox",
    args: @types.RequestArgs::from_values({
      "caller_id": "main.leaf-a".to_json(),
    }),
  }
  let resp = state.handle_check_inbox_request(req)
  assert_true(resp.is_ok())
  match resp.ok_payload() {
    Some(fields) => {
      @debug.assert_eq(fields.get_json("count"), Some((1 : Json)))
      match fields.get_json("messages") {
        Some(Array(items)) => {
          assert_eq(items.length(), 1)
          assert_true(items[0].stringify().contains("steer left"))
        }
        _ => fail("expected messages array")
      }
    }
    None => fail("expected ok payload")
  }
  assert_eq(state.pending_inbox_count("main.leaf-a"), 0)
  assert_eq(state.pending_inbox_count("main.leaf-b"), 1)
  // Missing caller is rejected; Operator is not an agent and cannot drain.
  let missing : @types.Request = {
    req_method: "tools/call",
    role: @types.Role::Dev,
    name: "check_inbox",
    args: @types.RequestArgs::from_values({}),
  }
  assert_true(!state.handle_check_inbox_request(missing).is_ok())
  let operator : @types.Request = {
    req_method: "tools/call",
    role: @types.Role::Operator,
    name: "check_inbox",
    args: @types.RequestArgs::from_values({
      "caller_id": "operator-tui".to_json(),
    }),
  }
  assert_true(!state.handle_check_inbox_request(operator).is_ok())
}

///|
test "inbox persists via checkpoint writes and survives boot" {
  let state = inbox_test_state("persist")
  let project_dir = state.config.project_dir
  ignore(@sys.create_dir_all(project_dir + "/.choir"))
  ignore(
    state.queue_inbox_message(
      "main.tl",
      "main.leaf-a",
      "hello",
      @types.Status::Info,
    ),
  )
  let inbox_path = project_dir + "/.choir/inbox.json"
  let persisted = @sys.read_file(inbox_path)
  assert_true(persisted.contains("hello"))
  // Boot a fresh state from the persisted checkpoint.
  let reborn = @server.ServerState::new(
    { ..@types.Config::default(), project_dir, },
    @server.make_hermetic_recovery_provider(),
    path_exists=fn(path) {
      path.has_suffix("/.choir/audit-gate.json") || path == inbox_path
    },
    boot_read_file=fn(path) { if path == inbox_path { persisted } else { "" } },
    write_file_atomic=fn(_path, _content) { true },
    now_unix_sec=fn() { 1779970001L },
  )
  assert_eq(reborn.pending_inbox_count("main.tl"), 1)
  let drained = reborn.drain_inbox("main.tl")
  assert_eq(drained[0].body, "hello")
  ignore(@sys.rm_rf(project_dir))
}

///|
test "plan_delivery_via_inbox shrinks terminal payload to the fixed nudge" {
  let target = match @types.LocalTarget::parse("zellij-tab:choir:tl") {
    Some(value) => value
    None => {
      fail("expected parseable target")
      return
    }
  }
  let agent : @types.Agent = {
    agent_id: "main.tl",
    role: @types.Role::TL,
    agent_type: @types.AgentType::Claude,
    parent: None,
    workspace: "/tmp/project",
    branch: "main",
    terminal_target: Some(target),
    host: @types.Host::Local,
    state: @types.AgentState::Active,
    spawn_depth: 0,
  }
  let queued : Array[(String, String, String)] = []
  let planned = @message.plan_delivery_via_inbox(
    agent,
    "main.leaf-a",
    "long review feedback body",
    @types.Status::Info,
    fn(recipient, sender, body, _status) {
      queued.push((recipient, sender, body))
      Some(3)
    },
  )
  assert_eq(queued.length(), 1)
  assert_eq(queued[0].2, "long review feedback body")
  match planned {
    @message.DeliveryMethod::LocalTerminalInput(_, text) => {
      assert_eq(text, "choir: 3 messages pending — call check_inbox")
      assert_false(text.contains("review feedback"))
    }
    _ => fail("expected terminal nudge delivery")
  }
  // No inbox capability: legacy full-content plan unchanged.
  match
    @message.plan_delivery_via_inbox(
      agent,
      "main.leaf-a",
      "content",
      @types.Status::Info,
      fn(_r, _s, _b, _st) { None },
    ) {
    @message.DeliveryMethod::LocalTerminalInput(_, text) =>
      assert_true(text.contains("content"))
    _ => fail("expected terminal delivery")
  }
}
