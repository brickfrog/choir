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
fn inbox_test_agent(agent_id : String, role : @types.Role) -> @types.Agent {
  {
    agent_id,
    role,
    agent_type: @types.AgentType::Codex,
    parent: None,
    workspace: "/tmp/ws/" + agent_id,
    branch: agent_id,
    terminal_target: None,
    host: @types.Host::Local,
    state: @types.AgentState::Active,
    spawn_depth: 1,
  }
}

///|
fn inbox_test_target() -> @types.LocalTarget {
  match @types.LocalTarget::parse("zellij-tab:choir:tl") {
    Some(value) => value
    None => abort("expected parseable target")
  }
}

///|
async fn inbox_test_sleep(_ms : Int) -> Unit {
  @async.sleep(0)
}

///|
fn inbox_test_sent_runner(
  sent : Array[String],
  status : Int,
) -> async (Array[@workspace.Command]) -> Array[Int] {
  async fn(cmds : Array[@workspace.Command]) -> Array[Int] {
    @async.sleep(0)
    let statuses : Array[Int] = []
    for cmd in cmds {
      if cmd.program == "choir" &&
        cmd.args.length() >= 4 &&
        cmd.args[0] == "zellij-action" &&
        cmd.args[1] == "send" {
        sent.push(cmd.args[3])
      }
      statuses.push(status)
    }
    statuses
  }
}

///|
fn inbox_test_pending_message(
  message_id : String,
  body : String,
  state : @types.InboxDeliveryState,
  queued_at_unix : Int64,
  nudge_attempts : Int,
  recipient_id? : String = "main.tl",
) -> @types.InboxMessage {
  {
    message_id,
    sender_id: "main.leaf",
    recipient_id,
    body,
    status: @types.Status::Info,
    queued_at_unix,
    delivery_state: state,
    nudge_attempts,
    last_nudged_at_unix: None,
  }
}

///|
async test "delivery then drain delivers pending rows in order and acks via state" {
  let state = inbox_test_state("drain")
  let sent : Array[String] = []
  match
    state.deliver_inbox_terminal_message(
      "main.tl",
      inbox_test_target(),
      "main.leaf-a",
      "[PR READY: main.leaf-a]\nbody",
      @types.Status::Success,
      inbox_test_sent_runner(sent, 0),
      now_unix_sec=1000L,
      sleep_fn=inbox_test_sleep,
    ) {
    Ok(_) => ()
    Err(e) => fail("expected first nudge: " + e.message())
  }
  match
    state.deliver_inbox_terminal_message(
      "main.tl",
      inbox_test_target(),
      "poller",
      "[REVIEW] PR #561: changes requested\nbody",
      @types.Status::Info,
      inbox_test_sent_runner(sent, 0),
      now_unix_sec=1001L,
      sleep_fn=inbox_test_sleep,
    ) {
    Ok(_) => ()
    Err(e) => fail("expected second nudge: " + e.message())
  }
  assert_eq(state.pending_inbox_count("main.tl"), 2)
  let drained = state.drain_inbox("main.tl")
  assert_eq(drained.length(), 2)
  assert_eq(drained[0].sender_id, "main.leaf-a")
  assert_eq(drained[0].body, "[PR READY: main.leaf-a]\nbody")
  assert_eq(drained[1].sender_id, "poller")
  assert_eq(state.pending_inbox_count("main.tl"), 0)
  assert_eq(state.drain_inbox("main.tl").length(), 0)
  match state.inboxes.get("main.tl") {
    Some(messages) => {
      assert_eq(messages.length(), 2)
      assert_eq(messages[0].delivery_state, @types.InboxDeliveryState::Drained)
      assert_eq(messages[1].delivery_state, @types.InboxDeliveryState::Drained)
    }
    None => fail("expected durable inbox audit rows")
  }
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
    state.registry.upsert(inbox_test_agent("main.leaf-a", @types.Role::Dev)),
  )
  ignore(
    state.registry.upsert(inbox_test_agent("main.leaf-b", @types.Role::Dev)),
  )
  state.inboxes.set("main.leaf-a", [
    inbox_test_pending_message(
      "leaf-a-msg",
      "steer left",
      @types.InboxDeliveryState::Pending,
      100L,
      0,
      recipient_id="main.leaf-a",
    ),
  ])
  state.inboxes.set("main.leaf-b", [
    inbox_test_pending_message(
      "leaf-b-msg",
      "steer right",
      @types.InboxDeliveryState::Pending,
      100L,
      0,
      recipient_id="main.leaf-b",
    ),
  ])
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
  match state.inboxes.get("main.leaf-a") {
    Some(messages) => {
      assert_eq(messages.length(), 1)
      assert_eq(messages[0].delivery_state, @types.InboxDeliveryState::Drained)
    }
    None => fail("expected durable drained audit row")
  }
  let mismatched : @types.Request = {
    req_method: "tools/call",
    role: @types.Role::TL,
    name: "check_inbox",
    args: @types.RequestArgs::from_values({
      "caller_id": "main.leaf-b".to_json(),
    }),
  }
  assert_true(!state.handle_check_inbox_request(mismatched).is_ok())
  assert_eq(state.pending_inbox_count("main.leaf-b"), 1)
  // Missing/unknown callers are rejected; Operator is not an agent and cannot drain.
  let missing : @types.Request = {
    req_method: "tools/call",
    role: @types.Role::Dev,
    name: "check_inbox",
    args: @types.RequestArgs::from_values({}),
  }
  assert_true(!state.handle_check_inbox_request(missing).is_ok())
  let unknown : @types.Request = {
    req_method: "tools/call",
    role: @types.Role::Dev,
    name: "check_inbox",
    args: @types.RequestArgs::from_values({ "caller_id": "main.nope".to_json() }),
  }
  assert_true(!state.handle_check_inbox_request(unknown).is_ok())
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
async test "inbox persists via checkpoint writes and survives boot" {
  let state = inbox_test_state("persist")
  let project_dir = state.config.project_dir
  ignore(@sys.create_dir_all(project_dir + "/.choir"))
  let sent : Array[String] = []
  match
    state.deliver_inbox_terminal_message(
      "main.tl",
      inbox_test_target(),
      "main.leaf-a",
      "hello\npending",
      @types.Status::Info,
      inbox_test_sent_runner(sent, 0),
      now_unix_sec=1000L,
      sleep_fn=inbox_test_sleep,
    ) {
    Ok(_) => ()
    Err(e) => fail("expected nudge delivery: " + e.message())
  }
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
  assert_eq(drained[0].body, "hello\npending")
  match reborn.inboxes.get("main.tl") {
    Some(messages) =>
      assert_eq(messages[0].delivery_state, @types.InboxDeliveryState::Drained)
    None => fail("expected durable inbox audit rows after drain")
  }
  ignore(@sys.rm_rf(project_dir))
}

///|
test "terminal delivery planning is pure and queues nothing while planning" {
  let state = inbox_test_state("plan-pure")
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
  let first = @message.plan_delivery(
    agent,
    "main.leaf-a",
    "long review feedback body",
    @types.Status::Info,
  )
  let second = @message.plan_delivery(
    agent,
    "main.leaf-a",
    "long review feedback body",
    @types.Status::Info,
  )
  assert_eq(state.pending_inbox_count("main.tl"), 0)
  assert_eq(first, second)
  match first {
    @message.DeliveryMethod::LocalTerminalInput(_, text) =>
      assert_eq(text, "[from: main.leaf-a] long review feedback body")
    _ => fail("expected terminal delivery")
  }
}

///|
async test "control characters route through inbox nudge and stay pending" {
  let cases = [
    ("escape", Int::unsafe_to_char(0x1B).to_string()),
    ("ctrl-c", Int::unsafe_to_char(0x03).to_string()),
  ]
  for item in cases {
    let (label, control) = item
    let state = inbox_test_state("control-" + label)
    let sent : Array[String] = []
    match
      state.deliver_inbox_terminal_message(
        "main.tl",
        inbox_test_target(),
        "main.leaf",
        "safe" + control + "body",
        @types.Status::Info,
        inbox_test_sent_runner(sent, 0),
        now_unix_sec=1000L,
        sleep_fn=inbox_test_sleep,
      ) {
      Ok(_) => ()
      Err(e) => fail("expected control-char nudge success: " + e.message())
    }
    assert_eq(sent.length(), 1)
    assert_true(sent[0] == "choir: 1 message pending — call check_inbox")
    assert_eq(state.pending_inbox_count("main.tl"), 1)
    match state.inboxes.get("main.tl") {
      Some(messages) => {
        assert_eq(messages.length(), 1)
        assert_eq(
          messages[0].delivery_state,
          @types.InboxDeliveryState::Pending,
        )
      }
      None => fail("expected durable pending row")
    }
  }
}

///|
async test "inline delivery sends single-line trimmed bodies up to 200 chars and marks delivered" {
  let state = inbox_test_state("inline-200")
  let sent : Array[String] = []
  let body = "x".repeat(200)
  match
    state.deliver_inbox_terminal_message(
      "main.tl",
      inbox_test_target(),
      "main.leaf",
      body,
      @types.Status::Info,
      inbox_test_sent_runner(sent, 0),
      now_unix_sec=1000L,
      sleep_fn=inbox_test_sleep,
    ) {
    Ok(_) => ()
    Err(e) => fail("expected inline delivery success: " + e.message())
  }
  assert_eq(sent.length(), 1)
  assert_eq(sent[0], "[from: main.leaf] " + body)
  assert_eq(state.pending_inbox_count("main.tl"), 0)
  match state.inboxes.get("main.tl") {
    Some(messages) => {
      assert_eq(messages.length(), 1)
      assert_eq(
        messages[0].delivery_state,
        @types.InboxDeliveryState::DeliveredInline,
      )
      assert_eq(messages[0].nudge_attempts, 1)
    }
    None => fail("expected durable inline audit row")
  }
}

///|
async test "embedded newlines route through overflow nudge and stay pending for drain" {
  let state = inbox_test_state("newline-overflow")
  let sent : Array[String] = []
  match
    state.deliver_inbox_terminal_message(
      "main.tl",
      inbox_test_target(),
      "main.leaf",
      "line one\nline two",
      @types.Status::Info,
      inbox_test_sent_runner(sent, 0),
      now_unix_sec=1000L,
      sleep_fn=inbox_test_sleep,
    ) {
    Ok(_) => ()
    Err(e) => fail("expected overflow nudge success: " + e.message())
  }
  assert_eq(sent.length(), 1)
  assert_eq(sent[0], "choir: 1 message pending — call check_inbox")
  assert_eq(state.pending_inbox_count("main.tl"), 1)
  let drained = state.drain_inbox("main.tl")
  assert_eq(drained.length(), 1)
  assert_eq(drained[0].body, "line one\nline two")
  match state.inboxes.get("main.tl") {
    Some(messages) =>
      assert_eq(messages[0].delivery_state, @types.InboxDeliveryState::Drained)
    None => fail("expected durable drained audit row")
  }
}

///|
async test "send-keys failure returns queued ok and leaves inline rows pending after one attempt" {
  let state = inbox_test_state("inline-fail")
  let sent : Array[String] = []
  match
    state.deliver_inbox_terminal_message(
      "main.tl",
      inbox_test_target(),
      "main.leaf",
      "small body",
      @types.Status::Info,
      inbox_test_sent_runner(sent, 1),
      now_unix_sec=1000L,
      sleep_fn=inbox_test_sleep,
    ) {
    Ok(_) => ()
    Err(e) =>
      fail(
        "expected durable queued ok despite terminal failure: " + e.message(),
      )
  }
  assert_eq(sent.length(), 1)
  assert_eq(sent[0], "[from: main.leaf] small body")
  assert_eq(state.pending_inbox_count("main.tl"), 1)
  match state.inboxes.get("main.tl") {
    Some(messages) => {
      assert_eq(messages.length(), 1)
      assert_eq(messages[0].delivery_state, @types.InboxDeliveryState::Pending)
      assert_eq(messages[0].nudge_attempts, 1)
    }
    None => fail("expected durable pending row")
  }
}

///|
async test "inline mark after drain preserves drained state" {
  let state = inbox_test_state("inline-drain-race")
  let sent : Array[String] = []
  match
    state.deliver_inbox_terminal_message(
      "main.tl",
      inbox_test_target(),
      "main.leaf",
      "small body",
      @types.Status::Info,
      async fn(cmds : Array[@workspace.Command]) -> Array[Int] {
        @async.sleep(0)
        for cmd in cmds {
          if cmd.program == "choir" &&
            cmd.args.length() >= 4 &&
            cmd.args[0] == "zellij-action" &&
            cmd.args[1] == "send" {
            sent.push(cmd.args[3])
          }
        }
        let drained = state.drain_inbox("main.tl")
        assert_eq(drained.length(), 1)
        let statuses : Array[Int] = []
        for _ in cmds {
          statuses.push(0)
        }
        statuses
      },
      now_unix_sec=1000L,
      sleep_fn=inbox_test_sleep,
    ) {
    Ok(_) => ()
    Err(e) => fail("expected inline delivery success: " + e.message())
  }
  assert_eq(sent.length(), 1)
  match state.inboxes.get("main.tl") {
    Some(messages) => {
      assert_eq(messages.length(), 1)
      assert_eq(messages[0].delivery_state, @types.InboxDeliveryState::Drained)
    }
    None => fail("expected durable inbox row")
  }
}

///|
async test "same millisecond same content creates unique inbox message ids" {
  let state = inbox_test_state("unique-ids")
  let sent : Array[String] = []
  for _ in 0..<2 {
    match
      state.deliver_inbox_terminal_message(
        "main.tl",
        inbox_test_target(),
        "main.leaf",
        "same body",
        @types.Status::Info,
        inbox_test_sent_runner(sent, 1),
        now_unix_sec=1000L,
        sleep_fn=inbox_test_sleep,
      ) {
      Ok(_) => ()
      Err(e) => fail("expected queued ok: " + e.message())
    }
  }
  assert_eq(sent.length(), 2)
  match state.inboxes.get("main.tl") {
    Some(messages) => {
      assert_eq(messages.length(), 2)
      assert_true(messages[0].message_id != messages[1].message_id)
    }
    None => fail("expected durable inbox rows")
  }
}

///|
async test "sweep failed inline attempt is retried only by later sweep cycles" {
  let state = inbox_test_state("sweep-single-attempt")
  ignore(
    state.registry.upsert({
      ..inbox_test_agent("main.tl", @types.Role::TL),
      terminal_target: Some(inbox_test_target()),
    }),
  )
  state.inboxes.set("main.tl", [
    inbox_test_pending_message(
      "stale",
      "stale body",
      @types.InboxDeliveryState::Pending,
      100L,
      0,
    ),
  ])
  let sent : Array[String] = []
  state.sweep_stale_inbox_nudges(
    300L,
    inbox_test_sent_runner(sent, 1),
    sleep_fn=inbox_test_sleep,
  )
  assert_eq(sent.length(), 1)
  state.sweep_stale_inbox_nudges(
    421L,
    inbox_test_sent_runner(sent, 1),
    sleep_fn=inbox_test_sleep,
  )
  assert_eq(sent.length(), 2)
  match state.inboxes.get("main.tl") {
    Some(messages) => {
      assert_eq(messages[0].delivery_state, @types.InboxDeliveryState::Pending)
      assert_eq(messages[0].nudge_attempts, 2)
    }
    None => fail("expected inbox row")
  }
}

///|
async test "system-tagged inline bodies are not double prefixed" {
  let state = inbox_test_state("system-tag")
  let sent : Array[String] = []
  let body = @message.format_failure("main.leaf", "child failed")
  match
    state.deliver_inbox_terminal_message(
      "main.tl",
      inbox_test_target(),
      "main.leaf",
      body,
      @types.Status::Failure,
      inbox_test_sent_runner(sent, 0),
      now_unix_sec=1000L,
      sleep_fn=inbox_test_sleep,
    ) {
    Ok(_) => ()
    Err(e) => fail("expected inline delivery success: " + e.message())
  }
  assert_eq(sent.length(), 1)
  assert_eq(sent[0], body)
}

///|
async test "sweep re-nudges only stale pending rows and skips delivered rows" {
  let state = inbox_test_state("sweep-stale")
  ignore(
    state.registry.upsert({
      ..inbox_test_agent("main.tl", @types.Role::TL),
      terminal_target: Some(inbox_test_target()),
    }),
  )
  state.inboxes.set("main.tl", [
    inbox_test_pending_message(
      "stale",
      "stale body",
      @types.InboxDeliveryState::Pending,
      100L,
      0,
    ),
    inbox_test_pending_message(
      "fresh",
      "fresh body",
      @types.InboxDeliveryState::Pending,
      250L,
      0,
    ),
    inbox_test_pending_message(
      "delivered",
      "delivered body",
      @types.InboxDeliveryState::DeliveredInline,
      100L,
      0,
    ),
  ])
  let sent : Array[String] = []
  state.sweep_stale_inbox_nudges(
    300L,
    inbox_test_sent_runner(sent, 0),
    sleep_fn=inbox_test_sleep,
  )
  assert_eq(sent.length(), 1)
  assert_eq(sent[0], "[from: main.leaf] stale body")
  match state.inboxes.get("main.tl") {
    Some(messages) => {
      assert_eq(
        messages[0].delivery_state,
        @types.InboxDeliveryState::DeliveredInline,
      )
      assert_eq(messages[0].nudge_attempts, 1)
      assert_eq(messages[1].delivery_state, @types.InboxDeliveryState::Pending)
      assert_eq(messages[1].nudge_attempts, 0)
      assert_eq(
        messages[2].delivery_state,
        @types.InboxDeliveryState::DeliveredInline,
      )
      assert_eq(messages[2].nudge_attempts, 0)
    }
    None => fail("expected inbox rows")
  }
}

///|
async test "sweep respects the five-attempt nudge cap" {
  let state = inbox_test_state("sweep-cap")
  ignore(
    state.registry.upsert({
      ..inbox_test_agent("main.tl", @types.Role::TL),
      terminal_target: Some(inbox_test_target()),
    }),
  )
  state.inboxes.set("main.tl", [
    inbox_test_pending_message(
      "capped",
      "capped body",
      @types.InboxDeliveryState::Pending,
      100L,
      5,
    ),
  ])
  let sent : Array[String] = []
  state.sweep_stale_inbox_nudges(
    300L,
    inbox_test_sent_runner(sent, 0),
    sleep_fn=inbox_test_sleep,
  )
  assert_eq(sent.length(), 0)
  assert_eq(state.pending_inbox_count("main.tl"), 1)
}

///|
async test "delivery planning and execution produce one durable inbox row" {
  let state = inbox_test_state("single-enqueue-behavior")
  let sent : Array[String] = []
  match
    state.deliver_inbox_terminal_message(
      "main.tl",
      inbox_test_target(),
      "main.leaf",
      "hello",
      @types.Status::Info,
      inbox_test_sent_runner(sent, 0),
      now_unix_sec=1000L,
      sleep_fn=inbox_test_sleep,
    ) {
    Ok(_) => ()
    Err(e) => fail("expected inline delivery success: " + e.message())
  }
  assert_eq(sent.length(), 1)
  match state.inboxes.get("main.tl") {
    Some(messages) => {
      assert_eq(messages.length(), 1)
      assert_eq(messages[0].sender_id, "main.leaf")
      assert_eq(messages[0].recipient_id, "main.tl")
      assert_eq(messages[0].body, "hello")
    }
    None => fail("expected durable inbox row")
  }
}
