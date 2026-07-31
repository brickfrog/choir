///|
#borrow(path)
extern "C" fn exec_path_is_nfc_ffi(path : Bytes, len : Int) -> Int = "choir_exec_path_is_nfc"

///|
extern "C" fn exec_path_nfc_available_ffi() -> Int = "choir_exec_path_nfc_available"

///|
#borrow(out)
extern "C" fn exec_path_nfc_library_path_ffi(
  out : Bytes,
  max_size : Int,
) -> Int = "choir_exec_path_nfc_library_path"

///|
pub fn native_path_nfc_library_path() -> String? {
  let out = Bytes::new(4096)
  let length = exec_path_nfc_library_path_ffi(out, out.length())
  if length <= 0 {
    None
  } else {
    Some(@utf8.decode_lossy(out[:length]))
  }
}

///|
pub fn native_path_nfc_available() -> Bool {
  exec_path_nfc_available_ffi() == 1
}

///|
pub fn native_path_is_nfc(path : String) -> Bool {
  let encoded = @utf8.encode(path)
  exec_path_is_nfc_ffi(encoded, encoded.length()) == 1
}

///|
pub(all) enum ChoirRuntimeAsset {
  ChoirSandboxMcp
  ChoirBoxLiteOwner
}

///|
fn ChoirRuntimeAsset::filename(self : ChoirRuntimeAsset) -> String {
  match self {
    ChoirSandboxMcp => "choir_sandbox_mcp.mjs"
    ChoirBoxLiteOwner => "choir_boxlite_owner.mjs"
  }
}

///|
fn native_runtime_parent(path : String) -> String {
  let mut index = path.length() - 1
  while index >= 0 && path[index] != '/' {
    index = index - 1
  }
  if index <= 0 {
    "/"
  } else {
    path[:index].to_owned()
  }
}

///|
fn native_runtime_asset_candidates(
  executable : String,
  asset : ChoirRuntimeAsset,
) -> Array[String] {
  let executable_dir = native_runtime_parent(executable)
  let filename = asset.filename()
  [
    executable_dir + "/" + filename,
    executable_dir + "/../libexec/choir/" + filename,
    executable_dir + "/../share/choir/" + filename,
  ]
}

///|
pub fn resolve_native_runtime_asset(asset : ChoirRuntimeAsset) -> String? {
  match @sys.getenv("CHOIR_RUNTIME_ASSET_DIR") {
    Some(directory) if directory.has_prefix("/") =>
      match @sys.realpath_native(directory + "/" + asset.filename()) {
        Some(path) => return Some(path)
        None => ()
      }
    _ => ()
  }
  let executable = match @sys.realpath_native("/proc/self/exe") {
    Some(value) => value
    None => return None
  }
  for candidate in native_runtime_asset_candidates(executable, asset) {
    match @sys.realpath_native(candidate) {
      Some(path) => return Some(path)
      None => ()
    }
  }
  None
}

///|
pub fn validate_native_runtime_assets() -> Result[Unit, @types.ChoirError] {
  for asset in [ChoirRuntimeAsset::ChoirSandboxMcp, ChoirBoxLiteOwner] {
    if resolve_native_runtime_asset(asset) is None {
      return Err(
        @types.ChoirError::workspace_error(
          "required Choir runtime asset is absent: " + asset.filename(),
        ),
      )
    }
  }
  Ok(())
}

///|
pub fn validate_native_goal_runtime(
  validate_assets? : () -> Result[Unit, @types.ChoirError] = validate_native_runtime_assets,
  resolve_binary? : () -> Result[String, @types.ChoirError] = native_boxlite_binary_path,
  resolve_runtime? : () -> Result[String, @types.ChoirError] = native_boxlite_runtime_dir,
  canonicalize? : (String) -> String? = @sys.realpath_native,
) -> Result[Unit, @types.ChoirError] {
  match validate_assets() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let binary = match resolve_binary() {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if canonicalize(binary) is None {
    return Err(
      @types.ChoirError::workspace_error(
        "BoxLite executable is absent at the configured path",
      ),
    )
  }
  let runtime = match resolve_runtime() {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if canonicalize(runtime) is None {
    return Err(
      @types.ChoirError::workspace_error(
        "BoxLite runtime bundle is absent at the configured path",
      ),
    )
  }
  Ok(())
}

///|
test "runtime assets resolve only from explicit installation layouts" {
  assert_eq(native_runtime_parent("/opt/choir/bin/choir"), "/opt/choir/bin")
  assert_eq(native_runtime_parent("/choir"), "/")
  assert_eq(
    native_runtime_asset_candidates(
      "/home/user/.local/bin/choir",
      ChoirRuntimeAsset::ChoirSandboxMcp,
    ),
    [
      "/home/user/.local/bin/choir_sandbox_mcp.mjs", "/home/user/.local/bin/../libexec/choir/choir_sandbox_mcp.mjs",
      "/home/user/.local/bin/../share/choir/choir_sandbox_mcp.mjs",
    ],
  )
  assert_false(
    native_runtime_asset_candidates(
      "/home/user/.local/bin/choir",
      ChoirRuntimeAsset::ChoirSandboxMcp,
    ).contains("scripts/choir_sandbox_mcp.mjs"),
  )
}

///|
test "installer layout matches native runtime path contracts" {
  let executable = "/opt/choir-prefix/bin/choir"
  let sandbox = native_runtime_asset_candidates(
    executable,
    ChoirRuntimeAsset::ChoirSandboxMcp,
  )
  let owner = native_runtime_asset_candidates(
    executable,
    ChoirRuntimeAsset::ChoirBoxLiteOwner,
  )
  assert_true(
    sandbox.contains(
      "/opt/choir-prefix/bin/../libexec/choir/choir_sandbox_mcp.mjs",
    ),
  )
  assert_true(
    owner.contains(
      "/opt/choir-prefix/bin/../libexec/choir/choir_boxlite_owner.mjs",
    ),
  )
  assert_true(
    native_boxlite_binary_candidates(executable).contains(
      "/opt/choir-prefix/bin/../libexec/choir/boxlite",
    ),
  )
  assert_true(
    native_boxlite_runtime_candidates(executable).contains(
      "/opt/choir-prefix/bin/../libexec/choir/boxlite-runtime",
    ),
  )
}

///|
test "real exec integration: native path NFC oracle accepts composed Unicode and rejects decomposed Unicode" {
  if !@test_support.real_exec_integration_enabled() {
    return
  }
  assert_true(exec_path_nfc_available_ffi() == 1)
  let library_path = native_path_nfc_library_path().unwrap()
  assert_true(@sys.realpath_native(library_path) is Some(_))
  assert_true(native_path_is_nfc("src/plain.mbt"))
  assert_true(native_path_is_nfc("docs/café.md"))
  assert_false(native_path_is_nfc("docs/cafe\u{301}.md"))
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
pub async fn drain_process_stdout(
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
    @terminal.strip_terminal_responses(
      @utf8.decode_lossy(buf.unsafe_reinterpret_as_bytes()[:total]),
    ),
    total,
  )
}

///|
async fn capture_command_merged_raw(cmd : Command) -> (Int, String) {
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
pub async fn capture_command_merged(cmd : Command) -> (Int, String) {
  capture_command_merged_raw(cmd)
}

///|
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
fn native_spawn_goal_worker(
  command : Command,
) -> Result[Int, @types.ChoirError] {
  let directory = match command.workdir {
    Some(value) => value
    None =>
      return Err(
        @types.ChoirError::validation_error(
          "Goal worker requires a project directory",
        ),
      )
  }
  let pid = @sys.spawn_goal_worker(command.program, directory)
  if pid <= 1 {
    Err(@types.ChoirError::transport_error("failed to start the Goal worker"))
  } else {
    Ok(pid)
  }
}

///|
pub fn spawn_native_goal_worker(
  choir_executable : String,
  project_dir : String,
  spawn? : (Command) -> Result[Int, @types.ChoirError] = native_spawn_goal_worker,
) -> Result[Int, @types.ChoirError] {
  let command = match goal_worker_command(choir_executable, project_dir) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  spawn(command)
}

///|
pub fn native_boxlite_binary_path() -> Result[String, @types.ChoirError] {
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
    None => {
      let executable = @sys.realpath_native("/proc/self/exe")
      if executable is Some(path) {
        for candidate in native_boxlite_binary_candidates(path) {
          match @sys.realpath_native(candidate) {
            Some(value) => return Ok(value)
            None => ()
          }
        }
      }
      match resolve_executable_in_path("boxlite") {
        Some(path) => Ok(path)
        None =>
          Err(
            @types.ChoirError::transport_error(
              "BoxLite executable unavailable: install the admitted binary beside Choir, install it in PATH, or set CHOIR_BOXLITE_BINARY",
            ),
          )
      }
    }
  }
}

///|
pub fn native_boxlite_runtime_dir() -> Result[String, @types.ChoirError] {
  match @sys.getenv("CHOIR_BOXLITE_RUNTIME_DIR") {
    Some(path) =>
      if path.has_prefix("/") && !path.contains(":") {
        Ok(path)
      } else {
        Err(
          @types.ChoirError::validation_error(
            "CHOIR_BOXLITE_RUNTIME_DIR must be one absolute operator-controlled conformance path",
          ),
        )
      }
    None => {
      let executable = @sys.realpath_native("/proc/self/exe")
      if executable is Some(path) {
        for candidate in native_boxlite_runtime_candidates(path) {
          match @sys.realpath_native(candidate) {
            Some(value) => return Ok(value)
            None => ()
          }
        }
      }
      Err(
        @types.ChoirError::validation_error(
          "BoxLite runtime unavailable: install the corrected bundle beside Choir or set CHOIR_BOXLITE_RUNTIME_DIR",
        ),
      )
    }
  }
}

///|
fn native_boxlite_binary_candidates(executable : String) -> Array[String] {
  let directory = native_runtime_parent(executable)
  [directory + "/boxlite", directory + "/../libexec/choir/boxlite"]
}

///|
fn native_boxlite_runtime_candidates(executable : String) -> Array[String] {
  let directory = native_runtime_parent(executable)
  [
    directory + "/boxlite-runtime",
    directory + "/../libexec/choir/boxlite-runtime",
    directory + "/../share/choir/boxlite-runtime",
  ]
}

///|
test "BoxLite install candidates stay relative to the Choir executable" {
  assert_eq(native_boxlite_binary_candidates("/home/user/.local/bin/choir"), [
    "/home/user/.local/bin/boxlite", "/home/user/.local/bin/../libexec/choir/boxlite",
  ])
  assert_eq(
    native_boxlite_runtime_candidates("/home/user/.local/libexec/choir/choir"),
    [
      "/home/user/.local/libexec/choir/boxlite-runtime", "/home/user/.local/libexec/choir/../libexec/choir/boxlite-runtime",
      "/home/user/.local/libexec/choir/../share/choir/boxlite-runtime",
    ],
  )
}
