///|
fn start_usage() -> String {
  "usage: choir start [--lean]"
}

///|
priv struct StartOptions {
  lean : Bool
} derive(Debug, Eq)

///|
fn start_parse_options(args : Array[String]) -> Result[StartOptions, String] {
  let mut lean = false
  let mut index = 2
  while index < args.length() {
    match args[index] {
      "--lean" => {
        lean = true
        index = index + 1
      }
      _ => return Err(start_usage())
    }
  }
  Ok({ lean, })
}

///|
fn start_root_bootstrap_request(token : String) -> @types.Request {
  {
    req_method: "root_bootstrap",
    role: @types.Role::TL,
    name: "root_bootstrap",
    args: @types.RequestArgs::from_values({ "token": token.to_json() }),
  }
}

///|
fn start_bootstrap_root(
  socket_path : String,
  token : String,
) -> Result[Unit, String] {
  let fd = @uds.client_connect(socket_path)
  if fd < 0 {
    return Err("cannot connect to choird at " + socket_path)
  }
  let request = @transport.format_request(start_root_bootstrap_request(token)) +
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
    Ok(config) => Ok(config)
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
) -> @workspace.ConductorProcessEnvironment {
  {
    agent_token: token,
    agent_id: "root",
    role: @types.Role::TL,
    workspace: config.project_dir,
    listen_uds: config.listen_uds,
    session_id: "root",
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
  let token = match @sys.mint_local_token() {
    Some(value) => value
    None => {
      @sys.write_stderr("choir start: failed to mint Conductor credential\n")
      @sys.exit(1)
      return
    }
  }
  match start_ensure_daemon(config.listen_uds, self_executable) {
    Ok(_) => ()
    Err(error) => {
      @sys.write_stderr("choir start: " + error + "\n")
      @sys.exit(1)
      return
    }
  }
  match start_bootstrap_root(config.listen_uds, token) {
    Ok(_) => ()
    Err(error) => {
      @sys.write_stderr("choir start: " + error + "\n")
      @sys.exit(1)
      return
    }
  }
  @async.run_async_main(async fn() {
    let command = @workspace.conductor_launch_command(
      @types.AgentType::Claude,
      config.project_dir,
      lean=options.lean,
    )
    let exit_code = @exec.run_conductor_process(
      command,
      start_conductor_environment(config, token),
    ) catch {
      _ => -1
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
test "start accepts only the Claude Conductor launch options" {
  assert_eq(start_parse_options(["choir", "start"]).unwrap(), StartOptions::{
    lean: false,
  })
  assert_eq(start_parse_options(["choir", "start", "--lean"]).unwrap(), StartOptions::{
    lean: true,
  })
  assert_true(start_parse_options(["choir", "start", "--conductor"]) is Err(_))
  assert_true(start_parse_options(["choir", "start", "--unknown"]) is Err(_))
}

///|
test "start root bootstrap request contains no provider credential" {
  let token = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
  let request = start_root_bootstrap_request(token)
  assert_eq(request.req_method, "root_bootstrap")
  assert_eq(request.name, "root_bootstrap")
  assert_eq(request.role, @types.Role::TL)
  @debug.assert_eq(request.args.get("token"), Some(token))
}
