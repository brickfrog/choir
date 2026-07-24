///|
priv struct ConductorServerState {
  config : @types.Config
  run_id : String
  mut conductor_token : String?
  mut statusline_cache_key : String?
  mut goal_worker_pid : Int?
  channel_fds : Array[Int]
  mut watched_goal_id : String?
  mut parked_for_goal_event : Bool
  mut last_goal_update : String?
  mut last_goal_update_fingerprint : String?
  goal_updates : Map[String, String]
  mut server_identity : String
}

///|
fn ConductorServerState::new(config : @types.Config) -> ConductorServerState {
  {
    config,
    run_id: "serve-" + @sys.get_pid().to_string(),
    conductor_token: None,
    statusline_cache_key: None,
    goal_worker_pid: None,
    channel_fds: [],
    watched_goal_id: None,
    parked_for_goal_event: false,
    last_goal_update: None,
    last_goal_update_fingerprint: None,
    goal_updates: Map([]),
    server_identity: "",
  }
}

///|
priv struct ConductorClient {
  fd : Int
  peer_is_choir : Bool
  mut buffer : FixedArray[Byte]
  mut used : Int
  mut authenticated : Bool
  mut busy : Bool
  mut close_after_response : Bool
}

///|
fn ConductorClient::new(fd : Int) -> ConductorClient {
  {
    fd,
    peer_is_choir: conductor_peer_is_choir(fd),
    buffer: FixedArray::make(4096, (0 : Byte)),
    used: 0,
    authenticated: false,
    busy: false,
    close_after_response: false,
  }
}

///|
let conductor_bootstrap_method : String = "conductor_bootstrap"

///|
let local_cli_register_method : String = "local_cli_register"

///|
let conductor_goal_update_method : String = "conductor_goal_update"

///|
let conductor_stop_decision_method : String = "conductor_stop_decision"

///|
let server_identity_method : String = "server_identity"

///|
fn conductor_goal_id_from_json(value : Json?) -> String? {
  match value {
    Some(String(identity)) => Some(identity)
    Some(Array([String(_), String(identity)])) => Some(identity)
    _ => None
  }
}

///|
fn conductor_response_goal_id(response : @types.Response) -> String? {
  match response.ok_payload() {
    Some(fields) => conductor_goal_id_from_json(fields.get_json("goal_id"))
    None => None
  }
}

///|
fn conductor_response_state(response : @types.Response) -> String? {
  match response.ok_payload() {
    Some(fields) =>
      match fields.get_json("state") {
        Some(String(state)) => Some(state)
        _ => None
      }
    None => None
  }
}

///|
fn conductor_goal_state_succeeded(state : String?) -> Bool {
  state == Some("GoalExecutionSucceeded")
}

///|
fn conductor_watch_goal(state : ConductorServerState, goal_id : String) -> Unit {
  if state.watched_goal_id == Some(goal_id) {
    return
  }
  state.watched_goal_id = Some(goal_id)
  state.last_goal_update = None
  state.last_goal_update_fingerprint = None
  match state.statusline_cache_key {
    Some(key) =>
      conductor_statusline_activate_cache(state.config.project_dir, key, None)
    None => ()
  }
  match state.goal_updates.get(goal_id) {
    Some(serialized) => {
      let report : Json? = Some(@json.parse(serialized)) catch { _ => None }
      match report {
        Some(value) => conductor_broadcast_goal_update(state, value)
        None => ()
      }
    }
    None => ()
  }
}

///|
fn conductor_observe_goal_response(
  state : ConductorServerState,
  request : @types.Request,
  response : @types.Response,
) -> Unit {
  if !response.is_ok() || !request.name.has_prefix("goal_") {
    return
  }
  let goal_id = match conductor_response_goal_id(response) {
    Some(identity) => Some(identity)
    None => request.args.get("goal_id")
  }
  state.parked_for_goal_event = !conductor_goal_state_succeeded(
    conductor_response_state(response),
  )
  match goal_id {
    Some(identity) => conductor_watch_goal(state, identity)
    None => ()
  }
}

///|
fn conductor_goal_update_line(report : Json) -> String {
  { "method": "choir/goal_status_changed".to_json(), "report": report }
  .to_json()
  .stringify(indent=0) +
  "\n"
}

///|
fn conductor_remove_channel_fd(state : ConductorServerState, fd : Int) -> Unit {
  let mut index = 0
  while index < state.channel_fds.length() {
    if state.channel_fds[index] == fd {
      ignore(state.channel_fds.remove(index))
    } else {
      index = index + 1
    }
  }
}

///|
fn conductor_copy_projection_field(
  source : Map[String, Json],
  target : Map[String, Json],
  name : String,
) -> Unit {
  match source.get(name) {
    Some(value) => target.set(name, value)
    None => ()
  }
}

///|
fn conductor_goal_update_fingerprint(report : Json) -> String {
  guard report is Object(fields) else { return report.stringify(indent=0) }
  let projection : Map[String, Json] = Map([])
  for
    name in [
      "goal_id", "state", "lifecycle", "pause_reason", "resume_state", "active_input_request",
      "maximum_parallel_parts", "assurance_stage", "publication_state", "pull_request_state",
      "finalization_id", "readiness_decision",
    ] {
    conductor_copy_projection_field(fields, projection, name)
  }
  match fields.get("parts") {
    Some(Array(parts)) => {
      let projected_parts = parts.map(fn(part) {
        guard part is Object(part_fields) else { return part }
        let projected : Map[String, Json] = Map([])
        for
          name in [
            "part_id", "implementation_take_lifecycle", "implementation_session_lifecycle",
            "verification_take_lifecycle", "verification_session_lifecycle", "audit_take_lifecycle",
            "audit_session_lifecycle", "lifecycle", "stage",
          ] {
          conductor_copy_projection_field(part_fields, projected, name)
        }
        projected.to_json()
      })
      projection.set("parts", projected_parts.to_json())
    }
    _ => ()
  }
  projection.to_json().stringify(indent=0)
}

///|
fn conductor_broadcast_goal_update(
  state : ConductorServerState,
  report : Json,
) -> Unit {
  guard report is Object(fields) else { return }
  let goal_id = conductor_goal_id_from_json(fields.get("goal_id"))
  guard goal_id is Some(identity) else { return }
  let serialized = report.stringify(indent=0)
  // Cache updates before applying the watch filter. The Goal worker can win a
  // race with goal_submit's response; watching that Goal must then replay the
  // already-observed transition instead of sleeping until a later one.
  state.goal_updates.set(identity, serialized)
  if state.watched_goal_id != goal_id {
    return
  }
  let fingerprint = conductor_goal_update_fingerprint(report)
  state.last_goal_update = Some(serialized)
  if state.last_goal_update_fingerprint == Some(fingerprint) {
    return
  }
  state.last_goal_update_fingerprint = Some(fingerprint)
  match state.statusline_cache_key {
    Some(key) =>
      conductor_statusline_update_cache(state.config.project_dir, key, report)
    None => ()
  }
  let goal_state = match fields.get("state") {
    Some(String(value)) => Some(value)
    _ => None
  }
  state.parked_for_goal_event = !conductor_goal_state_succeeded(goal_state)
  let wire = @utf8.encode(conductor_goal_update_line(report))
  let targets = state.channel_fds.copy()
  for fd in targets {
    if !conductor_write_all(fd, wire) {
      conductor_remove_channel_fd(state, fd)
    }
  }
}

///|
fn conductor_peer_is_choir(fd : Int) -> Bool {
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
    (Some(peer), Some(server)) => peer == server
    _ => false
  }
}

///|
fn conductor_valid_bootstrap_token(token : String) -> Bool {
  if token.length() != 64 {
    return false
  }
  for index = 0; index < token.length(); index = index + 1 {
    let unit = token.code_unit_at(index)
    if !((unit >= 48 && unit <= 57) || (unit >= 97 && unit <= 102)) {
      return false
    }
  }
  true
}

///|
fn conductor_tokens_equal(presented : String, stored : String) -> Bool {
  let mut different = if presented.length() == stored.length() { 0 } else { 1 }
  for index = 0; index < stored.length(); index = index + 1 {
    let presented_unit = if index < presented.length() {
      presented.code_unit_at(index)
    } else {
      0
    }
    if presented_unit != stored.code_unit_at(index) {
      different = 1
    }
  }
  different == 0
}

///|
fn conductor_bootstrap(
  state : ConductorServerState,
  request : @types.Request,
  peer_is_choir : Bool,
) -> @types.Response {
  if request.req_method != conductor_bootstrap_method ||
    request.name != conductor_bootstrap_method ||
    !peer_is_choir {
    return @types.Response::Err("Conductor bootstrap authentication failed")
  }
  let token = request.args.get(@types.registration_token_arg).unwrap_or("")
  let statusline_cache_key = request.args
    .get("statusline_cache_key")
    .unwrap_or("")
  if !conductor_valid_bootstrap_token(token) ||
    !conductor_statusline_cache_key_valid(statusline_cache_key) {
    return @types.Response::Err("Conductor bootstrap authentication failed")
  }
  state.conductor_token = Some(token)
  state.statusline_cache_key = Some(statusline_cache_key)
  let latest_report : Json? = match state.last_goal_update {
    Some(serialized) => Some(@json.parse(serialized)) catch { _ => None }
    None => None
  }
  conductor_statusline_activate_cache(
    state.config.project_dir,
    statusline_cache_key,
    latest_report,
  )
  @types.Response::ok_values(Map([]))
}

///|
fn conductor_register(
  state : ConductorServerState,
  request : @types.Request,
) -> @types.Response {
  let presented = request.registration_token().unwrap_or("")
  if request.req_method != "register" || presented == "" {
    return @types.Response::Err("Conductor registration authentication failed")
  }
  let stored = match state.conductor_token {
    Some(token) => token
    None =>
      return @types.Response::Err(
        "Conductor credential not provisioned; run `choir start`",
      )
  }
  if !conductor_tokens_equal(presented, stored) {
    return @types.Response::Err("Conductor registration authentication failed")
  }
  @types.Response::ok_values(Map([]))
}

///|
fn local_cli_register(
  request : @types.Request,
  peer_is_choir : Bool,
) -> @types.Response {
  if request.req_method != local_cli_register_method ||
    request.name != local_cli_register_method ||
    !peer_is_choir {
    @types.Response::Err("local CLI authentication failed")
  } else {
    @types.Response::ok_values(Map([]))
  }
}

///|
fn conductor_authenticated_request(request : @types.Request) -> @types.Request {
  let arguments : Map[String, Json] = Map([])
  request.args.each_json(fn(name, value) {
    if name != "caller_id" && name != "agent_id" && name != "sender_id" {
      arguments.set(name, value)
    }
  })
  {
    ..request,
    req_method: "tools/call",
    args: @types.RequestArgs::from_values(arguments),
  }
}

///|
async fn conductor_dispatch(
  state : ConductorServerState,
  request : @types.Request,
) -> @types.Response {
  @exec.dispatch_native_conductor_request(
    state.config.project_dir,
    conductor_authenticated_request(request),
  ) catch {
    error => {
      @moontrace.error("Conductor adapter error", fields=[
        @moontrace.field("request", request.name),
        @moontrace.field("error", error.to_string()),
      ])
      @types.Response::Err("internal error: " + error.to_string())
    }
  }
}

///|
fn conductor_write_all(fd : Int, data : Bytes) -> Bool {
  let mut written = 0
  while written < data.length() {
    let count = @uds.write_bytes(fd, data, written, data.length() - written)
    if count <= 0 {
      return false
    }
    written = written + count
  }
  true
}

///|
fn conductor_send_response(fd : Int, response : @types.Response) -> Bool {
  conductor_write_all(
    fd,
    @utf8.encode(@transport.format_response(response) + "\n"),
  )
}

///|
async fn conductor_handle_custom_line(
  client : ConductorClient,
  state : ConductorServerState,
  request : @types.Request,
) -> Unit {
  if request.req_method == server_identity_method {
    // Answered without authentication: the socket is 0600, and the build
    // identity lets `choir start` decide whether this daemon is current
    // even when the on-disk binary was replaced underneath it.
    ignore(
      conductor_send_response(
        client.fd,
        @types.Response::ok_values({
          "identity": state.server_identity.to_json(),
        }),
      ),
    )
    client.close_after_response = true
    client.busy = false
    return
  }
  if request.req_method == conductor_bootstrap_method {
    ignore(
      conductor_send_response(
        client.fd,
        conductor_bootstrap(state, request, client.peer_is_choir),
      ),
    )
    client.close_after_response = true
    client.busy = false
    return
  }
  if request.req_method == "register" {
    let response = conductor_register(state, request)
    let channel = request.args.get_bool("channel").unwrap_or(false)
    if response.is_ok() {
      client.authenticated = true
    } else {
      client.close_after_response = true
    }
    let response_sent = conductor_send_response(client.fd, response)
    // The registration response must be the first frame on this connection.
    // Adding the descriptor earlier lets a concurrent Goal update race ahead
    // of it and makes the MCP bridge parse the notification as registration.
    if response.is_ok() && response_sent && channel {
      if !state.channel_fds.contains(client.fd) {
        state.channel_fds.push(client.fd)
      }
      // A channel reconnect can occur after the worker published a transition.
      // Replay the latest projection so the Conductor cannot sleep forever
      // waiting for an event that preceded the new transport connection.
      match state.last_goal_update {
        Some(serialized) => {
          let report : Json? = Some(@json.parse(serialized)) catch { _ => None }
          match report {
            Some(value) =>
              if !conductor_write_all(
                  client.fd,
                  @utf8.encode(conductor_goal_update_line(value)),
                ) {
                conductor_remove_channel_fd(state, client.fd)
                client.close_after_response = true
              }
            None => ()
          }
        }
        None => ()
      }
    }
    client.busy = false
    return
  }
  if request.req_method == local_cli_register_method {
    let response = local_cli_register(request, client.peer_is_choir)
    if response.is_ok() {
      client.authenticated = true
    } else {
      client.close_after_response = true
    }
    ignore(conductor_send_response(client.fd, response))
    client.busy = false
    return
  }
  if request.req_method == conductor_goal_update_method {
    let response = if client.authenticated && client.peer_is_choir {
      match request.args.get_json("report") {
        Some(report) => {
          conductor_broadcast_goal_update(state, report)
          @types.Response::ok_values(Map([]))
        }
        None => @types.Response::Err("Goal update report is absent")
      }
    } else {
      @types.Response::Err("Goal update authentication failed")
    }
    ignore(conductor_send_response(client.fd, response))
    client.busy = false
    return
  }
  if request.req_method == conductor_stop_decision_method {
    let response = if client.authenticated {
      let fields : Map[String, Json] = {
        "park": state.parked_for_goal_event.to_json(),
      }
      match state.watched_goal_id {
        Some(identity) => fields.set("goal_id", identity.to_json())
        None => ()
      }
      @types.Response::ok_values(fields)
    } else {
      @types.Response::Err("authenticated Conductor required")
    }
    ignore(conductor_send_response(client.fd, response))
    client.busy = false
    return
  }
  let response = if client.authenticated {
    conductor_dispatch(state, request)
  } else {
    @types.Response::Err("authenticated Conductor required")
  }
  conductor_observe_goal_response(state, request, response)
  ignore(conductor_send_response(client.fd, response))
  client.busy = false
}

///|
fn conductor_jsonrpc_line(response : @mcp.JsonRpcResponse) -> String {
  response.to_json_string() + "\n"
}

///|
async fn conductor_handle_jsonrpc_line(
  client : ConductorClient,
  state : ConductorServerState,
  line : String,
) -> Unit {
  let response = match @mcp.parse_jsonrpc_request(line) {
    Ok(rpc) => {
      let id = rpc.id.unwrap_or(Number(0))
      if rpc.req_method == @mcp.method_initialize {
        @mcp.initialize_response(id)
      } else if rpc.req_method == @mcp.method_tools_list {
        @mcp.tools_list_response(id, client.authenticated)
      } else {
        match @mcp.to_internal_request(rpc) {
          Ok(request) => {
            let internal = if client.authenticated {
              conductor_dispatch(state, request)
            } else {
              @types.Response::Err("authenticated Conductor required")
            }
            @mcp.from_internal_response(id, internal)
          }
          Err(error) => @mcp.error_response(id, error.code, error.message)
        }
      }
    }
    Err(error) => @mcp.error_response(Number(0), error.code, error.message)
  }
  ignore(
    conductor_write_all(
      client.fd,
      @utf8.encode(conductor_jsonrpc_line(response)),
    ),
  )
  client.busy = false
}

///|
fn conductor_slice(source : FixedArray[Byte], length : Int) -> String {
  let bytes = Array::make(length, (0 : Byte))
  for index = 0; index < length; index = index + 1 {
    bytes[index] = source[index]
  }
  @utf8.decode_lossy(Bytes::from_array(bytes[:]))
}

///|
fn conductor_grow_buffer(source : FixedArray[Byte]) -> FixedArray[Byte] {
  let grown = FixedArray::make(source.length() * 2, (0 : Byte))
  for index = 0; index < source.length(); index = index + 1 {
    grown[index] = source[index]
  }
  grown
}

///|
fn conductor_consume_line(client : ConductorClient, newline : Int) -> String {
  let line = conductor_slice(client.buffer, newline)
  let remaining = client.used - newline - 1
  for index = 0; index < remaining; index = index + 1 {
    client.buffer[index] = client.buffer[newline + 1 + index]
  }
  client.used = remaining
  line
}

///|
fn conductor_poll_client(
  client : ConductorClient,
  state : ConductorServerState,
  spawn_request : (async () -> Unit) -> Unit,
) -> Bool {
  if client.close_after_response {
    return false
  }
  if client.busy {
    return true
  }
  for ;; {
    if client.used == client.buffer.length() {
      client.buffer = conductor_grow_buffer(client.buffer)
    }
    let count = @uds.read_bytes_nonblocking(
      client.fd,
      client.buffer,
      client.used,
      client.buffer.length() - client.used,
    )
    if count == -2 {
      return true
    }
    if count <= 0 {
      return false
    }
    client.used = client.used + count
    let mut newline = 0
    while newline < client.used && client.buffer[newline] != (10 : Byte) {
      newline = newline + 1
    }
    if newline == client.used {
      continue
    }
    let line = conductor_consume_line(client, newline)
    client.busy = true
    if @transport.is_jsonrpc_request(line) {
      spawn_request(async fn() {
        conductor_handle_jsonrpc_line(client, state, line)
      })
    } else {
      match @transport.parse_request(line) {
        Ok(request) =>
          spawn_request(async fn() {
            conductor_handle_custom_line(client, state, request)
          })
        Err(error) => {
          ignore(
            conductor_send_response(
              client.fd,
              @types.Response::Err("parse error: " + error),
            ),
          )
          client.busy = false
        }
      }
    }
    return true
  }
  true
}

///|
async fn conductor_serve_uds(
  state : ConductorServerState,
  root : @async.TaskGroup[Unit],
) -> Unit {
  let server_fd = @uds.server_create(state.config.listen_uds)
  if server_fd < 0 {
    @moontrace.error("failed to bind UDS server", fields=[
      @moontrace.field("path", state.config.listen_uds),
    ])
    return
  }
  ignore(@uds.set_nonblocking(server_fd))
  @moontrace.info("UDS server listening", fields=[
    @moontrace.field("path", state.config.listen_uds),
  ])
  let clients : Array[ConductorClient] = []
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
      clients.push(ConductorClient::new(client_fd))
    }
    let mut index = 0
    while index < clients.length() {
      if conductor_poll_client(clients[index], state, fn(task) {
          root.spawn_bg(task)
        }) {
        index = index + 1
      } else {
        let client = clients.remove(index)
        conductor_remove_channel_fd(state, client.fd)
        @uds.close(client.fd)
      }
    }
    @async.sleep(10)
  }
}

///|
fn conductor_publish_goal_update(
  report : @workflow.GoalStatusReport,
) -> Result[Unit, String] {
  let config = match goal_client_load_config() {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let request : @types.Request = {
    req_method: conductor_goal_update_method,
    name: conductor_goal_update_method,
    args: @types.RequestArgs::from_values({ "report": report.to_json() }),
  }
  match client_call_uds(config, request, None) {
    Ok(response) =>
      if response.is_ok() {
        Ok(())
      } else {
        Err(response.error_message().unwrap_or("Goal update rejected"))
      }
    Err(error) => Err(error)
  }
}

///|
async fn conductor_goal_loop(project_dir : String) -> Unit {
  for ;; {
    match @exec.run_native_goal_execution_tick(project_dir) {
      Ok(@workflow.GoalExecutionTickResult::GoalExecutionTickIdle) => ()
      Ok(@workflow.GoalExecutionTickResult::GoalExecutionTickAdvanced(record)) => {
        @moontrace.info("Goal execution advanced", fields=[
          @moontrace.field("goal_id", record.goal.id.0),
          @moontrace.field("state", record.state.to_json().stringify(indent=0)),
        ])
        match @exec.inspect_native_goal(project_dir, record.goal.id) {
          Ok(report) =>
            match conductor_publish_goal_update(report) {
              Ok(_) => ()
              Err(error) =>
                @moontrace.error("Goal update delivery failed", fields=[
                  @moontrace.field("goal_id", record.goal.id.0),
                  @moontrace.field("error", error),
                ])
            }
          Err(error) =>
            @moontrace.error("Goal update projection failed", fields=[
              @moontrace.field("goal_id", record.goal.id.0),
              @moontrace.field("error", error.message()),
            ])
        }
      }
      Err(error) =>
        @moontrace.error("Goal execution tick failed", fields=[
          @moontrace.field("error", error.message()),
        ])
    }
    @async.sleep(1000)
  }
}

///|
fn conductor_start_goal_worker(
  state : ConductorServerState,
  executable : String,
) -> Result[Int, @types.ChoirError] {
  let pid = match
    @exec.spawn_native_goal_worker(executable, state.config.project_dir) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  state.goal_worker_pid = Some(pid)
  Ok(pid)
}

///|
async fn conductor_supervise_goal_worker(
  state : ConductorServerState,
  executable : String,
) -> Unit {
  for ;; {
    match state.goal_worker_pid {
      Some(pid) =>
        match @sys.child_process_state(pid) {
          @sys.ChildProcessState::ChildProcessRunning => ()
          @sys.ChildProcessState::ChildProcessExited(status) => {
            @moontrace.error("Goal worker exited", fields=[
              @moontrace.field("pid", pid),
              @moontrace.field("status", status),
            ])
            state.goal_worker_pid = None
          }
          @sys.ChildProcessState::ChildProcessUnavailable => {
            @moontrace.error("Goal worker became unavailable", fields=[
              @moontrace.field("pid", pid),
            ])
            state.goal_worker_pid = None
          }
        }
      None =>
        match conductor_start_goal_worker(state, executable) {
          Ok(pid) =>
            @moontrace.info("Goal worker restarted", fields=[
              @moontrace.field("pid", pid),
            ])
          Err(error) =>
            @moontrace.error("failed to restart Goal worker", fields=[
              @moontrace.field("error", error.message()),
            ])
        }
    }
    @async.sleep(1000)
  }
}

///|
fn goal_worker_run() -> Unit {
  let config_content = @sys.read_file(".choir/config.toml")
  let local_content = @sys.read_file(".choir/config.local.toml")
  let config = match
    @config.parse_config(config_content, local_content=Some(local_content)) {
    Ok(value) => value
    Err(error) => {
      @sys.write_stderr("choir run-goals: " + error.message() + "\n")
      @sys.exit(1)
      return
    }
  }
  ignore(@sys.set_parent_death_signal_term())
  match @exec.observe_native_goal_fencing_epoch(config.project_dir) {
    Ok(_) => ()
    Err(error) => {
      @sys.write_stderr("choir run-goals: " + error.message() + "\n")
      @sys.exit(1)
      return
    }
  }
  @moontrace.set_global_field("service", "choir-goals".to_json())
  @moontrace.set_global_field(
    "run_id",
    ("run-goals-" + @sys.get_pid().to_string()).to_json(),
  )
  let log_path = config.project_dir + "/.choir/logs/serve.log"
  @moontrace.set_subscriber(fn(event) {
    let rendered = @exec.strip_terminal_responses(event.format(color=false))
    ignore(@sys.append_file_sync(log_path, rendered + "\n"))
  })
  @moontrace.set_min_level(@moontrace.Level::Debug)
  @async.run_async_main(async fn() { conductor_goal_loop(config.project_dir) })
}

///|
/// Content digest of the Choir binary at `path`. Both `choir serve` (for the
/// running daemon) and `choir start` (for the candidate binary) derive this,
/// so upgrade staleness compares build content rather than executable paths.
fn server_executable_identity(path : String) -> String? {
  match @sys.read_file_bytes(path) {
    Some(bytes) => Some(@crypto.bytes_to_hex_string(@crypto.sha256(bytes)))
    None => None
  }
}

///|
fn serve_run() -> Unit {
  let config_content = @sys.read_file(".choir/config.toml")
  let local_content = @sys.read_file(".choir/config.local.toml")
  let parsed_config = match
    @config.parse_config(config_content, local_content=Some(local_content)) {
    Ok(value) => value
    Err(error) => {
      @sys.write_stderr("choir serve: " + error.message() + "\n")
      @sys.exit(1)
      return
    }
  }
  let config = match
    native_resolve_launch_config(parsed_config, @sys.realpath_native) {
    Ok(value) => value
    Err(error) => {
      @sys.write_stderr("choir serve: " + error + "\n")
      @sys.exit(1)
      return
    }
  }
  ignore(@sys.create_dir_all(config.project_dir + "/.choir/logs"))
  ignore(@sys.create_dir_all(config.project_dir + "/.choir/run"))
  ignore(@sys.create_dir_all(config.project_dir + "/.choir/state"))
  ignore(@sys.create_dir_all(config.project_dir + "/.choir/state/control"))
  // The instance lock must precede any runtime-artifact cleanup: a live
  // daemon holds it for its whole lifetime, so reaching the unlink below
  // proves the socket and pid file are stale rather than another daemon's.
  if !@sys.acquire_instance_lock(config.project_dir + "/.choir/run/server.lock") {
    @sys.write_stderr(
      "choir serve: another choird instance already holds this project\n",
    )
    @sys.exit(1)
    return
  }
  @sys.init_cleanup_runtime_artifacts_native()
  conductor_statusline_deactivate_cache(config.project_dir)
  @sys.write_pid_file(".choir/run/server.pid")
  @sys.register_cleanup_runtime_artifacts()
  @sys.install_crash_handlers()
  // Mint the fencing generation while holding the instance lock, before the
  // goal worker spawns: the worker observes this value, and records written
  // by older surviving processes are fenced once this generation adopts them.
  match @exec.mint_native_goal_fencing_epoch(config.project_dir) {
    Ok(_) => ()
    Err(error) => {
      @sys.write_stderr("choir serve: " + error.message() + "\n")
      @sys.exit(1)
      return
    }
  }
  let state = ConductorServerState::new(config)
  @moontrace.set_global_field("service", "choir".to_json())
  @moontrace.set_global_field("run_id", state.run_id.to_json())
  let log_path = config.project_dir + "/.choir/logs/serve.log"
  @moontrace.set_subscriber(fn(event) {
    let rendered = @exec.strip_terminal_responses(event.format(color=false))
    ignore(@sys.append_file_sync(log_path, rendered + "\n"))
  })
  @moontrace.set_min_level(@moontrace.Level::Debug)
  let executable = match @sys.realpath_native("/proc/self/exe") {
    Some(value) => value
    None => {
      @moontrace.error("failed to resolve the Choir executable")
      @sys.exit(1)
      return
    }
  }
  match server_executable_identity(executable) {
    Some(identity) => state.server_identity = identity
    None => {
      @moontrace.error("failed to fingerprint the Choir executable")
      @sys.exit(1)
      return
    }
  }
  match conductor_start_goal_worker(state, executable) {
    Ok(pid) =>
      @moontrace.info("Goal worker started", fields=[
        @moontrace.field("pid", pid),
      ])
    Err(error) => {
      @moontrace.error("failed to start Goal worker", fields=[
        @moontrace.field("error", error.message()),
      ])
      @sys.exit(1)
      return
    }
  }
  @async.run_async_main(async fn() {
    @async.with_task_group(async fn(root) {
      root.spawn_bg(async fn() {
        conductor_supervise_goal_worker(state, executable)
      })
      conductor_serve_uds(state, root)
    })
  })
}

///|
test "Conductor tokens require an exact lowercase hexadecimal capability" {
  let token = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
  assert_true(conductor_valid_bootstrap_token(token))
  assert_false(conductor_valid_bootstrap_token(token + "0"))
  assert_false(conductor_valid_bootstrap_token(token.replace(old="a", new="A")))
  assert_true(conductor_tokens_equal(token, token))
  assert_false(conductor_tokens_equal(token, token + "0"))
}

///|
test "local CLI registration requires the current Choir executable" {
  let request : @types.Request = {
    req_method: local_cli_register_method,
    name: local_cli_register_method,
    args: @types.RequestArgs::from_values(Map([])),
  }
  assert_true(local_cli_register(request, true).is_ok())
  assert_false(local_cli_register(request, false).is_ok())
  assert_false(
    local_cli_register({ ..request, req_method: "register" }, true).is_ok(),
  )
}

///|
test "Conductor strips caller identity before dispatch" {
  let request : @types.Request = {
    req_method: "tools/call",
    name: "goal_status",
    args: @types.RequestArgs::from_values({
      "goal_id": "goal-a".to_json(),
      "caller_id": "forged".to_json(),
      "agent_id": "forged".to_json(),
    }),
  }
  let effective = conductor_authenticated_request(request)
  @debug.assert_eq(effective.args.get("caller_id"), None)
  @debug.assert_eq(effective.args.get("agent_id"), None)
  @debug.assert_eq(effective.args.get("goal_id"), Some("goal-a"))
}

///|
test "Conductor parks an active durable Goal until its success event" {
  let state = ConductorServerState::new({
    project_dir: "/repo",
    listen_uds: "/repo/.choir/run/server.sock",
  })
  let submit : @types.Request = {
    req_method: "tools/call",
    name: "goal_submit",
    args: @types.RequestArgs::from_values(Map([])),
  }
  conductor_observe_goal_response(
    state,
    submit,
    @types.Response::ok_values({
      "accepted": true.to_json(),
      "execution_registered": true.to_json(),
      "goal_id": ["GoalId", "goal-a"].to_json(),
    }),
  )
  assert_eq(state.watched_goal_id, Some("goal-a"))
  assert_true(state.parked_for_goal_event)
  let status : @types.Request = {
    req_method: "tools/call",
    name: "goal_status",
    args: @types.RequestArgs::from_values({ "goal_id": "goal-a".to_json() }),
  }
  conductor_observe_goal_response(
    state,
    status,
    @types.Response::ok_values({
      "goal_id": ["GoalId", "goal-a"].to_json(),
      "state": @workflow.GoalExecutionState::GoalExecutionSucceeded.to_json(),
    }),
  )
  assert_false(state.parked_for_goal_event)
}

///|
test "Conductor channel wakes only for material Goal projection changes" {
  let running = {
    "goal_id": ["GoalId", "goal-a"].to_json(),
    "state": "GoalExecutionRunning".to_json(),
    "lifecycle": ["GoalActive", "GoalExecuting"].to_json(),
    "durable_version": (7 : Int).to_json(),
    "assurance_effect_receipt_count": (2 : Int).to_json(),
    "parts": [
      {
        "part_id": ["PartId", "part-a"].to_json(),
        "stage": "PartImplementationHarnessStarted".to_json(),
        "durable_version": (11 : Int).to_json(),
        "effect_receipt_count": (3 : Int).to_json(),
      }.to_json(),
    ].to_json(),
  }.to_json()
  let count_only = {
    "goal_id": ["GoalId", "goal-a"].to_json(),
    "state": "GoalExecutionRunning".to_json(),
    "lifecycle": ["GoalActive", "GoalExecuting"].to_json(),
    "durable_version": (8 : Int).to_json(),
    "assurance_effect_receipt_count": (9 : Int).to_json(),
    "parts": [
      {
        "part_id": ["PartId", "part-a"].to_json(),
        "stage": "PartImplementationHarnessStarted".to_json(),
        "durable_version": (12 : Int).to_json(),
        "effect_receipt_count": (8 : Int).to_json(),
      }.to_json(),
    ].to_json(),
  }.to_json()
  assert_eq(
    conductor_goal_update_fingerprint(running),
    conductor_goal_update_fingerprint(count_only),
  )
  guard count_only is Object(fields) else { fail("expected report object") }
  guard fields.get("parts") is Some(Array([Object(part)])) else {
    fail("expected one Part")
  }
  part.set("stage", "PartVerificationSandboxPrepared".to_json())
  assert_true(
    conductor_goal_update_fingerprint(running) !=
    conductor_goal_update_fingerprint(count_only),
  )
}

///|
test "Conductor replays a worker update that races Goal observation" {
  let state = ConductorServerState::new({
    project_dir: "/repo",
    listen_uds: "/repo/.choir/run/server.sock",
  })
  let report = {
    "goal_id": ["GoalId", "goal-a"].to_json(),
    "state": "GoalExecutionRunning".to_json(),
    "lifecycle": ["GoalActive", "GoalExecuting"].to_json(),
    "durable_version": (2 : Int).to_json(),
    "parts": ([] : Array[Json]).to_json(),
  }.to_json()
  conductor_broadcast_goal_update(state, report)
  assert_eq(state.last_goal_update, None)
  conductor_watch_goal(state, "goal-a")
  assert_eq(state.last_goal_update, Some(report.stringify(indent=0)))
  assert_true(state.parked_for_goal_event)
}
