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
test "send_message_delivery_log_append matches dispatch log shape" {
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
    send_message_delivery_log_append("main.leaf", agent, delivery),
    "[send_message] target=main.leaf terminal_target=zellij-tab:choir:leaf delivery=" +
    delivery.to_display_string() +
    "\n",
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
    ) {
    SendMessagePlan::Deliver(delivery~, delivery_log_append~, response_ok~) => {
      assert_eq(delivery, expected_delivery)
      assert_eq(
        delivery_log_append,
        send_message_delivery_log_append("main.leaf", agent, expected_delivery),
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
    plan, "/tmp/choir-send-msg-test", mock_runner_all_ok,
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
    plan, "/tmp/choir-send-msg-test", mock_runner_all_ok,
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
  )
  let got = interpret_send_message(plan, project_dir, mock_runner_all_ok)
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
    "main.rleaf", agent, delivery,
  )
  assert_eq(@sys.read_file(log_path), expected_log)
}

///|
async test "interpret_send_message deliver local terminal failure returns err and keeps send_message log" {
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
  )
  let got = interpret_send_message(
    plan,
    project_dir,
    runner_send_msg_always_fail,
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
  let send_line = send_message_delivery_log_append("main.leaf", agent, delivery)
  assert_true(@sys.read_file(log_path).contains(send_line))
}

///|
