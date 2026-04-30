///|
fn mcp_write_all_uds(fd : Int, data : Bytes) -> Bool {
  let mut written = 0
  while written < data.length() {
    let n = @uds.write_bytes(fd, data, written, data.length() - written)
    if n <= 0 {
      return false
    }
    written = written + n
  }
  true
}

///|
fn mcp_resolved_agent_id(
  role : @types.Role,
  config : @types.Config,
  local_cfg : @types.LocalConfig,
) -> String {
  match config.agent_id {
    Some(id) => id
    None =>
      match local_cfg.agent_id {
        Some(id) => id
        None =>
          "agent-" +
          @config.role_to_string(role) +
          "-" +
          @sys.get_pid().to_string()
      }
  }
}

///|
fn mcp_config_with_cli_overrides(
  base_config : @types.Config,
  local_cfg : @types.LocalConfig,
  args : Array[String],
) -> @types.Config {
  {
    ..base_config,
    agent_id: match local_cfg.agent_id {
      Some(agent_id) => Some(agent_id)
      None =>
        match mcp_cli_override_agent_id(args) {
          Some(agent_id) => Some(agent_id)
          None => base_config.agent_id
        }
    },
  }
}

///|
fn mcp_build_registration_message(
  role : @types.Role,
  config : @types.Config,
  local_cfg : @types.LocalConfig,
) -> String {
  let agent_id = mcp_resolved_agent_id(role, config, local_cfg)
  let registration_local_cfg = if local_cfg.terminal_target is None &&
    local_cfg.parent_id is None &&
    local_cfg.workspace is None &&
    role == @types.Role::TL {
    {
      ..local_cfg,
      terminal_target: Some(
        @workspace.local_target_for(
          config.terminal_session,
          "TL",
          @types.IsolationMode::Worktree,
        ),
      ),
    }
  } else {
    local_cfg
  }
  @transport.format_registration_request(role, agent_id, registration_local_cfg) +
  "\n"
}

///|
fn mcp_build_wire_request(
  internal_req : @types.Request,
  role : @types.Role,
  config : @types.Config,
  local_cfg : @types.LocalConfig,
) -> String {
  let agent_id = mcp_resolved_agent_id(role, config, local_cfg)
  @transport.format_augmented_request(internal_req, agent_id, local_cfg) + "\n"
}

///|
fn mcp_cli_override_role(args : Array[String]) -> @types.Role? {
  let mut i = 0
  while i < args.length() {
    if args[i] == "--role" && i + 1 < args.length() {
      return match @config.parse_role(args[i + 1]) {
        Ok(role) => Some(role)
        Err(_) => None
      }
    }
    i = i + 1
  }
  None
}

///|
fn mcp_cli_override_agent_id(args : Array[String]) -> String? {
  let mut i = 0
  while i < args.length() {
    if args[i] == "--name" && i + 1 < args.length() {
      let value = args[i + 1]
      if value == "" {
        return None
      }
      return Some(value)
    }
    i = i + 1
  }
  None
}

///|
fn mcp_response_line(resp : @mcp.JsonRpcResponse) -> String {
  let body = resp.to_json_string() + "\n"
  let body_len = @utf8.encode(body).length()
  "Content-Length: " + body_len.to_string() + "\r\n\r\n" + body
}

///|
fn mcp_response_wire(resp : @mcp.JsonRpcResponse, raw_stdio : Bool) -> String {
  if raw_stdio {
    resp.to_json_string() + "\n"
  } else {
    mcp_response_line(resp)
  }
}

///|
fn mcp_parse_content_length(line : String) -> Int? {
  let trimmed = line.trim().to_owned()
  let prefix = if trimmed.has_prefix("Content-Length:") {
    "Content-Length:"
  } else if trimmed.has_prefix("content-length:") {
    "content-length:"
  } else {
    return None
  }
  let value_str = trimmed[prefix.length():].trim().to_owned()
  Some(@string.parse_int(value_str)) catch {
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
      Some(line) => line
      None => return None
    }
    let trimmed = line.trim().to_owned()
    if trimmed == "" {
      if !saw_headers {
        continue
      }
      match content_length {
        Some(len) =>
          match read_exact(len) {
            Some(body) => return Some(@utf8.decode_lossy(body))
            None => return None
          }
        None => continue
      }
    }
    match mcp_parse_content_length(trimmed) {
      Some(len) => {
        saw_headers = true
        content_length = Some(len)
      }
      None => if saw_headers { continue } else { return Some(trimmed) }
    }
  }
  None
}

///|
fn mcp_server_response_line(
  id : @mcp.JsonRpcId,
  resp_line : String,
  raw_stdio : Bool,
) -> String {
  if resp_line == "" {
    return mcp_response_wire(
      @mcp.error_response(id, @mcp.err_internal, "server connection closed"),
      raw_stdio,
    )
  }

  match @transport.parse_response(resp_line) {
    Ok(internal_resp) =>
      mcp_response_wire(
        @mcp.from_internal_response(id, internal_resp),
        raw_stdio,
      )
    Err(e) =>
      mcp_response_wire(
        @mcp.error_response(
          id,
          @mcp.err_internal,
          "failed to parse server response: " + e,
        ),
        raw_stdio,
      )
  }
}

///|
fn mcp_write_server_response(
  id : @mcp.JsonRpcId,
  resp_line : String,
  raw_stdio : Bool,
) -> Unit {
  @sys.write_stdout(mcp_server_response_line(id, resp_line, raw_stdio))
}

///|
fn mcp_cli_raw_stdio(args : Array[String]) -> Bool {
  let mut i = 0
  while i < args.length() {
    if args[i] == "--raw-stdio" {
      return true
    }
    i = i + 1
  }
  false
}

///|
fn mcp_parse_decimal_u32(s : String) -> Int? {
  let n_opt = Some(@string.parse_int(s)) catch { _ => None }
  match n_opt {
    Some(n) => if n <= 0 { None } else { Some(n) }
    None => None
  }
}

///|
fn mcp_cli_positive_int_arg(args : Array[String], flag : String) -> Int? {
  let mut i = 0
  while i < args.length() {
    if args[i] == flag && i + 1 < args.length() {
      return mcp_parse_decimal_u32(args[i + 1])
    }
    i = i + 1
  }
  None
}

///|
fn mcp_cli_wait_socket_tries(args : Array[String]) -> Int {
  match mcp_cli_positive_int_arg(args, "--wait-socket-tries") {
    Some(n) => n
    None => 60
  }
}

///|
fn mcp_cli_stderr_append_log(args : Array[String]) -> String? {
  let mut i = 0
  while i < args.length() {
    if args[i] == "--stderr-append-log" && i + 1 < args.length() {
      let p = args[i + 1]
      if p != "" && !p.has_prefix("--") {
        return Some(p)
      }
      return None
    }
    i = i + 1
  }
  None
}

///|
priv enum McpUdsLoopExit {
  InputClosed
  Reconnect
}

///|
fn mcp_should_reconnect_after_uds_loop(exit : McpUdsLoopExit) -> Bool {
  match exit {
    InputClosed => false
    Reconnect => true
  }
}

///|
fn mcp_run_request_loop(
  read_input : () -> String?,
  send_wire_request : (String) -> Bool,
  read_server_line : () -> String,
  write_output : (String) -> Unit,
  raw_stdio : Bool,
  role : @types.Role,
  config : @types.Config,
  local_cfg : @types.LocalConfig,
) -> McpUdsLoopExit {
  for ;; {
    let line = match read_input() {
      Some(line) => line
      None => break
    }
    match @mcp.parse_jsonrpc_request(line) {
      Ok(rpc) => {
        let id = match rpc.id {
          Some(id) => id
          None => continue
        }
        if rpc.req_method == @mcp.method_initialize {
          write_output(
            mcp_response_wire(@mcp.initialize_response(id), raw_stdio),
          )
        } else if rpc.req_method == @mcp.method_tools_list {
          write_output(
            mcp_response_wire(@mcp.tools_list_response(id, role), raw_stdio),
          )
        } else {
          match
            @mcp.to_internal_request(
              rpc,
              role,
              default_caller_id=Some(
                mcp_resolved_agent_id(role, config, local_cfg),
              ),
            ) {
            Ok(internal_req) => {
              let wire_req = mcp_build_wire_request(
                internal_req, role, config, local_cfg,
              )
              if !send_wire_request(wire_req) {
                write_output(
                  mcp_response_wire(
                    @mcp.error_response(
                      id, @mcp.err_internal, "server restarting, retry",
                    ),
                    raw_stdio,
                  ),
                )
                return Reconnect
              }
              let resp_line = read_server_line()
              if resp_line == "" {
                write_output(
                  mcp_response_wire(
                    @mcp.error_response(
                      id, @mcp.err_internal, "server restarting, retry",
                    ),
                    raw_stdio,
                  ),
                )
                return Reconnect
              }
              write_output(mcp_server_response_line(id, resp_line, raw_stdio))
            }
            Err(e) =>
              write_output(
                mcp_response_wire(
                  @mcp.error_response(id, e.code, e.message),
                  raw_stdio,
                ),
              )
          }
        }
      }
      Err(e) =>
        write_output(
          mcp_response_wire(
            @mcp.error_response(Number(0), e.code, e.message),
            raw_stdio,
          ),
        )
    }
  }
  InputClosed
}

///|
fn mcp_run_uds_loop(
  uds_fd : Int,
  raw_stdio : Bool,
  role : @types.Role,
  config : @types.Config,
  local_cfg : @types.LocalConfig,
) -> McpUdsLoopExit {
  let reader = UDSLineReader::new(uds_fd)
  let reg_msg = mcp_build_registration_message(role, config, local_cfg)
  if !mcp_write_all_uds(uds_fd, @utf8.encode(reg_msg)) {
    return Reconnect
  }

  let reg_resp = reader.read_line()
  if reg_resp == "" {
    return Reconnect
  }

  mcp_run_request_loop(
    fn() {
      mcp_read_next_message(fn() { @sys.read_stdin_line(8192) }, fn(size) {
        @sys.read_stdin_exact(size)
      })
    },
    fn(wire_req) { mcp_write_all_uds(uds_fd, @utf8.encode(wire_req)) },
    fn() { reader.read_line() },
    fn(output) { @sys.write_stdout(output) },
    raw_stdio,
    role,
    config,
    local_cfg,
  )
}

///|
fn mcp_run() -> Unit {
  let args = @env.args()
  match mcp_cli_stderr_append_log(args) {
    Some(path) => ignore(@sys.redirect_stderr_append(path))
    None => ()
  }
  let wait_tries = mcp_cli_wait_socket_tries(args)
  let config_content = @sys.read_file(".choir/config.toml")
  let base_config = match @config.parse_config(config_content) {
    Ok(cfg) => cfg
    Err(_) => {
      println("error: failed to parse .choir/config.toml")
      @sys.exit(1)
      @types.Config::default()
    }
  }

  let local_content = @sys.read_file(".choir/config.local.toml")
  let local_cfg = tool_local_cfg_with_env_fallback(
    match @config.parse_local_config(local_content) {
      Ok(cfg) => cfg
      Err(_) => @types.LocalConfig::default()
    },
  )
  let config = mcp_config_with_cli_overrides(base_config, local_cfg, args)
  let raw_stdio = mcp_cli_raw_stdio(args)
  let role = match mcp_cli_override_role(args) {
    Some(role) => role
    None => @config.resolve_role(local_cfg.role, config)
  }

  let mut uds_fd = @uds.client_connect(config.listen_uds)
  if uds_fd < 0 {
    // Server may still be starting - wait for the UDS socket
    if @sys.wait_for_socket(config.listen_uds, wait_tries) {
      uds_fd = @uds.client_connect(config.listen_uds)
    }
  }
  if uds_fd >= 0 {
    // Run loop; on server restart, wait and reconnect automatically
    for ;; {
      let exit_reason = mcp_run_uds_loop(
        uds_fd, raw_stdio, role, config, local_cfg,
      )
      @uds.close(uds_fd)
      if !mcp_should_reconnect_after_uds_loop(exit_reason) {
        break
      }
      if !@sys.wait_for_socket(config.listen_uds, wait_tries) {
        break
      }
      uds_fd = @uds.client_connect(config.listen_uds)
      if uds_fd < 0 {
        break
      }
    }
    return
  }

  @async.run_async_main(async fn() {
    @async.with_task_group(async fn(_root) {
      let addr_str = match config.listen_tcp {
        Some(addr) => addr
        None => {
          println("error: listen_tcp not configured in .choir/config.toml")
          @sys.exit(1)
          ""
        }
      }

      let conn = @socket.Tcp::connect(@socket.Addr::parse(addr_str)) catch {
        err => {
          println("error: failed to connect to \{addr_str}: \{err}")
          @sys.exit(1)
          raise err
        }
      }

      let reader = TcpLineReader::new(conn)

      let reg_msg = mcp_build_registration_message(role, config, local_cfg)
      try {
        match config.tcp_auth_token {
          Some(token) => conn.write(@utf8.encode(token + "\n"))
          None => ()
        }
        conn.write(@utf8.encode(reg_msg))
        let _ = reader.read_line()
      } catch {
        err => {
          println("error: registration failed: \{err}")
          @sys.exit(1)
        }
      }

      for ;; {
        let line = match
          mcp_read_next_message(fn() { @sys.read_stdin_line(8192) }, fn(size) {
            @sys.read_stdin_exact(size)
          }) {
          Some(line) => line
          None => break
        }
        match @mcp.parse_jsonrpc_request(line) {
          Ok(rpc) => {
            let id = match rpc.id {
              Some(id) => id
              None => continue
            }
            if rpc.req_method == @mcp.method_initialize {
              let resp = @mcp.initialize_response(id)
              @sys.write_stdout(mcp_response_wire(resp, raw_stdio))
            } else if rpc.req_method == @mcp.method_tools_list {
              let resp = @mcp.tools_list_response(id, role)
              @sys.write_stdout(mcp_response_wire(resp, raw_stdio))
            } else {
              match @mcp.to_internal_request(rpc, role) {
                Ok(internal_req) => {
                  let wire_req = mcp_build_wire_request(
                    internal_req, role, config, local_cfg,
                  )

                  try {
                    conn.write(@utf8.encode(wire_req))
                    let resp_line = reader.read_line()
                    mcp_write_server_response(id, resp_line, raw_stdio)
                  } catch {
                    err => {
                      let err_resp = @mcp.error_response(
                        id,
                        @mcp.err_internal,
                        "TCP error: \{err}",
                      )
                      @sys.write_stdout(mcp_response_wire(err_resp, raw_stdio))
                    }
                  }
                }
                Err(e) => {
                  let err_resp = @mcp.error_response(id, e.code, e.message)
                  @sys.write_stdout(mcp_response_wire(err_resp, raw_stdio))
                }
              }
            }
          }
          Err(e) => {
            let err_resp = @mcp.error_response(Number(0), e.code, e.message)
            @sys.write_stdout(mcp_response_wire(err_resp, raw_stdio))
          }
        }
      }
      conn.close()
    })
  })
}

///|
test "mcp UDS reconnect policy stops after stdin EOF" {
  assert_false(mcp_should_reconnect_after_uds_loop(InputClosed))
  assert_true(mcp_should_reconnect_after_uds_loop(Reconnect))
}

///|
test "mcp config applies CLI agent id when local config is unset" {
  let cfg = mcp_config_with_cli_overrides(
    @types.Config::default(),
    @types.LocalConfig::default(),
    ["choir", "mcp-stdio", "--name", "smoke-test"],
  )
  @debug.assert_eq(cfg.agent_id, Some("smoke-test"))
  assert_eq(
    mcp_resolved_agent_id(@types.Role::TL, cfg, @types.LocalConfig::default()),
    "smoke-test",
  )
}

///|
test "mcp config keeps local agent id over CLI agent id" {
  let local_cfg = {
    ..@types.LocalConfig::default(),
    agent_id: Some("local-agent"),
  }
  let cfg = mcp_config_with_cli_overrides(@types.Config::default(), local_cfg, [
    "choir", "mcp-stdio", "--name", "cli-agent",
  ])
  @debug.assert_eq(cfg.agent_id, Some("local-agent"))
  assert_eq(
    mcp_resolved_agent_id(@types.Role::TL, cfg, local_cfg),
    "local-agent",
  )
}

///|
test "mcp registration infers zellij TL terminal target for top-level session" {
  let cfg = {
    ..@types.Config::default(),
    terminal_session: "choir-resorter-py",
  }
  let output = mcp_build_registration_message(
    @types.Role::TL,
    cfg,
    @types.LocalConfig::default(),
  )
  assert_true(output.contains("\"name\":\"register\""))
  assert_true(
    output.contains("\"terminal_target\":\"zellij-tab:choir-resorter-py:TL\""),
  )
}

///|
test "mcp framed reader parses Content-Length bodies without trailing newline" {
  let body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}"
  let body_len = @utf8.encode(body).length()
  let lines = ["Content-Length: " + body_len.to_string(), ""]
  let mut line_index = 0
  let msg = mcp_read_next_message(
    fn() {
      if line_index < lines.length() {
        let next = lines[line_index]
        line_index = line_index + 1
        Some(next)
      } else {
        None
      }
    },
    fn(size) { if size == body_len { Some(@utf8.encode(body)) } else { None } },
  )
  match msg {
    Some(line) => assert_eq(line, body)
    None => fail("expected framed MCP body")
  }
}

///|
test "mcp framed reader preserves raw line mode for newline-delimited JSON" {
  let mut used_exact = false
  let msg = mcp_read_next_message(
    fn() {
      Some(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}",
      )
    },
    fn(_) {
      used_exact = true
      None
    },
  )
  match msg {
    Some(line) =>
      assert_eq(
        line, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}",
      )
    None => fail("expected raw MCP line")
  }
  assert_false(used_exact)
}

///|
test "mcp request loop returns InputClosed after successful task call" {
  let requests = [
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}", "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"task_create\",\"arguments\":{\"id\":\"loop-task\",\"title\":\"Loop Task\"}}}",
  ]
  let outputs = []
  let wire_requests = []
  let mut input_index = 0
  let mut server_reads = 0
  let exit = mcp_run_request_loop(
    fn() {
      if input_index < requests.length() {
        let next = requests[input_index]
        input_index = input_index + 1
        Some(next)
      } else {
        None
      }
    },
    fn(wire_req) {
      wire_requests.push(wire_req)
      true
    },
    fn() {
      server_reads = server_reads + 1
      @transport.format_response(
        @types.Response::ok_values({
          "status": "ok".to_json(),
          "task": {
            "id": "loop-task".to_json(),
            "title": "Loop Task".to_json(),
            "status": "todo".to_json(),
            "assignee": "".to_json(),
            "notes": "".to_json(),
          }.to_json(),
        }),
      )
    },
    fn(output) { outputs.push(output) },
    false,
    @types.Role::TL,
    { ..@types.Config::default(), agent_id: Some("smoke-loop") },
    @types.LocalConfig::default(),
  )
  match exit {
    InputClosed => ()
    Reconnect => fail("expected InputClosed")
  }
  assert_eq(wire_requests.length(), 1)
  assert_true(wire_requests[0].contains("\"caller_id\":\"smoke-loop\""))
  assert_eq(server_reads, 1)
  assert_eq(outputs.length(), 2)
  assert_true(outputs[0].contains("\"protocolVersion\":\"2024-11-05\""))
  assert_true(outputs[1].contains("loop-task"))
}

///|
test "mcp request loop returns Reconnect on wire write failure" {
  let outputs = []
  let mut server_reads = 0
  let exit = mcp_run_request_loop(
    fn() {
      Some(
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"task_create\",\"arguments\":{\"id\":\"retry-task\",\"title\":\"Retry Task\"}}}",
      )
    },
    fn(_) { false },
    fn() {
      server_reads = server_reads + 1
      ""
    },
    fn(output) { outputs.push(output) },
    false,
    @types.Role::TL,
    @types.Config::default(),
    @types.LocalConfig::default(),
  )
  match exit {
    Reconnect => ()
    InputClosed => fail("expected Reconnect")
  }
  assert_eq(server_reads, 0)
  assert_eq(outputs.length(), 1)
  assert_true(outputs[0].contains("server restarting, retry"))
}

///|
test "mcp request loop returns Reconnect on empty server response" {
  let outputs = []
  let mut server_reads = 0
  let exit = mcp_run_request_loop(
    fn() {
      Some(
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"task_create\",\"arguments\":{\"id\":\"retry-task-2\",\"title\":\"Retry Task 2\"}}}",
      )
    },
    fn(_) { true },
    fn() {
      server_reads = server_reads + 1
      ""
    },
    fn(output) { outputs.push(output) },
    false,
    @types.Role::TL,
    @types.Config::default(),
    @types.LocalConfig::default(),
  )
  match exit {
    Reconnect => ()
    InputClosed => fail("expected Reconnect")
  }
  assert_eq(server_reads, 1)
  assert_eq(outputs.length(), 1)
  assert_true(outputs[0].contains("server restarting, retry"))
}
