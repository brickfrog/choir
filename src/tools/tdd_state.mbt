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
enum TddExitExpectation {
  RedFailure
  GreenSuccess
} derive(Eq)

///|
fn tdd_state_phase(state : @types.LeafTddState?) -> @types.LeafTddPhase? {
  match state {
    Some(value) => Some(value.phase)
    None => None
  }
}

///|
fn tdd_normalized_test_command(
  command : String,
) -> Result[String, @types.ChoirError] {
  let trimmed = command.trim().to_owned()
  if trimmed == "" {
    Err(
      tdd_transition_error(
        "tdd_intent requires a non-empty test_command to verify red/green checks",
      ),
    )
  } else {
    Ok(trimmed)
  }
}

///|
fn tdd_declared_test_command(
  state : @types.LeafTddState?,
) -> Result[String, @types.ChoirError] {
  match state {
    Some(value) =>
      match value.test_command {
        Some(command) => tdd_normalized_test_command(command)
        None =>
          Err(
            tdd_transition_error(
              "tdd_intent did not persist a test_command; declare intent again with test_command before checking red/green",
            ),
          )
      }
    None =>
      Err(
        tdd_transition_error(
          "red/green check requires tdd_intent with a persisted test_command first",
        ),
      )
  }
}

///|
fn tdd_check_command(
  project_dir : String,
  command : String,
) -> @workspace.Command {
  { program: "sh", args: ["-lc", command], workdir: Some(project_dir) }
}

///|
pub fn tdd_check_workdir(
  project_dir : String,
  registry : @registry.AgentRegistry?,
  caller_id : String,
) -> Result[String, @types.ChoirError] {
  match registry {
    None => Ok(project_dir)
    Some(reg) =>
      try {
        let agent = reg.get(caller_id)
        let workspace = agent.workspace.trim().to_owned()
        if workspace == "" {
          Err(
            tdd_transition_error(
              "caller '" +
              caller_id +
              "' is registered with an empty workspace; cannot run TDD verification",
            ),
          )
        } else {
          Ok(workspace)
        }
      } catch {
        e =>
          Err(
            tdd_transition_error(
              "cannot resolve caller workspace for TDD verification: " +
              @types.choir_error_message_from_caught(e),
            ),
          )
      } noraise {
        result => result
      }
  }
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
async fn verify_tdd_command_outcome(
  project_dir : String,
  command : String,
  expectation : TddExitExpectation,
  capture : async (@workspace.Command) -> (Int, String),
) -> Result[String, @types.ChoirError] {
  let (actual_exit_code, actual_output) = capture(
    tdd_check_command(project_dir, command),
  )
  if actual_exit_code < 0 {
    return Err(
      tdd_transition_error(
        "declared test command could not be executed; actual exit code " +
        actual_exit_code.to_string() +
        tdd_exit_verification_context(command, actual_output),
      ),
    )
  }
  let ok = match expectation {
    RedFailure => actual_exit_code != 0
    GreenSuccess => actual_exit_code == 0
  }
  if !ok {
    let expectation_detail = match expectation {
      RedFailure => "red check expected actual exit code to be non-zero"
      GreenSuccess => "green check expected actual exit code 0"
    }
    Err(
      tdd_transition_error(
        "declared test command actual exit code " +
        actual_exit_code.to_string() +
        " did not satisfy " +
        expectation_detail +
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
  tdd_state_reader : (String) -> @types.LeafTddState?,
  tdd_state_writer : (String, @types.LeafTddState) -> Unit,
) -> @types.Response {
  let command = match tdd_normalized_test_command(args.test_command) {
    Ok(value) => value
    Err(e) => return @types.Response::Err(e.message())
  }
  match
    plan_tdd_intent_transition(
      tdd_state_phase(tdd_state_reader(args.caller_id)),
    ) {
    Err(e) => @types.Response::Err(e.message())
    Ok(next) => {
      tdd_state_writer(args.caller_id, {
        phase: next,
        test_command: Some(command),
      })
      let fields : Map[String, Json] = {
        "status": "tdd_phase_updated".to_json(),
        "agent_id": args.caller_id.to_json(),
        "phase": next.to_json(),
        "tool": "tdd_intent".to_json(),
        "intent": args.intent.to_json(),
      }
      fields.set("test_command", command.to_json())
      @types.Response::ok_values(fields)
    }
  }
}

///|
pub async fn interpret_tdd_red_check(
  args : TddRedCheckArgs,
  tdd_state_reader : (String) -> @types.LeafTddState?,
  tdd_state_writer : (String, @types.LeafTddState) -> Unit,
  project_dir? : String = ".",
  registry? : @registry.AgentRegistry? = None,
  capture? : async (@workspace.Command) -> (Int, String) = capture_command_output,
) -> @types.Response {
  let current_state = tdd_state_reader(args.caller_id)
  let next = match
    plan_tdd_red_check_transition(
      tdd_state_phase(current_state),
      args.exit_code,
    ) {
    Ok(phase) => phase
    Err(e) => return @types.Response::Err(e.message())
  }
  let command = match tdd_declared_test_command(current_state) {
    Ok(value) => value
    Err(e) => return @types.Response::Err(e.message())
  }
  let check_dir = match
    tdd_check_workdir(project_dir, registry, args.caller_id) {
    Ok(value) => value
    Err(e) => return @types.Response::Err(e.message())
  }
  let actual_output = match
    verify_tdd_command_outcome(
      check_dir,
      command,
      TddExitExpectation::RedFailure,
      capture,
    ) {
    Ok(output) => output
    Err(e) => return @types.Response::Err(e.message())
  }
  tdd_state_writer(args.caller_id, { phase: next, test_command: Some(command) })
  tdd_phase_response(
    args.caller_id,
    next,
    "tdd_red_check",
    command=Some(command),
    exit_code=Some(args.exit_code),
    output=Some(actual_output),
  )
}

///|
pub async fn interpret_tdd_green_check(
  args : TddGreenCheckArgs,
  tdd_state_reader : (String) -> @types.LeafTddState?,
  tdd_state_writer : (String, @types.LeafTddState) -> Unit,
  project_dir? : String = ".",
  registry? : @registry.AgentRegistry? = None,
  capture? : async (@workspace.Command) -> (Int, String) = capture_command_output,
) -> @types.Response {
  let current_state = tdd_state_reader(args.caller_id)
  let next = match
    plan_tdd_green_check_transition(
      tdd_state_phase(current_state),
      args.exit_code,
      args.next_phase,
    ) {
    Ok(phase) => phase
    Err(e) => return @types.Response::Err(e.message())
  }
  let command = match tdd_declared_test_command(current_state) {
    Ok(value) => value
    Err(e) => return @types.Response::Err(e.message())
  }
  let check_dir = match
    tdd_check_workdir(project_dir, registry, args.caller_id) {
    Ok(value) => value
    Err(e) => return @types.Response::Err(e.message())
  }
  let actual_output = match
    verify_tdd_command_outcome(
      check_dir,
      command,
      TddExitExpectation::GreenSuccess,
      capture,
    ) {
    Ok(output) => output
    Err(e) => return @types.Response::Err(e.message())
  }
  tdd_state_writer(args.caller_id, { phase: next, test_command: Some(command) })
  tdd_phase_response(
    args.caller_id,
    next,
    "tdd_green_check",
    command=Some(command),
    exit_code=Some(args.exit_code),
    output=Some(actual_output),
  )
}
