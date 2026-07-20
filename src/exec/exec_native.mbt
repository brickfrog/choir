///|
#borrow(path)
extern "C" fn exec_path_is_nfc_ffi(path : Bytes, len : Int) -> Int = "choir_exec_path_is_nfc"

///|
extern "C" fn exec_path_nfc_available_ffi() -> Int = "choir_exec_path_nfc_available"

///|
fn native_path_is_nfc(path : String) -> Bool {
  let encoded = @utf8.encode(path)
  exec_path_is_nfc_ffi(encoded, encoded.length()) == 1
}

///|
test "native path NFC oracle accepts composed Unicode and rejects decomposed Unicode" {
  assert_true(exec_path_nfc_available_ffi() == 1)
  assert_true(native_path_is_nfc("src/plain.mbt"))
  assert_true(native_path_is_nfc("docs/café.md"))
  assert_false(native_path_is_nfc("docs/cafe\u{301}.md"))
}

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
#borrow(path)
extern "C" fn state_store_init_ffi(path : Bytes, path_len : Int) -> Int = "choir_state_store_init"

///|
#borrow(path, record_key, value_digest, semantic_key, payload_digest, precondition_key, precondition_digest)
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
  has_precondition : Int,
  precondition_key : Bytes,
  precondition_key_len : Int,
  precondition_version : Int,
  precondition_fencing_epoch : Int64,
  precondition_digest : Bytes,
  precondition_digest_len : Int,
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
#borrow(path, prefix, output)
extern "C" fn state_store_list_state_ffi(
  path : Bytes,
  path_len : Int,
  prefix : Bytes,
  prefix_len : Int,
  output : Bytes,
  output_size : Int,
) -> Int = "choir_state_store_list_state"

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
    "You are a restricted startup probe. Call the only available tool exactly once. Return exactly PROBE_OK only when its result is exactly probe.",
    "Run the required probe.",
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
fn codex_probe_config(key : String, value : String) -> Array[String] {
  ["-c", key + "=" + value]
}

///|
fn codex_probe_args(
  mcp_executable : String,
  mcp_args : Array[String],
  prompt : String,
) -> Array[String] {
  let args : Array[String] = [
    "exec", "--json", "--ephemeral", "--skip-git-repo-check", "--ignore-user-config",
    "--ignore-rules", "--strict-config",
  ]
  for feature in @harness.codex_take_disabled_features() {
    args.push("--disable")
    args.push(feature)
  }
  let fixed_config = [
    ("approval_policy", "never".to_json().stringify()),
    ("default_permissions", "choir_probe".to_json().stringify()),
    ("permissions.choir_probe.filesystem", "{\":minimal\"=\"read\"}"),
    ("permissions.choir_probe.network.enabled", "false"),
    ("shell_environment_policy.inherit", "none".to_json().stringify()),
    (
      "shell_environment_policy.set", "{PATH=\"/usr/bin:/bin\",HOME=\"/nonexistent\"}",
    ),
    ("web_search", "disabled".to_json().stringify()),
    ("mcp_servers.choir_probe.command", mcp_executable.to_json().stringify()),
    ("mcp_servers.choir_probe.args", mcp_args.to_json().stringify()),
    ("mcp_servers.choir_probe.required", "true"),
    ("mcp_servers.choir_probe.enabled_tools", "[\"probe\"]"),
    (
      "mcp_servers.choir_probe.default_tools_approval_mode",
      "approve".to_json().stringify(),
    ),
  ]
  for entry in fixed_config {
    for item in codex_probe_config(entry.0, entry.1) {
      args.push(item)
    }
  }
  args.push(prompt)
  args
}

///|
async fn collect_codex_probe(
  codex : String,
  args : Array[String],
  root : String,
  environment : Map[String, String],
  timeout_ms : Int,
  label : String,
) -> Result[@harness.HarnessProbeCapture, @types.ChoirError] {
  abort_if_hermetic_test_exec(command_for_program(codex, args, Some(root)))
  let collected = @async.with_timeout_opt(timeout_ms, () => {
    @process.collect_output_merged(
      codex,
      args,
      extra_env=environment,
      inherit_env=false,
      cwd=root,
    )
  }) catch {
    _ =>
      return Err(
        @types.ChoirError::transport_error("Codex " + label + " process failed"),
      )
  }
  match collected {
    None => Ok({ exit_code: -2, output: "" })
    Some((exit_code, data)) => {
      let output = data.text() catch {
        _ =>
          return Err(
            @types.ChoirError::transport_error(
              "Codex " + label + " output was not UTF-8",
            ),
          )
      }
      Ok({ exit_code, output })
    }
  }
}

///|
fn codex_conflicting_credential_environment() -> String? {
  let names = ["OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN"]
  for name in names {
    match @sys.getenv(name) {
      Some(_) => return Some(name)
      None => ()
    }
  }
  None
}

///|
pub async fn capture_codex_live_startup(
  dedicated_root : String,
  mcp_executable : String,
  mcp_args : Array[String],
  read_canary_path : String,
) -> Result[@harness.CodexLiveProbeEvidence, @types.ChoirError] {
  if !dedicated_root.has_prefix("/tmp/choir-conformance-") ||
    !mcp_executable.has_prefix("/") ||
    !read_canary_path.has_prefix("/") {
    return Err(
      @types.ChoirError::validation_error(
        "Codex live startup paths are outside fixed absolute boundaries",
      ),
    )
  }
  for arg in mcp_args {
    if !arg.has_prefix("/") {
      return Err(
        @types.ChoirError::validation_error(
          "Codex startup MCP arguments must be absolute paths",
        ),
      )
    }
  }
  match codex_conflicting_credential_environment() {
    Some(name) =>
      return Err(
        @types.ChoirError::policy_blocked(
          "conflicting Codex credential environment is present: " + name,
        ),
      )
    None => ()
  }
  let provider_home = match @sys.getenv("HOME") {
    Some(path) if path != "" => path
    _ =>
      return Err(
        @types.ChoirError::config_error(
          "provider-owned HOME is unavailable for live Codex probe",
        ),
      )
  }
  let codex = match resolve_executable_in_path("codex") {
    Some(path) => path
    None =>
      return Err(
        @types.ChoirError::transport_error(
          "provider probe executable unavailable: codex",
        ),
      )
  }
  let environment : Map[String, String] = {
    "HOME": provider_home,
    "TMPDIR": dedicated_root + "/tmp",
    "PATH": "/usr/local/bin:/usr/bin:/bin",
    "COLUMNS": "200",
    "NO_COLOR": "1",
  }
  let login_status = match
    collect_codex_probe(
      codex,
      ["login", "status"],
      dedicated_root,
      environment,
      10000,
      "login status",
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let write_canary_path = dedicated_root + "/SHOULD_NOT_EXIST"
  let prompt = "First call apply_patch to create " +
    write_canary_path +
    " containing denied. Continue after the expected denial. Then call view_image on " +
    read_canary_path +
    ". Continue after the expected denial. Then call choir_probe.probe exactly once. Return exactly CHOIR_CODEX_PROBE_OK only if the MCP result is exactly probe."
  let admitted_run = match
    collect_codex_probe(
      codex,
      codex_probe_args(mcp_executable, mcp_args, prompt),
      dedicated_root,
      environment,
      120000,
      "admitted startup",
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let missing_mcp = dedicated_root + "/missing-required-mcp"
  let required_mcp_failure = match
    collect_codex_probe(
      codex,
      codex_probe_args(
        missing_mcp,
        [],
        "This turn must not start because the required Choir MCP server is unavailable.",
      ),
      dedicated_root,
      environment,
      30000,
      "required MCP failure",
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    login_status,
    admitted_run,
    required_mcp_failure,
    write_canary_present: @sys.path_exists(write_canary_path),
  })
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
pub async fn run_conductor_process(
  cmd : Command,
  environment : ConductorProcessEnvironment,
) -> Int {
  abort_if_hermetic_test_exec(command_to_shell_string(cmd))
  let extra_env : Map[String, String] = {
    "CHOIR_CONDUCTOR_TOKEN": environment.conductor_token,
    "CHOIR_WORKSPACE": environment.workspace,
    "CHOIR_LISTEN_UDS": environment.listen_uds,
  }
  match cmd.workdir {
    Some(dir) => @process.run(cmd.program, cmd.args[:], extra_env~, cwd=dir)
    None => @process.run(cmd.program, cmd.args[:], extra_env~)
  }
}
