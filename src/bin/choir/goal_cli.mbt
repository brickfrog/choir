///|
fn goal_cli_usage() -> String {
  "usage: choir goal list | choir goal status <goal-id|--part bead-id> | choir goal steer <goal-id|--part bead-id> <pause|resume|concurrency N|retry [bead-id]> | choir goal cancel <goal-id|--part bead-id> | choir goal attach <take-id> | choir goal answer <request-id> <answer>"
}

///|
/// Resolve a Goal selector shared across status/steer/cancel: a bare token is
/// the internal goal_id, `--part <bead-id>` names the user-facing Bead whose
/// Goal the daemon resolves. Recovery without a live Conductor needs the
/// latter because internal Goal ids are never shown to the user.
fn goal_cli_selector(
  args : Array[String],
  start : Int,
) -> Result[(Map[String, Json], Int), String] {
  if start >= args.length() {
    return Err(goal_cli_usage())
  }
  if args[start] == "--part" {
    if start + 1 >= args.length() || args[start + 1].trim() == "" {
      return Err(goal_cli_usage())
    }
    Ok(({ "part_id": args[start + 1].trim().to_owned().to_json() }, start + 2))
  } else {
    let value = args[start].trim().to_owned()
    if value == "" {
      return Err(goal_cli_usage())
    }
    Ok(({ "goal_id": value.to_json() }, start + 1))
  }
}

///|
test "goal selector accepts a goal id or a Bead part selector" {
  assert_eq(goal_cli_selector(["goal-a"], 0).unwrap().0, {
    "goal_id": "goal-a".to_json(),
  })
  assert_eq(goal_cli_selector(["--part", "choir-x"], 0).unwrap().0, {
    "part_id": "choir-x".to_json(),
  })
  assert_eq(goal_cli_selector(["--part", "choir-x"], 0).unwrap().1, 2)
  assert_true(goal_cli_selector(["--part"], 0) is Err(_))
  assert_true(goal_cli_selector([], 0) is Err(_))
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
  let config = match goal_client_load_config() {
    Ok(loaded) => loaded
    Err(err) => return @types.Response::Err(err)
  }
  let capability = @sys.getenv("CHOIR_CONDUCTOR_TOKEN")
  let req : @types.Request = {
    req_method: "tools/call",
    name: tool,
    args: @types.RequestArgs::from_values(values),
  }
  match client_call_uds(config, req, capability) {
    Ok(resp) => resp
    Err(_) => goal_cli_no_serve_response()
  }
}

///|
fn goal_cli_status_values(
  args : Array[String],
  start : Int,
) -> Result[Map[String, Json], String] {
  let (values, next) = match goal_cli_selector(args, start) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if next != args.length() {
    return Err(goal_cli_usage())
  }
  Ok(values)
}

///|
test "goal status accepts a Goal ID or a Bead part selector" {
  assert_eq(goal_cli_status_values(["goal-a"], 0).unwrap(), {
    "goal_id": "goal-a".to_json(),
  })
  assert_eq(goal_cli_status_values(["--part", "choir-x"], 0).unwrap(), {
    "part_id": "choir-x".to_json(),
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
  let (selector, action_index) = match goal_cli_selector(args, start) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if action_index >= args.length() {
    return Err(goal_cli_usage())
  }
  let action = args[action_index].trim().to_lower()
  let values = selector
  match action {
    "pause" | "resume" => {
      if action_index + 1 != args.length() {
        return Err(goal_cli_usage())
      }
      values["action"] = action.to_json()
      Ok(values)
    }
    "retry" => {
      // Optional trailing Bead id names the blocked Part; omitted when
      // exactly one Part is blocked.
      if action_index + 1 < args.length() {
        if action_index + 2 != args.length() ||
          args[action_index + 1].trim() == "" {
          return Err(goal_cli_usage())
        }
        values["part_id"] = args[action_index + 1].trim().to_owned().to_json()
      } else if action_index + 1 != args.length() {
        return Err(goal_cli_usage())
      }
      values["action"] = "retry_part".to_json()
      Ok(values)
    }
    "concurrency" => {
      if action_index + 2 != args.length() {
        return Err(goal_cli_usage())
      }
      let value = @string.parse_int(args[action_index + 1]) catch { _ => 0 }
      if value <= 0 {
        return Err("concurrency requires a positive integer")
      }
      values["action"] = "set_concurrency".to_json()
      values["maximum_parallel_parts"] = value.to_json()
      Ok(values)
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
  assert_eq(goal_cli_steer_values(["--part", "choir-x", "resume"], 0).unwrap(), {
    "part_id": "choir-x".to_json(),
    "action": "resume".to_json(),
  })
  assert_eq(goal_cli_steer_values(["goal-a", "concurrency", "3"], 0).unwrap(), {
    "goal_id": "goal-a".to_json(),
    "action": "set_concurrency".to_json(),
    "maximum_parallel_parts": (3).to_json(),
  })
  assert_eq(goal_cli_steer_values(["goal-a", "retry"], 0).unwrap(), {
    "goal_id": "goal-a".to_json(),
    "action": "retry_part".to_json(),
  })
  assert_eq(goal_cli_steer_values(["goal-a", "retry", "choir-b"], 0).unwrap(), {
    "goal_id": "goal-a".to_json(),
    "action": "retry_part".to_json(),
    "part_id": "choir-b".to_json(),
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
  if args.length() >= 3 && args[2] == "list" {
    if args.length() != 3 {
      client_emit(@types.Response::Err(goal_cli_usage()))
      return
    }
    client_emit(goal_cli_call("goal_list", Map([])))
    return
  }
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
    let values = match goal_cli_status_values(args, 3) {
      Ok(value) => value
      Err(err) => {
        client_emit(@types.Response::Err(err))
        return
      }
    }
    client_emit(goal_cli_call("goal_cancel", values))
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
