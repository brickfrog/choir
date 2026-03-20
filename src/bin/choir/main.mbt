///|
fn serve_fixed_array_slice_to_string(
  buf : FixedArray[Byte],
  start : Int,
  len : Int,
) -> String {
  let line_buf = Array::make(len, (0 : Byte))
  for i = 0; i < len; i = i + 1 {
    line_buf[i] = buf[start + i]
  }
  @utf8.decode_lossy(Bytes::from_array(line_buf[:]))
}

///|
fn grow_connection_buffer(buf : FixedArray[Byte]) -> FixedArray[Byte] {
  let next = FixedArray::make(buf.length() * 2, (0 : Byte))
  for i = 0; i < buf.length(); i = i + 1 {
    next[i] = buf[i]
  }
  next
}

///|
struct ServeUDSClient {
  fd : Int
  mut buf : FixedArray[Byte]
  mut read_pos : Int
  mut connected_agent_id : String?
}

///|
fn ServeUDSClient::new(fd : Int) -> ServeUDSClient {
  {
    fd,
    buf: FixedArray::make(4096, (0 : Byte)),
    read_pos: 0,
    connected_agent_id: None,
  }
}

///|
async fn serve_handle_connection(
  conn : @socket.TCP,
  state : @server.ServerState,
) -> Unit {
  let mut buf = FixedArray::make(4096, (0 : Byte))
  let mut read_pos = 0
  let mut authenticated = match state.config.tcp_auth_token {
    None => true
    Some(_) => false
  }
  let mut connected_agent_id : String? = None
  for {
    if read_pos == buf.length() {
      buf = grow_connection_buffer(buf)
    }
    let n = conn.read(buf, offset=read_pos, max_len=buf.length() - read_pos)
    if n == 0 {
      break
    }
    read_pos = read_pos + n
    let mut i = 0
    while i < read_pos {
      if buf[i] == (10 : Byte) {
        let line = serve_fixed_array_slice_to_string(buf, 0, i)
        let remaining = read_pos - (i + 1)
        if remaining > 0 {
          for j = 0; j < remaining; j = j + 1 {
            buf[j] = buf[i + 1 + j]
          }
        }
        read_pos = remaining
        i = 0
        if not(authenticated) {
          match state.config.tcp_auth_token {
            Some(token) =>
              if line == token {
                authenticated = true
              } else {
                return
              }
            None => authenticated = true
          }
          continue
        }
        let req_res = @transport.parse_request(line)
        match req_res {
          Ok(req) => {
            if req.req_method == "register" {
              connected_agent_id = req.args.get("agent_id")
            }
            let resp = state.handle(req)
            let resp_str = @transport.format_response(resp) + "\n"
            conn.write(@utf8.encode(resp_str))
          }
          Err(err) => {
            let resp = @types.Response::Err("parse error: " + err)
            conn.write(@utf8.encode(@transport.format_response(resp) + "\n"))
          }
        }
      } else {
        i = i + 1
      }
    }
  }
  match connected_agent_id {
    Some(agent_id) => state.handle_disconnect(agent_id)
    None => ()
  }
}

///|
fn serve_write_all_uds(fd : Int, data : Bytes) -> Unit {
  let mut written = 0
  @io.write_stderr(
    "[choir serve] writing UDS response bytes=" +
    data.length().to_string() +
    "\n",
  )
  while written < data.length() {
    let n = @uds.write_bytes(fd, data, written, data.length() - written)
    if n <= 0 {
      @io.write_stderr(
        "[choir serve] UDS write failed after " +
        written.to_string() +
        " bytes\n",
      )
      break
    }
    written = written + n
  }
  @io.write_stderr(
    "[choir serve] UDS write complete bytes=" + written.to_string() + "\n",
  )
}

///|
async fn serve_handle_uds_connection(
  client : ServeUDSClient,
  state : @server.ServerState,
) -> Bool {
  for {
    if client.read_pos == client.buf.length() {
      client.buf = grow_connection_buffer(client.buf)
    }
    let n = @uds.read_bytes_nonblocking(
      client.fd,
      client.buf,
      client.read_pos,
      client.buf.length() - client.read_pos,
    )
    if n == -2 {
      return true
    }
    if n <= 0 {
      return false
    }
    client.read_pos = client.read_pos + n
    let mut i = 0
    while i < client.read_pos {
      if client.buf[i] == (10 : Byte) {
        let line = serve_fixed_array_slice_to_string(client.buf, 0, i)
        let req_res = @transport.parse_request(line)
        match req_res {
          Ok(req) => {
            if req.req_method == "register" {
              client.connected_agent_id = req.args.get("agent_id")
            }
            let resp = state.handle(req)
            let resp_str = @transport.format_response(resp) + "\n"
            @io.write_stderr("[choir serve] request: " + line + "\n")
            @io.write_stderr("[choir serve] response: " + resp_str)
            serve_write_all_uds(client.fd, @utf8.encode(resp_str))
          }
          Err(err) => {
            let resp = @types.Response::Err("parse error: " + err)
            @io.write_stderr(
              "[choir serve] parse error for line: " + line + "\n",
            )
            serve_write_all_uds(
              client.fd,
              @utf8.encode(@transport.format_response(resp) + "\n"),
            )
          }
        }
        let remaining = client.read_pos - (i + 1)
        if remaining > 0 {
          for j = 0; j < remaining; j = j + 1 {
            client.buf[j] = client.buf[i + 1 + j]
          }
        }
        client.read_pos = remaining
        i = 0
      } else {
        i = i + 1
      }
    }
  }
  true
}

///|
async fn serve_close_uds_client(
  client : ServeUDSClient,
  state : @server.ServerState,
) -> Unit {
  @uds.close(client.fd)
  match client.connected_agent_id {
    Some(agent_id) => state.handle_disconnect(agent_id)
    None => ()
  }
}

///|
fn serve_run() -> Unit raise {
  let config_content = @io.read_file(".choir/config.toml")
  let config = match @config.parse_config(config_content) {
    Ok(cfg) => cfg
    Err(_) => @types.Config::default()
  }
  @io.write_pid_file(".choir/server.pid")
  let state = @server.ServerState::new(config)
  @async.with_event_loop(async fn(root) {
    @server.recover_state(state, config.tmux_session)
    root.spawn_bg(async fn() {
      let timeout_sec = 900L
      let interval_ms = 30000
      for {
        @async.sleep(interval_ms)
        let pending_events = []
        let pending_agent_ids = []
        let now = @poller.now_sec()
        state.poller.tick(now, timeout_sec, fn(event, agent_id) {
          pending_events.push(event)
          pending_agent_ids.push(agent_id)
        })
        for i = 0; i < pending_events.length(); i = i + 1 {
          let event = pending_events[i]
          let agent_id = pending_agent_ids[i]
          match state.plan_poll_event_delivery(event, agent_id) {
            Some(delivery) =>
              ignore(@tools.execute_delivery(delivery, @exec.run_sequence))
            None => ()
          }
        }
      }
    })
    root.spawn_bg(async fn() {
      let server_fd = @uds.server_create(config.listen_uds)
      if server_fd < 0 {
        println("failed to bind UDS server on \{config.listen_uds}")
        return
      }
      ignore(@uds.set_nonblocking(server_fd))
      println("UDS server listening on \{config.listen_uds}")
      let clients : Array[ServeUDSClient] = []
      for {
        for {
          let client_fd = @uds.accept_nonblocking(server_fd)
          if client_fd == -2 {
            break
          }
          if client_fd < 0 {
            @uds.close(server_fd)
            return
          }
          ignore(@uds.set_nonblocking(client_fd))
          clients.push(ServeUDSClient::new(client_fd))
        }
        let mut i = 0
        while i < clients.length() {
          let alive = serve_handle_uds_connection(clients[i], state) catch {
            _ => false
          }
          if alive {
            i = i + 1
          } else {
            let client = clients.remove(i)
            serve_close_uds_client(client, state) catch {
              _ => ()
            }
          }
        }
        @async.sleep(10)
      }
    })
    match config.listen_tcp {
      Some(addr_str) => {
        let server = @socket.TCPServer::new(@socket.Addr::parse(addr_str))
        try {
          println("TCP server listening on \{addr_str}")
          for {
            let (conn, addr) = server.accept()
            println("connection from \{addr}")
            root.spawn_bg(async fn() {
              serve_handle_connection(conn, state) catch {
                _ => ()
              }
              conn.close()
            })
          }
        } catch {
          err => {
            server.close()
            raise err
          }
        }
      }
      None => println("no listen_tcp configured")
    }
  })
}

///|
struct TCPLineReader {
  conn : @socket.TCP
  mut buf : FixedArray[Byte]
  mut read_pos : Int
  mut write_pos : Int
}

///|
fn TCPLineReader::new(conn : @socket.TCP) -> TCPLineReader {
  { conn, buf: FixedArray::make(8192, (0 : Byte)), read_pos: 0, write_pos: 0 }
}

///|
struct UDSLineReader {
  fd : Int
  mut buf : FixedArray[Byte]
  mut read_pos : Int
  mut write_pos : Int
}

///|
fn UDSLineReader::new(fd : Int) -> UDSLineReader {
  { fd, buf: FixedArray::make(8192, (0 : Byte)), read_pos: 0, write_pos: 0 }
}

///|
fn grow_line_buffer(buf : FixedArray[Byte]) -> FixedArray[Byte] {
  let next = FixedArray::make(buf.length() * 2, (0 : Byte))
  for i = 0; i < buf.length(); i = i + 1 {
    next[i] = buf[i]
  }
  next
}

///|
async fn TCPLineReader::read_line(self : TCPLineReader) -> String {
  for {
    let bytes = self.buf.unsafe_reinterpret_as_bytes()
    for i = self.read_pos; i < self.write_pos; i = i + 1 {
      if bytes[i] == (10 : Byte) {
        let line = @utf8.decode_lossy(bytes[self.read_pos:i])
        self.read_pos = i + 1
        return line
      }
    }

    if self.read_pos > 0 {
      let remaining = self.write_pos - self.read_pos
      if remaining > 0 {
        for i = 0; i < remaining; i = i + 1 {
          self.buf[i] = self.buf[self.read_pos + i]
        }
      }
      self.write_pos = remaining
      self.read_pos = 0
    }

    if self.write_pos == self.buf.length() {
      self.buf = grow_line_buffer(self.buf)
    }

    let n = self.conn.read(
      self.buf,
      offset=self.write_pos,
      max_len=self.buf.length() - self.write_pos,
    )
    if n == 0 {
      if self.write_pos > self.read_pos {
        let line = @utf8.decode_lossy(bytes[self.read_pos:self.write_pos])
        self.read_pos = self.write_pos
        return line
      }
      return ""
    }
    self.write_pos = self.write_pos + n
  }
}

///|
fn UDSLineReader::read_line(self : UDSLineReader) -> String {
  for {
    let bytes = self.buf.unsafe_reinterpret_as_bytes()
    for i = self.read_pos; i < self.write_pos; i = i + 1 {
      if bytes[i] == (10 : Byte) {
        let line = @utf8.decode_lossy(bytes[self.read_pos:i])
        self.read_pos = i + 1
        return line
      }
    }

    if self.read_pos > 0 {
      let remaining = self.write_pos - self.read_pos
      if remaining > 0 {
        for i = 0; i < remaining; i = i + 1 {
          self.buf[i] = self.buf[self.read_pos + i]
        }
      }
      self.write_pos = remaining
      self.read_pos = 0
    }

    if self.write_pos == self.buf.length() {
      self.buf = grow_line_buffer(self.buf)
    }

    let n = @uds.read_bytes(
      self.fd,
      self.buf,
      self.write_pos,
      self.buf.length() - self.write_pos,
    )
    if n <= 0 {
      if self.write_pos > self.read_pos {
        let line = @utf8.decode_lossy(bytes[self.read_pos:self.write_pos])
        self.read_pos = self.write_pos
        return line
      }
      return ""
    }
    self.write_pos = self.write_pos + n
  }
}

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
          @io.get_pid().to_string()
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
  @transport.format_registration_request(role, agent_id, local_cfg) + "\n"
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
  resp.to_json_string() + "\n"
}

///|
fn mcp_server_response_line(id : @mcp.JsonRpcId, resp_line : String) -> String {
  if resp_line == "" {
    return mcp_response_line(
      @mcp.error_response(id, @mcp.err_internal, "server connection closed"),
    )
  }

  match @transport.parse_response(resp_line) {
    Ok(internal_resp) =>
      mcp_response_line(@mcp.from_internal_response(id, internal_resp))
    Err(e) =>
      mcp_response_line(
        @mcp.error_response(
          id,
          @mcp.err_internal,
          "failed to parse server response: " + e,
        ),
      )
  }
}

///|
fn mcp_write_server_response(id : @mcp.JsonRpcId, resp_line : String) -> Unit {
  @io.write_stdout(mcp_server_response_line(id, resp_line))
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
  role : @types.Role,
  config : @types.Config,
  local_cfg : @types.LocalConfig,
) -> McpUdsLoopExit {
  for {
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
          write_output(mcp_response_line(@mcp.initialize_response(id)))
        } else if rpc.req_method == @mcp.method_tools_list {
          write_output(mcp_response_line(@mcp.tools_list_response(id)))
        } else {
          match @mcp.to_internal_request(rpc, role) {
            Ok(internal_req) => {
              let wire_req = mcp_build_wire_request(
                internal_req, role, config, local_cfg,
              )
              if not(send_wire_request(wire_req)) {
                write_output(
                  mcp_response_line(
                    @mcp.error_response(
                      id, @mcp.err_internal, "server restarting, retry",
                    ),
                  ),
                )
                return Reconnect
              }
              let resp_line = read_server_line()
              if resp_line == "" {
                write_output(
                  mcp_response_line(
                    @mcp.error_response(
                      id, @mcp.err_internal, "server restarting, retry",
                    ),
                  ),
                )
                return Reconnect
              }
              write_output(mcp_server_response_line(id, resp_line))
            }
            Err(e) =>
              write_output(
                mcp_response_line(@mcp.error_response(id, e.code, e.message)),
              )
          }
        }
      }
      Err(e) =>
        write_output(
          mcp_response_line(@mcp.error_response(Number(0), e.code, e.message)),
        )
    }
  }
  InputClosed
}

///|
fn mcp_run_uds_loop(
  uds_fd : Int,
  role : @types.Role,
  config : @types.Config,
  local_cfg : @types.LocalConfig,
) -> McpUdsLoopExit {
  let reader = UDSLineReader::new(uds_fd)
  let reg_msg = mcp_build_registration_message(role, config, local_cfg)
  if not(mcp_write_all_uds(uds_fd, @utf8.encode(reg_msg))) {
    return Reconnect
  }

  let reg_resp = reader.read_line()
  if reg_resp == "" {
    return Reconnect
  }

  mcp_run_request_loop(
    fn() { @io.read_stdin_line(8192) },
    fn(wire_req) { mcp_write_all_uds(uds_fd, @utf8.encode(wire_req)) },
    fn() { reader.read_line() },
    fn(output) { @io.write_stdout(output) },
    role,
    config,
    local_cfg,
  )
}

///|
fn mcp_run() -> Unit raise {
  let args = @io.get_args()
  let config_content = @io.read_file(".choir/config.toml")
  let base_config = match @config.parse_config(config_content) {
    Ok(cfg) => cfg
    Err(_) => {
      println("error: failed to parse .choir/config.toml")
      @io.exit(1)
      @types.Config::default()
    }
  }

  let local_content = @io.read_file(".choir/config.local.toml")
  let local_cfg = match @config.parse_local_config(local_content) {
    Ok(cfg) => cfg
    Err(_) => @types.LocalConfig::default()
  }
  let config = mcp_config_with_cli_overrides(base_config, local_cfg, args)
  let role = match mcp_cli_override_role(args) {
    Some(role) => role
    None => @config.resolve_role(local_cfg.role, config)
  }

  let mut uds_fd = @uds.client_connect(config.listen_uds)
  if uds_fd >= 0 {
    // Run loop; on server restart, wait and reconnect automatically
    for {
      let exit_reason = mcp_run_uds_loop(uds_fd, role, config, local_cfg)
      @uds.close(uds_fd)
      if not(mcp_should_reconnect_after_uds_loop(exit_reason)) {
        break
      }
      if not(@io.wait_for_socket(config.listen_uds, 60)) {
        break
      }
      uds_fd = @uds.client_connect(config.listen_uds)
      if uds_fd < 0 {
        break
      }
    }
    return
  }

  @async.with_event_loop(async fn(_root) {
    let addr_str = match config.listen_tcp {
      Some(addr) => addr
      None => {
        println("error: listen_tcp not configured in .choir/config.toml")
        @io.exit(1)
        ""
      }
    }

    let conn = @socket.TCP::connect(@socket.Addr::parse(addr_str)) catch {
      err => {
        println("error: failed to connect to \{addr_str}: \{err}")
        @io.exit(1)
        raise err
      }
    }

    let reader = TCPLineReader::new(conn)

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
        @io.exit(1)
      }
    }

    for {
      let line = match @io.read_stdin_line(8192) {
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
            @io.write_stdout_bytes(@mcp.response_to_bytes(resp))
          } else if rpc.req_method == @mcp.method_tools_list {
            let resp = @mcp.tools_list_response(id)
            @io.write_stdout_bytes(@mcp.response_to_bytes(resp))
          } else {
            match @mcp.to_internal_request(rpc, role) {
              Ok(internal_req) => {
                let wire_req = mcp_build_wire_request(
                  internal_req, role, config, local_cfg,
                )

                try {
                  conn.write(@utf8.encode(wire_req))
                  let resp_line = reader.read_line()
                  mcp_write_server_response(id, resp_line)
                } catch {
                  err => {
                    let err_resp = @mcp.error_response(
                      id,
                      @mcp.err_internal,
                      "TCP error: \{err}",
                    )
                    @io.write_stdout_bytes(@mcp.response_to_bytes(err_resp))
                  }
                }
              }
              Err(e) => {
                let err_resp = @mcp.error_response(id, e.code, e.message)
                @io.write_stdout_bytes(@mcp.response_to_bytes(err_resp))
              }
            }
          }
        }
        Err(e) => {
          let err_resp = @mcp.error_response(Number(0), e.code, e.message)
          @io.write_stdout_bytes(@mcp.response_to_bytes(err_resp))
        }
      }
    }
    conn.close()
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
  assert_eq(cfg.agent_id, Some("smoke-test"))
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
  assert_eq(cfg.agent_id, Some("local-agent"))
  assert_eq(
    mcp_resolved_agent_id(@types.Role::TL, cfg, local_cfg),
    "local-agent",
  )
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
          "status": @types.wire_string("ok"),
          "task": @types.wire_raw(
            "{\"id\":\"loop-task\",\"title\":\"Loop Task\",\"status\":\"todo\",\"assignee\":\"\",\"notes\":\"\"}",
          ),
        }),
      )
    },
    fn(output) { outputs.push(output) },
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

///|
fn hook_agent_id(input : @hooks.HookInput) -> String? {
  match input.agent_id {
    Some(agent_id) => Some(agent_id)
    None =>
      match @io.getenv("CHOIR_AGENT_ID") {
        Some(agent_id) => Some(agent_id)
        None => @io.getenv("EXOMONAD_AGENT_ID")
      }
  }
}

///|
fn persist_hook_session(input : @hooks.HookInput) -> Unit {
  match input.event {
    @hooks.HookEvent::SessionStart =>
      match (input.session_id, hook_agent_id(input)) {
        (Some(session_id), Some(agent_id)) =>
          ignore(
            @io.write_file_sync(
              ".choir/sessions/claude/" + agent_id + ".session_id",
              session_id,
            ),
          )
        _ => ()
      }
    _ => ()
  }
}

///|
fn hook_run() -> Unit raise {
  @async.with_event_loop(_ => {
    let line = match @io.read_stdin_line(8192) {
      Some(line) => line
      None => {
        @io.write_stdout(
          @hooks.HookResponse::fail_open().to_json_string() + "\n",
        )
        return
      }
    }
    let input = match @hooks.HookInput::from_json_string(line) {
      Some(i) => i
      None => {
        @io.write_stdout(
          @hooks.HookResponse::fail_open().to_json_string() + "\n",
        )
        return
      }
    }
    persist_hook_session(input)

    let config_content = @io.read_file(".choir/config.toml")

    let hook_key = match input.event {
      @hooks.HookEvent::SessionStart => "hook.session_start"
      @hooks.HookEvent::PreToolUse => "hook.pre_tool_use"
    }

    match @config.hook_command_path(config_content, hook_key) {
      None =>
        @io.write_stdout(@hooks.HookResponse::allow().to_json_string() + "\n")
      Some(cmd_path) => {
        let cmd = @workspace.Command::{
          program: cmd_path,
          args: [],
          workdir: None,
        }
        let exit_code = @exec.run(cmd) catch { _ => 1 }
        if exit_code == 0 {
          @io.write_stdout(@hooks.HookResponse::allow().to_json_string() + "\n")
        } else {
          @io.write_stdout(
            @hooks.HookResponse::block("blocked").to_json_string() + "\n",
          )
        }
      }
    }
  })
}

///|
fn init_config_toml_content() -> String {
  "default_role = \"tl\"\n" +
  "project_dir = \".\"\n" +
  "listen_uds = \".choir/server.sock\"\n"
}

///|
fn init_mcp_json_content(project_dir : String) -> String {
  "{\n" +
  "  \"mcpServers\": {\n" +
  "    \"choir\": {\n" +
  "      \"type\": \"stdio\",\n" +
  "      \"command\": \"sh\",\n" +
  "      \"args\": [\"-lc\", \"exec choir mcp-stdio --name root 2>> .choir/mcp-stdio.stderr.log\"],\n" +
  "      \"cwd\": \"" +
  project_dir +
  "\"\n" +
  "    }\n" +
  "  }\n" +
  "}\n"
}

///|

///|
fn init_escape_shell_single_quoted(s : String) -> String {
  let buf = StringBuilder::new()
  for c in s {
    if c == '\'' {
      buf.write_string("'\\''")
    } else {
      buf.write_char(c)
    }
  }
  buf.to_string()
}

///|
fn choir_escape_json_string(s : String) -> String {
  let buf = StringBuilder::new()
  for c in s {
    match c {
      '"' => buf.write_string("\\\"")
      '\\' => buf.write_string("\\\\")
      '\n' => buf.write_string("\\n")
      '\r' => buf.write_string("\\r")
      '\t' => buf.write_string("\\t")
      _ => buf.write_char(c)
    }
  }
  buf.to_string()
}

///|
async fn init_run_or_exit(cmd : @workspace.Command) -> Unit {
  let exit_code = @exec.run(cmd) catch { _ => 1 }
  if exit_code != 0 {
    @io.exit(exit_code)
  }
}

///|
fn init_run() -> Unit raise {
  @async.with_event_loop(async fn(_root) {
    let args = @io.get_args()
    let recreate = args.contains("--recreate")
    let project_dir = @io.getcwd()

    // Rebuild binary before doing anything else so the new server uses fresh code
    init_run_or_exit({
      program: "moon",
      args: ["build", "--target", "native", "--release"],
      workdir: None,
    })

    init_run_or_exit({
      program: "sh",
      args: ["-c", "mkdir -p .choir"],
      workdir: None,
    })
    init_run_or_exit({
      program: "sh",
      args: [
        "-c",
        "test -f .choir/config.toml || printf '%s' \"$1\" > .choir/config.toml",
        "sh",
        init_config_toml_content(),
      ],
      workdir: None,
    })
    init_run_or_exit({
      program: "sh",
      args: [
        "-c",
        "printf '%s' \"$1\" > .mcp.json",
        "sh",
        init_mcp_json_content(project_dir),
      ],
      workdir: None,
    })

    let config_content = @io.read_file(".choir/config.toml")
    let config = match @config.parse_config(config_content) {
      Ok(cfg) => cfg
      Err(_) => @types.Config::default()
    }
    let session = config.tmux_session

    if recreate {
      let pid_str = @io.read_file(".choir/server.pid")
      if pid_str != "" {
        @io.write_stdout("Stopping server (PID \{pid_str})...\n")
        ignore(
          @exec.run({
            program: "sh",
            args: [
              "-c", "kill -TERM \"$1\" 2>/dev/null; sleep 0.3; kill -KILL \"$1\" 2>/dev/null; true",
              "sh", pid_str,
            ],
            workdir: None,
          }) catch {
            _ => 0
          },
        )
        ignore(
          @exec.run({
            program: "sh",
            args: ["-c", "rm -f .choir/server.pid .choir/server.sock"],
            workdir: None,
          }) catch {
            _ => 0
          },
        )
      }
      let has_session = @exec.run({
        program: "sh",
        args: ["-c", "tmux has-session -t \"$1\" 2>/dev/null", "sh", session],
        workdir: None,
      }) catch {
        _ => 1
      }
      if has_session == 0 {
        @io.write_stdout("Killing session \{session}...\n")
        ignore(
          @exec.run({
            program: "tmux",
            args: ["kill-session", "-t", session],
            workdir: None,
          }) catch {
            _ => 0
          },
        )
      }
    }

    let session_alive = @exec.run({
      program: "sh",
      args: ["-c", "tmux has-session -t \"$1\" 2>/dev/null", "sh", session],
      workdir: None,
    }) catch {
      _ => 1
    }
    if session_alive == 0 {
      @io.write_stdout("Attaching to existing session \{session}...\n")
      ignore(
        @exec.run({
          program: "tmux",
          args: ["attach-session", "-t", session],
          workdir: None,
        }) catch {
          _ => 0
        },
      )
      return
    }

    ignore(
      @exec.run({
        program: "sh",
        args: [
          "-c", "mkdir -p .choir/agents/root && git branch --show-current > .choir/agents/root/.birth_branch 2>/dev/null || true",
        ],
        workdir: None,
      }) catch {
        _ => 0
      },
    )

    @io.write_stdout("Creating session \{session}...\n")
    init_run_or_exit({
      program: "tmux",
      args: ["new-session", "-d", "-s", session, "-n", "Server"],
      workdir: None,
    })

    init_run_or_exit({
      program: "tmux",
      args: ["send-keys", "-t", session + ":Server", "choir dev", "Enter"],
      workdir: None,
    })

    init_run_or_exit({
      program: "tmux",
      args: ["new-window", "-t", session, "-n", "TL"],
      workdir: None,
    })
    init_run_or_exit({
      program: "tmux",
      args: [
        "send-keys",
        "-t",
        session + ":TL",
        "claude --dangerously-skip-permissions; echo; echo '[Claude exited]'; exec bash -l",
        "Enter",
      ],
      workdir: None,
    })

    match config.companions_json {
      Some(json) => {
        let companions = @config.parse_companions_json(json)
        for c in companions {
          let agent_dir = ".choir/agents/" + c.name
          ignore(
            @exec.run({
              program: "sh",
              args: [
                "-c",
                "mkdir -p \"$1\" && printf '%s' \"$2\" > \"$1/.mcp.json\"",
                "sh",
                agent_dir,
                init_mcp_json_content(project_dir),
              ],
              workdir: None,
            }) catch {
              _ => 0
            },
          )
          ignore(
            @exec.run({
              program: "sh",
              args: [
                "-c",
                "printf '%s' \"$2\" > \"$1/.birth_branch\"",
                "sh",
                agent_dir,
                c.name,
              ],
              workdir: None,
            }) catch {
              _ => 0
            },
          )
          let window_cmd = c.command +
            " '" +
            init_escape_shell_single_quoted(c.task) +
            "'"
          ignore(
            @exec.run({
              program: "tmux",
              args: ["new-window", "-t", session, "-n", c.name],
              workdir: None,
            }) catch {
              _ => 0
            },
          )
          ignore(
            @exec.run({
              program: "tmux",
              args: [
                "send-keys",
                "-t",
                session + ":" + c.name,
                window_cmd,
                "Enter",
              ],
              workdir: None,
            }) catch {
              _ => 0
            },
          )
          @io.write_stdout("Spawned companion: \{c.name}\n")
        }
      }
      None => ()
    }

    @io.write_stdout("Waiting for server socket...\n")
    if not(@io.wait_for_socket(config.listen_uds, 60)) {
      @io.write_stdout("Warning: server socket not ready after 30s\n")
    } else {
      @io.write_stdout("Server ready.\n")
    }

    @io.write_stdout("Attaching to session \{session}...\n")
    ignore(
      @exec.run({
        program: "tmux",
        args: ["attach-session", "-t", session],
        workdir: None,
      }) catch {
        _ => 0
      },
    )
  })
}

///|
fn dev_run() -> Unit {
  let cmd = "command -v watchexec > /dev/null 2>&1 && " +
    "exec watchexec -e mbt,toml -r --shell=none -- sh -c 'moon build --target native --release && exec choir serve'; " +
    "command -v entr > /dev/null 2>&1 && " +
    "exec sh -c '(find src -name \"*.mbt\"; find . -maxdepth 2 -name \"*.toml\") | entr -r sh -c \"moon build --target native --release && exec choir serve\"'; " +
    "echo 'choir dev: watchexec and entr not found, running without hot reload'; " +
    "moon build --target native --release && exec choir serve"
  let code = @io.system(cmd)
  @io.exit(code)
}

///|
fn reply_run() -> Unit {
  let args = @io.get_args()

  let mut id = ""
  let mut payload = ""
  let mut cancel = false
  let mut i = 2
  while i < args.length() {
    match args[i] {
      "--id" =>
        if i + 1 < args.length() {
          id = args[i + 1]
          i = i + 2
        } else {
          i = i + 1
        }
      "--payload" =>
        if i + 1 < args.length() {
          payload = args[i + 1]
          i = i + 2
        } else {
          i = i + 1
        }
      "--cancel" => {
        cancel = true
        i = i + 1
      }
      _ => i = i + 1
    }
  }

  if id == "" {
    @io.write_stdout(
      "usage: choir reply --id <id> [--payload <json>] [--cancel]\n",
    )
    @io.exit(1)
    return
  }

  let config_content = @io.read_file(".choir/config.toml")
  let config = match @config.parse_config(config_content) {
    Ok(cfg) => cfg
    Err(_) => @types.Config::default()
  }

  let uds_fd = @uds.client_connect(config.listen_uds)
  if uds_fd < 0 {
    @io.write_stdout(
      "error: cannot connect to server at \{config.listen_uds}\n",
    )
    @io.exit(1)
    return
  }

  let reg_msg = "{\"method\":\"register\",\"role\":\"root\",\"name\":\"register\",\"args\":{\"agent_id\":\"system-reply\"}}\n"
  let reg_bytes = @utf8.encode(reg_msg)
  let mut written = 0
  while written < reg_bytes.length() {
    let n = @uds.write_bytes(
      uds_fd,
      reg_bytes,
      written,
      reg_bytes.length() - written,
    )
    if n <= 0 {
      break
    }
    written = written + n
  }

  let rbuf = FixedArray::make(1024, (0 : Byte))
  let _ = @uds.read_bytes(uds_fd, rbuf, 0, rbuf.length())

  let cancel_str = if cancel { "true" } else { "false" }
  let req_msg = "{\"method\":\"reply\",\"role\":\"root\",\"name\":\"reply\",\"args\":{\"id\":\"" +
    choir_escape_json_string(id) +
    "\",\"payload\":\"" +
    choir_escape_json_string(payload) +
    "\",\"cancel\":\"" +
    cancel_str +
    "\"}}\n"
  let req_bytes = @utf8.encode(req_msg)
  written = 0
  while written < req_bytes.length() {
    let n = @uds.write_bytes(
      uds_fd,
      req_bytes,
      written,
      req_bytes.length() - written,
    )
    if n <= 0 {
      break
    }
    written = written + n
  }

  let resp_buf = FixedArray::make(4096, (0 : Byte))
  let n = @uds.read_bytes(uds_fd, resp_buf, 0, resp_buf.length())
  if n > 0 {
    let resp = @utf8.decode_lossy(resp_buf.unsafe_reinterpret_as_bytes()[:n])
    @io.write_stdout(resp + "\n")
  }

  @uds.close(uds_fd)
}

///|
fn watch_run() -> Unit {
  dev_run()
}

///|
fn main {
  let args = @io.get_args()
  let subcmd = if args.length() >= 2 { args[1] } else { "" }
  match subcmd {
    "serve" => serve_run() catch { _ => @io.exit(1) }
    "dev" => dev_run()
    "mcp-stdio" => mcp_run() catch { err => println("fatal: \{err}") }
    "hook" =>
      hook_run() catch {
        _ =>
          @io.write_stdout(
            @hooks.HookResponse::fail_open().to_json_string() + "\n",
          )
      }
    "init" => init_run() catch { _ => @io.exit(1) }
    "reply" => reply_run()
    "watch" => watch_run()
    _ => {
      @io.write_stdout(
        "usage: choir <serve|dev|mcp-stdio|hook|init [--recreate]|reply|watch>\n",
      )
      @io.exit(1)
    }
  }
}
