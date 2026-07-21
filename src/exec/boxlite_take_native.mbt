///|
pub(all) struct NativeBoxLiteServerConfig {
  binary : String
  runtime_dir : String
  root : String
  port : Int
  api_key : String
} derive(Debug, Eq)

///|
pub(all) struct NativeBoxLiteServerHandle {
  config : NativeBoxLiteServerConfig
  pid : Int
  url : String
  owner_pid : Int
  owner_socket : String
  owner_token : String
} derive(Debug, Eq)

///|
pub(all) struct NativeBoxLitePreparedEnvironment {
  server : NativeBoxLiteServerHandle
  base_box_id : String
  image_digest : @control.Digest
  tool_manifest_digest : @control.Digest
  runtime_policy_digest : @control.Digest
} derive(Debug, Eq)

///|
pub(all) struct NativeBoxLiteTakeSandbox {
  prepared : NativeBoxLitePreparedEnvironment
  box_id : String
  source_digest : @control.Digest
  workspace_access : @sandbox.BoxLiteWorkspaceAccess
} derive(Debug, Eq)

///|
pub(all) struct NativeSandboxProcessResult {
  exit_code : Int
  output : String
  output_digest : @control.Digest
  started_at : Int64?
  finished_at : Int64?
} derive(Debug, Eq, ToJson, FromJson)

///|
fn native_sandbox_process_evidence(result : NativeSandboxProcessResult) -> Json {
  {
    "exit_code": result.exit_code.to_json(),
    "output_digest": result.output_digest.to_json(),
  }.to_json()
}

///|
test "durable process evidence excludes captured output" {
  let secret = "CHOIR_SYNTHETIC_PROCESS_OUTPUT_SECRET"
  let evidence = native_sandbox_process_evidence({
    exit_code: 1,
    output: "stderr: " + secret,
    output_digest: @storage.artifact_digest(@utf8.encode("stderr: " + secret)),
    started_at: Some(1L),
    finished_at: Some(2L),
  }).stringify(indent=0)
  assert_true(evidence.contains("output_digest"))
  assert_true(evidence.contains("exit_code"))
  assert_false(evidence.contains(secret))
  assert_false(evidence.contains("stderr"))
}

///|
fn native_boxlite_take_error(message : String) -> @types.ChoirError {
  @types.ChoirError::transport_error("BoxLite Take runtime: " + message)
}

///|
fn valid_native_boxlite_token(value : String, max_length : Int) -> Bool {
  if value == "" || value.length() > max_length {
    return false
  }
  for index = 0; index < value.length(); index = index + 1 {
    let code = value[index].to_int()
    let valid = (code >= 'a'.to_int() && code <= 'z'.to_int()) ||
      (code >= 'A'.to_int() && code <= 'Z'.to_int()) ||
      (code >= '0'.to_int() && code <= '9'.to_int()) ||
      code == '_'.to_int() ||
      code == '-'.to_int()
    if !valid {
      return false
    }
  }
  true
}

///|
fn validate_native_boxlite_server_config(
  config : NativeBoxLiteServerConfig,
) -> Result[Unit, @types.ChoirError] {
  let root_prefix = "/tmp/choir-take-"
  if !config.binary.has_prefix("/") ||
    !config.runtime_dir.has_prefix("/") ||
    !config.root.has_prefix(root_prefix) ||
    !valid_native_boxlite_token(
      config.root[root_prefix.length():].to_owned(),
      120,
    ) ||
    config.port < 1024 ||
    config.port > 65535 ||
    !valid_native_boxlite_token(config.api_key, 180) {
    Err(
      @types.ChoirError::validation_error(
        "native BoxLite server configuration is invalid",
      ),
    )
  } else {
    Ok(())
  }
}

///|
fn native_boxlite_environment(
  server : NativeBoxLiteServerHandle,
  authenticated : Bool,
) -> Map[String, String] {
  boxlite_probe_environment_with_runtime(
    server.config.root,
    if authenticated {
      Some(server.config.api_key)
    } else {
      None
    },
    Some(server.config.runtime_dir),
  )
}

///|
fn native_boxlite_remote_client_home(
  server : NativeBoxLiteServerHandle,
  discriminator : String,
) -> String {
  server.config.root +
  "/clients/" +
  @storage.artifact_digest(@utf8.encode(discriminator)).0[:20].to_owned()
}

///|
test "remote BoxLite clients get deterministic isolated homes" {
  let server : NativeBoxLiteServerHandle = {
    config: {
      binary: "/bin/boxlite",
      runtime_dir: "/runtime",
      root: "/tmp/choir-take-client-home-test",
      port: 12345,
      api_key: "key",
    },
    pid: 1,
    url: "http://127.0.0.1:12345",
    owner_pid: 2,
    owner_socket: "/tmp/choir-take-client-home-test/owner.sock",
    owner_token: "a".repeat(64),
  }
  let first = native_boxlite_remote_client_home(server, "box-a")
  assert_eq(first, native_boxlite_remote_client_home(server, "box-a"))
  assert_true(first.has_prefix(server.config.root + "/clients/"))
  assert_false(first == native_boxlite_remote_client_home(server, "box-b"))
}

///|
async fn capture_native_boxlite_http(
  server : NativeBoxLiteServerHandle,
  http_method : String,
  path : String,
  body : String?,
) -> Result[@sandbox.BoxLiteProbeCapture, @types.ChoirError] {
  let args : Array[String] = [
    "-fsS",
    "--max-time",
    "30",
    "-X",
    http_method,
    "-H",
    "Authorization: Bearer " + server.config.api_key,
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
  capture_boxlite_fixed_process(
    "/usr/bin/curl",
    args,
    server.config.root,
    native_boxlite_environment(server, false),
    40000,
  )
}

///|
async fn capture_native_boxlite_cli(
  server : NativeBoxLiteServerHandle,
  command : Array[String],
  timeout_ms : Int,
) -> Result[@sandbox.BoxLiteProbeCapture, @types.ChoirError] {
  let args : Array[String] = [
    "--home",
    native_boxlite_remote_client_home(server, command.join("\u{00}")),
    "--url",
    server.url,
  ]
  for item in command {
    args.push(item)
  }
  capture_boxlite_fixed_process(
    server.config.binary,
    args,
    server.config.root,
    native_boxlite_environment(server, true),
    timeout_ms,
  )
}

///|
async fn capture_native_boxlite_local_cli(
  config : NativeBoxLiteServerConfig,
  command : Array[String],
  timeout_ms : Int,
) -> Result[@sandbox.BoxLiteProbeCapture, @types.ChoirError] {
  let args : Array[String] = ["--home", config.root + "/server-home"]
  for item in command {
    args.push(item)
  }
  capture_boxlite_fixed_process(
    config.binary,
    args,
    config.root,
    boxlite_probe_environment_with_runtime(
      config.root,
      None,
      Some(config.runtime_dir),
    ),
    timeout_ms,
  )
}

///|
pub async fn start_native_boxlite_server(
  config : NativeBoxLiteServerConfig,
) -> Result[NativeBoxLiteServerHandle, @types.ChoirError] {
  match validate_native_boxlite_server_config(config) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if !@sys.create_dir_all(config.root) ||
    !@sys.create_dir_all(config.root + "/tmp") ||
    !@sys.create_dir_all(config.root + "/server-home") ||
    !@sys.create_dir_all(config.root + "/clients") ||
    !@sys.create_dir_all(config.root + "/staging") ||
    !@sys.create_dir_all(config.root + "/results") {
    return Err(native_boxlite_take_error("runtime directories are unavailable"))
  }
  if @sys.realpath_native(config.root) != Some(config.root) {
    return Err(native_boxlite_take_error("runtime root is not canonical"))
  }
  let executable_hash = match
    capture_boxlite_fixed_process(
      "/usr/bin/sha256sum",
      [config.binary],
      config.root,
      boxlite_probe_environment_with_runtime(
        config.root,
        None,
        Some(config.runtime_dir),
      ),
      10000,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let runtime_hashes = match
    capture_boxlite_runtime_bundle_hashes(config.root, Some(config.runtime_dir)) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if executable_hash.exit_code != 0 ||
    executable_hash.output.length() < 64 ||
    executable_hash.output[:64].to_owned() !=
    @sandbox.boxlite_release_executable_sha256 ||
    !@sandbox.boxlite_runtime_bundle_matches(runtime_hashes) {
    return Err(
      @types.ChoirError::policy_blocked(
        "BoxLite executable or runtime bundle is not the admitted identity",
      ),
    )
  }
  let image = match
    capture_boxlite_fixed_process(
      config.binary,
      [
        "--home",
        config.root + "/server-home",
        "pull",
        @sandbox.boxlite_take_image,
      ],
      config.root,
      boxlite_probe_environment_with_runtime(
        config.root,
        None,
        Some(config.runtime_dir),
      ),
      180000,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if image.exit_code != 0 {
    return Err(
      native_boxlite_take_error(
        "pinned image pull failed: " + image.output.trim().to_owned(),
      ),
    )
  }
  let url = "http://127.0.0.1:" + config.port.to_string()
  let args = [
    "--home",
    config.root + "/server-home",
    "serve",
    "--host",
    "127.0.0.1",
    "--port",
    config.port.to_string(),
    "--api-key",
    config.api_key,
  ]
  abort_if_hermetic_test_exec(
    command_for_program(config.binary, args, Some(config.root)),
  )
  let pid = @process.spawn_orphan(
    config.binary,
    args[:],
    extra_env=boxlite_probe_environment_with_runtime(
      config.root,
      None,
      Some(config.runtime_dir),
    ),
    inherit_env=false,
    cwd=config.root,
  ) catch {
    _ => return Err(native_boxlite_take_error("server failed to start"))
  }
  let owner_socket = config.root + "/owner.sock"
  let owner_token = match @sys.mint_local_token() {
    Some(value) if value.length() == 64 => value
    _ => {
      @sys.kill_server_pid_sequence_best_effort(pid)
      return Err(
        native_boxlite_take_error("runtime owner capability mint failed"),
      )
    }
  }
  let server : NativeBoxLiteServerHandle = {
    config,
    pid,
    url,
    owner_pid: 0,
    owner_socket,
    owner_token,
  }
  for attempt = 0; attempt < 80; attempt = attempt + 1 {
    let ready = match
      capture_boxlite_fixed_process(
        "/usr/bin/curl",
        ["-fsS", "--max-time", "1", url + "/v1/config"],
        server.config.root,
        native_boxlite_environment(server, false),
        2000,
      ) {
      Ok(value) => value
      Err(error) => {
        @sys.kill_server_pid_sequence_best_effort(pid)
        return Err(error)
      }
    }
    if ready.exit_code == 0 &&
      ready.output.contains("\"clone_enabled\":true") &&
      ready.output.contains("\"snapshots_enabled\":true") {
      let node = match resolve_executable_in_path("node") {
        Some(value) => value
        None => {
          @sys.kill_server_pid_sequence_best_effort(pid)
          return Err(
            native_boxlite_take_error("runtime owner node is unavailable"),
          )
        }
      }
      let owner_script = match
        @sys.realpath_native("scripts/choir_boxlite_owner.mjs") {
        Some(value) => value
        None => {
          @sys.kill_server_pid_sequence_best_effort(pid)
          return Err(
            native_boxlite_take_error("runtime owner script is unavailable"),
          )
        }
      }
      ignore(@sys.delete_file_sync(owner_socket))
      let owner_pid = @process.spawn_orphan(
        node,
        [
          owner_script,
          "--socket",
          owner_socket,
          "--binary",
          config.binary,
          "--runtime-dir",
          config.runtime_dir,
          "--home",
          config.root + "/server-home",
          "--url",
          url,
        ],
        extra_env={
          "HOME": config.root,
          "PATH": "/usr/bin:/bin",
          "CHOIR_BOXLITE_OWNER_TOKEN": owner_token,
          "CHOIR_BOXLITE_API_KEY": config.api_key,
        },
        inherit_env=false,
        cwd=config.root,
      ) catch {
        _ => {
          @sys.kill_server_pid_sequence_best_effort(pid)
          return Err(native_boxlite_take_error("runtime owner failed to start"))
        }
      }
      for owner_attempt = 0
          owner_attempt < 50
          owner_attempt = owner_attempt + 1 {
        if @sys.path_entry_exists(owner_socket) && @sys.pid_is_alive(owner_pid) {
          return Ok({ ..server, owner_pid, })
        }
        @async.sleep(20)
      }
      @sys.kill_server_pid_sequence_best_effort(owner_pid)
      @sys.kill_server_pid_sequence_best_effort(pid)
      let detail = @sys.read_file(config.root + "/server-home/owner.log")
        .trim()
        .to_owned()
      return Err(
        native_boxlite_take_error(
          if detail == "" {
            "runtime owner readiness timed out"
          } else {
            "runtime owner readiness failed: " + detail
          },
        ),
      )
    }
    @async.sleep(100)
  }
  @sys.kill_server_pid_sequence_best_effort(pid)
  Err(@types.ChoirError::timeout("BoxLite Take server readiness"))
}

///|
pub fn stop_native_boxlite_server(server : NativeBoxLiteServerHandle) -> Unit {
  if server.owner_pid > 1 {
    @sys.kill_server_pid_sequence_best_effort(server.owner_pid)
  }
  @sys.kill_server_pid_sequence_best_effort(server.pid)
}

///|
async fn remove_native_boxlite_runtime_root(
  config : NativeBoxLiteServerConfig,
) -> Result[Unit, @types.ChoirError] {
  match validate_native_boxlite_server_config(config) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if !@sys.path_exists(config.root) {
    return Ok(())
  }
  let writable = @process.collect_output_merged(
    "/usr/bin/chmod",
    ["-R", "u+rwX", "--", config.root],
    extra_env={ "HOME": "/nonexistent", "PATH": "/usr/bin:/bin" },
    inherit_env=false,
    cwd="/tmp",
  ) catch {
    _ => return Err(native_boxlite_take_error("runtime root cleanup failed"))
  }
  if writable.0 != 0 {
    return Err(native_boxlite_take_error("runtime root cleanup failed"))
  }
  ignore(@sys.rm_rf(config.root))
  if @sys.path_exists(config.root) {
    Err(native_boxlite_take_error("runtime root cleanup failed"))
  } else {
    Ok(())
  }
}

///|
pub async fn cleanup_native_boxlite_server(
  server : NativeBoxLiteServerHandle,
) -> Result[Unit, @types.ChoirError] {
  stop_native_boxlite_server(server)
  @async.sleep(400)
  let removed = match
    capture_native_boxlite_local_cli(
      server.config,
      ["rm", "--all", "--force"],
      120000,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if removed.exit_code == 0 {
    remove_native_boxlite_runtime_root(server.config)
  } else {
    Err(
      native_boxlite_take_error(
        "runtime cleanup failed: " + removed.output.trim().to_owned(),
      ),
    )
  }
}

///|
async test "native BoxLite cleanup removes sealed result trees" {
  let root = "/tmp/choir-take-cleanup-test-" + @sys.get_pid().to_string()
  ignore(@sys.rm_rf(root))
  let read_only_result = root + "/results/take/workspace/nested"
  if !@sys.create_dir_all(read_only_result) ||
    !@sys.write_file_sync(read_only_result + "/result.txt", "sealed\n") {
    fail("failed to create cleanup fixture")
  }
  let modes = @process.collect_output_merged(
    "/usr/bin/chmod",
    ["-R", "a-w", "--", root + "/results/take/workspace"],
    extra_env={ "HOME": "/nonexistent", "PATH": "/usr/bin:/bin" },
    inherit_env=false,
    cwd="/tmp",
  ) catch {
    _ => fail("failed to seal cleanup fixture")
  }
  if modes.0 != 0 {
    fail("failed to seal cleanup fixture")
  }
  remove_native_boxlite_runtime_root({
    binary: "/opt/boxlite",
    runtime_dir: "/opt/runtime",
    root,
    port: 22000,
    api_key: "cleanup-test",
  }).unwrap()
  assert_false(@sys.path_exists(root))
}

///|
pub async fn stop_native_boxlite_take(
  take : NativeBoxLiteTakeSandbox,
) -> Result[Unit, @types.ChoirError] {
  let stopped = match
    capture_native_boxlite_http(
      take.prepared.server,
      "POST",
      "/v1/boxes/" + take.box_id + "/stop",
      None,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if stopped.exit_code == 0 {
    Ok(())
  } else {
    Err(native_boxlite_take_error("Take stop failed"))
  }
}

///|
fn native_boxlite_create_body(name : String) -> String {
  let network : Map[String, Json] = {
    "mode": "disabled".to_json(),
    "allow_net": ([] : Array[String]).to_json(),
  }
  let body : Map[String, Json] = {
    "name": name.to_json(),
    "image": @sandbox.boxlite_take_image.to_json(),
    "cpus": (2 : Int).to_json(),
    "memory_mib": (2048 : Int).to_json(),
    "disk_size_gb": (4 : Int).to_json(),
    "entrypoint": ["/bin/sh"].to_json(),
    "cmd": ["-c", "while :; do sleep 60; done"].to_json(),
    "network": network.to_json(),
    "auto_remove": false.to_json(),
    "detach": true.to_json(),
  }
  body.to_json().stringify(indent=0)
}

///|
async fn create_and_start_native_boxlite(
  server : NativeBoxLiteServerHandle,
  name : String,
) -> Result[String, @types.ChoirError] {
  if !valid_native_boxlite_token(name, 120) {
    return Err(
      @types.ChoirError::validation_error("BoxLite box name is invalid"),
    )
  }
  let created = match
    capture_native_boxlite_http(
      server,
      "POST",
      "/v1/boxes",
      Some(native_boxlite_create_body(name)),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let box_id = match boxlite_json_string_field(created.output, "box_id") {
    Some(value) if created.exit_code == 0 => value
    _ => return Err(native_boxlite_take_error("box creation failed"))
  }
  let started = match
    capture_native_boxlite_http(
      server,
      "POST",
      "/v1/boxes/" + box_id + "/start",
      None,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if started.exit_code != 0 {
    Err(native_boxlite_take_error("box start failed"))
  } else {
    Ok(box_id)
  }
}

///|
async fn copy_native_boxlite_toolchain_offline(
  config : NativeBoxLiteServerConfig,
  box_id : String,
  source : String,
) -> Result[Unit, @types.ChoirError] {
  let resolved_source = match @sys.realpath_native(source) {
    Some(value) => value
    None =>
      return Err(
        @types.ChoirError::validation_error(
          "BoxLite toolchain source does not exist",
        ),
      )
  }
  if !resolved_source.has_prefix(config.root + "/staging/") ||
    resolved_source != source ||
    !valid_native_boxlite_token(box_id, 180) {
    return Err(
      @types.ChoirError::validation_error(
        "BoxLite toolchain transfer is outside its dedicated roots",
      ),
    )
  }
  let started = match
    capture_native_boxlite_local_cli(config, ["start", box_id], 60000) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if started.exit_code != 0 {
    return Err(native_boxlite_take_error("toolchain transfer start failed"))
  }
  let copied = match
    capture_native_boxlite_local_cli(
      config,
      ["cp", source, box_id + ":/opt/moon"],
      180000,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if copied.exit_code != 0 {
    return Err(
      native_boxlite_take_error(
        "toolchain copy-in failed: " + copied.output.trim().to_owned(),
      ),
    )
  }
  let script =
    #|set -eu
    #|marker=$(find /opt/moon -type f -name .choir-toolchain-root -print)
    #|test "$(printf '%s\n' "$marker" | sed '/^$/d' | wc -l)" -eq 1
    #|source_root=$(dirname "$marker")
    #|mkdir -p /root/choir-transfer
    #|cp -a "$source_root"/. /root/choir-transfer/
    #|rm -rf /opt/moon
    #|mkdir -p /opt/moon
    #|cp -a /root/choir-transfer/. /opt/moon/
    #|rm -rf /root/choir-transfer
  let normalized = match
    capture_native_boxlite_local_cli(
      config,
      ["exec", box_id, "--", "/bin/sh", "-c", script],
      60000,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if normalized.exit_code == 0 {
    Ok(())
  } else {
    Err(
      native_boxlite_take_error(
        "toolchain normalization failed: " + normalized.output.trim().to_owned(),
      ),
    )
  }
}

///|
async fn copy_native_boxlite_input_online(
  server : NativeBoxLiteServerHandle,
  box_id : String,
  source : String,
  destination : String,
  marker : String,
) -> Result[Unit, @types.ChoirError] {
  let resolved_source = match @sys.realpath_native(source) {
    Some(value) => value
    None =>
      return Err(
        @types.ChoirError::validation_error(
          "BoxLite transfer source does not exist",
        ),
      )
  }
  if !resolved_source.has_prefix(server.config.root + "/staging/") ||
    resolved_source != source ||
    !valid_native_boxlite_token(box_id, 180) {
    return Err(
      @types.ChoirError::validation_error(
        "BoxLite transfer is outside its dedicated roots",
      ),
    )
  }
  if destination != "/workspace" {
    return Err(
      @types.ChoirError::validation_error(
        "BoxLite online transfer destination is not admitted",
      ),
    )
  }
  let archive_key = @storage.artifact_digest(
    @utf8.encode(box_id + "\u{00}" + source + "\u{00}" + destination),
  ).0[:24].to_owned()
  let transfer_root = server.config.root + "/staging/upload-" + archive_key
  if !@sys.create_dir_all(transfer_root) ||
    @sys.realpath_native(transfer_root) != Some(transfer_root) {
    return Err(native_boxlite_take_error("transfer staging root failed"))
  }
  let archive = transfer_root + "/payload.tar"
  let archived = match
    capture_boxlite_fixed_process(
      "/usr/bin/tar",
      ["--format=ustar", "-C", source, "-cf", archive, "."],
      server.config.root,
      native_boxlite_environment(server, false),
      120000,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if archived.exit_code != 0 || !@sys.path_exists(archive) {
    return Err(
      native_boxlite_take_error(
        "transfer archive creation failed: " + archived.output.trim().to_owned(),
      ),
    )
  }
  let split = match
    capture_boxlite_fixed_process(
      "/usr/bin/split",
      ["-b", "1048576", "-d", "-a", "4", archive, transfer_root + "/part-"],
      server.config.root,
      native_boxlite_environment(server, false),
      120000,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if split.exit_code != 0 {
    return Err(
      native_boxlite_take_error(
        "transfer archive split failed: " + split.output.trim().to_owned(),
      ),
    )
  }
  ignore(@sys.rm_rf(archive))
  let encoded_upload_root = "%2Froot%2Fchoir-upload-" + archive_key
  let mut chunk_count = 0
  for index = 0; index < 2048; index = index + 1 {
    let chunk_name = "part-" + index.to_string().pad_start(4, '0')
    let chunk = transfer_root + "/" + chunk_name
    if !@sys.path_exists(chunk) {
      break
    }
    let upload_archive = transfer_root + "/upload-" + chunk_name + ".tar"
    let wrapped = match
      capture_boxlite_fixed_process(
        "/usr/bin/tar",
        [
          "--format=ustar", "-C", transfer_root, "-cf", upload_archive, chunk_name,
        ],
        server.config.root,
        native_boxlite_environment(server, false),
        30000,
      ) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    if wrapped.exit_code != 0 || !@sys.path_exists(upload_archive) {
      return Err(native_boxlite_take_error("transfer chunk wrapping failed"))
    }
    let uploaded = match
      capture_boxlite_fixed_process(
        "/usr/bin/curl",
        [
          "-fsS",
          "--max-time",
          "180",
          "-X",
          "PUT",
          "-H",
          "Authorization: Bearer " + server.config.api_key,
          "-H",
          "Content-Type: application/x-tar",
          "--data-binary",
          "@" + upload_archive,
          server.url +
          "/v1/boxes/" +
          box_id +
          "/files?path=" +
          encoded_upload_root,
        ],
        server.config.root,
        native_boxlite_environment(server, false),
        180000,
      ) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    ignore(@sys.rm_rf(upload_archive))
    if uploaded.exit_code != 0 {
      return Err(
        native_boxlite_take_error(
          "online copy-in failed: " + uploaded.output.trim().to_owned(),
        ),
      )
    }
    chunk_count = chunk_count + 1
  }
  if chunk_count == 0 || @sys.path_exists(transfer_root + "/part-2048") {
    return Err(native_boxlite_take_error("transfer chunk count is invalid"))
  }
  let assemble_script =
    #|set -eu
    #|upload_root="/root/choir-upload-$1"
    #|assemble_root="/root/choir-assemble-$1"
    #|rm -rf "$assemble_root"
    #|mkdir -p "$assemble_root/extracted"
    #|find "$upload_root" -type f -name 'part-*' -print | LC_ALL=C sort | while IFS= read -r part; do cat "$part"; done > "$assemble_root/payload.tar"
    #|tar -xf "$assemble_root/payload.tar" -C "$assemble_root/extracted"
    #|marker_path=$(find "$assemble_root/extracted" -type f -name "$2" -print)
    #|test "$(printf '%s\n' "$marker_path" | sed '/^$/d' | wc -l)" -eq 1
    #|source_root=$(dirname "$marker_path")
    #|rm -rf "$3"
    #|mkdir -p "$3"
    #|cp -a "$source_root"/. "$3"/
    #|rm -rf "$upload_root" "$assemble_root"
  let assembled = match
    capture_native_boxlite_cli(
      server,
      [
        "exec", box_id, "--", "/bin/sh", "-c", assemble_script, "choir-upload", archive_key,
        marker, destination,
      ],
      180000,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  ignore(@sys.rm_rf(transfer_root))
  if assembled.exit_code != 0 {
    return Err(native_boxlite_take_error("transfer assembly failed"))
  }
  Ok(())
}

///|
async fn copy_native_toolchain_directory(
  server : NativeBoxLiteServerHandle,
  source : String,
  destination : String,
) -> Result[Unit, @types.ChoirError] {
  let capture = @process.collect_output_merged(
    "/usr/bin/cp",
    ["-a", source, destination],
    extra_env=native_boxlite_environment(server, false),
    inherit_env=false,
    cwd=server.config.root,
  ) catch {
    _ => return Err(native_boxlite_take_error("toolchain staging failed"))
  }
  if capture.0 == 0 {
    Ok(())
  } else {
    Err(native_boxlite_take_error("toolchain staging failed"))
  }
}

///|
pub async fn prepare_native_boxlite_environment(
  server : NativeBoxLiteServerHandle,
  moon_home : String,
  base_name : String,
) -> Result[NativeBoxLitePreparedEnvironment, @types.ChoirError] {
  if !moon_home.has_prefix("/") || moon_home.contains("/../") {
    return Err(
      @types.ChoirError::validation_error("Moon toolchain root is invalid"),
    )
  }
  let base_box_id = match create_and_start_native_boxlite(server, base_name) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let stopped_before_transfer = match
    capture_native_boxlite_http(
      server,
      "POST",
      "/v1/boxes/" + base_box_id + "/stop",
      None,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if stopped_before_transfer.exit_code != 0 {
    return Err(native_boxlite_take_error("prepared base stop failed"))
  }
  let toolchain = server.config.root + "/staging/moon-toolchain"
  let toolchain_marker = toolchain + "/.choir-toolchain-root"
  let toolchain_digest = @sandbox.boxlite_take_tool_manifest_digest().0 + "\n"
  let staged = @sys.path_exists(toolchain_marker)
  if staged {
    if @sys.read_file(toolchain_marker) != toolchain_digest ||
      @sys.realpath_native(toolchain) != Some(toolchain) ||
      !@sys.path_exists(toolchain + "/bin/moon") ||
      !@sys.path_exists(toolchain + "/lib") ||
      !@sys.path_exists(toolchain + "/include") {
      return Err(native_boxlite_take_error("staged toolchain is invalid"))
    }
  } else {
    if !@sys.create_dir_all(toolchain) ||
      !@sys.write_file_sync(toolchain_marker, toolchain_digest) {
      return Err(native_boxlite_take_error("toolchain staging root failed"))
    }
    for directory in ["bin", "lib", "include"] {
      match
        copy_native_toolchain_directory(
          server,
          moon_home + "/" + directory,
          toolchain + "/" + directory,
        ) {
        Ok(_) => ()
        Err(error) => return Err(error)
      }
    }
  }
  stop_native_boxlite_server(server)
  @async.sleep(400)
  match
    copy_native_boxlite_toolchain_offline(server.config, base_box_id, toolchain) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let verified = match
    capture_native_boxlite_local_cli(
      server.config,
      [
        "exec",
        base_box_id,
        "--",
        "/bin/sh",
        "-c",
        "test \"$(cat /opt/moon/.choir-toolchain-root)\" = \"$1\" && /opt/moon/bin/moon version",
        "choir-toolchain",
        @sandbox.boxlite_take_tool_manifest_digest().0,
      ],
      60000,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if verified.exit_code != 0 {
    return Err(native_boxlite_take_error("toolchain verification failed"))
  }
  let stopped = match
    capture_native_boxlite_local_cli(
      server.config,
      ["stop", base_box_id],
      60000,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if stopped.exit_code != 0 {
    return Err(native_boxlite_take_error("prepared environment stop failed"))
  }
  let restarted = match start_native_boxlite_server(server.config) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    server: restarted,
    base_box_id,
    image_digest: @sandbox.boxlite_take_image_digest,
    tool_manifest_digest: @sandbox.boxlite_take_tool_manifest_digest(),
    runtime_policy_digest: @sandbox.boxlite_take_runtime_policy_digest(),
  })
}

///|
fn native_boxlite_clone_body(name : String) -> String {
  let body : Map[String, Json] = { "name": name.to_json() }
  body.to_json().stringify(indent=0)
}

///|
pub async fn clone_native_boxlite_take(
  prepared : NativeBoxLitePreparedEnvironment,
  name : String,
  source_directory : String,
  source_digest : @control.Digest,
) -> Result[NativeBoxLiteTakeSandbox, @types.ChoirError] {
  if !valid_native_boxlite_token(name, 120) || source_digest.0.length() != 64 {
    return Err(
      @types.ChoirError::validation_error("BoxLite Take identity is invalid"),
    )
  }
  let cloned = match
    capture_native_boxlite_http(
      prepared.server,
      "POST",
      "/v1/boxes/" + prepared.base_box_id + "/clone",
      Some(native_boxlite_clone_body(name)),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let box_id = match boxlite_json_string_field(cloned.output, "box_id") {
    Some(value) if cloned.exit_code == 0 => value
    _ => return Err(native_boxlite_take_error("prepared clone failed"))
  }
  let started = match
    capture_native_boxlite_http(
      prepared.server,
      "POST",
      "/v1/boxes/" + box_id + "/start",
      None,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if started.exit_code != 0 {
    return Err(native_boxlite_take_error("Take clone start failed"))
  }
  match
    copy_native_boxlite_input_online(
      prepared.server,
      box_id,
      source_directory,
      "/workspace",
      ".choir-source-root",
    ) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let checked = match
    capture_native_boxlite_cli(
      prepared.server,
      [
        "exec",
        box_id,
        "--",
        "/bin/sh",
        "-c",
        "test \"$(cat /workspace/.choir-source-root)\" = \"$1\" && test ! -e /workspace/.git && test ! -e /run/choir.sock && test ! -e /var/run/docker.sock && test ! -e /sys/class/net/eth0",
        "choir-source",
        source_digest.0,
      ],
      30000,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if checked.exit_code != 0 {
    return Err(native_boxlite_take_error("Take isolation check failed"))
  }
  Ok({
    prepared,
    box_id,
    source_digest,
    workspace_access: @sandbox.BoxLiteWorkspaceAccess::BoxLiteMutableWorkspace,
  })
}

///|
pub async fn seal_native_boxlite_assurance_subject(
  take : NativeBoxLiteTakeSandbox,
) -> Result[NativeBoxLiteTakeSandbox, @types.ChoirError] {
  if take.workspace_access !=
    @sandbox.BoxLiteWorkspaceAccess::BoxLiteMutableWorkspace {
    return Err(native_boxlite_take_error("assurance subject is already sealed"))
  }
  let seal_result = match
    capture_native_boxlite_cli(
      take.prepared.server,
      [
        "exec",
        take.box_id,
        "--",
        "/bin/sh",
        "-c",
        "set -eu; find /workspace -xdev -type d -exec chmod 0555 '{}' +; find /workspace -xdev -type f -perm /111 -exec chmod 0555 '{}' +; find /workspace -xdev -type f ! -perm /111 -exec chmod 0444 '{}' +; mkdir -p /scratch/home /scratch/tmp /output; chmod 0777 /scratch /scratch/home /scratch/tmp /output",
      ],
      60000,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if seal_result.exit_code != 0 {
    return Err(native_boxlite_take_error("assurance subject sealing failed"))
  }
  let probed = match
    capture_native_boxlite_cli(
      take.prepared.server,
      [
        "exec",
        take.box_id,
        "--",
        "/usr/bin/setpriv",
        "--reuid=65534",
        "--regid=65534",
        "--clear-groups",
        "--",
        "/bin/sh",
        "-c",
        "set -eu; if printf x >> /workspace/.choir-source-root 2>/dev/null; then exit 40; fi; printf scratch > /scratch/.choir-boundary-probe; printf output > /output/.choir-boundary-probe",
      ],
      30000,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if probed.exit_code != 0 {
    return Err(
      native_boxlite_take_error(
        "assurance write boundary failed with exit " +
        probed.exit_code.to_string() +
        ": " +
        probed.output.trim().to_owned(),
      ),
    )
  }
  let cleared = match
    capture_native_boxlite_cli(
      take.prepared.server,
      [
        "exec",
        take.box_id,
        "--",
        "/bin/sh",
        "-c",
        "set -eu; rm -f /scratch/.choir-boundary-probe /output/.choir-boundary-probe; test -z \"$(find /scratch /output -mindepth 1 ! -path /scratch/home ! -path /scratch/tmp -print -quit)\"",
      ],
      30000,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if cleared.exit_code != 0 {
    return Err(native_boxlite_take_error("assurance scratch reset failed"))
  }
  Ok({
    ..take,
    workspace_access: @sandbox.BoxLiteWorkspaceAccess::BoxLiteReadOnlySubject,
  })
}

///|
pub fn native_boxlite_take_mcp_arguments(
  take : NativeBoxLiteTakeSandbox,
  script : String,
) -> Result[Array[String], @types.ChoirError] {
  if !script.has_prefix("/") {
    return Err(
      @types.ChoirError::validation_error(
        "sandbox MCP script path must be absolute",
      ),
    )
  }
  let access = match take.workspace_access {
    @sandbox.BoxLiteWorkspaceAccess::BoxLiteMutableWorkspace => "mutable"
    @sandbox.BoxLiteWorkspaceAccess::BoxLiteReadOnlySubject =>
      "read-only-subject"
  }
  let execution_token = @storage.artifact_digest(
      @utf8.encode(
        "choir.boxlite-exec.v1\u{00}" +
        take.prepared.server.owner_token +
        "\u{00}" +
        take.box_id +
        "\u{00}" +
        access,
      ),
    ).0
  Ok([
    script,
    "--owner-socket",
    take.prepared.server.owner_socket,
    "--owner-token",
    execution_token,
    "--box",
    take.box_id,
    "--access",
    access,
  ])
}

///|
pub async fn inspect_native_boxlite_take(
  take : NativeBoxLiteTakeSandbox,
) -> Result[String, @types.ChoirError] {
  let inspected = match
    capture_native_boxlite_cli(
      take.prepared.server,
      [
        "exec",
        take.box_id,
        "--",
        "/bin/sh",
        "-c",
        "set -eu; test \"$(cat /workspace/.choir-source-root)\" = \"$1\"; /opt/moon/bin/moon version; printf '%s\\n' CHOIR_TAKE_SANDBOX_OK",
        "choir-inspect",
        take.source_digest.0,
      ],
      60000,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if inspected.exit_code == 0 &&
    inspected.output.contains("CHOIR_TAKE_SANDBOX_OK") {
    Ok(inspected.output)
  } else {
    Err(native_boxlite_take_error("Take inspection failed"))
  }
}

///|
fn validate_native_persisted_process_spec(
  persisted_process_spec_digest : @control.Digest,
  process : @sandbox.SandboxProcessSpec,
) -> Result[Unit, @types.ChoirError] {
  let observed_process_spec_digest = @storage.artifact_digest(
    @utf8.encode(process.to_json().stringify(indent=0)),
  )
  if observed_process_spec_digest != persisted_process_spec_digest {
    Err(
      @types.ChoirError::policy_blocked(
        "native sandbox process does not match its persisted specification",
      ),
    )
  } else {
    Ok(())
  }
}

///|
fn native_process_uses_scratch_target(arguments : Array[String]) -> Bool {
  for index = 0; index < arguments.length(); index = index + 1 {
    if arguments[index] == "--target-dir" &&
      index + 1 < arguments.length() &&
      arguments[index + 1].has_prefix("/scratch/") &&
      arguments[index + 1].length() > "/scratch/".length() {
      return true
    }
    if arguments[index].has_prefix("--target-dir=/scratch/") &&
      arguments[index].length() > "--target-dir=/scratch/".length() {
      return true
    }
  }
  false
}

///|
test "assurance process requires a nonempty scratch target" {
  assert_true(
    native_process_uses_scratch_target([
      "test", "--target-dir", "/scratch/verification-take",
    ]),
  )
  assert_true(
    native_process_uses_scratch_target([
      "test", "--target-dir=/scratch/audit-take",
    ]),
  )
  assert_false(
    native_process_uses_scratch_target([
      "test", "--target-dir", "/workspace/target",
    ]),
  )
  assert_false(native_process_uses_scratch_target(["test", "--target-dir"]))
  assert_false(
    native_process_uses_scratch_target(["test", "--target-dir=/scratch/"]),
  )
}

///|
pub async fn execute_native_boxlite_process(
  take : NativeBoxLiteTakeSandbox,
  capability : @sandbox.SandboxEffectCapability,
  persisted_process_spec_digest : @control.Digest,
  process : @sandbox.SandboxProcessSpec,
  artifact_exists : (@control.ArtifactReference) -> Bool,
) -> Result[NativeSandboxProcessResult, @types.ChoirError] {
  match
    validate_native_persisted_process_spec(
      persisted_process_spec_digest, process,
    ) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match
    @sandbox.validate_sandbox_process_spec(
      process,
      capability,
      take.prepared.runtime_policy_digest,
      artifact_exists,
      fn(tool_id, digest) {
        tool_id == @sandbox.SandboxRegisteredToolId("moon") &&
        digest == take.prepared.tool_manifest_digest
      },
      fn(_, _) { false },
    ) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if process.timeout_ms > 600000L ||
    process.output.stdout_limit_bytes + process.output.stderr_limit_bytes >
    2097152L {
    return Err(
      @types.ChoirError::policy_blocked(
        "native sandbox process exceeds the admitted runtime bound",
      ),
    )
  }
  let assurance_process = match process.authority {
    @sandbox.SandboxProcessAuthority::SandboxImplementationTool(_, _) => false
    @sandbox.SandboxProcessAuthority::SandboxVerificationTool(_, _, _)
    | @sandbox.SandboxProcessAuthority::SandboxAuditTool(_, _) => true
  }
  if assurance_process !=
    (
      take.workspace_access ==
      @sandbox.BoxLiteWorkspaceAccess::BoxLiteReadOnlySubject
    ) {
    return Err(
      @types.ChoirError::policy_blocked(
        "native sandbox workspace access does not match process authority",
      ),
    )
  }
  if assurance_process && !native_process_uses_scratch_target(process.arguments) {
    return Err(
      @types.ChoirError::policy_blocked(
        "native assurance process requires a declared scratch target",
      ),
    )
  }
  let executable = match process.executable {
    @sandbox.SandboxExecutable::SandboxRegisteredTool(tool_id, digest) =>
      if tool_id == @sandbox.SandboxRegisteredToolId("moon") &&
        digest == take.prepared.tool_manifest_digest {
        "/opt/moon/bin/moon"
      } else {
        return Err(
          @types.ChoirError::policy_blocked(
            "native sandbox executable is not in the admitted registry",
          ),
        )
      }
    _ =>
      return Err(
        @types.ChoirError::policy_blocked(
          "native sandbox executable is not in the admitted registry",
        ),
      )
  }
  match process.stdin {
    @sandbox.SandboxStdinPolicy::SandboxStdinClosed
    | @sandbox.SandboxStdinPolicy::SandboxStdinEmpty => ()
    _ =>
      return Err(
        @types.ChoirError::policy_blocked(
          "native sandbox stdin artifact execution is not supported",
        ),
      )
  }
  let working_directory = match process.working_directory {
    @sandbox.SandboxWorkingDirectory::SandboxWorkspaceRoot => "/workspace"
    @sandbox.SandboxWorkingDirectory::SandboxWorkspaceSubdirectory(path) =>
      "/workspace/" + path.0
  }
  let command : Array[String] = ["exec"]
  if assurance_process {
    command.push("--env")
    command.push("HOME=/scratch/home")
    command.push("--env")
    command.push("TMPDIR=/scratch/tmp")
  }
  command.push("--workdir")
  command.push(working_directory)
  for entry in process.environment {
    command.push("--env")
    command.push(entry.key + "=" + entry.value)
  }
  command.push(take.box_id)
  command.push("--")
  if assurance_process {
    command.push("/usr/bin/setpriv")
    command.push("--reuid=65534")
    command.push("--regid=65534")
    command.push("--clear-groups")
    command.push("--")
  }
  command.push(executable)
  for argument in process.arguments {
    command.push(argument)
  }
  let capture = match
    capture_native_boxlite_cli(
      take.prepared.server,
      command,
      process.timeout_ms.to_int(),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let output_limit = process.output.stdout_limit_bytes +
    process.output.stderr_limit_bytes
  if capture.output.length().to_int64() > output_limit {
    return Err(
      @types.ChoirError::policy_blocked(
        "native sandbox process output exceeded its admitted limit",
      ),
    )
  }
  Ok({
    exit_code: capture.exit_code,
    output: capture.output,
    output_digest: @storage.artifact_digest(@utf8.encode(capture.output)),
    started_at: None,
    finished_at: None,
  })
}

///|
pub async fn probe_native_boxlite_mcp(
  take : NativeBoxLiteTakeSandbox,
  node : String,
  script : String,
) -> Result[String, @types.ChoirError] {
  if !node.has_prefix("/") || !script.has_prefix("/") {
    return Err(
      @types.ChoirError::validation_error(
        "sandbox MCP probe executables must be absolute",
      ),
    )
  }
  let args = match native_boxlite_take_mcp_arguments(take, script) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let requests = match take.workspace_access {
    @sandbox.BoxLiteWorkspaceAccess::BoxLiteMutableWorkspace =>
      (
        #|{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
        #|{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}
        #|{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
        #|{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"read_file","arguments":{"path":"README.md"}}}
        #|{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"write_file","arguments":{"path":".choir-live-roundtrip.txt","content":"sandbox mutation\n"}}}
        #|{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"read_file","arguments":{"path":".choir-live-roundtrip.txt"}}}
        #|{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"run","arguments":{"argv":["/usr/bin/find","/workspace","-type","l","-printf","%P -> %l\\n"]}}}
        #|{"jsonrpc":"2.0","method":"notifications/exit","params":{}}
      )
    @sandbox.BoxLiteWorkspaceAccess::BoxLiteReadOnlySubject =>
      (
        #|{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
        #|{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}
        #|{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
        #|{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"read_file","arguments":{"path":"README.md"}}}
        #|{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"write_scratch","arguments":{"path":"probe/scratch.txt","content":"scratch persisted\n"}}}
        #|{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"write_output","arguments":{"path":"probe/output.txt","content":"output persisted\n"}}}
        #|{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"write_file","arguments":{"path":"README.md","content":"subject mutation\n"}}}
        #|{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"run","arguments":{"argv":["/bin/sh","-c","printf outside > /etc/choir-outside"]}}}
        #|{"jsonrpc":"2.0","method":"notifications/exit","params":{}}
      )
  }
  let (stdin_read, stdin_write) = @process.write_to_process() catch {
    _ => return Err(native_boxlite_take_error("MCP probe stdin failed"))
  }
  ignore(
    stdin_write.write(requests) catch {
      _ => {
        stdin_write.close()
        return Err(native_boxlite_take_error("MCP probe request failed"))
      }
    },
  )
  stdin_write.close()
  let collected = @async.with_timeout_opt(60000, () => {
    @process.collect_output_merged(
      node,
      args,
      extra_env={
        "HOME": take.prepared.server.config.root,
        "PATH": "/usr/bin:/bin",
        "NO_COLOR": "1",
      },
      inherit_env=false,
      stdin=stdin_read,
      cwd=take.prepared.server.config.root,
    )
  }) catch {
    _ => return Err(native_boxlite_take_error("MCP probe process failed"))
  }
  let (exit_code, data) = match collected {
    Some(value) => value
    None => return Err(@types.ChoirError::timeout("sandbox MCP probe"))
  }
  let output = data.text() catch {
    _ => return Err(native_boxlite_take_error("MCP probe output is not UTF-8"))
  }
  let contract_ok = match take.workspace_access {
    @sandbox.BoxLiteWorkspaceAccess::BoxLiteMutableWorkspace =>
      output.contains("\"name\":\"read_file\"") &&
      output.contains("sandbox mutation\\n")
    @sandbox.BoxLiteWorkspaceAccess::BoxLiteReadOnlySubject => {
      let boundary = match
        capture_native_boxlite_cli(
          take.prepared.server,
          [
            "exec",
            take.box_id,
            "--",
            "/bin/sh",
            "-c",
            "set -eu; test \"$(cat /scratch/probe/scratch.txt)\" = 'scratch persisted'; test \"$(cat /output/probe/output.txt)\" = 'output persisted'; test ! -e /etc/choir-outside; test \"$(cat /workspace/.choir-source-root)\" = \"$1\"",
            "choir-boundary",
            take.source_digest.0,
          ],
          30000,
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      boundary.exit_code == 0 &&
      output.contains("\"name\":\"write_scratch\"") &&
      output.contains("\"name\":\"write_output\"") &&
      !output.contains("\"name\":\"write_file\"") &&
      !output.contains("\"name\":\"run\"") &&
      output.contains("undeclared tool")
    }
  }
  if exit_code == 0 &&
    contract_ok &&
    !output.contains(take.prepared.server.config.api_key) {
    Ok(output)
  } else {
    Err(
      native_boxlite_take_error(
        "MCP probe contract failed: exit=" +
        exit_code.to_string() +
        " tools=" +
        output.contains("\"name\":\"read_file\"").to_string() +
        " mutation=" +
        output.contains("sandbox mutation\\n").to_string() +
        " leaked=" +
        output.contains(take.prepared.server.config.api_key).to_string() +
        " tool_error=" +
        output.contains("\"isError\":true").to_string() +
        " lock_error=" +
        output.contains("runtime lock").to_string() +
        " missing=" +
        output.contains("No such file").to_string() +
        " written=" +
        output.contains("written").to_string() +
        " read_failed=" +
        output.contains("read failed with exit").to_string() +
        " write_failed=" +
        output.contains("write failed with exit").to_string() +
        " execution_failed=" +
        output.contains("BoxLite execution failed").to_string() +
        " path_failed=" +
        output.contains("workspace path").to_string(),
      ),
    )
  }
}

///|
pub async fn probe_native_boxlite_path_identity(
  take : NativeBoxLiteTakeSandbox,
  node : String,
  script : String,
) -> Result[String, @types.ChoirError] {
  if take.workspace_access !=
    @sandbox.BoxLiteWorkspaceAccess::BoxLiteMutableWorkspace {
    return Err(
      @types.ChoirError::policy_blocked(
        "path identity requires a mutable Take workspace",
      ),
    )
  }
  if !node.has_prefix("/") || !script.has_prefix("/") {
    return Err(
      @types.ChoirError::validation_error(
        "sandbox MCP probe executables must be absolute",
      ),
    )
  }
  let logical_path = ".choir-path-identity.txt"
  let guest_initial = "GUEST_INITIAL_ONLY\n"
  let seeded = match
    capture_native_boxlite_cli(
      take.prepared.server,
      [
        "exec",
        take.box_id,
        "--",
        "/bin/sh",
        "-c",
        "set -eu; printf '%s' \"$1\" > \"/workspace/$2\"",
        "choir-path-identity",
        guest_initial,
        logical_path,
      ],
      30000,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if seeded.exit_code != 0 {
    return Err(native_boxlite_take_error("guest path canary setup failed"))
  }
  let args = match native_boxlite_take_mcp_arguments(take, script) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let requests =
    #|{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
    #|{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}
    #|{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"read_file","arguments":{"path":".choir-path-identity.txt"}}}
    #|{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"write_file","arguments":{"path":".choir-path-identity.txt","content":"GUEST_MUTATED_ONLY\n"}}}
    #|{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"read_file","arguments":{"path":".choir-path-identity.txt"}}}
    #|{"jsonrpc":"2.0","method":"notifications/exit","params":{}}
  let (stdin_read, stdin_write) = @process.write_to_process() catch {
    _ =>
      return Err(native_boxlite_take_error("path identity probe stdin failed"))
  }
  ignore(
    stdin_write.write(requests) catch {
      _ => {
        stdin_write.close()
        return Err(
          native_boxlite_take_error("path identity probe request failed"),
        )
      }
    },
  )
  stdin_write.close()
  let collected = @async.with_timeout_opt(60000, () => {
    @process.collect_output_merged(
      node,
      args,
      extra_env={
        "HOME": take.prepared.server.config.root,
        "PATH": "/usr/bin:/bin",
        "NO_COLOR": "1",
      },
      inherit_env=false,
      stdin=stdin_read,
      cwd=take.prepared.server.config.root,
    )
  }) catch {
    _ => return Err(native_boxlite_take_error("path identity probe failed"))
  }
  let (exit_code, data) = match collected {
    Some(value) => value
    None =>
      return Err(@types.ChoirError::timeout("sandbox path identity probe"))
  }
  let output = data.text() catch {
    _ =>
      return Err(native_boxlite_take_error("path identity output is not UTF-8"))
  }
  if exit_code == 0 &&
    output.contains("GUEST_INITIAL_ONLY\\n") &&
    output.contains("GUEST_MUTATED_ONLY\\n") &&
    !output.contains("HOST_ONLY") &&
    !output.contains(take.prepared.server.config.api_key) {
    Ok(output)
  } else {
    Err(
      native_boxlite_take_error(
        "guest path identity contract failed: exit=" +
        exit_code.to_string() +
        " initial=" +
        output.contains("GUEST_INITIAL_ONLY\\n").to_string() +
        " mutated=" +
        output.contains("GUEST_MUTATED_ONLY\\n").to_string() +
        " host=" +
        output.contains("HOST_ONLY").to_string() +
        " leaked=" +
        output.contains(take.prepared.server.config.api_key).to_string() +
        " tool_error=" +
        output.contains("\"isError\":true").to_string() +
        " auth=" +
        output.contains("authentication failed").to_string() +
        " owner=" +
        output.contains("BoxLite owner").to_string(),
      ),
    )
  }
}

///|
fn validate_native_boxlite_result_listing(
  listing : String,
) -> Result[@sandbox.ValidatedTransferManifest, @types.ChoirError] {
  let entries = match @sandbox.parse_transfer_archive_listing(listing) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  @sandbox.validate_transfer_manifest(
    entries,
    @sandbox.repository_result_transfer_limits(),
  )
}

///|
async fn inspect_native_boxlite_result_archive(
  server : NativeBoxLiteServerHandle,
  archive : String,
) -> Result[@sandbox.ValidatedTransferManifest, @types.ChoirError] {
  if @sys.realpath_native(archive) != Some(archive) {
    return Err(native_boxlite_take_error("copied result archive is invalid"))
  }
  let archive_size = @sys.file_size(archive)
  if archive_size <= 0 || archive_size > 805306368 {
    return Err(
      native_boxlite_take_error("copied result archive exceeds bounds"),
    )
  }
  let listed = @process.collect_output_merged(
    "/usr/bin/tar",
    [
      "--list", "--verbose", "--file", archive, "--numeric-owner", "--full-time",
      "--quoting-style=c",
    ],
    extra_env=native_boxlite_environment(server, false),
    inherit_env=false,
    cwd=server.config.root,
  ) catch {
    _ => return Err(native_boxlite_take_error("result manifest listing failed"))
  }
  let listing = listed.1.text() catch {
    _ => return Err(native_boxlite_take_error("result manifest is not UTF-8"))
  }
  if listed.0 != 0 {
    return Err(native_boxlite_take_error("result manifest listing failed"))
  }
  if listing.length() > 16777216 {
    return Err(
      native_boxlite_take_error("result manifest listing exceeds bounds"),
    )
  }
  validate_native_boxlite_result_listing(listing)
}

///|
test "native result listing admits repository symlinks and rejects other links" {
  let accepted =
    #|drwxr-xr-x 1000/1000 0 2026-07-20 22:51:46.1 "./"
    #|-rw-r--r-- 1000/1000 1 2026-07-20 22:51:46.1 "./file"
    #|lrwxrwxrwx 1000/1000 0 2026-07-20 22:51:46.1 "./AGENTS.md" -> "CLAUDE.md"
    #|
  let rejected =
    #|drwxr-xr-x 1000/1000 0 2026-07-20 22:51:46.1 "./"
    #|hrw-r--r-- 1000/1000 0 2026-07-20 22:51:46.1 "./alias" link to "file"
    #|
  assert_true(validate_native_boxlite_result_listing(accepted) is Ok(_))
  assert_true(validate_native_boxlite_result_listing(rejected) is Err(_))
}

///|
async test "native result archive is inspected through the production tar seam" {
  let root = "/tmp/choir-result-archive-test-" + @sys.get_pid().to_string()
  ignore(@sys.rm_rf(root))
  defer ignore(@sys.rm_rf(root))
  let source = root + "/source"
  if !@sys.create_dir_all(source) ||
    !@sys.write_file_sync(source + "/file.txt", "content\n") ||
    !@sys.symlink_force("file.txt", source + "/link.txt") {
    fail("failed to create result archive fixture")
  }
  let archive = root + "/result.tar"
  let created = @process.collect_output_merged(
    "/usr/bin/tar",
    ["--format=posix", "-C", source, "-cf", archive, "."],
    extra_env={ "HOME": root, "PATH": "/usr/bin:/bin" },
    inherit_env=false,
    cwd=root,
  ) catch {
    _ => fail("failed to run result archive fixture")
  }
  if created.0 != 0 {
    fail("failed to create result archive fixture")
  }
  let manifest = inspect_native_boxlite_result_archive(
    {
      config: {
        binary: "/opt/boxlite",
        runtime_dir: "/opt/runtime",
        root,
        port: 22000,
        api_key: "archive-test",
      },
      pid: 1,
      url: "http://127.0.0.1:22000",
      owner_pid: 2,
      owner_socket: root + "/owner.sock",
      owner_token: "a".repeat(64),
    },
    archive,
  ).unwrap()
  assert_eq(manifest.entries().length(), 2)
  assert_eq(manifest.total_bytes(), 8L)
}

///|
pub async fn copy_native_boxlite_take_result(
  take : NativeBoxLiteTakeSandbox,
) -> Result[String, @types.ChoirError] {
  let destination = take.prepared.server.config.root + "/results/" + take.box_id
  if @sys.path_exists(destination) || !@sys.create_dir_all(destination) {
    return Err(native_boxlite_take_error("result root is unavailable"))
  }
  let mut adopted = false
  defer (if !adopted { ignore(@sys.rm_rf(destination)) })
  let guest_archive = "/root/choir-result.tar"
  let archived = match
    capture_native_boxlite_cli(
      take.prepared.server,
      [
        "exec",
        take.box_id,
        "--",
        "/bin/tar",
        "--format=posix",
        "-C",
        "/workspace",
        "-cf",
        guest_archive,
        ".",
      ],
      180000,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if archived.exit_code != 0 {
    return Err(native_boxlite_take_error("result archive failed"))
  }
  let copied = match
    capture_native_boxlite_cli(
      take.prepared.server,
      ["cp", take.box_id + ":" + guest_archive, destination],
      180000,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if copied.exit_code != 0 {
    return Err(
      native_boxlite_take_error(
        "copy-out failed: " + copied.output.trim().to_owned(),
      ),
    )
  }
  let archive = destination + "/choir-result.tar"
  let workspace = destination + "/workspace"
  match inspect_native_boxlite_result_archive(take.prepared.server, archive) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match
    @sandbox.validate_transfer_adoption_destination([
      {
        path: destination,
        kind: @sandbox.TransferDestinationKind::TransferDestinationDirectory,
      },
      {
        path: workspace,
        kind: @sandbox.TransferDestinationKind::TransferDestinationMissing,
      },
    ]) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if !@sys.create_dir_all(workspace) {
    return Err(native_boxlite_take_error("result workspace is unavailable"))
  }
  let extracted = @process.collect_output_merged(
    "/usr/bin/bwrap",
    [
      "--unshare-all", "--die-with-parent", "--new-session", "--clearenv", "--setenv",
      "PATH", "/usr/bin", "--ro-bind", "/usr", "/usr", "--symlink", "usr/lib", "/lib",
      "--symlink", "usr/lib", "/lib64", "--ro-bind", archive, "/input.tar", "--bind",
      workspace, "/output", "/usr/bin/tar", "--extract", "--file", "/input.tar",
      "--directory", "/output", "--no-same-owner", "--no-same-permissions",
    ],
    extra_env=native_boxlite_environment(take.prepared.server, false),
    inherit_env=false,
    cwd=take.prepared.server.config.root,
  ) catch {
    _ =>
      return Err(native_boxlite_take_error("confined result extraction failed"))
  }
  if extracted.0 != 0 {
    return Err(native_boxlite_take_error("confined result extraction failed"))
  }
  let writable = @process.collect_output_merged(
    "/usr/bin/chmod",
    ["-R", "u+rwX", "--", workspace],
    extra_env=native_boxlite_environment(take.prepared.server, false),
    inherit_env=false,
    cwd=take.prepared.server.config.root,
  ) catch {
    _ =>
      return Err(native_boxlite_take_error("result mode normalization failed"))
  }
  if writable.0 != 0 {
    return Err(native_boxlite_take_error("result mode normalization failed"))
  }
  let special = @process.collect_output_merged(
    "/usr/bin/find",
    [
      workspace, "-xdev", "!", "-type", "d", "!", "-type", "f", "!", "-type", "l",
      "-print", "-quit",
    ],
    extra_env=native_boxlite_environment(take.prepared.server, false),
    inherit_env=false,
    cwd=take.prepared.server.config.root,
  ) catch {
    _ => return Err(native_boxlite_take_error("result type scan failed"))
  }
  let special_output = special.1.text() catch {
    _ => return Err(native_boxlite_take_error("result type scan is not UTF-8"))
  }
  if special.0 != 0 || special_output != "" {
    return Err(native_boxlite_take_error("result contains a special file"))
  }
  let located = @process.collect_output_merged(
    "/usr/bin/find",
    [workspace, "-type", "f", "-name", ".choir-source-root", "-print"],
    extra_env=native_boxlite_environment(take.prepared.server, false),
    inherit_env=false,
    cwd=take.prepared.server.config.root,
  ) catch {
    _ => return Err(native_boxlite_take_error("result marker lookup failed"))
  }
  let output = located.1.text() catch {
    _ => return Err(native_boxlite_take_error("result marker is not UTF-8"))
  }
  let markers : Array[String] = []
  for line in output.split("\n") {
    let path = line.trim().to_owned()
    if path != "" {
      markers.push(path)
    }
  }
  if located.0 != 0 || markers.length() != 1 {
    return Err(native_boxlite_take_error("result marker is not unique"))
  }
  let marker = markers[0]
  if !marker.has_prefix(destination + "/") ||
    @sys.read_file(marker) != take.source_digest.0 + "\n" {
    return Err(native_boxlite_take_error("result marker is invalid"))
  }
  let suffix = "/.choir-source-root"
  if !marker.has_suffix(suffix) || marker.length() <= suffix.length() {
    return Err(native_boxlite_take_error("result root is invalid"))
  }
  adopted = true
  Ok(marker[:marker.length() - suffix.length()].to_owned())
}

///|
pub async fn destroy_native_boxlite_take(
  take : NativeBoxLiteTakeSandbox,
) -> Result[Unit, @types.ChoirError] {
  let removed = match
    capture_native_boxlite_cli(
      take.prepared.server,
      ["rm", "-f", take.box_id],
      60000,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if removed.exit_code == 0 {
    Ok(())
  } else {
    Err(native_boxlite_take_error("Take cleanup failed"))
  }
}

///|
test "native BoxLite Take body fixes isolation and resources" {
  let body = native_boxlite_create_body("take-box")
  assert_true(body.contains("\"mode\":\"disabled\""))
  assert_true(body.contains("\"cpus\":2"))
  assert_true(body.contains("\"memory_mib\":2048"))
  assert_true(body.contains(@sandbox.boxlite_take_image))
  assert_false(body.contains("volume"))
  assert_false(body.contains("rootfs_path"))
}

///|
test "native BoxLite MCP launch binds one fixed box" {
  let server : NativeBoxLiteServerHandle = {
    config: {
      binary: "/opt/boxlite",
      runtime_dir: "/opt/runtime",
      root: "/tmp/choir-take-test",
      port: 22000,
      api_key: "take-key",
    },
    pid: 10,
    url: "http://127.0.0.1:22000",
    owner_pid: 11,
    owner_socket: "/tmp/choir-take-test/owner.sock",
    owner_token: "a".repeat(64),
  }
  let prepared : NativeBoxLitePreparedEnvironment = {
    server,
    base_box_id: "base-1",
    image_digest: @sandbox.boxlite_take_image_digest,
    tool_manifest_digest: @sandbox.boxlite_take_tool_manifest_digest(),
    runtime_policy_digest: @sandbox.boxlite_take_runtime_policy_digest(),
  }
  let args = native_boxlite_take_mcp_arguments(
    {
      prepared,
      box_id: "box-1",
      source_digest: @control.Digest(
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      ),
      workspace_access: @sandbox.BoxLiteWorkspaceAccess::BoxLiteMutableWorkspace,
    },
    "/repo/scripts/choir_sandbox_mcp.mjs",
  ).unwrap()
  assert_true(args.contains("--box"))
  assert_true(args.contains("box-1"))
  assert_true(args.contains("--owner-socket"))
  assert_true(args.contains("--owner-token"))
  assert_true(
    args.contains(
      "4494355adc99b905a122f7753198715a048dfa99d69e943cfb588c691b909ed2",
    ),
  )
  assert_false(args.contains("--api-key"))
  assert_false(args.contains("--url"))
  assert_true(args.contains("--access"))
  assert_true(args.contains("mutable"))
  assert_false(args.contains("base-1"))
}

///|
test "native process dispatch binds the exact persisted specification digest" {
  let process : @sandbox.SandboxProcessSpec = {
    authority: @sandbox.SandboxProcessAuthority::SandboxVerificationTool(
      @control.TakeId("process-take"),
      @control.VerificationSpecId("process-spec"),
      @control.Digest("process-policy"),
    ),
    executable: @sandbox.SandboxExecutable::SandboxRegisteredTool(
      @sandbox.SandboxRegisteredToolId("moon"),
      @sandbox.boxlite_take_tool_manifest_digest(),
    ),
    arguments: ["test", "--target", "native"],
    working_directory: @sandbox.SandboxWorkingDirectory::SandboxWorkspaceRoot,
    environment: [{ key: "NO_COLOR", value: "1" }],
    stdin: @sandbox.SandboxStdinPolicy::SandboxStdinClosed,
    timeout_ms: 60000L,
    resources: {
      cpu_millis: 1000L,
      memory_bytes: 268435456L,
      process_count: 64,
      file_bytes: 1073741824L,
    },
    network: {
      profile: @sandbox.SandboxNetworkProfile::NetworkDisabled,
      version: 1L,
      policy_digest: @sandbox.boxlite_take_runtime_policy_digest(),
    },
    output: {
      stdout_limit_bytes: 1048576L,
      stderr_limit_bytes: 1048576L,
      on_limit: @sandbox.SandboxOutputLimitDisposition::SandboxTerminateAndMarkExceeded,
    },
  }
  let digest = @storage.artifact_digest(
    @utf8.encode(process.to_json().stringify(indent=0)),
  )
  assert_true(validate_native_persisted_process_spec(digest, process) is Ok(_))
  assert_true(
    validate_native_persisted_process_spec(
      @control.Digest(
        "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
      ),
      process,
    )
    is Err(_),
  )
}
