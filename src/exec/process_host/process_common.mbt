///|
/// A validated process invocation assembled by an adapter. Orchestration code
/// passes these values to injected execution capabilities; it never runs them
/// directly.
pub(all) struct Command {
  program : String
  args : Array[String]
  workdir : String?
} derive(Debug, Eq)

///|
pub impl Show for Command with fn output(self, logger) -> Unit {
  self.to_repr().output(logger)
}

///|
pub(all) struct ConductorProcessEnvironment {
  conductor_token : String
  statusline_cache_key : String
  workspace : String
  listen_uds : String
}

///|
/// The environment the Conductor process is launched with: Choir's own handles
/// plus every variable the declared surface says the CLI must read.
///
/// Built as a value so the declared requirements are provably the ones passed.
/// The CLI-facing half is taken from `@harness.conductor_surface_environment()`
/// rather than written here, because a literal at the spawn site is exactly the
/// kind of undeclared dependency that went unnoticed through five launch
/// changes in one day.
pub fn conductor_process_environment_variables(
  environment : ConductorProcessEnvironment,
) -> Map[String, String] {
  let variables : Map[String, String] = {
    "CHOIR_CONDUCTOR_TOKEN": environment.conductor_token,
    "CHOIR_STATUSLINE_CACHE_KEY": environment.statusline_cache_key,
    "CHOIR_WORKSPACE": environment.workspace,
    "CHOIR_LISTEN_UDS": environment.listen_uds,
  }
  for requirement in @harness.conductor_surface_environment() {
    variables.set(requirement.name, requirement.value)
  }
  variables
}

///|
fn goal_worker_command(
  choir_executable : String,
  project_dir : String,
) -> Result[Command, @types.ChoirError] {
  if !choir_executable.has_prefix("/") || !project_dir.has_prefix("/") {
    return Err(
      @types.ChoirError::validation_error(
        "Goal worker requires absolute executable and project paths",
      ),
    )
  }
  Ok({
    program: choir_executable,
    args: ["run-goals"],
    workdir: Some(project_dir),
  })
}

///|
test "Goal worker command is bounded and executable-relative" {
  let command = goal_worker_command("/opt/choir/choir", "/repo").unwrap()
  assert_eq(command, Command::{
    program: "/opt/choir/choir",
    args: ["run-goals"],
    workdir: Some("/repo"),
  })
  assert_true(goal_worker_command("choir", "/repo") is Err(_))
}

///|
pub fn quote(s : String) -> String {
  @sys.shell_quote(s)
}

///|
pub fn command_to_shell_string(cmd : Command) -> String {
  let mut shell_cmd = quote(cmd.program)
  for arg in cmd.args {
    shell_cmd = shell_cmd + " " + quote(arg)
  }
  match cmd.workdir {
    None => shell_cmd
    Some(dir) => "cd " + quote(dir) + " && " + shell_cmd
  }
}

///|
pub fn abort_if_hermetic_test_exec(command : String) -> Unit {
  if @test_support.hermetic_test_no_exec_enabled() {
    abort(@test_support.hermetic_exec_violation_message(command))
  }
}

///|
pub fn command_for_program(
  program : String,
  args : Array[String],
  workdir : String?,
) -> String {
  command_to_shell_string(Command::{ program, args, workdir })
}

///|
pub fn resolve_executable_in_path_from_path_var(
  name : String,
  path_var : String,
) -> String? {
  for raw in path_var.split(":") {
    let dir = raw.trim().to_owned()
    if dir == "" {
      continue
    }
    let joined = dir + "/" + name
    if @sys.path_exists(joined) {
      return Some(joined)
    }
  }
  None
}

///|
pub fn resolve_executable_in_path(name : String) -> String? {
  let path_var = match @sys.getenv("PATH") {
    Some(p) => p
    None => "/usr/local/bin:/usr/bin:/bin"
  }
  resolve_executable_in_path_from_path_var(name, path_var)
}
