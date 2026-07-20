///|
fn mcp_write_all_uds(fd : Int, data : Bytes) -> Bool {
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
fn mcp_response_line(response : @mcp.JsonRpcResponse) -> String {
  let body = response.to_json_string() + "\n"
  "Content-Length: " +
  @utf8.encode(body).length().to_string() +
  "\r\n\r\n" +
  body
}

///|
fn mcp_response_wire(
  response : @mcp.JsonRpcResponse,
  raw_stdio : Bool,
) -> String {
  if raw_stdio {
    response.to_json_string() + "\n"
  } else {
    mcp_response_line(response)
  }
}

///|
fn mcp_parse_content_length(line : String) -> Int? {
  let trimmed = line.trim().to_owned()
  let lower = trimmed.to_lower()
  let prefix = "content-length:"
  if !lower.has_prefix(prefix) {
    return None
  }
  Some(@string.parse_int(trimmed[prefix.length():].trim().to_owned())) catch {
    _ => None
  }
}

///|
fn mcp_read_next_message(
  read_line : () -> String?,
  read_exact : (Int) -> Bytes?,
) -> String? {
  let mut saw_headers = false
  let mut content_length : Int? = None
  for ;; {
    let line = match read_line() {
      Some(value) => value
      None => return None
    }
    let trimmed = line.trim().to_owned()
    if trimmed == "" {
      if !saw_headers {
        continue
      }
      match content_length {
        Some(length) =>
          match read_exact(length) {
            Some(body) => return Some(@utf8.decode_lossy(body))
            None => return None
          }
        None => continue
      }
    }
    match mcp_parse_content_length(trimmed) {
      Some(length) => {
        saw_headers = true
        content_length = Some(length)
      }
      None => if saw_headers { continue } else { return Some(trimmed) }
    }
  }
  None
}

///|
fn mcp_server_response(
  id : @mcp.JsonRpcId,
  response_line : String,
  raw_stdio : Bool,
) -> String {
  if response_line == "" {
    return mcp_response_wire(
      @mcp.error_response(id, @mcp.err_internal, "choird disconnected"),
      raw_stdio,
    )
  }
  match @transport.parse_response(response_line) {
    Ok(response) =>
      mcp_response_wire(@mcp.from_internal_response(id, response), raw_stdio)
    Err(error) =>
      mcp_response_wire(
        @mcp.error_response(
          id,
          @mcp.err_internal,
          "invalid choird response: " + error,
        ),
        raw_stdio,
      )
  }
}

///|
fn mcp_arg_value(args : Array[String], name : String) -> String? {
  let mut index = 0
  while index + 1 < args.length() {
    if args[index] == name {
      let value = args[index + 1]
      return if value == "" || value.has_prefix("--") {
        None
      } else {
        Some(value)
      }
    }
    index = index + 1
  }
  None
}

///|
fn mcp_has_arg(args : Array[String], name : String) -> Bool {
  args.contains(name)
}

///|
fn mcp_wait_tries(args : Array[String]) -> Int {
  match mcp_arg_value(args, "--wait-socket-tries") {
    Some(value) => {
      let parsed = Some(@string.parse_int(value)) catch { _ => None }
      match parsed {
        Some(count) => if count > 0 { count } else { 150 }
        None => 150
      }
    }
    None => 150
  }
}

///|
fn mcp_conductor_allows(name : String) -> Bool {
  @mcp.conductor_tool_names().contains(name)
}

///|
priv enum McpLoopExit {
  InputClosed
  Reconnect
  Stop(String)
}

///|
fn mcp_build_wire_request(request : @types.Request) -> String {
  @transport.format_request(request) + "\n"
}

///|
fn mcp_run_request_loop(
  read_input : () -> String?,
  send_wire_request : (String) -> Bool,
  read_server_line : () -> String,
  write_output : (String) -> Unit,
  raw_stdio : Bool,
) -> McpLoopExit {
  for ;; {
    let line = match read_input() {
      Some(value) => value
      None => return InputClosed
    }
    match @mcp.parse_jsonrpc_request(line) {
      Ok(rpc) => {
        let id = match rpc.id {
          Some(value) => value
          None => continue
        }
        if rpc.req_method == @mcp.method_initialize {
          write_output(
            mcp_response_wire(@mcp.initialize_response(id), raw_stdio),
          )
          continue
        }
        if rpc.req_method == @mcp.method_tools_list {
          write_output(
            mcp_response_wire(
              @mcp.tools_list_response_filtered(
                id,
                @types.Role::TL,
                @mcp.conductor_tool_names(),
              ),
              raw_stdio,
            ),
          )
          continue
        }
        match @mcp.to_internal_request(rpc, @types.Role::TL) {
          Ok(request) => {
            if !mcp_conductor_allows(request.name) {
              write_output(
                mcp_response_wire(
                  @mcp.error_response(
                    id, @mcp.err_method_not_found, "tool is outside the Conductor surface",
                  ),
                  raw_stdio,
                ),
              )
              continue
            }
            if !send_wire_request(mcp_build_wire_request(request)) {
              write_output(
                mcp_response_wire(
                  @mcp.error_response(
                    id, @mcp.err_internal, "choird disconnected; retry the tool call",
                  ),
                  raw_stdio,
                ),
              )
              return Reconnect
            }
            let response_line = read_server_line()
            if response_line == "" {
              write_output(
                mcp_response_wire(
                  @mcp.error_response(
                    id, @mcp.err_internal, "choird disconnected; retry the tool call",
                  ),
                  raw_stdio,
                ),
              )
              return Reconnect
            }
            write_output(mcp_server_response(id, response_line, raw_stdio))
          }
          Err(error) =>
            write_output(
              mcp_response_wire(
                @mcp.error_response(id, error.code, error.message),
                raw_stdio,
              ),
            )
        }
      }
      Err(error) =>
        write_output(
          mcp_response_wire(
            @mcp.error_response(Number(0), error.code, error.message),
            raw_stdio,
          ),
        )
    }
  }
  InputClosed
}

///|
fn mcp_register_conductor(
  fd : Int,
  reader : UDSLineReader,
  token : String,
) -> McpLoopExit? {
  let wire = @transport.format_conductor_registration_request(token) + "\n"
  if !mcp_write_all_uds(fd, @utf8.encode(wire)) {
    return Some(Reconnect)
  }
  let response_line = reader.read_line()
  if response_line == "" {
    return Some(Reconnect)
  }
  match @transport.parse_response(response_line) {
    Ok(response) =>
      if response.is_ok() {
        None
      } else {
        Some(Stop(response.error_message().unwrap_or("registration rejected")))
      }
    Err(error) => Some(Stop("invalid registration response: " + error))
  }
}

///|
fn mcp_run_uds_loop(fd : Int, token : String, raw_stdio : Bool) -> McpLoopExit {
  let reader = UDSLineReader::new(fd)
  match mcp_register_conductor(fd, reader, token) {
    Some(exit) => return exit
    None => ()
  }
  mcp_run_request_loop(
    fn() {
      mcp_read_next_message(fn() { @sys.read_stdin_line(8192) }, fn(size) {
        @sys.read_stdin_exact(size)
      })
    },
    fn(wire) { mcp_write_all_uds(fd, @utf8.encode(wire)) },
    fn() { reader.read_line() },
    fn(output) { @sys.write_stdout(output) },
    raw_stdio,
  )
}

///|
fn mcp_connect_uds(path : String, wait_tries : Int) -> Int {
  let mut fd = @uds.client_connect(path)
  if fd < 0 && @sys.wait_for_socket(path, wait_tries) {
    fd = @uds.client_connect(path)
  }
  fd
}

///|
fn mcp_required_environment(name : String) -> String {
  match @sys.getenv(name) {
    Some(value) =>
      if value.trim() != "" {
        value
      } else {
        @sys.write_stderr("choir mcp-stdio: missing " + name + "\n")
        @sys.exit(1)
        ""
      }
    None => {
      @sys.write_stderr("choir mcp-stdio: missing " + name + "\n")
      @sys.exit(1)
      ""
    }
  }
}

///|
fn mcp_run() -> Unit {
  ignore(@sys.ignore_sigpipe())
  ignore(@sys.set_parent_death_signal_term())
  let args = @env.args()
  match mcp_arg_value(args, "--stderr-append-log") {
    Some(path) => ignore(@sys.redirect_stderr_append(path))
    None => ()
  }
  let socket_path = mcp_required_environment("CHOIR_LISTEN_UDS")
  let token = mcp_required_environment("CHOIR_AGENT_TOKEN")
  let raw_stdio = mcp_has_arg(args, "--raw-stdio")
  let wait_tries = mcp_wait_tries(args)
  let mut fd = mcp_connect_uds(socket_path, wait_tries)
  if fd < 0 {
    @sys.write_stderr(
      "choir mcp-stdio: cannot connect to choird at " + socket_path + "\n",
    )
    @sys.exit(1)
    return
  }
  for ;; {
    let outcome = mcp_run_uds_loop(fd, token, raw_stdio)
    @uds.close(fd)
    match outcome {
      InputClosed => return
      Stop(error) => {
        @sys.write_stderr("choir mcp-stdio: " + error + "\n")
        @sys.exit(1)
        return
      }
      Reconnect => {
        fd = mcp_connect_uds(socket_path, wait_tries)
        if fd < 0 {
          @sys.write_stderr(
            "choir mcp-stdio: lost choird at " + socket_path + "\n",
          )
          @sys.exit(1)
          return
        }
      }
    }
  }
}

///|
test "Conductor MCP bridge exposes only current Goal and Beads tools" {
  assert_eq(@mcp.conductor_tool_names(), [
    "goal_submit", "goal_status", "goal_cancel", "goal_steer", "goal_attach", "goal_answer",
    "task_list", "task_get", "task_create", "task_update",
  ])
}

///|
test "Conductor MCP bridge forwards no caller identity" {
  let request : @types.Request = {
    req_method: "tools/call",
    role: @types.Role::TL,
    name: "goal_status",
    args: @types.RequestArgs::from_values({ "goal_id": "goal-a".to_json() }),
  }
  let wire = mcp_build_wire_request(request)
  assert_true(wire.contains("\"goal_id\":\"goal-a\""))
  assert_false(wire.contains("caller_id"))
  assert_false(wire.contains("sender_id"))
  assert_false(wire.contains("agent_id"))
}

///|
test "Conductor MCP bridge reads framed and line-delimited requests" {
  let body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}"
  let length = @utf8.encode(body).length()
  let lines = ["Content-Length: " + length.to_string(), ""]
  let mut index = 0
  let framed = mcp_read_next_message(
    fn() {
      if index < lines.length() {
        let value = lines[index]
        index = index + 1
        Some(value)
      } else {
        None
      }
    },
    fn(expected) {
      if expected == length {
        Some(@utf8.encode(body))
      } else {
        None
      }
    },
  )
  @debug.assert_eq(framed, Some(body))
  let mut exact_read = false
  let line = mcp_read_next_message(fn() { Some(body) }, fn(_) {
    exact_read = true
    None
  })
  @debug.assert_eq(line, Some(body))
  assert_false(exact_read)
}

///|
test "Conductor MCP request loop uses choird for tool execution" {
  let inputs = [
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}", "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"goal_status\",\"arguments\":{\"goal_id\":\"goal-a\"}}}",
  ]
  let outputs = []
  let requests = []
  let mut index = 0
  let outcome = mcp_run_request_loop(
    fn() {
      if index < inputs.length() {
        let value = inputs[index]
        index = index + 1
        Some(value)
      } else {
        None
      }
    },
    fn(wire) {
      requests.push(wire)
      true
    },
    fn() {
      @transport.format_response(
        @types.Response::ok_values({ "status": "running".to_json() }),
      )
    },
    fn(output) { outputs.push(output) },
    true,
  )
  match outcome {
    InputClosed => ()
    _ => fail("expected input close")
  }
  assert_eq(requests.length(), 1)
  assert_false(requests[0].contains("caller_id"))
  assert_eq(outputs.length(), 2)
  assert_true(outputs[0].contains("protocolVersion"))
  assert_true(outputs[1].contains("running"))
}
