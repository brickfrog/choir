///|
pub(all) struct PrenotifyCheckOutcome {
  command : String
  exit_code : Int
  output_tail : String
} derive(Debug, Eq)

///|
fn prenotify_check_output_tail(output : String) -> String {
  let trimmed = output.trim().to_owned()
  let max_chars = 1200
  if trimmed.length() <= max_chars {
    trimmed
  } else {
    "[truncated]\n" + trimmed[trimmed.length() - max_chars:].to_owned()
  }
}

///|
fn prenotify_check_command(
  command : String,
  project_dir : String,
) -> @workspace.Command {
  { program: "sh", args: ["-lc", command], workdir: Some(project_dir) }
}

///|
fn prenotify_check_details(
  project_dir : String,
  outcome : PrenotifyCheckOutcome,
) -> String {
  let base = "cwd: " + project_dir + "\nexit: " + outcome.exit_code.to_string()
  if outcome.output_tail == "" {
    base
  } else {
    base + "\noutput_tail:\n" + outcome.output_tail
  }
}

///|
fn prenotify_check_failure_error(
  project_dir : String,
  outcome : PrenotifyCheckOutcome,
) -> @types.ChoirError {
  @types.ChoirError::validation_error(
    "notify_parent blocked: pre-notify check failed for `" +
    outcome.command +
    "`\nFix the failing check and call notify_parent again.\n" +
    prenotify_check_details(project_dir, outcome),
  )
}

///|
fn prenotify_has_nonempty_check(checks : Array[String]) -> Bool {
  for raw in checks {
    if raw.trim() != "" {
      return true
    }
  }
  false
}

///|
pub fn prenotify_checks_should_run(
  caller_role : @types.Role,
  status : @types.Status,
  checks : Array[String],
) -> Bool {
  caller_role == @types.Role::Dev &&
  status == @types.Status::Success &&
  prenotify_has_nonempty_check(checks)
}

///|
pub async fn run_prenotify_checks(
  project_dir : String,
  checks : Array[String],
  capture : async (@workspace.Command) -> (Int, String),
) -> Result[Array[PrenotifyCheckOutcome], @types.ChoirError] {
  let outcomes : Array[PrenotifyCheckOutcome] = []
  for raw in checks {
    let command = raw.trim().to_owned()
    if command == "" {
      continue
    }
    let (exit_code, output) = capture(
      prenotify_check_command(command, project_dir),
    )
    let outcome : PrenotifyCheckOutcome = {
      command,
      exit_code,
      output_tail: prenotify_check_output_tail(output),
    }
    outcomes.push(outcome)
    if exit_code != 0 {
      return Err(prenotify_check_failure_error(project_dir, outcome))
    }
  }
  Ok(outcomes)
}
