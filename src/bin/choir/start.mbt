///|
fn start_usage() -> String {
  "usage: choir start [--lean] [--conductor <claude|codex>]"
}

///|
fn start_resolve_executable(
  self_executable : String,
  resolve : (String) -> String?,
) -> String? {
  match resolve("/proc/self/exe") {
    Some(path) => Some(path)
    None => resolve(self_executable)
  }
}

///|
test "start resolves the running executable before a PATH command name" {
  assert_eq(
    start_resolve_executable("choir", fn(path) {
      if path == "/proc/self/exe" {
        Some("/opt/choir/versions/current/choir")
      } else {
        None
      }
    }),
    Some("/opt/choir/versions/current/choir"),
  )
  assert_eq(
    start_resolve_executable("/opt/choir", fn(path) {
      if path == "/opt/choir" {
        Some(path)
      } else {
        None
      }
    }),
    Some("/opt/choir"),
  )
}

///|
fn native_resolve_launch_config(
  config : @types.Config,
  resolve : (String) -> String?,
) -> Result[@types.Config, String] {
  let project_dir = match resolve(config.project_dir) {
    Some(path) if path.has_prefix("/") => path
    _ => return Err("failed to resolve the project directory")
  }
  let listen_uds = if config.listen_uds.has_prefix("/") {
    config.listen_uds
  } else if project_dir == "/" {
    "/" + config.listen_uds
  } else {
    project_dir + "/" + config.listen_uds
  }
  Ok({ project_dir, listen_uds })
}

///|
test "native launch config gives the Goal worker absolute project and socket paths" {
  assert_eq(
    native_resolve_launch_config(
      { project_dir: ".", listen_uds: ".choir/run/server.sock" },
      fn(path) { if path == "." { Some("/work/repo") } else { None } },
    ),
    Ok({
      project_dir: "/work/repo",
      listen_uds: "/work/repo/.choir/run/server.sock",
    }),
  )
  assert_eq(
    native_resolve_launch_config(
      { project_dir: "/work/repo", listen_uds: "/tmp/choir.sock" },
      fn(path) { Some(path) },
    ),
    Ok({ project_dir: "/work/repo", listen_uds: "/tmp/choir.sock" }),
  )
}

///|
priv enum StartConductorSurface {
  StartClaudeConductor
  StartCodexConductor
} derive(Debug, Eq)

///|
priv struct StartOptions {
  lean : Bool
  conductor : StartConductorSurface
} derive(Debug, Eq)

///|
fn start_parse_options(args : Array[String]) -> Result[StartOptions, String] {
  let mut lean = false
  let mut conductor = StartClaudeConductor
  let mut index = 2
  while index < args.length() {
    match args[index] {
      "--lean" => {
        lean = true
        index = index + 1
      }
      "--conductor" if index + 1 < args.length() => {
        conductor = match args[index + 1] {
          "claude" => StartClaudeConductor
          "codex" => StartCodexConductor
          _ => return Err(start_usage())
        }
        index = index + 2
      }
      _ => return Err(start_usage())
    }
  }
  if lean && conductor == StartCodexConductor {
    Err(start_usage())
  } else {
    Ok({ lean, conductor })
  }
}

///|
fn start_conductor_bootstrap_request(token : String) -> @types.Request {
  {
    req_method: "conductor_bootstrap",
    name: "conductor_bootstrap",
    args: @types.RequestArgs::from_values({ "token": token.to_json() }),
  }
}

///|
fn start_bootstrap_conductor(
  socket_path : String,
  token : String,
) -> Result[Unit, String] {
  let fd = @uds.client_connect(socket_path)
  if fd < 0 {
    return Err("cannot connect to choird at " + socket_path)
  }
  let request = @transport.format_request(
      start_conductor_bootstrap_request(token),
    ) +
    "\n"
  if !mcp_write_all_uds(fd, @utf8.encode(request)) {
    @uds.close(fd)
    return Err("failed to send Conductor bootstrap")
  }
  let response_line = UDSLineReader::new(fd).read_line()
  @uds.close(fd)
  if response_line == "" {
    return Err("choird closed the Conductor bootstrap connection")
  }
  match @transport.parse_response(response_line) {
    Ok(response) =>
      if response.is_ok() {
        Ok(())
      } else {
        Err(response.error_message().unwrap_or("Conductor bootstrap failed"))
      }
    Err(error) => Err("invalid Conductor bootstrap response: " + error)
  }
}

///|
fn start_config() -> Result[@types.Config, String] {
  let config_content = @sys.read_file(".choir/config.toml")
  if config_content == "" {
    return Err("missing .choir/config.toml; run `choir init` first")
  }
  let local_content = @sys.read_file(".choir/config.local.toml")
  match
    @config.parse_config(config_content, local_content=Some(local_content)) {
    Ok(config) => native_resolve_launch_config(config, @sys.realpath_native)
    Err(error) => Err(error.message())
  }
}

///|
fn start_ensure_daemon(
  socket_path : String,
  self_executable : String,
) -> Result[Unit, String] {
  let existing = @uds.client_connect(socket_path)
  if existing >= 0 {
    @uds.close(existing)
    return Ok(())
  }
  if !@sys.spawn_serve(self_executable) {
    return Err("failed to start choird")
  }
  if !@sys.wait_for_socket(socket_path, 100) {
    return Err("choird did not become ready at " + socket_path)
  }
  Ok(())
}

///|
fn start_conductor_environment(
  config : @types.Config,
  token : String,
) -> @exec.ConductorProcessEnvironment {
  {
    conductor_token: token,
    workspace: config.project_dir,
    listen_uds: config.listen_uds,
  }
}

///|
async fn start_codex_conductor(
  config : @types.Config,
  token : String,
  executable : String,
) -> Int {
  let conductor_config : @exec.NativeCodexConductorConfig = {
    sterile_root: config.project_dir + "/.choir/run/codex-conductor",
    mcp_executable: executable,
    mcp_arguments: [
      "mcp-stdio",
      "--name",
      "root",
      "--raw-stdio",
      "--inherit-parent-environment",
      "--stderr-append-log",
      config.project_dir + "/.choir/logs/codex-mcp.stderr.log",
    ],
    mcp_server_name: "choir",
    allowed_tools: @mcp.conductor_tool_names(),
    developer_instructions: @prompts.load_goal_prompt(config.project_dir),
    timeout_ms: 3600000,
    environment: start_conductor_environment(config, token),
  }
  let mut thread_id : String? = None
  @sys.write_stdout(
    "Codex Conductor ready. Describe a Goal, ask for status, or enter /exit.\n",
  )
  for ;; {
    @sys.write_stdout("choir> ")
    let prompt = match @sys.read_stdin_line(65536) {
      Some(value) => value.trim().to_owned()
      None => return 0
    }
    if prompt == "" {
      continue
    }
    if prompt == "/exit" || prompt == "/quit" {
      return 0
    }
    match
      @exec.run_native_codex_conductor_turn(
        conductor_config,
        prompt,
        thread_id~,
      ) {
      Ok(turn) => {
        thread_id = Some(turn.thread_id)
        @sys.write_stdout(turn.response + "\n")
      }
      Err(error) =>
        @sys.write_stderr("Codex Conductor: " + error.message() + "\n")
    }
  }
}

///|
fn start_with_options(options : StartOptions, self_executable : String) -> Unit {
  let config = match start_config() {
    Ok(value) => value
    Err(error) => {
      @sys.write_stderr("choir start: " + error + "\n")
      @sys.exit(1)
      return
    }
  }
  ignore(@sys.create_dir_all(config.project_dir + "/.choir/logs"))
  ignore(@sys.create_dir_all(config.project_dir + "/.choir/run"))
  ignore(@sys.create_dir_all(config.project_dir + "/.choir/state"))
  ignore(@sys.create_dir_all(config.project_dir + "/.choir/state/control"))
  match init_materialize_conductor_files(config.project_dir) {
    Ok(_) => ()
    Err(error) => {
      @sys.write_stderr("choir start: " + error + "\n")
      @sys.exit(1)
      return
    }
  }
  let executable = match
    start_resolve_executable(self_executable, @sys.realpath_native) {
    Some(value) => value
    None => {
      @sys.write_stderr("choir start: failed to resolve the Choir executable\n")
      @sys.exit(1)
      return
    }
  }
  match @exec.validate_native_goal_runtime() {
    Ok(_) => ()
    Err(error) => {
      @sys.write_stderr("choir start: " + error.message() + "\n")
      @sys.exit(1)
      return
    }
  }
  let token = match @sys.mint_local_token() {
    Some(value) => value
    None => {
      @sys.write_stderr("choir start: failed to mint Conductor credential\n")
      @sys.exit(1)
      return
    }
  }
  match start_ensure_daemon(config.listen_uds, executable) {
    Ok(_) => ()
    Err(error) => {
      @sys.write_stderr("choir start: " + error + "\n")
      @sys.exit(1)
      return
    }
  }
  match start_bootstrap_conductor(config.listen_uds, token) {
    Ok(_) => ()
    Err(error) => {
      @sys.write_stderr("choir start: " + error + "\n")
      @sys.exit(1)
      return
    }
  }
  @async.run_async_main(async fn() {
    match @exec.validate_native_beads_cli() {
      Ok(_) => ()
      Err(error) => {
        @sys.write_stderr("choir start: " + error.message() + "\n")
        @sys.exit(1)
        return
      }
    }
    let exit_code = match options.conductor {
      StartClaudeConductor => {
        let command = @exec.conductor_launch_command(
          config.project_dir,
          executable,
          lean=options.lean,
        )
        @exec.run_conductor_process(
          command,
          start_conductor_environment(config, token),
        ) catch {
          _ => -1
        }
      }
      StartCodexConductor => start_codex_conductor(config, token, executable)
    }
    @sys.exit(exit_code)
  })
}

///|
fn start_run() -> Unit {
  let args = @env.args()
  let options = match start_parse_options(args) {
    Ok(value) => value
    Err(error) => {
      @sys.write_stderr(error + "\n")
      @sys.exit(2)
      return
    }
  }
  start_with_options(options, if args.length() > 0 { args[0] } else { "choir" })
}

///|
test "start selects only supported Conductor surfaces" {
  assert_eq(start_parse_options(["choir", "start"]).unwrap(), StartOptions::{
    lean: false,
    conductor: StartClaudeConductor,
  })
  assert_eq(start_parse_options(["choir", "start", "--lean"]).unwrap(), StartOptions::{
    lean: true,
    conductor: StartClaudeConductor,
  })
  assert_eq(
    start_parse_options(["choir", "start", "--conductor", "codex"]).unwrap(),
    StartOptions::{ lean: false, conductor: StartCodexConductor },
  )
  assert_true(
    start_parse_options(["choir", "start", "--lean", "--conductor", "codex"])
    is Err(_),
  )
  assert_true(start_parse_options(["choir", "start", "--conductor"]) is Err(_))
  assert_true(start_parse_options(["choir", "start", "--unknown"]) is Err(_))
}

///|
test "start Conductor bootstrap request contains no provider credential" {
  let token = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
  let request = start_conductor_bootstrap_request(token)
  assert_eq(request.req_method, "conductor_bootstrap")
  assert_eq(request.name, "conductor_bootstrap")
  @debug.assert_eq(request.args.get("token"), Some(token))
}
