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
async fn serve_handle_connection(
  conn : @socket.TCP,
  state : @server.ServerState,
) -> Unit {
  let buf = FixedArray::make(4096, (0 : Byte))
  let mut read_pos = 0
  let mut authenticated = match state.config.tcp_auth_token {
    None => true
    Some(_) => false
  }
  let mut connected_agent_id : String? = None
  for {
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
    if read_pos == buf.length() {
      read_pos = 0
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
  while written < data.length() {
    let n = @uds.write_bytes(fd, data, written, data.length() - written)
    if n <= 0 {
      break
    }
    written = written + n
  }
}

///|
async fn serve_handle_uds_connection(
  client_fd : Int,
  state : @server.ServerState,
) -> Unit {
  let buf = FixedArray::make(4096, (0 : Byte))
  let mut read_pos = 0
  let mut connected_agent_id : String? = None
  for {
    let n = @uds.read_bytes(client_fd, buf, read_pos, buf.length() - read_pos)
    if n <= 0 {
      break
    }
    read_pos = read_pos + n
    let mut i = 0
    while i < read_pos {
      if buf[i] == (10 : Byte) {
        let line = serve_fixed_array_slice_to_string(buf, 0, i)
        let req_res = @transport.parse_request(line)
        match req_res {
          Ok(req) => {
            if req.req_method == "register" {
              connected_agent_id = req.args.get("agent_id")
            }
            let resp = state.handle(req)
            let resp_str = @transport.format_response(resp) + "\n"
            serve_write_all_uds(client_fd, @utf8.encode(resp_str))
          }
          Err(err) => {
            let resp = @types.Response::Err("parse error: " + err)
            serve_write_all_uds(
              client_fd,
              @utf8.encode(@transport.format_response(resp) + "\n"),
            )
          }
        }
        let remaining = read_pos - (i + 1)
        if remaining > 0 {
          for j = 0; j < remaining; j = j + 1 {
            buf[j] = buf[i + 1 + j]
          }
        }
        read_pos = remaining
        i = 0
      } else {
        i = i + 1
      }
    }
    if read_pos == buf.length() {
      read_pos = 0
    }
  }
  match connected_agent_id {
    Some(agent_id) => state.handle_disconnect(agent_id)
    None => ()
  }
}

///|
fn serve_format_poll_event(event : @poller.PollEvent) -> String {
  match event {
    PRReady(n) => "[PR READY] PR #\{n} approved"
    ReviewReceived(n, comments) =>
      if comments == "" {
        "[REVIEW] PR #\{n} has review comments"
      } else {
        "[REVIEW] PR #\{n} has review comments:\n\{comments}"
      }
    FixesPushed(n) => "[FIXES PUSHED] PR #\{n} new commits after review"
    ReviewTimeout(n) => "[REVIEW TIMEOUT] PR #\{n} no review after 15min"
    CIFailed(n) => "[CI FAILED] PR #\{n} CI checks failing"
  }
}

///|
fn serve_run() -> Unit raise {
  let config_content = @io.read_file(".choir/config.toml")
  let config = match @config.parse_config(config_content) {
    Ok(cfg) => cfg
    Err(_) => @types.Config::default()
  }
  let state = @server.ServerState::new(config)
  @async.with_event_loop(async fn(root) {
    @server.recover_state(state, "choir")
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
          match state.registry.get(agent_id) {
            Ok(agent) => {
              let msg = serve_format_poll_event(event)
              let delivery = @message.plan_delivery(
                agent, "poller", msg, "info",
              )
              ignore(@tools.execute_delivery(delivery, @exec.run_sequence))
            }
            Err(_) => ()
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
      println("UDS server listening on \{config.listen_uds}")
      for {
        let client_fd = @uds.accept(server_fd)
        if client_fd < 0 {
          break
        }
        serve_handle_uds_connection(client_fd, state) catch {
          _ => ()
        }
        @uds.close(client_fd)
      }
      @uds.close(server_fd)
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
      raise Failure::Failure("Line too long")
    }

    let n = self.conn.read(
      self.buf,
      offset=self.write_pos,
      max_len=self.buf.length() - self.write_pos,
    )
    if n == 0 {
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
fn mcp_build_registration_message(
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
fn mcp_build_wire_request(internal_req : @types.Request) -> String {
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
fn mcp_write_server_response(id : Int, resp_line : String) -> Unit {
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
fn mcp_run_uds_loop(
  uds_fd : Int,
  role : @types.Role,
  config : @types.Config,
) -> Unit {
  let reader = UDSLineReader::new(uds_fd)
  let reg_msg = mcp_build_registration_message(role, config)
  if not(mcp_write_all_uds(uds_fd, @utf8.encode(reg_msg))) {
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
              let wire_req = mcp_build_wire_request(internal_req)
              if not(mcp_write_all_uds(uds_fd, @utf8.encode(wire_req))) {
                let err_resp = @mcp.error_response(
                  id, @mcp.err_internal, "UDS error: write failed",
                )
                @io.write_stdout_bytes(@mcp.response_to_bytes(err_resp))
              } else {
                let resp_line = reader.read_line()
                mcp_write_server_response(id, resp_line)
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
fn mcp_run() -> Unit raise {
  let config_content = @io.read_file(".choir/config.toml")
  let config = match @config.parse_config(config_content) {
    Ok(cfg) => cfg
    Err(_) => {
      println("error: failed to parse .choir/config.toml")
      @io.exit(1)
      @types.Config::default()
    }
  }

  let local_content = @io.read_file(".choir/config.local.toml")
  let local_role = match @config.parse_config_local(local_content) {
    Ok(r) => Some(r)
    Err(_) => None
  }
  let role = @config.resolve_role(local_role, config)

  let uds_fd = @uds.client_connect(config.listen_uds)
  if uds_fd >= 0 {
    mcp_run_uds_loop(uds_fd, role, config)
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

    let reg_msg = mcp_build_registration_message(role, config)
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
                let wire_req = mcp_build_wire_request(internal_req)

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
fn hook_run() -> Unit raise {
  @async.with_event_loop(_ => {
    let (stdin_buf, len) = @io.read_stdin_line(8192)
    if len == 0 {
      @io.write_stdout(@hooks.HookResponse::fail_open().to_json_string() + "\n")
      return
    }

    let line = stdin_buf.to_unchecked_string(offset=0, length=len)
    let input = match @hooks.HookInput::from_json_string(line) {
      Some(i) => i
      None => {
        @io.write_stdout(
          @hooks.HookResponse::fail_open().to_json_string() + "\n",
        )
        return
      }
    }

    let config_content = @io.read_file(".choir/config.toml")
    let config_map = @config.parse_toml(config_content)

    let hook_key = match input.event {
      @hooks.HookEvent::SessionStart => "hook.session_start"
      @hooks.HookEvent::PreToolUse => "hook.pre_tool_use"
    }

    match config_map.get(hook_key) {
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
fn init_mcp_json_content() -> String {
  "{\n" +
  "  \"mcpServers\": {\n" +
  "    \"choir\": {\n" +
  "      \"type\": \"stdio\",\n" +
  "      \"command\": \"choir\",\n" +
  "      \"args\": [\"mcp-stdio\"]\n" +
  "    }\n" +
  "  }\n" +
  "}\n"
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
  @async.with_event_loop(_ => {
    if @io.read_file(".mcp.json") != "" {
      @io.write_stdout("Already initialized.\n")
      return
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
        init_mcp_json_content(),
      ],
      workdir: None,
    })

    @io.write_stdout("Initialized .choir/ and .mcp.json\n")
  })
}

///|
fn main {
  let args = @io.get_args()
  let subcmd = if args.length() >= 2 { args[1] } else { "" }
  match subcmd {
    "serve" => serve_run() catch { _ => @io.exit(1) }
    "mcp-stdio" => mcp_run() catch { err => println("fatal: \{err}") }
    "hook" =>
      hook_run() catch {
        _ =>
          @io.write_stdout(
            @hooks.HookResponse::fail_open().to_json_string() + "\n",
          )
      }
    "init" => init_run() catch { _ => @io.exit(1) }
    _ => {
      @io.write_stdout("usage: choir <serve|mcp-stdio|hook|init>\n")
      @io.exit(1)
    }
  }
}
