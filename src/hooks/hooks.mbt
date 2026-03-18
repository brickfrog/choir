///|
pub(all) enum HookEvent {
  SessionStart
  PreToolUse
} derive(Show, Eq)

///|
pub(all) struct HookInput {
  event : HookEvent
  agent_id : String?
  role : @types.Role?
  tool_name : String?
  tool_args : Map[String, String]?
} derive(Show)

///|
pub(all) struct HookResponse {
  continue_ : Bool
  message : String?
} derive(Show, Eq)

///|
pub fn HookResponse::allow() -> HookResponse {
  { continue_: true, message: None }
}

///|
pub fn HookResponse::block(message : String) -> HookResponse {
  { continue_: false, message: Some(message) }
}

///|
pub fn HookResponse::fail_open() -> HookResponse {
  { continue_: true, message: None }
}

///|
pub fn HookResponse::to_json_string(self : HookResponse) -> String {
  if self.continue_ {
    "{\"continue\":true}"
  } else {
    match self.message {
      Some(msg) => "{\"continue\":false,\"message\":\"" + msg + "\"}"
      None => "{\"continue\":false}"
    }
  }
}
