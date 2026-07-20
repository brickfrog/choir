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
  peer_is_choir : Bool
  mut buf : FixedArray[Byte]
  mut read_pos : Int
  mut connected_agent_id : String?
  // Verified identity bound on any successful register (Session OR OneShot),
  // used to authenticate this connection's subsequent requests. Separate from
  // connected_agent_id, which is Session-only for disconnect tracking.
  mut authenticated_agent_id : String?
  // Set on `register`; tracked so a disconnect log line names *which* agent
  // dropped, what it last asked for, and how long it was connected — the
  // contentless "UDS client disconnected written=N" told us nothing when the
  // TL claude process died. See choir-u7v.
  connected_at_sec : Int64
  mut last_request_name : String?
  mut busy : Bool
  mut close_after_response : Bool
}

///|
fn ServeUDSClient::new(fd : Int) -> ServeUDSClient {
  {
    fd,
    peer_is_choir: serve_peer_is_choir_client(fd),
    buf: FixedArray::make(4096, (0 : Byte)),
    read_pos: 0,
    connected_agent_id: None,
    authenticated_agent_id: None,
    connected_at_sec: @poller.now_sec(),
    last_request_name: None,
    busy: false,
    close_after_response: false,
  }
}

///|
fn serve_peer_is_choir_client(fd : Int) -> Bool {
  if fd < 0 || !@uds.peer_is_current_user(fd) {
    return false
  }
  let pid = @uds.peer_pid(fd)
  if pid <= 1 {
    return false
  }
  match
    (
      @sys.realpath_native("/proc/" + pid.to_string() + "/exe"),
      @sys.realpath_native("/proc/self/exe"),
    ) {
    (Some(peer_executable), Some(server_executable)) =>
      peer_executable == server_executable
    _ => false
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
  req : @types.Request,
) -> Result[String, @types.ChoirError] {
  match req.args.get("binary_path") {
    Some(path) => Ok(path)
    None => @exec.reload_binary_path()
  }
}

///|
fn serve_replace_self_after_reload_ack(
  state : @server.ServerState,
  server_fd : Int,
  req : @types.Request,
) -> Unit {
  if !@uds.clear_cloexec(server_fd) {
    @moontrace.error("server reload failed to clear FD_CLOEXEC", fields=[
      @moontrace.field("fd", server_fd),
    ])
    return
  }
  let binary_path = match serve_reload_binary_path_for_request(req) {
    Ok(path) => path
    Err(e) => {
      @moontrace.error("server reload binary path resolution failed", fields=[
        @moontrace.field("error", e.message()),
      ])
      @sys.write_stderr("[server_reload] exec failed: " + e.message() + "\n")
      return
    }
  }
  if !serve_prepare_reload_credentials_env(state) {
    @moontrace.error("server reload failed to prepare credential environment", fields=[])
    @sys.write_stderr(
      "[server_reload] exec failed: failed to prepare credential environment\n",
    )
    return
  }
  match @exec.replace_self(binary_path, server_fd) {
    Ok(_) => ()
    Err(e) => {
      ignore(serve_clear_reload_credentials_env())
      @moontrace.error("server reload exec failed", fields=[
        @moontrace.field("binary_path", binary_path),
        @moontrace.field("error", e.message()),
      ])
      @sys.write_stderr("[server_reload] exec failed: " + e.message() + "\n")
    }
  }
}

///|
fn lifecycle_agent_id_for_register(
  req : @types.Request,
  authenticated_agent_id : String,
) -> String? {
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
  Some(authenticated_agent_id)
}

///|
fn register_connection_agent_id_after_response(
  req : @types.Request,
  resp : @types.Response,
  authenticated_agent_id : String?,
) -> String? {
  if req.req_method == "register" && resp.is_ok() {
    match authenticated_agent_id {
      Some(agent_id) => lifecycle_agent_id_for_register(req, agent_id)
      None => None
    }
  } else {
    None
  }
}

///|
priv enum ServeRegisterAuth {
  Authorized(@types.Request, String?)
  Rejected(@types.Response)
}

///|
fn serve_registration_auth_failed_response() -> @types.Response {
  @types.Response::Err("registration authentication failed")
}

///|
let serve_root_agent_id : String = "root"

///|
let serve_root_boot_token_env : String = "CHOIR_ROOT_AGENT_TOKEN"

///|
let serve_reload_credentials_env : String = "CHOIR_RELOAD_CREDENTIALS"

///|
let serve_root_bootstrap_method : String = "root_bootstrap"

///|
fn serve_root_credential_not_provisioned_response() -> @types.Response {
  @types.Response::Err(
    "Conductor credential not provisioned; run `choir start` to open an authenticated Conductor",
  )
}

///|
fn serve_record_boot_root_credential(
  state : @server.ServerState,
  token : String,
) -> Unit {
  if token != "" {
    state.registry.record_spawn_credential(serve_root_agent_id, {
      role: @types.Role::TL,
      token,
    })
  }
}

///|
fn serve_boot_root_token_from_env(
  getenv? : (String) -> String? = fn(key) { @sys.getenv(key) },
) -> String? {
  match getenv(serve_root_boot_token_env) {
    Some(token) => if token == "" { None } else { Some(token) }
    None => None
  }
}

///|
fn serve_prepare_reload_credentials_env(
  state : @server.ServerState,
  setenv? : (String, String) -> Bool = @sys.setenv,
  unsetenv? : (String) -> Bool = @sys.unsetenv,
) -> Bool {
  let payload = state.registry.to_reload_credentials_env_string()
  if payload == "" {
    unsetenv(serve_reload_credentials_env)
  } else {
    setenv(serve_reload_credentials_env, payload)
  }
}

///|
fn serve_clear_reload_credentials_env(
  unsetenv? : (String) -> Bool = @sys.unsetenv,
) -> Bool {
  unsetenv(serve_reload_credentials_env)
}

///|
fn serve_restore_reload_credentials_from_env(
  state : @server.ServerState,
  getenv? : (String) -> String? = fn(key) { @sys.getenv(key) },
  unsetenv? : (String) -> Bool = @sys.unsetenv,
) -> Int {
  let restored = match getenv(serve_reload_credentials_env) {
    Some(payload) =>
      if payload == "" {
        0
      } else {
        match state.registry.restore_reload_credentials_env_string(payload) {
          Ok(count) => count
          Err(_) => 0
        }
      }
    None => 0
  }
  ignore(unsetenv(serve_reload_credentials_env))
  restored
}

///|
fn serve_constant_timeish_string_equal(
  presented : String,
  stored : String,
) -> Bool {
  let presented_len = presented.length()
  let stored_len = stored.length()
  let mut diff = if presented_len == stored_len { 0 } else { 1 }
  for i = 0; i < stored_len; i = i + 1 {
    let presented_unit = if i < presented_len {
      presented.code_unit_at(i)
    } else {
      0
    }
    if presented_unit != stored.code_unit_at(i) {
      diff = 1
    }
  }
  diff == 0
}

///|
fn serve_valid_root_bootstrap_token(token : String) -> Bool {
  if token.length() != 64 {
    return false
  }
  for i = 0; i < token.length(); i = i + 1 {
    let unit = token.code_unit_at(i)
    if !((unit >= 48 && unit <= 57) || (unit >= 97 && unit <= 102)) {
      return false
    }
  }
  true
}

///|
fn serve_handle_root_bootstrap(
  state : @server.ServerState,
  req : @types.Request,
  peer_is_choir : Bool,
) -> @types.Response {
  if req.req_method != serve_root_bootstrap_method ||
    req.name != serve_root_bootstrap_method ||
    req.role != @types.Role::TL ||
    !peer_is_choir {
    return @types.Response::Err("root bootstrap authentication failed")
  }
  let token = match req.args.get(@types.registration_token_arg) {
    Some(value) => value
    None => return @types.Response::Err("root bootstrap authentication failed")
  }
  if !serve_valid_root_bootstrap_token(token) {
    return @types.Response::Err("root bootstrap authentication failed")
  }
  state.registry.record_spawn_credential(serve_root_agent_id, {
    role: @types.Role::TL,
    token,
  })
  @types.Response::ok_values({ "agent_id": serve_root_agent_id.to_json() })
}

///|
fn serve_authenticate_register_request(
  state : @server.ServerState,
  req : @types.Request,
) -> ServeRegisterAuth {
  if req.req_method != "register" {
    return ServeRegisterAuth::Authorized(req, None)
  }
  let claimed_agent_id = match req.args.get("agent_id") {
    Some(v) =>
      if v == "" {
        return ServeRegisterAuth::Rejected(
          serve_registration_auth_failed_response(),
        )
      } else {
        v
      }
    None =>
      return ServeRegisterAuth::Rejected(
        serve_registration_auth_failed_response(),
      )
  }
  let presented_token = match req.registration_token() {
    Some(v) => v
    None =>
      return ServeRegisterAuth::Rejected(
        serve_registration_auth_failed_response(),
      )
  }
  if presented_token == "" {
    return ServeRegisterAuth::Rejected(
      serve_registration_auth_failed_response(),
    )
  }
  if claimed_agent_id == serve_root_agent_id &&
    state.registry.credential_for_agent(serve_root_agent_id) is None {
    return ServeRegisterAuth::Rejected(
      serve_root_credential_not_provisioned_response(),
    )
  }
  let credential = match state.registry.credential_for_agent(claimed_agent_id) {
    Some(value) => value
    None =>
      return ServeRegisterAuth::Rejected(
        serve_registration_auth_failed_response(),
      )
  }
  if credential.token == "" ||
    !serve_constant_timeish_string_equal(presented_token, credential.token) {
    return ServeRegisterAuth::Rejected(
      serve_registration_auth_failed_response(),
    )
  }
  let effective_req = { ..req, role: credential.role }
  // Return the UNFILTERED authenticated id. Each downstream consumer applies
  // its own policy: register_connection_agent_id_after_response drops OneShot
  // for the lifecycle/disconnect binding, while register_auth_agent_id_after_
  // response keeps it so the one-shot follow-up call authenticates.
  ServeRegisterAuth::Authorized(effective_req, Some(claimed_agent_id))
}

///|
struct ServeRequestLineResult {
  response_line : String?
  request_name : String?
  saw_register : Bool
  // Lifecycle/disconnect binding: only Session registers set this (a OneShot
  // register leaves it None) so transient one-shot calls do not schedule a
  // spurious disconnect for the agent.
  connected_agent_id : String?
  // Authentication binding: set on ANY successful register (Session OR OneShot)
  // so the agent's follow-up request on the same connection (the tool CLI
  // registers + calls on one OneShot socket) is verified as that agent rather
  // than downgraded to an unauthenticated Worker. Distinct from
  // connected_agent_id, which exists for disconnect tracking only.
  auth_agent_id : String?
  drop_connection : Bool
  reload_request : @types.Request?
}

///|
fn connected_agent_id_after_request(
  current : String?,
  result : ServeRequestLineResult,
) -> String? {
  if result.saw_register {
    match result.connected_agent_id {
      Some(agent_id) => Some(agent_id)
      None => current
    }
  } else {
    current
  }
}

///|
fn authenticated_agent_id_after_request(
  current : String?,
  result : ServeRequestLineResult,
) -> String? {
  match result.auth_agent_id {
    Some(agent_id) => Some(agent_id)
    None => current
  }
}

///|
fn register_auth_agent_id_after_response(
  req : @types.Request,
  resp : @types.Response,
  authenticated_agent_id : String?,
) -> String? {
  // The authenticated identity binds for ANY successful register regardless of
  // connection_lifetime; unlike register_connection_agent_id_after_response it
  // does NOT drop OneShot, because the auth binding must cover the one-shot
  // call that follows the register on the same socket.
  if req.req_method == "register" && resp.is_ok() {
    authenticated_agent_id
  } else {
    None
  }
}

///|
async fn serve_handle_internal_request(
  state : @server.ServerState,
  req : @types.Request,
  conductor_dispatch : async (String, @types.Request) -> @types.Response,
  authenticated_agent_id? : String? = None,
) -> @types.Response {
  if req.req_method == "register" {
    return state.handle(req, authenticated_agent_id~) catch {
      e => {
        @moontrace.error("handler error", fields=[
          @moontrace.field("request", req.name),
          @moontrace.field("error", e.to_string()),
        ])
        @types.Response::Err("internal error: " + e.to_string())
      }
    }
  }
  if authenticated_agent_id != Some(serve_root_agent_id) {
    return @types.Response::Err("authenticated Conductor required")
  }
  let args : Map[String, Json] = Map([])
  req.args.each_json(fn(name, value) {
    if name != "caller_id" && name != "agent_id" && name != "sender_id" {
      args.set(name, value)
    }
  })
  args.set("caller_id", serve_root_agent_id.to_json())
  let effective_req : @types.Request = {
    ..req,
    req_method: "tools/call",
    role: @types.Role::TL,
    args: @types.RequestArgs::from_values(args),
  }
  conductor_dispatch(state.config.project_dir, effective_req) catch {
    e => {
      @moontrace.error("Conductor adapter error", fields=[
        @moontrace.field("request", req.name),
        @moontrace.field("error", e.to_string()),
      ])
      @types.Response::Err("internal error: " + e.to_string())
    }
  }
}

///|
fn serve_custom_unauthenticated_request(req : @types.Request) -> @types.Request {
  let args : Map[String, Json] = {}
  req.args.each_json(fn(k, v) {
    // Strip every identity/provenance-shaped field from an unbound request so a
    // downgraded Worker cannot forge a caller (caller_id/agent_id) or a message
    // sender (sender_id).
    if k != "caller_id" && k != "agent_id" && k != "sender_id" {
      args.set(k, v)
    }
  })
  {
    ..req,
    role: @types.Role::Worker,
    args: @types.RequestArgs::from_values(args),
  }
}

///|
fn serve_custom_request_for_connection(
  req : @types.Request,
  authenticated_agent_id : String?,
) -> @types.Request {
  if req.req_method == "register" {
    req
  } else {
    match authenticated_agent_id {
      Some(_) => req
      None => serve_custom_unauthenticated_request(req)
    }
  }
}

///|
fn serve_jsonrpc_response_line(resp : @mcp.JsonRpcResponse) -> String {
  resp.to_json_string() + "\n"
}

///|
fn serve_jsonrpc_role_for_connection(
  state : @server.ServerState,
  authenticated_agent_id : String?,
) -> @types.Role {
  match authenticated_agent_id {
    Some(agent_id) =>
      match state.registry.get_opt(agent_id) {
        Some(agent) => agent.role
        None => @types.Role::Worker
      }
    None => @types.Role::Worker
  }
}

///|
fn serve_jsonrpc_request_for_connection(
  req : @types.Request,
  authenticated_agent_id : String?,
) -> @types.Request {
  match authenticated_agent_id {
    Some(_) => req
    None => serve_custom_unauthenticated_request(req)
  }
}

///|
async fn serve_handle_jsonrpc_request_line(
  state : @server.ServerState,
  line : String,
  allow_reload : Bool,
  conductor_dispatch : async (String, @types.Request) -> @types.Response,
  authenticated_agent_id? : String? = None,
) -> ServeRequestLineResult {
  match @mcp.parse_jsonrpc_request(line) {
    Ok(rpc) => {
      let id = match rpc.id {
        Some(id) => id
        None =>
          return {
            response_line: None,
            request_name: Some(rpc.req_method),
            saw_register: false,
            connected_agent_id: None,
            auth_agent_id: None,
            drop_connection: false,
            reload_request: None,
          }
      }
      let effective_role = serve_jsonrpc_role_for_connection(
        state, authenticated_agent_id,
      )
      if rpc.req_method == @mcp.method_initialize {
        return {
          response_line: Some(
            serve_jsonrpc_response_line(@mcp.initialize_response(id)),
          ),
          request_name: Some(rpc.req_method),
          saw_register: false,
          connected_agent_id: None,
          auth_agent_id: None,
          drop_connection: false,
          reload_request: None,
        }
      }
      if rpc.req_method == @mcp.method_tools_list {
        return {
          response_line: Some(
            serve_jsonrpc_response_line(
              @mcp.tools_list_response(id, effective_role),
            ),
          ),
          request_name: Some(rpc.req_method),
          saw_register: false,
          connected_agent_id: None,
          auth_agent_id: None,
          drop_connection: false,
          reload_request: None,
        }
      }
      match @mcp.to_internal_request(rpc, effective_role) {
        Ok(req) => {
          let effective_req = serve_jsonrpc_request_for_connection(
            req, authenticated_agent_id,
          )
          if !allow_reload && serve_is_reload_request(effective_req) {
            return {
              response_line: Some(
                serve_jsonrpc_response_line(
                  @mcp.from_internal_response(
                    id,
                    @types.Response::Err(
                      "server_reload requires the UDS transport",
                    ),
                  ),
                ),
              ),
              request_name: Some(effective_req.name),
              saw_register: false,
              connected_agent_id: None,
              auth_agent_id: None,
              drop_connection: false,
              reload_request: None,
            }
          }
          let resp = serve_handle_internal_request(
            state,
            effective_req,
            conductor_dispatch,
            authenticated_agent_id~,
          )
          {
            response_line: Some(
              serve_jsonrpc_response_line(@mcp.from_internal_response(id, resp)),
            ),
            request_name: Some(effective_req.name),
            saw_register: false,
            connected_agent_id: None,
            auth_agent_id: None,
            drop_connection: false,
            reload_request: if allow_reload &&
              serve_is_reload_request(effective_req) &&
              resp.is_ok() {
              Some(effective_req)
            } else {
              None
            },
          }
        }
        Err(e) =>
          {
            response_line: Some(
              serve_jsonrpc_response_line(
                @mcp.error_response(id, e.code, e.message),
              ),
            ),
            request_name: Some(rpc.req_method),
            saw_register: false,
            connected_agent_id: None,
            auth_agent_id: None,
            drop_connection: false,
            reload_request: None,
          }
      }
    }
    Err(e) => {
      @moontrace.warn("jsonrpc parse error", fields=[
        @moontrace.field("error", e.message),
      ])
      {
        response_line: Some(
          serve_jsonrpc_response_line(
            @mcp.error_response(Number(0), e.code, e.message),
          ),
        ),
        request_name: None,
        saw_register: false,
        connected_agent_id: None,
        auth_agent_id: None,
        drop_connection: false,
        reload_request: None,
      }
    }
  }
}

///|
async fn serve_handle_parsed_custom_request(
  state : @server.ServerState,
  req : @types.Request,
  allow_reload : Bool,
  conductor_dispatch : async (String, @types.Request) -> @types.Response,
  authenticated_agent_id? : String? = None,
) -> ServeRequestLineResult {
  let saw_register = req.req_method == "register"
  let effective_req = serve_custom_request_for_connection(
    req, authenticated_agent_id,
  )
  if !allow_reload && serve_is_reload_request(effective_req) {
    let resp = @types.Response::Err("server_reload requires the UDS transport")
    return {
      response_line: Some(@transport.format_response(resp) + "\n"),
      request_name: Some(effective_req.name),
      saw_register,
      connected_agent_id: None,
      auth_agent_id: None,
      drop_connection: false,
      reload_request: None,
    }
  }
  match serve_authenticate_register_request(state, effective_req) {
    ServeRegisterAuth::Rejected(resp) =>
      {
        response_line: Some(@transport.format_response(resp) + "\n"),
        request_name: Some(effective_req.name),
        saw_register,
        connected_agent_id: None,
        auth_agent_id: None,
        drop_connection: true,
        reload_request: None,
      }
    ServeRegisterAuth::Authorized(effective_req, registered_agent_id) => {
      let request_authenticated_agent_id = if saw_register {
        None
      } else {
        authenticated_agent_id
      }
      let resp = serve_handle_internal_request(
        state,
        effective_req,
        conductor_dispatch,
        authenticated_agent_id=request_authenticated_agent_id,
      )
      {
        response_line: Some(@transport.format_response(resp) + "\n"),
        request_name: Some(effective_req.name),
        saw_register,
        connected_agent_id: register_connection_agent_id_after_response(
          effective_req, resp, registered_agent_id,
        ),
        auth_agent_id: register_auth_agent_id_after_response(
          effective_req, resp, registered_agent_id,
        ),
        drop_connection: false,
        reload_request: if allow_reload &&
          serve_is_reload_request(effective_req) &&
          resp.is_ok() {
          Some(effective_req)
        } else {
          None
        },
      }
    }
  }
}

///|
async fn serve_handle_custom_request_line(
  state : @server.ServerState,
  line : String,
  allow_reload : Bool,
  conductor_dispatch : async (String, @types.Request) -> @types.Response,
  authenticated_agent_id? : String? = None,
) -> ServeRequestLineResult {
  match @transport.parse_request(line) {
    Ok(req) =>
      serve_handle_parsed_custom_request(
        state,
        req,
        allow_reload,
        conductor_dispatch,
        authenticated_agent_id~,
      )
    Err(err) => {
      @moontrace.warn("parse error", fields=[@moontrace.field("error", err)])
      let resp = @types.Response::Err("parse error: " + err)
      {
        response_line: Some(@transport.format_response(resp) + "\n"),
        request_name: None,
        saw_register: false,
        connected_agent_id: None,
        auth_agent_id: None,
        drop_connection: false,
        reload_request: None,
      }
    }
  }
}

///|
async fn serve_test_conductor_dispatch(
  _project_dir : String,
  request : @types.Request,
) -> @types.Response {
  @types.Response::Err(
    "Goal is not registered: " +
    request.args.get("goal_id").unwrap_or("unknown"),
  )
}

///|
async fn serve_native_conductor_dispatch(
  project_dir : String,
  request : @types.Request,
) -> @types.Response {
  @exec.dispatch_native_conductor_request(project_dir, request)
}

///|
async fn serve_handle_request_line(
  state : @server.ServerState,
  line : String,
  allow_reload : Bool,
  conductor_dispatch? : async (String, @types.Request) -> @types.Response = serve_test_conductor_dispatch,
  authenticated_agent_id? : String? = None,
) -> ServeRequestLineResult {
  if @transport.is_jsonrpc_request(line) {
    serve_handle_jsonrpc_request_line(
      state,
      line,
      allow_reload,
      conductor_dispatch,
      authenticated_agent_id~,
    )
  } else {
    serve_handle_custom_request_line(
      state,
      line,
      allow_reload,
      conductor_dispatch,
      authenticated_agent_id~,
    )
  }
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
  @debug.assert_eq(lifecycle_agent_id_for_register(req, "main.leaf"), None)
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
  @debug.assert_eq(
    lifecycle_agent_id_for_register(req, "main.leaf"),
    Some("main.leaf"),
  )
}

///|
fn serve_test_project_dir(label : String) -> String {
  "/tmp/choir-uds-jsonrpc-" +
  label +
  "-" +
  @sys.get_pid().to_string() +
  "-" +
  @env.now().reinterpret_as_int64().to_string()
}

///|
fn serve_test_state_with_root(label : String) -> (@server.ServerState, String) {
  let project_dir = serve_test_project_dir(label)
  ignore(@sys.rm_rf(project_dir))
  ignore(@sys.create_dir_all(project_dir))
  let state = @server.ServerState::new(
    { ..@types.Config::default(), project_dir, terminal_session: "uds-jsonrpc" },
    @server.make_hermetic_recovery_provider(),
  )
  ignore(
    state.registry.upsert({
      agent_id: "root",
      role: @types.Role::TL,
      agent_type: @types.AgentType::Codex,
      parent: None,
      workspace: project_dir,
      branch: "main",
      terminal_target: @types.LocalTarget::parse(
        "zellij-pane:uds-jsonrpc:terminal_1",
      ),
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  state.list_panes_cache.set("uds-jsonrpc", {
    snapshot: @tools.empty_zellij_list_panes_snapshot(),
    expires_at_unix_ms: 9_999_999_999_999L,
  })
  (state, project_dir)
}

///|
fn serve_test_upsert_agent(
  state : @server.ServerState,
  agent_id : String,
  role : @types.Role,
  project_dir : String,
) -> Unit {
  ignore(
    state.registry.upsert({
      agent_id,
      role,
      agent_type: @types.AgentType::Codex,
      parent: Some("root"),
      workspace: project_dir,
      branch: agent_id,
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
}

///|
fn serve_test_record_credential(
  state : @server.ServerState,
  agent_id : String,
  role : @types.Role,
  token : String,
) -> Unit {
  state.registry.record_spawn_credential(agent_id, { role, token })
}

///|
fn serve_test_register_line(
  agent_id : String,
  wire_role : String,
  token : String,
  project_dir : String,
) -> String {
  "{\"method\":\"register\",\"role\":\"" +
  wire_role +
  "\",\"name\":\"register\",\"args\":{\"agent_id\":\"" +
  agent_id +
  "\",\"agent_type\":\"codex\",\"branch\":\"" +
  agent_id +
  "\",\"workspace\":\"" +
  project_dir +
  "\",\"token\":\"" +
  token +
  "\"}}"
}

///|
fn serve_assert_register_ok(
  state : @server.ServerState,
  result : ServeRequestLineResult,
  agent_id : String,
  expected_role : @types.Role,
) -> Unit raise {
  assert_true(result.saw_register)
  @debug.assert_eq(result.connected_agent_id, Some(agent_id))
  assert_false(result.drop_connection)
  match result.response_line {
    Some(resp_line) =>
      match @transport.parse_response(resp_line.trim().to_owned()) {
        Ok(resp) => assert_true(resp.is_ok())
        Err(e) => fail("expected parseable response: " + e)
      }
    None => fail("expected register response")
  }
  assert_eq(state.registry.get(agent_id).role, expected_role)
}

///|
fn serve_assert_register_rejected(
  result : ServeRequestLineResult,
  secret : String,
) -> Unit raise {
  assert_true(result.saw_register)
  @debug.assert_eq(result.connected_agent_id, None)
  assert_true(result.drop_connection)
  match result.response_line {
    Some(resp_line) => {
      assert_false(resp_line.contains(secret))
      match @transport.parse_response(resp_line.trim().to_owned()) {
        Ok(resp) => {
          assert_false(resp.is_ok())
          match resp.error_message() {
            Some(msg) => assert_false(msg.contains(secret))
            None => fail("expected rejected register error")
          }
        }
        Err(e) => fail("expected parseable response: " + e)
      }
    }
    None => fail("expected rejected register response")
  }
}

///|
async fn serve_assert_register_token_validation_mode(
  label : String,
  allow_reload : Bool,
) -> Unit {
  let (state, project_dir) = serve_test_state_with_root(label)
  let ok_agent = "main." + label + ".ok"
  serve_test_upsert_agent(state, ok_agent, @types.Role::Worker, project_dir)
  serve_test_record_credential(
    state,
    ok_agent,
    @types.Role::Worker,
    "expected-token",
  )
  let ok_result = serve_handle_request_line(
    state,
    serve_test_register_line(ok_agent, "dev", "expected-token", project_dir),
    allow_reload,
  )
  serve_assert_register_ok(state, ok_result, ok_agent, @types.Role::Worker)

  let wrong_agent = "main." + label + ".wrong"
  serve_test_upsert_agent(state, wrong_agent, @types.Role::Dev, project_dir)
  serve_test_record_credential(
    state,
    wrong_agent,
    @types.Role::Dev,
    "right-token",
  )
  let wrong_result = serve_handle_request_line(
    state,
    serve_test_register_line(wrong_agent, "dev", "wrong-token", project_dir),
    allow_reload,
  )
  serve_assert_register_rejected(wrong_result, "wrong-token")
  @debug.assert_eq(state.registry.get(wrong_agent).role, @types.Role::Dev)

  let short_agent = "main." + label + ".short"
  serve_test_upsert_agent(state, short_agent, @types.Role::Dev, project_dir)
  serve_test_record_credential(
    state,
    short_agent,
    @types.Role::Dev,
    "short-token-stored",
  )
  let short_result = serve_handle_request_line(
    state,
    serve_test_register_line(short_agent, "dev", "short", project_dir),
    allow_reload,
  )
  serve_assert_register_rejected(short_result, "short")

  let long_agent = "main." + label + ".long"
  serve_test_upsert_agent(state, long_agent, @types.Role::Dev, project_dir)
  serve_test_record_credential(
    state,
    long_agent,
    @types.Role::Dev,
    "prefix-token",
  )
  let long_result = serve_handle_request_line(
    state,
    serve_test_register_line(
      long_agent, "dev", "prefix-token-extra", project_dir,
    ),
    allow_reload,
  )
  serve_assert_register_rejected(long_result, "prefix-token-extra")

  let empty_agent = "main." + label + ".empty"
  serve_test_upsert_agent(state, empty_agent, @types.Role::Dev, project_dir)
  serve_test_record_credential(
    state,
    empty_agent,
    @types.Role::Dev,
    "empty-token",
  )
  let empty_result = serve_handle_request_line(
    state,
    serve_test_register_line(empty_agent, "dev", "", project_dir),
    allow_reload,
  )
  serve_assert_register_rejected(empty_result, "empty-token")

  let absent_agent = "main." + label + ".absent"
  serve_test_upsert_agent(state, absent_agent, @types.Role::Dev, project_dir)
  let absent_result = serve_handle_request_line(
    state,
    serve_test_register_line(absent_agent, "dev", "orphan-token", project_dir),
    allow_reload,
  )
  serve_assert_register_rejected(absent_result, "orphan-token")
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "serve UDS register validates spawn credential token" {
  serve_assert_register_token_validation_mode("uds-token", true)
}

///|
async test "serve TCP register validates spawn credential token" {
  serve_assert_register_token_validation_mode("tcp-token", false)
}

///|
async test "serve root register without boot credential gives init recreate guidance without leaking token" {
  let (state, project_dir) = serve_test_state_with_root(
    "missing-root-credential",
  )
  let presented_secret = "missing-root-presented-token"
  let result = serve_handle_request_line(
    state,
    serve_test_register_line("root", "root", presented_secret, project_dir),
    true,
  )
  serve_assert_register_rejected(result, presented_secret)
  match result.response_line {
    Some(resp_line) =>
      match @transport.parse_response(resp_line.trim().to_owned()) {
        Ok(resp) =>
          match resp.error_message() {
            Some(msg) => {
              assert_true(msg.contains("Conductor credential not provisioned"))
              assert_true(msg.contains("choir start"))
              assert_false(msg.contains(presented_secret))
            }
            None => fail("expected root recovery error")
          }
        Err(e) => fail("expected parseable response: " + e)
      }
    None => fail("expected rejected register response")
  }
  @debug.assert_eq(state.registry.credential_for_agent("root"), None)
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "serve root register succeeds with boot credential and rejects mismatch" {
  let (state, project_dir) = serve_test_state_with_root("root-boot-credential")
  let root_token = "root-boot-token"
  serve_record_boot_root_credential(state, root_token)

  let ok_result = serve_handle_request_line(
    state,
    serve_test_register_line("root", "root", root_token, project_dir),
    true,
  )
  serve_assert_register_ok(state, ok_result, "root", @types.Role::TL)

  let wrong_secret = "wrong-root-token"
  let wrong_result = serve_handle_request_line(
    state,
    serve_test_register_line("root", "root", wrong_secret, project_dir),
    true,
  )
  serve_assert_register_rejected(wrong_result, wrong_secret)
  ignore(@sys.rm_rf(project_dir))
}

///|
test "serve boot root token env ignores missing and empty values" {
  @debug.assert_eq(serve_boot_root_token_from_env(getenv=fn(_) { None }), None)
  @debug.assert_eq(
    serve_boot_root_token_from_env(getenv=fn(_) { Some("") }),
    None,
  )
  @debug.assert_eq(
    serve_boot_root_token_from_env(getenv=fn(key) {
      if key == "CHOIR_ROOT_AGENT_TOKEN" {
        Some("root-env-token")
      } else {
        None
      }
    }),
    Some("root-env-token"),
  )
}

///|
test "root bootstrap accepts only a same-binary peer and fixed token" {
  let (state, project_dir) = serve_test_state_with_root("root-bootstrap")
  let token = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
  let request : @types.Request = {
    req_method: serve_root_bootstrap_method,
    role: @types.Role::TL,
    name: serve_root_bootstrap_method,
    args: @types.RequestArgs::from_values({ "token": token.to_json() }),
  }
  assert_true(serve_valid_root_bootstrap_token(token))
  assert_false(serve_valid_root_bootstrap_token(token + "0"))
  assert_false(
    serve_valid_root_bootstrap_token(
      "g0112233445566778899aabbccddeeff00112233445566778899aabbccddeeff",
    ),
  )
  let denied = serve_handle_root_bootstrap(state, request, false)
  assert_false(denied.is_ok())
  @debug.assert_eq(state.registry.credential_for_agent("root"), None)
  let accepted = serve_handle_root_bootstrap(state, request, true)
  assert_true(accepted.is_ok())
  guard state.registry.credential_for_agent("root") is Some(credential) else {
    ignore(@sys.rm_rf(project_dir))
    fail("root bootstrap did not record a credential")
  }
  assert_eq(credential.role, @types.Role::TL)
  assert_eq(credential.token, token)
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "serve restores reload credentials before non-root reconnect register" {
  let (state, project_dir) = serve_test_state_with_root("reload-creds")
  let agent_id = "main.reload-creds.dev"
  let token = "reload-original-token"
  serve_test_upsert_agent(state, agent_id, @types.Role::Dev, project_dir)

  let before_restore = serve_handle_request_line(
    state,
    serve_test_register_line(agent_id, "dev", token, project_dir),
    true,
  )
  serve_assert_register_rejected(before_restore, token)

  let payload =
    #|{"version":1,"credentials":[{"agent_id":"main.reload-creds.dev","role":"dev","token":"reload-original-token"}]}
  let unset_keys : Array[String] = []
  let restored = serve_restore_reload_credentials_from_env(
    state,
    getenv=fn(key) {
      if key == serve_reload_credentials_env {
        Some(payload)
      } else {
        None
      }
    },
    unsetenv=fn(key) {
      unset_keys.push(key)
      true
    },
  )
  assert_eq(restored, 1)
  @debug.assert_eq(unset_keys, [serve_reload_credentials_env])

  let after_restore = serve_handle_request_line(
    state,
    serve_test_register_line(agent_id, "root", token, project_dir),
    true,
  )
  serve_assert_register_ok(state, after_restore, agent_id, @types.Role::Dev)
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "serve reload credential env missing empty or malformed stays fail closed" {
  let empty_token_payload =
    #|{"version":1,"credentials":[{"agent_id":"main.reload-negative.dev","role":"dev","token":""}]}
  let cases : Array[(String, String?)] = [
    ("missing", None),
    ("empty", Some("")),
    ("malformed", Some("not-json")),
    ("empty-token", Some(empty_token_payload)),
  ]
  for item in cases {
    let (label, env_value) = item
    let (state, project_dir) = serve_test_state_with_root(
      "reload-creds-" + label,
    )
    let agent_id = "main.reload-negative.dev"
    let token = "reload-negative-secret"
    serve_test_upsert_agent(state, agent_id, @types.Role::Dev, project_dir)
    let unset_keys : Array[String] = []
    let restored = serve_restore_reload_credentials_from_env(
      state,
      getenv=fn(key) {
        if key == serve_reload_credentials_env {
          env_value
        } else {
          None
        }
      },
      unsetenv=fn(key) {
        unset_keys.push(key)
        true
      },
    )
    assert_eq(restored, 0)
    @debug.assert_eq(unset_keys, [serve_reload_credentials_env])
    @debug.assert_eq(state.registry.credential_for_agent(agent_id), None)
    let result = serve_handle_request_line(
      state,
      serve_test_register_line(agent_id, "dev", token, project_dir),
      true,
    )
    serve_assert_register_rejected(result, token)
    ignore(@sys.rm_rf(project_dir))
  }
}

///|
test "serve prepares reload credentials env without root token or logs" {
  let (state, project_dir) = serve_test_state_with_root("reload-env-prepare")
  let leaf_token = "reload-env-leaf-token"
  let root_token = "reload-env-root-token"
  serve_test_record_credential(
    state,
    "main.reload-env.leaf",
    @types.Role::Dev,
    leaf_token,
  )
  serve_test_record_credential(state, "root", @types.Role::TL, root_token)
  let captured_events : Array[@moontrace.Event] = []
  let set_values : Array[String] = []
  let unset_keys : Array[String] = []
  @moontrace.set_subscriber(fn(event) { captured_events.push(event) })
  let prepared = serve_prepare_reload_credentials_env(
    state,
    setenv=fn(key, value) {
      if key == serve_reload_credentials_env {
        set_values.push(value)
      }
      true
    },
    unsetenv=fn(key) {
      unset_keys.push(key)
      true
    },
  )
  @moontrace.clear_subscriber()
  assert_true(prepared)
  assert_eq(set_values.length(), 1)
  assert_true(set_values[0].contains(leaf_token))
  assert_false(set_values[0].contains(root_token))
  @debug.assert_eq(unset_keys, [])
  for event in captured_events {
    assert_false(event.format(color=false).contains(leaf_token))
    assert_false(event.format(color=false).contains(root_token))
  }
  ignore(@sys.rm_rf(project_dir))
}

///|
fn serve_test_json_object(line : String) -> Result[Map[String, Json], String] {
  let parsed = @json.parse(line.trim().to_owned()) catch {
    _ => return Err("expected JSON response")
  }
  guard parsed is Object(obj) else {
    return Err("expected JSON object response")
  }
  Ok(obj)
}

///|
async test "serve JSON-RPC initialize returns MCP handshake shape" {
  let (state, project_dir) = serve_test_state_with_root("initialize")
  let result = serve_handle_request_line(
    state, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}", true,
  )
  match result.response_line {
    Some(line) => {
      let obj = match serve_test_json_object(line) {
        Ok(obj) => obj
        Err(e) => {
          fail(e)
          return
        }
      }
      @debug.assert_eq(obj.get("jsonrpc"), Some("2.0".to_json()))
      @debug.assert_eq(obj.get("id"), Some((1).to_json()))
      guard obj.get("result") is Some(Object(body)) else {
        fail("expected initialize result")
      }
      @debug.assert_eq(
        body.get("protocolVersion"),
        Some("2024-11-05".to_json()),
      )
      guard body.get("serverInfo") is Some(Object(server_info)) else {
        fail("expected serverInfo")
      }
      @debug.assert_eq(server_info.get("name"), Some("choir".to_json()))
    }
    None => fail("expected initialize response")
  }
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "serve unbound JSON-RPC tools list is empty" {
  let (state, project_dir) = serve_test_state_with_root("unbound-jsonrpc-list")
  let result = serve_handle_request_line(
    state, "{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"tools/list\"}", true,
  )
  match result.response_line {
    Some(line) => {
      let obj = match serve_test_json_object(line) {
        Ok(obj) => obj
        Err(e) => {
          fail(e)
          return
        }
      }
      guard obj.get("result") is Some(Object(result_obj)) else {
        fail("expected tools/list result")
      }
      guard result_obj.get("tools") is Some(Array(tools)) else {
        fail("expected tools array")
      }
      assert_eq(tools.length(), 0)
    }
    None => fail("expected tools/list response")
  }
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "serve authenticated Conductor JSON-RPC reaches Goal adapter" {
  let (state, project_dir) = serve_test_state_with_root("bound-jsonrpc-root")
  serve_test_record_credential(
    state,
    "root",
    @types.Role::TL,
    "bound-jsonrpc-root-token",
  )
  let register_result = serve_handle_request_line(
    state,
    serve_test_register_line(
      "root", "root", "bound-jsonrpc-root-token", project_dir,
    ),
    true,
  )
  serve_assert_register_ok(state, register_result, "root", @types.Role::TL)
  let owner = connected_agent_id_after_request(None, register_result)

  let bound_result = serve_handle_request_line(
    state,
    "{\"jsonrpc\":\"2.0\",\"id\":12,\"method\":\"tools/call\",\"params\":{\"name\":\"goal_status\",\"arguments\":{\"goal_id\":\"missing-goal\"}}}",
    true,
    authenticated_agent_id=owner,
  )
  @debug.assert_eq(bound_result.request_name, Some("goal_status"))
  match bound_result.response_line {
    Some(line) => {
      let obj = match serve_test_json_object(line) {
        Ok(obj) => obj
        Err(e) => {
          fail(e)
          return
        }
      }
      guard obj.get("result") is Some(Object(result_obj)) else {
        fail("expected bound goal_status result")
      }
      @debug.assert_eq(result_obj.get("isError"), Some(true.to_json()))
      guard result_obj.get("structuredContent") is Some(Object(payload)) else {
        fail("expected bound structuredContent object")
      }
      guard payload.get("error") is Some(String(message)) else {
        fail("expected Goal lookup error")
      }
      assert_true(message.contains("Goal is not registered"))
    }
    None => fail("expected bound goal_status response")
  }

  let unbound_result = serve_handle_request_line(
    state, "{\"jsonrpc\":\"2.0\",\"id\":13,\"method\":\"tools/call\",\"params\":{\"name\":\"goal_status\",\"arguments\":{\"goal_id\":\"missing-goal\",\"caller_id\":\"root\",\"agent_id\":\"root\"}}}",
    true,
  )
  @debug.assert_eq(unbound_result.request_name, Some("goal_status"))
  match unbound_result.response_line {
    Some(line) => {
      let obj = match serve_test_json_object(line) {
        Ok(obj) => obj
        Err(e) => {
          fail(e)
          return
        }
      }
      guard obj.get("result") is Some(Object(result_obj)) else {
        fail("expected unbound goal_status result")
      }
      @debug.assert_eq(result_obj.get("isError"), Some(true.to_json()))
      guard result_obj.get("structuredContent") is Some(Object(structured)) else {
        fail("expected unbound structuredContent object")
      }
      match structured.get("error") {
        Some(String(msg)) =>
          assert_true(msg.contains("authenticated Conductor required"))
        _ => fail("expected Conductor authentication error")
      }
    }
    None => fail("expected unbound goal_status response")
  }
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "serve rejected register refresh keeps existing disconnect owner" {
  let (state, project_dir) = serve_test_state_with_root("rejected-register")
  let agent_id = "main.good-register"
  let bad_agent_id = "main.bad-register"
  serve_test_record_credential(
    state,
    agent_id,
    @types.Role::Dev,
    "good-register-token",
  )
  serve_test_record_credential(
    state,
    bad_agent_id,
    @types.Role::Dev,
    "bad-register-token",
  )
  let ok_line = "{\"method\":\"register\",\"role\":\"dev\",\"name\":\"register\",\"args\":{\"agent_id\":\"" +
    agent_id +
    "\",\"agent_type\":\"codex\",\"branch\":\"" +
    agent_id +
    "\",\"workspace\":\"" +
    project_dir +
    "\",\"token\":\"good-register-token" +
    "\"}}"
  let ok_result = serve_handle_request_line(state, ok_line, true)
  assert_true(ok_result.saw_register)
  @debug.assert_eq(ok_result.connected_agent_id, Some(agent_id))
  let owner = connected_agent_id_after_request(None, ok_result)

  let bad_line = "{\"method\":\"register\",\"role\":\"dev\",\"name\":\"register\",\"args\":{\"agent_id\":\"" +
    bad_agent_id +
    "\",\"agent_type\":\"definitely-not-real\",\"branch\":\"" +
    bad_agent_id +
    "\",\"workspace\":\"" +
    project_dir +
    "\",\"token\":\"bad-register-token" +
    "\"}}"
  let bad_result = serve_handle_request_line(state, bad_line, true)
  assert_true(bad_result.saw_register)
  @debug.assert_eq(bad_result.connected_agent_id, None)
  match bad_result.response_line {
    Some(resp_line) =>
      match @transport.parse_response(resp_line.trim().to_owned()) {
        Ok(resp) => assert_false(resp.is_ok())
        Err(e) => fail("expected parseable response: " + e)
      }
    None => fail("expected rejected register response")
  }
  let owner = connected_agent_id_after_request(owner, bad_result)
  @debug.assert_eq(owner, Some(agent_id))
  match owner {
    Some(id) => state.schedule_disconnect(id, 10L)
    None => ()
  }
  assert_true(state.registry.get_opt(agent_id) is Some(_))
  assert_true(state.registry.get_opt(bad_agent_id) is None)
  assert_true(@phase.read_lifecycle(project_dir, bad_agent_id) is None)
  assert_true(state.pending_disconnects.contains(agent_id))
  assert_false(state.pending_disconnects.contains(bad_agent_id))
  ignore(@sys.rm_rf(project_dir))
}

///|
struct LiveUDSTestContext {
  state : @server.ServerState
  project_dir : String
  sock_path : String
  server_fd : Int
}

///|
struct LiveUDSTestSession {
  client_fd : Int
  server_client : ServeUDSClient
}

///|
fn live_uds_cleanup(ctx : LiveUDSTestContext) -> Unit {
  @uds.close(ctx.server_fd)
  ignore(@sys.rm_rf(ctx.project_dir))
}

///|
async fn live_uds_with_server(
  label : String,
  body : async (LiveUDSTestContext) -> Unit,
) -> Unit {
  let (state, project_dir) = serve_test_state_with_root("live-uds-" + label)
  let sock_path = project_dir + "/server.sock"
  let server_fd = @uds.server_create(sock_path)
  if server_fd < 0 {
    ignore(@sys.rm_rf(project_dir))
    fail("live UDS server_create failed")
  }
  ignore(@uds.set_nonblocking(server_fd))
  let ctx : LiveUDSTestContext = { state, project_dir, sock_path, server_fd }
  try body(ctx) catch {
    err => {
      live_uds_cleanup(ctx)
      raise err
    }
  } noraise {
    _ => live_uds_cleanup(ctx)
  }
}

///|
fn live_uds_config(ctx : LiveUDSTestContext) -> @types.Config {
  {
    ..@types.Config::default(),
    project_dir: ctx.project_dir,
    listen_uds: ctx.sock_path,
    terminal_session: "live-uds",
  }
}

///|
fn live_uds_local_cfg(
  agent_id : String,
  role : @types.Role,
  ctx : LiveUDSTestContext,
) -> @types.LocalConfig {
  {
    ..@types.LocalConfig::default(),
    role: Some(role),
    agent_id: Some(agent_id),
    parent_id: if agent_id == "root" {
      None
    } else {
      Some("root")
    },
    branch: Some(agent_id),
    parent_branch: Some("main"),
    workspace: Some(ctx.project_dir),
    agent_type: Some(@types.AgentType::Codex),
    spawn_depth: Some(0),
  }
}

///|
fn live_uds_register_message(
  role : @types.Role,
  agent_id : String,
  local_cfg : @types.LocalConfig,
  token : String,
  connection_lifetime : @transport.ConnectionLifetime,
) -> String {
  @transport.format_registration_request(
    role,
    agent_id,
    local_cfg,
    connection_lifetime~,
    agent_token=Some(token),
  ) +
  "\n"
}

///|
async fn live_uds_pump_server_once(
  ctx : LiveUDSTestContext,
  session : LiveUDSTestSession,
) -> Bool {
  let tasks : Array[async () -> Unit] = []
  let alive = serve_handle_uds_connection(
    session.server_client,
    ctx.state,
    ctx.server_fd,
    fn(task) { tasks.push(task) },
  )
  for task in tasks {
    task()
  }
  alive
}

///|
async fn live_uds_open_session(ctx : LiveUDSTestContext) -> LiveUDSTestSession {
  let client_fd = @uds.client_connect(ctx.sock_path)
  if client_fd < 0 {
    fail("live UDS client_connect failed")
  }
  ignore(@uds.set_nonblocking(client_fd))
  let mut accepted_fd = @uds.accept_nonblocking(ctx.server_fd)
  let mut attempts = 0
  while accepted_fd == -2 && attempts < 100 {
    @async.sleep(1)
    accepted_fd = @uds.accept_nonblocking(ctx.server_fd)
    attempts = attempts + 1
  }
  if accepted_fd < 0 {
    @uds.close(client_fd)
    fail("live UDS accept_nonblocking failed")
  }
  ignore(@uds.set_nonblocking(accepted_fd))
  { client_fd, server_client: ServeUDSClient::new(accepted_fd) }
}

///|
async fn live_uds_close_session(
  ctx : LiveUDSTestContext,
  session : LiveUDSTestSession,
) -> Unit {
  @uds.close(session.client_fd)
  let alive = live_uds_pump_server_once(ctx, session)
  if !alive {
    serve_close_uds_client(session.server_client, ctx.state)
  } else {
    @uds.close(session.server_client.fd)
  }
}

///|
async fn live_uds_with_session(
  ctx : LiveUDSTestContext,
  body : async (LiveUDSTestSession) -> Unit,
) -> Unit {
  let session = live_uds_open_session(ctx)
  try body(session) catch {
    err => {
      live_uds_close_session(ctx, session)
      raise err
    }
  } noraise {
    _ => live_uds_close_session(ctx, session)
  }
}

///|
async fn live_uds_read_line_nonblocking(fd : Int) -> String {
  let buf = FixedArray::make(8192, (0 : Byte))
  let mut write_pos = 0
  let mut attempts = 0
  while attempts < 100 {
    let n = @uds.read_bytes_nonblocking(
      fd,
      buf,
      write_pos,
      buf.length() - write_pos,
    )
    if n > 0 {
      write_pos = write_pos + n
      let bytes = buf.unsafe_reinterpret_as_bytes()
      for i = 0; i < write_pos; i = i + 1 {
        if bytes[i] == (10 : Byte) {
          return @utf8.decode_lossy(bytes[0:i])
        }
      }
    } else if n == 0 {
      if write_pos > 0 {
        return @utf8.decode_lossy(
          buf.unsafe_reinterpret_as_bytes()[0:write_pos],
        )
      }
      return ""
    } else if n != -2 {
      fail("live UDS read failed")
    }
    attempts = attempts + 1
    @async.sleep(1)
  }
  fail("timed out waiting for live UDS response")
}

///|
async fn live_uds_send_wire(
  ctx : LiveUDSTestContext,
  session : LiveUDSTestSession,
  wire : String,
) -> @types.Response {
  if !mcp_write_all_uds(session.client_fd, @utf8.encode(wire)) {
    fail("live UDS client write failed")
  }
  let alive = live_uds_pump_server_once(ctx, session)
  if !alive {
    fail("live UDS server closed before response")
  }
  let line = live_uds_read_line_nonblocking(session.client_fd)
  if line == "" {
    fail("live UDS empty response")
  }
  match @transport.parse_response(line) {
    Ok(resp) => resp
    Err(e) => fail("live UDS parse response failed: " + e)
  }
}

///|
async fn live_uds_register_session(
  ctx : LiveUDSTestContext,
  session : LiveUDSTestSession,
  role : @types.Role,
  agent_id : String,
  token : String,
) -> @types.Response {
  live_uds_send_wire(
    ctx,
    session,
    live_uds_register_message(
      role,
      agent_id,
      live_uds_local_cfg(agent_id, role, ctx),
      token,
      @transport.ConnectionLifetime::Session,
    ),
  )
}

///|
async fn live_uds_call(
  ctx : LiveUDSTestContext,
  session : LiveUDSTestSession,
  role : @types.Role,
  agent_id : String,
  req : @types.Request,
) -> @types.Response {
  live_uds_send_wire(
    ctx,
    session,
    mcp_build_wire_request(
      req,
      role,
      live_uds_config(ctx),
      live_uds_local_cfg(agent_id, role, ctx),
    ),
  )
}

///|
fn live_uds_assert_ok(resp : @types.Response, label : String) -> Unit raise {
  if !resp.is_ok() {
    fail(label + " expected ok: " + resp.error_message().unwrap_or(""))
  }
}

///|
fn live_uds_assert_error_contains(
  resp : @types.Response,
  needle : String,
  label : String,
) -> Unit raise {
  match resp.error_message() {
    Some(msg) => assert_true(msg.contains(needle))
    None => fail(label + " expected error containing " + needle)
  }
}

///|
fn live_uds_goal_status_req(role : @types.Role) -> @types.Request {
  {
    req_method: "tools/call",
    role,
    name: "goal_status",
    args: @types.RequestArgs::from_values({}),
  }
}

///|
fn live_uds_note_pass(name : String) -> Unit {
  @sys.write_stderr("PASS " + name + "\n")
}

///|
async test "real exec integration: same-binary local client bootstraps the root Conductor over UDS" {
  if !@exec.real_exec_integration_enabled() {
    return
  }
  live_uds_with_server("root-bootstrap", async fn(ctx) {
    live_uds_with_session(ctx, async fn(session) {
      assert_true(session.server_client.peer_is_choir)
      let token = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
      let request : @types.Request = {
        req_method: serve_root_bootstrap_method,
        role: @types.Role::TL,
        name: serve_root_bootstrap_method,
        args: @types.RequestArgs::from_values({ "token": token.to_json() }),
      }
      let response = live_uds_send_wire(
        ctx,
        session,
        @transport.format_request(request) + "\n",
      )
      live_uds_assert_ok(response, "root bootstrap")
      guard ctx.state.registry.credential_for_agent("root") is Some(credential) else {
        fail("root bootstrap credential was not recorded")
      }
      assert_eq(credential.role, @types.Role::TL)
      assert_eq(credential.token, token)
    })
  })
}

///|
async test "real exec integration: live UDS: strict role gate rejects supervisor spoof" {
  if !@exec.real_exec_integration_enabled() {
    return
  }
  live_uds_with_server("strict-role", async fn(ctx) {
    let root_token = "live-root-token"
    serve_record_boot_root_credential(ctx.state, root_token)
    live_uds_with_session(ctx, async fn(session) {
      live_uds_assert_ok(
        live_uds_register_session(
          ctx,
          session,
          @types.Role::TL,
          "root",
          root_token,
        ),
        "root register",
      )
      live_uds_assert_ok(
        live_uds_call(
          ctx,
          session,
          @types.Role::TL,
          "root",
          live_uds_goal_status_req(@types.Role::TL),
        ),
        "root TL gated call",
      )
      @debug.assert_eq(
        session.server_client.authenticated_agent_id,
        Some("root"),
      )
    })

    let sub_tl_id = "main.live-uds.subtl"
    let sub_tl_token = "live-subtl-token"
    serve_test_upsert_agent(
      ctx.state,
      sub_tl_id,
      @types.Role::TL,
      ctx.project_dir,
    )
    serve_test_record_credential(
      ctx.state,
      sub_tl_id,
      @types.Role::TL,
      sub_tl_token,
    )
    live_uds_with_session(ctx, async fn(session) {
      live_uds_assert_ok(
        live_uds_register_session(
          ctx,
          session,
          @types.Role::TL,
          sub_tl_id,
          sub_tl_token,
        ),
        "sub-TL register",
      )
      live_uds_assert_ok(
        live_uds_call(
          ctx,
          session,
          @types.Role::TL,
          sub_tl_id,
          live_uds_goal_status_req(@types.Role::TL),
        ),
        "sub-TL gated call",
      )
    })

    let dev_id = "main.live-uds.dev"
    let dev_token = "live-dev-token"
    serve_test_upsert_agent(
      ctx.state,
      dev_id,
      @types.Role::Dev,
      ctx.project_dir,
    )
    serve_test_record_credential(ctx.state, dev_id, @types.Role::Dev, dev_token)
    live_uds_with_session(ctx, async fn(session) {
      live_uds_assert_ok(
        live_uds_register_session(
          ctx,
          session,
          @types.Role::Dev,
          dev_id,
          dev_token,
        ),
        "dev register",
      )
      live_uds_assert_error_contains(
        live_uds_call(
          ctx,
          session,
          @types.Role::Dev,
          dev_id,
          live_uds_goal_status_req(@types.Role::TL),
        ),
        "authenticated identity mismatch",
        "dev supervisor spoof",
      )
    })

    let worker_id = "main.live-uds.worker"
    let worker_token = "live-worker-token"
    serve_test_upsert_agent(
      ctx.state,
      worker_id,
      @types.Role::Worker,
      ctx.project_dir,
    )
    serve_test_record_credential(
      ctx.state,
      worker_id,
      @types.Role::Worker,
      worker_token,
    )
    live_uds_with_session(ctx, async fn(session) {
      live_uds_assert_ok(
        live_uds_register_session(
          ctx,
          session,
          @types.Role::Worker,
          worker_id,
          worker_token,
        ),
        "worker register",
      )
      live_uds_assert_error_contains(
        live_uds_call(
          ctx,
          session,
          @types.Role::Worker,
          worker_id,
          live_uds_goal_status_req(@types.Role::TL),
        ),
        "authenticated identity mismatch",
        "worker supervisor spoof",
      )
    })
  })
  live_uds_note_pass("live UDS: strict role gate rejects supervisor spoof")
}

///|
async test "real exec integration: live UDS: sub-TL session binds branch id" {
  if !@exec.real_exec_integration_enabled() {
    return
  }
  live_uds_with_server("subtl-bind", async fn(ctx) {
    let agent_id = "feature.live-uds.subtl"
    let token = "live-subtl-bind-token"
    serve_test_upsert_agent(
      ctx.state,
      agent_id,
      @types.Role::TL,
      ctx.project_dir,
    )
    serve_test_record_credential(ctx.state, agent_id, @types.Role::TL, token)
    live_uds_with_session(ctx, async fn(session) {
      live_uds_assert_ok(
        live_uds_register_session(
          ctx,
          session,
          @types.Role::TL,
          agent_id,
          token,
        ),
        "sub-TL register",
      )
      @debug.assert_eq(session.server_client.connected_agent_id, Some(agent_id))
      @debug.assert_eq(
        session.server_client.authenticated_agent_id,
        Some(agent_id),
      )
      assert_false(session.server_client.authenticated_agent_id == Some("root"))
      live_uds_assert_ok(
        live_uds_call(
          ctx,
          session,
          @types.Role::TL,
          agent_id,
          live_uds_goal_status_req(@types.Role::TL),
        ),
        "sub-TL goal_status",
      )
    })
    assert_true(ctx.state.pending_disconnects.contains(agent_id))
    assert_false(ctx.state.pending_disconnects.contains("root"))
  })
  live_uds_note_pass("live UDS: sub-TL session binds branch id")
}

///|
async test "real exec integration: live UDS: target agent_id is not caller identity" {
  if !@exec.real_exec_integration_enabled() {
    return
  }
  live_uds_with_server("target-agent-id", async fn(ctx) {
    let root_token = "live-target-root-token"
    serve_record_boot_root_credential(ctx.state, root_token)
    let victim_id = "main.live-uds.victim"
    serve_test_upsert_agent(
      ctx.state,
      victim_id,
      @types.Role::Worker,
      ctx.project_dir,
    )
    live_uds_with_session(ctx, async fn(session) {
      live_uds_assert_ok(
        live_uds_register_session(
          ctx,
          session,
          @types.Role::TL,
          "root",
          root_token,
        ),
        "root register",
      )
      live_uds_assert_ok(
        live_uds_call(ctx, session, @types.Role::TL, "root", {
          req_method: "tools/call",
          role: @types.Role::TL,
          name: "suspend",
          args: @types.RequestArgs::from_values({
            "agent_id": victim_id.to_json(),
            "reason": "live UDS target id regression".to_json(),
          }),
        }),
        "root suspend target arg",
      )
    })

    let dev_id = "main.live-uds.spoof-dev"
    let dev_token = "live-target-dev-token"
    serve_test_upsert_agent(
      ctx.state,
      dev_id,
      @types.Role::Dev,
      ctx.project_dir,
    )
    serve_test_record_credential(ctx.state, dev_id, @types.Role::Dev, dev_token)
    live_uds_with_session(ctx, async fn(session) {
      live_uds_assert_ok(
        live_uds_register_session(
          ctx,
          session,
          @types.Role::Dev,
          dev_id,
          dev_token,
        ),
        "dev register",
      )
      live_uds_assert_error_contains(
        live_uds_call(ctx, session, @types.Role::Dev, dev_id, {
          req_method: "tools/call",
          role: @types.Role::Dev,
          name: "agent_list",
          args: @types.RequestArgs::from_values({
            "caller_id": "root".to_json(),
          }),
        }),
        "authenticated identity mismatch",
        "dev caller spoof",
      )
    })
  })
  live_uds_note_pass("live UDS: target agent_id is not caller identity")
}

///|
async test "real exec integration: live UDS: send_message provenance uses bound identity" {
  if !@exec.real_exec_integration_enabled() {
    return
  }
  live_uds_with_server("send-message-provenance", async fn(ctx) {
    ignore(@sys.create_dir_all(ctx.project_dir + "/.choir"))
    let target_id = "main.live-uds.done-target"
    ignore(
      ctx.state.registry.upsert({
        agent_id: target_id,
        role: @types.Role::Worker,
        agent_type: @types.AgentType::Codex,
        parent: Some("root"),
        workspace: ctx.project_dir,
        branch: target_id,
        terminal_target: None,
        host: @types.Host::Local,
        spawn_depth: 0,
        state: @types.AgentState::Done,
      }),
    )
    let dev_id = "main.live-uds.sender-dev"
    let dev_token = "live-sender-dev-token"
    serve_test_upsert_agent(
      ctx.state,
      dev_id,
      @types.Role::Dev,
      ctx.project_dir,
    )
    serve_test_record_credential(ctx.state, dev_id, @types.Role::Dev, dev_token)
    live_uds_with_session(ctx, async fn(session) {
      live_uds_assert_ok(
        live_uds_register_session(
          ctx,
          session,
          @types.Role::Dev,
          dev_id,
          dev_token,
        ),
        "dev register",
      )
      live_uds_assert_ok(
        live_uds_call(ctx, session, @types.Role::Dev, dev_id, {
          req_method: "tools/call",
          role: @types.Role::Dev,
          name: "send_message",
          args: @types.RequestArgs::from_values({
            "target_id": target_id.to_json(),
            "sender_id": "root".to_json(),
            "message": "bound sender spoof".to_json(),
          }),
        }),
        "bound send_message",
      )
    })
    let log_after_bound = @sys.read_file(
      ctx.project_dir + "/.choir/logs/delivery.log",
    )
    assert_true(log_after_bound.contains("sender=" + dev_id))
    assert_false(log_after_bound.contains("sender=root"))

    live_uds_with_session(ctx, async fn(session) {
      live_uds_assert_ok(
        live_uds_send_wire(
          ctx,
          session,
          @transport.format_request({
            req_method: "tools/call",
            role: @types.Role::Worker,
            name: "send_message",
            args: @types.RequestArgs::from_values({
              "target_id": target_id.to_json(),
              "sender_id": "root".to_json(),
              "message": "unbound sender spoof".to_json(),
            }),
          }) +
          "\n",
        ),
        "unbound send_message",
      )
    })
    let log_after_unbound = @sys.read_file(
      ctx.project_dir + "/.choir/logs/delivery.log",
    )
    assert_false(log_after_unbound.contains("sender=root"))
    assert_true(log_after_unbound.contains("sender=unknown"))
  })
  live_uds_note_pass("live UDS: send_message provenance uses bound identity")
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
  let mut authenticated_agent_id : String? = None
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
        let result = serve_handle_request_line(
          state,
          line,
          false,
          conductor_dispatch=serve_native_conductor_dispatch,
          authenticated_agent_id~,
        )
        connected_agent_id = connected_agent_id_after_request(
          connected_agent_id, result,
        )
        authenticated_agent_id = authenticated_agent_id_after_request(
          authenticated_agent_id, result,
        )
        match result.response_line {
          Some(resp_str) => conn.write(@utf8.encode(resp_str))
          None => ()
        }
        if result.drop_connection {
          match connected_agent_id {
            Some(agent_id) =>
              state.schedule_disconnect(agent_id, @poller.now_sec())
            None => ()
          }
          return
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
      // written == 0 here means the peer closed the connection before we
      // wrote a single byte — characteristic of one-shot JSON-RPC clients
      // (zjbar) that close immediately after sending a request. Not a
      // server-side problem; demote to TRACE so the log isn't spammed at
      // 2 Hz per polling client. Anomalous mid-stream disconnects
      // (partial write then disconnect) stay at WARN.
      if written == 0 {
        @moontrace.trace("UDS client disconnected pre-write", fields=[
          @moontrace.field("response_bytes", data.length()),
        ])
      } else {
        @moontrace.warn("UDS client disconnected mid-write", fields=[
          @moontrace.field("written", written),
          @moontrace.field("response_bytes", data.length()),
        ])
      }
      break
    }
    written = written + n
  }
}

///|
async fn serve_handle_uds_request_line(
  client : ServeUDSClient,
  state : @server.ServerState,
  server_fd : Int,
  _line : String,
  req : @types.Request,
) -> Unit {
  if req.req_method == serve_root_bootstrap_method {
    let response = serve_handle_root_bootstrap(state, req, client.peer_is_choir)
    serve_write_all_uds(
      client.fd,
      @utf8.encode(@transport.format_response(response) + "\n"),
    )
    client.busy = false
    client.close_after_response = true
    return
  }
  let result = serve_handle_parsed_custom_request(
    state,
    req,
    true,
    serve_native_conductor_dispatch,
    authenticated_agent_id=client.authenticated_agent_id,
  )
  client.connected_agent_id = connected_agent_id_after_request(
    client.connected_agent_id,
    result,
  )
  client.authenticated_agent_id = authenticated_agent_id_after_request(
    client.authenticated_agent_id,
    result,
  )
  let resp_str = result.response_line.unwrap_or("")
  @moontrace.trace("request", fields=[
    @moontrace.field("request", result.request_name.unwrap_or("(unknown)")),
  ])
  @moontrace.trace("response", fields=[@moontrace.field("body", resp_str)])
  serve_write_all_uds(client.fd, @utf8.encode(resp_str))
  client.busy = false
  if result.drop_connection {
    client.close_after_response = true
  }
  match result.reload_request {
    Some(reload_req) =>
      serve_replace_self_after_reload_ack(state, server_fd, reload_req)
    None => ()
  }
}

///|
async fn serve_handle_uds_jsonrpc_request_line(
  client : ServeUDSClient,
  state : @server.ServerState,
  server_fd : Int,
  line : String,
) -> Unit {
  let result = serve_handle_jsonrpc_request_line(
    state,
    line,
    true,
    serve_native_conductor_dispatch,
    authenticated_agent_id=client.authenticated_agent_id,
  )
  client.connected_agent_id = connected_agent_id_after_request(
    client.connected_agent_id,
    result,
  )
  client.authenticated_agent_id = authenticated_agent_id_after_request(
    client.authenticated_agent_id,
    result,
  )
  match result.request_name {
    Some(name) => client.last_request_name = Some(name)
    None => ()
  }
  match result.response_line {
    Some(resp_str) => {
      @moontrace.trace("request", fields=[
        @moontrace.field("request", result.request_name.unwrap_or("jsonrpc")),
      ])
      @moontrace.trace("response", fields=[@moontrace.field("body", resp_str)])
      serve_write_all_uds(client.fd, @utf8.encode(resp_str))
    }
    None => ()
  }
  client.busy = false
  if result.drop_connection {
    client.close_after_response = true
  }
  match result.reload_request {
    Some(req) => serve_replace_self_after_reload_ack(state, server_fd, req)
    None => ()
  }
}

///|
fn serve_handle_uds_connection(
  client : ServeUDSClient,
  state : @server.ServerState,
  server_fd : Int,
  spawn_request : (async () -> Unit) -> Unit,
) -> Bool {
  if client.close_after_response {
    return false
  }
  if client.busy {
    return true
  }
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
        if @transport.is_jsonrpc_request(line) {
          client.last_request_name = Some("jsonrpc")
          client.busy = true
          spawn_request(async fn() {
            serve_handle_uds_jsonrpc_request_line(
              client, state, server_fd, line,
            )
          })
        } else {
          let req_res = @transport.parse_request(line)
          match req_res {
            Ok(req) => {
              client.last_request_name = Some(req.name)
              client.busy = true
              spawn_request(async fn() {
                serve_handle_uds_request_line(
                  client, state, server_fd, line, req,
                )
              })
            }
            Err(err) => {
              @moontrace.warn("parse error", fields=[
                @moontrace.field("error", err),
              ])
              let resp = @types.Response::Err("parse error: " + err)
              serve_write_all_uds(
                client.fd,
                @utf8.encode(@transport.format_response(resp) + "\n"),
              )
            }
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
        if client.busy {
          return true
        }
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
    Some(agent_id) => {
      // Name the agent, its last request, and how long it was connected, so
      // a dropped session (e.g. the TL claude process dying) is identifiable
      // in the log instead of just "UDS client disconnected written=N".
      // One-shot CLI clients have no agent_id and stay silent here.
      let connected_sec = @poller.now_sec() - client.connected_at_sec
      @moontrace.info("agent connection closed", fields=[
        @moontrace.field("agent", agent_id),
        @moontrace.field(
          "last_request",
          client.last_request_name.unwrap_or("(none)"),
        ),
        @moontrace.field("connected_sec", connected_sec.to_string()),
      ])
      state.schedule_disconnect(
        agent_id,
        @poller.now_sec(),
        connected_sec=Some(connected_sec),
        last_request_name=Some(client.last_request_name.unwrap_or("(none)")),
      )
    }
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
  let kv_dir = serve_project_path(project_dir, ".choir/state/kv")
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
async fn run_poller_heartbeat_tick_loop(
  tick_sec : Int,
  tick_fn : async (Int64, Int64) -> Unit,
  sleep_fn? : async (Int) -> Unit = @async.sleep,
  timeout_sec? : Int64 = 900L,
  now_sec? : () -> Int64 = @poller.now_sec,
  max_iterations? : Int = -1,
) -> Unit {
  if tick_sec == 0 {
    return
  }
  let interval_ms = tick_sec * 1000
  let mut remaining = max_iterations
  while remaining != 0 {
    ignore(sleep_fn(interval_ms))
    if tick_sec != 0 {
      ignore(tick_fn(now_sec(), timeout_sec)) catch {
        e =>
          @moontrace.error("poller heartbeat tick error", fields=[
            @moontrace.field("error", e.to_string()),
          ])
      }
    }
    if remaining > 0 {
      remaining = remaining - 1
    }
  }
}

///|
fn serve_write_status_dump_if_sigusr1_requested(
  state : @server.ServerState,
  now_sec : Int64,
) -> Unit {
  if @sys.consume_sigusr1_flag() {
    let status_path = @server.server_status_path(state.config.project_dir)
    let lifecycle_reader = fn(agent_id) {
      @phase.read_lifecycle(state.config.project_dir, agent_id)
    }
    if !state.write_server_status_snapshot(now_sec, lifecycle_reader) {
      @moontrace.error("server status dump failed", fields=[
        @moontrace.field("path", status_path),
      ])
    } else {
      let rows = @server.server_status_snapshot_rows(
        state.registry,
        state.poller,
        lifecycle_reader,
        now_sec,
      )
      let mut attention_count = 0
      for row in rows {
        if row.attention_needed != @tools.PaneAttention::Clear {
          attention_count = attention_count + 1
        }
      }
      @moontrace.info("status snapshot written", fields=[
        @moontrace.field("path", status_path),
        @moontrace.field("timestamp", now_sec.to_string()),
        @moontrace.field("agent_count", rows.length()),
        @moontrace.field("attention_count", attention_count),
        @moontrace.field("tracked_pr_count", state.poller.tracked.length()),
      ])
    }
  }
}

///|
fn serve_test_moontrace_field_value(
  fields : Array[@moontrace.Field],
  key : String,
) -> Json? {
  for field in fields {
    if field.key == key {
      return Some(field.value)
    }
  }
  None
}

///|
fn serve_test_assert_string_field(
  fields : Array[@moontrace.Field],
  key : String,
  expected : String,
) -> Unit raise {
  match serve_test_moontrace_field_value(fields, key) {
    Some(Json::String(value)) => assert_eq(value, expected)
    _ => fail("expected string moontrace field " + key)
  }
}

///|
fn serve_test_assert_number_field(
  fields : Array[@moontrace.Field],
  key : String,
  expected : Double,
) -> Unit raise {
  match serve_test_moontrace_field_value(fields, key) {
    Some(Json::Number(value, ..)) => assert_eq(value, expected)
    _ => fail("expected number moontrace field " + key)
  }
}

///|
test "serve SIGUSR1 flag writes server status snapshot" {
  let (state, project_dir) = serve_test_state_with_root("sigusr1-status")
  assert_true(@sys.unblock_sigusr1_for_test())
  ignore(@sys.consume_sigusr1_flag())
  assert_true(@sys.install_sigusr1_handler())
  assert_true(@sys.raise_sigusr1_for_test())
  let captured : Array[@moontrace.Event] = []
  @moontrace.set_subscriber(fn(event) { captured.push(event) })
  serve_write_status_dump_if_sigusr1_requested(state, 100L)
  @moontrace.clear_subscriber()
  let content = @sys.read_file(@server.server_status_path(project_dir))
  assert_true(content.contains("choir server status\n"))
  assert_true(content.contains("agent_id=root "))
  assert_true(
    content.contains("terminal_target=zellij-pane:uds-jsonrpc:terminal_1"),
  )
  let mut snapshot_written_count = 0
  let mut snapshot_written_event : @moontrace.Event? = None
  for event in captured {
    if event.level == @moontrace.Level::Info &&
      event.message == "status snapshot written" {
      snapshot_written_count = snapshot_written_count + 1
      snapshot_written_event = Some(event)
    }
  }
  assert_eq(snapshot_written_count, 1)
  let snapshot_written_event = snapshot_written_event.unwrap()
  serve_test_assert_string_field(
    snapshot_written_event.fields,
    "path",
    @server.server_status_path(project_dir),
  )
  serve_test_assert_string_field(
    snapshot_written_event.fields,
    "timestamp",
    "100",
  )
  serve_test_assert_number_field(
    snapshot_written_event.fields,
    "agent_count",
    1.0,
  )
  serve_test_assert_number_field(
    snapshot_written_event.fields,
    "attention_count",
    0.0,
  )
  serve_test_assert_number_field(
    snapshot_written_event.fields,
    "tracked_pr_count",
    0.0,
  )
  ignore(@sys.rm_rf(project_dir))
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
  @debug.assert_eq(listed, [".choir/state/kv"])
  assert_eq(removed, 2)
  @debug.assert_eq(deleted, [
    ".choir/state/kv/tl-goal--old.json", ".choir/state/kv/tl-goal--other.json",
  ])
}

///|
async test "serve heartbeat task honors interval and calls poller tick" {
  let tick_calls : Array[Int64] = []
  let sleeps : Array[Int] = []
  run_poller_heartbeat_tick_loop(
    1,
    async fn(_now : Int64, _timeout : Int64) {
      @async.sleep(0)
      tick_calls.push(1)
    },
    sleep_fn=async fn(delay : Int) {
      sleeps.push(delay)
      @async.sleep(0)
    },
    max_iterations=2,
  )
  @debug.assert_eq(sleeps, [1000, 1000])
  @debug.assert_eq(tick_calls.length(), 2)
}

///|
async test "heartbeat task with zero interval disables tick callback" {
  let tick_calls : Array[Int] = []
  let sleeps : Array[Int] = []
  run_poller_heartbeat_tick_loop(
    0,
    async fn(_now : Int64, _timeout : Int64) {
      @async.sleep(0)
      tick_calls.push(1)
    },
    sleep_fn=async fn(delay : Int) {
      sleeps.push(delay)
      @async.sleep(0)
    },
    max_iterations=2,
  )
  @debug.assert_eq(sleeps, [])
  @debug.assert_eq(tick_calls, [])
}

///|
async test "heartbeat tick loop triggers automerge sweep path via process_poller_tick" {
  let project_dir = "/tmp/choir-heartbeat-sweep-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.rm_rf(project_dir))
  assert_true(@sys.create_dir_all(project_dir))
  let child_id = "main.leaf-heartbeat"
  let parent_id = "main.tl-heartbeat"
  let child_workspace = project_dir + "/.choir/worktrees/leaf-heartbeat"
  ignore(@sys.create_dir_all(child_workspace))
  let state = @server.ServerState::new(
    {
      ..@types.Config::default(),
      project_dir,
      automerge: true,
      review_mode: @types.ReviewMode::Iterative,
      terminal_session: "test-heartbeat",
    },
    @server.make_hermetic_recovery_provider(),
  )
  ignore(
    state.register_agent({
      agent_id: parent_id,
      role: @types.Role::TL,
      agent_type: @types.AgentType::Claude,
      parent: None,
      workspace: project_dir,
      branch: "main",
      terminal_target: Some(
        @workspace.local_target_for(
          "test-heartbeat",
          "TL",
          @types.IsolationMode::Worktree,
        ),
      ),
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  ignore(
    state.register_agent({
      agent_id: child_id,
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Claude,
      parent: Some(parent_id),
      workspace: child_workspace,
      branch: child_id,
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  state.record_agent_task_contract(
    child_id,
    Some({ ..@types.TaskContract::empty(), goal: "heartbeat sweep leaf" }),
  )
  let pr_number = 77
  state.poller.track(
    pr_number,
    child_id,
    child_id,
    "main",
    "https://github.com/brickfrog/choir/pull/" + pr_number.to_string(),
    500L,
  )
  match state.poller.get(pr_number) {
    Some(tracked) =>
      state.poller.restore({
        ..tracked,
        last_review_state: @poller.ReviewState::Approved,
        last_ci_rollup: @poller.CiRollupStatus::Success,
        mergeable: @poller.Mergeable::Unknown,
        merge_state_status: @poller.MergeStateStatus::Unknown,
        merged_at_unix: None,
        last_sha: "sha-heartbeat-sweep",
        unresolved_thread_ids: [],
        unresolved_thread_ids_fetched: true,
        copilot_issue_comment_seen: true,
        auto_resolve_outdated_pending: false,
        last_automerge_attempt_sha: "",
      })
    None => fail("expected tracked PR")
  }
  let mut merge_seen = false
  let runner = async fn(cmds : Array[@workspace.Command]) {
    @async.sleep(0)
    let statuses = []
    for cmd in cmds {
      if cmd.program == "gh" &&
        cmd.args.length() >= 3 &&
        cmd.args[0] == "pr" &&
        cmd.args[1] == "merge" {
        merge_seen = true
      }
      if cmd.program == "git" && cmd.args == ["branch", "-D", child_id] {
        merge_seen = true
      }
      statuses.push(0)
    }
    statuses
  }
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    if cmd.program == "git" &&
      cmd.args == ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"] {
      return (0, "origin/main\n")
    }
    let repo_view_json =
      #|{"owner":{"login":"brickfrog"},"name":"choir"}
    if (
        cmd.program == "gh" &&
        cmd.args == ["repo", "view", "--json", "owner,name"]
      ) ||
      (
        cmd.program == "timeout" &&
        cmd.args == ["30s", "gh", "repo", "view", "--json", "owner,name"]
      ) {
      return (0, repo_view_json)
    }
    if cmd.program == "gh" &&
      cmd.args.length() >= 2 &&
      cmd.args[0] == "api" &&
      cmd.args[1].has_suffix("/reviews") {
      return (
        0, "[{\"state\":\"APPROVED\",\"user\":{\"login\":\"copilot-pull-request-reviewer[bot]\"},\"submitted_at\":\"2026-05-10T00:00:00Z\"}]",
      )
    }
    if cmd.args.contains("graphql") {
      return (
        0, "{\"data\":{\"repository\":{\"pullRequest\":{\"reviewThreads\":{\"nodes\":[]}}}}}",
      )
    }
    if cmd.args == ["pr", "view", pr_number.to_string(), "--json", "body"] {
      return (0, "{\"body\":\"Closes choir-heartbeat\"}")
    }
    if cmd.args ==
      ["pr", "merge", pr_number.to_string(), "--squash", "--delete-branch"] {
      return (0, "merged")
    }
    if cmd.program == "git" && cmd.args == ["branch", "-D", child_id] {
      return (0, "")
    }
    (0, "")
  }
  let poll = async fn(_pr_number : Int, _skip_issue_comment_fetch : Bool) {
    @async.sleep(0)
    (
      true,
      @poller.ReviewState::Approved,
      "sha-heartbeat-sweep",
      @poller.CiRollupStatus::Success,
      "",
      true,
      false,
      @poller.Mergeable::Unknown,
      @poller.MergeStateStatus::Unknown,
      None,
    )
  }
  let no_sleep = async fn(_ms : Int) -> Unit { @async.sleep(0) }
  run_poller_heartbeat_tick_loop(
    1,
    async fn(now : Int64, timeout_sec : Int64) {
      state.process_poller_tick_with(
        now,
        timeout_sec,
        poll,
        None,
        "",
        runner~,
        capture~,
        git_capture=async fn(_program, _args) {
          @async.sleep(0)
          ""
        },
        bd_capture=capture,
        git_pull_capture=capture,
        automerge_capture=capture,
        hook_capture=async fn(_p, _i, _c) {
          @async.sleep(0)
          (0, "")
        },
        path_exists=@exec.path_entry_exists,
        hook_path_exists=@exec.path_entry_exists,
        audit_receipt_exists=@exec.path_entry_exists,
        audit_receipt_read=@exec.read_file,
        sleep_fn=no_sleep,
      )
    },
    max_iterations=1,
  )
  assert_true(merge_seen)
  assert_true(state.poller.get(pr_number) == None)
}

///|
fn serve_run() -> Unit {
  let config_content = @sys.read_file(".choir/config.toml")
  let local_content = @sys.read_file(".choir/config.local.toml")
  let config = match
    @config.parse_config(config_content, local_content=Some(local_content)) {
    Ok(cfg) => cfg
    Err(_) => @types.Config::default()
  }
  // Ensure the categorized .choir subdirs exist before anything writes a log,
  // binds the socket, or a crash handler fires: logs/ (all logs), run/
  // (ephemeral runtime: socket, pids, run_id), state/ (durable server state).
  ignore(@sys.create_dir_all(config.project_dir + "/.choir/logs"))
  ignore(@sys.create_dir_all(config.project_dir + "/.choir/run"))
  ignore(@sys.create_dir_all(config.project_dir + "/.choir/run/pids"))
  ignore(@sys.create_dir_all(config.project_dir + "/.choir/state"))
  let inherited_uds_fd = serve_inherited_uds_fd()
  let serve_log_path = serve_project_path(
    config.project_dir,
    ".choir/logs/serve.log",
  )
  match inherited_uds_fd {
    Some(_) => ()
    None => {
      ignore(
        @server.serve_rotate_log_if_large(
          config.project_dir,
          ".choir/logs/delivery.log",
          @sys.file_size,
          @sys.rename_file_sync,
        ),
      )
      ignore(
        @server.serve_rotate_log_if_large(
          config.project_dir,
          ".choir/logs/serve.log",
          @sys.file_size,
          @sys.rename_file_sync,
        ),
      )
      ignore(
        @server.serve_rotate_log_if_large(
          config.project_dir,
          ".choir/logs/server-exits.log",
          @sys.file_size,
          @sys.rename_file_sync,
        ),
      )
    }
  }
  @moontrace.set_subscriber(fn(event) {
    println(@exec.strip_terminal_responses(event.format(color=true)))
    ignore(
      @sys.append_file_sync(
        serve_log_path,
        @exec.strip_terminal_responses(event.format(color=false)) + "\n",
      ),
    )
  })
  @moontrace.set_min_level(@moontrace.Level::Debug)
  match inherited_uds_fd {
    Some(_) => ()
    // Remove stale markers before publishing this server's PID. Publishing the
    // PID first makes cleanup erase the only bounded shutdown handle.
    None => @sys.init_cleanup_runtime_artifacts_native()
  }
  @sys.write_pid_file(".choir/run/server.pid")
  @sys.register_cleanup_runtime_artifacts()
  @sys.install_crash_handlers()
  if !@sys.install_sigusr1_handler() {
    @moontrace.warn("failed to install SIGUSR1 handler", fields=[])
  }
  match inherited_uds_fd {
    Some(_) => ()
    None => ignore(serve_cleanup_stale_goal_kv(config.project_dir))
  }
  let provider = @server.make_recovery_provider()
  let state = @server.ServerState::new(config, provider)
  @moontrace.set_global_field("service", "choir".to_json())
  @moontrace.set_global_field("run_id", state.run_id.to_json())
  @prompts.emit_prompt_drift_warnings(
    config.project_dir,
    @exec.path_entry_exists,
    @exec.read_file,
  )
  @async.run_async_main(async fn() {
    @async.with_task_group(async fn(root) {
      let mut reload_snapshot_restored = false
      match inherited_uds_fd {
        Some(fd) =>
          match state.restore_reload_snapshot() {
            Ok(_) => {
              reload_snapshot_restored = true
              let line = "[server_reload] resumed run_id=" + state.run_id
              @moontrace.info(line, fields=[@moontrace.field("fd", fd)])
              @sys.write_stdout(line + "\n")
            }
            Err(e) =>
              @moontrace.error("server reload resume failed", fields=[
                @moontrace.field("error", e.message()),
              ])
          }
        None => ignore(serve_clear_reload_credentials_env())
      }
      match serve_boot_root_token_from_env() {
        Some(token) => serve_record_boot_root_credential(state, token)
        None => ()
      }
      match inherited_uds_fd {
        Some(_) =>
          if reload_snapshot_restored {
            ignore(serve_restore_reload_credentials_from_env(state))
          } else {
            ignore(serve_clear_reload_credentials_env())
          }
        None => ()
      }
      if state.has_otlp_span_exporter() {
        root.spawn_bg(async fn() { state.run_otlp_span_export_loop() })
      }
      root.spawn_bg(async fn() {
        for ;; {
          @async.sleep(1000)
          serve_write_status_dump_if_sigusr1_requested(state, @poller.now_sec())
        }
      })
      root.spawn_bg(async fn() {
        for ;; {
          match @exec.run_native_goal_execution_tick(config.project_dir) {
            Ok(@workflow.GoalExecutionTickResult::GoalExecutionTickIdle) => ()
            Ok(
              @workflow.GoalExecutionTickResult::GoalExecutionTickAdvanced(
                record
              )
            ) =>
              @moontrace.info("Goal execution advanced", fields=[
                @moontrace.field("goal_id", record.goal.id.0),
                @moontrace.field(
                  "state",
                  record.state.to_json().stringify(indent=0),
                ),
              ])
            Err(error) =>
              @moontrace.error("Goal execution tick failed", fields=[
                @moontrace.field("error", error.message()),
              ])
          }
          @async.sleep(1000)
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
              fn(task) { root.spawn_bg(task) },
            )
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
          let server = @socket.TcpServer(@socket.Addr::parse(addr_str))
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
