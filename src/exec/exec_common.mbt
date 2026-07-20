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
  workspace : String
  listen_uds : String
}

///|
pub fn conductor_claude_mcp_config_json() -> String {
  "{\"mcpServers\":{\"choir\":{\"type\":\"stdio\",\"command\":\"choir\",\"args\":[\"mcp-stdio\",\"--name\",\"root\",\"--stderr-append-log\",\".choir/logs/mcp-stdio.stderr.log\"],\"alwaysLoad\":true}}}"
}

///|
pub fn conductor_claude_settings_json() -> String {
  "{\"enabledPlugins\":{\"choir@local\":true}}"
}

///|
pub fn conductor_launch_command(
  project_dir : String,
  lean? : Bool = false,
) -> Command {
  let lean_args : Array[String] = if lean {
    ["--system-prompt", "."]
  } else {
    []
  }
  {
    program: "claude",
    args: [
      "--dangerously-skip-permissions",
      "--tools",
      "",
      "--setting-sources",
      "",
      "--mcp-config",
      conductor_claude_mcp_config_json(),
      "--strict-mcp-config",
      "--plugin-dir",
      project_dir + "/.choir/plugin",
      "--settings",
      project_dir + "/.choir/state/claude-settings.json",
      ..lean_args,
    ],
    workdir: None,
  }
}

///|
pub fn quote(s : String) -> String {
  @sys.shell_quote(s)
}

///|
fn terminal_response_is_digit(c : UInt16) -> Bool {
  c >= '0' && c <= '9'
}

///|
fn terminal_response_osc_end(s : String, start : Int) -> Int? {
  let n = s.length()
  if start + 3 >= n || s[start] != '\u{1b}' || s[start + 1] != ']' {
    return None
  }
  let payload_start = if s[start + 2] == '4' && s[start + 3] == ';' {
    start + 4
  } else if start + 4 < n &&
    s[start + 2] == '1' &&
    (s[start + 3] == '0' || s[start + 3] == '1') &&
    s[start + 4] == ';' {
    start + 5
  } else {
    return None
  }
  let mut j = payload_start
  while j < n {
    if s[j] == '\u{07}' {
      return Some(j + 1)
    }
    if j + 1 < n && s[j] == '\u{1b}' && s[j + 1] == '\\' {
      return Some(j + 2)
    }
    j = j + 1
  }
  None
}

///|
fn terminal_response_primary_da_end(s : String, start : Int) -> Int? {
  let n = s.length()
  if start + 3 >= n ||
    s[start] != '\u{1b}' ||
    s[start + 1] != '[' ||
    s[start + 2] != '?' {
    return None
  }
  let mut j = start + 3
  let mut saw_digit = false
  while j < n && (terminal_response_is_digit(s[j]) || s[j] == ';') {
    if terminal_response_is_digit(s[j]) {
      saw_digit = true
    }
    j = j + 1
  }
  if saw_digit && j < n && s[j] == 'c' {
    Some(j + 1)
  } else {
    None
  }
}

///|
fn terminal_response_cpr_end(s : String, start : Int) -> Int? {
  let n = s.length()
  if start + 4 >= n || s[start] != '\u{1b}' || s[start + 1] != '[' {
    return None
  }
  let mut j = start + 2
  let row_start = j
  while j < n && terminal_response_is_digit(s[j]) {
    j = j + 1
  }
  if j == row_start || j >= n || s[j] != ';' {
    return None
  }
  j = j + 1
  let col_start = j
  while j < n && terminal_response_is_digit(s[j]) {
    j = j + 1
  }
  if j == col_start || j >= n || s[j] != 'R' {
    return None
  }
  Some(j + 1)
}

///|
fn terminal_response_end(s : String, start : Int) -> Int? {
  match terminal_response_osc_end(s, start) {
    Some(end) => Some(end)
    None =>
      match terminal_response_primary_da_end(s, start) {
        Some(end) => Some(end)
        None => terminal_response_cpr_end(s, start)
      }
  }
}

///|
/// Remove terminal response escape sequences that can leak from PTY-backed
/// subprocesses into logs. SGR color/style escapes are intentionally kept.
pub fn strip_terminal_responses(s : String) -> String {
  let buf = StringBuilder::new()
  let mut i = 0
  let n = s.length()
  while i < n {
    if s[i] == '\u{1b}' {
      match terminal_response_end(s, i) {
        Some(end) => {
          i = end
          continue
        }
        None => ()
      }
    }
    buf.write_char(Int::unsafe_to_char(s[i].to_int()))
    i = i + 1
  }
  buf.to_string()
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
pub let hermetic_no_exec_env : String = "CHOIR_TEST_NO_EXEC"

///|
pub let real_exec_integration_env : String = "CHOIR_TEST_REAL_EXEC"

///|
pub fn hermetic_exec_violation_message(command : String) -> String {
  "hermetic-test violation: real exec " +
  command +
  " -- inject a mock capture/runner"
}

///|
pub fn hermetic_test_no_exec_enabled() -> Bool {
  @env.get_env_var(hermetic_no_exec_env) is Some(_)
}

///|
pub fn real_exec_integration_enabled() -> Bool {
  match @env.get_env_var(real_exec_integration_env) {
    Some(value) => value == "1"
    None => false
  }
}

///|
fn abort_if_hermetic_test_exec(command : String) -> Unit {
  if hermetic_test_no_exec_enabled() {
    abort(hermetic_exec_violation_message(command))
  }
}

///|
fn command_for_program(
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
