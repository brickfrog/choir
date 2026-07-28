///|
priv struct ConductorServerState {
  config : @types.Config
  run_id : String
  mut conductor_token : String?
  mut statusline_cache_key : String?
  mut goal_worker_pid : Int?
  channel_fds : Array[Int]
  /// Per-channel subscriptions and per-Goal observation state. Replaces the
  /// single watched Goal id, the single cached report, and the single stall
  /// counter, all of which were Goal-scoped state kept once for the server.
  channels : @workflow.ConductorChannelRegistry
  /// Set when the Goal worker is persistently failing. The event the Stop hook
  /// waits for cannot arrive, so the park is released regardless of what the
  /// watched Goals say.
  mut goal_worker_unhealthy : Bool
  mut last_goal_worker_health : String?
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
    channels: @workflow.new_conductor_channel_registry(),
    goal_worker_unhealthy: false,
    last_goal_worker_health: None,
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
let conductor_goal_worker_health_method : String = "conductor_goal_worker_health"

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
/// Append one rendered log line, rolling the file first when it has grown past
/// its cap.
///
/// Both daemons appended to one file for the life of the workspace with no
/// bound. The Goal tick logs a failure every second while a Goal is stuck, so
/// the fastest-growing log is the one written when nobody is watching.
fn conductor_append_log_line(path : String, line : String) -> Unit {
  let plan = @command.plan_log_rotation(
    path,
    @sys.file_size(path),
    @command.default_log_rotation_policy(),
  )
  for discarded in plan.discard {
    ignore(@sys.delete_file_sync(discarded))
  }
  for step in plan.rotate {
    ignore(@sys.rename_file_sync(step.0, step.1))
  }
  ignore(@sys.append_file_sync(path, line))
}

///|
/// The level the daemons log at.
///
/// Debug was hard-coded, which is also why the file grew as fast as it did.
/// It stays the default so nothing an operator relies on disappears, but it is
/// now overridable rather than baked in.
fn conductor_log_level() -> @moontrace.Level {
  match @env.get_env_var("CHOIR_LOG_LEVEL") {
    Some("error") => @moontrace.Level::Error_
    Some("warn") => @moontrace.Level::Warn
    Some("info") => @moontrace.Level::Info
    Some("trace") => @moontrace.Level::Trace
    _ => @moontrace.Level::Debug
  }
}

///|
fn conductor_park_for_state_tag(state : String?) -> Bool {
  @workflow.conductor_park_for_goal_state(
    match state {
      Some(tag) => @workflow.parse_goal_execution_state(tag)
      None => None
    },
  )
}

///|
test "Conductor park releases on terminal states and cancellation cutoff" {
  assert_false(conductor_park_for_state_tag(Some("GoalExecutionSucceeded")))
  assert_false(conductor_park_for_state_tag(Some("GoalExecutionCanceled")))
  assert_false(conductor_park_for_state_tag(Some("GoalExecutionCanceling")))
  assert_true(conductor_park_for_state_tag(Some("GoalExecutionRunning")))
  assert_true(conductor_park_for_state_tag(None))
}

///|
/// Add a Goal to what every open channel watches.
///
/// Adding rather than replacing is the whole point: a Goal tool call used to
/// overwrite one global watched id, which silently stopped delivering every
/// other Goal. A channel that already watches this Goal is left alone, so a
/// repeated inspection replays nothing.
fn conductor_watch_goal(state : ConductorServerState, goal_id : String) -> Unit {
  let goal = @control.GoalId(goal_id)
  // Recorded on the portfolio first, so a Goal named while no channel is
  // connected is still watched by the channel that connects next.
  @workflow.conductor_note_goal_interest(state.channels, goal)
  let gained : Array[@workflow.ConductorDelivery] = []
  for fd in state.channel_fds.copy() {
    match
      @workflow.conductor_watch_goal_on_channel(
        state.channels,
        @workflow.ConductorChannelId(fd),
        goal,
      ) {
      Some(delivery) => gained.push(delivery)
      None => ()
    }
  }
  if gained.length() == 0 {
    return
  }
  match state.statusline_cache_key {
    Some(key) =>
      conductor_statusline_activate_cache(state.config.project_dir, key, None)
    None => ()
  }
  conductor_write_deliveries(state, gained)
}

///|
/// Write what the registry decided, dropping any channel whose socket is gone.
fn conductor_write_deliveries(
  state : ConductorServerState,
  deliveries : Array[@workflow.ConductorDelivery],
) -> Unit {
  for delivery in deliveries {
    let report : Json? = Some(@json.parse(delivery.report)) catch { _ => None }
    guard report is Some(value) else { continue }
    if !conductor_write_all(
        delivery.channel.0,
        @utf8.encode(conductor_goal_update_line(value)),
      ) {
      conductor_remove_channel_fd(state, delivery.channel.0)
    }
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
  match goal_id {
    Some(identity) => {
      // The response may name a state newer than the last observed report — a
      // cancellation accepted between two observations — so the park follows it
      // immediately rather than waiting for the next transition.
      @workflow.conductor_note_goal_park(
        state.channels,
        @control.GoalId(identity),
        conductor_park_for_state_tag(conductor_response_state(response)),
      )
      conductor_watch_goal(state, identity)
    }
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
fn conductor_goal_worker_health_line(
  healthy : Bool,
  consecutive_failures : Int,
  detail : String,
  goal_id : String?,
) -> String {
  let health : Map[String, Json] = {
    "healthy": healthy.to_json(),
    "consecutive_failures": consecutive_failures.to_json(),
    "detail": detail.to_json(),
  }
  match goal_id {
    Some(identity) => health.set("goal_id", identity.to_json())
    None => ()
  }
  {
    "method": "choir/goal_worker_health_changed".to_json(),
    "health": health.to_json(),
  }
  .to_json()
  .stringify(indent=0) +
  "\n"
}

///|
/// One Goal id to name in a server-wide event. The watched set is no longer a
/// singleton, so a health event that concerns the worker rather than any one
/// Goal names the first watched Goal in deterministic order, or none.
/// Whether the Conductor's Stop hook should park.
///
/// The park follows every watched Goal, not the one most recently inspected: a
/// terminal child must not release a Conductor whose siblings are still
/// running. A persistently failing worker releases it regardless, because the
/// event being waited on cannot arrive.
fn conductor_stop_decision_parks(state : ConductorServerState) -> Bool {
  !state.goal_worker_unhealthy &&
  @workflow.conductor_registry_parks(state.channels)
}

///|
fn conductor_first_watched_report(state : ConductorServerState) -> String? {
  match @workflow.conductor_watched_goals(state.channels) {
    [first, ..] => @workflow.conductor_goal_report(state.channels, first)
    [] => None
  }
}

///|
fn conductor_reported_goal_id(state : ConductorServerState) -> String? {
  match @workflow.conductor_watched_goals(state.channels) {
    [first, ..] => Some(first.0)
    [] => None
  }
}

///|
fn conductor_remove_channel_fd(state : ConductorServerState, fd : Int) -> Unit {
  @workflow.conductor_release_channel(
    state.channels,
    @workflow.ConductorChannelId(fd),
  )
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
/// Decode a wire report into the typed projection input. The worker
/// serializes `@workflow.GoalStatusReport`, so failure here means version
/// skew or corruption; callers fall back conservatively.
fn conductor_typed_goal_report(report : Json) -> @workflow.GoalStatusReport? {
  let decoded : @workflow.GoalStatusReport = @json.from_json(report) catch {
    _ => return None
  }
  Some(decoded)
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
  let typed = conductor_typed_goal_report(report)
  let fingerprint = match typed {
    Some(value) => @workflow.goal_report_material_fingerprint(value)
    // Undecodable reports are always material and keep the park unchanged.
    None => serialized
  }
  let parks = match typed {
    Some(value) => @workflow.conductor_park_for_goal_state(Some(value.state))
    None => true
  }
  // The registry caches every Goal it is told about, watched or not. The Goal
  // worker can win a race with goal_submit's response, and watching that Goal
  // afterwards must replay the transition that already happened rather than
  // sleeping until a later one.
  let deliveries = @workflow.conductor_observe_goal(
    state.channels,
    @control.GoalId(identity),
    fingerprint,
    serialized,
    parks,
  )
  if deliveries.length() == 0 {
    return
  }
  match state.statusline_cache_key {
    Some(key) =>
      conductor_statusline_update_cache(state.config.project_dir, key, report)
    None => ()
  }
  conductor_write_deliveries(state, deliveries)
}

///|
fn conductor_broadcast_goal_worker_health(
  state : ConductorServerState,
  healthy : Bool,
  consecutive_failures : Int,
  detail : String,
) -> Unit {
  let line = conductor_goal_worker_health_line(
    healthy,
    consecutive_failures,
    detail,
    conductor_reported_goal_id(state),
  )
  state.last_goal_worker_health = Some(line)
  // A persistent worker failure means the event the Stop hook is waiting for
  // cannot arrive. Release the park instead of trapping the Conductor in
  // repeated Stop-hook turns; recovery restores it.
  state.goal_worker_unhealthy = !healthy
  let wire = @utf8.encode(line)
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
  if request.req_method != @types.WireMethod::WireConductorBootstrap ||
    request.name != conductor_bootstrap_method ||
    !peer_is_choir {
    return @types.Response::err_text(
      "Conductor bootstrap authentication failed",
    )
  }
  let token = request.args.get(@types.registration_token_arg).unwrap_or("")
  let statusline_cache_key = request.args
    .get("statusline_cache_key")
    .unwrap_or("")
  if !conductor_valid_bootstrap_token(token) ||
    !conductor_statusline_cache_key_valid(statusline_cache_key) {
    return @types.Response::err_text(
      "Conductor bootstrap authentication failed",
    )
  }
  state.conductor_token = Some(token)
  state.statusline_cache_key = Some(statusline_cache_key)
  // The statusline shows one Goal, so it is seeded from the first watched Goal
  // in deterministic order rather than from whichever was inspected last.
  let latest_report : Json? = match conductor_first_watched_report(state) {
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
  if request.req_method != @types.WireMethod::WireRegister || presented == "" {
    return @types.Response::err_text(
      "Conductor registration authentication failed",
    )
  }
  let stored = match state.conductor_token {
    Some(token) => token
    None =>
      return @types.Response::err_text(
        "Conductor credential not provisioned; run `choir start`",
      )
  }
  if !conductor_tokens_equal(presented, stored) {
    return @types.Response::err_text(
      "Conductor registration authentication failed",
    )
  }
  @types.Response::ok_values(Map([]))
}

///|
fn local_cli_register(
  request : @types.Request,
  peer_is_choir : Bool,
) -> @types.Response {
  if request.req_method != @types.WireMethod::WireLocalCliRegister ||
    request.name != local_cli_register_method ||
    !peer_is_choir {
    @types.Response::err_text("local CLI authentication failed")
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
    req_method: @types.WireMethod::WireToolsCall,
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
      @types.Response::err_text("internal error: " + error.to_string())
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
  if request.req_method == @types.WireMethod::WireServerIdentity {
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
  if request.req_method == @types.WireMethod::WireConductorBootstrap {
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
  if request.req_method == @types.WireMethod::WireRegister {
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
      // A reconnect arrives on a new descriptor with no subscription of its
      // own, so it resumes watching everything currently watched and is shown
      // each of those Goals' latest state. Without this the Conductor sleeps
      // forever waiting for events that preceded the new connection.
      let channel_id = @workflow.ConductorChannelId(client.fd)
      @workflow.conductor_subscribe_channel(
        state.channels,
        channel_id,
        @workflow.conductor_watched_goals(state.channels),
      )
      let replay = @workflow.conductor_replay_channel(
        state.channels,
        channel_id,
      )
      if replay.length() > 0 {
        conductor_write_deliveries(state, replay)
        if !state.channel_fds.contains(client.fd) {
          client.close_after_response = true
        }
      }
      match state.last_goal_worker_health {
        Some(line) =>
          if !conductor_write_all(client.fd, @utf8.encode(line)) {
            conductor_remove_channel_fd(state, client.fd)
            client.close_after_response = true
          }
        None => ()
      }
    }
    client.busy = false
    return
  }
  if request.req_method == @types.WireMethod::WireLocalCliRegister {
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
  if request.req_method == @types.WireMethod::WireConductorGoalUpdate {
    let response = if client.authenticated && client.peer_is_choir {
      match request.args.get_json("report") {
        Some(report) => {
          conductor_broadcast_goal_update(state, report)
          @types.Response::ok_values(Map([]))
        }
        None => @types.Response::err_text("Goal update report is absent")
      }
    } else {
      @types.Response::err_text("Goal update authentication failed")
    }
    ignore(conductor_send_response(client.fd, response))
    client.busy = false
    return
  }
  if request.req_method == @types.WireMethod::WireConductorGoalWorkerHealth {
    let response = if client.authenticated && client.peer_is_choir {
      match
        (
          request.args.get_bool("healthy"),
          request.args.get_int("consecutive_failures"),
          request.args.get("detail"),
        ) {
        (Some(healthy), Some(consecutive_failures), Some(detail)) => {
          conductor_broadcast_goal_worker_health(
            state, healthy, consecutive_failures, detail,
          )
          @types.Response::ok_values(Map([]))
        }
        _ =>
          @types.Response::err_text("Goal worker health report is incomplete")
      }
    } else {
      @types.Response::err_text("Goal worker health authentication failed")
    }
    ignore(conductor_send_response(client.fd, response))
    client.busy = false
    return
  }
  if request.req_method == @types.WireMethod::WireConductorStopDecision {
    let response = if client.authenticated {
      let fields : Map[String, Json] = {
        "park": conductor_stop_decision_parks(state).to_json(),
      }
      match conductor_reported_goal_id(state) {
        Some(identity) => fields.set("goal_id", identity.to_json())
        None => ()
      }
      @types.Response::ok_values(fields)
    } else {
      @types.Response::err_text("authenticated Conductor required")
    }
    ignore(conductor_send_response(client.fd, response))
    client.busy = false
    return
  }
  let response = if client.authenticated {
    conductor_dispatch(state, request)
  } else {
    @types.Response::err_text("authenticated Conductor required")
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
              @types.Response::err_text("authenticated Conductor required")
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
              @types.Response::err_text("parse error: " + error),
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
    req_method: @types.WireMethod::WireConductorGoalUpdate,
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
fn conductor_publish_goal_worker_health(
  healthy : Bool,
  consecutive_failures : Int,
  detail : String,
) -> Result[Unit, String] {
  let config = match goal_client_load_config() {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let request : @types.Request = {
    req_method: @types.WireMethod::WireConductorGoalWorkerHealth,
    name: conductor_goal_worker_health_method,
    args: @types.RequestArgs::from_values({
      "healthy": healthy.to_json(),
      "consecutive_failures": consecutive_failures.to_json(),
      "detail": detail.to_json(),
    }),
  }
  match client_call_uds(config, request, None) {
    Ok(response) =>
      if response.is_ok() {
        Ok(())
      } else {
        Err(response.error_message().unwrap_or("Goal worker health rejected"))
      }
    Err(error) => Err(error)
  }
}

///|
/// Project durable Goal state on its own cadence.
///
/// The execute loop only projects when a tick returns, and a tick runs a
/// provider Take inline, so a Goal can advance through several Part stages
/// with nothing reaching the Conductor. This observes the same durable
/// records the tick writes and publishes them; the server drops any report
/// whose material fingerprint is unchanged, so an idle Goal emits nothing.
async fn conductor_goal_observer(project_dir : String) -> Unit {
  for ;; {
    let active = match @exec.list_native_active_goal_ids(project_dir) {
      Ok(value) => value
      Err(_) => []
    }
    for goal_id in active {
      match @exec.inspect_native_goal(project_dir, goal_id) {
        Ok(report) => ignore(conductor_publish_goal_update(report))
        Err(_) => ()
      }
    }
    @async.sleep(@workflow.goal_observation_interval_ms(active.length()))
  }
}

///|
async fn conductor_goal_loop(config : @types.Config) -> Unit {
  let mut consecutive_failures = 0
  // A Goal whose ticks succeed while advancing nothing looks identical to one
  // that is working. Track the durable version the last advance reported so a
  // run of ticks that changes nothing is reported instead of staying silent.
  let mut ticks_without_progress = 0
  let mut last_progress = ""
  for ;; {
    match
      @exec.run_native_goal_execution_tick(
        config.project_dir,
        pull_request_delivery=config.pull_request_delivery,
        provider_capacity=config.provider_capacity,
      ) {
      Ok(@workflow.GoalExecutionTickResult::GoalExecutionTickIdle) => {
        if @workflow.goal_execution_tick_failure_is_persistent(
            consecutive_failures,
          ) {
          match
            conductor_publish_goal_worker_health(
              true, 0, "Goal execution ticks recovered",
            ) {
            Ok(_) => ()
            Err(error) =>
              @moontrace.error("Goal worker recovery delivery failed", fields=[
                @moontrace.field("error", error),
              ])
          }
        }
        consecutive_failures = 0
      }
      Ok(@workflow.GoalExecutionTickResult::GoalExecutionTickAdvanced(record)) => {
        if @workflow.goal_execution_tick_failure_is_persistent(
            consecutive_failures,
          ) {
          match
            conductor_publish_goal_worker_health(
              true, 0, "Goal execution ticks recovered",
            ) {
            Ok(_) => ()
            Err(error) =>
              @moontrace.error("Goal worker recovery delivery failed", fields=[
                @moontrace.field("error", error),
              ])
          }
        }
        consecutive_failures = 0
        let progress = record.goal.id.0 +
          "@" +
          record.durable_version.to_string()
        if progress == last_progress {
          ticks_without_progress = ticks_without_progress + 1
          if @workflow.goal_execution_tick_stall_is_reportable(
              ticks_without_progress,
            ) {
            @moontrace.error("Goal execution is not advancing", fields=[
              @moontrace.field("goal_id", record.goal.id.0),
              @moontrace.field(
                "durable_version",
                record.durable_version.to_string(),
              ),
              @moontrace.field(
                "ticks_without_progress",
                ticks_without_progress.to_string(),
              ),
            ])
          }
        } else {
          ticks_without_progress = 0
          last_progress = progress
        }
        @moontrace.info("Goal execution advanced", fields=[
          @moontrace.field("goal_id", record.goal.id.0),
          @moontrace.field("state", record.state.to_json().stringify(indent=0)),
        ])
        match @exec.inspect_native_goal(config.project_dir, record.goal.id) {
          Ok(report) => {
            match @workflow.goal_report_attention_summary(report) {
              Some(summary) =>
                @moontrace.error("Goal needs attention", fields=[
                  @moontrace.field("goal_id", record.goal.id.0),
                  @moontrace.field(
                    "state",
                    record.state.to_json().stringify(indent=0),
                  ),
                  @moontrace.field("cause", summary),
                ])
              None => ()
            }
            match conductor_publish_goal_update(report) {
              Ok(_) => ()
              Err(error) =>
                @moontrace.error("Goal update delivery failed", fields=[
                  @moontrace.field("goal_id", record.goal.id.0),
                  @moontrace.field("error", error),
                ])
            }
          }
          Err(error) =>
            @moontrace.error("Goal update projection failed", fields=[
              @moontrace.field("goal_id", record.goal.id.0),
              @moontrace.field("error", error.message()),
            ])
        }
      }
      Err(error) => {
        consecutive_failures = consecutive_failures + 1
        let error_message = error.message()
        if @workflow.goal_execution_tick_failure_should_notify(
            consecutive_failures,
          ) {
          match
            conductor_publish_goal_worker_health(
              false, consecutive_failures, error_message,
            ) {
            Ok(_) => ()
            Err(delivery_error) =>
              @moontrace.error("Goal worker health delivery failed", fields=[
                @moontrace.field("error", delivery_error),
              ])
          }
        }
        // A tick that keeps failing is a Goal that is not advancing. Report the
        // run of failures, not just the latest one, so a standing stall is
        // distinguishable from a passing error in the log.
        if @workflow.goal_execution_tick_failure_is_persistent(
            consecutive_failures,
          ) {
          @moontrace.error("Goal execution is not advancing", fields=[
            @moontrace.field("error", error_message),
            @moontrace.field(
              "consecutive_failures",
              consecutive_failures.to_string(),
            ),
          ])
        } else {
          @moontrace.error("Goal execution tick failed", fields=[
            @moontrace.field("error", error_message),
          ])
        }
      }
    }
    // A tick that a provider capacity bound refused knows when a slot could
    // free. Waiting for that instant is the difference between a scheduled
    // wake and a spin against a full surface.
    @async.sleep(
      @workflow.goal_execution_tick_delay_ms_with_deferral(
        consecutive_failures,
        @exec.native_goal_provider_deferral(),
        @env.now().reinterpret_as_int64() / 1000L,
      ),
    )
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
  // A worker that dies during startup — an unreadable config, a missing
  // dependency — dies again the instant it is respawned. Restarting it
  // unconditionally every second turns that into a fork/exec loop whose only
  // trace is a log line per second, so respawns share the tick's backoff.
  let mut consecutive_restarts = 0
  for ;; {
    match state.goal_worker_pid {
      Some(pid) =>
        match @sys.child_process_state(pid) {
          @sys.ChildProcessState::ChildProcessRunning =>
            consecutive_restarts = 0
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
      None => {
        consecutive_restarts = consecutive_restarts + 1
        match conductor_start_goal_worker(state, executable) {
          Ok(pid) =>
            if @workflow.goal_execution_tick_failure_is_persistent(
                consecutive_restarts,
              ) {
              @moontrace.error("Goal worker keeps exiting", fields=[
                @moontrace.field("pid", pid),
                @moontrace.field(
                  "consecutive_restarts",
                  consecutive_restarts.to_string(),
                ),
              ])
            } else {
              @moontrace.info("Goal worker restarted", fields=[
                @moontrace.field("pid", pid),
              ])
            }
          Err(error) =>
            @moontrace.error("failed to restart Goal worker", fields=[
              @moontrace.field("error", error.message()),
            ])
        }
      }
    }
    @async.sleep(@workflow.goal_execution_tick_delay_ms(consecutive_restarts))
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
    conductor_append_log_line(log_path, rendered + "\n")
  })
  @moontrace.set_min_level(conductor_log_level())
  @async.run_async_main(async fn() {
    @async.with_task_group(async fn(group) {
      group.spawn_bg(async fn() { conductor_goal_observer(config.project_dir) })
      conductor_goal_loop(config)
    })
  })
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
  let control_state_prepared = Ref(false)
  @async.run_async_main(async fn() {
    match @exec.prepare_native_goal_control_state(config.project_dir) {
      Ok(
        @exec.NativeGoalControlStatePreparation::NativeGoalControlStateReset(
          report
        )
      ) => {
        // The reason travels with the report so the one message about a
        // destroyed control root names the evidence that authorized it.
        @sys.write_stdout(
          "Choir reset stale control state and released \{report.source_claims_released} Bead claim(s): \{report.reason.to_json().stringify(indent=0)}\n",
        )
        control_state_prepared.val = true
      }
      Ok(_) => control_state_prepared.val = true
      Err(error) =>
        @sys.write_stderr(
          "choir serve: failed to prepare Goal control state: " +
          error.message() +
          "\n",
        )
    }
    if control_state_prepared.val {
      // Runtime roots outlive the Goals that made them. Reclaiming here means
      // an abandoned Goal costs one restart of disk, not a reboot.
      match @exec.reclaim_native_goal_runtime_roots(config.project_dir) {
        Ok(0) => ()
        Ok(removed) =>
          @sys.write_stdout(
            "Choir reclaimed \{removed} abandoned Goal runtime root(s).\n",
          )
        Err(error) =>
          @moontrace.error("Goal runtime reclaim failed", fields=[
            @moontrace.field("error", error.message()),
          ])
      }
    }
  })
  if !control_state_prepared.val {
    @sys.exit(1)
    return
  }
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
    conductor_append_log_line(log_path, rendered + "\n")
  })
  @moontrace.set_min_level(conductor_log_level())
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
    req_method: @types.WireMethod::WireLocalCliRegister,
    name: local_cli_register_method,
    args: @types.RequestArgs::from_values(Map([])),
  }
  assert_true(local_cli_register(request, true).is_ok())
  assert_false(local_cli_register(request, false).is_ok())
  assert_false(
    local_cli_register(
      { ..request, req_method: @types.WireMethod::WireRegister },
      true,
    ).is_ok(),
  )
}

///|
test "Conductor strips caller identity before dispatch" {
  let request : @types.Request = {
    req_method: @types.WireMethod::WireToolsCall,
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
    ..@types.Config::default(),
    project_dir: "/repo",
    listen_uds: "/repo/.choir/run/server.sock",
  })
  let submit : @types.Request = {
    req_method: @types.WireMethod::WireToolsCall,
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
  // The response's Goal is now watched by name, and it parks.
  @debug.assert_eq(@workflow.conductor_watched_goals(state.channels), [
    @control.GoalId("goal-a"),
  ])
  assert_true(conductor_stop_decision_parks(state))
  let status : @types.Request = {
    req_method: @types.WireMethod::WireToolsCall,
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
  assert_false(conductor_stop_decision_parks(state))
}

///|
test "persistent Goal worker failure releases the Conductor park" {
  let state = ConductorServerState::new({
    ..@types.Config::default(),
    project_dir: "/repo",
    listen_uds: "/repo/.choir/run/server.sock",
  })
  @workflow.conductor_subscribe_channel(
    state.channels,
    @workflow.ConductorChannelId(7),
    [@control.GoalId("goal-a")],
  )
  assert_true(conductor_stop_decision_parks(state))
  conductor_broadcast_goal_worker_health(
    state, false, 5, "record has the wrong schema",
  )
  // The event the hook waits for cannot arrive while the worker is failing.
  assert_false(conductor_stop_decision_parks(state))
  let line = state.last_goal_worker_health.unwrap()
  assert_true(line.contains("choir/goal_worker_health_changed"))
  assert_true(line.contains("\"goal_id\":\"goal-a\""))
  assert_true(line.contains("\"consecutive_failures\":5"))
}

///|
test "Conductor replays a worker update that races Goal observation" {
  let state = ConductorServerState::new({
    ..@types.Config::default(),
    project_dir: "/repo",
    listen_uds: "/repo/.choir/run/server.sock",
  })
  let report = conductor_statusline_test_report("GoalExecutionRunning", 1, [])
  // The worker publishes before anyone watches the Goal.
  conductor_broadcast_goal_update(state, report)
  @workflow.conductor_subscribe_channel(
    state.channels,
    @workflow.ConductorChannelId(9),
    [@control.GoalId("goal-a")],
  )
  // The transition that already happened is available to replay rather than
  // lost, so the Conductor does not sleep waiting for a later one.
  @debug.assert_eq(
    @workflow.conductor_replay_channel(
      state.channels,
      @workflow.ConductorChannelId(9),
    ),
    [
      {
        channel: @workflow.ConductorChannelId(9),
        report: report.stringify(indent=0),
      },
    ],
  )
  assert_true(conductor_stop_decision_parks(state))
}

///|
/// Rotation applied to a real file, because the ordering that makes it safe is
/// only half the problem: the renames also have to actually happen, and the
/// live file has to come back afterwards.
test "the daemon log rolls and keeps a bounded set of generations" {
  let path = "/tmp/choir-log-rotation-test-" +
    @sys.get_pid().to_string() +
    ".log"
  let generations = @command.default_log_rotation_policy().retained_generations
  ignore(@sys.delete_file_sync(path))
  for index = 1; index <= generations + 1; index = index + 1 {
    ignore(@sys.delete_file_sync(@command.log_generation_path(path, index)))
  }
  // Under the cap: appended in place, nothing rolled.
  conductor_append_log_line(path, "first\n")
  assert_eq(@sys.read_file(path), "first\n")
  assert_false(@sys.path_exists(@command.log_generation_path(path, 1)))

  // Past the cap: the live file becomes generation 1 and a fresh one starts.
  let bulk = "x".repeat(@command.default_log_rotation_policy().maximum_bytes)
  ignore(@sys.write_file_sync(path, bulk))
  conductor_append_log_line(path, "second\n")
  assert_eq(@sys.read_file(path), "second\n")
  assert_eq(
    @sys.file_size(@command.log_generation_path(path, 1)),
    bulk.length(),
  )

  // Rolling repeatedly never grows the set past what the policy retains.
  for round = 0; round < generations + 3; round = round + 1 {
    ignore(@sys.write_file_sync(path, bulk))
    conductor_append_log_line(path, "round\n")
  }
  assert_false(
    @sys.path_exists(@command.log_generation_path(path, generations + 1)),
  )
  assert_true(@sys.path_exists(@command.log_generation_path(path, generations)))
  ignore(@sys.delete_file_sync(path))
  for index = 1; index <= generations + 1; index = index + 1 {
    ignore(@sys.delete_file_sync(@command.log_generation_path(path, index)))
  }
}
