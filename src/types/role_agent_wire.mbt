///|
/// Wire/config string for `Role` (distinct from `Show`).
pub fn Role::to_wire_string(self : Role) -> String {
  match self {
    Root => "root"
    TL => "tl"
    Dev => "dev"
    Worker => "worker"
  }
}

///|
pub fn Role::try_parse_wire(s : String) -> Result[Role, ChoirError] {
  match s {
    "root" => Ok(Root)
    "tl" => Ok(TL)
    "dev" => Ok(Dev)
    "worker" => Ok(Worker)
    _ => Err(ChoirError::config_error("unknown role: " + s))
  }
}

///|
pub fn Role::parse_wire(s : String) -> Role raise ChoirError {
  match Role::try_parse_wire(s) {
    Ok(r) => r
    Err(e) => raise e
  }
}

///|
/// Wire/config string for `AgentType` (distinct from `Show`).
pub fn AgentType::to_wire_string(self : AgentType) -> String {
  match self {
    Claude => "claude"
    Gemini => "gemini"
    MoonPilot => "moon_pilot"
    Codex => "codex"
    CursorAgent => "cursor_agent"
  }
}

///|
pub fn AgentType::try_parse_wire(s : String) -> Result[AgentType, ChoirError] {
  match s {
    "claude" => Ok(Claude)
    "gemini" => Ok(Gemini)
    "moon_pilot" => Ok(MoonPilot)
    "moonpilot" => Ok(MoonPilot)
    "codex" => Ok(Codex)
    "cursor_agent" => Ok(CursorAgent)
    "cursoragent" => Ok(CursorAgent)
    _ => Err(ChoirError::config_error("unknown agent_type: " + s))
  }
}

///|
pub fn AgentType::parse_wire(s : String) -> AgentType raise ChoirError {
  match AgentType::try_parse_wire(s) {
    Ok(t) => t
    Err(e) => raise e
  }
}
