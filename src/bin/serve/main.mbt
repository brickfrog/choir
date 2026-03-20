///|
fn fixed_array_slice_to_string(
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
struct UDSClient {
  fd : Int
  mut buf : FixedArray[Byte]
  mut read_pos : Int
  mut connected_agent_id : String?
}

///|
fn UDSClient::new(fd : Int) -> UDSClient {
  {
    fd,
    buf: FixedArray::make(4096, (0 : Byte)),
    read_pos: 0,
    connected_agent_id: None,
  }
}

///|
async fn handle_connection(
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
        let line = fixed_array_slice_to_string(buf, 0, i)
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
fn write_all_uds(fd : Int, data : Bytes) -> Unit {
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
async fn handle_uds_connection(
  client : UDSClient,
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
        let line = fixed_array_slice_to_string(client.buf, 0, i)
        let req_res = @transport.parse_request(line)
        match req_res {
          Ok(req) => {
            if req.req_method == "register" {
              client.connected_agent_id = req.args.get("agent_id")
            }
            let resp = state.handle(req)
            let resp_str = @transport.format_response(resp) + "\n"
            write_all_uds(client.fd, @utf8.encode(resp_str))
          }
          Err(err) => {
            let resp = @types.Response::Err("parse error: " + err)
            write_all_uds(
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
async fn close_uds_client(
  client : UDSClient,
  state : @server.ServerState,
) -> Unit {
  @uds.close(client.fd)
  match client.connected_agent_id {
    Some(agent_id) => state.handle_disconnect(agent_id)
    None => ()
  }
}

///|
fn main_prog() -> Unit raise {
  let config_content = @io.read_file(".choir/config.toml")
  let config = match @config.parse_config(config_content) {
    Ok(cfg) => cfg
    Err(_) => @types.Config::default()
  }
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
      let clients : Array[UDSClient] = []
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
          clients.push(UDSClient::new(client_fd))
        }
        let mut i = 0
        while i < clients.length() {
          let alive = handle_uds_connection(clients[i], state) catch {
            _ => false
          }
          if alive {
            i = i + 1
          } else {
            let client = clients.remove(i)
            close_uds_client(client, state) catch {
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
              handle_connection(conn, state) catch {
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
