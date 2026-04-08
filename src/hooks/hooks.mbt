///|
pub(all) enum HookEvent {
  SessionStart
  PreToolUse
  PostToolUse
  AgentExit
  SessionStop
  BeforeModel
  AfterModel
} derive(Debug, Eq)

///|
pub impl Show for HookEvent with output(self, logger) -> Unit {
  logger.write_string(self.hook_event_wire_name())
}

///|
pub(all) struct HookInput {
  event : HookEvent
  session_id : String?
  agent_id : String?
  role : @types.Role?
  tool_name : String?
  tool_args : Map[String, String]?
  tool_result_status : String?
  exit_reason : @types.ExitReason?
} derive(Debug)

///|
fn HookEvent::hook_event_wire_name(self : HookEvent) -> String {
  match self {
    SessionStart => "SessionStart"
    PreToolUse => "PreToolUse"
    PostToolUse => "PostToolUse"
    AgentExit => "AgentExit"
    SessionStop => "SessionStop"
    BeforeModel => "BeforeModel"
    AfterModel => "AfterModel"
  }
}

///|
fn role_wire_name(r : @types.Role) -> String {
  match r {
    Root => "root"
    TL => "tl"
    Dev => "dev"
    Worker => "worker"
  }
}

///|
pub fn HookInput::to_json_string(self : HookInput) -> String {
  let obj : Map[String, Json] = {}
  obj.set("event", self.event.hook_event_wire_name().to_json())
  match self.session_id {
    Some(v) => obj.set("session_id", v.to_json())
    None => ()
  }
  match self.agent_id {
    Some(v) => obj.set("agent_id", v.to_json())
    None => ()
  }
  match self.role {
    Some(r) => obj.set("role", role_wire_name(r).to_json())
    None => ()
  }
  match self.tool_name {
    Some(v) => obj.set("tool_name", v.to_json())
    None => ()
  }
  match self.tool_result_status {
    Some(v) => obj.set("tool_result_status", v.to_json())
    None => ()
  }
  match self.exit_reason {
    Some(v) =>
      obj.set("exit_reason", v.lifecycle_trigger().to_wire_string().to_json())
    None => ()
  }
  obj.to_json().stringify()
}

///|
pub(all) struct HookResponse {
  continue_ : Bool
  message : String?
} derive(Debug, Eq)

///|
pub impl Show for HookResponse with output(self, logger) {
  logger.write_string("HookResponse(continue_=")
  logger.write_string(self.continue_.to_string())
  match self.message {
    Some(m) => {
      logger.write_string(", message=")
      logger.write_string(m)
    }
    None => ()
  }
  logger.write_string(")")
}

///|
pub fn HookResponse::allow() -> HookResponse {
  { continue_: true, message: None }
}

///|
pub fn HookResponse::block(message : String) -> HookResponse {
  { continue_: false, message: Some(message) }
}

///|
/// Semantically distinct from allow() — used when hook execution itself fails
/// (missing WASM, parse error). Same result today; separated for future
/// differentiation (e.g., logging fail-open events differently).
pub fn HookResponse::fail_open() -> HookResponse {
  { continue_: true, message: None }
}

///|
pub fn HookResponse::to_json_string(self : HookResponse) -> String {
  let obj : Map[String, Json] = {}
  obj.set("continue", self.continue_.to_json())
  if !self.continue_ {
    match self.message {
      Some(msg) => obj.set("message", msg.to_json())
      None => ()
    }
  }
  obj.to_json().stringify()
}

///|
fn parse_json_object(line : String) -> Map[String, Json]? {
  let json = @json.parse(line) catch { _ => return None }
  guard json is Object(obj) else { return None }
  Some(obj)
}

///|
fn json_opt_string(obj : Map[String, Json], key : String) -> String? {
  match obj.get(key) {
    Some(String(s)) => Some(s)
    _ => None
  }
}

///|
pub fn HookInput::from_json_string(line : String) -> HookInput? {
  let obj = match parse_json_object(line) {
    Some(o) => o
    None => return None
  }
  let event_str = match json_opt_string(obj, "event") {
    Some(v) => v
    None => return None
  }
  let event = match event_str {
    "SessionStart" => HookEvent::SessionStart
    "PreToolUse" => HookEvent::PreToolUse
    "PostToolUse" => HookEvent::PostToolUse
    "AgentExit" => HookEvent::AgentExit
    "SessionStop" => HookEvent::SessionStop
    "BeforeModel" => HookEvent::BeforeModel
    "AfterModel" => HookEvent::AfterModel
    _ => return None
  }
  let session_id = json_opt_string(obj, "session_id")
  let agent_id = json_opt_string(obj, "agent_id")
  let role_str = json_opt_string(obj, "role")
  let role = match role_str {
    Some("root") => Some(@types.Role::Root)
    Some("tl") => Some(@types.Role::TL)
    Some("dev") => Some(@types.Role::Dev)
    Some("worker") => Some(@types.Role::Worker)
    _ => None
  }
  let tool_name = json_opt_string(obj, "tool_name")

  // Minimal support for args, as it's not strictly used for logic yet
  let tool_args = None
  let tool_result_status = json_opt_string(obj, "tool_result_status")
  let exit_reason = match json_opt_string(obj, "exit_reason") {
    Some("merged") => Some(@types.ExitReason::Merged)
    Some("disconnect") => Some(@types.ExitReason::Disconnected)
    Some("shutdown") | Some("killed") | Some("watchdog") =>
      Some(@types.ExitReason::Shutdown)
    Some(_) => Some(@types.ExitReason::Shutdown)
    None => None
  }
  Some({
    event,
    session_id,
    agent_id,
    role,
    tool_name,
    tool_args,
    tool_result_status,
    exit_reason,
  })
}

///|
pub fn HookEvent::script_name(self : HookEvent) -> String {
  match self {
    SessionStart => "session_start"
    PreToolUse => "pre_tool_use"
    PostToolUse => "post_tool_use"
    AgentExit => "agent_exit"
    SessionStop => "session_stop"
    BeforeModel => "before_model"
    AfterModel => "after_model"
  }
}

///|
pub fn HookResponse::from_json_string(line : String) -> HookResponse? {
  let obj = match parse_json_object(line) {
    Some(o) => o
    None => return None
  }
  let continue_ = match obj.get("continue") {
    Some(True) => true
    Some(False) => false
    Some(String(v)) => v == "true"
    _ => return None
  }
  let message = json_opt_string(obj, "message")
  Some({ continue_, message })
}
