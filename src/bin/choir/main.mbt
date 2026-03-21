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
    Some(agent_id) => state.schedule_disconnect(agent_id, @poller.now_sec())
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
    Some(agent_id) => state.schedule_disconnect(agent_id, @poller.now_sec())
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
    @server.recover_state(state, config.terminal_session)
    root.spawn_bg(async fn() {
      let timeout_sec = 900L
      let disconnect_grace_sec = 60L
      let interval_ms = 30000
      for {
        @async.sleep(interval_ms)
        let now = @poller.now_sec()
        state.process_pending_disconnects(now, disconnect_grace_sec)
        state.process_poller_tick(now, timeout_sec, runner=@exec.run_sequence)
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
  let registration_local_cfg = if local_cfg.terminal_target is None &&
    local_cfg.parent_id is None &&
    local_cfg.workspace is None &&
    role == @types.Role::TL {
    {
      ..local_cfg,
      terminal_target: Some(
        @workspace.local_target_for(
          config.terminal_backend,
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
priv struct LeafCliArgs {
  flags : Map[String, String]
  positionals : Array[String]
}

///|
fn normalize_cli_key(key : String) -> String {
  let buf = StringBuilder::new()
  for c in key {
    if c == '-' {
      buf.write_char('_')
    } else {
      buf.write_char(c)
    }
  }
  buf.to_string()
}

///|
fn parse_leaf_cli_args(args : Array[String]) -> LeafCliArgs {
  let flags : Map[String, String] = {}
  let positionals : Array[String] = []
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if arg.has_prefix("--") {
      let eq_idx = @jsonutil.find_substring(arg, "=")
      if eq_idx > 2 {
        let key = normalize_cli_key(arg[2:eq_idx].to_string() catch { _ => "" })
        let value = arg[eq_idx + 1:arg.length()].to_string() catch { _ => "" }
        flags.set(key, value)
        i = i + 1
      } else {
        let key = normalize_cli_key(
          arg[2:arg.length()].to_string() catch {
            _ => ""
          },
        )
        if i + 1 < args.length() && not(args[i + 1].has_prefix("--")) {
          flags.set(key, args[i + 1])
          i = i + 2
        } else {
          flags.set(key, "true")
          i = i + 1
        }
      }
    } else {
      positionals.push(arg)
      i = i + 1
    }
  }
  { flags, positionals }
}

///|
fn args_tail(args : Array[String], start : Int) -> Array[String] {
  let tail : Array[String] = []
  for i = start; i < args.length(); i = i + 1 {
    tail.push(args[i])
  }
  tail
}

///|
fn join_positionals(items : Array[String], start : Int) -> String {
  let buf = StringBuilder::new()
  for i = start; i < items.length(); i = i + 1 {
    if i > start {
      buf.write_char(' ')
    }
    buf.write_string(items[i])
  }
  buf.to_string()
}

///|
fn is_status_word(s : String) -> Bool {
  let lowered = s.trim().to_lower()
  lowered == "success" || lowered == "failure" || lowered == "info"
}

///|
fn looks_like_branch_token(s : String) -> Bool {
  let trimmed = s.trim().to_string()
  if trimmed == "" {
    return false
  }
  for c in trimmed {
    if not(
        (c >= 'a' && c <= 'z') ||
        (c >= 'A' && c <= 'Z') ||
        (c >= '0' && c <= '9') ||
        c == '-' ||
        c == '_' ||
        c == '/' ||
        c == '.',
      ) {
      return false
    }
  }
  true
}

///|
fn looks_like_legacy_branch_arg(s : String) -> Bool {
  looks_like_branch_token(s) &&
  (s.contains(".") || s.contains("/") || s.contains("-") || s.contains("_"))
}

///|
fn leaf_tool_request_args(
  tool : String,
  cli_args : LeafCliArgs,
) -> Result[Map[String, String], String] {
  let flags = cli_args.flags
  let positionals = cli_args.positionals
  match tool {
    "file_pr" => {
      let used_legacy_branch = not(flags.contains("branch")) &&
        positionals.length() > 0 &&
        looks_like_legacy_branch_arg(positionals[0])
      if not(flags.contains("branch")) && used_legacy_branch {
        flags.set("branch", positionals[0])
      }
      if used_legacy_branch && not(flags.contains("parent_branch")) {
        if positionals.length() > 2 && looks_like_branch_token(positionals[2]) {
          flags.set("parent_branch", positionals[2])
        } else if positionals.length() > 1 &&
          looks_like_branch_token(positionals[1]) {
          flags.set("parent_branch", positionals[1])
        }
      }
      Ok(flags)
    }
    "notify_parent" => {
      if not(flags.contains("status")) &&
        positionals.length() > 0 &&
        is_status_word(positionals[0]) {
        flags.set("status", positionals[0].trim().to_lower().to_string())
      }
      if not(flags.contains("message")) {
        let message_start = if flags.contains("status") &&
          positionals.length() > 0 &&
          is_status_word(positionals[0]) {
          1
        } else {
          0
        }
        let message = join_positionals(positionals, message_start)
          .trim()
          .to_string()
        if message != "" {
          flags.set("message", message)
        }
      }
      match flags.get("message") {
        Some(message) =>
          if message.trim() == "" {
            Err("notify_parent requires a message")
          } else {
            Ok(flags)
          }
        None => Err("notify_parent requires a message")
      }
    }
    "shutdown" => Ok(flags)
    "task_list" => Ok(flags)
    "task_get" =>
      match flags.get("id") {
        Some(id) =>
          if id.trim() == "" {
            Err("task_get requires id")
          } else {
            Ok(flags)
          }
        None =>
          if positionals.length() == 0 || positionals[0].trim() == "" {
            Err("task_get requires id")
          } else {
            flags.set("id", positionals[0])
            Ok(flags)
          }
      }
    "task_create" => {
      if not(flags.contains("id")) && positionals.length() > 0 {
        flags.set("id", positionals[0])
      }
      if not(flags.contains("title")) && positionals.length() > 1 {
        flags.set("title", join_positionals(positionals, 1))
      }
      match (flags.get("id"), flags.get("title")) {
        (Some(id), Some(title)) =>
          if id.trim() == "" || title.trim() == "" {
            Err("task_create requires id and title")
          } else {
            Ok(flags)
          }
        _ => Err("task_create requires id and title")
      }
    }
    "task_update" => {
      if not(flags.contains("id")) && positionals.length() > 0 {
        flags.set("id", positionals[0])
      }
      match flags.get("id") {
        Some(id) =>
          if id.trim() == "" {
            Err("task_update requires id")
          } else {
            Ok(flags)
          }
        None => Err("task_update requires id")
      }
    }
    _ => Err("unsupported leaf tool: " + tool)
  }
}

///|
fn leaf_tool_usage(tool : String) -> String {
  match tool {
    "file_pr" =>
      "usage: file_pr [--branch <branch>] [--parent-branch <parent_branch>]"
    "notify_parent" =>
      "usage: notify_parent [--status <success|failure|info>] <message>"
    "shutdown" => "usage: shutdown [--caller-id <caller_id>]"
    "task_list" => "usage: task_list"
    "task_get" => "usage: task_get <id>"
    "task_create" =>
      "usage: task_create <id> <title...> [--status <status>] [--assignee <assignee>] [--notes <notes>]"
    "task_update" =>
      "usage: task_update <id> [--status <status>] [--assignee <assignee>] [--notes <notes>]"
    _ => "usage: choir leaf-tool <tool> [args...]"
  }
}

///|
fn leaf_tool_response_json(resp : @types.Response) -> String {
  @transport.format_response(resp) + "\n"
}

///|
fn leaf_tool_emit(resp : @types.Response) -> Unit {
  @io.write_stdout(leaf_tool_response_json(resp))
  @io.exit(if resp.is_ok() { 0 } else { 1 })
}

///|
fn leaf_tool_load_config() -> Result[
  (@types.Role, @types.Config, @types.LocalConfig),
  String,
] {
  let config_content = @io.read_file(".choir/config.toml")
  if config_content == "" {
    return Err("missing .choir/config.toml")
  }
  let config = match @config.parse_config(config_content) {
    Ok(cfg) => cfg
    Err(e) => return Err(e.message())
  }
  let local_content = @io.read_file(".choir/config.local.toml")
  if local_content == "" {
    return Err("missing .choir/config.local.toml")
  }
  let local_cfg = match @config.parse_local_config(local_content) {
    Ok(cfg) => cfg
    Err(e) => return Err(e.message())
  }
  Ok((@config.resolve_role(local_cfg.role, config), config, local_cfg))
}

///|
fn leaf_tool_register_if_needed(
  uds_fd : Int,
  reader : UDSLineReader,
  role : @types.Role,
  config : @types.Config,
  local_cfg : @types.LocalConfig,
) -> Result[Unit, String] {
  let reg_msg = mcp_build_registration_message(role, config, local_cfg)
  if not(mcp_write_all_uds(uds_fd, @utf8.encode(reg_msg))) {
    return Err("failed to write registration request")
  }
  let reg_resp_line = reader.read_line()
  if reg_resp_line == "" {
    return Err("server connection closed during registration")
  }
  match @transport.parse_response(reg_resp_line) {
    Ok(resp) =>
      if resp.is_ok() {
        Ok(())
      } else {
        let err = resp.error_message().unwrap_or("registration failed")
        if err.contains("agent already exists:") {
          Ok(())
        } else {
          Err(err)
        }
      }
    Err(err) => Err("failed to parse registration response: " + err)
  }
}

///|
fn leaf_tool_run() -> Unit {
  let args = @io.get_args()
  if args.length() < 3 {
    leaf_tool_emit(
      @types.Response::Err("usage: choir leaf-tool <tool> [args...]"),
    )
    return
  }
  let tool = args[2]
  let cli_args = parse_leaf_cli_args(args_tail(args, 3))
  if cli_args.flags.contains("help") {
    leaf_tool_emit(
      @types.Response::ok_values({
        "usage": @types.wire_string(leaf_tool_usage(tool)),
      }),
    )
    return
  }
  let req_args = match leaf_tool_request_args(tool, cli_args) {
    Ok(parsed) => parsed
    Err(err) => {
      leaf_tool_emit(@types.Response::Err(err))
      return
    }
  }
  let (role, config, local_cfg) = match leaf_tool_load_config() {
    Ok(loaded) => loaded
    Err(err) => {
      leaf_tool_emit(@types.Response::Err(err))
      return
    }
  }
  let uds_fd = @uds.client_connect(config.listen_uds)
  if uds_fd < 0 {
    leaf_tool_emit(
      @types.Response::Err("cannot connect to server at " + config.listen_uds),
    )
    return
  }
  let reader = UDSLineReader::new(uds_fd)
  match leaf_tool_register_if_needed(uds_fd, reader, role, config, local_cfg) {
    Ok(_) => ()
    Err(err) => {
      @uds.close(uds_fd)
      leaf_tool_emit(@types.Response::Err(err))
      return
    }
  }
  let req : @types.Request = {
    req_method: "tools/call",
    role,
    name: tool,
    args: @types.RequestArgs::new(req_args),
  }
  let wire_req = mcp_build_wire_request(req, role, config, local_cfg)
  if not(mcp_write_all_uds(uds_fd, @utf8.encode(wire_req))) {
    @uds.close(uds_fd)
    leaf_tool_emit(@types.Response::Err("failed to write tool request"))
    return
  }
  let resp_line = reader.read_line()
  @uds.close(uds_fd)
  if resp_line == "" {
    leaf_tool_emit(@types.Response::Err("server connection closed"))
    return
  }
  match @transport.parse_response(resp_line) {
    Ok(resp) => leaf_tool_emit(resp)
    Err(err) =>
      leaf_tool_emit(@types.Response::Err("failed to parse response: " + err))
  }
}

///|
fn trusted_folders_json(existing : String, workspace : String) -> String {
  let values = @jsonutil.parse_flat_json_object(existing)
  values.set(workspace, "TRUST_FOLDER")
  let buf = StringBuilder::new()
  buf.write_char('{')
  let mut first = true
  values.each(fn(path, trust) {
    if not(first) {
      buf.write_char(',')
    }
    buf.write_char('"')
    buf.write_string(choir_escape_json_string(path))
    buf.write_string("\":\"")
    buf.write_string(choir_escape_json_string(trust))
    buf.write_char('"')
    first = false
  })
  buf.write_char('}')
  buf.to_string()
}

///|
fn trust_gemini_folder_run() -> Unit {
  let args = @io.get_args()
  if args.length() < 3 {
    @io.write_stdout("usage: choir trust-gemini-folder <workspace>\n")
    @io.exit(1)
    return
  }
  let home = match @io.getenv("HOME") {
    Some(path) =>
      if path == "" {
        @io.write_stdout("error: HOME is not set\n")
        @io.exit(1)
        return
      } else {
        path
      }
    None => {
      @io.write_stdout("error: HOME is not set\n")
      @io.exit(1)
      return
    }
  }
  let gemini_dir = home + "/.gemini"
  let trusted_path = gemini_dir + "/trustedFolders.json"
  ignore(
    @io.system("mkdir -p '" + init_escape_shell_single_quoted(gemini_dir) + "'"),
  )
  let content = @io.read_file(trusted_path)
  let updated = trusted_folders_json(content, args[2])
  if @io.write_file_sync(trusted_path, updated) {
    @io.write_stdout("trusted " + args[2] + "\n")
    @io.exit(0)
  } else {
    @io.write_stdout("error: failed to write " + trusted_path + "\n")
    @io.exit(1)
  }
}

///|
priv struct ZellijPaneRef {
  id : String
  tab_id : String
  title : String
  tab_name : String
  is_plugin : Bool
  exited : Bool
}

///|
async fn capture_stdout_main(program : String, args : Array[String]) -> String {
  let (read_end, write_end) = @pipe.pipe()
  let args_bytes = args.map(fn(arg) { @utf8.encode(arg) })
  ignore(
    @process.run(@utf8.encode(program), args_bytes, stdout=write_end) catch {
      _ => -1
    },
  )
  write_end.close()
  let buf = FixedArray::make(65536, (0 : Byte))
  let mut total = 0
  for {
    if total >= buf.length() {
      break
    }
    let n = read_end.read(buf, offset=total, max_len=buf.length() - total)
    if n == 0 {
      break
    }
    total = total + n
  }
  read_end.close()
  @utf8.decode_lossy(buf.unsafe_reinterpret_as_bytes()[:total])
}

///|
fn zellij_json_bool(value : @jsonutil.JsonValueText?) -> Bool {
  match value {
    Some(@jsonutil.JsonValueText::Raw("true")) => true
    Some(@jsonutil.JsonValueText::String("true")) => true
    _ => false
  }
}

///|
fn zellij_json_string(value : @jsonutil.JsonValueText?) -> String {
  match value {
    Some(@jsonutil.JsonValueText::String(v)) => v
    Some(@jsonutil.JsonValueText::Raw(v)) => v
    None => ""
  }
}

///|
async fn zellij_list_panes(session : String) -> Array[ZellijPaneRef] {
  let output = capture_stdout_main("zellij", [
    "--session", session, "action", "list-panes", "--json", "-a", "-t", "-s",
  ])
  let panes = []
  for pane in @jsonutil.parse_json_object_array_text(output) {
    panes.push({
      id: zellij_json_string(pane.get("id")),
      tab_id: zellij_json_string(pane.get("tab_id")),
      title: zellij_json_string(pane.get("title")),
      tab_name: zellij_json_string(pane.get("tab_name")),
      is_plugin: zellij_json_bool(pane.get("is_plugin")),
      exited: zellij_json_bool(pane.get("exited")),
    })
  }
  panes
}

///|
fn zellij_target_pane_id(
  target : @workspace.LocalTarget,
  panes : Array[ZellijPaneRef],
  allow_exited? : Bool = false,
) -> String? {
  let want_exited = allow_exited
  for pane in panes {
    if pane.is_plugin {
      continue
    }
    if not(want_exited) && pane.exited {
      continue
    }
    match target.kind {
      @workspace.LocalTargetKind::ZellijPane =>
        if pane.title == target.name {
          return Some(pane.id)
        }
      @workspace.LocalTargetKind::ZellijTab =>
        if pane.tab_name == target.name {
          return Some(pane.id)
        }
      _ => ()
    }
  }
  None
}

///|
fn zellij_target_tab_id(
  target : @workspace.LocalTarget,
  panes : Array[ZellijPaneRef],
) -> String? {
  for pane in panes {
    if pane.is_plugin {
      continue
    }
    if pane.tab_name == target.name {
      return Some(pane.tab_id)
    }
  }
  None
}

///|
fn zellij_action_usage() -> String {
  "usage: choir zellij-action <send|close> <target> [text]"
}

///|
fn zellij_action_run() -> Unit raise {
  @async.with_event_loop(async fn(_root) {
    let args = @io.get_args()
    if args.length() < 4 {
      @io.write_stdout(zellij_action_usage() + "\n")
      @io.exit(1)
      return
    }
    let action = args[2]
    let target_text = args[3]
    let target = match @workspace.parse_local_target(target_text) {
      Some(parsed) =>
        match parsed.kind {
          @workspace.LocalTargetKind::ZellijTab
          | @workspace.LocalTargetKind::ZellijPane => parsed
          _ => {
            @io.write_stdout(
              "error: not a zellij target: " + target_text + "\n",
            )
            @io.exit(1)
            return
          }
        }
      None => {
        @io.write_stdout("error: invalid zellij target: " + target_text + "\n")
        @io.exit(1)
        return
      }
    }
    let panes = zellij_list_panes(target.session)
    match action {
      "send" => {
        if args.length() < 5 {
          @io.write_stdout(zellij_action_usage() + "\n")
          @io.exit(1)
          return
        }
        let text = args[4]
        let pane_id = match zellij_target_pane_id(target, panes) {
          Some(id) => id
          None => {
            @io.write_stdout(
              "error: zellij target not found: " + target_text + "\n",
            )
            @io.exit(1)
            return
          }
        }
        let write_code = @exec.run({
          program: "zellij",
          args: [
            "--session",
            target.session,
            "action",
            "write-chars",
            "-p",
            pane_id,
            text,
          ],
          workdir: None,
        })
        if write_code != 0 {
          @io.exit(write_code)
          return
        }
        let key_code = @exec.run({
          program: "zellij",
          args: [
            "--session",
            target.session,
            "action",
            "send-keys",
            "-p",
            pane_id,
            "Enter",
          ],
          workdir: None,
        })
        @io.exit(key_code)
      }
      "close" =>
        match target.kind {
          @workspace.LocalTargetKind::ZellijPane => {
            let pane_id = match
              zellij_target_pane_id(target, panes, allow_exited=true) {
              Some(id) => id
              None => {
                @io.write_stdout(
                  "error: zellij target not found: " + target_text + "\n",
                )
                @io.exit(1)
                return
              }
            }
            let code = @exec.run({
              program: "zellij",
              args: [
                "--session",
                target.session,
                "action",
                "close-pane",
                "-p",
                pane_id,
              ],
              workdir: None,
            })
            @io.exit(code)
          }
          @workspace.LocalTargetKind::ZellijTab => {
            let tab_id = match zellij_target_tab_id(target, panes) {
              Some(id) => id
              None => {
                @io.write_stdout(
                  "error: zellij target not found: " + target_text + "\n",
                )
                @io.exit(1)
                return
              }
            }
            let code = @exec.run({
              program: "zellij",
              args: [
                "--session",
                target.session,
                "action",
                "close-tab-by-id",
                tab_id,
              ],
              workdir: None,
            })
            @io.exit(code)
          }
          _ => {
            @io.write_stdout(
              "error: not a zellij target: " + target_text + "\n",
            )
            @io.exit(1)
          }
        }
      _ => {
        @io.write_stdout(zellij_action_usage() + "\n")
        @io.exit(1)
      }
    }
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
test "mcp registration infers tmux TL terminal target for top-level session" {
  let cfg = {
    ..@types.Config::default(),
    terminal_backend: @types.TerminalBackend::Tmux,
    terminal_session: "choir-resorter-py",
  }
  let output = mcp_build_registration_message(
    @types.Role::TL,
    cfg,
    @types.LocalConfig::default(),
  )
  assert_true(output.contains("\"name\":\"register\""))
  assert_true(output.contains("\"terminal_target\":\"choir-resorter-py:TL\""))
}

///|
test "mcp registration infers zellij TL terminal target for top-level session" {
  let cfg = {
    ..@types.Config::default(),
    terminal_backend: @types.TerminalBackend::Zellij,
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
test "leaf tool parser supports notify_parent positional message and status" {
  let parsed = leaf_tool_request_args(
    "notify_parent",
    parse_leaf_cli_args(["failure", "[BLOCKED]", "need", "help"]),
  ).unwrap()
  assert_eq(parsed.get("status"), Some("failure"))
  assert_eq(parsed.get("message"), Some("[BLOCKED] need help"))
}

///|
test "leaf tool parser accepts legacy file_pr positional triplet" {
  let parsed = leaf_tool_request_args(
    "file_pr",
    parse_leaf_cli_args(["main.gemini-leaf", "main.gemini-leaf", "main"]),
  ).unwrap()
  assert_eq(parsed.get("branch"), Some("main.gemini-leaf"))
  assert_eq(parsed.get("parent_branch"), Some("main"))
}

///|
test "leaf tool parser ignores prose positionals for file_pr" {
  let parsed = leaf_tool_request_args(
    "file_pr",
    parse_leaf_cli_args(["Add", "pytest", "integration", "tests"]),
  ).unwrap()
  assert_eq(parsed.get("branch"), None)
  assert_eq(parsed.get("parent_branch"), None)
}

///|
test "leaf tool usage includes file_pr args" {
  assert_eq(
    leaf_tool_usage("file_pr"),
    "usage: file_pr [--branch <branch>] [--parent-branch <parent_branch>]",
  )
}

///|
test "leaf tool parser supports task_create positionals" {
  let parsed = leaf_tool_request_args(
    "task_create",
    parse_leaf_cli_args(["task-1", "Write", "better", "tests"]),
  ).unwrap()
  assert_eq(parsed.get("id"), Some("task-1"))
  assert_eq(parsed.get("title"), Some("Write better tests"))
}

///|
test "trusted_folders_json preserves existing paths and adds workspace" {
  let updated = trusted_folders_json(
    "{\"/existing\":\"TRUST_FOLDER\"}", "/new/worktree",
  )
  let parsed = @jsonutil.parse_flat_json_object(updated)
  assert_eq(parsed.get("/existing"), Some("TRUST_FOLDER"))
  assert_eq(parsed.get("/new/worktree"), Some("TRUST_FOLDER"))
}

///|
fn smoke_keep_temp(args : Array[String]) -> Bool {
  args.contains("--keep-temp")
}

///|
fn init_no_attach(args : Array[String]) -> Bool {
  args.contains("--no-attach")
}

///|
fn smoke_review_enabled(args : Array[String]) -> Bool {
  args.contains("--review")
}

///|
fn smoke_leafs_enabled(args : Array[String]) -> Bool {
  args.contains("--leafs")
}

///|
fn smoke_companions_enabled(args : Array[String]) -> Bool {
  args.contains("--companions")
}

///|
fn smoke_e2e_enabled(args : Array[String]) -> Bool {
  args.contains("--e2e-live")
}

///|
fn smoke_self_exe(args : Array[String]) -> String {
  let argv0 = if args.length() > 0 { args[0] } else { "choir" }
  if argv0.has_prefix("/") || not(argv0.contains("/")) {
    argv0
  } else {
    @io.getcwd() + "/" + argv0
  }
}

///|
fn smoke_script() -> String {
  (
    #|set -eu
    #|BIN="$1"
    #|KEEP_TEMP="$2"
    #|ROOT="$(mktemp -d "${TMPDIR:-/tmp}/choir-smoke-XXXXXX")"
    #|cleanup() {
    #|  status=$?
    #|  if [ -f "$ROOT/hold.pid" ]; then
    #|    kill "$(cat "$ROOT/hold.pid")" 2>/dev/null || true
    #|    wait "$(cat "$ROOT/hold.pid")" 2>/dev/null || true
    #|  fi
    #|  if [ -f "$ROOT/server.pid" ]; then
    #|    kill "$(cat "$ROOT/server.pid")" 2>/dev/null || true
    #|    wait "$(cat "$ROOT/server.pid")" 2>/dev/null || true
    #|  fi
    #|  if [ "$KEEP_TEMP" = "1" ] || [ "$status" -ne 0 ]; then
    #|    echo "smoke artifacts: $ROOT"
    #|  else
    #|    rm -rf "$ROOT"
    #|  fi
    #|}
    #|trap cleanup EXIT INT TERM
    #|if ! command -v timeout >/dev/null 2>&1; then
    #|  echo "error: timeout not found"
    #|  exit 1
    #|fi
    #|mkdir -p "$ROOT/repo/.choir/tasks" "$ROOT/repo/.choir/agents"
    #|cat > "$ROOT/repo/.choir/config.toml" <<'EOF'
    #|default_role = "tl"
    #|project_dir = "."
    #|listen_uds = ".choir/server.sock"
    #|EOF
    #|(cd "$ROOT/repo" && "$BIN" serve >"$ROOT/server.log" 2>&1 & echo $! >"$ROOT/server.pid")
    #|i=0
    #|while [ ! -S "$ROOT/repo/.choir/server.sock" ] && [ "$i" -lt 50 ]; do
    #|  sleep 0.1
    #|  i=$((i + 1))
    #|done
    #|test -S "$ROOT/repo/.choir/server.sock"
    #|sleep 0.2
    #|printf '%s\n' \
    #|'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
    #|'{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"task_create","arguments":{"id":"runtime-proof-task-1","title":"Runtime Proof Task 1"}}}' \
    #|> "$ROOT/first.reqs.jsonl"
    #|(cd "$ROOT/repo" && cat "$ROOT/first.reqs.jsonl" | timeout 8 "$BIN" mcp-stdio --name smoke-proof >"$ROOT/first.out" 2>"$ROOT/first.err")
    #|grep -F '"protocolVersion":"2024-11-05"' "$ROOT/first.out" >/dev/null
    #|grep -F 'runtime-proof-task-1' "$ROOT/first.out" >/dev/null
    #|test -f "$ROOT/repo/.choir/tasks/runtime-proof-task-1.json"
    #|printf '%s\n' \
    #|'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
    #|> "$ROOT/hold.reqs.jsonl"
    #|printf '%s\n' \
    #|'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
    #|'{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"task_create","arguments":{"id":"runtime-proof-task-2","title":"Runtime Proof Task 2"}}}' \
    #|> "$ROOT/second.reqs.jsonl"
    #|(
    #|  cd "$ROOT/repo" &&
    #|  { cat "$ROOT/hold.reqs.jsonl"; sleep 2; } |
    #|    "$BIN" mcp-stdio --name hold-open >"$ROOT/hold.out" 2>"$ROOT/hold.err"
    #|) &
    #|echo $! > "$ROOT/hold.pid"
    #|i=0
    #|while [ "$i" -lt 50 ]; do
    #|  if grep -F '"protocolVersion":"2024-11-05"' "$ROOT/hold.out" >/dev/null 2>&1; then
    #|    break
    #|  fi
    #|  sleep 0.1
    #|  i=$((i + 1))
    #|done
    #|grep -F '"protocolVersion":"2024-11-05"' "$ROOT/hold.out" >/dev/null
    #|(cd "$ROOT/repo" && cat "$ROOT/second.reqs.jsonl" | timeout 8 "$BIN" mcp-stdio --name second-client >"$ROOT/second.out" 2>"$ROOT/second.err")
    #|wait "$(cat "$ROOT/hold.pid")"
    #|grep -F 'runtime-proof-task-2' "$ROOT/second.out" >/dev/null
    #|test -f "$ROOT/repo/.choir/tasks/runtime-proof-task-2.json"
    #|! grep -F 'validation error:' "$ROOT/server.log" >/dev/null
    #|echo "smoke ok: EOF and multi-client checks passed"
  ) +
  "\n"
}

///|
fn smoke_leaf_script() -> String {
  (
    #|set -eu
    #|BIN="$1"
    #|KEEP_TEMP="$2"
    #|REPO="$3"
    #|ROOT="$(mktemp -d "${TMPDIR:-/tmp}/choir-leaf-smoke-XXXXXX")"
    #|SESSION="choir-leaf-smoke-$$"
    #|ROOT_BRANCH="live-smoke/leaf-root-$$"
    #|MOON_SLUG="moon-leaf-smoke-$$"
    #|GEMINI_SLUG="gemini-leaf-smoke-$$"
    #|MOON_BRANCH="main.$MOON_SLUG"
    #|GEMINI_BRANCH="main.$GEMINI_SLUG"
    #|MOON_PR=""
    #|GEMINI_PR=""
    #|cleanup() {
    #|  status=$?
    #|  if [ -n "$MOON_PR" ]; then
    #|    gh pr close "$MOON_PR" --delete-branch >/dev/null 2>&1 || true
    #|  fi
    #|  if [ -n "$GEMINI_PR" ]; then
    #|    gh pr close "$GEMINI_PR" --delete-branch >/dev/null 2>&1 || true
    #|  fi
    #|  tmux kill-session -t "$SESSION" >/dev/null 2>&1 || true
    #|  git -C "$REPO" worktree remove --force "$ROOT/repo/.choir/worktrees/$MOON_SLUG" >/dev/null 2>&1 || true
    #|  git -C "$REPO" worktree remove --force "$ROOT/repo/.choir/worktrees/$GEMINI_SLUG" >/dev/null 2>&1 || true
    #|  git -C "$REPO" worktree remove --force "$ROOT/repo" >/dev/null 2>&1 || true
    #|  git -C "$REPO" branch -D "$MOON_BRANCH" >/dev/null 2>&1 || true
    #|  git -C "$REPO" branch -D "$GEMINI_BRANCH" >/dev/null 2>&1 || true
    #|  git -C "$REPO" branch -D "$ROOT_BRANCH" >/dev/null 2>&1 || true
    #|  if [ "$KEEP_TEMP" = "1" ] || [ "$status" -ne 0 ]; then
    #|    echo "leaf smoke artifacts: $ROOT"
    #|  else
    #|    rm -rf "$ROOT"
    #|  fi
    #|}
    #|trap cleanup EXIT INT TERM
    #|for cmd in timeout gh tmux gemini moon; do
    #|  command -v "$cmd" >/dev/null 2>&1 || {
    #|    echo "error: required command not found: $cmd"
    #|    exit 1
    #|  }
    #|done
    #|git -C "$REPO" rev-parse --verify main >/dev/null 2>&1
    #|git -C "$REPO" worktree add -b "$ROOT_BRANCH" "$ROOT/repo" main >/dev/null
    #|mkdir -p "$ROOT/repo/.choir"
    #|cat > "$ROOT/repo/.choir/config.toml" <<EOF
    #|default_role = "tl"
    #|project_dir = "."
    #|listen_uds = ".choir/server.sock"
    #|terminal_session = "$SESSION"
    #|EOF
    #|(cd "$ROOT/repo" && "$BIN" init --recreate --no-attach >"$ROOT/init.log" 2>&1 || { cat "$ROOT/init.log"; exit 1; })
    #|spawn_leaf() {
    #|  slug="$1"
    #|  agent_type="${2:-gemini}"
    #|  req="$ROOT/$slug.req.jsonl"
    #|  cat > "$req" <<EOF
    #|{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
    #|{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"fork_wave","arguments":{"caller_id":"root-smoke","slug_prefix":"$slug","count":"1","agent_type":"$agent_type","parent_branch":"main","task":"Make a tiny doc-only change to CLAUDE.md, run moon fmt and moon test --target native, commit it, then use file_pr and notify_parent with the returned PR URL. Do not use raw gh commands.","read_first":"AGENTS.md\nCLAUDE.md","done_criteria":"A PR is filed through file_pr and the parent has been notified."}}}
    #|EOF
    #|  (cd "$ROOT/repo" && cat "$req" | timeout 120 "$BIN" mcp-stdio --name root-smoke >"$ROOT/$slug.out" 2>"$ROOT/$slug.err")
    #|}
    #|wait_for_pr() {
    #|  branch="$1"
    #|  out="$2"
    #|  i=0
    #|  while [ "$i" -lt 60 ]; do
    #|    result="$(cd "$ROOT/repo" && gh pr list --head "$branch" --state open --json number,url,state --template '{{range .}}{{.number}} {{.url}} {{.state}}{{"\n"}}{{end}}')"
    #|    if [ -n "$result" ]; then
    #|      printf '%s\n' "$result" > "$out"
    #|      return 0
    #|    fi
    #|    sleep 5
    #|    i=$((i + 1))
    #|  done
    #|  echo "error: timed out waiting for PR on branch $branch"
    #|  return 1
    #|}
    #|wait_for_notify() {
    #|  agent="$1"
    #|  i=0
    #|  while [ "$i" -lt 60 ]; do
    #|    pane="$(tmux capture-pane -p -S -1000 -t "$SESSION:Server")"
    #|    if printf '%s' "$pane" | grep -F "notify_parent" >/dev/null 2>&1 && \
    #|       printf '%s' "$pane" | grep -F "\"caller_id\":\"$agent\"" >/dev/null 2>&1; then
    #|      return 0
    #|    fi
    #|    sleep 5
    #|    i=$((i + 1))
    #|  done
    #|  echo "error: timed out waiting for notify_parent from $agent"
    #|  return 1
    #|}
    #|wait_for_poller_tracking() {
    #|  agent="$1"
    #|  i=0
    #|  while [ "$i" -lt 60 ]; do
    #|    if grep -F "\"agent_id\":\"$agent\"" "$ROOT/repo/.choir/poller_state.json" >/dev/null 2>&1; then
    #|      return 0
    #|    fi
    #|    sleep 5
    #|    i=$((i + 1))
    #|  done
    #|  echo "error: timed out waiting for poller tracking for $agent"
    #|  return 1
    #|}
    #|spawn_leaf "$MOON_SLUG" "moon_pilot"
    #|wait_for_pr "$MOON_BRANCH" "$ROOT/moon.pr"
    #|wait_for_notify "$MOON_BRANCH"
    #|wait_for_poller_tracking "$MOON_BRANCH"
    #|MOON_PR="$(cut -d' ' -f1 "$ROOT/moon.pr")"
    #|spawn_leaf "$GEMINI_SLUG" "gemini"
    #|wait_for_pr "$GEMINI_BRANCH" "$ROOT/gemini.pr"
    #|wait_for_notify "$GEMINI_BRANCH"
    #|wait_for_poller_tracking "$GEMINI_BRANCH"
    #|GEMINI_PR="$(cut -d' ' -f1 "$ROOT/gemini.pr")"
    #|echo "leaf smoke ok: moon pilot and gemini created PRs and notified parent"
  ) +
  "\n"
}

///|
fn smoke_companion_script() -> String {
  (
    #|set -eu
    #|BIN="$1"
    #|KEEP_TEMP="$2"
    #|REPO="$3"
    #|ROOT="$(mktemp -d "${TMPDIR:-/tmp}/choir-companion-smoke-XXXXXX")"
    #|SESSION="choir-companion-smoke-$$"
    #|ROOT_BRANCH="live-smoke/companion-root-$$"
    #|COMPANION_BRANCH="$ROOT_BRANCH.companion.monitor"
    #|cleanup() {
    #|  status=$?
    #|  tmux kill-session -t "$SESSION" >/dev/null 2>&1 || true
    #|  git -C "$REPO" worktree remove --force "$ROOT/repo/.choir/agents/monitor" >/dev/null 2>&1 || true
    #|  git -C "$REPO" worktree remove --force "$ROOT/repo" >/dev/null 2>&1 || true
    #|  git -C "$REPO" branch -D "$COMPANION_BRANCH" >/dev/null 2>&1 || true
    #|  git -C "$REPO" branch -D "$ROOT_BRANCH" >/dev/null 2>&1 || true
    #|  if [ "$KEEP_TEMP" = "1" ] || [ "$status" -ne 0 ]; then
    #|    echo "companion smoke artifacts: $ROOT"
    #|  else
    #|    rm -rf "$ROOT"
    #|  fi
    #|}
    #|trap cleanup EXIT INT TERM
    #|for cmd in tmux git; do
    #|  command -v "$cmd" >/dev/null 2>&1 || {
    #|    echo "error: required command not found: $cmd"
    #|    exit 1
    #|  }
    #|done
    #|git -C "$REPO" rev-parse --verify main >/dev/null 2>&1
    #|git -C "$REPO" worktree add -b "$ROOT_BRANCH" "$ROOT/repo" main >/dev/null
    #|mkdir -p "$ROOT/repo/.choir"
    #|cat > "$ROOT/repo/.choir/config.toml" <<EOF
    #|default_role = "tl"
    #|project_dir = "."
    #|listen_uds = ".choir/server.sock"
    #|terminal_backend = "tmux"
    #|terminal_session = "$SESSION"
    #|companions_json = '[{"name":"monitor","role":"dev","command":"sh","task":"ignored"}]'
    #|EOF
    #|(cd "$ROOT/repo" && "$BIN" init --recreate --no-attach >"$ROOT/init.log" 2>&1 || { cat "$ROOT/init.log"; exit 1; })
    #|AGENT_DIR="$ROOT/repo/.choir/agents/monitor"
    #|git -C "$AGENT_DIR" rev-parse --is-inside-work-tree >/dev/null
    #|test "$(git -C "$AGENT_DIR" branch --show-current)" = "$COMPANION_BRANCH"
    #|grep -F "\"--name\",\"$COMPANION_BRANCH\"" "$AGENT_DIR/.mcp.json" >/dev/null
    #|grep -F "agent_id = \"$COMPANION_BRANCH\"" "$AGENT_DIR/.choir/config.local.toml" >/dev/null
    #|grep -F "parent_branch = \"$ROOT_BRANCH\"" "$AGENT_DIR/.choir/config.local.toml" >/dev/null
    #|grep -F "terminal_target = \"$SESSION:monitor\"" "$AGENT_DIR/.choir/config.local.toml" >/dev/null
    #|tmux list-windows -t "$SESSION" | grep -E '^[0-9]+: monitor' >/dev/null
    #|echo "companion smoke ok: init created isolated companion worktree and config"
  ) +
  "\n"
}

///|
fn smoke_review_script() -> String {
  (
    #|set -eu
    #|BIN="$1"
    #|KEEP_TEMP="$2"
    #|REPO="$3"
    #|ROOT="$(mktemp -d "${TMPDIR:-/tmp}/choir-review-smoke-XXXXXX")"
    #|SESSION="choir-review-smoke-$$"
    #|ROOT_BRANCH="live-smoke/review-root-$$"
    #|MOON_SLUG="moon-review-smoke-$$"
    #|MOON_BRANCH="main.$MOON_SLUG"
    #|MOON_PR=""
    #|REVIEW_BODY="Smoke review comment: please tighten the doc wording."
    #|cleanup() {
    #|  status=$?
    #|  if [ -n "$MOON_PR" ]; then
    #|    gh pr close "$MOON_PR" --delete-branch >/dev/null 2>&1 || true
    #|  fi
    #|  tmux kill-session -t "$SESSION" >/dev/null 2>&1 || true
    #|  git -C "$REPO" worktree remove --force "$ROOT/repo/.choir/worktrees/$MOON_SLUG" >/dev/null 2>&1 || true
    #|  git -C "$REPO" worktree remove --force "$ROOT/repo" >/dev/null 2>&1 || true
    #|  git -C "$REPO" branch -D "$MOON_BRANCH" >/dev/null 2>&1 || true
    #|  git -C "$REPO" branch -D "$ROOT_BRANCH" >/dev/null 2>&1 || true
    #|  if [ "$KEEP_TEMP" = "1" ] || [ "$status" -ne 0 ]; then
    #|    echo "review smoke artifacts: $ROOT"
    #|  else
    #|    rm -rf "$ROOT"
    #|  fi
    #|}
    #|trap cleanup EXIT INT TERM
    #|for cmd in timeout gh tmux moon; do
    #|  command -v "$cmd" >/dev/null 2>&1 || {
    #|    echo "error: required command not found: $cmd"
    #|    exit 1
    #|  }
    #|done
    #|git -C "$REPO" rev-parse --verify main >/dev/null 2>&1
    #|git -C "$REPO" worktree add -b "$ROOT_BRANCH" "$ROOT/repo" main >/dev/null
    #|mkdir -p "$ROOT/repo/.choir"
    #|cat > "$ROOT/repo/.choir/config.toml" <<EOF
    #|default_role = "tl"
    #|project_dir = "."
    #|listen_uds = ".choir/server.sock"
    #|terminal_session = "$SESSION"
    #|EOF
    #|(cd "$ROOT/repo" && "$BIN" init --recreate --no-attach >"$ROOT/init.log" 2>&1 || { cat "$ROOT/init.log"; exit 1; })
    #|cat > "$ROOT/moon.req.jsonl" <<EOF
    #|{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
    #|{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"fork_wave","arguments":{"caller_id":"root-smoke","slug_prefix":"$MOON_SLUG","count":"1","agent_type":"moon_pilot","parent_branch":"main","task":"Make a tiny doc-only change to CLAUDE.md, run moon fmt and moon test --target native, commit it, file a PR through file_pr, notify_parent with the returned PR URL, and remain available in the session for follow-up review feedback. Do not use raw gh commands.","read_first":"AGENTS.md\nCLAUDE.md","done_criteria":"A PR is filed through file_pr, the parent has been notified, and you remain available for review feedback."}}}
    #|EOF
    #|(cd "$ROOT/repo" && cat "$ROOT/moon.req.jsonl" | timeout 120 "$BIN" mcp-stdio --name root-smoke >"$ROOT/moon.out" 2>"$ROOT/moon.err")
    #|wait_for_pr() {
    #|  branch="$1"
    #|  out="$2"
    #|  i=0
    #|  while [ "$i" -lt 60 ]; do
    #|    result="$(cd "$ROOT/repo" && gh pr list --head "$branch" --state open --json number,url,state --template '{{range .}}{{.number}} {{.url}} {{.state}}{{"\n"}}{{end}}')"
    #|    if [ -n "$result" ]; then
    #|      printf '%s\n' "$result" > "$out"
    #|      return 0
    #|    fi
    #|    sleep 5
    #|    i=$((i + 1))
    #|  done
    #|  echo "error: timed out waiting for PR on branch $branch"
    #|  return 1
    #|}
    #|wait_for_notify() {
    #|  agent="$1"
    #|  i=0
    #|  while [ "$i" -lt 60 ]; do
    #|    pane="$(tmux capture-pane -p -S -1000 -t "$SESSION:Server")"
    #|    if printf '%s' "$pane" | grep -F "notify_parent" >/dev/null 2>&1 && \
    #|       printf '%s' "$pane" | grep -F "\"caller_id\":\"$agent\"" >/dev/null 2>&1; then
    #|      return 0
    #|    fi
    #|    sleep 5
    #|    i=$((i + 1))
    #|  done
    #|  echo "error: timed out waiting for notify_parent from $agent"
    #|  return 1
    #|}
    #|wait_for_poller_tracking() {
    #|  agent="$1"
    #|  i=0
    #|  while [ "$i" -lt 60 ]; do
    #|    if grep -F "\"agent_id\":\"$agent\"" "$ROOT/repo/.choir/poller_state.json" >/dev/null 2>&1; then
    #|      return 0
    #|    fi
    #|    sleep 5
    #|    i=$((i + 1))
    #|  done
    #|  echo "error: timed out waiting for poller tracking for $agent"
    #|  return 1
    #|}
    #|wait_for_leaf_review() {
    #|  pane_target="$1"
    #|  review_body="$2"
    #|  i=0
    #|  while [ "$i" -lt 60 ]; do
    #|    pane="$(tmux capture-pane -p -S -1000 -t "$pane_target")"
    #|    if printf '%s' "$pane" | grep -F "$review_body" >/dev/null 2>&1; then
    #|      return 0
    #|    fi
    #|    sleep 5
    #|    i=$((i + 1))
    #|  done
    #|  echo "error: timed out waiting for review delivery in $pane_target"
    #|  return 1
    #|}
    #|wait_for_pr "$MOON_BRANCH" "$ROOT/moon.pr"
    #|wait_for_notify "$MOON_BRANCH"
    #|wait_for_poller_tracking "$MOON_BRANCH"
    #|MOON_PR="$(cut -d' ' -f1 "$ROOT/moon.pr")"
    #|(cd "$ROOT/repo" && gh pr review "$MOON_PR" --comment -b "$REVIEW_BODY")
    #|wait_for_leaf_review "$SESSION:$MOON_SLUG" "$REVIEW_BODY"
    #|echo "review smoke ok: moon pilot received live review feedback"
  ) +
  "\n"
}

///|
fn smoke_e2e_script() -> String {
  (
    #|set -eu
    #|BIN="$1"
    #|KEEP_TEMP="$2"
    #|REPO="$3"
    #|ROOT="$(mktemp -d "${TMPDIR:-/tmp}/choir-e2e-smoke-XXXXXX")"
    #|SESSION="choir-e2e-smoke-$$"
    #|ROOT_BRANCH="live-smoke.e2e-root-$$"
    #|MOON_SLUG="moon-e2e-smoke-$$"
    #|MOON_BRANCH="$ROOT_BRANCH.$MOON_SLUG"
    #|MOON_PR=""
    #|REVIEW_BODY="Smoke review comment: please tighten the doc wording."
    #|cleanup() {
    #|  status=$?
    #|  if [ -n "$MOON_PR" ]; then
    #|    gh pr close "$MOON_PR" >/dev/null 2>&1 || true
    #|  fi
    #|  git -C "$REPO" push origin --delete "$MOON_BRANCH" >/dev/null 2>&1 || true
    #|  git -C "$REPO" push origin --delete "$ROOT_BRANCH" >/dev/null 2>&1 || true
    #|  tmux kill-session -t "$SESSION" >/dev/null 2>&1 || true
    #|  git -C "$REPO" worktree remove --force "$ROOT/repo/.choir/worktrees/$MOON_SLUG" >/dev/null 2>&1 || true
    #|  git -C "$REPO" worktree remove --force "$ROOT/repo" >/dev/null 2>&1 || true
    #|  git -C "$REPO" branch -D "$MOON_BRANCH" >/dev/null 2>&1 || true
    #|  git -C "$REPO" branch -D "$ROOT_BRANCH" >/dev/null 2>&1 || true
    #|  if [ "$KEEP_TEMP" = "1" ] || [ "$status" -ne 0 ]; then
    #|    echo "e2e smoke artifacts: $ROOT"
    #|  else
    #|    rm -rf "$ROOT"
    #|  fi
    #|}
    #|trap cleanup EXIT INT TERM
    #|for cmd in timeout gh tmux moon git; do
    #|  command -v "$cmd" >/dev/null 2>&1 || {
    #|    echo "error: required command not found: $cmd"
    #|    exit 1
    #|  }
    #|done
    #|git -C "$REPO" rev-parse --verify main >/dev/null 2>&1
    #|git -C "$REPO" worktree add -b "$ROOT_BRANCH" "$ROOT/repo" main >/dev/null
    #|(cd "$ROOT/repo" && git push -u origin "$ROOT_BRANCH" >/dev/null)
    #|mkdir -p "$ROOT/repo/.choir"
    #|cat > "$ROOT/repo/.choir/config.toml" <<EOF
    #|default_role = "tl"
    #|project_dir = "."
    #|listen_uds = ".choir/server.sock"
    #|terminal_session = "$SESSION"
    #|EOF
    #|(cd "$ROOT/repo" && "$BIN" init --recreate --no-attach >"$ROOT/init.log" 2>&1 || { cat "$ROOT/init.log"; exit 1; })
    #|cat > "$ROOT/moon.req.jsonl" <<EOF
    #|{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
    #|{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"fork_wave","arguments":{"caller_id":"root-smoke","slug_prefix":"$MOON_SLUG","count":"1","agent_type":"moon_pilot","parent_branch":"$ROOT_BRANCH","task":"Make a tiny doc-only change to CLAUDE.md, run moon fmt and moon test --target native, commit it, file a PR through file_pr, notify_parent with the returned PR URL, and remain available in the session for follow-up review feedback. Do not use raw gh commands.","read_first":"AGENTS.md\nCLAUDE.md","done_criteria":"A PR is filed through file_pr, the parent has been notified, and you remain available for review feedback."}}}
    #|EOF
    #|(cd "$ROOT/repo" && cat "$ROOT/moon.req.jsonl" | timeout 120 "$BIN" mcp-stdio --name root-smoke >"$ROOT/moon.out" 2>"$ROOT/moon.err")
    #|wait_for_pr() {
    #|  branch="$1"
    #|  out="$2"
    #|  i=0
    #|  while [ "$i" -lt 60 ]; do
    #|    result="$(cd "$ROOT/repo" && gh pr list --head "$branch" --state open --json number,url,state --template '{{range .}}{{.number}} {{.url}} {{.state}}{{"\n"}}{{end}}')"
    #|    if [ -n "$result" ]; then
    #|      printf '%s\n' "$result" > "$out"
    #|      return 0
    #|    fi
    #|    sleep 5
    #|    i=$((i + 1))
    #|  done
    #|  echo "error: timed out waiting for PR on branch $branch"
    #|  return 1
    #|}
    #|wait_for_notify() {
    #|  agent="$1"
    #|  i=0
    #|  while [ "$i" -lt 60 ]; do
    #|    pane="$(tmux capture-pane -p -S -1000 -t "$SESSION:Server")"
    #|    if printf '%s' "$pane" | grep -F "notify_parent" >/dev/null 2>&1 && \
    #|       printf '%s' "$pane" | grep -F "\"caller_id\":\"$agent\"" >/dev/null 2>&1; then
    #|      return 0
    #|    fi
    #|    sleep 5
    #|    i=$((i + 1))
    #|  done
    #|  echo "error: timed out waiting for notify_parent from $agent"
    #|  return 1
    #|}
    #|wait_for_poller_tracking() {
    #|  agent="$1"
    #|  i=0
    #|  while [ "$i" -lt 60 ]; do
    #|    if grep -F "\"agent_id\":\"$agent\"" "$ROOT/repo/.choir/poller_state.json" >/dev/null 2>&1; then
    #|      return 0
    #|    fi
    #|    sleep 5
    #|    i=$((i + 1))
    #|  done
    #|  echo "error: timed out waiting for poller tracking for $agent"
    #|  return 1
    #|}
    #|wait_for_leaf_review() {
    #|  pane_target="$1"
    #|  review_body="$2"
    #|  i=0
    #|  while [ "$i" -lt 60 ]; do
    #|    pane="$(tmux capture-pane -p -S -1000 -t "$pane_target")"
    #|    if printf '%s' "$pane" | grep -F "$review_body" >/dev/null 2>&1; then
    #|      return 0
    #|    fi
    #|    sleep 5
    #|    i=$((i + 1))
    #|  done
    #|  echo "error: timed out waiting for review delivery in $pane_target"
    #|  return 1
    #|}
    #|wait_for_pr_merged() {
    #|  pr="$1"
    #|  i=0
    #|  while [ "$i" -lt 60 ]; do
    #|    state="$(cd "$ROOT/repo" && gh pr view "$pr" --json state --template '{{.state}}' 2>/dev/null || true)"
    #|    if [ "$state" = "MERGED" ]; then
    #|      return 0
    #|    fi
    #|    sleep 2
    #|    i=$((i + 1))
    #|  done
    #|  echo "error: timed out waiting for merged PR #$pr"
    #|  return 1
    #|}
    #|wait_for_untracked() {
    #|  agent="$1"
    #|  i=0
    #|  while [ "$i" -lt 60 ]; do
    #|    if [ ! -f "$ROOT/repo/.choir/poller_state.json" ] || ! grep -F "\"agent_id\":\"$agent\"" "$ROOT/repo/.choir/poller_state.json" >/dev/null 2>&1; then
    #|      return 0
    #|    fi
    #|    sleep 2
    #|    i=$((i + 1))
    #|  done
    #|  echo "error: timed out waiting for poller untrack of $agent"
    #|  return 1
    #|}
    #|wait_for_pr "$MOON_BRANCH" "$ROOT/moon.pr"
    #|wait_for_notify "$MOON_BRANCH"
    #|wait_for_poller_tracking "$MOON_BRANCH"
    #|MOON_PR="$(cut -d' ' -f1 "$ROOT/moon.pr")"
    #|(cd "$ROOT/repo" && gh pr review "$MOON_PR" --comment -b "$REVIEW_BODY")
    #|wait_for_leaf_review "$SESSION:$MOON_SLUG" "$REVIEW_BODY"
    #|cat > "$ROOT/merge.req.jsonl" <<EOF
    #|{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
    #|{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"merge_pr","arguments":{"caller_id":"root-smoke","pr_number":"$MOON_PR","parent_branch":"$ROOT_BRANCH"}}}
    #|EOF
    #|(cd "$ROOT/repo" && cat "$ROOT/merge.req.jsonl" | timeout 60 "$BIN" mcp-stdio --name root-smoke >"$ROOT/merge.out" 2>"$ROOT/merge.err")
    #|wait_for_pr_merged "$MOON_PR"
    #|wait_for_untracked "$MOON_BRANCH"
    #|echo "e2e smoke ok: moon pilot PR was reviewed and merged via choir"
  ) +
  "\n"
}

///|
fn smoke_run() -> Unit raise {
  @async.with_event_loop(async fn(_root) {
    let args = @io.get_args()
    let keep_temp = if smoke_keep_temp(args) { "1" } else { "0" }
    let self_exe = smoke_self_exe(args)
    let repo_dir = @io.getcwd()
    let script = if smoke_e2e_enabled(args) {
      @io.write_stdout("Running isolated live end-to-end smoke...\n")
      smoke_e2e_script()
    } else if smoke_companions_enabled(args) {
      @io.write_stdout("Running isolated companion smoke...\n")
      smoke_companion_script()
    } else if smoke_review_enabled(args) {
      @io.write_stdout("Running isolated review smoke...\n")
      smoke_review_script()
    } else if smoke_leafs_enabled(args) {
      @io.write_stdout("Running isolated leaf smoke...\n")
      smoke_leaf_script()
    } else {
      @io.write_stdout("Running isolated runtime smoke...\n")
      smoke_script()
    }
    let exit_code = @exec.run({
      program: "sh",
      args: ["-c", script, "sh", self_exe, keep_temp, repo_dir],
      workdir: None,
    }) catch {
      _ => 1
    }
    @io.exit(exit_code)
  })
}

///|
test "smoke keep temp flag parser" {
  assert_false(smoke_keep_temp(["choir", "smoke"]))
  assert_true(smoke_keep_temp(["choir", "smoke", "--keep-temp"]))
}

///|
test "init no attach flag parser" {
  assert_false(init_no_attach(["choir", "init"]))
  assert_true(init_no_attach(["choir", "init", "--no-attach"]))
}

///|
test "companion commands use isolated worktree with unique choir identity" {
  let config = {
    ..@types.Config::default(),
    extra_mcp_servers_json: Some("{\"extra\":{\"type\":\"stdio\"}}"),
  }
  let cmds = init_companion_commands(
    "/proj",
    "choir",
    @types.TerminalBackend::Tmux,
    config,
    "main",
    { name: "monitor", role: "dev", command: "claude", task: "watch tests" },
  )
  assert_eq(cmds.length(), 9)
  assert_eq(cmds[0].program, "sh")
  assert_true(cmds[0].args[3].contains("/proj/.choir/agents/monitor"))
  assert_true(cmds[0].args[4].contains("main.companion.monitor"))
  assert_eq(cmds[1].program, "git")
  assert_eq(cmds[1].args, [
    "worktree", "add", "/proj/.choir/agents/monitor", "-b", "main.companion.monitor",
  ])
  assert_true(cmds[2].args[4].contains("default_role = \"dev\""))
  assert_true(cmds[2].args[4].contains("terminal_session = \"choir\""))
  assert_true(cmds[3].args[4].contains("agent_id = \"main.companion.monitor\""))
  assert_true(cmds[3].args[4].contains("parent_branch = \"main\""))
  assert_true(cmds[3].args[4].contains("terminal_target = \"choir:monitor\""))
  assert_true(cmds[3].args[4].contains("agent_type = \"claude\""))
  assert_true(cmds[4].args[4].contains("\"--role\",\"dev\""))
  assert_true(cmds[4].args[4].contains("main.companion.monitor"))
  assert_true(cmds[4].args[4].contains("\"extra\":{\"type\":\"stdio\"}"))
  assert_eq(cmds[7].args, [
    "new-window", "-t", "choir", "-n", "monitor", "-c", "/proj/.choir/agents/monitor",
  ])
  assert_true(cmds[8].args[3].contains(".choir/bin"))
  assert_true(
    cmds[8].args[3].contains("CHOIR_AGENT_ID='main.companion.monitor'"),
  )
}

///|
test "companion gemini commands trust workspace and use zellij tab cwd" {
  let cmds = init_companion_commands(
    "/proj",
    "howdy",
    @types.TerminalBackend::Zellij,
    @types.Config::default(),
    "main",
    {
      name: "gem-helper",
      role: "worker",
      command: "gemini --model flash",
      task: "reply READY",
    },
  )
  assert_eq(cmds.length(), 9)
  assert_eq(cmds[7].program, "choir")
  assert_eq(cmds[7].args, [
    "trust-gemini-folder", "/proj/.choir/agents/gem-helper",
  ])
  assert_eq(cmds[8].program, "zellij")
  assert_eq(cmds[8].args[0], "--session")
  assert_eq(cmds[8].args[1], "howdy")
  assert_eq(cmds[8].args[2], "action")
  assert_eq(cmds[8].args[3], "new-tab")
  assert_eq(cmds[8].args[7], "/proj/.choir/agents/gem-helper")
  assert_true(
    cmds[8].args[11].contains(
      "CHOIR_TERMINAL_TARGET='zellij-tab:howdy:gem-helper'",
    ),
  )
}

///|
test "init choir source tree detection only matches choir source markers" {
  assert_true(
    init_is_choir_source_files(
      "{\"name\":\"choir\",\"version\":\"0.1.0\"}", "fn main {}",
    ),
  )
  assert_true(
    init_is_choir_source_files("{\n  \"name\": \"choir\"\n}", "fn main {}"),
  )
  assert_false(init_is_choir_source_files("", "fn main {}"))
  assert_false(init_is_choir_source_files("{\"name\":\"other\"}", "fn main {}"))
  assert_false(init_is_choir_source_files("{\"name\":\"choir\"}", ""))
}

///|
test "init server command switches between dev and serve" {
  assert_eq(init_server_command(true), "choir dev")
  assert_eq(init_server_command(false), "choir serve")
}

///|
test "init default terminal session is derived from project path" {
  assert_eq(
    init_default_terminal_session(
      "/mnt/data/Code/live2d_investigation/pixi-live2d5",
    ),
    "choir-pixi-live2d5",
  )
  assert_eq(
    init_default_terminal_session("/mnt/data/Code/resorter.py"),
    "choir-resorter-py",
  )
  assert_eq(init_default_terminal_session("/"), "choir-project")
}

///|
test "init config content includes derived terminal session" {
  let content = init_config_toml_content("choir-demo")
  assert_true(content.contains("terminal_session = \"choir-demo\""))
  assert_true(init_config_has_terminal_session(content))
  assert_false(init_config_has_terminal_session("default_role = \"tl\"\n"))
}

///|
fn init_session_exists_command(
  terminal_backend : @types.TerminalBackend,
  session : String,
) -> @workspace.Command {
  match terminal_backend {
    @types.TerminalBackend::Tmux =>
      {
        program: "sh",
        args: ["-c", "tmux has-session -t \"$1\" 2>/dev/null", "sh", session],
        workdir: None,
      }
    @types.TerminalBackend::Zellij => @workspace.zellij_session_exists(session)
  }
}

///|
fn init_kill_session_command(
  terminal_backend : @types.TerminalBackend,
  session : String,
) -> @workspace.Command {
  match terminal_backend {
    @types.TerminalBackend::Tmux =>
      { program: "tmux", args: ["kill-session", "-t", session], workdir: None }
    @types.TerminalBackend::Zellij => @workspace.zellij_kill_session(session)
  }
}

///|
fn init_kill_server_pid_command(pid_str : String) -> @workspace.Command {
  {
    program: "sh",
    args: [
      "-c", "kill -TERM \"$1\" 2>/dev/null; sleep 0.3; kill -KILL \"$1\" 2>/dev/null; true",
      "sh", pid_str,
    ],
    workdir: None,
  }
}

///|
fn init_cleanup_server_artifacts_command() -> @workspace.Command {
  {
    program: "sh",
    args: ["-c", "rm -f .choir/server.pid .choir/server.sock"],
    workdir: None,
  }
}

///|
test "init session lifecycle commands match backend" {
  let tmux_exists = init_session_exists_command(
    @types.TerminalBackend::Tmux,
    "choir",
  )
  assert_eq(tmux_exists.program, "sh")
  assert_eq(tmux_exists.args[3], "choir")

  let zellij_exists = init_session_exists_command(
    @types.TerminalBackend::Zellij,
    "choir",
  )
  assert_eq(zellij_exists.program, "sh")
  assert_true(zellij_exists.args[1].contains("zellij list-sessions"))

  let tmux_kill = init_kill_session_command(
    @types.TerminalBackend::Tmux,
    "choir",
  )
  assert_eq(tmux_kill.args, ["kill-session", "-t", "choir"])

  let zellij_kill = init_kill_session_command(
    @types.TerminalBackend::Zellij,
    "choir",
  )
  assert_eq(zellij_kill.args, ["delete-session", "--force", "choir"])
}

///|
test "init server cleanup commands cover pid and socket teardown" {
  let kill_cmd = init_kill_server_pid_command("123")
  assert_eq(kill_cmd.program, "sh")
  assert_eq(kill_cmd.args[3], "123")
  let cleanup_cmd = init_cleanup_server_artifacts_command()
  assert_eq(cleanup_cmd.program, "sh")
  assert_true(cleanup_cmd.args[1].contains(".choir/server.pid"))
  assert_true(cleanup_cmd.args[1].contains(".choir/server.sock"))
}

///|
test "smoke review flag parser" {
  assert_false(smoke_review_enabled(["choir", "smoke"]))
  assert_true(smoke_review_enabled(["choir", "smoke", "--review"]))
}

///|
test "smoke leaf flag parser" {
  assert_false(smoke_leafs_enabled(["choir", "smoke"]))
  assert_true(smoke_leafs_enabled(["choir", "smoke", "--leafs"]))
}

///|
test "smoke companion flag parser" {
  assert_false(smoke_companions_enabled(["choir", "smoke"]))
  assert_true(smoke_companions_enabled(["choir", "smoke", "--companions"]))
}

///|
test "smoke e2e flag parser" {
  assert_false(smoke_e2e_enabled(["choir", "smoke"]))
  assert_true(smoke_e2e_enabled(["choir", "smoke", "--e2e-live"]))
}

///|
test "smoke self exe resolves relative binary path" {
  let cwd = @io.getcwd()
  assert_eq(smoke_self_exe(["choir"]), "choir")
  assert_eq(smoke_self_exe(["/tmp/choir"]), "/tmp/choir")
  assert_eq(
    smoke_self_exe(["./_build/native/release/build/src/bin/choir/choir.exe"]),
    cwd + "/./_build/native/release/build/src/bin/choir/choir.exe",
  )
}

///|
test "smoke script covers EOF and multi-client checks" {
  let script = smoke_script()
  assert_true(script.contains("mcp-stdio --name smoke-proof"))
  assert_true(script.contains("mcp-stdio --name hold-open"))
  assert_true(script.contains("mcp-stdio --name second-client"))
  assert_true(script.contains("runtime-proof-task-1"))
  assert_true(script.contains("runtime-proof-task-2"))
  assert_true(script.contains("validation error:"))
  assert_true(script.contains("smoke ok: EOF and multi-client checks passed"))
}

///|
test "smoke leaf script covers Moon Pilot and Gemini proof" {
  let script = smoke_leaf_script()
  assert_true(script.contains("fork_wave"))
  assert_true(script.contains("moon_pilot"))
  assert_true(script.contains("gemini"))
  assert_true(script.contains("wait_for_pr"))
  assert_true(script.contains("wait_for_notify"))
  assert_true(script.contains("wait_for_poller_tracking"))
  assert_true(
    script.contains(
      "leaf smoke ok: moon pilot and gemini created PRs and notified parent",
    ),
  )
}

///|
test "smoke companion script covers isolated companion proof" {
  let script = smoke_companion_script()
  assert_true(script.contains("companions_json"))
  assert_true(
    script.contains("COMPANION_BRANCH=\"$ROOT_BRANCH.companion.monitor\""),
  )
  assert_true(script.contains("terminal_target = "))
  assert_true(script.contains("$SESSION:monitor"))
  assert_true(
    script.contains(
      "companion smoke ok: init created isolated companion worktree and config",
    ),
  )
}

///|
test "smoke review script covers live review delivery proof" {
  let script = smoke_review_script()
  assert_true(script.contains("fork_wave"))
  assert_true(script.contains("gh pr review"))
  assert_true(script.contains("wait_for_leaf_review"))
  assert_true(
    script.contains("review smoke ok: moon pilot received live review feedback"),
  )
}

///|
test "smoke e2e script covers review and merge proof" {
  let script = smoke_e2e_script()
  assert_true(script.contains("git push -u origin \"$ROOT_BRANCH\""))
  assert_true(script.contains("fork_wave"))
  assert_true(script.contains("gh pr review \"$MOON_PR\" --comment"))
  assert_true(script.contains("\"name\":\"merge_pr\""))
  assert_true(script.contains("wait_for_pr_merged"))
  assert_true(script.contains("wait_for_untracked"))
  assert_true(
    script.contains(
      "e2e smoke ok: moon pilot PR was reviewed and merged via choir",
    ),
  )
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
fn init_default_terminal_session(project_dir : String) -> String {
  let mut end = project_dir.length()
  while end > 1 && project_dir[end - 1] == '/' {
    end = end - 1
  }
  let trimmed = project_dir[:end].to_string() catch { _ => project_dir }
  let base = if trimmed == "" {
    "project"
  } else {
    let mut last_slash = -1
    for i = 0; i < trimmed.length(); i = i + 1 {
      if trimmed[i] == '/' {
        last_slash = i
      }
    }
    if last_slash < 0 || last_slash + 1 >= trimmed.length() {
      trimmed
    } else {
      trimmed[last_slash + 1:].to_string() catch {
        _ => "project"
      }
    }
  }
  let buf = StringBuilder::new()
  for c in base {
    if (c >= 'a' && c <= 'z') ||
      (c >= 'A' && c <= 'Z') ||
      (c >= '0' && c <= '9') ||
      c == '-' ||
      c == '_' {
      buf.write_char(c)
    } else {
      buf.write_char('-')
    }
  }
  let normalized_raw = buf.to_string()
  let mut start = 0
  let mut finish = normalized_raw.length()
  while start < finish && normalized_raw[start] == '-' {
    start = start + 1
  }
  while finish > start && normalized_raw[finish - 1] == '-' {
    finish = finish - 1
  }
  let suffix = normalized_raw[start:finish].to_string() catch { _ => "" }
  let normalized = if suffix == "" { "project" } else { suffix }
  "choir-" + normalized
}

///|
fn init_config_toml_content(default_session : String) -> String {
  "default_role = \"tl\"\n" +
  "project_dir = \".\"\n" +
  "listen_uds = \".choir/server.sock\"\n" +
  "terminal_backend = \"tmux\"\n" +
  "terminal_session = \"" +
  default_session +
  "\"\n"
}

///|
fn init_config_has_terminal_session(content : String) -> Bool {
  content.contains("terminal_session")
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
fn init_claude_mcp_config_path() -> String {
  ".choir/claude.mcp.json"
}

///|
fn init_claude_launch_command() -> String {
  "claude --dangerously-skip-permissions --mcp-config " +
  init_claude_mcp_config_path() +
  " --strict-mcp-config; echo; echo '[Claude exited]'; exec bash -l"
}

///|
test "init claude launch command uses explicit choir mcp config" {
  let cmd = init_claude_launch_command()
  assert_true(cmd.contains("--mcp-config .choir/claude.mcp.json"))
  assert_true(cmd.contains("--strict-mcp-config"))
  assert_false(cmd.contains(" .mcp.json"))
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
fn init_shell_quote(s : String) -> String {
  "'" + init_escape_shell_single_quoted(s) + "'"
}

///|
fn init_env_assignment(key : String, value : String) -> String {
  key + "=" + init_shell_quote(value)
}

///|
fn init_split_words(s : String) -> Array[String] {
  let parts : Array[String] = []
  let trimmed = s.trim().to_string()
  let mut start = 0
  for i = 0; i <= trimmed.length(); i = i + 1 {
    if i == trimmed.length() || trimmed[i] == ' ' {
      if i > start {
        parts.push(trimmed[start:i].to_string() catch { _ => "" })
      }
      start = i + 1
    }
  }
  parts
}

///|
fn init_companion_role(role : String) -> @types.Role {
  match @config.parse_role(role) {
    Ok(parsed) => parsed
    Err(_) => @types.Role::Worker
  }
}

///|
fn init_companion_branch(parent_branch : String, name : String) -> String {
  parent_branch + ".companion." + name
}

///|
fn init_companion_agent_type(command : String) -> @types.AgentType? {
  let parts = init_split_words(command)
  if parts.is_empty() {
    return None
  }
  let first = parts[0]
  if first == "claude" || first.has_suffix("/claude") {
    return Some(@types.AgentType::Claude)
  }
  if first == "gemini" || first.has_suffix("/gemini") {
    return Some(@types.AgentType::Gemini)
  }
  if (first == "moon" || first.has_suffix("/moon")) &&
    parts.length() > 1 &&
    parts[1] == "pilot" {
    return Some(@types.AgentType::MoonPilot)
  }
  None
}

///|
fn init_companion_local_config_content(
  role : @types.Role,
  agent_id : String,
  parent_id : String,
  branch : String,
  parent_branch : String,
  workspace : String,
  terminal_target : String,
  agent_type? : @types.AgentType? = None,
) -> String {
  let buf = StringBuilder::new()
  buf.write_string("role = \"")
  buf.write_string(@config.role_to_string(role))
  buf.write_string("\"\nagent_id = \"")
  buf.write_string(agent_id)
  buf.write_string("\"\nparent_id = \"")
  buf.write_string(parent_id)
  buf.write_string("\"\nbranch = \"")
  buf.write_string(branch)
  buf.write_string("\"\nparent_branch = \"")
  buf.write_string(parent_branch)
  buf.write_string("\"\nworkspace = \"")
  buf.write_string(workspace)
  buf.write_string("\"\nterminal_target = \"")
  buf.write_string(terminal_target)
  buf.write_string("\"\n")
  match agent_type {
    Some(kind) => {
      buf.write_string("agent_type = \"")
      buf.write_string(@config.agent_type_to_string(kind))
      buf.write_string("\"\n")
    }
    None => ()
  }
  buf.to_string()
}

///|
fn init_companion_launch_prefix(
  role : @types.Role,
  agent_id : String,
  parent_id : String,
  branch : String,
  parent_branch : String,
  workspace : String,
  terminal_backend : @types.TerminalBackend,
  terminal_target : String,
  session : String,
  agent_type? : @types.AgentType? = None,
) -> String {
  let assignments : Array[String] = [
    "PATH=" + init_shell_quote(workspace + "/.choir/bin") + ":$PATH",
    init_env_assignment("CHOIR_AGENT_ID", agent_id),
    init_env_assignment("CHOIR_PARENT_ID", parent_id),
    init_env_assignment("CHOIR_BRANCH", branch),
    init_env_assignment("CHOIR_PARENT_BRANCH", parent_branch),
    init_env_assignment("CHOIR_WORKSPACE", workspace),
    init_env_assignment("CHOIR_ROLE", @config.role_to_string(role)),
    init_env_assignment(
      "CHOIR_TERMINAL_BACKEND",
      @config.terminal_backend_to_string(terminal_backend),
    ),
    init_env_assignment("CHOIR_TERMINAL_TARGET", terminal_target),
    init_env_assignment("CHOIR_TERMINAL_SESSION", session),
    init_env_assignment("EXOMONAD_AGENT_ID", agent_id),
    init_env_assignment("EXOMONAD_SESSION_ID", agent_id),
    init_env_assignment("EXOMONAD_ROLE", @config.role_to_string(role)),
    init_env_assignment("EXOMONAD_PARENT_AGENT", parent_id),
  ]
  match agent_type {
    Some(kind) =>
      assignments.push(
        init_env_assignment(
          "CHOIR_AGENT_TYPE",
          @config.agent_type_to_string(kind),
        ),
      )
    None => ()
  }
  match @io.getenv("TRACEPARENT") {
    Some(value) =>
      if value != "" {
        assignments.push(init_env_assignment("TRACEPARENT", value))
      }
    None => ()
  }
  let buf = StringBuilder::new()
  for i = 0; i < assignments.length(); i = i + 1 {
    if i > 0 {
      buf.write_char(' ')
    }
    buf.write_string(assignments[i])
  }
  buf.to_string() + " "
}

///|
fn init_companion_commands(
  project_dir : String,
  session : String,
  terminal_backend : @types.TerminalBackend,
  config : @types.Config,
  current_branch : String,
  companion : @config.CompanionDef,
) -> Array[@workspace.Command] {
  let role = init_companion_role(companion.role)
  let branch = init_companion_branch(current_branch, companion.name)
  let workspace = project_dir + "/.choir/agents/" + companion.name
  let terminal_target = @workspace.local_target_for(
    terminal_backend,
    session,
    companion.name,
    @types.IsolationMode::Worktree,
  )
  let agent_type = init_companion_agent_type(companion.command)
  let launch_str = init_companion_launch_prefix(
      role,
      branch,
      "root",
      branch,
      current_branch,
      workspace,
      terminal_backend,
      terminal_target,
      session,
      agent_type~,
    ) +
    companion.command +
    " '" +
    init_escape_shell_single_quoted(companion.task) +
    "'"
  let cmds : Array[@workspace.Command] = [
    {
      program: "sh",
      args: [
        "-c", "git worktree remove --force \"$1\" 2>/dev/null || true; rm -rf \"$1\"; git branch -D \"$2\" 2>/dev/null || true",
        "sh", workspace, branch,
      ],
      workdir: None,
    },
    @workspace.git_worktree_add(workspace, branch),
    @workspace.write_spawn_config(
      workspace,
      @workspace.child_config_content(
        role,
        terminal_backend,
        session,
        project_dir,
        config.listen_uds,
        listen_tcp=config.listen_tcp,
        tcp_auth_token=config.tcp_auth_token,
      ),
    ),
    @workspace.write_local_config(
      workspace,
      init_companion_local_config_content(
        role,
        branch,
        "root",
        branch,
        current_branch,
        workspace,
        terminal_target,
        agent_type~,
      ),
    ),
    @workspace.write_mcp_json(
      workspace,
      @workspace.mcp_json_content(
        role,
        branch,
        extra_mcp_servers_json=config.extra_mcp_servers_json,
      ),
    ),
    @workspace.write_leaf_helper_scripts(workspace),
    {
      program: "sh",
      args: [
        "-c", "printf '%s' \"$2\" > \"$1/.birth_branch\"", "sh", workspace, branch,
      ],
      workdir: None,
    },
  ]
  if agent_type == Some(@types.AgentType::Gemini) {
    cmds.push(@workspace.trust_gemini_folder(workspace))
  }
  match terminal_backend {
    @types.TerminalBackend::Tmux => {
      cmds.push(@workspace.tmux_new_window(session, companion.name, workspace))
      cmds.push(
        @workspace.tmux_send_keys(session + ":" + companion.name, launch_str),
      )
    }
    @types.TerminalBackend::Zellij =>
      cmds.push(
        @workspace.zellij_new_tab(
          session,
          companion.name,
          workspace,
          launch_str,
        ),
      )
  }
  cmds
}

///|
fn init_is_choir_source_files(
  moon_mod_content : String,
  main_mbt_content : String,
) -> Bool {
  main_mbt_content != "" &&
  (
    moon_mod_content.contains("\"name\": \"choir\"") ||
    moon_mod_content.contains("\"name\":\"choir\"")
  )
}

///|
fn init_is_choir_source_tree(project_dir : String) -> Bool {
  init_is_choir_source_files(
    @io.read_file(project_dir + "/moon.mod.json"),
    @io.read_file(project_dir + "/src/bin/choir/main.mbt"),
  )
}

///|
fn init_server_command(use_dev : Bool) -> String {
  if use_dev {
    "choir dev"
  } else {
    "choir serve"
  }
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
    let no_attach = init_no_attach(args)
    let project_dir = @io.getcwd()
    let default_session = init_default_terminal_session(project_dir)
    let use_dev = init_is_choir_source_tree(project_dir)
    let server_cmd = init_server_command(use_dev)

    if use_dev {
      // Rebuild binary before doing anything else so the new server uses fresh code
      init_run_or_exit({
        program: "moon",
        args: ["build", "--target", "native", "--release"],
        workdir: None,
      })
    }

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
        init_config_toml_content(default_session),
      ],
      workdir: None,
    })
    let maybe_patch_config = @io.read_file(".choir/config.toml")
    if maybe_patch_config != "" &&
      not(init_config_has_terminal_session(maybe_patch_config)) {
      let separator = if maybe_patch_config.has_suffix("\n") {
        ""
      } else {
        "\n"
      }
      let patched = maybe_patch_config +
        separator +
        "terminal_session = \"" +
        default_session +
        "\"\n"
      ignore(@io.write_file_sync(".choir/config.toml", patched))
    }
    init_run_or_exit({
      program: "sh",
      args: [
        "-c",
        "printf '%s' \"$2\" > \"$1\"",
        "sh",
        init_claude_mcp_config_path(),
        init_mcp_json_content(project_dir),
      ],
      workdir: None,
    })

    let config_content = @io.read_file(".choir/config.toml")
    let config = match @config.parse_config(config_content) {
      Ok(cfg) => cfg
      Err(_) => @types.Config::default()
    }
    let current_branch_raw = capture_stdout_main("git", [
      "branch", "--show-current",
    ])
    let current_branch_trimmed = current_branch_raw.trim().to_string()
    let current_branch = if current_branch_trimmed == "" ||
      current_branch_trimmed == "HEAD" {
      "main"
    } else {
      current_branch_trimmed
    }
    let session = config.terminal_session
    let terminal_backend = config.terminal_backend

    if recreate {
      let pid_str = @io.read_file(".choir/server.pid")
      if pid_str != "" {
        @io.write_stdout("Stopping server (PID \{pid_str})...\n")
        ignore(
          @exec.run(init_kill_server_pid_command(pid_str)) catch {
            _ => 0
          },
        )
        ignore(
          @exec.run(init_cleanup_server_artifacts_command()) catch {
            _ => 0
          },
        )
      }
      let has_session = @exec.run(
        init_session_exists_command(terminal_backend, session),
      ) catch {
        _ => 1
      }
      if has_session == 0 || terminal_backend == @types.TerminalBackend::Zellij {
        @io.write_stdout("Killing session \{session}...\n")
        ignore(
          @exec.run(init_kill_session_command(terminal_backend, session)) catch {
            _ => 0
          },
        )
      }
    }

    let session_alive = @exec.run(
      init_session_exists_command(terminal_backend, session),
    ) catch {
      _ => 1
    }
    if session_alive == 0 {
      if no_attach {
        @io.write_stdout("Session \{session} already exists.\n")
      } else {
        @io.write_stdout("Attaching to existing session \{session}...\n")
        ignore(
          @exec.run(
            match terminal_backend {
              @types.TerminalBackend::Tmux =>
                {
                  program: "tmux",
                  args: ["attach-session", "-t", session],
                  workdir: None,
                }
              @types.TerminalBackend::Zellij =>
                @workspace.zellij_attach_session(session)
            },
          ) catch {
            _ => 0
          },
        )
      }
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
    match terminal_backend {
      @types.TerminalBackend::Tmux => {
        init_run_or_exit({
          program: "tmux",
          args: ["new-session", "-d", "-s", session, "-n", "Server"],
          workdir: None,
        })

        init_run_or_exit({
          program: "tmux",
          args: ["send-keys", "-t", session + ":Server", server_cmd, "Enter"],
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
            init_claude_launch_command(),
            "Enter",
          ],
          workdir: None,
        })
      }
      @types.TerminalBackend::Zellij => {
        init_run_or_exit(@workspace.zellij_create_background_session(session))
        init_run_or_exit(
          @workspace.zellij_new_tab(session, "Server", project_dir, server_cmd),
        )
        init_run_or_exit(
          @workspace.zellij_new_tab(
            session,
            "TL",
            project_dir,
            init_claude_launch_command(),
          ),
        )
        ignore(
          @exec.run({
            program: "zellij",
            args: ["--session", session, "action", "close-tab-by-id", "0"],
            workdir: None,
          }) catch {
            _ => 0
          },
        )
        ignore(
          @exec.run({
            program: "zellij",
            args: ["--session", session, "action", "go-to-tab-name", "TL"],
            workdir: None,
          }) catch {
            _ => 0
          },
        )
      }
    }

    match config.companions_json {
      Some(json) => {
        let companions = @config.parse_companions_json(json)
        for c in companions {
          for
            cmd in init_companion_commands(
              project_dir, session, terminal_backend, config, current_branch, c,
            ) {
            ignore(@exec.run(cmd) catch { _ => 0 })
          }
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

    if no_attach {
      @io.write_stdout("Session \{session} ready.\n")
    } else {
      @io.write_stdout("Attaching to session \{session}...\n")
      ignore(
        @exec.run(
          match terminal_backend {
            @types.TerminalBackend::Tmux =>
              {
                program: "tmux",
                args: ["attach-session", "-t", session],
                workdir: None,
              }
            @types.TerminalBackend::Zellij =>
              @workspace.zellij_attach_session(session)
          },
        ) catch {
          _ => 0
        },
      )
    }
  })
}

///|
fn stop_run() -> Unit raise {
  @async.with_event_loop(async fn(_root) {
    let config_content = @io.read_file(".choir/config.toml")
    let config = match @config.parse_config(config_content) {
      Ok(cfg) => cfg
      Err(_) => @types.Config::default()
    }
    let session = config.terminal_session
    let terminal_backend = config.terminal_backend
    let pid_str = @io.read_file(".choir/server.pid").trim().to_string()

    if pid_str != "" {
      @io.write_stdout("Stopping server (PID \{pid_str})...\n")
      ignore(@exec.run(init_kill_server_pid_command(pid_str)) catch { _ => 0 })
    }

    let has_session = @exec.run(
      init_session_exists_command(terminal_backend, session),
    ) catch {
      _ => 1
    }
    if has_session == 0 || terminal_backend == @types.TerminalBackend::Zellij {
      @io.write_stdout("Killing session \{session}...\n")
      ignore(
        @exec.run(init_kill_session_command(terminal_backend, session)) catch {
          _ => 0
        },
      )
    } else {
      @io.write_stdout("Session \{session} not running.\n")
    }

    ignore(@exec.run(init_cleanup_server_artifacts_command()) catch { _ => 0 })
    @io.write_stdout("Choir stopped.\n")
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
    "leaf-tool" => leaf_tool_run()
    "mcp-stdio" => mcp_run() catch { err => println("fatal: \{err}") }
    "trust-gemini-folder" => trust_gemini_folder_run()
    "zellij-action" => zellij_action_run() catch { _ => @io.exit(1) }
    "hook" =>
      hook_run() catch {
        _ =>
          @io.write_stdout(
            @hooks.HookResponse::fail_open().to_json_string() + "\n",
          )
      }
    "init" => init_run() catch { _ => @io.exit(1) }
    "stop" => stop_run() catch { _ => @io.exit(1) }
    "reply" => reply_run()
    "smoke" => smoke_run() catch { _ => @io.exit(1) }
    "watch" => watch_run()
    _ => {
      @io.write_stdout(
        "usage: choir <serve|dev|leaf-tool <tool>|mcp-stdio|trust-gemini-folder <path>|zellij-action <send|close>|hook|init [--recreate]|stop|reply|smoke [--keep-temp|--leafs|--companions|--review|--e2e-live]|watch>\n",
      )
      @io.exit(1)
    }
  }
}
