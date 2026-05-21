///|
fn tdd_phase_label(phase : @types.LeafTddPhase?) -> String {
  match phase {
    Some(value) => value.to_wire_string()
    None => "none"
  }
}

///|
fn tdd_transition_error(message : String) -> @types.ChoirError {
  @types.ChoirError::validation_error("leaf TDD gate: " + message)
}

///|
async fn tdd_default_capture(cmd : @workspace.Command) -> (Int, String) {
  @exec.capture_command_merged(cmd)
}

///|
fn tdd_check_command(
  project_dir : String,
  command : String,
) -> @workspace.Command {
  { program: "sh", args: ["-lc", command], workdir: Some(project_dir) }
}

///|
fn tdd_text_tail(raw : String) -> String {
  let trimmed = raw.trim().to_owned()
  if trimmed == "" {
    ""
  } else if trimmed.length() <= 600 {
    trimmed
  } else {
    "[truncated]\n" + trimmed[trimmed.length() - 600:].to_owned()
  }
}

///|
fn tdd_exit_verification_context(command : String, output : String) -> String {
  let output_tail = tdd_text_tail(output)
  let command_detail = "\ncommand: " + command
  if output_tail == "" {
    command_detail
  } else {
    command_detail + "\noutput_tail:\n" + output_tail
  }
}

///|
async fn verify_tdd_reported_exit_code(
  project_dir : String,
  command : String,
  reported_exit_code : Int,
  capture : async (@workspace.Command) -> (Int, String),
) -> Result[String, @types.ChoirError] {
  let (actual_exit_code, actual_output) = capture(
    tdd_check_command(project_dir, command),
  )
  if actual_exit_code < 0 {
    Err(
      tdd_transition_error(
        "declared test command could not be executed; actual exit code " +
        actual_exit_code.to_string() +
        ", reported exit_code " +
        reported_exit_code.to_string() +
        tdd_exit_verification_context(command, actual_output),
      ),
    )
  } else if actual_exit_code != reported_exit_code {
    Err(
      tdd_transition_error(
        "declared test command actual exit code " +
        actual_exit_code.to_string() +
        " did not match reported exit_code " +
        reported_exit_code.to_string() +
        tdd_exit_verification_context(command, actual_output),
      ),
    )
  } else {
    Ok(actual_output)
  }
}

///|
pub fn plan_tdd_intent_transition(
  current : @types.LeafTddPhase?,
) -> Result[@types.LeafTddPhase, @types.ChoirError] {
  match current {
    None
    | Some(@types.LeafTddPhase::Intent)
    | Some(@types.LeafTddPhase::Done) => Ok(@types.LeafTddPhase::Intent)
    Some(phase) =>
      Err(
        tdd_transition_error(
          "cannot declare intent while current phase is " +
          phase.to_wire_string(),
        ),
      )
  }
}

///|
pub fn plan_tdd_red_check_transition(
  current : @types.LeafTddPhase?,
  exit_code : Int,
) -> Result[@types.LeafTddPhase, @types.ChoirError] {
  if exit_code == 0 {
    return Err(
      tdd_transition_error(
        "red check expected failing test result (exit_code != 0)",
      ),
    )
  }
  match current {
    Some(@types.LeafTddPhase::Intent) => Ok(@types.LeafTddPhase::Red)
    _ =>
      Err(
        tdd_transition_error(
          "red check requires Intent first; expected Intent -> Red -> Green -> Done, current phase is " +
          tdd_phase_label(current),
        ),
      )
  }
}

///|
pub fn plan_tdd_green_check_transition(
  current : @types.LeafTddPhase?,
  exit_code : Int,
  next_phase : @types.LeafTddPhase?,
) -> Result[@types.LeafTddPhase, @types.ChoirError] {
  if exit_code != 0 {
    return Err(
      tdd_transition_error(
        "green check expected passing test result (exit_code == 0)",
      ),
    )
  }
  match current {
    Some(@types.LeafTddPhase::Red) => {
      let target = next_phase.unwrap_or(@types.LeafTddPhase::Green)
      if target == @types.LeafTddPhase::Green {
        Ok(target)
      } else {
        Err(
          tdd_transition_error(
            "green check from Red must advance to Green before Done",
          ),
        )
      }
    }
    Some(@types.LeafTddPhase::Green) => {
      let target = next_phase.unwrap_or(@types.LeafTddPhase::Done)
      if target == @types.LeafTddPhase::Done ||
        target == @types.LeafTddPhase::Refactor {
        Ok(target)
      } else {
        Err(
          tdd_transition_error(
            "green phase may advance only to Refactor or Done",
          ),
        )
      }
    }
    Some(@types.LeafTddPhase::Refactor) => {
      let target = next_phase.unwrap_or(@types.LeafTddPhase::Done)
      if target == @types.LeafTddPhase::Done {
        Ok(target)
      } else {
        Err(tdd_transition_error("refactor phase may advance only to Done"))
      }
    }
    _ =>
      Err(
        tdd_transition_error(
          "green check requires Red first; expected Intent -> Red -> Green -> Done, current phase is " +
          tdd_phase_label(current),
        ),
      )
  }
}

///|
fn tdd_output_tail(output : String?) -> Json? {
  match output {
    Some(raw) => {
      let trimmed = raw.trim().to_owned()
      if trimmed == "" {
        None
      } else if trimmed.length() <= 600 {
        Some(trimmed.to_json())
      } else {
        Some(
          ("[truncated]\n" + trimmed[trimmed.length() - 600:].to_owned()).to_json(),
        )
      }
    }
    None => None
  }
}

///|
fn tdd_phase_response(
  agent_id : String,
  phase : @types.LeafTddPhase,
  tool : String,
  command? : String? = None,
  exit_code? : Int? = None,
  output? : String? = None,
) -> @types.Response {
  let fields : Map[String, Json] = {
    "status": "tdd_phase_updated".to_json(),
    "agent_id": agent_id.to_json(),
    "phase": phase.to_json(),
    "tool": tool.to_json(),
  }
  match command {
    Some(value) => fields.set("command", value.to_json())
    None => ()
  }
  match exit_code {
    Some(value) => fields.set("exit_code", value.to_json())
    None => ()
  }
  match tdd_output_tail(output) {
    Some(value) => fields.set("output_tail", value)
    None => ()
  }
  @types.Response::ok_values(fields)
}

///|
pub fn interpret_tdd_intent(
  args : TddIntentArgs,
  tdd_phase_reader : (String) -> @types.LeafTddPhase?,
  tdd_phase_writer : (String, @types.LeafTddPhase) -> Unit,
) -> @types.Response {
  match plan_tdd_intent_transition(tdd_phase_reader(args.caller_id)) {
    Err(e) => @types.Response::Err(e.message())
    Ok(next) => {
      tdd_phase_writer(args.caller_id, next)
      let fields : Map[String, Json] = {
        "status": "tdd_phase_updated".to_json(),
        "agent_id": args.caller_id.to_json(),
        "phase": next.to_json(),
        "tool": "tdd_intent".to_json(),
        "intent": args.intent.to_json(),
      }
      match args.test_command {
        Some(command) => fields.set("test_command", command.to_json())
        None => ()
      }
      @types.Response::ok_values(fields)
    }
  }
}

///|
pub async fn interpret_tdd_red_check(
  args : TddRedCheckArgs,
  tdd_phase_reader : (String) -> @types.LeafTddPhase?,
  tdd_phase_writer : (String, @types.LeafTddPhase) -> Unit,
  project_dir? : String = ".",
  capture? : async (@workspace.Command) -> (Int, String) = tdd_default_capture,
) -> @types.Response {
  let next = match
    plan_tdd_red_check_transition(
      tdd_phase_reader(args.caller_id),
      args.exit_code,
    ) {
    Ok(phase) => phase
    Err(e) => return @types.Response::Err(e.message())
  }
  let actual_output = match
    verify_tdd_reported_exit_code(
      project_dir,
      args.command,
      args.exit_code,
      capture,
    ) {
    Ok(output) => output
    Err(e) => return @types.Response::Err(e.message())
  }
  tdd_phase_writer(args.caller_id, next)
  tdd_phase_response(
    args.caller_id,
    next,
    "tdd_red_check",
    command=Some(args.command),
    exit_code=Some(args.exit_code),
    output=Some(actual_output),
  )
}

///|
pub async fn interpret_tdd_green_check(
  args : TddGreenCheckArgs,
  tdd_phase_reader : (String) -> @types.LeafTddPhase?,
  tdd_phase_writer : (String, @types.LeafTddPhase) -> Unit,
  project_dir? : String = ".",
  capture? : async (@workspace.Command) -> (Int, String) = tdd_default_capture,
) -> @types.Response {
  let next = match
    plan_tdd_green_check_transition(
      tdd_phase_reader(args.caller_id),
      args.exit_code,
      args.next_phase,
    ) {
    Ok(phase) => phase
    Err(e) => return @types.Response::Err(e.message())
  }
  let actual_output = match
    verify_tdd_reported_exit_code(
      project_dir,
      args.command,
      args.exit_code,
      capture,
    ) {
    Ok(output) => output
    Err(e) => return @types.Response::Err(e.message())
  }
  tdd_phase_writer(args.caller_id, next)
  tdd_phase_response(
    args.caller_id,
    next,
    "tdd_green_check",
    command=Some(args.command),
    exit_code=Some(args.exit_code),
    output=Some(actual_output),
  )
}
