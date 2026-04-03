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
pub fn Role::parse_wire(s : String) -> Role raise ChoirError {
  match s {
    "root" => Root
    "tl" => TL
    "dev" => Dev
    "worker" => Worker
    _ => raise ChoirError::config_error("unknown role: " + s)
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
    Pi => "pi"
  }
}

///|
pub fn AgentType::parse_wire(s : String) -> AgentType raise ChoirError {
  match s {
    "claude" => Claude
    "gemini" => Gemini
    "moon_pilot" => MoonPilot
    "moonpilot" => MoonPilot
    "codex" => Codex
    "cursor_agent" => CursorAgent
    "cursoragent" => CursorAgent
    "pi" => Pi
    _ => raise ChoirError::config_error("unknown agent_type: " + s)
  }
}
