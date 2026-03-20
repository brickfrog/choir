///|
priv struct TCPLineReader {
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
priv struct UDSLineReader {
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
    // Check if we already have a line in buffer
    let bytes = self.buf.unsafe_reinterpret_as_bytes()
    for i = self.read_pos; i < self.write_pos; i = i + 1 {
      if bytes[i] == (10 : Byte) {
        let line = @utf8.decode_lossy(bytes[self.read_pos:i])
        self.read_pos = i + 1
        return line
      }
    }

    // Move remaining data to start of buffer if needed
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

    // Buffer is full but no newline found
    if self.write_pos == self.buf.length() {
      self.buf = grow_line_buffer(self.buf)
    }

    // Read more from TCP
    let n = self.conn.read(
      self.buf,
      offset=self.write_pos,
      max_len=self.buf.length() - self.write_pos,
    )
    if n == 0 {
      // Connection closed. If there's something left in buffer without newline, return it.
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
fn write_all_uds(fd : Int, data : Bytes) -> Bool {
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
fn resolved_agent_id(
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
fn build_registration_message(
  role : @types.Role,
  config : @types.Config,
  local_cfg : @types.LocalConfig,
) -> String {
  let agent_id = resolved_agent_id(role, config, local_cfg)
  @transport.format_registration_request(role, agent_id, local_cfg) + "\n"
}

///|
fn build_wire_request(
  internal_req : @types.Request,
  role : @types.Role,
  config : @types.Config,
  local_cfg : @types.LocalConfig,
) -> String {
  let agent_id = resolved_agent_id(role, config, local_cfg)
  @transport.format_augmented_request(internal_req, agent_id, local_cfg) + "\n"
}

///|
fn cli_override_role(args : Array[String]) -> @types.Role? {
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
fn cli_override_agent_id(args : Array[String]) -> String? {
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
fn write_server_response(id : @mcp.JsonRpcId, resp_line : String) -> Unit {
  if resp_line == "" {
    @io.write_stderr("[choir mcp-stdio] empty server response for id\n")
    let err_resp = @mcp.error_response(
      id, @mcp.err_internal, "server connection closed",
    )
    @io.write_stdout_bytes(@mcp.response_to_bytes(err_resp))
    return
  }

  match @transport.parse_response(resp_line) {
    Ok(internal_resp) => {
      let rpc_resp = @mcp.from_internal_response(id, internal_resp)
      @io.write_stderr("[choir mcp-stdio] server response: " + resp_line + "\n")
      @io.write_stderr(
        "[choir mcp-stdio] rpc response: " + rpc_resp.to_json_string() + "\n",
      )
      @io.write_stdout_bytes(@mcp.response_to_bytes(rpc_resp))
    }
    Err(e) => {
      @io.write_stderr(
        "[choir mcp-stdio] failed to parse server response: " + resp_line + "\n",
      )
      let err_resp = @mcp.error_response(
        id,
        @mcp.err_internal,
        "failed to parse server response: " + e,
      )
      @io.write_stdout_bytes(@mcp.response_to_bytes(err_resp))
    }
  }
}

///|
fn run_uds_loop(
  uds_fd : Int,
  role : @types.Role,
  config : @types.Config,
  local_cfg : @types.LocalConfig,
) -> Unit {
  let reader = UDSLineReader::new(uds_fd)
  let reg_msg = build_registration_message(role, config, local_cfg)
  @io.write_stderr("[choir mcp-stdio] starting UDS loop\n")
  @io.write_stderr("[choir mcp-stdio] registration request: " + reg_msg)
  if not(write_all_uds(uds_fd, @utf8.encode(reg_msg))) {
    println("error: registration failed: UDS write failed")
    @uds.close(uds_fd)
    @io.exit(1)
  }

  let reg_resp = reader.read_line()
  @io.write_stderr(
    "[choir mcp-stdio] registration response: " + reg_resp + "\n",
  )
  if reg_resp == "" {
    println("error: registration failed: server connection closed")
    @uds.close(uds_fd)
    @io.exit(1)
  }

  for {
    let line = match @io.read_stdin_line(8192) {
      Some(line) => line
      None => break
    }
    @io.write_stderr("[choir mcp-stdio] stdin request: " + line + "\n")
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
              let wire_req = build_wire_request(
                internal_req, role, config, local_cfg,
              )
              @io.write_stderr("[choir mcp-stdio] wire request: " + wire_req)
              if not(write_all_uds(uds_fd, @utf8.encode(wire_req))) {
                let err_resp = @mcp.error_response(
                  id, @mcp.err_internal, "UDS error: write failed",
                )
                @io.write_stdout_bytes(@mcp.response_to_bytes(err_resp))
              } else {
                @io.write_stderr(
                  "[choir mcp-stdio] waiting for server response\n",
                )
                let resp_line = reader.read_line()
                write_server_response(id, resp_line)
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

  @uds.close(uds_fd)
}

///|
fn main_prog() -> Unit raise {
  let args = @io.get_args()
  let config_content = @io.read_file(".choir/config.toml")
  let base_config = match @config.parse_config(config_content) {
    Ok(cfg) => cfg
    Err(_) => {
      println("error: failed to parse .choir/config.toml")
      @io.exit(1)
      @types.Config::default() // unreachable
    }
  }

  let local_content = @io.read_file(".choir/config.local.toml")
  let local_cfg = match @config.parse_local_config(local_content) {
    Ok(cfg) => cfg
    Err(_) => @types.LocalConfig::default()
  }
  let config = {
    ..base_config,
    agent_id: match local_cfg.agent_id {
      Some(agent_id) => Some(agent_id)
      None =>
        match cli_override_agent_id(args) {
          Some(agent_id) => Some(agent_id)
          None => base_config.agent_id
        }
    },
  }
  let role = match cli_override_role(args) {
    Some(role) => role
    None => @config.resolve_role(local_cfg.role, config)
  }

  let uds_fd = @uds.client_connect(config.listen_uds)
  if uds_fd >= 0 {
    run_uds_loop(uds_fd, role, config, local_cfg)
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

    let reg_msg = build_registration_message(role, config, local_cfg)
    try {
      match config.tcp_auth_token {
        Some(token) => conn.write(@utf8.encode(token + "\n"))
        None => ()
      }
      conn.write(@utf8.encode(reg_msg))
      // Read and discard the registration response
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
                let wire_req = build_wire_request(
                  internal_req, role, config, local_cfg,
                )

                try {
                  conn.write(@utf8.encode(wire_req))
                  let resp_line = reader.read_line()
                  write_server_response(id, resp_line)
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
