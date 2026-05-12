///|
fn goal_cli_usage() -> String {
  "usage: choir goal <bead-id|text> [--verify <cmd>]... | choir goal status [--evaluate] | choir goal-clear"
}

///|
fn goal_cli_string_args(values : Map[String, Json]) -> Map[String, String] {
  let out : Map[String, String] = {}
  values.each(fn(k, v) {
    out.set(
      k,
      match v {
        String(s) => s
        Array(items) => {
          let lines : Array[String] = []
          for item in items {
            match item {
              String(s) => lines.push(s)
              _ => ()
            }
          }
          lines.join("\n")
        }
        _ => v.stringify()
      },
    )
  })
  out
}

///|
async fn goal_cli_local_dispatch(
  role : @types.Role,
  config : @types.Config,
  tool : String,
  values : Map[String, Json],
) -> @types.Response {
  let resp = @tools.dispatch_call(
    { role, name: tool, args: goal_cli_string_args(values) },
    project_dir=config.project_dir,
    session=config.terminal_session,
  )
  goal_cli_response_with_local_dispatch_warning(tool, resp)
}

///|
fn goal_cli_response_append_warning(
  resp : @types.Response,
  warning : String,
) -> @types.Response {
  match resp.ok_field("warning") {
    Some(existing) => resp.with_warning(existing + "\n" + warning)
    None => resp.with_warning(warning)
  }
}

///|
fn goal_cli_response_with_local_dispatch_warning(
  tool : String,
  resp : @types.Response,
) -> @types.Response {
  if tool == "goal_set" && resp.is_ok() {
    goal_cli_response_append_warning(
      resp, "goal set, but no running `choir serve` was detected — the judge will not run until a choir server is up.",
    )
  } else {
    resp
  }
}

///|
async fn goal_cli_call(
  tool : String,
  values : Map[String, Json],
) -> @types.Response {
  let empty_cli = parse_leaf_cli_args([])
  let (role, config, local_cfg) = match tool_load_config(empty_cli) {
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
    client_call_uds(role, config, local_cfg, req, register_if_needed=false) {
    Ok(resp) =>
      match resp.error_message() {
        Some(msg) if msg.has_prefix("unknown tool: goal_") =>
          goal_cli_local_dispatch(role, config, tool, values)
        _ => resp
      }
    Err(_) => goal_cli_local_dispatch(role, config, tool, values)
  }
}

///|
fn goal_cli_parse_goal_values(
  args : Array[String],
  start : Int,
) -> Result[Map[String, Json], String] {
  let target_parts : Array[String] = []
  let verify : Array[Json] = []
  let mut i = start
  while i < args.length() {
    let arg = args[i]
    if arg == "--verify" {
      if i + 1 >= args.length() {
        return Err("--verify requires a command")
      }
      verify.push(args[i + 1].to_json())
      i = i + 2
    } else if arg.has_prefix("--verify=") {
      verify.push(arg["--verify=".length():].to_owned().to_json())
      i = i + 1
    } else if arg.has_prefix("--") {
      return Err("unknown option: " + arg)
    } else {
      target_parts.push(arg)
      i = i + 1
    }
  }
  let input = target_parts.join(" ").trim().to_owned()
  if input == "" {
    return Err(goal_cli_usage())
  }
  Ok({ "input": input.to_json(), "verify": verify.to_json() })
}

///|
fn goal_cli_status_values(
  args : Array[String],
  start : Int,
) -> Result[Map[String, Json], String] {
  let mut evaluate = false
  let mut i = start
  while i < args.length() {
    match args[i] {
      "--evaluate" => {
        evaluate = true
        i = i + 1
      }
      other => return Err("unknown option: " + other)
    }
  }
  Ok({ "evaluate": evaluate.to_json() })
}

///|
test "goal CLI local dispatch warning is attached to goal_set success" {
  let resp = goal_cli_response_with_local_dispatch_warning(
    "goal_set",
    @types.Response::ok_values({ "status": "set".to_json() }),
  )
  assert_eq(
    resp.ok_field("warning").unwrap_or(""),
    "goal set, but no running `choir serve` was detected — the judge will not run until a choir server is up.",
  )
  let clear = goal_cli_response_with_local_dispatch_warning(
    "goal_clear",
    @types.Response::ok_values({ "status": "cleared".to_json() }),
  )
  match clear.ok_field("warning") {
    None => ()
    Some(_) => fail("goal_clear local fallback should not use goal_set warning")
  }
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
    @async.run_async_main(async fn() {
      client_emit(goal_cli_call("goal_status", values))
    })
    return
  }
  let values = match goal_cli_parse_goal_values(args, 2) {
    Ok(value) => value
    Err(err) => {
      client_emit(@types.Response::Err(err))
      return
    }
  }
  @async.run_async_main(async fn() {
    client_emit(goal_cli_call("goal_set", values))
  })
}

///|
fn goal_clear_run() -> Unit {
  @async.run_async_main(async fn() {
    client_emit(goal_cli_call("goal_clear", {}))
  })
}
