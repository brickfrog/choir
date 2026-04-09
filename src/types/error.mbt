///|
/// Orchestrator error types (suberror for `raise` / `try?` interop).
suberror ChoirError {
  AgentNotFound(String)
  ToolNotFound(String)
  PermissionDenied(String, String)
  PolicyBlocked(String)
  ValidationError(String)
  WorkspaceError(String)
  TransportError(String)
  GitError(String)
  ConfigError(String)
}

///|
pub fn ChoirError::message(self : ChoirError) -> String {
  match self {
    AgentNotFound(id) => "agent not found: " + id
    ToolNotFound(name) => "tool not found: " + name
    PermissionDenied(role, tool) => "role " + role + " cannot call " + tool
    PolicyBlocked(msg) => "policy blocked: " + msg
    ValidationError(msg) => "validation error: " + msg
    WorkspaceError(msg) => "workspace error: " + msg
    TransportError(msg) => "transport error: " + msg
    GitError(msg) => "git error: " + msg
    ConfigError(msg) => "config error: " + msg
  }
}

///|
/// Factories for use outside this package (`suberror` constructors are package-private).
pub fn ChoirError::agent_not_found(id : String) -> ChoirError {
  AgentNotFound(id)
}

///|
pub fn ChoirError::tool_not_found(name : String) -> ChoirError {
  ToolNotFound(name)
}

///|
pub fn ChoirError::permission_denied(
  role : String,
  tool : String,
) -> ChoirError {
  PermissionDenied(role, tool)
}

///|
pub fn ChoirError::policy_blocked(msg : String) -> ChoirError {
  PolicyBlocked(msg)
}

///|
pub fn ChoirError::validation_error(msg : String) -> ChoirError {
  ValidationError(msg)
}

///|
pub fn ChoirError::validation_detail_or_message(self : ChoirError) -> String {
  match self {
    ValidationError(msg) => msg
    _ => self.message()
  }
}

///|
pub fn ChoirError::workspace_error(msg : String) -> ChoirError {
  WorkspaceError(msg)
}

///|
pub fn ChoirError::transport_error(msg : String) -> ChoirError {
  TransportError(msg)
}

///|
pub fn ChoirError::git_error(msg : String) -> ChoirError {
  GitError(msg)
}

///|
pub fn ChoirError::config_error(msg : String) -> ChoirError {
  ConfigError(msg)
}

///|
pub fn ChoirError::is_tool_not_found(self : ChoirError) -> Bool {
  match self {
    ToolNotFound(_) => true
    _ => false
  }
}

///|
/// Format a caught [`Error`] when it originated from [`ChoirError`] (`try` / `catch`).
pub fn choir_error_message_from_caught(e : Error) -> String {
  match e {
    AgentNotFound(id) => ChoirError::agent_not_found(id).message()
    ToolNotFound(name) => ChoirError::tool_not_found(name).message()
    PermissionDenied(role, tool) =>
      ChoirError::permission_denied(role, tool).message()
    PolicyBlocked(msg) => ChoirError::policy_blocked(msg).message()
    ValidationError(msg) => ChoirError::validation_error(msg).message()
    WorkspaceError(msg) => ChoirError::workspace_error(msg).message()
    TransportError(msg) => ChoirError::transport_error(msg).message()
    GitError(msg) => ChoirError::git_error(msg).message()
    ConfigError(msg) => ChoirError::config_error(msg).message()
    _ => "internal error"
  }
}

///|
/// True when `e` is a [`ChoirError`] variant carried as [`Error`] (from `raise` / `catch`).
pub fn caught_error_is_choir_error(e : Error) -> Bool {
  match e {
    AgentNotFound(_)
    | ToolNotFound(_)
    | PermissionDenied(_, _)
    | PolicyBlocked(_)
    | ValidationError(_)
    | WorkspaceError(_)
    | TransportError(_)
    | GitError(_)
    | ConfigError(_) => true
    _ => false
  }
}

///|
pub fn caught_error_is_tool_not_found(e : Error) -> Bool {
  match e {
    ToolNotFound(_) => true
    _ => false
  }
}
