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
          match role {
            @types.Role::TL => "root"
            _ =>
              "agent-" +
              @config.role_to_string(role) +
              "-" +
              @sys.get_pid().to_string()
          }
      }
  }
}

///|
fn mcp_connection_has_stable_agent_id(
  config : @types.Config,
  local_cfg : @types.LocalConfig,
) -> Bool {
  config.agent_id is Some(_) || local_cfg.agent_id is Some(_)
}

///|
fn mcp_should_register_connection(
  role : @types.Role,
  config : @types.Config,
  local_cfg : @types.LocalConfig,
) -> Bool {
  match role {
    @types.Role::TL => mcp_connection_has_stable_agent_id(config, local_cfg)
    _ => true
  }
}

///|
fn mcp_config_with_cli_overrides(
  base_config : @types.Config,
  local_cfg : @types.LocalConfig,
  args : Array[String],
) -> @types.Config {
  let base_config = config_with_local_listen_uds(base_config, local_cfg)
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
/// Resolve the `LocalConfig` used to register an MCP-stdio session, preferring
/// the spawn-written inline metadata file when CLI `--name` declares a child
/// agent. Inline workers run in the parent's cwd, so cwd
/// `.choir/config.local.toml` belongs to the parent and would clobber the
/// worker's `parent_id` on register (see `master.sarcasmotron-*` notify_parent
/// failures). Child agent ids contain a `.`; root TL ids ("root", "user-...")
/// do not, so this guard does not affect TL bring-up.
fn mcp_local_cfg_with_agent_metadata_fallback(
  local_cfg : @types.LocalConfig,
  args : Array[String],
  env_get? : (String) -> String? = fn(key) { @sys.getenv(key) },
  read_file? : (String) -> String = fn(path) { @sys.read_file(path) },
) -> @types.LocalConfig {
  match mcp_cli_override_agent_id(args) {
    Some(agent_id) =>
      if agent_id.contains(".") {
        let metadata_path = ".choir/state/inline/" +
          @types.sanitize_agent_id(agent_id) +
          "/.choir/config.local.toml"
        match @config.parse_local_config(read_file(metadata_path)) {
          Ok(cfg) => if local_cfg_has_registration_identity(cfg) { return cfg }
          Err(_) => ()
        }
      }
    None => ()
  }
  if local_cfg_has_registration_identity(local_cfg) {
    return local_cfg
  }
  local_cfg_from_env_lookup(env_get)
}

///|
fn mcp_build_registration_message(
  role : @types.Role,
  config : @types.Config,
  local_cfg : @types.LocalConfig,
  connection_lifetime? : @transport.ConnectionLifetime = @transport.ConnectionLifetime::Session,
) -> String {
  let agent_id = mcp_resolved_agent_id(role, config, local_cfg)
  @transport.format_registration_request(
    role,
    agent_id,
    local_cfg,
    connection_lifetime~,
  ) +
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
  let trimmed = line.trim().to_owned()
  let prefix = if trimmed.has_prefix("Content-Length:") {
    "Content-Length:"
  } else if trimmed.has_prefix("content-length:") {
    "content-length:"
  } else {
    return None
  }
  let value_str = trimmed[prefix.length():].trim().to_owned()
  Some(@string.parse_int(value_str)) catch {
    _ => None
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
    let trimmed = line.trim().to_owned()
    if trimmed == "" {
      if !saw_headers {
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
fn mcp_parse_decimal_u32(s : String) -> Int? {
  let n_opt = Some(@string.parse_int(s)) catch { _ => None }
  match n_opt {
    Some(n) => if n <= 0 { None } else { Some(n) }
    None => None
  }
}

///|
fn mcp_cli_positive_int_arg(args : Array[String], flag : String) -> Int? {
  let mut i = 0
  while i < args.length() {
    if args[i] == flag && i + 1 < args.length() {
      return mcp_parse_decimal_u32(args[i + 1])
    }
    i = i + 1
  }
  None
}

///|
fn mcp_cli_wait_socket_tries(args : Array[String]) -> Int {
  match mcp_cli_positive_int_arg(args, "--wait-socket-tries") {
    Some(n) => n
    // Direct `choir mcp-stdio` defaults to about 30s per socket wait; the
    // outer startup attempts already stretch cold-start handling to about 93s.
    None => 150
  }
}

///|
fn mcp_cli_startup_attempts(args : Array[String]) -> Int {
  match mcp_cli_positive_int_arg(args, "--mcp-startup-attempts") {
    Some(n) => n
    None => 3
  }
}

///|
fn mcp_cli_startup_backoff_base_ms(args : Array[String]) -> Int {
  match mcp_cli_positive_int_arg(args, "--mcp-startup-backoff-base-ms") {
    Some(n) => n
    None => 1000
  }
}

///|
fn mcp_cli_stderr_append_log(args : Array[String]) -> String? {
  let mut i = 0
  while i < args.length() {
    if args[i] == "--stderr-append-log" && i + 1 < args.length() {
      let p = args[i + 1]
      if p != "" && !p.has_prefix("--") {
        return Some(p)
      }
      return None
    }
    i = i + 1
  }
  None
}

///|
priv enum McpUdsLoopExit {
  InputClosed
  Reconnect
}

///|
priv enum McpStartupConnectResult {
  Connected(Int)
  Exhausted(Int)
}

///|
priv enum McpStartupTransport {
  Uds(Int)
  Tcp(String)
  FailedUds(Int)
}

///|
fn mcp_should_reconnect_after_uds_loop(exit : McpUdsLoopExit) -> Bool {
  match exit {
    InputClosed => false
    Reconnect => true
  }
}

///|
fn mcp_startup_backoff_max_ms() -> Int {
  30000
}

///|
fn mcp_startup_backoff_ms(base_ms : Int, retry_index : Int) -> Int {
  let cap = mcp_startup_backoff_max_ms()
  let mut value = if base_ms > cap { cap } else { base_ms }
  let mut i = 0
  while i < retry_index && value < cap {
    if value > cap / 2 {
      value = cap
    } else {
      value = value * 2
    }
    i = i + 1
  }
  value
}

///|
fn mcp_startup_exhausted_message(path : String, attempts : Int) -> String {
  "error: failed to connect to UDS " +
  path +
  " after " +
  attempts.to_string() +
  " startup attempts"
}

///|
fn mcp_startup_transport(
  result : McpStartupConnectResult,
  listen_tcp : String?,
) -> McpStartupTransport {
  match result {
    Connected(fd) => Uds(fd)
    Exhausted(attempts) =>
      match listen_tcp {
        Some(addr) => Tcp(addr)
        None => FailedUds(attempts)
      }
  }
}

///|
fn mcp_connect_uds_startup(
  path : String,
  wait_tries : Int,
  max_attempts : Int,
  backoff_base_ms : Int,
  connect_uds? : (String) -> Int = fn(socket_path) {
    @uds.client_connect(socket_path)
  },
  wait_for_socket? : (String, Int) -> Bool = fn(socket_path, tries) {
    @sys.wait_for_socket(socket_path, tries)
  },
  sleep_ms? : (Int) -> Unit = fn(ms) { @sys.sleep_milliseconds(ms) },
) -> McpStartupConnectResult {
  // Default cold-start budget is about 93s: 3 outer attempts * 150
  // wait_for_socket tries * 200ms, plus 1s and 2s retry sleeps.
  let attempts = if max_attempts < 1 { 1 } else { max_attempts }
  let mut outer_attempt = 0
  while outer_attempt < attempts {
    let mut uds_fd = connect_uds(path)
    if uds_fd < 0 {
      if wait_for_socket(path, wait_tries) {
        uds_fd = connect_uds(path)
      }
    }
    if uds_fd >= 0 {
      return Connected(uds_fd)
    }
    outer_attempt = outer_attempt + 1
    if outer_attempt < attempts {
      sleep_ms(mcp_startup_backoff_ms(backoff_base_ms, outer_attempt - 1))
    }
  }
  Exhausted(attempts)
}

///|
fn mcp_conductor_tool_names() -> Array[String] {
  @mcp.conductor_tool_names()
}

///|
fn mcp_is_conductor(
  role : @types.Role,
  config : @types.Config,
  local_cfg : @types.LocalConfig,
) -> Bool {
  role == @types.Role::TL &&
  mcp_resolved_agent_id(role, config, local_cfg) == "root"
}

///|
fn mcp_conductor_allows(name : String) -> Bool {
  mcp_conductor_tool_names().contains(name)
}

///|
test "Conductor MCP surface admits Goal and Beads operations only" {
  assert_true(mcp_conductor_allows("goal_submit"))
  assert_true(mcp_conductor_allows("goal_status"))
  assert_true(mcp_conductor_allows("task_list"))
  assert_true(mcp_conductor_allows("task_create"))
  assert_false(mcp_conductor_allows("fork_wave"))
  assert_false(mcp_conductor_allows("spawn_worker"))
  assert_false(mcp_conductor_allows("file_pr"))
  assert_false(mcp_conductor_allows("goal_set"))
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
  let conductor = mcp_is_conductor(role, config, local_cfg)
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
          let response = if conductor {
            @mcp.tools_list_response_filtered(
              id,
              role,
              mcp_conductor_tool_names(),
            )
          } else {
            @mcp.tools_list_response(id, role)
          }
          write_output(mcp_response_wire(response, raw_stdio))
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
              if conductor && !mcp_conductor_allows(internal_req.name) {
                write_output(
                  mcp_response_wire(
                    @mcp.error_response(
                      id, @mcp.err_method_not_found, "tool is outside the Conductor surface",
                    ),
                    raw_stdio,
                  ),
                )
                continue
              }
              let wire_req = mcp_build_wire_request(
                internal_req, role, config, local_cfg,
              )
              if !send_wire_request(wire_req) {
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
/// Performs the optional registration handshake at the top of
/// `mcp_run_uds_loop`. Extracted so the call-site contract — "do NOT
/// write a registration frame when `mcp_should_register_connection`
/// returns false" — is testable without a live UDS. Returns
/// `Some(Reconnect)` on write or response failure (caller aborts the
/// loop); returns `None` both when registration was skipped and when it
/// completed cleanly. The bound test
/// `mcp_perform_registration_handshake skips writer for no-identity TL`
/// guards choir-tl-id-leak: any refactor that decouples the write from
/// the predicate has to either preserve this skip or break the test.
fn mcp_perform_registration_handshake(
  role : @types.Role,
  config : @types.Config,
  local_cfg : @types.LocalConfig,
  write : (Bytes) -> Bool,
  read : () -> String,
) -> McpUdsLoopExit? {
  if !mcp_should_register_connection(role, config, local_cfg) {
    return None
  }
  let reg_msg = mcp_build_registration_message(role, config, local_cfg)
  if !write(@utf8.encode(reg_msg)) {
    return Some(Reconnect)
  }
  if read() == "" {
    return Some(Reconnect)
  }
  None
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
  match
    mcp_perform_registration_handshake(
      role,
      config,
      local_cfg,
      fn(bytes) { mcp_write_all_uds(uds_fd, bytes) },
      fn() { reader.read_line() },
    ) {
    Some(exit) => return exit
    None => ()
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
  if !@sys.ignore_sigpipe() {
    @moontrace.trace("failed to ignore SIGPIPE", fields=[])
  }
  if !@sys.set_parent_death_signal_term() {
    @moontrace.trace("failed to set parent death signal", fields=[])
  }
  let args = @env.args()
  match mcp_cli_stderr_append_log(args) {
    Some(path) => ignore(@sys.redirect_stderr_append(path))
    None => ()
  }
  let wait_tries = mcp_cli_wait_socket_tries(args)
  let config_content = @sys.read_file(".choir/config.toml")
  let local_content = @sys.read_file(".choir/config.local.toml")
  let base_config = match
    @config.parse_config(config_content, local_content=Some(local_content)) {
    Ok(cfg) => cfg
    Err(_) => {
      println("error: failed to parse .choir/config.toml")
      @sys.exit(1)
      @types.Config::default()
    }
  }

  let local_cfg = mcp_local_cfg_with_agent_metadata_fallback(
    match @config.parse_local_config(local_content) {
      Ok(cfg) => cfg
      Err(_) => @types.LocalConfig::default()
    },
    args,
  )
  let config = mcp_config_with_cli_overrides(base_config, local_cfg, args)
  let raw_stdio = mcp_cli_raw_stdio(args)
  let max_startup_attempts = mcp_cli_startup_attempts(args)
  let startup_backoff_base_ms = mcp_cli_startup_backoff_base_ms(args)
  let role = match mcp_cli_override_role(args) {
    Some(role) => role
    None => @config.resolve_role(local_cfg.role, config)
  }

  let startup_transport = mcp_startup_transport(
    mcp_connect_uds_startup(
      config.listen_uds,
      wait_tries,
      max_startup_attempts,
      startup_backoff_base_ms,
    ),
    config.listen_tcp,
  )
  match startup_transport {
    Uds(fd) => {
      let mut uds_fd = fd
      // Run loop; on server restart, wait and reconnect automatically
      for ;; {
        let exit_reason = mcp_run_uds_loop(
          uds_fd, raw_stdio, role, config, local_cfg,
        )
        @uds.close(uds_fd)
        if !mcp_should_reconnect_after_uds_loop(exit_reason) {
          break
        }
        if !@sys.wait_for_socket(config.listen_uds, wait_tries) {
          break
        }
        uds_fd = @uds.client_connect(config.listen_uds)
        if uds_fd < 0 {
          break
        }
      }
      return
    }
    FailedUds(attempts) => {
      @sys.write_stderr(
        mcp_startup_exhausted_message(config.listen_uds, attempts) + "\n",
      )
      @sys.exit(1)
      return
    }
    Tcp(addr_str) =>
      @async.run_async_main(async fn() {
        @async.with_task_group(async fn(_root) {
          let conductor = mcp_is_conductor(role, config, local_cfg)
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
              mcp_read_next_message(fn() { @sys.read_stdin_line(8192) }, fn(
                size,
              ) {
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
                  let resp = if conductor {
                    @mcp.tools_list_response_filtered(
                      id,
                      role,
                      mcp_conductor_tool_names(),
                    )
                  } else {
                    @mcp.tools_list_response(id, role)
                  }
                  @sys.write_stdout(mcp_response_wire(resp, raw_stdio))
                } else {
                  match @mcp.to_internal_request(rpc, role) {
                    Ok(internal_req) => {
                      if conductor && !mcp_conductor_allows(internal_req.name) {
                        @sys.write_stdout(
                          mcp_response_wire(
                            @mcp.error_response(
                              id, @mcp.err_method_not_found, "tool is outside the Conductor surface",
                            ),
                            raw_stdio,
                          ),
                        )
                        continue
                      }
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
                          @sys.write_stdout(
                            mcp_response_wire(err_resp, raw_stdio),
                          )
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
}

///|
test "mcp UDS reconnect policy stops after stdin EOF" {
  assert_false(mcp_should_reconnect_after_uds_loop(InputClosed))
  assert_true(mcp_should_reconnect_after_uds_loop(Reconnect))
}

///|
test "mcp startup CLI defaults and overrides are bounded" {
  assert_eq(mcp_cli_wait_socket_tries(["choir", "mcp-stdio"]), 150)
  assert_eq(mcp_cli_startup_attempts(["choir", "mcp-stdio"]), 3)
  assert_eq(mcp_cli_startup_backoff_base_ms(["choir", "mcp-stdio"]), 1000)
  assert_eq(
    mcp_cli_wait_socket_tries(["choir", "mcp-stdio", "--wait-socket-tries", "9"]),
    9,
  )
  assert_eq(
    mcp_cli_startup_attempts([
      "choir", "mcp-stdio", "--mcp-startup-attempts", "4",
    ]),
    4,
  )
  assert_eq(
    mcp_cli_startup_backoff_base_ms([
      "choir", "mcp-stdio", "--mcp-startup-backoff-base-ms", "250",
    ]),
    250,
  )
}

///|
test "mcp startup retries UDS connect until success" {
  let sleeps : Array[Int] = []
  let waits : Array[String] = []
  let connect_paths : Array[String] = []
  let mut connect_calls = 0
  let result = mcp_connect_uds_startup(
    ".choir/run/server.sock",
    150,
    3,
    1000,
    connect_uds=fn(path) {
      connect_paths.push(path)
      connect_calls = connect_calls + 1
      if connect_calls < 3 {
        -1
      } else {
        42
      }
    },
    wait_for_socket=fn(path, tries) {
      waits.push(path + ":" + tries.to_string())
      false
    },
    sleep_ms=fn(ms) { sleeps.push(ms) },
  )
  match result {
    Connected(fd) => assert_eq(fd, 42)
    Exhausted(_) => fail("expected startup connect to succeed")
  }
  assert_eq(connect_calls, 3)
  @debug.assert_eq(connect_paths, [
    ".choir/run/server.sock", ".choir/run/server.sock", ".choir/run/server.sock",
  ])
  @debug.assert_eq(waits, [
    ".choir/run/server.sock:150", ".choir/run/server.sock:150",
  ])
  @debug.assert_eq(sleeps, [1000, 2000])
  match mcp_startup_transport(result, None) {
    Uds(fd) => assert_eq(fd, 42)
    Tcp(_) => fail("expected UDS transport")
    FailedUds(_) => fail("expected UDS transport")
  }
}

///|
test "wait_for_socket_returns_success_mid_attempt_breaks_outer_retry" {
  let sleeps : Array[Int] = []
  let waits : Array[String] = []
  let connect_paths : Array[String] = []
  let mut connect_calls = 0
  let result = mcp_connect_uds_startup(
    ".choir/run/server.sock",
    150,
    3,
    1000,
    connect_uds=fn(path) {
      connect_paths.push(path)
      connect_calls = connect_calls + 1
      if connect_calls == 1 {
        -1
      } else {
        42
      }
    },
    wait_for_socket=fn(path, tries) {
      waits.push(path + ":" + tries.to_string())
      true
    },
    sleep_ms=fn(ms) { sleeps.push(ms) },
  )
  match result {
    Connected(fd) => assert_eq(fd, 42)
    Exhausted(_) =>
      fail("expected startup connect to succeed after socket wait")
  }
  assert_eq(connect_calls, 2)
  @debug.assert_eq(connect_paths, [
    ".choir/run/server.sock", ".choir/run/server.sock",
  ])
  @debug.assert_eq(waits, [".choir/run/server.sock:150"])
  @debug.assert_eq(sleeps, [])
  match mcp_startup_transport(result, None) {
    Uds(fd) => assert_eq(fd, 42)
    Tcp(_) => fail("expected UDS transport")
    FailedUds(_) => fail("expected UDS transport")
  }
}

///|
test "mcp startup exits after exhausting UDS attempts with no TCP fallback" {
  let sleeps : Array[Int] = []
  let mut connect_calls = 0
  let mut wait_calls = 0
  let result = mcp_connect_uds_startup(
    ".choir/run/server.sock",
    150,
    3,
    250,
    connect_uds=fn(_) {
      connect_calls = connect_calls + 1
      -1
    },
    wait_for_socket=fn(_, _) {
      wait_calls = wait_calls + 1
      false
    },
    sleep_ms=fn(ms) { sleeps.push(ms) },
  )
  match result {
    Connected(_) => fail("expected startup connect to exhaust attempts")
    Exhausted(attempts) => {
      assert_eq(attempts, 3)
      let message = mcp_startup_exhausted_message(
        ".choir/run/server.sock", attempts,
      )
      assert_true(message.contains("failed to connect to UDS"))
      assert_true(message.contains(".choir/run/server.sock"))
      assert_true(message.contains("3 startup attempts"))
    }
  }
  assert_eq(connect_calls, 3)
  assert_eq(wait_calls, 3)
  @debug.assert_eq(sleeps, [250, 500])
  match mcp_startup_transport(result, None) {
    Uds(_) => fail("expected startup failure")
    Tcp(_) => fail("expected startup failure without listen_tcp")
    FailedUds(attempts) => assert_eq(attempts, 3)
  }
  match mcp_startup_transport(result, Some("127.0.0.1:7777")) {
    Uds(_) => fail("expected TCP fallback")
    Tcp(addr) => assert_eq(addr, "127.0.0.1:7777")
    FailedUds(_) => fail("expected TCP fallback when listen_tcp is configured")
  }
}

///|
test "mcp startup backoff caps per-attempt sleeps" {
  assert_eq(mcp_startup_backoff_ms(1000, 0), 1000)
  assert_eq(mcp_startup_backoff_ms(1000, 1), 2000)
  assert_eq(mcp_startup_backoff_ms(20000, 1), 30000)
  assert_eq(mcp_startup_backoff_ms(60000, 0), 30000)
}

///|
test "mcp config applies CLI agent id when local config is unset" {
  let cfg = mcp_config_with_cli_overrides(
    @types.Config::default(),
    @types.LocalConfig::default(),
    ["choir", "mcp-stdio", "--name", "smoke-test"],
  )
  @debug.assert_eq(cfg.agent_id, Some("smoke-test"))
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
  @debug.assert_eq(cfg.agent_id, Some("local-agent"))
  assert_eq(
    mcp_resolved_agent_id(@types.Role::TL, cfg, local_cfg),
    "local-agent",
  )
}

///|
test "mcp no-identity TL uses root caller and skips registration" {
  let cfg = @types.Config::default()
  let local_cfg = @types.LocalConfig::default()
  assert_eq(mcp_resolved_agent_id(@types.Role::TL, cfg, local_cfg), "root")
  assert_false(mcp_should_register_connection(@types.Role::TL, cfg, local_cfg))
}

///|
test "mcp_perform_registration_handshake skips writer for no-identity TL" {
  // Pins the call-site contract that ties choir-tl-id-leak's fix to its
  // call site: with no agent_id/parent/workspace set, the supervisor-
  // shaped MCP stdio bridge must NOT send a registration frame, full
  // stop. Any refactor that decouples the predicate from the write
  // (inline, fuse with adjacent branch, etc.) breaks this test.
  let cfg = @types.Config::default()
  let local_cfg = @types.LocalConfig::default()
  let writes : Array[Bytes] = []
  let mut reads = 0
  let result = mcp_perform_registration_handshake(
    @types.Role::TL,
    cfg,
    local_cfg,
    fn(bytes) {
      writes.push(bytes)
      true
    },
    fn() {
      reads = reads + 1
      ""
    },
  )
  guard result is None else { fail("expected continue, got Some(_)") }
  assert_eq(writes.length(), 0)
  assert_eq(reads, 0)
}

///|
test "mcp_perform_registration_handshake writes register frame for identified root TL" {
  // Mirror of the no-identity case: with an agent_id set, the handshake
  // must write exactly one registration frame and consume exactly one
  // response line.
  let cfg = { ..@types.Config::default(), agent_id: Some("root") }
  let local_cfg = @types.LocalConfig::default()
  let writes : Array[Bytes] = []
  let mut reads = 0
  let result = mcp_perform_registration_handshake(
    @types.Role::TL,
    cfg,
    local_cfg,
    fn(bytes) {
      writes.push(bytes)
      true
    },
    fn() {
      reads = reads + 1
      // Non-empty response keeps the handshake successful.
      "{}\n"
    },
  )
  guard result is None else { fail("expected continue, got Some(_)") }
  assert_eq(writes.length(), 1)
  assert_eq(reads, 1)
}

///|
test "mcp_perform_registration_handshake returns Reconnect when write fails" {
  let cfg = { ..@types.Config::default(), agent_id: Some("root") }
  let local_cfg = @types.LocalConfig::default()
  let result = mcp_perform_registration_handshake(
    @types.Role::TL,
    cfg,
    local_cfg,
    fn(_bytes) { false },
    fn() { "" },
  )
  guard result is Some(McpUdsLoopExit::Reconnect) else {
    fail("expected Some(Reconnect)")
  }
}

///|
test "mcp_perform_registration_handshake returns Reconnect when read is empty" {
  // Symmetric to the write-failure case: write succeeds but the server
  // disconnects before sending a response line. The handshake must
  // surface Reconnect rather than fall through into the request loop.
  let cfg = { ..@types.Config::default(), agent_id: Some("root") }
  let local_cfg = @types.LocalConfig::default()
  let writes : Array[Bytes] = []
  let mut reads = 0
  let result = mcp_perform_registration_handshake(
    @types.Role::TL,
    cfg,
    local_cfg,
    fn(bytes) {
      writes.push(bytes)
      true
    },
    fn() {
      reads = reads + 1
      ""
    },
  )
  guard result is Some(McpUdsLoopExit::Reconnect) else {
    fail("expected Some(Reconnect)")
  }
  assert_eq(writes.length(), 1)
  assert_eq(reads, 1)
}

///|
test "mcp named TL keeps stable registration path" {
  let cfg = { ..@types.Config::default(), agent_id: Some("user-123-456") }
  let local_cfg = @types.LocalConfig::default()
  assert_eq(
    mcp_resolved_agent_id(@types.Role::TL, cfg, local_cfg),
    "user-123-456",
  )
  assert_true(mcp_should_register_connection(@types.Role::TL, cfg, local_cfg))
}

///|
test "mcp local cfg falls back to inline worker metadata when env is stripped" {
  let metadata =
    #|role = "worker"
    #|agent_id = "master.sarcasmotron-claim-schema"
    #|parent_id = "master.tl"
    #|branch = "master.sarcasmotron-claim-schema"
    #|parent_branch = "master"
    #|workspace = "/repo"
    #|agent_type = "codex"
    #|
  let mut requested_path = ""
  let cfg = mcp_local_cfg_with_agent_metadata_fallback(
    @types.LocalConfig::default(),
    ["choir", "mcp-stdio", "--name", "master.sarcasmotron-claim-schema"],
    env_get=fn(_) { None },
    read_file=fn(path) {
      requested_path = path
      metadata
    },
  )
  assert_eq(
    requested_path, ".choir/state/inline/master.sarcasmotron-claim-schema/.choir/config.local.toml",
  )
  @debug.assert_eq(cfg.role, Some(@types.Role::Worker))
  @debug.assert_eq(cfg.agent_id, Some("master.sarcasmotron-claim-schema"))
  @debug.assert_eq(cfg.parent_id, Some("master.tl"))
  @debug.assert_eq(cfg.parent_branch, Some("master"))
  @debug.assert_eq(cfg.agent_type, Some(@types.AgentType::Codex))
}

///|
test "mcp local cfg prefers inline metadata over parent's cwd config for child --name" {
  // Inline worker layout: cwd `.choir/config.local.toml` is the parent TL's
  // file (no parent_id). The worker's own metadata at
  // `.choir/state/inline/<sanitized>/.choir/config.local.toml` carries `parent_id`.
  // Without the inline lookup the worker would register with `parent: None`,
  // which breaks notify_parent.
  let parent_cwd_cfg = {
    ..@types.LocalConfig::default(),
    role: Some(@types.Role::TL),
    agent_id: Some("root"),
    workspace: Some("/repo"),
  }
  let worker_metadata =
    #|role = "worker"
    #|agent_id = "master.sarcasmotron-agenda-signals"
    #|parent_id = "root"
    #|branch = "master.sarcasmotron-agenda-signals"
    #|parent_branch = "master"
    #|workspace = "/repo"
    #|agent_type = "claude"
    #|
  let cfg = mcp_local_cfg_with_agent_metadata_fallback(
    parent_cwd_cfg,
    ["choir", "mcp-stdio", "--name", "master.sarcasmotron-agenda-signals"],
    env_get=fn(_) { None },
    read_file=fn(_) { worker_metadata },
  )
  @debug.assert_eq(cfg.role, Some(@types.Role::Worker))
  @debug.assert_eq(cfg.agent_id, Some("master.sarcasmotron-agenda-signals"))
  @debug.assert_eq(cfg.parent_id, Some("root"))
}

///|
test "mcp local cfg keeps cwd config for root TL (no inline lookup)" {
  // `--name root` (no dot) must not trigger the inline-metadata path; the TL
  // writes its own `.choir/config.local.toml` in cwd and that is authoritative.
  let mut read_calls = 0
  let tl_cfg = {
    ..@types.LocalConfig::default(),
    role: Some(@types.Role::TL),
    agent_id: Some("root"),
  }
  let cfg = mcp_local_cfg_with_agent_metadata_fallback(
    tl_cfg,
    ["choir", "mcp-stdio", "--name", "root"],
    env_get=fn(_) { None },
    read_file=fn(_) {
      read_calls = read_calls + 1
      ""
    },
  )
  assert_eq(read_calls, 0)
  @debug.assert_eq(cfg.agent_id, Some("root"))
  @debug.assert_eq(cfg.role, Some(@types.Role::TL))
}

///|
test "mcp registration can mark one-shot helper connections" {
  let output = mcp_build_registration_message(
    @types.Role::Dev,
    @types.Config::default(),
    @types.LocalConfig::{
      ..@types.LocalConfig::default(),
      agent_id: Some("main.leaf"),
    },
    connection_lifetime=@transport.ConnectionLifetime::OneShot,
  )
  assert_true(output.contains("\"connection_lifetime\":\"oneshot\""))
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
