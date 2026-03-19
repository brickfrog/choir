///|
struct TCPLineReader {
  conn : @socket.TCP
  buf : FixedArray[Byte]
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
  buf : FixedArray[Byte]
  mut read_pos : Int
  mut write_pos : Int
}

///|
fn UDSLineReader::new(fd : Int) -> UDSLineReader {
  { fd, buf: FixedArray::make(8192, (0 : Byte)), read_pos: 0, write_pos: 0 }
}

///|
async fn TCPLineReader::read_line(self : TCPLineReader) -> String {
  for {
    // Check if we already have a line in buffer
    let bytes = self.buf.unsafe_reinterpret_as_bytes()
    for i = self.read_pos; i < self.write_pos; i = i + 1 {
      if bytes[i] == (10 : Byte) {
        let line = bytes.to_unchecked_string(
          offset=self.read_pos,
          length=i - self.read_pos,
        )
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
      raise Failure::Failure("Line too long")
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
        let line = bytes.to_unchecked_string(
          offset=self.read_pos,
          length=self.write_pos - self.read_pos,
        )
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
        let line = bytes.to_unchecked_string(
          offset=self.read_pos,
          length=i - self.read_pos,
        )
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
      return ""
    }

    let n = @uds.read_bytes(
      self.fd,
      self.buf,
      self.write_pos,
      self.buf.length() - self.write_pos,
    )
    if n <= 0 {
      if self.write_pos > self.read_pos {
        let line = bytes.to_unchecked_string(
          offset=self.read_pos,
          length=self.write_pos - self.read_pos,
        )
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
fn build_registration_message(
  role : @types.Role,
  config : @types.Config,
) -> String {
  let role_str = @config.role_to_string(role)
  let agent_id = match config.agent_id {
    Some(id) => id
    None => "agent-" + role_str
  }
  "{\"method\":\"register\",\"role\":\"" +
  role_str +
  "\",\"name\":\"register\",\"args\":{\"agent_id\":\"" +
  agent_id +
  "\"}}\n"
}

///|
fn build_wire_request(internal_req : @types.Request) -> String {
  let req_method = internal_req.req_method
  let role_str = @config.role_to_string(internal_req.role)
  let name = internal_req.name
  let args_buf = StringBuilder::new()
  args_buf.write_char('{')
  let mut first = true
  internal_req.args.each(fn(k, v) {
    if not(first) {
      args_buf.write_char(',')
    }
    args_buf.write_string("\"" + k + "\":\"" + v + "\"")
    first = false
  })
  args_buf.write_char('}')
  "{\"method\":\"\{req_method}\",\"role\":\"\{role_str}\",\"name\":\"\{name}\",\"args\":\{args_buf.to_string()}}\n"
}

///|
fn write_server_response(id : Int, resp_line : String) -> Unit {
  if resp_line == "" {
    let err_resp = @mcp.error_response(
      id, @mcp.err_internal, "server connection closed",
    )
    @io.write_stdout_bytes(@mcp.response_to_bytes(err_resp))
    return
  }

  match @transport.parse_response(resp_line) {
    Ok(internal_resp) => {
      let rpc_resp = @mcp.from_internal_response(id, internal_resp)
      @io.write_stdout_bytes(@mcp.response_to_bytes(rpc_resp))
    }
    Err(e) => {
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
) -> Unit {
  let reader = UDSLineReader::new(uds_fd)
  let reg_msg = build_registration_message(role, config)
  if not(write_all_uds(uds_fd, @utf8.encode(reg_msg))) {
    println("error: registration failed: UDS write failed")
    @uds.close(uds_fd)
    @io.exit(1)
  }

  let reg_resp = reader.read_line()
  if reg_resp == "" {
    println("error: registration failed: server connection closed")
    @uds.close(uds_fd)
    @io.exit(1)
  }

  for {
    let (stdin_buf, len) = @io.read_stdin_line(8192)
    if len == 0 {
      break
    }

    let line = stdin_buf.to_unchecked_string(offset=0, length=len)
    match @mcp.parse_jsonrpc_request(line) {
      Ok(rpc) =>
        if rpc.req_method == @mcp.method_tools_list {
          let resp = @mcp.tools_list_response(rpc.id)
          @io.write_stdout_bytes(@mcp.response_to_bytes(resp))
        } else {
          let id = rpc.id
          match @mcp.to_internal_request(rpc, role) {
            Ok(internal_req) => {
              let wire_req = build_wire_request(internal_req)
              if not(write_all_uds(uds_fd, @utf8.encode(wire_req))) {
                let err_resp = @mcp.error_response(
                  id, @mcp.err_internal, "UDS error: write failed",
                )
                @io.write_stdout_bytes(@mcp.response_to_bytes(err_resp))
              } else {
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
      Err(e) => {
        let err_resp = @mcp.error_response(0, e.code, e.message)
        @io.write_stdout_bytes(@mcp.response_to_bytes(err_resp))
      }
    }
  }

  @uds.close(uds_fd)
}

///|
fn main_prog() -> Unit raise {
  let config_content = @io.read_file(".exo/config.toml")
  let config = match @config.parse_config(config_content) {
    Ok(cfg) => cfg
    Err(_) => {
      println("error: failed to parse .exo/config.toml")
      @io.exit(1)
      @types.Config::default() // unreachable
    }
  }

  let local_content = @io.read_file(".exo/config.local.toml")
  let local_role = match @config.parse_config_local(local_content) {
    Ok(r) => Some(r)
    Err(_) => None
  }
  let role = @config.resolve_role(local_role, config)

  let uds_fd = @uds.client_connect(config.listen_uds)
  if uds_fd >= 0 {
    run_uds_loop(uds_fd, role, config)
    return
  }

  @async.with_event_loop(async fn(_root) {
    let addr_str = match config.listen_tcp {
      Some(addr) => addr
      None => {
        println("error: listen_tcp not configured in .exo/config.toml")
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

    let reg_msg = build_registration_message(role, config)
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
      let (stdin_buf, len) = @io.read_stdin_line(8192)
      if len == 0 {
        break
      }

      let line = stdin_buf.to_unchecked_string(offset=0, length=len)
      match @mcp.parse_jsonrpc_request(line) {
        Ok(rpc) =>
          if rpc.req_method == @mcp.method_tools_list {
            let resp = @mcp.tools_list_response(rpc.id)
            @io.write_stdout_bytes(@mcp.response_to_bytes(resp))
          } else {
            let id = rpc.id
            match @mcp.to_internal_request(rpc, role) {
              Ok(internal_req) => {
                let wire_req = build_wire_request(internal_req)

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
        Err(e) => {
          let err_resp = @mcp.error_response(0, e.code, e.message)
          @io.write_stdout_bytes(@mcp.response_to_bytes(err_resp))
        }
      }
    }
    conn.close()
  })
}

///|
fn main {
  main_prog() catch {
    err => println("fatal: \{err}")
  }
}
