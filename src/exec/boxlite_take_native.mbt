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
} derive(Debug, Eq)

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
  let root_prefix = "/tmp/choir-v2-take-"
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
    server.config.root + "/client-home",
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
    !@sys.create_dir_all(config.root + "/client-home") ||
    !@sys.create_dir_all(config.root + "/staging") ||
    !@sys.create_dir_all(config.root + "/results") {
    return Err(native_boxlite_take_error("runtime directories are unavailable"))
  }
  if @sys.realpath_native(config.root) != Some(config.root) {
    return Err(native_boxlite_take_error("runtime root is not canonical"))
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
  let server : NativeBoxLiteServerHandle = { config, pid, url }
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
      return Ok(server)
    }
    @async.sleep(100)
  }
  @sys.kill_server_pid_sequence_best_effort(pid)
  Err(@types.ChoirError::timeout("BoxLite Take server readiness"))
}

///|
pub fn stop_native_boxlite_server(server : NativeBoxLiteServerHandle) -> Unit {
  @sys.kill_server_pid_sequence_best_effort(server.pid)
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
    Ok(())
  } else {
    Err(
      native_boxlite_take_error(
        "runtime cleanup failed: " + removed.output.trim().to_owned(),
      ),
    )
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
async fn normalize_native_boxlite_transfer(
  config : NativeBoxLiteServerConfig,
  box_id : String,
  destination : String,
  marker : String,
) -> Result[Unit, @types.ChoirError] {
  let script =
    #|set -eu
    #|marker=$(find "$1" -type f -name "$2" -print)
    #|test "$(printf '%s\n' "$marker" | sed '/^$/d' | wc -l)" -eq 1
    #|source_root=$(dirname "$marker")
    #|mkdir -p /root/choir-transfer
    #|cp -a "$source_root"/. /root/choir-transfer/
    #|rm -rf "$1"
    #|mkdir -p "$1"
    #|cp -a /root/choir-transfer/. "$1"/
    #|rm -rf /root/choir-transfer
  let capture = match
    capture_native_boxlite_local_cli(
      config,
      [
        "exec", box_id, "--", "/bin/sh", "-c", script, "choir-transfer", destination,
        marker,
      ],
      60000,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if capture.exit_code == 0 {
    Ok(())
  } else {
    Err(native_boxlite_take_error("transfer normalization failed"))
  }
}

///|
async fn copy_native_boxlite_input(
  config : NativeBoxLiteServerConfig,
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
  if !resolved_source.has_prefix(config.root + "/staging/") ||
    resolved_source != source ||
    !destination.has_prefix("/") ||
    destination.contains("/../") {
    return Err(
      @types.ChoirError::validation_error(
        "BoxLite transfer is outside its dedicated roots",
      ),
    )
  }
  let started = match
    capture_native_boxlite_local_cli(config, ["start", box_id], 60000) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if started.exit_code != 0 {
    return Err(
      native_boxlite_take_error(
        "local transfer start failed: " + started.output.trim().to_owned(),
      ),
    )
  }
  let copied = match
    capture_native_boxlite_local_cli(
      config,
      ["cp", source, box_id + ":" + destination],
      180000,
    ) {
    Ok(value) => value
    Err(error) => {
      ignore(capture_native_boxlite_local_cli(config, ["stop", box_id], 60000))
      return Err(error)
    }
  }
  if copied.exit_code != 0 {
    ignore(capture_native_boxlite_local_cli(config, ["stop", box_id], 60000))
    return Err(
      native_boxlite_take_error(
        "copy-in failed: " + copied.output.trim().to_owned(),
      ),
    )
  }
  let normalized = normalize_native_boxlite_transfer(
    config, box_id, destination, marker,
  )
  match normalized {
    Ok(_) => ()
    Err(error) => {
      ignore(capture_native_boxlite_local_cli(config, ["stop", box_id], 60000))
      return Err(error)
    }
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
  if !@sys.create_dir_all(toolchain) ||
    !@sys.write_file_sync(
      toolchain + "/.choir-toolchain-root",
      @sandbox.boxlite_take_tool_manifest_digest().0 + "\n",
    ) {
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
  stop_native_boxlite_server(server)
  @async.sleep(400)
  match
    copy_native_boxlite_input(
      server.config,
      base_box_id,
      toolchain,
      "/opt/moon",
      ".choir-toolchain-root",
    ) {
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
  stop_native_boxlite_server(prepared.server)
  @async.sleep(400)
  match
    copy_native_boxlite_input(
      prepared.server.config,
      box_id,
      source_directory,
      "/workspace",
      ".choir-source-root",
    ) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let checked = match
    capture_native_boxlite_local_cli(
      prepared.server.config,
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
  let local_stop = match
    capture_native_boxlite_local_cli(
      prepared.server.config,
      ["stop", box_id],
      60000,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if local_stop.exit_code != 0 {
    return Err(native_boxlite_take_error("Take isolation stop failed"))
  }
  let restarted = match start_native_boxlite_server(prepared.server.config) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let started = match
    capture_native_boxlite_http(
      restarted,
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
  Ok({ prepared: { ..prepared, server: restarted }, box_id, source_digest })
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
  Ok([
    script,
    "--binary",
    take.prepared.server.config.binary,
    "--runtime-dir",
    take.prepared.server.config.runtime_dir,
    "--url",
    take.prepared.server.url,
    "--api-key",
    take.prepared.server.config.api_key,
    "--home",
    take.prepared.server.config.root + "/client-home",
    "--box",
    take.box_id,
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
  let requests =
    #|{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
    #|{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}
    #|{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
    #|{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"read_file","arguments":{"path":"README.md"}}}
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
  if exit_code == 0 &&
    output.contains("\"name\":\"read_file\"") &&
    output.contains("sandbox fixture\\n") &&
    !output.contains(take.prepared.server.config.api_key) {
    Ok(output)
  } else {
    Err(native_boxlite_take_error("MCP probe contract failed"))
  }
}

///|
pub async fn copy_native_boxlite_take_result(
  take : NativeBoxLiteTakeSandbox,
) -> Result[String, @types.ChoirError] {
  let destination = take.prepared.server.config.root + "/results/" + take.box_id
  if !@sys.create_dir_all(destination) {
    return Err(native_boxlite_take_error("result root is unavailable"))
  }
  let copied = match
    capture_native_boxlite_cli(
      take.prepared.server,
      ["cp", "--include-parent=false", take.box_id + ":/workspace", destination],
      180000,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if copied.exit_code != 0 {
    Err(native_boxlite_take_error("copy-out failed"))
  } else {
    Ok(destination)
  }
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
      root: "/tmp/choir-v2-take-test",
      port: 22000,
      api_key: "take-key",
    },
    pid: 10,
    url: "http://127.0.0.1:22000",
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
    },
    "/repo/scripts/choir_sandbox_mcp.mjs",
  ).unwrap()
  assert_true(args.contains("--box"))
  assert_true(args.contains("box-1"))
  assert_true(args.contains("--api-key"))
  assert_false(args.contains("base-1"))
}
