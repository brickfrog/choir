///|
pub(all) enum HookEvent {
  SessionStart
  PreToolUse
} derive(Show, Eq)

///|
pub(all) struct HookInput {
  event : HookEvent
  session_id : String?
  agent_id : String?
  role : @types.Role?
  tool_name : String?
  tool_args : Map[String, String]?
} derive(Show)

///|
pub fn HookInput::to_json_string(self : HookInput) -> String {
  let buf = StringBuilder::new()
  buf.write_string("{\"event\":\"")
  match self.event {
    SessionStart => buf.write_string("SessionStart")
    PreToolUse => buf.write_string("PreToolUse")
  }
  buf.write_string("\"")
  match self.session_id {
    Some(v) => {
      buf.write_string(",\"session_id\":\"")
      buf.write_string(v)
      buf.write_string("\"")
    }
    None => ()
  }
  match self.agent_id {
    Some(v) => {
      buf.write_string(",\"agent_id\":\"")
      buf.write_string(v)
      buf.write_string("\"")
    }
    None => ()
  }
  match self.role {
    Some(r) => {
      buf.write_string(",\"role\":\"")
      match r {
        Root => buf.write_string("root")
        TL => buf.write_string("tl")
        Dev => buf.write_string("dev")
        Worker => buf.write_string("worker")
      }
      buf.write_string("\"")
    }
    None => ()
  }
  match self.tool_name {
    Some(v) => {
      buf.write_string(",\"tool_name\":\"")
      buf.write_string(v)
      buf.write_string("\"")
    }
    None => ()
  }
  // Simplified tool_args serialization as it's not strictly required by the prompt
  // but good to have if we want to follow the schema.
  buf.write_string("}")
  buf.to_string()
}

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

///|
fn find_substring(s : String, sub : String, start : Int) -> Int {
  if sub.length() == 0 {
    return start
  }
  if start >= s.length() {
    return -1
  }
  for i = start; i <= s.length() - sub.length(); i = i + 1 {
    let mut is_match = true
    for j = 0; j < sub.length(); j = j + 1 {
      if s[i + j] != sub[j] {
        is_match = false
        break
      }
    }
    if is_match {
      return i
    }
  }
  -1
}

///|
fn get_string_value(json : String, key : String) -> String? {
  let key_pattern = "\"" + key + "\":\""
  let i = find_substring(json, key_pattern, 0)
  if i == -1 {
    None
  } else {
    let start = i + key_pattern.length()
    let mut end = start
    while end < json.length() {
      if json[end] == '"' && (end == 0 || json[end - 1] != '\\') {
        break
      }
      end = end + 1
    }
    if end >= json.length() {
      None
    } else {
      Some(json[start:end].to_string()) catch {
        _ => None
      }
    }
  }
}

///|
pub fn HookInput::from_json_string(line : String) -> HookInput? {
  let event_str = match get_string_value(line, "event") {
    Some(v) => v
    None => return None
  }
  let event = match event_str {
    "SessionStart" => HookEvent::SessionStart
    "PreToolUse" => HookEvent::PreToolUse
    _ => return None
  }
  let session_id = get_string_value(line, "session_id")
  let agent_id = get_string_value(line, "agent_id")
  let role_str = get_string_value(line, "role")
  let role = match role_str {
    Some("root") => Some(@types.Role::Root)
    Some("tl") => Some(@types.Role::TL)
    Some("dev") => Some(@types.Role::Dev)
    Some("worker") => Some(@types.Role::Worker)
    _ => None
  }
  let tool_name = get_string_value(line, "tool_name")

  // Minimal support for args, as it's not strictly used for logic yet
  let tool_args = None
  Some({ event, session_id, agent_id, role, tool_name, tool_args })
}

///|
pub fn HookResponse::from_json_string(line : String) -> HookResponse? {
  let continue_str = match get_string_value(line, "continue") {
    Some(v) => v
    None => {
      // Try boolean without quotes
      let key_pattern = "\"continue\":"
      let i = find_substring(line, key_pattern, 0)
      if i == -1 {
        return None
      }
      let start = i + key_pattern.length()
      let rest = line[start:].to_string() catch { _ => return None }
      if rest.has_prefix("true") {
        "true"
      } else if rest.has_prefix("false") {
        "false"
      } else {
        return None
      }
    }
  }
  let continue_ = continue_str == "true"
  let message = get_string_value(line, "message")
  Some({ continue_, message })
}
