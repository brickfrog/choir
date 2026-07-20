//|

///|
/// Orchestrator error types (suberror for `raise` / `try?` interop).
suberror ChoirError {
  AgentNotFound(String)
  ToolNotFound(String)
  PermissionDenied(String, String)
  /// An authority rejection that reports as `permission_denied` but carries a
  /// custom explanatory message (e.g. the single-writer gate's kill-to-take-over
  /// / terminal-fence wording). Same taxonomy as `PermissionDenied`, with an
  /// informative detail instead of the fixed `role X cannot call Y` rendering.
  PermissionDeniedDetail(String)
  PolicyBlocked(String)
  ProviderProtocolViolation(String)
  EventIngestionOverflow(String)
  ValidationError(String)
  Timeout(String)
  OperationCanceled(String)
  WorkspaceError(String)
  TransportError(String)
  GitError(String)
  ConfigError(String)
}

///|
pub fn ChoirError::to_wire_string(self : ChoirError) -> String {
  match self {
    AgentNotFound(_) => "agent_not_found"
    ToolNotFound(_) => "tool_not_found"
    PermissionDenied(_, _) => "permission_denied"
    PermissionDeniedDetail(_) => "permission_denied"
    PolicyBlocked(_) => "policy_blocked"
    ProviderProtocolViolation(_) => "provider_protocol_violation"
    EventIngestionOverflow(_) => "event_ingestion_overflow"
    ValidationError(_) => "validation_error"
    Timeout(_) => "timeout"
    OperationCanceled(_) => "canceled"
    WorkspaceError(_) => "workspace_error"
    TransportError(_) => "transport_error"
    GitError(_) => "git_error"
    ConfigError(_) => "config_error"
  }
}

///|
pub fn ChoirError::message(self : ChoirError) -> String {
  match self {
    AgentNotFound(id) => "agent not found: " + id
    ToolNotFound(name) => "tool not found: " + name
    PermissionDenied(role, tool) => "role " + role + " cannot call " + tool
    PermissionDeniedDetail(msg) => msg
    PolicyBlocked(msg) => "policy blocked: " + msg
    ProviderProtocolViolation(msg) => "provider protocol violation: " + msg
    EventIngestionOverflow(msg) => "event ingestion overflow: " + msg
    ValidationError(msg) => "validation error: " + msg
    Timeout(msg) => "timeout error: " + msg
    OperationCanceled(msg) => "canceled: " + msg
    WorkspaceError(msg) => "workspace error: " + msg
    TransportError(msg) => "transport error: " + msg
    GitError(msg) => "git error: " + msg
    ConfigError(msg) => "config error: " + msg
  }
}

///|
pub impl Show for ChoirError with fn output(self, logger) -> Unit {
  self.message().output(logger)
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
/// Authority rejection reported as `permission_denied` but carrying a custom
/// explanatory message (single-writer gate kill-to-take-over / terminal fence).
pub fn ChoirError::permission_denied_detail(detail : String) -> ChoirError {
  PermissionDeniedDetail(detail)
}

///|
pub fn ChoirError::policy_blocked(msg : String) -> ChoirError {
  PolicyBlocked(msg)
}

///|
pub fn ChoirError::provider_protocol_violation(msg : String) -> ChoirError {
  ProviderProtocolViolation(msg)
}

///|
pub fn ChoirError::event_ingestion_overflow(msg : String) -> ChoirError {
  EventIngestionOverflow(msg)
}

///|
pub fn ChoirError::validation_error(msg : String) -> ChoirError {
  ValidationError(msg)
}

///|
pub fn ChoirError::timeout(msg : String) -> ChoirError {
  Timeout(msg)
}

///|
pub fn ChoirError::canceled(msg : String) -> ChoirError {
  OperationCanceled(msg)
}

///|
pub fn ChoirError::validation_detail_or_message(self : ChoirError) -> String {
  match self {
    ValidationError(msg) => msg
    Timeout(msg) => msg
    OperationCanceled(msg) => msg
    PermissionDeniedDetail(msg) => msg
    _ => self.message()
  }
}

///|
pub fn ChoirError::config_detail(self : ChoirError) -> String? {
  match self {
    ConfigError(msg) => Some(msg)
    _ => None
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
pub fn ChoirError::is_timeout(self : ChoirError) -> Bool {
  match self {
    Timeout(_) => true
    _ => false
  }
}

///|
pub fn ChoirError::is_provider_protocol_violation(self : ChoirError) -> Bool {
  match self {
    ProviderProtocolViolation(_) => true
    _ => false
  }
}

///|
pub fn ChoirError::is_event_ingestion_overflow(self : ChoirError) -> Bool {
  match self {
    EventIngestionOverflow(_) => true
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
    PermissionDeniedDetail(msg) =>
      ChoirError::permission_denied_detail(msg).message()
    PolicyBlocked(msg) => ChoirError::policy_blocked(msg).message()
    ProviderProtocolViolation(msg) =>
      ChoirError::provider_protocol_violation(msg).message()
    EventIngestionOverflow(msg) =>
      ChoirError::event_ingestion_overflow(msg).message()
    ValidationError(msg) => ChoirError::validation_error(msg).message()
    Timeout(msg) => ChoirError::timeout(msg).message()
    OperationCanceled(msg) => ChoirError::canceled(msg).message()
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
    | PermissionDeniedDetail(_)
    | PolicyBlocked(_)
    | ProviderProtocolViolation(_)
    | EventIngestionOverflow(_)
    | ValidationError(_)
    | Timeout(_)
    | OperationCanceled(_)
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

///|
pub fn caught_error_is_agent_not_found(e : Error) -> Bool {
  match e {
    AgentNotFound(_) => true
    _ => false
  }
}
