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
    Unknown => ""
  }
}

///|
pub fn AgentType::try_parse_wire(s : String) -> Result[AgentType, ChoirError] {
  match s {
    "" | "unknown" => Ok(Unknown)
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

///|
pub impl ToJson for AgentType with to_json(self) -> Json {
  self.to_wire_string().to_json()
}

///|
pub impl FromJson for AgentType with from_json(json, path) {
  match json {
    String(s) =>
      match AgentType::try_parse_wire(s) {
        Ok(t) => t
        Err(e) =>
          raise JsonDecodeError((path, "AgentType::from_json: " + e.message()))
      }
    _ => raise JsonDecodeError((path, "AgentType::from_json: expected string"))
  }
}

///|
pub fn TaskStatus::to_wire_string(self : TaskStatus) -> String {
  match self {
    Todo => "todo"
    InProgress => "in_progress"
    Done => "done"
  }
}

///|
pub fn TaskStatus::try_parse_wire(s : String) -> Result[TaskStatus, ChoirError] {
  match s {
    "todo" => Ok(Todo)
    "in_progress" => Ok(InProgress)
    "done" => Ok(Done)
    _ => Err(ChoirError::config_error("unknown task status: " + s))
  }
}

///|
pub fn Status::to_wire_string(self : Status) -> String {
  match self {
    Success => "success"
    Failure => "failure"
    Info => "info"
  }
}

///|
pub fn Status::try_parse_wire(s : String) -> Result[Status, ChoirError] {
  match s {
    "success" => Ok(Success)
    "failure" => Ok(Failure)
    "info" => Ok(Info)
    _ => Err(ChoirError::config_error("unknown status: " + s))
  }
}

///|
pub impl ToJson for Status with to_json(self) -> Json {
  self.to_wire_string().to_json()
}

///|
pub impl FromJson for Status with from_json(json, path) {
  match json {
    String(s) =>
      match Status::try_parse_wire(s) {
        Ok(t) => t
        Err(e) =>
          raise JsonDecodeError((path, "Status::from_json: " + e.message()))
      }
    _ => raise JsonDecodeError((path, "Status::from_json: expected string"))
  }
}
