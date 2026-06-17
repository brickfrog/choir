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
} derive(Eq)

///|
fn tdd_state_phase(state : @types.LeafTddState?) -> @types.LeafTddPhase? {
  match state {
    Some(value) => Some(value.phase)
    None => None
  }
}

///|
priv struct TddConfiguredVerify {
  workdir : String
  command : String
  commands : Array[String]
}

///|
fn tdd_normalized_verify_commands(
  commands : Array[String],
) -> Result[Array[String], @types.ChoirError] {
  let normalized : Array[String] = []
  for raw in commands {
    let trimmed = raw.trim().to_owned()
    if trimmed != "" {
      normalized.push(trimmed)
    }
  }
  if normalized.length() == 0 {
    Err(
      tdd_transition_error(
        "task contract does not configure any verify command for TDD red/green checks",
      ),
    )
  } else {
    Ok(normalized)
  }
}

///|
fn tdd_configured_command_script(commands : Array[String]) -> String {
  commands.join(" && ")
}

///|
fn tdd_validate_leaf_declared_command(
  declared : String?,
  configured : TddConfiguredVerify,
) -> Result[Unit, @types.ChoirError] {
  match declared {
    None => Ok(())
    Some(command) => {
      let trimmed = command.trim().to_owned()
      if trimmed == "" {
        return Err(
          tdd_transition_error(
            "tdd_intent test_command is optional, but when supplied it must be non-empty and match the configured verify command",
          ),
        )
      }
      if trimmed == configured.command || configured.commands.contains(trimmed) {
        Ok(())
      } else {
        Err(
          tdd_transition_error(
            "tdd_intent test_command must match the configured verify command; configured verify is `" +
            configured.command +
            "`",
          ),
        )
      }
    }
  }
}

///|
fn tdd_validate_artifact_path(
  raw : String,
) -> Result[String, @types.ChoirError] {
  let path = raw.trim().to_owned()
  if path == "" {
    return Err(tdd_transition_error("artifact_path must be non-empty"))
  }
  if path.has_prefix("/") {
    return Err(tdd_transition_error("artifact_path must be relative"))
  }
  for c in path {
    if c == '\n' || c == '\r' {
      return Err(tdd_transition_error("artifact_path must stay on one line"))
    }
  }
  for part in path.split("/") {
    if part == ".." {
      return Err(tdd_transition_error("artifact_path must not contain '..'"))
    }
  }
  Ok(path)
}

///|
fn tdd_configured_verify_mentions_artifact(
  configured : TddConfiguredVerify,
  artifact_path : String,
) -> Bool {
  for command in configured.commands {
    if tdd_command_checks_artifact_path(command, artifact_path) {
      return true
    }
  }
  false
}

///|
fn tdd_unquoted_comment_index(segment : String) -> Int? {
  let mut in_double = false
  let mut in_single = false
  let mut i = 0
  while i < segment.length() {
    let c = segment[i]
    if c == '"' && !in_single {
      in_double = !in_double
    } else if c == '\'' && !in_double {
      in_single = !in_single
    } else if c == '#' &&
      !in_single &&
      !in_double &&
      (i == 0 || tdd_token_space(segment[i - 1])) {
      return Some(i)
    }
    i = i + 1
  }
  None
}

///|
fn tdd_token_space(c : UInt16) -> Bool {
  c == ' ' || c == '\t' || c == '\n' || c == '\r'
}

///|
fn tdd_command_tokens(command : String) -> Array[String] {
  let command = match tdd_unquoted_comment_index(command) {
    Some(idx) => command[:idx].to_owned()
    None => command
  }
  let tokens : Array[String] = []
  let mut token = ""
  let mut token_active = false
  let mut in_double = false
  let mut in_single = false
  let mut i = 0
  while i < command.length() {
    let c = command[i]
    if c == '"' && !in_single {
      in_double = !in_double
      token_active = true
    } else if c == '\'' && !in_double {
      in_single = !in_single
      token_active = true
    } else if !in_single && !in_double && tdd_token_space(c) {
      if token_active {
        tokens.push(token)
        token = ""
        token_active = false
      }
    } else {
      token = token + command[i:i + 1].to_owned()
      token_active = true
    }
    i = i + 1
  }
  if token_active {
    tokens.push(token)
  }
  tokens
}

///|
fn tdd_file_test_operator(token : String) -> Bool {
  token == "-e" || token == "-f" || token == "-s"
}

///|
fn tdd_token_is_shell_separator(token : String) -> Bool {
  token == "&&" || token == "||" || token == ";" || token == "|"
}

///|
fn tdd_test_command_checks_artifact(
  tokens : Array[String],
  start : Int,
  artifact_path : String,
) -> Bool {
  let mut i = start + 1
  while i < tokens.length() && !tdd_token_is_shell_separator(tokens[i]) {
    if tdd_file_test_operator(tokens[i]) &&
      i + 1 < tokens.length() &&
      tokens[i + 1] == artifact_path {
      return true
    }
    i = i + 1
  }
  false
}

///|
fn tdd_command_checks_artifact_path(
  command : String,
  artifact_path : String,
) -> Bool {
  let tokens = tdd_command_tokens(command)
  let mut i = 0
  while i < tokens.length() {
    if tokens[i] == "test" || tokens[i] == "[" || tokens[i] == "[[" {
      if tdd_test_command_checks_artifact(tokens, i, artifact_path) {
        return true
      }
    }
    i = i + 1
  }
  false
}

///|
fn tdd_validate_artifact_intent(
  raw : String?,
  configured : TddConfiguredVerify,
) -> Result[String?, @types.ChoirError] {
  match raw {
    None => Ok(None)
    Some(value) => {
      let artifact_path = match tdd_validate_artifact_path(value) {
        Ok(path) => path
        Err(e) => return Err(e)
      }
      if tdd_configured_verify_mentions_artifact(configured, artifact_path) {
        Ok(Some(artifact_path))
      } else {
        Err(
          tdd_transition_error(
            "artifact mode requires the configured verify command to check artifact_path `" +
            artifact_path +
            "` as a file-test operand; re-scope the wave with an artifact verify such as `test -f " +
            artifact_path +
            " && <verify>`",
          ),
        )
      }
    }
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
  registry : @registry.AgentRegistry?,
  caller_id : String,
) -> Result[String, @types.ChoirError] {
  match registry {
    None =>
      Err(
        tdd_transition_error(
          "cannot resolve caller workspace for TDD verification without an agent registry",
        ),
      )
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
fn tdd_configured_verify(
  registry : @registry.AgentRegistry?,
  caller_id : String,
  task_contract_reader : (String) -> @types.TaskContract?,
) -> Result[TddConfiguredVerify, @types.ChoirError] {
  let workdir = match tdd_check_workdir(registry, caller_id) {
    Ok(value) => value
    Err(e) => return Err(e)
  }
  let contract = match task_contract_reader(caller_id) {
    Some(value) => value
    None =>
      return Err(
        tdd_transition_error(
          "cannot resolve configured verify command for caller '" +
          caller_id +
          "' from server task contract",
        ),
      )
  }
  let commands = match tdd_normalized_verify_commands(contract.verify) {
    Ok(value) => value
    Err(e) => return Err(e)
  }
  let command = tdd_configured_command_script(commands)
  Ok({ workdir, command, commands })
}

///|
fn tdd_text_tail(raw : String) -> String {
  let trimmed = collapse_cr_progress(raw).trim().to_owned()
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
fn tdd_baseline_advisory_message(
  command : String,
  baseline_sha : String,
) -> String {
  "verify: " +
  command +
  " failed but already red at baseline " +
  baseline_sha +
  " -> advisory, not blocking"
}

///|
fn tdd_join_command_outputs(outputs : Array[String]) -> String {
  let chunks : Array[String] = []
  for output in outputs {
    let trimmed = output.trim().to_owned()
    if trimmed != "" {
      chunks.push(trimmed)
    }
  }
  chunks.join("\n")
}

///|
async fn tdd_failed_verify_advisory(
  caller_id : String,
  project_dir : String,
  command : String,
  baseline_sha_for_agent : (String) -> String?,
  baseline_git_capture : async (@workspace.Command) -> (Int, String),
  capture : async (@workspace.Command) -> (Int, String),
  baseline_verify : async (
    String,
    String,
    String,
    async (@workspace.Command) -> (Int, String),
    async (@workspace.Command) -> (Int, String),
  ) -> BaselineOutcome,
) -> String? {
  let baseline_sha = match baseline_sha_for_agent(caller_id) {
    Some(value) => value.trim().to_owned()
    None => return None
  }
  if baseline_sha == "" {
    return None
  }
  match
    baseline_verify(
      baseline_sha, command, project_dir, baseline_git_capture, capture,
    ) {
    BaselineOutcome::AlreadyRed => {
      let message = tdd_baseline_advisory_message(command, baseline_sha)
      @moontrace.warn(message, fields=[
        @moontrace.field("event", "verify_baseline_advisory"),
        @moontrace.field("context", "tdd_green_check"),
        @moontrace.field("command", command),
        @moontrace.field("baseline_sha", baseline_sha),
      ])
      Some(message)
    }
    BaselineOutcome::GreenAtBaseline | BaselineOutcome::Unknown => None
  }
}

///|
async fn verify_tdd_command_outcome(
  project_dir : String,
  command : String,
  expectation : TddExitExpectation,
  capture : async (@workspace.Command) -> (Int, String),
) -> Result[String, @types.ChoirError] {
  let expectation_detail = match expectation {
    RedFailure => "red check expected exit code to be non-zero"
  }
  let (actual_exit_code, actual_output) = capture(
    tdd_check_command(project_dir, command),
  )
  if actual_exit_code < 0 {
    return Err(
      tdd_transition_error(
        "configured verify command could not be executed; actual exit code " +
        actual_exit_code.to_string() +
        tdd_exit_verification_context(command, actual_output),
      ),
    )
  }
  let ok = match expectation {
    RedFailure => actual_exit_code != 0
  }
  if !ok {
    Err(
      tdd_transition_error(
        "configured verify command actual exit code " +
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
async fn verify_tdd_green_commands_outcome(
  project_dir : String,
  caller_id : String,
  commands : Array[String],
  capture : async (@workspace.Command) -> (Int, String),
  baseline_sha_for_agent : (String) -> String?,
  baseline_git_capture : async (@workspace.Command) -> (Int, String),
  baseline_verify : async (
    String,
    String,
    String,
    async (@workspace.Command) -> (Int, String),
    async (@workspace.Command) -> (Int, String),
  ) -> BaselineOutcome,
) -> Result[String, @types.ChoirError] {
  let outputs : Array[String] = []
  for command in commands {
    let (actual_exit_code, actual_output) = capture(
      tdd_check_command(project_dir, command),
    )
    if actual_exit_code < 0 {
      return Err(
        tdd_transition_error(
          "configured verify command could not be executed; actual exit code " +
          actual_exit_code.to_string() +
          tdd_exit_verification_context(command, actual_output),
        ),
      )
    }
    if actual_exit_code == 0 {
      outputs.push(actual_output)
    } else {
      let advisory = tdd_failed_verify_advisory(
        caller_id, project_dir, command, baseline_sha_for_agent, baseline_git_capture,
        capture, baseline_verify,
      )
      match advisory {
        Some(message) =>
          if actual_output.trim() == "" {
            outputs.push(message)
          } else {
            outputs.push(message + "\n" + actual_output)
          }
        None =>
          return Err(
            tdd_transition_error(
              "configured verify command actual exit code " +
              actual_exit_code.to_string() +
              " did not satisfy green check expected exit code 0" +
              tdd_exit_verification_context(command, actual_output),
            ),
          )
      }
    }
  }
  Ok(tdd_join_command_outputs(outputs))
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
        "red check rejected because the configured verify passed (exit 0): there is no failing test / no red to open the TDD gate. For code changes, write the failing test first, run the configured verify until it fails, then rerun tdd_red_check before implementing the fix. For non-code doc/skill/config work, a blanket verify (for example `moon test`) may be green before and after, so it can never produce the required red; the wave verify must red->green on the artifact, for example `test -f <path> && <verify>`. If this is non-code work, notify the parent TL to re-scope/re-fork the wave with an artifact verify.",
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
      let tail = tdd_text_tail(raw)
      if tail == "" {
        None
      } else {
        Some(tail.to_json())
      }
    }
    None => None
  }
}

///|
test "tdd_output_tail uses collapsed carriage-return text tail" {
  let raw = "red\n[>      ] 1/319\r[==>    ] 50/319\r[======] 319/319 done\n"
  match tdd_output_tail(Some(raw)) {
    Some(String(value)) => {
      assert_false(value.contains("[>      ] 1/319"))
      assert_false(value.contains("[==>    ] 50/319"))
      assert_true(value.contains("[======] 319/319 done"))
      assert_true(value.contains("red"))
    }
    _ => fail("expected output_tail json string")
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
  registry? : @registry.AgentRegistry? = None,
  task_contract_reader? : (String) -> @types.TaskContract? = fn(_) { None },
) -> @types.Response {
  let configured = match
    tdd_configured_verify(registry, args.caller_id, task_contract_reader) {
    Ok(value) => value
    Err(e) => return @types.Response::Err(e.message())
  }
  match tdd_validate_leaf_declared_command(args.test_command, configured) {
    Ok(_) => ()
    Err(e) => return @types.Response::Err(e.message())
  }
  let artifact_path = match
    tdd_validate_artifact_intent(args.artifact_path, configured) {
    Ok(value) => value
    Err(e) => return @types.Response::Err(e.message())
  }
  match
    plan_tdd_intent_transition(
      tdd_state_phase(tdd_state_reader(args.caller_id)),
    ) {
    Err(e) => @types.Response::Err(e.message())
    Ok(next) => {
      tdd_state_writer(args.caller_id, { phase: next })
      let fields : Map[String, Json] = {
        "status": "tdd_phase_updated".to_json(),
        "agent_id": args.caller_id.to_json(),
        "phase": next.to_json(),
        "tool": "tdd_intent".to_json(),
        "intent": args.intent.to_json(),
      }
      fields.set("test_command", configured.command.to_json())
      match artifact_path {
        Some(value) => fields.set("artifact_path", value.to_json())
        None => ()
      }
      @types.Response::ok_values(fields)
    }
  }
}

///|
pub async fn interpret_tdd_red_check(
  args : TddRedCheckArgs,
  tdd_state_reader : (String) -> @types.LeafTddState?,
  tdd_state_writer : (String, @types.LeafTddState) -> Unit,
  registry? : @registry.AgentRegistry? = None,
  task_contract_reader? : (String) -> @types.TaskContract? = fn(_) { None },
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
  let configured = match
    tdd_configured_verify(registry, args.caller_id, task_contract_reader) {
    Ok(value) => value
    Err(e) => return @types.Response::Err(e.message())
  }
  let actual_output = match
    verify_tdd_command_outcome(
      configured.workdir,
      configured.command,
      TddExitExpectation::RedFailure,
      capture,
    ) {
    Ok(output) => output
    Err(e) => return @types.Response::Err(e.message())
  }
  tdd_state_writer(args.caller_id, { phase: next })
  tdd_phase_response(
    args.caller_id,
    next,
    "tdd_red_check",
    command=Some(configured.command),
    exit_code=Some(args.exit_code),
    output=Some(actual_output),
  )
}

///|
pub async fn interpret_tdd_green_check(
  args : TddGreenCheckArgs,
  tdd_state_reader : (String) -> @types.LeafTddState?,
  tdd_state_writer : (String, @types.LeafTddState) -> Unit,
  registry? : @registry.AgentRegistry? = None,
  task_contract_reader? : (String) -> @types.TaskContract? = fn(_) { None },
  capture? : async (@workspace.Command) -> (Int, String) = capture_command_output,
  baseline_sha_for_agent? : (String) -> String? = fn(_) { None },
  baseline_git_capture? : async (@workspace.Command) -> (Int, String) = capture,
  baseline_verify? : async (
    String,
    String,
    String,
    async (@workspace.Command) -> (Int, String),
    async (@workspace.Command) -> (Int, String),
  ) -> BaselineOutcome = async fn(
    baseline_sha,
    command,
    project_dir,
    git_capture,
    capture,
  ) {
    baseline_verify_command_outcome(
      baseline_sha, command, project_dir, git_capture, capture,
    )
  },
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
  let configured = match
    tdd_configured_verify(registry, args.caller_id, task_contract_reader) {
    Ok(value) => value
    Err(e) => return @types.Response::Err(e.message())
  }
  let actual_output = match
    verify_tdd_green_commands_outcome(
      configured.workdir,
      args.caller_id,
      configured.commands,
      capture,
      baseline_sha_for_agent,
      baseline_git_capture,
      baseline_verify,
    ) {
    Ok(output) => output
    Err(e) => return @types.Response::Err(e.message())
  }
  tdd_state_writer(args.caller_id, { phase: next })
  tdd_phase_response(
    args.caller_id,
    next,
    "tdd_green_check",
    command=Some(configured.command),
    exit_code=Some(args.exit_code),
    output=Some(actual_output),
  )
}
