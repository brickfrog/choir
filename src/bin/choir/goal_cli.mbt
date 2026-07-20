///|
fn goal_cli_usage() -> String {
  "usage: choir goal status <goal-id> | choir goal steer <goal-id> <pause|resume|concurrency N> | choir goal cancel <goal-id> | choir goal attach <take-id> | choir goal answer <request-id> <answer>"
}

///|
fn goal_cli_no_serve_response() -> @types.Response {
  @types.Response::Err(
    @types.ChoirError::transport_error(
      "no `choir serve` is running — start it, then run `choir goal`.",
    ).message(),
  )
}

///|
fn goal_cli_call(tool : String, values : Map[String, Json]) -> @types.Response {
  let (role, config, local_cfg) = match goal_client_load_config() {
    Ok(loaded) => loaded
    Err(err) => return @types.Response::Err(err)
  }
  let req : @types.Request = {
    req_method: "tools/call",
    role,
    name: tool,
    args: @types.RequestArgs::from_values(values),
  }
  match
    client_call_uds(
      role,
      config,
      local_cfg,
      req,
      register_if_needed=client_should_register(local_cfg),
    ) {
    Ok(resp) => resp
    Err(_) => goal_cli_no_serve_response()
  }
}

///|
fn goal_cli_status_values(
  args : Array[String],
  start : Int,
) -> Result[Map[String, Json], String] {
  if start + 1 != args.length() || args[start].trim() == "" {
    return Err(goal_cli_usage())
  }
  Ok({ "goal_id": args[start].trim().to_owned().to_json() })
}

///|
test "goal status requires exactly one durable Goal ID" {
  assert_eq(goal_cli_status_values(["goal-a"], 0).unwrap(), {
    "goal_id": "goal-a".to_json(),
  })
  assert_true(goal_cli_status_values([], 0) is Err(_))
  assert_true(goal_cli_status_values(["goal-a", "goal-b"], 0) is Err(_))
}

///|
test "goal CLI reports missing serve instead of local fallback" {
  match goal_cli_no_serve_response().error_message() {
    Some(msg) => {
      assert_true(msg.contains("no `choir serve` is running"))
      assert_true(msg.contains("start it, then run `choir goal`"))
    }
    None => fail("expected missing-serve error")
  }
}

///|
fn goal_cli_steer_values(
  args : Array[String],
  start : Int,
) -> Result[Map[String, Json], String] {
  if start + 1 >= args.length() {
    return Err(goal_cli_usage())
  }
  let goal_id = args[start].trim().to_owned()
  let action = args[start + 1].trim().to_lower()
  if goal_id == "" {
    return Err(goal_cli_usage())
  }
  match action {
    "pause" | "resume" => {
      if start + 2 != args.length() {
        return Err(goal_cli_usage())
      }
      Ok({ "goal_id": goal_id.to_json(), "action": action.to_json() })
    }
    "concurrency" => {
      if start + 3 != args.length() {
        return Err(goal_cli_usage())
      }
      let value = @string.parse_int(args[start + 2]) catch { _ => 0 }
      if value <= 0 {
        return Err("concurrency requires a positive integer")
      }
      Ok({
        "goal_id": goal_id.to_json(),
        "action": "set_concurrency".to_json(),
        "maximum_parallel_parts": value.to_json(),
      })
    }
    _ => Err(goal_cli_usage())
  }
}

///|
test "goal CLI parses typed steering operations" {
  assert_eq(goal_cli_steer_values(["goal-a", "pause"], 0).unwrap(), {
    "goal_id": "goal-a".to_json(),
    "action": "pause".to_json(),
  })
  assert_eq(goal_cli_steer_values(["goal-a", "resume"], 0).unwrap(), {
    "goal_id": "goal-a".to_json(),
    "action": "resume".to_json(),
  })
  assert_eq(goal_cli_steer_values(["goal-a", "concurrency", "3"], 0).unwrap(), {
    "goal_id": "goal-a".to_json(),
    "action": "set_concurrency".to_json(),
    "maximum_parallel_parts": (3).to_json(),
  })
  assert_true(
    goal_cli_steer_values(["goal-a", "concurrency", "0"], 0) is Err(_),
  )
  assert_true(goal_cli_steer_values(["goal-a", "pause", "extra"], 0) is Err(_))
}

///|
fn goal_cli_attach_values(
  args : Array[String],
  start : Int,
) -> Result[Map[String, Json], String] {
  if start + 1 != args.length() || args[start].trim() == "" {
    Err(goal_cli_usage())
  } else {
    Ok({ "take_id": args[start].trim().to_owned().to_json() })
  }
}

///|
test "goal CLI parses observational Take attachment" {
  assert_eq(goal_cli_attach_values(["take-a"], 0).unwrap(), {
    "take_id": "take-a".to_json(),
  })
  assert_true(goal_cli_attach_values([], 0) is Err(_))
  assert_true(goal_cli_attach_values(["take-a", "extra"], 0) is Err(_))
}

///|
fn goal_cli_answer_values(
  args : Array[String],
  start : Int,
) -> Result[Map[String, Json], String] {
  if start + 1 >= args.length() || args[start].trim() == "" {
    return Err(goal_cli_usage())
  }
  let answer = args[start + 1:].join(" ").trim().to_owned()
  if answer == "" {
    return Err(goal_cli_usage())
  }
  Ok({
    "request_id": args[start].trim().to_owned().to_json(),
    "answer": answer.to_json(),
  })
}

///|
test "goal CLI binds an answer to one durable request" {
  assert_eq(
    goal_cli_answer_values(["request-a", "I", "reopened", "it"], 0).unwrap(),
    { "request_id": "request-a".to_json(), "answer": "I reopened it".to_json() },
  )
  assert_true(goal_cli_answer_values(["request-a"], 0) is Err(_))
}

///|
fn goal_run() -> Unit {
  let args = @env.args()
  if args.length() >= 3 && args[2] == "status" {
    let values = match goal_cli_status_values(args, 3) {
      Ok(value) => value
      Err(err) => {
        client_emit(@types.Response::Err(err))
        return
      }
    }
    client_emit(goal_cli_call("goal_status", values))
    return
  }
  if args.length() >= 3 && args[2] == "cancel" {
    if args.length() != 4 || args[3].trim() == "" {
      client_emit(@types.Response::Err(goal_cli_usage()))
      return
    }
    client_emit(goal_cli_call("goal_cancel", { "goal_id": args[3].to_json() }))
    return
  }
  if args.length() >= 3 && args[2] == "steer" {
    let values = match goal_cli_steer_values(args, 3) {
      Ok(value) => value
      Err(err) => {
        client_emit(@types.Response::Err(err))
        return
      }
    }
    client_emit(goal_cli_call("goal_steer", values))
    return
  }
  if args.length() >= 3 && args[2] == "attach" {
    let values = match goal_cli_attach_values(args, 3) {
      Ok(value) => value
      Err(err) => {
        client_emit(@types.Response::Err(err))
        return
      }
    }
    client_emit(goal_cli_call("goal_attach", values))
    return
  }
  if args.length() >= 3 && args[2] == "answer" {
    let values = match goal_cli_answer_values(args, 3) {
      Ok(value) => value
      Err(err) => {
        client_emit(@types.Response::Err(err))
        return
      }
    }
    client_emit(goal_cli_call("goal_answer", values))
    return
  }
  client_emit(@types.Response::Err(goal_cli_usage()))
}
