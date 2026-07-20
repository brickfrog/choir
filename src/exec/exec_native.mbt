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
#borrow(path)
extern "C" fn state_store_init_ffi(path : Bytes, path_len : Int) -> Int = "choir_state_store_init"

///|
#borrow(path, record_key, value_digest, semantic_key, payload_digest)
extern "C" fn state_store_commit_ffi(
  path : Bytes,
  path_len : Int,
  record_key : Bytes,
  record_key_len : Int,
  has_expected_version : Int,
  expected_version : Int,
  next_version : Int,
  fencing_epoch : Int64,
  value_digest : Bytes,
  value_digest_len : Int,
  semantic_key : Bytes,
  semantic_key_len : Int,
  payload_digest : Bytes,
  payload_digest_len : Int,
  fault_point : Int,
) -> Int = "choir_state_store_commit"

///|
#borrow(path, record_key, output)
extern "C" fn state_store_read_state_ffi(
  path : Bytes,
  path_len : Int,
  record_key : Bytes,
  record_key_len : Int,
  output : Bytes,
  output_size : Int,
) -> Int = "choir_state_store_read_state"

///|
#borrow(path, semantic_key, output)
extern "C" fn state_store_read_outbox_ffi(
  path : Bytes,
  path_len : Int,
  semantic_key : Bytes,
  semantic_key_len : Int,
  output : Bytes,
  output_size : Int,
) -> Int = "choir_state_store_read_outbox"

///|
#borrow(root, digest, content)
extern "C" fn artifact_store_adopt_ffi(
  root : Bytes,
  root_len : Int,
  digest : Bytes,
  digest_len : Int,
  content : Bytes,
  content_len : Int,
) -> Int = "choir_artifact_store_adopt"

///|
#borrow(root, digest)
extern "C" fn artifact_store_contains_ffi(
  root : Bytes,
  root_len : Int,
  digest : Bytes,
  digest_len : Int,
) -> Int = "choir_artifact_store_contains"

///|
#borrow(root, digest)
extern "C" fn artifact_store_size_ffi(
  root : Bytes,
  root_len : Int,
  digest : Bytes,
  digest_len : Int,
) -> Int = "choir_artifact_store_size"

///|
#borrow(root, digest, output)
extern "C" fn artifact_store_read_ffi(
  root : Bytes,
  root_len : Int,
  digest : Bytes,
  digest_len : Int,
  output : Bytes,
  output_size : Int,
) -> Int = "choir_artifact_store_read"

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
fn reload_binary_path_resolution_error() -> @types.ChoirError {
  @types.ChoirError::workspace_error(
    "cannot resolve reload binary path from /proc/self/exe",
  )
}

///|
pub fn default_reload_binary_path(
  realpath? : (String) -> String? = @sys.realpath_native,
) -> Result[String, @types.ChoirError] {
  match realpath("/proc/self/exe") {
    Some(path) =>
      if path.trim() == "" {
        Err(reload_binary_path_resolution_error())
      } else {
        Ok(path)
      }
    None => Err(reload_binary_path_resolution_error())
  }
}

///|
pub fn reload_binary_path() -> Result[String, @types.ChoirError] {
  match @sys.getenv("CHOIR_BINARY_PATH") {
    Some(path) =>
      if path.trim() == "" {
        default_reload_binary_path()
      } else {
        Ok(path)
      }
    None => default_reload_binary_path()
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
fn harness_probe_program_and_args(
  spec : @harness.HarnessProbeProcess,
) -> (String, Array[String]) {
  match (spec.surface, spec.command) {
    (
      @harness.ProviderSurface::ClaudeCli,
      @harness.HarnessProbeCommand::ProbeVersion,
    ) => ("claude", ["--version"])
    (
      @harness.ProviderSurface::ClaudeCli,
      @harness.HarnessProbeCommand::ProbeMainHelp,
    ) => ("claude", ["--help"])
    (
      @harness.ProviderSurface::ClaudeCli,
      @harness.HarnessProbeCommand::ProbeExecHelp,
    ) => ("claude", ["--help"])
    (
      @harness.ProviderSurface::CodexCli,
      @harness.HarnessProbeCommand::ProbeVersion,
    ) => ("codex", ["--version"])
    (
      @harness.ProviderSurface::CodexCli,
      @harness.HarnessProbeCommand::ProbeMainHelp,
    ) => ("codex", ["--help"])
    (
      @harness.ProviderSurface::CodexCli,
      @harness.HarnessProbeCommand::ProbeExecHelp,
    ) => ("codex", ["exec", "--help"])
  }
}

///|
/// Execute the fixed, read-only provider declaration probes. No caller can
/// supply an executable, argv item, working directory, or environment entry.
pub async fn capture_harness_probe(
  spec : @harness.HarnessProbeProcess,
) -> Result[@harness.HarnessProbeCapture, @types.ChoirError] {
  let (program, args) = harness_probe_program_and_args(spec)
  abort_if_hermetic_test_exec(command_for_program(program, args, None))
  let (reader, writer) = @process.read_from_process() catch {
    _ =>
      return Err(
        @types.ChoirError::transport_error(
          "provider probe pipe creation failed",
        ),
      )
  }
  let probe_env : Map[String, String] = { "COLUMNS": "200", "NO_COLOR": "1" }
  let pid = @process.spawn_orphan(
    program,
    args[:],
    extra_env=probe_env,
    inherit_env=true,
    stdout=writer,
    stderr=writer,
  ) catch {
    _ => {
      reader.close()
      return Err(
        @types.ChoirError::transport_error(
          "provider probe executable unavailable: " + program,
        ),
      )
    }
  }
  let (output, _) = drain_process_stdout(reader, capture_max_bytes)
  let exit_code = @process.wait_pid(pid) catch {
    _ =>
      return Err(
        @types.ChoirError::transport_error("provider probe wait failed"),
      )
  }
  Ok({ exit_code, output })
}

///|
fn boxlite_probe_executable() -> Result[String, @types.ChoirError] {
  match @sys.getenv("CHOIR_BOXLITE_BINARY") {
    Some(path) =>
      if path.has_prefix("/") {
        Ok(path)
      } else {
        Err(
          @types.ChoirError::validation_error(
            "CHOIR_BOXLITE_BINARY must be an absolute operator-controlled conformance path",
          ),
        )
      }
    None =>
      match resolve_executable_in_path("boxlite") {
        Some(path) => Ok(path)
        None =>
          Err(
            @types.ChoirError::transport_error(
              "BoxLite probe executable unavailable: set CHOIR_BOXLITE_BINARY or install boxlite in PATH",
            ),
          )
      }
  }
}

///|
fn boxlite_probe_program_and_args(
  binary : String,
  root : String,
  operation : @sandbox.BoxLiteProbeOperation,
) -> (String, Array[String], Int) {
  let home = root + "/home"
  match operation {
    @sandbox.BoxLiteProbeOperation::BoxLiteHashExecutable =>
      ("/usr/bin/sha256sum", [binary], 10000)
    @sandbox.BoxLiteProbeOperation::BoxLiteVersion =>
      (binary, ["--version"], 10000)
    @sandbox.BoxLiteProbeOperation::BoxLiteInfo =>
      (binary, ["--home", home, "info"], 10000)
    @sandbox.BoxLiteProbeOperation::BoxLitePullPinnedImage =>
      (binary, ["--home", home, "pull", @sandbox.boxlite_probe_image], 120000)
    @sandbox.BoxLiteProbeOperation::BoxLiteSecureBoot =>
      (
        binary,
        [
          "--home", home, "run", "--rm", "--network", "disabled", "--security", "enable",
          "--cpus", "1", "--memory", "256", "--disk-size", "1", @sandbox.boxlite_probe_image,
          "/bin/echo", "CHOIR_BOXLITE_SECURE_OK",
        ],
        120000,
      )
    @sandbox.BoxLiteProbeOperation::BoxLiteInsecureBootDiagnostic =>
      (
        binary,
        [
          "--home", home, "run", "--rm", "--network", "disabled", "--security", "disable",
          "--cpus", "1", "--memory", "256", "--disk-size", "1", @sandbox.boxlite_probe_image,
          "/bin/echo", "CHOIR_BOXLITE_INSECURE_CONTROL_OK",
        ],
        120000,
      )
  }
}

///|
async fn capture_boxlite_probe_operation(
  binary : String,
  root : String,
  operation : @sandbox.BoxLiteProbeOperation,
) -> Result[@sandbox.BoxLiteProbeCapture, @types.ChoirError] {
  let (program, args, timeout_ms) = boxlite_probe_program_and_args(
    binary, root, operation,
  )
  abort_if_hermetic_test_exec(command_for_program(program, args, Some(root)))
  let probe_env = boxlite_probe_environment(root, None)
  let collected = @async.with_timeout_opt(timeout_ms, () => {
    @process.collect_output_merged(
      program,
      args,
      extra_env=probe_env,
      inherit_env=false,
      cwd=root,
    )
  }) catch {
    _ =>
      return Err(
        @types.ChoirError::transport_error(
          "BoxLite conformance process failed to start or collect output",
        ),
      )
  }
  match collected {
    None => Ok({ exit_code: -2, output: "" })
    Some((exit_code, data)) => {
      let output = data.text() catch {
        _ =>
          return Err(
            @types.ChoirError::transport_error(
              "BoxLite conformance output was not UTF-8",
            ),
          )
      }
      Ok({ exit_code, output })
    }
  }
}

///|
async fn capture_boxlite_fixed_process(
  program : String,
  args : Array[String],
  root : String,
  extra_env : Map[String, String],
  timeout_ms : Int,
) -> Result[@sandbox.BoxLiteProbeCapture, @types.ChoirError] {
  abort_if_hermetic_test_exec(command_for_program(program, args, Some(root)))
  let collected = @async.with_timeout_opt(timeout_ms, () => {
    @process.collect_output_merged(
      program,
      args,
      extra_env~,
      inherit_env=false,
      cwd=root,
    )
  }) catch {
    _ =>
      return Err(
        @types.ChoirError::transport_error(
          "BoxLite lifecycle process failed to start or collect output",
        ),
      )
  }
  match collected {
    None => Ok({ exit_code: -2, output: "" })
    Some((exit_code, data)) => {
      let output = data.text() catch {
        _ =>
          return Err(
            @types.ChoirError::transport_error(
              "BoxLite lifecycle output was not UTF-8",
            ),
          )
      }
      Ok({ exit_code, output })
    }
  }
}

///|
fn boxlite_probe_environment_with_runtime(
  root : String,
  api_key : String?,
  runtime_dir : String?,
) -> Map[String, String] {
  let environment : Map[String, String] = {
    "HOME": root,
    "TMPDIR": root + "/tmp",
    "PATH": "/usr/local/bin:/usr/bin:/bin",
    "NO_COLOR": "1",
  }
  match api_key {
    Some(value) => environment["BOXLITE_API_KEY"] = value
    None => ()
  }
  match runtime_dir {
    Some(value) => environment["BOXLITE_RUNTIME_DIR"] = value
    None => ()
  }
  environment
}

///|
fn boxlite_probe_environment(
  root : String,
  api_key : String?,
) -> Map[String, String] {
  boxlite_probe_environment_with_runtime(
    root,
    api_key,
    @sys.getenv("CHOIR_BOXLITE_RUNTIME_DIR"),
  )
}

///|
async fn capture_boxlite_network_case(
  binary : String,
  root : String,
  script : String,
  security_enabled : Bool,
) -> Result[@sandbox.BoxLiteProbeCapture, @types.ChoirError] {
  capture_boxlite_fixed_process(
    binary,
    [
      "--home",
      root + "/home",
      "run",
      "--rm",
      "--network",
      "disabled",
      "--security",
      if security_enabled {
        "enable"
      } else {
        "disable"
      },
      "--cpus",
      "1",
      "--memory",
      "256",
      "--disk-size",
      "1",
      @sandbox.boxlite_probe_image,
      "/bin/sh",
      "-c",
      script,
    ],
    root,
    boxlite_probe_environment(root, None),
    120000,
  )
}

///|
async fn capture_boxlite_network_evidence(
  binary : String,
  root : String,
  security_enabled : Bool,
) -> Result[@sandbox.BoxLiteDownstreamEvidence, @types.ChoirError] {
  let evidence = @sandbox.boxlite_downstream_not_run_evidence()
  let network_disabled = match
    capture_boxlite_network_case(
      binary, root, "if [ -e /sys/class/net/eth0 ]; then exit 41; else echo CHOIR_BOXLITE_NETWORK_DISABLED_OK; fi",
      security_enabled,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let network_dns = match
    capture_boxlite_network_case(
      binary, root, "if nslookup example.com >/dev/null 2>&1; then exit 42; else echo CHOIR_BOXLITE_DNS_DENIED; fi",
      security_enabled,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let network_tcp = match
    capture_boxlite_network_case(
      binary, root, "if nc -z -w 1 1.1.1.1 443 >/dev/null 2>&1; then exit 43; else echo CHOIR_BOXLITE_TCP_DENIED; fi",
      security_enabled,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let network_udp = match
    capture_boxlite_network_case(
      binary, root, "if nc -u -z -w 1 1.1.1.1 53 >/dev/null 2>&1; then exit 44; else echo CHOIR_BOXLITE_UDP_DENIED; fi",
      security_enabled,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let network_quic = match
    capture_boxlite_network_case(
      binary, root, "if nc -u -z -w 1 1.1.1.1 443 >/dev/null 2>&1; then exit 45; else echo CHOIR_BOXLITE_QUIC_DENIED; fi",
      security_enabled,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let network_host_aliases = match
    capture_boxlite_network_case(
      binary, root, "if nslookup host.docker.internal >/dev/null 2>&1 || nslookup host.containers.internal >/dev/null 2>&1 || nslookup host.boxlite.internal >/dev/null 2>&1; then exit 46; else echo CHOIR_BOXLITE_HOST_ALIASES_DENIED; fi",
      security_enabled,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let network_choir_socket = match
    capture_boxlite_network_case(
      binary, root, "if [ -e /run/choir.sock ] || [ -e /tmp/choir.sock ]; then exit 47; else echo CHOIR_BOXLITE_CHOIR_SOCKET_DENIED; fi",
      security_enabled,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let network_runtime_socket = match
    capture_boxlite_network_case(
      binary, root, "if [ -e /run/docker.sock ] || [ -e /run/containerd/containerd.sock ] || [ -e /var/run/docker.sock ]; then exit 48; else echo CHOIR_BOXLITE_RUNTIME_SOCKET_DENIED; fi",
      security_enabled,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    ..evidence,
    network_disabled,
    network_dns,
    network_tcp,
    network_udp,
    network_quic,
    network_host_aliases,
    network_choir_socket,
    network_runtime_socket,
  })
}

///|
priv struct BoxLiteProbeServer {
  pid : Int
  url : String
  api_key : String
}

///|
fn boxlite_json_string_field(body : String, key : String) -> String? {
  let parsed = @json.parse(body) catch { _ => return None }
  guard parsed is Object(fields) else { return None }
  match fields.get(key) {
    Some(String(value)) => Some(value)
    _ => None
  }
}

///|
fn boxlite_pass_capture(marker : String) -> @sandbox.BoxLiteProbeCapture {
  { exit_code: 0, output: marker + "\n" }
}

///|
fn boxlite_failed_capture(
  capture : @sandbox.BoxLiteProbeCapture,
  label : String,
) -> @sandbox.BoxLiteProbeCapture {
  {
    exit_code: if capture.exit_code == 0 {
      1
    } else {
      capture.exit_code
    },
    output: label + ": " + capture.output,
  }
}

///|
async fn capture_boxlite_curl(
  root : String,
  args : Array[String],
) -> Result[@sandbox.BoxLiteProbeCapture, @types.ChoirError] {
  capture_boxlite_fixed_process(
    "/usr/bin/curl",
    args,
    root,
    boxlite_probe_environment(root, None),
    30000,
  )
}

///|
async fn capture_boxlite_authorized_http(
  server : BoxLiteProbeServer,
  root : String,
  http_method : String,
  path : String,
  body : String?,
) -> Result[@sandbox.BoxLiteProbeCapture, @types.ChoirError] {
  let args : Array[String] = [
    "-fsS",
    "--max-time",
    "20",
    "-X",
    http_method,
    "-H",
    "Authorization: Bearer " + server.api_key,
  ]
  match body {
    Some(value) => {
      args.push("-H")
      args.push("Content-Type: application/json")
      args.push("--data-binary")
      args.push(value)
    }
    None => ()
  }
  args.push(server.url + path)
  capture_boxlite_curl(root, args)
}

///|
async fn start_boxlite_probe_server(
  binary : String,
  root : String,
) -> Result[BoxLiteProbeServer, @types.ChoirError] {
  let port = 21000 + @sys.get_pid() % 20000
  let url = "http://127.0.0.1:" + port.to_string()
  let api_key = "choir-boxlite-probe-" + @sys.get_pid().to_string()
  let home = root + "/server-home"
  if !@sys.create_dir_all(home) {
    return Err(
      @types.ChoirError::workspace_error(
        "cannot create dedicated BoxLite server home",
      ),
    )
  }
  let args = [
    "--home",
    home,
    "serve",
    "--host",
    "127.0.0.1",
    "--port",
    port.to_string(),
    "--api-key",
    api_key,
  ]
  abort_if_hermetic_test_exec(command_for_program(binary, args, Some(root)))
  let pid = @process.spawn_orphan(
    binary,
    args[:],
    extra_env=boxlite_probe_environment(root, None),
    inherit_env=false,
    cwd=root,
  ) catch {
    _ =>
      return Err(
        @types.ChoirError::transport_error(
          "BoxLite probe server failed to start",
        ),
      )
  }
  let server : BoxLiteProbeServer = { pid, url, api_key }
  for attempt = 0; attempt < 40; attempt = attempt + 1 {
    let ready = match
      capture_boxlite_curl(root, ["-fsS", "--max-time", "1", url + "/v1/config"]) {
      Ok(value) => value
      Err(error) => {
        @sys.kill_server_pid_sequence_best_effort(pid)
        return Err(error)
      }
    }
    if ready.exit_code == 0 &&
      ready.output.contains("\"clone_enabled\":true") &&
      ready.output.contains("\"snapshots_enabled\":true") {
      return Ok(server)
    }
    @async.sleep(100)
  }
  @sys.kill_server_pid_sequence_best_effort(pid)
  Err(@types.ChoirError::timeout("BoxLite probe server readiness"))
}

///|
fn stop_boxlite_probe_server(server : BoxLiteProbeServer) -> Unit {
  @sys.kill_server_pid_sequence_best_effort(server.pid)
}

///|
async fn capture_boxlite_remote_cli(
  binary : String,
  server : BoxLiteProbeServer,
  root : String,
  command_args : Array[String],
  timeout_ms : Int,
) -> Result[@sandbox.BoxLiteProbeCapture, @types.ChoirError] {
  let args : Array[String] = [
    "--home",
    root + "/client-home",
    "--url",
    server.url,
  ]
  for arg in command_args {
    args.push(arg)
  }
  capture_boxlite_fixed_process(
    binary,
    args,
    root,
    boxlite_probe_environment(root, Some(server.api_key)),
    timeout_ms,
  )
}

///|
fn boxlite_create_body(name : String, network_disabled : Bool) -> String {
  let network : Map[String, Json] = {
    "mode": if network_disabled {
      "disabled".to_json()
    } else {
      "enabled".to_json()
    },
    "allow_net": if network_disabled {
      ([] : Array[String]).to_json()
    } else {
      ["127.0.0.1"].to_json()
    },
  }
  let body : Map[String, Json] = {
    "name": name.to_json(),
    "image": @sandbox.boxlite_probe_image.to_json(),
    "cpus": (1 : Int).to_json(),
    "memory_mib": (256 : Int).to_json(),
    "disk_size_gb": (1 : Int).to_json(),
    "entrypoint": ["/bin/sh"].to_json(),
    "cmd": ["-c", "while :; do sleep 60; done"].to_json(),
    "network": network.to_json(),
    "auto_remove": false.to_json(),
    "detach": true.to_json(),
  }
  body.to_json().stringify(indent=0)
}

///|
fn boxlite_clone_body(name : String) -> String {
  let body : Map[String, Json] = { "name": name.to_json() }
  body.to_json().stringify(indent=0)
}

///|
fn boxlite_exec_body(command : String, args : Array[String]) -> String {
  let body : Map[String, Json] = {
    "command": command.to_json(),
    "args": args.to_json(),
    "tty": false.to_json(),
  }
  body.to_json().stringify(indent=0)
}

///|
fn boxlite_signal_body(signal : Int) -> String {
  let body : Map[String, Json] = { "signal": signal.to_json() }
  body.to_json().stringify(indent=0)
}

///|
fn boxlite_copy_in_args(
  host_source : String,
  box_id : String,
  guest_directory : String,
) -> Array[String] {
  ["cp", host_source, box_id + ":" + guest_directory]
}

///|
fn boxlite_copy_out_args(
  box_id : String,
  guest_source : String,
  host_directory : String,
) -> Array[String] {
  ["cp", box_id + ":" + guest_source, host_directory]
}

///|
fn boxlite_rest_uploaded_path(
  guest_directory : String,
  source_name : String,
) -> String {
  guest_directory + "/extracted/" + source_name
}

///|
test "BoxLite REST create body fixes security-relevant resource policy" {
  let body = boxlite_create_body("probe", true)
  assert_true(body.contains("\"mode\":\"disabled\""))
  assert_true(body.contains("\"cpus\":1"))
  assert_true(body.contains("\"memory_mib\":256"))
  assert_true(body.contains("\"disk_size_gb\":1"))
  assert_false(body.contains("rootfs_path"))
  assert_false(body.contains("security"))
  assert_false(body.contains("volume"))
}

///|
test "BoxLite copy commands target staging directories" {
  assert_eq(boxlite_copy_in_args("/stage/input.txt", "box-1", "/root/work"), [
    "cp", "/stage/input.txt", "box-1:/root/work",
  ])
  assert_eq(
    boxlite_copy_out_args("box-1", "/root/work/output.txt", "/stage/out"),
    ["cp", "box-1:/root/work/output.txt", "/stage/out"],
  )
  assert_eq(
    boxlite_rest_uploaded_path("/root/work", "input.txt"),
    "/root/work/extracted/input.txt",
  )
}

///|
test "BoxLite probe environment starts from an explicit narrow map" {
  let environment = boxlite_probe_environment_with_runtime(
    "/tmp/probe",
    Some("key"),
    Some("/opt/choir/boxlite-runtime"),
  )
  assert_eq(environment.length(), 6)
  assert_eq(environment["HOME"], "/tmp/probe")
  assert_eq(environment["BOXLITE_API_KEY"], "key")
  assert_eq(environment["BOXLITE_RUNTIME_DIR"], "/opt/choir/boxlite-runtime")
  assert_false(environment.contains("SSH_AUTH_SOCK"))
  assert_false(environment.contains("DOCKER_HOST"))
}

///|
fn boxlite_lifecycle_failure_evidence(
  capture : @sandbox.BoxLiteProbeCapture,
  label : String,
) -> @sandbox.BoxLiteDownstreamEvidence {
  let evidence = @sandbox.boxlite_downstream_not_run_evidence()
  let failed = boxlite_failed_capture(capture, label)
  {
    ..evidence,
    clone_isolation: failed,
    transfer_lifecycle: failed,
    attach_signal_kill: failed,
    restart_recovery: failed,
    read_only_boundary: failed,
  }
}

///|
async fn capture_boxlite_lifecycle_evidence(
  binary : String,
  root : String,
  network_disabled : Bool,
) -> Result[@sandbox.BoxLiteDownstreamEvidence, @types.ChoirError] {
  let server = match start_boxlite_probe_server(binary, root) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let active_server = @ref.new(server)
  defer stop_boxlite_probe_server(active_server.val)
  let unauthenticated = match
    capture_boxlite_curl(root, [
      "-sS",
      "--max-time",
      "5",
      "-o",
      "/dev/null",
      "-w",
      "%{http_code}",
      server.url + "/v1/boxes",
    ]) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if unauthenticated.exit_code != 0 ||
    unauthenticated.output.trim().to_owned() != "401" {
    return Ok(
      boxlite_lifecycle_failure_evidence(
        unauthenticated, "unauthenticated mutation route was not denied",
      ),
    )
  }
  let base_name = "choir-base-" + @sys.get_pid().to_string()
  let created = match
    capture_boxlite_authorized_http(
      server,
      root,
      "POST",
      "/v1/boxes",
      Some(boxlite_create_body(base_name, network_disabled)),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let base_id = match boxlite_json_string_field(created.output, "box_id") {
    Some(value) if created.exit_code == 0 => value
    _ =>
      return Ok(
        boxlite_lifecycle_failure_evidence(created, "prepared base creation"),
      )
  }
  let started_base = match
    capture_boxlite_authorized_http(
      server,
      root,
      "POST",
      "/v1/boxes/" + base_id + "/start",
      None,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if started_base.exit_code != 0 {
    return Ok(
      boxlite_lifecycle_failure_evidence(started_base, "prepared base start"),
    )
  }
  let input_root = root + "/transfer-in"
  if !@sys.create_dir_all(input_root) ||
    !@sys.write_file_sync(
      input_root + "/seed.txt",
      "CHOIR_BOXLITE_TRANSFER_SEED\n",
    ) {
    return Err(
      @types.ChoirError::workspace_error(
        "cannot prepare BoxLite transfer staging input",
      ),
    )
  }
  // Seed the persistent guest filesystem independently of the transfer API.
  // Transfer conformance is measured below and must not prevent the remaining
  // lifecycle operations from being exercised.
  let seed_base = match
    capture_boxlite_remote_cli(
      binary,
      server,
      root,
      [
        "exec", base_id, "--", "/bin/sh", "-c", "mkdir -p /root/choir-probe && printf '%s\\n' CHOIR_BOXLITE_TRANSFER_SEED > /root/choir-probe/seed.txt",
      ],
      30000,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if seed_base.exit_code != 0 {
    return Ok(
      boxlite_lifecycle_failure_evidence(seed_base, "prepared base seed"),
    )
  }
  let stopped_base = match
    capture_boxlite_authorized_http(
      server,
      root,
      "POST",
      "/v1/boxes/" + base_id + "/stop",
      None,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if stopped_base.exit_code != 0 {
    return Ok(
      boxlite_lifecycle_failure_evidence(stopped_base, "prepared base stop"),
    )
  }
  let clone_a_capture = match
    capture_boxlite_authorized_http(
      server,
      root,
      "POST",
      "/v1/boxes/" + base_id + "/clone",
      Some(boxlite_clone_body("choir-clone-a-" + @sys.get_pid().to_string())),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let clone_a = match
    boxlite_json_string_field(clone_a_capture.output, "box_id") {
    Some(value) if clone_a_capture.exit_code == 0 => value
    _ =>
      return Ok(
        boxlite_lifecycle_failure_evidence(clone_a_capture, "first clone"),
      )
  }
  let clone_b_capture = match
    capture_boxlite_authorized_http(
      server,
      root,
      "POST",
      "/v1/boxes/" + base_id + "/clone",
      Some(boxlite_clone_body("choir-clone-b-" + @sys.get_pid().to_string())),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let clone_b = match
    boxlite_json_string_field(clone_b_capture.output, "box_id") {
    Some(value) if clone_b_capture.exit_code == 0 => value
    _ =>
      return Ok(
        boxlite_lifecycle_failure_evidence(clone_b_capture, "second clone"),
      )
  }
  for clone_id in [clone_a, clone_b] {
    let started = match
      capture_boxlite_authorized_http(
        server,
        root,
        "POST",
        "/v1/boxes/" + clone_id + "/start",
        None,
      ) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    if started.exit_code != 0 {
      return Ok(boxlite_lifecycle_failure_evidence(started, "clone start"))
    }
  }
  let attached = match
    capture_boxlite_remote_cli(
      binary,
      server,
      root,
      ["exec", clone_a, "--", "/bin/echo", "CHOIR_BOXLITE_ATTACH_OK"],
      30000,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if attached.exit_code != 0 ||
    !attached.output.contains("CHOIR_BOXLITE_ATTACH_OK") {
    return Ok(boxlite_lifecycle_failure_evidence(attached, "attach stream"))
  }
  let transfer_marker = input_root + "/transfer-in.txt"
  if !@sys.write_file_sync(transfer_marker, "CHOIR_BOXLITE_TRANSFER_IN\n") {
    return Err(
      @types.ChoirError::workspace_error(
        "cannot prepare BoxLite transfer input",
      ),
    )
  }
  let copy_in = match
    capture_boxlite_remote_cli(
      binary,
      server,
      root,
      boxlite_copy_in_args(transfer_marker, clone_a, "/root/choir-probe"),
      30000,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let copy_in_check = match
    capture_boxlite_remote_cli(
      binary,
      server,
      root,
      [
        "exec",
        clone_a,
        "--",
        "/bin/cat",
        boxlite_rest_uploaded_path("/root/choir-probe", "transfer-in.txt"),
      ],
      30000,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let clone_a_write = match
    capture_boxlite_remote_cli(
      binary,
      server,
      root,
      [
        "exec", clone_a, "--", "/bin/sh", "-c", "printf '%s\\n' CHOIR_BOXLITE_CLONE_A_ONLY > /root/choir-probe/clone-a-only.txt",
      ],
      30000,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let clone_b_check = match
    capture_boxlite_remote_cli(
      binary,
      server,
      root,
      [
        "exec", clone_b, "--", "/bin/sh", "-c", "if [ -e /root/choir-probe/clone-a-only.txt ]; then exit 51; else echo CHOIR_BOXLITE_CLONE_B_ISOLATED; fi",
      ],
      30000,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let clone_a_check = match
    capture_boxlite_remote_cli(
      binary,
      server,
      root,
      ["exec", clone_a, "--", "/bin/cat", "/root/choir-probe/clone-a-only.txt"],
      30000,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let clone_isolation = if clone_a_write.exit_code != 0 ||
    clone_a_check.exit_code != 0 ||
    !clone_a_check.output.contains("CHOIR_BOXLITE_CLONE_A_ONLY") ||
    clone_b_check.exit_code != 0 ||
    !clone_b_check.output.contains("CHOIR_BOXLITE_CLONE_B_ISOLATED") {
    boxlite_failed_capture(
      if clone_a_write.exit_code != 0 {
        clone_a_write
      } else if clone_a_check.exit_code != 0 {
        clone_a_check
      } else {
        clone_b_check
      },
      "clone isolation",
    )
  } else {
    boxlite_pass_capture("CHOIR_BOXLITE_CLONE_OK")
  }
  let copy_out_root = root + "/transfer-out"
  if !@sys.create_dir_all(copy_out_root) {
    return Err(
      @types.ChoirError::workspace_error(
        "cannot create BoxLite transfer output staging root",
      ),
    )
  }
  let copy_out = match
    capture_boxlite_remote_cli(
      binary,
      server,
      root,
      boxlite_copy_out_args(
        clone_a, "/root/choir-probe/seed.txt", copy_out_root,
      ),
      30000,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let transfer_lifecycle = if copy_in.exit_code != 0 ||
    copy_in_check.exit_code != 0 ||
    !copy_in_check.output.contains("CHOIR_BOXLITE_TRANSFER_IN") ||
    copy_out.exit_code != 0 ||
    @sys.read_file(copy_out_root + "/seed.txt") !=
    "CHOIR_BOXLITE_TRANSFER_SEED\n" {
    boxlite_failed_capture(
      if copy_in.exit_code != 0 {
        copy_in
      } else if copy_in_check.exit_code != 0 ||
        !copy_in_check.output.contains("CHOIR_BOXLITE_TRANSFER_IN") {
        copy_in_check
      } else {
        copy_out
      },
      "transfer lifecycle",
    )
  } else {
    boxlite_pass_capture("CHOIR_BOXLITE_TRANSFER_OK")
  }
  let execution = match
    capture_boxlite_authorized_http(
      server,
      root,
      "POST",
      "/v1/boxes/" + clone_a + "/exec",
      Some(
        boxlite_exec_body("/bin/sh", [
          "-c", "trap 'exit 0' TERM; while :; do sleep 1; done",
        ]),
      ),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let execution_id = match
    boxlite_json_string_field(execution.output, "execution_id") {
    Some(value) if execution.exit_code == 0 => value
    _ =>
      return Ok(
        boxlite_lifecycle_failure_evidence(execution, "signal execution start"),
      )
  }
  let signaled = match
    capture_boxlite_authorized_http(
      server,
      root,
      "POST",
      "/v1/boxes/" + clone_a + "/executions/" + execution_id + "/signal",
      Some(boxlite_signal_body(15)),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let kill_execution = match
    capture_boxlite_authorized_http(
      server,
      root,
      "POST",
      "/v1/boxes/" + clone_a + "/exec",
      Some(boxlite_exec_body("/bin/sh", ["-c", "while :; do sleep 1; done"])),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let kill_execution_id = match
    boxlite_json_string_field(kill_execution.output, "execution_id") {
    Some(value) if kill_execution.exit_code == 0 => value
    _ =>
      return Ok(
        boxlite_lifecycle_failure_evidence(
          kill_execution, "kill execution start",
        ),
      )
  }
  let killed = match
    capture_boxlite_authorized_http(
      server,
      root,
      "DELETE",
      "/v1/boxes/" + clone_a + "/executions/" + kill_execution_id,
      None,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if signaled.exit_code != 0 || killed.exit_code != 0 {
    return Ok(
      boxlite_lifecycle_failure_evidence(
        if signaled.exit_code != 0 {
          signaled
        } else {
          killed
        },
        "signal or kill",
      ),
    )
  }
  let host_canary = root + "/host-read-only-canary"
  if !@sys.write_file_sync(host_canary, "HOST_ONLY\n") {
    return Err(
      @types.ChoirError::workspace_error(
        "cannot create BoxLite host-boundary canary",
      ),
    )
  }
  let boundary = match
    capture_boxlite_remote_cli(
      binary,
      server,
      root,
      [
        "exec",
        clone_a,
        "--",
        "/bin/sh",
        "-c",
        "if [ -e " +
        host_canary +
        "]; then exit 52; else echo CHOIR_BOXLITE_READ_ONLY_OK; fi",
      ],
      30000,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if boundary.exit_code != 0 ||
    !boundary.output.contains("CHOIR_BOXLITE_READ_ONLY_OK") {
    return Ok(boxlite_lifecycle_failure_evidence(boundary, "host boundary"))
  }
  for clone_id in [clone_a, clone_b] {
    let stopped = match
      capture_boxlite_authorized_http(
        server,
        root,
        "POST",
        "/v1/boxes/" + clone_id + "/stop",
        None,
      ) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    if stopped.exit_code != 0 {
      return Ok(boxlite_lifecycle_failure_evidence(stopped, "clone stop"))
    }
  }
  stop_boxlite_probe_server(server)
  @async.sleep(400)
  let restarted_server = match start_boxlite_probe_server(binary, root) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  active_server.val = restarted_server
  let readopted = match
    capture_boxlite_authorized_http(
      restarted_server,
      root,
      "GET",
      "/v1/boxes/" + clone_a,
      None,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if readopted.exit_code != 0 || !readopted.output.contains(clone_a) {
    return Ok(
      boxlite_lifecycle_failure_evidence(readopted, "restart re-adoption"),
    )
  }
  Ok({
    ..@sandbox.boxlite_downstream_not_run_evidence(),
    clone_isolation,
    transfer_lifecycle,
    attach_signal_kill: boxlite_pass_capture("CHOIR_BOXLITE_PROCESS_CONTROL_OK"),
    restart_recovery: boxlite_pass_capture("CHOIR_BOXLITE_RESTART_RECOVERY_OK"),
    read_only_boundary: boxlite_pass_capture("CHOIR_BOXLITE_READ_ONLY_OK"),
  })
}

///|
fn merge_boxlite_downstream_evidence(
  lifecycle : @sandbox.BoxLiteDownstreamEvidence,
  network : @sandbox.BoxLiteDownstreamEvidence,
) -> @sandbox.BoxLiteDownstreamEvidence {
  {
    ..lifecycle,
    network_disabled: network.network_disabled,
    network_dns: network.network_dns,
    network_tcp: network.network_tcp,
    network_udp: network.network_udp,
    network_quic: network.network_quic,
    network_host_aliases: network.network_host_aliases,
    network_choir_socket: network.network_choir_socket,
    network_runtime_socket: network.network_runtime_socket,
  }
}

///|
async fn capture_boxlite_runtime_bundle_hashes(
  root : String,
  runtime_dir : String?,
) -> Result[@sandbox.BoxLiteProbeCapture, @types.ChoirError] {
  match runtime_dir {
    Some(path) => {
      let environment = boxlite_probe_environment_with_runtime(
        root,
        None,
        Some(path),
      )
      let entries = match
        capture_boxlite_fixed_process(
          "/usr/bin/find",
          [path, "-mindepth", "1", "-maxdepth", "1", "-printf", "%y %f\n"],
          root,
          environment,
          10000,
        ) {
        Ok(capture) => capture
        Err(error) => return Err(error)
      }
      if entries.exit_code != 0 {
        return Ok(entries)
      }
      let args : Array[String] = []
      for name in @sandbox.boxlite_runtime_bundle_files() {
        args.push(path + "/" + name)
      }
      let hashes = match
        capture_boxlite_fixed_process(
          "/usr/bin/sha256sum", args, root, environment, 10000,
        ) {
        Ok(capture) => capture
        Err(error) => return Err(error)
      }
      Ok({
        exit_code: hashes.exit_code,
        output: "ENTRIES\n" + entries.output + "HASHES\n" + hashes.output,
      })
    }
    None => Ok({ exit_code: -3, output: "" })
  }
}

///|
/// Execute only the fixed, pinned BoxLite release probe matrix.
pub async fn capture_boxlite_live_evidence(
  dedicated_root : String,
) -> Result[@sandbox.BoxLiteLiveEvidence, @types.ChoirError] {
  if !dedicated_root.has_prefix("/tmp/choir-conformance-boxlite-") {
    return Err(
      @types.ChoirError::validation_error(
        "BoxLite probe root is outside the dedicated conformance namespace",
      ),
    )
  }
  let runtime_dir = match @sys.getenv("CHOIR_BOXLITE_RUNTIME_DIR") {
    Some(path) =>
      if !path.has_prefix("/") || path.contains(":") {
        return Err(
          @types.ChoirError::validation_error(
            "CHOIR_BOXLITE_RUNTIME_DIR must be one absolute operator-controlled conformance path",
          ),
        )
      } else {
        Some(path)
      }
    None => None
  }
  let binary = match boxlite_probe_executable() {
    Ok(path) => path
    Err(error) => return Err(error)
  }
  let executable_hash = match
    capture_boxlite_probe_operation(
      binary,
      dedicated_root,
      @sandbox.BoxLiteProbeOperation::BoxLiteHashExecutable,
    ) {
    Ok(capture) => capture
    Err(error) => return Err(error)
  }
  let observed_hash = executable_hash.output.trim().to_owned()
  let runtime_bundle_hashes = match
    capture_boxlite_runtime_bundle_hashes(dedicated_root, runtime_dir) {
    Ok(capture) => capture
    Err(error) => return Err(error)
  }
  if executable_hash.exit_code != 0 ||
    observed_hash.length() < 64 ||
    observed_hash[:64].to_owned() != @sandbox.boxlite_release_executable_sha256 ||
    !@sandbox.boxlite_runtime_bundle_matches(runtime_bundle_hashes) {
    let not_run : @sandbox.BoxLiteProbeCapture = { exit_code: -3, output: "" }
    return Ok({
      executable_hash,
      runtime_bundle_hashes,
      version: not_run,
      info: not_run,
      image_pull: not_run,
      secure_boot: not_run,
      insecure_boot_diagnostic: not_run,
      downstream: @sandbox.boxlite_downstream_not_run_evidence(),
    })
  }
  let version = match
    capture_boxlite_probe_operation(
      binary,
      dedicated_root,
      @sandbox.BoxLiteProbeOperation::BoxLiteVersion,
    ) {
    Ok(capture) => capture
    Err(error) => return Err(error)
  }
  if version.exit_code != 0 ||
    version.output.trim().to_owned() != "boxlite 0.9.7" {
    let not_run : @sandbox.BoxLiteProbeCapture = { exit_code: -3, output: "" }
    return Ok({
      executable_hash,
      runtime_bundle_hashes,
      version,
      info: not_run,
      image_pull: not_run,
      secure_boot: not_run,
      insecure_boot_diagnostic: not_run,
      downstream: @sandbox.boxlite_downstream_not_run_evidence(),
    })
  }
  let info = match
    capture_boxlite_probe_operation(
      binary,
      dedicated_root,
      @sandbox.BoxLiteProbeOperation::BoxLiteInfo,
    ) {
    Ok(capture) => capture
    Err(error) => return Err(error)
  }
  if info.exit_code != 0 || !info.output.contains("virtualization: available") {
    let not_run : @sandbox.BoxLiteProbeCapture = { exit_code: -3, output: "" }
    return Ok({
      executable_hash,
      runtime_bundle_hashes,
      version,
      info,
      image_pull: not_run,
      secure_boot: not_run,
      insecure_boot_diagnostic: not_run,
      downstream: @sandbox.boxlite_downstream_not_run_evidence(),
    })
  }
  let image_pull = match
    capture_boxlite_probe_operation(
      binary,
      dedicated_root,
      @sandbox.BoxLiteProbeOperation::BoxLitePullPinnedImage,
    ) {
    Ok(capture) => capture
    Err(error) => return Err(error)
  }
  if image_pull.exit_code != 0 {
    let not_run : @sandbox.BoxLiteProbeCapture = { exit_code: -3, output: "" }
    return Ok({
      executable_hash,
      runtime_bundle_hashes,
      version,
      info,
      image_pull,
      secure_boot: not_run,
      insecure_boot_diagnostic: not_run,
      downstream: @sandbox.boxlite_downstream_not_run_evidence(),
    })
  }
  let secure_boot = match
    capture_boxlite_probe_operation(
      binary,
      dedicated_root,
      @sandbox.BoxLiteProbeOperation::BoxLiteSecureBoot,
    ) {
    Ok(capture) => capture
    Err(error) => return Err(error)
  }
  // This is a diagnostic control only. Its success can show that the image and
  // KVM path work; it can never admit a runtime whose secure boot failed.
  let insecure_boot_diagnostic = match
    capture_boxlite_probe_operation(
      binary,
      dedicated_root,
      @sandbox.BoxLiteProbeOperation::BoxLiteInsecureBootDiagnostic,
    ) {
    Ok(capture) => capture
    Err(error) => return Err(error)
  }
  let downstream = if secure_boot.exit_code == 0 &&
    secure_boot.output.contains("CHOIR_BOXLITE_SECURE_OK") {
    let lifecycle = match
      capture_boxlite_lifecycle_evidence(binary, dedicated_root, true) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let network = match
      capture_boxlite_network_evidence(binary, dedicated_root, true) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    merge_boxlite_downstream_evidence(lifecycle, network)
  } else {
    let lifecycle = match
      capture_boxlite_lifecycle_evidence(binary, dedicated_root, false) {
      Ok(value) => value
      Err(_) => @sandbox.boxlite_downstream_not_run_evidence()
    }
    let network = match
      capture_boxlite_network_evidence(binary, dedicated_root, false) {
      Ok(value) => value
      Err(_) => @sandbox.boxlite_downstream_not_run_evidence()
    }
    merge_boxlite_downstream_evidence(lifecycle, network)
  }
  Ok({
    executable_hash,
    runtime_bundle_hashes,
    version,
    info,
    image_pull,
    secure_boot,
    insecure_boot_diagnostic,
    downstream,
  })
}

///|
fn claude_startup_probe_args(
  mcp_executable : String,
  mcp_args : Array[String],
) -> Array[String] {
  let server : Map[String, Json] = {
    "command": mcp_executable.to_json(),
    "args": mcp_args.to_json(),
  }
  let servers : Map[String, Json] = { "choir_probe": server.to_json() }
  let mcp_config : Map[String, Json] = { "mcpServers": servers.to_json() }
  [
    "-p",
    "--setting-sources",
    "",
    "--tools",
    "",
    "--disable-slash-commands",
    "--permission-mode",
    "dontAsk",
    "--allowedTools",
    "mcp__choir_probe__probe",
    "--strict-mcp-config",
    "--mcp-config",
    mcp_config.to_json().stringify(),
    "--output-format",
    "stream-json",
    "--verbose",
    "--no-session-persistence",
    "--system-prompt",
    "You are a restricted startup probe.",
    "Return exactly PROBE_OK without using tools.",
  ]
}

///|
async fn collect_claude_startup_probe(
  claude : String,
  args : Array[String],
  root : String,
  probe_env : Map[String, String],
  timeout_ms : Int,
  label : String,
) -> Result[@harness.HarnessProbeCapture, @types.ChoirError] {
  abort_if_hermetic_test_exec(command_for_program(claude, args, Some(root)))
  let collected = @async.with_timeout_opt(timeout_ms, () => {
    @process.collect_output_merged(
      claude,
      args,
      extra_env=probe_env,
      inherit_env=false,
      cwd=root,
    )
  }) catch {
    _ =>
      return Err(
        @types.ChoirError::transport_error(
          "Claude " + label + " startup process failed",
        ),
      )
  }
  match collected {
    None => Ok({ exit_code: -2, output: "" })
    Some((exit_code, data)) => {
      let output = data.text() catch {
        _ =>
          return Err(
            @types.ChoirError::transport_error(
              "Claude " + label + " startup output was not UTF-8",
            ),
          )
      }
      Ok({ exit_code, output })
    }
  }
}

///|
fn claude_probe_executable() -> Result[String, @types.ChoirError] {
  match resolve_executable_in_path("claude") {
    Some(path) => Ok(path)
    None =>
      Err(
        @types.ChoirError::transport_error(
          "provider probe executable unavailable: claude",
        ),
      )
  }
}

///|
pub async fn capture_claude_synthetic_startup(
  synthetic_root : String,
  mcp_executable : String,
  mcp_args : Array[String],
) -> Result[@harness.HarnessProbeCapture, @types.ChoirError] {
  if !synthetic_root.has_prefix("/tmp/choir-conformance-") ||
    !mcp_executable.has_prefix("/") {
    return Err(
      @types.ChoirError::validation_error(
        "synthetic startup paths are outside the conformance root",
      ),
    )
  }
  let claude = match claude_probe_executable() {
    Ok(path) => path
    Err(error) => return Err(error)
  }
  let probe_env : Map[String, String] = {
    "HOME": synthetic_root,
    "XDG_CONFIG_HOME": synthetic_root + "/xdg",
    "TMPDIR": synthetic_root + "/tmp",
    "PATH": "/usr/local/bin:/usr/bin:/bin",
    "COLUMNS": "200",
    "NO_COLOR": "1",
  }
  collect_claude_startup_probe(
    claude,
    claude_startup_probe_args(mcp_executable, mcp_args),
    synthetic_root,
    probe_env,
    10000,
    "synthetic",
  )
}

///|
fn claude_conflicting_credential_environment() -> String? {
  let names = [
    "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "AWS_BEARER_TOKEN_BEDROCK", "CLAUDE_CODE_USE_BEDROCK",
    "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
  ]
  for name in names {
    match @sys.getenv(name) {
      Some(_) => return Some(name)
      None => ()
    }
  }
  None
}

///|
pub async fn capture_claude_live_startup(
  dedicated_root : String,
  mcp_executable : String,
  mcp_args : Array[String],
) -> Result[@harness.HarnessProbeCapture, @types.ChoirError] {
  if !dedicated_root.has_prefix("/tmp/choir-conformance-") ||
    !mcp_executable.has_prefix("/") {
    return Err(
      @types.ChoirError::validation_error(
        "live startup paths are outside the conformance root",
      ),
    )
  }
  match claude_conflicting_credential_environment() {
    Some(name) =>
      return Err(
        @types.ChoirError::policy_blocked(
          "conflicting Claude credential environment is present: " + name,
        ),
      )
    None => ()
  }
  let provider_home = match @sys.getenv("HOME") {
    Some(path) if path != "" => path
    _ =>
      return Err(
        @types.ChoirError::config_error(
          "provider-owned HOME is unavailable for live Claude probe",
        ),
      )
  }
  let claude = match claude_probe_executable() {
    Ok(path) => path
    Err(error) => return Err(error)
  }
  let probe_env : Map[String, String] = {
    "HOME": provider_home,
    "TMPDIR": dedicated_root + "/tmp",
    "PATH": "/usr/local/bin:/usr/bin:/bin",
    "COLUMNS": "200",
    "NO_COLOR": "1",
  }
  collect_claude_startup_probe(
    claude,
    claude_startup_probe_args(mcp_executable, mcp_args),
    dedicated_root,
    probe_env,
    60000,
    "live",
  )
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
fn moon_direct_global_flag_takes_value(flag : String) -> Bool {
  flag == "-C" ||
  flag == "--directory" ||
  flag == "--target" ||
  flag == "--source-dir" ||
  flag == "--target-dir" ||
  flag == "--build-dir" ||
  flag == "--config" ||
  flag == "-Z" ||
  flag == "--unstable-feature"
}

///|
fn moon_direct_program_is_moon(program : String) -> Bool {
  program == "moon" || program.has_suffix("/moon")
}

///|
fn moon_direct_render_subcommand(subcommand : String) -> Bool {
  subcommand == "check" || subcommand == "test" || subcommand == "build"
}

///|
fn moon_direct_args_with_suppressed_render(
  args : Array[String],
) -> Array[String] {
  if args.contains("--no-render") {
    return args
  }
  let mut i = 0
  while i < args.length() && args[i].has_prefix("-") {
    let flag = args[i]
    i = i + 1
    if moon_direct_global_flag_takes_value(flag) &&
      !flag.contains("=") &&
      i < args.length() {
      i = i + 1
    }
  }
  if i >= args.length() || !moon_direct_render_subcommand(args[i]) {
    return args
  }
  let out : Array[String] = []
  for j = 0; j < args.length(); j = j + 1 {
    out.push(args[j])
    if j == i {
      out.push("--no-render")
    }
  }
  out
}

///|
pub fn command_with_suppressed_moon_render(
  cmd : @workspace.Command,
) -> @workspace.Command {
  if moon_direct_program_is_moon(cmd.program) {
    let args = moon_direct_args_with_suppressed_render(cmd.args)
    if args != cmd.args {
      return { ..cmd, args, }
    }
    return cmd
  }
  if (cmd.program == "sh" || cmd.program == "bash") &&
    cmd.args.length() == 2 &&
    (cmd.args[0] == "-lc" || cmd.args[0] == "-c") {
    let script = @types.moon_render_suppress_command(cmd.args[1])
    if script != cmd.args[1] {
      return { ..cmd, args: [cmd.args[0], script] }
    }
  }
  cmd
}

///|
pub async fn run(cmd : @workspace.Command) -> Int {
  let run_cmd = command_with_suppressed_moon_render(cmd)
  abort_if_hermetic_test_exec(command_to_shell_string(run_cmd))
  let native = @workspace.run_native_choir_file_command(run_cmd)
  if native >= 0 {
    return native
  }
  let native_rel = @workspace.run_native_workspace_rel_file_command(run_cmd)
  if native_rel >= 0 {
    return native_rel
  }
  let native_leaf_helpers = @workspace.run_native_leaf_helpers_command(run_cmd)
  if native_leaf_helpers >= 0 {
    return native_leaf_helpers
  }
  let native_wt_cleanup = @workspace.run_native_worktree_bootstrap_cleanup_command(
    run_cmd,
  )
  if native_wt_cleanup >= 0 {
    return native_wt_cleanup
  }
  let native_fetch = @workspace.run_native_git_fetch_origin_branch_best_effort_command(
    run_cmd,
  )
  if native_fetch >= 0 {
    return native_fetch
  }
  let native_seed = @workspace.run_native_worktree_seed_agent_runtime_gitexclude_command(
    run_cmd,
  )
  if native_seed >= 0 {
    return native_seed
  }
  let native_agy_cache_links = @workspace.run_native_agy_cache_links_command(
    run_cmd,
  )
  if native_agy_cache_links >= 0 {
    return native_agy_cache_links
  }
  let native_agy_prepare = @workspace.run_native_agy_shared_cache_prepare_command(
    run_cmd,
  )
  if native_agy_prepare >= 0 {
    return native_agy_prepare
  }
  let native_agy_validate = @workspace.run_native_agy_shared_cache_validate_command(
    run_cmd,
  )
  if native_agy_validate >= 0 {
    return native_agy_validate
  }
  let native_agy_seed_if_needed = run_agy_shared_cache_seed_if_needed_command(
    run_cmd,
  )
  if native_agy_seed_if_needed >= 0 {
    return native_agy_seed_if_needed
  }
  let prog = run_cmd.program
  let args = run_cmd.args[:]
  match run_cmd.workdir {
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
