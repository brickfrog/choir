///|
priv struct ConductorServerState {
  config : @types.Config
  run_id : String
  mut root_token : String?
}

///|
fn ConductorServerState::new(config : @types.Config) -> ConductorServerState {
  { config, run_id: "serve-" + @sys.get_pid().to_string(), root_token: None }
}

///|
priv struct ConductorClient {
  fd : Int
  peer_is_choir : Bool
  mut buffer : FixedArray[Byte]
  mut used : Int
  mut authenticated : Bool
  mut busy : Bool
  mut close_after_response : Bool
}

///|
fn ConductorClient::new(fd : Int) -> ConductorClient {
  {
    fd,
    peer_is_choir: conductor_peer_is_choir(fd),
    buffer: FixedArray::make(4096, (0 : Byte)),
    used: 0,
    authenticated: false,
    busy: false,
    close_after_response: false,
  }
}

///|
let conductor_root_id : String = "root"

///|
let conductor_bootstrap_method : String = "root_bootstrap"

///|
fn conductor_peer_is_choir(fd : Int) -> Bool {
  if fd < 0 || !@uds.peer_is_current_user(fd) {
    return false
  }
  let pid = @uds.peer_pid(fd)
  if pid <= 1 {
    return false
  }
  match
    (
      @sys.realpath_native("/proc/" + pid.to_string() + "/exe"),
      @sys.realpath_native("/proc/self/exe"),
    ) {
    (Some(peer), Some(server)) => peer == server
    _ => false
  }
}

///|
fn conductor_valid_bootstrap_token(token : String) -> Bool {
  if token.length() != 64 {
    return false
  }
  for index = 0; index < token.length(); index = index + 1 {
    let unit = token.code_unit_at(index)
    if !((unit >= 48 && unit <= 57) || (unit >= 97 && unit <= 102)) {
      return false
    }
  }
  true
}

///|
fn conductor_tokens_equal(presented : String, stored : String) -> Bool {
  let mut different = if presented.length() == stored.length() { 0 } else { 1 }
  for index = 0; index < stored.length(); index = index + 1 {
    let presented_unit = if index < presented.length() {
      presented.code_unit_at(index)
    } else {
      0
    }
    if presented_unit != stored.code_unit_at(index) {
      different = 1
    }
  }
  different == 0
}

///|
fn conductor_bootstrap(
  state : ConductorServerState,
  request : @types.Request,
  peer_is_choir : Bool,
) -> @types.Response {
  if request.req_method != conductor_bootstrap_method ||
    request.name != conductor_bootstrap_method ||
    request.role != @types.Role::TL ||
    !peer_is_choir {
    return @types.Response::Err("Conductor bootstrap authentication failed")
  }
  let token = request.args.get(@types.registration_token_arg).unwrap_or("")
  if !conductor_valid_bootstrap_token(token) {
    return @types.Response::Err("Conductor bootstrap authentication failed")
  }
  state.root_token = Some(token)
  @types.Response::ok_values({ "agent_id": conductor_root_id.to_json() })
}

///|
fn conductor_register(
  state : ConductorServerState,
  request : @types.Request,
) -> @types.Response {
  let agent_id = request.args.get("agent_id").unwrap_or("")
  let presented = request.registration_token().unwrap_or("")
  if request.req_method != "register" ||
    agent_id != conductor_root_id ||
    request.role != @types.Role::TL ||
    presented == "" {
    return @types.Response::Err("Conductor registration authentication failed")
  }
  let stored = match state.root_token {
    Some(token) => token
    None =>
      return @types.Response::Err(
        "Conductor credential not provisioned; run `choir start`",
      )
  }
  if !conductor_tokens_equal(presented, stored) {
    return @types.Response::Err("Conductor registration authentication failed")
  }
  @types.Response::ok_values({ "agent_id": conductor_root_id.to_json() })
}

///|
fn conductor_authenticated_request(request : @types.Request) -> @types.Request {
  let arguments : Map[String, Json] = Map([])
  request.args.each_json(fn(name, value) {
    if name != "caller_id" && name != "agent_id" && name != "sender_id" {
      arguments.set(name, value)
    }
  })
  arguments.set("caller_id", conductor_root_id.to_json())
  {
    ..request,
    req_method: "tools/call",
    role: @types.Role::TL,
    args: @types.RequestArgs::from_values(arguments),
  }
}

///|
async fn conductor_dispatch(
  state : ConductorServerState,
  request : @types.Request,
) -> @types.Response {
  @exec.dispatch_native_conductor_request(
    state.config.project_dir,
    conductor_authenticated_request(request),
  ) catch {
    error => {
      @moontrace.error("Conductor adapter error", fields=[
        @moontrace.field("request", request.name),
        @moontrace.field("error", error.to_string()),
      ])
      @types.Response::Err("internal error: " + error.to_string())
    }
  }
}

///|
fn conductor_write_all(fd : Int, data : Bytes) -> Bool {
  let mut written = 0
  while written < data.length() {
    let count = @uds.write_bytes(fd, data, written, data.length() - written)
    if count <= 0 {
      return false
    }
    written = written + count
  }
  true
}

///|
fn conductor_send_response(fd : Int, response : @types.Response) -> Bool {
  conductor_write_all(
    fd,
    @utf8.encode(@transport.format_response(response) + "\n"),
  )
}

///|
async fn conductor_handle_custom_line(
  client : ConductorClient,
  state : ConductorServerState,
  request : @types.Request,
) -> Unit {
  if request.req_method == conductor_bootstrap_method {
    ignore(
      conductor_send_response(
        client.fd,
        conductor_bootstrap(state, request, client.peer_is_choir),
      ),
    )
    client.close_after_response = true
    client.busy = false
    return
  }
  if request.req_method == "register" {
    let response = conductor_register(state, request)
    if response.is_ok() {
      client.authenticated = true
    } else {
      client.close_after_response = true
    }
    ignore(conductor_send_response(client.fd, response))
    client.busy = false
    return
  }
  let response = if client.authenticated {
    conductor_dispatch(state, request)
  } else {
    @types.Response::Err("authenticated Conductor required")
  }
  ignore(conductor_send_response(client.fd, response))
  client.busy = false
}

///|
fn conductor_jsonrpc_line(response : @mcp.JsonRpcResponse) -> String {
  response.to_json_string() + "\n"
}

///|
async fn conductor_handle_jsonrpc_line(
  client : ConductorClient,
  state : ConductorServerState,
  line : String,
) -> Unit {
  let response = match @mcp.parse_jsonrpc_request(line) {
    Ok(rpc) => {
      let id = rpc.id.unwrap_or(Number(0))
      if rpc.req_method == @mcp.method_initialize {
        @mcp.initialize_response(id)
      } else if rpc.req_method == @mcp.method_tools_list {
        if client.authenticated {
          @mcp.tools_list_response(id, @types.Role::TL)
        } else {
          @mcp.tools_list_response(id, @types.Role::Worker)
        }
      } else {
        match @mcp.to_internal_request(rpc, @types.Role::TL) {
          Ok(request) => {
            let internal = if client.authenticated {
              conductor_dispatch(state, request)
            } else {
              @types.Response::Err("authenticated Conductor required")
            }
            @mcp.from_internal_response(id, internal)
          }
          Err(error) => @mcp.error_response(id, error.code, error.message)
        }
      }
    }
    Err(error) => @mcp.error_response(Number(0), error.code, error.message)
  }
  ignore(
    conductor_write_all(
      client.fd,
      @utf8.encode(conductor_jsonrpc_line(response)),
    ),
  )
  client.busy = false
}

///|
fn conductor_slice(source : FixedArray[Byte], length : Int) -> String {
  let bytes = Array::make(length, (0 : Byte))
  for index = 0; index < length; index = index + 1 {
    bytes[index] = source[index]
  }
  @utf8.decode_lossy(Bytes::from_array(bytes[:]))
}

///|
fn conductor_grow_buffer(source : FixedArray[Byte]) -> FixedArray[Byte] {
  let grown = FixedArray::make(source.length() * 2, (0 : Byte))
  for index = 0; index < source.length(); index = index + 1 {
    grown[index] = source[index]
  }
  grown
}

///|
fn conductor_consume_line(client : ConductorClient, newline : Int) -> String {
  let line = conductor_slice(client.buffer, newline)
  let remaining = client.used - newline - 1
  for index = 0; index < remaining; index = index + 1 {
    client.buffer[index] = client.buffer[newline + 1 + index]
  }
  client.used = remaining
  line
}

///|
fn conductor_poll_client(
  client : ConductorClient,
  state : ConductorServerState,
  spawn_request : (async () -> Unit) -> Unit,
) -> Bool {
  if client.close_after_response {
    return false
  }
  if client.busy {
    return true
  }
  for ;; {
    if client.used == client.buffer.length() {
      client.buffer = conductor_grow_buffer(client.buffer)
    }
    let count = @uds.read_bytes_nonblocking(
      client.fd,
      client.buffer,
      client.used,
      client.buffer.length() - client.used,
    )
    if count == -2 {
      return true
    }
    if count <= 0 {
      return false
    }
    client.used = client.used + count
    let mut newline = 0
    while newline < client.used && client.buffer[newline] != (10 : Byte) {
      newline = newline + 1
    }
    if newline == client.used {
      continue
    }
    let line = conductor_consume_line(client, newline)
    client.busy = true
    if @transport.is_jsonrpc_request(line) {
      spawn_request(async fn() {
        conductor_handle_jsonrpc_line(client, state, line)
      })
    } else {
      match @transport.parse_request(line) {
        Ok(request) =>
          spawn_request(async fn() {
            conductor_handle_custom_line(client, state, request)
          })
        Err(error) => {
          ignore(
            conductor_send_response(
              client.fd,
              @types.Response::Err("parse error: " + error),
            ),
          )
          client.busy = false
        }
      }
    }
    return true
  }
  true
}

///|
async fn conductor_serve_uds(
  state : ConductorServerState,
  root : @async.TaskGroup[Unit],
) -> Unit {
  let server_fd = @uds.server_create(state.config.listen_uds)
  if server_fd < 0 {
    @moontrace.error("failed to bind UDS server", fields=[
      @moontrace.field("path", state.config.listen_uds),
    ])
    return
  }
  ignore(@uds.set_nonblocking(server_fd))
  @moontrace.info("UDS server listening", fields=[
    @moontrace.field("path", state.config.listen_uds),
  ])
  let clients : Array[ConductorClient] = []
  for ;; {
    for ;; {
      let client_fd = @uds.accept_nonblocking(server_fd)
      if client_fd == -2 {
        break
      }
      if client_fd < 0 {
        @uds.close(server_fd)
        return
      }
      ignore(@uds.set_nonblocking(client_fd))
      clients.push(ConductorClient::new(client_fd))
    }
    let mut index = 0
    while index < clients.length() {
      if conductor_poll_client(clients[index], state, fn(task) {
          root.spawn_bg(task)
        }) {
        index = index + 1
      } else {
        let client = clients.remove(index)
        @uds.close(client.fd)
      }
    }
    @async.sleep(10)
  }
}

///|
async fn conductor_goal_loop(project_dir : String) -> Unit {
  for ;; {
    match @exec.run_native_goal_execution_tick(project_dir) {
      Ok(@workflow.GoalExecutionTickResult::GoalExecutionTickIdle) => ()
      Ok(@workflow.GoalExecutionTickResult::GoalExecutionTickAdvanced(record)) =>
        @moontrace.info("Goal execution advanced", fields=[
          @moontrace.field("goal_id", record.goal.id.0),
          @moontrace.field("state", record.state.to_json().stringify(indent=0)),
        ])
      Err(error) =>
        @moontrace.error("Goal execution tick failed", fields=[
          @moontrace.field("error", error.message()),
        ])
    }
    @async.sleep(1000)
  }
}

///|
fn serve_run() -> Unit {
  let config_content = @sys.read_file(".choir/config.toml")
  let local_content = @sys.read_file(".choir/config.local.toml")
  let config = match
    @config.parse_config(config_content, local_content=Some(local_content)) {
    Ok(value) => value
    Err(error) => {
      @sys.write_stderr("choir serve: " + error.message() + "\n")
      @sys.exit(1)
      return
    }
  }
  ignore(@sys.create_dir_all(config.project_dir + "/.choir/logs"))
  ignore(@sys.create_dir_all(config.project_dir + "/.choir/run"))
  ignore(@sys.create_dir_all(config.project_dir + "/.choir/state"))
  ignore(@sys.create_dir_all(config.project_dir + "/.choir/state/control"))
  @sys.init_cleanup_runtime_artifacts_native()
  @sys.write_pid_file(".choir/run/server.pid")
  @sys.register_cleanup_runtime_artifacts()
  @sys.install_crash_handlers()
  let state = ConductorServerState::new(config)
  @moontrace.set_global_field("service", "choir".to_json())
  @moontrace.set_global_field("run_id", state.run_id.to_json())
  let log_path = config.project_dir + "/.choir/logs/serve.log"
  @moontrace.set_subscriber(fn(event) {
    let rendered = @exec.strip_terminal_responses(event.format(color=false))
    ignore(@sys.append_file_sync(log_path, rendered + "\n"))
  })
  @moontrace.set_min_level(@moontrace.Level::Debug)
  @async.run_async_main(async fn() {
    @async.with_task_group(async fn(root) {
      root.spawn_bg(async fn() { conductor_goal_loop(config.project_dir) })
      conductor_serve_uds(state, root)
    })
  })
}

///|
test "Conductor tokens require an exact lowercase hexadecimal capability" {
  let token = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
  assert_true(conductor_valid_bootstrap_token(token))
  assert_false(conductor_valid_bootstrap_token(token + "0"))
  assert_false(conductor_valid_bootstrap_token(token.replace(old="a", new="A")))
  assert_true(conductor_tokens_equal(token, token))
  assert_false(conductor_tokens_equal(token, token + "0"))
}

///|
test "Conductor strips caller identity before dispatch" {
  let request : @types.Request = {
    req_method: "tools/call",
    role: @types.Role::Worker,
    name: "goal_status",
    args: @types.RequestArgs::from_values({
      "goal_id": "goal-a".to_json(),
      "caller_id": "forged".to_json(),
      "agent_id": "forged".to_json(),
    }),
  }
  let effective = conductor_authenticated_request(request)
  assert_eq(effective.role, @types.Role::TL)
  @debug.assert_eq(effective.args.get("caller_id"), Some("root"))
  @debug.assert_eq(effective.args.get("agent_id"), None)
  @debug.assert_eq(effective.args.get("goal_id"), Some("goal-a"))
}
