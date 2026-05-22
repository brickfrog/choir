///|
#borrow(path)
extern "C" fn exec_path_executable_ffi(path : Bytes, len : Int) -> Int = "choir_exec_path_executable"

///|
#borrow(path)
extern "C" fn exec_replace_self_ffi(
  path : Bytes,
  len : Int,
  inherited_uds_fd : Int,
) -> Int = "choir_exec_replace_self"

///|
fn exec_string_to_null_terminated_bytes(s : String) -> (Bytes, Int) {
  let encoded = @utf8.encode(s)
  let len = encoded.length()
  let result = FixedArray::make(len + 1, (0 : Byte))
  for i = 0; i < len; i = i + 1 {
    result[i] = encoded[i]
  }
  result[len] = (0 : Byte)
  (result.unsafe_reinterpret_as_bytes(), len)
}

///|
pub fn default_reload_binary_path(project_dir : String) -> String {
  project_dir + "/_build/native/release/build/src/bin/choir/choir.exe"
}

///|
pub fn reload_binary_path(project_dir : String) -> String {
  match @sys.getenv("CHOIR_BINARY_PATH") {
    Some(path) =>
      if path.trim() == "" {
        default_reload_binary_path(project_dir)
      } else {
        path
      }
    None => default_reload_binary_path(project_dir)
  }
}

///|
pub fn hook_xdg_config_home() -> String? {
  @sys.getenv("XDG_CONFIG_HOME")
}

///|
pub fn hook_home() -> String {
  match @sys.getenv("HOME") {
    Some(value) => value
    None => ""
  }
}

///|
pub fn path_entry_exists(path : String) -> Bool {
  @sys.path_entry_exists(path)
}

///|
pub fn read_file(path : String) -> String {
  @sys.read_file(path)
}

///|
fn replace_self_error(binary_path : String, code : Int) -> @types.ChoirError {
  let errno = if code < 0 { 0 - code } else { code }
  @types.ChoirError::workspace_error(
    "replace_self failed for " +
    binary_path +
    " (errno=" +
    errno.to_string() +
    ")",
  )
}

///|
pub fn validate_replace_self_binary(
  binary_path : String,
) -> Result[Unit, @types.ChoirError] {
  let (path_bytes, len) = exec_string_to_null_terminated_bytes(binary_path)
  let code = exec_path_executable_ffi(path_bytes, len)
  if code == 0 {
    Ok(())
  } else {
    Err(replace_self_error(binary_path, code))
  }
}

///|
pub fn replace_self(
  binary_path : String,
  inherited_uds_fd : Int,
) -> Result[Unit, @types.ChoirError] {
  abort_if_hermetic_test_exec(
    command_for_program(binary_path, [inherited_uds_fd.to_string()], None),
  )
  match validate_replace_self_binary(binary_path) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  let (path_bytes, len) = exec_string_to_null_terminated_bytes(binary_path)
  let code = exec_replace_self_ffi(path_bytes, len, inherited_uds_fd)
  if code == 0 {
    Ok(())
  } else {
    Err(replace_self_error(binary_path, code))
  }
}

///|
/// Run the `entr` fallback for `choir dev` without `/bin/sh -c`: two native `find` invocations
/// (same argv as the former `(find …; find …) | entr …` pipeline), stdout streamed to `entr` stdin
/// (unbounded, matching the shell pipe); `entr` inherits the caller's stdout/stderr.
pub async fn run_dev_entr_watcher(
  entr_path : String,
  choir_exe : String,
) -> Int {
  abort_if_hermetic_test_exec(
    command_to_shell_string(dev_entr_entr_command(entr_path, choir_exe)),
  )
  let c1 = dev_entr_find_src_mbt_command()
  let c2 = dev_entr_find_toml_command()
  let (stdin_read, stdin_write) = @process.write_to_process() catch {
    _ => return -1
  }
  let entr = dev_entr_entr_command(entr_path, choir_exe)
  let pid = @process.spawn_orphan(entr.program, entr.args[:], stdin=stdin_read) catch {
    _ => {
      stdin_write.close()
      return -1
    }
  }
  run_find_and_pump_to(c1.program, c1.args, c1.workdir, stdin_write)
  run_find_and_pump_to(c2.program, c2.args, c2.workdir, stdin_write)
  stdin_write.close()
  @process.wait_pid(pid) catch {
    _ => -1
  }
}

///|
priv enum AgySharedCacheSeedStep {
  Prepare
  ColdBootstrap
  ReValidate
}

///|
fn AgySharedCacheSeedStep::label(self : AgySharedCacheSeedStep) -> String {
  match self {
    Prepare => "prepare"
    ColdBootstrap => "cold-bootstrap"
    ReValidate => "re-validate"
  }
}

///|
fn write_agy_shared_cache_seed_warning(
  step : AgySharedCacheSeedStep,
  status : Int,
  detail : String,
) -> Unit {
  let trimmed = detail.trim().to_owned()
  let suffix = if trimmed == "" { "" } else { ": " + trimmed }
  @sys.write_stderr(
    "choir: warning: agy shared cache seed " +
    step.label() +
    " failed (exit " +
    status.to_string() +
    ")" +
    suffix +
    "\n",
  )
}

///|
fn handled_native_failure_status(status : Int) -> Int {
  if status < 0 {
    1
  } else {
    status
  }
}

///|
async fn run_agy_shared_cache_seed_if_needed_command(
  cmd : @workspace.Command,
) -> Int {
  if cmd.program != @workspace.native_agy_shared_cache_seed_if_needed_program {
    return -1
  }
  if cmd.args.length() != 1 {
    return 1
  }
  let project_dir = cmd.args[0]
  if project_dir == "" {
    return 1
  }
  if @workspace.run_native_agy_shared_cache_validate_command(
      @workspace.agy_shared_cache_validate(project_dir),
    ) ==
    0 {
    return 0
  }
  let prepare_status = @workspace.run_native_agy_shared_cache_prepare_command(
    @workspace.agy_shared_cache_prepare(project_dir),
  )
  if prepare_status != 0 {
    write_agy_shared_cache_seed_warning(
      Prepare,
      prepare_status,
      "could not prepare seed HOME and shared cache links",
    )
    return prepare_status
  }
  let bootstrap = @workspace.agy_shared_cache_cold_bootstrap(project_dir)
  let (bootstrap_status, bootstrap_output) = capture_agy_shared_cache_cold_bootstrap(
    bootstrap,
  )
  if bootstrap_status != 0 {
    let handled_status = handled_native_failure_status(bootstrap_status)
    write_agy_shared_cache_seed_warning(
      ColdBootstrap,
      handled_status,
      bootstrap_output,
    )
    return handled_status
  }
  let validate_status = @workspace.run_native_agy_shared_cache_validate_command(
    @workspace.agy_shared_cache_validate(project_dir),
  )
  if validate_status != 0 {
    write_agy_shared_cache_seed_warning(
      ReValidate,
      validate_status,
      "shared cache did not validate after cold-bootstrap",
    )
    return validate_status
  }
  0
}

///|
/// Default capture cap for `drain_process_stdout`. One megabyte accommodates
/// JSON responses like `gh pr list` for large repos (previously 64 KiB, which
/// truncated mid-array and fed malformed JSON into downstream parsers).
pub let capture_max_bytes : Int = 1048576

///|
/// Read up to `max_bytes` from a pipe wired to process stdout (or stderr), close the reader,
/// and return the captured output as lossy UTF-8 plus the number of bytes read.
///
/// On silent failure modes — read error mid-stream, or output exceeding
/// `max_bytes` — emit a diagnostic to stderr so downstream parse failures
/// on truncated input are explainable. The return signature is preserved
/// for existing callers; upgrading them to receive a truncation flag is
/// deferred.
async fn drain_process_stdout(
  reader : @process.ReadFromProcess,
  max_bytes : Int,
) -> (String, Int) {
  let buf = FixedArray::make(max_bytes, (0 : Byte))
  let mut total = 0
  let mut read_error = false
  for ;; {
    if total >= buf.length() {
      break
    }
    let n = reader.read(buf, offset=total, max_len=buf.length() - total) catch {
      _ => {
        read_error = true
        0
      }
    }
    if n == 0 {
      break
    }
    total = total + n
  }
  // If the buffer filled, probe one more byte to distinguish "capture == EOF"
  // from "capture == cap exceeded". A positive read here means the child had
  // more to say than the cap allowed.
  let mut truncated = false
  if total >= buf.length() {
    let probe = FixedArray::make(1, (0 : Byte))
    let extra = reader.read(probe, offset=0, max_len=1) catch { _ => 0 }
    if extra > 0 {
      truncated = true
    }
  }
  reader.close()
  if truncated {
    @sys.write_stderr(
      "capture truncated at " +
      total.to_string() +
      " bytes (cap " +
      max_bytes.to_string() +
      "); downstream parse may fail\n",
    )
  }
  if read_error {
    @sys.write_stderr(
      "capture read error after " + total.to_string() + " bytes\n",
    )
  }
  (
    strip_terminal_responses(
      @utf8.decode_lossy(buf.unsafe_reinterpret_as_bytes()[:total]),
    ),
    total,
  )
}

///|
priv enum HookCaptureFailureKind {
  PipeCreateFailed
  SpawnPermanentEnoent
  SpawnPermanentEacces
  SpawnPermanentEperm
  SpawnTransientNonblocking
  SpawnTransientEmfile
  SpawnUnknownOS
  SpawnUnclassified
} derive(Debug, Eq)

///|
priv enum HookCaptureAttemptResult {
  Done(Int, String)
  Failed(HookCaptureFailureKind)
}

///|
let hook_capture_spawn_retry_delay_ms : Int = 25

///|
let hook_capture_spawn_max_attempts : Int = 3

///|
fn HookCaptureFailureKind::to_wire_string(
  self : HookCaptureFailureKind,
) -> String {
  match self {
    PipeCreateFailed => "pipe_create_failed"
    SpawnPermanentEnoent => "spawn_permanent_enoent"
    SpawnPermanentEacces => "spawn_permanent_eacces"
    SpawnPermanentEperm => "spawn_permanent_eperm"
    SpawnTransientNonblocking => "spawn_transient_nonblocking"
    SpawnTransientEmfile => "spawn_transient_emfile"
    SpawnUnknownOS => "spawn_unknown_os"
    SpawnUnclassified => "spawn_unclassified"
  }
}

///|
fn HookCaptureFailureKind::is_retryable(self : HookCaptureFailureKind) -> Bool {
  match self {
    PipeCreateFailed
    | SpawnTransientNonblocking
    | SpawnTransientEmfile
    | SpawnUnknownOS
    | SpawnUnclassified => true
    SpawnPermanentEnoent | SpawnPermanentEacces | SpawnPermanentEperm => false
  }
}

///|
fn HookCaptureFailureKind::retry_attempt_limit(
  self : HookCaptureFailureKind,
) -> Int {
  match self {
    PipeCreateFailed | SpawnTransientNonblocking | SpawnTransientEmfile =>
      hook_capture_spawn_max_attempts
    SpawnUnknownOS | SpawnUnclassified => 2
    SpawnPermanentEnoent | SpawnPermanentEacces | SpawnPermanentEperm => 1
  }
}

///|
/// POSIX EPERM ("Operation not permitted") — errno 1 on Linux/macOS/BSD.
/// `@os_error` does not expose a typed predicate for EPERM, so the value
/// is referenced by name here rather than scattered as a magic number.
const POSIX_EPERM : Int = 1

///|
/// POSIX EMFILE ("Too many open files") — errno 24 on Linux/macOS/BSD.
/// `@os_error.is_nonblocking_io_error` covers EAGAIN/EWOULDBLOCK but not
/// EMFILE, so we classify it explicitly as a transient retry candidate.
const POSIX_EMFILE : Int = 24

///|
#cfg(not(platform="windows"))
fn hook_capture_errno_is_eperm(errno : Int) -> Bool {
  errno == POSIX_EPERM
}

///|
#cfg(platform="windows")
fn hook_capture_errno_is_eperm(_errno : Int) -> Bool {
  false
}

///|
#cfg(not(platform="windows"))
fn hook_capture_errno_is_emfile(errno : Int) -> Bool {
  errno == POSIX_EMFILE
}

///|
#cfg(platform="windows")
fn hook_capture_errno_is_emfile(_errno : Int) -> Bool {
  false
}

///|
fn hook_capture_spawn_failure_kind(
  err : @os_error.OSError,
) -> HookCaptureFailureKind {
  let @os_error.OSError(errno, ..) = err
  if err.is_ENOENT() {
    SpawnPermanentEnoent
  } else if err.is_EACCES() {
    SpawnPermanentEacces
  } else if hook_capture_errno_is_eperm(errno) {
    SpawnPermanentEperm
  } else if err.is_nonblocking_io_error() {
    SpawnTransientNonblocking
  } else if hook_capture_errno_is_emfile(errno) {
    SpawnTransientEmfile
  } else {
    SpawnUnknownOS
  }
}

///|
fn hook_capture_log_retry_exhausted(
  hook_path : String,
  attempts : Int,
  final_error : HookCaptureFailureKind,
) -> Unit {
  @moontrace.warn("hook capture retry exhausted", fields=[
    @moontrace.field("event", "hook_capture_retry_exhausted"),
    @moontrace.field("hook_path", hook_path),
    @moontrace.field("attempts", attempts),
    @moontrace.field("final_error", final_error.to_wire_string()),
  ])
}

///|
/// Stream one `find` stdout into `out` until EOF (no total size cap), then wait for the child.
async fn run_find_and_pump_to(
  program : String,
  args : Array[String],
  cwd : String?,
  out : @process.WriteToProcess,
) -> Unit {
  let (reader, writer) = @process.read_from_process() catch { _ => return }
  let pid = match cwd {
    Some(dir) =>
      @process.spawn_orphan(program, args[:], stdout=writer, cwd=dir) catch {
        _ => {
          reader.close()
          return
        }
      }
    None =>
      @process.spawn_orphan(program, args[:], stdout=writer) catch {
        _ => {
          reader.close()
          return
        }
      }
  }
  let buf = FixedArray::make(8192, (0 : Byte))
  for ;; {
    let n = reader.read(buf, offset=0, max_len=buf.length()) catch {
      _ => break
    }
    if n == 0 {
      break
    }
    let chunk = @utf8.decode_lossy(buf.unsafe_reinterpret_as_bytes()[:n])
    ignore(out.write(chunk) catch { _ => () })
  }
  reader.close()
  ignore(@process.wait_pid(pid) catch { _ => -1 })
}

///|
fn agy_cold_bootstrap_latest_cli_log(home : String) -> String? {
  let log_dir = home + "/.gemini/antigravity-cli/log"
  let mut latest = ""
  for entry in @sys.list_dir(log_dir) {
    if entry.has_prefix("cli-") &&
      entry.has_suffix(".log") &&
      (latest == "" || entry.compare(latest) > 0) {
      latest = entry
    }
  }
  if latest == "" {
    None
  } else {
    Some(log_dir + "/" + latest)
  }
}

///|
fn agy_cold_bootstrap_log_excerpt(path : String) -> String {
  let trimmed = @sys.read_file(path).trim().to_owned()
  if trimmed.length() > 4000 {
    "[truncated]\n" + trimmed[trimmed.length() - 4000:].to_owned()
  } else {
    trimmed
  }
}

///|
fn agy_cold_bootstrap_failure_detail(
  cmd : @workspace.Command,
  output : String,
) -> String {
  let exec = match @workspace.agy_shared_cache_cold_bootstrap_exec(cmd) {
    Some(exec) => exec
    None => return output
  }
  let trimmed = output.trim().to_owned()
  if trimmed != "" {
    return trimmed
  }
  let log_path = match agy_cold_bootstrap_latest_cli_log(exec.home) {
    Some(path) => path
    None => return output
  }
  let log_excerpt = agy_cold_bootstrap_log_excerpt(log_path)
  if log_excerpt == "" {
    return output
  }
  "agy cli log (" + log_path + "): " + log_excerpt
}

///|
/// Spawn `cmd` with argv (`program` + `args`) and optional `workdir`, redirecting stderr to the
/// same pipe as stdout (shell `2>&1` semantics). Capture up to `capture_max_bytes` merged output, wait for exit.
/// Returns `(exit_code, output)`; negative `exit_code` means spawn/pipe/wait failure.
async fn capture_command_merged_raw(cmd : @workspace.Command) -> (Int, String) {
  abort_if_hermetic_test_exec(command_to_shell_string(cmd))
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
  let (output, _) = drain_process_stdout(reader, capture_max_bytes)
  let exit_code = @process.wait_pid(pid) catch { _ => -1 }
  (exit_code, output)
}

///|
pub async fn capture_command_merged(cmd : @workspace.Command) -> (Int, String) {
  capture_command_merged_raw(cmd)
}

///|
async fn capture_agy_shared_cache_cold_bootstrap(
  cmd : @workspace.Command,
) -> (Int, String) {
  let (status, output) = capture_command_merged_raw(cmd)
  if status != 0 {
    (status, agy_cold_bootstrap_failure_detail(cmd, output))
  } else {
    (status, output)
  }
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
  abort_if_hermetic_test_exec(command_for_program(hook_path, [], cwd))
  capture_hook_script_merged_with_retry(
    hook_path, stdin_body, cwd, capture_hook_script_merged_once, @async.sleep,
  )
}

///|
async fn capture_hook_script_merged_with_retry(
  hook_path : String,
  stdin_body : String,
  cwd : String?,
  attempt : async (String, String, String?) -> HookCaptureAttemptResult,
  sleep_fn : async (Int) -> Unit,
) -> (Int, String) {
  let mut attempts = 0
  for ;; {
    attempts = attempts + 1
    match attempt(hook_path, stdin_body, cwd) {
      Done(code, output) => return (code, strip_terminal_responses(output))
      Failed(kind) =>
        if !kind.is_retryable() {
          return (-1, "")
        } else if attempts >= kind.retry_attempt_limit() {
          hook_capture_log_retry_exhausted(hook_path, attempts, kind)
          return (-1, "")
        } else {
          sleep_fn(hook_capture_spawn_retry_delay_ms)
        }
    }
  }
}

///|
fn hook_capture_make_stdin_pipe() -> Result[
  (&@process.ProcessInput, @process.WriteToProcess),
  HookCaptureFailureKind,
] {
  let pipe = @process.write_to_process() catch {
    _ => return Err(PipeCreateFailed)
  }
  Ok(pipe)
}

///|
fn hook_capture_make_stdout_pipe() -> Result[
  (@process.ReadFromProcess, &@process.ProcessOutput),
  HookCaptureFailureKind,
] {
  let pipe = @process.read_from_process() catch {
    _ => return Err(PipeCreateFailed)
  }
  Ok(pipe)
}

///|
async fn hook_capture_spawn_hook_process(
  hook_path : String,
  argv : Array[String],
  stdin_read : &@process.ProcessInput,
  stdout_write : &@process.ProcessOutput,
  cwd : String?,
) -> Result[Int, HookCaptureFailureKind] {
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
        @os_error.OSError(_) as err =>
          return Err(hook_capture_spawn_failure_kind(err))
        _ => return Err(SpawnUnclassified)
      }
    None =>
      @process.spawn_orphan(
        hook_path,
        argv,
        stdin=stdin_read,
        stdout=stdout_write,
        stderr=stdout_write,
      ) catch {
        @os_error.OSError(_) as err =>
          return Err(hook_capture_spawn_failure_kind(err))
        _ => return Err(SpawnUnclassified)
      }
  }
  Ok(pid)
}

///|
async fn capture_hook_script_merged_once_with_adapters(
  hook_path : String,
  stdin_body : String,
  cwd : String?,
  make_stdin_pipe : () -> Result[
    (&@process.ProcessInput, @process.WriteToProcess),
    HookCaptureFailureKind,
  ],
  make_stdout_pipe : () -> Result[
    (@process.ReadFromProcess, &@process.ProcessOutput),
    HookCaptureFailureKind,
  ],
  spawn_hook : async (
    String,
    Array[String],
    &@process.ProcessInput,
    &@process.ProcessOutput,
    String?,
  ) -> Result[Int, HookCaptureFailureKind],
) -> HookCaptureAttemptResult {
  let (stdin_read, stdin_write) = match make_stdin_pipe() {
    Ok(pipe) => pipe
    Err(kind) => return Failed(kind)
  }
  let (stdout_read, stdout_write) = match make_stdout_pipe() {
    Ok(pipe) => pipe
    Err(kind) => {
      stdin_write.close()
      return Failed(kind)
    }
  }
  let argv : Array[String] = []
  let pid = match spawn_hook(hook_path, argv, stdin_read, stdout_write, cwd) {
    Ok(pid) => pid
    Err(kind) => {
      stdin_write.close()
      stdout_read.close()
      return Failed(kind)
    }
  }
  ignore(stdin_write.write(stdin_body) catch { _ => () })
  stdin_write.close()
  let (output, _) = drain_process_stdout(stdout_read, capture_max_bytes)
  let exit_code = @process.wait_pid(pid) catch { _ => -1 }
  Done(exit_code, output)
}

///|
async fn capture_hook_script_merged_once(
  hook_path : String,
  stdin_body : String,
  cwd : String?,
) -> HookCaptureAttemptResult {
  abort_if_hermetic_test_exec(command_for_program(hook_path, [], cwd))
  capture_hook_script_merged_once_with_adapters(
    hook_path, stdin_body, cwd, hook_capture_make_stdin_pipe, hook_capture_make_stdout_pipe,
    hook_capture_spawn_hook_process,
  )
}

///|
fn hook_capture_field_value(
  fields : Array[@moontrace.Field],
  key : String,
) -> Json? {
  for field in fields {
    if field.key == key {
      return Some(field.value)
    }
  }
  None
}

///|
fn hook_capture_retry_exhausted_warn_event(
  events : Array[@moontrace.Event],
) -> @moontrace.Event? {
  for event in events {
    if event.level == @moontrace.Level::Warn {
      match hook_capture_field_value(event.fields, "event") {
        Some(Json::String("hook_capture_retry_exhausted")) => return Some(event)
        _ => ()
      }
    }
  }
  None
}

///|
fn assert_hook_capture_string_field(
  fields : Array[@moontrace.Field],
  key : String,
  expected : String,
) -> Unit raise {
  match hook_capture_field_value(fields, key) {
    Some(Json::String(value)) => assert_eq(value, expected)
    _ => fail("expected string moontrace field " + key)
  }
}

///|
fn assert_hook_capture_number_field(
  fields : Array[@moontrace.Field],
  key : String,
  expected : Double,
) -> Unit raise {
  match hook_capture_field_value(fields, key) {
    Some(Json::Number(value, ..)) => assert_eq(value, expected)
    _ => fail("expected number moontrace field " + key)
  }
}

///|
async test "capture_hook_script_merged_once exhausts after N attempts and logs warn" {
  let mut attempts = 0
  let mut sleeps = 0
  let captured : Array[@moontrace.Event] = []
  let attempt = async fn(
    _hook_path : String,
    _stdin_body : String,
    _cwd : String?,
  ) -> HookCaptureAttemptResult {
    @async.sleep(0)
    attempts = attempts + 1
    Failed(SpawnTransientEmfile)
  }
  let sleep_fn = async fn(ms : Int) -> Unit {
    assert_eq(ms, hook_capture_spawn_retry_delay_ms)
    sleeps = sleeps + 1
    @async.sleep(0)
  }

  @moontrace.set_subscriber(fn(event) { captured.push(event) })
  let (code, output) = capture_hook_script_merged_with_retry(
    "/tmp/hook.sh",
    "{}",
    None,
    attempt,
    sleep_fn,
  )
  @moontrace.clear_subscriber()

  assert_eq(code, -1)
  assert_eq(output, "")
  assert_eq(attempts, hook_capture_spawn_max_attempts)
  assert_eq(sleeps, hook_capture_spawn_max_attempts - 1)
  let warn_event = match hook_capture_retry_exhausted_warn_event(captured) {
    Some(event) => event
    None => fail("expected hook capture retry exhaustion warning")
  }
  assert_hook_capture_string_field(
    warn_event.fields,
    "event",
    "hook_capture_retry_exhausted",
  )
  assert_hook_capture_string_field(
    warn_event.fields,
    "hook_path",
    "/tmp/hook.sh",
  )
  assert_hook_capture_number_field(
    warn_event.fields,
    "attempts",
    hook_capture_spawn_max_attempts.to_double(),
  )
  assert_hook_capture_string_field(
    warn_event.fields,
    "final_error",
    "spawn_transient_emfile",
  )
}

///|
async test "capture_hook_script_merged strips terminal responses from captured output" {
  let attempt = async fn(
    _hook_path : String,
    _stdin_body : String,
    _cwd : String?,
  ) -> HookCaptureAttemptResult {
    @async.sleep(0)
    Done(
      0, "before \u{1b}[32mok\u{1b}[0m \u{1b}]11;rgb:0a0a/0f0f/1414\u{1b}\\\u{1b}[?62;4;52c\u{1b}[61;1R after",
    )
  }
  let sleep_fn = async fn(_ms : Int) -> Unit { @async.sleep(0) }

  let (code, output) = capture_hook_script_merged_with_retry(
    "/tmp/hook.sh",
    "{}",
    None,
    attempt,
    sleep_fn,
  )

  assert_eq(code, 0)
  assert_eq(output, "before \u{1b}[32mok\u{1b}[0m  after")
}

///|
test "agy cold-bootstrap failure detail uses stderr before cli logs" {
  let cmd = @workspace.Command::{
    program: "env",
    args: [
      "HOME=/tmp/choir-agy-detail-home", "agy", "--dangerously-skip-permissions",
      "--print", "Reply READY.",
    ],
    workdir: Some("/tmp/choir-agy-detail-project"),
  }

  assert_eq(
    agy_cold_bootstrap_failure_detail(cmd, "actual agy stderr\n"),
    "actual agy stderr",
  )
}

///|
test "agy cold-bootstrap failure detail leaves non-bootstrap output unchanged" {
  let cmd = @workspace.Command::{
    program: "env",
    args: [
      "HOME=/tmp/choir-agy-detail-home", "not-agy", "--dangerously-skip-permissions",
      "--print", "Reply READY.",
    ],
    workdir: Some("/tmp/choir-agy-detail-project"),
  }

  assert_eq(
    agy_cold_bootstrap_failure_detail(cmd, " ordinary output \n"),
    " ordinary output \n",
  )
}

///|
test "agy cold-bootstrap failure detail falls back to cli log" {
  let dir = "/tmp/choir-agy-capture-detail-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  let project = dir + "/project"
  ignore(@sys.rm_rf(dir))
  assert_true(@sys.create_dir_all(project))
  let cmd = @workspace.agy_shared_cache_cold_bootstrap(project)
  let home = cmd.args[0].replace(old="HOME=", new="")
  let log_dir = home + "/.gemini/antigravity-cli/log"
  assert_true(@sys.create_dir_all(log_dir))
  assert_true(
    @sys.write_file_sync(
      log_dir + "/cli-20260521_232348.log",
      "actual agy cli log\n",
    ),
  )

  let output = agy_cold_bootstrap_failure_detail(cmd, "")
  assert_true(output.contains("agy cli log (" + log_dir))
  assert_true(output.contains("actual agy cli log"))
  ignore(@sys.rm_rf(dir))
}

///|
async test "capture_hook_script_merged_once does NOT retry on permanent ENOENT" {
  if !real_exec_integration_enabled() {
    return
  }
  let missing = "/tmp/choir-missing-hook-" +
    @sys.get_pid().to_string() +
    "-enoent"
  ignore(@sys.rm_rf(missing))
  let mut attempts = 0
  let mut sleeps = 0
  let mut final_kind = SpawnUnclassified
  let attempt = async fn(
    hook_path : String,
    stdin_body : String,
    cwd : String?,
  ) -> HookCaptureAttemptResult {
    attempts = attempts + 1
    let result = capture_hook_script_merged_once(hook_path, stdin_body, cwd)
    match result {
      Failed(kind) => final_kind = kind
      _ => ()
    }
    result
  }
  let sleep_fn = async fn(_ms : Int) -> Unit {
    sleeps = sleeps + 1
    @async.sleep(0)
  }

  let (code, output) = capture_hook_script_merged_with_retry(
    missing,
    "{}",
    None,
    attempt,
    sleep_fn,
  )

  assert_eq(code, -1)
  assert_eq(output, "")
  assert_eq(attempts, 1)
  assert_eq(sleeps, 0)
  @debug.assert_eq(final_kind, SpawnPermanentEnoent)
}

///|
#cfg(not(platform="windows"))
async test "capture_hook_script_merged_once does NOT retry on permanent EACCES" {
  let mut attempts = 0
  let mut sleeps = 0
  let mut final_kind = SpawnUnclassified
  let fail_spawn_hook = async fn(
    _hook_path : String,
    _argv : Array[String],
    _stdin : &@process.ProcessInput,
    _stdout : &@process.ProcessOutput,
    _cwd : String?,
  ) -> Result[Int, HookCaptureFailureKind] {
    @async.sleep(0)
    Err(SpawnPermanentEacces)
  }
  let attempt = async fn(
    hook_path : String,
    stdin_body : String,
    cwd : String?,
  ) -> HookCaptureAttemptResult {
    attempts = attempts + 1
    let result = capture_hook_script_merged_once_with_adapters(
      hook_path, stdin_body, cwd, hook_capture_make_stdin_pipe, hook_capture_make_stdout_pipe,
      fail_spawn_hook,
    )
    match result {
      Failed(kind) => final_kind = kind
      _ => ()
    }
    result
  }
  let sleep_fn = async fn(_ms : Int) -> Unit {
    sleeps = sleeps + 1
    @async.sleep(0)
  }

  let (code, output) = capture_hook_script_merged_with_retry(
    "eacces-hook.sh",
    "{}",
    None,
    attempt,
    sleep_fn,
  )

  assert_eq(code, -1)
  assert_eq(output, "")
  assert_eq(attempts, 1)
  assert_eq(sleeps, 0)
  @debug.assert_eq(final_kind, SpawnPermanentEacces)
}

///|
#cfg(not(platform="windows"))
async test "capture_hook_script_merged_once maps real EACCES to permanent failure" {
  if !real_exec_integration_enabled() {
    return
  }
  let dir = "/tmp/choir-eacces-classify-" + @sys.get_pid().to_string()
  ignore(@sys.rm_rf(dir))
  assert_true(@sys.create_dir_all(dir))
  let script = dir + "/hook.sh"
  assert_true(@sys.write_file_sync(script, "#!/bin/sh\necho no\n"))

  let result = capture_hook_script_merged_once(script, "{}", Some(dir))

  match result {
    Failed(kind) => @debug.assert_eq(kind, SpawnPermanentEacces)
    _ => fail("expected non-executable hook to fail with permanent EACCES")
  }
  ignore(@sys.rm_rf(dir))
}

///|
async test "capture_hook_script_merged_once retries on pipe-creation failure" {
  let mut attempts = 0
  let mut sleeps = 0
  let fail_stdin_pipe = fn() -> Result[
    (&@process.ProcessInput, @process.WriteToProcess),
    HookCaptureFailureKind,
  ] {
    Err(PipeCreateFailed)
  }
  let fail_stdout_pipe = fn() -> Result[
    (@process.ReadFromProcess, &@process.ProcessOutput),
    HookCaptureFailureKind,
  ] {
    Err(PipeCreateFailed)
  }
  let attempt = async fn(
    hook_path : String,
    stdin_body : String,
    cwd : String?,
  ) -> HookCaptureAttemptResult {
    attempts = attempts + 1
    match attempts {
      1 =>
        capture_hook_script_merged_once_with_adapters(
          hook_path, stdin_body, cwd, fail_stdin_pipe, hook_capture_make_stdout_pipe,
          hook_capture_spawn_hook_process,
        )
      2 =>
        capture_hook_script_merged_once_with_adapters(
          hook_path, stdin_body, cwd, hook_capture_make_stdin_pipe, fail_stdout_pipe,
          hook_capture_spawn_hook_process,
        )
      _ => Done(0, "ok")
    }
  }
  let sleep_fn = async fn(ms : Int) -> Unit {
    assert_eq(ms, hook_capture_spawn_retry_delay_ms)
    sleeps = sleeps + 1
    @async.sleep(0)
  }

  let (code, output) = capture_hook_script_merged_with_retry(
    "/tmp/hook.sh",
    "{}",
    None,
    attempt,
    sleep_fn,
  )

  assert_eq(code, 0)
  assert_eq(output, "ok")
  assert_eq(attempts, 3)
  assert_eq(sleeps, 2)
}

///|
/// Like [`capture_command_merged`], but only stdout is captured (stderr is not redirected to the
/// pipe). Matches shell `cmd >capture` without `2>&1` for JSON and other stdout-only protocols.
pub async fn capture_command_stdout(cmd : @workspace.Command) -> (Int, String) {
  abort_if_hermetic_test_exec(command_to_shell_string(cmd))
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
  let (output, _) = drain_process_stdout(reader, capture_max_bytes)
  let exit_code = @process.wait_pid(pid) catch { _ => -1 }
  (exit_code, output)
}

///|
/// Capture stdout for successful JSON protocols, but include stderr in the returned
/// text when the command fails so error responses keep useful diagnostics.
pub async fn capture_command_stdout_with_stderr_on_error(
  cmd : @workspace.Command,
) -> (Int, String) {
  abort_if_hermetic_test_exec(command_to_shell_string(cmd))
  let (stdout_reader, stdout_writer) = @process.read_from_process() catch {
    _ => return (-1, "")
  }
  let (stderr_reader, stderr_writer) = @process.read_from_process() catch {
    _ => {
      stdout_reader.close()
      return (-1, "")
    }
  }
  let prog = cmd.program
  let args = cmd.args[:]
  let pid = match cmd.workdir {
    Some(dir) =>
      @process.spawn_orphan(
        prog,
        args,
        stdout=stdout_writer,
        stderr=stderr_writer,
        cwd=dir,
      ) catch {
        _ => {
          stdout_reader.close()
          stderr_reader.close()
          return (-1, "")
        }
      }
    None =>
      @process.spawn_orphan(
        prog,
        args,
        stdout=stdout_writer,
        stderr=stderr_writer,
      ) catch {
        _ => {
          stdout_reader.close()
          stderr_reader.close()
          return (-1, "")
        }
      }
  }
  let (stdout, _) = drain_process_stdout(stdout_reader, capture_max_bytes)
  let (stderr, _) = drain_process_stdout(stderr_reader, capture_max_bytes)
  let exit_code = @process.wait_pid(pid) catch { _ => -1 }
  if exit_code == 0 {
    (exit_code, stdout)
  } else {
    (exit_code, stdout + "\n--- stderr ---\n" + stderr)
  }
}

///|
/// Run `plugin_command` under `timeout` (seconds), write `request_line` plus newline on stdin,
/// capture up to `capture_max_bytes` of stdout (stderr discarded). When the command is a simple argv list
/// (no shell-only syntax), runs `timeout <sec> <argv...>` directly; otherwise falls back to
/// `timeout <sec> sh -c <plugin_command>`. See [`plugin_capture_uses_shell`].
pub async fn capture_plugin_shell_command(
  plugin_command : String,
  request_line : String,
  timeout_sec : Int,
) -> (Int, String) {
  abort_if_hermetic_test_exec(plugin_command)
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
  let use_shell = plugin_capture_uses_shell(plugin_command)
  let timeout_args = if use_shell {
    return (-1, "")
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
      None => return (-1, "")
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
  let (output, _) = drain_process_stdout(stdout_read, capture_max_bytes)
  let exit_code = @process.wait_pid(pid) catch { _ => -1 }
  (exit_code, output)
}

///|
/// Spawn `program` with `args`, capture stdout (up to `capture_max_bytes`), wait for exit, return decoded output.
pub async fn capture_stdout(program : String, args : Array[String]) -> String {
  capture_stdout_with_cwd(program, args, None)
}

///|
/// Spawn `program` with `args` in `cwd`, capture stdout (up to `capture_max_bytes`), wait for exit, return decoded output.
pub async fn capture_stdout_with_cwd(
  program : String,
  args : Array[String],
  cwd : String?,
) -> String {
  abort_if_hermetic_test_exec(command_for_program(program, args, cwd))
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
  let (output, _) = drain_process_stdout(reader, capture_max_bytes)
  ignore(@process.wait_pid(pid) catch { _ => -1 })
  output
}

///|
pub async fn run(cmd : @workspace.Command) -> Int {
  abort_if_hermetic_test_exec(command_to_shell_string(cmd))
  let native = @workspace.run_native_choir_file_command(cmd)
  if native >= 0 {
    return native
  }
  let native_rel = @workspace.run_native_workspace_rel_file_command(cmd)
  if native_rel >= 0 {
    return native_rel
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
  let native_seed = @workspace.run_native_worktree_seed_agent_runtime_gitexclude_command(
    cmd,
  )
  if native_seed >= 0 {
    return native_seed
  }
  let native_agy_cache_links = @workspace.run_native_agy_cache_links_command(
    cmd,
  )
  if native_agy_cache_links >= 0 {
    return native_agy_cache_links
  }
  let native_agy_prepare = @workspace.run_native_agy_shared_cache_prepare_command(
    cmd,
  )
  if native_agy_prepare >= 0 {
    return native_agy_prepare
  }
  let native_agy_validate = @workspace.run_native_agy_shared_cache_validate_command(
    cmd,
  )
  if native_agy_validate >= 0 {
    return native_agy_validate
  }
  let native_agy_seed_if_needed = run_agy_shared_cache_seed_if_needed_command(
    cmd,
  )
  if native_agy_seed_if_needed >= 0 {
    return native_agy_seed_if_needed
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
  let command = if cmds.length() == 0 {
    "run_sequence []"
  } else {
    command_to_shell_string(cmds[0])
  }
  abort_if_hermetic_test_exec(command)
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
