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
fn serve_inherited_uds_fd() -> Int? {
  match @sys.getenv("CHOIR_INHERIT_UDS_FD") {
    Some(raw) => {
      let parsed = @string.parse_int(raw.trim()) catch { _ => -1 }
      if parsed >= 0 {
        Some(parsed)
      } else {
        None
      }
    }
    None => None
  }
}

///|
fn serve_is_reload_request(req : @types.Request) -> Bool {
  req.req_method == "tools/call" && req.name == "server_reload"
}

///|
fn serve_reload_binary_path_for_request(
  state : @server.ServerState,
  req : @types.Request,
) -> String {
  req.args
  .get("binary_path")
  .unwrap_or(@exec.reload_binary_path(state.config.project_dir))
}

///|
fn serve_replace_self_after_reload_ack(
  server_fd : Int,
  state : @server.ServerState,
  req : @types.Request,
) -> Unit {
  if !@uds.clear_cloexec(server_fd) {
    @moontrace.error("server reload failed to clear FD_CLOEXEC", fields=[
      @moontrace.field("fd", server_fd),
    ])
    return
  }
  let binary_path = serve_reload_binary_path_for_request(state, req)
  match @exec.replace_self(binary_path, server_fd) {
    Ok(_) => ()
    Err(e) => {
      @moontrace.error("server reload exec failed", fields=[
        @moontrace.field("binary_path", binary_path),
        @moontrace.field("error", e.message()),
      ])
      @sys.write_stderr("[server_reload] exec failed: " + e.message() + "\n")
    }
  }
}

///|
fn lifecycle_agent_id_for_register(req : @types.Request) -> String? {
  if req.req_method != "register" {
    return None
  }
  match req.args.get("connection_lifetime") {
    Some(raw) =>
      match @transport.parse_connection_lifetime(raw) {
        Some(@transport.ConnectionLifetime::OneShot) => return None
        Some(@transport.ConnectionLifetime::Session) => ()
        None => ()
      }
    None => ()
  }
  req.args.get("agent_id")
}

///|
test "lifecycle_agent_id_for_register ignores one-shot clients" {
  let req : @types.Request = {
    req_method: "register",
    role: @types.Role::Dev,
    name: "register",
    args: @types.RequestArgs::new({
      "agent_id": "main.leaf",
      "connection_lifetime": "oneshot",
    }),
  }
  @debug.assert_eq(lifecycle_agent_id_for_register(req), None)
}

///|
test "lifecycle_agent_id_for_register keeps session clients" {
  let req : @types.Request = {
    req_method: "register",
    role: @types.Role::Dev,
    name: "register",
    args: @types.RequestArgs::new({
      "agent_id": "main.leaf",
      "connection_lifetime": "session",
    }),
  }
  @debug.assert_eq(lifecycle_agent_id_for_register(req), Some("main.leaf"))
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
        if !authenticated {
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
            if serve_is_reload_request(req) {
              let resp = @types.Response::Err(
                "server_reload requires the UDS transport",
              )
              conn.write(@utf8.encode(@transport.format_response(resp) + "\n"))
              continue
            }
            if req.req_method == "register" {
              connected_agent_id = lifecycle_agent_id_for_register(req)
            }
            let resp = state.handle(req) catch {
              e => {
                @moontrace.error("handler error", fields=[
                  @moontrace.field("error", e.to_string()),
                ])
                @types.Response::Err("internal error: " + e.to_string())
              }
            }
            let resp_str = @transport.format_response(resp) + "\n"
            conn.write(@utf8.encode(resp_str))
          }
          Err(err) => {
            @moontrace.warn("parse error", fields=[
              @moontrace.field("line", line),
            ])
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
  @moontrace.trace("UDS write start", fields=[
    @moontrace.field("bytes", data.length()),
  ])
  while written < data.length() {
    let n = @uds.write_bytes(fd, data, written, data.length() - written)
    if n <= 0 {
      @moontrace.warn("UDS client disconnected", fields=[
        @moontrace.field("written", written),
      ])
      break
    }
    written = written + n
  }
}

///|
async fn serve_handle_uds_connection(
  client : ServeUDSClient,
  state : @server.ServerState,
  server_fd : Int,
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
              client.connected_agent_id = lifecycle_agent_id_for_register(req)
            }
            let resp = state.handle(req) catch {
              e => {
                @moontrace.error("handler error", fields=[
                  @moontrace.field("error", e.to_string()),
                ])
                @types.Response::Err("internal error: " + e.to_string())
              }
            }
            let resp_str = @transport.format_response(resp) + "\n"
            @moontrace.trace("request", fields=[@moontrace.field("line", line)])
            @moontrace.trace("response", fields=[
              @moontrace.field("body", resp_str),
            ])
            serve_write_all_uds(client.fd, @utf8.encode(resp_str))
            if serve_is_reload_request(req) && resp.is_ok() {
              serve_replace_self_after_reload_ack(server_fd, state, req)
            }
          }
          Err(err) => {
            @moontrace.warn("parse error", fields=[
              @moontrace.field("line", line),
            ])
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
fn serve_project_path(project_dir : String, rel : String) -> String {
  if project_dir == "" || project_dir == "." {
    rel
  } else {
    project_dir + "/" + rel
  }
}

///|
fn serve_cleanup_stale_goal_kv(
  project_dir : String,
  list_dir? : (String) -> Array[String] = @sys.list_dir,
  delete_file? : (String) -> Bool = @sys.delete_file_sync,
) -> Int {
  let kv_dir = serve_project_path(project_dir, ".choir/kv")
  let mut removed = 0
  for name in list_dir(kv_dir) {
    if name.has_prefix("tl-goal--") && name.has_suffix(".json") {
      if delete_file(kv_dir + "/" + name) {
        removed = removed + 1
      }
    }
  }
  removed
}

///|
test "serve cleanup removes stale tl goal kv files only" {
  let entries = [
    "tl-goal--old.json", "tl-goal--other.json", "tl-goal--missing.tmp", "lifecycle--root.json",
    "not-tl-goal--old.json",
  ]
  let listed : Array[String] = []
  let deleted : Array[String] = []
  let removed = serve_cleanup_stale_goal_kv(
    ".",
    list_dir=fn(path) {
      listed.push(path)
      entries
    },
    delete_file=fn(path) {
      deleted.push(path)
      true
    },
  )
  assert_eq(listed, [".choir/kv"])
  assert_eq(removed, 2)
  assert_eq(deleted, [
    ".choir/kv/tl-goal--old.json", ".choir/kv/tl-goal--other.json",
  ])
}

///|
fn serve_run() -> Unit {
  let config_content = @sys.read_file(".choir/config.toml")
  let config = match @config.parse_config(config_content) {
    Ok(cfg) => cfg
    Err(_) => @types.Config::default()
  }
  let inherited_uds_fd = serve_inherited_uds_fd()
  @moontrace.set_subscriber(fn(event) { println(event.format(color=true)) })
  @moontrace.set_min_level(@moontrace.Level::Debug)
  @sys.write_pid_file(".choir/server.pid")
  @sys.register_cleanup_runtime_artifacts()
  match inherited_uds_fd {
    Some(_) => ()
    // Clean stale runtime markers from previous sessions, but preserve recoverable
    // worktrees/lifecycle/poller state so restart recovery can rehydrate agents.
    None => {
      @sys.init_cleanup_runtime_artifacts_native()
      ignore(serve_cleanup_stale_goal_kv(config.project_dir))
    }
  }
  let provider = @server.make_recovery_provider()
  let state = @server.ServerState::new(config, provider)
  @moontrace.set_global_field("service", "choir".to_json())
  @moontrace.set_global_field("run_id", state.run_id.to_json())
  @async.run_async_main(async fn() {
    @async.with_task_group(async fn(root) {
      let recovery_input = @runtime.discover_recovery_input(
        provider,
        config.project_dir,
        config.terminal_session,
      )
      @server.recover_state(state, config.terminal_session, recovery_input)
      match inherited_uds_fd {
        Some(fd) =>
          match state.restore_reload_snapshot() {
            Ok(_) => {
              let line = "[server_reload] resumed run_id=" + state.run_id
              @moontrace.info(line, fields=[@moontrace.field("fd", fd)])
              @sys.write_stdout(line + "\n")
            }
            Err(e) =>
              @moontrace.error("server reload resume failed", fields=[
                @moontrace.field("error", e.message()),
              ])
          }
        None => ()
      }
      state.replay_pending_outbox(runner=@exec.run_sequence)
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
            if !state.process_requested_goal_judge_tick(
                now,
                runner=@exec.run_sequence,
              ) {
              state.process_goal_judge_tick(now, runner=@exec.run_sequence)
            }
            state.check_idle_agents(now, 300L, @exec.run_sequence)
          } catch {
            e =>
              @moontrace.error("poller tick error", fields=[
                @moontrace.field("error", e.to_string()),
              ])
          }
        }
      })
      root.spawn_bg(async fn() {
        for ;; {
          @async.sleep(1000)
          let now = @poller.now_sec()
          ignore(
            state.process_requested_goal_judge_tick(
              now,
              runner=@exec.run_sequence,
            ),
          ) catch {
            e =>
              @moontrace.error("goal judge requested tick loop error", fields=[
                @moontrace.field("error", e.to_string()),
              ])
          }
        }
      })
      root.spawn_bg(async fn() {
        let server_fd = match inherited_uds_fd {
          Some(fd) => fd
          None => @uds.server_create(config.listen_uds)
        }
        if server_fd < 0 {
          @moontrace.error("failed to bind UDS server", fields=[
            @moontrace.field("path", config.listen_uds),
          ])
          return
        }
        ignore(@uds.set_nonblocking(server_fd))
        match inherited_uds_fd {
          Some(fd) =>
            @moontrace.info("UDS server inherited listener", fields=[
              @moontrace.field("path", config.listen_uds),
              @moontrace.field("fd", fd),
            ])
          None =>
            @moontrace.info("UDS server listening", fields=[
              @moontrace.field("path", config.listen_uds),
            ])
        }
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
            let alive = serve_handle_uds_connection(
              clients[i],
              state,
              server_fd,
            ) catch {
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
            @moontrace.info("TCP server listening", fields=[
              @moontrace.field("addr", addr_str),
            ])
            for ;; {
              let (conn, addr) = server.accept()
              @moontrace.debug("TCP connection", fields=[
                @moontrace.field("addr", addr.to_string()),
              ])
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
