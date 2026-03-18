///|
#borrow(path)
extern "C" fn c_get_file_size(path : Bytes) -> Int = "choir_get_file_size"

///|
#borrow(path, buf)
extern "C" fn c_read_file_to_buf(path : Bytes, buf : Bytes, size : Int) = "choir_read_file_to_buf"

///|
extern "C" fn c_exit(code : Int) = "choir_exit"

///|
#borrow(buf)
extern "C" fn c_stdin_read_line(buf : Bytes, max_size : Int) -> Int = "choir_stdin_read_line"

///|
#borrow(buf)
extern "C" fn c_stdout_write(buf : Bytes, size : Int) = "choir_stdout_write"

///|
fn string_to_null_terminated_bytes(s : String) -> Bytes {
  let b = s.to_bytes()
  let len = b.length()
  let result = FixedArray::make(len + 1, (0 : Byte))
  for i = 0; i < len; i = i + 1 {
    result[i] = b[i]
  }
  result[len] = (0 : Byte)
  result.unsafe_reinterpret_as_bytes()
}

///|
fn read_file_to_string(path : String) -> String {
  let path_bytes = string_to_null_terminated_bytes(path)
  let size = c_get_file_size(path_bytes)
  if size < 0 {
    return ""
  }
  let buf = Bytes::new(size)
  c_read_file_to_buf(path_bytes, buf, size)
  buf.to_unchecked_string(offset=0, length=size)
}

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
    let n = self.conn.recv(self.buf, offset=self.write_pos)
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
fn main_prog() -> Unit raise {
  let config_content = read_file_to_string(".exo/config.toml")
  let config = match @config.parse_config(config_content) {
    Ok(cfg) => cfg
    Err(_) => {
      println("error: failed to parse .exo/config.toml")
      c_exit(1)
      @types.Config::default() // unreachable
    }
  }

  let local_content = read_file_to_string(".exo/config.local.toml")
  let local_role = match @config.parse_config_local(local_content) {
    Ok(r) => Some(r)
    Err(_) => None
  }
  let role = @config.resolve_role(local_role, config)

  @async.with_event_loop(async fn(_root) {
    let addr_str = match config.listen_tcp {
      Some(addr) => addr
      None => {
        println("error: listen_tcp not configured in .exo/config.toml")
        c_exit(1)
        ""
      }
    }

    let conn = @socket.TCP::new()
    ignore(conn..connect(@socket.Addr::parse(addr_str))) catch {
      err => {
        println("error: failed to connect to \{addr_str}: \{err}")
        c_exit(1)
      }
    }

    let reader = TCPLineReader::new(conn)
    let stdin_buf = Bytes::new(8192)

    for {
      let len = c_stdin_read_line(stdin_buf, 8192)
      if len == 0 {
        break
      }

      let line = stdin_buf.to_unchecked_string(offset=0, length=len)
      match @mcp.parse_jsonrpc_request(line) {
        Ok(rpc) =>
          if rpc.req_method == @mcp.method_tools_list {
            let resp = @mcp.tools_list_response(rpc.id)
            let bytes = @mcp.response_to_bytes(resp)
            c_stdout_write(bytes, bytes.length())
          } else {
            let id = rpc.id
            match @mcp.to_internal_request(rpc, role) {
              Ok(internal_req) => {
                // Convert to internal wire format JSON + \n
                // Internal wire format for Request: {"method":"<req_method>","role":"<role>","name":"<name>","args":{...}}
                let req_method = internal_req.req_method
                let role_str = match internal_req.role {
                  @types.Role::Root => "root"
                  @types.Role::TL => "tl"
                  @types.Role::Dev => "dev"
                  @types.Role::Worker => "worker"
                }
                let name = internal_req.name

                // Map args to JSON string
                let args_buf = StringBuilder::new()
                args_buf.write_char('{')
                let mut first = true
                internal_req.args.each(fn(k, v) {
                  if not(first) {
                    args_buf.write_char(',')
                  }
                  args_buf.write_string("\"" + k + "\":\"" + v + "\"") // Simplified escaping for now, mcp/serialize has better
                  first = false
                })
                args_buf.write_char('}')

                let wire_req = "{\"method\":\"\{req_method}\",\"role\":\"\{role_str}\",\"name\":\"\{name}\",\"args\":\{args_buf.to_string()}}\n"

                try {
                  conn.send(wire_req.to_bytes())
                  let resp_line = reader.read_line()
                  if resp_line == "" {
                    let err_resp = @mcp.error_response(
                      id, @mcp.err_internal, "server connection closed",
                    )
                    c_stdout_write(
                      @mcp.response_to_bytes(err_resp),
                      @mcp.response_to_bytes(err_resp).length(),
                    )
                  } else {
                    match @transport.parse_response(resp_line) {
                      Ok(internal_resp) => {
                        let rpc_resp = @mcp.from_internal_response(
                          id, internal_resp,
                        )
                        let bytes = @mcp.response_to_bytes(rpc_resp)
                        c_stdout_write(bytes, bytes.length())
                      }
                      Err(e) => {
                        let err_resp = @mcp.error_response(
                          id,
                          @mcp.err_internal,
                          "failed to parse server response: " + e,
                        )
                        c_stdout_write(
                          @mcp.response_to_bytes(err_resp),
                          @mcp.response_to_bytes(err_resp).length(),
                        )
                      }
                    }
                  }
                } catch {
                  err => {
                    let err_resp = @mcp.error_response(
                      id,
                      @mcp.err_internal,
                      "TCP error: \{err}",
                    )
                    c_stdout_write(
                      @mcp.response_to_bytes(err_resp),
                      @mcp.response_to_bytes(err_resp).length(),
                    )
                  }
                }
              }
              Err(e) => {
                let err_resp = @mcp.error_response(id, e.code, e.message)
                let bytes = @mcp.response_to_bytes(err_resp)
                c_stdout_write(bytes, bytes.length())
              }
            }
          }
        Err(e) => {
          // If we can't parse ID, we use 0 or something. 
          // MCP spec says if id is missing/invalid, return null for id if possible.
          // But our JsonRpcResponse.id is Int.
          let err_resp = @mcp.error_response(0, e.code, e.message)
          let bytes = @mcp.response_to_bytes(err_resp)
          c_stdout_write(bytes, bytes.length())
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
