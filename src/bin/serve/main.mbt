///|
async fn handle_connection(
  conn : @socket.TCP,
  state : @server.ServerState,
) -> Unit {
  let buf = FixedArray::make(4096, (0 : Byte))
  let mut read_pos = 0
  for {
    let n = conn.read(buf, offset=read_pos, max_len=buf.length() - read_pos)
    if n == 0 {
      break
    }
    read_pos = read_pos + n
    let bytes = buf.unsafe_reinterpret_as_bytes()
    let mut i = 0
    while i < read_pos {
      if bytes[i] == (10 : Byte) {
        let line = bytes.to_unchecked_string(offset=0, length=i)
        let req_res = @transport.parse_request(line)
        match req_res {
          Ok(req) => {
            let resp = state.handle(req)
            let resp_str = @transport.format_response(resp) + "\n"
            conn.write(resp_str.to_bytes())
          }
          Err(err) => {
            let resp = @types.Response::Err("parse error: " + err)
            conn.write((@transport.format_response(resp) + "\n").to_bytes())
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
}

///|
fn main_prog() -> Unit raise {
  let config_content = @io.read_file(".exo/config.toml")
  let config = match @config.parse_config(config_content) {
    Ok(cfg) => cfg
    Err(_) => @types.Config::default()
  }
  let state = @server.ServerState::new(config)
  @async.with_event_loop(fn(root) {
    match config.listen_tcp {
      Some(addr_str) => {
        let server = @socket.TCPServer::new(@socket.Addr::parse(addr_str))
        try {
          println("TCP server listening on \{addr_str}")
          for {
            let (conn, addr) = server.accept()
            println("connection from \{addr}")
            root.spawn_bg(fn() {
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

///|
fn main {
  main_prog() catch {
    err => println("fatal: \{err}")
  }
}
