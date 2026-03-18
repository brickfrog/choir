///|
#borrow(path)
extern "C" fn c_get_file_size(path : Bytes) -> Int = "choir_get_file_size"

///|
#borrow(path, buf)
extern "C" fn c_read_file_to_buf(path : Bytes, buf : Bytes, size : Int) = "choir_read_file_to_buf"

///|
extern "C" fn c_exit(code : Int) = "choir_exit"

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
async fn handle_connection(
  conn : @socket.TCP,
  state : @server.ServerState,
) -> Unit {
  let buf = FixedArray::make(4096, (0 : Byte))
  let mut read_pos = 0
  for {
    let n = conn.recv(buf, offset=read_pos)
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
            conn.send(resp_str.to_bytes())
          }
          Err(err) => {
            let resp = @types.Response::Err("parse error: " + err)
            conn.send((@transport.format_response(resp) + "\n").to_bytes())
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
  let config_content = read_file_to_string(".exo/config.toml")
  let config = match @config.parse_config(config_content) {
    Ok(cfg) => cfg
    Err(_) => @types.Config::default()
  }
  let state = @server.ServerState::new(config)
  @async.with_event_loop(fn(root) {
    match config.listen_tcp {
      Some(addr_str) => {
        let listen_sock = @socket.TCP::new()
        try {
          listen_sock..bind(@socket.Addr::parse(addr_str))..listen()
          println("TCP server listening on \{addr_str}")
          for {
            let (conn, addr) = listen_sock.accept()
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
            listen_sock.close()
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
