///|
pub fn quote(s : String) -> String {
  @sys.shell_quote(s)
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
/// Read up to `max_bytes` from a pipe wired to process stdout (or stderr), close the reader,
/// and return the captured output as lossy UTF-8 plus the number of bytes read.
pub async fn drain_process_stdout(
  reader : @process.ReadFromProcess,
  max_bytes : Int,
) -> (String, Int) {
  let buf = FixedArray::make(max_bytes, (0 : Byte))
  let mut total = 0
  for ;; {
    if total >= buf.length() {
      break
    }
    let n = reader.read(buf, offset=total, max_len=buf.length() - total) catch {
      _ => 0
    }
    if n == 0 {
      break
    }
    total = total + n
  }
  reader.close()
  (@utf8.decode_lossy(buf.unsafe_reinterpret_as_bytes()[:total]), total)
}

///|
/// Spawn `cmd` with argv (`program` + `args`) and optional `workdir`, redirecting stderr to the
/// same pipe as stdout (shell `2>&1` semantics). Capture up to 64KiB merged output, wait for exit.
/// Returns `(exit_code, output)`; negative `exit_code` means spawn/pipe/wait failure.
pub async fn capture_command_merged(cmd : @workspace.Command) -> (Int, String) {
  let (reader, writer) = @process.read_from_process() catch {
    _ => return (-1, "")
  }
  let prog = cmd.program
  let args = cmd.args[:]
  let pid = match cmd.workdir {
    Some(dir) =>
      @process.spawn_orphan(prog, args, stdout=writer, stderr=writer, cwd=dir) catch {
        _ => {
          reader.close()
          return (-1, "")
        }
      }
    None =>
      @process.spawn_orphan(prog, args, stdout=writer, stderr=writer) catch {
        _ => {
          reader.close()
          return (-1, "")
        }
      }
  }
  let (output, _) = drain_process_stdout(reader, 65536)
  let exit_code = @process.wait_pid(pid) catch { _ => -1 }
  (exit_code, output)
}

///|
/// Run `hook_path` as an executable (e.g. `*.sh` with shebang) with `stdin_body` written to stdin
/// (no trailing newline added; matches `printf '%s'` feeding a pipe). Stderr is merged into the
/// capture stream like shell `2>&1`. Returns `(exit_code, merged_output)`; negative `exit_code`
/// means spawn/pipe/wait failure.
pub async fn capture_hook_script_merged(
  hook_path : String,
  stdin_body : String,
  cwd : String?,
) -> (Int, String) {
  let (stdin_read, stdin_write) = @process.write_to_process() catch {
    _ => return (-1, "")
  }
  let (stdout_read, stdout_write) = @process.read_from_process() catch {
    _ => {
      stdin_write.close()
      return (-1, "")
    }
  }
  let argv : Array[String] = []
  let pid = match cwd {
    Some(dir) =>
      @process.spawn_orphan(
        hook_path,
        argv,
        stdin=stdin_read,
        stdout=stdout_write,
        stderr=stdout_write,
        cwd=dir,
      ) catch {
        _ => {
          stdin_write.close()
          stdout_read.close()
          return (-1, "")
        }
      }
    None =>
      @process.spawn_orphan(
        hook_path,
        argv,
        stdin=stdin_read,
        stdout=stdout_write,
        stderr=stdout_write,
      ) catch {
        _ => {
          stdin_write.close()
          stdout_read.close()
          return (-1, "")
        }
      }
  }
  ignore(stdin_write.write(stdin_body) catch { _ => () })
  stdin_write.close()
  let (output, _) = drain_process_stdout(stdout_read, 65536)
  let exit_code = @process.wait_pid(pid) catch { _ => -1 }
  (exit_code, output)
}

///|
/// Like [`capture_command_merged`], but only stdout is captured (stderr is not redirected to the
/// pipe). Matches shell `cmd >capture` without `2>&1` for JSON and other stdout-only protocols.
pub async fn capture_command_stdout(cmd : @workspace.Command) -> (Int, String) {
  let (reader, writer) = @process.read_from_process() catch {
    _ => return (-1, "")
  }
  let prog = cmd.program
  let args = cmd.args[:]
  let pid = match cmd.workdir {
    Some(dir) =>
      @process.spawn_orphan(prog, args, stdout=writer, cwd=dir) catch {
        _ => {
          reader.close()
          return (-1, "")
        }
      }
    None =>
      @process.spawn_orphan(prog, args, stdout=writer) catch {
        _ => {
          reader.close()
          return (-1, "")
        }
      }
  }
  let (output, _) = drain_process_stdout(reader, 65536)
  let exit_code = @process.wait_pid(pid) catch { _ => -1 }
  (exit_code, output)
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
/// Shell-only syntax: pipelines, redirections, expansion, globs, compound commands, etc.
fn plugin_command_requires_shell_interpreter(raw : String) -> Bool {
  let s = raw.trim()
  if s == "" {
    return true
  }
  if s.contains("&&") {
    return true
  }
  if s.contains("||") {
    return true
  }
  if s.contains(";") {
    return true
  }
  if s.contains("|") {
    return true
  }
  if s.contains("\n") {
    return true
  }
  if s.contains(">") {
    return true
  }
  if s.contains("<") {
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
  if s.contains("(") {
    return true
  }
  if s.contains(")") {
    return true
  }
  false
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
/// Run `plugin_command` under `timeout` (seconds), write `request_line` plus newline on stdin,
/// capture up to 64KiB of stdout (stderr discarded). When the command is a simple argv list
/// (no shell-only syntax), runs `timeout <sec> <argv...>` directly; otherwise falls back to
/// `timeout <sec> sh -c <plugin_command>`.
pub async fn capture_plugin_shell_command(
  plugin_command : String,
  request_line : String,
  timeout_sec : Int,
) -> (Int, String) {
  let (stdin_read, stdin_write) = @process.write_to_process() catch {
    _ => return (-1, "")
  }
  let (stdout_read, stdout_write) = @process.read_from_process() catch {
    _ => {
      stdin_write.close()
      return (-1, "")
    }
  }
  let stderr_dest = @process.redirect_to_file("/dev/null") catch {
    _ => {
      stdin_write.close()
      stdout_read.close()
      return (-1, "")
    }
  }
  let parsed = parse_plugin_argv_line(plugin_command)
  let use_shell = if plugin_command_requires_shell_interpreter(plugin_command) {
    true
  } else {
    match parsed {
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
  let timeout_args = if use_shell {
    [timeout_sec.to_string(), "sh", "-c", plugin_command]
  } else {
    match parsed {
      Some(words) => {
        let args : Array[String] = []
        args.push(timeout_sec.to_string())
        for w in words {
          args.push(w)
        }
        args
      }
      None => [timeout_sec.to_string(), "sh", "-c", plugin_command]
    }
  }
  let pid = @process.spawn_orphan(
    "timeout",
    timeout_args,
    stdin=stdin_read,
    stdout=stdout_write,
    stderr=stderr_dest,
  ) catch {
    _ => {
      stdin_write.close()
      stdout_read.close()
      return (-1, "")
    }
  }
  let line = request_line + "\n"
  ignore(stdin_write.write(line) catch { _ => () })
  stdin_write.close()
  let (output, _) = drain_process_stdout(stdout_read, 65536)
  let exit_code = @process.wait_pid(pid) catch { _ => -1 }
  (exit_code, output)
}

///|
/// Spawn `program` with `args`, capture stdout (up to 64KiB), wait for exit, return decoded output.
pub async fn capture_stdout(program : String, args : Array[String]) -> String {
  capture_stdout_with_cwd(program, args, None)
}

///|
/// Spawn `program` with `args` in `cwd`, capture stdout (up to 64KiB), wait for exit, return decoded output.
pub async fn capture_stdout_with_cwd(
  program : String,
  args : Array[String],
  cwd : String?,
) -> String {
  let (reader, writer) = @process.read_from_process() catch { _ => return "" }
  let pid = match cwd {
    Some(dir) =>
      @process.spawn_orphan(program, args[:], stdout=writer, cwd=dir) catch {
        _ => {
          reader.close()
          return ""
        }
      }
    None =>
      @process.spawn_orphan(program, args[:], stdout=writer) catch {
        _ => {
          reader.close()
          return ""
        }
      }
  }
  let (output, _) = drain_process_stdout(reader, 65536)
  ignore(@process.wait_pid(pid) catch { _ => -1 })
  output
}

///|
pub async fn run(cmd : @workspace.Command) -> Int {
  let native = @workspace.run_native_choir_file_command(cmd)
  if native >= 0 {
    return native
  }
  let native_rel = @workspace.run_native_workspace_rel_file_command(cmd)
  if native_rel >= 0 {
    return native_rel
  }
  let native_pi_dirs = @workspace.run_native_pi_runtime_dirs_command(cmd)
  if native_pi_dirs >= 0 {
    return native_pi_dirs
  }
  let native_pi_auth = @workspace.run_native_pi_seed_auth_command(cmd)
  if native_pi_auth >= 0 {
    return native_pi_auth
  }
  let native_leaf_helpers = @workspace.run_native_leaf_helpers_command(cmd)
  if native_leaf_helpers >= 0 {
    return native_leaf_helpers
  }
  let native_wt_cleanup = @workspace.run_native_worktree_bootstrap_cleanup_command(
    cmd,
  )
  if native_wt_cleanup >= 0 {
    return native_wt_cleanup
  }
  let native_fetch = @workspace.run_native_git_fetch_origin_branch_best_effort_command(
    cmd,
  )
  if native_fetch >= 0 {
    return native_fetch
  }
  let prog = cmd.program
  let args = cmd.args[:]
  match cmd.workdir {
    Some(dir) => @process.run(prog, args, cwd=dir)
    None => @process.run(prog, args)
  }
}

///|
pub async fn run_sequence(cmds : Array[@workspace.Command]) -> Array[Int] {
  let results = []
  for cmd in cmds {
    let status = run(cmd)
    results.push(status)
    if status != 0 {
      return results
    }
  }
  results
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
test "plugin_command_requires_shell_interpreter detects compound commands" {
  assert_true(plugin_command_requires_shell_interpreter("a && b"))
  assert_false(plugin_command_requires_shell_interpreter("choir tool x"))
}

///|
test "first_token_is_env_assignment detects VAR=value prefix" {
  assert_true(first_token_is_env_assignment("FOO=bar"))
  assert_false(first_token_is_env_assignment("./bin=odd"))
}
