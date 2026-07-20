///|
async test "goal_submit forwards the Conductor draft through the TL tool seam" {
  let draft = "{\"proposal_id\":\"proposal-1\",\"goal_id\":\"goal-1\",\"parts\":[]}"
  let mut observed : String? = None
  let response = @tools.dispatch_call(
    @tools.ToolCall::{
      role: @types.Role::TL,
      name: "goal_submit",
      args: { "draft": draft },
    },
    project_dir="/repo",
    path_exists=fn(_) { false },
    goal_submit=async fn(value) {
      observed = Some(value)
      @types.Response::ok({ "goal_id": "goal-1" })
    },
  )
  assert_true(response.is_ok())
  @debug.assert_eq(observed, Some(draft))
  @debug.assert_eq(response.ok_field("goal_id"), Some("goal-1"))
}

///|
async test "goal_submit is unavailable to non-Conductor roles" {
  let mut called = false
  let response = @tools.dispatch_call(
    @tools.ToolCall::{
      role: @types.Role::Dev,
      name: "goal_submit",
      args: { "draft": "{}" },
    },
    project_dir="/repo",
    path_exists=fn(_) { false },
    goal_submit=async fn(_) {
      called = true
      @types.Response::ok(Map([]))
    },
  )
  assert_false(called)
  match response {
    @types.Response::Err(message) =>
      assert_true(message.contains("cannot call"))
    @types.Response::Ok(_) => fail("expected role refusal")
  }
}

///|
async test "goal_status routes a durable Goal ID through the inspection seam" {
  let mut observed : String? = None
  let response = @tools.dispatch_call(
    @tools.ToolCall::{
      role: @types.Role::TL,
      name: "goal_status",
      args: { "goal_id": "goal-1" },
    },
    project_dir="/repo",
    path_exists=fn(_) { false },
    goal_status=async fn(goal_id) {
      observed = Some(goal_id)
      @types.Response::ok_values({
        "goal_id": goal_id.to_json(),
        "state": "GoalExecutionRunning".to_json(),
      })
    },
  )
  assert_true(response.is_ok())
  @debug.assert_eq(observed, Some("goal-1"))
  @debug.assert_eq(response.ok_field("goal_id"), Some("goal-1"))
}

///|
async test "goal_status cannot inspect a durable Goal from a non-Conductor role" {
  let called = @ref.new(false)
  let response = @tools.dispatch_call(
    @tools.ToolCall::{
      role: @types.Role::Worker,
      name: "goal_status",
      args: { "goal_id": "goal-1" },
    },
    project_dir="/repo",
    path_exists=fn(_) { false },
    goal_status=async fn(_) {
      called.val = true
      @types.Response::ok(Map([]))
    },
  )
  assert_false(called.val)
  match response {
    @types.Response::Err(message) =>
      assert_true(message.contains("cannot call"))
    @types.Response::Ok(_) => fail("expected role refusal")
  }
}

///|
async test "goal_cancel routes a durable Goal ID through the cancellation seam" {
  let observed = @ref.new("")
  let response = dispatch_call(
    {
      role: @types.Role::TL,
      name: "goal_cancel",
      args: { "goal_id": "goal-stop" },
    },
    goal_cancel=async fn(goal_id) {
      observed.val = goal_id
      @types.Response::ok({ "state": "canceling" })
    },
  )
  assert_eq(observed.val, "goal-stop")
  assert_true(response.error_message() is None)
}

///|
async test "goal_cancel requires a Goal ID and Conductor role" {
  let missing = dispatch_call({
    role: @types.Role::TL,
    name: "goal_cancel",
    args: {},
  })
  assert_true(missing.error_message().unwrap_or("").contains("missing goal_id"))
  let denied = dispatch_call(
    {
      role: @types.Role::Worker,
      name: "goal_cancel",
      args: { "goal_id": "goal-stop" },
    },
    goal_cancel=async fn(_) { fail("worker reached cancellation capability") },
  )
  assert_true(
    denied
    .error_message()
    .unwrap_or("")
    .contains("role worker cannot call goal_cancel"),
  )
}

///|
async test "goal_steer routes typed pause resume and concurrency actions" {
  let observed : Array[@tools.GoalSteerAction] = []
  let cases : Array[(String, Map[String, String])] = [
    ("pause", Map([])),
    ("resume", Map([])),
    ("set_concurrency", Map([("maximum_parallel_parts", "4")])),
  ]
  for item in cases {
    let (action, extra) = item
    let args : Map[String, String] = {
      "goal_id": "goal-steer",
      "action": action,
    }
    extra.each(fn(key, value) { args[key] = value })
    let response = dispatch_call(
      { role: @types.Role::TL, name: "goal_steer", args },
      goal_steer=async fn(goal_id, typed_action) {
        assert_eq(goal_id, "goal-steer")
        observed.push(typed_action)
        @types.Response::ok({ "state": "steered" })
      },
    )
    assert_true(response.error_message() is None)
  }
  assert_eq(observed, [
    @tools.GoalSteerAction::GoalSteerPause,
    @tools.GoalSteerAction::GoalSteerResume,
    @tools.GoalSteerAction::GoalSteerSetMaximumParallelParts(4),
  ])
}

///|
async test "goal_steer rejects malformed policy changes and non-Conductors" {
  for
    args in [
      { "goal_id": "goal-steer", "action": "set_concurrency" },
      {
        "goal_id": "goal-steer",
        "action": "pause",
        "maximum_parallel_parts": "2",
      },
      { "goal_id": "goal-steer", "action": "invent" },
    ] {
    let response = dispatch_call({
      role: @types.Role::TL,
      name: "goal_steer",
      args,
    })
    assert_true(response.error_message() is Some(_))
  }
  let denied = dispatch_call(
    {
      role: @types.Role::Worker,
      name: "goal_steer",
      args: { "goal_id": "goal-steer", "action": "pause" },
    },
    goal_steer=async fn(_, _) { fail("worker reached steering capability") },
  )
  assert_true(
    denied
    .error_message()
    .unwrap_or("")
    .contains("role worker cannot call goal_steer"),
  )
}

///|
async test "goal_attach routes a Take ID through the read-only capability" {
  let observed = @ref.new("")
  let response = dispatch_call(
    {
      role: @types.Role::TL,
      name: "goal_attach",
      args: { "take_id": "take-observe" },
    },
    goal_attach=async fn(take_id) {
      observed.val = take_id
      @types.Response::ok({ "observational": "true" })
    },
  )
  assert_eq(observed.val, "take-observe")
  assert_true(response.error_message() is None)
}

///|
async test "goal_attach requires a Take ID and Conductor role" {
  let missing = dispatch_call({
    role: @types.Role::TL,
    name: "goal_attach",
    args: {},
  })
  assert_true(missing.error_message().unwrap_or("").contains("missing take_id"))
  let denied = dispatch_call(
    {
      role: @types.Role::Worker,
      name: "goal_attach",
      args: { "take_id": "take-observe" },
    },
    goal_attach=async fn(_) { fail("worker reached attach capability") },
  )
  assert_true(
    denied
    .error_message()
    .unwrap_or("")
    .contains("role worker cannot call goal_attach"),
  )
}

///|
async test "goal_answer routes one exact request and answer" {
  let observed = @ref.new("")
  let response = dispatch_call(
    {
      role: @types.Role::TL,
      name: "goal_answer",
      args: { "request_id": "request-a", "answer": "The PR is reopened." },
    },
    goal_answer=async fn(request_id, answer) {
      observed.val = request_id + ":" + answer
      @types.Response::ok({ "state": "resumed" })
    },
  )
  assert_eq(observed.val, "request-a:The PR is reopened.")
  assert_true(response.error_message() is None)
}

///|
async test "goal_answer rejects missing content and non-Conductors" {
  for
    args in [
      { "answer": "yes" },
      { "request_id": "request-a" },
      { "request_id": "request-a", "answer": "   " },
    ] {
    assert_true(
      dispatch_call({ role: @types.Role::TL, name: "goal_answer", args }).error_message()
      is Some(_),
    )
  }
  let denied = dispatch_call(
    {
      role: @types.Role::Worker,
      name: "goal_answer",
      args: { "request_id": "request-a", "answer": "yes" },
    },
    goal_answer=async fn(_, _) { fail("worker reached answer capability") },
  )
  assert_true(
    denied
    .error_message()
    .unwrap_or("")
    .contains("role worker cannot call goal_answer"),
  )
}
