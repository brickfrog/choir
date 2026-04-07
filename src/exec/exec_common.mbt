///|
pub fn quote(s : String) -> String {
  @sys.shell_quote(s)
}

///|
/// Subcommand used only by `choir dev` hot-reload (`watchexec` / `entr`): build native then run `serve`.
pub const DEV_RELOAD_SUBCOMMAND : String = "__dev_reload"

///|
/// `watchexec` invocation with `--shell=none` and a native `choir` hook (no `sh -c` for the reload step).
pub fn dev_watchexec_command(
  wx_path : String,
  choir_exe : String,
) -> @workspace.Command {
  {
    program: wx_path,
    args: [
      "-e",
      "mbt,toml",
      "-r",
      "--shell=none",
      "--",
      choir_exe,
      DEV_RELOAD_SUBCOMMAND,
    ],
    workdir: None,
  }
}

///|
/// First `find` in the former `entr` pipeline: `find src -name '*.mbt'`.
pub fn dev_entr_find_src_mbt_command() -> @workspace.Command {
  { program: "find", args: ["src", "-name", "*.mbt"], workdir: None }
}

///|
/// Second `find` in the former `entr` pipeline: `find . -maxdepth 2 -name '*.toml'`.
pub fn dev_entr_find_toml_command() -> @workspace.Command {
  {
    program: "find",
    args: [".", "-maxdepth", "2", "-name", "*.toml"],
    workdir: None,
  }
}

///|
/// `entr` argv for `choir dev` hot-reload (stdin is the concatenated `find` outputs).
pub fn dev_entr_entr_command(
  entr_path : String,
  choir_exe : String,
) -> @workspace.Command {
  {
    program: entr_path,
    args: ["-r", choir_exe, DEV_RELOAD_SUBCOMMAND],
    workdir: None,
  }
}

///|
pub fn command_to_shell_string(cmd : @workspace.Command) -> String {
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
/// Scan `path_var` as a POSIX `PATH` (colon-separated dirs) and return the first
/// `dir/name` that exists as a readable file path (`path_exists`).
pub fn resolve_executable_in_path_from_path_var(
  name : String,
  path_var : String,
) -> String? {
  for raw in path_var.split(":") {
    let dir = raw.trim().to_string()
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
/// Resolve `name` using the process `PATH` (or a common default when unset).
pub fn resolve_executable_in_path(name : String) -> String? {
  let path_var = match @sys.getenv("PATH") {
    Some(p) => p
    None => "/usr/local/bin:/usr/bin:/bin"
  }
  resolve_executable_in_path_from_path_var(name, path_var)
}

///|
fn is_space_plugin_cu(c : UInt16) -> Bool {
  c == ' ' || c == '\t' || c == '\n' || c == '\r'
}

///|
fn is_valid_shell_var_name(name : String) -> Bool {
  if name.length() == 0 {
    return false
  }
  let c0 = name[0]
  if c0 != '_' && (c0 < 'a' || c0 > 'z') && (c0 < 'A' || c0 > 'Z') {
    return false
  }
  for i = 1; i < name.length(); i = i + 1 {
    let c = name[i]
    if c != '_' &&
      (c < 'a' || c > 'z') &&
      (c < 'A' || c > 'Z') &&
      (c < '0' || c > '9') {
      return false
    }
  }
  true
}

///|
/// True when the first token looks like a POSIX `NAME=value` prefix (handled by a shell, not plain
/// `execve` of argv[0]).
fn first_token_is_env_assignment(argv0 : String) -> Bool {
  let mut eq = -1
  for i = 0; i < argv0.length(); i = i + 1 {
    if argv0[i] == '=' {
      eq = i
      break
    }
  }
  if eq <= 0 {
    return false
  }
  let name = argv0[:eq].to_string()
  is_valid_shell_var_name(name)
}

///|
/// True when `&&`, `||`, `;`, `|`, redirections (`>`, `<`), `&`, or subshell parens (`(`, `)`) appear
/// in **unquoted** spans
/// (POSIX-like `'...'` and `"..."` with the same backslash escapes as [`parse_plugin_argv_line`]).
/// Metacharacters that are only **quoted** are literal and do not force `sh -c` by themselves.
fn unquoted_shell_metachars_present(s : String) -> Bool {
  let mut i = 0
  let n = s.length()
  let mut in_single = false
  let mut in_double = false
  while i < n {
    let c = s[i]
    if in_single {
      if c == '\'' {
        in_single = false
      }
      i = i + 1
      continue
    }
    if in_double {
      if c == '\\' && i + 1 < n {
        i = i + 2
        continue
      }
      if c == '"' {
        in_double = false
      }
      i = i + 1
      continue
    }
    if c == '\'' {
      in_single = true
      i = i + 1
      continue
    }
    if c == '"' {
      in_double = true
      i = i + 1
      continue
    }
    if i + 1 < n && c == '&' && s[i + 1] == '&' {
      return true
    }
    if i + 1 < n && c == '|' && s[i + 1] == '|' {
      return true
    }
    if c == ';' || c == '|' {
      return true
    }
    if c == '>' || c == '<' {
      return true
    }
    if c == '&' {
      return true
    }
    if c == '(' || c == ')' {
      return true
    }
    i = i + 1
  }
  false
}

///|
/// Conservative shell-only signals that are not modeled by [`parse_plugin_argv_line`]: newlines,
/// expansion (`$`, `` ` ``), glob (`*`, `?`). Parens are handled in [`unquoted_shell_metachars_present`]
/// so literal `)` inside quotes does not force `sh -c`.
fn plugin_shell_global_heuristic(s : String) -> Bool {
  if s.contains("\n") {
    return true
  }
  if s.contains("$") {
    return true
  }
  if s.contains("`") {
    return true
  }
  if s.contains("*") {
    return true
  }
  if s.contains("?") {
    return true
  }
  false
}

///|
/// Returns true when [`capture_plugin_shell_command`] runs the plugin via
/// `timeout … sh -c <plugin_command>` instead of `timeout … <argv…>`.
///
/// **Argv-safe** (no shell): a single-line token list that parses with [`parse_plugin_argv_line`],
/// is non-empty, has no `VAR=value` prefix on argv0, and passes the heuristics above.
///
/// **Shell-required** (non-exhaustive): unquoted shell operators, redirections, subshell parens;
/// expansion or glob characters anywhere in the string (quoted spans still count for `$` / glob —
/// conservative); multi-line commands; unbalanced or ambiguous quotes (parse fails); leading env
/// assignment.
pub fn plugin_capture_uses_shell(plugin_command : String) -> Bool {
  let s = plugin_command.trim().to_string()
  if s == "" {
    return true
  }
  if plugin_shell_global_heuristic(s) {
    return true
  }
  if unquoted_shell_metachars_present(s) {
    return true
  }
  match parse_plugin_argv_line(plugin_command) {
    None => true
    Some(words) =>
      if words.length() == 0 {
        true
      } else if first_token_is_env_assignment(words[0]) {
        true
      } else {
        false
      }
  }
}

///|
/// Parse a single-line plugin command into argv words (POSIX-like single/double quotes). Returns
/// `None` when quotes are unbalanced or a quote appears mid-token in a way this subset does not
/// model (caller should fall back to `sh -c`).
fn parse_plugin_argv_line(raw : String) -> Array[String]? {
  let s = raw.trim()
  if s == "" {
    return Some([])
  }
  let out : Array[String] = []
  let mut i = 0
  let n = s.length()
  while i < n {
    while i < n && is_space_plugin_cu(s[i]) {
      i = i + 1
    }
    if i >= n {
      break
    }
    if s[i] == '\'' {
      i = i + 1
      let wstart = i
      while i < n && s[i] != '\'' {
        i = i + 1
      }
      if i >= n {
        return None
      }
      out.push(s[wstart:i].to_string())
      i = i + 1
    } else if s[i] == '"' {
      i = i + 1
      let buf = StringBuilder::new()
      let mut closed = false
      while i < n {
        if s[i] == '\\' && i + 1 < n {
          let c = s[i + 1]
          if c == '"' || c == '\\' || c == '$' || c == '`' {
            buf.write_char(Int::unsafe_to_char(c.to_int()))
            i = i + 2
          } else if c == '\n' {
            buf.write_char('\n')
            i = i + 2
          } else {
            buf.write_char(Int::unsafe_to_char(c.to_int()))
            i = i + 2
          }
        } else if s[i] == '"' {
          closed = true
          i = i + 1
          break
        } else {
          buf.write_char(Int::unsafe_to_char(s[i].to_int()))
          i = i + 1
        }
      }
      if !closed {
        return None
      }
      out.push(buf.to_string())
    } else {
      let wstart = i
      while i < n && !is_space_plugin_cu(s[i]) {
        if s[i] == '\'' || s[i] == '"' {
          return None
        }
        i = i + 1
      }
      out.push(s[wstart:i].to_string())
    }
  }
  Some(out)
}

///|
test "parse_plugin_argv_line splits unquoted words" {
  match parse_plugin_argv_line("choir tool plugin_run") {
    Some(parts) => {
      assert_eq(parts.length(), 3)
      assert_eq(parts[0], "choir")
      assert_eq(parts[1], "tool")
      assert_eq(parts[2], "plugin_run")
    }
    None => fail("expected argv")
  }
}

///|
test "parse_plugin_argv_line respects double quotes" {
  match parse_plugin_argv_line("\"a b\" c") {
    Some(parts) => {
      assert_eq(parts.length(), 2)
      assert_eq(parts[0], "a b")
      assert_eq(parts[1], "c")
    }
    None => fail("expected argv")
  }
}

///|
test "parse_plugin_argv_line returns None on unclosed quote" {
  assert_eq(parse_plugin_argv_line("echo \""), None)
}

///|
test "first_token_is_env_assignment detects VAR=value prefix" {
  assert_true(first_token_is_env_assignment("FOO=bar"))
  assert_false(first_token_is_env_assignment("./bin=odd"))
}
