///|
test "notify_parent_plan no registry records success event and ok response" {
  let args : CallerMessageArgs = {
    caller_id: "main.leaf",
    message: "done",
    status: @types.Status::Success,
  }
  match notify_parent_plan(args, None) {
    NotifyParentPlan::NoRegistry(dev_event~, response~) => {
      assert_eq(dev_event, @phase.DevEvent::NotifyParentSuccess(message="done"))
      match response {
        @types.Response::Ok(fields) => {
          let map = fields.to_json_map()
          @debug.assert_eq(map.get("status"), Some(String::to_json("notified")))
        }
        _ => fail("expected ok response")
      }
    }
    _ => fail("expected NoRegistry")
  }
}

///|
test "notify_parent_plan maps parent resolve error to ParentResolveFailed" {
  let args : CallerMessageArgs = {
    caller_id: "main.leaf",
    message: "x",
    status: @types.Status::Info,
  }
  let err = @types.ChoirError::agent_not_found("main.tl")
  match notify_parent_plan(args, Some(Err(err))) {
    NotifyParentPlan::ParentResolveFailed(error_message~) =>
      assert_eq(error_message, err.message())
    _ => fail("expected ParentResolveFailed")
  }
}

///|
test "notify_parent_plan deliver matches plan_delivery and success response" {
  let parent : @types.Agent = {
    agent_id: @types.AgentId("main.tl"),
    role: @types.Role::TL,
    agent_type: @types.AgentType::Claude,
    parent: None,
    workspace: "/tmp",
    branch: "main",
    terminal_target: @types.LocalTarget::parse("zellij-tab:choir:tl"),
    host: @types.Host::Local,
    spawn_depth: 0,
    state: @types.AgentState::Active,
  }
  let args : CallerMessageArgs = {
    caller_id: "main.leaf",
    message: "hello",
    status: @types.Status::Failure,
  }
  let expected_delivery = @message.plan_delivery(
    parent,
    "main.leaf",
    "hello",
    @types.Status::Failure,
  )
  match notify_parent_plan(args, Some(Ok(parent))) {
    NotifyParentPlan::Deliver(delivery~, dev_event_on_success~, response_ok~) => {
      assert_eq(delivery, expected_delivery)
      assert_eq(
        dev_event_on_success,
        @phase.DevEvent::NotifyParentSuccess(message="hello"),
      )
      match response_ok {
        @types.Response::Ok(fields) => {
          let map = fields.to_json_map()
          @debug.assert_eq(map.get("status"), Some(String::to_json("notified")))
        }
        _ => fail("expected ok response")
      }
    }
    _ => fail("expected Deliver")
  }
}

///|
fn messaging_test_agent_with_state(state : @types.AgentState) -> @types.Agent {
  {
    agent_id: @types.AgentId("main.leaf"),
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Claude,
    parent: Some("main"),
    workspace: "/tmp",
    branch: "main.leaf",
    terminal_target: @types.LocalTarget::parse("zellij-tab:choir:leaf"),
    host: @types.Host::Local,
    spawn_depth: 0,
    state,
  }
}

///|
fn assert_response_status(
  response : @types.Response,
  expected : String,
) -> Unit raise {
  match response {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      @debug.assert_eq(map.get("status"), Some(String::to_json(expected)))
    }
    _ => fail("expected ok response")
  }
}

///|
test "send_message_delivery_log_append matches dispatch log shape" {
  let now_ms = 1776000000123L
  let agent : @types.Agent = {
    agent_id: @types.AgentId("main.leaf"),
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Claude,
    parent: Some("main"),
    workspace: "/tmp",
    branch: "main.leaf",
    terminal_target: @types.LocalTarget::parse("zellij-tab:choir:leaf"),
    host: @types.Host::Local,
    spawn_depth: 0,
    state: @types.AgentState::Active,
  }
  let delivery = @message.plan_delivery(
    agent,
    "main.tl",
    "hi",
    @types.Status::Success,
  )
  assert_eq(
    send_message_delivery_log_append("main.leaf", agent, delivery, now_ms~),
    @poller.delivery_log_line(
      "[send_message] target=main.leaf terminal_target=zellij-tab:choir:leaf delivery=" +
      delivery.to_display_string(),
      now_ms~,
    ),
  )
}

///|
test "send_message_delivery_log_append uses NONE without terminal_target" {
  let agent : @types.Agent = {
    agent_id: @types.AgentId("main.leaf"),
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Claude,
    parent: Some("main"),
    workspace: "/tmp",
    branch: "main.leaf",
    terminal_target: None,
    host: @types.Host::Local,
    spawn_depth: 0,
    state: @types.AgentState::Active,
  }
  let delivery = @message.plan_delivery(
    agent,
    "main.tl",
    "hi",
    @types.Status::Success,
  )
  assert_true(
    send_message_delivery_log_append("main.leaf", agent, delivery).contains(
      "terminal_target=NONE",
    ),
  )
}

///|
test "send_message_plan returns TargetFinalized when target agent state is Done" {
  let now_ms = 1776000000123L
  let agent = messaging_test_agent_with_state(@types.AgentState::Done)
  match
    send_message_plan(
      "main.leaf",
      "main.tl",
      "merged; you may shut down",
      @types.Status::Info,
      Some(Ok(agent)),
      now_ms~,
    ) {
    SendMessagePlan::TargetFinalized(
      target_id~,
      state~,
      sender_id~,
      delivery_log_append~,
      response~
    ) => {
      assert_eq(target_id, "main.leaf")
      assert_eq(state, @types.AgentState::Done)
      assert_eq(sender_id, "main.tl")
      assert_eq(
        delivery_log_append,
        @poller.delivery_log_line(
          "[send_message] target=main.leaf state=done sender=main.tl delivery=skipped_target_finalized message_preview=merged; you may shut down",
          now_ms~,
        ),
      )
      assert_response_status(response, "skipped_target_finalized")
    }
    _ => fail("expected TargetFinalized")
  }
}

///|
test "send_message_plan returns TargetFinalized when target agent state is Failed" {
  let now_ms = 1776000000123L
  let agent = messaging_test_agent_with_state(@types.AgentState::Failed)
  match
    send_message_plan(
      "main.leaf",
      "main.tl",
      "ship failed; shutting down",
      @types.Status::Failure,
      Some(Ok(agent)),
      now_ms~,
    ) {
    SendMessagePlan::TargetFinalized(
      target_id~,
      state~,
      sender_id~,
      delivery_log_append~,
      response~
    ) => {
      assert_eq(target_id, "main.leaf")
      assert_eq(state, @types.AgentState::Failed)
      assert_eq(sender_id, "main.tl")
      assert_eq(
        delivery_log_append,
        @poller.delivery_log_line(
          "[send_message] target=main.leaf state=failed sender=main.tl delivery=skipped_target_finalized message_preview=ship failed; shutting down",
          now_ms~,
        ),
      )
      assert_response_status(response, "skipped_target_finalized")
    }
    _ => fail("expected TargetFinalized")
  }
}

///|
/// Real coverage for the preview bounded-truncate-then-sanitize path:
/// send the actual plan a long, newline-laden message and inspect the
/// preview baked into the resulting delivery_log_append. If the production
/// path regresses to replace-then-truncate (or grows back into unbounded
/// allocation), this test will fail because the preview will either
/// contain the post-cutoff `TAIL` or contain a literal `\n` byte.
test "send_message_plan truncates and sanitizes long messages with embedded newlines" {
  let now_ms = 1776000000123L
  let agent = messaging_test_agent_with_state(@types.AgentState::Done)
  let long_message = "first line\nsecond line\rthird line " +
    "1234567890123456789012345678901234567890123456789012345678901234567890" +
    "TAIL"
  // The first 80 bytes (after \n/\r → space) become the preview. Any byte
  // beyond position 79 — including "TAIL" — must not appear.
  match
    send_message_plan(
      "main.leaf",
      "main.tl",
      long_message,
      @types.Status::Info,
      Some(Ok(agent)),
      now_ms~,
    ) {
    SendMessagePlan::TargetFinalized(delivery_log_append~, ..) => {
      // The preview must show newlines as spaces (sanitization happened)
      // and must stop before "TAIL" (truncation happened).
      assert_true(
        delivery_log_append.contains(
          "message_preview=first line second line third line",
        ),
      )
      assert_false(delivery_log_append.contains("TAIL"))
      // The unsanitized newline shape would have left `first line\n` in
      // the preview text. The append-trailing newline from delivery_log_line
      // is fine — we're testing that the raw \n didn't survive the cutoff.
      assert_false(delivery_log_append.contains("first line\nsecond"))
    }
    _ => fail("expected TargetFinalized")
  }
}

///|
test "send_message_plan still returns Deliver when target agent state is Active" {
  let agent = messaging_test_agent_with_state(@types.AgentState::Active)
  match
    send_message_plan(
      "main.leaf",
      "main.tl",
      "hello",
      @types.Status::Info,
      Some(Ok(agent)),
    ) {
    SendMessagePlan::Deliver(delivery~, delivery_log_append~, response_ok~) => {
      ignore(delivery)
      ignore(delivery_log_append)
      assert_response_status(response_ok, "sent")
    }
    _ => fail("expected Deliver")
  }
}

///|
test "send_message_plan still returns Deliver when target agent state is Suspended" {
  let agent = messaging_test_agent_with_state(@types.AgentState::Suspended)
  match
    send_message_plan(
      "main.leaf",
      "main.tl",
      "resume when ready",
      @types.Status::Info,
      Some(Ok(agent)),
    ) {
    SendMessagePlan::Deliver(delivery~, delivery_log_append~, response_ok~) => {
      ignore(delivery)
      ignore(delivery_log_append)
      assert_response_status(response_ok, "sent")
    }
    _ => fail("expected Deliver")
  }
}

///|
test "send_message_plan no registry returns best-effort sent" {
  match send_message_plan("main.x", "a", "m", @types.Status::Success, None) {
    SendMessagePlan::NoRegistry(response~) =>
      match response {
        @types.Response::Ok(fields) => {
          let map = fields.to_json_map()
          @debug.assert_eq(map.get("status"), Some(String::to_json("sent")))
        }
        _ => fail("expected ok")
      }
    _ => fail("expected NoRegistry")
  }
}

///|
test "send_message_plan maps registry lookup error" {
  let err = @types.ChoirError::agent_not_found("main.missing")
  match
    send_message_plan(
      "main.missing",
      "a",
      "m",
      @types.Status::Info,
      Some(Err(err)),
    ) {
    SendMessagePlan::RegistryLookupFailed(error_message~) =>
      assert_eq(error_message, err.message())
    _ => fail("expected RegistryLookupFailed")
  }
}

///|
test "send_message_plan deliver matches plan_delivery and log append" {
  let now_ms = 1776000000123L
  let agent : @types.Agent = {
    agent_id: @types.AgentId("main.leaf"),
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Claude,
    parent: Some("main"),
    workspace: "/tmp",
    branch: "main.leaf",
    terminal_target: @types.LocalTarget::parse("zellij-tab:choir:leaf"),
    host: @types.Host::Local,
    spawn_depth: 0,
    state: @types.AgentState::Active,
  }
  let expected_delivery = @message.plan_delivery(
    agent,
    "main.tl",
    "hello",
    @types.Status::Failure,
  )
  match
    send_message_plan(
      "main.leaf",
      "main.tl",
      "hello",
      @types.Status::Failure,
      Some(Ok(agent)),
      now_ms~,
    ) {
    SendMessagePlan::Deliver(delivery~, delivery_log_append~, response_ok~) => {
      assert_eq(delivery, expected_delivery)
      assert_eq(
        delivery_log_append,
        send_message_delivery_log_append(
          "main.leaf",
          agent,
          expected_delivery,
          now_ms~,
        ),
      )
      match response_ok {
        @types.Response::Ok(fields) => {
          let map = fields.to_json_map()
          @debug.assert_eq(map.get("status"), Some(String::to_json("sent")))
        }
        _ => fail("expected ok")
      }
    }
    _ => fail("expected Deliver")
  }
}

///|
async test "interpret_send_message no registry skips delivery" {
  let plan = send_message_plan("t", "s", "m", @types.Status::Info, None)
  let got = interpret_send_message(
    plan,
    "/tmp/choir-send-msg-test",
    mock_runner_all_ok,
    fn(_, _) { true },
  )
  match got {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      @debug.assert_eq(map.get("status"), Some(String::to_json("sent")))
    }
    _ => fail("expected ok")
  }
}

///|
async test "interpret_send_message registry lookup failed returns err" {
  let err = @types.ChoirError::agent_not_found("x")
  let plan = send_message_plan(
    "x",
    "s",
    "m",
    @types.Status::Info,
    Some(Err(err)),
  )
  let got = interpret_send_message(
    plan,
    "/tmp/choir-send-msg-test",
    mock_runner_all_ok,
    fn(_, _) { true },
  )
  match got {
    @types.Response::Err(msg) => assert_eq(msg, err.message())
    _ => fail("expected err")
  }
}

///|
fn send_message_interpret_test_project_dir() -> String {
  "/tmp/choir-send-msg-interpret-" + @sys.get_pid().to_string()
}

///|
async fn sleep_zero_for_send_msg(_ms : Int) -> Unit {
  @async.sleep(0)
}

///|
async fn runner_send_msg_always_fail(
  cmds : Array[@workspace.Command],
) -> Array[Int] {
  @async.sleep(0)
  let statuses = []
  for _ in cmds {
    statuses.push(1)
  }
  statuses
}

///|
async test "interpret_send_message deliver tcp success appends send_message log" {
  let now_ms = 1776000000123L
  let project_dir = send_message_interpret_test_project_dir()
  assert_true(@sys.create_dir_all(project_dir + "/.choir"))
  let log_path = project_dir + "/.choir/delivery.log"
  ignore(@sys.delete_file_sync(log_path))
  let agent : @types.Agent = {
    agent_id: @types.AgentId("main.rleaf"),
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Claude,
    parent: Some("main"),
    workspace: "/tmp",
    branch: "main.rleaf",
    terminal_target: None,
    host: @types.Host::Remote("127.0.0.1"),
    spawn_depth: 0,
    state: @types.AgentState::Active,
  }
  let plan = send_message_plan(
    "main.rleaf",
    "main.tl",
    "text",
    @types.Status::Success,
    Some(Ok(agent)),
    now_ms~,
  )
  let got = interpret_send_message(
    plan, project_dir, mock_runner_all_ok, @sys.append_file_sync,
  )
  match got {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      @debug.assert_eq(map.get("status"), Some(String::to_json("sent")))
    }
    _ => fail("expected ok")
  }
  let delivery = @message.plan_delivery(
    agent,
    "main.tl",
    "text",
    @types.Status::Success,
  )
  let expected_log = send_message_delivery_log_append(
    "main.rleaf",
    agent,
    delivery,
    now_ms~,
  )
  assert_eq(@sys.read_file(log_path), expected_log)
}

///|
async test "interpret_send_message deliver local terminal failure returns err and keeps send_message log" {
  let now_ms = 1776000000123L
  let project_dir = send_message_interpret_test_project_dir()
  assert_true(@sys.create_dir_all(project_dir + "/.choir"))
  let log_path = project_dir + "/.choir/delivery.log"
  ignore(@sys.delete_file_sync(log_path))
  let agent : @types.Agent = {
    agent_id: @types.AgentId("main.leaf"),
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Claude,
    parent: Some("main"),
    workspace: "/tmp",
    branch: "main.leaf",
    terminal_target: @types.LocalTarget::parse("zellij-tab:choir:leaf"),
    host: @types.Host::Local,
    spawn_depth: 0,
    state: @types.AgentState::Active,
  }
  let plan = send_message_plan(
    "main.leaf",
    "main.tl",
    "x",
    @types.Status::Info,
    Some(Ok(agent)),
    now_ms~,
  )
  let got = interpret_send_message(
    plan,
    project_dir,
    runner_send_msg_always_fail,
    @sys.append_file_sync,
    sleep_fn=sleep_zero_for_send_msg,
  )
  match got {
    @types.Response::Err(msg) =>
      assert_true(msg.contains("delivery command failed"))
    _ => fail("expected err from execute_delivery")
  }
  let delivery = @message.plan_delivery(
    agent,
    "main.tl",
    "x",
    @types.Status::Info,
  )
  let send_line = send_message_delivery_log_append(
    "main.leaf",
    agent,
    delivery,
    now_ms~,
  )
  assert_true(@sys.read_file(log_path).contains(send_line))
}

///|
async test "interpret_send_message TargetFinalized branch logs and returns ok without invoking runner" {
  let project_dir = send_message_interpret_test_project_dir() + "-finalized"
  assert_true(@sys.create_dir_all(project_dir + "/.choir"))
  let log_path = project_dir + "/.choir/delivery.log"
  ignore(@sys.delete_file_sync(log_path))
  let long_message = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopTAIL"
  let expected_preview = long_message[:80].to_owned()
  let delivery_log_append = @poller.delivery_log_line(
    "[send_message] target=main.leaf state=done sender=main.tl delivery=skipped_target_finalized message_preview=" +
    expected_preview,
    now_ms=1776000000123L,
  )
  let runner_calls : Array[Int] = [0]
  let runner = async fn(cmds : Array[@workspace.Command]) -> Array[Int] {
    @async.sleep(0)
    runner_calls[0] = runner_calls[0] + 1
    let statuses = []
    for _ in cmds {
      statuses.push(0)
    }
    statuses
  }
  let plan = SendMessagePlan::TargetFinalized(
    target_id="main.leaf",
    state=@types.AgentState::Done,
    sender_id="main.tl",
    delivery_log_append~,
    response=@types.Response::ok_values({
      "status": String::to_json("skipped_target_finalized"),
    }),
  )
  let got = interpret_send_message(
    plan, project_dir, runner, @sys.append_file_sync,
  )
  assert_response_status(got, "skipped_target_finalized")
  assert_eq(runner_calls[0], 0)
  let log_body = @sys.read_file(log_path)
  assert_eq(log_body, delivery_log_append)
  assert_true(log_body.contains("[send_message]"))
  assert_true(log_body.contains("target=main.leaf"))
  assert_true(log_body.contains("state=done"))
  assert_true(log_body.contains("sender=main.tl"))
  assert_true(log_body.contains("message_preview=" + expected_preview))
  assert_false(log_body.contains("TAIL"))
}

///|
