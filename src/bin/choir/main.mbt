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
  conn : @socket.Tcp,
  state : @server.ServerState,
) -> Unit {
  let mut buf = FixedArray::make(4096, (0 : Byte))
  let mut read_pos = 0
  let mut authenticated = match state.config.tcp_auth_token {
    None => true
    Some(_) => false
  }
  let mut connected_agent_id : String? = None
  for ;; {
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
            let resp = state.handle(req) catch {
              e => {
                @moontrace.error(
                  "handler panic",
                  fields=@moontrace.fields([("error", e.to_string().to_json())]),
                )
                @types.Response::Err("internal error: " + e.to_string())
              }
            }
            let resp_str = @transport.format_response(resp) + "\n"
            conn.write(@utf8.encode(resp_str))
          }
          Err(err) => {
            @moontrace.warn(
              "parse error",
              fields=@moontrace.fields([("line", line.to_json())]),
            )
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
  @moontrace.trace(
    "UDS write start",
    fields=@moontrace.fields([("bytes", data.length().to_json())]),
  )
  while written < data.length() {
    let n = @uds.write_bytes(fd, data, written, data.length() - written)
    if n <= 0 {
      @moontrace.warn(
        "UDS client disconnected",
        fields=@moontrace.fields([("written", written.to_json())]),
      )
      break
    }
    written = written + n
  }
}

///|
async fn serve_handle_uds_connection(
  client : ServeUDSClient,
  state : @server.ServerState,
) -> Bool {
  for ;; {
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
            let resp = state.handle(req) catch {
              e => {
                @moontrace.error(
                  "handler panic",
                  fields=@moontrace.fields([("error", e.to_string().to_json())]),
                )
                @types.Response::Err("internal error: " + e.to_string())
              }
            }
            let resp_str = @transport.format_response(resp) + "\n"
            @moontrace.trace(
              "request",
              fields=@moontrace.fields([("line", line.to_json())]),
            )
            @moontrace.trace(
              "response",
              fields=@moontrace.fields([("body", resp_str.to_json())]),
            )
            serve_write_all_uds(client.fd, @utf8.encode(resp_str))
          }
          Err(err) => {
            @moontrace.warn(
              "parse error",
              fields=@moontrace.fields([("line", line.to_json())]),
            )
            let resp = @types.Response::Err("parse error: " + err)
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
fn serve_close_uds_client(
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
fn serve_run() -> Unit {
  let config_content = @sys.read_file(".choir/config.toml")
  let config = match @config.parse_config(config_content) {
    Ok(cfg) => cfg
    Err(_) => @types.Config::default()
  }
  @moontrace.set_subscriber(fn(event) { println(event.format(color=true)) })
  @moontrace.set_min_level(@moontrace.Level::Debug)
  @sys.write_pid_file(".choir/server.pid")
  ignore(@sys.system("rm -f .choir/tasks/*.json 2>/dev/null; true"))
  let state = @server.ServerState::new(config)
  @moontrace.set_global_field("service", "choir".to_json())
  @moontrace.set_global_field("run_id", state.run_id.to_json())
  @async.run_async_main(async fn() {
    @async.with_task_group(async fn(root) {
      @server.recover_state(state, config.terminal_session)
      root.spawn_bg(async fn() {
        let timeout_sec = 900L
        let disconnect_grace_sec = 60L
        let interval_ms = 30000
        for ;; {
          @async.sleep(interval_ms)
          let now = @poller.now_sec()
          try {
            state.process_pending_disconnects(now, disconnect_grace_sec)
            state.process_poller_tick(
              now,
              timeout_sec,
              runner=@exec.run_sequence,
            )
            state.check_idle_agents(now, 300L, @exec.run_sequence)
          } catch {
            e =>
              @moontrace.error(
                "poller tick error",
                fields=@moontrace.fields([("error", e.to_string().to_json())]),
              )
          }
        }
      })
      root.spawn_bg(async fn() {
        let server_fd = @uds.server_create(config.listen_uds)
        if server_fd < 0 {
          @moontrace.error(
            "failed to bind UDS server",
            fields=@moontrace.fields([("path", config.listen_uds.to_json())]),
          )
          return
        }
        ignore(@uds.set_nonblocking(server_fd))
        @moontrace.info(
          "UDS server listening",
          fields=@moontrace.fields([("path", config.listen_uds.to_json())]),
        )
        let clients : Array[ServeUDSClient] = []
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
              serve_close_uds_client(client, state)
            }
          }
          @async.sleep(10)
        }
      })
      match config.listen_tcp {
        Some(addr_str) => {
          let server = @socket.TcpServer::new(@socket.Addr::parse(addr_str))
          try {
            @moontrace.info(
              "TCP server listening",
              fields=@moontrace.fields([("addr", addr_str.to_json())]),
            )
            for ;; {
              let (conn, addr) = server.accept()
              @moontrace.debug(
                "TCP connection",
                fields=@moontrace.fields([("addr", addr.to_string().to_json())]),
              )
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
        None => @moontrace.debug("no listen_tcp configured")
      }
    })
  })
}

///|
struct TcpLineReader {
  conn : @socket.Tcp
  mut buf : FixedArray[Byte]
  mut read_pos : Int
  mut write_pos : Int
}

///|
fn TcpLineReader::new(conn : @socket.Tcp) -> TcpLineReader {
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
async fn TcpLineReader::read_line(self : TcpLineReader) -> String {
  for ;; {
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
  for ;; {
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
  let trimmed = line.trim().to_string()
  if not(trimmed.has_prefix("Content-Length:")) &&
    not(trimmed.has_prefix("content-length:")) {
    return None
  }
  let mut value = 0
  let mut saw_digit = false
  let mut saw_colon = false
  for c in trimmed {
    if not(saw_colon) {
      if c == ':' {
        saw_colon = true
      }
      continue
    }
    if c >= '0' && c <= '9' {
      saw_digit = true
      value = value * 10 + (c.to_int() - '0'.to_int())
    }
  }
  if saw_digit {
    Some(value)
  } else {
    None
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
    let trimmed = line.trim().to_string()
    if trimmed == "" {
      if not(saw_headers) {
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
            mcp_response_wire(@mcp.tools_list_response(id), raw_stdio),
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
              if not(send_wire_request(wire_req)) {
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
  if not(mcp_write_all_uds(uds_fd, @utf8.encode(reg_msg))) {
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
  let local_cfg = match @config.parse_local_config(local_content) {
    Ok(cfg) => cfg
    Err(_) => @types.LocalConfig::default()
  }
  let config = mcp_config_with_cli_overrides(base_config, local_cfg, args)
  let raw_stdio = mcp_cli_raw_stdio(args)
  let role = match mcp_cli_override_role(args) {
    Some(role) => role
    None => @config.resolve_role(local_cfg.role, config)
  }

  let mut uds_fd = @uds.client_connect(config.listen_uds)
  if uds_fd < 0 {
    // Server may still be starting — wait for the UDS socket
    if @sys.wait_for_socket(config.listen_uds, 60) {
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
      if not(mcp_should_reconnect_after_uds_loop(exit_reason)) {
        break
      }
      if not(@sys.wait_for_socket(config.listen_uds, 60)) {
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
              let resp = @mcp.tools_list_response(id)
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
      let eq_idx = match arg.find("=") {
        Some(idx) => idx
        None => -1
      }
      if eq_idx > 2 {
        let key = normalize_cli_key(arg[2:eq_idx].to_string())
        let value = arg[eq_idx + 1:arg.length()].to_string()
        flags.set(key, value)
        i = i + 1
      } else {
        let key = normalize_cli_key(arg[2:arg.length()].to_string())
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
      if not(flags.contains("caller_id")) {
        match @sys.getenv("CHOIR_AGENT_ID") {
          Some(id) => if id != "" { flags.set("caller_id", id) }
          None => ()
        }
      }
      let used_legacy_branch = not(flags.contains("branch")) &&
        positionals.length() > 0 &&
        looks_like_legacy_branch_arg(positionals[0])
      if not(flags.contains("branch")) {
        if used_legacy_branch {
          flags.set("branch", positionals[0])
        } else if positionals.length() == 0 {
          match @sys.getenv("CHOIR_BRANCH") {
            Some(branch) => if branch != "" { flags.set("branch", branch) }
            None => ()
          }
        }
      }
      if not(flags.contains("parent_branch")) {
        if used_legacy_branch {
          if positionals.length() > 2 && looks_like_branch_token(positionals[2]) {
            flags.set("parent_branch", positionals[2])
          } else if positionals.length() > 1 &&
            looks_like_branch_token(positionals[1]) {
            flags.set("parent_branch", positionals[1])
          }
        } else if positionals.length() == 0 {
          match @sys.getenv("CHOIR_PARENT_BRANCH") {
            Some(parent_branch) =>
              if parent_branch != "" {
                flags.set("parent_branch", parent_branch)
              }
            None => ()
          }
        }
      }
      Ok(flags)
    }
    "notify_parent" => {
      if not(flags.contains("caller_id")) {
        match @sys.getenv("CHOIR_AGENT_ID") {
          Some(id) => if id != "" { flags.set("caller_id", id) }
          None => ()
        }
      }
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
    "shutdown" => {
      if not(flags.contains("caller_id")) {
        match @sys.getenv("CHOIR_AGENT_ID") {
          Some(id) => if id != "" { flags.set("caller_id", id) }
          None => ()
        }
      }
      Ok(flags)
    }
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
  @sys.write_stdout(leaf_tool_response_json(resp))
  @sys.exit(if resp.is_ok() { 0 } else { 1 })
}

///|
fn leaf_tool_load_config() -> Result[
  (@types.Role, @types.Config, @types.LocalConfig),
  String,
] {
  let config_content = @sys.read_file(".choir/config.toml")
  if config_content == "" {
    return Err("missing .choir/config.toml")
  }
  let config = match @config.parse_config(config_content) {
    Ok(cfg) => cfg
    Err(e) => return Err(e.message())
  }
  let local_content = @sys.read_file(".choir/config.local.toml")
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
  let args = @env.args()
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
      @types.Response::ok_values({ "usage": leaf_tool_usage(tool).to_json() }),
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
  let json = @json.parse(existing) catch { _ => return "{}" }
  let obj = match json {
    Object(m) => m
    _ => {}
  }
  obj.set(workspace, "TRUST_FOLDER".to_json())
  obj.to_json().stringify()
}

///|
fn trust_gemini_folder_run() -> Unit {
  let args = @env.args()
  if args.length() < 3 {
    @sys.write_stdout("usage: choir trust-gemini-folder <workspace>\n")
    @sys.exit(1)
    return
  }
  let home = match @sys.getenv("HOME") {
    Some(path) =>
      if path == "" {
        @sys.write_stdout("error: HOME is not set\n")
        @sys.exit(1)
        return
      } else {
        path
      }
    None => {
      @sys.write_stdout("error: HOME is not set\n")
      @sys.exit(1)
      return
    }
  }
  let gemini_dir = home + "/.gemini"
  let trusted_path = gemini_dir + "/trustedFolders.json"
  ignore(
    @sys.system(
      "mkdir -p '" + init_escape_shell_single_quoted(gemini_dir) + "'",
    ),
  )
  let content = @sys.read_file(trusted_path)
  let updated = trusted_folders_json(content, args[2])
  if @sys.write_file_sync(trusted_path, updated) {
    @sys.write_stdout("trusted " + args[2] + "\n")
    @sys.exit(0)
  } else {
    @sys.write_stdout("error: failed to write " + trusted_path + "\n")
    @sys.exit(1)
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
fn zellij_json_bool(value : Json?) -> Bool {
  match value {
    Some(True) => true
    _ => false
  }
}

///|
fn zellij_json_string(value : Json?) -> String {
  match value {
    Some(String(v)) => v
    Some(Number(n, ..)) => n.to_int().to_string()
    _ => ""
  }
}

///|
async fn zellij_list_panes(session : String) -> Array[ZellijPaneRef] {
  let output = @exec.capture_stdout("zellij", [
    "--session", session, "action", "list-panes", "--json", "-a", "-t", "-s",
  ])
  let panes = []
  let json = @json.parse(output) catch { _ => ([] : Array[Json]).to_json() }
  guard json is Array(arr) else { return panes }
  for item in arr {
    guard item is Object(pane) else { continue }
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
  target : @types.LocalTarget,
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
      @types.TargetKind::ZellijPane =>
        if pane.title == target.name {
          return Some(pane.id)
        }
      @types.TargetKind::ZellijTab =>
        if pane.tab_name == target.name {
          return Some(pane.id)
        }
    }
  }
  None
}

///|
fn zellij_target_tab_id(
  target : @types.LocalTarget,
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
fn zellij_action_run() -> Unit {
  @async.run_async_main(async fn() {
    @async.with_task_group(async fn(_root) {
      let args = @env.args()
      if args.length() < 4 {
        @sys.write_stdout(zellij_action_usage() + "\n")
        @sys.exit(1)
        return
      }
      let action = args[2]
      let target_text = args[3]
      let target = match @types.LocalTarget::parse(target_text) {
        Some(parsed) => parsed
        None => {
          @sys.write_stdout(
            "error: invalid zellij target: " + target_text + "\n",
          )
          @sys.exit(1)
          return
        }
      }
      // If the target name is already a pane ID (terminal_N), skip list-panes
      let direct_pane_id = if target.name.has_prefix("terminal_") {
        Some(target.name)
      } else {
        None
      }
      let panes = match direct_pane_id {
        Some(_) => [] // skip list-panes when we have a direct ID
        None => zellij_list_panes(target.session)
      }
      match action {
        "send" => {
          if args.length() < 5 {
            @sys.write_stdout(zellij_action_usage() + "\n")
            @sys.exit(1)
            return
          }
          let text = args[4]
          let pane_id = match direct_pane_id {
            Some(id) => id
            None =>
              match zellij_target_pane_id(target, panes) {
                Some(id) => id
                None => {
                  @sys.write_stdout(
                    "error: zellij target not found: " + target_text + "\n",
                  )
                  @sys.exit(1)
                  return
                }
              }
          }
          // Wrap in bracketed paste (ESC[200~ ... ESC[201~) so agents
          // like Moon Pilot treat multi-line text as a single paste event
          // instead of executing each newline as Enter.
          let esc = Int::unsafe_to_char(0x1B).to_string()
          let pasted = esc + "[200~" + text + esc + "[201~"
          let write_code = @exec.run({
            program: "zellij",
            args: [
              "--session",
              target.session,
              "action",
              "write-chars",
              "-p",
              pane_id,
              pasted,
            ],
            workdir: None,
          })
          if write_code != 0 {
            @sys.exit(write_code)
            return
          }
          // Delay so Claude Code finishes processing pasted text before Enter
          ignore(@exec.run({ program: "sleep", args: ["0.5"], workdir: None }))
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
          @sys.exit(key_code)
        }
        "close" =>
          match target.kind {
            @types.TargetKind::ZellijPane => {
              let pane_id = match direct_pane_id {
                Some(id) => id
                None =>
                  match
                    zellij_target_pane_id(target, panes, allow_exited=true) {
                    Some(id) => id
                    None => {
                      @sys.write_stdout(
                        "error: zellij target not found: " + target_text + "\n",
                      )
                      @sys.exit(1)
                      return
                    }
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
              @sys.exit(code)
            }
            @types.TargetKind::ZellijTab => {
              let tab_id = match zellij_target_tab_id(target, panes) {
                Some(id) => id
                None => {
                  @sys.write_stdout(
                    "error: zellij target not found: " + target_text + "\n",
                  )
                  @sys.exit(1)
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
              @sys.exit(code)
            }
          }
        _ => {
          @sys.write_stdout(zellij_action_usage() + "\n")
          @sys.exit(1)
        }
      }
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
  // Prose must not be interpreted as the legacy branch triplet (ambient CHOIR_* may still set branch).
  assert_not_eq(parsed.get("branch"), Some("Add"))
  assert_not_eq(parsed.get("branch"), Some("pytest"))
  assert_not_eq(parsed.get("parent_branch"), Some("Add"))
  assert_not_eq(parsed.get("parent_branch"), Some("pytest"))
  assert_not_eq(parsed.get("parent_branch"), Some("integration"))
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
  let json = @json.parse(updated) catch { _ => ().to_json() }
  guard json is Object(parsed) else { panic() }
  assert_eq(parsed.get("/existing"), Some("TRUST_FOLDER".to_json()))
  assert_eq(parsed.get("/new/worktree"), Some("TRUST_FOLDER".to_json()))
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
    @env.current_dir().unwrap_or(".") + "/" + argv0
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
    #|(cd "$ROOT/repo" && cat "$ROOT/first.reqs.jsonl" | timeout 8 "$BIN" mcp-stdio --raw-stdio --name smoke-proof >"$ROOT/first.out" 2>"$ROOT/first.err")
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
    #|    "$BIN" mcp-stdio --raw-stdio --name hold-open >"$ROOT/hold.out" 2>"$ROOT/hold.err"
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
    #|(cd "$ROOT/repo" && cat "$ROOT/second.reqs.jsonl" | timeout 8 "$BIN" mcp-stdio --raw-stdio --name second-client >"$ROOT/second.out" 2>"$ROOT/second.err")
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
    #|{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"fork_wave","arguments":{"caller_id":"root-smoke","slug_prefix":"$slug","count":"1","agent_type":"$agent_type","parent_branch":"main","task":"Make a tiny doc-only change to .choir/context/common.md, run moon fmt and moon test --target native, commit it, then use file_pr and notify_parent with the returned PR URL. Do not use raw gh commands.","read_first":".choir/context/common.md\n.choir/context/dev.md","done_criteria":"A PR is filed through file_pr and the parent has been notified."}}}
    #|EOF
    #|  (cd "$ROOT/repo" && cat "$req" | timeout 120 "$BIN" mcp-stdio --raw-stdio --name root-smoke >"$ROOT/$slug.out" 2>"$ROOT/$slug.err")
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
    #|{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"fork_wave","arguments":{"caller_id":"root-smoke","slug_prefix":"$MOON_SLUG","count":"1","agent_type":"moon_pilot","parent_branch":"main","task":"Make a tiny doc-only change to .choir/context/common.md, run moon fmt and moon test --target native, commit it, file a PR through file_pr, notify_parent with the returned PR URL, and remain available in the session for follow-up review feedback. Do not use raw gh commands.","read_first":".choir/context/common.md\n.choir/context/dev.md","done_criteria":"A PR is filed through file_pr, the parent has been notified, and you remain available for review feedback."}}}
    #|EOF
    #|(cd "$ROOT/repo" && cat "$ROOT/moon.req.jsonl" | timeout 120 "$BIN" mcp-stdio --raw-stdio --name root-smoke >"$ROOT/moon.out" 2>"$ROOT/moon.err")
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
    #|{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"fork_wave","arguments":{"caller_id":"root-smoke","slug_prefix":"$MOON_SLUG","count":"1","agent_type":"moon_pilot","parent_branch":"$ROOT_BRANCH","task":"Make a tiny doc-only change to .choir/context/common.md, run moon fmt and moon test --target native, commit it, file a PR through file_pr, notify_parent with the returned PR URL, and remain available in the session for follow-up review feedback. Do not use raw gh commands.","read_first":".choir/context/common.md\n.choir/context/dev.md","done_criteria":"A PR is filed through file_pr, the parent has been notified, and you remain available for review feedback."}}}
    #|EOF
    #|(cd "$ROOT/repo" && cat "$ROOT/moon.req.jsonl" | timeout 120 "$BIN" mcp-stdio --raw-stdio --name root-smoke >"$ROOT/moon.out" 2>"$ROOT/moon.err")
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
    #|(cd "$ROOT/repo" && cat "$ROOT/merge.req.jsonl" | timeout 60 "$BIN" mcp-stdio --raw-stdio --name root-smoke >"$ROOT/merge.out" 2>"$ROOT/merge.err")
    #|wait_for_pr_merged "$MOON_PR"
    #|wait_for_untracked "$MOON_BRANCH"
    #|echo "e2e smoke ok: moon pilot PR was reviewed and merged via choir"
  ) +
  "\n"
}

///|
fn smoke_run() -> Unit {
  @async.run_async_main(async fn() {
    @async.with_task_group(async fn(_root) {
      let args = @env.args()
      let keep_temp = if smoke_keep_temp(args) { "1" } else { "0" }
      let self_exe = smoke_self_exe(args)
      let repo_dir = @env.current_dir().unwrap_or(".")
      let script = if smoke_e2e_enabled(args) {
        @sys.write_stdout("Running isolated live end-to-end smoke...\n")
        smoke_e2e_script()
      } else if smoke_companions_enabled(args) {
        @sys.write_stdout("Running isolated companion smoke...\n")
        smoke_companion_script()
      } else if smoke_review_enabled(args) {
        @sys.write_stdout("Running isolated review smoke...\n")
        smoke_review_script()
      } else if smoke_leafs_enabled(args) {
        @sys.write_stdout("Running isolated leaf smoke...\n")
        smoke_leaf_script()
      } else {
        @sys.write_stdout("Running isolated runtime smoke...\n")
        smoke_script()
      }
      let exit_code = @exec.run({
        program: "sh",
        args: ["-c", script, "sh", self_exe, keep_temp, repo_dir],
        workdir: None,
      }) catch {
        _ => 1
      }
      @sys.exit(exit_code)
    })
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
test "companion commands use isolated worktree with zellij tab" {
  let config = {
    ..@types.Config::default(),
    extra_mcp_servers_json: Some("{\"extra\":{\"type\":\"stdio\"}}"),
  }
  let cmds = init_companion_commands("/proj", "choir", config, "main", {
    name: "monitor",
    role: "dev",
    command: "claude",
    task: "watch tests",
  })
  assert_eq(cmds.length(), 7)
  assert_eq(cmds[0].program, "sh")
  assert_true(cmds[0].args[3].contains("/proj/.choir/agents/monitor"))
  assert_true(cmds[0].args[4].contains("main.companion.monitor"))
  assert_eq(cmds[1].program, "git")
  assert_eq(cmds[1].args, [
    "worktree", "add", "/proj/.choir/agents/monitor", "-b", "main.companion.monitor",
    "main",
  ])
  assert_true(cmds[2].args[4].contains("default_role = \"dev\""))
  assert_true(cmds[2].args[4].contains("terminal_session = \"choir\""))
  assert_true(cmds[3].args[4].contains("agent_id = \"main.companion.monitor\""))
  assert_true(cmds[3].args[4].contains("parent_branch = \"main\""))
  assert_true(
    cmds[3].args[4].contains("terminal_target = \"zellij-tab:choir:monitor\""),
  )
  assert_true(cmds[3].args[4].contains("agent_type = \"claude\""))
  assert_true(cmds[6].args[11].contains("claude"))
  assert_true(cmds[6].args[11].contains("\"mcpServers\""))
  assert_true(cmds[6].args[11].contains("main.companion.monitor"))
  assert_true(cmds[6].args[11].contains("\"extra\":{\"type\":\"stdio\"}"))
  assert_eq(cmds[6].program, "zellij")
  assert_eq(cmds[6].args[3], "new-tab")
}

///|
test "companion gemini commands trust workspace and use zellij tab cwd" {
  let cmds = init_companion_commands(
    "/proj",
    "howdy",
    @types.Config::default(),
    "main",
    {
      name: "gem-helper",
      role: "worker",
      command: "gemini --model flash",
      task: "reply READY",
    },
  )
  assert_eq(cmds.length(), 8)
  assert_eq(cmds[6].program, "choir")
  assert_eq(cmds[6].args, [
    "trust-gemini-folder", "/proj/.choir/agents/gem-helper",
  ])
  assert_eq(cmds[7].program, "zellij")
  assert_eq(cmds[7].args[0], "--session")
  assert_eq(cmds[7].args[1], "howdy")
  assert_eq(cmds[7].args[2], "action")
  assert_eq(cmds[7].args[3], "new-tab")
  assert_eq(cmds[7].args[7], "/proj/.choir/agents/gem-helper")
  assert_true(
    cmds[7].args[11].contains(
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
fn init_session_exists_command(session : String) -> @workspace.Command {
  @workspace.zellij_session_exists(session)
}

///|
fn init_kill_session_command(session : String) -> @workspace.Command {
  @workspace.zellij_kill_session(session)
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
test "init session lifecycle commands use zellij" {
  let exists = init_session_exists_command("choir")
  assert_eq(exists.program, "sh")
  assert_true(exists.args[1].contains("zellij list-sessions"))

  let kill = init_kill_session_command("choir")
  assert_eq(kill.args, ["delete-session", "--force", "choir"])
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
  let cwd = @env.current_dir().unwrap_or(".")
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
  assert_true(script.contains("mcp-stdio --raw-stdio --name smoke-proof"))
  assert_true(script.contains("mcp-stdio --raw-stdio --name hold-open"))
  assert_true(script.contains("mcp-stdio --raw-stdio --name second-client"))
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
    None => @sys.getenv("CHOIR_AGENT_ID")
  }
}

///|
fn persist_hook_session(input : @hooks.HookInput) -> Unit {
  match input.event {
    @hooks.HookEvent::SessionStart =>
      match (input.session_id, hook_agent_id(input)) {
        (Some(session_id), Some(agent_id)) =>
          ignore(
            @sys.write_file_sync(
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
fn hook_run() -> Unit {
  @async.run_async_main(async fn() {
    let line = match @sys.read_stdin_line(8192) {
      Some(line) => line
      None => {
        @sys.write_stdout(
          @hooks.HookResponse::fail_open().to_json_string() + "\n",
        )
        return
      }
    }
    let input = match @hooks.HookInput::from_json_string(line) {
      Some(i) => i
      None => {
        @sys.write_stdout(
          @hooks.HookResponse::fail_open().to_json_string() + "\n",
        )
        return
      }
    }
    persist_hook_session(input)

    let config_content = @sys.read_file(".choir/config.toml")

    let hook_key = match input.event {
      @hooks.HookEvent::SessionStart => "hook.session_start"
      @hooks.HookEvent::PreToolUse => "hook.pre_tool_use"
      @hooks.HookEvent::PostToolUse => "hook.post_tool_use"
      @hooks.HookEvent::AgentExit => "hook.agent_exit"
      @hooks.HookEvent::SessionStop => "hook.session_stop"
      @hooks.HookEvent::BeforeModel => "hook.before_model"
      @hooks.HookEvent::AfterModel => "hook.after_model"
    }

    match @config.hook_command_path(config_content, hook_key) {
      None =>
        @sys.write_stdout(@hooks.HookResponse::allow().to_json_string() + "\n")
      Some(cmd_path) => {
        let cmd = @workspace.Command::{
          program: cmd_path,
          args: [],
          workdir: None,
        }
        let exit_code = @exec.run(cmd) catch { _ => 1 }
        if exit_code == 0 {
          @sys.write_stdout(
            @hooks.HookResponse::allow().to_json_string() + "\n",
          )
        } else {
          @sys.write_stdout(
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
  let trimmed = project_dir[:end].to_string()
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
      trimmed[last_slash + 1:].to_string()
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
  let suffix = normalized_raw[start:finish].to_string()
  let normalized = if suffix == "" { "project" } else { suffix }
  "choir-" + normalized
}

///|
fn init_config_toml_content(default_session : String) -> String {
  "default_role = \"tl\"\n" +
  "project_dir = \".\"\n" +
  "listen_uds = \".choir/server.sock\"\n" +
  "terminal_session = \"" +
  default_session +
  "\"\n"
}

///|
fn init_config_has_terminal_session(content : String) -> Bool {
  content.contains("terminal_session")
}

///|
fn init_codex_mcp_override_args(
  role : @types.Role,
  agent_id : String,
  project_dir : String,
) -> Array[String] {
  let role_args = match role {
    @types.Role::TL => ""
    _ => " --role " + @config.role_to_string(role)
  }
  let cmd = "i=0; while [ ! -S .choir/server.sock ] && [ \"$i\" -lt 600 ]; do sleep 0.1; i=$((i + 1)); done; " +
    "exec choir mcp-stdio" +
    role_args +
    " --raw-stdio" +
    " --name " +
    init_shell_quote(agent_id) +
    " 2>> .choir/mcp-stdio.stderr.log"
  [
    "-c",
    "mcp_servers.choir.command=\"sh\"",
    "-c",
    "mcp_servers.choir.args=[\"-lc\", \"" + init_escape_toml_string(cmd) + "\"]",
    "-c",
    "mcp_servers.choir.cwd=\"" + init_escape_toml_string(project_dir) + "\"",
  ]
}

///|
fn init_claude_mcp_config_json() -> String {
  "{\"mcpServers\":{\"choir\":{\"type\":\"stdio\",\"command\":\"choir\",\"args\":[\"mcp-stdio\",\"--name\",\"root\"]}}}"
}

///|
fn init_tl_launch_command(tl_type : String, project_dir : String) -> String {
  let cmd = match tl_type {
    "codex" => {
      let parts : Array[String] = [
        "codex",
        "--dangerously-bypass-approvals-and-sandbox",
        "--no-alt-screen",
        ..init_codex_mcp_override_args(@types.Role::TL, "root", project_dir),
        "-C",
        project_dir,
      ]
      let buf = StringBuilder::new()
      for i = 0; i < parts.length(); i = i + 1 {
        if i > 0 {
          buf.write_char(' ')
        }
        buf.write_string(init_shell_quote(parts[i]))
      }
      buf.to_string()
    }
    "gemini" => "gemini --yolo --prompt-interactive"
    "cursor_agent" =>
      "agent --yolo --approve-mcps --workspace " + init_shell_quote(project_dir)
    _ =>
      "claude --dangerously-skip-permissions --mcp-config " +
      init_shell_quote(init_claude_mcp_config_json()) +
      " --strict-mcp-config"
  }
  cmd + "; echo; echo '[TL exited]'; exec bash -l"
}

///|
fn init_parse_tl_type(args : Array[String]) -> String {
  for i = 0; i < args.length() - 1; i = i + 1 {
    if args[i] == "--tl" {
      return args[i + 1]
    }
  }
  "claude"
}

///|
test "init TL launch command defaults to claude" {
  let cmd = init_tl_launch_command("claude", ".")
  assert_true(cmd.contains("claude --dangerously-skip-permissions"))
  assert_true(cmd.contains("--mcp-config '{\"mcpServers\""))
}

///|
test "init TL launch command supports codex" {
  let cmd = init_tl_launch_command("codex", "/tmp/choir repo")
  assert_true(cmd.contains("'codex'"))
  assert_true(cmd.contains("'--dangerously-bypass-approvals-and-sandbox'"))
  assert_true(cmd.contains("'--no-alt-screen'"))
  assert_true(cmd.contains("'mcp_servers.choir.command=\"sh\"'"))
  assert_true(cmd.contains("mcp-stdio --raw-stdio --name"))
  assert_true(cmd.contains("'mcp_servers.choir.cwd=\"/tmp/choir repo\"'"))
  assert_true(cmd.contains("'-C' '/tmp/choir repo'"))
  assert_false(cmd.contains("--mcp-config"))
}

///|
test "init TL launch command supports cursor_agent" {
  let cmd = init_tl_launch_command("cursor_agent", "/tmp/choir repo")
  assert_true(cmd.contains("agent --yolo --approve-mcps --workspace"))
  assert_true(cmd.contains("'/tmp/choir repo'"))
  assert_false(cmd.contains("--mcp-config"))
}

///|
test "init parse_tl_type extracts --tl flag" {
  assert_eq(init_parse_tl_type(["choir", "init", "--tl", "codex"]), "codex")
  assert_eq(init_parse_tl_type(["choir", "init"]), "claude")
  assert_eq(
    init_parse_tl_type(["choir", "init", "--recreate", "--tl", "gemini"]),
    "gemini",
  )
}

///|
fn init_escape_toml_string(s : String) -> String {
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
        parts.push(trimmed[start:i].to_string())
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
  if first == "codex" || first.has_suffix("/codex") {
    return Some(@types.AgentType::Codex)
  }
  if first == "agent" || first.has_suffix("/agent") {
    return Some(@types.AgentType::CursorAgent)
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
  terminal_target : @types.LocalTarget,
  agent_type? : @types.AgentType? = None,
) -> String {
  let role_str = @config.role_to_string(role)
  let target_str = terminal_target.to_string()
  let agent_type_line = match agent_type {
    Some(kind) => "agent_type = \"\{@config.agent_type_to_string(kind)}\"\n"
    None => ""
  }
  "role = \"\{role_str}\"\nagent_id = \"\{agent_id}\"\nparent_id = \"\{parent_id}\"\nbranch = \"\{branch}\"\nparent_branch = \"\{parent_branch}\"\nworkspace = \"\{workspace}\"\nterminal_target = \"\{target_str}\"\nspawn_depth = 0\n\{agent_type_line}"
}

///|
fn init_companion_launch_prefix(
  role : @types.Role,
  agent_id : String,
  parent_id : String,
  branch : String,
  parent_branch : String,
  workspace : String,
  terminal_target : @types.LocalTarget,
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
    init_env_assignment("CHOIR_TERMINAL_TARGET", terminal_target.to_string()),
    init_env_assignment("CHOIR_TERMINAL_SESSION", session),
    init_env_assignment("CHOIR_AGENT_ID", agent_id),
    init_env_assignment("CHOIR_SESSION_ID", agent_id),
    init_env_assignment("CHOIR_ROLE", @config.role_to_string(role)),
    init_env_assignment("CHOIR_PARENT_AGENT", parent_id),
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
  match @sys.getenv("TRACEPARENT") {
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
fn init_join_shell_words(parts : Array[String]) -> String {
  let buf = StringBuilder::new()
  for i = 0; i < parts.length(); i = i + 1 {
    if i > 0 {
      buf.write_char(' ')
    }
    buf.write_string(init_shell_quote(parts[i]))
  }
  buf.to_string()
}

///|
fn init_companion_launch_command(
  role : @types.Role,
  branch : String,
  workspace : String,
  command : String,
  task : String,
  extra_mcp_servers_json? : String? = None,
) -> String {
  let parts = init_split_words(command)
  if parts.is_empty() {
    return init_shell_quote(task)
  }
  let program = parts[0]
  let extra_args : Array[String] = []
  for i = 1; i < parts.length(); i = i + 1 {
    extra_args.push(parts[i])
  }
  match init_companion_agent_type(command) {
    Some(@types.AgentType::Claude) =>
      init_join_shell_words(
        [
          program,
          ..extra_args,
          "--dangerously-skip-permissions",
          "--mcp-config",
          @workspace.mcp_json_content(role, branch, extra_mcp_servers_json~),
          "--strict-mcp-config",
          task,
        ],
      )
    Some(@types.AgentType::Gemini) =>
      init_join_shell_words([program, ..extra_args, task])
    Some(@types.AgentType::MoonPilot) =>
      init_join_shell_words([program, ..extra_args, task])
    Some(@types.AgentType::Codex) =>
      init_join_shell_words(
        [
          program,
          ..extra_args,
          "--dangerously-bypass-approvals-and-sandbox",
          "--no-alt-screen",
          ..init_codex_mcp_override_args(role, branch, workspace),
          "-C",
          workspace,
          task,
        ],
      )
    Some(@types.AgentType::CursorAgent) =>
      init_join_shell_words(
        [
          program, ..extra_args, "--yolo", "--approve-mcps", "--workspace", workspace,
          task,
        ],
      )
    None => command + " '" + init_escape_shell_single_quoted(task) + "'"
  }
}

///|
fn init_companion_commands(
  project_dir : String,
  session : String,
  config : @types.Config,
  current_branch : String,
  companion : @config.CompanionDef,
) -> Array[@workspace.Command] {
  let role = init_companion_role(companion.role)
  let branch = init_companion_branch(current_branch, companion.name)
  let workspace = project_dir + "/.choir/agents/" + companion.name
  let terminal_target = @workspace.local_target_for(
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
      terminal_target,
      session,
      agent_type~,
    ) +
    init_companion_launch_command(
      role,
      branch,
      workspace,
      companion.command,
      companion.task,
      extra_mcp_servers_json=config.extra_mcp_servers_json,
    )
  let cmds : Array[@workspace.Command] = [
    {
      program: "sh",
      args: [
        "-c", "git worktree remove --force \"$1\" 2>/dev/null || true; rm -rf \"$1\"; git branch -D \"$2\" 2>/dev/null || true",
        "sh", workspace, branch,
      ],
      workdir: None,
    },
    @workspace.git_worktree_add(workspace, branch, current_branch),
    @workspace.write_spawn_config(
      workspace,
      @workspace.child_config_content(
        role,
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
  if agent_type == Some(@types.AgentType::CursorAgent) {
    cmds.push(
      @workspace.write_cursor_mcp_json(
        workspace,
        branch,
        @config.role_to_string(role),
      ),
    )
  }
  cmds.push(
    @workspace.zellij_new_tab(session, companion.name, workspace, launch_str),
  )
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
    @sys.read_file(project_dir + "/moon.mod.json"),
    @sys.read_file(project_dir + "/src/bin/choir/main.mbt"),
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
async fn init_run_or_exit(cmd : @workspace.Command) -> Unit {
  let exit_code = @exec.run(cmd) catch { _ => 1 }
  if exit_code != 0 {
    @sys.exit(exit_code)
  }
}

///|
fn init_run() -> Unit {
  @async.run_async_main(async fn() {
    @async.with_task_group(async fn(_root) {
      let args = @env.args()
      let recreate = args.contains("--recreate")
      let no_attach = init_no_attach(args)
      let tl_type = init_parse_tl_type(args)
      let project_dir = @env.current_dir().unwrap_or(".")
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
      // Set up Claude Code statusline if .claude/settings.json doesn't exist
      ignore(
        @exec.run({
          program: "sh",
          args: [
            "-c", "mkdir -p .claude && test -f .claude/settings.json || printf '%s' '{\"statusLine\":{\"type\":\"command\",\"command\":\"choir statusline\"}}' > .claude/settings.json",
          ],
          workdir: None,
        }) catch {
          _ => 0
        },
      )
      let maybe_patch_config = @sys.read_file(".choir/config.toml")
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
        ignore(@sys.write_file_sync(".choir/config.toml", patched))
      }
      let config_content = @sys.read_file(".choir/config.toml")
      let config = match @config.parse_config(config_content) {
        Ok(cfg) => cfg
        Err(_) => @types.Config::default()
      }
      let current_branch_raw = @exec.capture_stdout("git", [
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

      if recreate {
        let pid_str = @sys.read_file(".choir/server.pid")
        if pid_str != "" {
          @sys.write_stdout("Stopping server (PID \{pid_str})...\n")
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
        @sys.write_stdout("Killing session \{session}...\n")
        ignore(@exec.run(init_kill_session_command(session)) catch { _ => 0 })
      }

      let session_alive = @exec.run(init_session_exists_command(session)) catch {
        _ => 1
      }
      if session_alive == 0 {
        if no_attach {
          @sys.write_stdout("Session \{session} already exists.\n")
        } else {
          @sys.write_stdout("Attaching to existing session \{session}...\n")
          ignore(
            @exec.run(@workspace.zellij_attach_session(session)) catch {
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

      @sys.write_stdout("Creating session \{session}...\n")
      init_run_or_exit(@workspace.zellij_create_background_session(session))
      init_run_or_exit(
        @workspace.zellij_new_tab(session, "Server", project_dir, server_cmd),
      )
      init_run_or_exit(
        @workspace.zellij_new_tab(
          session,
          "TL",
          project_dir,
          init_tl_launch_command(tl_type, project_dir),
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

      match config.companions_json {
        Some(json) => {
          let companions = @config.parse_companions_json(json)
          for c in companions {
            for
              cmd in init_companion_commands(
                project_dir, session, config, current_branch, c,
              ) {
              ignore(@exec.run(cmd) catch { _ => 0 })
            }
            @sys.write_stdout("Spawned companion: \{c.name}\n")
          }
        }
        None => ()
      }

      @sys.write_stdout("Waiting for server socket...\n")
      if not(@sys.wait_for_socket(config.listen_uds, 60)) {
        @sys.write_stdout("Warning: server socket not ready after 30s\n")
      } else {
        @sys.write_stdout("Server ready.\n")
      }

      if no_attach {
        @sys.write_stdout("Session \{session} ready.\n")
      } else {
        @sys.write_stdout("Attaching to session \{session}...\n")
        ignore(
          @exec.run(@workspace.zellij_attach_session(session)) catch {
            _ => 0
          },
        )
      }
    })
  })
}

///|
fn stop_run() -> Unit {
  @async.run_async_main(async fn() {
    @async.with_task_group(async fn(_root) {
      let config_content = @sys.read_file(".choir/config.toml")
      let config = match @config.parse_config(config_content) {
        Ok(cfg) => cfg
        Err(_) => @types.Config::default()
      }
      let session = config.terminal_session
      let pid_str = @sys.read_file(".choir/server.pid").trim().to_string()

      if pid_str != "" {
        @sys.write_stdout("Stopping server (PID \{pid_str})...\n")
        ignore(
          @exec.run(init_kill_server_pid_command(pid_str)) catch {
            _ => 0
          },
        )
      }

      @sys.write_stdout("Killing session \{session}...\n")
      ignore(@exec.run(init_kill_session_command(session)) catch { _ => 0 })

      ignore(
        @exec.run(init_cleanup_server_artifacts_command()) catch {
          _ => 0
        },
      )
      @sys.write_stdout("Choir stopped.\n")
    })
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
  let code = @sys.system(cmd)
  @sys.exit(code)
}

///|
fn reply_run() -> Unit {
  let args = @env.args()

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
    @sys.write_stdout(
      "usage: choir reply --id <id> [--payload <json>] [--cancel]\n",
    )
    @sys.exit(1)
    return
  }

  let config_content = @sys.read_file(".choir/config.toml")
  let config = match @config.parse_config(config_content) {
    Ok(cfg) => cfg
    Err(_) => @types.Config::default()
  }

  let uds_fd = @uds.client_connect(config.listen_uds)
  if uds_fd < 0 {
    @sys.write_stdout(
      "error: cannot connect to server at \{config.listen_uds}\n",
    )
    @sys.exit(1)
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

  let req_msg = {
      "method": "reply".to_json(),
      "role": "root".to_json(),
      "name": "reply".to_json(),
      "args": {
        "id": id.to_json(),
        "payload": payload.to_json(),
        "cancel": cancel.to_string().to_json(),
      }.to_json(),
    }
    .to_json()
    .stringify() +
    "\n"
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
    @sys.write_stdout(resp + "\n")
  }

  @uds.close(uds_fd)
}

///|
fn watch_run() -> Unit {
  dev_run()
}

///|

///|
fn statusline_read_all_stdin() -> String {
  let buf = StringBuilder::new()
  for ;; {
    match @sys.read_stdin_line(65536) {
      Some(line) => {
        buf.write_string(line)
        buf.write_string("\n")
      }
      None => break
    }
  }
  buf.to_string()
}

///|
fn statusline_json_string(obj : Map[String, Json], key : String) -> String {
  match obj.get(key) {
    Some(String(s)) => s
    _ => ""
  }
}

///|
fn statusline_json_number(obj : Map[String, Json], key : String) -> Double {
  match obj.get(key) {
    Some(Number(n, ..)) => n
    _ => 0.0
  }
}

///|
fn statusline_json_object(
  obj : Map[String, Json],
  key : String,
) -> Map[String, Json] {
  match obj.get(key) {
    Some(Object(m)) => m
    _ => {}
  }
}

///|
fn statusline_list_lifecycle_files(project_dir : String) -> Array[String] {
  let tmp = "/tmp/choir-statusline-" + @sys.get_pid().to_string() + ".tmp"
  let cmd = "ls " +
    project_dir +
    "/.choir/kv/lifecycle--* 2>/dev/null > " +
    tmp +
    " 2>/dev/null"
  ignore(@sys.system(cmd))
  let output = @sys.read_file(tmp)
  ignore(@sys.delete_file_sync(tmp))
  let files = []
  for line in output.split("\n") {
    let trimmed = line.trim().to_string()
    if trimmed != "" {
      files.push(trimmed)
    }
  }
  files
}

///|
fn statusline_collect_child_ids(project_dir : String) -> Map[String, Bool] {
  let tmp = "/tmp/choir-statusline-ch-" + @sys.get_pid().to_string() + ".tmp"
  let cmd = "ls " +
    project_dir +
    "/.choir/kv/children--* 2>/dev/null > " +
    tmp +
    " 2>/dev/null"
  ignore(@sys.system(cmd))
  let output = @sys.read_file(tmp)
  ignore(@sys.delete_file_sync(tmp))
  let ids : Map[String, Bool] = {}
  for line in output.split("\n") {
    let path = line.trim().to_string()
    if path == "" {
      continue
    }
    let content = @sys.read_file(path)
    if content == "" {
      continue
    }
    let json = @json.parse(content) catch { _ => continue }
    let arr = match json {
      Array(items) => items
      _ => continue
    }
    for item in arr {
      match item {
        Object(child) =>
          match child.get("id") {
            Some(String(id)) => ids.set(id, true)
            _ => ()
          }
        _ => ()
      }
    }
  }
  ids
}

///|
fn statusline_count_agents(project_dir : String) -> (Int, Int, Int, Int, Int) {
  let child_ids = statusline_collect_child_ids(project_dir)
  let files = statusline_list_lifecycle_files(project_dir)
  let mut working = 0
  let mut review = 0
  let mut changes = 0
  let mut failed = 0
  let mut done = 0
  for path in files {
    // Extract agent_id from path: .../lifecycle--<agent_id>
    let prefix = "/lifecycle--"
    let mut idx = -1
    for i = 0; i < path.length() - prefix.length(); i = i + 1 {
      let mut match_ = true
      for j = 0; j < prefix.length(); j = j + 1 {
        if path[i + j] != prefix[j] {
          match_ = false
          break
        }
      }
      if match_ {
        idx = i + prefix.length()
      }
    }
    if idx < 0 {
      continue
    }
    let agent_id = path.substring(start=idx)
    // If children files exist, only count tracked agents
    if child_ids.length() > 0 && not(child_ids.contains(agent_id)) {
      continue
    }
    let content = @sys.read_file(path)
    if content == "" {
      continue
    }
    let json = @json.parse(content) catch { _ => continue }
    let obj = match json {
      Object(m) => m
      _ => continue
    }
    let workflow = statusline_json_object(obj, "workflow")
    let state = statusline_json_object(workflow, "state")
    let tag = statusline_json_string(state, "tag")
    match tag {
      "Working" => working = working + 1
      "ReviewOwned" | "ExitRequestedDeferred" => review = review + 1
      "ChangesRequested" => changes = changes + 1
      "Failed" => failed = failed + 1
      "Done" => done = done + 1
      _ => ()
    }
  }
  (working, review, changes, failed, done)
}

///|
fn statusline_pr_summary(project_dir : String) -> String {
  let content = @sys.read_file(project_dir + "/.choir/poller_state.json")
  if content.trim().to_string() == "" || content.trim().to_string() == "[]" {
    return ""
  }
  let json = @json.parse(content) catch { _ => return "" }
  let arr = match json {
    Array(items) => items
    _ => return ""
  }
  if arr.length() == 0 {
    return ""
  }
  let parts = StringBuilder::new()
  let mut first = true
  for item in arr {
    match item {
      Object(pr) => {
        let number = statusline_json_number(pr, "pr_number").to_int()
        let review = statusline_json_string(pr, "last_review_state")
        if not(first) {
          parts.write_string(" ")
        }
        first = false
        match review {
          "Approved" => parts.write_string("\u001b[32m#\{number}\u001b[0m")
          "ChangesRequested" =>
            parts.write_string("\u001b[35m#\{number}\u001b[0m")
          _ => parts.write_string("#\{number}")
        }
      }
      _ => ()
    }
  }
  parts.to_string()
}

///|
fn statusline_run() -> Unit {
  let input = statusline_read_all_stdin()
  let json = @json.parse(input) catch {
    _ => @json.parse("{}") catch { _ => return }
  }
  let root = match json {
    Object(m) => m
    _ => return
  }
  let model_obj = statusline_json_object(root, "model")
  let model = statusline_json_string(model_obj, "display_name")
  let ctx_obj = statusline_json_object(root, "context_window")
  let ctx_pct = statusline_json_number(ctx_obj, "used_percentage").to_int()
  let cost_obj = statusline_json_object(root, "cost")
  let cost = statusline_json_number(cost_obj, "total_cost_usd")
  let cwd = match root.get("cwd") {
    Some(String(s)) => s
    _ => "."
  }
  let project_dir = cwd
  let has_choir = @sys.read_file(project_dir + "/.choir/config.toml") != ""
  let cost_str = if cost < 0.01 {
    "$0"
  } else if cost < 1.0 {
    "$" + ((cost * 100.0).to_int().to_double() / 100.0).to_string()
  } else {
    "$" + ((cost * 100.0).to_int().to_double() / 100.0).to_string()
  }
  let line1 = "\u001b[36m\{model}\u001b[0m  ctx \{ctx_pct}%  \{cost_str}"
  if not(has_choir) {
    @sys.write_stdout(line1)
    return
  }
  let (working, review, changes, failed, done) = statusline_count_agents(
    project_dir,
  )
  let total = working + review + changes + failed + done
  let agent_parts = StringBuilder::new()
  let mut has_part = false
  if working > 0 {
    agent_parts.write_string("\u001b[33m\{working} working\u001b[0m")
    has_part = true
  }
  if review > 0 {
    if has_part {
      agent_parts.write_string(" ")
    }
    agent_parts.write_string("\u001b[32m\{review} review\u001b[0m")
    has_part = true
  }
  if changes > 0 {
    if has_part {
      agent_parts.write_string(" ")
    }
    agent_parts.write_string("\u001b[35m\{changes} fixes\u001b[0m")
    has_part = true
  }
  if failed > 0 {
    if has_part {
      agent_parts.write_string(" ")
    }
    agent_parts.write_string("\u001b[31m\{failed} failed\u001b[0m")
    has_part = true
  }
  if done > 0 {
    if has_part {
      agent_parts.write_string(" ")
    }
    agent_parts.write_string("\{done} done")
    has_part = true
  }
  let pr_summary = statusline_pr_summary(project_dir)
  @sys.write_stdout(line1)
  if total > 0 || pr_summary != "" {
    let line2 = StringBuilder::new()
    if total > 0 {
      line2.write_string(agent_parts.to_string())
    }
    if pr_summary != "" {
      if total > 0 {
        line2.write_string("  ")
      }
      line2.write_string("PR ")
      line2.write_string(pr_summary)
    }
    @sys.write_stdout("\n" + line2.to_string())
  }
}

///|
fn main {
  let args = @env.args()
  let subcmd = if args.length() >= 2 { args[1] } else { "" }
  match subcmd {
    "serve" => serve_run()
    "dev" => dev_run()
    "leaf-tool" => leaf_tool_run()
    "mcp-stdio" => mcp_run()
    "trust-gemini-folder" => trust_gemini_folder_run()
    "zellij-action" => zellij_action_run()
    "hook" => hook_run()
    "init" => init_run()
    "stop" => stop_run()
    "reply" => reply_run()
    "smoke" => smoke_run()
    "watch" => watch_run()
    "statusline" => statusline_run()
    _ => {
      @sys.write_stdout(
        "usage: choir <serve|dev|leaf-tool <tool>|mcp-stdio|trust-gemini-folder <path>|zellij-action <send|close>|hook|init [--recreate] [--tl claude|codex|gemini|cursor_agent]|stop|reply|smoke [--keep-temp|--leafs|--companions|--review|--e2e-live]|watch|statusline>\n",
      )
      @sys.exit(1)
    }
  }
}
