///|
/// Extract the string view used by text-valued wire callers.
/// String → inner text (unquoted), everything else → .stringify().
fn json_to_wire_string(json : Json) -> String {
  match json {
    String(s) => s
    _ => json.stringify()
  }
}

///|
/// JSON object field bag used on the internal wire (request args and ok-payload fields).
pub(all) struct FieldMap {
  values : Map[String, Json]
} derive(Eq)

///|
pub type RequestArgs = FieldMap

///|
pub type ResponseFields = FieldMap

///|
pub fn FieldMap::new(values : Map[String, String]) -> FieldMap {
  let converted : Map[String, Json] = Map([])
  values.each(fn(k, v) { converted.set(k, v.to_json()) })
  { values: converted }
}

///|
pub fn FieldMap::from_values(values : Map[String, Json]) -> FieldMap {
  { values, }
}

///|
pub fn FieldMap::get(self : FieldMap, key : String) -> String? {
  match self.values.get(key) {
    Some(value) => Some(json_to_wire_string(value))
    None => None
  }
}

///|
pub fn FieldMap::get_json(self : FieldMap, key : String) -> Json? {
  self.values.get(key)
}

///|
pub fn FieldMap::get_int(self : FieldMap, key : String) -> Int? {
  match self.values.get(key) {
    Some(Number(n, ..)) => Some(n.to_int())
    _ => None
  }
}

///|
pub fn FieldMap::get_bool(self : FieldMap, key : String) -> Bool? {
  match self.values.get(key) {
    Some(True) => Some(true)
    Some(False) => Some(false)
    _ => None
  }
}

///|
pub fn FieldMap::contains(self : FieldMap, key : String) -> Bool {
  self.values.contains(key)
}

///|
pub fn FieldMap::each(self : FieldMap, f : (String, String) -> Unit) -> Unit {
  self.values.each(fn(k, v) { f(k, json_to_wire_string(v)) })
}

///|
pub fn FieldMap::each_json(self : FieldMap, f : (String, Json) -> Unit) -> Unit {
  self.values.each(f)
}

///|
pub fn FieldMap::to_map(self : FieldMap) -> Map[String, String] {
  let converted : Map[String, String] = Map([])
  self.values.each(fn(k, v) { converted.set(k, json_to_wire_string(v)) })
  converted
}

///|
pub fn FieldMap::to_json_map(self : FieldMap) -> Map[String, Json] {
  self.values
}

///|
pub let registration_token_arg : String = "token"

///|
/// The closed set of methods the internal wire accepts. Dispatching on a raw
/// string meant a typo produced a silent fallthrough instead of a compile
/// error, and the daemon's dispatch chain could not be checked for coverage.
pub(all) enum WireMethod {
  WireRegister
  WireConductorBootstrap
  WireLocalCliRegister
  WireConductorGoalUpdate
  WireConductorGoalWorkerHealth
  WireConductorStopDecision
  WireServerIdentity
  WireInitialize
  WireToolsList
  WireToolsCall
  /// What an unrecognized peer asked for, retained verbatim so the rejection
  /// can name it instead of reporting a generic parse failure.
  WireUnknownMethod(String)
} derive(Debug, Eq)

///|
pub fn wire_method_text(value : WireMethod) -> String {
  match value {
    WireRegister => "register"
    WireConductorBootstrap => "conductor_bootstrap"
    WireLocalCliRegister => "local_cli_register"
    WireConductorGoalUpdate => "conductor_goal_update"
    WireConductorGoalWorkerHealth => "conductor_goal_worker_health"
    WireConductorStopDecision => "conductor_stop_decision"
    WireServerIdentity => "server_identity"
    WireInitialize => "initialize"
    WireToolsList => "tools/list"
    WireToolsCall => "tools/call"
    WireUnknownMethod(value) => value
  }
}

///|
/// Parse the method once, at the wire boundary.
pub fn wire_method_from_text(text : String) -> WireMethod {
  match text {
    "register" => WireRegister
    "conductor_bootstrap" => WireConductorBootstrap
    "local_cli_register" => WireLocalCliRegister
    "conductor_goal_update" => WireConductorGoalUpdate
    "conductor_goal_worker_health" => WireConductorGoalWorkerHealth
    "conductor_stop_decision" => WireConductorStopDecision
    "server_identity" => WireServerIdentity
    "initialize" => WireInitialize
    "tools/list" => WireToolsList
    "tools/call" => WireToolsCall
    _ => WireUnknownMethod(text)
  }
}

///|
/// Internal wire format request (UDS, not MCP JSON-RPC).
pub(all) struct Request {
  req_method : WireMethod
  name : String
  args : RequestArgs
} derive(Eq)

///|
pub fn Request::registration_token(self : Request) -> String? {
  if self.req_method == WireMethod::WireRegister {
    self.args.get(registration_token_arg)
  } else {
    None
  }
}

///|
/// The closed taxonomy that crosses the internal wire. `ChoirError` already
/// classifies every failure; without this the classification stopped at the
/// daemon boundary and clients could only display opaque prose.
pub(all) enum WireErrorCode {
  WireAgentNotFound
  WireToolNotFound
  WirePermissionDenied
  WirePolicyBlocked
  WireProviderProtocolViolation
  WireEventIngestionOverflow
  WireProviderProcessLost
  WireValidationError
  WireTimeout
  WireCanceled
  WireWorkspaceError
  WireTransportError
  WireGitError
  WireConfigError
  WireCommandPreparationBlocked
  /// A peer sent an error this build does not classify. Kept distinct so an
  /// unrecognized code is never silently read as a known one.
  WireUnclassifiedError
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct WireError {
  code : WireErrorCode
  message : String
} derive(Debug, Eq)

///|
/// Internal wire format response.
pub(all) enum Response {
  Ok(ResponseFields)
  Err(WireError)
} derive(Eq)

///|
pub fn wire_error_code_text(code : WireErrorCode) -> String {
  match code {
    WireAgentNotFound => "agent_not_found"
    WireToolNotFound => "tool_not_found"
    WirePermissionDenied => "permission_denied"
    WirePolicyBlocked => "policy_blocked"
    WireProviderProtocolViolation => "provider_protocol_violation"
    WireEventIngestionOverflow => "event_ingestion_overflow"
    WireProviderProcessLost => "provider_process_lost"
    WireValidationError => "validation_error"
    WireTimeout => "timeout"
    WireCanceled => "canceled"
    WireWorkspaceError => "workspace_error"
    WireTransportError => "transport_error"
    WireGitError => "git_error"
    WireConfigError => "config_error"
    WireCommandPreparationBlocked => "command_preparation_blocked"
    WireUnclassifiedError => "unclassified_error"
  }
}

///|
pub fn wire_error_code_from_text(text : String) -> WireErrorCode {
  match text {
    "agent_not_found" => WireAgentNotFound
    "tool_not_found" => WireToolNotFound
    "permission_denied" => WirePermissionDenied
    "policy_blocked" => WirePolicyBlocked
    "provider_protocol_violation" => WireProviderProtocolViolation
    "event_ingestion_overflow" => WireEventIngestionOverflow
    "provider_process_lost" => WireProviderProcessLost
    "validation_error" => WireValidationError
    "timeout" => WireTimeout
    "canceled" => WireCanceled
    "workspace_error" => WireWorkspaceError
    "transport_error" => WireTransportError
    "git_error" => WireGitError
    "config_error" => WireConfigError
    "command_preparation_blocked" => WireCommandPreparationBlocked
    _ => WireUnclassifiedError
  }
}

///|
/// Carry a classified failure across the wire with its taxonomy intact.
pub fn Response::err(error : ChoirError) -> Response {
  Err({
    code: wire_error_code_from_text(error.to_wire_string()),
    message: error.message(),
  })
}

///|
/// A failure raised at the wire boundary itself, before any `ChoirError`
/// exists: a malformed request, a missing capability, a usage rejection.
pub fn Response::err_text(message : String) -> Response {
  Err({ code: WireValidationError, message })
}

///|
pub fn Response::error_code(self : Response) -> WireErrorCode? {
  match self {
    Ok(_) => None
    Err(error) => Some(error.code)
  }
}

///|
/// Whether the peer classified this failure as worth another attempt rather
/// than as a decision the caller must change something to satisfy.
pub fn Response::error_is_retryable(self : Response) -> Bool {
  match self.error_code() {
    Some(WireTransportError)
    | Some(WireTimeout)
    | Some(WireProviderProcessLost)
    | Some(WireEventIngestionOverflow) => true
    _ => false
  }
}

///|
pub fn Response::ok(self : Map[String, String]) -> Response {
  Ok(FieldMap::new(self))
}

///|
pub fn Response::ok_values(self : Map[String, Json]) -> Response {
  Ok(FieldMap::from_values(self))
}

///|
pub fn Response::ok_payload(self : Response) -> ResponseFields? {
  match self {
    Ok(fields) => Some(fields)
    Err(_) => None
  }
}

///|
pub fn Response::ok_fields(self : Response) -> Map[String, String]? {
  match self.ok_payload() {
    Some(fields) => Some(fields.to_map())
    None => None
  }
}

///|
pub fn Response::ok_field(self : Response, key : String) -> String? {
  match self.ok_payload() {
    Some(fields) => fields.get(key)
    None => None
  }
}

///|
pub fn Response::is_ok(self : Response) -> Bool {
  match self {
    Ok(_) => true
    Err(_) => false
  }
}

///|
pub fn Response::error_message(self : Response) -> String? {
  match self {
    Ok(_) => None
    Err(error) => Some(error.message)
  }
}

///|
pub fn Response::status_tag(self : Response) -> String {
  if self.is_ok() {
    "ok"
  } else {
    "error"
  }
}
